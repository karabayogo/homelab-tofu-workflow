#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SYNC_SCRIPT="$SCRIPT_DIR/pve-backup-sync-to-synology.sh"
HEALTH_SCRIPT="$SCRIPT_DIR/backup-health-check.sh"
RESTORE_SCRIPT="$SCRIPT_DIR/backup-restore-drill.sh"
SERVICE_FILE="$SCRIPT_DIR/pve-backup-sync-to-synology.service"

test -f "$SYNC_SCRIPT"
test -f "$HEALTH_SCRIPT"
test -f "$RESTORE_SCRIPT"
test -f "$SERVICE_FILE"

grep -q '/srv/proxmox-backup-primary/datastore/' "$SYNC_SCRIPT"
grep -q '/etc/proxmox-backup/' "$SYNC_SCRIPT"
grep -q 'latest-state.txt' "$SYNC_SCRIPT"

grep -q 'PBS host/pve-config' "$HEALTH_SCRIPT"
grep -q 'PBS vm/300' "$HEALTH_SCRIPT"
if grep -q 'vzdump-qemu-300' "$HEALTH_SCRIPT"; then
  echo '[ERROR] stale direct-dump VM300 health contract found; off-host validation must follow PBS snapshots'
  exit 1
fi

grep -q 'pbs-primary/datastore/host/pve-config' "$RESTORE_SCRIPT"
grep -q 'pbs-primary/datastore/vm/906' "$RESTORE_SCRIPT"
grep -q 'ExecStart=/usr/local/sbin/pve-backup-sync-to-synology.sh' "$SERVICE_FILE"

echo '[OK] VM201 off-host backup contract is Git-managed and PBS-aware'
