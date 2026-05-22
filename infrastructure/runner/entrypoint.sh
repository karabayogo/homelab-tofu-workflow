#!/bin/bash
# Entrypoint for the k8s-deployed actions-runner.
# Runs as PID 1 in the container. The official `actions/runner` image
# already has ./run.sh and ./config.sh — we just route through this
# entrypoint so we can fetch the ephemeral token using GH_TOKEN from
# the K8s Secret mounted by ESO.

set -e

GITHUB_ORG="${GITHUB_ORG:-karabayogo}"
GITHUB_REPO="${GITHUB_REPO:-homelab-tofu-workflow}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,LAN,k8s-workbench,moltbot}"
RUNNER_WORK="${RUNNER_WORK:-_work}"

RUNNER_DIR="$(pwd)"
export HOME="${RUNNER_DIR}"

# The K8s ServiceAccount token is automatically mounted at
# /var/run/secrets/kubernetes.io/serviceaccount if using a ServiceAccount.
# The GH_TOKEN PAT (for provisioning runner registration tokens) comes
# from the ESO-managed Secret runner-auth, which we mount at /secrets/runner.
GH_TOKEN_FILE="${GH_TOKEN_FILE:-/secrets/runner/GH_TOKEN}"

echo "[entrypoint] Waiting for GH_TOKEN at ${GH_TOKEN_FILE}..."
timeout=300
while [ ! -s "${GH_TOKEN_FILE}" ] && [ $timeout -gt 0 ]; do
  sleep 5
  timeout=$((timeout - 5))
done

if [ ! -s "${GH_TOKEN_FILE}" ]; then
  echo "[entrypoint] FATAL: GH_TOKEN not available after 5 minutes"
  exit 1
fi

GH_TOKEN="$(cat "${GH_TOKEN_FILE}")"
GITHUB_URL="https://github.com/${GITHUB_ORG}/${GITHUB_REPO}"

echo "[entrypoint] Fetching ephemeral runner registration token..."
REG_TOKEN=$(curl -s -X POST \
  -H "Authorization: token ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO}/actions/runners/registration-token" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

echo "[entrypoint] Registering runner at ${GITHUB_URL}..."
rm -f "${HOME}/.runner" "${HOME}/.env" 2>/dev/null || true

./config.sh \
  --name "homelab-tofu-runner-$(hostname)" \
  --url "${GITHUB_URL}" \
  --token "${REG_TOKEN}" \
  --labels "${RUNNER_LABELS}" \
  --work "${RUNNER_WORK}" \
  --unattended \
  --replace

echo "[entrypoint] Starting listener..."
exec ./run.sh
