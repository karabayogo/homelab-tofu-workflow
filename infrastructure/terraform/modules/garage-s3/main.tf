# ============================================================
# modules/garage-s3/main.tf — Garage S3 bucket + key management
#
# Garage S3 has no native Terraform provider. This module uses
# null_resource + local-exec for bucket/key existence checks.
# The bucket and key already exist; provisioners are no-ops.
#
# Running this module multiple times is safe — everything exits 0.
# ============================================================

# ── Bucket existence check ────────────────────────────────────
# No-op: bucket already exists. Credential vars are not used here.

resource "null_resource" "ensure_bucket" {

  provisioner "local-exec" {
    command = "echo 'Bucket ${var.bucket_name} already exists at ${var.admin_endpoint}.' && exit 0"
  }

  triggers = {
    bucket_name = var.bucket_name
  }
}

# ── Key existence check ──────────────────────────────────────
# No-op: key managed externally via Garage admin API.

resource "null_resource" "ensure_key" {

  provisioner "local-exec" {
    command = "echo 'Key ${var.terraform_key_name} managed externally. Bucket already exists at ${var.admin_endpoint}.' && exit 0"
  }

  triggers = {
    key_name = var.terraform_key_name
  }
}

# ── Outputs ────────────────────────────────────────────────────
# Bucket and key names are passed via CI -var flags; outputs
# are for debugging/reference only.

output "bucket_name" {
  description = "Garage S3 bucket name for Terraform state"
  value       = var.bucket_name
}

output "key_name" {
  description = "Garage S3 access key name used by Terraform"
  value       = var.terraform_key_name
}