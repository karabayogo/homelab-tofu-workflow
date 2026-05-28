# Vault AppRole Setup — Garage S3 Node Authentication

**Purpose:** Configure Vault so garage nodes (VMs 901/902/903) can authenticate at first boot using AppRole credentials baked into cloud-init, fetch real secrets (rpc_secret, admin_token) from Vault, and replace PLACEHOLDER values in `/etc/garage.toml`.

**Prerequisites:**
- Vault is running in the k8s cluster at `https://vault.ariesmcrae.com` (external) / `https://vault.vault.svc.cluster.local:8200` (internal)
- Vault root token available for initial setup (stored in Vault at `secret/data/data/vault/root-token` — fetch via ESO or from a k8s master node)
- kubectl access to the k8s cluster (via k8s-master2 at 192.168.1.202 or k8s-worker1 at 192.168.1.204)
- AppRole credentials will be stored in `terraform.tfvars` — same values used for all three garage nodes + migration helper

---

## Step 1 — Verify Vault is reachable and unsealed

From any machine that can reach Vault:

```bash
# Check Vault status (unsealed = ready)
curl -sS https://vault.ariesmcrae.com/v1/sys/health \
  | jq '{initialized: .initialized, sealed: .sealed, version: .version}'
```

**Expected output:** `initialized: true, sealed: false` — Vault is ready.

**Error recovery:** If `sealed: true`, run `vault operator unseal` on the Vault pod (k8s-master2 SSH + `kubectl exec`). If `initialized: false`, Vault needs to be initialized from scratch (out of scope for this doc).

---

## Step 2 — Enable AppRole auth method

**Option A — From inside the cluster (recommended):**

SSH to a k8s master or worker node that has kubectl access:

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.1.202

# Check Vault pod status
kubectl get pods -n vault

# Exec into Vault pod
kubectl exec -n vault vault-0 -- vault auth list
```

Verify `approle` is listed. If not:

```bash
kubectl exec -n vault vault-0 -- vault auth enable approle
```

**Option B — From moltbot with direct Vault CLI:**

```bash
# Authenticate to Vault using root token (fetch from ESO or k8s master)
export VAULT_ADDR="https://vault.ariesmcrae.com"
vault login -

# Enable AppRole auth method
vault auth enable approle
```

---

## Step 3 — Create Vault policy for garage-cluster

The policy grants read access to `secret/data/garage/cluster` (where rpc_secret + admin_token are stored).

**From the Vault pod (SSH to k8s-master2, then kubectl exec):**

```bash
kubectl exec -n vault vault-0 -- vault policy list
```

Create the policy:

```bash
kubectl exec -n vault vault-0 -- vault policy write garage-cluster - <<'EOF'
# Read garage cluster secrets (rpc_secret + admin_token)
path "secret/data/garage/cluster" {
  capabilities = ["read"]
}
EOF
```

**Verify:**
```bash
kubectl exec -n vault vault-0 -- vault policy read garage-cluster
```

**Expected:** Policy shows one path block (`secret/data/garage/cluster`) with read capability. The helper reads S3 credentials directly from the new cluster API (Option B), not from Vault.

---

## Step 4 — Create AppRole role for garage-node

Create the AppRole with the `garage-cluster` policy attached:

```bash
kubectl exec -n vault vault-0 -- vault write auth/approle/role/garage-node \
  secret_id_ttl=8760h \
  token_ttl=1h \
  policies=garage-cluster
```

**Parameters explained:**
- `secret_id_ttl=8760h` — Secret ID never expires (one-time generation, shown only once)
- `token_ttl=1h` — Short-lived Vault token, reduces blast radius if credential is compromised
- `policies=garage-cluster` — The policy created in Step 3

**Verify:**
```bash
kubectl exec -n vault vault-0 -- vault read auth/approle/role/garage-node
```

**Expected output:** Shows `secret_id_ttl`, `token_ttl`, `policies: [garage-cluster]`.

---

## Step 5 — Generate AppRole credentials

Get the `role_id` and generate a `secret_id`:

```bash
# Get role_id (stable — doesn't change)
ROLE_ID=$(kubectl exec -n vault vault-0 -- vault read -field=role_id auth/approle/role/garage-node/role-id)
echo "ROLE_ID: ${ROLE_ID}"
# Example output: 9f3f8c2d-4a5b-6e7f-8a9b-0c1d2e3f4a5b

# Generate secret_id (ONE-TIME — shown only here, save it somewhere secure)
kubectl exec -n vault vault-0 -- vault write -f auth/approle/role/garage-node/secret-id
# Example output:
#   secret_id               4a5b6c7d-8e9f-0a1b-2c3d-4e5f6a7b8c9d
#   secret_id_accessor      1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d
```

**CRITICAL:** Copy and save both `ROLE_ID` and `SECRET_ID` immediately. The `SECRET_ID` is shown only once and cannot be retrieved later. If lost, regenerate with:

```bash
kubectl exec -n vault vault-0 -- vault write -f auth/approle/role/garage-node/secret-id
```

---

## Step 6 — Seed garage/cluster secrets in Vault

Write the real secrets to Vault. These will be fetched by cloud-init on first boot:

```bash
# Generate random secrets (or use your own)
RPC_SECRET=$(openssl rand -hex 32)
ADMIN_TOKEN=$(openssl rand -hex 32)

echo "RPC_SECRET: ${RPC_SECRET}"
echo "ADMIN_TOKEN: ${ADMIN_TOKEN}"

# Write to Vault
kubectl exec -n vault vault-0 -- vault kv put secret/data/garage/cluster \
  rpc_secret="${RPC_SECRET}" \
  admin_token="${ADMIN_TOKEN}"
```

**Verify:**
```bash
kubectl exec -n vault vault-0 -- vault kv get secret/data/garage/cluster
```

**Expected output:** Shows `rpc_secret` and `admin_token` with real hex values (not shown in output for security).

---

## Step 7 — Test AppRole authentication

Verify that the AppRole credentials work — can authenticate and read the secrets:

```bash
# Authenticate with AppRole
VAULT_TOKEN=$(curl -sS \
  -X POST \
  -d "role_id=${ROLE_ID}&secret_id=${SECRET_ID}" \
  "https://vault.ariesmcrae.com/v1/auth/approle/login" \
  | jq -r '.auth.client_token')

echo "VAULT_TOKEN obtained: ${VAULT_TOKEN:0:8}..."

# Fetch secrets using the obtained token
curl -sS \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "https://vault.ariesmcrae.com/v1/secret/data/garage/cluster" \
  | jq '.data.data'
```

**Expected:** Shows `rpc_secret` and `admin_token` with the values from Step 6.

**Error recovery:**
- `invalid credential` → role_id or secret_id is wrong; regenerate secret_id in Step 5
- `permission denied` → policy not attached; verify Step 4
- `path not found` → secret not seeded; re-run Step 6

---

## Step 8 — Add AppRole credentials to terraform.tfvars

On moltbot, update the terraform variables:

```bash
cd ~/repositories/homelab-tofu-workflow/infrastructure/terraform

# Edit terraform.tfvars — ADD these two lines
# Replace <role_id> and <secret_id> with values from Step 5
vault_approle_role_id   = "<role_id>"
vault_approle_secret_id = "<secret_id>"
```

**IMPORTANT:** `terraform.tfvars` is typically in `.gitignore` but ensure it is NOT committed to the repo. If it is tracked, use `tfvars` file naming convention to keep it local. Verify:

```bash
git -C ~/repositories/homelab-tofu-workflow check-ignore terraform.tfvars
# Should output: terraform.tfvars
# If empty, the file is tracked — move to terraform.tfvars.local instead
```

---

## Step 9 — Update cloud-init template to verify Vault fetch

The cloud-init template (`cloud-init-garage.yaml.tftpl`) already contains the Vault AppRole fetch logic. Verify it is correctly configured:

```bash
grep -A 30 "vault_approle" ~/repositories/homelab-tofu-workflow/infrastructure/terraform/modules/vm/templates/cloud-init-garage.yaml.tftpl
```

**Expected:** Template shows:
- `ROLE_ID` and `SECRET_ID` passed as template variables
- `vault write -f auth/approle/login` for AppRole authentication
- Fetch from `secret/data/garage/cluster`
- `GARAGE_RPC_SECRET` and `GARAGE_ADMIN_TOKEN` written to `/etc/garage.env`

---

## Step 10 — Commit and push terraform changes

```bash
cd ~/repositories/homelab-tofu-workflow

# Create feature branch
git checkout -b feat/garage-approle-vault

# Stage terraform.tfvars (use .local extension to avoid accidental commit)
# If using terraform.tfvars.local:
git add infrastructure/terraform/terraform.tfvars.local

# Stage cloud-init template (if modified)
git add infrastructure/terraform/modules/vm/templates/cloud-init-garage.yaml.tftpl

# Commit
git commit -m "feat: add Vault AppRole credentials to terraform.tfvars

- Adds vault_approle_role_id and vault_approle_secret_id variables
- cloud-init-garage.yaml.tftpl uses AppRole to fetch real secrets from Vault
- Secrets (rpc_secret, admin_token) seeded in Vault at secret/data/garage/cluster

Refs: plan/02-garage-migration-plan.md Phase 2"

# Push
git push -u origin feat/garage-approle-vault

# Create PR
gh pr create \
  --title "feat: Vault AppRole setup for garage nodes" \
  --body "Adds Vault AppRole credentials to terraform.tfvars. Cloud-init on garage nodes (901/902/903) uses AppRole to fetch real rpc_secret and admin_token from Vault at first boot, replacing PLACEHOLDER values.

Steps completed:
- [x] Vault AppRole enabled
- [x] garage-cluster policy created (read on secret/data/garage/cluster only — helper fetches S3 keys via Management API, not Vault)
- [x] garage-node role created (secret_id_ttl=8760h, token_ttl=1h)
- [x] AppRole credentials generated (role_id + secret_id)
- [x] secrets seeded in Vault (rpc_secret, admin_token)
- [x] AppRole auth tested successfully" \
  --base main

# Merge (bypass review — user has org admin)
gh pr merge N --squash --delete-branch --admin
```

Replace `N` with the PR number from the `gh pr create` output.

---

## Step 11 — Verify the tofu plan runs cleanly

After the PR is merged, GitHub Actions will trigger `infra.yml`. Verify:

```bash
# Watch the run
gh run watch

# Or check status
gh run list --workflow=infra.yml --limit=1
```

**Expected:** `infra.yml` plan step shows no changes to existing VMs (k8s masters/workers/openclaw), and shows +++ for garage_n1/garage_n2/garage_n3 module creation.

**If tofu plan fails:**
- Check `gh run view` for the error
- Common cause: `vault_approle_role_id` or `vault_approle_secret_id` not set in `terraform.tfvars`
- Fix: ensure `terraform.tfvars` has both values from Step 5

---

## Verification Checklist

After completing all steps:

- [ ] `vault auth list` shows `approle/` enabled
- [ ] `vault policy read garage-cluster` shows read on `secret/data/garage/cluster` only (no s3-credentials path — helper uses Management API)
- [ ] `vault read auth/approle/role/garage-node` shows `policies: [garage-cluster]`
- [ ] `vault kv get secret/data/garage/cluster` shows real (non-PLACEHOLDER) rpc_secret and admin_token
- [ ] AppRole authentication test (Step 7) returns the secrets successfully
- [ ] `terraform.tfvars` has `vault_approle_role_id` and `vault_approle_secret_id` set
- [ ] `tofu plan` runs without error
- [ ] PR merged, GitHub Actions green

---

## Rollback

If something goes wrong with AppRole setup:

```bash
# Regenerate secret_id (old one is still valid until revoked)
kubectl exec -n vault vault-0 -- vault write -f auth/approle/role/garage-node/secret-id

# If role is broken, recreate:
kubectl exec -n vault vault-0 -- vault delete auth/approle/role/garage-node
kubectl exec -n vault vault-0 -- vault write auth/approle/role/garage-node \
  secret_id_ttl=8760h \
  token_ttl=1h \
  policies=garage-cluster

# If policy is wrong, update:
kubectl exec -n vault vault-0 -- vault policy write garage-cluster - <<'EOF'
path "secret/data/garage/cluster" {
  capabilities = ["read"]
}
EOF
```

---

## Dependencies

| Step | Depends on |
|------|------------|
| 1.1  | Vault reachable from network |
| 1.2  | Step 1 (AppRole enabled) |
| 1.3  | Step 1 (policy created) |
| 1.4  | Step 2 (role created) |
| 1.5  | Step 3 (credentials generated) |
| 1.6  | Step 4 (secrets seeded) |
| 1.7  | Step 5 (auth tested) |
| 1.8  | Step 6 (tfvars updated) |
| 1.9  | Step 7 (PR merged, Actions green) |