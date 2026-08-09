#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"

PBS_HOST="${PBS_HOST:-192.168.1.247}"
PBS_USER="${PBS_USER:-root}"
PBS_TARGET="${PBS_USER}@${PBS_HOST}"
SSH_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
)
SCP_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PBS_TEMPLATE="${REPO_ROOT}/infrastructure/terraform/modules/vm/templates/cloud-init-pbs.yaml.tftpl"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

ssh_pbs() {
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "$PBS_TARGET" "$@"
}

extract_template_script() {
  local target_path="$1" out_path="$2"
  python3 - "$PBS_TEMPLATE" "$target_path" "$out_path" <<'PY'
from pathlib import Path
import sys

template_path = Path(sys.argv[1])
target = sys.argv[2]
out_path = Path(sys.argv[3])
lines = template_path.read_text().splitlines()

for idx, line in enumerate(lines):
    if line == f"  - path: {target}":
        if idx + 2 >= len(lines) or lines[idx + 2] != '    content: |':
            raise SystemExit(f'malformed template block for {target}')
        content = []
        for inner in lines[idx + 3:]:
            if inner.startswith('  - path: ') or inner.startswith('runcmd:') or inner.startswith('power_state:'):
                break
            if inner.startswith('      '):
                content.append(inner[6:])
            else:
                content.append(inner)
        out_path.write_text("\n".join(content).replace('$$', '$') + "\n")
        raise SystemExit(0)
raise SystemExit(f'path not found in template: {target}')
PY
}

render_local_scripts() {
  extract_template_script /opt/pbs-install.sh "$TMP_DIR/pbs-install.sh"
  extract_template_script /opt/pbs-data-disk-setup.sh "$TMP_DIR/pbs-data-disk-setup.sh"
  extract_template_script /opt/pbs-bootstrap.sh "$TMP_DIR/pbs-bootstrap.sh"
}

local_sha() {
  sha256sum "$1" | awk '{print $1}'
}

remote_sha() {
  local path="$1"
  ssh_pbs "sha256sum '$path' 2>/dev/null | awk '{print \$1}' || true"
}

check_file() {
  local local_path="$1" remote_path="$2"
  local expected actual
  expected="$(local_sha "$local_path")"
  actual="$(remote_sha "$remote_path")"
  if [[ "$expected" != "$actual" ]]; then
    echo "[ERROR] Drift detected for ${remote_path}"
    return 1
  fi
  echo "[OK] ${remote_path} matches template"
}

copy_to_pbs() {
  local src="$1" dest="$2" mode="$3"
  local tmp
  tmp="/tmp/$(basename "$dest").codex.$$"
  scp "${SCP_OPTS[@]}" "$src" "$PBS_TARGET:$tmp"
  ssh_pbs "install -D -m ${mode} '$tmp' '$dest' && rm -f '$tmp'"
}

case "$MODE" in
  --check)
    render_local_scripts
    check_file "$TMP_DIR/pbs-install.sh" /opt/pbs-install.sh
    check_file "$TMP_DIR/pbs-data-disk-setup.sh" /opt/pbs-data-disk-setup.sh
    check_file "$TMP_DIR/pbs-bootstrap.sh" /opt/pbs-bootstrap.sh
    ;;
  --enforce)
    render_local_scripts
    copy_to_pbs "$TMP_DIR/pbs-install.sh" /opt/pbs-install.sh 0755
    copy_to_pbs "$TMP_DIR/pbs-data-disk-setup.sh" /opt/pbs-data-disk-setup.sh 0755
    copy_to_pbs "$TMP_DIR/pbs-bootstrap.sh" /opt/pbs-bootstrap.sh 0755
    check_file "$TMP_DIR/pbs-install.sh" /opt/pbs-install.sh
    check_file "$TMP_DIR/pbs-data-disk-setup.sh" /opt/pbs-data-disk-setup.sh
    check_file "$TMP_DIR/pbs-bootstrap.sh" /opt/pbs-bootstrap.sh
    ;;
  *)
    echo "Usage: $0 [--check|--enforce]"
    exit 64
    ;;
esac
