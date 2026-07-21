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

Create an **ACK Managed Pro** cluster in the console in `ap-southeast-5`.
Use Terway in shared ENI mode with NetworkPolicy enabled, CSI storage, a
fixed system pool, and an autoscaling workload pool. The ALB Gateway API
adapter will later require two ALB-capable vSwitches.

```bash
cp platforms/ack/config/ack.env.example platforms/ack/config/ack.env
# Fill ACK_PROFILE, ACK_CLUSTER_ID, ACK_CLUSTER_NAME, ACK_STORAGE_CLASS,
# and the workload node-pool label from the ACK console.

bash platforms/ack/scripts/ack-track.sh check-prerequisites
bash platforms/ack/scripts/ack-track.sh connect
bash platforms/ack/scripts/ack-track.sh preflight
```

`connect` deliberately does not download or persist credentials. Obtain a
short-lived kubeconfig from the ACK console, set `KUBECONFIG` locally, and
select the expected context before running it.

## First Validated Path

Install `ack-vertical-pod-autoscaler` from **ACK Console -> Cluster ->
Operations -> Add-ons**, then continue:

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
| 08-18 | Pending live validation; do not run provider-sensitive native steps unchanged. |
| 99 | Candidate native module once prerequisite adapters are proven. |

## Cleanup

```bash
bash platforms/ack/scripts/ack-track.sh destroy
```

This removes only lab Kubernetes resources and never deletes an ACK cluster,
node pool, ESSD disk, snapshot, ALB, VPC, or Resource Group.
