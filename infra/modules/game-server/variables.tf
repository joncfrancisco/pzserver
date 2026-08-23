variable "name_prefix" { type = string }
variable "stack" { type = string }
variable "region" { type = string }
variable "availability_zone" { type = string }
variable "subnet_id" { type = string }
variable "security_group_id" { type = string }

variable "instance_type" { type = string }
variable "root_volume_gb" { type = number }
variable "data_volume_gb" { type = number }

variable "server_name" { type = string }
variable "xmx" { type = string }
variable "idle_warn_minutes" { type = number }
variable "idle_timeout_minutes" { type = number }
variable "session_cap_hours" { type = number }
variable "monthly_budget_usd" { type = number }

variable "backup_bucket_arn" { type = string }
variable "backup_bucket_name" { type = string }
variable "ssm_prefix" { type = string }
variable "alert_topic_arn" { type = string }
