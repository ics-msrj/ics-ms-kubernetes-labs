output "control_plane_public_ip" {
  description = "Control-plane EIP for SSH and the repository's SSH tunnel."
  value       = alicloud_eip_address.nodes["control"].ip_address
}

output "control_plane_private_ip" {
  description = "Control-plane private VPC IP used by kubeadm and the SSH tunnel destination."
  value       = alicloud_instance.nodes["control"].private_ip
}

output "worker_public_ips" {
  description = "Worker EIPs for the repository's direct SSH bootstrap scripts."
  value       = [for key in ["worker_01", "worker_02"] : alicloud_eip_address.nodes[key].ip_address]
}

output "worker_private_ips" {
  description = "Worker private VPC IPs."
  value       = [for key in ["worker_01", "worker_02"] : alicloud_instance.nodes[key].private_ip]
}

output "longhorn_mount_path" {
  description = "Path where cloud-init mounts the dedicated Longhorn disk on every node."
  value       = var.longhorn_mount_path
}

output "next_steps" {
  description = "Values to copy into lab.env before Module 01."
  value       = <<-EOT

  =================================================================
  Alibaba Cloud ECS foundation is ready in ${var.region}/${var.zone_id}.

  Add the following to lab.env:
  SSH_USER=ubuntu
  CONTROL_PLANE_PUBLIC_IP=${alicloud_eip_address.nodes["control"].ip_address}
  CONTROL_PLANE_PRIVATE_IP=${alicloud_instance.nodes["control"].private_ip}
  WORKER_PUBLIC_IPS="${join(" ", [for key in ["worker_01", "worker_02"] : alicloud_eip_address.nodes[key].ip_address])}"

  Confirm the dedicated data disk is mounted on every node:
    ssh ubuntu@<node-eip> 'findmnt ${var.longhorn_mount_path}'

  Then run Module 00, followed by Module 01.
  =================================================================
  EOT
}
