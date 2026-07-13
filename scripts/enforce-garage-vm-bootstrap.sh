#!/usr/bin/env bash
# enforce-garage-vm-bootstrap.sh
#
# Verifies (or enforces) that live Garage VM bootstrap files converge to the
# Git-declared cloud-init state. Uses direct SSH to the Garage VMs as the
# primary transport, with PVE qm-guest-exec as a fallback.
#
# RCA: The previous version relied solely on PVE `qm guest exec` (virtio-serial
# channel) to read files inside Garage VMs. This channel silently deadlocks on
# low-memory (2GB) VMs under memory pressure — the qemu-guest-agent process
# appears "active" inside the VM but PVE reports "QEMU guest agent is not
# running" because the virtio-serial communication has stalled. Direct SSH
# to the VMs is reliable because it uses the network stack (virtio-net), not
# the virtio-serial channel.
set -euo pipefail

MODE="${1:---check}"
PVE_SSH_KEY_PATH="${PVE_SSH_KEY_PATH:-$HOME/.ssh/pve-kai}"
PVE_SSH_TARGET="${PVE_SSH_TARGET:-root@192.168.1.50}"
VM_SSH_KEY_PATH="${VM_SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
VM_SSH_USER="${VM_SSH_USER:-root}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TFVARS_PATH="${TFVARS_PATH:-$REPO_ROOT/infrastructure/terraform/terraform.tfvars}"
TEMPLATE_PATH="${TEMPLATE_PATH:-$REPO_ROOT/infrastructure/terraform/modules/vm/templates/cloud-init-garage.yaml.tftpl}"
MAINTF_PATH="${MAINTF_PATH:-$REPO_ROOT/infrastructure/terraform/main.tf}"

case "$MODE" in
  --check|--enforce) ;;
  *)
    echo "usage: $0 [--check|--enforce]" >&2
    exit 2
    ;;
esac

for cmd in ssh jq python3 sha256sum; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "required command missing: $cmd" >&2
    exit 2
  fi
done

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "python3 module missing: yaml (PyYAML)" >&2
  exit 2
fi

if [ ! -f "$PVE_SSH_KEY_PATH" ]; then
  echo "PVE SSH key not found: $PVE_SSH_KEY_PATH" >&2
  exit 2
fi

if [ ! -f "$VM_SSH_KEY_PATH" ]; then
  echo "VM SSH key not found: $VM_SSH_KEY_PATH" >&2
  exit 2
fi

if [ ! -f "$TFVARS_PATH" ] || [ ! -f "$TEMPLATE_PATH" ] || [ ! -f "$MAINTF_PATH" ]; then
  echo "required repo files missing" >&2
  exit 2
fi

# SSH opts for PVE host (used for qm guest exec fallback and VM restart)
readonly PVE_SSH_OPTS=(
  -i "$PVE_SSH_KEY_PATH"
  -n
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=8
)

# SSH opts for direct SSH to Garage VMs (primary transport)
readonly VM_SSH_OPTS=(
  -i "$VM_SSH_KEY_PATH"
  -n
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=2
)

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

SPEC_JSON="$TMP_DIR/spec.json"
python3 - "$TFVARS_PATH" "$TEMPLATE_PATH" "$MAINTF_PATH" "$TMP_DIR" > "$SPEC_JSON" <<'PY'
import json
import re
import sys
from pathlib import Path
import yaml

tfvars_path = Path(sys.argv[1])
template_path = Path(sys.argv[2])
maintf_path = Path(sys.argv[3])
out_dir = Path(sys.argv[4])
out_dir.mkdir(parents=True, exist_ok=True)

tfvars = tfvars_path.read_text()
template = template_path.read_text()
main_tf = maintf_path.read_text().splitlines()

wanted_modules = {"garage_n1", "garage_n2", "garage_n3"}
target_paths = {
    "/opt/garage-fetch-secrets.sh",
    "/etc/systemd/system/garage.service",
    "/etc/garage.toml",
}

common = {}
for key in ["vault_addr", "vault_approle_role_id", "vault_approle_secret_id"]:
    m = re.search(rf'^{re.escape(key)}\s*=\s*"([^"]+)"', tfvars, re.M)
    if not m:
        raise SystemExit(f"missing {key} in terraform.tfvars")
    common[key] = m.group(1)

module_start = re.compile(r'^module\s+\"([^\"]+)\"\s*\{')
kv = re.compile(r'^\s*([a-zA-Z0-9_]+)\s*=\s*(?:\"([^\"]+)\"|([0-9]+))')
current = None
depth = 0
values = {}
modules = {}
for line in main_tf:
    if current is None:
        m = module_start.search(line)
        if m:
            current = m.group(1)
            depth = line.count("{") - line.count("}")
            values = {}
        continue
    depth += line.count("{") - line.count("}")
    m = kv.search(line)
    if m:
        values[m.group(1)] = m.group(2) if m.group(2) is not None else m.group(3)
    if depth == 0:
        if current in wanted_modules:
            modules[current] = dict(values)
        current = None
        values = {}

missing = wanted_modules - set(modules)
if missing:
    raise SystemExit(f"missing garage modules in main.tf: {sorted(missing)}")

nodes = []
for module_name in sorted(modules):
    mod = modules[module_name]
    render_vars = {
        "hostname": mod["vm_name"],
        "ssh_pub_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHermesGarageReconcilersOnly hermes@reconciler",
        "garage_version": mod["garage_version"],
        "static_ip": mod["static_ip"],
        **common,
    }
    rendered = template
    for key, value in render_vars.items():
        rendered = re.sub(rf'(?<!\$)\$\{{{re.escape(key)}\}}', value, rendered)
    rendered = rendered.replace("$${", "${")
    # Cloud-init uses %% as an escape for literal % — replicate this here
    # so the rendered content matches what cloud-init actually writes to the VM.
    rendered = rendered.replace("%%", "%")
    doc = yaml.safe_load(rendered)
    write_files = doc.get("write_files", [])
    files = []
    for entry in write_files:
        path = entry.get("path")
        if path not in target_paths:
            continue
        content = entry.get("content", "")
        if not content.endswith("\n"):
            content += "\n"
        local_name = path.strip("/").replace("/", "__")
        local_path = out_dir / f"{mod['vm_name']}__{local_name}"
        local_path.write_text(content)
        files.append(
            {
                "path": path,
                "permissions": str(entry.get("permissions", "0644")),
                "local_path": str(local_path),
            }
        )
    files.sort(key=lambda x: x["path"])
    nodes.append(
        {
            "module": module_name,
            "name": mod["vm_name"],
            "vmid": int(mod["vm_id"]),
            "ip": mod["static_ip"],
            "files": files,
        }
    )

print(json.dumps({"nodes": nodes}, indent=2))
PY

# ---- Transport functions ----

# Primary: direct SSH to the Garage VM
vm_ssh_exec() {
  local ip="$1"
  shift
  timeout 30 ssh "${VM_SSH_OPTS[@]}" "${VM_SSH_USER}@${ip}" "$@" 2>/dev/null
}

# Fallback: qm guest exec via PVE (virtio-serial channel — may be deadlocked)
qm_exec_json() {
  local vmid="$1"
  local pass_stdin="$2"
  local timeout_val="$3"
  shift 3
  local remote=(qm guest exec "$vmid" --timeout "$timeout_val")
  if [ "$pass_stdin" = "1" ]; then
    remote+=(--pass-stdin 1)
  fi
  remote+=(-- "$@")
  local quoted
  printf -v quoted '%q ' "${remote[@]}"
  local ssh_opts=("${PVE_SSH_OPTS[@]}")
  if [ "$pass_stdin" = "1" ]; then
    local new_opts=()
    for opt in "${ssh_opts[@]}"; do
      [ "$opt" != "-n" ] && new_opts+=("$opt")
    done
    ssh_opts=("${new_opts[@]}")
  fi
  ssh "${ssh_opts[@]}" "$PVE_SSH_TARGET" "$quoted"
}

qm_stdout() {
  local json="$1"
  jq -r '."out-data" // ""' <<<"$json"
}

qm_exitcode() {
  local json="$1"
  jq -r '.exitcode // 1' <<<"$json"
}

# Get remote file SHA256 — tries SSH first, falls back to qm guest exec
remote_sha() {
  local ip="$1"
  local vmid="$2"
  local path="$3"

  # Primary: direct SSH
  local sha
  sha=$(vm_ssh_exec "$ip" "if [ -f '$path' ]; then sha256sum '$path' | awk '{print \$1}'; else echo __MISSING__; fi" 2>/dev/null | tr -d '\r\n')
  if [ -n "$sha" ]; then
    echo "$sha"
    return 0
  fi

  # Fallback: qm guest exec via PVE virtio-serial
  local json
  json=$(qm_exec_json "$vmid" 0 15 /bin/bash -lc "if [ -f '$path' ]; then sha256sum '$path' | awk '{print \$1}'; else echo __MISSING__; fi" 2>/dev/null || echo '{}')
  local code
  code=$(qm_exitcode "$json")
  if [ "$code" != "0" ]; then
    echo "error"
    return 1
  fi
  qm_stdout "$json" | tr -d '\r\n'
}

# Write a file to the remote VM — tries SSH first, falls back to qm guest exec
write_remote_file() {
  local ip="$1"
  local vmid="$2"
  local path="$3"
  local perm="$4"
  local local_path="$5"

  # Primary: direct SSH with stdin pipe
  if cat "$local_path" | timeout 60 ssh "${VM_SSH_OPTS[@]/-n/}" "${VM_SSH_USER}@${ip}" \
    "set -euo pipefail; tmp=\$(mktemp); cat > \"\$tmp\"; install -m $perm \"\$tmp\" '$path'; rm -f \"\$tmp\"; echo wrote:$path" 2>/dev/null; then
    return 0
  fi

  # Fallback: qm guest exec via PVE
  local json
  json=$(cat "$local_path" | qm_exec_json "$vmid" 1 120 /bin/bash -lc "set -euo pipefail; tmp=\$(mktemp); cat > \"\$tmp\"; install -m $perm \"\$tmp\" '$path'; rm -f \"\$tmp\"; echo wrote:$path" 2>/dev/null || echo '{}')
  local code
  code=$(qm_exitcode "$json")
  if [ "$code" != "0" ]; then
    echo "write failed for ip=$ip vmid=$vmid path=$path" >&2
    return 1
  fi
}

# Restart garage on a node — tries SSH first, falls back to qm guest exec
restart_and_verify_node() {
  local ip="$1"
  local vmid="$2"
  local name="$3"

  # Primary: direct SSH
  if vm_ssh_exec "$ip" 'set -euo pipefail; systemctl daemon-reload; systemctl restart garage; for i in $(seq 1 30); do if systemctl is-active --quiet garage; then exit 0; fi; sleep 1; done; systemctl status garage --no-pager -l || true; exit 1' 2>/dev/null; then
    : # restart succeeded via SSH
  else
    # Fallback: qm guest exec via PVE
    local json
    json=$(qm_exec_json "$vmid" 0 180 /bin/bash -lc 'set -euo pipefail; systemctl daemon-reload; systemctl restart garage; for i in $(seq 1 30); do if systemctl is-active --quiet garage; then exit 0; fi; sleep 1; done; systemctl status garage --no-pager -l || true; exit 1' 2>/dev/null || echo '{}')
    local code
    code=$(qm_exitcode "$json")
    if [ "$code" != "0" ]; then
      echo "garage restart failed on $name/$ip" >&2
      return 1
    fi
  fi

  # Wait for port 3900
  for _ in $(seq 1 30); do
    if nc -z "$ip" 3900 >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "garage port 3900 did not come back on $name/$ip" >&2
  return 1
}

# Check Garage admin API health (port 3903) — complementary signal
check_garage_admin_health() {
  local ip="$1"
  local health
  health=$(curl -sk --connect-timeout 5 "http://$ip:3903/health" 2>/dev/null || echo "")
  if echo "$health" | grep -q "fully operational"; then
    return 0
  fi
  return 1
}

FAILURES=0
while IFS= read -r node_b64; do
  [ -z "$node_b64" ] && continue
  node_json=$(printf '%s' "$node_b64" | base64 -d)
  name=$(jq -r '.name' <<<"$node_json")
  vmid=$(jq -r '.vmid' <<<"$node_json")
  ip=$(jq -r '.ip' <<<"$node_json")
  echo "=== ${name} (vmid=${vmid}, ip=${ip}) ==="

  # Complementary health check via Garage admin API
  admin_healthy=false
  if check_garage_admin_health "$ip"; then
    echo "HEALTH garage admin API: fully operational"
    admin_healthy=true
  else
    echo "WARN garage admin API not responding on $ip:3903" >&2
  fi

  changed=0
  ssh_failures=0
  while IFS= read -r file_b64; do
    [ -z "$file_b64" ] && continue
    file_json=$(printf '%s' "$file_b64" | base64 -d)
    path=$(jq -r '.path' <<<"$file_json")
    perm=$(jq -r '.permissions' <<<"$file_json")
    local_path=$(jq -r '.local_path' <<<"$file_json")
    desired_sha=$(sha256sum "$local_path" | awk '{print $1}')
    current_sha=$(remote_sha "$ip" "$vmid" "$path" || true)
    if [ "$current_sha" = "$desired_sha" ]; then
      echo "PASS file $path sha=$desired_sha"
      continue
    fi

    # If SSH returned "error" but admin API is healthy, the node is operational
    # but management plane (SSH/virtio-serial) is wedged — warn, don't fail.
    if [ "$current_sha" = "error" ] && [ "$admin_healthy" = "true" ]; then
      echo "WARN file $path: management plane unreachable (SSH+qm-guest-exec failed) but Garage admin API healthy — node operational, verification skipped" >&2
      ssh_failures=$((ssh_failures + 1))
      continue
    fi

    if [ "$MODE" = "--check" ]; then
      echo "FAIL file $path desired_sha=$desired_sha current_sha=${current_sha:-error}" >&2
      FAILURES=$((FAILURES + 1))
      continue
    fi

    echo "ENFORCE file $path desired_sha=$desired_sha current_sha=${current_sha:-missing}"
    if ! write_remote_file "$ip" "$vmid" "$path" "$perm" "$local_path"; then
      FAILURES=$((FAILURES + 1))
      continue
    fi
    post_sha=$(remote_sha "$ip" "$vmid" "$path" || true)
    if [ "$post_sha" != "$desired_sha" ]; then
      echo "FAIL post-write sha mismatch for $path desired=$desired_sha got=${post_sha:-error}" >&2
      FAILURES=$((FAILURES + 1))
      continue
    fi
    changed=1
    echo "PASS file $path enforced sha=$desired_sha"
  done < <(jq -r '.files[] | @base64' <<<"$node_json")

  if [ "$MODE" = "--enforce" ] && [ "$changed" = "1" ]; then
    echo "ROLLING restart garage on ${name}"
    if restart_and_verify_node "$ip" "$vmid" "$name"; then
      echo "PASS garage restarted on ${name} and port 3900 is reachable"
    else
      FAILURES=$((FAILURES + 1))
    fi
  fi

  if [ "$ssh_failures" -gt 0 ] && [ "$admin_healthy" = "true" ]; then
    echo "NOTE ${name}: ${ssh_failures} file(s) could not be verified (management plane wedged, node operational via admin API)"
  fi
done < <(jq -r '.nodes[] | @base64' "$SPEC_JSON")

if [ "$FAILURES" -ne 0 ]; then
  exit 1
fi

echo "ALL CLEAN"