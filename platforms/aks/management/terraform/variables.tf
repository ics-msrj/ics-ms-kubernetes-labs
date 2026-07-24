variable "subscription_id" {
  description = "Azure subscription ID to deploy into. Pinned explicitly rather than left to inherit from `az account show` — same reasoning as platforms/aks/terraform/variables.tf: an unpinned provider silently follows whatever subscription is currently active."
  type        = string
}

variable "location" {
  description = "Azure region for the resource group and VM."
  type        = string
  default     = "southeastasia"
}

variable "resource_group_name" {
  description = "Resource group name. This track deliberately does NOT reuse rg-nextops-prod-jkt-001 (the shared AKS workload resource group) — checked live via `az group list` and confirmed no existing resource group is suitable for an isolated management VM."
  type        = string
  default     = "rg-ics-ms-prod-sgp-001"
}

variable "create_resource_group" {
  description = "true creates resource_group_name as a new resource group (the default here, unlike platforms/aks/terraform — there is no existing resource group to adopt for this track). false looks it up as a data source instead."
  type        = bool
  default     = true
}

# ── Networking — first Azure VM/VNet/NSG convention in this repo; no existing ─
# ── one to reuse (confirmed by repo-wide search) ───────────────────────────────

variable "vnet_name" {
  type    = string
  default = "vnet-ics-ms-sgp-001"
}

variable "vnet_cidr" {
  type    = string
  default = "10.90.0.0/24"
}

variable "subnet_name" {
  type    = string
  default = "snet-ics-ms-sgp-001"
}

variable "subnet_cidr" {
  type    = string
  default = "10.90.0.0/26"
}

variable "admin_cidr" {
  description = "CIDR allowed for SSH to the VM. Restrict to your own IP — never 0.0.0.0/0. There is no other inbound rule: Rancher itself is reached only through the outbound Cloudflare Tunnel (see manifests/rancher/values.yaml), never a public LB or NodePort."
  type        = string

  validation {
    condition     = var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr cannot be 0.0.0.0/0. Use a trusted IP/CIDR (e.g. x.x.x.x/32) — curl ifconfig.me to find yours."
  }
}

# ── VMs — 1 control-plane + 1 worker, mirroring modules/01-cluster-setup's ──
# ── proven topology (its own verify.sh refuses a cluster with no worker) ────
#
# Deliberately not single-node: found live that a single-node kubeadm+Cilium
# node does not reliably survive a reboot (cilium/cilium#44194 — stale TCX
# BPF programs on Cilium agent restart cause duplicate attachments and
# total ClusterIP/DNS failure). Splitting control-plane and worker onto
# separate nodes contains the blast radius if that bug recurs on either
# one, and allows patching them one at a time instead of simultaneously.

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to your SSH public key file."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "os_disk_type" {
  description = "Premium SSD — etcd (control-plane) is latency-sensitive to disk write performance; kept the same for the worker for consistency."
  type        = string
  default     = "Premium_LRS"
}

variable "os_disk_size_gb" {
  description = "Bumped from modules/01-cluster-setup's 50GB default to leave headroom for Rancher/cert-manager/cloudflared images on the worker specifically; applied to both nodes for simplicity."
  type        = number
  default     = 100
}

# ── Control plane ────────────────────────────────────────────────────────

variable "control_plane_vm_name" {
  type    = string
  default = "vm-ics-ms-k8s-ops-sgp-001"
}

variable "control_plane_vm_size" {
  description = "2 vCPU / 8 GiB: etcd/apiserver/scheduler/controller-manager/kube-proxy/cilium only — Rancher and its dependencies now live on the worker instead, so this no longer needs the 4 vCPU the single-node design required. Dadsv7 generation — confirmed available in this subscription/region (`az vm list-skus --location southeastasia --size Standard_D2ads_v7`), Dadsv7 family had 10 vCPU quota headroom."
  type        = string
  default     = "Standard_D2ads_v7"
}

variable "control_plane_node_name" {
  description = "Hostname / kubeadm --node-name for the control-plane node."
  type        = string
  default     = "k8s-ops-01"
}

# ── Worker ────────────────────────────────────────────────────────────────

variable "worker_vm_name" {
  type    = string
  default = "vm-ics-ms-k8s-worker-sgp-001"
}

variable "worker_vm_size" {
  description = "4 vCPU / 16 GiB: this node carries Rancher (which alone recommends ~4 vCPU/8GB) plus cert-manager, cloudflared, and its own Cilium agent."
  type        = string
  default     = "Standard_D4ads_v7"
}

variable "worker_node_name" {
  description = "Hostname / kubeadm --node-name for the worker node."
  type        = string
  default     = "k8s-worker-01"
}

variable "tags" {
  description = "owner/managed_by/cost_center are enforced by this subscription's Azure Policy — every resource create fails outright without them (same requirement as platforms/aks/terraform/variables.tf)."
  type        = map(string)
  default = {
    owner       = "ics-ms"
    managed_by  = "terraform"
    cost_center = "nextops"
    environment = "production"
    project     = "k8s-learning-lab"
    platform    = "k8s-ops"
  }
}
