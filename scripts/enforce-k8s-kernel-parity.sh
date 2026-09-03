#!/usr/bin/env bash
# K8s kernel parity enforcer — GitOps cattle, non-destructive.
#
# RCA (2026-09-03): k8s-worker1 hard-rebooted at 06:33Z after an unattended
# userspace upgrade + needrestart daemon-reexec churn. GRUB_DEFAULT=0 means
# "boot the NEWEST installed kernel" — the node came back on 6.8.0-138 that
# had been sitting idle since Aug-20, and the uncoordinated reboot / kernel
# jump wedged Longhorn engines (14.5h of crash-looping, 174 restarts, zero
# alerts before the fiefdom gate).
#
# This script converges the k3s fleet to the Git-declared kernel policy:
#   1. apt:  Unattended-Upgrade::Automatic-Reboot "false" (categorical no to
#            self-reboot), keep installed kernels (no Remove-Unused).
#   2. needrestart: list-only restarts — k8s containers restart via k8s
#            controllers, never via needrestart mid-apt (the 06:32:18
#            daemon-reexec churn was exactly that).
#   3. GRUB: GRUB_DEFAULT=saved + GRUB_SAVEDEFAULT=true — boot the kernel
#            that was LAST BOOTED, never "newest installed". This is the
#            structural fix: a crash-reboot stays on the same kernel.
#   4. Parity: running kernel must equal the Git contract per node.
#              (contract: infrastructure/contracts/k8s-kernel-parity.json)
#
# --check   : report any deviation, exit 1 on drift (page via fiefdom gate).
# --enforce : write policy files + update-grub + saved-default seed, then
#             re-verify. NEVER reboots (reboot orchestration is the separate
#             maintenance-window script, gated on cordon+drain+volume health).
#
set -euo pipefail

MODE="${1:---check}"
LIVE_CHECK="${LIVE_CHECK:-1}"
SSH_KEY_PATH="${VM_SSH_KEY_PATH:-${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAIN_TF="${MAIN_TF:-$REPO_ROOT/infrastructure/terraform/main.tf}"
ROOT_VARIABLES_TF="${ROOT_VARIABLES_TF:-$REPO_ROOT/infrastructure/terraform/variables.tf}"
TERRAFORM_TFVARS="${TERRAFORM_TFVARS:-$REPO_ROOT/infrastructure/terraform/terraform.tfvars}"
CONTRACT_JSON="${CONTRACT_JSON:-$REPO_ROOT/infrastructure/contracts/k8s-kernel-parity.json}"

case "$MODE" in
  --check|--enforce) ;;
  *) echo "usage: $0 [--check|--enforce]" >&2; exit 2 ;;
esac

for f in "$MAIN_TF" "$CONTRACT_JSON"; do
  test -f "$f" || { echo "required file missing: $f" >&2; exit 2; }
done
test -f "$SSH_KEY_PATH" || { echo "SSH key not found: $SSH_KEY_PATH" >&2; exit 2; }

readonly SSH_OPTS=(
  -i "$SSH_KEY_PATH" -n -o BatchMode=yes
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2
)

# ---- inventory: reuse the main.tf parser approach from enforce-k8s-k3s-config.sh
inventory_json() {
  python3 - "$MAIN_TF" "$ROOT_VARIABLES_TF" "$TERRAFORM_TFVARS" "$CONTRACT_JSON" <<'PY'
import json, re, sys
from pathlib import Path
main_tf = Path(sys.argv[1]).read_text()
root_variables_tf = Path(sys.argv[2]).read_text()
tfvars_path = Path(sys.argv[3])
tfvars_text = tfvars_path.read_text() if tfvars_path.exists() else ""
contract = json.loads(Path(sys.argv[4]).read_text())

quoted_value = re.compile(r'^\s*([a-zA-Z0-9_]+)\s*=\s*"([^"]*)"')
bool_value = re.compile(r'^\s*([a-zA-Z0-9_]+)\s*=\s*(true|false)\s*$')
module_start = re.compile(r'^module\s+"([^"]+)"\s*\{')
ref_value = re.compile(r'^\s*([a-zA-Z0-9_]+)\s*=\s*(local|var)\.([a-zA-Z0-9_]+)\s*$')
number_value = re.compile(r'^\s*([a-zA-Z0-9_]+)\s*=\s*([0-9]+)\s*$')

def resolve(raw, refs):
    if raw not in (None, ""):
        return raw
    if refs and refs.get("kind") == "var":
        name = refs["name"]
        # tfvars over env over variables.tf default
        for key in (f"TF_VAR_{name}", name.upper()):
            if os.environ.get(key):
                return os.environ[key]
        m = re.search(rf'variable\s+"{re.escape(name)}"\s*\{{.*?default\s*=\s*"([^"]*)"', root_variables_tf, re.S)
        return m.group(1) if m else ""
    return ""

import os
nodes, current, depth, values, refs = [], None, 0, {}, {}
for line in main_tf.splitlines():
    if current is None:
        m = module_start.match(line)
        if m and m.group(1).startswith("k8s_"):
            current = m.group(1); depth = line.count("{") - line.count("}")
            values, refs = {}, {}
        continue
    depth += line.count("{") - line.count("}")
    m = quoted_value.match(line)
    if m:
        k, v = m.group(1), m.group(2)
        if re.match(r'^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$', v):
            values[k] = v
        else:
            values.setdefault(k, v)
        continue
    m = bool_value.match(line)
    if m: values.setdefault(m.group(1), m.group(2)); continue
    m = ref_value.match(line)
    if m: refs[m.group(1)] = {"kind": m.group(2), "name": m.group(3)}; continue
    m = number_value.match(line)
    if m: values.setdefault(m.group(1), m.group(2)); continue
    if depth == 0:
        name = values.get("vm_name", "")
        role = values.get("k3s_role", "")
        cc = contract["nodes"].get(name, {})
        if name.startswith("k8s-") and role in ("agent", "server"):
            nodes.append({
                "name": name, "role": role,
                "ip": values.get("static_ip", ""),
                "admin_user": values.get("admin_user", "ubuntu"),
                "contract_kernel": cc.get("contract_kernel", ""),
            })
        current, depth, values, refs = None, 0, {}, {}
print(json.dumps({"nodes": nodes}))
PY
}

ssh_first_success() {
  local ip="$1" admin_user="$2" remote_cmd="$3" target
  for target in "${admin_user}@${ip}" "ubuntu@${ip}" "root@${ip}"; do
    if ssh "${SSH_OPTS[@]}" "$target" "$remote_cmd" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

node_remote_state() {
  local ip="$1" admin_user="$2" contract_kernel="$3"
  ssh_first_success "$ip" "$admin_user" "CONTRACT_KERNEL='$contract_kernel' python3 - <<'PY'
import os, pathlib

def read(p):
    try:
        return pathlib.Path(p).read_text().strip()
    except Exception:
        return '__MISSING__'

def matches(p, needle):
    return needle in read(p)

ok = True
reasons = []

# 1. apt policy
if not matches('/etc/apt/apt.conf.d/98k8s-kernel-policy', 'Automatic-Reboot \"false\"'):
    ok = False; reasons.append('apt policy missing Automatic-Reboot false')
if not matches('/etc/apt/apt.conf.d/98k8s-kernel-policy', 'Remove-Unused-Dependencies \"false\"'):
    ok = False; reasons.append('apt policy missing Remove-Unused-Dependencies false')
# 2. needrestart
if not matches('/etc/needrestart/conf.d/98-k8s-cattle.conf', \"nrconf{restart} = 'l'\"):
    ok = False; reasons.append('needrestart not list-only')
# 3. grub pin
if not matches('/etc/default/grub.d/98-k8s-boot-pin.cfg', 'GRUB_DEFAULT=saved'):
    ok = False; reasons.append('grub boot-pin GRUB_DEFAULT=saved missing')
if not matches('/etc/default/grub.d/98-k8s-boot-pin.cfg', 'GRUB_SAVEDEFAULT=true'):
    ok = False; reasons.append('grub boot-pin GRUB_SAVEDEFAULT=true missing')
# effective boot default: the base /etc/default/grub keeps GRUB_DEFAULT=0;
# the grub.d drop-in must have taken effect in the GENERATED grub.cfg ->
# "set default=\${saved_entry}" with grubenv seed for the running kernel.
grubcfg = read('/boot/grub/grub.cfg')
if 'set default="\${saved_entry}"' not in grubcfg:
    ok = False; reasons.append('grub.cfg not resolving to saved_entry (drop-in not regenerated)')
for env_k in ('saved_entry', 'prev_saved_entry'):
    env_line = read('/boot/grub/grubenv')
    if env_k + '=' not in env_line:
        ok = False; reasons.append(f'grubenv {env_k} unset (saved-default seed missing)')
# 4. running kernel
running = read('/proc/sys/kernel/osrelease')
env = os.environ.get('CONTRACT_KERNEL', '')
if env and running != env:
    ok = False; reasons.append(f'kernel drift: running={running} contract={env}')
# 5. reboot-required — with the GRUB boot-pin active this is an
#    OPERATIONAL signal (a newer kernel is staged for the maintenance window),
#    not drift: a reboot on a saved-default node stays on the contract kernel.
if pathlib.Path('/run/reboot-required').exists():
    print('NOTE: /run/reboot-required present (newer kernel staged; maintenance window applies it)', flush=True)
print(('OK' if ok else 'DRIFT') + ' kernel=' + running + ('; ' + '; '.join(reasons) if reasons else ''))
exit(0 if ok else 1)
PY"
}

apply_remote_policy() {
  local ip="$1" admin_user="$2"
  ssh_first_success "$ip" "$admin_user" "set -euo pipefail
# ubuntu-login nodes need sudo for root-owned writes; root nodes skip it.
if [ \"\$(id -u)\" -ne 0 ]; then SUDO=\"sudo\"; else SUDO=\"\"; fi
\$SUDO mkdir -p /etc/apt/apt.conf.d /etc/needrestart/conf.d /etc/default/grub.d
cat > /tmp/98k8s-kernel-policy <<'EOF'
// GitOps cattle kernel policy — managed by homelab-tofu-workflow
// (enforce-k8s-kernel-parity.sh). DO NOT EDIT ON NODE.
Unattended-Upgrade::Automatic-Reboot \"false\";
Unattended-Upgrade::Remove-Unused-Dependencies \"false\";
EOF
\$SUDO cp /tmp/98k8s-kernel-policy /etc/apt/apt.conf.d/98k8s-kernel-policy
cat > /tmp/98-k8s-cattle.conf <<'EOF'
// k8s cattle: never auto-restart services during apt runs.
\$nrconf{restart} = 'l';
\$nrconf{kernelhints} = -1;
EOF
\$SUDO cp /tmp/98-k8s-cattle.conf /etc/needrestart/conf.d/98-k8s-cattle.conf
cat > /tmp/98-k8s-boot-pin.cfg <<'EOF'
GRUB_DEFAULT=saved
GRUB_SAVEDEFAULT=true
EOF
\$SUDO cp /tmp/98-k8s-boot-pin.cfg /etc/default/grub.d/98-k8s-boot-pin.cfg
rm -f /tmp/98k8s-kernel-policy /tmp/98-k8s-cattle.conf /tmp/98-k8s-boot-pin.cfg
# regenerate grub.cfg with the pin, then seed saved_entry to the CURRENT
# kernel so the next boot stays on it even before any saved-default boot
\$SUDO update-grub 2>/dev/null || \$SUDO grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
RUNNING=\$(uname -r)
SUBMENU=\"Advanced options for Ubuntu>Ubuntu, with Linux \${RUNNING}\"
\$SUDO grub-editenv /boot/grub/grubenv set saved_entry=\"\$SUBMENU\" 2>/dev/null || true
\$SUDO grub-editenv /boot/grub/grubenv set prev_saved_entry=\"\$SUBMENU\" 2>/dev/null || true
echo POLICY_APPLIED kernel=\$RUNNING
"
}

fail=0
declare -A SEEN
INV="$(inventory_json)"
echo "mode=$MODE  live_check=$LIVE_CHECK"
echo "parity inventory:"
echo "$INV" | python3 -c 'import json,sys; d=json.load(sys.stdin); [print("  ", n["name"], n["role"], n["ip"], "contract="+n["contract_kernel"]) for n in d["nodes"]]'

TOTAL=0; DRIFT_COUNT=0
for row in $(echo "$INV" | python3 -c '
import json,sys
for n in json.load(sys.stdin)["nodes"]:
    print(n["name"] + "|" + n["role"] + "|" + n["ip"] + "|" + n["admin_user"] + "|" + n["contract_kernel"])
'); do
  IFS='|' read -r name role ip admin_user ck <<< "$row"
  [ -z "$name" ] || [ -n "${SEEN[$name]:-}" ] && continue
  SEEN[$name]=1
  TOTAL=$((TOTAL+1))

  # repo-only check still validates the contract file has this node + kernel sanity
  if [ "$LIVE_CHECK" = "0" ]; then
    if [ -z "$ck" ]; then
      echo "DRIFT $name: missing contract_kernel in k8s-kernel-parity.json"
      DRIFT_COUNT=$((DRIFT_COUNT+1))
    else
      echo "OK   $name (repo-only): contract kernel=$ck"
    fi
    continue
  fi

  if [ "$MODE" = "--enforce" ]; then
    echo "ENFORCE $name ($ip) ..."
    out="$(apply_remote_policy "$ip" "$admin_user" 2>&1)" && ok=1 || ok=0
    echo "  $out"
    if [ "$ok" != "1" ]; then DRIFT_COUNT=$((DRIFT_COUNT+1)); continue; fi
  fi

  out="$(node_remote_state "$ip" "$admin_user" "$ck" 2>&1)" && rc=$? || rc=$?
  echo "  $out"
  if [ "$rc" -ne 0 ]; then
    DRIFT_COUNT=$((DRIFT_COUNT+1))
    if [ "$MODE" = "--enforce" ] && [ "$LIVE_CHECK" = "1" ]; then
      echo "  WARN: $name still drifting after enforce (contract kernel=$ck — kernel change requires maintenance window, not force)"
    fi
  fi
done

echo ""
echo "k8s kernel parity: $((TOTAL-DRIFT_COUNT))/$TOTAL compliant, $DRIFT_COUNT drifting"
if [ "$DRIFT_COUNT" -gt 0 ]; then
  exit 1
fi
echo "All k3s nodes compliant with kernel parity contract."
exit 0