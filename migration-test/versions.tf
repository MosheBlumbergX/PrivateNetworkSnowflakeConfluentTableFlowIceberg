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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
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
  subscription_id     = local.infra.azure_subscription_id
  storage_use_azuread = true
  features {}
}
