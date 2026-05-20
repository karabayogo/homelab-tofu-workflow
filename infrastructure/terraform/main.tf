# ============================================================
# main.tf — Proxmox VM definitions (k8s cattle)
#
# ALL k8s cluster VMs declared here. Managed by OpenTofu
# with Garage S3 remote state. Reconciled by GitHub Actions.
#
# DO NOT EDIT MANUALLY — changes must go through tofu plan/apply.
# ============================================================

terraform {
  backend "s3" {
    endpoint                    = "http://192.168.1.230:3900"
    region                      = "us-east-1"
    bucket                      = "terraform-state"
    key                         = "homelab-tofu-workflow/terraform.tfstate"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    use_path_style              = true
  }
}

# ── K8s Master 2 (VM 500) — Primary server, other masters join here ──

module "k8s_master2" {
  source = "./modules/vm"

  vm_id             = 500
  vm_name           = "k8s-master2"
  memory_mb         = 3072
  cpu_cores         = 4
  cpu_units         = 4096
  os_disk_size_gb   = 32
  data_disk_size_gb = 0
  vm_storage        = "local-zfs"
  data_storage      = "bulkpool"
  bridge            = "vmbr0"
  vm_os_type        = "l26"
  vm_bios           = "ovmf"
  vm_machine        = "q35"
  tags              = ["k8s-master"]
  os_version        = "24.04"
  boot_order        = ["scsi0"]
  network_mac       = "BC:24:11:99:2E:79"
  static_ip         = "192.168.1.202"
  k3s_token         = var.k3s_token
  k3s_role          = "server"
  vm_started        = true

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user      = "ubuntu"
  ssh_pub_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"
  tofu_deploy_key = ""

  protect_vm = true
}

# ── K8s Master 1 (VM 400) — Control plane, joins via master2 ──

module "k8s_master1" {
  source = "./modules/vm"

  vm_id             = 400
  vm_name           = "k8s-master1"
  memory_mb         = 3072
  cpu_cores         = 4
  cpu_units         = 4096
  os_disk_size_gb   = 32
  data_disk_size_gb = 0
  vm_storage        = "local-zfs"
  data_storage      = "bulkpool"
  bridge            = "vmbr0"
  vm_os_type        = "l26"
  vm_bios           = "ovmf"
  vm_machine        = "q35"
  tags              = ["k8s-master"]
  os_version        = "24.04"
  boot_order        = ["scsi0"]
  network_mac       = "BC:24:11:03:3C:33"
  static_ip         = "192.168.1.201"
  k3s_token         = var.k3s_token
  k3s_role          = "server"
  k3s_join_server   = "192.168.1.202"
  vm_started        = true

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user      = "ubuntu"
  ssh_pub_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"
  tofu_deploy_key = ""

  protect_vm = true
}

# ── K8s Master 3 (VM 600) — Control plane ──

module "k8s_master3" {
  source = "./modules/vm"

  vm_id             = 600
  vm_name           = "k8s-master3"
  memory_mb         = 3072
  cpu_cores         = 4
  cpu_units         = 4096
  os_disk_size_gb   = 32
  data_disk_size_gb = 0
  vm_storage        = "local-zfs"
  data_storage      = "bulkpool"
  bridge            = "vmbr0"
  vm_os_type        = "l26"
  vm_bios           = "ovmf"
  vm_machine        = "q35"
  tags              = ["k8s-master"]
  os_version        = "24.04"
  boot_order        = ["scsi0"]
  network_mac       = "BC:24:11:D6:6C:25"
  static_ip         = "192.168.1.203"
  k3s_token         = var.k3s_token
  k3s_role          = "server"
  vm_started        = true

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user      = "ubuntu"
  ssh_pub_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"
  tofu_deploy_key = ""

  protect_vm = true
}

# ── K8s Worker 1 (VM 700) ──

module "k8s_worker1" {
  source = "./modules/vm"

  vm_id             = 700
  vm_name           = "k8s-worker1"
  memory_mb         = 4096
  cpu_cores         = 4
  cpu_units         = 1024
  os_disk_size_gb   = 32
  data_disk_size_gb = 150
  vm_storage        = "local-zfs"
  data_storage      = "bulkpool"
  bridge            = "vmbr0"
  vm_os_type        = "l26"
  vm_bios           = "ovmf"
  vm_machine        = "q35"
  tags              = ["k8s-worker"]
  os_version        = "24.04"
  boot_order        = ["scsi0"]
  network_mac       = "BC:24:11:3D:3C:72"
  static_ip         = "192.168.1.204"
  k3s_token         = var.k3s_token
  k3s_role          = "agent"
  vm_started        = true

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user      = "ubuntu"
  ssh_pub_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"
  tofu_deploy_key = ""

  protect_vm = true
}

# ── K8s Worker 2 (VM 800) ──

module "k8s_worker2" {
  source = "./modules/vm"

  vm_id             = 800
  vm_name           = "k8s-worker2"
  memory_mb         = 4096
  cpu_cores         = 4
  cpu_units         = 1024
  os_disk_size_gb   = 32
  data_disk_size_gb = 100
  vm_storage        = "local-zfs"
  data_storage      = "bulkpool"
  bridge            = "vmbr0"
  vm_os_type        = "l26"
  vm_bios           = "ovmf"
  vm_machine        = "q35"
  tags              = ["k8s-worker"]
  os_version        = "24.04"
  boot_order        = ["scsi0"]
  network_mac       = "BC:24:11:73:7C:22"
  static_ip         = "192.168.1.205"
  k3s_token         = var.k3s_token
  k3s_role          = "agent"
  vm_started        = true

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user      = "ubuntu"
  ssh_pub_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"
  tofu_deploy_key = ""

  protect_vm = true
}
