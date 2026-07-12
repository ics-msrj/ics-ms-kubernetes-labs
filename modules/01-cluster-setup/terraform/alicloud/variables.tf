variable "alicloud_profile" {
  description = "Authenticated Alibaba Cloud CLI/provider profile name. Use the profile reported as current by `aliyun configure list`."
  type        = string
}

variable "region" {
  description = "Alibaba Cloud region for the lab. Jakarta is ap-southeast-5."
  type        = string
  default     = "ap-southeast-5"
}

variable "zone_id" {
  description = "Single-zone lab placement. Start with Jakarta Zone A, then use a separate multi-zone exercise for failure testing."
  type        = string
  default     = "ap-southeast-5a"
}

variable "cluster_name" {
  description = "Name prefix for all Alibaba Cloud resources."
  type        = string
  default     = "k8s-lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric with hyphens, max 21 characters."
  }
}

variable "image_id" {
  description = "Ubuntu 24.04 x86_64 ECS image ID available in the selected Jakarta zone. Query it with aliyun ecs DescribeImages before applying."
  type        = string

  validation {
    condition     = length(trimspace(var.image_id)) > 0
    error_message = "image_id must be a non-empty Ubuntu image ID available in the selected zone."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated Kubernetes lab VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "vswitch_cidr" {
  description = "CIDR block for the lab vSwitch. It must be contained within vpc_cidr."
  type        = string
  default     = "10.42.10.0/24"
}

variable "admin_cidrs" {
  description = "Trusted public CIDRs allowed to SSH to all lab nodes."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for cidr in var.admin_cidrs : cidr != "0.0.0.0/0"])
    error_message = "admin_cidrs must contain at least one trusted CIDR and must not include 0.0.0.0/0."
  }
}

variable "ssh_public_key_path" {
  description = "Local path to the public SSH key installed on the ECS instances."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "control_plane_instance_type" {
  description = "ECS instance type for the control plane. Choose an available 4 vCPU / 8 GiB-or-larger type in Jakarta."
  type        = string
}

variable "worker_instance_type" {
  description = "ECS instance type for both workers. Choose an available 8 vCPU / 16 GiB-or-larger type in Jakarta for the full curriculum."
  type        = string
}

variable "system_disk_category" {
  description = "ECS system disk category supported by the selected zone and instance type."
  type        = string
  default     = "cloud_essd"
}

variable "system_disk_size_gib" {
  description = "System disk size in GiB."
  type        = number
  default     = 80

  validation {
    condition     = var.system_disk_size_gib >= 80
    error_message = "Use at least an 80 GiB system disk for this lab."
  }
}

variable "data_disk_category" {
  description = "ECS data disk category for Longhorn."
  type        = string
  default     = "cloud_essd"
}

variable "data_disk_size_gib" {
  description = "Dedicated Longhorn data disk size per node in GiB."
  type        = number
  default     = 100

  validation {
    condition     = var.data_disk_size_gib >= 100
    error_message = "Use at least a 100 GiB Longhorn data disk per node."
  }
}

variable "longhorn_mount_path" {
  description = "Mount path initialized by cloud-init for the dedicated Longhorn disk."
  type        = string
  default     = "/var/lib/longhorn"
}

variable "initialize_longhorn_disks" {
  description = "Whether cloud-init formats an empty attached data disk and mounts it at longhorn_mount_path."
  type        = bool
  default     = true
}

variable "encrypt_disks" {
  description = "Whether ECS system and Longhorn data disks are encrypted with the account default KMS key."
  type        = bool
  default     = true
}

variable "eip_bandwidth_mbps" {
  description = "Maximum EIP egress bandwidth in Mbps for each node."
  type        = number
  default     = 10

  validation {
    condition     = var.eip_bandwidth_mbps >= 1
    error_message = "eip_bandwidth_mbps must be at least 1."
  }
}
