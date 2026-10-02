#!/usr/bin/env python3
"""Gate: ssh payloads in the drill scripts must survive host-side quoting.

The drill scripts hand a multi-line shell payload to a guest through a
DOUBLE-QUOTED host string:

    SOME_VAR="$(ssh_pve "qm guest exec ... -- bash -lc '<payload>'" ...)"

Inside that host string only ``\\"`` and ``\\$`` are escapes; every other
character is passed through. So inside a payload region:

  * a raw ``"`` terminates the host string early and the remaining payload
    leaks into the host shell,
  * a raw ``$`` (or ``$(...)``) is expanded by the HOST instead of the guest,
  * a backtick runs a command on the HOST,
  * a raw ``'`` closes the guest payload early.

2026-10-02: a comment inside a payload quoted an error message and used
backticks (`` `snapshot files` ``). The host shell tried to run ``snapshot`` and
the whole restore step died AFTER a 2h19m mirror push — ``bash -n`` cannot catch
this class, because to the host shell the payload is just a string.

Usage: drill-scripts-payload-quoting-gate.py <script> [<script> ...]
Exit 0 = clean, 1 = violations, 2 = usage/structure error.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

PAYLOAD_OPEN = "bash -lc '"
USAGE = "usage: drill-scripts-payload-quoting-gate.py <script> [<script> ...]"
# A payload contains NO single quotes (that is one of the violations we detect),
# so the payload ends at the first "'" after the opening — optionally followed by
# the host string's closing quote, i.e. `'"` or `'\"`.
PAYLOAD_CLOSE = re.compile(r"'\\?\"?")


def payload_spans(text: str) -> list[tuple[int, int, str]]:
    spans = []
    for match in re.finditer(re.escape(PAYLOAD_OPEN), text):
        start = match.end()
        close = PAYLOAD_CLOSE.search(text, start)
        if close is None:
            raise ValueError(
                f"unterminated ssh payload starting at char offset {start}"
            )
        spans.append((start, close.start(), text[start:close.start()]))
    return spans


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def scan(path: Path) -> list[str]:
    text = path.read_text()
    problems: list[str] = []
    spans = payload_spans(text)
    if not spans:
        problems.append(f"{path}: no ssh payloads found (expected at least one)")
        return problems

    for start, _end, payload in spans:
        for index, char in enumerate(payload):
            previous = payload[index - 1] if index else ""
            if char == "'":
                reason = "raw single quote closes the guest payload early"
            elif char == '"' and previous != "\\":
                reason = 'raw double quote terminates the host string'
            elif char == "`":
                reason = "backtick runs a command on the HOST"
            elif char == "$" and previous != "\\":
                reason = "raw dollar is expanded by the HOST (use \\$)"
            else:
                continue
            offset = start + index
            line_no = line_number(text, offset)
            line = text.splitlines()[line_no - 1]
            problems.append(
                f"{path}:{line_no}: {reason}\n    {line.strip()[:160]}"
            )
    return problems


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(USAGE.strip(), file=sys.stderr)
        return 2

    failures: list[str] = []
    for name in argv[1:]:
        path = Path(name)
        if not path.exists():
            print(f"[FAIL] {name}: file not found", file=sys.stderr)
            return 2
        try:
            problems = scan(path)
        except ValueError as exc:
            print(f"[FAIL] {name}: {exc}", file=sys.stderr)
            return 2
        if problems:
            failures.extend(problems)
        else:
            print(f"[OK]   {name}: ssh payloads are safely quoted")

    if failures:
        print("", file=sys.stderr)
        for problem in failures:
            print(f"[FAIL] {problem}", file=sys.stderr)
        print(
            f"\n[FAIL] {len(failures)} payload quoting violation(s) — inside a "
            "double-quoted ssh payload use \\\" for quotes and \\$ for guest "
            "variables; never backticks or raw single quotes.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
