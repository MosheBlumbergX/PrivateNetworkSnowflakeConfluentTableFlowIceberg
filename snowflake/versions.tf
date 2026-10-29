terraform {
  required_version = ">= 1.6"

  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = "~> 2.22"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.40"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# Authentication comes from the provider's env vars so any method works
# (password, PAT, key pair, externalbrowser):
#   SNOWFLAKE_USER, SNOWFLAKE_PASSWORD | SNOWFLAKE_AUTHENTICATOR | SNOWFLAKE_PRIVATE_KEY ...
provider "snowflake" {
  organization_name = var.snowflake_organization_name
  account_name      = var.snowflake_account_name
  role              = var.snowflake_admin_role

  preview_features_enabled = [
    "snowflake_system_get_snowflake_platform_info_datasource",
    "snowflake_external_volume_resource",
    "snowflake_catalog_integration_object_storage_resource",
  ]
}

provider "azurerm" {
  subscription_id     = local.infra.azure_subscription_id
  storage_use_azuread = true

  features {
    storage {
      data_plane_available = false
    }
  }
}

provider "azuread" {
  tenant_id = local.infra.azure_tenant_id
}
