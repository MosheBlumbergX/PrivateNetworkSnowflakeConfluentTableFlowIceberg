terraform {
  required_version = ">= 1.6"

  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = "~> 2.92"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.40"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
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

provider "confluent" {
  cloud_api_key    = var.confluent_cloud_api_key
  cloud_api_secret = var.confluent_cloud_api_secret
}

provider "azurerm" {
  subscription_id     = var.azure_subscription_id
  storage_use_azuread = true

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    # The storage account only allows selected networks, so Terraform on a laptop
    # must manage it purely through ARM (no blob/queue data plane calls).
    storage {
      data_plane_available = false
    }
  }
}

provider "azuread" {
  tenant_id = var.azure_tenant_id
}
