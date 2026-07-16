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

locals {
  resource_group_name     = var.create_resource_group ? azurerm_resource_group.lab[0].name : data.azurerm_resource_group.existing[0].name
  resource_group_location = var.create_resource_group ? azurerm_resource_group.lab[0].location : data.azurerm_resource_group.existing[0].location
}

resource "azurerm_kubernetes_cluster" "lab" {
  name                = var.cluster_name
  location            = local.resource_group_location
  resource_group_name = local.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  tags                = var.tags

  # The default node pool hosts only AKS system components — this repo's
  # application and load-test Pods are never scheduled here (see the
  # workload node pool below and its matching nodeSelector-based manifests).
  default_node_pool {
    name       = "system"
    vm_size    = var.system_node_vm_size
    node_count = var.system_node_count

    only_critical_addons_enabled = true
  }

  identity {
    type = "SystemAssigned"
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
