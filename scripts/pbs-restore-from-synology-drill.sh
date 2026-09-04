#!/usr/bin/env bash
# ============================================================
# pbs-restore-from-synology-drill.sh — the DR-endpoint proof.
#
# The rebuild drill (pbs-rebuild-drill.sh) proves the PBS tier can be
# rebuilt from Git. THIS drill proves the actual disaster-recovery
# endpoint: a fresh PBS built from Git, with ZERO access to the live
# PBS datastore, recovers a restorable datastore from the Synology
# off-host mirror alone and successfully restores a guest config from
# it. "Backups you have never restored are just hopes."
#
# Flow:
#   1. render real cloud-init-pbs.yaml.tftpl (tofu console, scratch dir)
#   2. stamp ephemeral drill VM 907/.248 (same spec as backup_pbs1)
#   3. provision via repo vm-provisioner.sh, wait for full convergence
#   4. push the curated Synology mirror into the drill PBS datastore
#      (rsync over the drill VM's SSH; live PBS .247 never touched)
#   5. verify chunk store integrity (proxmox-backup-debug recover:
#      index -> chunk walk) on the restored datastore
#   6. restore host/pve-config latest snapshot into a real pxar archive
#   7. destroy the drill
#
# Usage:
#   pbs-restore-from-synology-drill.sh              # full drill
#   pbs-restore-from-synology-drill.sh --keep       # leave VM for inspection
# ============================================================
set -euo pipefail

DRILL_VM_ID="${DRILL_VM_ID:-907}"
DRILL_IP="${DRILL_IP:-192.168.1.248}"
DRILL_NAME="pbs-restore-drill"
PVE_HOST="${PVE_HOST:-192.168.1.50}"
PVE_TARGET="root@${PVE_HOST}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/pve-kai}"
DRILL_DATA_DISK_GB="${DRILL_DATA_DISK_GB:-20}"
SYN_ROOT="${SYN_ROOT:-/mnt/synology/proxmoxbackups/homelab_backups/pve/pbs-primary}"

SSH_OPTS=( -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 )

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/infrastructure/terraform"
TOFU="${TOFU:-$HOME/.local/bin/tofu}"
SNIPPET_REMOTE="local:snippets/cloudinit-${DRILL_NAME}.yaml"
SNIPPET_PATH="/var/lib/vz/snippets/cloudinit-${DRILL_NAME}.yaml"

# ── Step 0: mirror preflight + data-disk auto-sizing (2026-09-04) ──
# The Synology mirror is the DR source of truth — fail fast BEFORE the
# ~4.5h run if a required snapshot group is missing, and size the drill's
# data disk from the live mirror so a hardcoded constant can never overflow
# or drift (the script default of 20 GiB was 3.5x too small for the actual
# 71.5 GiB mirror — the Sep-02 manual run only worked because it passed
# DRILL_DATA_DISK_GB=100 by hand).
for group in host/pve-config vm/201 vm/300 vm/906; do
  n_snap="$(ls -d "${SYN_ROOT}/datastore/${group}"/*/ 2>/dev/null | wc -l)"
  [[ "${n_snap:-0}" -ge 1 ]] || die "Synology mirror missing snapshots for group '${group}' (SYN_ROOT=${SYN_ROOT}) — refusing to run a doomed 4.5h drill"
done
mirror_gb="$(du -s "${SYN_ROOT}/datastore" 2>/dev/null | awk '{printf "%d", ($1 * 1.25) / 1048576 + 1}')"
mirror_gb="${mirror_gb:-0}"
if [ "$mirror_gb" -gt 0 ] && [ "$mirror_gb" -gt "$DRILL_DATA_DISK_GB" ]; then
  log "auto-sizing data disk ${DRILL_DATA_DISK_GB} -> ${mirror_gb} GiB (live mirror ${mirror_gb} GiB incl 25% margin)"
  DRILL_DATA_DISK_GB="$mirror_gb"
fi

ssh_pve() { ssh "${SSH_OPTS[@]}" "$PVE_TARGET" "$@"; }
log() { echo "[restore-drill] $*"; }
die() { echo "[restore-drill][ERROR] $*" >&2; exit 1; }

cleanup_on_failure() {
  log "FAILURE — cleaning up drill VM ${DRILL_VM_ID} (live PBS untouched)"
  ssh_pve "qm stop ${DRILL_VM_ID} --timeout 30 2>/dev/null; qm destroy ${DRILL_VM_ID} --purge 2>/dev/null; rm -f '${SNIPPET_PATH}'" || true
}
trap cleanup_on_failure ERR

exec 9>/tmp/pbs-drill.lock
flock -n 9 || die "another drill (rebuild or restore) is already running"
# 2026-09-04: shared lock across BOTH drill scripts — rebuild and restore
# both stamp VM 907/.248; mutual exclusion by name-guard alone was fragile.

# ── Safety: never run against anything that is not a drill VM ──
existing_name="$(ssh_pve "qm config ${DRILL_VM_ID} 2>/dev/null | awk '/^name:/{print \$2}'" || true)"
if [[ -n "$existing_name" && "$existing_name" != "$DRILL_NAME" ]]; then
  die "VM ${DRILL_VM_ID} exists and is '${existing_name}' (not ${DRILL_NAME}) — refusing to touch it"
fi
if [[ "$existing_name" == "$DRILL_NAME" ]]; then
  log "removing leftover drill instance"
  ssh_pve "qm stop ${DRILL_VM_ID} --timeout 30 2>/dev/null; qm destroy ${DRILL_VM_ID} --purge; rm -f '${SNIPPET_PATH}'"
fi

# ── Step 1: render the REAL PBS cloud-init template from Git ──
log "rendering cloud-init-pbs.yaml.tftpl from Git via tofu console (scratch dir)"
SSH_PUB_KEY="$(awk '/^  ssh_pub_key = /{gsub(/"/,"",$3); print $3; exit}' "$TF_DIR/main.tf")"
[[ -n "$SSH_PUB_KEY" ]] || die "could not extract ssh_pub_key from main.tf"
rm -rf /tmp/restore-drill && mkdir -p /tmp/restore-drill/console
cat > /tmp/restore-drill/console/render.tf <<EOF
locals {
  rendered = templatefile("${TF_DIR}/modules/vm/templates/cloud-init-pbs.yaml.tftpl", {
    hostname    = "${DRILL_NAME}"
    ssh_pub_key = "${SSH_PUB_KEY}"
    admin_user  = "ubuntu"
  })
}
output "rendered" { value = local.rendered }
EOF
(cd /tmp/restore-drill/console && "$TOFU" init -input=false >/dev/null 2>&1)
RENDER="$(cd /tmp/restore-drill/console && "$TOFU" console <<'EOF' 2>/dev/null
local.rendered
EOF
)"
rm -rf /tmp/restore-drill/console
[[ -n "$RENDER" ]] || die "tofu console returned empty render"
sed '1{/^<<EOT$/d}' <<< "$RENDER" | sed '${/^EOT$/d}' > /tmp/restore-drill/user-data.yaml
head -1 /tmp/restore-drill/user-data.yaml | grep -q '^#cloud-config' || die "render does not start with #cloud-config"
log "render OK ($(wc -l < /tmp/restore-drill/user-data.yaml) lines)"

# ── Step 2: stamp the drill VM (same spec as module backup_pbs1) ──
log "uploading snippet + creating VM ${DRILL_VM_ID} (${DRILL_NAME})"
scp "${SSH_OPTS[@]}" /tmp/restore-drill/user-data.yaml "${PVE_TARGET}:${SNIPPET_PATH}"
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
  --tags drill,pbs,restore \\
  --cicustom user=${SNIPPET_REMOTE}"

# ── Step 3: provision OS disk with the repo's own provisioner ──
log "provisioning OS disk via repo vm-provisioner.sh"
HOME="$HOME" bash "$TF_DIR/modules/vm/scripts/vm-provisioner.sh" \
  "$DRILL_VM_ID" "$DRILL_NAME" 13 debian "$PVE_HOST" "$SSH_KEY" true

# ── Step 4: wait for FULL cloud-init convergence ──
log "waiting for full PBS convergence (timeout 25m)"
ready="WAIT"
deadline=$(( $(date +%s) + 1500 ))
while (( $(date +%s) < deadline )); do
  if ssh_pve "qm guest exec ${DRILL_VM_ID} -- bash -lc 'command -v proxmox-backup-manager'" >/dev/null 2>&1; then
    ready="$(ssh_pve "qm guest exec ${DRILL_VM_ID} -- bash -lc 'command -v proxmox-backup-manager >/dev/null && echo READY || echo WAIT'" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data","").strip())' || echo WAIT)"
    [[ "$ready" == "READY" ]] && break
  fi
  sleep 20
done
[[ "$ready" == "READY" ]] || die "PBS did not converge within 25m"
log "manager present — waiting for datastore bootstrap"
deadline=$(( $(date +%s) + 300 ))
ds="WAIT"
while (( $(date +%s) < deadline )); do
  ds="$(ssh_pve "qm guest exec ${DRILL_VM_ID} -- bash -lc 'findmnt -n -o SOURCE /srv/proxmox-backup-primary >/dev/null 2>&1 && test -d /srv/proxmox-backup-primary/datastore && echo READY || echo WAIT'" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data","").strip())' || echo WAIT)"
  [[ "$ds" == "READY" ]] && break
  sleep 10
done
[[ "$ds" == "READY" ]] || die "datastore mount did not converge"
log "datastore converged"
# Capture boot-1 uptime NOW (before cloud-init 'done'/reboot) as the reboot
# baseline. cloud-init 'done' persists across the template's power_state
# reboot, so a post-done check alone cannot tell which boot we're on.
BOOT1_UPTIME="$(ssh_pve "qm guest exec ${DRILL_VM_ID} --timeout 20 -- bash -lc 'cut -d. -f1 /proc/uptime'" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("out-data","").strip())
except Exception: print("")' || echo "")"
[[ "$BOOT1_UPTIME" =~ ^[0-9]+$ ]] || BOOT1_UPTIME=""
log "boot-1 uptime baseline: ${BOOT1_UPTIME:-unknown}"

# ── Step 4b: wait out the template's post-cloud-init reboot ──
# The PBS template reboots via cloud-init power_state after install. A
# datastore-mount check can pass on first boot while the reboot is imminent
# (2026-09-02 restore-drill RCA: rsync connected exactly as the VM went down
# — pam_nologin, broken pipe). Wait for: cloud-init done -> reboot (uptime
# drop) -> system running with datastore mounted.
log "waiting for cloud-init to finish first boot"
deadline=$(( $(date +%s) + 900 ))
ci="WAIT"
while (( $(date +%s) < deadline )); do
  ci="$(ssh_pve "qm guest exec ${DRILL_VM_ID} --timeout 30 -- bash -lc 'cloud-init status 2>/dev/null | grep -q done && echo READY || echo WAIT'" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data","").strip())' || echo WAIT)"
  [[ "$ci" == "READY" ]] && break
  sleep 15
done
[[ "$ci" == "READY" ]] || die "cloud-init never reached 'done'"
log "waiting for post-install reboot to settle (vs boot-1 baseline)"
# Reboot is confirmed the moment current uptime is BELOW the boot-1 baseline.
# If cloud-init 'done' only registered on boot 2, uptime is already lower —
# the very first reading satisfies the check. Either way this converges.
deadline=$(( $(date +%s) + 900 ))
rebooted="WAIT"
if [[ -n "$BOOT1_UPTIME" ]]; then
  while (( $(date +%s) < deadline )); do
    cur="$(ssh_pve "qm guest exec ${DRILL_VM_ID} --timeout 20 -- bash -lc 'cut -d. -f1 /proc/uptime'" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("out-data","").strip())
except Exception: print("")' || echo "")"
    if [[ "$cur" =~ ^[0-9]+$ && "$cur" -lt "$BOOT1_UPTIME" ]]; then
      rebooted="READY"
      break
    fi
    sleep 5
  done
else
  rebooted="READY"  # no baseline (agent blip); fall through to health check
fi
[[ "$rebooted" == "READY" ]] || die "post-install reboot not observed within 15m (uptime never regressed below baseline ${BOOT1_UPTIME})"
deadline=$(( $(date +%s) + 600 ))
healthy="WAIT"
while (( $(date +%s) < deadline )); do
  # DR-relevant health: datastore mounted + PBS manager usable. Do NOT use
  # 'systemctl is-system-running' — a fresh PBS boot can sit at 'degraded'
  # (any failed unit) forever, which is irrelevant to DR capability.
  healthy="$(ssh_pve "qm guest exec ${DRILL_VM_ID} --timeout 30 -- bash -lc 'if findmnt -n -o SOURCE /srv/proxmox-backup-primary >/dev/null 2>&1; then if command -v proxmox-backup-manager >/dev/null; then echo READY; exit 0; fi; fi; echo WAIT'" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("out-data","").strip())
except Exception: print("WAIT")' || echo WAIT)"
  [[ "$healthy" == "READY" ]] && break
  sleep 15
done
[[ "$healthy" == "READY" ]] || die "system did not come back healthy (datastore+manager) after reboot"
log "post-reboot settled — datastore mounted on a clean boot"

# ── Step 5: recover the datastore from the Synology mirror ONLY ──
# The drill VM has no route to the live PBS (.247 route is unnecessary; the
# curated mirror is the sole source). rsync pushes mirror -> drill datastore.
log "restoring curated mirror from Synology (via VM201) into drill datastore"
ssh_pve "set -e
# Synology lives under VM201's mount; use VM201 as the rsync pull source
qm guest exec ${DRILL_VM_ID} --timeout 3000 -- bash -lc 'echo datastore-ready' >/dev/null"
# Push from VM201 (which mounts Synology) to the drill VM over SSH using
# VM201's pve-backupsync identity (authorized on every PBS VM via the
# Git-declared cloud-init template).
PUSH_CMD="rsync -aH --info=progress2 -e 'ssh -i /home/moltbot/.ssh/pve-backupsync -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' ${SYN_ROOT}/datastore/ root@${DRILL_IP}:/srv/proxmox-backup-primary/datastore/"
ssh_pve "qm guest exec 201 --timeout 7200 -- bash -lc \"mountpoint -q /mnt/synology/proxmoxbackups && ${PUSH_CMD} && echo MIRROR-PUSH-OK\"" > /tmp/restore-drill/push.json 2>/dev/null
push_rc="$(python3 -c 'import json; print(json.load(open("/tmp/restore-drill/push.json")).get("exitcode", 1))')"
[[ "$push_rc" == "0" ]] || die "mirror push failed (rc=${push_rc}) — see /tmp/restore-drill/push.json"
log "mirror push OK ($(du -sh /tmp/restore-drill 2>/dev/null | awk '{print $1}' || echo '?') scratch)"

# ── Step 6: verify chunk-store integrity on the drill PBS ──
log "verifying restored datastore integrity (index -> chunk walk)"
INTEGRITY="$(ssh_pve "qm guest exec ${DRILL_VM_ID} --timeout 1200 -- bash -lc '
set -e
for group in host/pve-config vm/201 vm/300 vm/906; do
  latest=\"\"
  while IFS= read -r d; do [[ -f \"\$d/index.json.blob\" ]] \&\& latest=\"\$d\"; done < <(find /srv/proxmox-backup-primary/datastore/\$group -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
  [[ -n \"\$latest\" ]] || { echo \"FAIL no snapshot for \$group\"; exit 1; }
  for f in \"\$latest\"/*.fidx \"\$latest\"/*.didx; do
    [[ -e \"\$f\" ]] || continue
    n=\$(proxmox-backup-debug inspect file \"\$f\" | sed -n \"s/^  \\\"\\([0-9a-f]\\{64\\}\\)\\\"\\$/\\1/p\" | while read -r c; do
        p=/srv/proxmox-backup-primary/datastore/.chunks/\${c:0:4}/\$c
        [[ -s \"\$p\" ]] || echo missing
      done | wc -l)
    [[ \"\$n\" == \"0\" ]] || { echo \"FAIL \$group: \$n chunks missing\"; exit 1; }
  done
  echo \"OK \$group \$(basename \"\$latest\")\"
done
'" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data",""))')"
echo "$INTEGRITY"
echo "$INTEGRITY" | grep -q "OK host/pve-config" || die "host/pve-config group failed integrity walk"
echo "$INTEGRITY" | grep -q "OK vm/201"          || die "vm/201 group failed integrity walk"
log "chunk integrity verified for host/pve-config + vm/201 (all present groups listed above)"

# ── Step 7: restore host/pve-config into a real pxar archive ──
log "restoring host/pve-config latest snapshot to pxar (the actual DR proof)"
RESTORE_OUT="$(ssh_pve "qm guest exec ${DRILL_VM_ID} --timeout 1200 -- bash -lc '
latest=\"\$(find /srv/proxmox-backup-primary/datastore/host/pve-config -maxdepth 1 -mindepth 1 -type d | sort | while read -r d; do [[ -f \"\$d/index.json.blob\" ]] \&\& echo \"\$d\"; done | tail -1)
snapshot=\"host/pve-config/\$(basename \"\$latest\")\"
mkdir -p /root/drill-restore
proxmox-backup-client restore \"\${snapshot}\" root.pxar --repository /srv/proxmox-backup-primary/datastore --keyfile /etc/proxmox-backup/encryption-key.json 2>/dev/null \
  || proxmox-backup-client restore \"\${snapshot}\" root.pxar --repository /srv/proxmox-backup-primary/datastore 2>&1 | tail -3
test -s /root/drill-restore/root.pxar \&\& echo RESTORE-PXAR-OK \&\& proxmox-backup-client list-files \"\${snapshot}\" --repository /srv/proxmox-backup-primary/datastore 2>/dev/null | head -5
'" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("out-data","")); err=d.get("err-data","") or ""; err.strip() && print("[guest-stderr]", err[:400])')"
echo "$RESTORE_OUT"
echo "$RESTORE_OUT" | grep -q "RESTORE-PXAR-OK" || die "pxar restore did not produce an archive"

# ── Step 8: destroy the drill ──
if [[ "${1:-}" == "--keep" ]]; then
  log "KEEP mode: drill VM left running at ${DRILL_IP} — destroy with: qm stop ${DRILL_VM_ID} && qm destroy ${DRILL_VM_ID} --purge"
  exit 0
fi
log "destroying drill VM + snippet"
ssh_pve "qm stop ${DRILL_VM_ID} --timeout 30; qm destroy ${DRILL_VM_ID} --purge; rm -f '${SNIPPET_PATH}'"
ssh-keygen -R "$DRILL_IP" >/dev/null 2>&1 || true
rm -rf /tmp/restore-drill

log "PASS — DR endpoint proven: Synology mirror alone rebuilt a PBS datastore, chunks verified, and a real pxar restore succeeded"
