# ============================================================
# modules/garage-s3/variables.tf
# ============================================================

variable "admin_endpoint" {
  description = "Garage S3 API endpoint (e.g. http://192.168.1.230:3900)"
  type        = string
  default     = "http://192.168.1.230:3900"
}

variable "admin_key_id" {
  description = "Garage admin access key ID (from CI secrets)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "admin_secret_key" {
  description = "Garage admin secret access key (from CI secrets)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "bucket_name" {
  description = "Name of the S3 bucket for Terraform state"
  type        = string
  default     = "terraform-state"
}

variable "terraform_key_name" {
  description = "Name tag for the Terraform access key in Garage"
  type        = string
  default     = "terraform-state-key"
}
