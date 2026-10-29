# ============================================================================
# ADLS Gen2 (BYOS for Tableflow), closed to the public internet.
#   - Confluent Tableflow writes through its egress Private Link gateway
#     (private endpoints bypass the storage firewall).
#   - The VM reads through a private endpoint in this VNet.
#   - Snowflake reads through its Azure VNet subnets, which the snowflake/
#     stack adds as firewall rules (option A, any Snowflake edition).
# ============================================================================
resource "azurerm_storage_account" "adls" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  is_hns_enabled                  = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = true # "selected networks" only, see network_rules
  tags                            = var.tags

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  lifecycle {
    # The snowflake/ stack adds Snowflake's VNet subnet IDs out of band.
    ignore_changes = [network_rules[0].virtual_network_subnet_ids]
  }
}

resource "azurerm_storage_container" "tableflow" {
  name                  = local.container_name
  storage_account_id    = azurerm_storage_account.adls.id
  container_access_type = "private"
}

# ----------------------------------------------------------------------------
# Confluent provider integration (multi-tenant app -> this tenant)
# ----------------------------------------------------------------------------
resource "confluent_provider_integration_setup" "azure" {
  environment {
    id = confluent_environment.main.id
  }

  display_name = "${local.name}-azure"
  cloud        = "AZURE"
}

resource "confluent_provider_integration_authorization" "azure" {
  provider_integration_id = confluent_provider_integration_setup.azure.id

  environment {
    id = confluent_environment.main.id
  }

  azure {
    customer_azure_tenant_id = var.azure_tenant_id
  }
}

# Graph create via the azuread provider often 403s for cross-tenant apps; az CLI works.
resource "null_resource" "confluent_azure_sp" {
  triggers = {
    app_id = confluent_provider_integration_authorization.azure.azure[0].confluent_multi_tenant_app_id
  }

  provisioner "local-exec" {
    # Confluent's app can take a minute to become visible to a new tenant; retry.
    command = "for i in $(seq 1 30); do az ad sp show --id ${self.triggers.app_id} -o none 2>/dev/null && exit 0; az ad sp create --id ${self.triggers.app_id} -o none 2>/dev/null && exit 0; sleep 10; done; exit 1"
  }
}

data "azuread_service_principal" "confluent" {
  client_id  = confluent_provider_integration_authorization.azure.azure[0].confluent_multi_tenant_app_id
  depends_on = [null_resource.confluent_azure_sp]
}

resource "azurerm_role_assignment" "confluent_blob_contributor" {
  scope                = azurerm_storage_account.adls.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azuread_service_principal.confluent.object_id
}

resource "azurerm_role_assignment" "confluent_reader" {
  scope                = azurerm_storage_account.adls.id
  role_definition_name = "Reader"
  principal_id         = data.azuread_service_principal.confluent.object_id
}

# ----------------------------------------------------------------------------
# Private endpoint so the VM (sync job) can list Iceberg metadata files.
# ----------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "${local.name}-blob-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.main.id
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "blob" {
  name                          = "${local.name}-blob-pe"
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  subnet_id                     = azurerm_subnet.private_endpoints.id
  custom_network_interface_name = "${local.name}-blob-pe-nic"
  tags                          = var.tags

  private_service_connection {
    name                           = "${local.name}-blob-psc"
    is_manual_connection           = false
    private_connection_resource_id = azurerm_storage_account.adls.id
    subresource_names              = ["blob"]
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }
}
