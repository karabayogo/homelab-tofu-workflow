# ============================================================
# modules/vm/outputs.tf — VM module outputs
# ============================================================

output "vm_id" {
  description = "Proxmox VM ID"
  value       = proxmox_virtual_environment_vm.this[0].vm_id
}

output "vm_name" {
  description = "VM name"
  value       = proxmox_virtual_environment_vm.this[0].name
}

output "vm_ip" {
  description = "VM IP (set by cloud-init, available after boot via QEMU agent)"
  value       = ""
}

output "static_ip" {
  description = "Configured static IP for the VM"
  value       = var.static_ip
}

output "proxmox_node" {
  description = "Proxmox node name"
  value       = var.proxmox_node
}
