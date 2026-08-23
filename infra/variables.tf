variable "region" {
  description = "AWS region. Choose for player latency, not price (DESIGN Q3)."
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = <<-EOT
    Single AZ for the whole stack. us-east-1a matches where the foodblog Lightsail
    instance lives -- purely cosmetic consistency, the two share no network.
  EOT
  type        = string
  default     = "us-east-1a"
}

variable "stack" {
  description = "Stack name. Tags, SSM parameter paths, S3 prefixes and the DNS record all derive from this. One stack == one PZ world."
  type        = string
  default     = "prod"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,20}$", var.stack))
    error_message = "stack must be lowercase alphanumeric/hyphen, <= 20 chars (it becomes a DNS label and an SSM path segment)."
  }
}

variable "vpc_cidr" {
  description = "CIDR for the stack's own VPC. us-east-1 has NO default VPC in this account (verified 2026-08-22), so this stack brings its own."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.20.1.0/24"
}

# --- Game server ------------------------------------------------------------------

variable "game_instance_type" {
  description = <<-EOT
    MUST be x86_64 (DESIGN C1: PZ ships native x86 .so files) and should favour clock
    speed over core count (C2). Changing this is a stop -> modify -> start, ~2 min of
    downtime, no data movement. Remember to move `game_xmx` with it.
  EOT
  type        = string
  default     = "m7i.xlarge"
}

variable "game_xmx" {
  description = <<-EOT
    JVM max heap for the PZ server, e.g. "11g". Rule of thumb: instance RAM minus ~4 GiB
    for OS + page cache. The host asserts at boot that this is <= 75% of MemTotal and
    refuses to start otherwise (see ops/bin/pz-preflight.sh) -- leaving this at the JVM
    default is the single most common way to OOM a PZ server with RAM still free (C3).

    Size against MemTotal, not the marketing number: a "16 GiB" m7i.xlarge reports
    15703 MiB, so the 75% ceiling is 11777 MiB and 12g does not fit.
  EOT
  type        = string
  default     = "12g"

  validation {
    condition     = can(regex("^[0-9]+[mMgG]$", var.game_xmx))
    error_message = "game_xmx must look like 12g or 12288m."
  }
}

variable "root_volume_gb" {
  description = "OS + SteamCMD + PZ binaries. Rebuildable; not the world."
  type        = number
  default     = 30
}

variable "data_volume_gb" {
  description = "THE WORLD. Mounted at /opt/pz/data, DeleteOnTermination=false, prevent_destroy=true."
  type        = number
  default     = 30
}

variable "server_name" {
  description = "PZ server name. Determines the .ini filename and the save directory name under Saves/Multiplayer/. Changing it after first boot orphans the existing world."
  type        = string
  default     = "pzprod"
}

variable "public_server" {
  description = <<-EOT
    false (default): server is direct-connect only; only UDP 16261-16262 is open.
    true: also opens UDP 8766-8767 so the server can list in the in-game public browser.
    Only flip this if you actually set Public=true in the server .ini -- otherwise it
    opens two ports to the internet for nothing.
  EOT
  type        = bool
  default     = false
}

# --- Cost control -----------------------------------------------------------------

variable "idle_warn_minutes" {
  description = "Minutes at ZERO players before the watchdog broadcasts a shutdown warning."
  type        = number
  default     = 25
}

variable "idle_timeout_minutes" {
  description = "Minutes at ZERO players before the watchdog saves, backs up and stops the instance. Must be > idle_warn_minutes."
  type        = number
  default     = 30

  validation {
    condition     = var.idle_timeout_minutes > 0
    error_message = "idle_timeout_minutes must be positive. To disable idle shutdown, set it very high -- do not set 0, which would stop the server instantly."
  }
}

variable "session_cap_hours" {
  description = "Maximum continuous runtime before the standard stop sequence runs anyway. Catches a character left idling in a safehouse overnight (DESIGN 12)."
  type        = number
  default     = 12
}

variable "monthly_budget_usd" {
  description = <<-EOT
    Monthly cap for THIS STACK ONLY (Budgets filtered on the pz:stack tag). This does
    not replace, and is not affected by, the account-wide "Safety Net" budget -- see
    INFRA.md "Budgets: the collision". ~$37 is the DESIGN estimate at 4 hr/day.
  EOT
  type        = number
  default     = 45
}

variable "budget_notification_emails" {
  description = "Addresses subscribed to the SNS alert topic. The bot subscribes to the same topic and mirrors alerts into Discord; email is the backstop for when the bot host is the thing that is down."
  type        = list(string)
  default     = []
}

# --- DNS --------------------------------------------------------------------------

variable "route53_zone_id" {
  description = <<-EOT
    Hosted zone for joncfrancis.co, created by the Route53 registrar and shared with
    foodblog (apex + www A records point at the Lightsail box). This stack reads the
    zone as a DATA source and manages exactly one record inside it -- it never owns the
    zone, so `terraform destroy` here cannot take the blog's DNS down with it.
  EOT
  type        = string
  default     = "Z02575211T1QV3GILBPJH"
}

variable "dns_label" {
  description = "Subdomain for the game server, joined to the zone name. Default yields pz.joncfrancis.co."
  type        = string
  default     = "pz"
}

# --- Bot host ---------------------------------------------------------------------

variable "bot_instance_type" {
  description = "Graviton is fine here -- the bot is pure Python and C1 does not apply to it."
  type        = string
  default     = "t4g.nano"
}
