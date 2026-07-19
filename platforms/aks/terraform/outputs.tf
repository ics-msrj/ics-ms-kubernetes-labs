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

output "container_registry_login_server" {
  description = "ACR login server — set as AKS_CONTAINER_REGISTRY in platforms/aks/config/aks.env if you push custom images"
  value       = azurerm_container_registry.lab.login_server
}

output "backup_vault_name" {
  description = "Data Protection Backup Vault name — set as AKS_BACKUP_VAULT_NAME in platforms/aks/config/aks.env if enable_aks_backup = true"
  value       = var.enable_aks_backup ? azurerm_data_protection_backup_vault.lab[0].name : null
}

output "backup_resource_group_name" {
  description = "Dedicated resource group holding AKS Backup's storage account and snapshots — set as AKS_BACKUP_RESOURCE_GROUP in platforms/aks/config/aks.env if enable_aks_backup = true"
  value       = var.enable_aks_backup ? azurerm_resource_group.backup[0].name : null
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
  AKS_CONTAINER_REGISTRY=${azurerm_container_registry.lab.login_server}

  Then follow platforms/aks/README.md from "Foundation":
    bash platforms/aks/scripts/aks-track.sh connect
    bash platforms/aks/scripts/aks-track.sh preflight
    bash platforms/aks/scripts/aks-track.sh enable-managed-addons
  ================================================================
  EOT
}
