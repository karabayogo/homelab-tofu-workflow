# ============================================================
# backend.tf — Garage S3 remote state configuration
#
# Uses environment variables (not .tfvars) for credentials:
#   AWS_ACCESS_KEY_ID     = tofu-backend access key
#   AWS_SECRET_ACCESS_KEY = tofu-backend secret key
#   AWS_ENDPOINT_URL_OVERRIDE = http://192.168.1.241:3900
#
# GitHub Actions: set via secrets in workflow yaml.
# Local runs: export before tofu init/plan/apply.
# ============================================================

terraform {
  backend "s3" {
    endpoint = "http://192.168.1.241:3900"

    # Credentials from environment — DO NOT hardcode
    # export AWS_ACCESS_KEY_ID=...
    # export AWS_SECRET_ACCESS_KEY=...
    # export AWS_ENDPOINT_URL_OVERRIDE=http://192.168.1.241:3900
    # export AWS_DEFAULT_REGION=us-east-1

    region                      = "us-east-1"
    bucket                      = "terraform-state"
    key                         = "homelab-tofu-workflow/terraform.tfstate"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    use_path_style              = true
  }
}
