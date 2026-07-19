# GKE Cluster Foundation

This optional Terraform root module provisions the actual GKE cluster the
rest of `platforms/gke/` operates against — the GCP equivalent of
`platforms/aks/terraform/`.

- A dedicated VPC and subnet (`network_name`), never the project's shared
  `default` VPC — same reasoning as the AKS track never adopting an
  existing resource group.
- One zonal GKE cluster (`zone`, not a 3-control-plane regional cluster —
  cheaper and simpler for a lab) with a fixed-size **system** node pool
  (GKE system components only — application and load-test Pods never
  schedule here) and one autoscaling **workload** node pool
  (`workloadpool`, 1-4 nodes by default), labelled `workload=autoscale`.
- Dataplane V2 (`datapath_provider = "ADVANCED_DATAPATH"`) — GKE's
  Cilium-based CNI, the same technology the native kubeadm track and the
  AKS track both use, just GKE-managed instead.
- Workload Identity enabled at the cluster level (`workload_pool`) — the
  GCP equivalent of AKS's Key Vault Secrets Provider managed identity,
  used later for a Secret Manager CSI adapter.
- The Persistent Disk CSI driver enabled explicitly (GA default in
  current GKE, declared here so it's a verified fact, not an assumption).
- One Artifact Registry Docker repo, with a dedicated node service
  account (not the project's broad-access default Compute Engine SA)
  granted `artifactregistry.reader` — for custom images, not required for
  the stock Online Boutique manifests.

It does **not** enable the GKE Gateway API controller or anything else
that's a `gcloud container clusters update` operation —
`platforms/gke/scripts/enable-managed-addons.sh` runs those afterward,
deliberately outside Terraform, mirroring the AKS track's
`enable-managed-addons.sh` split. It does not deploy anything into the
cluster either — that's `deploy-core-workloads.sh` and beyond.

## Prerequisites

- Terraform `>= 1.7`.
- An authenticated `gcloud` session (`gcloud auth login` +
  `gcloud auth application-default login`) with permission to create
  networks, GKE clusters, and Artifact Registry repos in the target
  project.
- `gcloud config get-value project` should report the project you
  actually want billed — this configuration doesn't select one for you.

## Deploy

```bash
cd platforms/gke/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit project_id at minimum; region/zone/machine types have defaults.
terraform init
terraform plan
terraform apply
terraform output -raw next_steps
```

Copy the printed values into `platforms/gke/config/gke.env`, then continue
with `platforms/gke/README.md`'s Foundation steps.

## Cost

This creates real, continuously-billed GCP resources (VM instances,
managed disks, a flat GKE cluster management fee) — there is no
meaningful free tier for the always-on control plane. As of this writing:
a flat **$0.10/hour cluster management fee** applies to every GKE cluster
regardless of mode or topology (zonal, regional, or Autopilot) — unlike
AKS, where the Free tier has no such fee at all. GCP does credit
**$74.40/month per billing account**, enough to fully offset exactly one
zonal cluster's management fee — but only if this billing account hasn't
already used that credit elsewhere. Node VM costs (the system and
workload pools) are separate and additional on top of that. Verify
current pricing at
[cloud.google.com/kubernetes-engine/pricing](https://cloud.google.com/kubernetes-engine/pricing)
before applying. Run `terraform destroy` when you're done for the
session; it's not free to leave running.

## Cleanup

Run `platforms/gke/scripts/gke-track.sh destroy` first to remove the
in-cluster workload, then:

```bash
terraform destroy
```

This example uses local state for an individual lab. Configure a remote,
locked backend (a GCS bucket) before using it as a shared environment.
