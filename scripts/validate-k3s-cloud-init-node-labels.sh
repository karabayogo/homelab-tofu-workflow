#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MASTER="$REPO_ROOT/infrastructure/terraform/modules/vm/templates/cloud-init-master.yaml.tftpl"
WORKER="$REPO_ROOT/infrastructure/terraform/modules/vm/templates/cloud-init-worker.yaml.tftpl"
EXPECTED_INDENT="\${indent(8, node_labels_yaml)}"

for path in "$MASTER" "$WORKER"; do
  test -f "$path"
  grep -q '^      node-label:$' "$path"
  grep -Fqx "$EXPECTED_INDENT" "$path"
  if grep -q 'indent(6, node_labels_yaml)' "$path"; then
    echo "::error file=$path::node_labels_yaml is indented only 6 spaces; this escapes the write_files content block and renders a malformed /etc/rancher/k3s/config.yaml"
    exit 1
  fi
done

echo "k3s cloud-init node-label indentation contract passed"