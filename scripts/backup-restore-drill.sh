#!/usr/bin/env bash
set -euo pipefail

SYNOLOGY_SHARE_MOUNT="${SYNOLOGY_SHARE_MOUNT:-/mnt/synology/proxmoxbackups}"
SYNOLOGY_BACKUP_ROOT="${SYNOLOGY_BACKUP_ROOT:-${SYNOLOGY_SHARE_MOUNT}/homelab_backups}"
SCRIPT_NAME="backup-restore-drill"
TMP_DIR="$(mktemp -d "/tmp/${SCRIPT_NAME}.XXXXXX")"

cleanup() {
  local rc=$?
  rm -rf -- "$TMP_DIR"
  exit "$rc"
}
trap cleanup EXIT

latest_file() {
  local dir="$1" glob="$2"
  find "$dir" -maxdepth 1 -type f -name "$glob" -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk 'NR == 1 { print $2 }'
}

latest_dir() {
  local dir="$1"
  find "$dir" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk 'NR == 1 { print $2 }'
}

mountpoint -q "$SYNOLOGY_SHARE_MOUNT" || {
  echo "[ERROR] Backup share is not mounted at ${SYNOLOGY_SHARE_MOUNT}"
  exit 1
}

host_root="$(latest_file "${SYNOLOGY_BACKUP_ROOT}/pve/host-root" '*.zfs.zst')"
vm201="$(latest_file "${SYNOLOGY_BACKUP_ROOT}/pve/vm-201-rootfs" '*.tar.zst')"
unifi="$(latest_file "${SYNOLOGY_BACKUP_ROOT}/unifi" '*.unifi')"
pbs_state="$(latest_file "${SYNOLOGY_BACKUP_ROOT}/pve/pbs-primary/config" 'latest-state.txt')"
pbs_host="$(latest_dir "${SYNOLOGY_BACKUP_ROOT}/pve/pbs-primary/datastore/host/pve-config")"
pbs_vm201="$(latest_dir "${SYNOLOGY_BACKUP_ROOT}/pve/pbs-primary/datastore/vm/201")"
pbs_vm300="$(latest_dir "${SYNOLOGY_BACKUP_ROOT}/pve/pbs-primary/datastore/vm/300")"
pbs_vm906="$(latest_dir "${SYNOLOGY_BACKUP_ROOT}/pve/pbs-primary/datastore/vm/906")"

[[ -n "$host_root" && -n "$vm201" && -n "$unifi" && -n "$pbs_state" && -n "$pbs_host" && -n "$pbs_vm201" && -n "$pbs_vm300" && -n "$pbs_vm906" ]] || {
  echo "[ERROR] Missing one or more latest artifacts for restore drill"
  exit 1
}

zstd -t "$host_root" >/dev/null
tar -tzf "${host_root%.zfs.zst}.meta.tgz" | head -n 20 > "${TMP_DIR}/host-root-meta.lst"

head -c 65536 "$vm201" > /dev/null
tar -tzf "${vm201%.tar.zst}.meta.tgz" | head -n 20 > "${TMP_DIR}/vm201-meta.lst"

file "$unifi" > "${TMP_DIR}/unifi-filetype.txt"
sed -n '1,80p' "$pbs_state" > "${TMP_DIR}/pbs-state-snippet.txt"

for snapshot in "$pbs_host" "$pbs_vm201" "$pbs_vm300" "$pbs_vm906"; do
  test -s "$snapshot/index.json.blob"
  head -c 65536 "$snapshot/index.json.blob" > /dev/null
  payload_file="$(find "$snapshot" -maxdepth 1 -type f \( -name '*.didx' -o -name '*.fidx' -o -name 'client.log.blob' -o -name 'qemu-server.conf.blob' \) | head -n 1)"
  test -n "$payload_file"
  head -c 65536 "$payload_file" > /dev/null
done

echo "[OK] Restore drill completed"
echo "  host_root=$(basename "$host_root")"
echo "  vm201=$(basename "$vm201")"
echo "  unifi=$(basename "$unifi")"
echo "  pbs_host=$(basename "$pbs_host")"
echo "  pbs_vm201=$(basename "$pbs_vm201")"
echo "  pbs_vm300=$(basename "$pbs_vm300")"
echo "  pbs_vm906=$(basename "$pbs_vm906")"
