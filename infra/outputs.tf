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
  value       = "ssh -i ${abspath(local_sensitive_file.vm_ssh_key.filename)} azureuser@${azurerm_public_ip.vm.ip_address}"
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

output "grafana_tunnel" {
  description = "Open this tunnel, then browse to http://localhost:3000 (anonymous viewer, no login prompt)"
  value       = "ssh -i ${abspath(local_sensitive_file.vm_ssh_key.filename)} -N -L 3000:localhost:3000 azureuser@${azurerm_public_ip.vm.ip_address}"
}

output "grafana_admin_password" {
  description = "Grafana admin login, only needed to edit panels; viewing needs no login"
  value       = random_password.grafana_admin.result
  sensitive   = true
}

output "prometheus_tunnel" {
  description = "Prometheus UI, useful for checking scrape health against the Metrics API"
  value       = "ssh -i ${abspath(local_sensitive_file.vm_ssh_key.filename)} -N -L 9090:localhost:9090 azureuser@${azurerm_public_ip.vm.ip_address}"
}
