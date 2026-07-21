# ACK Platform Track

This is the Alibaba Cloud ACK counterpart to `platforms/aks/` and
`platforms/gke/`. It keeps the native kubeadm curriculum intact and replaces
only responsibilities owned by ACK: control plane, CNI, CSI storage, node
pools, and node autoscaling.

Do not run `modules/01-cluster-setup` against ACK. Never install Cilium as a
second CNI, run `kubeadm`, SSH to managed nodes, or modify ACK system
components directly.

## Status

Foundation plus Modules 02, 05, and 07 adapters are implemented but not yet
validated against a live ACK cluster. Run each stage below in order and record
provider-specific fixes before adding networking, observability, backup,
service-mesh, or chaos adapters.

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

## First Validated Path

The Terraform foundation installs the ACK-managed
`ack-vertical-pod-autoscaler` add-on. Confirm its API is ready, then continue:

```bash
bash platforms/ack/scripts/ack-track.sh enable-managed-addons
bash platforms/ack/scripts/ack-track.sh deploy-core-workloads
bash platforms/ack/scripts/ack-track.sh enable-storage

# Module 06 is unchanged and should be validated before scaling policy work.
bash modules/06-security-policy/scripts/setup.sh
bash platforms/ack/scripts/ack-track.sh enable-scaling
bash platforms/ack/scripts/ack-track.sh verify
```

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
| 03 | Pending: validate Sealed Secrets and ACK StorageClass substitution. |
| 04 | Pending: use ACK ALB Gateway API, not Cilium Gateway. |
| 05 | Replace: ACK CSI VolumeSnapshots replace Longhorn. |
| 06 | Candidate native module; validate after Module 02. |
| 07 | Adapt: ACK VPA plus ACK node-pool autoscaling; KEDA remains pending live validation. |
| 08-17 | Pending live validation; do not run provider-sensitive native steps unchanged. |
| 18 | Adapt: isolated ACK VPA-first capacity simulation; other chaos experiments remain pending. |
| 99 | Candidate native module once prerequisite adapters are proven. |

## Cleanup

```bash
bash platforms/ack/scripts/ack-track.sh destroy
```

This removes only lab Kubernetes resources and never deletes an ACK cluster,
node pool, ESSD disk, snapshot, ALB, VPC, or Resource Group.
