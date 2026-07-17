#!/usr/bin/env bash
set -euo pipefail

umask 077

PBS_HOST="${PBS_HOST:-192.168.1.247}"
PBS_PORT="${PBS_PORT:-8007}"
PBS_DATASTORE="${PBS_DATASTORE:-primary}"
PBS_USERNAME="${PBS_USERNAME:-pve-backup@pbs!pve}"
PBS_REPOSITORY="${PBS_REPOSITORY:-${PBS_USERNAME}@${PBS_HOST}:${PBS_DATASTORE}}"
PBS_FINGERPRINT="${PBS_FINGERPRINT:-87:13:B2:80:41:B7:03:7F:4D:60:3E:28:74:E8:02:06:AF:BC:30:B1:73:09:E8:0E:BF:71:BA:E6:DC:7D:CA:24}"
PBS_PASSWORD_FILE="${PBS_PASSWORD_FILE:-/root/.config/pbs/pve-backup.token}"
PBS_NAMESPACE="${PBS_NAMESPACE:-}"
BACKUP_ID="${BACKUP_ID:-$(hostname -s)-config}"
STAGE_ROOT="${STAGE_ROOT:-/var/lib/pve-host-config-backup/current}"
TMP_STAGE="${STAGE_ROOT}.tmp"
LOCK_FILE="/var/lock/pve-host-config-backup-to-pbs.lock"

detect_duplicate_ip() {
  local route_dev
  local arping_output
  local macs

  command -v arping >/dev/null || return 0

  route_dev="$(ip route get "$PBS_HOST" 2>/dev/null | awk '/ dev / { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
  [[ -n "$route_dev" ]] || return 0

  arping_output="$(arping -c 4 -I "$route_dev" "$PBS_HOST" 2>/dev/null || true)"
  macs="$(
    awk '/reply from/ { print toupper($5) }' <<<"$arping_output" \
      | tr -d '[]' \
      | sort -u
  )"

  if [[ -n "$macs" ]]; then
    echo "[INFO] ARP responders for ${PBS_HOST}:"
    printf '  %s\n' $macs
  fi

  if [[ -n "$macs" ]] && [[ "$(wc -l <<<"$macs" | tr -d ' ')" -gt 1 ]]; then
    echo "[ERROR] Multiple MAC addresses responded for ${PBS_HOST}; likely duplicate IP conflict"
    return 1
  fi

  return 0
}

preflight_pbs_endpoint() {
  local url="https://${PBS_HOST}:${PBS_PORT}/api2/json/version"
  local http_code

  http_code="$(curl -ksS -o /dev/null -w '%{http_code}' --connect-timeout 5 "$url" || true)"
  if [[ "$http_code" == "200" || "$http_code" == "401" ]]; then
    echo "[OK] PBS API endpoint reachable at ${url}"
    return 0
  fi

  echo "[ERROR] PBS API endpoint unreachable at ${url} (http_code=${http_code:-none})"
  detect_duplicate_ip || return 1
  return 1
}

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

command -v curl >/dev/null || {
  echo "[ERROR] curl is not installed"
  exit 12
}

[[ -s "$PBS_PASSWORD_FILE" ]] || {
  echo "[ERROR] Missing PBS token file: $PBS_PASSWORD_FILE"
  exit 11
}

case "${1:-}" in
  --preflight)
    preflight_pbs_endpoint
    exit 0
    ;;
  ""|--backup)
    ;;
  *)
    echo "Usage: $0 [--preflight|--backup]"
    exit 64
    ;;
esac

export PBS_REPOSITORY
export PBS_FINGERPRINT
export PBS_PASSWORD
PBS_PASSWORD="$(<"$PBS_PASSWORD_FILE")"

preflight_pbs_endpoint

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
