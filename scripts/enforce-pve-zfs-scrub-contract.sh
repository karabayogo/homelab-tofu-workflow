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

REMOTE_SCRIPT="/root/bin/pve-zfs-bulkpool-scrub.sh"
REMOTE_SERVICE="/etc/systemd/system/pve-zfs-bulkpool-scrub.service"
REMOTE_TIMER="/etc/systemd/system/pve-zfs-bulkpool-scrub.timer"
REMOTE_CRON_FILE="/etc/cron.d/zfsutils-linux"

LOCAL_SCRIPT="${SCRIPT_DIR}/pve-zfs-bulkpool-scrub.sh"
LOCAL_SERVICE="${SCRIPT_DIR}/pve-zfs-bulkpool-scrub.service"
LOCAL_TIMER="${SCRIPT_DIR}/pve-zfs-bulkpool-scrub.timer"

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

disable_default_scrub_cron() {
  ssh_pve "python3 - <<'PY'
from pathlib import Path
path = Path('${REMOTE_CRON_FILE}')
lines = path.read_text().splitlines()
out = []
replaced = False
for line in lines:
    if '/usr/lib/zfs-linux/scrub' in line and not line.lstrip().startswith('#'):
        out.append('# Disabled by homelab-tofu-workflow: managed by pve-zfs-bulkpool-scrub.timer')
        out.append(f'# {line}')
        replaced = True
    else:
        out.append(line)
if not replaced and not any('managed by pve-zfs-bulkpool-scrub.timer' in line for line in lines):
    raise SystemExit('default scrub cron line not found in expected format')
path.write_text('\n'.join(out) + '\n')
PY"
}

check_scrub_cron_disabled() {
  local status
  status="$(ssh_pve "python3 - <<'PY'
from pathlib import Path
lines = Path('${REMOTE_CRON_FILE}').read_text().splitlines()
managed = any('managed by pve-zfs-bulkpool-scrub.timer' in line for line in lines)
active_default = any('/usr/lib/zfs-linux/scrub' in line and not line.lstrip().startswith('#') for line in lines)
print('disabled' if managed and not active_default else 'enabled')
PY")"
  if [[ "$status" != "disabled" ]]; then
    echo "[ERROR] default zfsutils scrub cron is still active"
    return 1
  fi
  echo "[OK] default zfsutils scrub cron is disabled in favor of managed timer"
}

enable_timer() {
  ssh_pve "systemctl daemon-reload && systemctl disable --now zfs-scrub-monthly@bulkpool.timer >/dev/null 2>&1 || true && systemctl enable --now pve-zfs-bulkpool-scrub.timer"
}

check_timer_enabled() {
  local status
  status="$(ssh_pve "systemctl is-enabled pve-zfs-bulkpool-scrub.timer")"
  [[ "$status" == "enabled" ]] || {
    echo "[ERROR] pve-zfs-bulkpool-scrub.timer is ${status:-unknown}"
    return 1
  }
  echo "[OK] pve-zfs-bulkpool-scrub.timer is enabled"
}

check_calendar() {
  ssh_pve "systemd-analyze calendar 'Sun *-*-08..14 13:24:00' >/dev/null"
  echo "[OK] managed scrub calendar parses on the host"
}

usage() {
  cat <<'EOF'
Usage:
  enforce-pve-zfs-scrub-contract.sh --enforce
  enforce-pve-zfs-scrub-contract.sh --check
EOF
}

case "$MODE" in
  --enforce)
    copy_to_pve "$LOCAL_SCRIPT" "$REMOTE_SCRIPT" 0755
    copy_to_pve "$LOCAL_SERVICE" "$REMOTE_SERVICE" 0644
    copy_to_pve "$LOCAL_TIMER" "$REMOTE_TIMER" 0644
    disable_default_scrub_cron
    enable_timer
    ;;
  --check)
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

check_file "$LOCAL_SCRIPT" "$REMOTE_SCRIPT"
check_file "$LOCAL_SERVICE" "$REMOTE_SERVICE"
check_file "$LOCAL_TIMER" "$REMOTE_TIMER"
check_scrub_cron_disabled
check_timer_enabled
check_calendar

echo "[OK] PVE ZFS scrub contract verified"
