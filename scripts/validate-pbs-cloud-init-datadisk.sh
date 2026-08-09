#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$REPO_ROOT/infrastructure/terraform/modules/vm/templates/cloud-init-pbs.yaml.tftpl"

test -f "$TEMPLATE"
if grep -q 'DISK="/dev/sdb"' "$TEMPLATE"; then
  echo "FAIL: hard-coded /dev/sdb PBS datastore device found in $TEMPLATE" >&2
  exit 1
fi
# shellcheck disable=SC2016
grep -q 'ROOT_SOURCE="$(findmnt -n -o SOURCE /)"' "$TEMPLATE"
# shellcheck disable=SC2016
grep -q 'ROOT_DISK="/dev/$(lsblk -no PKNAME "$${ROOT_SOURCE}")"' "$TEMPLATE"
grep -q 'LABEL="pbs-datastore"' "$TEMPLATE"
# shellcheck disable=SC2016
grep -q 'echo "LABEL=$LABEL $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab.tmp' "$TEMPLATE"
grep -q 'rm -f /etc/apt/sources.list.d/pbs-enterprise.list /etc/apt/sources.list.d/pbs-enterprise.sources' "$TEMPLATE"
grep -q 'proxmox-backup-manager datastore list --output-format json' "$TEMPLATE"

echo "PBS cloud-init data-disk contract passed"