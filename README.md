# homelab-tofu-workflow

Reusable GitHub Actions workflow + OpenTofu infrastructure code for homelab k8s cattle.

## What's here

### Reusable CI/CD workflow

`.github/workflows/tofu.yml` — reusable workflow for OpenTofu plan/apply with Garage S3 remote state and SigV4 authentication. Other repos call it via `workflow_call`.

### k8s cattle templates

`infrastructure/terraform/` — full OpenTofu code declaring all k8s cluster VMs as cattle:
- 3x control plane (VM 400, 500, 600)
- 2x workers (VM 700, 800)
- `modules/vm/` — reusable VM module with cloud-image provisioner, cloud-init templates, and post-create hooks
- Garage S3 backend for state (`terraform-state` bucket)

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
| `GARAGE_ACCESS_KEY` | Garage S3 access key |
| `GARAGE_SECRET_KEY` | Garage S3 secret key |
| `GARAGE_ENDPOINT_URL_OVERRIDE` | Garage S3 endpoint URL |
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
- State is stored in Garage S3 with `us-east-1` SigV4 region workaround
- VMs are cattle: `prevent_destroy = true`, imported via `tofu import`, cloud-init handles k3s bootstrap
- Worker nodes get `node-role.kubernetes.io/worker` label applied via post-create kubectl hook
