# =============================================================================
# Rancher management cluster — Azure, southeastasia. 1 control-plane VM + 1
# worker VM.
#
# Unlike platforms/aks/terraform (which provisions an actual AKS cluster),
# this provisions raw VMs. The Kubernetes cluster on top is self-managed
# (kubeadm) — see ../scripts/bootstrap-control-plane.sh and
# ../scripts/bootstrap-worker.sh, which mirror
# modules/01-cluster-setup/scripts/setup-control-plane.sh and
# setup-worker.sh. Terraform's job stops at "two reachable Ubuntu VMs";
# everything Kubernetes-shaped happens over SSH after this applies, exactly
# like modules/01-cluster-setup/terraform/aws.
#
# Deliberately 2 nodes, not 1: a single-node kubeadm+Cilium node was found
# live not to reliably survive a reboot (cilium/cilium#44194). Splitting
# control-plane and worker contains the blast radius if that recurs on
# either node, and lets them be patched one at a time.
#
# State is local by default — for a real team setup, configure a remote
# backend (see backend.hcl.example) before running this for real.
# =============================================================================

provider "azurerm" {
  features {}
  # Pinned explicitly for the same reason as platforms/aks/terraform/main.tf.
  subscription_id = var.subscription_id
}

# create_resource_group defaults to true here (opposite of
# platforms/aks/terraform's default) — confirmed live via `az group list`
# that no existing resource group is suitable to adopt for this isolated
# management cluster; rg-nextops-prod-jkt-001 is the shared AKS workload RG
# and deliberately not reused.
resource "azurerm_resource_group" "management" {
  count = var.create_resource_group ? 1 : 0

  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

data "azurerm_resource_group" "existing" {
  count = var.create_resource_group ? 0 : 1

  name = var.resource_group_name
}

locals {
  resource_group_name = var.create_resource_group ? azurerm_resource_group.management[0].name : data.azurerm_resource_group.existing[0].name
}

# ── Networking — first azurerm VNet/NSG/VM convention in this repo ──────────
# Shared by both nodes — a single /26 subnet, one NSG associated at the
# subnet level (covers both nodes' NICs without a per-NIC association).

resource "azurerm_virtual_network" "management" {
  name                = var.vnet_name
  address_space       = [var.vnet_cidr]
  location            = var.location
  resource_group_name = local.resource_group_name
  tags                = var.tags
}

resource "azurerm_subnet" "management" {
  name                 = var.subnet_name
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.management.name
  address_prefixes     = [var.subnet_cidr]
}

# SSH from admin_cidr only. No other inbound rule exists: Rancher is reached
# solely through the outbound Cloudflare Tunnel connector (see
# manifests/rancher/values.yaml — networkExposure.type=none,
# ingress.enabled=false, service.type=ClusterIP). This is deliberately
# tighter than modules/01-cluster-setup/terraform/aws (which opens 6443 +
# NodePort range for teaching-lab convenience) — a real management server
# doesn't need either exposed. Worker-to-control-plane traffic (6443, kubelet,
# etc.) doesn't need an explicit rule — same-subnet traffic is allowed by
# Azure's default NSG rules (AllowVnetInBound) unless overridden, and this
# NSG only adds a rule, never removes that default.
resource "azurerm_network_security_group" "management" {
  name                = "nsg-ics-ms-sgp-001"
  location            = var.location
  resource_group_name = local.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "AllowSSHFromAdmin"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.admin_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "management" {
  subnet_id                 = azurerm_subnet.management.id
  network_security_group_id = azurerm_network_security_group.management.id
}

# ── Control plane ────────────────────────────────────────────────────────

resource "azurerm_public_ip" "control_plane" {
  name                = "pip-ics-ms-sgp-001"
  location            = var.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "control_plane" {
  name                = "nic-ics-ms-sgp-001"
  location            = var.location
  resource_group_name = local.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.management.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.control_plane.id
  }
}

resource "azurerm_linux_virtual_machine" "control_plane" {
  name                = var.control_plane_vm_name
  location            = var.location
  resource_group_name = local.resource_group_name
  size                = var.control_plane_vm_size
  admin_username      = var.admin_username
  network_interface_ids = [
    azurerm_network_interface.control_plane.id,
  ]
  tags = var.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  # Same Ubuntu 24.04 LTS as modules/01-cluster-setup/terraform/aws's AMI
  # filter (ubuntu-noble-24.04-amd64-server-*) — "server" is the standard
  # gen2 SKU (confirmed via `az vm image list --publisher Canonical --offer
  # ubuntu-24_04-lts`; "cvm"/"minimal"/"*-arm64" are not it).
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
    #!/bin/bash
    hostnamectl set-hostname ${var.control_plane_node_name}
    echo "127.0.1.1 ${var.control_plane_node_name}" >> /etc/hosts
  EOF
  )
}

# ── Worker ────────────────────────────────────────────────────────────────

resource "azurerm_public_ip" "worker" {
  name                = "pip-ics-ms-worker-sgp-001"
  location            = var.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "worker" {
  name                = "nic-ics-ms-worker-sgp-001"
  location            = var.location
  resource_group_name = local.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.management.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.worker.id
  }
}

resource "azurerm_linux_virtual_machine" "worker" {
  name                = var.worker_vm_name
  location            = var.location
  resource_group_name = local.resource_group_name
  size                = var.worker_vm_size
  admin_username      = var.admin_username
  network_interface_ids = [
    azurerm_network_interface.worker.id,
  ]
  tags = var.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
    #!/bin/bash
    hostnamectl set-hostname ${var.worker_node_name}
    echo "127.0.1.1 ${var.worker_node_name}" >> /etc/hosts
  EOF
  )
}
