#!/usr/bin/env bash
set -euo pipefail

VM_USER="${OPENCLAW_VM_USER:-kai}"
VM_HOST="${OPENCLAW_VM_HOST:-192.168.1.252}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/openclaw_vm_key}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i $SSH_KEY_PATH"

echo "Running runtime contract checks against ${VM_USER}@${VM_HOST}"

ssh $SSH_OPTS "${VM_USER}@${VM_HOST}" 'set -euo pipefail
export PATH="$HOME/.local/share/fnm:$PATH"

command -v fnm >/dev/null
eval "$(fnm env)"
fnm use 24 >/dev/null
node -v | awk '"'"'index($0,"v24.")==1{ok=1} END{exit ok?0:1}'"'"'

command -v openclaw >/dev/null
command -v docker >/dev/null

systemctl --user is-active openclaw-gateway.service | awk '"'"'$1=="active"{ok=1} END{exit ok?0:1}'"'"'
systemctl --user is-active openclaw-gitops-reconcile.timer | awk '"'"'$1=="active"{ok=1} END{exit ok?0:1}'"'"'
loginctl show-user "$USER" -p Linger | awk -F= '"'"'$2=="yes"{ok=1} END{exit ok?0:1}'"'"'

test -f ~/.openclaw/openclaw.json
test -f ~/.openclaw/secrets.json
test -f ~/.openclaw/secrets.json.enc
python3 -c "import json; json.load(open(\"$HOME/.openclaw/openclaw.json\")); json.load(open(\"$HOME/.openclaw/secrets.json\"))"

mountpoint -q /data
curl -sf http://127.0.0.1:11434/api/tags >/dev/null
sudo docker ps --format "{{.Names}}" | awk '"'"'index($0,"ollama")==1{ok=1} END{exit ok?0:1}'"'"'
curl -sf http://127.0.0.1:18789/ >/dev/null
'

echo "Runtime contract checks passed."
