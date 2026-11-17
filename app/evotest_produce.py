"""Schema-evolution test producer for a standalone topic (runs on the VM).

Produces to a throwaway topic with its own schema so you can watch an evolution
flow all the way to Snowflake, independent of the demo's shared StockTrade schema.

    evotest_produce.py <topic> <v1|v2> <count>

    v1: id, amount, ts
    v2: adds an OPTIONAL field 'region' (nullable union with default null).

The optional union matters: Tableflow rejects an added *required* field even when
it carries a default (Schema Registry accepts it, Tableflow FAILs the topic with
"Adding required fields is currently not compatible"). A nullable union is the
Tableflow-compatible way to evolve. Old rows read back NULL for the new column.

Full run (topic name must start with the producer's RBAC prefix, e.g. stock_):

    sudo -u demo /opt/tableflow-demo/run evotest_produce.py stock_evotest v1 5000
    # enable Tableflow (Iceberg) on the topic in the Console or via the API
    # wait for it in Snowflake, then:
    sudo -u demo /opt/tableflow-demo/run evotest_produce.py stock_evotest v2 5000
    # the REGION column appears; v1 rows are NULL, v2 rows carry a value
"""
import random
import sys
import time

from confluent_kafka import SerializingProducer
from confluent_kafka.admin import AdminClient, NewTopic
from confluent_kafka.schema_registry import Schema, SchemaRegistryClient
from confluent_kafka.schema_registry.avro import AvroSerializer
from confluent_kafka.serialization import StringSerializer

from common import kafka_config, schema_registry_config

V1 = """
{"type":"record","name":"EvoTest","namespace":"io.confluent.demo","fields":[
  {"name":"id","type":"string"},
  {"name":"amount","type":"double"},
  {"name":"ts","type":{"type":"long","logicalType":"timestamp-millis"}}
]}
"""

V2 = """
{"type":"record","name":"EvoTest","namespace":"io.confluent.demo","fields":[
  {"name":"id","type":"string"},
  {"name":"amount","type":"double"},
  {"name":"ts","type":{"type":"long","logicalType":"timestamp-millis"}},
  {"name":"region","type":["null","string"],"default":null}
]}
"""

REGIONS = ["emea", "amer", "apac"]


def main():
    if len(sys.argv) != 4 or sys.argv[2] not in ("v1", "v2"):
        raise SystemExit(__doc__)
    topic, version, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
    schema_str = V1 if version == "v1" else V2

    admin = AdminClient(kafka_config())
    if topic not in admin.list_topics(timeout=30).topics:
        admin.create_topics([NewTopic(topic, num_partitions=6)])[topic].result()
        print(f"created topic {topic}")

    sr = SchemaRegistryClient(schema_registry_config())
    sid = sr.register_schema(f"{topic}-value", Schema(schema_str, "AVRO"))
    print(f"registered {topic}-value {version} id={sid}")

    producer = SerializingProducer({
        **kafka_config(),
        "key.serializer": StringSerializer("utf_8"),
        "value.serializer": AvroSerializer(sr, schema_str, conf={"auto.register.schemas": False, "use.latest.version": True}),
    })

    for i in range(count):
        rec = {"id": f"evt-{random.randint(1, 1_000_000)}",
               "amount": round(random.uniform(1, 1000), 2),
               "ts": int(time.time() * 1000)}
        if version == "v2":
            rec["region"] = random.choice(REGIONS)
        producer.produce(topic, key=rec["id"], value=rec)
        if i % 1000 == 0:
            producer.poll(0)
    producer.flush()
    print(f"produced {count} {version} records to {topic}")


if __name__ == "__main__":
    main()
