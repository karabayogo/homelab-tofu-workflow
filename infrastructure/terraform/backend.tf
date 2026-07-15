# ============================================================
# backend.tf — remote state configuration
#
# Endpoint and credentials are injected at `tofu init` time via
# `-backend-config`, not hardcoded in Git:
#   endpoint   = http://192.168.1.246:9000   (current tofu-state1 MinIO)
#   access_key = ...
#   secret_key = ...
#
# This lets the same codebase migrate to a different S3-compatible control-plane
# backend without another code change, and avoids coupling Git history to one
# mutable object-store cluster.
# ============================================================

terraform {
  backend "s3" {
    region                      = "us-east-1"
    bucket                      = "terraform-state"
    key                         = "homelab-tofu-workflow/terraform.tfstate"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    use_path_style              = true
  }
}
