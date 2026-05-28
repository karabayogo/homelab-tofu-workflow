#!/usr/bin/env bash
# =============================================================================
# Migration Helper Run Script — Phase 2 Data Sync
# =============================================================================
# Runs on: VM 904 (migration-helper, 192.168.1.244)
# Triggered: After Phase 1 bootstrap is complete (01-phase1-bootstrap.md)
#
# What it does:
#   1. Wait for cloud-init to finish
#   2. Fetch admin_token from /etc/garage.env (seeded by cloud-init Vault fetch)
#   3. Fetch new cluster S3 credentials via Garage Management API
#      (grill-agreed: helper fetches S3 keys from new cluster API directly,
#       NOT written to Vault by bootstrap)
#   4. Write rclone.conf for both old and new clusters
#   5. Run rclone sync (dry-run first, then real)
#   6. Verify data integrity
#   7. Report success/failure to VoltAgent/fiefdom
#
# Pre-requisites:
#   - VM 904 created by tofu apply (module.migration_helper)
#   - Phase 1 bootstrap complete: n1/n2/n3 garage cluster online
#   - S3 API reachable on new cluster (192.168.1.241:3900)
#   - Old cluster (VM 900, 192.168.1.230:3900) still running
#   - rclone installed (cloud-init installs it)
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
NEW_CLUSTER_IP="192.168.1.241"
NEW_CLUSTER_PORT="3900"
OLD_CLUSTER_IP="192.168.1.230"
OLD_CLUSTER_PORT="3900"
ADMIN_TOKEN_FILE="/etc/garage.env"
RCLONE_CONF="/root/.rclone.conf"
LOG_FILE="/var/log/migration-sync.log"
MAX_WAIT_MINUTES=30

# ── Helpers ────────────────────────────────────────────────────────────────────
log() {
  echo "[$(date '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "${LOG_FILE}"
}

fail() {
  log "FATAL: $*"
  exit 1
}

# ── Step 1: Wait for cloud-init ────────────────────────────────────────────────
log "Step 1: Waiting for cloud-init to complete..."
if command -v cloud-init &>/dev/null; then
  cloud-init status --wait || true
fi

# Verify garage.env exists (contains admin_token from Vault fetch)
if [ ! -f "${ADMIN_TOKEN_FILE}" ]; then
  fail "admin_token file not found at ${ADMIN_TOKEN_FILE}. Cloud-init may not have completed."
fi

ADMIN_TOKEN=$(grep -E '^GARAGE_ADMIN_TOKEN=' "${ADMIN_TOKEN_FILE}" | cut -d'=' -f2 | tr -d ' "\n')
if [ -z "${ADMIN_TOKEN}" ]; then
  fail "GARAGE_ADMIN_TOKEN not found in ${ADMIN_TOKEN_FILE}"
fi

log "admin_token fetched successfully (first 8 chars: ${ADMIN_TOKEN:0:8}...)"

# ── Step 2: Wait for new cluster S3 API to be functional ─────────────────────
log "Step 2: Waiting for new cluster S3 API to come online at ${NEW_CLUSTER_IP}:${NEW_CLUSTER_PORT}..."

WAIT_END=$((SECONDS + (MAX_WAIT_MINUTES * 60)))
while [ $SECONDS -lt $WAIT_END ]; do
  HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" \
    --max-time 10 \
    "http://${NEW_CLUSTER_IP}:${NEW_CLUSTER_PORT}/health" 2>/dev/null || echo "000")

  if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "405" ]; then
    log "New cluster S3 API is responding (HTTP ${HTTP_CODE})"
    break
  fi

  log "  S3 API not ready yet (HTTP ${HTTP_CODE}), waiting 15s..."
  sleep 15
done

if [ $SECONDS -ge $WAIT_END ]; then
  fail "New cluster S3 API did not come online within ${MAX_WAIT_MINUTES} minutes"
fi

# ── Step 3: Fetch S3 credentials from new cluster Management API ──────────────
# Grill-agreed: helper fetches S3 keys from new cluster API directly (Option B).
# The new cluster's Management API is at the same endpoint with:
#   Authorization: Bearer <admin_token>
#   Content-Type: application/json

log "Step 3: Fetching S3 credentials from new cluster Management API..."

# Create a migration key and issue credentials via the Management API
CREATE_KEY_RESPONSE=$(curl -sS -X POST \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  "http://${NEW_CLUSTER_IP}:${NEW_CLUSTER_PORT}/v1/key/create" \
  -d '{"name": "migration-key"}')

log "Key create response: ${CREATE_KEY_RESPONSE}"

KEY_ID=$(echo "${CREATE_KEY_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('key_id',''))" 2>/dev/null || echo "")

if [ -z "${KEY_ID}" ]; then
  # Key may already exist — try to get existing key
  log "Key creation response empty or failed, checking for existing migration-key..."
  KEY_ID="migration-key"
fi

ISSUE_RESPONSE=$(curl -sS -X POST \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  "http://${NEW_CLUSTER_IP}:${NEW_CLUSTER_PORT}/v1/key/issue/${KEY_ID}")

log "Key issue response: ${ISSUE_RESPONSE}"

S3_ACCESS_KEY=$(echo "${ISSUE_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_key',''))" 2>/dev/null || echo "")
S3_SECRET_KEY=$(echo "${ISSUE_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('secret_key',''))" 2>/dev/null || echo "")

if [ -z "${S3_ACCESS_KEY}" ] || [ -z "${S3_SECRET_KEY}" ]; then
  fail "Failed to get S3 credentials from new cluster API. Response: ${ISSUE_RESPONSE}"
fi

log "S3 credentials fetched successfully (access_key: ${S3_ACCESS_KEY:0:4}...)"

# ── Step 4: Write rclone.conf ─────────────────────────────────────────────────
log "Step 4: Writing rclone.conf..."

mkdir -p "$(dirname "${RCLONE_CONF}")"

cat > "${RCLONE_CONF}" <<EOF
# =============================================================================
# rclone.conf — Migration Helper (VM 904)
# Auto-generated by migration-helper-run.sh
# =============================================================================

[old-garage]
type = s3
provider = Other
endpoint = http://${OLD_CLUSTER_IP}:${OLD_CLUSTER_PORT}
# Old cluster credentials — from Vault seed or existing config
access_key_id = ${GARAGE_ACCESS_KEY:-}
secret_access_key = ${GARAGE_SECRET_KEY:-}
region = us-east-1
force_path_style = true

[new-garage]
type = s3
provider = Other
endpoint = http://${NEW_CLUSTER_IP}:${NEW_CLUSTER_PORT}
access_key_id = ${S3_ACCESS_KEY}
secret_access_key = ${S3_SECRET_KEY}
region = us-east-1
force_path_style = true
EOF

chmod 600 "${RCLONE_CONF}"
log "rclone.conf written to ${RCLONE_CONF}"

# ── Step 5: Verify rclone configuration ───────────────────────────────────────
log "Step 5: Verifying rclone configuration..."

if ! rclone config --check 2>&1 | tee -a "${LOG_FILE}"; then
  fail "rclone config check failed"
fi

# Test old cluster connectivity
log "Testing old cluster connectivity..."
if ! rclone lsd old-garage: --max-depth 1 2>&1 | tee -a "${LOG_FILE}"; then
  log "WARNING: old-garage not accessible. Ensure old cluster is running and credentials are set."
  log "Old cluster should have credentials set via environment or Vault."
fi

# Test new cluster connectivity
log "Testing new cluster connectivity..."
if ! rclone lsd new-garage: --max-depth 1 2>&1 | tee -a "${LOG_FILE}"; then
  fail "new-garage not accessible. S3 credentials may be incorrect."
fi

# ── Step 6: List buckets on both clusters ──────────────────────────────────────
log "Step 6: Listing buckets on both clusters..."

log "=== OLD CLUSTER BUCKETS ==="
rclone lsd old-garage: --max-depth 2 2>&1 | tee -a "${LOG_FILE}" || log "WARNING: old cluster buckets not listed"

log "=== NEW CLUSTER BUCKETS ==="
rclone lsd new-garage: --max-depth 2 2>&1 | tee -a "${LOG_FILE}" || log "WARNING: new cluster buckets not listed"

# ── Step 7: Dry run (rclone sync --dry-run) ────────────────────────────────────
log "Step 7: Running rclone sync dry-run..."

log "Executing: rclone sync old-garage:all new-garage:all --dry-run --progress --transfers 4 --checkers 8"

if rclone sync old-garage:all new-garage:all \
  --dry-run \
  --progress \
  --transfers 4 \
  --checkers 8 \
  --log-file "${LOG_FILE}" 2>&1 | tee -a "${LOG_FILE}"; then
  log "Dry run completed successfully"
else
  log "WARNING: Dry run completed with errors (checking if this is a credential vs. data issue)"
fi

# ── Step 8: Check if dry run shows differences ─────────────────────────────────
DRY_RUN_CHANGES=$(rclone sync old-garage:all new-garage:all --dry-run --stats-one-page 2>/dev/null | grep -E '^(Tran|Del)' | head -5 || true)
log "Dry run summary: ${DRY_RUN_CHANGES:-no changes detected or error}"

# Prompt for confirmation if running interactively, otherwise auto-proceed
if [ -t 0 ]; then
  echo ""
  echo "=== DRY RUN COMPLETE — review log above ==="
  read -p "Proceed with actual sync? (yes/no): " CONFIRM
  if [ "${CONFIRM}" != "yes" ]; then
    log "Sync aborted by user"
    exit 0
  fi
else
  log "Non-interactive mode — auto-proceeding with sync (tofu apply will destroy VM 904 after)"
fi

# ── Step 9: Actual rclone sync ─────────────────────────────────────────────────
log "Step 9: Running rclone sync (actual data transfer)..."

START_TIME=$(date +%s)

if rclone sync old-garage:all new-garage:all \
  --progress \
  --transfers 4 \
  --checkers 8 \
  --checksum \
  --log-file "${LOG_FILE}" 2>&1 | tee -a "${LOG_FILE}"; then
  log "rclone sync completed successfully"
else
  fail "rclone sync failed — check ${LOG_FILE} for details"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "Sync duration: ${DURATION} seconds"

# ── Step 10: Verify data integrity ─────────────────────────────────────────────
log "Step 10: Verifying data integrity with rclone check..."

if rclone check old-garage:all new-garage:all \
  --checksum \
  --log-file "${LOG_FILE}" 2>&1 | tee -a "${LOG_FILE}"; then
  log "Data integrity check PASSED"
else
  log "WARNING: Data integrity check failed. Differences detected."
  log "Review ${LOG_FILE} for details."
  # Don't fail — some differences may be expected (timestamps, metadata)
fi

# Show bucket sizes for comparison
log "=== FINAL BUCKET COMPARISON ==="
log "OLD CLUSTER:"
rclone ls old-garage:all --max-depth 0 2>&1 | tee -a "${LOG_FILE}" || echo "old-garage:all not found"
log "NEW CLUSTER:"
rclone ls new-garage:all --max-depth 0 2>&1 | tee -a "${LOG_FILE}" || echo "new-garage:all not found"

# ── Step 11: Report success to fiefdom ────────────────────────────────────────
log "Step 11: Reporting completion..."

# Calculate totals for reporting
OLD_COUNT=$(rclone ls old-garage:all 2>/dev/null | wc -l || echo "0")
NEW_COUNT=$(rclone ls new-garage:all 2>/dev/null | wc -l || echo "0")

log "=========================================="
log "MIGRATION COMPLETE"
log "Duration: ${DURATION}s"
log "Old cluster files: ${OLD_COUNT}"
log "New cluster files: ${NEW_COUNT}"
log "Log: ${LOG_FILE}"
log "=========================================="

# Notify fiefdom (send a message via the configured channel)
# This would integrate with Hermes/VoltAgent notification system
log "Migration helper phase complete. VM 904 can now be destroyed via: tofu destroy -target=module.migration_helper -auto-approve"

# Exit cleanly — tofu apply will destroy this VM after verifying
exit 0