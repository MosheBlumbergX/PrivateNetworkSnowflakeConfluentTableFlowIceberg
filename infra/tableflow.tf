# Tableflow on each demo topic, writing Iceberg to the private ADLS account.
# Topics are created from the VM (null_resource.deploy_app) since the cluster's
# REST endpoint is only reachable inside the VNet.
resource "confluent_tableflow_topic" "demo" {
  for_each = toset(var.topics)

  display_name  = each.key
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
    null_resource.deploy_app,
    confluent_dns_record.storage,
    azurerm_role_assignment.confluent_blob_contributor,
    azurerm_role_assignment.confluent_reader,
  ]
}
