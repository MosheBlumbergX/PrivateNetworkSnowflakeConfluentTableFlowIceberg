variable "snowflake_organization_name" {
  description = "Snowflake organization name (Admin > Accounts). The account must be on Azure in the same region as the infra stack (uksouth)."
  type        = string
}

variable "snowflake_account_name" {
  description = "Snowflake account name (not the locator)"
  type        = string
}

variable "snowflake_admin_role" {
  description = "Role Terraform uses (needs to create integrations, volumes, users)"
  type        = string
  default     = "ACCOUNTADMIN"
}

variable "snowflake_query_role" {
  description = "Existing role that is granted the sync role so humans can query the tables"
  type        = string
  default     = "SYSADMIN"
}

variable "name_prefix" {
  description = "Prefix for Snowflake object names"
  type        = string
  default     = "TABLEFLOW_PL"
}

variable "snowflake_azure_consent_completed" {
  description = <<-EOT
    Phase gate. Set true after opening the snowflake_azure_consent_url output once so
    Snowflake's multi-tenant app exists in the Azure tenant. The next apply grants it
    read access to the storage account and starts the sync job.
  EOT
  type        = bool
  default     = false
}
