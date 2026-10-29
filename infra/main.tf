resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  name                 = "${var.prefix}-${random_string.suffix.result}"
  storage_account_name = substr("${var.prefix}${random_string.suffix.result}", 0, 24)
  container_name       = "tableflow"
}

resource "azurerm_resource_group" "main" {
  name     = "${local.name}-rg"
  location = var.region
  tags     = var.tags
}
