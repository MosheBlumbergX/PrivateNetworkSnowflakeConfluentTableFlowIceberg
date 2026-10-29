"""Produce Avro stock trades to every topic in topics.txt over Private Link.

The topic list is re-read periodically so topics added during a demo
(add_topic.py) start receiving data without a restart.
"""
import time

from confluent_kafka import SerializingProducer
from confluent_kafka.schema_registry import SchemaRegistryClient
from confluent_kafka.schema_registry.avro import AvroSerializer
from confluent_kafka.serialization import StringSerializer

from common import STOCK_TRADE_SCHEMA, env, kafka_config, random_trade, read_topics, schema_registry_config

RELOAD_SECONDS = 30


def main():
    sr = SchemaRegistryClient(schema_registry_config())
    producer = SerializingProducer({
        **kafka_config(),
        "key.serializer": StringSerializer("utf_8"),
        "value.serializer": AvroSerializer(sr, STOCK_TRADE_SCHEMA, conf={"auto.register.schemas": False, "use.latest.version": True}),
        "linger.ms": 100,
    })
    rate = int(env("MESSAGES_PER_SECOND", "50"))
    topics, loaded_at, sent = [], 0.0, 0

    while True:
        if time.time() - loaded_at > RELOAD_SECONDS:
            new_topics = read_topics()
            if new_topics != topics:
                print(f"producing to {new_topics}", flush=True)
            topics, loaded_at = new_topics, time.time()

        started = time.time()
        for topic in topics:
            for _ in range(rate):
                trade = random_trade()
                producer.produce(topic, key=trade["symbol"], value=trade)
        producer.poll(0)
        sent += rate * len(topics)
        if sent % (rate * max(len(topics), 1) * 60) == 0:
            producer.flush()
            print(f"sent {sent} records", flush=True)
        time.sleep(max(0.0, 1.0 - (time.time() - started)))


if __name__ == "__main__":
    main()
