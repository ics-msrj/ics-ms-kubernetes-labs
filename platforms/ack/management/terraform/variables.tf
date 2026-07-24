variable "alicloud_profile" { type = string }
variable "cluster_name" { type = string }
variable "resource_group_id" { type = string }
variable "control_plane_vswitch_ids" { type = list(string) }
variable "node_vswitch_ids" { type = list(string) }
variable "pod_vswitch_ids" { type = list(string) }
variable "key_name" { type = string }
variable "encryption_provider_key_id" { type = string }
variable "management_instance_types" { type = list(string) }

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

variable "environment" {
  type    = string
  default = "platform"
}

variable "service_cidr" {
  type        = string
  description = "Immutable IPv4 CIDR for Services; it must not overlap the VPC or another cluster."

  validation {
    condition     = can(cidrnetmask(var.service_cidr))
    error_message = "service_cidr must be a valid IPv4 CIDR block."
  }
}

variable "create_nat_gateway" {
  type        = bool
  default     = true
  description = "Create an ACK-managed NAT Gateway only when existing VPC egress is unavailable."
}

variable "api_server_public_access" {
  type        = bool
  default     = true
  description = "Expose the API through an ACK SLB. Restrict it with ACK network ACLs immediately after apply."
}

variable "management_node_count" {
  type        = number
  default     = 3
  description = "Three nodes preserve management-plane availability during one node failure."

  validation {
    condition     = var.management_node_count >= 3
    error_message = "management_node_count must be at least three for the Rancher HA management cluster."
  }
}

variable "management_node_labels" {
  type    = map(string)
  default = { "platform.nextops.ai/role" = "management" }
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
  default = "/tmp/ack-nextops-platform-kubeconfig"
}
