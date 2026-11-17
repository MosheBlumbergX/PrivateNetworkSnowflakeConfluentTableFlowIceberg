# Public Standard cluster + a Datagen source + Tableflow (Iceberg, BYOS), in the
# existing environment. The public cluster's REST endpoint is reachable from here,
# so the topic is created directly (no VM needed, unlike the private cluster).

resource "confluent_kafka_cluster" "pub" {
  display_name = "migration-test-public"
  availability = "SINGLE_ZONE"
  cloud        = "AZURE"
  region       = local.infra.region
  standard {}

  environment {
    id = local.infra.confluent_environment_id
  }
}

data "confluent_environment" "main" {
  id = local.infra.confluent_environment_id
}

data "confluent_schema_registry_cluster" "main" {
  environment {
    id = local.infra.confluent_environment_id
  }
}

resource "confluent_service_account" "app" {
  display_name = "migration-test-sa"
  description  = "Public cluster migration test: produce, enable Tableflow, REST catalog OAuth"
}

resource "confluent_role_binding" "cluster_admin" {
  principal   = "User:${confluent_service_account.app.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.pub.rbac_crn
}

resource "confluent_role_binding" "env_admin" {
  principal   = "User:${confluent_service_account.app.id}"
  role_name   = "EnvironmentAdmin"
  crn_pattern = data.confluent_environment.main.resource_name
}

resource "confluent_role_binding" "subject_write" {
  principal   = "User:${confluent_service_account.app.id}"
  role_name   = "DeveloperWrite"
  crn_pattern = "${data.confluent_schema_registry_cluster.main.resource_name}/subject=*"
}

resource "confluent_api_key" "kafka" {
  display_name = "migration-test-kafka"
  owner {
    id          = confluent_service_account.app.id
    api_version = confluent_service_account.app.api_version
    kind        = confluent_service_account.app.kind
  }
  managed_resource {
    id          = confluent_kafka_cluster.pub.id
    api_version = confluent_kafka_cluster.pub.api_version
    kind        = confluent_kafka_cluster.pub.kind
    environment {
      id = local.infra.confluent_environment_id
    }
  }
  depends_on = [confluent_role_binding.cluster_admin]
}

# Tableflow key: enables Tableflow and, in Phase 2, is the REST catalog OAuth client.
resource "confluent_api_key" "tableflow" {
  display_name = "migration-test-tableflow"
  owner {
    id          = confluent_service_account.app.id
    api_version = confluent_service_account.app.api_version
    kind        = confluent_service_account.app.kind
  }
  managed_resource {
    id          = "tableflow"
    api_version = "tableflow/v1"
    kind        = "Tableflow"
    environment {
      id = local.infra.confluent_environment_id
    }
  }
  depends_on = [
    confluent_role_binding.cluster_admin,
    confluent_role_binding.env_admin,
  ]
}

# Public cluster REST endpoint is reachable, so create the topic directly.
resource "confluent_kafka_topic" "trades" {
  kafka_cluster {
    id = confluent_kafka_cluster.pub.id
  }
  topic_name    = var.topic
  rest_endpoint = confluent_kafka_cluster.pub.rest_endpoint
  credentials {
    key    = confluent_api_key.kafka.id
    secret = confluent_api_key.kafka.secret
  }
}

# Datagen brings its own schema (ORDERS, AVRO) and produces data.
resource "confluent_connector" "datagen" {
  environment {
    id = local.infra.confluent_environment_id
  }
  kafka_cluster {
    id = confluent_kafka_cluster.pub.id
  }

  config_sensitive = {}
  config_nonsensitive = {
    "connector.class"          = "DatagenSource"
    "name"                     = "migration-test-datagen"
    "kafka.auth.mode"          = "SERVICE_ACCOUNT"
    "kafka.service.account.id" = confluent_service_account.app.id
    "kafka.topic"              = confluent_kafka_topic.trades.topic_name
    "output.data.format"       = "AVRO"
    "quickstart"               = "ORDERS"
    # High throughput so Tableflow commits (and the sync) land within minutes.
    "tasks.max"    = "4"
    "max.interval" = "20"
  }

  depends_on = [confluent_role_binding.cluster_admin]
}

# SR key used only to poll for schema registration below.
resource "confluent_api_key" "sr" {
  display_name = "migration-test-sr"
  owner {
    id          = confluent_service_account.app.id
    api_version = confluent_service_account.app.api_version
    kind        = confluent_service_account.app.kind
  }
  managed_resource {
    id          = data.confluent_schema_registry_cluster.main.id
    api_version = data.confluent_schema_registry_cluster.main.api_version
    kind        = data.confluent_schema_registry_cluster.main.kind
    environment {
      id = local.infra.confluent_environment_id
    }
  }
  depends_on = [confluent_role_binding.subject_write]
}

# Gate: wait until datagen has registered the topic's value schema. Enabling
# Tableflow before the schema exists makes it FAIL ("no value schema").
resource "null_resource" "wait_for_schema" {
  triggers = {
    topic = confluent_kafka_topic.trades.topic_name
  }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      for i in $(seq 1 60); do
        code=$(curl -s -o /dev/null -w "%%{http_code}" -u "${confluent_api_key.sr.id}:${confluent_api_key.sr.secret}" \
          "${data.confluent_schema_registry_cluster.main.rest_endpoint}/subjects/${confluent_kafka_topic.trades.topic_name}-value/versions")
        if [ "$code" = "200" ]; then echo "schema registered"; exit 0; fi
        sleep 5
      done
      echo "value schema not registered in time"; exit 1
    EOT
  }
  depends_on = [confluent_connector.datagen]
}

# Tableflow (Iceberg) to the new BYOS container. Depends on the connector so a
# schema and data exist first (enabling on an empty/schema-less topic fails).
resource "confluent_tableflow_topic" "trades" {
  display_name  = confluent_kafka_topic.trades.topic_name
  table_formats = ["ICEBERG"]

  environment {
    id = local.infra.confluent_environment_id
  }
  kafka_cluster {
    id = confluent_kafka_cluster.pub.id
  }

  credentials {
    key    = confluent_api_key.tableflow.id
    secret = confluent_api_key.tableflow.secret
  }

  # Separate PUBLIC account: a public cluster egresses to storage over the public
  # internet, which the private demo's firewalled account denies. This one allows
  # all networks.
  azure_data_lake_storage_gen_2 {
    provider_integration_id = var.provider_integration_id
    container_name          = azurerm_storage_container.pub.name
    storage_account_name    = azurerm_storage_account.pub.name
  }

  depends_on = [
    null_resource.wait_for_schema,
    azurerm_role_assignment.confluent_contributor,
    azurerm_role_assignment.confluent_reader,
  ]
}
