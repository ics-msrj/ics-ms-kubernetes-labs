# =============================================================================
# OPTIONAL — example VM provisioning on AWS EC2.
#
# The kubeadm scripts in ../../scripts/ only need SSH access to a handful of
# Ubuntu VMs — they don't care how those VMs were created. If you already
# have VMs (any cloud, homelab, bare metal), skip this directory entirely
# and go straight to setup-control-plane.sh / setup-worker.sh.
#
# This is provided as a runnable reference for provisioning raw VMs with
# Terraform on one provider (AWS). State is local by default — for a real
# team setup, configure a remote backend before running this for real.
# =============================================================================

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  tags = {
    Project     = "k8s-learning-lab"
    Module      = "01-cluster-setup"
    Environment = "lab"
    ManagedBy   = "terraform"
    ClusterName = var.cluster_name
  }

  tags_control_plane = merge(local.tags, { Role = "control-plane" })
  tags_worker        = merge(local.tags, { Role = "worker" })

  effective_allowed_cidrs = length(var.allowed_cidrs) > 0 ? var.allowed_cidrs : [var.allowed_cidr]
}

# ── Ubuntu 24.04 LTS AMI ──────────────────────────────────────────────────────

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ── Networking ────────────────────────────────────────────────────────────────

resource "aws_vpc" "lab" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(local.tags, { Name = "${var.cluster_name}-vpc" })
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = merge(local.tags, { Name = "${var.cluster_name}-igw" })
}

resource "aws_subnet" "lab" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "${var.cluster_name}-subnet" })
}

resource "aws_route_table" "lab" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }
  tags = merge(local.tags, { Name = "${var.cluster_name}-rt" })
}

resource "aws_route_table_association" "lab" {
  subnet_id      = aws_subnet.lab.id
  route_table_id = aws_route_table.lab.id
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-nodes"
  description = "K8s learning lab nodes"
  vpc_id      = aws_vpc.lab.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = local.effective_allowed_cidrs
    description = "SSH"
  }

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = local.effective_allowed_cidrs
    description = "Kubernetes API server (for the SSH-tunneled kubeconfig)"
  }

  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = local.effective_allowed_cidrs
    description = "NodePort services"
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
    description = "Node-to-node traffic"
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
    description = "VPC internal traffic"
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.244.0.0/16"]
    description = "Cilium pod network"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound"
  }

  tags = merge(local.tags, { Name = "${var.cluster_name}-sg" })
}

# ── SSH Key Pair ──────────────────────────────────────────────────────────────

resource "aws_key_pair" "lab" {
  key_name   = "${var.cluster_name}-key"
  public_key = file(var.ssh_public_key_path)
  tags       = local.tags
}

# ── Control Plane ──────────────────────────────────────────────────────────────

resource "aws_instance" "control_plane" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.control_plane_instance_type
  subnet_id              = aws_subnet.lab.id
  vpc_security_group_ids = [aws_security_group.nodes.id]
  key_name               = aws_key_pair.lab.key_name
  source_dest_check      = false # required for pod networking

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = <<-EOF
    #!/bin/bash
    hostnamectl set-hostname k8s-control
    echo "127.0.1.1 k8s-control" >> /etc/hosts
  EOF

  tags = merge(local.tags_control_plane, { Name = "${var.cluster_name}-control-plane" })
}

resource "aws_eip" "control_plane" {
  instance   = aws_instance.control_plane.id
  domain     = "vpc"
  tags       = merge(local.tags_control_plane, { Name = "${var.cluster_name}-control-plane-eip" })
  depends_on = [aws_internet_gateway.lab]
}

# ── Workers ────────────────────────────────────────────────────────────────────

resource "aws_instance" "workers" {
  count                  = var.worker_count
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.worker_instance_type
  subnet_id              = aws_subnet.lab.id
  vpc_security_group_ids = [aws_security_group.nodes.id]
  key_name               = aws_key_pair.lab.key_name
  source_dest_check      = false

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = <<-EOF
    #!/bin/bash
    hostnamectl set-hostname k8s-worker-0${count.index + 1}
    echo "127.0.1.1 k8s-worker-0${count.index + 1}" >> /etc/hosts
  EOF

  tags = merge(local.tags_worker, { Name = "${var.cluster_name}-worker-${count.index + 1}" })
}

resource "aws_eip" "workers" {
  count      = var.worker_count
  instance   = aws_instance.workers[count.index].id
  domain     = "vpc"
  tags       = merge(local.tags_worker, { Name = "${var.cluster_name}-worker-${count.index + 1}-eip" })
  depends_on = [aws_internet_gateway.lab]
}
