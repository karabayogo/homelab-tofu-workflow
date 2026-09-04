#!/usr/bin/env python3
"""Def-before-use gate for drill scripts.

2026-09-04 RCA: pbs-restore-from-synology-drill.sh died on the first GHA
dispatch with "line 61: log: command not found" (exit 127) because a Step-0
block inserted above the log()/die() definitions called them before bash
resolved them. `bash -n` does NOT catch this class (functions resolve at
call time). This gate scans for any use of log/die/ssh_pve before its
definition line.
"""
import re
import sys

FNS = ("log", "die", "ssh_pve")


def check(path: str) -> list:
    src = open(path).read().splitlines()
    defs: dict = {fn: None for fn in FNS}
    for i, line in enumerate(src, 1):
        m = re.match(r"^(log|die|ssh_pve)\(\)", line)
        if m and defs[m.group(1)] is None:
            defs[m.group(1)] = i
    bad = []
    for i, line in enumerate(src, 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        for fn, d in defs.items():
            if d and re.search(rf"\b{fn}\b", line) and i < d:
                bad.append(f"{fn} used at line {i} before definition at line {d}")
    return bad


def main() -> int:
    files = sys.argv[1:] or [
        "scripts/pbs-rebuild-drill.sh",
        "scripts/pbs-restore-from-synology-drill.sh",
    ]
    rc = 0
    for path in files:
        bad = check(path)
        if bad:
            print(f"FAIL {path}: " + "; ".join(bad))
            rc = 1
        else:
            print(f"OK   {path}")
    return rc


if __name__ == "__main__":
    sys.exit(main())