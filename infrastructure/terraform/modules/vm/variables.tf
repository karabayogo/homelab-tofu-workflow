# ============================================================
# modules/vm/variables.tf — VM module variables
# ============================================================

variable "vm_id" {
  description = "Proxmox VM ID (must be unique)"
  type        = number
}

variable "vm_name" {
  description = "Hostname of the VM"
  type        = string
}

variable "proxmox_node" {
  description = "Proxmox node name (e.g. pve)"
  type        = string
  default     = "pve"
}

variable "admin_user" {
  description = "Admin user to create via cloud-init"
  type        = string
  default     = "ubuntu"
}

variable "ssh_pub_key" {
  description = "SSH public key content for cloud-init user"
  type        = string
  default     = ""
}

variable "memory_mb" {
  description = "RAM in MB"
  type        = number
  default     = 4096
}

variable "cpu_cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 2
}

variable "cpu_units" {
  description = "CPU weight (1024 = 1 share, masters=4096, workers=1024)"
  type        = number
  default     = 1024
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB"
  type        = number
  default     = 32
}

variable "data_disk_size_gb" {
  description = "Extra data disk size in GB (0 = no extra disk)"
  type        = number
  default     = 0
}

variable "network_mac" {
  description = "MAC address for network interface (auto-generated if blank)"
  type        = string
  default     = ""
}

variable "vm_storage" {
  description = "Storage pool for OS disk"
  type        = string
  default     = "local-zfs"
}

variable "data_storage" {
  description = "Storage pool for extra data disk"
  type        = string
  default     = "bulkpool"
}

variable "bridge" {
  description = "Bridge network name"
  type        = string
  default     = "vmbr0"
}

variable "vm_os_type" {
  description = "Proxmox OS type (l26 = Linux)"
  type        = string
  default     = "l26"
}

variable "vm_bios" {
  description = "BIOS type (ovmf = UEFI)"
  type        = string
  default     = "ovmf"
}

variable "vm_machine" {
  description = "QEMU machine type"
  type        = string
  default     = "q35"
}

variable "onboot" {
  description = "Start VM when Proxmox boots"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to the VM"
  type        = list(string)
  default     = []
}

variable "os_version" {
  description = "Ubuntu LTS version (e.g. 24.04). Used to identify the cloud-image."
  type        = string
  default     = "24.04"
}

variable "ssh_key_path" {
  description = "Local path to SSH private key for connecting to Proxmox"
  type        = string
  default     = "~/.ssh/pve-kai"
}

variable "proxmox_host" {
  description = "Proxmox hostname or IP"
  type        = string
  default     = "192.168.1.50"
}

variable "network_queues" {
  description = "Number of multi-queue pairs for the NIC (0 = auto, 4 is typical for k8s)"
  type        = number
  default     = 4
}

variable "efi_pre_enrolled_keys" {
  description = "Include Microsoft pre-enrolled secure boot keys in EFI image"
  type        = bool
  default     = true
}

variable "scsi_hardware" {
  description = "SCSI controller model (virtio-scsi-single or virtio-scsi-pci)"
  type        = string
  default     = "virtio-scsi-single"
}

variable "boot_order" {
  description = "Boot order (e.g. [\"scsi0\"]). Default excludes cloud-init ISO from boot."
  type        = list(string)
  default     = ["scsi0"]
}

variable "tofu_deploy_key" {
  description = "SSH public key content for infra-tofu-cloudinit CI access (optional)"
  type        = string
  default     = ""
}

# ── k3s cloud-init variables ──

variable "k3s_version" {
  description = "k3s version to install (e.g., v1.33.6+k3s1)"
  type        = string
  default     = "v1.33.6+k3s1"
}

variable "k3s_token" {
  description = "k3s cluster join token (from /var/lib/rancher/k3s/server/token on master)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "k3s_role" {
  description = "k3s role: 'server' for control plane, 'agent' for worker nodes"
  type        = string
  default     = "agent"
}

variable "static_ip" {
  description = "Static IP to assign to this node via k3s agent --node-ip"
  type        = string
  default     = ""
}

variable "k3s_join_server" {
  description = "IP of an existing k3s server to join. Safe default: master2 (192.168.1.202)."
  type        = string
  default     = "192.168.1.202"
}

variable "vm_started" {
  description = "Whether the VM should be running. false for net-new VMs, true for imported."
  type        = bool
  default     = true
}

variable "protect_vm" {
  description = "Prevent accidental VM destroy via tofu lifecycle. Set false to allow tofu destroy."
  type        = bool
  default     = false
}

# ── Node labels for k3s registration ──

variable "node_labels" {
  description = "Map of node labels to set via k3s --node-label flag (non-restricted domains only)"
  type        = map(string)
  default     = {}
}

variable "post_create_node_labels" {
  description = "Map of node labels to apply via kubectl after node joins (for restricted domains like node.kubernetes.io/*)"
  type        = map(string)
  default     = {}
}

# ── Non-k3s / standalone VM support ──

variable "k3s_enabled" {
  description = "Whether this VM is a k3s node. false = standalone VM."
  type        = bool
  default     = true
}

variable "cloud_init_template" {
  description = "Cloud-init template profile: master, worker, or base."
  type        = string
  default     = "worker"

  validation {
    condition     = contains(["master", "worker", "base"], var.cloud_init_template)
    error_message = "cloud_init_template must be one of: master, worker, base"
  }
}
