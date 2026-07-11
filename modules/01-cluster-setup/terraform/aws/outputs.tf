output "control_plane_public_ip" {
  description = "Public IP of the control-plane node — set as CONTROL_PLANE_PUBLIC_IP in lab.env"
  value       = aws_eip.control_plane.public_ip
}

output "control_plane_private_ip" {
  description = "Private IP of the control-plane node — set as CONTROL_PLANE_PRIVATE_IP in lab.env"
  value       = aws_instance.control_plane.private_ip
}

output "worker_public_ips" {
  description = "Public IPs of worker nodes — set as WORKER_PUBLIC_IPS in lab.env (space-separated)"
  value       = aws_eip.workers[*].public_ip
}

output "worker_private_ips" {
  description = "Private IPs of worker nodes"
  value       = aws_instance.workers[*].private_ip
}

output "next_steps" {
  description = "Steps to bootstrap Kubernetes on these VMs"
  value       = <<-EOT

  ================================================================
  VMs are ready. Fill these into lab.env at the repo root:

  SSH_USER=${var.ssh_user}
  CONTROL_PLANE_PUBLIC_IP=${aws_eip.control_plane.public_ip}
  CONTROL_PLANE_PRIVATE_IP=${aws_instance.control_plane.private_ip}
  WORKER_PUBLIC_IPS="${join(" ", aws_eip.workers[*].public_ip)}"

  Then follow modules/01-cluster-setup/README.md from "Step 2".
  ================================================================
  EOT
}
