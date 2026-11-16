"""Probe Confluent's Iceberg REST Catalog (IRC) for this cluster and show that a
private-networking cluster is served an empty catalog.

The IRC is a public, internet-reachable service: tableflow.<region>.<cloud>.confluent.cloud
resolves to a public IP and answers over TLS. What private networking changes is not
reachability but *contents*: the catalog returns config and the namespace, then lists
zero tables and 404s on a table that Tableflow is actively materializing. That is the
documented limitation made concrete, and the reason this demo reads Iceberg metadata
straight from ADLS instead of federating Snowflake to the catalog.

Auth note: the IRC OAuth only accepts a resource-scoped *Tableflow* API key
(TABLEFLOW_API_KEY here), not a cloud-scoped key. A cloud key returns invalid_grant.

Run on the VM:  sudo -u demo /opt/tableflow-demo/run check_rest_catalog.py
"""
import json
import sys

import requests

from common import env, read_topics


# By default this probes our own cluster with the Tableflow key already on the VM.
# To point it at another environment (for example a public-networking cluster, to see
# the catalog actually serve tables), set the CATALOG_* overrides below:
#   CATALOG_HOST=tableflow.us-east4.gcp.confluent.cloud \
#   CATALOG_ENV=env-xxxx CATALOG_CLUSTER=lkc-xxxx \
#   CATALOG_KEY=<tableflow-key> CATALOG_SECRET=<secret> \
#   sudo -u demo /opt/tableflow-demo/run check_rest_catalog.py
def settings():
    return {
        "host": env("CATALOG_HOST", env("TABLEFLOW_CATALOG_HOST")),
        "org": env("CONFLUENT_ORG_ID"),
        "environment": env("CATALOG_ENV", env("CONFLUENT_ENVIRONMENT_ID")),
        "cluster": env("CATALOG_CLUSTER", env("CONFLUENT_CLUSTER_ID")),
        "key": env("CATALOG_KEY", env("TABLEFLOW_API_KEY")),
        "secret": env("CATALOG_SECRET", env("TABLEFLOW_API_SECRET")),
    }


def token(base, key, secret):
    resp = requests.post(
        f"{base}/v1/oauth/tokens",
        auth=(key, secret),
        data={"grant_type": "client_credentials", "scope": "catalog"},
        timeout=30,
    )
    if resp.status_code != 200:
        sys.exit(f"token exchange failed [{resp.status_code}]: {resp.text}")
    return resp.json()["access_token"]


def main():
    cfg = settings()
    base = f"https://{cfg['host']}/iceberg/catalog/organizations/{cfg['org']}/environments/{cfg['environment']}"
    cluster = cfg["cluster"]
    print(f"IRC endpoint: {base}")
    print(f"cluster (warehouse / namespace): {cluster}\n")

    hdr = {"Authorization": f"Bearer {token(base, cfg['key'], cfg['secret'])}"}

    def get(path):
        r = requests.get(f"{base}{path}", headers=hdr, timeout=30)
        return r.status_code, r

    code, r = get(f"/v1/config?warehouse={cluster}")
    print(f"GET /v1/config                         -> {code}")

    code, r = get("/v1/namespaces")
    namespaces = r.json().get("namespaces", []) if code == 200 else []
    print(f"GET /v1/namespaces                     -> {code}  {r.text.strip()[:80]}")

    code, r = get(f"/v1/namespaces/{cluster}/tables")
    identifiers = r.json().get("identifiers", []) if code == 200 else []
    print(f"GET /v1/namespaces/{cluster}/tables -> {code}  {r.text.strip()[:80]}")

    # Which topics to try loading. CATALOG_TOPICS overrides (comma-separated), for
    # pointing at another cluster; otherwise use the live topic list, falling back
    # to whatever the catalog itself listed.
    override = env("CATALOG_TOPICS", "")
    if override:
        topics = [t.strip() for t in override.split(",") if t.strip()]
    else:
        try:
            topics = read_topics()
        except OSError:
            topics = [i["name"] for i in identifiers]
    loaded, missing = [], []
    for name in topics:
        code, r = get(f"/v1/namespaces/{cluster}/tables/{name}")
        if code == 200:
            loc = r.json().get("metadata-location")
            loaded.append((name, loc))
            print(f"LOAD table {name:<16} -> 200  metadata-location={loc}")
        else:
            missing.append(name)
            print(f"LOAD table {name:<16} -> {code}  {r.json().get('error', {}).get('type', r.text.strip()[:60])}")

    print("\n" + "=" * 70)
    if loaded and not missing:
        print("Catalog is SERVING tables. This cluster exposes Tableflow tables over the")
        print("public IRC, so an engine like Snowflake or Spark could federate to it directly.")
    elif not identifiers and missing:
        print("Catalog responds (config + namespace) but lists ZERO tables and 404s on")
        print("topics that Tableflow is materializing. This is the private-networking block:")
        print("the built-in Iceberg REST Catalog is not served for this cluster, which is why")
        print("this demo reads Iceberg metadata straight from ADLS instead of federating.")
    else:
        print(f"Mixed result: served {len(loaded)}, missing {len(missing)}.")


if __name__ == "__main__":
    main()
