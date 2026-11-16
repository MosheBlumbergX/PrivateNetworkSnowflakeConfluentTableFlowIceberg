# ============================================================================
# A second data source: a fully-managed Datagen connector with its own schema
# (ORDERS quickstart, distinct from the producer's StockTrade), plus Tableflow
# on its topic. This exercises the sync job's automatic discovery: sync.py finds
# any RUNNING Iceberg Tableflow topic via the API, so "orders" lands in Snowflake
# and on the Grafana dashboard with no further changes.
#
# Datagen produces AVRO, so a value schema is registered before Tableflow is
# enabled (enabling Tableflow on a schema-less topic sends the table to cleanup).
# ============================================================================

resource "confluent_service_account" "connector" {
  display_name = "${local.name}-connector"
  description  = "Fully-managed Datagen source connector"
}

# Lets the connector create and write its topic.
resource "confluent_role_binding" "connector_cluster_admin" {
  principal   = "User:${confluent_service_account.connector.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.main.rbac_crn
}

# Lets the connector register the Avro value schema.
resource "confluent_role_binding" "connector_subject_write" {
  principal   = "User:${confluent_service_account.connector.id}"
  role_name   = "DeveloperWrite"
  crn_pattern = "${data.confluent_schema_registry_cluster.main.resource_name}/subject=*"
}

resource "confluent_connector" "datagen_orders" {
  environment {
    id = confluent_environment.main.id
  }
  kafka_cluster {
    id = confluent_kafka_cluster.main.id
  }

  config_sensitive = {}
  config_nonsensitive = {
    "connector.class"          = "DatagenSource"
    "name"                     = "${local.name}-datagen-orders"
    "kafka.auth.mode"          = "SERVICE_ACCOUNT"
    "kafka.service.account.id" = confluent_service_account.connector.id
    "kafka.topic"              = var.orders_topic
    "output.data.format"       = "AVRO"
    "quickstart"               = "ORDERS"
    "tasks.max"                = "1"
  }

  depends_on = [
    confluent_role_binding.connector_cluster_admin,
    confluent_role_binding.connector_subject_write,
    # The VM deploy pre-creates the (bare) topic; CC connectors do not auto-create it.
    null_resource.deploy_app,
  ]
}

# Enable Tableflow (Iceberg) on the connector's topic, same BYOB ADLS as the
# producer topic. Depends on the connector so data and a schema exist first.
resource "confluent_tableflow_topic" "orders" {
  display_name  = var.orders_topic
  table_formats = ["ICEBERG"]

  environment {
    id = confluent_environment.main.id
  }
  kafka_cluster {
    id = confluent_kafka_cluster.main.id
  }

  credentials {
    key    = confluent_api_key.tableflow.id
    secret = confluent_api_key.tableflow.secret
  }

  azure_data_lake_storage_gen_2 {
    provider_integration_id = confluent_provider_integration_authorization.azure.id
    container_name          = azurerm_storage_container.tableflow.name
    storage_account_name    = azurerm_storage_account.adls.name
  }

  depends_on = [
    confluent_connector.datagen_orders,
    confluent_dns_record.storage,
    azurerm_role_assignment.confluent_blob_contributor,
    azurerm_role_assignment.confluent_reader,
  ]
}

output "orders_connector_status" {
  value = confluent_connector.datagen_orders.status
}
