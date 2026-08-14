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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_CONF="${SCRIPT_DIR}/pve-zfs-arc-cap.conf"
REMOTE_CONF="/etc/modprobe.d/zfs.conf"

ssh_pve() {
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "$PVE_TARGET" "$@"
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

desired_arc_max() {
  awk -F'zfs_arc_max=' '/zfs_arc_max=/ {print $2; exit}' "$LOCAL_CONF" | tr -dc '0-9'
}

apply_live_arc_cap() {
  local target="$1"
  ssh_pve "TARGET_ARC_MAX='${target}' python3 - <<'PY'
from pathlib import Path
import os

target = os.environ['TARGET_ARC_MAX']
path = Path('/sys/module/zfs/parameters/zfs_arc_max')
current = path.read_text().strip()
if current != target:
    path.write_text(target)
print(path.read_text().strip())
PY"
}

check_live_arc_cap() {
  local target="$1"
  local actual
  actual="$(ssh_pve "cat /sys/module/zfs/parameters/zfs_arc_max")"
  if [[ "$actual" != "$target" ]]; then
    echo "[ERROR] live zfs_arc_max is ${actual:-unknown} but expected $target"
    return 1
  fi
  echo "[OK] live zfs_arc_max matches ${target}"
}

check_remote_config_value() {
  local target="$1"
  local actual
  actual="$(ssh_pve "python3 - <<'PY'
from pathlib import Path
import re
text = Path('/etc/modprobe.d/zfs.conf').read_text() if Path('/etc/modprobe.d/zfs.conf').exists() else ''
match = re.search(r'zfs_arc_max=(\\d+)', text)
print(match.group(1) if match else '')
PY")"
  if [[ "$actual" != "$target" ]]; then
    echo "[ERROR] remote zfs.conf declares ${actual:-unknown} but expected $target"
    return 1
  fi
  echo "[OK] remote zfs.conf declares ${target}"
}

report_runtime_state() {
  ssh_pve "python3 - <<'PY'
from pathlib import Path
stats = {}
for line in Path('/proc/spl/kstat/zfs/arcstats').read_text().splitlines()[2:]:
    parts = line.split()
    if len(parts) >= 3:
        stats[parts[0]] = int(parts[2])
for key in ('size', 'c_max', 'c_min'):
    value = stats.get(key, 0)
    print(f'{key}_mb={round(value / (1024 * 1024))}')
PY"
}

usage() {
  cat <<'EOF'
Usage:
  enforce-pve-zfs-arc-cap-contract.sh --enforce
  enforce-pve-zfs-arc-cap-contract.sh --check
EOF
}

TARGET_ARC_MAX="$(desired_arc_max)"
[[ -n "$TARGET_ARC_MAX" ]] || {
  echo "[ERROR] failed to parse zfs_arc_max from $LOCAL_CONF" >&2
  exit 1
}

case "$MODE" in
  --enforce)
    copy_to_pve "$LOCAL_CONF" "$REMOTE_CONF" 0644
    apply_live_arc_cap "$TARGET_ARC_MAX" >/dev/null
    ;;
  --check)
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

check_file "$LOCAL_CONF" "$REMOTE_CONF"
check_remote_config_value "$TARGET_ARC_MAX"
check_live_arc_cap "$TARGET_ARC_MAX"
report_runtime_state

echo "[OK] PVE ZFS ARC cap contract verified"
