#!/usr/bin/env bash
# ============================================================
# pbs-rebuild-drill.sh — cattle rebuild proof for the PBS tier.
#
# Proves the same-host PBS restore tier is reproducible from Git:
#   1. render the REAL cloud-init-pbs.yaml.tftpl via tofu console
#   2. stamp an ephemeral drill VM (default 907, .248) with the
#      same spec as backup_pbs1 (module vm, pbs template, ovmf/q35,
#      scsi0 local-zfs + scsi1 bulkpool-dir data disk)
#   3. provision the OS disk with the repo's own vm-provisioner.sh
#      (debian-13 genericcloud, identical path as cattle rebuilds)
#   4. run the FULL repo PBS contract (enforce-pve-host-backup-stack.sh
#      --check with PBS_VM_ID overridden to the drill VM)
#   5. destroy the drill VM and snippet — live PBS (VM 905, .247)
#      is never touched.
#
# This closes the 2026-08-09 review gap: "migration success is not a
# reproducibility proof". Re-run any time; guarded by flock and by a
# pre-flight that refuses to run if the drill VMID is occupied by a VM
# that is not a previous drill instance.
#
# Usage:
#   pbs-rebuild-drill.sh [--check-only]      # render + static checks, no VM
#   pbs-rebuild-drill.sh                     # full drill (build, verify, destroy)
#   pbs-rebuild-drill.sh --keep              # full drill, leave VM for inspection
# ============================================================
set -euo pipefail

DRILL_VM_ID="${DRILL_VM_ID:-907}"
DRILL_IP="${DRILL_IP:-192.168.1.248}"
DRILL_NAME="backup-pbs-drill"
PVE_HOST="${PVE_HOST:-192.168.1.50}"
PVE_TARGET="root@${PVE_HOST}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/pve-kai}"
DRILL_DATA_DISK_GB="${DRILL_DATA_DISK_GB:-20}"

SSH_OPTS=( -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 )

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/infrastructure/terraform"
TOFU="${TOFU:-$HOME/.local/bin/tofu}"
SNIPPET_REMOTE="local:snippets/cloudinit-${DRILL_NAME}.yaml"
SNIPPET_PATH="/var/lib/vz/snippets/cloudinit-${DRILL_NAME}.yaml"

ssh_pve() { ssh "${SSH_OPTS[@]}" "$PVE_TARGET" "$@"; }

log() { echo "[pbs-drill] $*"; }
die() { echo "[pbs-drill][ERROR] $*" >&2; exit 1; }

cleanup_on_failure() {
  log "FAILURE — cleaning up drill VM ${DRILL_VM_ID} (live PBS untouched)"
  ssh_pve "qm stop ${DRILL_VM_ID} --timeout 30 2>/dev/null; qm destroy ${DRILL_VM_ID} --purge 2>/dev/null; rm -f '${SNIPPET_PATH}'" || true
}
trap cleanup_on_failure ERR

exec 9>/tmp/pbs-rebuild-drill.lock
flock -n 9 || die "another drill is already running"

# ── Safety: never run against anything that is not a drill VM ──
existing_name="$(ssh_pve "qm config ${DRILL_VM_ID} 2>/dev/null | awk '/^name:/{print \$2}'" || true)"
if [[ -n "$existing_name" && "$existing_name" != "$DRILL_NAME" ]]; then
  die "VM ${DRILL_VM_ID} exists and is '${existing_name}' (not ${DRILL_NAME}) — refusing to touch it"
fi

# ── Step 1: render the REAL PBS cloud-init template through tofu console ──
# Runs in a clean scratch dir (no backend/state) so the render is purely the
# template + vars — immune to stale local state and schema-decode noise.
log "rendering cloud-init-pbs.yaml.tftpl from Git via tofu console"
SSH_PUB_KEY="$(awk '/^  ssh_pub_key = /{gsub(/"/,"",$3); print $3; exit}' "$TF_DIR/main.tf")"
[[ -n "$SSH_PUB_KEY" ]] || die "could not extract ssh_pub_key from main.tf"
rm -rf /tmp/pbs-drill && mkdir -p /tmp/pbs-drill/console
cat > /tmp/pbs-drill/console/render.tf <<EOF
locals {
  rendered = templatefile("${TF_DIR}/modules/vm/templates/cloud-init-pbs.yaml.tftpl", {
    hostname    = "${DRILL_NAME}"
    ssh_pub_key = "${SSH_PUB_KEY}"
    admin_user  = "ubuntu"
  })
}
output "rendered" { value = local.rendered }
EOF
(cd /tmp/pbs-drill/console && "$TOFU" init -input=false >/dev/null 2>&1)
RENDER="$(
  cd /tmp/pbs-drill/console && "$TOFU" console <<'EOF' 2>/dev/null
local.rendered
EOF
)"
rm -rf /tmp/pbs-drill/console
[[ -n "$RENDER" ]] || die "tofu console returned empty render"
# tofu console prints multiline strings fenced as <<EOT ... EOT — strip the fence
sed '1{/^<<EOT$/d}' <<< "$RENDER" | sed '${/^EOT$/d}' > /tmp/pbs-drill/user-data.yaml
head -1 /tmp/pbs-drill/user-data.yaml | grep -q '^#cloud-config' || die "rendered file does not start with #cloud-config (EOT fence strip failed)"
grep -q '#cloud-config' /tmp/pbs-drill/user-data.yaml || die "rendered file is not cloud-config"
grep -q 'pbs-install.sh' /tmp/pbs-drill/user-data.yaml || die "rendered file missing PBS install bootstrap"
log "render OK ($(wc -l < /tmp/pbs-drill/user-data.yaml) lines)"

if [[ "${1:-}" == "--check-only" ]]; then
  log "check-only mode: template render verified, no VM created"
  exit 0
fi

# ── Step 2: stamp the drill VM (same spec as module "backup_pbs1") ──
if [[ "$existing_name" == "$DRILL_NAME" ]]; then
  log "removing leftover drill instance"
  ssh_pve "qm stop ${DRILL_VM_ID} --timeout 30 2>/dev/null; qm destroy ${DRILL_VM_ID} --purge; rm -f '${SNIPPET_PATH}'"
fi

log "uploading snippet + creating VM ${DRILL_VM_ID} (${DRILL_NAME})"
scp "${SSH_OPTS[@]}" /tmp/pbs-drill/user-data.yaml "${PVE_TARGET}:${SNIPPET_PATH}"
ssh_pve "qm create ${DRILL_VM_ID} \\
  --name ${DRILL_NAME} --ostype l26 --bios ovmf --machine q35 \\
  --cores 2 --cpuunits 2048 --cpu host --memory 2048 --balloon 0 \\
  --efidisk0 local-zfs:1,pre-enrolled-keys=1,efitype=4m \\
  --scsihw virtio-scsi-single \\
  --scsi0 local-zfs:32,ssd=1,discard=on,iothread=1 \\
  --scsi1 bulkpool-dir:${DRILL_DATA_DISK_GB},ssd=1,discard=on,iothread=1 \\
  --net0 virtio=BC:24:11:AA:90:07,bridge=vmbr0,queues=4 \\
  --ipconfig0 ip=${DRILL_IP}/24,gw=192.168.1.1 \\
  --ide2 local-zfs:cloudinit \\
  --agent enabled=1 --onboot 0 --boot order=scsi0 \\
  --tags drill,pbs \\
  --cicustom user=${SNIPPET_REMOTE}"

# ── Step 3: provision the OS disk with the repo's own provisioner ──
log "provisioning OS disk via repo vm-provisioner.sh (cattle rebuild path)"
HOME="$HOME" bash "$TF_DIR/modules/vm/scripts/vm-provisioner.sh" \
  "$DRILL_VM_ID" "$DRILL_NAME" 13 debian "$PVE_HOST" "$SSH_KEY" true

# ── Step 4: wait for FULL cloud-init convergence ──
# 'proxmox-backup-manager exists' only proves the apt install finished; the
# disk-setup and datastore bootstrap run after it. Wait for the actual
# repo contract (agent, then contract script) instead of racing ahead.
log "waiting for full cloud-init / PBS convergence on ${DRILL_NAME} (timeout 25m)"
ready="WAIT"
deadline=$(( $(date +%s) + 1500 ))
while (( $(date +%s) < deadline )); do
  if ssh_pve "qm guest exec ${DRILL_VM_ID} -- bash -lc 'command -v proxmox-backup-manager'" >/dev/null 2>&1; then
    ready="$(ssh_pve "qm guest exec ${DRILL_VM_ID} -- bash -lc 'command -v proxmox-backup-manager >/dev/null && echo READY || echo WAIT'" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data","").strip())' || echo WAIT)"
    [[ "$ready" == "READY" ]] && break
  fi
  sleep 20
done
[[ "$ready" == "READY" ]] || die "PBS did not converge within 25m (cloud-init failed or still running)"
log "manager present — waiting for datastore bootstrap (mkfs/mount/datastore create)"
deadline=$(( $(date +%s) + 300 ))
ds="WAIT"
while (( $(date +%s) < deadline )); do
  # The mountpoint is /srv/proxmox-backup-primary (the datastore dir below it
  # is NOT a mount) — checking the subdir made this wait impossible to satisfy.
  ds="$(ssh_pve "qm guest exec ${DRILL_VM_ID} -- bash -lc 'findmnt -n -o SOURCE /srv/proxmox-backup-primary >/dev/null 2>&1 && test -d /srv/proxmox-backup-primary/datastore && echo READY || echo WAIT'" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data","").strip())' || echo WAIT)"
  [[ "$ds" == "READY" ]] && break
  sleep 10
done
[[ "$ds" == "READY" ]] || die "datastore mount did not converge within 5m after manager install"
log "datastore converged"

# Wait out the template's post-cloud-init reboot before running contract
# checks (they ride the guest agent, which dies during a reboot).
log "waiting for cloud-init done + post-install reboot to settle"
deadline=$(( $(date +%s) + 900 ))
ci="WAIT"
while (( $(date +%s) < deadline )); do
  ci="$(ssh_pve "qm guest exec ${DRILL_VM_ID} --timeout 30 -- bash -lc 'cloud-init status 2>/dev/null | grep -q done && echo READY || echo WAIT'" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data","").strip())' || echo WAIT)"
  [[ "$ci" == "READY" ]] && break
  sleep 15
done
[[ "$ci" == "READY" ]] || die "cloud-init never reached 'done'"
deadline=$(( $(date +%s) + 900 ))
rebooted="WAIT"
while (( $(date +%s) < deadline )); do
  rebooted="$(ssh_pve "qm guest exec ${DRILL_VM_ID} --timeout 30 -- bash -lc 'up=\$(cut -d. -f1 /proc/uptime); [ \"\$up\" -lt 120 ] && echo READY || echo WAIT'" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data","").strip())' || echo WAIT)"
  [[ "$rebooted" == "READY" ]] && break
  sleep 15
done
[[ "$rebooted" == "READY" ]] || die "post-install reboot not observed within 15m"
deadline=$(( $(date +%s) + 600 ))
healthy="WAIT"
while (( $(date +%s) < deadline )); do
  healthy="$(ssh_pve "qm guest exec ${DRILL_VM_ID} --timeout 30 -- bash -lc 'systemctl is-system-running >/dev/null 2>&1 \&\& findmnt -n -o SOURCE /srv/proxmox-backup-primary >/dev/null 2>&1 \&\& echo READY || echo WAIT'" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data","").strip())' || echo WAIT)"
  [[ "$healthy" == "READY" ]] && break
  sleep 15
done
[[ "$healthy" == "READY" ]] || die "system did not come back healthy after reboot"
log "post-reboot settled"

# ── Step 5: run the FULL repo PBS contract against the drill VM ──
log "running repo PBS contract against ${DRILL_NAME} (PBS_VM_ID=${DRILL_VM_ID})"
PBS_VM_ID="$DRILL_VM_ID" bash "$SCRIPT_DIR/enforce-pve-host-backup-stack.sh" --check

log "verify datastore state on drill VM"
state="$(ssh_pve "qm guest exec ${DRILL_VM_ID} -- bash -lc 'proxmox-backup-manager datastore list --output-format json'" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data","").strip())')"
echo "$state" | python3 -c 'import json,sys; items=json.loads(sys.stdin.read()); raise SystemExit(0 if any(i.get("name")=="primary" for i in items) else 1)' \
  || die "drill VM datastore 'primary' missing"

# ── Step 6: destroy the drill ──
if [[ "${1:-}" == "--keep" ]]; then
  log "KEEP mode: drill VM left running at ${DRILL_IP} (ssh root@${DRILL_IP}) — destroy manually with: qm stop ${DRILL_VM_ID} && qm destroy ${DRILL_VM_ID} --purge"
  exit 0
fi
log "destroying drill VM + snippet"
ssh_pve "qm stop ${DRILL_VM_ID} --timeout 30; qm destroy ${DRILL_VM_ID} --purge; rm -f '${SNIPPET_PATH}'"
ssh-keygen -R "$DRILL_IP" >/dev/null 2>&1 || true
rm -rf /tmp/pbs-drill

log "PASS — PBS tier rebuilds from Git: template render, VM stamp, provisioner, and full repo contract all verified on a fresh VM"
