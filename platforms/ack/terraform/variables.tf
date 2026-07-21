variable "alicloud_profile" { type = string }
variable "cluster_name" { type = string }
variable "kubernetes_version" { type = string }
variable "resource_group_id" { type = string }
variable "control_plane_vswitch_ids" { type = list(string) }
variable "node_vswitch_ids" { type = list(string) }
variable "pod_vswitch_ids" { type = list(string) }
variable "key_name" { type = string }
variable "encryption_provider_key_id" { type = string }
variable "system_instance_types" { type = list(string) }
variable "workload_instance_types" { type = list(string) }

variable "region" {
  type    = string
  default = "ap-southeast-5"
}

variable "cluster_spec" {
  type    = string
  default = "ack.pro.small"
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
