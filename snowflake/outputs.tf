output "snowflake_azure_subnet_ids" {
  description = "Snowflake VNet subnets added to the storage firewall"
  value       = data.snowflake_system_get_snowflake_platform_info.current.azure_vnet_subnet_ids
}

output "snowflake_azure_consent_url" {
  description = "Open once (tenant admin), accept, then set snowflake_azure_consent_completed = true and apply again"
  value       = local.azure_consent_url
}

output "snowflake_azure_multi_tenant_app_name" {
  value = local.azure_app_name
}

output "status" {
  value = var.snowflake_azure_consent_completed ? "Phase 2: sync job configured on the VM; tables appear in ${local.database}.${local.schema} within ~1 minute of each Tableflow snapshot." : "Phase 1: open snowflake_azure_consent_url, accept, set snowflake_azure_consent_completed = true, then terraform apply."
}

output "query_example" {
  value = <<-EOT
    USE ROLE ${var.snowflake_query_role};
    USE WAREHOUSE ${local.warehouse};
    SHOW ICEBERG TABLES IN SCHEMA ${local.database}.${local.schema};
    SELECT symbol, side, COUNT(*) trades, ROUND(AVG(price), 2) avg_price
    FROM ${local.database}.${local.schema}.STOCK_TRADES
    GROUP BY 1, 2 ORDER BY trades DESC;
  EOT
}
