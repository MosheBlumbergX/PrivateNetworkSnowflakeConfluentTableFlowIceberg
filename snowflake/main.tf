data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = "${path.module}/../infra/terraform.tfstate"
  }
}

locals {
  infra = data.terraform_remote_state.infra.outputs

  database            = "${var.name_prefix}_DB"
  schema              = "CONFLUENT"
  warehouse           = "${var.name_prefix}_WH"
  sync_role           = "${var.name_prefix}_SYNC_ROLE"
  sync_user           = "${var.name_prefix}_SYNC_USER"
  external_volume     = "${var.name_prefix}_ADLS_VOLUME"
  catalog_integration = "${var.name_prefix}_OBJECT_STORE"

  # Blob endpoint, not dfs: Tableflow metadata references abfss:// paths, and
  # Snowflake resolves them under this base URL.
  storage_base_url = "azure://${local.infra.storage_account_name}.blob.core.windows.net/${local.infra.storage_container_name}/"

  azure_storage_location = try(snowflake_external_volume.adls.describe_output[0].storage_locations[0].azure_storage_location[0], null)
  azure_consent_url      = try(local.azure_storage_location.azure_consent_url, null)
  azure_app_name         = try(local.azure_storage_location.azure_multi_tenant_app_name, null)
  azure_app_display_name = local.azure_app_name != null ? split("_", local.azure_app_name)[0] : null
}

# ============================================================================
# Option A network path: allow Snowflake's Azure VNet subnets on the storage
# firewall (service endpoints, Azure backbone, any Snowflake edition).
# ============================================================================
data "snowflake_system_get_snowflake_platform_info" "current" {}

resource "null_resource" "storage_firewall_snowflake_subnets" {
  triggers = {
    subnet_ids      = join(" ", data.snowflake_system_get_snowflake_platform_info.current.azure_vnet_subnet_ids)
    storage_account = local.infra.storage_account_name
    resource_group  = local.infra.resource_group_name
  }

  provisioner "local-exec" {
    command = "for s in ${self.triggers.subnet_ids}; do az storage account network-rule add -g ${self.triggers.resource_group} --account-name ${self.triggers.storage_account} --subnet \"$s\" -o none; done"
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "for s in ${self.triggers.subnet_ids}; do az storage account network-rule remove -g ${self.triggers.resource_group} --account-name ${self.triggers.storage_account} --subnet \"$s\" -o none; done"
  }
}

# ============================================================================
# External volume on the private ADLS container (read-only)
# ============================================================================
resource "snowflake_external_volume" "adls" {
  name         = local.external_volume
  comment      = "Tableflow BYOS ADLS (managed id ${local.infra.tags["cflt_managed_id"]})"
  allow_writes = "false"

  storage_location {
    storage_location_name = "tableflow-adls"
    storage_provider      = "AZURE"
    storage_base_url      = local.storage_base_url
    azure_tenant_id       = local.infra.azure_tenant_id
  }

  depends_on = [null_resource.storage_firewall_snowflake_subnets]
}

data "azuread_service_principal" "snowflake" {
  count        = var.snowflake_azure_consent_completed ? 1 : 0
  display_name = local.azure_app_display_name
}

resource "azurerm_role_assignment" "snowflake_blob_reader" {
  count = var.snowflake_azure_consent_completed ? 1 : 0

  scope                = local.infra.storage_account_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = data.azuread_service_principal.snowflake[0].object_id
}

# ============================================================================
# Object-store catalog integration: Snowflake reads Iceberg metadata files
# straight from ADLS instead of the (unavailable) Tableflow REST catalog.
# ============================================================================
resource "snowflake_catalog_integration_object_storage" "tableflow" {
  name         = local.catalog_integration
  enabled      = true
  table_format = "ICEBERG"
  comment      = "Tableflow Iceberg metadata in ADLS (no IRC on private networking)"
}

resource "snowflake_database" "tableflow" {
  name    = local.database
  comment = "Tableflow Iceberg tables over private networking"
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
