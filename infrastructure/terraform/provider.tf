# ============================================================
# provider.tf — Proxmox provider configuration (bpg/proxmox v0.101+)
#
# Authentication: API token (root@pam!vm-gitops:...)
# Token created via: pveum user token add root@pam vm-gitops --privsep 0
# Token role: PVEAdmin
#
# SSH for file uploads (snippets, ISOs). CI writes key to
# /home/moltbot/.ssh/pve-kai via GitHub Actions secret.
# ============================================================

provider "proxmox" {
  endpoint = "https://${var.proxmox_host}:${var.proxmox_port}/"
  api_token = var.proxmox_api_token
  insecure  = true

  ssh {
    username    = "root"
    private_key = file("${pathexpand("~")}/.ssh/pve-kai")
  }
}
