# ============================================================================
# Egress: Confluent Tableflow -> ADLS via Confluent egress Private Link gateway
# Two access points are required: blob and dfs sub-resources.
# ============================================================================
resource "confluent_gateway" "egress" {
  display_name = "${local.name}-egress"

  environment {
    id = confluent_environment.main.id
  }

  azure_egress_private_link_gateway {
    region = var.region
  }
}

resource "confluent_access_point" "storage" {
  for_each = toset(["blob", "dfs"])

  display_name = "${local.name}-adls-${each.key}"

  environment {
    id = confluent_environment.main.id
  }

  gateway {
    id = confluent_gateway.egress.id
  }

  azure_egress_private_link_endpoint {
    private_link_service_resource_id = azurerm_storage_account.adls.id
    private_link_subresource_name    = each.key
  }
}

# Confluent's private endpoints land as Pending connections on the storage
# account; approve them, then wait for the access points to become READY.
resource "null_resource" "approve_storage_endpoints" {
  for_each = confluent_access_point.storage

  triggers = {
    access_point_id = each.value.id
  }

  provisioner "local-exec" {
    command = "${path.module}/../scripts/approve-egress-endpoint.sh"
    environment = {
      STORAGE_ACCOUNT_ID         = azurerm_storage_account.adls.id
      PRIVATE_ENDPOINT_ID        = each.value.azure_egress_private_link_endpoint[0].private_endpoint_resource_id
      ACCESS_POINT_ID            = each.value.id
      ENVIRONMENT_ID             = confluent_environment.main.id
      CONFLUENT_CLOUD_API_KEY    = var.confluent_cloud_api_key
      CONFLUENT_CLOUD_API_SECRET = var.confluent_cloud_api_secret
    }
  }
}

# The access point's private_endpoint_domain is only populated once it is READY,
# so re-read it after approval.
data "confluent_access_point" "storage" {
  for_each = confluent_access_point.storage

  id = each.value.id

  environment {
    id = confluent_environment.main.id
  }

  depends_on = [null_resource.approve_storage_endpoints]
}

resource "confluent_dns_record" "storage" {
  for_each = confluent_access_point.storage

  display_name = "${local.name}-adls-${each.key}"
  domain       = data.confluent_access_point.storage[each.key].azure_egress_private_link_endpoint[0].private_endpoint_domain

  environment {
    id = confluent_environment.main.id
  }

  gateway {
    id = confluent_gateway.egress.id
  }

  private_link_access_point {
    id = each.value.id
  }

  depends_on = [null_resource.approve_storage_endpoints]
}
