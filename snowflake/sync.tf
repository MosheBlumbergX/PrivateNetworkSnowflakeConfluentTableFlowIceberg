# ============================================================================
# Sync role + key-pair service user for the VM sync job
# ============================================================================
resource "snowflake_account_role" "sync" {
  name    = local.sync_role
  comment = "Creates/refreshes Tableflow Iceberg tables"
}

resource "snowflake_grant_account_role" "sync_to_query_role" {
  role_name        = snowflake_account_role.sync.name
  parent_role_name = var.snowflake_query_role
}

resource "snowflake_grant_privileges_to_account_role" "sync_integration" {
  account_role_name = snowflake_account_role.sync.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "INTEGRATION"
    object_name = snowflake_catalog_integration_object_storage.tableflow.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "sync_volume" {
  account_role_name = snowflake_account_role.sync.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "EXTERNAL VOLUME"
    object_name = snowflake_external_volume.adls.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "sync_database" {
  account_role_name = snowflake_account_role.sync.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.tableflow.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "sync_warehouse" {
  account_role_name = snowflake_account_role.sync.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.tableflow.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "sync_schema" {
  account_role_name = snowflake_account_role.sync.name
  privileges        = ["USAGE", "CREATE ICEBERG TABLE"]
  on_schema {
    schema_name = snowflake_schema.confluent.fully_qualified_name
  }
}

resource "tls_private_key" "sync_user" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "snowflake_service_user" "sync" {
  name              = local.sync_user
  login_name        = local.sync_user
  comment           = "Tableflow sync job on the Azure VM (key-pair auth)"
  default_role      = snowflake_account_role.sync.name
  default_warehouse = snowflake_warehouse.tableflow.name
  rsa_public_key = join("", [
    for line in split("\n", trimspace(tls_private_key.sync_user.public_key_pem)) : line if !startswith(line, "-----")
  ])
}

resource "snowflake_grant_account_role" "sync_to_user" {
  role_name = snowflake_account_role.sync.name
  user_name = snowflake_service_user.sync.name
}

# ============================================================================
# Push Snowflake settings + key to the VM (via run-command, inside the VNet)
# ============================================================================
resource "local_sensitive_file" "vm_snowflake_config" {
  count = var.snowflake_azure_consent_completed ? 1 : 0

  filename = "${path.module}/../.generated/configure-snowflake.sh"
  content  = <<-EOT
    #!/bin/bash
    set -euo pipefail
    ETC=/etc/tableflow-demo
    cat > $ETC/snowflake_key.p8 <<'KEYEOF'
    ${trimspace(tls_private_key.sync_user.private_key_pem_pkcs8)}
    KEYEOF
    cat > $ETC/snowflake.env <<'ENVEOF'
    SNOWFLAKE_ACCOUNT=${var.snowflake_organization_name}-${var.snowflake_account_name}
    SNOWFLAKE_USER=${snowflake_service_user.sync.name}
    SNOWFLAKE_PRIVATE_KEY_PATH=$ETC/snowflake_key.p8
    SNOWFLAKE_ROLE=${snowflake_account_role.sync.name}
    SNOWFLAKE_WAREHOUSE=${snowflake_warehouse.tableflow.name}
    SNOWFLAKE_DATABASE=${snowflake_database.tableflow.name}
    SNOWFLAKE_SCHEMA=${snowflake_schema.confluent.name}
    SNOWFLAKE_EXTERNAL_VOLUME=${snowflake_external_volume.adls.name}
    SNOWFLAKE_CATALOG_INTEGRATION=${snowflake_catalog_integration_object_storage.tableflow.name}
    ENVEOF
    sed -i 's/^[[:space:]]*//; s#\$ETC#/etc/tableflow-demo#' $ETC/snowflake.env $ETC/snowflake_key.p8
    chown root:demo $ETC/snowflake.env $ETC/snowflake_key.p8
    chmod 640 $ETC/snowflake.env $ETC/snowflake_key.p8
    systemctl start tableflow-sync.service || true
    journalctl -u tableflow-sync.service -n 20 --no-pager
    echo SNOWFLAKE_CONFIG_OK
  EOT
}

resource "null_resource" "vm_snowflake_config" {
  count = var.snowflake_azure_consent_completed ? 1 : 0

  triggers = {
    script = local_sensitive_file.vm_snowflake_config[0].content_sha256
  }

  provisioner "local-exec" {
    command = "${path.module}/../scripts/vm-run.sh ${local.infra.azure_subscription_id} ${local.infra.resource_group_name} ${local.infra.vm_name} ${local_sensitive_file.vm_snowflake_config[0].filename} SNOWFLAKE_CONFIG_OK"
  }

  depends_on = [
    azurerm_role_assignment.snowflake_blob_reader,
    snowflake_grant_account_role.sync_to_user,
    snowflake_grant_privileges_to_account_role.sync_integration,
    snowflake_grant_privileges_to_account_role.sync_volume,
    snowflake_grant_privileges_to_account_role.sync_database,
    snowflake_grant_privileges_to_account_role.sync_warehouse,
    snowflake_grant_privileges_to_account_role.sync_schema,
  ]
}
