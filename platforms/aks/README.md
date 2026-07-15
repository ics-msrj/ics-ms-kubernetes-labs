# AKS Platform Track

This is an additive managed-Kubernetes track for the repository. It preserves
the existing kubeadm curriculum and replaces only the responsibilities owned by
AKS: control plane, node runtime, CNI, CSI storage, node autoscaling, and
managed add-ons.

It must not run `modules/01-cluster-setup` against AKS. Never install a second
CNI, call `kubeadm`, modify the managed control plane, or SSH to AKS nodes.

## Prerequisites

```bash
bash platforms/aks/scripts/aks-track.sh check-prerequisites
```

Same idea as Module 00's own `verify.sh`, with `az` replacing `ssh` as the
one required tool this track needs that the native track doesn't.

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
bash platforms/aks/scripts/aks-track.sh enable-networking      # Module 04
bash platforms/aks/scripts/aks-track.sh enable-storage         # Module 05
bash platforms/aks/scripts/aks-track.sh enable-scaling         # Module 07
bash platforms/aks/scripts/aks-track.sh enable-observability   # Module 08
bash platforms/aks/scripts/aks-track.sh enable-backup          # Module 13
```

## Run natively, unmodified

Modules 03, 06, 09, 10, 11, 12, 15, and 16 have zero infra-specific
assumptions — verified by reading every one of their setup.sh scripts, not
assumed from the table below. Run them exactly as the native track's own
README says to, in order, once their explicit prerequisites above are met:

```bash
bash modules/03-config-secrets/scripts/setup.sh
bash modules/06-security-policy/scripts/setup.sh
bash modules/09-logging/scripts/setup.sh
bash modules/10-package-management/scripts/setup.sh   # or use charts/kustomize directly
bash modules/11-gitops-cicd/scripts/setup.sh           # needs a real Git remote, same as native
bash modules/12-progressive-delivery/scripts/setup.sh  # needed before enable-servicemesh below
bash modules/15-multi-tenancy-cost/scripts/setup.sh
bash modules/16-supply-chain-security/scripts/setup.sh
```

## Optional: Service Mesh (Module 17 equivalent)

Needs Module 12 (frontend must already be a Rollout) and enable-observability
(Prometheus) above:

```bash
bash platforms/aks/scripts/aks-track.sh enable-servicemesh
```

Deliberately self-managed Istio via Helm, not AKS's own Istio service mesh
add-on — that add-on cannot be combined with application-routing's
Istio-based Gateway (confirmed against Microsoft's own docs), and
self-managed Istio has no such conflict since App Routing owns north-south
ingress while this owns east-west mesh traffic.

## Optional: Multi-Cluster (Module 14 equivalent)

Needs a second AKS cluster — same Terraform module, a different workspace:

```bash
cd platforms/aks/terraform && terraform workspace new cluster2
cp terraform.tfvars.example terraform.tfvars   # different cluster_name/resource_group_name
terraform apply
cd -

# Set RANCHER_DOMAIN, SECOND_AKS_RESOURCE_GROUP, SECOND_AKS_CLUSTER_NAME in aks.env
bash platforms/aks/scripts/aks-track.sh enable-multicluster
# Follow the printed instructions to import cluster2 into Rancher, then:
bash platforms/aks/scripts/aks-track.sh promote-canary
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

Removes the `online-boutique` namespace, the `velero` namespace (MinIO/
Velero), and Rancher (if installed). It does not disable the managed
add-ons `enable-managed-addons.sh` turned on, and it does not touch the
AKS cluster or its node pools — those are Azure-billed resources this
track doesn't own. Modules run natively (03/06/09/10/11/12/15/16) and
Istio/Kiali/Tempo (`enable-servicemesh.sh`) aren't covered — clean those
up with their own native `destroy.sh`/`helm uninstall` if needed.

## Module Compatibility

| Module | AKS status | AKS treatment |
|---|---|---|
| 00 Prerequisites | Adapt | `check-prerequisites.sh` — same tool checks as Module 00, `az` replaces `ssh` as the one required addition. |
| 01 Cluster Setup | Replace | AKS owns the control plane, CNI, kubelet, and node lifecycle. |
| 02 Core Workloads | Supported | Use `deploy-core-workloads.sh`; Azure Disk CSI replaces local-path. |
| 03 Config & Secrets | Supported | Run its existing setup after Module 02. |
| 04 Networking & Gateway | Adapt | `enable-networking.sh` — reuses Module 04's ClusterIssuers/HTTPRoute/NetworkPolicy unmodified, Gateway swapped to `approuting-istio`. |
| 05 Storage | Replace | `enable-storage.sh` — redis-cart is already on managed-csi as of Module 02; this confirms CSI snapshot support and takes a real snapshot. |
| 06 Security Policy | Supported | Run its existing setup after Module 02. |
| 07 Scalability & HA | Adapt | `enable-scaling.sh` — skips installing metrics-server/VPA/KEDA (AKS ships/manages them already), reuses Module 07's HPA/VPA/ScaledObject/PDB manifests unmodified. |
| 08 Observability | Adapt | `enable-observability.sh` — `nodeExporter.enabled=true` (opposite of native — no separate DaemonSet to collide with), skips the native PodMonitor, everything else (sealed password, cert-manager ServiceMonitor, PrometheusRule) reused unmodified. |
| 09 Logging | Supported | Run its existing setup after Module 08. |
| 10 Package Management | Supported | Run its existing setup, or use `charts/`/`kustomize/` directly — infra-agnostic either way. |
| 11 GitOps & CI/CD | Supported | Run its existing setup — needs a real Git remote, same requirement as native. |
| 12 Progressive Delivery | Supported | Run its existing setup — required before `enable-servicemesh.sh` (frontend must already be a Rollout). |
| 13 Cluster Operations | Replace | `enable-backup.sh` — no etcd snapshot step (AKS backs up its own control plane); Velero/MinIO/backup/restore manifests reused unmodified from Module 13, only the storage class changed; node drain drill reused, scoped to the workload pool only. |
| 14 Multi-Cluster | Replace | `enable-multicluster.sh` + `promote-canary.sh` — Rancher install and canary-app.yaml reused unmodified from Module 14, only rancher-values.yaml's GatewayClass differs. Second cluster via a Terraform workspace, not bootstrapped VMs. |
| 15 Multi-Tenancy & Cost | Supported | Run its existing setup after Module 08. |
| 16 Supply Chain Security | Supported | Run its existing setup after Modules 02 and 06. |
| 17 Service Mesh | Adapt | `enable-servicemesh.sh` — self-managed Istio via Helm (not the AKS Istio add-on, which conflicts with application-routing's Gateway); everything else reused unmodified from Module 17 except Tempo's storage class. |
| 18 Chaos Engineering | Partial | Use the AKS capacity GameDay (`docs/aks-autoscaling-simulation.md`); do not run the SSH node-failure drill (no SSH access to AKS nodes). |

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
