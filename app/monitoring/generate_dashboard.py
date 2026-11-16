"""Generates the Grafana dashboard JSON. Run from the repo root:

    python3 app/monitoring/generate_dashboard.py

Note on the Confluent Metrics API /export endpoint: metrics typed COUNTER are
*not* cumulative. Each scrape returns the value for the most recent complete
minute, so `received_bytes` sits flat at the per-minute byte count rather than
climbing. rate() and increase() are therefore wrong against them and return no
data, because Prometheus also rejects the repeated timestamps. Counters are
used raw here and read as "per minute"; only true gauges are plotted directly.
"""
import json

DS = {"type": "prometheus", "uid": "tableflow-prometheus"}


def target(expr, legend, ref="A"):
    return {"datasource": DS, "editorMode": "code", "expr": expr,
            "legendFormat": legend, "range": True, "refId": ref}


def ts(title, x, y, w, h, targets, unit="short", desc="", fill=8, minval=None):
    return {
        "type": "timeseries", "title": title, "description": desc, "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "targets": targets,
        "fieldConfig": {"defaults": {
            "unit": unit,
            **({"min": minval} if minval is not None else {}),
            "custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": fill,
                       "showPoints": "never", "spanNulls": True,
                       "scaleDistribution": {"type": "linear"}},
            "color": {"mode": "palette-classic"},
        }, "overrides": []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
    }


def stat(title, x, y, w, h, targets, unit="short", desc="", mappings=None, steps=None, text_size=None):
    return {
        "type": "stat", "title": title, "description": desc, "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "targets": targets,
        "fieldConfig": {"defaults": {
            "unit": unit,
            "mappings": mappings or [],
            "thresholds": {"mode": "absolute", "steps": steps or [{"color": "text", "value": None}]},
            "color": {"mode": "thresholds"},
        }, "overrides": []},
        "options": {"colorMode": "value", "graphMode": "area", "justifyMode": "auto",
                    "orientation": "auto", "textMode": "auto",
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    **({"text": {"valueSize": text_size}} if text_size else {})},
    }


def row(title, y):
    return {"type": "row", "title": title, "collapsed": False,
            "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []}


BOOL_MAP = [{"type": "value", "options": {"0": {"text": "No", "color": "red", "index": 1},
                                          "1": {"text": "Yes", "color": "green", "index": 0}}}]

panels = []

# ---------------------------------------------------------------- Kafka -> Tableflow
panels.append(row("Kafka to Tableflow  (Confluent Cloud Metrics API)", 0))

panels.append(ts(
    "Records per minute: read from Kafka vs committed to Iceberg", 0, 1, 12, 8,
    [target("sum by (topic) (confluent_tableflow_rows_read)", "{{topic}} read", "A"),
     target("sum by (topic) (confluent_tableflow_rows_added)", "{{topic}} committed", "B")],
    unit="short", minval=0,
    desc="'read' is what Tableflow consumed from the topic, 'committed' is what landed in "
         "an Iceberg snapshot in ADLS. Tableflow commits every few minutes, so 'committed' "
         "arrives in bursts while 'read' stays flat. These are per-minute values straight "
         "from the Metrics API, not a rate() over a cumulative counter."))

panels.append(ts(
    "Materialization latency", 12, 1, 12, 8,
    [target("confluent_tableflow_event_freshness_latency_milliseconds", "{{topic}} event", "A"),
     target("confluent_tableflow_processing_freshness_latency_milliseconds", "{{topic}} processing", "B")],
    unit="ms", minval=0,
    desc="Event freshness is the age of the most recently materialized record; processing "
         "freshness is how long Tableflow took to handle it. Sawtooths up between commits "
         "and drops on each one. Both are Preview metrics in the Confluent Metrics API.\n\n"
         "io.confluent.tableflow/kafka_topic_offset and table_offset would give the same "
         "picture in records rather than time, but neither is published on this cluster."))

panels.append(ts(
    "Bytes per minute: read from Kafka vs written to Iceberg", 0, 9, 8, 8,
    [target("sum by (topic) (confluent_tableflow_read_bytes)", "{{topic}} read", "A"),
     target("sum by (topic) (confluent_tableflow_added_bytes)", "{{topic}} written", "B")],
    unit="bytes", minval=0,
    desc="Written lands in bursts on each Iceberg commit; read stays roughly flat. The "
         "written total is usually lower thanks to Parquet compression."))

panels.append(ts(
    "Iceberg snapshots committed per minute", 8, 9, 8, 8,
    [target("sum by (topic) (confluent_tableflow_snapshots_generated)", "{{topic}}", "A")],
    unit="short", minval=0,
    desc="Each snapshot is a new metadata.json in ADLS, which is what sync.py then points "
         "Snowflake at. Default commit interval is about 3 minutes, so this reads 0 for a "
         "couple of minutes and then 1."))

panels.append(stat(
    "Rows skipped", 16, 9, 4, 4,
    [target("sum(confluent_tableflow_rows_skipped) or vector(0)", "skipped", "A")],
    steps=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
    desc="Records Tableflow could not process, usually a schema problem. Should stay at zero."))

panels.append(stat(
    "Tableflow syncing", 20, 9, 4, 4,
    [target("min(confluent_tableflow_sync_active)", "active", "A")],
    mappings=[{"type": "value", "options": {
        "0": {"text": "Stopped", "color": "red", "index": 1},
        "1": {"text": "Active", "color": "green", "index": 0}}}],
    desc="1 while Tableflow is actively syncing every topic to its destination format."))

panels.append(stat(
    "Written to Iceberg / min", 16, 13, 4, 4,
    [target("sum(confluent_tableflow_added_bytes) or vector(0)", "written", "A")], unit="bytes",
    desc="io.confluent.tableflow/storage_bytes is not used here: it measures Confluent-owned "
         "buckets, and this demo writes to the customer's own ADLS account."))

panels.append(stat(
    "Tableflow topics", 20, 13, 4, 4,
    [target("max(confluent_tableflow_num_topics)", "topics", "A")]))

# ---------------------------------------------------------------- ADLS -> Snowflake
panels.append(row("ADLS to Snowflake  (sync.py, the hop no vendor metric covers)", 17))

panels.append(ts(
    "Rows in the Iceberg table: ADLS vs what Snowflake can see", 0, 18, 12, 8,
    [target("tableflow_sync_adls_total_records", "{{topic}} in ADLS", "A"),
     target("tableflow_sync_snowflake_total_records", "{{topic}} in Snowflake", "B")],
    unit="short", minval=0, fill=4,
    desc="Both read from the Iceberg snapshot summary, so neither costs Snowflake warehouse "
         "time. The gap is the cost of having no Iceberg REST catalog to federate to on a "
         "private-networking cluster."))

panels.append(ts(
    "Rows committed to ADLS but not yet visible in Snowflake", 12, 18, 12, 8,
    [target("tableflow_sync_adls_total_records - tableflow_sync_snowflake_total_records",
            "{{topic}}", "A")],
    unit="short", minval=0,
    desc="Measured at the start of each sync run, before it refreshes Snowflake. Returns to "
         "zero once sync.py issues ALTER ICEBERG TABLE ... REFRESH."))

panels.append(ts(
    "Age of the newest Iceberg snapshot in ADLS", 0, 26, 8, 8,
    [target("time() - tableflow_sync_adls_snapshot_timestamp_seconds", "{{topic}}", "A")],
    unit="s", minval=0,
    desc="Time since Tableflow last wrote a metadata.json. Should stay around the commit "
         "interval; a steady climb means Tableflow stopped writing."))

panels.append(stat(
    "Snowflake on newest snapshot", 8, 26, 5, 4,
    [target("min(tableflow_sync_snowflake_current)", "current", "A")],
    mappings=BOOL_MAP,
    desc="Whether every table was already pointing at the newest ADLS metadata file when the "
         "last sync run started."))

panels.append(stat(
    "Last sync run", 13, 26, 5, 4,
    [target("time() - tableflow_sync_last_run_timestamp_seconds", "age", "A")], unit="s",
    steps=[{"color": "green", "value": None}, {"color": "orange", "value": 120},
           {"color": "red", "value": 300}],
    desc="The systemd timer runs sync.py every 60s. Anything above two minutes means the "
         "job is failing or stopped."))

panels.append(stat(
    "Last sync result", 8, 30, 5, 4,
    [target("tableflow_sync_success", "ok", "A")],
    mappings=[{"type": "value", "options": {
        "0": {"text": "Failed", "color": "red", "index": 1},
        "1": {"text": "OK", "color": "green", "index": 0}}}]))

panels.append(stat(
    "Sync run duration", 13, 30, 5, 4,
    [target("tableflow_sync_duration_seconds", "duration", "A")], unit="s"))

panels.append(ts(
    "Tables created, refreshed and dropped per run", 18, 26, 6, 8,
    [target("tableflow_sync_actions", "{{action}}", "A")], unit="short", minval=0,
    desc="Spikes when a topic is added live and sync.py registers it in Snowflake."))

# ---------------------------------------------------------------- Kafka cluster
panels.append(row("Kafka cluster", 34))

panels.append(ts(
    "Topic ingress", 0, 35, 12, 7,
    [target("sum by (topic) (confluent_kafka_server_received_bytes) / 60", "{{topic}}", "A")],
    unit="Bps", minval=0,
    desc="The Metrics API reports bytes for the last complete minute, so this is that "
         "value divided by 60."))

panels.append(ts(
    "Retained bytes", 12, 35, 12, 7,
    [target("sum by (topic) (confluent_kafka_server_retained_bytes)", "{{topic}}", "A")],
    unit="bytes", minval=0))

dashboard = {
    "uid": "tableflow-pipeline",
    "title": "Tableflow pipeline: Kafka to Iceberg to Snowflake (private networking)",
    "description": "Confluent Cloud Metrics API for the Kafka and Tableflow legs, plus sync.py's "
                   "own metrics for the ADLS to Snowflake leg that no vendor metric covers.",
    "tags": ["tableflow", "confluent", "snowflake", "iceberg"],
    "timezone": "browser",
    "schemaVersion": 39,
    "version": 1,
    "refresh": "1m",
    "time": {"from": "now-1h", "to": "now"},
    "editable": True,
    "graphTooltip": 1,
    "panels": panels,
}

path = "app/monitoring/grafana/dashboards/tableflow-pipeline.json"
with open(path, "w") as f:
    json.dump(dashboard, f, indent=2)
    f.write("\n")
print(f"wrote {path}: {len(panels)} panels")
