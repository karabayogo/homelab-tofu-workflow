#!/bin/sh
# vm-provisioner.sh — writes a cloud-image to a Proxmox ZFS disk.
# Usage: vm-provisioner.sh <vm_id> <vm_name> <os_version> <image_family> <pve_host> <ssh_key_path> [start_after_provision]
#
# IDEMPOTENT: safe to run on running or stopped VMs. Stops VM if needed,
# writes the cloud-image to the OS disk (largest zvol, not EFI), and
# optionally starts the VM to run cloud-init.
set -eu

VMID="$1"
VM_NAME="$2"
OS_VERSION="$3"
IMAGE_FAMILY="$4"
PVE_HOST="$5"
SSH_KEY="$6"
START_AFTER_PROVISION="${7:-true}"

SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i ${SSH_KEY}"

case "${IMAGE_FAMILY}" in
  ubuntu)
    IMAGE_NAME="ubuntu-${OS_VERSION}-server-cloudimg-amd64.img"
    IMAGE_URL="https://cloud-images.ubuntu.com/releases/${OS_VERSION}/release/${IMAGE_NAME}"
    ;;
  debian)
    case "${OS_VERSION}" in
      12) DEBIAN_SUITE="bookworm" ;;
      13) DEBIAN_SUITE="trixie" ;;
      *)
        echo "[vm-gitops] Unsupported Debian version '${OS_VERSION}'." >&2
        exit 2
        ;;
    esac
    IMAGE_NAME="debian-${OS_VERSION}-genericcloud-amd64.qcow2"
    IMAGE_URL="https://cloud.debian.org/images/cloud/${DEBIAN_SUITE}/latest/${IMAGE_NAME}"
    ;;
  *)
    echo "[vm-gitops] Unsupported image family '${IMAGE_FAMILY}'." >&2
    exit 2
    ;;
esac

IMAGE_CACHE="/tmp/${IMAGE_NAME}"

echo "[vm-gitops] Provisioning VM ${VMID} (${VM_NAME}) with ${IMAGE_FAMILY} ${OS_VERSION} cloud-image..."

# Step 1: Download cloud-image on PVE host
${SSH_CMD} "root@${PVE_HOST}" "
  if [ ! -f '${IMAGE_CACHE}' ]; then
    echo '[vm-gitops] Downloading ${IMAGE_FAMILY} ${OS_VERSION} cloud-image (cache miss)...'
    curl -sL '${IMAGE_URL}' -o '${IMAGE_CACHE}'
    echo '[vm-gitops] Download complete: '\$(ls -lh ${IMAGE_CACHE} | awk '{print \$5}')''
  else
    echo '[vm-gitops] Cloud-image cached on PVE: '\$(ls -lh ${IMAGE_CACHE} | awk '{print \$5}')''
  fi
"

# Step 2: Stop VM if running (disk locked by QEMU when running)
VM_STATUS=$(${SSH_CMD} "root@${PVE_HOST}" "qm status ${VMID} 2>/dev/null" || echo "unknown")
echo "[vm-gitops] VM status before provision: ${VM_STATUS}"
case "${VM_STATUS}" in
  *running*)
    echo "[vm-gitops] Stopping VM ${VMID} to write disk..."
    ${SSH_CMD} "root@${PVE_HOST}" "qm stop ${VMID} --timeout 30 2>/dev/null || qm shutdown ${VMID} --timeout 30 2>/dev/null; sleep 5"
    ;;
  *)
    echo "[vm-gitops] VM already stopped or unknown — proceeding"
    ;;
esac

# Step 3: Find the OS disk (scsi0) via qm config
OS_DISK_NUM=$(${SSH_CMD} "root@${PVE_HOST}" "
  qm config ${VMID} 2>/dev/null | grep '^scsi0:' | grep -oP 'vm-${VMID}-disk-\K[0-9]+' | head -1
" 2>/dev/null || echo "")

if [ -z "${OS_DISK_NUM}" ]; then
  OS_DISK_NUM=$(${SSH_CMD} "root@${PVE_HOST}" "
    for z in /dev/zvol/rpool/data/vm-${VMID}-disk-*; do
      [ -e \"\$z\" ] || continue
      echo \"\$(blockdev --getsize64 \"\$z\" 2>/dev/null || echo 0) \$z\"
    done | sort -rn | grep -v cloudinit | head -1 | awk '{print \$2}' | grep -oP 'disk-\K[0-9]+'
  " 2>/dev/null || echo "")
fi

OS_DISK_DEV="/dev/zvol/rpool/data/vm-${VMID}-disk-${OS_DISK_NUM:-1}"
echo "[vm-gitops] OS disk: ${OS_DISK_DEV} (scsi0 disk number: ${OS_DISK_NUM:-1})"

# Step 4: Write cloud-image to OS disk
echo "[vm-gitops] Writing cloud-image to ${OS_DISK_DEV}..."
${SSH_CMD} "root@${PVE_HOST}" "
  qemu-img convert -O raw '${IMAGE_CACHE}' '${OS_DISK_DEV}' && echo '[vm-gitops] Disk write OK'
  qemu-img resize -f raw '${OS_DISK_DEV}' +\$(qm config ${VMID} 2>/dev/null | grep '^scsi0:' | grep -oP 'size=\K[0-9]+[GTgt]' | head -1 || echo '32G') 2>/dev/null || true
"

# Step 5: Start VM for cloud-init
case "${START_AFTER_PROVISION}" in
  true)
    echo "[vm-gitops] Starting VM ${VMID} for cloud-init..."
    ${SSH_CMD} "root@${PVE_HOST}" "qm start ${VMID} 2>/dev/null || echo '[vm-gitops] VM already started'"
    echo "[vm-gitops] VM ${VMID} provisioned. Cloud-init will handle k3s join on first boot."
    ;;
  false)
    echo "[vm-gitops] VM ${VMID} provisioned and left stopped (start_after_provision=false)."
    ;;
  *)
    echo "[vm-gitops] Invalid start_after_provision='${START_AFTER_PROVISION}' (expected true|false)." >&2
    exit 2
    ;;
esac
