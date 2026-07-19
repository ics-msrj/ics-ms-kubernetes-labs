variable "project_id" {
  description = "GCP project ID to deploy into. Pinned explicitly rather than left to inherit from `gcloud config get-value project` — a session's active gcloud project can change between runs (it did during the AKS track's equivalent subscription_id, the reason this is pinned here too), and an unpinned provider would then silently target the same resource names in the wrong project."
  type        = string
}

variable "region" {
  description = "GCP region for the VPC, cluster, and Artifact Registry."
  type        = string
  default     = "asia-southeast1"
}

variable "zone" {
  description = "GCP zone for the (zonal) GKE cluster — cheaper and simpler than a regional cluster's replicated control plane for a lab. Must be inside `region`."
  type        = string
  default     = "asia-southeast1-a"
}

# ── Networking ────────────────────────────────────────────────────────────

variable "network_name" {
  description = "Name for a new, dedicated VPC — this configuration never deploys into the project's `default` VPC (shared, wide-open firewall rules by default, and not something this configuration should adopt or modify)."
  type        = string
  default     = "vpc-nextops-gke-sgp-001"
}

variable "subnet_cidr" {
  description = "Primary CIDR range for the GKE subnet (node IPs)."
  type        = string
  default     = "10.20.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary CIDR range for Pod IPs (VPC-native/alias-IP cluster)."
  type        = string
  default     = "10.21.0.0/16"
}

variable "services_cidr" {
  description = "Secondary CIDR range for Service (ClusterIP) IPs (VPC-native/alias-IP cluster)."
  type        = string
  default     = "10.22.0.0/20"
}

variable "proxy_only_subnet_cidr" {
  description = "CIDR range for the REGIONAL_MANAGED_PROXY subnet — required for Gateway API's regional external/internal load balancers (gke-l7-regional-*-managed GatewayClasses) to provision at all. /26 (64 IPs) is comfortably above Google's documented minimum for a single region's proxy-only subnet."
  type        = string
  default     = "10.23.0.0/26"
}

# ── Cluster ──────────────────────────────────────────────────────────────

variable "cluster_name" {
  description = "GKE cluster name — set as GKE_CLUSTER_NAME in platforms/gke/config/gke.env"
  type        = string
  default     = "gke-nextops-production-sgp-001" # same platform-org-env-region-seq convention as the AKS track's aks-nextops-production-sgp-001

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,38}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must start with a lowercase letter, lowercase alphanumeric+hyphens only, max 40 chars (GKE cluster naming rules)."
  }
}

variable "kubernetes_release_channel" {
  description = "GKE release channel: RAPID, REGULAR, or STABLE. REGULAR tracks a current, well-tested GA version without pinning one that ages out — the same reasoning as leaving AKS's kubernetes_version null."
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.kubernetes_release_channel)
    error_message = "kubernetes_release_channel must be RAPID, REGULAR, or STABLE."
  }
}

variable "deletion_protection" {
  description = "GKE cluster deletion protection. Defaults to false — this is a lab cluster meant to be destroyed with `terraform destroy` between sessions; the provider default (true) would silently block that."
  type        = bool
  default     = false
}

# ── System node pool — fixed size, hosts only GKE system components ────────

variable "system_node_machine_type" {
  description = "Machine type for the system node pool. e2-standard-2 (2 vCPU, 8 GiB) — this project's CPUS quota in `region` is generous (checked: 5000, vs. the 10-vCPU ceiling the AKS track kept colliding with), so this is sized for comfort, not quota scarcity."
  type        = string
  default     = "e2-standard-2"
}

variable "system_node_count" {
  description = "Fixed node count for the system pool (not autoscaled — this repo's application/load workloads never schedule here, same rule as the AKS track's system pool)."
  type        = number
  default     = 1
}

# ── Workload node pool — autoscaled, this is where the app runs ────────────

variable "workload_node_machine_type" {
  description = "Machine type for the workload node pool. e2-standard-4 (4 vCPU, 16 GiB) — sized larger than the AKS track's workload nodes (2 vCPU) on purpose: this project's quota isn't the constraint here, and the AKS track spent an entire session doing whack-a-mole CPU trims (scaling down loadgenerator, frontend replicas, etc.) every time a new module's workload got added. Starting with more headroom avoids repeating that."
  type        = string
  default     = "e2-standard-4"
}

variable "workload_min_count" {
  description = "Minimum workload pool node count. Must match MIN_NODES the platform track's scripts expect."
  type        = number
  default     = 1
}

variable "workload_max_count" {
  description = "Maximum workload pool node count. Must match MAX_NODES the platform track's scripts expect."
  type        = number
  default     = 4
}

variable "workload_node_label_key" {
  description = "Node label key applied to the workload pool. Must match GKE_WORKLOAD_LABEL_KEY in gke.env — preflight.sh checks for it exactly. Same key name as the AKS track's equivalent variable, so native modules' nodeSelector-patched manifests carry over unchanged."
  type        = string
  default     = "workload"
}

variable "workload_node_label_value" {
  description = "Node label value applied to the workload pool. Must match GKE_WORKLOAD_LABEL_VALUE in gke.env — preflight.sh checks for it exactly."
  type        = string
  default     = "autoscale"
}

# ── Artifact Registry ────────────────────────────────────────────────────

variable "artifact_registry_repo_id" {
  description = "Repository ID for the Artifact Registry Docker repo this configuration creates — for custom images, not required for the stock Online Boutique manifests (those pull public images directly)."
  type        = string
  default     = "nextops-gke-sgp-001"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.artifact_registry_repo_id))
    error_message = "artifact_registry_repo_id must start with a lowercase letter, lowercase alphanumeric+hyphens only, max 63 chars."
  }
}

variable "labels" {
  description = "Labels applied to every resource this configuration creates. No Org Policy in this project enforces labels (checked: `gcloud resource-manager org-policies list` returned none) — unlike the AKS track's tags, these are for cost tracking/hygiene only, not a hard requirement. Keys/values match the convention already used by other resources in this project (the bastion VM), not invented for this configuration."
  type        = map(string)
  default = {
    owner       = "ics-ms"
    managed_by  = "terraform"
    cost_center = "nextops"
    environment = "production"
    project     = "k8s-learning-lab"
    platform    = "gke"
  }
}
