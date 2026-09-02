#!/usr/bin/env python3
"""Workshop mods: what this world loads, in what order, and where each one came from.

Runs on the game server, invoked by the `pz-<stack>-mods` SSM document with a fixed
command line and pattern-constrained parameters -- so `workshopId` and `modIds` arrive as
plain argv, never as text interpolated into a shell string. Same rule as
`pz-ini-tool.py` and `pz-sandbox-tool.py`, and the same reason.

The awkward part of PZ mod management, and the reason this is a tool rather than two more
`INI_KEYS` entries, is that the `.ini` holds **two** parallel lists that mean different
things and are not one-to-one:

    WorkshopItems=2169435993;2392709985      what the server DOWNLOADS from Steam
    Mods=Authentic_Z;AuthenticZ_Clothing     what the game LOADS, in load order

One Workshop item can ship several mods, and a mod id is not derivable from a Workshop id
without looking at the downloaded item. So removing "that armour mod" means knowing which
`Mods=` entries came from which Workshop id -- an association the `.ini` does not record
and which is lost the moment somebody edits either list by hand.

This tool keeps that association in a sidecar manifest next to the `.ini`. The manifest is
BOOKKEEPING, never authority: the `.ini` is what the game reads, so every action re-reads
it and reconciles, and an entry the manifest has never heard of is reported rather than
quietly dropped. Living in `Server/` also means it is inside the backup set (`Saves/` +
`Server/` + `db/`), so a restore brings back the mod list and its provenance together with
the world that needs them.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import shutil
import sys

# Steam's app id for the Workshop content, which is the GAME's id (108600), not the
# dedicated server's (380870). The server downloads items under the cachedir it was
# started with, which pz-start-server.sh points at the data volume.
# PZ_WORKSHOP_ROOTS overrides them, colon-separated. Not a knob anything sets in
# production -- it is what makes discover() testable off the game server.
WORKSHOP_ROOTS = tuple(
    os.environ.get(
        "PZ_WORKSHOP_ROOTS",
        "/opt/pz/data/Zomboid/steamapps/workshop/content/108600"
        ":/opt/pz/data/Zomboid/Workshop",
    ).split(":")
)

WORKSHOP_ID = re.compile(r"^[0-9]{1,12}$")
MOD_ID = re.compile(r"^[A-Za-z0-9_.\-]{1,64}$")


class ModError(Exception):
    """Refusal, with a message meant to end up in front of whoever typed the command."""


def _now() -> str:
    stamp = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    return stamp.replace("+00:00", "Z")


# --- The .ini's two lists ---------------------------------------------------------------


def read_list(text: str, key: str) -> list[str]:
    """The values of one semicolon-separated .ini key, in file order.

    Order is preserved because for `Mods=` it is load order, and load order is the
    difference between a working mod list and a server that will not start.
    """
    for line in text.splitlines():
        name, sep, value = line.partition("=")
        if sep and name.strip() == key:
            return [item.strip() for item in value.split(";") if item.strip()]
    return []


def write_list(text: str, key: str, values: list[str]) -> str:
    lines = text.splitlines()
    rendered = f"{key}=" + ";".join(values)
    for index, line in enumerate(lines):
        name, sep, _ = line.partition("=")
        if sep and name.strip() == key:
            lines[index] = rendered
            break
    else:
        lines.append(rendered)
    return "\n".join(lines) + "\n"


# --- Discovering what a Workshop item actually contains -----------------------------------


def discover(workshop_id: str) -> list[str]:
    """The mod ids inside a downloaded Workshop item, or [] if it is not on disk yet.

    The id the game wants is the `id=` line in `mod.info`, which is NOT reliably the
    directory name -- authors rename folders and the two drift. Falling back to the
    directory name is right for the older mods that omit the line entirely.
    """
    found: list[str] = []
    for root in WORKSHOP_ROOTS:
        mods_dir = os.path.join(root, workshop_id, "mods")
        if not os.path.isdir(mods_dir):
            continue
        for entry in sorted(os.listdir(mods_dir)):
            info = os.path.join(mods_dir, entry, "mod.info")
            mod_id = entry
            try:
                with open(info, encoding="utf-8", errors="replace") as handle:
                    for line in handle:
                        name, sep, value = line.partition("=")
                        if sep and name.strip().lower() == "id":
                            mod_id = value.strip()
                            break
            except OSError:
                pass
            if MOD_ID.fullmatch(mod_id) and mod_id not in found:
                found.append(mod_id)
    return found


# --- The sidecar manifest -----------------------------------------------------------------


def manifest_path(ini_path: str) -> str:
    stem, _ = os.path.splitext(ini_path)
    return f"{stem}_pzbot-mods.json"


def read_manifest(ini_path: str) -> dict[str, dict]:
    try:
        with open(manifest_path(ini_path), encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        # A missing or corrupt manifest costs provenance, not correctness: every action
        # reconciles against the .ini, which is the thing the game reads.
        return {}
    entries = data.get("entries") if isinstance(data, dict) else None
    if not isinstance(entries, list):
        return {}
    return {
        str(entry["workshop_id"]): {
            "mods": [m for m in entry.get("mods", []) if MOD_ID.fullmatch(str(m))],
            "added": str(entry.get("added", "")),
        }
        for entry in entries
        if isinstance(entry, dict) and WORKSHOP_ID.fullmatch(str(entry.get("workshop_id", "")))
    }


def render_manifest(entries: dict[str, dict]) -> str:
    return (
        json.dumps(
            {
                "entries": [
                    {"workshop_id": wid, "mods": body["mods"], "added": body["added"]}
                    for wid, body in entries.items()
                ]
            },
            indent=2,
        )
        + "\n"
    )


# --- Reconciliation -------------------------------------------------------------------------


def inventory(text: str, entries: dict[str, dict]) -> dict:
    """What the .ini says, joined with what the manifest remembers about it."""
    workshop = read_list(text, "WorkshopItems")
    mods = read_list(text, "Mods")

    listed = []
    attributed: set[str] = set()
    for wid in workshop:
        known = entries.get(wid)
        owned = [m for m in (known or {}).get("mods", []) if m in mods]
        attributed.update(owned)
        listed.append(
            {
                "workshop_id": wid,
                "mods": owned,
                "added": (known or {}).get("added", ""),
                # False means: in the .ini but not in the manifest, i.e. added by hand or
                # carried in from a restore of a world this bot never managed.
                "tracked": known is not None,
                # True means: downloaded, but its mods are not in Mods= -- it is listed
                # and inert. `scan` is what fixes this.
                "pending": not owned,
            }
        )

    return {
        "workshop_items": workshop,
        "mods": mods,
        "entries": listed,
        # Loaded, but not attributable to any listed Workshop item: a built-in mod, or the
        # leftovers of a Workshop item somebody removed from WorkshopItems= by hand.
        "unattributed_mods": [m for m in mods if m not in attributed],
    }


# --- Actions -----------------------------------------------------------------------------------


def add(
    text: str, entries: dict[str, dict], workshop_id: str, mod_ids: list[str]
) -> tuple[str, dict]:
    workshop = read_list(text, "WorkshopItems")
    mods = read_list(text, "Mods")

    if workshop_id in workshop:
        raise ModError(f"Workshop item {workshop_id} is already in this server's mod list.")

    discovered = False
    if not mod_ids:
        mod_ids = discover(workshop_id)
        discovered = True

    workshop.append(workshop_id)
    # Appended, so the newest mod loads last. PZ resolves conflicts in load order, and
    # "the one I just added wins" is both the conventional default and the only ordering
    # this tool can infer without being told.
    added_mods = [m for m in mod_ids if m not in mods]
    mods.extend(added_mods)

    text = write_list(text, "WorkshopItems", workshop)
    text = write_list(text, "Mods", mods)
    entries[workshop_id] = {
        "mods": mod_ids,
        "added": _now(),
    }

    return text, {
        "workshop_id": workshop_id,
        # Not "mods": the report is merged with inventory(), whose "mods" is the whole
        # Mods= line. Colliding on that key made an added item claim every mod on the
        # server as its own.
        "mods_added": mod_ids,
        "discovered": discovered,
        # Listed but inert: the server has not downloaded the item yet, so there is
        # nothing to read a mod id out of. It downloads on the next start; `scan` then
        # finishes the job. Saying so is the whole point -- a Workshop id in
        # WorkshopItems= with no matching Mods= entry is a mod that silently does nothing.
        "pending": not mod_ids,
    }


def remove(text: str, entries: dict[str, dict], workshop_id: str) -> tuple[str, dict]:
    workshop = read_list(text, "WorkshopItems")
    mods = read_list(text, "Mods")

    if workshop_id not in workshop and workshop_id not in entries:
        raise ModError(f"Workshop item {workshop_id} is not in this server's mod list.")

    # An item added by hand has no manifest record, so fall back to asking the downloaded
    # item what it contains. Better than leaving orphaned Mods= entries behind, which load
    # nothing and break the next start when the files go.
    owned = entries.get(workshop_id, {}).get("mods") or discover(workshop_id)

    removed = [m for m in owned if m in mods]
    text = write_list(text, "WorkshopItems", [w for w in workshop if w != workshop_id])
    text = write_list(text, "Mods", [m for m in mods if m not in removed])
    entries.pop(workshop_id, None)

    return text, {
        "workshop_id": workshop_id,
        "mods_removed": removed,
        # Nothing to remove and nothing on disk to ask: the Mods= entries this item
        # contributed, if any, are still loaded and have to be sorted out by hand.
        "unresolved": not owned,
    }


def scan(text: str, entries: dict[str, dict]) -> tuple[str, dict]:
    """Finish the job for items the server has downloaded since they were added."""
    workshop = read_list(text, "WorkshopItems")
    mods = read_list(text, "Mods")

    resolved, adopted, pending = [], [], []
    for wid in workshop:
        # Checked BEFORE setdefault, which would otherwise make every item look tracked.
        if wid not in entries:
            adopted.append(wid)
        entry = entries.setdefault(wid, {"mods": [], "added": ""})
        if entry["mods"] and all(m in mods for m in entry["mods"]):
            continue
        found = entry["mods"] or discover(wid)
        if not found:
            pending.append(wid)
            continue
        entry["mods"] = found
        new = [m for m in found if m not in mods]
        if new:
            mods.extend(new)
            resolved.append({"workshop_id": wid, "mods": new})

    text = write_list(text, "Mods", mods)
    return text, {"resolved": resolved, "adopted": adopted, "still_pending": pending}


# --- The half that touches the filesystem ------------------------------------------------------


def _read(target: str) -> str:
    try:
        with open(target, encoding="utf-8") as handle:
            return handle.read()
    except FileNotFoundError:
        raise ModError(
            f"{target} does not exist. The server has not written its .ini yet -- start it "
            "once and let it finish loading."
        ) from None


def _write(target: str, text: str, *, backup: bool) -> None:
    """Write in place, atomically, preserving ownership.

    Ownership matters for the same reason it does in pz-sandbox-tool.py: this runs as root
    over SSM, and a Server/ file owned by root is one the `pzuser` service account cannot
    rewrite when the game itself next writes it.
    """
    try:
        stat = os.stat(target)
        mode, uid, gid = stat.st_mode, stat.st_uid, stat.st_gid
        if backup:
            shutil.copy2(target, target + ".pzbot.bak")
    except FileNotFoundError:
        # The manifest on its first write. Match the .ini beside it rather than root's
        # umask, so the game's own account can read it.
        mode, uid, gid = 0o644, -1, -1

    tmp = target + ".pzbot.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.chmod(tmp, mode)
    if uid != -1:
        os.chown(tmp, uid, gid)
    os.replace(tmp, target)


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(
            "usage: pz-mod-tool.py <ini-path> list|add|remove|scan [workshop-id] [mod,ids]",
            file=sys.stderr,
        )
        return 2

    # Padded rather than indexed: the SSM document quotes every parameter so argc is
    # fixed, but a human running this by hand omits the trailing ones.
    args = (argv[3:] + ["", ""])[:2]
    ini_path, action = argv[1], argv[2]
    workshop_id, raw_mods = args[0].strip(), args[1].strip()

    try:
        text = _read(ini_path)
        entries = read_manifest(ini_path)

        if action == "list":
            print(json.dumps(inventory(text, entries)))
            return 0

        if action == "scan":
            text, report = scan(text, entries)
        elif action in ("add", "remove"):
            if not WORKSHOP_ID.fullmatch(workshop_id):
                raise ModError(
                    f"'{workshop_id}' is not a Steam Workshop id. It is the number at the "
                    "end of the item's Workshop URL."
                )
            if action == "add":
                mod_ids = [m.strip() for m in raw_mods.split(",") if m.strip()]
                for mod_id in mod_ids:
                    if not MOD_ID.fullmatch(mod_id):
                        raise ModError(f"'{mod_id}' is not a mod id.")
                text, report = add(text, entries, workshop_id, mod_ids)
            else:
                text, report = remove(text, entries, workshop_id)
        else:
            print(f"mods: unknown action {action!r}", file=sys.stderr)
            return 2

        # The .ini first: if the manifest write fails after it, the game still has a
        # coherent mod list and the next `list` reports the lost provenance rather than
        # loading something nobody asked for.
        _write(ini_path, text, backup=True)
        _write(manifest_path(ini_path), render_manifest(entries), backup=False)

        report.update(inventory(text, entries))
        print(json.dumps(report))
        return 0
    except ModError as exc:
        print(f"mods: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
