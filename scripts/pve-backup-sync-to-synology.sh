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
PBS_DATASTORE_STAGING="${PBS_DEST_ROOT}/datastore.next"
PBS_DATASTORE_PREV="${PBS_DEST_ROOT}/datastore.prev"
PBS_CONFIG_DEST="${PBS_DEST_ROOT}/config"
PBS_CONFIG_STAGING="${PBS_DEST_ROOT}/config.next"
PBS_CONFIG_PREV="${PBS_DEST_ROOT}/config.prev"
TAG="pve-backup-sync-to-synology"
LOCK_FILE="/tmp/${TAG}.lock"
TMP_DIR="$(mktemp -d "/tmp/${TAG}.XXXXXX")"
INCLUDE_LIST="$TMP_DIR/pbs-curated-files.txt"
LATEST_STATE_FILE="$TMP_DIR/latest-state.txt"

cleanup() {
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[WARN] Another ${TAG} run is in progress; skipping"
  exit 0
fi

command -v rsync >/dev/null || { echo "[ERROR] rsync not available locally"; exit 11; }
command -v ssh >/dev/null || { echo "[ERROR] ssh not available"; exit 12; }
ssh "${SSH_OPTS[@]}" "$PBS_SSH_TARGET" 'command -v rsync >/dev/null && command -v proxmox-backup-debug >/dev/null' || {
  echo "[ERROR] rsync/proxmox-backup-debug not available on PBS guest ${PBS_SSH_TARGET}"
  exit 15
}
mountpoint -q "$SYNOLOGY_SHARE_MOUNT" || { echo "[ERROR] Synology share is not mounted: $SYNOLOGY_SHARE_MOUNT"; exit 13; }
[[ -w "$SYNOLOGY_BACKUP_ROOT" ]] || { echo "[ERROR] Synology backup root is not writable: $SYNOLOGY_BACKUP_ROOT"; exit 14; }

install -d -m 0770 "$HOST_ROOT_DEST" "$VM201_DEST" "$PBS_DEST_ROOT"

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

build_pbs_curated_file_list() {
  ssh "${SSH_OPTS[@]}" "$PBS_SSH_TARGET" 'bash -s' <<'EOF' > "$INCLUDE_LIST"
set -euo pipefail
ROOT="/srv/proxmox-backup-primary/datastore"
groups=(host/pve-config vm/201 vm/300 vm/906)
declare -A chunks=()
for group in "${groups[@]}"; do
  latest=""
  while IFS= read -r candidate; do
    [[ -f "$candidate/index.json.blob" ]] || continue
    latest="$candidate"
  done < <(find "$ROOT/$group" -maxdepth 1 -mindepth 1 -type d | sort)
  if [[ -z "$latest" ]]; then
    echo "missing latest complete snapshot for $group" >&2
    exit 1
  fi
  rel_dir="${latest#"$ROOT/"}"
  echo "$rel_dir/"
  while IFS= read -r file; do
    rel_file="${file#"$ROOT/"}"
    echo "$rel_file"
    case "$file" in
      *.didx|*.fidx)
        while IFS= read -r chunk; do
          [[ -n "$chunk" ]] || continue
          chunks[".chunks/${chunk:0:4}/$chunk"]=1
        done < <(proxmox-backup-debug inspect file "$file" | sed -n 's/^  "\([0-9a-f]\{64\}\)"$/\1/p')
        ;;
    esac
  done < <(find "$latest" -maxdepth 1 -type f | sort)
done
for path in "${!chunks[@]}"; do
  echo "$path"
done | sort
EOF
}

capture_pbs_state_manifest() {
  ssh "${SSH_OPTS[@]}" "$PBS_SSH_TARGET" '
    set -e
    {
      echo "timestamp=$(date -Is)"
      echo "hostname=$(hostname)"
      echo "sync_scope=latest-management-plane-snapshots"
      echo "== datastore =="
      proxmox-backup-manager datastore show primary --output-format json-pretty
      echo "== prune-jobs =="
      proxmox-backup-manager prune-job list --output-format json-pretty
      echo "== verify-jobs =="
      proxmox-backup-manager verify-job list --output-format json-pretty
      echo "== sync-jobs =="
      proxmox-backup-manager sync-job list --output-format json-pretty
      echo "== latest-host-group =="
      latest=""; while read -r d; do [[ -f "$d/index.json.blob" ]] && latest="$d"; done < <(find /srv/proxmox-backup-primary/datastore/host/pve-config -maxdepth 1 -mindepth 1 -type d | sort); printf "%s\n" "$latest"
      echo "== latest-vm201-group =="
      latest=""; while read -r d; do [[ -f "$d/index.json.blob" ]] && latest="$d"; done < <(find /srv/proxmox-backup-primary/datastore/vm/201 -maxdepth 1 -mindepth 1 -type d | sort); printf "%s\n" "$latest"
      echo "== latest-vm300-group =="
      latest=""; while read -r d; do [[ -f "$d/index.json.blob" ]] && latest="$d"; done < <(find /srv/proxmox-backup-primary/datastore/vm/300 -maxdepth 1 -mindepth 1 -type d | sort); printf "%s\n" "$latest"
      echo "== latest-vm906-group =="
      latest=""; while read -r d; do [[ -f "$d/index.json.blob" ]] && latest="$d"; done < <(find /srv/proxmox-backup-primary/datastore/vm/906 -maxdepth 1 -mindepth 1 -type d | sort); printf "%s\n" "$latest"
    }
  ' > "$LATEST_STATE_FILE"
}

promote_staging_tree() {
  local staging="$1" final="$2" prev="$3"
  local ts trash
  # Collision-proof trash name: nanosecond timestamp plus loop-until-free.
  # A plain date +%s made two promote cycles in the same second nest the tree
  # inside a retained .stale dir and abort the sync mid-promotion (caught by
  # the 2026-09-02 rollover simulation; retained trash + same-second re-run).
  ts="$(date +%s%N 2>/dev/null || date +%s)"
  while [[ -e "${prev}.stale.${ts}" ]]; do
    ts=$((ts + 1))
  done
  if [[ -e "$prev" ]]; then
    trash="${prev}.stale.${ts}"
    mv "$prev" "$trash"
    echo "[WARN] Preserved older previous tree at ${trash} for out-of-band cleanup"
  fi
  if [[ -e "$final" ]]; then
    mv "$final" "$prev"
  fi
  mv "$staging" "$final"
}

prune_stale_rollover_dirs() {
  local prev="$1" keep="${2:-2}"
  local parent pattern
  parent="$(dirname "$prev")"
  pattern="$(basename "$prev").stale.*"

  mapfile -t stale_dirs < <(
    find "$parent" -maxdepth 1 -mindepth 1 -type d -name "$pattern" -printf '%T@\t%p\n' \
      | sort -nr \
      | cut -f2-
  )

  if (( ${#stale_dirs[@]} <= keep )); then
    return 0
  fi

  for old in "${stale_dirs[@]:keep}"; do
    echo "[INFO] Pruning stale rollover tree ${old}"
    rm -rf -- "$old"
  done
}

echo "[INFO] Syncing ${PVE_SSH_HOST}:/var/lib/vz/host-image -> ${HOST_ROOT_DEST}"
rsync -a --delete \
  --include='*/' \
  --include='*.zfs.zst' \
  --include='*.zfs.zst.sha256' \
  --include='*.meta.tgz' \
  --include='*.meta.tgz.sha256' \
  --exclude='*' \
  -e "${RSYNC_SSH[*]}" \
  "${PVE_SSH_HOST}:/var/lib/vz/host-image/" "${HOST_ROOT_DEST}/"

mirror_local_dir_to_share "$VM201_LOCAL_DIR" "$VM201_DEST"

echo "[INFO] Building curated PBS DR file list"
build_pbs_curated_file_list
capture_pbs_state_manifest

rm -rf -- "$PBS_DATASTORE_STAGING" "$PBS_CONFIG_STAGING"
mkdir -p "$PBS_DATASTORE_STAGING" "$PBS_CONFIG_STAGING"

echo "[INFO] Syncing curated latest PBS snapshots + referenced chunks"
rsync -aH \
  --files-from="$INCLUDE_LIST" \
  -e "${RSYNC_SSH[*]}" \
  "${PBS_SSH_TARGET}:/srv/proxmox-backup-primary/datastore/" "${PBS_DATASTORE_STAGING}/"

# Chunk manifest for orphan GC: --files-from only prunes directories rsync
# walks, so chunks dropped from the curated set would otherwise accumulate
# on the mirror forever (2026-09-02 RCA: .chunks had grown to 71G vs ~8G of
# live payload). The manifest travels with the tree; promote_staging_tree
# then GCs the promoted tree against it.
awk '/^\.chunks\// { print }' "$INCLUDE_LIST" > "$PBS_DATASTORE_STAGING/.chunk-manifest.txt"
chunk_total=$(wc -l < "$PBS_DATASTORE_STAGING/.chunk-manifest.txt")
echo "[INFO] Chunk manifest written: ${chunk_total} live chunks"

echo "[INFO] Syncing ${PBS_SSH_TARGET}:/etc/proxmox-backup -> ${PBS_CONFIG_STAGING}/etc-proxmox-backup"
rsync -a --delete \
  -e "${RSYNC_SSH[*]}" \
  "${PBS_SSH_TARGET}:/etc/proxmox-backup/" "${PBS_CONFIG_STAGING}/etc-proxmox-backup/"
cp "$LATEST_STATE_FILE" "$PBS_CONFIG_STAGING/latest-state.txt"

promote_staging_tree "$PBS_DATASTORE_STAGING" "$PBS_DATASTORE_DEST" "$PBS_DATASTORE_PREV"
promote_staging_tree "$PBS_CONFIG_STAGING" "$PBS_CONFIG_DEST" "$PBS_CONFIG_PREV"
# Rollback generations are load-bearing: datastore.prev / config.prev are the
# guard against promoting a structurally-valid-but-corrupt upstream sync, and
# .stale.* trees are older rollback generations. Never rm -rf prev after
# promotion (that leaves zero rollback and defeats the rollover design);
# bound disk usage instead by pruning .stale.* beyond keep=2.
# 2026-09-02 RCA: deployed version never pruned .stale.* — one full curated
# tree (~18 GiB) accumulated per day and drove the Synology share to 60%.
prune_stale_rollover_dirs "$PBS_DATASTORE_PREV" 2
prune_stale_rollover_dirs "$PBS_CONFIG_PREV" 2

# Orphan-chunk GC on the promoted tree (see manifest write above): remove any
# chunk file NOT in the current curated manifest. Walk bottom-up so emptied
# chunk-level dirs are removed too. prev-generation trees keep their own
# (possibly older) chunks until their rollover prune — that is fine.
MANIFEST="$PBS_DATASTORE_DEST/.chunk-manifest.txt"
if [[ -s "$MANIFEST" ]]; then
  removed=0
  while IFS= read -r -d '' live_dir; do
    rel_live="${live_dir#"$PBS_DATASTORE_DEST/"}"
    while IFS= read -r -d '' chunk_file; do
      rel_chunk="${chunk_file#"$PBS_DATASTORE_DEST/"}"
      if ! grep -qxF "$rel_chunk" "$MANIFEST"; then
        rm -f -- "$chunk_file"
        removed=$((removed + 1))
      fi
    done < <(find "$live_dir" -maxdepth 1 -type f -print0)
  done < <(find "$PBS_DATASTORE_DEST/.chunks" -mindepth 1 -maxdepth 1 -type d -print0)
  # drop now-empty chunk subdirs
  find "$PBS_DATASTORE_DEST/.chunks" -mindepth 1 -maxdepth 1 -type d -empty -delete
  echo "[INFO] Orphan chunk GC: removed ${removed} chunks not in curated manifest"
else
  echo "[WARN] No chunk manifest in promoted tree — skipping orphan chunk GC"
fi

prune_verified_local_tree "$VM201_LOCAL_DIR" "$VM201_DEST"

echo "[OK] Synology sync completed"
