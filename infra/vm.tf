# ============================================================================
# Demo VM inside the customer VNet:
#   - creates topics and produces Avro data over Private Link (PLATT)
#   - runs the Tableflow -> Snowflake sync job on a systemd timer
# Terraform pushes app code/config with `az vm run-command`, which executes
# inside the VNet and so can reach the private cluster.
# ============================================================================
resource "tls_private_key" "vm_ssh" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "vm_ssh_key" {
  filename        = "${path.module}/../.generated/vm_ssh_key.pem"
  content         = tls_private_key.vm_ssh.private_key_openssh
  file_permission = "0600"
}

resource "azurerm_public_ip" "vm" {
  name                = "${local.name}-vm-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "vm" {
  name                = "${local.name}-vm-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

resource "azurerm_linux_virtual_machine" "demo" {
  name                  = "${local.name}-vm"
  location              = azurerm_resource_group.main.location
  resource_group_name   = azurerm_resource_group.main.name
  size                  = var.vm_size
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.vm.id]
  custom_data           = base64encode(file("${path.module}/../app/cloud-init.yaml"))
  tags                  = var.tags

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.vm_ssh.public_key_openssh
  }

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    name                 = "${local.name}-vm-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

# Lets the sync job list Tableflow's Iceberg metadata files.
resource "azurerm_role_assignment" "vm_blob_reader" {
  scope                = azurerm_storage_account.adls.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_linux_virtual_machine.demo.identity[0].principal_id
}

# OS disks and private endpoint NICs are created implicitly and don't inherit tags.
resource "null_resource" "tag_implicit_resources" {
  triggers = {
    ids  = join(" ", local.implicit_resource_ids)
    tags = jsonencode(var.tags)
  }

  provisioner "local-exec" {
    command = "for id in ${self.triggers.ids}; do az tag update --resource-id \"$id\" --operation Merge --tags ${join(" ", [for k, v in var.tags : "${k}=${v}"])} >/dev/null; done"
  }
}

locals {
  implicit_resource_ids = [
    "${azurerm_resource_group.main.id}/providers/Microsoft.Compute/disks/${azurerm_linux_virtual_machine.demo.os_disk[0].name}",
    azurerm_private_endpoint.confluent.network_interface[0].id,
    azurerm_private_endpoint.blob.network_interface[0].id,
  ]

  app_files = {
    for f in ["common.py", "create_topics.py", "producer.py", "sync.py", "add_topic.py", "requirements.txt",
    "tableflow-producer.service", "tableflow-sync.service", "tableflow-sync.timer"] :
    f => filebase64("${path.module}/../app/${f}")
  }

  common_env = {
    KAFKA_BOOTSTRAP            = replace(confluent_kafka_cluster.main.bootstrap_endpoint, "SASL_SSL://", "")
    KAFKA_API_KEY              = confluent_api_key.producer_kafka.id
    KAFKA_API_SECRET           = confluent_api_key.producer_kafka.secret
    SCHEMA_REGISTRY_URL        = data.confluent_schema_registry_cluster.main.rest_endpoint
    SCHEMA_REGISTRY_API_KEY    = confluent_api_key.producer_sr.id
    SCHEMA_REGISTRY_API_SECRET = confluent_api_key.producer_sr.secret
    MESSAGES_PER_SECOND        = tostring(var.producer_messages_per_second)
    TOPIC_PREFIX               = var.topic_prefix
    TABLEFLOW_API_KEY          = confluent_api_key.tableflow.id
    TABLEFLOW_API_SECRET       = confluent_api_key.tableflow.secret
    CONFLUENT_ENVIRONMENT_ID   = confluent_environment.main.id
    CONFLUENT_CLUSTER_ID       = confluent_kafka_cluster.main.id
    AZURE_STORAGE_ACCOUNT      = azurerm_storage_account.adls.name
    AZURE_STORAGE_CONTAINER    = azurerm_storage_container.tableflow.name
  }
}

resource "local_sensitive_file" "deploy_script" {
  filename = "${path.module}/../.generated/deploy-app.sh"
  content = templatefile("${path.module}/../app/deploy.sh.tftpl", {
    files      = local.app_files
    common_env = local.common_env
    topics     = var.topics
  })
}

resource "null_resource" "deploy_app" {
  triggers = {
    script = local_sensitive_file.deploy_script.content_sha256
    vm_id  = azurerm_linux_virtual_machine.demo.id
  }

  provisioner "local-exec" {
    command = "${path.module}/../scripts/vm-run.sh ${azurerm_resource_group.main.name} ${azurerm_linux_virtual_machine.demo.name} ${local_sensitive_file.deploy_script.filename} DEPLOY_OK"
  }

  depends_on = [
    confluent_private_link_attachment_connection.main,
    azurerm_private_dns_a_record.confluent_wildcard,
    azurerm_private_dns_zone_virtual_network_link.confluent,
    azurerm_private_endpoint.blob,
    azurerm_role_assignment.vm_blob_reader,
  ]
}
