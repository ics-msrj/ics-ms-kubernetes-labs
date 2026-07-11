variable "region" {
  description = "AWS region where VMs will be created"
  type        = string
  default     = "ap-southeast-1"
}

variable "cluster_name" {
  description = "Name prefix for all AWS resources"
  type        = string
  default     = "k8s-lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric with hyphens, max 21 chars."
  }
}

variable "ssh_user" {
  description = "Linux username to SSH with (Ubuntu default: 'ubuntu')"
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key_path" {
  description = "Path to your SSH public key file"
  type        = string
  default     = "~/.ssh/k8s-lab.pub"
}

variable "allowed_cidr" {
  description = "CIDR allowed for SSH, K8s API, and NodePorts. Restrict to your own IP."
  type        = string
  default     = "127.0.0.1/32" # Replace with your IP: curl ifconfig.me

  validation {
    condition     = var.allowed_cidr != "0.0.0.0/0"
    error_message = "allowed_cidr cannot be 0.0.0.0/0. Use a trusted IP/CIDR (e.g., x.x.x.x/32)."
  }
}

variable "allowed_cidrs" {
  description = "Optional list of CIDRs. If set, overrides allowed_cidr."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.allowed_cidrs : c != "0.0.0.0/0"])
    error_message = "allowed_cidrs cannot include 0.0.0.0/0."
  }
}

variable "control_plane_instance_type" {
  description = "EC2 instance type for the control-plane node (minimum: 2 vCPU, 4 GB RAM)"
  type        = string
  default     = "t3.medium"
}

variable "worker_instance_type" {
  description = "EC2 instance type for worker nodes. Online Boutique's 11 services plus later add-ons (observability, service mesh) want more headroom than the bare minimum."
  type        = string
  default     = "t3.large" # 2 vCPU, 8 GB RAM
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 5
    error_message = "worker_count must be between 1 and 5."
  }
}
