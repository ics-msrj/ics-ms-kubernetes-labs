variable "subscription_id" {
  description = "Azure subscription ID to deploy into. Pinned explicitly rather than left to inherit from `az account show` — a session's active `az` subscription can change between runs (it did during this project), and an unpinned provider would then silently target the same resource group name in the wrong subscription."
  type        = string
}

variable "location" {
  description = "Azure region for the resource group and AKS cluster"
  type        = string
  default     = "southeastasia"
}

variable "key_vault_name" {
  description = "Name of an existing Key Vault (in resource_group_name) to enable the Key Vault Secrets Provider add-on against, for Secrets Store CSI-backed application secrets in place of Sealed Secrets. This configuration never creates a Key Vault — leave null to skip the add-on entirely (Module 03 then falls back to its native, unmodified Sealed Secrets treatment)."
  type        = string
  default     = null
}

variable "enable_aks_backup" {
  description = "Enable Azure Backup for AKS (Backup Vault, Backup Extension, Trusted Access, a dedicated backup.tf resource group for snapshot storage) in place of enable-backup.sh's Velero+MinIO install. False keeps this track's Module 13 equivalent on Velero+MinIO, matching native Module 13's own mechanism."
  type        = bool
  default     = false
}

variable "backup_resource_group_name" {
  description = "Name for a new, dedicated resource group holding AKS Backup's storage account and disk snapshots — deliberately separate from resource_group_name, since the cluster identity needs Contributor on whatever resource group holds the snapshots, and that shouldn't be a resource group with unrelated resources in it. Only used when enable_aks_backup = true."
  type        = string
  default     = "rg-aks-backup-lab"
}

variable "backup_storage_account_name" {
  description = "Name for the storage account AKS Backup's extension writes backup data to. Must be globally unique, lowercase alphanumeric only, 3-24 chars. Only used when enable_aks_backup = true."
  type        = string
  default     = "staksbackuplab"

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.backup_storage_account_name))
    error_message = "backup_storage_account_name must be 3-24 lowercase alphanumeric characters (Azure Storage Account naming rules)."
  }
}

variable "backup_vault_name" {
  description = "Name for the Data Protection Backup Vault. Only used when enable_aks_backup = true."
  type        = string
  default     = "bvault-aks-lab"
}

variable "backup_schedule_rrule" {
  description = "RRULE-format backup schedule, e.g. \"R/<ISO8601 start>/<ISO8601 duration>\". Default: daily at 02:00 UTC. Only used when enable_aks_backup = true."
  type        = string
  default     = "R/2026-01-01T02:00:00+00:00/P1D"
}

variable "backup_retention_duration" {
  description = "ISO8601 duration to retain each backup, e.g. \"P7D\" for 7 days. Only used when enable_aks_backup = true."
  type        = string
  default     = "P7D"
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
  description = "VM size for the system node pool. Defaults to the Dsv3 generation, not the newer Dsv5 — many subscriptions (especially new/dev ones) start with a 0-vCPU Dsv5 family quota that only a support request raises, while Dsv3 is broadly available out of the box. Check `az vm list-usage --location <region> -o table` before changing this."
  type        = string
  default     = "Standard_D2s_v3" # 2 vCPU, 8 GiB
}

variable "system_node_count" {
  description = "Fixed node count for the system pool (not autoscaled — this repo's application/load workloads never schedule here)"
  type        = number
  default     = 1
}

# ── Workload node pool — autoscaled, this is where the app runs ─────────────

variable "workload_node_vm_size" {
  description = "VM size for the workload node pool. Online Boutique's 11 services plus later add-ons (Istio, Chaos Mesh) want more headroom than the bare minimum — bump this to a 4 vCPU size if your subscription's quota allows it. Defaults to the Dsv3 generation for the same quota-availability reason as system_node_vm_size."
  type        = string
  default     = "Standard_D2s_v3" # 2 vCPU, 8 GiB
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

variable "disk_encryption_set_id" {
  description = "Resource ID of an existing azurerm_disk_encryption_set for customer-managed-key (CMK) encryption of node OS/data disks. Leave null to use Azure's platform-managed key instead — this configuration never creates a Disk Encryption Set itself, only references one that already exists (its own Key Vault key access/RBAC is that resource's responsibility, not this one's)."
  type        = string
  default     = null
}

variable "container_registry_name" {
  description = "Name for the Azure Container Registry this configuration creates. Must be globally unique, alphanumeric only (no hyphens), 5-50 chars."
  type        = string
  default     = "acrakslab"

  validation {
    condition     = can(regex("^[a-zA-Z0-9]{5,50}$", var.container_registry_name))
    error_message = "container_registry_name must be 5-50 alphanumeric characters (no hyphens or other symbols — ACR naming is stricter than most Azure resources)."
  }
}

variable "container_registry_sku" {
  description = "ACR SKU. Basic is enough for a lab (limited storage/throughput, no geo-replication, no private endpoints — see Standard/Premium if this needs to become a real shared registry)."
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.container_registry_sku)
    error_message = "container_registry_sku must be Basic, Standard, or Premium."
  }
}

variable "tags" {
  description = "Tags applied to every resource this configuration creates. owner/managed_by/cost_center are enforced by this subscription's Azure Policy ('ICS MS - Require tag: ...') — every resource create fails outright without them, and the key casing matters (snake_case, not the Platform/Environment-style casing this repo uses elsewhere). Values here match the convention already used by other resources in rg-nextops-prod-jkt-001 (the bastion, Key Vault), not invented for this configuration."
  type        = map(string)
  default = {
    owner       = "ics-ms"
    managed_by  = "terraform"
    cost_center = "nextops"
    environment = "production"
    project     = "k8s-learning-lab"
    platform    = "aks"
  }
}
