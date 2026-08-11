# ============================================================
# main.tf — Proxmox VM definitions (k8s cattle)
#
# ALL k8s cluster VMs declared here. Managed by OpenTofu
# with an S3-compatible remote state backend. Reconciled by GitHub Actions.
#
# DO NOT EDIT MANUALLY — changes must go through tofu plan/apply.
# ============================================================

module "garage_s3" {
  source = "./modules/garage-s3"

  admin_endpoint     = "http://192.168.1.242:3900"
  admin_key_id       = var.garage_access_key
  admin_secret_key   = var.garage_secret_key
  bucket_name        = "terraform-state"
  terraform_key_name = "terraform-state-key"
}

terraform {
  # Backend is configured in backend.tf
  # Runtime endpoint/credentials are injected at init time by GitHub Actions
  # or local operator commands via -backend-config.
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

# Strategic PVE storage contract (2026-07-28 RCA): bulkpool must be thin
# provisioned. Thick-provisioned ZFS zvols (`refreservation=<volsize>`) made
# PVE report only ~74 MiB free even while `zpool list` still had >1 TiB free,
# which blocked Garage disk expansion and let Longhorn backups age out. Manage
# the storage definition declaratively so future disks inherit sparse zvols.
resource "proxmox_storage_zfspool" "bulkpool" {
  id    = "bulkpool"
  nodes = ["pve"]

  zfs_pool       = "bulkpool"
  content        = ["images", "rootdir"]
  thin_provision = true
}

# Strategic host-side storage split after the 2026-08-09 PVE zvol hang RCA:
# keep bulkpool as the capacity tier, but expose a file-backed directory storage
# on top of the same pool for management-plane / standalone VM data disks.
#
# Why: the incident signatures were in the ZFS zvol event path
# (`zvol_check_events`, `txg_wait_synced`, `systemd-udevd` watchdog), so the
# durable direction is to shrink the blast radius of zvol-backed guest disks
# instead of letting every non-root data disk ride the same zvol code path.
#
# We keep the workers' Longhorn replica disks and the large Garage capacity tier
# on explicit zvol-backed bulkpool for now, but move small management-plane data
# disks to file-backed images. That is a strategic reduction in host-side zvol
# pressure without forcing an all-at-once migration of every high-capacity disk.
resource "null_resource" "bulkpool_dir_path" {
  triggers = {
    proxmox_host = "192.168.1.50"
    ssh_key_path = "/home/moltbot/.ssh/pve-kai"
    path         = "/bulkpool/proxmox-dir"
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh -o BatchMode=yes -o ConnectTimeout=10 -i "${self.triggers.ssh_key_path}" "root@${self.triggers.proxmox_host}" \
        "install -d -m 0755 '${self.triggers.path}'"
    EOT
  }
}

resource "proxmox_storage_directory" "bulkpool_dir" {
  id    = "bulkpool-dir"
  nodes = ["pve"]

  path    = "/bulkpool/proxmox-dir"
  content = ["images"]

  depends_on = [null_resource.bulkpool_dir_path]
}

locals {
  k3s_api_vip        = var.k3s_api_vip
  legacy_vm_contract = jsondecode(file("${path.root}/../contracts/legacy-vm-contracts.json"))
  legacy_vm_reserved_memory_mb = sum([
    for vm in values(local.legacy_vm_contract.vms) : tonumber(vm.memory_mb)
  ])

  # Strategic guardrail after the 2026-07-15 PVE hang RCA:
  # keep an explicit budget for the single-host control plane instead of
  # letting GitOps silently reserve all RAM and push the hypervisor into swap.
  #
  # 2026-07-21 RCA: the budget was at 100% (63488/63488) because it only
  # counted garage/migration VMs when start_*_nodes=true. But the VMs were
  # provisioned (enable_*=true) and running, consuming 6 GiB the budget
  # didn't see. Now we count ALL provisioned VMs (enable_*) plus a mandatory
  # headroom (pve_memory_headroom_mb) so CI fails before host overcommit.
  #
  # VM 201 is still legacy/manual today, so it is accounted for via
  # legacy-vm-contracts.json until it is onboarded as full Terraform cattle.
  pve_managed_running_vm_memory_mb = (
    4096 + # k8s-master2
    4096 + # k8s-master1
    4096 + # k8s-master3
    6144 + # k8s-worker1
    6144 + # k8s-worker2
    3072 + # home-assistant-os
    2048 + # openclaw (reduced 3→2 GiB, 2026-07-21 RCA)
    2048 + # backup-pbs1 (reduced 4→2 GiB, 2026-07-21 RCA)
    1024 + # tofu-state1
    # Count provisioned VMs, not just "should be started" — they can be
    # started at any time and the host must handle the memory.
    (var.enable_migration_helper ? 2048 : 0) +
    (var.enable_garage_cluster ? 2048 : 0) +
    (var.enable_garage_cluster ? 2048 : 0) +
    (var.enable_garage_cluster ? 2048 : 0)
  )
}

check "pve_host_memory_budget" {
  assert {
    condition = (
      local.pve_managed_running_vm_memory_mb +
      local.legacy_vm_reserved_memory_mb +
      var.pve_host_reserved_memory_mb +
      var.pve_memory_headroom_mb
    ) <= var.pve_host_total_memory_mb
    error_message = format(
      "PVE RAM budget exceeded (including %d MiB required headroom): managed=%d MiB unmanaged=%d MiB host-reserve=%d MiB headroom=%d MiB total=%d MiB. Reduce VM memory, start fewer optional VMs, or onboard/right-size legacy VMs before applying.",
      var.pve_memory_headroom_mb,
      local.pve_managed_running_vm_memory_mb,
      local.legacy_vm_reserved_memory_mb,
      var.pve_host_reserved_memory_mb,
      var.pve_memory_headroom_mb,
      var.pve_host_total_memory_mb,
    )
  }
}

# ── K8s Master 2 (VM 500) — Bootstrap server for the HA API VIP ──

module "k8s_master2" {
  source = "./modules/vm"

  vm_id   = 500
  vm_name = "k8s-master2"
  # Right-sized after the 2026-07-15 host-memory RCA.
  # Observed steady-state guest usage was ~2.1 GiB with >5 GiB available,
  # so 4 GiB preserves control-plane headroom without forcing the PVE host
  # into chronic swap pressure.
  memory_mb             = 4096
  cpu_cores             = 4
  cpu_units             = 4096
  os_disk_size_gb       = 80
  data_disk_size_gb     = 0
  vm_storage            = "local-zfs"
  data_storage          = "bulkpool"
  bridge                = "vmbr0"
  vm_os_type            = "l26"
  vm_bios               = "ovmf"
  vm_machine            = "q35"
  tags                  = ["k8s-master"]
  os_version            = "24.04"
  boot_order            = ["scsi0"]
  network_mac           = "BC:24:11:99:2E:79"
  static_ip             = "192.168.1.202"
  k3s_token             = var.k3s_token
  k3s_role              = "server"
  k3s_cluster_init      = true
  k3s_api_vip           = local.k3s_api_vip
  k3s_api_vip_interface = var.k3s_api_vip_interface
  kube_vip_version      = var.kube_vip_version
  vm_started            = true

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user      = "ubuntu"
  ssh_pub_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"
  tofu_deploy_key = ""

  # Longhorn node labels - declarative at IaC layer.
  # Control-plane protection policy: master1/master2 stay excluded from Longhorn
  # replica placement so etcd and apiserver capacity remains reserved for cluster
  # control-plane duties. The third storage failure domain is provided by an
  # explicit opt-in on master3 until a dedicated third worker exists.
  node_labels = {
    "node.longhorn.io/evicted"             = "true"
    "node.longhorn.io/create-default-disk" = "false"
  }
  # No additional post-create Longhorn labels on protected control-plane nodes.
  post_create_node_labels = {}

  protect_vm = true
}

# ── K8s Master 1 (VM 400) — Control plane, joins through the HA API VIP ──

module "k8s_master1" {
  source = "./modules/vm"

  vm_id   = 400
  vm_name = "k8s-master1"
  # Right-sized after the 2026-07-15 host-memory RCA.
  # Observed steady-state guest usage was ~2.7 GiB with ~5 GiB available,
  # so 4 GiB preserves control-plane headroom without forcing the PVE host
  # into chronic swap pressure.
  memory_mb             = 4096
  cpu_cores             = 4
  cpu_units             = 4096
  os_disk_size_gb       = 80
  data_disk_size_gb     = 0
  vm_storage            = "local-zfs"
  data_storage          = "bulkpool"
  bridge                = "vmbr0"
  vm_os_type            = "l26"
  vm_bios               = "ovmf"
  vm_machine            = "q35"
  tags                  = ["k8s-master"]
  os_version            = "24.04"
  boot_order            = ["scsi0"]
  network_mac           = "BC:24:11:03:3C:33"
  static_ip             = "192.168.1.201"
  k3s_token             = var.k3s_token
  k3s_role              = "server"
  k3s_join_server       = local.k3s_api_vip
  k3s_api_vip           = local.k3s_api_vip
  k3s_api_vip_interface = var.k3s_api_vip_interface
  kube_vip_version      = var.kube_vip_version
  vm_started            = true

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user      = "ubuntu"
  ssh_pub_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"
  tofu_deploy_key = ""

  # Longhorn node labels - declarative at IaC layer.
  # Control-plane protection policy: master1/master2 stay excluded from Longhorn
  # replica placement so etcd and apiserver capacity remains reserved for cluster
  # control-plane duties. The third storage failure domain is provided by an
  # explicit opt-in on master3 until a dedicated third worker exists.
  node_labels = {
    "node.longhorn.io/evicted"             = "true"
    "node.longhorn.io/create-default-disk" = "false"
  }
  # No additional post-create Longhorn labels on protected control-plane nodes.
  post_create_node_labels = {}

  protect_vm = true
}

# ── K8s Master 3 (VM 600) — Control plane, joins through the HA API VIP ──

module "k8s_master3" {
  source = "./modules/vm"

  vm_id   = 600
  vm_name = "k8s-master3"
  # Right-sized after the 2026-07-15 host-memory RCA.
  # Observed steady-state guest usage was ~2.0 GiB with ~5.7 GiB available,
  # so 4 GiB preserves control-plane headroom without forcing the PVE host
  # into chronic swap pressure.
  memory_mb             = 4096
  cpu_cores             = 4
  cpu_units             = 4096
  os_disk_size_gb       = 80
  data_disk_size_gb     = 0
  vm_storage            = "local-zfs"
  data_storage          = "bulkpool"
  bridge                = "vmbr0"
  vm_os_type            = "l26"
  vm_bios               = "ovmf"
  vm_machine            = "q35"
  tags                  = ["k8s-master"]
  os_version            = "24.04"
  boot_order            = ["scsi0"]
  network_mac           = "BC:24:11:D6:6C:25"
  static_ip             = "192.168.1.203"
  k3s_token             = var.k3s_token
  k3s_role              = "server"
  k3s_join_server       = local.k3s_api_vip
  k3s_api_vip           = local.k3s_api_vip
  k3s_api_vip_interface = var.k3s_api_vip_interface
  kube_vip_version      = var.kube_vip_version
  vm_started            = true

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user      = "ubuntu"
  ssh_pub_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"
  tofu_deploy_key = ""

  # Longhorn node labels - declarative at IaC layer.
  # Strategic posture after the 2026-07-19 Longhorn/control-plane RCA:
  # master3 is no longer a replica fallback. A third Longhorn replica requires
  # a third dedicated worker/storage VM, not control-plane storage I/O.
  node_labels = {
    "node.longhorn.io/evicted"             = "true"
    "node.longhorn.io/create-default-disk" = "false"
  }
  # No additional post-create Longhorn labels on protected control-plane nodes.
  post_create_node_labels = {}

  protect_vm = true
}

# ── K8s Worker 1 (VM 700) ──

module "k8s_worker1" {
  source = "./modules/vm"

  vm_id   = 700
  vm_name = "k8s-worker1"
  # Right-sized after the 2026-07-15 host-memory RCA.
  # 4 GiB proved too small during the June 29 worker OOM incident, but the
  # 8 GiB fixed reservation materially contributed to host swap pressure.
  # Observed steady-state guest usage was ~3.3 GiB with ~4.5 GiB available,
  # so 6 GiB keeps real workload headroom while reducing PVE overcommit.
  memory_mb         = 6144
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
  k3s_join_server   = local.k3s_api_vip
  k3s_api_vip       = local.k3s_api_vip
  vm_started        = true

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user      = "ubuntu"
  ssh_pub_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"
  tofu_deploy_key = ""

  # Longhorn node labels - declarative at IaC layer.
  # Strategic policy: workers provide one true Longhorn replica failure domain each.
  # The additional data disk is the intended replica disk; the node-taint-enforcer
  # reconciles the Longhorn node CR so the OS disk is not used as a second faux replica.
  node_labels = {
    "node.longhorn.io/create-default-disk"           = "true"
    "storage.k8s.workbench.io/longhorn-primary-disk" = "longhorn-additional"
  }
  post_create_node_labels = {
    "node.kubernetes.io/longhorn-storage" = "available"
  }

  protect_vm = true
}

# ── K8s Worker 2 (VM 800) ──

module "k8s_worker2" {
  source = "./modules/vm"

  vm_id   = 800
  vm_name = "k8s-worker2"
  # Right-sized after the 2026-07-15 host-memory RCA.
  # Observed steady-state guest usage was ~2.2 GiB with ~5.6 GiB available,
  # so 6 GiB keeps parity with worker1 and avoids another 8 GiB fixed host
  # reservation on a single-node PVE box.
  memory_mb         = 6144
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
  k3s_join_server   = local.k3s_api_vip
  k3s_api_vip       = local.k3s_api_vip
  vm_started        = true

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  admin_user      = "ubuntu"
  ssh_pub_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"
  tofu_deploy_key = ""

  # Longhorn node labels - declarative at IaC layer.
  # Strategic policy: workers provide one true Longhorn replica failure domain each.
  # The additional data disk is the intended replica disk; the node-taint-enforcer
  # reconciles the Longhorn node CR so the OS disk is not used as a second faux replica.
  node_labels = {
    "node.longhorn.io/create-default-disk"           = "true"
    "storage.k8s.workbench.io/longhorn-primary-disk" = "longhorn-additional"
  }
  post_create_node_labels = {
    "node.kubernetes.io/longhorn-storage" = "available"
  }

  protect_vm = true
}

module "openclaw" {
  source = "./modules/vm"

  vm_id   = 252
  vm_name = "openclaw"
  # 2026-08-04 disk-capacity RCA: 32 GiB OS disk was too small for the
  # combined OpenClaw toolchain footprint (`/var/lib/containerd` + Docker +
  # VS Code server caches + linuxbrew/home state). The watchdog showed 94%
  # rootfs usage even after safe journal cleanup, which means capacity — not
  # just cache drift — became the limiting factor. Keep RAM right-sized at
  # 2 GiB, but raise the OS disk so the management-plane/runtime caches stop
  # sharing the same tiny failure domain.
  memory_mb         = 2048
  cpu_cores         = 2
  os_disk_size_gb   = 64
  data_disk_size_gb = 50
  vm_storage        = "local-zfs"
  # Strategic 2026-08-09 RCA: keep management-plane data disks off the ZFS zvol
  # event path where possible. Use file-backed bulkpool-dir instead of a bulkpool
  # zvol for standalone runtime state.
  data_storage = "bulkpool-dir"
  bridge       = "vmbr0"
  vm_os_type   = "l26"
  vm_bios      = "ovmf"
  vm_machine   = "q35"
  tags         = ["standalone"]
  os_version   = "24.04"
  static_ip    = "192.168.1.252"
  vm_started   = true

  admin_user  = "henesink"
  ssh_pub_key = file("${path.root}/ssh-keys/id_ed25519.pub")

  # Workload profile
  k3s_enabled         = false
  k3s_role            = "agent"
  cloud_init_template = "base"

  protect_vm = false
}

# ── Home Assistant OS appliance (VM 300) ───────────────────────────────────
# Strategic 2026-08-11 fix:
#   - make the appliance itself cattle at the Proxmox contract layer instead of
#     leaving it as an unmanaged/manual headroom entry
#   - keep the current 3 GiB RAM reservation because the PVE host is already
#     right on the host-pressure threshold; the durable protection for the
#     actual incident is a Git-managed HAOS automation-path watchdog that
#     detects the exact sensor->automation stall and auto-heals with a reboot
#   - disable cloud-init because HAOS is an imported appliance image, not a
#     cloud-image guest
module "home_assistant_os" {
  source = "./modules/vm"

  vm_id      = 300
  vm_name    = "home-assistant-os"
  memory_mb  = 3072
  cpu_cores  = 4
  vm_storage = "local-zfs"
  bridge     = "vmbr0"
  vm_os_type = "l26"
  vm_bios    = "ovmf"
  vm_machine = "q35"
  tags       = ["standalone", "appliance", "home-assistant"]
  vm_started = true
  onboot     = true

  os_disk_size_gb       = 32
  os_disk_ssd           = false
  network_mac           = "BC:24:11:93:64:45"
  network_queues        = 0
  efi_pre_enrolled_keys = false
  static_ip             = "192.168.1.199"

  proxmox_host = "192.168.1.50"
  ssh_key_path = "/home/moltbot/.ssh/pve-kai"
  proxmox_node = "pve"

  k3s_enabled           = false
  cloud_init_enabled    = false
  serial_device_enabled = false

  protect_vm = true
}

# ── Same-host PBS restore tier (VM 905) ──────────────────────────────────
# Strategic intent:
#   - local restore UX via PBS
#   - no Synology/NFS mount in the Proxmox management plane
#   - use VM201 as a Git-managed off-host bridge that mirrors the latest
#     management-plane PBS snapshots + required chunks + config to Synology,
#     so DR follows the current backup source of truth instead of stale
#     pre-PBS dump artifacts
#   - boot automatically because the host-side RAM reservations were
#     right-sized after the 2026-07-15 memory-pressure RCA
module "backup_pbs1" {
  source = "./modules/vm"

  vm_id   = 905
  vm_name = "backup-pbs1"
  # Right-sized after the 2026-07-21 PVE host-memory RCA.
  # Observed steady-state guest usage was ~450 MiB with 3.45 GiB available
  # at 4 GiB. PBS is idle most of the time (only active during backup
  # windows). Reduced from 4 GiB to 2 GiB to free 2 GiB of PVE host
  # headroom. 2 GiB leaves ~1.5 GiB above observed usage, sufficient
  # for backup window spikes.
  memory_mb         = 2048
  cpu_cores         = 2
  cpu_units         = 2048
  os_disk_size_gb   = 32
  data_disk_size_gb = 500
  vm_storage        = "local-zfs"
  # 2026-08-09 explicit maintenance migration completed: PBS now lives on the
  # file-backed bulkpool-dir tier alongside the other management-plane disks.
  # This keeps the restore tier off the zvol event path implicated in the host
  # stall RCA while preserving bulkpool itself as the high-capacity backing pool.
  data_storage = "bulkpool-dir"
  bridge       = "vmbr0"
  vm_os_type   = "l26"
  vm_bios      = "ovmf"
  vm_machine   = "q35"
  tags         = ["backup", "pbs"]
  os_version   = "13"
  # 2026-07-17 RCA: .245 had a live duplicate-IP conflict on the LAN.
  # Move PBS to a collision-free address and keep the desired endpoint in Git.
  static_ip  = "192.168.1.247"
  vm_started = true
  onboot     = true

  proxmox_host       = "192.168.1.50"
  ssh_key_path       = "/home/moltbot/.ssh/pve-kai"
  proxmox_node       = "pve"
  cloud_image_family = "debian"

  admin_user  = "ubuntu"
  ssh_pub_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"

  k3s_enabled         = false
  cloud_init_template = "pbs"

  protect_vm = true
}

# ── Dedicated state backend VM (VM 906) ──────────────────────────────────
# Strategic intent:
#   - break the circular dependency between OpenTofu state and the Garage cluster
#   - keep state on a small, dedicated management-plane VM instead of a workload S3 tier
#   - keep backend state available even when the Garage workload cluster is degraded
module "tofu_state1" {
  source = "./modules/vm"

  vm_id             = 906
  vm_name           = "tofu-state1"
  memory_mb         = 1024
  cpu_cores         = 1
  cpu_units         = 512
  os_disk_size_gb   = 16
  data_disk_size_gb = 32
  vm_storage        = "local-zfs"
  # Strategic 2026-08-09 RCA: keep the Terraform state backend on file-backed
  # storage so control-plane state is not another bulkpool zvol guest.
  data_storage = "bulkpool-dir"
  bridge       = "vmbr0"
  vm_os_type   = "l26"
  vm_bios      = "ovmf"
  vm_machine   = "q35"
  tags         = ["control-plane", "state-backend"]
  os_version   = "13"
  static_ip    = "192.168.1.246"
  vm_started   = true
  onboot       = true

  proxmox_host       = "192.168.1.50"
  ssh_key_path       = "/home/moltbot/.ssh/pve-kai"
  proxmox_node       = "pve"
  cloud_image_family = "debian"

  admin_user  = "ubuntu"
  ssh_pub_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABcqqosImBbChMBDBgLkt8KRF4MfVQc7uE6ExLHuGXu kai@moltbot"

  k3s_enabled          = false
  cloud_init_template  = "state-s3"
  state_s3_access_key  = var.state_backend_access_key
  state_s3_secret_key  = var.state_backend_secret_key
  state_s3_bucket_name = "terraform-state"

  protect_vm = true
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

  vm_id   = 901
  vm_name = "garage-n1"
  # Right-sized after the 2026-07-15 PVE memory-pressure RCA.
  # Strategic capacity bump (2026-08-04 RCA): Loki + Longhorn share Garage, and
  # unbounded Loki object growth exhausted n1/n2 again even after the 400G July
  # expansion. Move all three nodes to 600G so the cluster has durable headroom
  # while GitOps retention deletes old Loki chunks and while historical data
  # placement gradually evens out.
  memory_mb         = 2048
  cpu_cores         = 2
  cpu_units         = 1024
  os_disk_size_gb   = 64
  data_disk_size_gb = 600
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

  vm_id   = 902
  vm_name = "garage-n2"
  # Strategic capacity bump (2026-08-04 RCA): keep n2 at parity with n1/n3 and
  # raise the shared Garage floor to 600G so RF=3 writes keep headroom during
  # retention-compaction lag and historical-placement skew.
  memory_mb         = 2048
  cpu_cores         = 2
  cpu_units         = 1024
  os_disk_size_gb   = 64
  data_disk_size_gb = 600
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

  vm_id   = 903
  vm_name = "garage-n3"
  # Right-sized after the 2026-07-15 PVE memory-pressure RCA.
  # Strategic capacity bump (2026-08-04 RCA): keep n3 at parity with n1/n2 at
  # 600G so new writes are not capacity-pinned while old data ages out.
  memory_mb         = 2048
  cpu_cores         = 2
  cpu_units         = 1024
  os_disk_size_gb   = 64
  data_disk_size_gb = 600
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
