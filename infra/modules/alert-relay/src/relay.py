"""SNS -> Discord webhook.

DESIGN section 15 says "everything routes to SNS; the bot subscribes and mirrors into
Discord. Discord is the pager." Nothing ever subscribed. `alert_topic_arn` reached the
bot's Config dataclass and was never read again, so every CloudWatch alarm, every
EventBridge state change, every Budgets threshold and the watchdog's own "shutting down in
5 minutes" notice resolved to a single email.

This is a Lambda rather than a poller inside the bot on purpose. The alert you most need
delivered is "the bot host is down", and a bot cannot page you about its own host. This
keeps working when the bot does not, needs no inbound port on sg-bot (which has
deliberately zero inbound rules, so an SNS HTTPS push was never an option either), and
costs effectively nothing at this volume.

No dependencies: urllib.request is in the standard library, so the deployment package is
this one file and there is no build step to get wrong.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request

log = logging.getLogger()
log.setLevel(logging.INFO)

WEBHOOK_PARAM = os.environ["WEBHOOK_PARAM"]
STACK = os.environ.get("STACK", "prod")

# Discord's own palette, so these read the same as the bot's embeds.
RED = 0xED4245
GREEN = 0x3BA55D
YELLOW = 0xFAA61A
GREY = 0x4F545C

_webhook: str | None = None


def _webhook_url() -> str:
    """Read the webhook out of Parameter Store, once per container.

    Not a Lambda environment variable: the URL is a bearer credential -- anyone holding it
    can post into the channel -- and env vars are visible to anyone with
    lambda:GetFunctionConfiguration. Terraform never sees it either, which is the same
    rule the rest of this repo follows (there is no `data "aws_ssm_parameter"` anywhere).
    """
    global _webhook
    if _webhook is None:
        import boto3  # provided by the Lambda runtime; imported late to keep cold start cheap

        ssm = boto3.client("ssm")
        _webhook = ssm.get_parameter(Name=WEBHOOK_PARAM, WithDecryption=True)["Parameter"]["Value"]
    return _webhook


def _alarm_embed(alarm: dict) -> dict:
    """A CloudWatch alarm notification."""
    state = alarm.get("NewStateValue", "UNKNOWN")
    colour = {"ALARM": RED, "OK": GREEN, "INSUFFICIENT_DATA": YELLOW}.get(state, GREY)
    name = alarm.get("AlarmName", "unknown alarm")

    fields = [{"name": "State", "value": state, "inline": True}]
    if previous := alarm.get("OldStateValue"):
        fields.append({"name": "Was", "value": previous, "inline": True})

    # The reason string carries the actual numbers -- "Threshold Crossed: 1 datapoint
    # [0.0] was less than the threshold (1.0)" -- which is the part worth reading.
    reason = alarm.get("NewStateReason", "")

    return {
        "title": f"{'🔴' if state == 'ALARM' else '🟢' if state == 'OK' else '🟡'}  {name}",
        "description": (alarm.get("AlarmDescription") or "")[:400] or None,
        "colour": colour,
        "fields": fields,
        "footer": reason[:2000],
    }


def _state_change_embed(detail: dict) -> dict:
    """An EventBridge EC2 instance state change."""
    state = detail.get("state", "?")
    colour = {"running": GREEN, "stopped": GREY, "terminated": RED}.get(state, YELLOW)
    return {
        "title": f"🖥️  Instance {state}",
        "description": None,
        "colour": colour,
        "fields": [{"name": "Instance", "value": detail.get("instance-id", "?"), "inline": True}],
        "footer": "",
    }


def _plain_embed(subject: str, message: str) -> dict:
    """Anything else: Budgets, and the watchdog's own `aws sns publish` calls.

    Budgets sends prose rather than JSON, and the watchdog sends a subject line and a
    sentence. Both are already written to be read by a human, so they are passed through
    rather than parsed.
    """
    lowered = f"{subject} {message}".lower()
    if any(word in lowered for word in ("fail", "unreachable", "exceed", "stop failed")):
        colour = RED
    elif any(word in lowered for word in ("warning", "budget", "shutting down")):
        colour = YELLOW
    else:
        colour = GREY
    return {
        "title": f"📣  {subject or 'PZ alert'}"[:250],
        "description": message[:1800] or None,
        "colour": colour,
        "fields": [],
        "footer": "",
    }


def _render(subject: str, message: str) -> dict:
    """Work out which of the four shapes this is, and never fail because of it."""
    try:
        payload = json.loads(message)
    except (TypeError, ValueError):
        return _plain_embed(subject, message)

    if not isinstance(payload, dict):
        return _plain_embed(subject, message)

    if "NewStateValue" in payload and "AlarmName" in payload:
        return _alarm_embed(payload)
    if payload.get("detail-type") == "EC2 Instance State-change Notification":
        return _state_change_embed(payload.get("detail", {}))

    # Valid JSON of an unrecognised shape. Show it rather than swallowing it -- an alert
    # nobody can read still beats an alert nobody receives.
    return _plain_embed(subject, json.dumps(payload, indent=2))


def _post(embed: dict) -> None:
    body = {
        "username": f"PZ {STACK}",
        "embeds": [
            {
                "title": embed["title"],
                **({"description": embed["description"]} if embed["description"] else {}),
                "color": embed["colour"],
                **({"fields": embed["fields"]} if embed["fields"] else {}),
                **({"footer": {"text": embed["footer"][:2000]}} if embed["footer"] else {}),
            }
        ],
    }
    request = urllib.request.Request(
        _webhook_url(),
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "pz-alert-relay/1"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        log.info("discord returned %s", response.status)


def handler(event, _context):
    """One SNS event can carry several records; each becomes its own message.

    A failure here is raised, not swallowed. Lambda retries an async invocation twice and
    then sends it to the configured destination -- and a relay that quietly returned 200
    on a broken webhook would be the pager silently not working, which is the exact class
    of bug this whole change exists to fix.
    """
    for record in event.get("Records", []):
        sns = record.get("Sns", {})
        subject = sns.get("Subject") or ""
        message = sns.get("Message") or ""
        log.info("relaying subject=%r bytes=%d", subject, len(message))
        try:
            _post(_render(subject, message))
        except urllib.error.HTTPError as exc:
            # 404 means the webhook was deleted in Discord. Worth its own line, because
            # the fix is "make a new webhook and put-parameter it", not "debug the relay".
            log.error("discord rejected the post: %s %s", exc.code, exc.read()[:500])
            raise
    return {"ok": True}
