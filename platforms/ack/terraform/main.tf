provider "alicloud" {
  region  = var.region
  profile = var.alicloud_profile
}

locals {
  tags = {
    Name        = var.cluster_name
    Project     = "kubernetes-learning-lab"
    Platform    = "ack"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Network and Resource Group are inputs. This module must not make changes to
# shared VPC, vSwitch, NAT, route, or security-group infrastructure.
resource "alicloud_cs_managed_kubernetes" "this" {
  name              = var.cluster_name
  cluster_spec      = var.cluster_spec
  version           = var.kubernetes_version
  resource_group_id = var.resource_group_id
  vswitch_ids       = var.control_plane_vswitch_ids
  pod_vswitch_ids   = var.pod_vswitch_ids
  service_cidr      = var.service_cidr
  new_nat_gateway   = var.create_nat_gateway

  slb_internet_enabled    = var.api_server_public_access
  deletion_protection     = true
  encryption_provider_key = var.encryption_provider_key_id

  tags = local.tags

  addons {
    name = "terway-eniip"
  }

  addons {
    name = "csi-plugin"
  }

  addons {
    name = "csi-provisioner"
  }
}

resource "alicloud_cs_kubernetes_node_pool" "system" {
  cluster_id            = alicloud_cs_managed_kubernetes.this.id
  node_pool_name        = "systempool"
  resource_group_id     = var.resource_group_id
  vswitch_ids           = var.node_vswitch_ids
  instance_types        = var.system_instance_types
  desired_size          = var.system_node_count
  instance_charge_type  = "PostPaid"
  key_name              = var.key_name
  system_disk_category  = var.system_disk_category
  system_disk_size      = var.system_disk_size_gib
  install_cloud_monitor = true
  tags                  = merge(local.tags, { NodePool = "systempool" })
}

resource "alicloud_cs_kubernetes_node_pool" "workload" {
  cluster_id            = alicloud_cs_managed_kubernetes.this.id
  node_pool_name        = var.workload_nodepool_name
  resource_group_id     = var.resource_group_id
  vswitch_ids           = var.node_vswitch_ids
  instance_types        = var.workload_instance_types
  instance_charge_type  = "PostPaid"
  key_name              = var.key_name
  system_disk_category  = var.system_disk_category
  system_disk_size      = var.system_disk_size_gib
  install_cloud_monitor = true
  tags                  = merge(local.tags, { NodePool = var.workload_nodepool_name })

  dynamic "labels" {
    for_each = var.workload_node_labels
    content {
      key   = labels.key
      value = labels.value
    }
  }

  scaling_config {
    min_size = var.workload_min_size
    max_size = var.workload_max_size
    type     = "cpu"
  }
}

# Keep the ACK-managed VPA implementation under Terraform rather than applying
# upstream VPA manifests, which are not the supported path for ACK 1.26+.
resource "alicloud_cs_kubernetes_addon" "vertical_pod_autoscaler" {
  cluster_id = alicloud_cs_managed_kubernetes.this.id
  name       = "ack-vertical-pod-autoscaler"
}

# ACK manages the controller. A subsequent Gateway using GatewayClass `alb`
# provisions the billable ALB, so installing this add-on alone creates no
# application-facing load balancer.
resource "alicloud_cs_kubernetes_addon" "alb_ingress_controller" {
  cluster_id = alicloud_cs_managed_kubernetes.this.id
  name       = "alb-ingress-controller"
}

data "alicloud_cs_cluster_credential" "this" {
  cluster_id                 = alicloud_cs_managed_kubernetes.this.id
  temporary_duration_minutes = 60
  output_file                = var.kubeconfig_output_path
}
