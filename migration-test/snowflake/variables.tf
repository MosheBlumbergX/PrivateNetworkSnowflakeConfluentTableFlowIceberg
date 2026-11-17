variable "snowflake_organization_name" {
  type = string
}

variable "snowflake_account_name" {
  type = string
}

variable "snowflake_admin_role" {
  type    = string
  default = "ACCOUNTADMIN"
}

variable "name_prefix" {
  type    = string
  default = "TABLEFLOW_PUB"
}

variable "container_name" {
  description = "ADLS container the public cluster's Tableflow writes to (shared 'tableflow'; isolation is by cluster-id path)"
  type        = string
  default     = "tableflow"
}

# Phase 2 inputs (REST catalog integration). Filled from the migration-test outputs.
variable "public_cluster_id" {
  type    = string
  default = ""
}

variable "tableflow_api_key" {
  type    = string
  default = ""
}

variable "tableflow_api_secret" {
  type      = string
  default   = ""
  sensitive = true
}

variable "topic" {
  type    = string
  default = "pub_trades"
}

variable "enable_phase2" {
  description = "Create the native REST catalog integration + catalog-linked database"
  type        = bool
  default     = true
}

variable "org_id" {
  description = "Confluent organization id (for the Tableflow IRC catalog URI)"
  type        = string
  default     = "f5f511c7-d821-48cc-8388-c96a6f11f12a"
}

variable "region" {
  type    = string
  default = "uksouth"
}
