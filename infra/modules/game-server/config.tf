# Runtime configuration for the host, in Parameter Store.
#
# This exists because of DESIGN C6: user_data runs once and never again, so anything
# baked into it at first boot is frozen forever on a box that is stopped and started
# rather than replaced. Putting the knobs in SSM instead means `pz-config.service`
# (a boot-time oneshot) re-renders /etc/pz/env on EVERY start, so changing `game_xmx`
# in prod.tfvars takes effect on the next `/pz start` with no reprovisioning.
#
# These are plain String parameters, not SecureString: none of them are secrets. The
# secrets -- RCON password, PZ admin password, Discord token, role IDs -- live under the
# same prefix but are created out of band with `aws ssm put-parameter` and never appear
# in Terraform state. See DEPLOY.md.

locals {
  host_config = {
    "config/stack"             = var.stack
    "config/region"            = var.region
    "config/server_name"       = var.server_name
    "config/xmx"               = var.xmx
    "config/idle_warn_min"     = tostring(var.idle_warn_minutes)
    "config/idle_timeout_min"  = tostring(var.idle_timeout_minutes)
    "config/session_cap_hours" = tostring(var.session_cap_hours)
    "config/down_timeout_min"  = tostring(var.down_timeout_minutes)
    "config/backup_bucket"     = var.backup_bucket_name
    "config/alert_topic_arn"   = var.alert_topic_arn

    # Read by the BOT, not by the host -- but it belongs here because /pz/<stack>/config/
    # is the shared config tree both sides read, and splitting it across two prefixes for
    # the sake of module tidiness would be worse. The bot gates player-tier `/pz start`
    # on month-to-date spend against this number (DESIGN section 12's third cost-control
    # layer), so it has to see the same value the Budgets resource was created with.
    "config/monthly_budget_usd" = tostring(var.monthly_budget_usd)
  }
}

resource "aws_ssm_parameter" "host_config" {
  for_each = local.host_config

  name  = "${var.ssm_prefix}/${each.key}"
  type  = "String"
  value = each.value

  tags = { Name = "${var.name_prefix}-${replace(each.key, "/", "-")}" }
}
