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
 |  prometheus + grafana        |  |             |  egress Private Link gateway  |
 |   (127.0.0.1, SSH tunnel)    |  |             |  access points: blob + dfs    |
 +------------------------------+  |             +--------+----------------------+
            | blob private endpoint|                      |
            v                      |                      |
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
| Sync -> Confluent API / Snowflake SQL | HTTPS control plane: topic names, metadata file paths, DDL | Yes, metadata only |
| Producer -> Schema Registry | Public Schema Registry endpoint: Avro schemas and lookups | Yes, schemas only |
| Prometheus -> Metrics API | `api.telemetry.confluent.cloud` from the VM: throughput counters and offsets | Yes, metrics only |
| Users -> Snowflake | Snowsight / drivers on the public Snowflake endpoint: **query results** | Yes (private needs Snowflake inbound Private Link, Business Critical) |

All Kafka record data moves privately from producer to Snowflake's storage reads. The Snowflake
leg uses VNet service endpoints rather than Private Link: traffic stays on the Azure backbone and
only Snowflake's subnets pass the firewall, but the storage account's public endpoint is still
"enabled from selected networks", not disabled.

Snowflake option A works on any edition but requires the Snowflake account and the storage
account to be in the same Azure region. On Business Critical you can swap it for Snowflake
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

### Proving the REST catalog is empty on a private cluster

```bash
eval "$(terraform -chdir=infra output -raw vm_ssh)"
sudo -u demo /opt/tableflow-demo/run check_rest_catalog.py
```

```
GET /v1/config                         -> 200
GET /v1/namespaces                     -> 200  {"namespaces":[["lkc-2266qdq"]]}
GET /v1/namespaces/lkc-2266qdq/tables  -> 200  {"identifiers":[]}
LOAD table stock_trades                -> 404  NoSuchResourceException
```

The Iceberg REST Catalog is a public, internet-reachable service
(`tableflow.<region>.<cloud>.confluent.cloud` resolves to a public IP and answers over TLS).
Private networking does not change its reachability, it changes its contents: the catalog serves
config and the namespace, then lists zero tables and 404s on a topic Tableflow is actively
materializing. That is the limitation this whole demo works around, shown live rather than quoted.

On a public-networking cluster the same walk returns the table with a `metadata-location`, which
is what Snowflake or Spark would federate to. The catalog's OAuth only accepts a resource-scoped
Tableflow API key; a cloud-scoped key returns `invalid_grant`.

### Counting records at each stage

```bash
eval "$(terraform -chdir=infra output -raw vm_ssh)"
sudo -u demo /opt/tableflow-demo/run counts.py
```

```
topic                     in Kafka    in Iceberg  in Snowflake    behind
--------------------------------------------------------------------------
stock_trades               476,900       469,100       469,100     7,800
```

Kafka has no record count, so the first column sums `high - low` watermark offsets across
partitions, which is records currently retained. The other two read `total-records` from the
Iceberg snapshot summary: the newest metadata file in ADLS, and whichever file Snowflake is
pointing at. That is what a Snowflake query would return right now, obtained without running
`COUNT(*)` and without waking the warehouse.

A gap in `behind` is the pipeline working normally, since Kafka runs about one Tableflow commit
interval ahead. Iceberg and Snowflake differing from each other is the interesting case: that is
the window before `sync.py` refreshes, and the cost of having no Iceberg REST catalog here.

### Monitoring

Prometheus and Grafana run on the demo VM. Prometheus scrapes the Confluent Cloud
[Metrics API](https://docs.confluent.io/cloud/current/monitoring/metrics-api.html) `/export`
endpoint directly, which speaks OpenMetrics, so there is no exporter process to maintain. This
is the same pattern as Confluent's own
[ccloud-prometheus-grafana](https://github.com/confluentinc/jmx-monitoring-stacks/tree/main/ccloud-prometheus-grafana)
reference stack. Scrape interval is 1 minute, which is the granularity Confluent publishes at.

The scrape uses a dedicated service account with `MetricsViewer` **scoped to this environment**
and its own cloud API key, both created and destroyed with the demo. The `/export` endpoint
rejects resource-scoped keys with `403`. Nothing in this demo touches shared org-level
notification integrations or subscriptions.

The dashboard covers the whole chain:

| Section | Source | Shows |
|---|---|---|
| Kafka to Tableflow | `io.confluent.tableflow/*` | rows read vs committed, event and processing freshness, bytes read vs written, snapshots committed, rows skipped, sync active |
| ADLS to Snowflake | `sync.py` textfile via node_exporter | rows in ADLS vs rows Snowflake can see, snapshot age, whether Snowflake points at the newest metadata file, sync job health |
| Kafka cluster | `io.confluent.kafka.server/*` | topic ingress, retained bytes |

The middle section exists because Confluent's metrics stop at "snapshot committed to ADLS" and
Snowflake has no catalog to federate to here, so the last hop is invisible to both vendors.
`sync.py` already knows both sides, so it writes them as a Prometheus textfile. Row counts come
from the Iceberg snapshot summary (`total-records`) rather than `COUNT(*)`, so the dashboard
costs no Snowflake warehouse time and keeps reporting while the warehouse is suspended.

Two things about the `/export` endpoint that are easy to get wrong:

- **Metrics typed `COUNTER` are not cumulative.** Each scrape returns the value for the most
  recent complete minute, so `received_bytes` sits flat at the per-minute byte count instead of
  climbing. `rate()` and `increase()` against them return no data. The dashboard uses them raw
  and reads them as "per minute", dividing by 60 only where a per-second unit is wanted.
- **`honor_timestamps` must be `false`.** Confluent stamps each point with the minute it covers
  and repeats that stamp until a new point is published. Honouring those timestamps makes
  Prometheus drop the repeats as duplicate samples, leaving about one sample per window and
  empty panels.

Some metrics never publish on this deployment and are deliberately not on the dashboard:
`storage_bytes` measures Confluent-owned buckets, which a bring-your-own-storage setup does not
use, and `kafka_topic_offset` / `table_offset` are not emitted on this cluster, so the
materialization panel uses the freshness gauges instead. Metrics with a zero value are omitted
from the export entirely, which is why `rows_skipped` is wrapped in `or vector(0)`.

The dashboard is generated, not hand-edited. After changing panels run:

```bash
python3 app/monitoring/generate_dashboard.py
```

Open it with the tunnel from `terraform output`:

```bash
eval "$(terraform -chdir=infra output -raw grafana_tunnel)" &
open http://localhost:3000
```

Grafana binds to `127.0.0.1` on the VM and the NSG only opens port 22 from `ssh_allowed_cidr`,
so the SSH session is the only way in. Anonymous viewer access is therefore enabled and the
tunnel lands straight on the dashboard with no login prompt. An admin login still exists for
editing panels: `terraform -chdir=infra output -raw grafana_admin_password`.

## Layout

| Path | What |
|---|---|
| `infra/` | Azure VNet, PLATT ingress, ADLS + firewall, Confluent env/cluster/RBAC, egress gateway + access points + DNS, Tableflow, demo VM |
| `snowflake/` | Storage firewall rule for Snowflake subnets, external volume, object-store catalog integration, DB/schema/warehouse, sync role + key-pair service user, pushes sync config to the VM |
| `app/` | VM code: `producer.py`, `create_topics.py`, `sync.py`, `add_topic.py`, `metrics.py`, `counts.py`, `check_rest_catalog.py`, systemd units, cloud-init |
| `app/monitoring/` | Prometheus + Grafana + node_exporter compose stack, scrape config, provisioned dashboard |
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
cp .env.example .env                           # fill in Confluent + Snowflake credentials
set -a; . ./.env; set +a
export TF_VAR_confluent_cloud_api_key=$CONFLUENT_CLOUD_API_KEY
export TF_VAR_confluent_cloud_api_secret=$CONFLUENT_CLOUD_API_SECRET
cd infra
cp terraform.tfvars.example terraform.tfvars   # edit subscription, tenant, your IP, tags
terraform init && terraform apply
```

Check the VM is producing and Tableflow is writing (discovery-only mode until Snowflake is set up):

```bash
eval "$(terraform output -raw vm_ssh)"
sudo journalctl -u tableflow-producer -n 5
sudo journalctl -u tableflow-sync -n 20
```

### 2. Snowflake (two applies, Azure consent in between)

```bash
cd ../snowflake
cp terraform.tfvars.example terraform.tfvars   # org + account name (not the locator)
export SNOWFLAKE_USER=$SNOWFLAKE_USERNAME SNOWFLAKE_PASSWORD   # or SNOWFLAKE_AUTHENTICATOR=externalbrowser
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
3. Query in Snowflake (`terraform output query_example`), rerun a few minutes later and watch
   counts grow (Tableflow commits roughly every 3 minutes at the default 50 msg/s).
4. Add a topic live and watch it appear in Snowflake without touching Snowflake. From the VM
   (`eval "$(terraform -chdir=infra output -raw vm_ssh)"`):

   ```bash
   sudo -u demo /opt/tableflow-demo/run add_topic.py stock_quotes
   sudo journalctl -fu tableflow-sync
   ```

   Allow about 5 minutes: the table appears in Snowflake as soon as Tableflow's first snapshot
   lands, but that snapshot is empty; rows show up with the next one. Topic names must start
   with `stock_` (the producer's RBAC prefix) and each name can only be used once per deployment.

5. Open Grafana (`eval "$(terraform -chdir=infra output -raw grafana_tunnel)" &`, then
   <http://localhost:3000>) and walk the chain top to bottom. The two panels worth narrating:

   - **Materialization latency** sawtooths up between Tableflow commits and collapses on each
     one. That is the Iceberg commit interval made visible.
   - **Rows committed to ADLS but not yet visible in Snowflake** is the architectural cost of
     losing the Iceberg REST catalog on a private cluster. It fills up as Tableflow commits and
     drops to zero when `sync.py` issues the next `REFRESH`. On the public-networking version of
     this demo, that panel would not exist: Snowflake would federate to the catalog directly.

   The topic you added in step 4 appears as a new series in both sections within a few minutes.

## Cleanup

Log in to the tenant that holds the resources (`az login --tenant <tenant-id>`), load the same
env vars as for deploy, then destroy Snowflake first:

```bash
cd snowflake && terraform destroy
cd ../infra && terraform destroy
```

Topics added live with `add_topic.py` have Tableflow enabled outside Terraform. They go away
with the cluster; if Confluent refuses to delete the cluster, disable Tableflow on those topics
in the Confluent Cloud console and run the destroy again.

If the Confluent provider integration refuses deletion (409, still `ACTIVE`), see the
cleanup notes in the original repo: `terraform state rm confluent_provider_integration_setup.azure`
and destroy again.

## Caveats

- This is a stop-gap until Tableflow's IRC or catalog sync supports private networking.
- Tableflow commits on a best-effort cadence (about every 3 minutes in this demo, up to ~5 for
  low-throughput topics) and a new topic's first snapshot is empty, so a new table takes a few
  minutes to show rows.
- Snowflake tables created by the sync are read-only, externally managed Iceberg tables.
- Schema Registry uses its public endpoint (schemas only, no records); it supports Private Link
  on Enterprise if you need it.
- The demo VM has a public IP (SSH from `ssh_allowed_cidr`, package installs). Use Azure Bastion
  and a NAT gateway for anything real.
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
