# ============================================================================
# Ingress: customer VNet -> Confluent Enterprise cluster via Private Link (PLATT)
# ============================================================================
resource "confluent_private_link_attachment" "main" {
  cloud        = "AZURE"
  region       = var.region
  display_name = "${local.name}-platt"

  environment {
    id = confluent_environment.main.id
  }
}

resource "azurerm_private_endpoint" "confluent" {
  name                          = "${local.name}-confluent-pe"
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  subnet_id                     = azurerm_subnet.private_endpoints.id
  custom_network_interface_name = "${local.name}-confluent-pe-nic"
  tags                          = var.tags

  private_service_connection {
    name                              = "${local.name}-confluent-psc"
    is_manual_connection              = true
    private_connection_resource_alias = confluent_private_link_attachment.main.azure[0].private_link_service_alias
    request_message                   = "Confluent Private Link Attachment"
  }
}

resource "confluent_private_link_attachment_connection" "main" {
  display_name = "${local.name}-plattc"

  environment {
    id = confluent_environment.main.id
  }

  azure {
    private_endpoint_resource_id = azurerm_private_endpoint.confluent.id
  }

  private_link_attachment {
    id = confluent_private_link_attachment.main.id
  }
}

resource "azurerm_private_dns_zone" "confluent" {
  name                = confluent_private_link_attachment.main.dns_domain
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "confluent" {
  name                  = "${local.name}-confluent-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.confluent.name
  virtual_network_id    = azurerm_virtual_network.main.id
  tags                  = var.tags
}

resource "azurerm_private_dns_a_record" "confluent_wildcard" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.confluent.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 60
  records             = [azurerm_private_endpoint.confluent.private_service_connection[0].private_ip_address]
  tags                = var.tags
}
