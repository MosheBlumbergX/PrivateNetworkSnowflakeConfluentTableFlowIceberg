# CLAUDE.md

Guidance for Claude Code when working in this repository. `README.md` is the full write-up
(architecture, deploy steps, demo script). This file is the short version plus the things that
are easy to get wrong.

## What this project is

A demo of getting Kafka data into Snowflake with **no public data path**, on Azure:

```
Kafka (Confluent Enterprise, Private Link) -> Tableflow (Iceberg) -> ADLS Gen2 (private) -> Snowflake
```

The problem it solves: on a privately networked Confluent cluster the **Tableflow Iceberg REST
Catalog serves no tables** (it answers, but lists zero and 404s on a live topic), so Snowflake
cannot federate to it. This demo skips the catalogue and uses **storage as the source of truth**:
Snowflake reads Tableflow's Iceberg metadata files straight from ADLS through an object-store
catalog integration, and a small job (`app/sync.py`) keeps each Snowflake table pointed at the
newest snapshot.

It is a stop-gap until Tableflow's catalogue or catalog sync supports private networking.

## Layout

| Path | What |
|---|---|
| `infra/` | Terraform: Azure VNet, Private Link ingress and egress, ADLS + firewall, Confluent environment/cluster/RBAC, Tableflow, the demo VM, monitoring service account |
| `snowflake/` | Terraform: storage firewall rule for Snowflake subnets, external volume, object-store catalog integration, database/schema/warehouse, sync role and key-pair service user, pushes config to the VM |
| `app/` | Code that runs on the VM: `producer.py`, `create_topics.py`, `sync.py`, `add_topic.py`, `counts.py`, `check_rest_catalog.py`, `evotest_produce.py`, `metrics.py`, systemd units, cloud-init, `deploy.sh.tftpl` |
| `app/monitoring/` | Prometheus + Grafana + node_exporter stack. The dashboard JSON is **generated**: edit `generate_dashboard.py`, then run it, never hand-edit the JSON |
| `scripts/` | `vm-run.sh` (runs a local script on the VM via `az vm run-command`), `approve-egress-endpoint.sh` |
| `docs/storage-retention.md` | Snapshot retention and what disabling Tableflow does to the data |
| `migration-test/` | Separate Terraform stack proving migration from this solution to the native catalogue on a **public** cluster. See `MIGRATION-TEST.md` |
| `slides/` | Slide deck for presenting the demo |
| `comms/` | Local drafts of emails and messages. Git-ignored, never commit |

## How it fits together

- `snowflake/` reads `infra/`'s **local Terraform state** (`terraform_remote_state`, local backend)
  for names, IDs and tags. Apply `infra/` first, and keep both state files on the same machine.
- A laptop cannot reach a private cluster's REST endpoint. Anything that talks to the cluster
  (topic creation, producing) runs **on the VM**. Terraform pushes files and config there with
  `scripts/vm-run.sh`, which wraps `az vm run-command` and fails unless the script prints a
  success marker (`DEPLOY_OK`, `SNOWFLAKE_CONFIG_OK`).
- Changing anything in `app/` that is listed in `local.app_files` (`infra/vm.tf`) or the deploy
  template re-runs the deploy on the next `terraform apply`. New files must be added to that list.
- `sync.py` runs every 60 seconds from a systemd timer. Without Snowflake settings it runs in
  discovery-only mode and only logs.
- Snowflake setup needs **two applies** with an Azure consent step in between
  (`snowflake_azure_consent_completed`, see the README).

## Behaviour of `sync.py` you must preserve

- It drops a Snowflake table **only** when the topic is absent from the Tableflow API. A topic that
  is merely `FAILED` or `PENDING` (for example during a bad schema evolution) must never cause a drop.
- Each table is synced in isolation: one failing table is logged, the others still refresh, and the
  run exits non-zero at the end so systemd and the `tableflow_sync_success` metric report failure.
- Error 003041 ("already exists, but current role has no privileges") means another role owns the
  table, so `SHOW ICEBERG TABLES` could not see it and `CREATE` was attempted. Fix by transferring
  ownership to the sync role (`GRANT OWNERSHIP ... TO ROLE <PREFIX>_SYNC_ROLE COPY CURRENT GRANTS`),
  not by changing the code. Tables must be **owned** by the sync role, not just readable.
- Row counts come from the Iceberg snapshot summary (`total-records`), not `COUNT(*)`, so metrics cost
  no warehouse time.

## Things that fail in non-obvious ways

- **Tableflow and Avro:** added fields must be optional (`["null","string"]`, default null). A new
  required field passes Schema Registry but Tableflow FAILs the topic, and a FAILED topic does not
  self-recover: disable and re-enable it.
- **Confluent Metrics API `/export`:** `COUNTER` metrics are per-minute values, not cumulative, so
  `rate()` and `increase()` return nothing. `honor_timestamps` must be `false` in the scrape config.
  It rejects resource-scoped API keys, so the monitoring key is cloud-scoped.
- **Tableflow IRC auth:** the catalogue's OAuth accepts only a resource-scoped Tableflow API key.
  A cloud-scoped key returns `invalid_grant`.
- **Confluent tenant:** the Azure tenant must be the user's own. Confluent rejects provider
  integrations pointing at Confluent's corporate tenant.
- **Same region:** the Snowflake account and the storage account must be in the same Azure region for
  the subnet firewall approach.
- **Implicit Azure resources** (OS disk, private endpoint NICs) do not inherit tags. `infra/vm.tf`
  tags them with `az tag update`. Do the same for any new implicit resource.
- No Snowflake client is installed locally. Snowflake SQL either goes through Terraform, the
  Snowsight UI, or runs on the VM (`/opt/tableflow-demo/run <script.py>`).

## Common commands

```bash
# Credentials (never print or commit these)
set -a; . ./.env; set +a
export TF_VAR_confluent_cloud_api_key=$CONFLUENT_CLOUD_API_KEY
export TF_VAR_confluent_cloud_api_secret=$CONFLUENT_CLOUD_API_SECRET

# Infra, then Snowflake (SNOWFLAKE_USER / SNOWFLAKE_PASSWORD or SNOWFLAKE_AUTHENTICATOR must be set)
cd infra && terraform plan && terraform apply
cd ../snowflake && terraform plan && terraform apply

# On the VM
eval "$(terraform -chdir=infra output -raw vm_ssh)"
sudo journalctl -u tableflow-sync -n 20
sudo -u demo /opt/tableflow-demo/run counts.py

# Regenerate the Grafana dashboard after editing panels
python3 app/monitoring/generate_dashboard.py

# Quick syntax check of VM code
python3 -m py_compile app/sync.py
```

## Working rules for this repo

- **Secrets:** `.env`, `*.tfstate`, `*tfplan*`, `*.tfvars`, `.generated/` and `*.pem` are git-ignored
  and contain credentials or generated keys. Do not read them aloud, print them, or commit them.
  `.terraform.lock.hcl` has no secrets (provider versions and checksums) and should be committed.
- **Confirm before applying:** `terraform apply` and `destroy` change a live Confluent environment,
  Azure subscription and Snowflake account, and Snowflake setup ends with a VM push. Run `plan`, show
  the summary, and get a yes first. Never open an inbound port to the internet without being asked.
- **Cloud tags:** every Azure resource carries the tags in `var.tags` (owner, `cflt_service`,
  `cflt_managed_by`, `cflt_managed_id`, `cflt_keep_until`). They come from `infra/terraform.tfvars`,
  which is per-user and git-ignored. Do not hard-code tag values, and add tags to any new resource.
- **Git:** do not push or open pull requests unless asked. Commit only when asked.
- **Communications** (emails, Slack or chat drafts) go in `comms/`, which is git-ignored.
- Keep the README, this file and `docs/` in step with behaviour changes. Verify claims against the
  code or a live check before writing them down.

## History worth knowing

- A **self-hosted read-only Iceberg REST catalogue** was prototyped for this demo (a small FastAPI
  service on the VM behind Caddy, with a Snowflake `ICEBERG_REST` integration using
  `EXTERNAL_VOLUME_CREDENTIALS`). It worked: Snowflake accepted `abfss://` metadata locations and
  row counts matched the object-store tables. It was **removed** because it needed a public HTTPS
  endpoint and complicated the demo, and the repo returned to the storage-sync design. The idea
  lives on as a separate, local-only example (`BuildYourOwnIcebergCatalog`, outside this repo).
- `migration-test/` documents moving from this solution to the native Tableflow catalogue and then
  Horizon catalogue federation, tested on a public cluster.
