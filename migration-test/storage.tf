# A separate, PUBLIC BYOS ADLS account just for the public-cluster migration test.
# The private demo's account stays locked down; this one allows all networks so a
# public Standard cluster's Tableflow (which egresses over the public internet) can
# write to it. This is the whole reason the earlier attempts FAILED on the private
# account: its firewall denies the public cluster's network path.

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_storage_account" "pub" {
  name                     = "mbpltfpub${random_string.suffix.result}"
  resource_group_name      = local.infra.resource_group_name
  location                 = local.infra.region
  account_tier             = "Standard"
  account_replication_type = "LRS"
  is_hns_enabled           = true # ADLS Gen2

  # Open: the public cluster reaches this over the public internet. No network_rules
  # block means default-Allow (all networks), and avoids azurerm's perpetual diff on
  # a bare default_action.
  public_network_access_enabled = true

  tags = local.infra.tags
}

resource "azurerm_storage_container" "pub" {
  name               = "tableflow"
  storage_account_id = azurerm_storage_account.pub.id
}

# Confluent provider-integration SP: write access so Tableflow can materialize.
resource "azurerm_role_assignment" "confluent_contributor" {
  scope                = azurerm_storage_account.pub.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.confluent_sp_object_id
}

resource "azurerm_role_assignment" "confluent_reader" {
  scope                = azurerm_storage_account.pub.id
  role_definition_name = "Reader"
  principal_id         = var.confluent_sp_object_id
}

# Snowflake SP (already consented for this Snowflake account + tenant): read access
# so the external volume / object-store catalog can read the Iceberg data.
resource "azurerm_role_assignment" "snowflake_reader" {
  scope                = azurerm_storage_account.pub.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = var.snowflake_sp_object_id
}

# Demo VM managed identity: read access so register_pub.py (runs on the VM) can
# list the newest Iceberg metadata to register the manual Phase-1 table.
resource "azurerm_role_assignment" "vm_reader" {
  scope                = azurerm_storage_account.pub.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = var.vm_mi_object_id
}
