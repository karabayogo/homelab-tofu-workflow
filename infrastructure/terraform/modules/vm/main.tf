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
      "${path.module}/templates/cloud-init-${var.k3s_role == "server" ? "master" : "worker"}.yaml.tftpl",
      {
        hostname        = var.vm_name
        ssh_pub_key     = var.ssh_pub_key
        tofu_deploy_key = var.tofu_deploy_key
        k3s_version     = var.k3s_version
        k3s_token       = var.k3s_token
        static_ip       = var.static_ip
        k3s_join_server = var.k3s_join_server
      }
    )
    file_name = "cloudinit-${var.vm_name}.yaml"
  }

  lifecycle {
    ignore_changes = [source_raw[0].data]
  }
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
# k3s v1.33+ restricts node-role.kubernetes.io labels in kubelet,
# so they must be applied via the API after the node joins.
resource "null_resource" "k8s_worker_label" {
  count = var.k3s_role == "agent" ? 1 : 0

  triggers = {
    vm_id = proxmox_virtual_environment_vm.this[0].id
  }

  provisioner "local-exec" {
    command = <<EOT
      echo "[vm-gitops] Waiting for node ${var.vm_name} to join cluster before labeling..."
      for i in {1..30}; do
        if kubectl get node ${var.vm_name} 2>/dev/null | grep -q " Ready "; then
          echo "[vm-gitops] Node ${var.vm_name} is Ready. Applying worker label."
          kubectl label node ${var.vm_name} node-role.kubernetes.io/worker=worker --overwrite
          exit 0
        fi
        sleep 10
      done
      echo "[vm-gitops] Error: Timeout waiting for node ${var.vm_name} to become Ready"
      exit 1
    EOT
  }
}
