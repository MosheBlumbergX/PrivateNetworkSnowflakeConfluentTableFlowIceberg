"""Compare record counts at each stage: Kafka topic -> Iceberg in ADLS -> Snowflake.

There is no single "count" for a Kafka topic, so this sums (high - low) watermark
offsets across partitions, which is the number of records currently retained.
The Iceberg count comes from the snapshot summary in the newest metadata file,
and the Snowflake count from whichever snapshot Snowflake is pointing at, so
neither costs any Snowflake warehouse time.

Run on the VM:  sudo -u demo /opt/tableflow-demo/run counts.py
"""
import os

from confluent_kafka import Consumer, TopicPartition
from confluent_kafka.admin import AdminClient

from common import env, kafka_config, read_topics


def topic_counts():
    """{topic: records retained} summed over partitions."""
    admin = AdminClient(kafka_config())
    consumer = Consumer({**kafka_config(), "group.id": "count-probe", "enable.auto.commit": False})
    metadata = admin.list_topics(timeout=30)

    counts = {}
    try:
        for topic in read_topics():
            meta = metadata.topics.get(topic)
            if meta is None or meta.error is not None:
                continue
            total = 0
            for partition in meta.partitions:
                low, high = consumer.get_watermark_offsets(
                    TopicPartition(topic, partition), timeout=15, cached=False
                )
                total += high - low
            counts[topic] = total
    finally:
        consumer.close()
    return counts


def iceberg_counts():
    """{topic: (rows in newest ADLS snapshot, rows in the snapshot Snowflake uses)}"""
    from azure.identity import ManagedIdentityCredential
    from azure.storage.blob import ContainerClient

    from sync import (blob_prefix, metadata_files, newest_metadata, snapshot_records,
                      table_name, tableflow_topics)

    container = env("AZURE_STORAGE_CONTAINER")
    client = ContainerClient(
        account_url=f"https://{env('AZURE_STORAGE_ACCOUNT')}.blob.core.windows.net",
        container_name=container,
        credential=ManagedIdentityCredential(),
    )

    cache, result = {}, {}
    for topic, table_path in tableflow_topics()[0].items():
        files = metadata_files(client, blob_prefix(table_path, container))
        newest = newest_metadata(files)
        if newest is None:
            result[topic] = (None, None)
            continue
        adls = snapshot_records(client, newest, cache)

        visible = None
        if os.environ.get("SNOWFLAKE_ACCOUNT"):
            import json

            from sync import snowflake_connection

            fqn = f"{env('SNOWFLAKE_DATABASE')}.{env('SNOWFLAKE_SCHEMA')}.{table_name(topic)}"
            conn = snowflake_connection()
            cur = conn.cursor()
            try:
                cur.execute("SELECT SYSTEM$GET_ICEBERG_TABLE_INFORMATION(%s)", (fqn,))
                current = json.loads(cur.fetchone()[0]).get("metadataLocation", "")
                served = next((b for b in files if current.endswith(b)), None)
                if served:
                    visible = snapshot_records(client, served, cache)
            except Exception as exc:
                print(f"  ({topic}: not registered in Snowflake yet: {exc})")
            finally:
                cur.close()
                conn.close()
        result[topic] = (adls, visible)
    return result


def main():
    kafka = topic_counts()
    iceberg = iceberg_counts()

    print(f"{'topic':<20}{'in Kafka':>14}{'in Iceberg':>14}{'in Snowflake':>14}{'  behind':>10}")
    print("-" * 74)
    for topic in sorted(set(kafka) | set(iceberg)):
        in_kafka = kafka.get(topic)
        adls, visible = iceberg.get(topic, (None, None))
        behind = in_kafka - visible if in_kafka is not None and visible is not None else None
        fmt = lambda v: f"{v:,}" if v is not None else "-"
        print(f"{topic:<20}{fmt(in_kafka):>14}{fmt(adls):>14}{fmt(visible):>14}{fmt(behind):>10}")

    print("\nKafka is records retained (sum of high - low watermarks across partitions).")
    print("Iceberg and Snowflake come from the Iceberg snapshot summary, not COUNT(*).")


if __name__ == "__main__":
    main()
