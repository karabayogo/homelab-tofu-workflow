#!/usr/bin/env bash
set -euo pipefail

POOL="${1:-bulkpool}"

if ! zpool list -H "$POOL" >/dev/null 2>&1; then
  echo "[ERROR] zpool $POOL not found" >&2
  exit 1
fi

if zpool status "$POOL" | grep -q 'scan: scrub in progress'; then
  echo "[INFO] scrub already in progress for $POOL"
  zpool status "$POOL" | sed -n '1,12p'
  exit 0
fi

echo "[INFO] starting scrub for $POOL at $(date -Is)"
ionice -c2 -n7 nice -n 19 zpool scrub "$POOL"
zpool status "$POOL" | sed -n '1,12p'
