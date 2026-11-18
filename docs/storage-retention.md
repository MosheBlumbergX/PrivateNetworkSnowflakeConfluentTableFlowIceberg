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
- **Configurable** per Tableflow topic: it can be raised or lowered (for example `7776000000`,
  90 days). Set it via the `retention_ms` field on the Tableflow topic (the top-level `retention_ms`
  argument on the `confluent_tableflow_topic` resource, which maps to `spec.config.retention_ms` in
  the Tableflow API), in the Console, or by PATCHing the API. An in-place change is honored:
  PATCHing `retention_ms` on an enabled topic and reading it back confirms the new value took.
- **Trade-off:** a longer retention keeps more snapshots (a longer time-travel / historical-read
  window) at the cost of more storage; a shorter retention uses less storage but limits how far back
  you can read.

Crucially, `retention_ms` governs snapshot expiration **while Tableflow is enabled**: snapshots
older than the window are expired by Tableflow's maintenance (expiration and compaction) and their
unreferenced data files removed, so the time-travel window is bounded by this value. It does **not**
govern what happens to the files once Tableflow is disabled (see below).

This retention is about the **materialized Iceberg table** in storage. It is separate from the
Kafka **topic** retention, which governs how long the source records live in the topic. The two are
configured independently.

## What happens when you turn Tableflow off (disable)

There is only one way to turn Tableflow off: **disable** it, which removes the Tableflow topic
(HTTP `DELETE` on the tableflow-topic, equivalently destroying the `confluent_tableflow_topic`
resource). This stops materialization and leaves the underlying **Kafka topic and its records
intact**, only the Iceberg materialization is turned off. There is no supported pause: setting
`spec.suspended=true` is rejected with `400 "suspended flag can't be set to true. Pausing the
Tableflow on-demand is not currently supported"`.

**Disabling Tableflow removes the Iceberg files, and it does not honor `retention_ms`.** This
corrects an earlier version of this doc. In testing on this demo (private-networking Standard
cluster, BYOS to ADLS), with `retention_ms` set and verified at 1 day, the Iceberg table directory
went from a full set of data and metadata blobs to **zero within about one hour** of disabling, far
short of the 1-day retention. Reproduced twice, the second time with the retention value confirmed
by read-back immediately before disabling.

So, on disable:

1. **Materialization stops.**
2. **The Iceberg files are torn down within about 1 hour.**
3. **`retention_ms` does not extend how long the files survive** after disable.

> Note: the Confluent docs for
> [Disable Tableflow](https://docs.confluent.io/cloud/current/topics/tableflow/concepts/tableflow-storage.html#disable-tableflow)
> currently state that cleanup after disabling is governed by snapshot retention and that files
> "persist for at least the retention period." Our testing contradicts that on BYOS + private
> networking. This has been raised with Confluent engineering to confirm the intended behavior and
> whether Confluent-managed storage differs. Treat the ~1 hour teardown as the observed behavior
> until that is resolved.

### If you need to keep the Iceberg data

- **Do not rely on retention to protect data across a disable.** It does not.
- **Keep Tableflow enabled** and stop queries at the downstream instead (drop the Snowflake
  table/view, or repoint consumers); the files remain as long as Tableflow runs.
- **Copy the files out first** (for example `azcopy` the table directory to another
  container/account) before disabling if you need an archival copy.

### Other consequences to plan for

- **Re-enabling later produces a fresh table** (new table path / UUID); it does not resume the old
  one, and re-enabling during the teardown window can conflict (`409` "being cleaned up").
- **Switching a topic's storage** (container/account) requires disable, wait, then re-enable; you
  cannot hot-swap it, and the old files are torn down in the process.
- **Downstream consumers** (Snowflake external volume / object-store or REST catalog table, Trino,
  Spark) break once the files are gone. The sync job drops the Snowflake table once the topic is
  genuinely absent from the Tableflow API.

### Shrinking footprint without disabling

To reduce storage while still materializing, lower `retention_ms` instead of disabling; old
snapshots age out per the new window but the live table keeps updating. This is the only
retention-governed cleanup, and it only applies while Tableflow is enabled.
