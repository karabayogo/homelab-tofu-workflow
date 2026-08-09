#!/usr/bin/env bash
set -euo pipefail

PVE_SSH_HOST="${PVE_SSH_HOST:-pve-backupsync}"
PBS_SSH_TARGET="${PBS_SSH_TARGET:-root@192.168.1.247}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
RSYNC_SSH=(ssh "${SSH_OPTS[@]}")

VM201_LOCAL_DIR="${VM201_LOCAL_DIR:-$HOME/pve-guest-backups/vm201-rootfs}"
SYNOLOGY_SHARE_MOUNT="${SYNOLOGY_SHARE_MOUNT:-/mnt/synology/proxmoxbackups}"
SYNOLOGY_BACKUP_ROOT="${SYNOLOGY_BACKUP_ROOT:-${SYNOLOGY_SHARE_MOUNT}/homelab_backups}"
HOST_ROOT_DEST="${SYNOLOGY_BACKUP_ROOT}/pve/host-root"
VM201_DEST="${SYNOLOGY_BACKUP_ROOT}/pve/vm-201-rootfs"
PBS_DEST_ROOT="${SYNOLOGY_BACKUP_ROOT}/pve/pbs-primary"
PBS_DATASTORE_DEST="${PBS_DEST_ROOT}/datastore"
PBS_CONFIG_DEST="${PBS_DEST_ROOT}/config"
TAG="pve-backup-sync-to-synology"
LOCK_FILE="/tmp/${TAG}.lock"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[WARN] Another ${TAG} run is in progress; skipping"
  exit 0
fi

command -v rsync >/dev/null || { echo "[ERROR] rsync not available locally"; exit 11; }
command -v ssh >/dev/null || { echo "[ERROR] ssh not available"; exit 12; }
ssh "${SSH_OPTS[@]}" "$PBS_SSH_TARGET" 'command -v rsync >/dev/null' || { echo "[ERROR] rsync not available on PBS guest ${PBS_SSH_TARGET}"; exit 15; }
mountpoint -q "$SYNOLOGY_SHARE_MOUNT" || { echo "[ERROR] Synology share is not mounted: $SYNOLOGY_SHARE_MOUNT"; exit 13; }
[[ -w "$SYNOLOGY_BACKUP_ROOT" ]] || { echo "[ERROR] Synology backup root is not writable: $SYNOLOGY_BACKUP_ROOT"; exit 14; }

install -d -m 0770 "$HOST_ROOT_DEST" "$VM201_DEST" "$PBS_DATASTORE_DEST" "$PBS_CONFIG_DEST"

mirror_local_dir_to_share() {
  local local_dir="$1" dest_dir="$2"
  if ! find "$local_dir" -maxdepth 1 -type f | grep -q .; then
    echo "[WARN] No files found in ${local_dir}; leaving ${dest_dir} untouched"
    return 0
  fi
  echo "[INFO] Mirroring ${local_dir} -> ${dest_dir}"
  rsync -a --delete "$local_dir"/ "$dest_dir"/
}

sha_record() {
  local sha_file="$1"
  awk 'NF {print $1; exit}' "$sha_file" 2>/dev/null || true
}

verified_copy_exists() {
  local local_file="$1" dest_root="$2" base size candidate
  base="$(basename "$local_file")"
  size="$(stat -c %s "$local_file")"
  while IFS= read -r -d '' candidate; do
    if [[ "$local_file" == *.sha256 ]]; then
      [[ "$(sha_record "$local_file")" == "$(sha_record "$candidate")" ]] && return 0
      continue
    fi
    if [[ -f "${local_file}.sha256" && -f "${candidate}.sha256" ]]; then
      [[ "$(sha_record "${local_file}.sha256")" == "$(sha_record "${candidate}.sha256")" ]] && return 0
      continue
    fi
    return 0
  done < <(find "$dest_root" -type f -name "$base" -size "${size}c" -print0 2>/dev/null)
  return 1
}

prune_verified_local_tree() {
  local local_root="$1" dest_root="$2" removed=0 freed=0 file bytes
  [[ -d "$local_root" ]] || return 0
  while IFS= read -r -d '' file; do
    if verified_copy_exists "$file" "$dest_root"; then
      bytes="$(stat -c %s "$file")"
      rm -f -- "$file"
      removed=$((removed + 1))
      freed=$((freed + bytes))
      echo "[INFO] Pruned verified local copy: ${file} (${bytes} bytes)"
    fi
  done < <(find "$local_root" -type f -print0 2>/dev/null)
  echo "[INFO] Verified prune ${local_root}: removed=${removed} freed_bytes=${freed}"
}

echo "[INFO] Syncing ${PVE_SSH_HOST}:/var/lib/vz/host-image -> ${HOST_ROOT_DEST}"
rsync -a --delete           --include='*/'           --include='*.zfs.zst'           --include='*.zfs.zst.sha256'           --include='*.meta.tgz'           --include='*.meta.tgz.sha256'           --exclude='*'           -e "${RSYNC_SSH[*]}"           "${PVE_SSH_HOST}:/var/lib/vz/host-image/" "${HOST_ROOT_DEST}/"

mirror_local_dir_to_share "$VM201_LOCAL_DIR" "$VM201_DEST"

echo "[INFO] Syncing ${PBS_SSH_TARGET}:/srv/proxmox-backup-primary/datastore -> ${PBS_DATASTORE_DEST}"
rsync -aH --delete --delete-delay --numeric-ids           -e "${RSYNC_SSH[*]}"           "${PBS_SSH_TARGET}:/srv/proxmox-backup-primary/datastore/" "${PBS_DATASTORE_DEST}/"

echo "[INFO] Syncing ${PBS_SSH_TARGET}:/etc/proxmox-backup -> ${PBS_CONFIG_DEST}/etc-proxmox-backup"
rsync -a --delete           -e "${RSYNC_SSH[*]}"           "${PBS_SSH_TARGET}:/etc/proxmox-backup/" "${PBS_CONFIG_DEST}/etc-proxmox-backup/"

echo "[INFO] Writing PBS state manifest"
ssh "${SSH_OPTS[@]}" "$PBS_SSH_TARGET" '
  set -e
  {
    echo "timestamp=$(date -Is)"
    echo "hostname=$(hostname)"
    echo "== datastore =="
    proxmox-backup-manager datastore show primary --output-format json-pretty
    echo "== prune-jobs =="
    proxmox-backup-manager prune-job list --output-format json-pretty
    echo "== verify-jobs =="
    proxmox-backup-manager verify-job list --output-format json-pretty
    echo "== sync-jobs =="
    proxmox-backup-manager sync-job list --output-format json-pretty
    echo "== latest-host-group =="
    find /srv/proxmox-backup-primary/datastore/host/pve-config -maxdepth 1 -mindepth 1 -type d | sort | tail -1
    echo "== latest-vm201-group =="
    find /srv/proxmox-backup-primary/datastore/vm/201 -maxdepth 1 -mindepth 1 -type d | sort | tail -1
    echo "== latest-vm300-group =="
    find /srv/proxmox-backup-primary/datastore/vm/300 -maxdepth 1 -mindepth 1 -type d | sort | tail -1
    echo "== latest-vm906-group =="
    find /srv/proxmox-backup-primary/datastore/vm/906 -maxdepth 1 -mindepth 1 -type d | sort | tail -1
  }
' > "${PBS_CONFIG_DEST}/latest-state.txt"

prune_verified_local_tree "$VM201_LOCAL_DIR" "$VM201_DEST"

echo "[OK] Synology sync completed"
