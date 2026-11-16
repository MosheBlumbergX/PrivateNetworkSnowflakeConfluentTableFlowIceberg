"""Tableflow -> Snowflake sync for privately networked clusters.

The Tableflow Iceberg REST Catalog is not available on private-networking
clusters, so Snowflake cannot federate to it. Instead, every run:

  1. Discovers Tableflow topics via the Confluent Cloud API (control plane,
     metadata only) and keeps those in RUNNING phase.
  2. Finds the newest Iceberg *.metadata.json for each table in ADLS, over the
     storage private endpoint, using the VM's managed identity.
  3. In Snowflake (object-store catalog integration), creates the Iceberg table
     if missing, refreshes it to the newest metadata file if it moved, and drops
     tables this job created whose topic no longer has Tableflow.

Without Snowflake settings it runs in discovery-only mode and just logs what
it would register.
"""
import json
import os
import re
import time
from urllib.parse import urlparse

import requests
from azure.identity import ManagedIdentityCredential
from azure.storage.blob import ContainerClient

from common import env
from metrics import Metrics

MANAGED_COMMENT = "managed-by=tableflow-sync"


def tableflow_topics():
    resp = requests.get(
        "https://api.confluent.cloud/tableflow/v1/tableflow-topics",
        auth=(env("TABLEFLOW_API_KEY"), env("TABLEFLOW_API_SECRET")),
        params={"environment": env("CONFLUENT_ENVIRONMENT_ID"), "spec.kafka_cluster": env("CONFLUENT_CLUSTER_ID")},
        timeout=30,
    )
    resp.raise_for_status()
    topics = {}
    for t in resp.json().get("data") or []:
        name, phase = t["spec"]["display_name"], t["status"]["phase"]
        path = t["spec"].get("storage", {}).get("table_path")
        if phase != "RUNNING" or not path or "ICEBERG" not in t["spec"].get("table_formats", []):
            print(f"skip {name}: phase={phase} table_path={path}")
            continue
        topics[name] = path
    return topics


def blob_prefix(table_path, container):
    """abfss://<container>@<acct>.dfs.core.windows.net/<path> (or https://.../<container>/<path>) -> <path>/"""
    parsed = urlparse(table_path)
    path = parsed.path.lstrip("/")
    if "@" not in parsed.netloc and path.startswith(container + "/"):
        path = path[len(container) + 1:]
    return path.rstrip("/") + "/"


def metadata_files(container_client, prefix):
    """{blob name: last_modified} for every Iceberg metadata file under a table."""
    return {
        blob.name: blob.last_modified
        for blob in container_client.list_blobs(name_starts_with=prefix + "metadata/")
        if blob.name.endswith(".metadata.json")
    }


def newest_metadata(files):
    return max(files, key=lambda name: (files[name], name)) if files else None


def snapshot_records(container_client, blob_name, cache):
    """Rows in the current snapshot, read from the Iceberg metadata JSON.

    Cheaper and more robust than COUNT(*) in Snowflake: no warehouse time, and
    it still reports while the warehouse is suspended.
    """
    if blob_name in cache:
        return cache[blob_name]
    records = None
    try:
        body = json.loads(container_client.download_blob(blob_name).readall())
        current = body.get("current-snapshot-id")
        for snapshot in body.get("snapshots") or []:
            if snapshot.get("snapshot-id") == current:
                records = int(snapshot.get("summary", {}).get("total-records", 0))
                break
    except Exception as exc:  # never fail the sync over a metrics read
        print(f"warning: could not read {blob_name}: {exc}")
    cache[blob_name] = records
    return records


def table_name(topic):
    return re.sub(r"[^A-Za-z0-9_]", "_", topic).upper()


def snowflake_connection():
    import snowflake.connector
    from cryptography.hazmat.primitives import serialization

    with open(env("SNOWFLAKE_PRIVATE_KEY_PATH"), "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    return snowflake.connector.connect(
        account=env("SNOWFLAKE_ACCOUNT"),
        user=env("SNOWFLAKE_USER"),
        private_key=key.private_bytes(serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()),
        role=env("SNOWFLAKE_ROLE"),
        warehouse=env("SNOWFLAKE_WAREHOUSE"),
        database=env("SNOWFLAKE_DATABASE"),
        schema=env("SNOWFLAKE_SCHEMA"),
    )


def sync_snowflake(desired, metrics, container_client, files_by_table, record_cache):
    """desired: {TABLE_NAME: (topic, metadata_path_relative_to_container)}

    Metrics describe Snowflake's state as found at the *start* of the run, before
    this job refreshes it. That is the number worth showing: it is how far behind
    Snowflake actually runs without an Iceberg REST catalog to federate to.
    """
    db, schema = env("SNOWFLAKE_DATABASE"), env("SNOWFLAKE_SCHEMA")
    volume, catalog = env("SNOWFLAKE_EXTERNAL_VOLUME"), env("SNOWFLAKE_CATALOG_INTEGRATION")
    conn = snowflake_connection()
    cur = conn.cursor()
    try:
        cur.execute(f"SHOW ICEBERG TABLES IN SCHEMA {db}.{schema}")
        cols = [c[0] for c in cur.description]
        existing = {row["name"]: row for row in (dict(zip(cols, r)) for r in cur.fetchall())}

        added = updated = removed = 0
        for name, (topic, metadata_path) in desired.items():
            fqn = f"{db}.{schema}.{name}"
            labels = {"topic": topic, "table": name}

            if name not in existing:
                cur.execute(
                    f"CREATE ICEBERG TABLE {fqn} EXTERNAL_VOLUME = '{volume}' CATALOG = '{catalog}' "
                    f"METADATA_FILE_PATH = '{metadata_path}' COMMENT = '{MANAGED_COMMENT} topic={topic}'"
                )
                print(f"created {fqn} -> {metadata_path}")
                added += 1
                # Nothing was visible in Snowflake before this run.
                metrics.set("tableflow_sync_snowflake_current", 0, **labels)
                metrics.set("tableflow_sync_snowflake_total_records", 0, **labels)
                continue

            cur.execute("SELECT SYSTEM$GET_ICEBERG_TABLE_INFORMATION(%s)", (fqn,))
            current = json.loads(cur.fetchone()[0]).get("metadataLocation", "")
            in_sync = current.endswith(metadata_path)
            metrics.set("tableflow_sync_snowflake_current", 1 if in_sync else 0, **labels)

            # Report on whichever snapshot Snowflake was actually serving.
            files = files_by_table.get(name, {})
            served = metadata_path if in_sync else next(
                (blob for blob in files if current.endswith(blob)), None
            )
            if served:
                metrics.set("tableflow_sync_snowflake_snapshot_timestamp_seconds", files[served].timestamp(), **labels)
                records = snapshot_records(container_client, served, record_cache)
                if records is not None:
                    metrics.set("tableflow_sync_snowflake_total_records", records, **labels)

            if not in_sync:
                cur.execute(f"ALTER ICEBERG TABLE {fqn} REFRESH '{metadata_path}'")
                print(f"refreshed {fqn} -> {metadata_path}")
                updated += 1

        for name, row in existing.items():
            if name not in desired and (row.get("comment") or "").startswith(MANAGED_COMMENT):
                cur.execute(f"DROP ICEBERG TABLE {db}.{schema}.{name}")
                print(f"dropped {db}.{schema}.{name} (Tableflow no longer enabled)")
                removed += 1

        for action, count in (("created", added), ("refreshed", updated), ("dropped", removed)):
            metrics.set("tableflow_sync_actions", count, action=action)

        print(f"snowflake: {added} added, {updated} refreshed, {removed} removed, {len(desired) - added - updated} unchanged")
    finally:
        cur.close()
        conn.close()


def run(metrics):
    container = env("AZURE_STORAGE_CONTAINER")
    container_client = ContainerClient(
        account_url=f"https://{env('AZURE_STORAGE_ACCOUNT')}.blob.core.windows.net",
        container_name=container,
        credential=ManagedIdentityCredential(),
    )

    topics = tableflow_topics()
    metrics.set("tableflow_sync_topics_discovered", len(topics))

    desired, files_by_table, record_cache = {}, {}, {}
    for topic, table_path in topics.items():
        files = metadata_files(container_client, blob_prefix(table_path, container))
        metadata = newest_metadata(files)
        if metadata is None:
            print(f"skip {topic}: no Iceberg snapshot written yet under {table_path}")
            continue
        print(f"{topic}: latest metadata {metadata}")

        table = table_name(topic)
        desired[table] = (topic, metadata)
        files_by_table[table] = files

        labels = {"topic": topic, "table": table}
        metrics.set("tableflow_sync_adls_snapshot_timestamp_seconds", files[metadata].timestamp(), **labels)
        records = snapshot_records(container_client, metadata, record_cache)
        if records is not None:
            metrics.set("tableflow_sync_adls_total_records", records, **labels)

    metrics.set("tableflow_sync_tables", len(desired))

    if not os.environ.get("SNOWFLAKE_ACCOUNT"):
        print("discovery-only mode: Snowflake not configured yet")
        return
    sync_snowflake(desired, metrics, container_client, files_by_table, record_cache)


def main():
    started = time.time()
    metrics = Metrics()
    ok = 1
    try:
        run(metrics)
    except Exception:
        ok = 0
        raise
    finally:
        metrics.set("tableflow_sync_success", ok)
        metrics.set("tableflow_sync_last_run_timestamp_seconds", started)
        metrics.set("tableflow_sync_duration_seconds", time.time() - started)
        metrics.write()


if __name__ == "__main__":
    main()
