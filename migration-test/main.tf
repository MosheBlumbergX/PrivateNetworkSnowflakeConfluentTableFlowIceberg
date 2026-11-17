# Migration test, Phase 1: a PUBLIC cluster in the same environment, running this
# repo's manual "storage as source of truth" solution, as the starting point for
# migrating to the native Tableflow Iceberg REST Catalog (Phase 2).
#
# Writes Iceberg to the existing shared "tableflow" container (isolated by the
# cluster-id path). A brand-new container trips a first-enable permissions race
# against the Confluent provider SP, so reuse the proven one.
data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = "${path.module}/../infra/terraform.tfstate"
  }
}

locals {
  infra = data.terraform_remote_state.infra.outputs
}
