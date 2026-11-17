output "public_cluster_id" {
  value = confluent_kafka_cluster.pub.id
}

output "topic" {
  value = confluent_kafka_topic.trades.topic_name
}

output "container_name" {
  value = azurerm_storage_container.pub.name
}

output "storage_account_name" {
  value = azurerm_storage_account.pub.name
}

output "storage_account_id" {
  value = azurerm_storage_account.pub.id
}

output "environment_id" {
  value = local.infra.confluent_environment_id
}

# Consumed by the Phase 2 Snowflake REST catalog integration (OAuth client).
output "tableflow_api_key" {
  value     = confluent_api_key.tableflow.id
  sensitive = true
}

output "tableflow_api_secret" {
  value     = confluent_api_key.tableflow.secret
  sensitive = true
}

output "check_irc_command" {
  description = "Walk the IRC for this public cluster from the VM (reuses the env Tableflow key on the VM)"
  value       = "sudo -u demo CATALOG_CLUSTER=${confluent_kafka_cluster.pub.id} CATALOG_TOPICS=${confluent_kafka_topic.trades.topic_name} /opt/tableflow-demo/run check_rest_catalog.py"
}
