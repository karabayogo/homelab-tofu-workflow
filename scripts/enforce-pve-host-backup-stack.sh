#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"

PVE_HOST="${PVE_HOST:-192.168.1.50}"
PVE_USER="${PVE_USER:-root}"
PVE_TARGET="${PVE_USER}@${PVE_HOST}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/pve-kai}"
SSH_OPTS=(
  -i "$SSH_KEY_PATH"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="${HOME}/.ssh/known_hosts"
)
PBS_HOST="${PBS_HOST:-192.168.1.247}"
PBS_PORT="${PBS_PORT:-8007}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REMOTE_SCRIPT="/root/bin/pve-host-config-backup-to-pbs.sh"
REMOTE_SERVICE="/etc/systemd/system/pve-host-config-backup-to-pbs.service"
REMOTE_TIMER="/etc/systemd/system/pve-host-config-backup-to-pbs.timer"

LOCAL_SCRIPT="${SCRIPT_DIR}/pve-host-config-backup-to-pbs.sh"
LOCAL_SERVICE="${SCRIPT_DIR}/pve-host-config-backup-to-pbs.service"
LOCAL_TIMER="${SCRIPT_DIR}/pve-host-config-backup-to-pbs.timer"

ssh_pve() {
  ssh "${SSH_OPTS[@]}" "$PVE_TARGET" "$@"
}

copy_to_pve() {
  local src="$1"
  local dest="$2"
  local mode="$3"
  local tmp

  tmp="/tmp/$(basename "$dest").codex.$$"
  scp "${SSH_OPTS[@]}" "$src" "${PVE_TARGET}:${tmp}" >/dev/null
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

run_preflight() {
  ssh_pve "${REMOTE_SCRIPT} --preflight"
  ssh_pve "pvesm status --storage pbs-primary"
}

case "$MODE" in
  --check)
    check_file "$LOCAL_SCRIPT" "$REMOTE_SCRIPT"
    check_file "$LOCAL_SERVICE" "$REMOTE_SERVICE"
    check_file "$LOCAL_TIMER" "$REMOTE_TIMER"
    check_storage_target
    run_preflight
    ;;
  --enforce)
    copy_to_pve "$LOCAL_SCRIPT" "$REMOTE_SCRIPT" 0755
    copy_to_pve "$LOCAL_SERVICE" "$REMOTE_SERVICE" 0644
    copy_to_pve "$LOCAL_TIMER" "$REMOTE_TIMER" 0644
    enforce_storage_target
    enable_timer
    run_preflight
    ;;
  *)
    echo "Usage: $0 [--check|--enforce]"
    exit 64
    ;;
esac
