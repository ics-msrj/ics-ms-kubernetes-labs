# =============================================================================
# OPTIONAL — three-node kubeadm lab on Alibaba Cloud ECS (Jakarta by default).
#
# This provisions only the cloud foundation. Module 01's existing scripts still
# install containerd, kubeadm, and Cilium after Terraform prints lab.env values.
# State is local for a personal lab; configure a remote backend before a team
# shares this environment.
# =============================================================================

provider "alicloud" {
  region  = var.region
  profile = var.alicloud_profile
}

locals {
  common_tags = {
    Project     = "kubernetes-learning-lab"
    Module      = "01-cluster-setup"
    Environment = "lab"
    ManagedBy   = "terraform"
    ClusterName = var.cluster_name
  }

  nodes = {
    control = {
      hostname      = "k8s-control"
      instance_type = var.control_plane_instance_type
      role          = "control-plane"
    }
    worker_01 = {
      hostname      = "k8s-worker-01"
      instance_type = var.worker_instance_type
      role          = "worker"
    }
    worker_02 = {
      hostname      = "k8s-worker-02"
      instance_type = var.worker_instance_type
      role          = "worker"
    }
  }
}

resource "alicloud_vpc" "lab" {
  vpc_name    = "${var.cluster_name}-vpc"
  cidr_block  = var.vpc_cidr
  description = "Dedicated VPC for the Kubernetes learning lab"
  tags        = merge(local.common_tags, { Name = "${var.cluster_name}-vpc" })
}

resource "alicloud_vswitch" "lab" {
  vswitch_name = "${var.cluster_name}-vswitch"
  vpc_id       = alicloud_vpc.lab.id
  zone_id      = var.zone_id
  cidr_block   = var.vswitch_cidr
  description  = "Kubernetes lab nodes in ${var.zone_id}"
  tags         = merge(local.common_tags, { Name = "${var.cluster_name}-vswitch" })
}

resource "alicloud_security_group" "nodes" {
  security_group_name = "${var.cluster_name}-nodes"
  vpc_id              = alicloud_vpc.lab.id
  description         = "Kubernetes learning lab node access"
  tags                = merge(local.common_tags, { Name = "${var.cluster_name}-nodes" })
}

resource "alicloud_security_group_rule" "ssh" {
  for_each = toset(var.admin_cidrs)

  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "22/22"
  priority          = 1
  security_group_id = alicloud_security_group.nodes.id
  cidr_ip           = each.value
  description       = "SSH from an approved administrator CIDR"
}

resource "alicloud_security_group_rule" "gateway_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "80/80"
  priority          = 10
  security_group_id = alicloud_security_group.nodes.id
  cidr_ip           = "0.0.0.0/0"
  description       = "Cilium Gateway HTTP and ACME HTTP-01"
}

resource "alicloud_security_group_rule" "gateway_https" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "443/443"
  priority          = 10
  security_group_id = alicloud_security_group.nodes.id
  cidr_ip           = "0.0.0.0/0"
  description       = "Cilium Gateway HTTPS"
}

resource "alicloud_security_group_rule" "node_to_node" {
  type                     = "ingress"
  ip_protocol              = "all"
  nic_type                 = "intranet"
  policy                   = "accept"
  port_range               = "-1/-1"
  priority                 = 1
  security_group_id        = alicloud_security_group.nodes.id
  source_security_group_id = alicloud_security_group.nodes.id
  description              = "Kubernetes, Cilium, and Longhorn node-to-node traffic"
}

resource "alicloud_security_group_rule" "egress" {
  type              = "egress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.nodes.id
  cidr_ip           = "0.0.0.0/0"
  description       = "Package, image, Helm, GitOps, and ACME egress"
}

resource "alicloud_key_pair" "lab" {
  key_pair_name = "${var.cluster_name}-key"
  public_key    = file(pathexpand(var.ssh_public_key_path))
  tags          = local.common_tags
}

resource "alicloud_instance" "nodes" {
  for_each = local.nodes

  instance_name              = "${var.cluster_name}-${each.value.role}-${each.key}"
  host_name                  = each.value.hostname
  image_id                   = var.image_id
  instance_type              = each.value.instance_type
  availability_zone          = var.zone_id
  vswitch_id                 = alicloud_vswitch.lab.id
  security_groups            = [alicloud_security_group.nodes.id]
  key_name                   = alicloud_key_pair.lab.key_pair_name
  instance_charge_type       = "PostPaid"
  system_disk_category       = var.system_disk_category
  system_disk_size           = var.system_disk_size_gib
  system_disk_encrypted      = var.encrypt_disks
  internet_charge_type       = "PayByTraffic"
  internet_max_bandwidth_out = 0
  user_data = templatefile("${path.module}/cloud-init.sh.tftpl", {
    hostname        = each.value.hostname
    longhorn_mount  = var.longhorn_mount_path
    initialize_disk = var.initialize_longhorn_disks
  })

  data_disks {
    name                 = "${var.cluster_name}-${each.key}-longhorn"
    category             = var.data_disk_category
    size                 = var.data_disk_size_gib
    encrypted            = var.encrypt_disks
    delete_with_instance = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-${each.value.role}-${each.key}"
    Role = each.value.role
  })
}

resource "alicloud_eip_address" "nodes" {
  for_each = local.nodes

  address_name         = "${var.cluster_name}-${each.key}-eip"
  bandwidth            = var.eip_bandwidth_mbps
  internet_charge_type = "PayByTraffic"
  tags                 = merge(local.common_tags, { Name = "${var.cluster_name}-${each.key}-eip" })
}

resource "alicloud_eip_association" "nodes" {
  for_each = local.nodes

  allocation_id = alicloud_eip_address.nodes[each.key].id
  instance_id   = alicloud_instance.nodes[each.key].id
  instance_type = "EcsInstance"
}
