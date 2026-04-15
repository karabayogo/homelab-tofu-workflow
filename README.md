# homelab-tofu-workflow

Reusable GitHub Actions workflow for OpenTofu-based homelab infrastructure CI/CD.

Uses Garage S3 remote backend for Terraform state with SigV4 authentication.

## Usage

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
```

## Required Secrets

| Secret | Description |
|--------|-------------|
| `PROXMOX_API_TOKEN` | Proxmox VE API token |
| `PVE_SSH_PRIVATE_KEY` | SSH private key for Proxmox host |
| `GARAGE_ACCESS_KEY` | Garage S3 access key |
| `GARAGE_SECRET_KEY` | Garage S3 secret key |
| `GARAGE_ENDPOINT_URL_OVERRIDE` | Garage S3 endpoint URL |

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