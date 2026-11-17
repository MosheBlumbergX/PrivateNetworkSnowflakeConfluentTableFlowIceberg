# Migration test, Phase 1 (Snowflake): this repo's manual "storage as source of
# truth" solution, applied to the public cluster's Iceberg data in the new
# tableflowpub container. Reuses the Snowflake Azure app and the account-scoped
# Storage Blob Data Reader grant created by the ../snowflake deploy, so no new
# consent is needed (same Snowflake account + Azure tenant).
data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = "${path.module}/../../infra/terraform.tfstate"
  }
}

# The public-cluster migration test writes Iceberg to its own open ADLS account.
data "terraform_remote_state" "pub" {
  backend = "local"
  config = {
    path = "${path.module}/../terraform.tfstate"
  }
}

locals {
  infra = data.terraform_remote_state.infra.outputs
  pub   = data.terraform_remote_state.pub.outputs

  database            = "${var.name_prefix}_DB"
  schema              = "CONFLUENT"
  warehouse           = "${var.name_prefix}_WH"
  external_volume     = "${var.name_prefix}_ADLS_VOLUME"
  catalog_integration = "${var.name_prefix}_OBJECT_STORE"

  storage_base_url = "azure://${local.pub.storage_account_name}.blob.core.windows.net/${local.pub.container_name}/"
}

resource "snowflake_external_volume" "adls" {
  name         = local.external_volume
  comment      = "Migration test: public cluster Tableflow BYOS (${var.container_name})"
  allow_writes = "false"

  storage_location {
    storage_location_name = "tableflowpub-adls"
    storage_provider      = "AZURE"
    storage_base_url      = local.storage_base_url
    azure_tenant_id       = local.infra.azure_tenant_id
  }
}

resource "snowflake_catalog_integration_object_storage" "tableflow" {
  name         = local.catalog_integration
  enabled      = true
  table_format = "ICEBERG"
  comment      = "Manual object-store catalog (our solution) for the public cluster"
}

resource "snowflake_database" "tableflow" {
  name    = local.database
  comment = "Migration test: public cluster Iceberg tables"
}

resource "snowflake_schema" "confluent" {
  database = snowflake_database.tableflow.name
  name     = local.schema
}

resource "snowflake_warehouse" "tableflow" {
  name                = local.warehouse
  warehouse_size      = "XSMALL"
  auto_suspend        = 60
  auto_resume         = "true"
  initially_suspended = true
}

output "external_volume" { value = snowflake_external_volume.adls.name }
output "catalog_integration" { value = snowflake_catalog_integration_object_storage.tableflow.name }
output "database" { value = snowflake_database.tableflow.name }
output "schema" { value = snowflake_schema.confluent.name }
output "warehouse" { value = snowflake_warehouse.tableflow.name }
output "external_volume_azure_app" {
  description = "Azure app for the new external volume; confirms whether it reuses the already-consented Snowflake SP"
  value       = try(snowflake_external_volume.adls.describe_output[0].storage_locations[0].azure_storage_location[0].azure_multi_tenant_app_name, null)
}
