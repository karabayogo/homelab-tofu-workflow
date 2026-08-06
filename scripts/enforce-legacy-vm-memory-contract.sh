#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---check}"
LIVE_CHECK="${LIVE_CHECK:-1}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/pve-kai}"
PVE_HOST="${PVE_HOST:-192.168.1.50}"
PVE_USER="${PVE_USER:-root}"
PVE_TARGET="${PVE_USER}@${PVE_HOST}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTRACT_JSON="${CONTRACT_JSON:-$REPO_ROOT/infrastructure/terraform/legacy-vm-contracts.json}"

case "$MODE" in
  --check|--enforce) ;;
  *)
    echo "usage: $0 [--check|--enforce]" >&2
    exit 2
    ;;
esac

if [ ! -f "$SSH_KEY_PATH" ]; then
  echo "SSH key not found: $SSH_KEY_PATH" >&2
  exit 2
fi

if [ ! -f "$CONTRACT_JSON" ]; then
  echo "Legacy VM contract JSON not found: $CONTRACT_JSON" >&2
  exit 2
fi

readonly SSH_OPTS=(
  -i "$SSH_KEY_PATH"
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=8
)

warn() {
  local message="$1"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::warning::${message}"
  else
    echo "WARN ${message}"
  fi
}

ssh_pve() {
  ssh "${SSH_OPTS[@]}" "$PVE_TARGET" "$@"
}

contract_rows() {
  python3 - "$CONTRACT_JSON" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
vms = data.get("vms")
if not isinstance(vms, dict) or not vms:
    raise SystemExit(f"contract file has no vms map: {path}")

for vmid, cfg in sorted(vms.items(), key=lambda kv: int(kv[0])):
    memory_mb = int(cfg["memory_mb"])
    if memory_mb <= 0:
        raise SystemExit(f"invalid memory_mb for VM {vmid}: {memory_mb}")
    allow_reboot = 1 if cfg.get("allow_automated_reboot", False) else 0
    name = cfg.get("name", f"vm-{vmid}")
    reason = cfg.get("reason", "")
    print(f"{vmid}\t{name}\t{memory_mb}\t{allow_reboot}\t{reason}")
PY
}

static_check() {
  python3 - "$CONTRACT_JSON" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
vms = data.get("vms")
if not isinstance(vms, dict) or not vms:
    raise SystemExit(f"contract file has no vms map: {path}")

total = 0
for vmid, cfg in sorted(vms.items(), key=lambda kv: int(kv[0])):
    memory_mb = int(cfg["memory_mb"])
    if memory_mb <= 0:
        raise SystemExit(f"invalid memory_mb for VM {vmid}: {memory_mb}")
    total += memory_mb
    print(f"CONTRACT VM {vmid} {cfg.get('name', f'vm-{vmid}')} memory_mb={memory_mb} allow_automated_reboot={cfg.get('allow_automated_reboot', False)}")
print(f"CONTRACT TOTAL unmanaged_memory_mb={total}")
PY
}

live_state() {
  local vmid="$1"
  ssh_pve python3 - "$vmid" <<'PY'
import json
import subprocess
import sys

vmid = sys.argv[1]
config = subprocess.run(["qm", "config", vmid], check=True, capture_output=True, text=True).stdout
config_mem = 0
name = f"vm-{vmid}"
for line in config.splitlines():
    if line.startswith("memory:"):
        config_mem = int(line.split(":", 1)[1].strip())
    elif line.startswith("name:"):
        name = line.split(":", 1)[1].strip()

current_raw = subprocess.run(
    ["pvesh", "get", f"/nodes/pve/qemu/{vmid}/status/current", "--output-format", "json"],
    check=True,
    capture_output=True,
    text=True,
).stdout
current = json.loads(current_raw)
status = current.get("status", "unknown")
maxmem = current.get("maxmem") or 0
runtime_mem_mb = int(round(maxmem / (1024 * 1024))) if maxmem else 0
uptime = int(current.get("uptime") or 0)
print(f"{name}\t{config_mem}\t{status}\t{runtime_mem_mb}\t{uptime}")
PY
}

set_config_memory() {
  local vmid="$1"
  local memory_mb="$2"
  ssh_pve "qm set '${vmid}' --memory '${memory_mb}' >/dev/null"
}

power_cycle_and_wait() {
  local vmid="$1"
  local expected_memory_mb="$2"

  ssh_pve "qm shutdown '${vmid}' --timeout 120 >/dev/null || true"

  local attempt
  local state
  local runtime_name runtime_config runtime_status runtime_mem runtime_uptime
  for attempt in $(seq 1 24); do
    sleep 5
    state="$(live_state "$vmid")"
    IFS=$'\t' read -r runtime_name runtime_config runtime_status runtime_mem runtime_uptime <<<"$state"
    if [ "$runtime_status" = "stopped" ]; then
      break
    fi
  done

  state="$(live_state "$vmid")"
  IFS=$'\t' read -r runtime_name runtime_config runtime_status runtime_mem runtime_uptime <<<"$state"
  if [ "$runtime_status" != "stopped" ]; then
    ssh_pve "qm stop '${vmid}' >/dev/null"
  fi

  ssh_pve "qm start '${vmid}' >/dev/null"

  for attempt in $(seq 1 36); do
    sleep 5
    state="$(live_state "$vmid")"
    IFS=$'\t' read -r runtime_name runtime_config runtime_status runtime_mem runtime_uptime <<<"$state"
    if [ "$runtime_status" = "running" ] && [ "$runtime_mem" -eq "$expected_memory_mb" ] 2>/dev/null; then
      printf '%s\n' "$state"
      return 0
    fi
  done

  printf '%s\n' "$state"
  return 1
}

if [ "$LIVE_CHECK" = "0" ]; then
  static_check
  exit 0
fi

FAILURES=0
WARNINGS=0

while IFS=$'\t' read -r vmid expected_name expected_memory_mb allow_reboot reason; do
  [ -z "$vmid" ] && continue

  state="$(live_state "$vmid")"
  IFS=$'\t' read -r live_name config_memory_mb runtime_status runtime_memory_mb uptime_s <<<"$state"

  if [ "$MODE" = "--enforce" ] && [ "$config_memory_mb" -ne "$expected_memory_mb" ] 2>/dev/null; then
    echo "ENFORCE VM ${vmid} (${live_name}): config_memory=${config_memory_mb}MiB -> ${expected_memory_mb}MiB"
    set_config_memory "$vmid" "$expected_memory_mb"
    state="$(live_state "$vmid")"
    IFS=$'\t' read -r live_name config_memory_mb runtime_status runtime_memory_mb uptime_s <<<"$state"
  fi

  if [ "$config_memory_mb" -ne "$expected_memory_mb" ] 2>/dev/null; then
    echo "FAIL VM ${vmid} (${live_name}): config_memory=${config_memory_mb}MiB expected=${expected_memory_mb}MiB runtime_status=${runtime_status} runtime_memory=${runtime_memory_mb}MiB"
    FAILURES=$((FAILURES + 1))
    continue
  fi

  if [ "$runtime_status" = "running" ] && [ "$runtime_memory_mb" -ne "$expected_memory_mb" ] 2>/dev/null; then
    if [ "$MODE" = "--enforce" ] && [ "$allow_reboot" = "1" ]; then
      echo "ENFORCE VM ${vmid} (${live_name}): runtime_memory=${runtime_memory_mb}MiB -> ${expected_memory_mb}MiB via full power cycle"
      if state="$(power_cycle_and_wait "$vmid" "$expected_memory_mb")"; then
        IFS=$'\t' read -r live_name config_memory_mb runtime_status runtime_memory_mb uptime_s <<<"$state"
      else
        IFS=$'\t' read -r live_name config_memory_mb runtime_status runtime_memory_mb uptime_s <<<"$state"
      fi
    fi
  fi

  if [ "$runtime_status" = "running" ] && [ "$runtime_memory_mb" -ne "$expected_memory_mb" ] 2>/dev/null; then
    if [ "$allow_reboot" = "1" ]; then
      echo "FAIL VM ${vmid} (${live_name}): config_memory=${config_memory_mb}MiB runtime_memory=${runtime_memory_mb}MiB expected=${expected_memory_mb}MiB after automated power-cycle attempt"
      FAILURES=$((FAILURES + 1))
    else
      warn "VM ${vmid} (${live_name}) still running with ${runtime_memory_mb}MiB while contract is ${expected_memory_mb}MiB. Config is already repaired; a coordinated full power cycle is still required because lowering qm config does not shrink a running guest's maxmem and pending memory changes are only applied when the VM fully stops. ${reason}"
      echo "WARN VM ${vmid} (${live_name}): config_memory=${config_memory_mb}MiB runtime_memory=${runtime_memory_mb}MiB expected=${expected_memory_mb}MiB reboot_required=true"
      WARNINGS=$((WARNINGS + 1))
    fi
  else
    echo "PASS VM ${vmid} (${live_name}): config_memory=${config_memory_mb}MiB runtime_memory=${runtime_memory_mb}MiB status=${runtime_status}"
  fi
done < <(contract_rows)

if [ "$WARNINGS" -gt 0 ]; then
  echo "SUMMARY warnings=${WARNINGS} failures=${FAILURES}"
fi

if [ "$FAILURES" -ne 0 ]; then
  exit 1
fi
