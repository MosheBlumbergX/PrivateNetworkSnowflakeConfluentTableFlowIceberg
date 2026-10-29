"""Shared config and schema for the demo producer, topic setup and sync job."""
import os
import random
import time

TOPICS_FILE = "/etc/tableflow-demo/topics.txt"

STOCK_TRADE_SCHEMA = """
{
  "type": "record",
  "name": "StockTrade",
  "namespace": "io.confluent.demo",
  "fields": [
    {"name": "side", "type": "string"},
    {"name": "quantity", "type": "int"},
    {"name": "symbol", "type": "string"},
    {"name": "price", "type": "double"},
    {"name": "account", "type": "string"},
    {"name": "userid", "type": "string"},
    {"name": "trade_ts", "type": {"type": "long", "logicalType": "timestamp-millis"}}
  ]
}
"""

SYMBOLS = ["ZVZZT", "ZWZZT", "ZXZZT", "ZJZZT", "ZTEST", "ZBZX", "ZVV", "ZEXIT"]


def env(name, default=None):
    value = os.environ.get(name, default)
    if value is None:
        raise SystemExit(f"missing environment variable {name}")
    return value


def read_topics():
    with open(TOPICS_FILE) as f:
        return [line.strip() for line in f if line.strip()]


def kafka_config():
    return {
        "bootstrap.servers": env("KAFKA_BOOTSTRAP"),
        "security.protocol": "SASL_SSL",
        "sasl.mechanisms": "PLAIN",
        "sasl.username": env("KAFKA_API_KEY"),
        "sasl.password": env("KAFKA_API_SECRET"),
    }


def schema_registry_config():
    return {
        "url": env("SCHEMA_REGISTRY_URL"),
        "basic.auth.user.info": f'{env("SCHEMA_REGISTRY_API_KEY")}:{env("SCHEMA_REGISTRY_API_SECRET")}',
    }


def random_trade():
    return {
        "side": random.choice(["BUY", "SELL"]),
        "quantity": random.randint(1, 5000),
        "symbol": random.choice(SYMBOLS),
        "price": round(random.uniform(5, 1000), 2),
        "account": f"ABC{random.randint(100, 999)}",
        "userid": f"User_{random.randint(1, 9)}",
        "trade_ts": int(time.time() * 1000),
    }
