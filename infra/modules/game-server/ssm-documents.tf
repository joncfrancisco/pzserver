# --- Scoped SSM documents for the bot (issue #29) --------------------------------------
#
# Phase 1 of closing the AWS-RunShellScript gap: give the bot a small, enumerated set of
# documents with typed, pattern-constrained parameters, so the document itself is the
# allowlist -- enforced by AWS, not by `shlex.quote` in pzbot. SSM substitutes `{{ Param }}`
# as raw text into the shell command list; it does not shell-quote for you, so every
# `allowedPattern` below is chosen to exclude shell metacharacters, not just to validate
# shape.
#
# This is additive: pz-bot-role still has its AWS-RunShellScript grant until pzbot's
# companion issue switches every call site over to these documents and that grant is
# removed in a follow-up change.

locals {
  # Mirrors pzbot's INI_KEYS table (src/pzbot/server.py) -- the allowlist `/pz config`
  # may read or write. Keep the two in sync by hand; this list governs what the
  # config-read/config-write documents will touch regardless of what pzbot sends.
  ini_keys = [
    "PublicName", "PublicDescription", "ServerWelcomeMessage", "MaxPlayers",
    "PauseEmpty", "GlobalChat", "PVP", "SafetySystem", "SleepAllowed",
    "DisplayUserName", "NoFire", "AnnounceDeath",
  ]
  ini_path = "/opt/pz/data/Zomboid/Server/${var.server_name}.ini"
}

resource "aws_ssm_document" "backup" {
  name            = "${var.name_prefix}-backup"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Run pz-backup.sh in prestop or manual mode."
    parameters = {
      mode = {
        type          = "String"
        description   = "prestop (before a stop) or manual (on demand)"
        allowedValues = ["prestop", "manual"]
      }
      label = {
        type           = "String"
        description    = "Optional label for a manual backup"
        default        = ""
        allowedPattern = "^[A-Za-z0-9_-]{0,40}$"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "runBackup"
      inputs = {
        timeoutSeconds = "1800"
        runCommand     = ["/opt/pz/bin/pz-backup.sh {{ mode }} {{ label }}"]
      }
    }]
  })
}

resource "aws_ssm_document" "restore" {
  name            = "${var.name_prefix}-restore"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Run pz-restore.sh against one backup this stack produced."
    parameters = {
      backupName = {
        type        = "String"
        description = "A backup name produced by this stack's backup tiers"
        # Mirrors pzbot's BACKUP_NAME regex (server.py) exactly.
        allowedPattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z__(scheduled|prestop|prerestore|manual)(__[A-Za-z0-9_-]{1,40})?\\.tar\\.zst$"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "runRestore"
      inputs = {
        timeoutSeconds = "3600"
        runCommand     = ["/opt/pz/bin/pz-restore.sh {{ backupName }} --yes"]
      }
    }]
  })
}

resource "aws_ssm_document" "lifecycle" {
  name            = "${var.name_prefix}-lifecycle"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Start, stop, or restart pzserver.service."
    parameters = {
      action = {
        type          = "String"
        description   = "systemctl action to take on pzserver.service"
        allowedValues = ["start", "stop", "restart"]
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "runLifecycle"
      inputs = {
        timeoutSeconds = "300"
        runCommand     = ["systemctl {{ action }} pzserver.service"]
      }
    }]
  })
}

resource "aws_ssm_document" "config_read" {
  name            = "${var.name_prefix}-config-read"
  document_type   = "Command"
  document_format = "JSON"

  # No parameters: the .ini path and the readable key allowlist are fixed by Terraform,
  # not by the caller, so there is nothing here for a bad parameter to widen.
  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Read the allowlisted .ini keys for this stack's server."
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "readIni"
      inputs = {
        timeoutSeconds = "60"
        runCommand = [
          "grep -E '^(${join("|", local.ini_keys)})=' ${local.ini_path} || true",
        ]
      }
    }]
  })
}

resource "aws_ssm_document" "config_write" {
  name            = "${var.name_prefix}-config-write"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Set one allowlisted .ini key for this stack's server."
    parameters = {
      key = {
        type           = "String"
        description    = "An INI_KEYS name from pzbot"
        allowedPattern = "^[A-Za-z]{1,40}$"
      }
      value = {
        type = "String"
        # No `=` (would split the key) and no newline (would inject a second .ini
        # line) -- mirrors pzbot's IniKey.clean rule for text values. 300, not 200:
        # ServerWelcomeMessage's max_len is 300 and this must be a superset of every
        # INI_KEYS entry's own bound, not just the common case.
        allowedPattern = "^[^\\n=]{0,300}$"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "writeIni"
      inputs = {
        timeoutSeconds = "60"
        runCommand     = ["python3 /opt/pz/bin/pz-ini-tool.py ${local.ini_path} {{ key }} {{ value }}"]
      }
    }]
  })
}

resource "aws_ssm_document" "sandbox" {
  name            = "${var.name_prefix}-sandbox"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Read or set one SandboxVars.lua option for this stack's world."
    parameters = {
      action = {
        type          = "String"
        allowedValues = ["get", "set"]
      }
      path = {
        type           = "String"
        description    = "Absolute path to this stack's SandboxVars.lua"
        allowedPattern = "^/opt/pz/data/Zomboid/Server/[A-Za-z0-9_-]{1,64}_SandboxVars\\.lua$"
      }
      key = {
        type           = "String"
        description    = "Dotted sandbox setting path (ignored for action=get)"
        default        = ""
        allowedPattern = "^[A-Za-z0-9_.]{0,80}$"
      }
      value = {
        type           = "String"
        description    = "Lua literal to write (ignored for action=get)"
        default        = ""
        allowedPattern = "^(true|false|-?[0-9]+(\\.[0-9]+)?)?$"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "runSandbox"
      inputs = {
        timeoutSeconds = "60"
        runCommand     = ["python3 /opt/pz/bin/pz-sandbox-tool.py {{ action }} {{ path }} {{ key }} {{ value }}"]
      }
    }]
  })
}

resource "aws_ssm_document" "idle_retune" {
  name            = "${var.name_prefix}-idle-retune"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Retune the watchdog's idle timeout for the current session."
    parameters = {
      timeoutMin = {
        type           = "String"
        allowedPattern = "^[0-9]{1,4}$"
      }
      warnMin = {
        type           = "String"
        allowedPattern = "^[0-9]{1,4}$"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "retuneIdle"
      inputs = {
        timeoutSeconds = "60"
        runCommand = [
          "set -e",
          "sed -i -E 's/^PZ_IDLE_TIMEOUT_MIN=.*/PZ_IDLE_TIMEOUT_MIN={{ timeoutMin }}/' /etc/pz/env",
          "sed -i -E 's/^PZ_IDLE_WARN_MIN=.*/PZ_IDLE_WARN_MIN={{ warnMin }}/' /etc/pz/env",
          "rm -f /var/lib/pz/idle-warned /var/lib/pz/idle-minutes",
          "grep -E '^PZ_IDLE' /etc/pz/env",
        ]
      }
    }]
  })
}
