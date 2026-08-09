#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAIN_TF="${REPO_ROOT}/infrastructure/terraform/main.tf"

module_block() {
  local module_name="$1"
  awk -v name="$module_name" '
    $0 ~ "^module \"" name "\"" { in_block=1 }
    in_block { print }
    in_block && /^}/ { exit }
  ' "$MAIN_TF"
}

require_pattern() {
  local pattern="$1"
  local file="$2"
  local message="$3"
  if ! grep -Eq "$pattern" "$file"; then
    echo "[ERROR] $message" >&2
    exit 1
  fi
}

require_absent() {
  local pattern="$1"
  local file="$2"
  local message="$3"
  if grep -Eq "$pattern" "$file"; then
    echo "[ERROR] $message" >&2
    exit 1
  fi
}

require_pattern 'resource "proxmox_storage_directory" "bulkpool_dir"' "$MAIN_TF" 'bulkpool-dir directory storage resource missing'
require_pattern 'path *= *"/bulkpool/proxmox-dir"' "$MAIN_TF" 'bulkpool-dir path must be /bulkpool/proxmox-dir'
require_pattern 'content *= *\["images"\]' "$MAIN_TF" 'bulkpool-dir must be images-only storage'

for module in openclaw backup_pbs1 tofu_state1; do
  block="$(module_block "$module")"
  if [[ -z "$block" ]]; then
    echo "[ERROR] module $module not found in $MAIN_TF" >&2
    exit 1
  fi
  if ! grep -Eq 'data_storage *= *"bulkpool-dir"' <<<"$block"; then
    echo "[ERROR] module $module must use data_storage = \"bulkpool-dir\"'" >&2
    exit 1
  fi
done

for module in k8s_worker1 k8s_worker2; do
  block="$(module_block "$module")"
  if [[ -z "$block" ]]; then
    echo "[ERROR] module $module not found in $MAIN_TF" >&2
    exit 1
  fi
  if ! grep -Eq 'data_storage *= *"bulkpool"' <<<"$block"; then
    echo "[ERROR] module $module must keep data_storage = \"bulkpool\" for Longhorn replica disks'" >&2
    exit 1
  fi
done

require_absent 'vm_storage *= *"bulkpool"' "$MAIN_TF" 'OS disks must not use bulkpool'

echo "bulkpool storage contract passed"
