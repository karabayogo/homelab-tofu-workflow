#!/usr/bin/env bash
# K8s kernel maintenance-window reboot orchestrator — GitOps cattle.
#
# Complement to enforce-k8s-kernel-parity.sh. That script converges POLICY
# and detects drift; this one performs DELIBERATE kernel-change reboots with
# full cluster-side safety gates. It never acts outside the declared window,
# never touches a node with unhealthy Longhorn state, and reboots ONE node at
# a time (single-flight).
#
# Failure modes it prevents (all RCA'd 2026-09-03 and earlier):
#   - uncoordinated reboot into a kernel jump (GRUB pin handles that, but a
#     deliberate switch must re-point saved_entry BEFORE boot)
#   - rebooting a node whose Longhorn volumes are degraded/rebuilding
#   - draining away the only healthy replica of an RWO volume
#   - concurrent node reboots (thundering herd on volume reattachment)
#
# Usage:
#   k8s-kernel-reboot-window.sh --dry-run   # plan only, exit 0
#   k8s-kernel-reboot-window.sh --reboot <node>   # cordon+drain+reboot+uncordon
#   k8s-kernel-reboot-window.sh --list     # candidates needing a reboot
#
# Gates (all must pass before ANY reboot):
#   1. target is an agent (worker) — masters require --allow-master (default NO)
#   2. inside maintenance window (local time, default Sat 19:00-22:00 UTC =
#      Sun 05:00-08:00 AEST per contract) OR FORCE_WINDOW=1
#   3. no other node currently cordoned (single-flight)
#   4. all nodes Ready
#   5. Longhorn: no volume with robustness != healthy; no rebuilding/attaching
#      engine; the RWO replica must have one surviving healthy peer on another
#      node (we drain only when a sibling can take over)
#   6. target has staged kernel != running (or /run/reboot-required)
#   7. contract json exists and names the node
#
set -euo pipefail

MODE="${1:---list}"
TARGET_NODE="${2:-}"
FORCE_WINDOW="${FORCE_WINDOW:-0}"
ALLOW_MASTER="${ALLOW_MASTER:-0}"
KUBECTL="${KUBECTL:-kubectl}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTRACT_JSON="${CONTRACT_JSON:-$REPO_ROOT/infrastructure/contracts/k8s-kernel-parity.json}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"

# --- Cordon ownership + heartbeat contract (2026-10-04 RCA) -----------------
# A deliberate maintenance reboot cordons a node and can take ~3-20 minutes
# (drain up to 600s + reboot + Ready wait up to 600s). If the process DRIVING it
# dies mid-flight (driver script timeout, host reboot, ssh hang, OOM kill) the
# cordon used to be stranded forever: the single-flight gate counted it and
# refused every later run, so the node stayed out of the scheduler until an
# operator noticed — imperative state with no owner, i.e. a pet.
#
# Contract: whoever cordons a node MUST (a) label it
#   maintenance.k8s.workbench.io/reboot-window=true
# and (b) keep the annotation
#   maintenance.k8s.workbench.io/reboot-heartbeat=<RFC3339 UTC>
# fresh (<= HEARTBEAT_INTERVAL) for as long as it owns the cordon, and MUST
# release on every exit path (uncordon + remove label/annotations).
# The in-cluster GitOps reaper (k8s-workbench,
# infrastructure/k8s/maintenance-cordon-reaper) uncordons any maintenance-owned
# node whose heartbeat is older than its TTL, so a hard-killed run self-heals.
MAINT_LABEL_KEY="maintenance.k8s.workbench.io/reboot-window"
MAINT_HEARTBEAT_ANNOTATION="maintenance.k8s.workbench.io/reboot-heartbeat"
MAINT_OWNER_ANNOTATION="maintenance.k8s.workbench.io/reboot-owner"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-20}"
CORDONED_NODE=""
HEARTBEAT_PID=""
HEARTBEAT_STOP_FILE=""

case "$MODE" in
  --list|--dry-run|--reboot) ;;
  *) echo "usage: $0 [--list|--dry-run|--reboot <node>]" >&2; exit 2 ;;
esac

[ "$MODE" = "--reboot" ] && [ -z "$TARGET_NODE" ] && { echo "error: --reboot requires a node name" >&2; exit 2; }
[ -f "$CONTRACT_JSON" ] || { echo "contract missing: $CONTRACT_JSON" >&2; exit 2; }
command -v "$KUBECTL" >/dev/null 2>&1 || { echo "kubectl not found" >&2; exit 2; }

WINDOW_START="${WINDOW_START:-19}"   # UTC hour start
WINDOW_END="${WINDOW_END:-22}"       # UTC hour end (exclusive)
in_window() {
  [ "$FORCE_WINDOW" = "1" ] && return 0
  local h
  h=$(date -u +%-H)
  [ "$h" -ge "$WINDOW_START" ] && [ "$h" -lt "$WINDOW_END" ]
}

contract_node_kernel() {
  python3 - "$CONTRACT_JSON" "$1" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
n = c.get("nodes", {}).get(sys.argv[2], {})
print(n.get("contract_kernel", ""))
PY
}

node_running_kernel() {
  # resolve ssh target from contract + ssh config user
  local node="$1" ip
  ip=$(python3 - "$CONTRACT_JSON" "$node" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print(c.get("nodes", {}).get(sys.argv[2], {}).get("ip", ""))
PY
)
  [ -n "$ip" ] || { echo "?"; return; }
  for user in root ubuntu; do
    out=$(ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "$user@$ip" \
          'uname -r 2>/dev/null' 2>/dev/null) && { echo "$out"; return; }
  done
  echo "?"
}

node_staged_kernel() {
  local node="$1" ip
  ip=$(python3 - "$CONTRACT_JSON" "$node" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print(c.get("nodes", {}).get(sys.argv[2], {}).get("ip", ""))
PY
)
  [ -n "$ip" ] || { echo "?"; return; }
  for user in root ubuntu; do
    out=$(ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "$user@$ip" \
          'ls -1 /boot/vmlinuz-* 2>/dev/null | sed "s|.*vmlinuz-||" | sort -V | tail -1' 2>/dev/null) && { echo "$out"; return; }
  done
  echo "?"
}

longhorn_healthy() {
  # all attached volumes healthy, and no volume has a locked rebuild/attach
  local bad_count
  bad_count=$("$KUBECTL" get volumes.longhorn.io -n longhorn-system -o json 2>/dev/null \
    | python3 -c '
import json, sys
d = json.load(sys.stdin)
bad = [v["metadata"]["name"] for v in d.get("items", [])
       if v.get("status", {}).get("state") == "attached"
       and v.get("status", {}).get("robustness") != "healthy"]
for b in bad: print(b)
')
  [ -z "${bad_count:-}" ]
}

cordoned_count() {
  "$KUBECTL" get nodes --no-headers 2>/dev/null \
    | awk '$2 == "Ready,SchedulingDisabled" {n++} END {print n+0}'
}

node_ready() {
  "$KUBECTL" get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True
}

node_role() {
  python3 - "$CONTRACT_JSON" "$1" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print(c.get("nodes", {}).get(sys.argv[2], {}).get("role", ""))
PY
}

candidates() {
  python3 - "$CONTRACT_JSON" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
for name, n in c.get("nodes", {}).items():
    if n.get("role") == "agent":
        print(name)
PY
}

ensure_saved_entry_points_to_contract() {
  local node="$1" contract_kernel="$2" ip
  ip=$(python3 - "$CONTRACT_JSON" "$node" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print(c.get("nodes", {}).get(sys.argv[2], {}).get("ip", ""))
PY
)
  for user in root ubuntu; do
    if ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "$user@$ip" \
         "sudo grub-editenv /boot/grub/grubenv set saved_entry='Advanced options for Ubuntu>Ubuntu, with Linux ${contract_kernel}' 2>/dev/null; \
          sudo grub-editenv /boot/grub/grubenv set prev_saved_entry='Advanced options for Ubuntu>Ubuntu, with Linux ${contract_kernel}' 2>/dev/null; echo GRUB_REPOINTED" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

reboot_node_via_ssh() {
  local node="$1" ip
  ip=$(python3 - "$CONTRACT_JSON" "$node" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print(c.get("nodes", {}).get(sys.argv[2], {}).get("ip", ""))
PY
)
  for user in root ubuntu; do
    # nohup + disown: ssh must return before the box drops, or the drain
    # script would wait forever on the connection
    if ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "$user@$ip" \
         'sudo systemd-run --on-active=3 --unit=k8s-maintenance-reboot systemctl reboot' 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

maint_heartbeat_write() {
  local node="$1"
  "$KUBECTL" label node "$node" "$MAINT_LABEL_KEY=true" --overwrite >/dev/null 2>&1 || true
  "$KUBECTL" annotate node "$node" --overwrite \
    "$MAINT_HEARTBEAT_ANNOTATION=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$MAINT_OWNER_ANNOTATION=$(hostname):$$" >/dev/null 2>&1 || true
}

maint_heartbeat_start() {
  local node="$1"
  # refresh on a background loop so a long drain / Ready-wait never looks stale
  HEARTBEAT_STOP_FILE="$(mktemp -t maint-hb.XXXXXX)"
  (
    while [ ! -f "$HEARTBEAT_STOP_FILE" ]; do
      maint_heartbeat_write "$node"
      sleep "$HEARTBEAT_INTERVAL"
    done
  ) &
  HEARTBEAT_PID=$!
}

maint_heartbeat_stop() {
  [ -n "$HEARTBEAT_STOP_FILE" ] && rm -f "$HEARTBEAT_STOP_FILE"
  if [ -n "$HEARTBEAT_PID" ]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
  fi
  HEARTBEAT_PID=""
  HEARTBEAT_STOP_FILE=""
}

# Idempotent: uncordon + drop ownership so the reaper and the single-flight gate
# both see a released node. Safe to call from any exit path.
maint_release_cordon() {
  local node="${1:-$CORDONED_NODE}"
  [ -n "$node" ] || return 0
  maint_heartbeat_stop
  "$KUBECTL" uncordon "$node" >/dev/null 2>&1 || true
  "$KUBECTL" label node "$node" "${MAINT_LABEL_KEY}-" >/dev/null 2>&1 || true
  "$KUBECTL" annotate node "$node" \
    "${MAINT_HEARTBEAT_ANNOTATION}-" "${MAINT_OWNER_ANNOTATION}-" >/dev/null 2>&1 || true
  echo "  released cordon ownership on $node (uncordoned, maintenance label/annotations cleared)"
  CORDONED_NODE=""
}

# Every exit path releases the cordon. A hard kill (SIGKILL) cannot run this —
# that is exactly the case the in-cluster reaper covers.
cleanup_on_exit() {
  local rc=$?
  trap - EXIT
  if [ -n "$CORDONED_NODE" ]; then
    echo "  ABORT: this run owns the cordon on $CORDONED_NODE and is exiting (rc=$rc) before finishing — uncordoning now"
    maint_release_cordon "$CORDONED_NODE"
  fi
  exit "$rc"
}
trap cleanup_on_exit EXIT

run_reboot() {
  local node="$1"
  echo "== maintenance-window reboot: $node =="

  local role
  role=$(node_role "$node")
  if [ "$role" = "server" ] && [ "$ALLOW_MASTER" != "1" ]; then
    echo "REFUSE: $node is a control-plane node; automatic master reboots disabled (ALLOW_MASTER=1 to override)"
    exit 2
  fi

  if ! in_window; then
    echo "REFUSE: outside maintenance window (UTC ${WINDOW_START}-${WINDOW_END}); FORCE_WINDOW=1 to override"
    exit 2
  fi

  node_ready "$node" || { echo "REFUSE: $node not Ready"; exit 2; }
  local running staged cc ck
  cc=$(cordoned_count)
  [ "$cc" -eq 0 ] || {
    echo "REFUSE: ${cc} node(s) already SchedulingDisabled — single-flight. A maintenance-owned cordon (label ${MAINT_LABEL_KEY}=true) whose heartbeat is stale is uncordoned automatically by the in-cluster maintenance-cordon-reaper; a cordon placed by hand must be cleared by hand."
    exit 2
  }
  ck=$(contract_node_kernel "$node")
  echo "  contract_kernel=$ck"
  running=$(node_running_kernel "$node")
  staged=$(node_staged_kernel "$node")
  echo "  running=$running staged=$staged"
  if [ "$running" = "?" ] || [ "$staged" = "?" ]; then
    echo "REFUSE: cannot determine kernel state for $node (ssh to contract ip failed) — refusing to reboot blind; fix node access first (2026-09-08 RCA: unknown kernel used to be silently SKIPPED as a false green)"
    exit 2
  fi
  # 2026-09-08 RCA: the old gate skipped when running==staged. That (a) rebooted
  # a node on contract kernel every week while a newer kernel stayed staged
  # (139 is still installed on both workers), and (b) SKIPPED the dangerous
  # case — a node that already silently jumped onto the staged kernel would
  # match running==staged and never be driven back to the contract kernel.
  # Correct policy: the node is healthy iff it RUNS the contract kernel (the
  # boot-pin makes any staged kernel harmless — crash-reboots land on
  # saved_entry=contract). Re-point saved_entry (cheap, no reboot) as defence
  # in depth, then skip. Reboot only when running!=contract (silent jump back,
  # or deliberate promotion after the contract is updated) or a userspace
  # reboot is pending.
  if [ "$running" = "$ck" ]; then
    if ensure_saved_entry_points_to_contract "$node" "$ck"; then
      echo "  GRUB saved_entry pinned to $ck (no reboot needed)"
    else
      echo "  WARN: could not re-point GRUB saved_entry on $node — boot-pin check will re-flag"
    fi
    if ! ssh_running_kernel_pending "$node"; then
      echo "  SKIP: $node already on contract kernel $ck; staged=${staged} is harmless under the boot-pin, no pending reboot"
      return 0
    fi
  fi
  # 2026-09-08 RCA (gate order): longhorn_healthy used to run BEFORE this
  # kernel-identity skip. A node already ON the contract kernel — the weekly
  # no-op case — could abort the whole run on a transient volume rebuild
  # (Sep-06: worker1's reboot minutes earlier left a volume mid-rebuild, so
  # worker2, which needed NO reboot, was REFUSEd and the cron went red).
  # The Longhorn gate only matters when a reboot is actually about to happen.
  longhorn_healthy || { echo "REFUSE: Longhorn has unhealthy/attached non-healthy volumes — aborting before drain"; exit 2; }

  echo "  cordoning $node ..."
  "$KUBECTL" cordon "$node"
  CORDONED_NODE="$node"
  maint_heartbeat_start "$node"
  echo "  claimed cordon ownership (label ${MAINT_LABEL_KEY}=true, heartbeat every ${HEARTBEAT_INTERVAL}s; the in-cluster reaper is the backstop if this process is killed)"

  echo "  draining $node (longhorn-safe: --ignore-daemonsets --delete-emptydir-data) ..."
  if ! "$KUBECTL" drain "$node" --ignore-daemonsets --delete-emptydir-data \
       --grace-period=180 --timeout=600s --force --disable-eviction=false 2>&1; then
    echo "  DRAIN FAILED — releasing cordon, aborting"
    maint_release_cordon "$node"
    exit 1
  fi

  echo "  re-pointing GRUB saved_entry to contract kernel $ck ..."
  ensure_saved_entry_points_to_contract "$node" "$ck" || echo "  WARN: couldn't re-point GRUB; checking boot-pin still holds"

  echo "  rebooting $node ..."
  reboot_node_via_ssh "$node" || { echo "  REBOOT ISSUE — manual check needed; releasing cordon"; maint_release_cordon "$node"; exit 1; }

  echo "  waiting for Ready (max 600s) ..."
  local waited=0
  until node_ready "$node"; do
    sleep 10; waited=$((waited+10))
    [ "$waited" -ge 600 ] && {
      echo "  TIMEOUT waiting Ready — releasing cordon (a NotReady node is protected by its taint; the reaper is the backstop), manual check needed"
      maint_release_cordon "$node"
      exit 1
    }
  done

  local new_kernel
  new_kernel=$(node_running_kernel "$node")
  echo "  node Ready, kernel=$new_kernel"
  if [ -n "$new_kernel" ] && [ "$new_kernel" != "?" ] && [ "$new_kernel" != "$ck" ]; then
    echo "  WARN: kernel ${new_kernel} != contract ${ck} — uncordoning anyway, parity check will re-flag"
  fi

  maint_release_cordon "$node"
  echo "== $node reboot complete, uncordoned =="
}

# hacky but effective: is /run/reboot-required present?
ssh_running_kernel_pending() {
  local node="$1" ip out
  ip=$(python3 - "$CONTRACT_JSON" "$node" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print(c.get("nodes", {}).get(sys.argv[2], {}).get("ip", ""))
PY
)
  for user in root ubuntu; do
    out=$(ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "$user@$ip" \
         'test -f /run/reboot-required && echo yes || echo no' 2>/dev/null) || continue
    case "$(echo "$out" | tail -1)" in
      yes) return 0 ;;
      *) return 1 ;;
    esac
  done
  return 1
}

case "$MODE" in
  --list)
    echo "candidate workers (from contract):"
    for n in $(candidates); do
      echo "  $n: running=$(node_running_kernel "$n") staged=$(node_staged_kernel "$n")"
    done
    ;;
  --dry-run)
    [ -z "$TARGET_NODE" ] && TARGET_NODE=$(candidates | head -1)
    echo "DRY RUN for $TARGET_NODE"
    echo "  window-enabled=$([ "$FORCE_WINDOW" = "1" ] && echo yes || (in_window && echo yes || echo no))"
    echo "  cordoned=$(cordoned_count)  longhorn-healthy=$(longhorn_healthy && echo yes || echo no)  ready=$(node_ready "$TARGET_NODE" && echo yes || echo no)"
    ;;
  --reboot)
    run_reboot "$TARGET_NODE"
    ;;
esac
exit 0