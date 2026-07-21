variable "alicloud_profile" { type = string }
variable "cluster_name" { type = string }
variable "resource_group_id" { type = string }
variable "control_plane_vswitch_ids" { type = list(string) }
variable "node_vswitch_ids" { type = list(string) }
variable "pod_vswitch_ids" { type = list(string) }
variable "service_cidr" {
  type        = string
  description = "Immutable IPv4 CIDR used for Kubernetes Services; it must not overlap the VPC or another cluster CIDR."

  validation {
    condition     = can(cidrnetmask(var.service_cidr))
    error_message = "service_cidr must be a valid IPv4 CIDR block."
  }
}
variable "key_name" { type = string }
variable "encryption_provider_key_id" { type = string }
variable "system_instance_types" { type = list(string) }
variable "workload_instance_types" { type = list(string) }

variable "region" {
  type    = string
  default = "ap-southeast-5"
}

variable "kubernetes_version" {
  type     = string
  default  = null
  nullable = true
}

variable "cluster_spec" {
  type    = string
  default = "ack.pro.small"
}

variable "create_nat_gateway" {
  type        = bool
  default     = true
  description = "Create the ACK-managed NAT Gateway required for outbound node and Pod connectivity."
}

variable "api_server_public_access" {
  type        = bool
  default     = true
  description = "Expose the API server through an Internet-facing SLB for temporary local kubeconfig access."
}

variable "environment" {
  type    = string
  default = "lab"
}

variable "system_node_count" {
  type    = number
  default = 2
}

variable "workload_nodepool_name" {
  type    = string
  default = "workloadpool"
}

variable "workload_min_size" {
  type    = number
  default = 1
}

variable "workload_max_size" {
  type    = number
  default = 4
}

variable "workload_node_labels" {
  type    = map(string)
  default = { workload = "autoscale" }
}

variable "system_disk_category" {
  type    = string
  default = "cloud_essd"
}

variable "system_disk_size_gib" {
  type    = number
  default = 80
}

variable "kubeconfig_output_path" {
  type    = string
  default = "/tmp/ack-nextops-production-kubeconfig"
}
