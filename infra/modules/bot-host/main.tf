# The always-on host that holds the Discord gateway connection.
#
# It exists because `/pz start` has to work while the game server is powered off, which
# is the entire point of the design (DESIGN G3). At ~$3.07/month it is the cheapest way
# to have a persistent WebSocket, and being persistent means no 3-second interaction
# deadline and somewhere to stream progress from.
#
# THIS MODULE PROVISIONS THE HOST, NOT THE BOT. The Python lives in the pzbot repo; see
# `terraform output bot_contract` for the values it needs and INFRA.md "The pzbot
# handoff" for the boundary.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# AL2023 arm64 here rather than Ubuntu: Graviton is fine for pure Python (DESIGN C1
# constrains only the game server), the SSM agent is native rather than a snap, and on a
# 512 MB nano the smaller base image is worth having.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.*-arm64"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_instance" "bot" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.bot.name

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
    tags        = { Name = "${var.name_prefix}-bot-root" }
  }

  user_data = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    dnf install -y python3.12 python3.12-pip git
    id pzbot >/dev/null 2>&1 || useradd --system --create-home --shell /usr/sbin/nologin pzbot
    install -d -o pzbot -g pzbot /opt/pzbot
    # The application is deployed from the pzbot repo. Nothing further happens here.
  EOT

  tags = {
    Name       = "${var.name_prefix}-bot"
    "pz:role"  = "bot"
    "pz:stack" = var.stack
  }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

# The bot host is always on, so its address is stable anyway -- but an EIP means a
# rebuild does not change it, and it keeps the instance reachable over SSM without
# depending on a public IP being auto-assigned.
resource "aws_eip" "bot" {
  domain   = "vpc"
  instance = aws_instance.bot.id
  tags     = { Name = "${var.name_prefix}-bot-eip" }
}
