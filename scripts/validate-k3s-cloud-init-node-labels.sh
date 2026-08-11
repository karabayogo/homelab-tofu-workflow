#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MASTER="$REPO_ROOT/infrastructure/terraform/modules/vm/templates/cloud-init-master.yaml.tftpl"
WORKER="$REPO_ROOT/infrastructure/terraform/modules/vm/templates/cloud-init-worker.yaml.tftpl"

for path in "$MASTER" "$WORKER"; do
  test -f "$path"
  grep -q '^      node-label:$' "$path"
  grep -Fqx '%{ for label in split("\n", trimspace(node_labels_yaml)) ~}' "$path"
  grep -Fqx '        ${label}' "$path"
  if grep -Eq 'indent\([0-9]+, node_labels_yaml\)' "$path"; then
    echo "::error file=$path::node_labels_yaml still uses indent(...). Use the explicit per-label loop so the first rendered label line cannot escape the YAML block."
    exit 1
  fi
done

grep -q '^  - path: /opt/longhorn-setup.sh$' "$WORKER"
grep -q '^      cat > "\$MOUNT_POINT/longhorn/longhorn-disk.cfg" << '\''DISKEOF'\''$' "$WORKER"
grep -q '^      {$' "$WORKER"
grep -q '^      DISKEOF$' "$WORKER"

echo "k3s cloud-init node-label contract passed"
