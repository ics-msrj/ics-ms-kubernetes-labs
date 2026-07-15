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

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_kubernetes_cluster" "lab" {
  name                = var.cluster_name
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
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
