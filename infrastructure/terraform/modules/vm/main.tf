# ============================================================
# modules/vm/main.tf — Proxmox VM (bpg/proxmox v0.101+)
#
# Provisioning: Cloud-image boot (Mode A)
#   Writes the Ubuntu cloud-image to the OS disk via SSH to Proxmox.
#   Cloud-init runs on first boot via the initialization block.
#
# TWO-STEP CREATE (for net-new VMs):
#   1. Apply with started=false — provisioner writes cloud-image to stopped VM
#   2. Apply with started=true  — syncs state, agent check
#
# For IMPORTED VMs: set started=true, provisioner is a no-op (disk already exists).
# ============================================================

# ── Cloud-init snippet: rendered from template, uploaded to Proxmox ──
resource "proxmox_virtual_environment_file" "cloud_init_snippet" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data = templatefile(
      var.k3s_enabled
        ? (
          var.cloud_init_template == "base"
          ? "${path.module}/templates/cloud-init-base.yaml.tftpl"
          : "${path.module}/templates/cloud-init-${var.k3s_role == "server" ? "master" : "worker"}.yaml.tftpl"
        )
        : "${path.module}/templates/cloud-init-base.yaml.tftpl",
      {
        hostname          = var.vm_name
        ssh_pub_key       = var.ssh_pub_key
        tofu_deploy_key   = var.tofu_deploy_key
        k3s_version       = var.k3s_version
        k3s_token         = var.k3s_token
        static_ip         = var.static_ip
        k3s_join_server   = var.k3s_join_server
        node_labels_args  = local.node_labels_args
        data_disk_size_gb = var.data_disk_size_gb
        admin_user        = var.admin_user
      }
    )
    file_name = "cloudinit-${var.vm_name}.yaml"
  }
}

# ── Locals: Node label helpers ──
locals {
  node_labels_args           = length(var.node_labels) > 0 ? join(" ", [for k, v in var.node_labels : " --node-label ${k}=${v}"]) : ""
  post_create_label_commands = length(var.post_create_node_labels) > 0 ? join("\n      ", [for k, v in var.post_create_node_labels : "kubectl label node \"$node_name\" ${k}=${v} --overwrite"]) : ""
}

# ── VM resource ──
resource "proxmox_virtual_environment_vm" "this" {
  count     = 1
  name      = var.vm_name
  node_name = var.proxmox_node
  vm_id     = var.vm_id
  bios      = var.vm_bios
  machine   = var.vm_machine
  tags      = var.tags

  cpu {
    cores = var.cpu_cores
    type  = "host"
    units = var.cpu_units
  }

  memory {
    dedicated = var.memory_mb
  }

  operating_system {
    type = var.vm_os_type
  }

  efi_disk {
    datastore_id      = var.vm_storage
    type              = "4m"
    pre_enrolled_keys = var.efi_pre_enrolled_keys
  }

  disk {
    datastore_id = var.vm_storage
    interface    = "scsi0"
    size         = var.os_disk_size_gb
    discard      = "on"
    iothread     = var.vm_machine == "q35" ? true : false
  }

  dynamic "disk" {
    for_each = var.data_disk_size_gb > 0 ? [1] : []
    content {
      datastore_id = var.data_storage
      interface    = "scsi1"
      size         = var.data_disk_size_gb
    }
  }

  network_device {
    bridge      = var.bridge
    model       = "virtio"
    mac_address = var.network_mac
    queues      = var.network_queues
  }

  boot_order    = var.boot_order
  on_boot       = var.onboot
  scsi_hardware = var.scsi_hardware

  serial_device {
    device = "socket"
  }

  initialization {
    datastore_id      = var.vm_storage
    interface         = "ide2"
    upgrade           = false
    user_data_file_id = proxmox_virtual_environment_file.cloud_init_snippet.id

    ip_config {
      ipv4 {
        address = "${var.static_ip}/24"
        gateway = "192.168.1.1"
      }
    }

    user_account {
      keys = concat(
        var.ssh_pub_key != "" ? [var.ssh_pub_key] : [],
        var.tofu_deploy_key != "" ? [var.tofu_deploy_key] : [],
      )
      username = var.admin_user
    }
  }

  agent {
    enabled = true
    timeout = "15m"
  }

  started = var.vm_started

  # ── Cloud-image provisioner ──
  # Runs ONLY on resource CREATE. Writes the OS image to the stopped VM's disk.
  # For imported VMs this is a no-op (disk already has the OS image).
  provisioner "local-exec" {
    command = "${path.module}/scripts/vm-provisioner.sh ${self.vm_id} ${var.vm_name} ${var.os_version} ${var.proxmox_host} ${var.ssh_key_path}"
  }

  lifecycle {
    # All attributes that should never trigger a plan change:
    # - initialization: PVE computes this from VM config; differs from HCL defaults on import
    # - ipv4_addresses, ipv6_addresses, network_interface_names: provider-computed read-only
    # The bpg/proxmox provider does not respect ignore_changes for these provider-computed
    # attributes (they show as "known after apply" in plan output), but including them here
    # silences tofu's redundant-ignore_changes warning and documents intent.
    ignore_changes = [
      initialization,
      ipv4_addresses,
      ipv6_addresses,
      network_interface_names,
    ]
    prevent_destroy = true
  }
}

# ── Post-create hook: Label k8s worker nodes ──
# REMOVED: This provisioner runs on the TOFU HOST (not inside the VM).
# Since the tofu host is outside the k8s cluster network, it cannot reach
# the API server at 192.168.1.201:6443. The kubectl commands would fail.
#
# Node labeling is already handled correctly via cloud-init --node-labels
# in the VM module's user_data. That runs INSIDE the VM during boot, which
# is the correct place for VM-side configuration.
#
# If you need to label nodes post-boot from the tofu host, you must:
#   1. Copy ~/.kube/config to the tofu host first, OR
#   2. Run a Kubernetes Job/CronJob inside the cluster that the tofu host
#      triggers via a webhook or by writing to a ConfigMap/Secret.
# DO NOT add local-exec provisioners that call kubectl from the tofu host.
resource "null_resource" "k8s_worker_label" {
  count = 0  # DISABLED — handled by cloud-init user_data instead

  triggers = {
    vm_id = proxmox_virtual_environment_vm.this[0].id
  }

  provisioner "local-exec" {
    command = "echo 'k8s_worker_label disabled — use cloud-init user_data instead' && exit 0"
  }
}
