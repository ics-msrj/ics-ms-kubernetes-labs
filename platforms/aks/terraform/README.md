# AKS Cluster Foundation

This optional Terraform root module provisions the actual AKS cluster the
rest of `platforms/aks/` operates against:

- One resource group — created by default (`create_resource_group = true`).
  Set it to `false` to target an existing resource group instead (e.g. a
  shared or production one you don't want this configuration creating,
  adopting, or re-tagging — it's then looked up as a read-only data source
  and nothing about the resource group itself is managed here).
- One AKS cluster with a fixed-size **system** node pool (AKS system
  components only — application and load-test Pods never schedule here).
- One autoscaling **workload** node pool (`workloadpool`, 1-3 nodes by
  default), labelled `workload=autoscale` — this is where Online Boutique
  and every later add-on run.
- Azure CNI Overlay with the Cilium data plane (`network_data_plane =
  "cilium"`) — the same CNI technology the native kubeadm track uses,
  just AKS-managed instead of self-installed.
- The CSI snapshot controller enabled at create time (off by default on
  AKS; Module 05's VolumeSnapshot support needs it).
- One Azure Container Registry (`container_registry_name`), with the
  cluster's kubelet identity granted `AcrPull` on it — for custom images,
  not required for the stock Online Boutique manifests (those pull public
  images directly).
- Optionally, customer-managed-key (CMK) disk encryption via
  `disk_encryption_set_id` — references an existing
  `azurerm_disk_encryption_set`, never creates one. Leave unset for
  Azure's platform-managed key.

It does **not** enable VPA, KEDA, or the application-routing Gateway API —
those are `az aks update` operations `platforms/aks/scripts/
enable-managed-addons.sh` runs afterward, deliberately outside Terraform
(this configuration's `lifecycle.ignore_changes` accounts for that so a
later `terraform apply` doesn't fight it). It does not deploy anything
into the cluster either — that's `deploy-core-workloads.sh` and beyond.

## Prerequisites

- Terraform `>= 1.7`.
- An authenticated `az` session (`az login`) with permission to create
  resource groups and AKS clusters in the target subscription.
- `az account show` should report the subscription you actually want
  billed — this configuration doesn't select one for you.

## Deploy

```bash
cd platforms/aks/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit location, resource_group_name, cluster_name, and VM sizes for your
# subscription's quota if the defaults don't fit.
terraform init
terraform plan
terraform apply
terraform output -raw next_steps
```

Copy the printed values into `platforms/aks/config/aks.env`, then continue
with `platforms/aks/README.md`'s Foundation steps.

## Cost

This creates real, continuously-billed Azure resources (VMs, standard
Load Balancer, managed disks) — unlike the native track's VM-only
Terraform examples, AKS itself does not have a meaningful free tier for
the always-on control plane in most subscription types. Run
`terraform destroy` when you're done for the session; it's not free to
leave running.

## Cleanup

Run `platforms/aks/scripts/aks-track.sh destroy` first to remove the
in-cluster workload, then:

```bash
terraform destroy
```

This example uses local state for an individual lab. Configure a remote,
locked backend before using it as a shared environment.
