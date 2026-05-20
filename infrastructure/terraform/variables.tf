# ============================================================
# variables.tf — All tuneable VM parameters
# CI passes secrets via -var flags. Local dev uses terraform.tfvars.
# ============================================================

variable "proxmox_host" {
  description = "Proxmox hostname or IP"
  type        = string
  default     = "192.168.1.50"
}

variable "proxmox_port" {
  description = "Proxmox API port"
  type        = string
  default     = "8006"
}

variable "proxmox_api_token" {
  description = "Full Proxmox API token (format: user!tokenid:secret)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "vm_storage" {
  description = "Proxmox storage pool for OS disks"
  type        = string
  default     = "local-zfs"
}

variable "data_storage" {
  description = "Proxmox storage pool for extra data disks"
  type        = string
  default     = "bulkpool"
}

variable "bridge" {
  description = "Proxmox bridge name"
  type        = string
  default     = "vmbr0"
}

variable "garage_access_key" {
  description = "Garage S3 access key for remote state backend"
  type        = string
  sensitive   = true
  default     = ""
}

variable "garage_secret_key" {
  description = "Garage S3 secret key for remote state backend"
  type        = string
  sensitive   = true
  default     = ""
}

# ── k3s cattle config ──

variable "k3s_token" {
  description = "k3s cluster join token (sensitive — pass via TF_VAR or CI secret)"
  type        = string
  sensitive   = true
  default     = ""
}
