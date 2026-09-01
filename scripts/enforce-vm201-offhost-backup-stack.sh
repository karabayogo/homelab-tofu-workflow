#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"

PVE_HOST="${PVE_HOST:-192.168.1.50}"
PVE_USER="${PVE_USER:-root}"
PVE_TARGET="${PVE_USER}@${PVE_HOST}"
PVE_VM_ID="${PVE_VM_ID:-201}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/pve-kai}"
SSH_OPTS=(
  -n
  -i "$SSH_KEY_PATH"
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OFFHOST_SCRIPT_LOCAL="$SCRIPT_DIR/pve-backup-sync-to-synology.sh"
HEALTH_SCRIPT_LOCAL="$SCRIPT_DIR/backup-health-check.sh"
RESTORE_SCRIPT_LOCAL="$SCRIPT_DIR/backup-restore-drill.sh"
UNIFI_SCRIPT_LOCAL="$SCRIPT_DIR/unifi-backup-to-synology.sh"
OFFHOST_SERVICE_LOCAL="$SCRIPT_DIR/pve-backup-sync-to-synology.service"
OFFHOST_TIMER_LOCAL="$SCRIPT_DIR/pve-backup-sync-to-synology.timer"
HEALTH_SERVICE_LOCAL="$SCRIPT_DIR/backup-health-check.service"
HEALTH_TIMER_LOCAL="$SCRIPT_DIR/backup-health-check.timer"
RESTORE_SERVICE_LOCAL="$SCRIPT_DIR/backup-restore-drill.service"
RESTORE_TIMER_LOCAL="$SCRIPT_DIR/backup-restore-drill.timer"
UNIFI_SERVICE_LOCAL="$SCRIPT_DIR/unifi-backup-to-synology.service"
UNIFI_TIMER_LOCAL="$SCRIPT_DIR/unifi-backup-to-synology.timer"

OFFHOST_SCRIPT_REMOTE="/usr/local/sbin/pve-backup-sync-to-synology.sh"
HEALTH_SCRIPT_REMOTE="/usr/local/sbin/backup-health-check.sh"
RESTORE_SCRIPT_REMOTE="/usr/local/sbin/backup-restore-drill.sh"
UNIFI_SCRIPT_REMOTE="/usr/local/sbin/unifi-backup-to-synology.sh"
OFFHOST_SERVICE_REMOTE="/etc/systemd/system/pve-backup-sync-to-synology.service"
OFFHOST_TIMER_REMOTE="/etc/systemd/system/pve-backup-sync-to-synology.timer"
HEALTH_SERVICE_REMOTE="/etc/systemd/system/backup-health-check.service"
HEALTH_TIMER_REMOTE="/etc/systemd/system/backup-health-check.timer"
RESTORE_SERVICE_REMOTE="/etc/systemd/system/backup-restore-drill.service"
RESTORE_TIMER_REMOTE="/etc/systemd/system/backup-restore-drill.timer"
UNIFI_SERVICE_REMOTE="/etc/systemd/system/unifi-backup-to-synology.service"
UNIFI_TIMER_REMOTE="/etc/systemd/system/unifi-backup-to-synology.timer"

ssh_pve() {
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "$PVE_TARGET" "$@"
}

guest_exec() {
  local guest_cmd="$1"
  local quoted_cmd
  local raw_output
  printf -v quoted_cmd '%q' "$guest_cmd"
  raw_output="$(ssh_pve "qm guest exec ${PVE_VM_ID} -- bash -lc ${quoted_cmd}")"
  printf '%s' "$raw_output" | python3 -c 'import json, sys; data = json.load(sys.stdin); sys.stdout.write(data.get("out-data", "")); raise SystemExit(data.get("exitcode", 1))'
}

local_sha() {
  sha256sum "$1" | awk '{print $1}'
}

remote_sha() {
  local path="$1"
  guest_exec "sha256sum '$path' 2>/dev/null | awk '{print \$1}' || true"
}

copy_to_guest() {
  local src="$1" dest="$2" mode="$3"
  local payload
  payload="$(base64 -w0 "$src")"
  guest_exec "install -d -m 0755 '$(dirname "$dest")' && base64 -d > '$dest' <<'EOF'
${payload}
EOF
chmod ${mode} '$dest'"
}

check_file() {
  local local_path="$1" remote_path="$2"
  local expected actual
  expected="$(local_sha "$local_path")"
  actual="$(remote_sha "$remote_path")"
  if [[ "$expected" != "$actual" ]]; then
    echo "[ERROR] Drift detected for ${remote_path}"
    return 1
  fi
  echo "[OK] ${remote_path} matches repo"
}

check_runtime() {
  guest_exec 'mountpoint -q /mnt/synology/proxmoxbackups'
  guest_exec 'systemctl is-enabled pve-backup-sync-to-synology.timer backup-health-check.timer backup-restore-drill.timer unifi-backup-to-synology.timer >/dev/null'
  guest_exec 'systemctl is-active pve-backup-sync-to-synology.timer backup-health-check.timer backup-restore-drill.timer unifi-backup-to-synology.timer >/dev/null'
  # Producer failure detection (2026-09-02 RCA: unifi-backup-to-synology
  # failed 203/EXEC daily for 4 days with timer active — only a last-run
  # state check catches "runs and fails" producers).
  guest_exec 'systemctl is-failed pve-backup-sync-to-synology.service backup-health-check.service backup-restore-drill.service unifi-backup-to-synology.service >/dev/null; test $? -ne 0'
  echo '[OK] VM201 off-host backup timers are enabled, active, and no producer unit is failed'
}

enable_timers() {
  # reset-failed clears last-run failure state from BEFORE convergence
  # (e.g. units that failed daily under the broken pre-fix stack); the next
  # timer fire re-establishes real state. Without it, --enforce can never
  # converge when any producer is currently failed.
  guest_exec 'systemctl daemon-reload && systemctl enable --now pve-backup-sync-to-synology.timer backup-health-check.timer backup-restore-drill.timer unifi-backup-to-synology.timer && systemctl reset-failed pve-backup-sync-to-synology.service backup-health-check.service backup-restore-drill.service unifi-backup-to-synology.service'
}

case "$MODE" in
  --check)
    bash "$SCRIPT_DIR/validate-vm201-offhost-backup-contract.sh"
    check_file "$OFFHOST_SCRIPT_LOCAL" "$OFFHOST_SCRIPT_REMOTE"
    check_file "$HEALTH_SCRIPT_LOCAL" "$HEALTH_SCRIPT_REMOTE"
    check_file "$RESTORE_SCRIPT_LOCAL" "$RESTORE_SCRIPT_REMOTE"
    check_file "$UNIFI_SCRIPT_LOCAL" "$UNIFI_SCRIPT_REMOTE"
    check_file "$OFFHOST_SERVICE_LOCAL" "$OFFHOST_SERVICE_REMOTE"
    check_file "$OFFHOST_TIMER_LOCAL" "$OFFHOST_TIMER_REMOTE"
    check_file "$HEALTH_SERVICE_LOCAL" "$HEALTH_SERVICE_REMOTE"
    check_file "$HEALTH_TIMER_LOCAL" "$HEALTH_TIMER_REMOTE"
    check_file "$RESTORE_SERVICE_LOCAL" "$RESTORE_SERVICE_REMOTE"
    check_file "$RESTORE_TIMER_LOCAL" "$RESTORE_TIMER_REMOTE"
    check_file "$UNIFI_SERVICE_LOCAL" "$UNIFI_SERVICE_REMOTE"
    check_file "$UNIFI_TIMER_LOCAL" "$UNIFI_TIMER_REMOTE"
    check_runtime
    ;;
  --enforce)
    bash "$SCRIPT_DIR/validate-vm201-offhost-backup-contract.sh"
    copy_to_guest "$OFFHOST_SCRIPT_LOCAL" "$OFFHOST_SCRIPT_REMOTE" 0755
    copy_to_guest "$HEALTH_SCRIPT_LOCAL" "$HEALTH_SCRIPT_REMOTE" 0755
    copy_to_guest "$RESTORE_SCRIPT_LOCAL" "$RESTORE_SCRIPT_REMOTE" 0755
    copy_to_guest "$UNIFI_SCRIPT_LOCAL" "$UNIFI_SCRIPT_REMOTE" 0755
    copy_to_guest "$OFFHOST_SERVICE_LOCAL" "$OFFHOST_SERVICE_REMOTE" 0644
    copy_to_guest "$OFFHOST_TIMER_LOCAL" "$OFFHOST_TIMER_REMOTE" 0644
    copy_to_guest "$HEALTH_SERVICE_LOCAL" "$HEALTH_SERVICE_REMOTE" 0644
    copy_to_guest "$HEALTH_TIMER_LOCAL" "$HEALTH_TIMER_REMOTE" 0644
    copy_to_guest "$RESTORE_SERVICE_LOCAL" "$RESTORE_SERVICE_REMOTE" 0644
    copy_to_guest "$RESTORE_TIMER_LOCAL" "$RESTORE_TIMER_REMOTE" 0644
    copy_to_guest "$UNIFI_SERVICE_LOCAL" "$UNIFI_SERVICE_REMOTE" 0644
    copy_to_guest "$UNIFI_TIMER_LOCAL" "$UNIFI_TIMER_REMOTE" 0644
    enable_timers
    check_runtime
    ;;
  *)
    echo "Usage: $0 [--check|--enforce]"
    exit 64
    ;;
esac
