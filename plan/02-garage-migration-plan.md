# Garage S3 Migration Plan — Phase 1 (IaC) + Phase 2 (Migration)

**Goal:** Replace the single-node Garage S3 on VM 900 (docker-compose) with a three-node Garage v2.2.0 cluster (VMs 901/902/903) managed by OpenTofu + GitOps cattle. Migrate existing S3 data without downtime.

---

## Executive Summary

```
OLD (docker-compose, VM 900)          NEW (tofu-managed, VMs 901/902/903)
─────────────────────────────         ─────────────────────────────────────
192.168.1.230:3900                    192.168.1.241:3900 (n1)
Single-node, RF=none                  3-node cluster, RF=3
docker-compose on Ubuntu VM           OpenTofu VM module + cloud-init
Secrets on disk (.env)                Vault AppRole → cloud-init injects secrets
No GitOps                             Full GitOps: tofu plan → PR → apply
No backup                             Longhorn-backed disk snapshots
```

**Key design decisions (grill-agreed):**
1. Three Garage v2.2.0 nodes (901/902/903) managed by OpenTofu
2. Vault AppRole for secret injection — real secrets never in Terraform state or cloud-init metadata
3. Sequential boot: `systemctl enable garage` only (no start), `systemctl start garage` runs after `garage cluster init` via SSH
4. Migration helper VM 904: rclone sync from old cluster to new cluster, destroyed after Phase 2
5. **GitHub App + Vault k8s auth for runner OIDC** — no PAT anywhere, runner is proper GitOps cattle

---

## Phase 0 — GitHub App + Vault OIDC Setup (new infrastructure)

### Why OIDC

The self-hosted runner currently uses a PAT stored in Vault and refreshed via ESO. This is a pet credential — it expires, requires rotation, and is not self-healing.

**GitHub OIDC + GitHub App pattern:**
- Runner k8s SA → Vault k8s auth method → short-lived Vault token
- Runner uses Vault-stored GitHub App private key → signs JWT → calls GitHub API
- GitHub issues ephemeral runner registration tokens (valid 1hr, auto-renewed at runner startup)
- No PATs. No expiration management. Runner is cattle.

### 0.1 — Create GitHub App (one-time, GitHub web UI)

**Repository or Organization:** Organization `karabayogo`

1. Go to: https://github.com/organizations/karabayogo/settings/apps
2. Click **New GitHub App**
3. Fill in:
   - **Name:** `homelab-tofu-runner` (must be unique across GitHub)
   - **Homepage URL:** `https://github.com/karabayogo/homelab-tofu-workflow`
   - **Repository access:** Only `homelab-tofu-workflow`
   - **Permissions:**
     - `Administration` (read and write) — needed to create runner registration tokens
   - **Where can this GitHub App be installed?** — "Only on this account"
4. Click **Create GitHub App**
5. Note the **App ID** (shown on the app page)
6. Click **Generate a private key** (bottom of app page) → downloads `homelab-tofu-runner.private-key.pem`

**Why a GitHub App (not OAuth or PAT)?**
- GitHub App JWT is scoped to this app + this repo only
- JWT lifetime: 1 hour, auto-generated at runner startup using the private key
- Can be revoked instantly from GitHub web UI
- Industry standard for workload identity (like GCP WIF, AWS IRSA)

### 0.2 — Store GitHub App credentials in Vault

On any machine with Vault CLI + network access to Vault:

```bash
# Encode private key as single-line JSON for Vault
PRIVATE_KEY=$(cat /path/to/homelab-tofu-runner.private-key.pem)
GITHUB_APP_ID="<App ID from step 0.1>"

vault kv put secret/data/github-app/homelab-tofu-runner \
  app_id="${GITHUB_APP_ID}" \
  private_key="${PRIVATE_KEY}"
```

Verify:
```bash
vault kv get secret/data/github-app/homelab-tofu-runner
```

### 0.3 — Enable Vault Kubernetes auth method

**On the Vault server (k8s-master1, SSH required):**

```bash
vault auth enable kubernetes
```

### 0.4 — Configure Vault k8s auth method

```bash
# Get the k8s API endpoint from inside the cluster
vault write auth/kubernetes/config \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_host="https://kubernetes.default.svc" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
```

### 0.5 — Create Vault policy for runner

```bash
# Policy: runner can read its own GitHub App credentials
vault policy write homelab-tofu-runner - <<'EOF'
path "secret/data/github-app/homelab-tofu-runner" {
  capabilities = ["read"]
}
EOF
```

### 0.6 — Create Vault k8s auth role for runner

```bash
# Binds the runner's k8s ServiceAccount to the policy above
vault write auth/kubernetes/role/homelab-tofu-runner \
  bound_service_account_names=actions-runner \
  bound_service_account_namespaces=actions-runner \
  policies=homelab-tofu-runner \
  ttl=1h
```

**Validation:**
```bash
vault read auth/kubernetes/role/homelab-tofu-runner
```

### 0.7 — Update ESO ClusterSecretStore to sync GitHub App secret

Add to the existing ESO ClusterSecretStore (in `argocd/eso/cluster-secret-store.yaml`):

```yaml
# Add this secret store — reads from the same Vault path ESO already uses
# This ClusterSecretStore uses the vault-server's ServiceAccount ( ESO's default)
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-github-app
spec:
  vault:
    server: "https://vault.vault.svc.cluster.local:8200"
    path: secret
    version: latest
    auth:
      kubernetes:
        mountPath: kubernetes
        # The ESO ServiceAccount is bound to vault-server's SA — check eso namespace
        # If ESO runs in 'external-secrets' namespace:
        serviceAccountRef:
          name: external-secrets
          namespace: external-secrets
```

**Note:** ESO may already have access to the `secret/` path. Verify with:
```bash
kubectl get clustersecretstore
# If 'vault-backend' exists and works, it likely already covers 'secret/' path
```

### 0.8 — Create ESO ExternalSecret for runner-auth (updated)

Replace the current `runner-auth` ExternalSecret (which fetches a PAT) with:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: runner-auth
  namespace: actions-runner
spec:
  refreshInterval: 1h   # Refresh every hour — GitHub App JWT is valid for 1hr
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-github-app
  target:
    name: runner-auth
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: GH_APP_PRIVATE_KEY_PEM
      remoteRef:
        key: secret/data/github-app/homelab-tofu-runner
        property: private_key
    - secretKey: GH_APP_ID
      remoteRef:
        key: secret/data/github-app/homelab-tofu-runner
        property: app_id
```

**Key difference from the current PAT-based ExternalSecret:**
- No PAT stored in Vault. Instead, Vault stores the GitHub App private key.
- ESO syncs the private key to the runner pod at `/secrets/runner/GH_APP_PRIVATE_KEY_PEM`
- The runner entrypoint script (updated in step 0.9) reads the private key, generates a JWT, calls GitHub API to get the ephemeral registration token

### 0.9 — Update runner entrypoint to use GitHub App JWT

Update `infrastructure/runner/entrypoint.sh` to replace PAT-based token fetch:

```bash
#!/bin/bash
# Updated: uses GitHub App JWT instead of PAT
# 1. Authenticate to Vault using k8s SA token
# 2. Fetch GitHub App private key from Vault
# 3. Generate signed JWT using app_id + private_key
# 4. Exchange JWT for GitHub App installation access token
# 5. Use installation token to fetch runner registration token

set -e

GITHUB_ORG="${GITHUB_ORG:-karabayogo}"
GITHUB_REPO="${GITHUB_REPO:-homelab-tofu-workflow}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,LAN,k8s-workbench,moltbot}"
RUNNER_WORK="${RUNNER_WORK:-_work}"

RUNNER_DIR="$(pwd)"
export HOME="${RUNNER_DIR}"

VAULT_ADDR="${VAULT_ADDR:-https://vault.vault.svc.cluster.local:8200}"
SECRET_PATH="secret/data/github-app/homelab-tofu-runner"
VAULT_K8S_MOUNT="kubernetes"

echo "[entrypoint] Authenticating to Vault via k8s SA..."
VAULT_TOKEN=$(vault write -f auth/${VAULT_K8S_MOUNT}/login -format=json | jq -r '.auth.client_token')

echo "[entrypoint] Fetching GitHub App credentials from Vault..."
GH_APP_ID=$(vault kv get -field=app_id "${SECRET_PATH}" --token="${VAULT_TOKEN}")
GH_APP_PRIVATE_KEY=$(vault kv get -field=private_key "${SECRET_PATH}" --token="${VAULT_TOKEN}")

echo "[entrypoint] Generating GitHub App JWT..."
# The JWT header and payload are base64url-encoded JSON
# We use python3 for reliable JWT generation (pyjwt or manually constructed)
GH_APP_JWT=$(python3 -c "
import json, time, base64, hmac, hashlib

# GitHub App JWT must include iat (issued at) and exp (expiry, max 10 min)
now = int(time.time())
header = {'alg': 'RS256', 'typ': 'JWT'}
payload = {
    'iat': now,
    'exp': now + 600,  # 10 minutes max for GitHub App JWT
    'iss': '${GH_APP_ID}'
}

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

header_b64 = b64url(json.dumps(header).encode())
payload_b64 = b64url(json.dumps(payload).encode())
message = f'{header_b64}.{payload_b64}'

# Sign with RS256 using the private key
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend
private_key = serialization.load_pem_private_key(
    '''${GH_APP_PRIVATE_KEY}'''.encode(), password=None, backend=default_backend()
)
signature = private_key.sign(message.encode(), algorithm=hashlib.sha256)
sig_b64 = b64url(signature)
print(f'{message}.{sig_b64}')
")

echo "[entrypoint] Fetching GitHub App installation ID..."
INSTALLATION_ID=$(curl -sS \
  -H "Authorization: Bearer ${GH_APP_JWT}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO}/installation" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

echo "[entrypoint] Fetching installation access token..."
ACCESS_TOKEN=$(curl -sS -X POST \
  -H "Authorization: Bearer ${GH_APP_JWT}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

echo "[entrypoint] Fetching ephemeral runner registration token..."
REG_TOKEN=$(curl -sS -X POST \
  -H "Authorization: token ${ACCESS_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO}/actions/runners/registration-token" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

echo "[entrypoint] Registering runner..."
rm -f "${HOME}/.runner" "${HOME}/.env" 2>/dev/null || true

./config.sh \
  --name "homelab-tofu-runner-$(hostname)" \
  --url "https://github.com/${GITHUB_ORG}/${GITHUB_REPO}" \
  --token "${REG_TOKEN}" \
  --labels "${RUNNER_LABELS}" \
  --work "${RUNNER_WORK}" \
  --unattended \
  --replace

echo "[entrypoint] Starting listener..."
exec ./run.sh
```

**Also update the Dockerfile to include the `cryptography` Python package:**
```dockerfile
# Add to existing Dockerfile before ENTRYPOINT/CMD
RUN pip install --no-cache-dir cryptography
```

### 0.10 — Create ESO ExternalSecret for GitHub App private key

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: github-app-credentials
  namespace: actions-runner
spec:
  refreshInterval: 24h   # App private key doesn't expire unless revoked
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-github-app
  target:
    name: github-app-credentials
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: GH_APP_ID
      remoteRef:
        key: secret/data/github-app/homelab-tofu-runner
        property: app_id
    - secretKey: GH_APP_PRIVATE_KEY
      remoteRef:
        key: secret/data/github-app/homelab-tofu-runner
        property: private_key
```

---

## Phase 1 — Tofu Infrastructure Setup

### 1.1 — Create tofu garage-node module

**File:** `infrastructure/terraform/modules/garage-node/main.tf`
**Purpose:** Encapsulates all garage-specific VM logic — identical to `modules/vm` but with `cloud_init_template = "garage"` and `k3s_enabled = false`.

> **Note:** The plan was to create a dedicated `modules/garage-node/main.tf` as a thin wrapper around `modules/vm`. However, after reviewing the existing `modules/vm` module, it already supports all required parameters via conditional logic in `main.tf` and `cloudinit.tf`. The garage nodes can use `modules/vm` directly with `cloud_init_template = "garage"`, `k3s_enabled = false`, and garage-specific variables (version, rpc_secret, admin_token, vault_approle credentials). No new module needed.

### 1.2 — Add Vault AppRole variables to Terraform

**File:** `infrastructure/terraform/variables.tf`

Add two new variable declarations:

```hcl
variable "vault_approle_role_id" {
  description = "Vault AppRole Role ID for garage-node secret fetching"
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.vault_approle_role_id) > 0
    error_message = "vault_approle_role_id must not be empty."
  }
}

variable "vault_approle_secret_id" {
  description = "Vault AppRole Secret ID for garage-node secret fetching"
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.vault_approle_secret_id) > 0
    error_message = "vault_approle_secret_id must not be empty."
  }
}
```

Add to `terraform.tfvars`:
```hcl
vault_approle_role_id   = "<role_id from vault>"
vault_approle_secret_id  = "<secret_id from vault>"
```

**To generate AppRole credentials:**
```bash
# On Vault server or any machine with Vault CLI + network access
vault write auth/approle/role/garage-node \
  secret_id_ttl=8760h \
  token_ttl=1h \
  policies=garage-cluster

# Get role_id
vault read auth/approle/role/garage-node/role-id

# Generate secret_id (one-time — save it, it's only shown once)
vault write -f auth/approle/role/garage-node/secret-id
```

**Vault policy for garage-node AppRole:**
```bash
vault policy write garage-cluster - <<'EOF'
path "secret/data/garage/cluster" {
  capabilities = ["read"]
}
EOF
```

### 1.3 — Add garage node modules to main.tf

Three module calls for VMs 901, 902, 903. Each uses the `modules/vm` module with `cloud_init_template = "garage"`.

**File:** `infrastructure/terraform/main.tf`

```hcl
# ── Garage S3 Storage Nodes (901/902/903) ──
# Three-node Garage v2.2.0 cluster with RF=3.
# All nodes use cloud_init_template = "garage" (dedicated Garage cloud-init, not base/worker/master).
# Real secrets never appear here — rpc_secret and admin_token are PLACEHOLDER values that get
# replaced at first boot via Vault AppRole fetch (see cloud-init-garage.yaml.tftpl).
# AppRole credentials (role_id + secret_id) are passed as variables — not the secrets themselves.
#
# IMPORTANT: These three modules MUST be applied together (tofu apply, not targeted apply)
# because Garage cluster bootstrap requires all three nodes to be present.
# Apply with: tofu apply -auto-approve  (all modules)
#
# Provisioning order for cluster init (n1 first, then n2+n3):
#   1. tofu apply → VMs 901/902/903 created, cloud-init runs on all three
#   2. SSH to 192.168.1.241: garage-fetch-secrets.sh replaces PLACEHOLDER values
#   3. SSH to 192.168.1.241: garage cluster init (n1 is the initiator)
#   4. SSH to 192.168.1.242: garage node accept (from n1, to accept n2)
#   5. SSH to 192.168.1.243: garage node accept (from n1, to accept n3)
# Full step-by-step in: 01-phase1-bootstrap.md

module "garage_n1" {
  source = "./modules/vm"

  vm_id             = 901
  vm_name           = "garage-n1"
  memory_mb         = 2048
  cpu_cores         = 2
  cpu_units         = 1024
  os_disk_size_gb   = 64
  data_disk_size_gb = 200
  vm_storage        = "local-zfs"
  data_storage      = "bulkpool"
  bridge            = "vmbr0"
  vm_os_type        = "l26"
  vm_bios           = "ovmf"
  vm_machine        = "q35"
  tags              = ["garage-s3", "garage-node"]
  os_version        = "24.04"
  boot_order        = ["scsi0"]
  static_ip         = "192.168.1.241"
  vm_started        = false   # Start false for first provision; cloud-init sets hostname + disk

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user  = "ubuntu"
  ssh_pub_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"

  # Standalone — no k3s, use garage cloud-init template
  k3s_enabled         = false
  cloud_init_template = "garage"

  # Garage version (must match across all three nodes)
  garage_version = "v2.2.0"

  # PLACEHOLDER values — replaced at boot via Vault AppRole (see cloud-init-garage.yaml.tftpl)
  # These placeholder strings are safe to commit to repo.
  # Real secrets are NEVER in Terraform state or cloud-init metadata.
  rpc_secret   = "PLACEHOLDER_RPC_SECRET"
  admin_token  = "PLACEHOLDER_ADMIN_TOKEN"

  # Vault AppRole — used by cloud-init to authenticate and fetch real secrets from Vault
  vault_addr              = "https://vault.ariesmcrae.com"
  vault_approle_role_id   = var.vault_approle_role_id
  vault_approle_secret_id = var.vault_approle_secret_id

  protect_vm = true
}

module "garage_n2" {
  source = "./modules/vm"

  vm_id             = 902
  vm_name           = "garage-n2"
  memory_mb         = 2048
  cpu_cores         = 2
  cpu_units         = 1024
  os_disk_size_gb   = 64
  data_disk_size_gb = 200
  vm_storage        = "local-zfs"
  data_storage      = "bulkpool"
  bridge            = "vmbr0"
  vm_os_type        = "l26"
  vm_bios           = "ovmf"
  vm_machine        = "q35"
  tags              = ["garage-s3", "garage-node"]
  os_version        = "24.04"
  boot_order        = ["scsi0"]
  static_ip         = "192.168.1.242"
  vm_started        = false

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user  = "ubuntu"
  ssh_pub_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"

  k3s_enabled         = false
  cloud_init_template = "garage"

  garage_version = "v2.2.0"
  rpc_secret     = "PLACEHOLDER_RPC_SECRET"
  admin_token    = "PLACEHOLDER_ADMIN_TOKEN"

  vault_addr              = "https://vault.ariesmcrae.com"
  vault_approle_role_id   = var.vault_approle_role_id
  vault_approle_secret_id = var.vault_approle_secret_id

  protect_vm = true
}

module "garage_n3" {
  source = "./modules/vm"

  vm_id             = 903
  vm_name           = "garage-n3"
  memory_mb         = 2048
  cpu_cores         = 2
  cpu_units         = 1024
  os_disk_size_gb   = 64
  data_disk_size_gb = 200
  vm_storage        = "local-zfs"
  data_storage      = "bulkpool"
  bridge            = "vmbr0"
  vm_os_type        = "l26"
  vm_bios           = "ovmf"
  vm_machine        = "q35"
  tags              = ["garage-s3", "garage-node"]
  os_version        = "24.04"
  boot_order        = ["scsi0"]
  static_ip         = "192.168.1.243"
  vm_started        = false

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user  = "ubuntu"
  ssh_pub_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"

  k3s_enabled         = false
  cloud_init_template = "garage"

  garage_version = "v2.2.0"
  rpc_secret     = "PLACEHOLDER_RPC_SECRET"
  admin_token    = "PLACEHOLDER_ADMIN_TOKEN"

  vault_addr              = "https://vault.ariesmcrae.com"
  vault_approle_role_id   = var.vault_approle_role_id
  vault_approle_secret_id = var.vault_approle_secret_id

  protect_vm = true
}
```

### 1.4 — Create garage cloud-init template

**File:** `infrastructure/terraform/modules/vm/templates/cloud-init-garage.yaml.tftpl`

This template handles:
1. Ubuntu 24.04 setup (netplan, SWAP, NTP)
2. QEMU guest agent
3. Unattended upgrades
4. Garage v2.2.0 binary installation from GitHub releases
5. **Vault AppRole** fetch at boot: `rpc_secret` + `admin_token` fetched from Vault using AppRole credentials, replacing PLACEHOLDER values in `/etc/garage.toml`
6. Data disk partition + filesystem (ext4, no RAID — Garage handles replication)
7. Garage systemd service: `enable` only, **NO start** (see bootstrap sequence)
8. rclone installation (for Phase 2 migration)

```yaml
#cloud-config
# Garage S3 Node — cloud-init template
# Variables: ${vm_name}, ${static_ip}, ${gateway}, ${dns_nameservers}, ${admin_token},
#            ${rpc_secret}, ${data_disk}, ${garage_version}, ${vault_addr},
#            ${vault_approle_role_id}, ${vault_approle_secret_id}

# ── 1. Hostname + network ───────────────────────────────────────────────
hostname: ${vm_name}
manage_etc_hosts: true
write_files:
  - path: /etc/netplan/50-cloud-init.yaml
    content: |
      network:
        version: 2
        ethernets:
          ens18:
            addresses: [${static_ip}/24]
            gateway4: ${gateway}
            nameservers:
              addresses: [${dns_nameservers}]
            dhcp4: false

# ── 2. Bootstrapping: disable cloud-init on subsequent boots ────────────
# Ensures cloud-init runs fully on first boot only (no re-configuration on reboot)
bootcmd:
  - [systemctl, disable, --now, cloud-init]
  - [systemctl, mask, cloud-init]
  - [sed, -i, 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/', /etc/ssh/sshd_config]
  - [systemctl, restart, sshd]

# ── 3. System packages ────────────────────────────────────────────────────
package_update: true
packages:
  - curl
  - htop
  - iotop
  - smartmontools
  - systemd-timesyncd
  - unattended-upgrades
  - ubuntu-server
  - qemu-guest-agent
  - rclone

# ── 4. SWAP ──────────────────────────────────────────────────────────────
disk_setup:
  /dev/vdb:
    table_type: gpt
    layout:
      - [100, 82]   # 100MB swap, type 82 (Linux swap)
    overwrite: false

fs_setup:
  - label: none
    device: /dev/vdb1
    filesystem: swap
    overwrite: false

mounts:
  - [none, swap, none, sw, "0", "0"]

# ── 5. Time synchronization ──────────────────────────────────────────────
timezone: Australia/Melbourne
ntp:
  enabled: true
  servers:
    - 0.au.pool.ntp.org
    - 1.au.pool.ntp.org

# ── 6. Unattended upgrades ───────────────────────────────────────────────
unattended_upgrades:
  release: lts
  upgrade: true
  reboot: false
  auto_upgrade: true
  blacklist: []
  unattended_upgrades:
    remove_unused_kernel_packages: true
    remove_unused_dependencies: true
    only_on_battery_updates: false
    update_days_of_week: ["0"]

# ── 7. Garage install ────────────────────────────────────────────────────
write_files:
  # garage-install.sh — downloads and installs Garage binary
  - path: /opt/garage-install.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      set -e
      VERSION="${garage_version}"
      DEST="/usr/local/bin/garage"
      curl -fsSL "https://github.com/BenjaminCoe/garage/releases/download/v${VERSION}/garage-v${VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
        -o /tmp/garage.tar.gz
      tar -xzf /tmp/garage.tar.gz -C /tmp
      mv /tmp/garage "${DEST}"
      chmod +x "${DEST}"
      rm -f /tmp/garage.tar.gz /tmp/garage
      garage version

  # garage-fetch-secrets.sh — fetches real secrets from Vault via AppRole
  - path: /opt/garage-fetch-secrets.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      # Fetches rpc_secret and admin_token from Vault using AppRole credentials.
      # Runs at first boot after cloud-init completes.
      # REQUIRES: curl, jq, vault CLI (installed separately or via binary download)
      set -e

      VAULT_ADDR="${vault_addr}"
      ROLE_ID="${vault_approle_role_id}"
      SECRET_ID="${vault_approle_secret_id}"
      SECRET_PATH="secret/data/garage/cluster"

      echo "[garage-fetch-secrets] Authenticating to Vault at ${VAULT_ADDR}..."
      VAULT_TOKEN=$(curl -sS \
        -X POST \
        -d "role_id=${ROLE_ID}&secret_id=${SECRET_ID}" \
        "${VAULT_ADDR}/v1/auth/approle/login" \
        | jq -r '.auth.client_token')

      if [ -z "${VAULT_TOKEN}" ] || [ "${VAULT_TOKEN}" = "null" ]; then
        echo "[garage-fetch-secrets] FATAL: Vault authentication failed"
        exit 1
      fi

      echo "[garage-fetch-secrets] Fetching garage/cluster secrets..."
      SECRETS=$(curl -sS \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        "${VAULT_ADDR}/v1/${SECRET_PATH}" \
        | jq -r '.data.data')

      RPC_SECRET=$(echo "${SECRETS}" | jq -r '.rpc_secret // empty')
      ADMIN_TOKEN=$(echo "${SECRETS}" | jq -r '.admin_token // empty')

      if [ -z "${RPC_SECRET}" ] || [ -z "${ADMIN_TOKEN}" ]; then
        echo "[garage-fetch-secrets] FATAL: Could not retrieve rpc_secret or admin_token"
        exit 1
      fi

      echo "[garage-fetch-secrets] Writing secrets to /etc/garage.env..."
      cat > /etc/garage.env <<EOF
      GARAGE_RPC_SECRET=${RPC_SECRET}
      GARAGE_ADMIN_TOKEN=${ADMIN_TOKEN}
EOF
      chmod 600 /etc/garage.env
      echo "[garage-fetch-secrets] Done."

runcmd:
  # ── 7. Install or update Garage binary ───────────────────────────────────
  - [bash, -c, "bash /opt/garage-install.sh"]

  # ── 8. Enable Garage service (DO NOT START — daemon starts after cluster bootstrap) ──
  # Starting the daemon BEFORE `garage cluster init` and `garage node accept` is UNSUPPORTED.
  # The sequential bootstrap (Step 1.5 in 01-phase1-bootstrap.md) SSH's to each node
  # and runs `systemctl start garage` AFTER cluster init and node accept commands.
  - [systemctl, daemon-reload]
  - [systemctl, enable, garage]
  # ← NO systemctl start garage here. See 01-phase1-bootstrap.md Step 1.5.

  # ── 9. QEMU guest agent ──────────────────────────────────────────────────
  - [systemctl, enable, qemu-guest-agent]

  # ── 10. Run garage-fetch-secrets.sh (replaces PLACEHOLDER in garage.toml) ──
  # cloud-init-garage.yaml.tftpl uses write_files for both scripts, but the
  # PlaceholderReplacement in garage.toml happens in two stages:
  #   Stage 1 (cloud-init): Write garage.toml with PLACEHOLDER values
  #   Stage 2 (first boot): garage-fetch-secrets.sh fetches real values from Vault
  #   Stage 3 (before garage start): sed replaces PLACEHOLDER in garage.toml
  - [bash, -c, "/opt/garage-fetch-secrets.sh || echo '[cloud-init] garage-fetch-secrets failed (will retry on boot)'"]

  # ── 11. Replace PLACEHOLDER in /etc/garage.toml ──────────────────────────
  - [bash, -c, "sed -i 's/PLACEHOLDER_RPC_SECRET/${GARAGE_RPC_SECRET}/g; s/PLACEHOLDER_ADMIN_TOKEN/${GARAGE_ADMIN_TOKEN}/g' /etc/garage.toml 2>/dev/null || true"]

# ── 12. Data disk setup (partition, filesystem, mount) ──────────────────
# Note: The disk_setup/filesystem sections above handle partition + fs creation.
# This runcmd ensures the data directory exists and is mounted.
bootcmd:
  - [
      bash, -c,
      "parted -s /dev/vdb mklabel gpt && \
       parted -s /dev/vdb mkpart primary ext4 0% 100% && \
       mkfs.ext4 -F /dev/vdb1 && \
       mkdir -p /mnt/garage-data && \
       echo '/dev/vdb1 /mnt/garage-data ext4 defaults 0 2' >> /etc/fstab && \
       mount /mnt/garage-data"
    ]

# ── 13. Garage configuration file ─────────────────────────────────────────
# This file is written by the VM module's templatefile() call in cloudinit.tf
# It MUST contain PLACEHOLDER values that are replaced at first boot.
# DO NOT put real secrets here. DO NOT start garage in this template.
```

### 1.5 — Update terraform.tfvars

```hcl
# Garage AppRole credentials (for secret injection at boot)
vault_approle_role_id   = "<role_id from vault>"      # e.g., "auth/approle/role/garage-node/role-id"
vault_approle_secret_id = "<secret_id from vault>"    # Generated once, shown only once

# Existing variables (must be present)
garage_access_key = "<old cluster access key>"
garage_secret_key = "<old cluster secret key>"
k3s_token         = "<k3s cluster join token>"
```

---

## Phase 2 — Vault Setup

### 2.1 — Seed garage/cluster secret in Vault

```bash
# Connect to k8s cluster and port-forward to Vault
kubectl exec -n vault vault-0 -- vault login -
# Paste root token when prompted

# Seed the cluster secrets
kubectl exec -n vault vault-0 -- vault kv put secret/data/garage/cluster \
  rpc_secret="$(openssl rand -hex 32)" \
  admin_token="$(openssl rand -hex 32)"

# Verify
kubectl exec -n vault vault-0 -- vault kv get secret/data/garage/cluster
```

### 2.2 — Verify Vault AppRole is working

On a machine with Vault CLI and network access:

```bash
# Authenticate with AppRole
vault write auth/approle/login \
  role_id="<role_id>" \
  secret_id="<secret_id>"

# Should return: bond with garage-cluster policy
```

---

## Phase 3 — Sequential Bootstrap (01-phase1-bootstrap.md)

### Step 3.1 — tofu apply (creates VMs 901/902/903 + 904)

```bash
cd ~/repositories/homelab-tofu-workflow/infrastructure/terraform

# Verify tofu plan first (no changes to existing VMs)
tofu plan -var="vault_approle_role_id=${ROLE_ID}" \
         -var="vault_approle_secret_id=${SECRET_ID}"

# Apply — creates all garage VMs + migration helper
tofu apply -auto-approve \
  -var="vault_approle_role_id=${ROLE_ID}" \
  -var="vault_approle_secret_id=${SECRET_ID}"
```

**Expected output:**
- `module.garage_n1` — VM 901 created
- `module.garage_n2` — VM 902 created
- `module.garage_n3` — VM 903 created
- `module.migration_helper` — VM 904 created

### Step 3.2 — Wait for cloud-init to complete on all nodes

```bash
# Check cloud-init status via QEMU guest agent
for ip in 192.168.1.241 192.168.1.242 192.168.1.243 192.168.1.244; do
  echo "=== Checking cloud-init on ${ip} ==="
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@${ip} \
    "cloud-init status --wait 2>/dev/null || sudo cloud-init status --wait 2>/dev/null || echo 'cloud-init may still be running'"
done
```

### Step 3.3 — Sequential Garage bootstrap (n1 first, then n2+n3)

**On each node, SSH as ubuntu and run the commands:**

**Node 1 (192.168.1.241):**
```bash
ssh ubuntu@192.168.1.241

# Verify secrets were fetched
cat /etc/garage.env
# Should show: GARAGE_RPC_SECRET=<real hex string>, GARAGE_ADMIN_TOKEN=<real hex string>

# Start garage on n1
sudo systemctl start garage
sudo systemctl status garage --no-pager

# Initialize cluster (n1 is the initiator)
garage node status
garage cluster init --tls-cert-organisation=garage

# Add n2 and n3 to the cluster
garage node accept --token <token from n2 startup log>
garage node accept --token <token from n3 startup log>

# Verify
garage node status
```

**Node 2 (192.168.1.242):**
```bash
ssh ubuntu@192.168.1.242

# Verify secrets
cat /etc/garage.env

# Start garage
sudo systemctl start garage
sudo systemctl status garage --no-pager

# The token for n2 will be shown in n1's `garage node status` output
# Run on n1: garage node accept --token <token>
# Then verify on n2:
garage node status
```

**Node 3 (192.168.1.243):**
```bash
ssh ubuntu@192.168.1.243

# Verify secrets
cat /etc/garage.env

# Start garage
sudo systemctl start garage
sudo systemctl status garage --no-pager

# Run on n1: garage node accept --token <token>
# Then verify on n3:
garage node status
```

### Step 3.4 — Create S3 API keys for data migration

```bash
# Run on n1 (192.168.1.241)
ssh ubuntu@192.168.1.241

# Create a key for migration
garage key create migration-key

# Issue S3 credentials for the migration helper
# NOTE: These credentials are NOT written to Vault.
# The migration helper (VM 904) fetches S3 keys directly from the new cluster's
# Management API using admin_token from /etc/garage.env (grill-agreed Option B).
garage key issue migration-key

# Capture the access key and secret key from output
# The helper will call this same API to get credentials at migration time.
```

### Step 3.5 — Write tofu state to new Garage S3

The old cluster (VM 900) already has tofu state. After the new cluster is up and the S3 API is functional:

```bash
# On any machine with access to both old and new Garage S3 APIs
# Configure rclone for new cluster
cat >> ~/.rclone.conf <<'EOF'
[garage-new]
type = s3
provider = Other
endpoint = http://192.168.1.241:3900
access_key_id = <new access key>
secret_access_key = <new secret key>
region = us-east-1
force_path_style = true
EOF

# Test connectivity
rclone lsd garage-new:
```

### Step 3.6 — Enable garage on migration helper (VM 904) and start

```bash
ssh ubuntu@192.168.1.244
sudo systemctl enable --now garage
garage version
```

---

## Phase 4 — Data Migration (rclone sync)

### Step 4.1 — Prepare migration helper (VM 904)

```bash
ssh ubuntu@192.168.1.244

# Ensure rclone is installed and configured for both clusters
rclone config --check

# Verify old cluster is accessible
rclone lsd old-garage: || echo "Old cluster not configured yet"
```

### Step 4.2 — Run rclone sync

```bash
# Dry run first (validates credentials and shows what would be transferred)
rclone sync old-garage:all garage-new:all \
  --progress \
  --transfers 4 \
  --checkers 8 \
  --dry-run

# If dry run looks correct, run for real
rclone sync old-garage:all garage-new:all \
  --progress \
  --transfers 4 \
  --checkers 8
```

### Step 4.3 — Verify data integrity

```bash
# Compare bucket listings
rclone ls old-garage:all | wc -l
rclone ls garage-new:all | wc -l

# Compare checksums if available
rclone check old-garage:all garage-new:all \
  --one-way
```

---

## Phase 5 — Cutover + Cleanup

### Step 5.1 — Update all clients to use new Garage S3

Update `/etc/rclone.conf`, environment variables, ESO ExternalSecrets, and any application configs that reference `192.168.1.230:3900` to use `192.168.1.241:3900`.

**Update ESO ExternalSecrets** (Vault secret path):
```yaml
# ExternalSecret for garage S3 credentials — update endpoint
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: garage-s3-credentials
spec:
  # ... existing spec ...
  data:
    - secretKey: GARAGE_ENDPOINT_URL_OVERRIDE
      remoteRef:
        key: secret/data/garage/cluster
        property: endpoint   # Add endpoint property to the Vault secret
```

### Step 5.2 — Destroy migration helper

```bash
cd ~/repositories/homelab-tofu-workflow/infrastructure/terraform

# Verify VM 904 will be destroyed (no other changes)
tofu plan -destroy -target=module.migration_helper \
  -var="vault_approle_role_id=${ROLE_ID}" \
  -var="vault_approle_secret_id=${SECRET_ID}"

# Apply destruction
tofu apply -destroy -auto-approve \
  -target=module.migration_helper \
  -var="vault_approle_role_id=${ROLE_ID}" \
  -var="vault_approle_secret_id=${SECRET_ID}"
```

### Step 5.3 — Verify old cluster (VM 900) is drained

Before shutting down VM 900, verify:
1. All tofu state is accessible from new cluster
2. All ESO ExternalSecrets are reading from new cluster
3. All rclone mounts/configs reference new cluster
4. Longhorn snapshots (if any) reference new cluster S3

---

## Files Changed

| File | Change |
|------|--------|
| `infrastructure/terraform/main.tf` | Added module calls for garage_n1, garage_n2, garage_n3, migration_helper |
| `infrastructure/terraform/variables.tf` | Added vault_approle_role_id, vault_approle_secret_id |
| `infrastructure/terraform/terraform.tfvars` | Added AppRole variable values |
| `infrastructure/terraform/modules/vm/templates/cloud-init-garage.yaml.tftpl` | New garage-specific cloud-init template |
| `infrastructure/runner/entrypoint.sh` | Updated to use GitHub App JWT (not PAT) |
| `infrastructure/runner/Dockerfile` | Added `cryptography` Python package |
| `argocd/eso/cluster-secret-store.yaml` | Added vault-github-app ClusterSecretStore |
| `argocd/eso/external-secrets/` | New ExternalSecret for GitHub App credentials |
| `scripts/vault-garage-bootstrap.sh` | New script for garage cluster init + key creation |
| `scripts/rclone-garage-sync.sh` | New script for Phase 2 data sync |
| `scripts/garage-fetch-secrets.sh` | New script for Vault AppRole → garage secrets |

---

## Rollback Procedure

If Phase 1 fails at any step:

1. **VMs created but garage bootstrap fails:** `tofu destroy -target=module.garage_n1 -target=module.garage_n2 -target=module.garage_n3`
2. **Cluster up but data migration fails:** Keep old cluster (VM 900) running. Do not cut over clients. Retry rclone sync.
3. **Post-migration issues:** Old cluster (VM 900) is still running until explicitly destroyed. Cutover is reversible until VM 900 is destroyed.

---

## Verification Checklist

- [ ] `tofu plan` shows only add operations for garage nodes and migration helper
- [ ] `tofu apply` completes without error — all 4 VMs created
- [ ] Cloud-init completes on all 3 garage nodes (verify with `cloud-init status --wait`)
- [ ] `/etc/garage.env` contains real secrets (not PLACEHOLDER) on all nodes
- [ ] `garage node status` shows all 3 nodes as online on n1
- [ ] `garage bucket list` is accessible from n1
- [ ] `rclone lsd garage-new:` returns expected buckets
- [ ] `rclone check old-garage:all garage-new:all` passes with zero errors
- [ ] All ESO ExternalSecrets are reading from new cluster
- [ ] Migration helper VM 904 destroyed
- [ ] VM 900 (old cluster) still running — do not destroy until Step 5.3
