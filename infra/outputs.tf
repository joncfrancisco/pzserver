output "connect_string" {
  description = "What you paste into the Project Zomboid client. Stable forever: the A record points at an Elastic IP, so it is written once at apply time and never on boot."
  value       = "${module.dns.fqdn}:16261"
}

output "game_public_ip" {
  description = "Elastic IP. The DNS record above is the address to hand out; this is here for debugging and for the PZ client's fallback IP field."
  value       = module.game_server.public_ip
}

output "game_instance_id" {
  value = module.game_server.instance_id
}

output "bot_instance_id" {
  value = module.bot_host.instance_id
}

output "data_volume_id" {
  description = "THE WORLD. prevent_destroy is on; see INFRA.md before doing anything to this."
  value       = module.game_server.data_volume_id
}

output "backup_bucket" {
  value = module.backups.bucket_name
}

output "alert_topic_arn" {
  description = "SNS topic the bot subscribes to in order to mirror CloudWatch and Budgets alerts into Discord."
  value       = aws_sns_topic.alerts.arn
}

output "ssm_prefix" {
  description = "Parameter Store path holding the Discord token, RCON password and role IDs. Values are put here out of band -- never by Terraform."
  value       = "/pz/${var.stack}"
}

output "bot_contract" {
  description = "Everything the pzbot repo needs in order to configure itself. Feed this to the bot host's environment."
  value = {
    region           = var.region
    stack            = var.stack
    game_instance_id = module.game_server.instance_id
    game_private_ip  = module.game_server.private_ip
    connect_host     = module.dns.fqdn
    rcon_port        = 27015
    ssm_prefix       = "/pz/${var.stack}"
    backup_bucket    = module.backups.bucket_name
    alert_topic_arn  = aws_sns_topic.alerts.arn
    metric_namespace = "PZ"
  }
}
