# =============================================================================
# AKS Backup (Azure Backup for AKS) — replaces enable-backup.sh's Velero+
# MinIO Helm install when var.enable_aks_backup = true. Everything here is
# in its OWN resource group (var.backup_resource_group_name), deliberately
# separate from local.resource_group_name — the official pattern requires
# granting the cluster's identity Contributor on the resource group that
# holds backup snapshots, and rg-nextops-prod-jkt-001 already holds
# unrelated production resources (bastion, Key Vault, DES) this
# configuration has been careful all along not to expand access to.
#
# Reference: https://learn.microsoft.com/en-us/azure/backup/quick-kubernetes-backup-terraform
# =============================================================================

data "azurerm_client_config" "current" {
  count = var.enable_aks_backup ? 1 : 0
}

resource "azurerm_resource_group" "backup" {
  count    = var.enable_aks_backup ? 1 : 0
  name     = var.backup_resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "backup" {
  count                    = var.enable_aks_backup ? 1 : 0
  name                     = var.backup_storage_account_name
  resource_group_name      = azurerm_resource_group.backup[0].name
  location                 = azurerm_resource_group.backup[0].location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = var.tags
}

resource "azurerm_storage_container" "backup" {
  count              = var.enable_aks_backup ? 1 : 0
  name               = "aks-backup"
  storage_account_id = azurerm_storage_account.backup[0].id
}

resource "azurerm_data_protection_backup_vault" "lab" {
  count               = var.enable_aks_backup ? 1 : 0
  name                = var.backup_vault_name
  resource_group_name = azurerm_resource_group.backup[0].name
  location            = azurerm_resource_group.backup[0].location
  datastore_type      = "OperationalStore"
  redundancy          = "LocallyRedundant"
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_data_protection_backup_policy_kubernetes_cluster" "lab" {
  count               = var.enable_aks_backup ? 1 : 0
  name                = "aks-backup-policy"
  resource_group_name = azurerm_resource_group.backup[0].name
  vault_name          = azurerm_data_protection_backup_vault.lab[0].name

  backup_repeating_time_intervals = [var.backup_schedule_rrule]

  default_retention_rule {
    life_cycle {
      duration        = var.backup_retention_duration
      data_store_type = "OperationalStore"
    }
  }
}

# Lets the Backup Vault's identity call into the AKS cluster (via the
# Backup Extension below) — the least-privilege alternative to a full
# RBAC role assignment for cluster access.
resource "azurerm_kubernetes_cluster_trusted_access_role_binding" "backup" {
  count                 = var.enable_aks_backup ? 1 : 0
  kubernetes_cluster_id = azurerm_kubernetes_cluster.lab.id
  name                  = "backuptrustedaccess"
  roles                 = ["Microsoft.DataProtection/backupVaults/backup-operator"]
  source_resource_id    = azurerm_data_protection_backup_vault.lab[0].id
}

resource "azurerm_kubernetes_cluster_extension" "backup" {
  count          = var.enable_aks_backup ? 1 : 0
  name           = "azure-aks-backup"
  cluster_id     = azurerm_kubernetes_cluster.lab.id
  extension_type = "microsoft.dataprotection.kubernetes"

  configuration_settings = {
    "configuration.backupStorageLocation.bucket"                   = azurerm_storage_container.backup[0].name
    "configuration.backupStorageLocation.config.storageAccount"    = azurerm_storage_account.backup[0].name
    "configuration.backupStorageLocation.config.resourceGroup"     = azurerm_resource_group.backup[0].name
    "configuration.backupStorageLocation.config.subscriptionId"    = var.subscription_id
    "credentials.tenantId"                                         = data.azurerm_client_config.current[0].tenant_id
    "configuration.backupStorageLocation.config.useAAD"            = "true"
    "configuration.backupStorageLocation.config.storageAccountURI" = azurerm_storage_account.backup[0].primary_blob_endpoint
  }

  depends_on = [azurerm_kubernetes_cluster_trusted_access_role_binding.backup]
}

# Four distinct role assignments, each least-privilege for its own
# direction — mirrors the official quickstart exactly rather than
# collapsing them into one broader grant.
resource "azurerm_role_assignment" "backup_extension_storage" {
  count                = var.enable_aks_backup ? 1 : 0
  scope                = azurerm_storage_account.backup[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_kubernetes_cluster_extension.backup[0].aks_assigned_identity[0].principal_id
}

resource "azurerm_role_assignment" "backup_vault_reader_cluster" {
  count                = var.enable_aks_backup ? 1 : 0
  scope                = azurerm_kubernetes_cluster.lab.id
  role_definition_name = "Reader"
  principal_id         = azurerm_data_protection_backup_vault.lab[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "backup_vault_reader_snaprg" {
  count                = var.enable_aks_backup ? 1 : 0
  scope                = azurerm_resource_group.backup[0].id
  role_definition_name = "Reader"
  principal_id         = azurerm_data_protection_backup_vault.lab[0].identity[0].principal_id
}

# The one grant with real blast radius — Contributor, not Reader — but
# scoped to the dedicated backup resource group above, never
# local.resource_group_name.
resource "azurerm_role_assignment" "cluster_contributor_snaprg" {
  count                = var.enable_aks_backup ? 1 : 0
  scope                = azurerm_resource_group.backup[0].id
  role_definition_name = "Contributor"
  principal_id         = azurerm_kubernetes_cluster.lab.identity[0].principal_id
}

resource "azurerm_data_protection_backup_instance_kubernetes_cluster" "lab" {
  count                        = var.enable_aks_backup ? 1 : 0
  name                         = "aks-backup-instance"
  location                     = azurerm_resource_group.backup[0].location
  vault_id                     = azurerm_data_protection_backup_vault.lab[0].id
  kubernetes_cluster_id        = azurerm_kubernetes_cluster.lab.id
  snapshot_resource_group_name = azurerm_resource_group.backup[0].name
  backup_policy_id             = azurerm_data_protection_backup_policy_kubernetes_cluster.lab[0].id

  backup_datasource_parameters {
    included_namespaces              = ["online-boutique"]
    excluded_namespaces              = []
    included_resource_types          = []
    excluded_resource_types          = []
    label_selectors                  = []
    cluster_scoped_resources_enabled = false
    volume_snapshot_enabled          = true
  }

  depends_on = [
    azurerm_kubernetes_cluster_extension.backup,
    azurerm_role_assignment.backup_extension_storage,
    azurerm_role_assignment.backup_vault_reader_cluster,
    azurerm_role_assignment.backup_vault_reader_snaprg,
    azurerm_role_assignment.cluster_contributor_snaprg,
  ]
}
