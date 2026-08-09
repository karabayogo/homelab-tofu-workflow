#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---check}"
VM_SSH_KEY_PATH="${VM_SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAIN_TF="${MAIN_TF:-$REPO_ROOT/infrastructure/terraform/main.tf}"

case "$MODE" in
  --check|--enforce) ;;
  *)
    echo "usage: $0 [--check|--enforce]" >&2
    exit 2
    ;;
esac

for cmd in ssh python3 sha256sum base64; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "required command missing: $cmd" >&2; exit 2; }
done

test -f "$VM_SSH_KEY_PATH" || { echo "VM SSH key not found: $VM_SSH_KEY_PATH" >&2; exit 2; }
test -f "$MAIN_TF" || { echo "main.tf not found: $MAIN_TF" >&2; exit 2; }

readonly SSH_OPTS=(
  -i "$VM_SSH_KEY_PATH"
  -n
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=2
)

inventory_json() {
  python3 - "$MAIN_TF" <<'PY'
import json
import re
import sys
from pathlib import Path

module_start = re.compile(r'^module\s+"([^"]+)"\s*\{')
quoted_value = re.compile(r'^\s*([a-zA-Z0-9_]+)\s*=\s*"([^"]*)"')
bool_value = re.compile(r'^\s*([a-zA-Z0-9_]+)\s*=\s*(true|false)\s*$')

lines = Path(sys.argv[1]).read_text().splitlines()
nodes = []
current = None
depth = 0
values = {}
node_labels = {}
in_node_labels = False

for line in lines:
    if current is None:
        m = module_start.match(line)
        if m and m.group(1).startswith("k8s_"):
            current = m.group(1)
            depth = line.count("{") - line.count("}")
            values = {}
            node_labels = {}
            in_node_labels = False
        continue

    depth += line.count("{") - line.count("}")

    if in_node_labels:
        if re.match(r'^\s*}\s*$', line):
            in_node_labels = False
        else:
            m = re.match(r'^\s*"([^"]+)"\s*=\s*"([^"]+)"\s*$', line)
            if m:
                node_labels[m.group(1)] = m.group(2)
        if depth == 0:
            in_node_labels = False
        continue

    if re.match(r'^\s*node_labels\s*=\s*{\s*$', line):
        in_node_labels = True
        continue

    m = quoted_value.match(line)
    if m:
        values[m.group(1)] = m.group(2)
    else:
        m = bool_value.match(line)
        if m:
            values[m.group(1)] = m.group(2)

    if depth == 0:
        if values.get("vm_name", "").startswith("k8s-"):
            labels = [f"  - {k}={v}" for k, v in sorted(node_labels.items())]
            nodes.append(
                {
                    "module": current,
                    "name": values["vm_name"],
                    "ip": values["static_ip"],
                    "admin_user": values.get("admin_user", "ubuntu"),
                    "service": "k3s" if values.get("k3s_role") == "server" else "k3s-agent",
                    "labels": labels,
                }
            )
        current = None
        values = {}
        node_labels = {}
        in_node_labels = False

print(json.dumps({"nodes": nodes}, indent=2))
PY
}

ssh_first_success() {
  local ip="$1"
  local admin_user="$2"
  local remote_cmd="$3"
  local target

  for target in "${admin_user}@${ip}" "ubuntu@${ip}" "root@${ip}"; do
    # shellcheck disable=SC2029
    if ssh "${SSH_OPTS[@]}" "$target" "$remote_cmd" 2>/dev/null; then
      return 0
    fi
  done

  return 1
}

read_remote_config() {
  local ip="$1"
  local admin_user="$2"
  local remote_cmd="python3 - <<'PY'
from pathlib import Path
import sys
path = Path('/etc/rancher/k3s/config.yaml')
if not path.exists():
    print('__MISSING__', end='')
    raise SystemExit(0)
sys.stdout.write(path.read_text())
PY"

  ssh_first_success "$ip" "$admin_user" "$remote_cmd"
}

write_remote_config() {
  local ip="$1"
  local admin_user="$2"
  local content_b64="$3"
  local remote_cmd="CONTENT_B64='$content_b64' python3 - <<'PY'
import base64
import os
import pathlib
import subprocess
content = base64.b64decode(os.environ['CONTENT_B64']).decode()
tmp = pathlib.Path('/tmp/k3s-config.yaml.hermes')
tmp.write_text(content)
subprocess.run(['sudo', 'install', '-m', '0644', str(tmp), '/etc/rancher/k3s/config.yaml'], check=True)
print(pathlib.Path('/etc/rancher/k3s/config.yaml').read_text(), end='')
tmp.unlink(missing_ok=True)
PY"

  ssh_first_success "$ip" "$admin_user" "$remote_cmd"
}

restart_service() {
  local ip="$1"
  local admin_user="$2"
  local service="$3"
  local remote_cmd="sudo systemctl restart '$service' && sudo systemctl is-active '$service'"
  ssh_first_success "$ip" "$admin_user" "$remote_cmd"
}

wait_for_flannel() {
  local ip="$1"
  local admin_user="$2"
  local service="$3"
  local node_name="$4"

  local remote_cmd
  for _ in $(seq 1 24); do
    remote_cmd="sudo test -s /run/flannel/subnet.env && sudo systemctl is-active '$service' | grep -qx active"
    if ssh_first_success "$ip" "$admin_user" "$remote_cmd"; then
      if command -v kubectl >/dev/null 2>&1; then
        if kubectl get node "$node_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -qx True; then
          return 0
        fi
      else
        return 0
      fi
    fi
    sleep 5
  done
  return 1
}

normalize_config() {
  python3 -c 'import json, sys
payload = json.loads(sys.stdin.read())
current = payload["current"]
labels = payload["labels"]
label_set = set(labels)
kept = []
for line in current.splitlines():
    if line == "node-label:" or line in label_set:
        continue
    kept.append(line)
base = "\n".join(kept).rstrip("\n")
desired_block = "node-label:\n" + "\n".join(labels) + "\n"
updated = base + "\n" + desired_block
sys.stdout.write(updated)'
}

current_node_label_block() {
  python3 -c 'import re, sys
text = sys.stdin.read()
m = re.search(r"(?ms)^node-label:\n(?:  - .*\n)*", text)
if not m:
    sys.exit(1)
sys.stdout.write(m.group(0))'
}

build_normalize_payload() {
  CURRENT_CONTENT="$1" LABELS_JSON="$2" python3 - <<'PY'
import json
import os

print(json.dumps({
    "current": os.environ["CURRENT_CONTENT"],
    "labels": json.loads(os.environ["LABELS_JSON"]),
}))
PY
}

status=0
inventory_payload="$(inventory_json)"
while IFS=$'\t' read -r name ip admin_user service labels_json; do
  printf '== %s (%s) ==\n' "$name" "$ip"

  if ! current="$(read_remote_config "$ip" "$admin_user")"; then
    echo "UNREACHABLE: could not read /etc/rancher/k3s/config.yaml"
    status=1
    continue
  fi

  if [ "$current" = "__MISSING__" ]; then
    echo "OK: node has no /etc/rancher/k3s/config.yaml; leaving live node untouched"
    continue
  fi

  if ! printf '%s' "$current" | grep -q '^node-label:'; then
    echo "OK: legacy config has no declarative node-label block; leaving live node untouched"
    continue
  fi

  updated="$(build_normalize_payload "$current" "$labels_json" | normalize_config)"

  if [ "$updated" = "$current" ]; then
    echo "OK: config already converged"
    continue
  fi

  echo "DRIFT: node-label block is malformed or missing"
  printf '%s' "$current" | current_node_label_block 2>/dev/null || echo "(current node-label block missing)"

  if [ "$MODE" = "--check" ]; then
    status=1
    continue
  fi

  content_b64="$(printf '%s' "$updated" | base64 | tr -d '\n')"
  readback="$(write_remote_config "$ip" "$admin_user" "$content_b64")"
  if [ "$readback" != "$updated" ]; then
    echo "FAIL: readback mismatch after write"
    status=1
    continue
  fi

  if ! restart_service "$ip" "$admin_user" "$service" >/dev/null; then
    echo "FAIL: service restart failed for $service"
    status=1
    continue
  fi

  if ! wait_for_flannel "$ip" "$admin_user" "$service" "$name"; then
    echo "FAIL: flannel subnet.env or node readiness did not recover in time"
    status=1
    continue
  fi

  echo "FIXED: config converged, service restarted, flannel subnet.env restored"
done < <(
  python3 -c 'import json, sys
data = json.load(sys.stdin)
for node in data["nodes"]:
    print("\t".join([
        node["name"],
        node["ip"],
        node["admin_user"],
        node["service"],
        json.dumps(node["labels"]),
    ]))' <<<"$inventory_payload"
)

exit "$status"