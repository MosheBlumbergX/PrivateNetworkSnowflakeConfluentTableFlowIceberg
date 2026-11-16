"""Create a bare Kafka topic (no schema) from inside the VNet.

Confluent Cloud fully-managed source connectors do NOT auto-create their target
topic (unlike self-managed Connect on Confluent Platform), so a topic fed by a
connector must exist first. No schema is registered here on purpose: the
connector brings its own (for example the Datagen ORDERS quickstart), and
pre-registering a different schema on <topic>-value would collide with it.

Idempotent. Runs with the producer key, so the name must match TOPIC_PREFIX.
"""
import sys

from confluent_kafka.admin import AdminClient, NewTopic

from common import env, kafka_config


def ensure_bare_topic(name):
    admin = AdminClient(kafka_config())
    existing = set(admin.list_topics(timeout=30).topics)
    prefix = env("TOPIC_PREFIX")
    if not name.startswith(prefix):
        raise SystemExit(f"topic {name} must start with {prefix} (producer RBAC is prefix-scoped)")
    if name in existing:
        print(f"topic {name} already exists")
        return
    admin.create_topics([NewTopic(name, num_partitions=6)])[name].result()
    print(f"created bare topic {name}")


if __name__ == "__main__":
    for topic in sys.argv[1:]:
        ensure_bare_topic(topic)
