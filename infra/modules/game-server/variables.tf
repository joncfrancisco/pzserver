variable "enabled" {
  description = "false leaves out the instance, its EIP and the volume attachment (the wound-down state). Everything else in this module stays."
  type        = bool
  default     = true
}

variable "name_prefix" { type = string }
variable "stack" { type = string }
variable "region" { type = string }
variable "availability_zone" { type = string }
variable "subnet_id" { type = string }
variable "security_group_id" { type = string }

variable "instance_type" { type = string }
variable "root_volume_gb" { type = number }
variable "data_volume_id" {
  description = "Existing world volume to attach to the game server, or null for none. See main.tf \"The world\"."
  type        = string
  default     = null
}

variable "server_name" { type = string }
variable "xmx" { type = string }
variable "idle_warn_minutes" { type = number }
variable "idle_timeout_minutes" { type = number }
variable "session_cap_hours" { type = number }
variable "down_timeout_minutes" { type = number }
variable "monthly_budget_usd" { type = number }

variable "backup_bucket_arn" { type = string }
variable "backup_bucket_name" { type = string }
variable "ssm_prefix" { type = string }
variable "alert_topic_arn" { type = string }
variable "audit_log_group_name" { type = string }
variable "audit_log_group_arn" { type = string }
