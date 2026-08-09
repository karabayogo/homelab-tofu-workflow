#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"

PVE_HOST="${PVE_HOST:-192.168.1.50}"
PVE_USER="${PVE_USER:-root}"
PVE_TARGET="${PVE_USER}@${PVE_HOST}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/pve-kai}"
SSH_OPTS=(
  -n
  -i "$SSH_KEY_PATH"
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
)
SCP_OPTS=(
  -i "$SSH_KEY_PATH"
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
)
PBS_HOST="${PBS_HOST:-192.168.1.247}"
PBS_PORT="${PBS_PORT:-8007}"
PBS_VM_ID="${PBS_VM_ID:-905}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PBS_TEMPLATE="${REPO_ROOT}/infrastructure/terraform/modules/vm/templates/cloud-init-pbs.yaml.tftpl"

REMOTE_SCRIPT="/root/bin/pve-host-config-backup-to-pbs.sh"
REMOTE_SERVICE="/etc/systemd/system/pve-host-config-backup-to-pbs.service"
REMOTE_TIMER="/etc/systemd/system/pve-host-config-backup-to-pbs.timer"

LOCAL_SCRIPT="${SCRIPT_DIR}/pve-host-config-backup-to-pbs.sh"
LOCAL_SERVICE="${SCRIPT_DIR}/pve-host-config-backup-to-pbs.service"
LOCAL_TIMER="${SCRIPT_DIR}/pve-host-config-backup-to-pbs.timer"

ssh_pve() {
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "$PVE_TARGET" "$@"
}

guest_exec() {
  local guest_cmd="$1"
  local quoted_cmd
  local raw_output

  printf -v quoted_cmd '%q' "$guest_cmd"
  raw_output="$(ssh_pve "qm guest exec ${PBS_VM_ID} -- bash -lc ${quoted_cmd}")"
  printf '%s' "$raw_output" | python3 -c 'import json, sys; data = json.load(sys.stdin); sys.stdout.write(data.get("out-data", "")); raise SystemExit(data.get("exitcode", 1))'
}

copy_to_pve() {
  local src="$1"
  local dest="$2"
  local mode="$3"
  local tmp

  tmp="/tmp/$(basename "$dest").codex.$$"
  scp "${SCP_OPTS[@]}" "$src" "$PVE_TARGET:$tmp"
  ssh_pve "install -D -m ${mode} '${tmp}' '${dest}' && rm -f '${tmp}'"
}

remote_sha() {
  local path="$1"
  ssh_pve "sha256sum '${path}' 2>/dev/null | awk '{print \$1}' || true"
}

local_sha() {
  sha256sum "$1" | awk '{print $1}'
}

check_file() {
  local local_path="$1"
  local remote_path="$2"
  local expected
  local actual

  expected="$(local_sha "$local_path")"
  actual="$(remote_sha "$remote_path")"
  if [[ "$expected" != "$actual" ]]; then
    echo "[ERROR] Drift detected for ${remote_path}"
    return 1
  fi
  echo "[OK] ${remote_path} matches repo"
}

check_storage_target() {
  local actual

  actual="$(
    ssh_pve "sed -n '/^pbs: pbs-primary\$/,/^[^[:space:]]/p' /etc/pve/storage.cfg | awk '/^[[:space:]]+server / { print \$2; exit }'"
  )"

  if [[ "$actual" != "$PBS_HOST" ]]; then
    echo "[ERROR] pbs-primary server is ${actual:-<unset>} but expected ${PBS_HOST}"
    return 1
  fi

  echo "[OK] pbs-primary server matches ${PBS_HOST}"
}

check_template_contract() {
  test -f "$PBS_TEMPLATE"
  if grep -q 'DISK="/dev/sdb"' "$PBS_TEMPLATE"; then
    echo "[ERROR] hard-coded /dev/sdb PBS datastore device found in $PBS_TEMPLATE"
    return 1
  fi
  # shellcheck disable=SC2016
  grep -q 'ROOT_SOURCE="$(findmnt -n -o SOURCE /)"' "$PBS_TEMPLATE"
  # shellcheck disable=SC2016
  grep -q 'ROOT_DISK="/dev/$(lsblk -no PKNAME "$${ROOT_SOURCE}")"' "$PBS_TEMPLATE"
  grep -q 'LABEL="pbs-datastore"' "$PBS_TEMPLATE"
  # shellcheck disable=SC2016
  grep -q 'echo "LABEL=$LABEL $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab.tmp' "$PBS_TEMPLATE"
  echo "[OK] PBS cloud-init template uses root-disk-aware datastore discovery"
}

enforce_storage_target() {
  ssh_pve "PBS_HOST='${PBS_HOST}' PBS_PORT='${PBS_PORT}' python3 - <<'PY'
from pathlib import Path
import os
import re

path = Path('/etc/pve/storage.cfg')
lines = path.read_text().splitlines()

header = 'pbs: pbs-primary'
host = os.environ['PBS_HOST']
port = os.environ['PBS_PORT']

try:
    start = next(i for i, line in enumerate(lines) if line.strip() == header)
except StopIteration as exc:
    raise SystemExit('pbs-primary section not found in /etc/pve/storage.cfg') from exc

end = len(lines)
for i in range(start + 1, len(lines)):
    if lines[i] and not lines[i].startswith((' ', '\t')):
        end = i
        break

section = lines[start + 1:end]
updated = []
server_seen = False
port_seen = False

for line in section:
    if re.match(r'^\s*server\s+', line):
        updated.append(f'\tserver {host}')
        server_seen = True
    elif re.match(r'^\s*port\s+', line):
        updated.append(f'\tport {port}')
        port_seen = True
    else:
        updated.append(line)

if not server_seen:
    updated.append(f'\tserver {host}')
if not port_seen:
    updated.append(f'\tport {port}')

lines = lines[: start + 1] + updated + lines[end:]
path.write_text('\n'.join(lines) + '\n')
PY"
}

enable_timer() {
  ssh_pve "systemctl daemon-reload && systemctl enable --now pve-host-config-backup-to-pbs.timer"
}

guest_datastore_contract_script() {
  cat <<'EOF'
set -euo pipefail

MODE="${MODE:-check}"
MOUNT_POINT="/srv/proxmox-backup-primary"
DATASTORE_PATH="${MOUNT_POINT}/datastore"
LABEL="pbs-datastore"

ROOT_SOURCE="$(findmnt -n -o SOURCE /)"
ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_SOURCE")"
mapfile -t DATA_DISKS < <(
  lsblk -dnpo NAME,TYPE \
    | awk '$2 == "disk" { print $1 }' \
    | grep -vx "$ROOT_DISK"
)

if [ "${#DATA_DISKS[@]}" -ne 1 ]; then
  echo "expected exactly one non-root PBS data disk, found: ${DATA_DISKS[*]:-none}"
  exit 1
fi

DISK="${DATA_DISKS[0]}"
CURRENT_LABEL="$(blkid -s LABEL -o value "$DISK" 2>/dev/null || true)"

if [ "$MODE" = "enforce" ]; then
  if ! blkid "$DISK" >/dev/null 2>&1; then
    echo "unformatted datastore disk $DISK: live converge refuses to mkfs; reprovision or first-boot cloud-init must initialize it"
    exit 1
  elif [ "${CURRENT_LABEL:-}" != "$LABEL" ]; then
    tune2fs -L "$LABEL" "$DISK"
    CURRENT_LABEL="$LABEL"
  fi

  mkdir -p "$MOUNT_POINT"
  awk '$2 != "/srv/proxmox-backup-primary" { print }' /etc/fstab > /etc/fstab.tmp
  printf 'LABEL=%s %s ext4 defaults,nofail 0 2\n' "$LABEL" "$MOUNT_POINT" >> /etc/fstab.tmp
  mv /etc/fstab.tmp /etc/fstab

  if ! mountpoint -q "$MOUNT_POINT"; then
    mount "$MOUNT_POINT"
  fi

  mkdir -p "$DATASTORE_PATH"
  if ! proxmox-backup-manager datastore list --output-format json | python3 -c 'import json, sys; items = json.load(sys.stdin); sys.exit(0 if any(item.get("name") == "primary" for item in items) else 1)'
  then
    proxmox-backup-manager datastore create primary "$DATASTORE_PATH"
  fi
fi

mountpoint -q "$MOUNT_POINT"
test -d "$DATASTORE_PATH"
printf 'root_source=%s\nroot_disk=%s\ndata_disk=%s\nlabel=%s\nmount_source=%s\n' \
  "$ROOT_SOURCE" "$ROOT_DISK" "$DISK" "$(blkid -s LABEL -o value "$DISK" 2>/dev/null || true)" "$(findmnt -n -o SOURCE "$MOUNT_POINT")"
EOF
}

check_guest_datastore_contract() {
  local guest_script

  guest_script="$(guest_datastore_contract_script)"
  guest_exec "MODE=check; ${guest_script}"
  echo "[OK] backup-pbs1 datastore mount contract is healthy"
}

enforce_guest_datastore_contract() {
  local guest_script

  guest_script="$(guest_datastore_contract_script)"
  guest_exec "MODE=enforce; ${guest_script}"
  echo "[OK] backup-pbs1 datastore contract converged"
}

run_preflight() {
  local storage_status

  ssh_pve "${REMOTE_SCRIPT} --preflight"
  storage_status="$(ssh_pve "python3 - <<'PY'
import subprocess
raw = subprocess.check_output(['pvesm', 'status', '--storage', 'pbs-primary'], text=True)
lines = [line for line in raw.splitlines() if line.strip()]
if len(lines) < 2:
    raise SystemExit('missing pvesm status row for pbs-primary')
parts = lines[1].split()
if len(parts) < 3:
    raise SystemExit(f'unexpected pvesm status row: {lines[1]!r}')
print(parts[2])
PY"
)"
  if [[ "$storage_status" != "active" ]]; then
    echo "[ERROR] pbs-primary storage status is ${storage_status:-<unknown>} (expected active)"
    return 1
  fi
  echo "[OK] pbs-primary storage is active"
}

case "$MODE" in
  --check)
    check_template_contract
    check_file "$LOCAL_SCRIPT" "$REMOTE_SCRIPT"
    check_file "$LOCAL_SERVICE" "$REMOTE_SERVICE"
    check_file "$LOCAL_TIMER" "$REMOTE_TIMER"
    check_storage_target
    check_guest_datastore_contract
    run_preflight
    ;;
  --enforce)
    check_template_contract
    copy_to_pve "$LOCAL_SCRIPT" "$REMOTE_SCRIPT" 0755
    copy_to_pve "$LOCAL_SERVICE" "$REMOTE_SERVICE" 0644
    copy_to_pve "$LOCAL_TIMER" "$REMOTE_TIMER" 0644
    enforce_storage_target
    enable_timer
    enforce_guest_datastore_contract
    run_preflight
    ;;
  *)
    echo "Usage: $0 [--check|--enforce]"
    exit 64
    ;;
esac
