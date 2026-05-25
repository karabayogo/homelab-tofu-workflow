#!/usr/bin/env bash
set -euo pipefail

VM_USER="${OPENCLAW_VM_USER:-henesink}"
VM_HOST="${OPENCLAW_VM_HOST:-192.168.1.252}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/openclaw_vm_key}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i $SSH_KEY_PATH"

echo "Running runtime contract checks against ${VM_USER}@${VM_HOST}"

# Basic connectivity and user environment check
ssh $SSH_OPTS "${VM_USER}@${VM_HOST}" 'set -euo pipefail
echo "SSH connection OK"
id
pwd
ls /data/ 2>/dev/null || true
'

echo "Runtime contract checks passed."
