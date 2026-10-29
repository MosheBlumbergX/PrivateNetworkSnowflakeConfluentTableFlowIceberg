# ============================================================================
# Credentials / accounts
# ============================================================================
variable "confluent_cloud_api_key" {
  description = "Confluent Cloud API key (export TF_VAR_confluent_cloud_api_key)"
  type        = string
}

variable "confluent_cloud_api_secret" {
  description = "Confluent Cloud API secret (export TF_VAR_confluent_cloud_api_secret)"
  type        = string
  sensitive   = true
}

variable "azure_subscription_id" {
  description = "Azure subscription for all customer-side resources"
  type        = string
}

variable "azure_tenant_id" {
  description = "Azure AD tenant for the Confluent provider integration"
  type        = string
}

# ============================================================================
# Placement / naming
# ============================================================================
variable "region" {
  description = "Azure region for everything (Confluent cluster, storage, VNet). Must match the Snowflake account region for subnet firewall rules."
  type        = string
  default     = "uksouth"
}

variable "prefix" {
  description = "Name prefix for Azure and Confluent resources"
  type        = string
  default     = "mbpltf"
}

variable "tags" {
  description = "Required cloud resource tags (applied to every Azure resource)"
  type        = map(string)
}

variable "vnet_cidr" {
  description = "Address space of the customer VNet"
  type        = string
  default     = "10.42.0.0/16"
}

variable "ssh_allowed_cidr" {
  description = "CIDR allowed to SSH to the demo VM (your public IP /32)"
  type        = string
}

variable "vm_size" {
  description = "Size of the producer/sync VM"
  type        = string
  default     = "Standard_B2s"
}

# ============================================================================
# Demo content
# ============================================================================
variable "topics" {
  description = "Kafka topics created from inside the VNet and enabled for Tableflow"
  type        = list(string)
  default     = ["stock_trades"]
}

variable "topic_prefix" {
  description = "Topic name prefix the producer service account may create/write (RBAC prefix binding). All topics, including ones added live, must start with it."
  type        = string
  default     = "stock_"
}

variable "producer_messages_per_second" {
  description = "Messages per second the VM producer writes to each topic"
  type        = number
  default     = 50
}
