#!/usr/bin/env python3
"""Cordon-ownership contract gate for scripts/k8s-kernel-reboot-window.sh.

Why this gate exists (2026-10-04 RCA): the weekly kernel maintenance window
cordoned k8s-worker2, started draining it, and was SIGKILLed by the driver's
script timeout. Nothing owned the cordon, so it stranded the node (and the
ArgoCD application controller that got evicted from it) until an operator
looked, and the single-flight gate refused every later run.

The orchestrator must therefore:
  * declare the cordon-ownership wire contract (label + heartbeat/owner
    annotations) that the in-cluster reaper (k8s-workbench
    infrastructure/k8s/maintenance-cordon-reaper) reads;
  * label the node and keep a heartbeat fresh for as long as it owns the cordon;
  * release ownership on EVERY exit path (uncordon + drop label/annotations),
    via an EXIT trap, so a graceful failure can never leave the cordon behind;
  * keep the safety gates that make a deliberate reboot safe (window, Longhorn
    health, contract-kernel identity, single-flight, Ready) and keep returning
    rc=2 for REFUSE/SKIP so a driver can distinguish "refused safely" from
    "failed" (the 2026-09-27 false red).

Usage: k8s-kernel-maintenance-cordon-contract-gate.py <path-to-orchestrator>
"""
import re
import sys
from pathlib import Path

REQUIRED = {
    # wire contract with the in-cluster reaper
    'label key': 'maintenance.k8s.workbench.io/reboot-window',
    'heartbeat annotation': 'maintenance.k8s.workbench.io/reboot-heartbeat',
    'owner annotation': 'maintenance.k8s.workbench.io/reboot-owner',
    # ownership lifecycle
    'heartbeat refresh loop': 'maint_heartbeat_start()',
    'heartbeat writer': 'maint_heartbeat_write()',
    'release helper': 'maint_release_cordon()',
    'EXIT trap': 'trap cleanup_on_exit EXIT',
    'uncordon on release': 'uncordon "$node"',
    'drop maintenance label': '${MAINT_LABEL_KEY}-',
    # safety gates that must survive any refactor
    'maintenance window gate': 'in_window',
    'longhorn health gate': 'longhorn_healthy ||',
    'single-flight gate': 'cordoned_count',
    'contract kernel identity gate': 'contract_node_kernel',
    'node Ready gate': 'node_ready "$node"',
}

# Every cordon must be followed by ownership + a release on each failure path.
REQUIRED_SEQUENCE = [
    ('cordon', r'"\$KUBECTL" cordon "\$node"'),
    ('claim ownership', r'CORDONED_NODE="\$node"'),
    ('start heartbeat', r'maint_heartbeat_start "\$node"'),
]

failures = []


def fail(msg):
    failures.append(msg)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = Path(sys.argv[1])
    if not path.is_file():
        print(f'FAIL k8s-kernel-maintenance-cordon-contract-gate: {path} not found')
        return 1

    text = path.read_text()

    for name, needle in REQUIRED.items():
        if needle not in text:
            fail(f'missing {name}: {needle!r}')

    # Ownership must be taken in order, right where the cordon happens.
    positions = []
    for name, pattern in REQUIRED_SEQUENCE:
        m = re.search(pattern, text)
        if not m:
            fail(f'cordon lifecycle: {name} not found ({pattern!r})')
        else:
            positions.append((name, m.start()))
    if len(positions) == len(REQUIRED_SEQUENCE):
        ordered = all(positions[i][1] < positions[i + 1][1] for i in range(len(positions) - 1))
        if not ordered:
            fail('cordon lifecycle: cordon -> claim ownership -> start heartbeat must happen in that order')

    # No failure path may exit while still owning a cordon: every `exit 1` after
    # the cordon must be preceded by a release, and the trap must be installed
    # before run_reboot is ever called.
    trap_pos = text.find('trap cleanup_on_exit EXIT')
    run_reboot_pos = text.find('run_reboot() {')
    if trap_pos == -1 or run_reboot_pos == -1 or trap_pos > run_reboot_pos:
        fail('the EXIT trap must be installed before run_reboot is defined/called')

    cordon_pos = text.find('CORDONED_NODE="$node"')
    if cordon_pos != -1:
        tail = text[cordon_pos:]
        if 'maint_release_cordon "$node"' not in tail:
            fail('after the cordon, no path releases ownership')
        # each explicit failure exit in the drain/reboot/wait section must release
        for marker in ('DRAIN FAILED', 'REBOOT ISSUE', 'TIMEOUT waiting Ready'):
            idx = tail.find(marker)
            if idx == -1:
                fail(f'expected failure path {marker!r} in the cordon section')
                continue
            window = tail[idx: idx + 400]
            if 'maint_release_cordon' not in window:
                fail(f'failure path {marker!r} does not release the cordon before exiting')

    # REFUSE must stay a distinct, non-failure exit code (rc=2).
    refuse_exits = re.findall(r'echo "REFUSE:[^\n]*\n\s*exit (\d+)', text)
    if not refuse_exits:
        fail('no REFUSE exit found — the safety-gate refusals must remain explicit')
    elif any(code != '2' for code in refuse_exits):
        fail(f'REFUSE must exit 2 (driver treats it as skip, not failure); found {sorted(set(refuse_exits))}')

    # The heartbeat must be bounded so a live run is never mistaken for dead,
    # and it must be released (not leaked) after the run.
    if 'HEARTBEAT_INTERVAL' not in text:
        fail('heartbeat interval constant missing')

    if failures:
        print('FAIL k8s-kernel-maintenance-cordon-contract-gate')
        for f in failures:
            print(f'  - {f}')
        return 1
    print('PASS k8s-kernel-maintenance-cordon-contract-gate')
    return 0


if __name__ == '__main__':
    sys.exit(main())
