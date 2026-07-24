output "control_plane_public_ip" { value = azurerm_public_ip.control_plane.ip_address }
output "control_plane_private_ip" { value = azurerm_network_interface.control_plane.private_ip_address }
output "worker_public_ip" { value = azurerm_public_ip.worker.ip_address }
output "worker_private_ip" { value = azurerm_network_interface.worker.private_ip_address }
output "resource_group_name" { value = local.resource_group_name }

output "next_steps" {
  value = <<-EOT
    Copy ../config/platform.env.example to ../config/platform.env and set:
      AKS_MANAGEMENT_CP_PUBLIC_IP=${azurerm_public_ip.control_plane.ip_address}
      AKS_MANAGEMENT_CP_PRIVATE_IP=${azurerm_network_interface.control_plane.private_ip_address}
      AKS_MANAGEMENT_WORKER_PUBLIC_IP=${azurerm_public_ip.worker.ip_address}
      AKS_MANAGEMENT_WORKER_PRIVATE_IP=${azurerm_network_interface.worker.private_ip_address}
      AKS_MANAGEMENT_SSH_USER=${var.admin_username}

    Then:
      bash platforms/aks/management/scripts/platform-track.sh preflight
      bash platforms/aks/management/scripts/platform-track.sh bootstrap-control-plane
      bash platforms/aks/management/scripts/platform-track.sh bootstrap-worker
  EOT
}
