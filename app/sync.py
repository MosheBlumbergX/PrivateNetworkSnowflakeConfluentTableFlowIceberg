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
from urllib.parse import urlparse

import requests
from azure.identity import ManagedIdentityCredential
from azure.storage.blob import ContainerClient

from common import env

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


def latest_metadata_file(container_client, prefix):
    newest = None
    for blob in container_client.list_blobs(name_starts_with=prefix + "metadata/"):
        if blob.name.endswith(".metadata.json"):
            key = (blob.last_modified, blob.name)
            if newest is None or key > newest[0]:
                newest = (key, blob.name)
    return newest[1] if newest else None


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


def sync_snowflake(desired):
    """desired: {TABLE_NAME: (topic, metadata_path_relative_to_container)}"""
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
            if name not in existing:
                cur.execute(
                    f"CREATE ICEBERG TABLE {fqn} EXTERNAL_VOLUME = '{volume}' CATALOG = '{catalog}' "
                    f"METADATA_FILE_PATH = '{metadata_path}' COMMENT = '{MANAGED_COMMENT} topic={topic}'"
                )
                print(f"created {fqn} -> {metadata_path}")
                added += 1
                continue
            cur.execute("SELECT SYSTEM$GET_ICEBERG_TABLE_INFORMATION(%s)", (fqn,))
            current = json.loads(cur.fetchone()[0]).get("metadataLocation", "")
            if not current.endswith(metadata_path):
                cur.execute(f"ALTER ICEBERG TABLE {fqn} REFRESH '{metadata_path}'")
                print(f"refreshed {fqn} -> {metadata_path}")
                updated += 1

        for name, row in existing.items():
            if name not in desired and (row.get("comment") or "").startswith(MANAGED_COMMENT):
                cur.execute(f"DROP ICEBERG TABLE {db}.{schema}.{name}")
                print(f"dropped {db}.{schema}.{name} (Tableflow no longer enabled)")
                removed += 1

        print(f"snowflake: {added} added, {updated} refreshed, {removed} removed, {len(desired) - added - updated} unchanged")
    finally:
        cur.close()
        conn.close()


def main():
    container = env("AZURE_STORAGE_CONTAINER")
    container_client = ContainerClient(
        account_url=f"https://{env('AZURE_STORAGE_ACCOUNT')}.blob.core.windows.net",
        container_name=container,
        credential=ManagedIdentityCredential(),
    )

    desired = {}
    for topic, table_path in tableflow_topics().items():
        metadata = latest_metadata_file(container_client, blob_prefix(table_path, container))
        if metadata is None:
            print(f"skip {topic}: no Iceberg snapshot written yet under {table_path}")
            continue
        print(f"{topic}: latest metadata {metadata}")
        desired[table_name(topic)] = (topic, metadata)

    if not os.environ.get("SNOWFLAKE_ACCOUNT"):
        print("discovery-only mode: Snowflake not configured yet")
        return
    sync_snowflake(desired)


if __name__ == "__main__":
    main()
