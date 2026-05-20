# ============================================================
# imports.tf — Import existing VMs into tfstate
#
# VMs 400-800 already exist on PVE. Import blocks tell OpenTofu
# to adopt them instead of creating duplicates.
# Run: tofu plan -generate-config-out=generated.tf
# Then: tofu apply -generated-config-out=generated.tf
# ============================================================

import {
  to = module.k8s_master1.proxmox_virtual_environment_vm.this[0]
  id = "400"
}

import {
  to = module.k8s_master2.proxmox_virtual_environment_vm.this[0]
  id = "500"
}

import {
  to = module.k8s_master3.proxmox_virtual_environment_vm.this[0]
  id = "600"
}

import {
  to = module.k8s_worker1.proxmox_virtual_environment_vm.this[0]
  id = "700"
}

import {
  to = module.k8s_worker2.proxmox_virtual_environment_vm.this[0]
  id = "800"
}