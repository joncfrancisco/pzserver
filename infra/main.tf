# Project Zomboid dedicated server -- root module.
#
# Wires the six child modules together. Read DESIGN.md section 4 for the architecture and
# INFRA.md for how this coexists with foodblog in the shared account 020949219706.

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "pz-${var.stack}"

  # Every SSM parameter this stack reads lives under this path. Values are put out of
  # band (see DEPLOY.md); Terraform manages only the IAM access to the path, never the
  # secrets themselves -- a `data "aws_ssm_parameter"` lookup would pull plaintext into
  # state, which is why there is not one anywhere in this repo.
  ssm_prefix = "/pz/${var.stack}"
}

module "network" {
  source = "./modules/network"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  public_subnet_cidr = var.public_subnet_cidr
  availability_zone  = var.availability_zone
  public_server      = var.public_server
}

module "backups" {
  source = "./modules/backups"

  name_prefix = local.name_prefix
  stack       = var.stack
  account_id  = data.aws_caller_identity.current.account_id
}

module "game_server" {
  source = "./modules/game-server"

  name_prefix       = local.name_prefix
  stack             = var.stack
  region            = var.region
  availability_zone = var.availability_zone
  subnet_id         = module.network.public_subnet_id
  security_group_id = module.network.game_security_group_id

  instance_type  = var.game_instance_type
  root_volume_gb = var.root_volume_gb
  data_volume_gb = var.data_volume_gb

  server_name          = var.server_name
  xmx                  = var.game_xmx
  idle_warn_minutes    = var.idle_warn_minutes
  idle_timeout_minutes = var.idle_timeout_minutes
  session_cap_hours    = var.session_cap_hours

  backup_bucket_arn  = module.backups.bucket_arn
  backup_bucket_name = module.backups.bucket_name
  ssm_prefix         = local.ssm_prefix
  alert_topic_arn    = aws_sns_topic.alerts.arn
}

module "bot_host" {
  source = "./modules/bot-host"

  name_prefix       = local.name_prefix
  stack             = var.stack
  region            = var.region
  subnet_id         = module.network.public_subnet_id
  security_group_id = module.network.bot_security_group_id
  instance_type     = var.bot_instance_type

  backup_bucket_arn  = module.backups.bucket_arn
  backup_bucket_name = module.backups.bucket_name
  ssm_prefix         = local.ssm_prefix
  alert_topic_arn    = aws_sns_topic.alerts.arn
}

module "dns" {
  source = "./modules/dns"

  zone_id   = var.route53_zone_id
  label     = var.dns_label
  target_ip = module.game_server.public_ip
}

module "observability" {
  source = "./modules/observability"

  name_prefix        = local.name_prefix
  stack              = var.stack
  game_instance_id   = module.game_server.instance_id
  data_volume_id     = module.game_server.data_volume_id
  monthly_budget_usd = var.monthly_budget_usd
  alert_topic_arn    = aws_sns_topic.alerts.arn
}
