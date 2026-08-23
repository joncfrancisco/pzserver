variable "name_prefix" { type = string }
variable "stack" { type = string }
variable "region" { type = string }
variable "alert_topic_arn" { type = string }

variable "webhook_parameter" {
  description = <<-EOT
    SSM parameter (SecureString) holding the Discord webhook URL the relay posts to.
    Terraform manages only the NAME and the IAM access -- the value is put out of band,
    the same rule the rest of this stack follows for secrets. Create it with:

      aws ssm put-parameter --name /pz/prod/discord/alert_webhook \
        --type SecureString --value 'https://discord.com/api/webhooks/...'
  EOT
  type        = string
}
