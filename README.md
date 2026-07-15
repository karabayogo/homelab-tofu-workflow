# homelab-tofu-workflow

Reusable GitHub Actions workflow + OpenTofu infrastructure code for homelab k8s cattle.

## What's here

### Reusable CI/CD workflow

`.github/workflows/tofu.yml` — reusable workflow for OpenTofu plan/apply with a dedicated S3-compatible control-plane state backend. Other repos call it via `workflow_call`.

### k8s cattle templates

`infrastructure/terraform/` — full OpenTofu code declaring all k8s cluster VMs as cattle:
- 3x control plane (VM 400, 500, 600)
- 2x workers (VM 700, 800)
- `modules/vm/` — reusable VM module with cloud-image provisioner, cloud-init templates, and post-create hooks
- dedicated control-plane state backend (`terraform-state` bucket on `tofu-state1`)

### Self-calling CI

`.github/workflows/infra.yml` — calls the reusable workflow for this repo's own TF code.

## Reusable workflow usage

In your infra repo's `.github/workflows/infra-apply.yml`:

```yaml
name: Infra Apply

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  tofu:
    uses: karabayogo/homelab-tofu-workflow/.github/workflows/tofu.yml@main
    with:
      runner_labels: '["self-hosted", "LAN", "moltbot", "your-repo"]'
      tofu_version: ${{ vars.TOFU_VERSION }}
      terraform_dir: infrastructure/terraform
      checkout_path: your-repo
    secrets:
      PROXMOX_API_TOKEN: ${{ secrets.PROXMOX_API_TOKEN }}
      PVE_SSH_PRIVATE_KEY: ${{ secrets.PVE_SSH_PRIVATE_KEY }}
      TOFU_BACKEND_ACCESS_KEY: ${{ secrets.TOFU_BACKEND_ACCESS_KEY }}
      TOFU_BACKEND_SECRET_KEY: ${{ secrets.TOFU_BACKEND_SECRET_KEY }}
      TOFU_BACKEND_ENDPOINT: ${{ secrets.TOFU_BACKEND_ENDPOINT }}
      GARAGE_ACCESS_KEY: ${{ secrets.GARAGE_ACCESS_KEY }}
      GARAGE_SECRET_KEY: ${{ secrets.GARAGE_SECRET_KEY }}
      GARAGE_ENDPOINT_URL_OVERRIDE: ${{ secrets.GARAGE_ENDPOINT_URL_OVERRIDE }}
      K3S_TOKEN: ${{ secrets.K3S_TOKEN }}
```

## Required Secrets

| Secret | Description |
|--------|-------------|
| `PROXMOX_API_TOKEN` | Proxmox VE API token |
| `PVE_SSH_PRIVATE_KEY` | SSH private key for Proxmox host |
| `TOFU_BACKEND_ACCESS_KEY` | Dedicated OpenTofu state-backend access key |
| `TOFU_BACKEND_SECRET_KEY` | Dedicated OpenTofu state-backend secret key |
| `TOFU_BACKEND_ENDPOINT` | Dedicated OpenTofu state-backend endpoint |
| `GARAGE_ACCESS_KEY` | Garage workload-cluster S3 access key |
| `GARAGE_SECRET_KEY` | Garage workload-cluster S3 secret key |
| `GARAGE_ENDPOINT_URL_OVERRIDE` | Garage workload-cluster S3 endpoint URL |
| `K3S_TOKEN` | k3s cluster join token (optional, required for k8s cattle templates) |

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `runner_labels` | `["self-hosted", "LAN", "moltbot"]` | JSON array of runner labels |
| `tofu_version` | `1.11.6` | OpenTofu version |
| `terraform_dir` | `infrastructure/terraform` | Directory with terraform files |
| `checkout_path` | `.` | Checkout path for the repo |

## How it works

- **PRs** trigger a `tofu plan` (read-only, no changes)
- **Pushes to main** trigger a `tofu apply` (with `environment: production` gate)
- State is stored in a dedicated S3-compatible control-plane backend with `us-east-1` SigV4 compatibility
- CI uses a dedicated compatibility credential on `tofu-state1` so backend migrations do not break runners during control-plane cutovers
- Terraform enforces a PVE host memory budget so CI fails before a single-host overcommit can push Proxmox into swap thrash again
- Legacy/manual VMs are accounted for explicitly in that budget until they are onboarded into GitOps as cattle
- PVE host config is backed up to PBS via `scripts/pve-host-config-backup-to-pbs.{sh,service,timer}` instead of mounting Synology/NFS into the management plane
- VMs are cattle: `prevent_destroy = true`, imported via `tofu import`, cloud-init handles k3s bootstrap
- Worker nodes get `node-role.kubernetes.io/worker` label applied via post-create kubectl hook
# smoke test 2026-05-20T22:35:35+10:00
