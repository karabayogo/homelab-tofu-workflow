#!/usr/bin/env bash
set -euo pipefail

PBS_SSH_TARGET="${PBS_SSH_TARGET:-root@192.168.1.247}"
SSH_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ssh_pbs() {
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "$PBS_SSH_TARGET" "$@"
}

bash "$SCRIPT_DIR/enforce-pbs-bootstrap-scripts.sh" --enforce
ssh_pbs 'bash -lc "/opt/pbs-install.sh && /opt/pbs-data-disk-setup.sh && /opt/pbs-bootstrap.sh"'
ssh_pbs 'systemctl is-active qemu-guest-agent proxmox-backup proxmox-backup-proxy >/dev/null'
ssh_pbs 'mountpoint -q /srv/proxmox-backup-primary && test -d /srv/proxmox-backup-primary/datastore'
ssh_pbs 'proxmox-backup-manager datastore list --output-format json | python3 -c '\''import json, sys; items = json.load(sys.stdin); assert any(item.get("name") == "primary" for item in items), items; print("primary datastore present")'\'''
echo '[OK] PBS bootstrap replay proof passed'
