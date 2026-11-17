# Tableflow storage: snapshot retention and what happens when you turn Tableflow off

This covers how long Tableflow keeps the Iceberg data and snapshots in storage, how to change
that, and, importantly, what disabling Tableflow does to the data. It applies to both
Confluent-managed storage and bring-your-own-storage (BYOS, the ADLS account this demo uses).

## Snapshot / table retention

Tableflow writes each commit as a new Iceberg snapshot (a `metadata.json` plus manifest and data
files) and retains that history in the storage account. How far back the history goes is governed
by the Tableflow topic's retention setting.

- **Default: 7 days** (`retention_ms = 604800000`). Confirmed on this demo's topics:
  `stock_trades` and `stock_orders` are both `604800000` (7 days).
- **Configurable** per Tableflow topic: it can be raised or lowered. Example from this environment:
  `stock_evotest` is set to `7776000000` (90 days). Set it via the Tableflow topic config
  (`retention.ms` / `retention_ms`) in the Console, the Tableflow API, or the
  `confluent_tableflow_topic` resource.
- **Trade-off:** a longer retention keeps more snapshots (a longer time-travel / historical-read
  window) at the cost of more storage; a shorter retention uses less storage but limits how far back
  you can read.
- Snapshots older than the retention are expired and their files removed by Tableflow's maintenance
  (expiration and compaction), so the time-travel window is bounded by this value, not unlimited.

This retention is about the **materialized Iceberg table** in storage. It is separate from the
Kafka **topic** retention, which governs how long the source records live in the topic. The two are
configured independently.

## What happens when you turn Tableflow off (disable)

Disabling Tableflow does **not** delete the table files immediately, and cleanup is **governed by
the snapshot retention**, not a fixed deadline. From the Confluent docs
([Tableflow storage: disable Tableflow](https://docs.confluent.io/cloud/current/topics/tableflow/concepts/tableflow-storage.html#disable-tableflow)):

> *"When you disable Tableflow on a topic, Tableflow stops materializing new data to the table, but
> it doesn't delete the existing table files immediately. Cleanup is asynchronous: Tableflow expires
> snapshots according to the table's snapshot retention configuration, which defaults to seven days,
> and removes the data files that no remaining snapshot needs. Because cleanup runs periodically
> rather than on a fixed deadline, expect the files to persist for at least the retention period
> after you disable Tableflow."*

So:

1. **Materialization stops** immediately; no new snapshots are written.
2. **Existing files remain.** Nothing is deleted at disable time.
3. **Async cleanup follows retention.** Snapshots are expired per the table's retention (default
   7 days), and only data files that no retained snapshot needs are removed. Files persist for **at
   least the retention period** after disabling.

**Retention therefore protects data after disable.** This is the key point, and it corrects an
earlier misreading in this project: with a 90-day retention, the Iceberg files remain for at least
90 days after you disable; with a 1-day retention, roughly a day. Confirmed empirically on this
demo: after disabling `stock_evotest` (retention set to 1 day), the data files were still present,
no immediate deletion.

Note the separate "cleanup in progress" state seen when you **disable and then try to re-enable or
switch storage**: Confluent reports a short window ("1 hour grace period before deletion begins",
"this table is being cleaned up and cannot be re-enabled") and blocks re-enable until it settles.
That is about the re-enable conflict; it does not mean the files are gone, their removal still
follows retention.

### Consequences to plan for

- **Set retention deliberately before disabling.** It is the lever that decides how long the files
  survive. Want to keep them: raise retention first. Want them gone sooner: lower retention first.
- **Re-enabling during the cleanup window conflicts** (`409` "being cleaned up"); switching a topic's
  storage (container/account) requires disable, wait, then re-enable, you cannot hot-swap it.
- **Re-enabling later produces a fresh table** (new table path / UUID); it does not resume the old
  one.
- **Downstream consumers** (Snowflake external volume / object-store or REST catalog table, Trino,
  Spark) keep reading until the files are actually expired, then break. The sync job also drops the
  Snowflake table once the topic is genuinely gone from the Tableflow API.

### Alternatives to disabling

- To stop queries without affecting the data, leave Tableflow enabled and retire the **downstream**
  object (drop the Snowflake table / view, or point consumers elsewhere).
- To shrink footprint while still materializing, lower `retention.ms` instead of disabling; old
  snapshots age out but the live table keeps updating.
