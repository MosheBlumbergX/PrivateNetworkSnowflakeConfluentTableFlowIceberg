"""Create demo topics and register their Avro value schema (runs inside the VNet)."""
import sys

from confluent_kafka.admin import AdminClient, NewTopic
from confluent_kafka.schema_registry import Schema, SchemaRegistryClient

from common import STOCK_TRADE_SCHEMA, env, kafka_config, read_topics, schema_registry_config


def ensure_topics(topics):
    admin = AdminClient(kafka_config())
    existing = set(admin.list_topics(timeout=30).topics)
    missing = [t for t in topics if t not in existing]
    prefix = env("TOPIC_PREFIX")
    for t in missing:
        if not t.startswith(prefix):
            raise SystemExit(f"topic {t} must start with {prefix} (producer RBAC is prefix-scoped)")
    if missing:
        futures = admin.create_topics([NewTopic(t, num_partitions=6) for t in missing])
        for topic, future in futures.items():
            future.result()
            print(f"created topic {topic}")
    for t in topics:
        if t in existing:
            print(f"topic {t} already exists")

    sr = SchemaRegistryClient(schema_registry_config())
    for t in topics:
        schema_id = sr.register_schema(f"{t}-value", Schema(STOCK_TRADE_SCHEMA, "AVRO"))
        print(f"schema {t}-value id={schema_id}")


if __name__ == "__main__":
    ensure_topics(sys.argv[1:] or read_topics())
