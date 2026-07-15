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
  description = "Garage S3 access key for Garage object-store administration and bootstrap resources"
  type        = string
  sensitive   = true
  default     = ""
}

variable "garage_secret_key" {
  description = "Garage S3 secret key for Garage object-store administration and bootstrap resources"
  type        = string
  sensitive   = true
  default     = ""
}

variable "state_backend_access_key" {
  description = "Access key used by the dedicated state-backend VM. Not marked sensitive because it must render into cloud-init literally."
  type        = string
  default     = ""
}

variable "state_backend_secret_key" {
  description = "Secret key used by the dedicated state-backend VM. Not marked sensitive because it must render into cloud-init literally."
  type        = string
  default     = ""
}

# ── k3s cattle config ──

variable "k3s_token" {
  description = "k3s cluster join token (pass via TF_VAR or CI secret)"
  type        = string
  # NOT marked sensitive — must render into cloud-init templatefile() literally
  default = ""
}

# ── Vault AppRole bootstrap for Garage nodes ──

variable "vault_addr" {
  description = "Reachable Vault API endpoint for Garage node bootstrap (must be reachable from VM LAN)"
  type        = string
  nullable    = false
  default     = ""
}

variable "vault_approle_role_id" {
  description = "Vault AppRole Role ID used by Garage nodes to fetch secret/data/garage/cluster"
  type        = string
  # NOT marked sensitive — templatefile() masks ALL vars if any is sensitive
  nullable = false
  default  = ""
}

variable "vault_approle_secret_id" {
  description = "Vault AppRole Secret ID used by Garage nodes to fetch secret/data/garage/cluster"
  type        = string
  # NOT marked sensitive — templatefile() masks ALL vars if any is sensitive
  nullable = false
  default  = ""
}

# ── Vault AppRole bootstrap for migration helper (least privilege) ──

variable "vault_migration_approle_role_id" {
  description = "Vault AppRole Role ID used by migration helper to read secret/data/garage-s3 and secret/data/garage-s3-new"
  type        = string
  # NOT marked sensitive — templatefile() masks ALL vars if any is sensitive
  nullable = false
  default  = ""
}

variable "vault_migration_approle_secret_id" {
  description = "Vault AppRole Secret ID used by migration helper to read secret/data/garage-s3 and secret/data/garage-s3-new"
  type        = string
  # NOT marked sensitive — templatefile() masks ALL vars if any is sensitive
  nullable = false
  default  = ""
}

# ── Garage migration rollout flags (GitOps phase control) ──

variable "enable_garage_cluster" {
  description = "Enable provisioning of Garage cluster VMs (901/902/903)"
  type        = bool
  default     = false
}

variable "enable_migration_helper" {
  description = "Enable provisioning of migration helper VM (904)"
  type        = bool
  default     = false
}

variable "start_garage_nodes" {
  description = "Start Garage cluster VMs (901/902/903) after initial provisioning"
  type        = bool
  default     = false
}

variable "start_migration_helper" {
  description = "Start migration helper VM (904) after initial provisioning"
  type        = bool
  default     = false
}

variable "protect_garage_nodes" {
  description = "Enable Proxmox VM protection on Garage nodes (set false during bootstrap/reprovision, true after migration cutover)"
  type        = bool
  default     = true
}

# ── PVE host capacity guardrails ──

variable "pve_host_total_memory_mb" {
  description = "Physical RAM available on the single Proxmox host. Keep conservative so CI fails before host overcommit."
  type        = number
  default     = 63488
}

variable "pve_host_reserved_memory_mb" {
  description = "Minimum RAM permanently reserved for the PVE host itself, ZFS ARC, daemons, and burst headroom."
  type        = number
  default     = 6144
}

variable "pve_unmanaged_reserved_memory_mb" {
  description = "RAM reserved for legacy/manual VMs that are still outside Terraform. Default covers VM 201 and VM 300 until they are onboarded as cattle."
  type        = number
  default     = 24576
}
