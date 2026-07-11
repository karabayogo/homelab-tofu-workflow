# ============================================================
# main.tf — Proxmox VM definitions (k8s cattle)
#
# ALL k8s cluster VMs declared here. Managed by OpenTofu
# with Garage S3 remote state. Reconciled by GitHub Actions.
#
# DO NOT EDIT MANUALLY — changes must go through tofu plan/apply.
# ============================================================

module "garage_s3" {
  source = "./modules/garage-s3"

  admin_endpoint     = "http://192.168.1.241:3900"
  admin_key_id       = var.garage_access_key
  admin_secret_key   = var.garage_secret_key
  bucket_name        = "terraform-state"
  terraform_key_name = "terraform-state-key"
}

terraform {
  # Backend is configured in backend.tf
  # Credentials via env vars: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ENDPOINT_URL_OVERRIDE
}

check "garage_bootstrap_prereqs" {
  assert {
    condition = (
      !var.enable_garage_cluster || (
        length(trimspace(var.vault_addr)) > 0 &&
        length(trimspace(var.vault_approle_role_id)) > 0 &&
        length(trimspace(var.vault_approle_secret_id)) > 0
      )
      ) && (
      !var.enable_migration_helper || (
        length(trimspace(var.vault_addr)) > 0 &&
        length(trimspace(var.vault_migration_approle_role_id)) > 0 &&
        length(trimspace(var.vault_migration_approle_secret_id)) > 0
      )
    )
    error_message = "Garage migration flags require vault_addr and role-specific AppRole credentials: garage-node vars for enable_garage_cluster, migration-helper vars for enable_migration_helper."
  }
}

resource "null_resource" "garage_bootstrap_guard" {
  count = (var.enable_garage_cluster || var.enable_migration_helper) ? 1 : 0

  triggers = {
    vault_addr = var.vault_addr
  }

  lifecycle {
    precondition {
      condition = (
        !var.enable_garage_cluster || (
          length(trimspace(var.vault_addr)) > 0 &&
          length(trimspace(var.vault_approle_role_id)) > 0 &&
          length(trimspace(var.vault_approle_secret_id)) > 0
        )
        ) && (
        !var.enable_migration_helper || (
          length(trimspace(var.vault_addr)) > 0 &&
          length(trimspace(var.vault_migration_approle_role_id)) > 0 &&
          length(trimspace(var.vault_migration_approle_secret_id)) > 0
        )
      )
      error_message = "Garage migration flags require vault_addr and role-specific AppRole credentials: garage-node vars for enable_garage_cluster, migration-helper vars for enable_migration_helper."
    }
  }
}

# ── K8s Master 2 (VM 500) — Primary server, other masters join here ──

module "k8s_master2" {
  source = "./modules/vm"

  vm_id             = 500
  vm_name           = "k8s-master2"
  memory_mb         = 8192
  cpu_cores         = 4
  cpu_units         = 4096
  os_disk_size_gb   = 80
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
  k3s_join_server   = "192.168.1.201" # joins master1 (bootstrap primary)
  vm_started        = true

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user      = "ubuntu"
  ssh_pub_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"
  tofu_deploy_key = ""

  # Longhorn node labels - declarative at IaC layer
  node_labels = {
    "node.longhorn.io/create-default-disk" = "true"
  }
  # No additional post-create Longhorn labels on control-plane nodes.
  # Capacity-tier labels are only declared for worker nodes with data disks.
  post_create_node_labels = {}

  protect_vm = true
}

# ── K8s Master 1 (VM 400) — Control plane, joins via master2 ──

module "k8s_master1" {
  source = "./modules/vm"

  vm_id             = 400
  vm_name           = "k8s-master1"
  memory_mb         = 8192
  cpu_cores         = 4
  cpu_units         = 4096
  os_disk_size_gb   = 80
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

  # Longhorn node labels - declarative at IaC layer
  node_labels = {
    "node.longhorn.io/create-default-disk" = "true"
  }
  # No additional post-create Longhorn labels on control-plane nodes.
  # Capacity-tier labels are only declared for worker nodes with data disks.
  post_create_node_labels = {}

  protect_vm = true
}

# ── K8s Master 3 (VM 600) — Control plane ──

module "k8s_master3" {
  source = "./modules/vm"

  vm_id             = 600
  vm_name           = "k8s-master3"
  memory_mb         = 8192
  cpu_cores         = 4
  cpu_units         = 4096
  os_disk_size_gb   = 80
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
  k3s_join_server   = "192.168.1.201" # joins master1 (bootstrap primary)
  vm_started        = true

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user      = "ubuntu"
  ssh_pub_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"
  tofu_deploy_key = ""

  # Longhorn node labels - declarative at IaC layer
  node_labels = {
    "node.longhorn.io/create-default-disk" = "true"
  }
  # No additional post-create Longhorn labels on control-plane nodes.
  # Capacity-tier labels are only declared for worker nodes with data disks.
  post_create_node_labels = {}

  protect_vm = true
}

# ── K8s Worker 1 (VM 700) ──

module "k8s_worker1" {
  source = "./modules/vm"

  vm_id             = 700
  vm_name           = "k8s-worker1"
  # Bumped from 4096 to 8192 on 2026-07-08.
  # Same OOM cascade as worker2 (June 29 RCA): 4GB is insufficient for
  # worker nodes running observability workloads (prometheus, grafana,
  # loki, alloy, longhorn CSI). OOM kills → kernel soft lockups →
  # containerd/PLEG death → node NotReady → stuck Terminating pods →
  # Longhorn PVC I/O errors → CrashLoopBackOff across multiple apps.
  memory_mb         = 8192
  cpu_cores         = 4
  cpu_units         = 1024
  os_disk_size_gb   = 80
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

  # Longhorn node labels - declarative at IaC layer
  node_labels = {
    "node.longhorn.io/create-default-disk" = "true"
  }
  post_create_node_labels = {
    "node.kubernetes.io/longhorn-storage" = "available"
  }

  protect_vm = true
}

# ── K8s Worker 2 (VM 800) ──

module "k8s_worker2" {
  source = "./modules/vm"

  vm_id             = 800
  vm_name           = "k8s-worker2"
  memory_mb         = 8192
  cpu_cores         = 4
  cpu_units         = 1024
  os_disk_size_gb   = 80
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

  # Longhorn node labels - declarative at IaC layer
  node_labels = {
    "node.longhorn.io/create-default-disk" = "true"
  }
  post_create_node_labels = {
    "node.kubernetes.io/longhorn-storage" = "available"
  }

  protect_vm = true
}

module "openclaw" {
  source = "./modules/vm"

  vm_id             = 252
  vm_name           = "openclaw"
  memory_mb         = 4096
  cpu_cores         = 2
  os_disk_size_gb   = 32
  data_disk_size_gb = 50
  vm_storage        = "local-zfs"
  data_storage      = "bulkpool"
  bridge            = "vmbr0"
  vm_os_type        = "l26"
  vm_bios           = "ovmf"
  vm_machine        = "q35"
  tags              = ["standalone"]
  os_version        = "24.04"
  static_ip         = "192.168.1.252"
  vm_started        = true

  admin_user  = "henesink"
  ssh_pub_key = file("${path.root}/ssh-keys/id_ed25519.pub")

  # Workload profile
  k3s_enabled         = false
  k3s_role            = "agent"
  cloud_init_template = "base"

  protect_vm = false
}

# ── Phase 2 Migration Helper VM (VM 904) ─────────────────────────────────
# Ephemeral VM used to sync data from old cluster (VM 900) to new cluster (901/902/903).
# Cloud-init fetches Vault AppRole credentials, writes /root/.config/rclone/rclone.conf,
# and provides migration scripts. Credentials are least-privilege and separated from Garage nodes.
# Lifecycle: toggled declaratively with enable_migration_helper:
#   false -> helper absent
#   true  -> helper present for Phase 2 sync window
#
# IMPORTANT: Set vault_migration_approle_role_id + vault_migration_approle_secret_id
# in terraform.tfvars before enabling this module.

module "migration_helper" {
  source = "./modules/vm"
  count  = var.enable_migration_helper ? 1 : 0

  vm_id             = 904
  vm_name           = "migration-helper"
  memory_mb         = 2048
  cpu_cores         = 2
  cpu_units         = 1024
  os_disk_size_gb   = 32
  data_disk_size_gb = 0 # No data disk needed — rclone streams data directly
  vm_storage        = "local-zfs"
  data_storage      = "bulkpool"
  bridge            = "vmbr0"
  vm_os_type        = "l26"
  vm_bios           = "ovmf"
  vm_machine        = "q35"
  tags              = ["migration", "ephemeral"]
  os_version        = "24.04"
  boot_order        = ["scsi0"]
  static_ip         = "192.168.1.244"
  vm_started        = var.start_migration_helper

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user  = "ubuntu"
  ssh_pub_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"

  # Standalone — no k3s, no garage, dedicated migration helper cloud-init
  k3s_enabled         = false
  cloud_init_template = "migration-helper"

  # Vault AppRole for fetching old/new S3 credentials during Phase 2
  vault_addr              = var.vault_addr
  vault_approle_role_id   = var.vault_migration_approle_role_id
  vault_approle_secret_id = var.vault_migration_approle_secret_id

  protect_vm = false # Ephemeral — can be destroyed without warning
}

# ── Garage S3 Storage Nodes (901/902/903) ──
# Three-node Garage v2.2.0 cluster with RF=3.
# All nodes use cloud_init_template = "garage" (dedicated Garage cloud-init, not base/worker/master).
# Real secrets never appear here — rpc_secret and admin_token are PLACEHOLDER values that get
# replaced at first boot via Vault AppRole fetch (see cloud-init-garage.yaml.tftpl).
# AppRole credentials (role_id + secret_id) are passed as variables — not the secrets themselves.
#
# IMPORTANT: Apply via phase flags and full plan/apply, not targeted apply.
# Garage bootstrap sequence after VM provisioning is:
#   1. start services on n1/n2/n3
#   2. connect peers from n1: garage node connect <nX-id>@<ip>:3901
#   3. assign capacity and apply layout: garage layout assign/config/apply
# Full step-by-step runbook: docs/plans/TODO/garage-cluster-migration/01-phase1-bootstrap.md

module "garage_n1" {
  source = "./modules/vm"
  count  = var.enable_garage_cluster ? 1 : 0

  vm_id             = 901
  vm_name           = "garage-n1"
  memory_mb         = 2048
  cpu_cores         = 2
  cpu_units         = 1024
  os_disk_size_gb   = 64
  data_disk_size_gb = 200
  vm_storage        = "local-zfs"
  data_storage      = "bulkpool"
  bridge            = "vmbr0"
  vm_os_type        = "l26"
  vm_bios           = "ovmf"
  vm_machine        = "q35"
  tags              = ["garage-s3", "garage-node"]
  os_version        = "24.04"
  boot_order        = ["scsi0"]
  static_ip         = "192.168.1.241"
  vm_started        = var.start_garage_nodes

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user  = "ubuntu"
  ssh_pub_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"

  # Standalone — no k3s, use garage cloud-init template
  k3s_enabled         = false
  cloud_init_template = "garage"

  # Garage version (must match across all three nodes)
  garage_version = "v2.2.0"

  # PLACEHOLDER values — replaced at boot via Vault AppRole (see cloud-init-garage.yaml.tftpl)
  # These placeholder strings are safe to commit to repo.
  # Real secrets are NEVER in Terraform state or cloud-init metadata.
  rpc_secret  = "PLACEHOLDER_RPC_SECRET"
  admin_token = "PLACEHOLDER_ADMIN_TOKEN"

  # Vault AppRole — used by cloud-init to authenticate and fetch real secrets from Vault
  # AppRole + cluster secret are GitOps-managed by the vault-approle-bootstrap ArgoCD app
  # (k8s-workbench: argocd/vault-approle-bootstrap/). A PostSync Job idempotently restores
  # the AppRole with the exact baked role-id + custom secret-id from a SOPS-encrypted seed.
  # A CronJob watchdog (garage-approle-watchdog) self-heals on drift hourly.
  # Do NOT create the AppRole manually — the GitOps bootstrap handles it.
  vault_addr              = var.vault_addr
  vault_approle_role_id   = var.vault_approle_role_id   # Set in terraform.tfvars
  vault_approle_secret_id = var.vault_approle_secret_id # Set in terraform.tfvars

  protect_vm = var.protect_garage_nodes
}

module "garage_n2" {
  source = "./modules/vm"
  count  = var.enable_garage_cluster ? 1 : 0

  vm_id             = 902
  vm_name           = "garage-n2"
  memory_mb         = 2048
  cpu_cores         = 2
  cpu_units         = 1024
  os_disk_size_gb   = 64
  data_disk_size_gb = 200
  vm_storage        = "local-zfs"
  data_storage      = "bulkpool"
  bridge            = "vmbr0"
  vm_os_type        = "l26"
  vm_bios           = "ovmf"
  vm_machine        = "q35"
  tags              = ["garage-s3", "garage-node"]
  os_version        = "24.04"
  boot_order        = ["scsi0"]
  static_ip         = "192.168.1.242"
  vm_started        = var.start_garage_nodes

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user  = "ubuntu"
  ssh_pub_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"

  k3s_enabled         = false
  cloud_init_template = "garage"

  garage_version = "v2.2.0"
  rpc_secret     = "PLACEHOLDER_RPC_SECRET"
  admin_token    = "PLACEHOLDER_ADMIN_TOKEN"

  vault_addr              = var.vault_addr
  vault_approle_role_id   = var.vault_approle_role_id
  vault_approle_secret_id = var.vault_approle_secret_id

  protect_vm = var.protect_garage_nodes
}

module "garage_n3" {
  source = "./modules/vm"
  count  = var.enable_garage_cluster ? 1 : 0

  vm_id             = 903
  vm_name           = "garage-n3"
  memory_mb         = 2048
  cpu_cores         = 2
  cpu_units         = 1024
  os_disk_size_gb   = 64
  data_disk_size_gb = 200
  vm_storage        = "local-zfs"
  data_storage      = "bulkpool"
  bridge            = "vmbr0"
  vm_os_type        = "l26"
  vm_bios           = "ovmf"
  vm_machine        = "q35"
  tags              = ["garage-s3", "garage-node"]
  os_version        = "24.04"
  boot_order        = ["scsi0"]
  static_ip         = "192.168.1.243"
  vm_started        = var.start_garage_nodes

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user  = "ubuntu"
  ssh_pub_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"

  k3s_enabled         = false
  cloud_init_template = "garage"

  garage_version = "v2.2.0"
  rpc_secret     = "PLACEHOLDER_RPC_SECRET"
  admin_token    = "PLACEHOLDER_ADMIN_TOKEN"

  vault_addr              = var.vault_addr
  vault_approle_role_id   = var.vault_approle_role_id
  vault_approle_secret_id = var.vault_approle_secret_id

  protect_vm = var.protect_garage_nodes
}
