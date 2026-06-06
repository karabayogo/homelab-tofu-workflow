#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---check}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/pve-kai}"
TERRAFORM_DIR="${TERRAFORM_DIR:-infrastructure/terraform}"

case "$MODE" in
  --check|--enforce) ;;
  *)
    echo "usage: $0 [--check|--enforce]" >&2
    exit 2
    ;;
esac

if ! command -v tofu >/dev/null 2>&1; then
  echo "tofu not found in PATH" >&2
  exit 2
fi

if [ ! -f "$SSH_KEY_PATH" ]; then
  echo "SSH key not found: $SSH_KEY_PATH" >&2
  exit 2
fi

readonly SSH_COMMON_OPTS=(
  -i "$SSH_KEY_PATH"
  -n
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=8
)

ssh_first_success() {
  local node_name="$1"
  local node_ip="$2"
  local remote_cmd="$3"
  local ssh_target
  local out=""

  for ssh_target in "$node_name" "root@${node_ip}" "ubuntu@${node_ip}"; do
    out="$(ssh "${SSH_COMMON_OPTS[@]}" "$ssh_target" "$remote_cmd" 2>/dev/null || true)"
    if [ -n "$out" ]; then
      printf '%s' "$out"
      return 0
    fi
  done

  return 1
}

node_state() {
  local node_name="$1"
  local node_ip="$2"
  local out=""
  local remote_cmd='
    if [ "$(id -u)" -ne 0 ]; then SUDO=sudo; else SUDO=""; fi
    enabled="$($SUDO systemctl is-enabled multipathd.service multipathd.socket 2>/dev/null | paste -sd, -)"
    active="$($SUDO systemctl is-active multipathd.service multipathd.socket 2>/dev/null | paste -sd, -)"
    blacklist="missing"
    module_state="unloaded"
    session_state="clean"
    if [ -f /etc/modprobe.d/99-longhorn-no-multipath.conf ] && sed -n "/blacklist dm_multipath/p" /etc/modprobe.d/99-longhorn-no-multipath.conf >/dev/null 2>&1; then
      blacklist="present"
    fi
    if lsmod | awk "\$1 == \"dm_multipath\" { found=1 } END { exit(found ? 0 : 1) }"; then
      module_state="loaded"
    fi
    if $SUDO iscsiadm -m session -P 1 2>/dev/null | awk "
      /iSCSI Session State:/ { if (\$NF == \"FREE\") bad=1 }
      /Internal iscsid Session State:/ { if (\$NF == \"REOPEN\") bad=1 }
      END { exit(bad ? 0 : 1) }
    "; then
      session_state="stale"
    fi
    printf "%s\t%s\t%s\t%s\t%s\n" "${enabled:-unknown}" "${active:-unknown}" "$blacklist" "$module_state" "$session_state"
  '

  out="$(ssh_first_success "$node_name" "$node_ip" "$remote_cmd" || true)"
  if [ -z "$out" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$node_name" "$node_ip" "unreachable" "unreachable" "missing" "unknown"
    return 0
  fi

  printf '%s\t%s\t%s\n' "$node_name" "$node_ip" "$out"
}

inventory_rows() {
  local inventory_json=""

  if inventory_json="$(tofu output -json k8s_node_inventory 2>/dev/null)"; then
    python3 - "$inventory_json" <<'PY'
import json, sys

for item in json.loads(sys.argv[1]):
    print(f"{item['name']}\t{item['ip']}")
PY
    return 0
  fi

  python3 - "main.tf" <<'PY'
import re
import sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text().splitlines()
module_start = re.compile(r'module\s+"(k8s_[^"]+)"\s*\{')
kv = re.compile(r'^\s*([a-zA-Z0-9_]+)\s*=\s*"([^"]+)"')

current = None
depth = 0
values = {}

for line in lines:
    if current is None:
        match = module_start.search(line)
        if match:
            current = match.group(1)
            depth = line.count("{") - line.count("}")
            values = {}
        continue

    depth += line.count("{") - line.count("}")
    match = kv.search(line)
    if match:
        values[match.group(1)] = match.group(2)

    if depth == 0:
        name = values.get("vm_name")
        ip = values.get("static_ip")
        if name and ip:
            print(f"{name}\t{ip}")
        current = None
        values = {}
PY
}

inventory_state_rows() {
  while IFS=$'\t' read -r node_name node_ip; do
    [ -z "$node_name" ] && continue
    node_state "$node_name" "$node_ip"
  done < <(inventory_rows)
}

enforce_node() {
  local node_name="$1"
  local node_ip="$2"
  local remote_cmd='
    set -e
    if [ "$(id -u)" -ne 0 ]; then SUDO=sudo; else SUDO=""; fi
    stale_sessions="$($SUDO iscsiadm -m session -P 1 2>/dev/null | awk "
      /^Target: / { target=\$2; portal=\"\"; stale=0 }
      /^Current Portal: / { portal=\$3; sub(/,.*/, \"\", portal) }
      /iSCSI Session State:/ { if (\$NF == \"FREE\") stale=1 }
      /Internal iscsid Session State:/ { if (\$NF == \"REOPEN\") stale=1 }
      /^$/ {
        if (stale && target != \"\" && portal != \"\") {
          printf \"%s\\t%s\\n\", target, portal
        }
        target=\"\"; portal=\"\"; stale=0
      }
      END {
        if (stale && target != \"\" && portal != \"\") {
          printf \"%s\\t%s\\n\", target, portal
        }
      }
    " || true)"
    while IFS="$(printf "\t")" read -r target portal; do
      [ -z "${target:-}" ] && continue
      $SUDO iscsiadm -m node -T "$target" -p "$portal" --logout || true
      $SUDO iscsiadm -m node -T "$target" -p "$portal" -o delete || true
    done <<EOF
$stale_sessions
EOF
    $SUDO systemctl stop multipathd.socket multipathd.service || true
    $SUDO systemctl disable multipathd.socket multipathd.service || true
    $SUDO systemctl mask multipathd.socket multipathd.service || true
    $SUDO multipath -F || true
    $SUDO modprobe -r dm_service_time dm_multipath || true
    printf "%s\n" "blacklist dm_multipath" | $SUDO tee /etc/modprobe.d/99-longhorn-no-multipath.conf >/dev/null
    enabled="$($SUDO systemctl is-enabled multipathd.service multipathd.socket 2>/dev/null | paste -sd, -)"
    active="$($SUDO systemctl is-active multipathd.service multipathd.socket 2>/dev/null | paste -sd, -)"
    blacklist="missing"
    module_state="unloaded"
    session_state="clean"
    if [ -f /etc/modprobe.d/99-longhorn-no-multipath.conf ] && sed -n "/blacklist dm_multipath/p" /etc/modprobe.d/99-longhorn-no-multipath.conf >/dev/null 2>&1; then
      blacklist="present"
    fi
    if lsmod | awk "\$1 == \"dm_multipath\" { found=1 } END { exit(found ? 0 : 1) }"; then
      module_state="loaded"
    fi
    if $SUDO iscsiadm -m session -P 1 2>/dev/null | awk "
      /iSCSI Session State:/ { if (\$NF == \"FREE\") bad=1 }
      /Internal iscsid Session State:/ { if (\$NF == \"REOPEN\") bad=1 }
      END { exit(bad ? 0 : 1) }
    "; then
      session_state="stale"
    fi
    printf "%s\t%s\t%s\t%s\t%s\n" "${enabled:-unknown}" "${active:-unknown}" "$blacklist" "$module_state" "$session_state"
  '

  if ! ssh_first_success "$node_name" "$node_ip" "$remote_cmd" >/dev/null; then
    echo "FAIL ${node_name}: unable to reach node for enforcement" >&2
    return 1
  fi
}

is_hardened() {
  local enabled_csv="$1"
  local active_csv="$2"
  local blacklist_state="$3"
  local module_state="$4"
  local session_state="$5"

  [ "$enabled_csv" = "masked,masked" ] || return 1
  [ "$active_csv" = "inactive,inactive" ] || return 1
  [ "$blacklist_state" = "present" ] || return 1
  [ "$module_state" = "unloaded" ] || return 1
  [ "$session_state" = "clean" ] || return 1
}

cd "$TERRAFORM_DIR"

FAILURES=0
while IFS=$'\t' read -r node_name node_ip enabled_csv active_csv blacklist_state module_state session_state; do
  if [ -z "$node_name" ]; then
    continue
  fi

  if [ "$MODE" = "--enforce" ]; then
    if ! is_hardened "$enabled_csv" "$active_csv" "$blacklist_state" "$module_state" "$session_state"; then
      echo "ENFORCE ${node_name} (${node_ip}) enabled=${enabled_csv} active=${active_csv} blacklist=${blacklist_state} module=${module_state} session=${session_state}"
      enforce_node "$node_name" "$node_ip"
      read -r node_name node_ip enabled_csv active_csv blacklist_state module_state session_state <<<"$(node_state "$node_name" "$node_ip")"
    fi
  fi

  if is_hardened "$enabled_csv" "$active_csv" "$blacklist_state" "$module_state" "$session_state"; then
    echo "PASS ${node_name} (${node_ip}) enabled=${enabled_csv} active=${active_csv} blacklist=${blacklist_state} module=${module_state} session=${session_state}"
  else
    echo "FAIL ${node_name} (${node_ip}) enabled=${enabled_csv} active=${active_csv} blacklist=${blacklist_state} module=${module_state} session=${session_state}"
    FAILURES=$((FAILURES + 1))
  fi
done < <(inventory_state_rows)

if [ "$FAILURES" -ne 0 ]; then
  exit 1
fi
