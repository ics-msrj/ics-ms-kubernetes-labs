# AKS Platform Track

This is an additive managed-Kubernetes track for the repository. It preserves
the existing kubeadm curriculum and replaces only the responsibilities owned by
AKS: control plane, node runtime, CNI, CSI storage, node autoscaling, and
managed add-ons.

It must not run `modules/01-cluster-setup` against AKS. Never install a second
CNI, call `kubeadm`, modify the managed control plane, or SSH to AKS nodes.

## Cluster

No AKS cluster to point this at yet? [`terraform/`](terraform/) provisions
one (resource group, system + autoscaling workload node pools, Azure CNI
Overlay with the Cilium data plane, CSI snapshot controller enabled) —
this is the AKS equivalent of Module 01's optional VM Terraform, except
here the control plane is what's being provisioned, not VMs to `kubeadm`
yourself. See [`terraform/README.md`](terraform/README.md), including its
cost note before running `terraform apply`.

Already have a suitable AKS cluster? Skip straight to Foundation below —
`preflight.sh` will tell you exactly what's missing if it isn't ready.

## Foundation

```bash
cp platforms/aks/config/aks.env.example platforms/aks/config/aks.env
# Edit the resource group, AKS cluster, workload pool, and domain settings
# (terraform/'s `next_steps` output has these values if you used it).

bash platforms/aks/scripts/aks-track.sh connect
bash platforms/aks/scripts/aks-track.sh preflight
bash platforms/aks/scripts/aks-track.sh enable-managed-addons

# Wait for the AKS update to finish, then refresh credentials and check again.
bash platforms/aks/scripts/aks-track.sh connect
bash platforms/aks/scripts/aks-track.sh preflight
bash platforms/aks/scripts/aks-track.sh deploy-core-workloads
bash platforms/aks/scripts/aks-track.sh enable-networking
bash platforms/aks/scripts/aks-track.sh enable-storage
```

`enable-managed-addons` enables AKS VPA, KEDA, and the application-routing
Gateway API. The managed GatewayClass is `approuting-istio`; it is not Cilium
and must not be combined with the existing Cilium host-network Gateway setup.

The core workload adapter deploys the actual vendored Online Boutique workload
from Module 02, but replaces `local-path` with AKS `managed-csi`. It does not
install the kubeadm-specific node-exporter DaemonSet.

`enable-networking` is the Module 04 equivalent: it reuses Module 04's own
ClusterIssuers, frontend HTTPRoute, and redis-cart NetworkPolicy manifests
unmodified (none of them have a CNI-specific assumption), installs
cert-manager exactly as Module 04 does, and applies a Gateway that differs
from Module 04's only in `gatewayClassName` (`approuting-istio`, not
`cilium`). Set `APP_DOMAIN`/`ACME_EMAIL`/`TLS_ISSUER` in `aks.env` first —
same variables, same meaning, as `lab.env` on the native track.

## Cleanup

```bash
bash platforms/aks/scripts/aks-track.sh destroy
```

Removes the `online-boutique` namespace only. It does not disable the
managed add-ons `enable-managed-addons.sh` turned on, and it does not touch
the AKS cluster or its node pools — those are Azure-billed resources this
track doesn't own.

## Module Compatibility

| Module | AKS status | AKS treatment |
|---|---|---|
| 00 Prerequisites | Adapt | Add `az`; do not require SSH for AKS operation. |
| 01 Cluster Setup | Replace | AKS owns the control plane, CNI, kubelet, and node lifecycle. |
| 02 Core Workloads | Supported | Use `deploy-core-workloads.sh`; Azure Disk CSI replaces local-path. |
| 03 Config & Secrets | Supported | Run its existing setup after Module 02. |
| 04 Networking & Gateway | Adapt | `enable-networking.sh` — reuses Module 04's ClusterIssuers/HTTPRoute/NetworkPolicy unmodified, Gateway swapped to `approuting-istio`. |
| 05 Storage | Replace | `enable-storage.sh` — redis-cart is already on managed-csi as of Module 02; this confirms CSI snapshot support and takes a real snapshot. |
| 06 Security Policy | Supported | Run its existing setup after Module 02. |
| 07 Scalability & HA | Adapt | AKS supplies Metrics Server and VPA; retain HPA/PDB manifests and use managed KEDA/VPA. |
| 08 Observability | Adapt | Reuse the chart/manifests, but enable its node exporter and omit SSH control-plane patches. |
| 09-12 | Mostly supported | Run after their explicit dependencies are met. |
| 13 Cluster Operations | Replace | No etcd snapshot or kubeadm upgrade access; use AKS backup/upgrade operations. |
| 14 Multi-Cluster | Replace | Import or create a second AKS cluster; do not bootstrap VMs. |
| 15-16 | Supported | Run after Module 08 and the relevant application dependencies. |
| 17 Service Mesh | Adapt | Select the AKS Istio add-on or self-managed Istio; do not combine it with application-routing Gateway API. |
| 18 Chaos Engineering | Partial | Use the AKS capacity GameDay; do not run SSH node-failure experiments. |

## VPA-First Autoscaling

After Module 08 Prometheus and Module 15 OpenCost are deployed, use the
[AKS capacity simulation](../../modules/18-chaos-engineering/docs/aks-autoscaling-simulation.md).
The simulation keeps VPA in `Off` mode, applies reviewed requests, then enables
HPA and observes AKS Cluster Autoscaler add nodes only for unschedulable Pods.

## Platform Decisions

- AKS managed VPA is used instead of installing the upstream VPA chart.
- AKS application-routing Gateway API is used instead of the Cilium Gateway.
- Azure Disk CSI `managed-csi` replaces local-path and Longhorn for this lab.
- AKS system node pools are never selected by application or load-test Pods.

## References

- [AKS application-routing Gateway API](https://learn.microsoft.com/azure/aks/app-routing-gateway-api)
- [AKS Vertical Pod Autoscaler](https://learn.microsoft.com/azure/aks/vertical-pod-autoscaler)
- [AKS Azure Disk CSI storage](https://learn.microsoft.com/azure/aks/create-volume-azure-disk)
