#!/usr/bin/env python3
"""Set one key=value line in the PZ server .ini, in place.

Runs on the game server, invoked by the `pz-prod-config-write` SSM document with a
fixed command line and pattern-constrained parameters -- so the caller's `key` and
`value` arrive as plain argv, never as text interpolated into a shell string. This is
the same logic pzbot previously shipped as a base64-encoded pipe per invocation
(issue #29); moving it here makes it a file in this repo instead of a second,
unreviewed implementation living in a string.
"""

from __future__ import annotations

import sys


def set_key(path: str, key: str, value: str) -> str:
    lines = open(path, encoding="utf-8").read().splitlines()

    out, found = [], False
    for line in lines:
        if line.split("=", 1)[0].strip() == key:
            out.append(key + "=" + value)
            found = True
        else:
            out.append(line)
    if not found:
        out.append(key + "=" + value)

    open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
    return "updated " + key if found else "added " + key


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print("usage: pz-ini-tool.py <ini-path> <key> <value>", file=sys.stderr)
        return 2
    _, path, key, value = argv
    print(set_key(path, key, value))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
