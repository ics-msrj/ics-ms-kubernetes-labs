# Rancher Management VM — Terraform

This Terraform root provisions a single Ubuntu 24.04 VM in a new, dedicated
resource group (`rg-ics-ms-prod-sgp-001` by default). It does not touch
`rg-nextops-prod-jkt-001` or any other existing resource group — confirmed
live via `az group list` that nothing existing was suitable to reuse for an
isolated management VM.

It stops at "a reachable VM with an SSH key installed." The Kubernetes
cluster on top (kubeadm, Cilium) and Rancher itself are installed afterward
over SSH/kubectl by `../scripts/`, the same split used by
`modules/01-cluster-setup/terraform/aws`.

```bash
cd platforms/aks/management/terraform
cp terraform.tfvars.example terraform.tfvars
# Fill subscription_id, admin_cidr (your own IP, never 0.0.0.0/0), and
# ssh_public_key_path.
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
terraform show tfplan
# Review the billable VM, disk, public IP, and NSG before applying.
terraform apply tfplan
```

The generated `terraform.tfvars` and `backend.hcl` are git-ignored. There is
no deletion-protection equivalent for a raw VM (unlike the managed-cluster
`deletion_protection = true` used elsewhere in this repo) — be deliberate
before `terraform destroy`: Rancher's state (etcd on this VM) has no backup
plan yet, and downstream clusters lose their management-server connection
the moment this VM goes away.
