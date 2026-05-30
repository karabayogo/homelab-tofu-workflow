# Phase 1 Bootstrap — Garage S3 Cluster Initialization

**Context:** Three-node Garage v2.2.0 cluster (VMs 901/902/903). Sequential bootstrap required because:
- `garage cluster init` must run on n1 first before n2/n3 can join
- Daemon must NOT be started at boot — enabled only, started manually after cluster init
- Real secrets (rpc_secret, admin_token) fetched from Vault via AppRole at first boot

**Prerequisites (must be completed BEFORE this doc):**
- [x] ✅ Phase 0: Vault AppRole + policy + `secret/data/garage/cluster` seeded — DONE (2026-05-27)
- [x] ✅ `tofu apply` has been run (VMs 901/902/903 created, cloud-init completed on all three) — DONE
- [x] ✅ `systemctl start garage` REMOVED from cloud-init (commit 0fe9f94) — daemon stays dead until Step 1.2
- [x] ✅ `bootstrap_peers` ADDED to `garage.toml` — nodes auto-discover on restart (no manual `node connect`)
- [x] ✅ Gateway tags assigned to all 3 nodes (layout V2, 2026-05-30 audit)
- [x] ✅ Tofu backend migrated to new cluster (192.168.1.241:3900) — `~/.aws/credentials` updated
- [ ] ❌ Migration helper VM 904 NOT created — buckets and keys already exist on new cluster, VM 904 may not be needed
- [ ] ❌ Phase 0 doc (`00a-phase0-tofu-state-migration.md`) NOT created — VM 900 already destroyed; state migration was manual

---

## Step 1.1 — Verify cloud-init completed on all nodes

Run on moltbot (your local machine):

```bash
# Check cloud-init status on all three garage nodes
for ip in 192.168.1.241 192.168.1.242 192.168.1.243; do
  echo "=== Checking cloud-init on ${ip} ==="
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@${ip} \
    "cloud-init status --wait 2>/dev/null || sudo cloud-init status --wait 2>/dev/null || echo 'cloud-init may still be running'"
done
```

**Expected output:** All three nodes report `status: done` or `finished`. If any node shows `running` or `error`, wait 60s and re-check.

**Verification:** Each node should have `/etc/garage.env` containing real Vault-fetched secrets (not PLACEHOLDER):

```bash
# Verify secrets were fetched on each node
for ip in 192.168.1.241 192.168.1.242 192.168.1.243; do
  echo "=== ${ip} secrets ==="
  ssh -o StrictHostKeyChecking=no ubuntu@${ip} "cat /etc/garage.env" 2>/dev/null || echo "FILE NOT FOUND"
done
```

**Expected:** Each node has `GARAGE_RPC_SECRET=<hex string>` and `GARAGE_ADMIN_TOKEN=<hex string>`. If any node shows `PLACEHOLDER`, cloud-init did not complete the Vault fetch — debug before proceeding.

---

## Step 1.2 — Start Garage daemon on n1 (192.168.1.241)

SSH to n1 and start the daemon:

```bash
ssh ubuntu@192.168.1.241
```

On n1, run:

```bash
# Verify secrets
cat /etc/garage.env

# Start garage daemon (DO NOT run 'garage cluster init' yet)
sudo systemctl start garage

# Check daemon started successfully
sudo systemctl status garage --no-pager -l
```

**Expected:** `Active: active (running)` — Garage daemon is up and waiting for cluster initialization.

**Error recovery:** If daemon fails to start, check logs: `journalctl -u garage --no-pager -l`. Common causes:
- `/etc/garage.toml` has malformed config → review cloud-init template
- Data disk not mounted → `mount /mnt/garage-data` and check `/etc/fstab`
- Port 3900 already in use → `ss -tlnp | grep 3900`

---

## Step 1.3 — Initialize cluster on n1

On n1, run the cluster init command:

```bash
# Initialize the cluster (n1 is the initiator)
garage cluster init --tls-cert-organisation=garage

# Verify cluster initialized
garage node status
```

**Expected output:**
```
ID         | Name       | Tags | Status
---------- | ---------- | ---- | --------
<node_id>  | garage-n1  | []   | Online
```

**Verification:** `garage cluster info` should show 1 node, RF=3 not yet set (set in Step 1.6).

---

## Step 1.4 — Accept n2 (192.168.1.242) into cluster

**On n2:** SSH to n2, start daemon, capture the join token:

```bash
ssh ubuntu@192.168.1.242

# Verify secrets were fetched
cat /etc/garage.env

# Start garage daemon
sudo systemctl start garage
sudo systemctl status garage --no-pager -l
```

**Back on n1:** Accept n2 using the node ID from n2's startup log:

```bash
# On n1: check for n2's join token
garage node status
# Look for: "To join this node from another node, run:"
# Command: garage node accept --token <token> --node-id <n2-id>

# Accept n2
garage node accept --token <token_from_n2_startup_log>
```

**Verification on n1:**
```bash
garage node status
```
Should show 2 nodes: n1 (Online) and n2 (Online).

**Verification on n2:**
```bash
garage node status
```
Should show n2 is Online and knows about the cluster.

---

## Step 1.5 — Accept n3 (192.168.1.243) into cluster

**On n3:** SSH to n3, start daemon, capture join token:

```bash
ssh ubuntu@192.168.1.243

# Verify secrets were fetched
cat /etc/garage.env

# Start garage daemon
sudo systemctl start garage
sudo systemctl status garage --no-pager -l
```

**Back on n1:** Accept n3:

```bash
# On n1: accept n3
garage node accept --token <token_from_n3_startup_log>
```

**Verification on n1:**
```bash
garage node status
```
Should show 3 nodes: n1, n2, n3 all Online.

---

## Step 1.6 — Configure replication factor and storage

On n1, configure RF=3 and assign storage:

```bash
# Set replication factor
garage layout add --region default --replication-factor 3

# Tag nodes for storage
garage node mark --node-id $(garage node status --output json | jq -r '.nodes[0].id') --tag storage=true
garage node mark --node-id $(garage node status --output json | jq -r '.nodes[1].id') --tag storage=true
garage node mark --node-id $(garage node status --output json | jq -r '.nodes[2].id') --tag storage=true

# Verify cluster is healthy
garage cluster info
garage node status
```

**Expected:** All 3 nodes Online, replication factor 3, storage assigned.

---

## Step 1.7 — Create S3 credentials for data migration (Phase 2)

On n1, create S3 access key for the migration helper:

```bash
# Create a key for migration
garage key create migration-key

# Issue S3 credentials for the migration helper
garage key issue migration-key

# Capture the access key and secret key from output
# Format:
#   Access key: <key>
#   Secret key: <key>
```

**CRITICAL:** Save these credentials. They are consumed by the migration helper (VM 904) via the new cluster's Management API — see `04-migration-helper-run.sh`. The helper fetches S3 keys directly from the new cluster API (grill-agreed Option B), so these credentials are NOT written to Vault.

---

## Step 1.8 — Note: S3 credentials fetched directly by helper (no Vault write)</step>

The migration helper (VM 904) fetches S3 credentials from the new cluster's Management API directly — it does NOT read from Vault. This was the grill-agreed Option B. Therefore:

- **Do NOT write S3 credentials to Vault from this bootstrap doc**
- S3 keys created in Step 1.7 are consumed by `04-migration-helper-run.sh` when the helper calls `garage key issue migration-key` via the Management API
- The helper uses `admin_token` from `/etc/garage.env` to authenticate to the Management API

If you need to verify the helper can reach the new cluster API, run Step 1.9.

---

## Step 1.9 — Verify S3 API is functional

On n1, test the S3 API:

```bash
# Configure AWS CLI for the new cluster
export AWS_ACCESS_KEY_ID="<from Step 1.7>"
export AWS_SECRET_ACCESS_KEY="<from Step 1.7>"
export AWS_ENDPOINT_URL_OVERRIDE="http://192.168.1.241:3900"

# List buckets (should be empty — old data not migrated yet)
aws s3 ls --endpoint-url http://192.168.1.241:3900

# Create a test bucket to verify write access
aws s3 mb s3://migration-test --endpoint-url http://192.168.1.241:3900

# Clean up test bucket
aws s3 rb s3://migration-test --endpoint-url http://192.168.1.241:3900
```

**Expected:** `aws s3 ls` succeeds with empty output (no buckets yet). `aws s3 mb` creates bucket successfully.

---

## Step 1.10 — Start migration helper (VM 904)

The migration helper (VM 904) was created in `tofu apply`. It needs to be started and configured for Phase 2.

```bash
# SSH to migration helper
ssh ubuntu@192.168.1.244

# Start garage daemon on the helper
sudo systemctl enable --now garage

# Verify garage is running
garage version
sudo systemctl status garage --no-pager -l
```

**Expected:** `garage version` returns `v2.2.0`. Daemon is active.

---

## Step 1.11 — Update tofu state backend to new cluster (AFTER Phase 2 data migration)

**DO NOT do this until Phase 2 (data migration) is complete.**

After rclone sync has verified all data is on the new cluster:

```bash
cd ~/repositories/homelab-tofu-workflow/infrastructure/terraform

# Update backend endpoint in main.tf:
# Change: endpoint = "http://192.168.1.230:3900"
# To:      endpoint = "http://192.168.1.241:3900"

# Run tofu init to migrate state to new backend
tofu init -migrate-state

# Verify state is on new cluster
tofu plan -var="vault_approle_role_id=${ROLE_ID}" \
         -var="vault_approle_secret_id=${SECRET_ID}"
```

**Warning:** This step is irreversible. Ensure Phase 2 data migration is complete and verified before proceeding.

---

## Step 1.12 — Verify Phase 1 completion

All steps above must show success before proceeding to Phase 2 (`02-garage-migration-plan.md` Phase 4).

**Checklist:**
- [ ] All three garage nodes: cloud-init shows `status: done`
- [ ] All three nodes: `/etc/garage.env` has real secrets (not PLACEHOLDER)
- [ ] n1: `garage cluster init` completed successfully
- [ ] n1: `garage node accept` succeeded for n2
- [ ] n1: `garage node accept` succeeded for n3
- [ ] All three nodes show `Online` in `garage node status`
- [ ] `garage cluster info` shows RF=3
- [ ] S3 credentials created and saved (Step 1.7)
- [ ] S3 credentials written to Vault (Step 1.8)
- [ ] `aws s3 ls` on new cluster succeeds
- [ ] Migration helper (VM 904) garage daemon is running

---

## Rollback Procedure

If cluster init fails catastrophically:

```bash
# On each node: stop garage and reset
ssh ubuntu@192.168.1.241
sudo systemctl stop garage
sudo rm -f /etc/garage.toml
# Re-run cloud-init to regenerate config:
sudo cloud-init clean --logs && sudo cloud-init init

# Repeat on n2 and n3
```

**Note:** `garage cluster init` can only be run once per cluster lifetime. If init has already been run, you must wipe and re-initialize. The nuclear option is to destroy VMs 901/902/903 and re-run `tofu apply`.

---

## Dependencies

| Step | Depends on |
|------|------------|
| 1.1  | `tofu apply` completed |
| 1.2  | Step 1.1 (cloud-init done) |
| 1.3  | Step 1.2 (daemon running) |
| 1.4  | Step 1.3 (cluster init done) |
| 1.5  | Step 1.4 (n2 accepted) |
| 1.6  | Step 1.5 (n3 accepted) |
| 1.7  | Step 1.6 (cluster healthy) |
| 1.8  | Step 1.7 (S3 keys created) |
| 1.9  | Step 1.8 (credentials in Vault) |
| 1.10 | Step 1.8 |
| 1.11 | Phase 2 complete |