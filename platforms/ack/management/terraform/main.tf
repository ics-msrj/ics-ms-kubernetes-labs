provider "alicloud" {
  region  = var.region
  profile = var.alicloud_profile
}

locals {
  tags = {
    Name        = var.cluster_name
    Project     = "kubernetes-learning-lab"
    Platform    = "ack"
    Role        = "management"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Shared network, Resource Group, key pair, and KMS key are inputs. Keeping
# them external prevents this management-cluster state from modifying workload
# cluster networking.
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

resource "alicloud_cs_kubernetes_node_pool" "management" {
  cluster_id            = alicloud_cs_managed_kubernetes.this.id
  node_pool_name        = "management"
  resource_group_id     = var.resource_group_id
  vswitch_ids           = var.node_vswitch_ids
  instance_types        = var.management_instance_types
  desired_size          = var.management_node_count
  instance_charge_type  = "PostPaid"
  key_name              = var.key_name
  system_disk_category  = var.system_disk_category
  system_disk_size      = var.system_disk_size_gib
  install_cloud_monitor = true
  tags                  = merge(local.tags, { NodePool = "management" })

  dynamic "labels" {
    for_each = var.management_node_labels
    content {
      key   = labels.key
      value = labels.value
    }
  }
}

data "alicloud_cs_cluster_credential" "this" {
  cluster_id                 = alicloud_cs_managed_kubernetes.this.id
  temporary_duration_minutes = 60
  output_file                = var.kubeconfig_output_path
}
