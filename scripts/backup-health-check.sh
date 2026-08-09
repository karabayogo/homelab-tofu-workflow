#!/usr/bin/env bash
set -euo pipefail

SYNOLOGY_SHARE_MOUNT="${SYNOLOGY_SHARE_MOUNT:-/mnt/synology/proxmoxbackups}"
SYNOLOGY_BACKUP_ROOT="${SYNOLOGY_BACKUP_ROOT:-${SYNOLOGY_SHARE_MOUNT}/homelab_backups}"
DISCORD_CHANNEL_ID="${DISCORD_CHANNEL_ID:-channel:1479668391169097891}"
SECRETS_JSON="${SECRETS_JSON:-/home/moltbot/.openclaw/secrets.json}"
SCRIPT_NAME="backup-health-check"

resolve_discord_token() {
  if [[ "${DISCORD_BOT_TOKEN:-}" != "" && "${DISCORD_BOT_TOKEN}" != "__REF__"* ]]; then
    return 0
  fi
  if [[ ! -f "$SECRETS_JSON" ]]; then
    return 0
  fi
  DISCORD_BOT_TOKEN="$({
    python3 - <<'PY'
import json
from pathlib import Path

path = Path('/home/moltbot/.openclaw/secrets.json')
if not path.exists():
    print('')
    raise SystemExit

data = json.loads(path.read_text())
print(data.get('env', {}).get('DISCORD_BOT_TOKEN', ''))
PY
  })"
  export DISCORD_BOT_TOKEN
}

send_alert() {
  local prefix="$1" description="$2" color="${3:-16726822}"
  resolve_discord_token
  if [[ -z "${DISCORD_BOT_TOKEN:-}" ]]; then
    echo "[${SCRIPT_NAME}] Warning: DISCORD_BOT_TOKEN not available"
    return 0
  fi

  local payload now
  now="$(date -Iseconds)"
  payload="$(python3 - "$prefix" "$description" "$color" "$SCRIPT_NAME" "$now" <<'PY'
import json
import sys
prefix, description, color, script_name, now = sys.argv[1:6]
print(json.dumps({
    "content": prefix,
    "embeds": [{
        "title": prefix,
        "description": description,
        "color": int(color),
        "footer": {"text": f"{script_name} {now}"},
    }],
}))
PY
)"

  curl -sf -X POST \
    -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://discord.com/api/v10/channels/${DISCORD_CHANNEL_ID}/messages" >/dev/null 2>&1 || \
    echo "[${SCRIPT_NAME}] Warning: Discord alert delivery failed"
}

latest_file() {
  local dir="$1" glob="$2"
  find "$dir" -maxdepth 1 -type f -name "$glob" -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk 'NR == 1 { print $2 }'
}

latest_dir() {
  local dir="$1"
  find "$dir" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk 'NR == 1 { print $2 }'
}

age_seconds() {
  local path="$1"
  echo $(( $(date +%s) - $(stat -c %Y "$path") ))
}

check_artifact() {
  local label="$1" dir="$2" glob="$3" max_age="$4"
  shift 4
  local file base age

  file="$(latest_file "$dir" "$glob")"
  if [[ -z "$file" ]]; then
    FAILURES+=("${label}: missing artifact in ${dir}")
    return
  fi
  if [[ ! -s "$file" ]]; then
    FAILURES+=("${label}: empty artifact $(basename "$file")")
    return
  fi

  age="$(age_seconds "$file")"
  if (( age > max_age )); then
    FAILURES+=("${label}: stale artifact $(basename "$file") age=${age}s limit=${max_age}s")
  fi

  base="$file"
  case "$file" in
    *.zfs.zst) base="${file%.zfs.zst}" ;;
    *.tar.zst) base="${file%.tar.zst}" ;;
    *.unifi) base="${file%.unifi}" ;;
  esac

  while (($#)); do
    local required="$1"
    shift
    if [[ ! -s "${base}${required}" ]]; then
      FAILURES+=("${label}: missing companion ${base}${required}")
    fi
  done
}

check_pbs_group() {
  local label="$1" dir="$2" max_age="$3"
  local snapshot age

  snapshot="$(latest_dir "$dir")"
  if [[ -z "$snapshot" ]]; then
    FAILURES+=("${label}: missing snapshot group in ${dir}")
    return
  fi
  age="$(age_seconds "$snapshot")"
  if (( age > max_age )); then
    FAILURES+=("${label}: stale snapshot $(basename "$snapshot") age=${age}s limit=${max_age}s")
  fi
  if [[ ! -s "$snapshot/index.json.blob" ]]; then
    FAILURES+=("${label}: missing index.json.blob in $(basename "$snapshot")")
  fi
  if ! find "$snapshot" -maxdepth 1 -type f \( -name '*.didx' -o -name '*.fidx' -o -name 'client.log.blob' -o -name 'qemu-server.conf.blob' \) | grep -q .; then
    FAILURES+=("${label}: snapshot $(basename "$snapshot") has no payload index files")
  fi
}

declare -a FAILURES=()

mountpoint -q "$SYNOLOGY_SHARE_MOUNT" || {
  send_alert "CRITICAL" "Backup share is not mounted at ${SYNOLOGY_SHARE_MOUNT}"
  echo "[ERROR] Backup share is not mounted at ${SYNOLOGY_SHARE_MOUNT}"
  exit 1
}

check_artifact "PVE host root" "${SYNOLOGY_BACKUP_ROOT}/pve/host-root" "*.zfs.zst" $((36 * 3600)) ".zfs.zst.sha256" ".meta.tgz" ".meta.tgz.sha256"
check_artifact "VM 201 rootfs" "${SYNOLOGY_BACKUP_ROOT}/pve/vm-201-rootfs" "*.tar.zst" $((8 * 24 * 3600)) ".tar.zst.sha256" ".meta.tgz" ".meta.tgz.sha256"
check_artifact "UniFi UCG" "${SYNOLOGY_BACKUP_ROOT}/unifi" "*.unifi" $((36 * 3600))
check_artifact "PBS state manifest" "${SYNOLOGY_BACKUP_ROOT}/pve/pbs-primary/config" "latest-state.txt" $((36 * 3600))

pbs_root="${SYNOLOGY_BACKUP_ROOT}/pve/pbs-primary/datastore"
[[ -d "$pbs_root/.chunks" ]] || FAILURES+=("PBS datastore mirror: missing ${pbs_root}/.chunks")
check_pbs_group "PBS host/pve-config" "$pbs_root/host/pve-config" $((36 * 3600))
check_pbs_group "PBS vm/201" "$pbs_root/vm/201" $((36 * 3600))
check_pbs_group "PBS vm/300" "$pbs_root/vm/300" $((36 * 3600))
check_pbs_group "PBS vm/906" "$pbs_root/vm/906" $((36 * 3600))

if (( ${#FAILURES[@]} > 0 )); then
  printf '[ERROR] %s\n' "${FAILURES[@]}"
  description="$(printf '%s\n' "${FAILURES[@]}" | sed ':a;N;$!ba;s/\n/\\n/g')"
  send_alert "CRITICAL" "$description"
  exit 1
fi

echo "[OK] Backup health checks passed"
