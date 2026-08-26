variable "name_prefix" { type = string }
variable "stack" { type = string }
variable "region" { type = string }
variable "subnet_id" { type = string }
variable "security_group_id" { type = string }
variable "instance_type" { type = string }
variable "backup_bucket_arn" { type = string }
variable "backup_bucket_name" { type = string }
variable "ssm_prefix" { type = string }
variable "alert_topic_arn" { type = string }

variable "ssm_document_arns" {
  description = "ARNs of the scoped SSM documents the bot may invoke (issue #29). Additive alongside AWS-RunShellScript until pzbot switches over."
  type        = list(string)
}

variable "enable_bot_heartbeat_alarm" {
  description = <<-EOT
    Alarm when the bot stops publishing PZ/BotAlive. Leave false until pzbot's heartbeat
    change is deployed -- the alarm treats missing data as breaching, which is the point,
    but means it pages continuously against a metric that does not exist yet. Verify with
    `aws cloudwatch list-metrics --namespace PZ --metric-name BotAlive` before flipping.
  EOT
  type        = bool
  default     = false
}
