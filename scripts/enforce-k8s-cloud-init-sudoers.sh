#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---check}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/pve-kai}"
PVE_SSH_TARGET="${PVE_SSH_TARGET:-root@192.168.1.50}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAIN_TF="${MAIN_TF:-$REPO_ROOT/infrastructure/terraform/main.tf}"

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

readonly SSH_BASE_OPTS=(
  -i "$SSH_KEY_PATH"
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=8
)

readonly SSH_COMMON_OPTS=(
  "${SSH_BASE_OPTS[@]}"
  -n
)

declare -A VMID_CACHE=()

inventory_rows() {
  python3 - "$MAIN_TF" <<'PY'
import re
import sys
from pathlib import Path

module_start = re.compile(r'module\s+"(k8s_[^"]+)"\s*\{')
kv = re.compile(r'^\s*([a-zA-Z0-9_]+)\s*=\s*"([^"]+)"')

lines = Path(sys.argv[1]).read_text().splitlines()
current = None
depth = 0
values = {}

for line in lines:
    if current is None:
        match = module_start.search(line)
        if match:
            current = match.group(1)
            depth = line.count("{") - line.count("}")
            values = {}
        continue

    depth += line.count("{") - line.count("}")
    match = kv.search(line)
    if match:
        values[match.group(1)] = match.group(2)

    if depth == 0:
        name = values.get("vm_name")
        ip = values.get("static_ip")
        admin_user = values.get("admin_user", "ubuntu")
        if name and ip:
            print(f"{name}\t{ip}\t{admin_user}")
        current = None
        values = {}
PY
}

pve_vm_id_for_name() {
  local node_name="$1"

  if [[ -n "${VMID_CACHE[$node_name]:-}" ]]; then
    printf '%s\n' "${VMID_CACHE[$node_name]}"
    return 0
  fi

  local vmid
  vmid="$(
    ssh "${SSH_BASE_OPTS[@]}" "$PVE_SSH_TARGET" python3 - "$node_name" <<'PY'
import subprocess
import sys

node_name = sys.argv[1]
qm_list = subprocess.run(["qm", "list"], check=True, capture_output=True, text=True).stdout

for line in qm_list.splitlines()[1:]:
    parts = line.split()
    if len(parts) >= 2 and parts[1] == node_name:
        print(parts[0])
        break
PY
  )" || return 1

  if [ -n "$vmid" ]; then
    VMID_CACHE["$node_name"]="$vmid"
  fi

  printf '%s\n' "$vmid"
}

pve_guest_exec() {
  local vmid="$1"
  local remote_cmd="$2"
  local remote_cmd_b64

  remote_cmd_b64="$(printf '%s' "$remote_cmd" | base64 | tr -d '\n')"

  ssh "${SSH_BASE_OPTS[@]}" "$PVE_SSH_TARGET" \
    REMOTE_CMD_B64="$remote_cmd_b64" \
    python3 - "$vmid" <<'PY'
import base64
import json
import os
import subprocess
import sys

vmid = sys.argv[1]
remote_cmd = base64.b64decode(os.environ["REMOTE_CMD_B64"]).decode()

proc = subprocess.run(
    ["qm", "guest", "exec", vmid, "--", "bash", "-lc", remote_cmd],
    capture_output=True,
    text=True,
)
if proc.returncode != 0:
    sys.stderr.write(proc.stderr)
    raise SystemExit(proc.returncode)

payload = json.loads(proc.stdout)
stdout = payload.get("out-data", "")
stderr = payload.get("err-data", "")
if stdout:
    sys.stdout.write(stdout)
if stderr:
    sys.stderr.write(stderr)
raise SystemExit(payload.get("exitcode", 0))
PY
}

ssh_first_success() {
  local node_name="$1"
  local node_ip="$2"
  local admin_user="$3"
  local remote_cmd="$4"
  local ssh_target

  for ssh_target in "$node_name" "${admin_user}@${node_ip}" "ubuntu@${node_ip}" "root@${node_ip}"; do
    if ssh "${SSH_COMMON_OPTS[@]}" "$ssh_target" "$remote_cmd" 2>/dev/null; then
      return 0
    fi
  done

  return 1
}

status_cmd_for_admin_user() {
  local admin_user="$1"

  cat <<EOF
ADMIN_USER='$admin_user' python3 - <<'PY'
import os
import pathlib
import subprocess
import sys

sudo = [] if os.geteuid() == 0 else ["sudo"]
sudoers = pathlib.Path("/etc/sudoers.d/90-cloud-init-users")

if not sudoers.exists():
    print("missing\t0\t0")
    raise SystemExit(0)

valid = subprocess.run(
    sudo + ["visudo", "-cf", str(sudoers)],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
).returncode == 0

desired = f"{os.environ['ADMIN_USER']} ALL=(ALL) NOPASSWD:ALL"
desired_count = 0
extra_count = 0

for raw_line in sudoers.read_text().splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue
    if line == desired:
        desired_count += 1
    else:
        extra_count += 1

print(f"{'yes' if valid else 'no'}\t{desired_count}\t{extra_count}")
PY
EOF
}

enforce_cmd_for_admin_user() {
  local admin_user="$1"

  cat <<EOF
ADMIN_USER='$admin_user' python3 - <<'PY'
import os
import pathlib
import subprocess
import tempfile

sudo = [] if os.geteuid() == 0 else ["sudo"]
sudoers = "/etc/sudoers.d/90-cloud-init-users"
content = (
    "# Managed by homelab-tofu-workflow cloud-init sudoers convergence\n\n"
    f"# User rules for {os.environ['ADMIN_USER']}\n"
    f"{os.environ['ADMIN_USER']} ALL=(ALL) NOPASSWD:ALL\n"
)

with tempfile.NamedTemporaryFile("w", delete=False) as tmp:
    tmp.write(content)
    tmp_path = tmp.name

subprocess.run(["chmod", "0440", tmp_path], check=True)
subprocess.run(sudo + ["visudo", "-cf", tmp_path], check=True, stdout=subprocess.DEVNULL)
subprocess.run(sudo + ["install", "-m", "0440", tmp_path, sudoers], check=True)
subprocess.run(sudo + ["visudo", "-cf", sudoers], check=True, stdout=subprocess.DEVNULL)
os.unlink(tmp_path)
PY
EOF
}

node_state() {
  local node_name="$1"
  local node_ip="$2"
  local admin_user="$3"
  local remote_cmd
  local vmid

  remote_cmd="$(status_cmd_for_admin_user "$admin_user")"

  vmid="$(pve_vm_id_for_name "$node_name" 2>/dev/null || true)"
  if [ -n "$vmid" ] && pve_guest_exec "$vmid" "$remote_cmd" 2>/dev/null; then
    return 0
  fi

  if ! ssh_first_success "$node_name" "$node_ip" "$admin_user" "$remote_cmd"; then
    printf 'unreachable\t0\t0\n'
    return 0
  fi
}

is_clean() {
  local valid="$1"
  local desired_count="$2"
  local extra_count="$3"

  [ "$valid" = "yes" ] || return 1
  [ "$desired_count" = "1" ] || return 1
  [ "$extra_count" = "0" ] || return 1
}

enforce_node() {
  local node_name="$1"
  local node_ip="$2"
  local admin_user="$3"
  local remote_cmd
  local vmid

  remote_cmd="$(enforce_cmd_for_admin_user "$admin_user")"

  vmid="$(pve_vm_id_for_name "$node_name" 2>/dev/null || true)"
  if [ -n "$vmid" ] && pve_guest_exec "$vmid" "$remote_cmd" >/dev/null 2>&1; then
    return 0
  fi

  ssh_first_success "$node_name" "$node_ip" "$admin_user" "$remote_cmd" >/dev/null
}

FAILURES=0

while IFS=$'\t' read -r node_name node_ip admin_user; do
  [ -z "$node_name" ] && continue

  read -r valid desired_count extra_count <<<"$(node_state "$node_name" "$node_ip" "$admin_user")"

  if [ "$MODE" = "--enforce" ] && ! is_clean "$valid" "$desired_count" "$extra_count"; then
    echo "ENFORCE ${node_name} (${node_ip}) admin=${admin_user} valid=${valid} desired=${desired_count} extra=${extra_count}"
    if ! enforce_node "$node_name" "$node_ip" "$admin_user"; then
      echo "FAIL ${node_name} (${node_ip}) unable to enforce" >&2
      FAILURES=$((FAILURES + 1))
      continue
    fi
    read -r valid desired_count extra_count <<<"$(node_state "$node_name" "$node_ip" "$admin_user")"
  fi

  if is_clean "$valid" "$desired_count" "$extra_count"; then
    echo "PASS ${node_name} (${node_ip}) admin=${admin_user} valid=${valid} desired=${desired_count} extra=${extra_count}"
  else
    echo "FAIL ${node_name} (${node_ip}) admin=${admin_user} valid=${valid} desired=${desired_count} extra=${extra_count}"
    FAILURES=$((FAILURES + 1))
  fi
done < <(inventory_rows)

if [ "$FAILURES" -ne 0 ]; then
  exit 1
fi
