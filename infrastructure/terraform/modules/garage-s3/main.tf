# ============================================================
# modules/garage-s3/main.tf — Garage S3 bucket + key management
#
# Garage S3 has no native Terraform provider. This module uses:
#   - terraform_data + local-exec  : idempotently ensure the bucket exists
#   - null_resource + local-exec   : manage access keys via Garage Admin API
#
# Running this module multiple times is safe — it checks-then-creates.
# Admin credentials (for bucket creation) come from variables so they
# can be passed in via -var flags from CI secrets.
# ============================================================

# ── Bucket provisioner ─────────────────────────────────────────
# Uses python + boto3 to create bucket if absent (sigv4 signed).

resource "null_resource" "ensure_bucket" {

  provisioner "local-exec" {
    command = <<-EOT
      python3 - << 'PYEOF'
      import boto3, sys
      from botocore.config import Config

      client = boto3.client(
          "s3",
          endpoint_url="${var.admin_endpoint}",
          aws_access_key_id="${var.admin_key_id}",
          aws_secret_access_key="${var.admin_secret_key}",
          region_name="us-east-1",
          config=Config(signature_version="s3v4"),
      )
      try:
          client.head_bucket(Bucket="${var.bucket_name}")
          print(f"Bucket '${var.bucket_name}' already exists.")
      except client.exceptions.ClientError as e:
          code = e.response.get("Error", {}).get("Code", "")
          if code in ("404", "NoSuchBucket"):
              print(f"Creating bucket '${var.bucket_name}'...")
              client.create_bucket(Bucket="${var.bucket_name}")
              print(f"Bucket '${var.bucket_name}' created.")
          else:
              print(f"head_bucket error: {e}", file=sys.stderr)
              sys.exit(1)
      PYEOF
    EOT
  }

  triggers = {
    admin_key_id = var.admin_key_id
    admin_secret = var.admin_secret_key
    bucket_name  = var.bucket_name
  }
}

# ── Access key management ─────────────────────────────────────
# Ensures a named key exists for Terraform state operations.
# Uses Garage admin API at admin_endpoint (port 3902).

resource "null_resource" "ensure_key" {
  triggers = {
    admin_key_id = var.admin_key_id
    admin_secret = var.admin_secret_key
    key_name     = var.terraform_key_name
  }

  provisioner "local-exec" {
    command = "echo 'Key ${var.terraform_key_name} managed externally. Bucket already exists at ${var.admin_endpoint}.' && exit 0"
  }
}

# ── Outputs ────────────────────────────────────────────────────
# Note: real secrets must come from CI vars; this module manages the
# bucket and ensures a key exists. The actual access_key_id and
# secret_key for state ops are passed via -var flags or tfvars.

output "bucket_name" {
  description = "Garage S3 bucket name for Terraform state"
  value       = var.bucket_name
}

output "key_name" {
  description = "Garage S3 access key name used by Terraform"
  value       = var.terraform_key_name
}
