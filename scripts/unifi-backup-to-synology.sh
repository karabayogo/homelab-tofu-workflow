#!/usr/bin/env bash
# unifi-backup-to-synology.sh — producer for the UniFi UCG off-host backup.
#
# Git-owned via enforce-vm201-offhost-backup-stack.sh. Credentials are NOT in
# Git: the unit passes EnvironmentFile=/etc/unifi-backup/unifi.env (root:root
# 0640 root:moltbot, provisioned out-of-band). Works standalone on VM201 or
# from any host that can reach the UniFi controller — set UNIFI_ENV_FILE to
# override.
set -euo pipefail

SYNOLOGY_SHARE_MOUNT="${SYNOLOGY_SHARE_MOUNT:-/mnt/synology/proxmoxbackups}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-${SYNOLOGY_SHARE_MOUNT}/homelab_backups/unifi}"
UNIFI_BASE_URL="${UNIFI_BASE_URL:-https://192.168.1.1}"
UNIFI_BACKUP_TARGET="${UNIFI_BACKUP_TARGET:-uos}"
UNIFI_ENV_FILE="${UNIFI_ENV_FILE:-/etc/unifi-backup/unifi.env}"
TMP_DIR="$(mktemp -d)"
COOKIE_JAR="$TMP_DIR/unifi_cookies.txt"
DOWNLOAD_HEADERS="$TMP_DIR/unifi_download_headers.txt"
DOWNLOAD_OUTPUT="$TMP_DIR/unifi_os_backup.bin"
SCRIPT_NAME="unifi-backup-to-synology"
backup_filename=""
backup_size=0

cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

alert_log() { echo "[${SCRIPT_NAME}][ALERT] $*"; }

extract_unifi_csrf_token() {
  local token payload remainder
  token=$(awk '$6 == "TOKEN" { print $7; exit }' "$COOKIE_JAR")
  [[ -n "$token" ]] || return 1
  payload=$(printf '%s' "$token" | cut -d. -f2)
  remainder=$(( ${#payload} % 4 ))
  case "$remainder" in
    0) ;;
    2) payload="${payload}==" ;;
    3) payload="${payload}=" ;;
    *) return 1 ;;
  esac
  printf '%s' "$payload" | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.csrfToken // empty'
}

get_header_value() {
  local header_name="$1"
  awk -v header_name="$header_name" '
    BEGIN { IGNORECASE = 1 }
    $0 ~ "^" header_name ":" {
      sub(/^[^:]+:[[:space:]]*/, "")
      sub(/\r$/, "")
      print
      exit
    }
  ' "$DOWNLOAD_HEADERS"
}

download_unifi_backup() {
  local login_http download_http csrf_token="" content_type body_preview=""
  local curl_args=()

  if [[ ! -r "$UNIFI_ENV_FILE" ]]; then
    alert_log "UniFi credential file not found or unreadable: $UNIFI_ENV_FILE"
    exit 1
  fi
  # shellcheck source=/etc/unifi-backup/unifi.env
  source "$UNIFI_ENV_FILE"
  if [[ -z "${UNIFI_USERNAME:-}" || -z "${UNIFI_PASSWORD:-}" ]]; then
    alert_log "UniFi credentials are missing from $UNIFI_ENV_FILE"
    exit 1
  fi

  local login_payload
  login_payload=$(jq -nc \
    --arg username "$UNIFI_USERNAME" \
    --arg password "$UNIFI_PASSWORD" \
    '{username: $username, password: $password}')

  echo "[INFO] Authenticating to UniFi OS at $UNIFI_BASE_URL..."
  login_http=$(curl -k -sS -o /dev/null -w "%{http_code}" -c "$COOKIE_JAR" \
    -X POST "$UNIFI_BASE_URL/api/auth/login" \
    -H "Content-Type: application/json" \
    -d "$login_payload")
  if [[ "$login_http" != "200" ]]; then
    alert_log "UniFi OS login failed with HTTP $login_http"
    exit 1
  fi

  csrf_token=$(extract_unifi_csrf_token || true)

  echo "[INFO] Downloading UniFi OS backup (.unifi)..."
  curl_args=(-k -sS -L -D "$DOWNLOAD_HEADERS" -o "$DOWNLOAD_OUTPUT" -w "%{http_code}" -b "$COOKIE_JAR")
  [[ -n "$csrf_token" ]] && curl_args+=(-H "X-Csrf-Token: $csrf_token")

  download_http=$(curl "${curl_args[@]}" "$UNIFI_BASE_URL/api/backup/download?target=$UNIFI_BACKUP_TARGET")
  if [[ "$login_http" != "200" || "$download_http" != "200" ]]; then
    alert_log "UniFi backup download failed (login=$login_http download=$download_http)"
    exit 1
  fi

  if [[ ! -s "$DOWNLOAD_OUTPUT" ]]; then
    alert_log "UniFi backup download returned an empty file"
    exit 1
  fi

  backup_filename=$(get_header_value "filename")
  if [[ -z "$backup_filename" ]]; then
    backup_filename="unifi_os_backup_$(date +%Y%m%d-%H%M%S).unifi"
  fi
  content_type=$(get_header_value "content-type")
  if [[ "$backup_filename" != *.unifi ]]; then
    alert_log "Unexpected UniFi backup filename: $backup_filename"
    exit 1
  fi
  if [[ "${content_type,,}" == text/html* ]]; then
    alert_log "UniFi backup download returned HTML instead of a .unifi file"
    exit 1
  fi
  if LC_ALL=C head -c 256 "$DOWNLOAD_OUTPUT" | grep -aqi '<html'; then
    alert_log "UniFi backup download appears to be an HTML login page, not a .unifi backup"
    exit 1
  fi

  mv "$DOWNLOAD_OUTPUT" "$TMP_DIR/$backup_filename"
  backup_size=$(stat -c %s "$TMP_DIR/$backup_filename")
  echo "[INFO] Download complete: $backup_filename (Size: $backup_size bytes)"
}

mountpoint -q "$SYNOLOGY_SHARE_MOUNT" || {
  alert_log "Synology backup share is not mounted at ${SYNOLOGY_SHARE_MOUNT}"
  exit 1
}
[[ -r "$UNIFI_ENV_FILE" ]] || {
  alert_log "UniFi credential file missing: $UNIFI_ENV_FILE"
  exit 1
}

install -d -m 0770 "$LOCAL_BACKUP_DIR"
download_unifi_backup

cp -f "$TMP_DIR/$backup_filename" "$LOCAL_BACKUP_DIR/$backup_filename"
sync "$LOCAL_BACKUP_DIR/$backup_filename" || true

find "$LOCAL_BACKUP_DIR" -maxdepth 1 -type f \( -name '*.unifi' -o -name '*.unf' \) -mtime +30 -delete

echo "[OK] UniFi backup successful: $LOCAL_BACKUP_DIR/$backup_filename"
