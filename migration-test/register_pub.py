"""One-off: register the public cluster's Tableflow topic in Snowflake the manual
('our solution') way. Runs on the demo VM; reads the newest Iceberg metadata from
the open ADLS account with the VM's managed identity and connects as an admin user
(password) to the migration-test DB. Expects the app modules (common, sync) on the
path, i.e. copy it into /opt/tableflow-demo/app before running.
"""
import json
import os

import snowflake.connector
from azure.identity import ManagedIdentityCredential
from azure.storage.blob import ContainerClient

from common import env
from sync import blob_prefix, metadata_files, newest_metadata, table_name, tableflow_topics

container = env("AZURE_STORAGE_CONTAINER")
cc = ContainerClient(
    account_url=f"https://{env('AZURE_STORAGE_ACCOUNT')}.blob.core.windows.net",
    container_name=container,
    credential=ManagedIdentityCredential(),
)

topics, _ = tableflow_topics()  # filtered to CONFLUENT_CLUSTER_ID (the public cluster)
if not topics:
    raise SystemExit("no RUNNING Iceberg Tableflow topics on the public cluster yet")

conn = snowflake.connector.connect(
    account=env("SNOWFLAKE_ACCOUNT"),
    user=env("SNOWFLAKE_USER"),
    password=env("SNOWFLAKE_PASSWORD"),
    role=env("SNOWFLAKE_ROLE"),
    warehouse=env("SNOWFLAKE_WAREHOUSE"),
    database=env("SNOWFLAKE_DATABASE"),
    schema=env("SNOWFLAKE_SCHEMA"),
)
db, schema = env("SNOWFLAKE_DATABASE"), env("SNOWFLAKE_SCHEMA")
vol, cat = env("SNOWFLAKE_EXTERNAL_VOLUME"), env("SNOWFLAKE_CATALOG_INTEGRATION")
cur = conn.cursor()
for topic, table_path in topics.items():
    files = metadata_files(cc, blob_prefix(table_path, container))
    meta = newest_metadata(files)
    if not meta:
        print(f"skip {topic}: no metadata yet")
        continue
    name = table_name(topic)
    fqn = f"{db}.{schema}.{name}"
    cur.execute(
        f"CREATE OR REPLACE ICEBERG TABLE {fqn} EXTERNAL_VOLUME = '{vol}' CATALOG = '{cat}' "
        f"METADATA_FILE_PATH = '{meta}' COMMENT = 'managed-by=migration-test topic={topic}'"
    )
    cur.execute(f"SELECT COUNT(*) FROM {fqn}")
    print(f"registered {fqn}  (manual/object-store)  rows={cur.fetchone()[0]:,}  metadata={meta.rsplit('/',1)[-1]}")
cur.close()
conn.close()
