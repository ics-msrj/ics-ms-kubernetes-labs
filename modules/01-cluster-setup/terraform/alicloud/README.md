# Alibaba Cloud ECS Foundation

This optional Terraform root module creates the three-node Alibaba Cloud ECS
foundation used by the Kubernetes learning lab:

- Jakarta region (`ap-southeast-5`) and one selected zone by default.
- One VPC, one vSwitch, and a dedicated security group.
- One control-plane and two worker ECS instances, each with an EIP.
- One encrypted Longhorn data disk per node, initialized by cloud-init at
  `/var/lib/longhorn`.

It does **not** install Kubernetes. Its outputs feed the existing `lab.env`
contract, after which you run Module 00 and Module 01 normally.

## Prerequisites

- Terraform `>= 1.7`.
- An authenticated Alibaba Cloud CLI profile. Run `aliyun configure list` and
  set `alicloud_profile` to the profile reported as current; Terraform uses
  that named profile.
- An SSH public key.
- An Ubuntu 24.04 x86_64 ECS image ID and instance types available in the
  chosen Jakarta zone. Do not hardcode these: capacity and image IDs vary by
  zone and account.

## Deploy

```bash
cd modules/01-cluster-setup/terraform/alicloud
cp terraform.tfvars.example terraform.tfvars
# Edit alicloud_profile, image_id, admin_cidrs, and the available ECS types.
terraform init
terraform plan
terraform apply
terraform output -raw next_steps
```

Copy the printed values into the repository-root `lab.env`. Before Module 05,
confirm the dedicated disk is mounted on each node:

```bash
ssh ubuntu@<node-eip> 'findmnt /var/lib/longhorn'
```

## Network Contract

- SSH is restricted to `admin_cidrs`.
- Cilium Gateway needs public TCP 80/443 for Module 04 and ACME HTTP-01.
- Kubernetes API port 6443 is deliberately not public; Module 01 reaches it
  over SSH.
- Node-to-node traffic is allowed only by security-group reference.

The module intentionally assigns EIPs to workers because the current Module 01
bootstrap scripts SSH to each worker directly. Replacing this with a bastion
and `ProxyJump` is a separate hardening change to those scripts.

## Cleanup

Run the repository's Kubernetes cleanup first if applicable, then:

```bash
terraform destroy
```

This example uses local state for an individual lab. Configure a remote,
locked backend before using it as a shared environment.
