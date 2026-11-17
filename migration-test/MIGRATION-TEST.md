# Migration test: storage-sync solution to native Tableflow Catalog (public cluster)

Date: 2026-11-17 · Environment: `env-2kpn8o` (Confluent, Azure uksouth)

## Why this test

On a private-networking cluster the Tableflow Iceberg REST Catalog (IRC) does not serve
tables, so this repo's solution has Snowflake read Iceberg metadata directly from ADLS via a
sync job (`sync.py` + an object-store catalog integration). When Confluent lifts the
private-networking IRC restriction, private clusters will be able to use the native catalog like
public ones.

This test de-risks that change by proving the migration on a **public** cluster in the same
environment: start on the manual storage-sync solution, then migrate to the native **Tableflow
Iceberg REST Catalog** (per-table), then to **Horizon catalog federation** (a Snowflake
catalog-linked database with auto-discovery). The Snowflake-side wiring is identical regardless
of the cluster's networking, so a clean public-cluster migration is strong evidence the private
path will work once the restriction is lifted.

## What was built

| Thing | Value |
|---|---|
| Public cluster | `lkc-0x6mm62` (Standard), topic `pub_orders2` |
| Data source | fully-managed Datagen (`ORDERS`, AVRO), 4 tasks, `max.interval=20` |
| Tableflow | Iceberg, writing to a **separate open** ADLS account `mbpltfpub<suffix>` |
| Snowflake | `TABLEFLOW_PUB_DB.CONFLUENT`, external volume `TABLEFLOW_PUB_ADLS_VOLUME` |

Terraform: `migration-test/` (Confluent + the open storage account + RBAC) and
`migration-test/snowflake/` (external volume, object-store integration, REST integration,
catalog-linked database). Not committed.

## The three methods, same ADLS data

All three read the identical Iceberg data through the same external volume. Nothing was
re-materialized or copied between methods.

| Method | Snowflake object | Discovery | Refresh | Rows observed |
|---|---|---|---|---|
| Our solution | `PUB_ORDERS2` (object-store) | manual (`sync.py`) | manual `METADATA_FILE_PATH` | 222,989 |
| REST per-table | `PUB_ORDERS2_REST` | manual `CREATE … CATALOG_TABLE_NAME` | auto | 297,588 |
| Horizon federation | `TABLEFLOW_PUB_LINKED."lkc-0x6mm62"."pub_orders2"` | auto (catalog-linked DB) | auto (30s) | 372,087 |

The row counts rise only because each method read a later snapshot of the same growing table.
The manual table is frozen where `sync.py` last pinned it; the native tables keep up on their own.

## The DDL (from Snowflake GET_DDL / DESC)

Native REST catalog integration (the migration target):

```sql
CREATE CATALOG INTEGRATION TABLEFLOW_PUB_REST
  CATALOG_SOURCE = ICEBERG_REST
  TABLE_FORMAT   = ICEBERG
  CATALOG_NAMESPACE = 'lkc-0x6mm62'                 -- Confluent cluster id = IRC namespace
  REST_CONFIG = (
    CATALOG_URI = 'https://tableflow.uksouth.azure.confluent.cloud/iceberg/catalog/organizations/<org>/environments/env-2kpn8o',
    CATALOG_API_TYPE = PUBLIC,
    ACCESS_DELEGATION_MODE = EXTERNAL_VOLUME_CREDENTIALS   -- BYOS: read via our external volume, not vended creds
  )
  REST_AUTHENTICATION = (
    TYPE = OAUTH,
    OAUTH_TOKEN_URI = '.../v1/oauth/tokens',
    OAUTH_CLIENT_ID = '<tableflow API key>',
    OAUTH_ALLOWED_SCOPES = ('catalog')
  )
  ENABLED = true;
```

The table, three ways:

```sql
-- our manual solution: a hard-pinned snapshot that sync.py keeps rewriting
CREATE ICEBERG TABLE PUB_ORDERS2
  EXTERNAL_VOLUME = 'TABLEFLOW_PUB_ADLS_VOLUME'
  CATALOG = 'TABLEFLOW_PUB_OBJECT_STORE'
  METADATA_FILE_PATH = '.../lkc-0x6mm62/v1/.../metadata/00004-....metadata.json';

-- REST per-table: no metadata path, auto-refresh from the catalog
CREATE ICEBERG TABLE PUB_ORDERS2_REST
  EXTERNAL_VOLUME    = 'TABLEFLOW_PUB_ADLS_VOLUME'
  CATALOG            = 'TABLEFLOW_PUB_REST'
  CATALOG_TABLE_NAME = 'pub_orders2'
  CATALOG_NAMESPACE  = 'lkc-0x6mm62'
  AUTO_REFRESH       = true;

-- Horizon federation: this is the ONLY statement you write
CREATE DATABASE TABLEFLOW_PUB_LINKED
  LINKED_CATALOG = (
    CATALOG = 'TABLEFLOW_PUB_REST',
    ALLOWED_NAMESPACES = ('lkc-0x6mm62'),
    NAMESPACE_MODE = IGNORE_NESTED_NAMESPACE,
    SYNC_INTERVAL_SECONDS = 30
  )
  EXTERNAL_VOLUME = 'TABLEFLOW_PUB_ADLS_VOLUME';
```

For the linked database Snowflake then generates the schema and table DDL itself (one schema per
namespace, one table per topic), and new topics appear automatically on the sync interval with no
DDL at all.

## Verdict on "seamless migration"

- **Storage reuse is fully seamless.** All three methods share one external volume. Nothing is
  re-materialized; no data is copied. The migration is purely a catalog/metadata change.
- **The DDL arc shrinks:** per-table `METADATA_FILE_PATH` (plus a sync job) to per-table
  `CATALOG_TABLE_NAME` (auto-refresh) to a single `LINKED_CATALOG` database (auto-discovery). The
  sync job, and the whole object-store integration, can be retired.
- **The one non-transparent step is table identity.** The fully-qualified name consumers query
  changes between methods. See "Migrating the queries" below for the cutover options and which one
  is truly gapless.

## Migrating the queries (preserving table identity)

Data migrates seamlessly on storage, but everything that queries these tables (dashboards,
scheduled jobs, dbt models, ad-hoc SQL) binds to a **fully-qualified name** `DATABASE.SCHEMA.TABLE`.
That name differs between methods, so retiring the manual table breaks existing queries unless you
plan the cutover.

Today (our solution):

```sql
SELECT ... FROM TABLEFLOW_PUB_DB.CONFLUENT.PUB_ORDERS2
```

Under Horizon federation the same data lives at a different name:

```sql
SELECT ... FROM TABLEFLOW_PUB_LINKED."lkc-0x6mm62"."pub_orders2"
```

All three parts change:

- **Database** is a new object (`TABLEFLOW_PUB_LINKED`).
- **Schema = the Kafka cluster id** (`lkc-0x6mm62`), set by Tableflow as the Iceberg namespace. It
  has a hyphen, so it is not a legal bare identifier and must be double-quoted everywhere.
- **Table = the topic name, lowercase** (`pub_orders2`), created as a quoted lowercase identifier.

Casing footgun: Snowflake folds **unquoted** identifiers to uppercase, so the manual `PUB_ORDERS2`
is case-insensitive, but the federated `"pub_orders2"` must be written **quoted and lowercase**.
This fails: `... "lkc-0x6mm62".pub_orders2` (it looks for `PUB_ORDERS2`). Only the fully-quoted form
works. And you cannot rename your way out inside a linked database: its schema and table objects are
managed by the catalog sync, so their names are dictated by the catalog, not by you.

### Option A - view that preserves the old name (brief gap, enables federation)

```sql
DROP ICEBERG TABLE TABLEFLOW_PUB_DB.CONFLUENT.PUB_ORDERS2;
CREATE VIEW  TABLEFLOW_PUB_DB.CONFLUENT.PUB_ORDERS2 AS
  SELECT * FROM TABLEFLOW_PUB_LINKED."lkc-0x6mm62"."pub_orders2";
```

Every existing `...CONFLUENT.PUB_ORDERS2` query then works, served by a view over the auto-refreshing
federated table. **This is not truly zero-downtime.** Snowflake DDL auto-commits per statement, so
`DROP` + `CREATE VIEW` cannot be made atomic, and `CREATE OR REPLACE VIEW` will not replace a name
that is currently a table. In the window between the two statements:

- the name does not exist, so **new queries fail** with `002003 ... does not exist or not authorized`;
- **in-flight queries that already started complete fine** (a running query has pinned its version);
- `DROP` on an externally-managed Iceberg table removes only the Snowflake catalog pointer, **not the
  data in ADLS**, so there is no data loss.

The gap is sub-second if the two statements are submitted back-to-back (ideally in one multi-statement
request during a quiet window), but it is nonzero. Use this only when you need federation's
auto-discovery and must keep the old names; accept the brief swap window.

### Option B - per-table REST, keep the exact name (truly gapless, no view)

The per-table REST method lets you choose the Snowflake name, so recreate the table in place with
the same fully-qualified name:

```sql
CREATE OR REPLACE ICEBERG TABLE TABLEFLOW_PUB_DB.CONFLUENT.PUB_ORDERS2
  EXTERNAL_VOLUME    = 'TABLEFLOW_PUB_ADLS_VOLUME'
  CATALOG            = 'TABLEFLOW_PUB_REST'   -- native, auto-refresh
  CATALOG_TABLE_NAME = 'pub_orders2'
  CATALOG_NAMESPACE  = 'lkc-0x6mm62'
  AUTO_REFRESH       = true;
```

`CREATE OR REPLACE` is a single atomic statement: the name never disappears, so concurrent sessions
see either the old or the new table, never "not found." This is the **only truly zero-downtime**
cutover. Same database, schema, and table name, just swapped from object-store + `METADATA_FILE_PATH`
+ sync to REST + auto-refresh. No consumer changes, no view, no gap. Tradeoff: you give up
auto-discovery and run one `CREATE OR REPLACE` per table.

### Option C - repoint consumers to the new federated names

Only sensible if you control every query and want to adopt federation's naming. Not zero-downtime.

### Recommendation

- Want a **truly zero-downtime, no-touch cutover** for existing queries: use **per-table REST** and
  recreate each table in place with its existing name (Option B). `CREATE OR REPLACE` is atomic, no
  gap. Accept manual `CREATE` for new topics.
- Want **auto-discovery** of new topics and must keep old names: go to **federation** and bridge old
  names with **views** (Option A), accepting the brief swap window per table.

## Findings and gotchas

1. **Storage firewall / network path is the dominant blocker.** A locked-down BYOS account
   (default-Deny) rejects a cluster's Tableflow egress unless that network path is allowed. The
   private cluster works because of its egress Private Link; a public cluster egresses over the
   public internet and was denied by the private demo's firewall. Every early failure here, which
   surfaced as a misleading "insufficient permissions" error, was this. The fix for the test was a
   separate open storage account. For private clusters this is already solved by the egress
   Private Link; for any public use the storage must be reachable by the cluster.
2. **Tableflow must be enabled only after the value schema exists.** Enabling it on a schema-less
   topic FAILs ("no value schema"). The build gates Tableflow on a schema-registration poll.
3. **Added schema fields must be optional for Tableflow.** A new field with a default is accepted
   by Schema Registry but Tableflow FAILs it ("required field"); use a nullable union
   (`["null", ...]`, `default null`). (Seen earlier in the private demo's evolution test.)
4. **Brand-new container or account races RBAC propagation.** Even with correct account-scoped RBAC,
   the first enable against new storage can fail on authorization and auto-suspend; a re-enable
   after propagation clears it. Create storage and let RBAC settle before enabling Tableflow.
5. **Switching a topic's Tableflow storage is gated by a ~1 hour cleanup.** You cannot hot-swap the
   container/account on an existing Tableflow topic; use a fresh topic.
6. **A new Snowflake external volume reuses the already-consented app.** Same Snowflake account +
   Azure tenant means no repeat Azure admin-consent when adding or migrating storage.
7. **BYOS + `ACCESS_DELEGATION_MODE = EXTERNAL_VOLUME_CREDENTIALS`.** For BYOS, Snowflake reads the
   data files with the external volume's own credentials rather than credentials vended by the
   catalog. The Snowflake service principal needs read RBAC on the storage account.

## Relevance to private-networking clusters

Every Snowflake object used here (REST catalog integration, OAuth with a Tableflow key, external
volume, catalog-linked database) is independent of the Kafka cluster's networking. The only thing
blocking private clusters today is Tableflow not serving the IRC. When Confluent lifts that
restriction, this exact configuration should apply to the private cluster, with the storage network
path already handled by the existing egress Private Link. The storage-firewall finding (item 1) is
the main thing to validate on the real private cluster once the IRC is available.

## Teardown

```bash
terraform -chdir=migration-test/snowflake destroy   # REST integration, linked DB, external volume, DB
terraform -chdir=migration-test destroy             # public cluster, datagen, Tableflow, open storage account + all RBAC
```

The open storage account's RBAC (Confluent SP contributor/reader, Snowflake SP reader, VM managed
identity reader) is all Terraform-managed, so `destroy` removes it with the account.

`register_pub.py` is the Phase-1 manual-registration helper. It runs on the demo VM: copy it into
`/opt/tableflow-demo/app` and run under that venv with the migration-test cluster id, the open
storage account, and the Snowflake `TABLEFLOW_PUB_*` objects in the environment.
