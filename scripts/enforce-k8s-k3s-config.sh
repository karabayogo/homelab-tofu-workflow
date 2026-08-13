#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---check}"
ROLE_FILTER="${ROLE_FILTER:-agent}"
VM_SSH_KEY_PATH="${VM_SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAIN_TF="${MAIN_TF:-$REPO_ROOT/infrastructure/terraform/main.tf}"
ROOT_VARIABLES_TF="${ROOT_VARIABLES_TF:-$REPO_ROOT/infrastructure/terraform/variables.tf}"
TERRAFORM_TFVARS="${TERRAFORM_TFVARS:-$REPO_ROOT/infrastructure/terraform/terraform.tfvars}"

case "$MODE" in
  --check|--enforce) ;;
  *)
    echo "usage: $0 [--check|--enforce]" >&2
    exit 2
    ;;
esac

case "$ROLE_FILTER" in
  agent|server|all) ;;
  *)
    echo "ROLE_FILTER must be one of: agent, server, all" >&2
    exit 2
    ;;
esac

for cmd in ssh python3 base64; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "required command missing: $cmd" >&2; exit 2; }
done

test -f "$VM_SSH_KEY_PATH" || { echo "VM SSH key not found: $VM_SSH_KEY_PATH" >&2; exit 2; }
test -f "$MAIN_TF" || { echo "main.tf not found: $MAIN_TF" >&2; exit 2; }
test -f "$ROOT_VARIABLES_TF" || { echo "variables.tf not found: $ROOT_VARIABLES_TF" >&2; exit 2; }

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
  python3 - "$MAIN_TF" "$ROOT_VARIABLES_TF" "$TERRAFORM_TFVARS" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

main_tf = Path(sys.argv[1]).read_text()
root_variables_tf = Path(sys.argv[2]).read_text()
tfvars_path = Path(sys.argv[3])
tfvars_text = tfvars_path.read_text() if tfvars_path.exists() else ""

module_start = re.compile(r'^module\s+"([^"]+)"\s*\{')
quoted_value = re.compile(r'^\s*([a-zA-Z0-9_]+)\s*=\s*"([^"]*)"')
bool_value = re.compile(r'^\s*([a-zA-Z0-9_]+)\s*=\s*(true|false)\s*$')
ref_value = re.compile(r'^\s*([a-zA-Z0-9_]+)\s*=\s*(local|var)\.([a-zA-Z0-9_]+)\s*$')
number_value = re.compile(r'^\s*([a-zA-Z0-9_]+)\s*=\s*([0-9]+)\s*$')


def tf_default(var_name: str) -> str:
    pattern = re.compile(
        rf'variable\s+"{re.escape(var_name)}"\s*\{{.*?default\s*=\s*"([^"]*)"',
        re.S,
    )
    m = pattern.search(root_variables_tf)
    return m.group(1) if m else ""


def tfvars_value(var_name: str) -> str:
    if not tfvars_text:
        return ""
    pattern = re.compile(rf'^\s*{re.escape(var_name)}\s*=\s*"([^"]*)"\s*$', re.M)
    m = pattern.search(tfvars_text)
    return m.group(1) if m else ""


def runtime_value(var_name: str, env_keys) -> str:
    for key in env_keys:
        value = os.environ.get(key, "")
        if value:
            return value
    value = tfvars_value(var_name)
    if value:
        return value
    return tf_default(var_name)


runtime = {
    "k3s_token": runtime_value("k3s_token", ["K3S_TOKEN", "TF_VAR_k3s_token"]),
    "k3s_api_vip": runtime_value("k3s_api_vip", ["K3S_API_VIP", "TF_VAR_k3s_api_vip"]),
}


def resolve_value(raw, refs):
    if raw not in (None, ""):
        return raw
    if not refs:
        return ""
    if refs.get("kind") == "local" and refs.get("name") == "k3s_api_vip":
        return runtime["k3s_api_vip"]
    if refs.get("kind") == "var":
        return runtime_value(refs["name"], [f"TF_VAR_{refs['name']}", refs["name"].upper()])
    return ""


nodes = []
current = None
depth = 0
values = {}
refs = {}
node_labels = {}
in_node_labels = False

for line in main_tf.splitlines():
    if current is None:
        m = module_start.match(line)
        if m and m.group(1).startswith("k8s_"):
            current = m.group(1)
            depth = line.count("{") - line.count("}")
            values = {}
            refs = {}
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
            values[m.group(1)] = (m.group(2) == "true")
        else:
            m = ref_value.match(line)
            if m:
                refs[m.group(1)] = {"kind": m.group(2), "name": m.group(3)}
            else:
                m = number_value.match(line)
                if m:
                    values[m.group(1)] = m.group(2)

    if depth == 0:
        role = values.get("k3s_role")
        allowed_roles = {"agent", "server"}
        role_filter = os.environ.get("ROLE_FILTER", "agent")
        if role_filter != "all":
            allowed_roles = {role_filter}
        if values.get("vm_name", "").startswith("k8s-") and role in allowed_roles:
            labels = [f"  - {k}={v}" for k, v in sorted(node_labels.items())]
            nodes.append(
                {
                    "module": current,
                    "name": values["vm_name"],
                    "ip": values["static_ip"],
                    "vm_id": values.get("vm_id", ""),
                    "admin_user": values.get("admin_user", "ubuntu"),
                    "role": role,
                    "service": "k3s" if role == "server" else "k3s-agent",
                    "cluster_init": bool(values.get("k3s_cluster_init", False)),
                    "join_server": resolve_value(values.get("k3s_join_server"), refs.get("k3s_join_server")),
                    "api_vip": resolve_value(values.get("k3s_api_vip"), refs.get("k3s_api_vip")),
                    "labels": labels,
                }
            )
        current = None
        values = {}
        refs = {}
        node_labels = {}
        in_node_labels = False

print(json.dumps({"runtime": runtime, "nodes": nodes}, indent=2))
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
path = Path('/etc/rancher/k3s/config.yaml')
if not path.exists():
    print('__MISSING__', end='')
    raise SystemExit(0)
print(path.read_text(), end='')
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
  local remote_cmd="sudo systemctl restart --no-block '$service'"
  ssh_first_success "$ip" "$admin_user" "$remote_cmd"
}

wait_for_recovery() {
  local ip="$1"
  local admin_user="$2"
  local service="$3"
  local node_name="$4"
  local remote_cmd

  for _ in $(seq 1 60); do
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

desired_config() {
  local node_json="$1"
  local k3s_token="$2"
  NODE_JSON="$node_json" K3S_TOKEN_VALUE="$k3s_token" python3 - <<'PY'
import json
import os

node = json.loads(os.environ['NODE_JSON'])
token = os.environ['K3S_TOKEN_VALUE']
lines = []
labels = node.get('labels', [])

if node['role'] == 'agent':
    lines.extend([
        f'server: "https://{node["join_server"]}:6443"',
        f'token: "{token}"',
        f'node-ip: "{node["ip"]}"',
    ])
else:
    lines.extend([
        f'token: "{token}"',
        'write-kubeconfig-mode: "644"',
        f'node-ip: "{node["ip"]}"',
        'tls-san:',
        f'  - "{node["api_vip"]}"',
    ])
    if node.get('cluster_init'):
        lines.append('cluster-init: true')
    else:
        lines.append(f'server: "https://{node["join_server"]}:6443"')
    lines.extend([
        'cluster-domain: cluster.local',
        'resolv-conf: /etc/rancher/k3s/resolv.conf',
    ])

if labels:
    lines.append('node-label:')
    lines.extend(labels)

print("\n".join(lines) + "\n", end='')
PY
}

masked_diff() {
  local current="$1"
  local desired="$2"
  CURRENT_CONFIG="$current" DESIRED_CONFIG="$desired" python3 - <<'PY'
import difflib
import os
import re

pattern = re.compile(r'^(\s*token:\s*").*("\s*)$', re.M)

def sanitize(text: str) -> str:
    return pattern.sub(r'\1REDACTED\2', text)

current = sanitize(os.environ['CURRENT_CONFIG']).splitlines(keepends=True)
desired = sanitize(os.environ['DESIRED_CONFIG']).splitlines(keepends=True)
for line in difflib.unified_diff(current, desired, fromfile='live', tofile='desired'):
    print(line, end='')
PY
}

status=0
inventory_payload="$(inventory_json)"
k3s_token="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["runtime"]["k3s_token"], end="")' <<<"$inventory_payload")"

if [ -z "$k3s_token" ]; then
  echo "k3s_token is empty after resolving env/tfvars/defaults; refusing to continue" >&2
  exit 2
fi

while IFS=$'\t' read -r name ip admin_user service node_json; do
  printf '== %s (%s) ==\n' "$name" "$ip"

  if ! current="$(read_remote_config "$ip" "$admin_user")"; then
    echo "UNREACHABLE: could not read /etc/rancher/k3s/config.yaml"
    status=1
    continue
  fi

  desired="$(desired_config "$node_json" "$k3s_token")"

  if [ "$current" = "$desired" ]; then
    echo "OK: config already converged"
    continue
  fi

  echo "DRIFT: live /etc/rancher/k3s/config.yaml diverges from Git-declared contract"
  masked_diff "$current" "$desired" || true

  if [ "$MODE" = "--check" ]; then
    status=1
    continue
  fi

  content_b64="$(printf '%s' "$desired" | base64 | tr -d '\n')"
  if ! readback="$(write_remote_config "$ip" "$admin_user" "$content_b64")"; then
    echo "FAIL: could not write /etc/rancher/k3s/config.yaml"
    status=1
    continue
  fi

  if [ "$readback" != "$desired" ]; then
    echo "FAIL: readback mismatch after write"
    masked_diff "$readback" "$desired" || true
    status=1
    continue
  fi

  if ! restart_service "$ip" "$admin_user" "$service"; then
    echo "FAIL: service restart submission failed for $service"
    status=1
    continue
  fi

  if ! wait_for_recovery "$ip" "$admin_user" "$service" "$name"; then
    echo "FAIL: service/node readiness did not recover in time"
    status=1
    continue
  fi

  echo "FIXED: config converged, service restarted, node recovered"
done < <(
  python3 -c 'import json, sys
payload = json.load(sys.stdin)
for node in payload["nodes"]:
    print("\t".join([
        node["name"],
        node["ip"],
        node["admin_user"],
        node["service"],
        json.dumps(node),
    ]))' <<<"$inventory_payload"
)

exit "$status"
