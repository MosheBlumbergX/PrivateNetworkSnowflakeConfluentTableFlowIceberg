# Azure Private Link: Confluent Tableflow -> ADLS -> Snowflake (no public data path)

Private-networking variant of
[SnowflakeConfluentTableFlowIceberg](https://github.com/MosheBlumbergX/SnowflakeConfluentTableFlowIceberg). That demo has
Snowflake federate to the **Tableflow Iceberg REST Catalog (IRC)**. On a privately networked
cluster that isn't possible:

> The built-in Apache Iceberg REST Catalog is not supported in private networking-enabled
> clusters. ([Tableflow private networking](https://docs.confluent.io/cloud/current/topics/tableflow/operate/tableflow-private-networking.html))

On Azure, the external catalog sync targets don't help either (Glue is AWS only, Unity Catalog
and Open Catalog are not supported over private networking). So this demo **skips the catalog
and uses storage as the source of truth**: Snowflake reads Tableflow's Iceberg metadata files
directly from ADLS, and a small sync job keeps Snowflake pointed at the latest snapshot.
The approach is adapted from Jeremy Ber's
[tableflow-manual-sync-to-unity-catalog](https://github.com/jeremyber/tableflow-manual-sync-to-unity-catalog)
(see [Credits](#credits)).

## Architecture

```
 Customer VNet (uksouth)                         Confluent Cloud (uksouth)
 +------------------------------+                +-------------------------------+
 | demo VM                      |  Private Link  | Enterprise Kafka cluster      |
 |  producer.py (Avro) ---------+--(PLATT PE)--->|  topic stock_trades           |
 |                              |                |        | Tableflow (Iceberg)   |
 |  sync.py (systemd timer) ----+--+             |        v                      |
 +------------------------------+  |             |  egress Private Link gateway  |
            | blob private endpoint|             |  access points: blob + dfs    |
            v                      |             +--------+----------------------+
 +------------------------------+  |                      | private endpoints
 | ADLS Gen2 (HNS)              |<-+----------------------+ (approved on the account)
 | firewall: default Deny       |
 |  allow: Snowflake VNet       |<---- Snowflake (Azure uksouth), service endpoints
 |         subnets (option A)   |      object-store catalog integration
 +------------------------------+      + Iceberg tables refreshed by sync.py
```

| Leg | Path | Public internet? |
|---|---|---|
| Producer -> Kafka | Azure Private Link (Private Link Attachment) | No |
| Tableflow -> ADLS | Confluent egress Private Link gateway (blob + dfs) | No |
| Snowflake -> ADLS | Storage firewall allows Snowflake's Azure VNet subnets (service endpoints on the Azure backbone) | No (account is "selected networks" only) |
| VM sync -> ADLS | Private endpoint in the VNet | No |
| Sync -> Confluent API / Snowflake SQL | HTTPS control plane, metadata only (topic names, metadata file paths) | Yes, no customer data |

Snowflake option A works on any edition. On Business Critical you can swap it for Snowflake
outbound Private Endpoints (`USE_PRIVATELINK_ENDPOINT = TRUE`) and disable public network
access on the storage account entirely.

### How the sync works (`app/sync.py`, every 60s)

1. List Tableflow topics via the Confluent Cloud API; keep `RUNNING` Iceberg topics and their `table_path`.
2. Find the newest `metadata/*.metadata.json` under each table path in ADLS (managed identity, private endpoint).
3. In Snowflake: `CREATE ICEBERG TABLE ... CATALOG = <object store integration> METADATA_FILE_PATH = ...`
   for new topics, `ALTER ICEBERG TABLE ... REFRESH '<newest metadata>'` when the snapshot moved,
   and drop tables it created whose topic no longer has Tableflow.

Snowflake can't auto-refresh Iceberg tables from an object-store catalog integration, which is
why the job does it. Freshness is roughly the Tableflow commit interval plus up to 60s.

## Layout

| Path | What |
|---|---|
| `infra/` | Azure VNet, PLATT ingress, ADLS + firewall, Confluent env/cluster/RBAC, egress gateway + access points + DNS, Tableflow, demo VM |
| `snowflake/` | Storage firewall rule for Snowflake subnets, external volume, object-store catalog integration, DB/schema/warehouse, sync role + key-pair service user, pushes sync config to the VM |
| `app/` | VM code: `producer.py`, `create_topics.py`, `sync.py`, `add_topic.py`, systemd units, cloud-init |
| `scripts/` | `approve-egress-endpoint.sh` (approves Confluent's private endpoints on the storage account), `vm-run.sh` (`az vm run-command` wrapper) |

Terraform on a laptop can't reach a private cluster's REST endpoint, so permissions use RBAC role
bindings (control plane) and topic creation happens on the VM via `az vm run-command`.

## Deploy

Prerequisites: Terraform >= 1.6, Azure CLI logged in (`az login --tenant <tenant-id>`), Python 3,
a Snowflake account in the **same Azure region** as `region` (check with `SELECT CURRENT_REGION()`),
and ACCOUNTADMIN.

The Azure tenant must be your own: Confluent rejects provider integrations that point at
Confluent's corporate tenant ("You cannot use Confluent's tenant ID as your own").

### 1. Azure + Confluent

```bash
set -a; . ./.env; set +a
export TF_VAR_confluent_cloud_api_key=$CONFLUENT_CLOUD_API_KEY
export TF_VAR_confluent_cloud_api_secret=$CONFLUENT_CLOUD_API_SECRET
cd infra
cp terraform.tfvars.example terraform.tfvars   # edit subscription, tenant, your IP, tags
terraform init && terraform apply
```

Check the VM is producing and Tableflow is writing (discovery-only mode until Snowflake is set up):

```bash
$(terraform output -raw vm_ssh)
sudo journalctl -u tableflow-producer -n 5
sudo journalctl -u tableflow-sync -n 20
```

### 2. Snowflake (two applies, Azure consent in between)

```bash
cd ../snowflake
cp terraform.tfvars.example terraform.tfvars   # org + account name
export SNOWFLAKE_USER=... SNOWFLAKE_PASSWORD=...   # or SNOWFLAKE_AUTHENTICATOR=externalbrowser
terraform init && terraform apply
terraform output snowflake_azure_consent_url     # open, accept as tenant admin
# set snowflake_azure_consent_completed = true in terraform.tfvars
terraform apply
terraform output query_example
```

## Demo script

1. Show the storage account networking: public access limited to selected networks, Snowflake
   subnets only, plus the two approved `plap-*` private endpoints from Confluent.
2. Show the Confluent environment: Enterprise cluster, Private Link Attachment, egress gateway.
3. Query in Snowflake (`terraform output query_example`), rerun after a minute and watch counts grow.
4. Add a topic live and watch it appear in Snowflake without touching Snowflake:

   ```bash
   sudo -u demo /opt/tableflow-demo/run add_topic.py stock_orders
   sudo journalctl -fu tableflow-sync
   ```

   Topic names must start with `stock_` (the producer's RBAC prefix).

## Cleanup

```bash
cd snowflake && terraform destroy
cd ../infra && terraform destroy
```

If the Confluent provider integration refuses deletion (409, still `ACTIVE`), see the
cleanup notes in the original repo: `terraform state rm confluent_provider_integration_setup.azure`
and destroy again.

## Caveats

- This is a stop-gap until Tableflow's IRC or catalog sync supports private networking.
- Tableflow commits low-throughput topics on a best-effort ~5 minute cadence, so the first table
  can take a few minutes to appear.
- Snowflake tables created by the sync are read-only, externally managed Iceberg tables.
- Schema Registry uses its public endpoint (schemas only, no records).
- Secrets reach the VM through `az vm run-command`; fine for a demo, use Key Vault for anything real.

## Credits

- **Jeremy Ber** ([@jeremyber](https://github.com/jeremyber)): the sync pattern in `app/sync.py`
  (discover Tableflow topics via the Confluent Cloud API, register them in the query engine,
  diff-based and idempotent, only `RUNNING` topics) comes from his
  [tableflow-manual-sync-to-unity-catalog](https://github.com/jeremyber/tableflow-manual-sync-to-unity-catalog).
  This repo adapts it from Unity Catalog + Delta to Snowflake + Iceberg, adding the step that
  finds the newest Iceberg metadata file and refreshes the Snowflake table to it.
- The Terraform for Tableflow + Snowflake Horizon this demo builds on is also based on his
  [Integrate-Tableflow-with-Snowflake-Horizon-Catalog](https://github.com/jeremyber/Integrate-Tableflow-with-Snowflake-Horizon-Catalog)
  guide.
