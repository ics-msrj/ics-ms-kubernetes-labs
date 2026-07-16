variable "location" {
  description = "Azure region for the resource group and AKS cluster"
  type        = string
  default     = "southeastasia"
}

variable "resource_group_name" {
  description = "Resource group name — set as AKS_RESOURCE_GROUP in platforms/aks/config/aks.env"
  type        = string
  default     = "rg-aks-platform-lab"
}

variable "create_resource_group" {
  description = "true creates resource_group_name as a new resource group (default, for a from-scratch lab). false looks it up as a data source instead and creates nothing but the cluster inside it — use this for an existing (e.g. shared/production) resource group, so this configuration never touches its tags or lifecycle."
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = "AKS cluster name — set as AKS_CLUSTER_NAME in platforms/aks/config/aks.env"
  type        = string
  default     = "aks-platform-lab"

  validation {
    # Real Azure limit for the cluster name itself is 1-63 chars, but this
    # value also becomes dns_prefix below (main.tf), whose own limit is
    # tighter: 1-54 chars. Validating against 54 here, not 63, so this
    # never fails later on the dns_prefix constraint instead.
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{0,52}[a-zA-Z0-9]$", var.cluster_name))
    error_message = "cluster_name must start/end alphanumeric, alphanumeric+hyphens only, max 54 chars (the tighter dns_prefix limit, since this value is reused as dns_prefix)."
  }
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version. Leave null to use AKS's current default GA version rather than pinning one that will age out."
  type        = string
  default     = null
}

# ── System node pool — fixed size, hosts only AKS system components ─────────

variable "system_node_vm_size" {
  description = "VM size for the system node pool"
  type        = string
  default     = "Standard_D2s_v5" # 2 vCPU, 8 GiB
}

variable "system_node_count" {
  description = "Fixed node count for the system pool (not autoscaled — this repo's application/load workloads never schedule here)"
  type        = number
  default     = 1
}

# ── Workload node pool — autoscaled, this is where the app runs ─────────────

variable "workload_node_vm_size" {
  description = "VM size for the workload node pool. Online Boutique's 11 services plus later add-ons (Istio, Chaos Mesh) want more headroom than the bare minimum."
  type        = string
  default     = "Standard_D4s_v5" # 4 vCPU, 16 GiB
}

variable "workload_min_count" {
  description = "Minimum workload pool node count. Must match MIN_NODES the platform track's scripts expect."
  type        = number
  default     = 1
}

variable "workload_max_count" {
  description = "Maximum workload pool node count. Must match MAX_NODES the platform track's scripts expect."
  type        = number
  default     = 3
}

variable "workload_node_label_key" {
  description = "Node label key applied to the workload pool. Must match AKS_WORKLOAD_LABEL_KEY in aks.env — preflight.sh checks for it exactly."
  type        = string
  default     = "workload"
}

variable "workload_node_label_value" {
  description = "Node label value applied to the workload pool. Must match AKS_WORKLOAD_LABEL_VALUE in aks.env — preflight.sh checks for it exactly."
  type        = string
  default     = "autoscale"
}

variable "enable_snapshot_controller" {
  description = "Enable AKS's CSI snapshot controller at cluster-create time (Module 05's VolumeSnapshot support needs this — it is not on by default)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource this configuration creates"
  type        = map(string)
  default = {
    Project     = "k8s-learning-lab"
    Platform    = "aks"
    Environment = "lab"
    ManagedBy   = "terraform"
  }
}
