#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$REPO_ROOT/infrastructure/terraform/modules/vm/templates/cloud-init-pbs.yaml.tftpl"

test -f "$TEMPLATE"

# 2026-10-02: these used to be bare `grep -q` calls under `set -e`, so a broken
# contract exited 1 with NO output at all (the CI step showed only "Process
# completed with exit code 1"). Always say which assertion failed.
assert_template_contains() {
  local needle="$1"
  if ! grep -qF "$needle" "$TEMPLATE"; then
    echo "FAIL: $TEMPLATE no longer contains: $needle" >&2
    exit 1
  fi
}

if grep -q 'DISK="/dev/sdb"' "$TEMPLATE"; then
  echo "FAIL: hard-coded /dev/sdb PBS datastore device found in $TEMPLATE" >&2
  exit 1
fi

# shellcheck disable=SC2016
assert_template_contains 'ROOT_SOURCE="$(findmnt -n -o SOURCE /)"'
# shellcheck disable=SC2016
assert_template_contains 'ROOT_DISK="/dev/$(lsblk -no PKNAME "$${ROOT_SOURCE}")"'
assert_template_contains 'LABEL="pbs-datastore"'
# shellcheck disable=SC2016
assert_template_contains 'echo "LABEL=$LABEL $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab.tmp'
assert_template_contains 'rm -f /etc/apt/sources.list.d/pbs-enterprise.list /etc/apt/sources.list.d/pbs-enterprise.sources'
assert_template_contains 'proxmox-backup-manager datastore list --output-format json | python3 -c'

# The PBS packages must be installed by /opt/pbs-install.sh, AFTER the PBS apt
# repo is added — proxmox-backup-client is required for DR restore drills
# (pxar restore from a recovered datastore) and a rebuilt-from-Git PBS without
# it cannot restore anything.
assert_template_contains 'apt-get install -y -o Acquire::ForceIPv4=true --fix-missing proxmox-backup-server proxmox-backup-client rsync'

# ... and must NOT be declared under cloud-init `packages:`, which runs BEFORE
# the PBS repo exists: cloud-init then skips the unavailable package silently
# (2026-10-02: the drill pushed the whole mirror and only then found the client
# missing).
if grep -qE '^  - proxmox-backup-(client|server)$' "$TEMPLATE"; then
  echo "FAIL: a PBS package is declared under cloud-init packages: in $TEMPLATE — that runs before the PBS apt repo exists and is silently skipped; install it in /opt/pbs-install.sh instead" >&2
  exit 1
fi

# shellcheck disable=SC2016
if grep -q 'python3 - "\$DATASTORE_NAME" <<'"'"'PY'"'"'' "$TEMPLATE"; then
  echo "FAIL: heredoc-based datastore existence check is broken in $TEMPLATE" >&2
  exit 1
fi

echo "PBS cloud-init data-disk contract passed"
