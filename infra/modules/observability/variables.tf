variable "name_prefix" { type = string }
variable "stack" { type = string }
variable "region" { type = string }
variable "game_instance_id" { type = string }
variable "data_volume_id" { type = string }
variable "monthly_budget_usd" { type = number }
variable "alert_topic_arn" { type = string }

# The quiet destination. Emergencies go to alert_topic_arn; everything else is recorded
# here and read on demand by bin/pz-audit.sh. See infra/alerts.tf for why the split
# exists and how to decide which one a new signal belongs on.
variable "audit_log_group_arn" { type = string }
