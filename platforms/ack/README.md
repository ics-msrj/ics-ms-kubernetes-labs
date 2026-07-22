# ACK Platform Track

This is the Alibaba Cloud ACK counterpart to `platforms/aks/` and
`platforms/gke/`. It keeps the native kubeadm curriculum intact and replaces
only responsibilities owned by ACK: control plane, CNI, CSI storage, node
pools, and node autoscaling.

Do not run `modules/01-cluster-setup` against ACK. Never install Cilium as a
second CNI, run `kubeadm`, SSH to managed nodes, or modify ACK system
components directly.

## Status

Foundation plus Modules 02, 03, 04, 05, 06, 07, 08, 09, and 10 now have ACK
entrypoints. Foundation, Modules 02, 05, 06, and 07 have been verified on the
live ACK cluster. Modules 03, 04, 08, 09, and 10 are implemented parity paths
and must be validated in this order on the target cluster; do not describe
them as provider-verified until their own module verification passes.

## Foundation

Provision an **ACK Managed Pro** cluster in `ap-southeast-5` through
[`terraform/`](terraform/), not manually in the console. It uses Terway shared
ENI networking, CSI storage, a fixed system pool, and an autoscaling workload
pool. The ALB Gateway API adapter will later require two ALB-capable vSwitches.
The ACK Redis adapter requests a 20 GiB CSI disk because Alibaba Cloud ESSD
volumes cannot be provisioned below that minimum.

Before Terraform apply, activate ACK Pro and Auto Scaling for the account. In
the ACK console, open the cluster's **Nodes -> Node Pools** page and use
**Enable** next to Node Scaling to authorize
`AliyunCSManagedAutoScalerRole`. The workload pool uses this role when its
autoscaling configuration is created.

```bash
cd platforms/ack/terraform
cp terraform.tfvars.example terraform.tfvars
# Fill existing VPC/vSwitch, Resource Group, KMS, key-pair, version, and type IDs.
terraform init
terraform plan -out=tfplan
# Review the plan, then apply it yourself.

terraform apply tfplan
terraform output -raw next_steps
cd ../../..

cp platforms/ack/config/ack.env.example platforms/ack/config/ack.env
# Fill ACK_CLUSTER_ID and ACK_STORAGE_CLASS from Terraform outputs/kubectl.

bash platforms/ack/scripts/ack-track.sh check-prerequisites
bash platforms/ack/scripts/ack-track.sh connect
bash platforms/ack/scripts/ack-track.sh preflight
```

`connect` deliberately does not download or persist credentials. Obtain a
short-lived kubeconfig from the ACK console, set `KUBECONFIG` locally, and
select the expected context before running it.

## Deployment Order

The Terraform foundation installs the ACK-managed
`ack-vertical-pod-autoscaler` add-on. Confirm its API is ready, then continue:

```bash
bash platforms/ack/scripts/ack-track.sh enable-managed-addons
bash platforms/ack/scripts/ack-track.sh deploy-core-workloads
bash platforms/ack/scripts/ack-track.sh enable-secrets
# Module 04 requires the ALB Ingress Controller v2.17+ and two ALB-capable
# vSwitches in different zones. Install the ACK add-on first; this creates
# GatewayClass `alb`.
bash platforms/ack/scripts/ack-track.sh enable-networking
bash platforms/ack/scripts/ack-track.sh enable-storage

bash modules/06-security-policy/scripts/setup.sh
bash platforms/ack/scripts/ack-track.sh enable-scaling
bash platforms/ack/scripts/ack-track.sh enable-observability
bash platforms/ack/scripts/ack-track.sh enable-logging
bash platforms/ack/scripts/ack-track.sh enable-packages
bash platforms/ack/scripts/ack-track.sh verify-packages
bash platforms/ack/scripts/ack-track.sh enable-gitops
# Commit and push the generated ACK GitOps files when prompted, configure the
# Cloudflare public hostname, then re-run enable-gitops.
bash platforms/ack/scripts/ack-track.sh verify-gitops
bash modules/12-progressive-delivery/scripts/setup.sh
bash modules/12-progressive-delivery/scripts/verify.sh
# Before Module 13: create an ap-southeast-5 cnfs-oss-* bucket, enable Cloud
# Backup/ECS Snapshots, authorize the ACK backup role, and install
# migrate-controller in the ACK console. Then set ACK_BACKUP_* in ack.env.
bash platforms/ack/scripts/ack-track.sh enable-backup
bash platforms/ack/scripts/ack-track.sh run-backup-drill
bash platforms/ack/scripts/ack-track.sh verify-backup
# Deliberately remove the isolated restore and one-time backup afterward.
bash platforms/ack/scripts/ack-track.sh cleanup-backup-drill
bash platforms/ack/scripts/ack-track.sh verify
```

Run each native module's `verify.sh` after its corresponding ACK entrypoint,
except Module 10, which uses `verify-packages` to account for ACK ESSD's
minimum disk size.

Module 11 uses `enable-gitops` and `verify-gitops`. It creates ACK-specific
Application manifests and SealedSecrets because both the ESSD storage settings
and Sealed Secrets controller key are cluster-specific. Configure
`ACK_GITOPS_REPO_URL`, `ACK_GITOPS_REPO_REVISION`, and `ACK_ARGOCD_HOSTNAME`
in `config/ack.env` before running it. The Cloudflare public hostname must
route to `http://argocd-server.argocd.svc.cluster.local:80`; this is dashboard
configuration and does not create an ALB.
The ALB Gateway and Grafana listeners create billable ALB resources. Delete
the Gateway before deleting the cluster or retiring the lab.

## Module 13: ACK Backup Center

Module 13 uses ACK Backup Center rather than a self-hosted Velero/MinIO
installation. In the ACK console, activate Cloud Backup and ECS Snapshots,
create a Jakarta OSS bucket whose name starts with `cnfs-oss-`, authorize the
backup role, and install `migrate-controller`. Set the `ACK_BACKUP_*` values
in `config/ack.env`, then run `enable-backup` to register a `BackupLocation`.
The bucket, prefix, and region are treated as immutable shared vault state.

`run-backup-drill` backs up only `online-boutique`, excludes cluster-scoped
resources, and restores into `online-boutique-restore-drill` with fresh
NodePorts. It does not drain a node or modify the source namespace. Run
`verify-backup`, then `cleanup-backup-drill` to remove the drill through ACK
Backup Center's `DeleteRequest` API. If this repository's earlier MinIO/Velero
attempt exists, remove it separately with `cleanup-legacy-backup`.

The workload pool must be labelled `workload=autoscale` (or the configured
equivalent). Its minimum should be one node and its maximum should initially
be four. ACK adds nodes for Pods that cannot be scheduled from their requested
resources; it does not use a raw 80% node-CPU threshold. Keep VPA in `Off`
mode while reviewing recommendations, then use those requests to create the
pending-Pod condition that drives node-pool scaling.

## Autoscaling Simulation

The ACK capacity simulation is isolated in `ack-autoscale-sim`; it does not
send traffic to Online Boutique or reuse the AKS-specific GameDay scripts. It
uses a VPA in `Off` mode, then explicitly requires a reviewed recommendation
before enabling HPA and either load profile. The target and k6 Job are pinned
to the ACK workload node pool. A scale-out is expected only when replica
**requests** cannot fit, not when node utilization reaches an arbitrary
percentage.

```bash
cp platforms/ack/config/autoscale-sim.env.example \
  platforms/ack/config/autoscale-sim.env

bash platforms/ack/scripts/ack-track.sh autoscaling-sim preflight
bash platforms/ack/scripts/ack-track.sh autoscaling-sim apply
bash platforms/ack/scripts/ack-track.sh autoscaling-sim baseline
bash platforms/ack/scripts/ack-track.sh autoscaling-sim vpa-check

# Review the VPA recommendation. Update request values if required, then set
# ACK_SIM_VPA_REVIEWED="true" in platforms/ack/config/autoscale-sim.env.
bash platforms/ack/scripts/ack-track.sh autoscaling-sim enable-hpa

# Run this in a second terminal while executing one profile at a time.
bash platforms/ack/scripts/ack-track.sh autoscaling-sim watch
bash platforms/ack/scripts/ack-track.sh autoscaling-sim gradual
bash platforms/ack/scripts/ack-track.sh autoscaling-sim spike
```

Evidence is written under `platforms/ack/artifacts/autoscale-sim/` and is
ignored by Git. The gradual profile takes 45 minutes and the spike takes 30
minutes. Both may scale the workload pool to its maximum and create ECS cost.
Use `autoscaling-sim cleanup` after collecting evidence; ACK scale-in follows
its own delay and billing continues until added nodes are released.

## Module Compatibility

| Module | ACK treatment |
|---|---|
| 00 | Adapt: `check-prerequisites.sh` adds `aliyun`. |
| 01 | Replace: ACK Managed Pro, Terway, CSI, and node pools. |
| 02 | Adapt: ACK disk CSI replaces `local-path`. |
| 03 | Adapt: Sealed Secrets with ACK CSI StorageClass substitution. |
| 04 | Adapt: ACK ALB Gateway API (`GatewayClass alb`), not Cilium Gateway. |
| 05 | Replace: ACK CSI VolumeSnapshots replace Longhorn. |
| 06 | Candidate native module; validate after Module 02. |
| 07 | Adapt: ACK VPA plus ACK node-pool autoscaling; KEDA remains pending live validation. |
| 08 | Adapt: kube-prometheus-stack with managed-node exporter and ALB Gateway listener. |
| 09 | Adapt: native Loki/Alloy with ACK CSI StorageClass. |
| 10 | Adapt: native Helm/Kustomize with ACK CSI and workload-pool selector. |
| 11 | Adapt: ArgoCD uses ACK-specific Applications and Cloudflare Tunnel exposure. |
| 12 | Candidate native module; validate before the Module 13 restore drill. |
| 13 | Replace: ACK Backup Center (`migrate-controller`), OSS BackupLocation, ECS CSI snapshots, and isolated restore drill. |
| 14-17 | Pending live validation; do not run provider-sensitive native steps unchanged. |
| 18 | Adapt: isolated ACK VPA-first capacity simulation; other chaos experiments remain pending. |
| 99 | Candidate native module once prerequisite adapters are proven. |

## Cleanup

```bash
bash platforms/ack/scripts/ack-track.sh destroy
```

This removes only the application lab resources. It does not remove ACK Backup
Center vaults, backup records, ECS snapshots, ALB, VPC, node pools, or the ACK
cluster. Use `cleanup-backup-drill` for the explicit one-time backup cleanup.
