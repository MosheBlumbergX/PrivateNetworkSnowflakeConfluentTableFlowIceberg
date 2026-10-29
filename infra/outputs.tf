output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "region" {
  value = var.region
}

output "azure_tenant_id" {
  value = var.azure_tenant_id
}

output "azure_subscription_id" {
  value = var.azure_subscription_id
}

output "storage_account_name" {
  value = azurerm_storage_account.adls.name
}

output "storage_account_id" {
  value = azurerm_storage_account.adls.id
}

output "storage_container_name" {
  value = azurerm_storage_container.tableflow.name
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.demo.name
}

output "vm_ssh" {
  description = "SSH into the demo VM"
  value       = "ssh -i .generated/vm_ssh_key.pem azureuser@${azurerm_public_ip.vm.ip_address}"
}

output "confluent_environment_id" {
  value = confluent_environment.main.id
}

output "kafka_cluster_id" {
  value = confluent_kafka_cluster.main.id
}

output "kafka_bootstrap_endpoint" {
  value = confluent_kafka_cluster.main.bootstrap_endpoint
}

output "kafka_endpoints" {
  value = confluent_kafka_cluster.main.endpoints
}

output "tableflow_table_paths" {
  description = "Where Tableflow writes each table in ADLS"
  value       = { for k, t in confluent_tableflow_topic.demo : k => t.table_path }
}

output "tags" {
  value = var.tags
}
