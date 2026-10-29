"""Live demo helper: create a topic, start producing to it and enable Tableflow.

The sync job then registers it in Snowflake automatically.
Usage: sudo -u demo /opt/tableflow-demo/run add_topic.py stock_orders
"""
import sys

import requests

from common import TOPICS_FILE, env, read_topics
from create_topics import ensure_topics

API = "https://api.confluent.cloud/tableflow/v1/tableflow-topics"


def enable_tableflow(topic):
    auth = (env("TABLEFLOW_API_KEY"), env("TABLEFLOW_API_SECRET"))
    env_id, cluster_id = env("CONFLUENT_ENVIRONMENT_ID"), env("CONFLUENT_CLUSTER_ID")

    # Reuse the BYOS storage spec of an existing Tableflow topic (provider
    # integration, account, container) so this matches what Terraform set up.
    listing = requests.get(API, auth=auth, params={"environment": env_id, "spec.kafka_cluster": cluster_id}, timeout=30)
    listing.raise_for_status()
    existing = listing.json().get("data") or []
    if any(t["spec"]["display_name"] == topic for t in existing):
        print(f"Tableflow already enabled on {topic}")
        return
    if not existing:
        raise SystemExit("no existing Tableflow topic to copy the storage config from")
    storage = {k: v for k, v in existing[0]["spec"]["storage"].items() if k not in ("table_path", "storage_region")}

    body = {"spec": {
        "display_name": topic,
        "table_formats": ["ICEBERG"],
        "environment": {"id": env_id},
        "kafka_cluster": {"id": cluster_id},
        "storage": storage,
    }}
    resp = requests.post(API, auth=auth, json=body, timeout=30)
    if not resp.ok:
        raise SystemExit(f"enable Tableflow failed: {resp.status_code} {resp.text}")
    print(f"Tableflow enabled on {topic}: {resp.json()['status']['phase']}")


def main():
    topic = sys.argv[1]
    ensure_topics([topic])
    if topic not in read_topics():
        with open(TOPICS_FILE, "a") as f:
            f.write(topic + "\n")
        print(f"producer will pick up {topic} within 30s")
    enable_tableflow(topic)


if __name__ == "__main__":
    main()
