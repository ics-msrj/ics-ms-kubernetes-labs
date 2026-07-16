output "resource_group_name" {
  description = "Resource group name — set as AKS_RESOURCE_GROUP in platforms/aks/config/aks.env"
  value       = local.resource_group_name
}

output "cluster_name" {
  description = "AKS cluster name — set as AKS_CLUSTER_NAME in platforms/aks/config/aks.env"
  value       = azurerm_kubernetes_cluster.lab.name
}

output "workload_nodepool_name" {
  description = "Workload node pool name — set as AKS_WORKLOAD_NODEPOOL in platforms/aks/config/aks.env"
  value       = azurerm_kubernetes_cluster_node_pool.workload.name
}

output "next_steps" {
  description = "Steps to continue the AKS platform track after this applies"
  value       = <<-EOT

  ================================================================
  AKS cluster is ready. Fill these into platforms/aks/config/aks.env
  (copy from aks.env.example first if you haven't):

  AKS_RESOURCE_GROUP=${local.resource_group_name}
  AKS_CLUSTER_NAME=${azurerm_kubernetes_cluster.lab.name}
  AKS_WORKLOAD_NODEPOOL=${azurerm_kubernetes_cluster_node_pool.workload.name}
  AKS_WORKLOAD_LABEL_KEY=${var.workload_node_label_key}
  AKS_WORKLOAD_LABEL_VALUE=${var.workload_node_label_value}

  Then follow platforms/aks/README.md from "Foundation":
    bash platforms/aks/scripts/aks-track.sh connect
    bash platforms/aks/scripts/aks-track.sh preflight
    bash platforms/aks/scripts/aks-track.sh enable-managed-addons
  ================================================================
  EOT
}
