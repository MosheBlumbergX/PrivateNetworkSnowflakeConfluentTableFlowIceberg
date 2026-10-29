resource "confluent_environment" "main" {
  display_name = "${local.name}-env"

  stream_governance {
    package = "ESSENTIALS"
  }
}

# Enterprise clusters on Azure are reached through a Private Link Attachment (PLATT).
resource "confluent_kafka_cluster" "main" {
  display_name = "${local.name}-enterprise"
  availability = "HIGH"
  cloud        = "AZURE"
  region       = var.region
  enterprise {}

  environment {
    id = confluent_environment.main.id
  }
}

data "confluent_schema_registry_cluster" "main" {
  environment {
    id = confluent_environment.main.id
  }

  depends_on = [confluent_kafka_cluster.main]
}

# ----------------------------------------------------------------------------
# Producer service account (runs on the VM inside the VNet).
# RBAC role bindings go through the public control plane, so Terraform on a
# laptop can grant access without reaching the private Kafka REST endpoint.
# ----------------------------------------------------------------------------
resource "confluent_service_account" "producer" {
  display_name = "${local.name}-producer"
  description  = "Produces demo data from the customer VNet over Private Link"
}

resource "confluent_role_binding" "producer_topic_manage" {
  principal   = "User:${confluent_service_account.producer.id}"
  role_name   = "DeveloperManage"
  crn_pattern = "${confluent_kafka_cluster.main.rbac_crn}/kafka=${confluent_kafka_cluster.main.id}/topic=${var.topic_prefix}*"
}

resource "confluent_role_binding" "producer_topic_write" {
  principal   = "User:${confluent_service_account.producer.id}"
  role_name   = "DeveloperWrite"
  crn_pattern = "${confluent_kafka_cluster.main.rbac_crn}/kafka=${confluent_kafka_cluster.main.id}/topic=${var.topic_prefix}*"
}

resource "confluent_role_binding" "producer_subject_write" {
  principal   = "User:${confluent_service_account.producer.id}"
  role_name   = "DeveloperWrite"
  crn_pattern = "${data.confluent_schema_registry_cluster.main.resource_name}/subject=${var.topic_prefix}*"
}

resource "confluent_api_key" "producer_kafka" {
  display_name = "${local.name}-producer-kafka"
  # The provider's readiness check calls the cluster REST endpoint, which is
  # only reachable inside the VNet.
  disable_wait_for_ready = true
  owner {
    id          = confluent_service_account.producer.id
    api_version = confluent_service_account.producer.api_version
    kind        = confluent_service_account.producer.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.main.id
    api_version = confluent_kafka_cluster.main.api_version
    kind        = confluent_kafka_cluster.main.kind
    environment {
      id = confluent_environment.main.id
    }
  }

  depends_on = [
    confluent_role_binding.producer_topic_manage,
    confluent_role_binding.producer_topic_write,
  ]
}

resource "confluent_api_key" "producer_sr" {
  display_name = "${local.name}-producer-sr"
  owner {
    id          = confluent_service_account.producer.id
    api_version = confluent_service_account.producer.api_version
    kind        = confluent_service_account.producer.kind
  }

  managed_resource {
    id          = data.confluent_schema_registry_cluster.main.id
    api_version = data.confluent_schema_registry_cluster.main.api_version
    kind        = data.confluent_schema_registry_cluster.main.kind
    environment {
      id = confluent_environment.main.id
    }
  }

  depends_on = [confluent_role_binding.producer_subject_write]
}

# ----------------------------------------------------------------------------
# Tableflow service account. Its API key enables Tableflow and is used by the
# sync job to discover Tableflow topics (control plane metadata only).
# ----------------------------------------------------------------------------
resource "confluent_service_account" "tableflow" {
  display_name = "${local.name}-tableflow"
  description  = "Tableflow enablement and discovery"
}

resource "confluent_role_binding" "tableflow_cluster_admin" {
  principal   = "User:${confluent_service_account.tableflow.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.main.rbac_crn
}

resource "confluent_role_binding" "tableflow_env_admin" {
  principal   = "User:${confluent_service_account.tableflow.id}"
  role_name   = "EnvironmentAdmin"
  crn_pattern = confluent_environment.main.resource_name
}

resource "confluent_role_binding" "tableflow_subject_read" {
  principal   = "User:${confluent_service_account.tableflow.id}"
  role_name   = "DeveloperRead"
  crn_pattern = "${data.confluent_schema_registry_cluster.main.resource_name}/subject=*"
}

resource "confluent_api_key" "tableflow" {
  display_name = "${local.name}-tableflow"
  owner {
    id          = confluent_service_account.tableflow.id
    api_version = confluent_service_account.tableflow.api_version
    kind        = confluent_service_account.tableflow.kind
  }

  managed_resource {
    id          = "tableflow"
    api_version = "tableflow/v1"
    kind        = "Tableflow"
    environment {
      id = confluent_environment.main.id
    }
  }

  depends_on = [
    confluent_role_binding.tableflow_cluster_admin,
    confluent_role_binding.tableflow_env_admin,
    confluent_role_binding.tableflow_subject_read,
  ]
}
