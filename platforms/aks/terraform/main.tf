# =============================================================================
# AKS platform track — cluster provisioning.
#
# Unlike modules/01-cluster-setup/terraform/{aws,alicloud}/ (which provision
# raw VMs for you to kubeadm yourself), this provisions an actual AKS
# cluster — the control plane, CNI, and node OS are AKS's responsibility
# from the moment this applies. Everything after this is
# platforms/aks/scripts/aks-track.sh connect/preflight/... against what
# Terraform creates here.
#
# State is local by default — for a real team setup, configure a remote
# backend before running this for real.
# =============================================================================

provider "azurerm" {
  features {}
  # Pinned explicitly — without this, the provider silently follows
  # whatever subscription `az account show` currently reports, which can
  # (and did) change out from under a session between runs, pointing this
  # at the wrong subscription's identically-named resource group.
  subscription_id = var.subscription_id
}

# create_resource_group = true creates a new resource group (default, for a
# from-scratch lab). false looks it up as a read-only data source instead —
# this configuration then creates nothing but the cluster inside it, and
# never touches an existing resource group's tags or lifecycle. Using a
# managed `resource` block against an already-existing resource group name
# would make Terraform "adopt" it and overwrite its tags with var.tags on
# every apply — a real risk for a shared or production resource group this
# configuration doesn't own.
resource "azurerm_resource_group" "lab" {
  count = var.create_resource_group ? 1 : 0

  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

data "azurerm_resource_group" "existing" {
  count = var.create_resource_group ? 0 : 1

  name = var.resource_group_name
}

# Referenced, never created or managed — this is the real Key Vault
# secrets get pushed into (outside Terraform, imperatively) for the AKS
# Key Vault Secrets Provider add-on to sync from. var.key_vault_name is
# null by default so clusters without a pre-existing Key Vault (most
# lab/from-scratch setups) don't need one.
data "azurerm_key_vault" "secrets" {
  count               = var.key_vault_name != null ? 1 : 0
  name                = var.key_vault_name
  resource_group_name = local.resource_group_name
}

locals {
  resource_group_name = var.create_resource_group ? azurerm_resource_group.lab[0].name : data.azurerm_resource_group.existing[0].name
}

resource "azurerm_kubernetes_cluster" "lab" {
  name = var.cluster_name
  # var.location, not the resource group's own location — a resource
  # group's location is only where its metadata lives; resources inside it
  # (including this cluster) can be created in any region. This matters
  # when targeting an existing RG whose home region has no quota headroom
  # for the VM sizes below.
  location               = var.location
  resource_group_name    = local.resource_group_name
  dns_prefix             = var.cluster_name
  kubernetes_version     = var.kubernetes_version
  disk_encryption_set_id = var.disk_encryption_set_id
  tags                   = var.tags

  # The default node pool hosts only AKS system components — this repo's
  # application and load-test Pods are never scheduled here (see the
  # workload node pool below and its matching nodeSelector-based manifests).
  default_node_pool {
    name       = "system"
    vm_size    = var.system_node_vm_size
    node_count = var.system_node_count

    only_critical_addons_enabled = true
    # Without this, the cluster resource itself carries var.tags but the
    # system pool's underlying VMSS (in the MC_ resource group) does not —
    # this subscription's tag-requirement policies check the VMSS directly
    # and reject it outright if untagged, even though the parent cluster
    # already passed the same check.
    tags = var.tags
  }

  identity {
    type = "SystemAssigned"
  }

  # Azure Key Vault Provider for Secrets Store CSI Driver — replaces
  # Sealed Secrets for this track when var.key_vault_name is set. AKS
  # provisions its own managed identity for this (secret_identity below),
  # separate from both the cluster identity above and kubelet_identity
  # used for ACR pulls.
  dynamic "key_vault_secrets_provider" {
    for_each = var.key_vault_name != null ? [1] : []
    content {
      secret_rotation_enabled  = true
      secret_rotation_interval = "2m"
    }
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium" # required whenever network_policy = "cilium"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
  }

  storage_profile {
    disk_driver_enabled         = true
    snapshot_controller_enabled = var.enable_snapshot_controller
  }

  lifecycle {
    ignore_changes = [
      # enable-managed-addons.sh (az aks update --enable-vpa --enable-keda
      # --enable-app-routing-istio) changes cluster state outside Terraform
      # on purpose — don't fight it on the next apply.
      workload_autoscaler_profile,
      web_app_routing,
    ]
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "workload" {
  name                  = "workloadpool"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.lab.id
  vm_size               = var.workload_node_vm_size
  mode                  = "User"

  auto_scaling_enabled = true
  min_count            = var.workload_min_count
  max_count            = var.workload_max_count

  node_labels = {
    (var.workload_node_label_key) = var.workload_node_label_value
  }

  tags = var.tags
}

resource "azurerm_container_registry" "lab" {
  name                = var.container_registry_name
  resource_group_name = local.resource_group_name
  location            = var.location
  sku                 = var.container_registry_sku
  admin_enabled       = false
  tags                = var.tags
}

# Grants the cluster's own kubelet identity (not the cluster-management
# identity above) pull access — this is what lets nodes actually pull
# images, replacing the legacy `az aks update --attach-acr` flow with a
# plain role assignment Terraform can track.
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.lab.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.lab.kubelet_identity[0].object_id
}

# Without this, dynamically-provisioned PVs (any PVC on a StorageClass
# whose diskEncryptionSetID points here) fail outright with
# LinkedAuthorizationFailed: the cluster's own control-plane identity — not
# the kubelet identity above — is what the in-tree Azure Disk CSI
# provisioning path authenticates as, and it has no access to a DES it
# doesn't own by default. This is the identity behind the cluster resource
# itself (`azurerm_kubernetes_cluster.lab.identity`), a different
# principal from kubelet_identity used for ACR pulls above. Confirmed by
# testing that Contributor scoped to the DES alone is sufficient (a
# resource-group-scoped grant was tried first while debugging and was
# unnecessarily broad — removed once this narrower scope proved to work).
resource "azurerm_role_assignment" "aks_des_access" {
  count                = var.disk_encryption_set_id != null ? 1 : 0
  scope                = var.disk_encryption_set_id
  role_definition_name = "Contributor"
  principal_id         = azurerm_kubernetes_cluster.lab.identity[0].principal_id
}

# Yet another distinct identity — key_vault_secrets_provider's own
# secret_identity, not the cluster identity or kubelet_identity used
# above. Key Vault Secrets User is the minimum built-in role that lets the
# CSI driver read secret values (not manage the vault itself).
resource "azurerm_role_assignment" "aks_keyvault_secrets_user" {
  count                = var.key_vault_name != null ? 1 : 0
  scope                = data.azurerm_key_vault.secrets[0].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_kubernetes_cluster.lab.key_vault_secrets_provider[0].secret_identity[0].object_id
}
