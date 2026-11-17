variable "confluent_cloud_api_key" {
  type = string
}

variable "confluent_cloud_api_secret" {
  type      = string
  sensitive = true
}

variable "provider_integration_id" {
  description = "Confluent provider integration authorizing Tableflow to write to the ADLS account (from infra)"
  type        = string
  default     = "cspi-n7m7v"
}

variable "confluent_sp_object_id" {
  description = "Object id of the Confluent provider-integration service principal (from infra)"
  type        = string
  default     = "99ea4a4b-5a62-4c86-9caa-2819759d6607"
}

variable "snowflake_sp_object_id" {
  description = "Object id of the Snowflake Azure service principal (vxkg5hsnowflakepacint)"
  type        = string
  default     = "4c9dd4d0-c5d8-4ed5-a3f3-f8abea5e50f5"
}

variable "vm_mi_object_id" {
  description = "Object id of the demo VM's system-assigned managed identity (reads metadata for register_pub.py)"
  type        = string
  default     = "e0c621c3-5464-4f53-82dd-1c273c2d9672"
}

variable "container_name" {
  description = "New BYOS container for the public cluster's Tableflow output (isolated from the private demo)"
  type        = string
  default     = "tableflowpub"
}

variable "topic" {
  type    = string
  default = "pub_orders2"
}
