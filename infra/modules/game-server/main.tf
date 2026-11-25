# The game server: one x86_64 instance that is STOPPED by default, one EBS data volume
# that holds the world, one Elastic IP, and the ops tree that provisions it.

# Ubuntu 24.04 LTS rather than AL2023. Two reasons: SteamCMD is a 32-bit binary and
# Ubuntu's `lib32gcc-s1` is the documented, universally-trodden dependency for PZ
# dedicated servers; and it matches the OS already running foodblog, so there is one
# less Linux to keep in your head. Looked up as an AMI rather than via
# `data "aws_ssm_parameter"` -- this repo does not use that data source anywhere (it
# would pull SecureString plaintext into state, and consistency is cheaper than a
# special case).
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# --- The ops tree ------------------------------------------------------------------
#
# Provisioning assets are shipped to S3 and pulled down by the instance, rather than
# stuffed into user_data (which is capped at 16 KB and, per DESIGN C6, runs exactly
# once). Keeping them in S3 means re-provisioning is one `ssm send-command` away, and
# promoting this to a Packer build in Phase 5 is a matter of running the same script at
# bake time instead of boot time.
resource "aws_s3_object" "ops" {
  for_each = fileset("${path.module}/../../../ops", "**")

  bucket = var.backup_bucket_name
  key    = "ops/${each.value}"
  source = "${path.module}/../../../ops/${each.value}"
  etag   = filemd5("${path.module}/../../../ops/${each.value}")
}

# --- Compute -----------------------------------------------------------------------

resource "aws_instance" "game" {
  count = var.enabled ? 1 : 0

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.game.name
  availability_zone      = var.availability_zone

  # ACPI shutdown, so an `ec2:StopInstances` from anywhere -- the bot, the watchdog, the
  # console -- reaches systemd, which reaches pzserver.service's ExecStop, which saves
  # the world. This is the mechanism behind G5.
  instance_initiated_shutdown_behavior = "stop"

  # The world itself is safe without this: the data volume is prevent_destroy and its
  # attachment leaves DeleteOnTermination at the default of false. What a termination
  # would take is the root volume, the provisioned state, and an afternoon. This is a
  # SHARED account with seven IAM users and console access, so the same reasoning that
  # justified prevent_destroy one layer down applies here, and it is free.
  #
  # It does not impede any normal operation -- stop/start is unaffected, and the bot has
  # no ec2:TerminateInstances at all. A deliberate teardown clears it first; see
  # DEPLOY.md "Tearing the stack down".
  disable_api_termination = true

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
    # Lets pz-config-refresh.sh read its own pz:stack tag straight from IMDS and work
    # out which Parameter Store path it owns, with no API call and nothing baked in at
    # first boot. It falls back to ec2:DescribeTags if this is ever turned off.
    instance_metadata_tags = "enabled"
  }

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true # OS + SteamCMD + PZ binaries; all rebuildable
    tags                  = { Name = "${var.name_prefix}-root" }
  }

  user_data = templatefile("${path.module}/userdata.sh.tftpl", {
    bucket = var.backup_bucket_name
    region = var.region
  })

  # Changing user_data would otherwise force a replacement, which would take the root
  # volume with it. Provisioning changes ship by re-running provision.sh over SSM
  # instead -- see DEPLOY.md "Re-provisioning".
  user_data_replace_on_change = false

  tags = {
    Name       = "${var.name_prefix}-game"
    "pz:role"  = "gameserver"
    "pz:stack" = var.stack
  }

  # The world lives on a separate volume, but a replacement still means a full rebuild.
  # Make it a deliberate act.
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [aws_s3_object.ops]
}

resource "aws_eip" "game" {
  count = var.enabled ? 1 : 0

  domain   = "vpc"
  instance = aws_instance.game[0].id

  tags = { Name = "${var.name_prefix}-eip" }
}

# --- The world ---------------------------------------------------------------------
#
# The stack was wound down on 2026-10-22, and in the November 2026 cleanup the world volume
# (vol-09e3f5065531b0ccb) and its DLM snapshot policy were removed to stop paying for
# them. The world now lives only in the two `keep=forever` archive snapshots and the S3
# archive copy -- see DEPLOY.md "WOUND DOWN".
#
# The volume is no longer a Terraform resource. On a restart, create a volume from the
# final archive snapshot by hand, in var.availability_zone, tagged `pz:role =
# gameserver-data`, and pass its id as `data_volume_id`. Until then this attachment does
# not exist. Managing a volume created from a snapshot here would mean a new resource
# with `snapshot_id`, which is a decision for the restart, not for the wind-down.

resource "aws_volume_attachment" "data" {
  count = var.enabled && var.data_volume_id != null ? 1 : 0

  device_name = "/dev/sdf"
  volume_id   = var.data_volume_id
  instance_id = aws_instance.game[0].id

  # On Nitro this surfaces as /dev/nvme1n1, and the number is not guaranteed stable, so
  # nothing on the host mounts by device path -- provision.sh labels the filesystem
  # `pzdata` and the mount unit uses /dev/disk/by-label/pzdata.
  stop_instance_before_detaching = true
}
