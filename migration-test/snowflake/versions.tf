terraform {
  required_version = ">= 1.6"
  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = "~> 2.22"
    }
  }
}

provider "snowflake" {
  organization_name = var.snowflake_organization_name
  account_name      = var.snowflake_account_name
  role              = var.snowflake_admin_role

  preview_features_enabled = [
    "snowflake_system_get_snowflake_platform_info_datasource",
    "snowflake_external_volume_resource",
    "snowflake_catalog_integration_object_storage_resource",
    "snowflake_catalog_integration_iceberg_rest_resource",
    "snowflake_iceberg_table_from_rest_resource",
  ]
}
