#!/usr/bin/env bash
set -euo pipefail

umask 077

PBS_REPOSITORY="${PBS_REPOSITORY:-pve-backup@pbs!pve@192.168.1.245:primary}"
PBS_FINGERPRINT="${PBS_FINGERPRINT:-87:13:B2:80:41:B7:03:7F:4D:60:3E:28:74:E8:02:06:AF:BC:30:B1:73:09:E8:0E:BF:71:BA:E6:DC:7D:CA:24}"
PBS_PASSWORD_FILE="${PBS_PASSWORD_FILE:-/root/.config/pbs/pve-backup.token}"
PBS_NAMESPACE="${PBS_NAMESPACE:-}"
BACKUP_ID="${BACKUP_ID:-$(hostname -s)-config}"
STAGE_ROOT="${STAGE_ROOT:-/var/lib/pve-host-config-backup/current}"
TMP_STAGE="${STAGE_ROOT}.tmp"
LOCK_FILE="/var/lock/pve-host-config-backup-to-pbs.lock"

copy_path() {
  local src="$1"
  local dest="$2"

  if [[ -e "$src" ]]; then
    install -d -m 0700 "$(dirname "$dest")"
    cp -a "$src" "$dest"
  fi
}

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[WARN] Another PVE host-config backup is already running; skipping"
  exit 0
fi

command -v proxmox-backup-client >/dev/null || {
  echo "[ERROR] proxmox-backup-client is not installed"
  exit 10
}

[[ -s "$PBS_PASSWORD_FILE" ]] || {
  echo "[ERROR] Missing PBS token file: $PBS_PASSWORD_FILE"
  exit 11
}

export PBS_REPOSITORY
export PBS_FINGERPRINT
export PBS_PASSWORD
PBS_PASSWORD="$(<"$PBS_PASSWORD_FILE")"

rm -rf "$TMP_STAGE"
install -d -m 0700 "$TMP_STAGE"

copy_path /etc/pve "$TMP_STAGE/etc/pve"
copy_path /etc/network "$TMP_STAGE/etc/network"
copy_path /etc/hosts "$TMP_STAGE/etc/hosts"
copy_path /etc/fstab "$TMP_STAGE/etc/fstab"
copy_path /etc/default/grub "$TMP_STAGE/etc/default/grub"
copy_path /etc/kernel "$TMP_STAGE/etc/kernel"
copy_path /etc/modprobe.d "$TMP_STAGE/etc/modprobe.d"
copy_path /etc/modules-load.d "$TMP_STAGE/etc/modules-load.d"
copy_path /etc/systemd/system "$TMP_STAGE/etc/systemd/system"
copy_path /usr/local/bin "$TMP_STAGE/usr/local/bin"
copy_path /root/bin "$TMP_STAGE/root/bin"

install -d -m 0700 "$TMP_STAGE/reports"
pveversion -v >"$TMP_STAGE/reports/pveversion.txt" 2>&1 || true
proxmox-boot-tool status >"$TMP_STAGE/reports/proxmox-boot-tool-status.txt" 2>&1 || true
zpool status rpool >"$TMP_STAGE/reports/zpool-status-rpool.txt" 2>&1 || true
zpool status bulkpool >"$TMP_STAGE/reports/zpool-status-bulkpool.txt" 2>&1 || true
zfs list -o name,used,avail,refer,mountpoint >"$TMP_STAGE/reports/zfs-list.txt" 2>&1 || true
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT >"$TMP_STAGE/reports/lsblk.txt" 2>&1 || true
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS >"$TMP_STAGE/reports/findmnt.txt" 2>&1 || true
qm list >"$TMP_STAGE/reports/qm-list.txt" 2>&1 || true
pvesm status >"$TMP_STAGE/reports/pvesm-status.txt" 2>&1 || true
cp /etc/pve/storage.cfg "$TMP_STAGE/reports/storage.cfg" 2>/dev/null || true
cp /etc/pve/jobs.cfg "$TMP_STAGE/reports/jobs.cfg" 2>/dev/null || true

for vmid in 201 300 905 906; do
  qm config "$vmid" >"$TMP_STAGE/reports/qm-config-${vmid}.txt" 2>&1 || true
done

printf 'timestamp=%s\nhostname=%s\n' "$(date -Is)" "$(hostname -s)" >"$TMP_STAGE/reports/manifest.txt"

rm -rf "$STAGE_ROOT"
mv "$TMP_STAGE" "$STAGE_ROOT"

backup_args=(
  host-config.pxar:"$STAGE_ROOT"
  --backup-type host
  --backup-id "$BACKUP_ID"
  --change-detection-mode data
)

if [[ -n "$PBS_NAMESPACE" ]]; then
  backup_args+=(--ns "$PBS_NAMESPACE")
fi

proxmox-backup-client backup "${backup_args[@]}"

echo "[OK] PVE host config backup uploaded to PBS repository $PBS_REPOSITORY namespace $PBS_NAMESPACE"
