"""Show the Iceberg storage layout in ADLS, from inside the VNet.

The storage account firewall is default-Deny, so the Azure Portal's blob browser
(which reads over the public endpoint from your laptop) returns 403. The data is
only reachable from inside the network: this runs on the demo VM over the blob
private endpoint, authenticating with the VM's managed identity.

Run on the VM:  sudo -u demo /opt/tableflow-demo/run show_storage.py
"""
from azure.identity import ManagedIdentityCredential
from azure.storage.blob import ContainerClient

from common import env
from sync import blob_prefix, tableflow_topics


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def summarize(container_client, prefix):
    """Group blobs under a table path into metadata/ and data/ with counts and bytes."""
    groups = {}
    for b in container_client.list_blobs(name_starts_with=prefix):
        rel = b.name[len(prefix):]
        top = rel.split("/", 1)[0] if "/" in rel else "(root)"
        g = groups.setdefault(top, {"count": 0, "bytes": 0, "newest": None})
        g["count"] += 1
        g["bytes"] += b.size or 0
        if g["newest"] is None or b.name > g["newest"]:
            g["newest"] = b.name
    return groups


def main():
    container = env("AZURE_STORAGE_CONTAINER")
    account = env("AZURE_STORAGE_ACCOUNT")
    client = ContainerClient(
        account_url=f"https://{account}.blob.core.windows.net",
        container_name=container,
        credential=ManagedIdentityCredential(),
    )

    print(f"ADLS: {account}/{container}  (read over the blob private endpoint, managed identity)\n")

    topics = tableflow_topics()
    if not topics:
        print("No RUNNING Iceberg Tableflow topics yet.")
        return

    for topic, table_path in sorted(topics.items()):
        prefix = blob_prefix(table_path, container)
        print(f"- {topic}")
        print(f"    {prefix}")
        groups = summarize(client, prefix)
        for name in sorted(groups):
            g = groups[name]
            line = f"      {name + '/':12} {g['count']:>4} files   {human(g['bytes']):>10}"
            print(line)
        newest_meta = groups.get("metadata", {}).get("newest")
        if newest_meta:
            print(f"      newest metadata: {newest_meta.rsplit('/', 1)[-1]}")
        print()

    print("The Azure Portal shows 403 for this container: its firewall is default-Deny and")
    print("only the Snowflake VNet subnets and the private endpoints are allowed. This view")
    print("works only because it runs inside the VNet.")


if __name__ == "__main__":
    main()
