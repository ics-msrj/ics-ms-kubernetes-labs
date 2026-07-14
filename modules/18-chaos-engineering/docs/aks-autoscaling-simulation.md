# AKS Autoscaling Capacity Simulation

This GameDay proves a cost-first capacity policy: a workload pool starts at one
`2 vCPU / 8 GiB` node, Pods are sized from reviewed VPA recommendations, HPA
adds replicas under traffic, and AKS Cluster Autoscaler adds a node only after
the requested Pods cannot be scheduled.

It is deliberately separate from `online-boutique` and does not use Chaos Mesh.
Traffic is a controlled capacity event, not a destructive fault.

## Prerequisites

- An AKS workload node pool with Cluster Autoscaler enabled, minimum one and
  maximum three nodes.
- Every node in that pool labelled `workload=autoscale`. Do not apply this
  label to the AKS system pool.
- Module 08 Prometheus installed. Module 15 OpenCost is optional.
- Metrics Server and the VPA CRD installed.
- `kubectl`, `az`, and `jq` authenticated to the intended AKS subscription.

Create the local configuration:

```bash
cp modules/18-chaos-engineering/config/aks-autoscale-sim.env.example \
  modules/18-chaos-engineering/config/aks-autoscale-sim.env
```

## Runbook

```bash
bash modules/18-chaos-engineering/scripts/aks-autoscale/gameday-aks-autoscaling.sh preflight
bash modules/18-chaos-engineering/scripts/aks-autoscale/gameday-aks-autoscaling.sh apply
bash modules/18-chaos-engineering/scripts/aks-autoscale/gameday-aks-autoscaling.sh baseline
bash modules/18-chaos-engineering/scripts/aks-autoscale/gameday-aks-autoscaling.sh vpa-check
bash modules/18-chaos-engineering/scripts/aks-autoscale/gameday-aks-autoscaling.sh enable-hpa

# In a second terminal, observe HPA, Pods, and workload-pool nodes.
bash modules/18-chaos-engineering/scripts/aks-autoscale/gameday-aks-autoscaling.sh watch

bash modules/18-chaos-engineering/scripts/aks-autoscale/gameday-aks-autoscaling.sh gradual
bash modules/18-chaos-engineering/scripts/aks-autoscale/gameday-aks-autoscaling.sh spike
```

The gradual profile runs `5 -> 25 -> 50` virtual users, holds at 50, then
returns to 5. The spike profile moves from 5 to 125 virtual users within one
minute, holds, then rapidly returns to baseline.

The baseline holds 10 virtual users for 20 minutes with no HPA object. VPA
recommendations may require a longer representative observation period; do not
enable HPA merely because this short lab baseline has completed.

## Acceptance Criteria

1. The VPA remains `Off`; recommendations are reviewed before changing the
   target Deployment's requests.
2. HPA observes CPU usage and increases replicas under load.
3. When replicas cannot fit by their CPU/memory *requests*, Pods report an
   unschedulable event and AKS grows the workload pool.
4. After load reduces, HPA reduces replicas. AKS then returns the pool to its
   configured minimum after its own scale-down delay.
5. Each run records Kubernetes state, events, resource usage, k6 output, and,
   when available, an OpenCost allocation response under `artifacts/`.

## Safety Boundaries

- `preflight` rejects a node pool outside the configured `1-3` bounds.
- The target Deployment and k6 Job use `nodeSelector`; neither can land on the
  AKS system pool.
- `cleanup` deletes only the `autoscale-sim` namespace after explicit approval.
- The scripts never change AKS node-pool settings, VPA update mode, or
  Prometheus/OpenCost configuration.
