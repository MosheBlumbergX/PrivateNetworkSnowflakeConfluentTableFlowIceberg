# Phase 2 - migrate to the NATIVE Tableflow Iceberg REST Catalog.
#
# Step A: a per-table REST catalog integration. Snowflake federates to Tableflow's
# public IRC (OAuth with the Tableflow key), and reads the data files through the
# SAME external volume used by the manual object-store table in Phase 1, so nothing
# re-materializes. Compare PUB_ORDERS2 (manual) vs PUB_ORDERS2_REST (native).

resource "snowflake_catalog_integration_iceberg_rest" "pub_rest" {
  count = var.enable_phase2 ? 1 : 0

  name              = "${var.name_prefix}_REST"
  enabled           = true
  catalog_namespace = local.pub.public_cluster_id # Tableflow IRC namespace = cluster id

  rest_config {
    catalog_uri      = "https://tableflow.${var.region}.azure.confluent.cloud/iceberg/catalog/organizations/${var.org_id}/environments/${local.infra.confluent_environment_id}"
    catalog_api_type = "PUBLIC"
    # BYOS: Snowflake reads data files via the external volume's own credentials,
    # not credentials vended by the catalog.
    access_delegation_mode = "EXTERNAL_VOLUME_CREDENTIALS"
  }

  oauth_rest_authentication {
    oauth_client_id      = local.pub.tableflow_api_key
    oauth_client_secret  = local.pub.tableflow_api_secret
    oauth_allowed_scopes = ["catalog"]
  }
}

resource "snowflake_iceberg_table_from_rest" "pub_rest_table" {
  count = var.enable_phase2 ? 1 : 0

  database           = snowflake_database.tableflow.name
  schema             = snowflake_schema.confluent.name
  name               = "PUB_ORDERS2_REST"
  external_volume    = snowflake_external_volume.adls.name
  catalog            = snowflake_catalog_integration_iceberg_rest.pub_rest[0].name
  catalog_table_name = local.pub.topic
  catalog_namespace  = local.pub.public_cluster_id
  auto_refresh       = "true"
  comment            = "Native REST-catalog table (migration target)"
}

output "rest_table" {
  value = var.enable_phase2 ? "${local.database}.${local.schema}.PUB_ORDERS2_REST" : null
}

# Step B - Horizon catalog federation: a catalog-linked database that auto-discovers
# every Tableflow topic in the cluster's namespace, no per-table DDL. No typed
# resource exists for this, so use snowflake_execute. Tables appear under a schema
# named after the namespace (the cluster id).
resource "snowflake_execute" "linked_catalog" {
  count = var.enable_phase2 ? 1 : 0

  execute = "CREATE DATABASE IF NOT EXISTS ${var.name_prefix}_LINKED LINKED_CATALOG = (CATALOG = '${snowflake_catalog_integration_iceberg_rest.pub_rest[0].name}', ALLOWED_NAMESPACES = ('${local.pub.public_cluster_id}'), SYNC_INTERVAL_SECONDS = 30) EXTERNAL_VOLUME = '${snowflake_external_volume.adls.name}'"
  revert  = "DROP DATABASE IF EXISTS ${var.name_prefix}_LINKED"
  query   = "SHOW DATABASES LIKE '${var.name_prefix}_LINKED'"

  depends_on = [snowflake_iceberg_table_from_rest.pub_rest_table]
}

output "linked_database" {
  value = var.enable_phase2 ? "${var.name_prefix}_LINKED" : null
}
