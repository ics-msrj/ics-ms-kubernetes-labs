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
bash platforms/aks/scripts/aks-track.sh enable-secrets         # Module 03 — see below if AKS_KEY_VAULT_NAME isn't set
bash platforms/aks/scripts/aks-track.sh enable-networking      # Module 04
bash platforms/aks/scripts/aks-track.sh enable-storage         # Module 05
bash platforms/aks/scripts/aks-track.sh enable-scaling         # Module 07
bash platforms/aks/scripts/aks-track.sh enable-observability   # Module 08
bash platforms/aks/scripts/aks-track.sh enable-backup          # Module 13

bash platforms/aks/scripts/aks-track.sh verify
```

`verify` is one aggregate check across the whole Foundation flow — every
native module has its own `verify.sh`, but the individual `enable-*.sh`
scripts here don't, so this is where they all get checked together.
Service mesh and multi-cluster are checked only if they look like they
were actually run (their absence is a WARN, not a FAIL).

## Run natively, unmodified

Modules 06, 10, 11, 12, 15, and 16 have zero infra-specific
assumptions — verified by reading every one of their setup.sh scripts, not
assumed from the table below. Run them exactly as the native track's own
README says to, in order, once their explicit prerequisites above are met:

```bash
bash modules/06-security-policy/scripts/setup.sh
LOKI_STORAGE_CLASS="${AKS_STORAGE_CLASS}" bash modules/09-logging/scripts/setup.sh   # see note below — this one DOES need a fixup
bash modules/10-package-management/scripts/setup.sh   # or use charts/kustomize directly
bash modules/11-gitops-cicd/scripts/setup.sh           # needs a real Git remote, same as native
bash modules/12-progressive-delivery/scripts/setup.sh  # needed before enable-servicemesh below
bash modules/15-multi-tenancy-cost/scripts/setup.sh
bash modules/16-supply-chain-security/scripts/setup.sh
```

Module 09 is the one exception to "zero infra-specific assumptions": its
`setup.sh` hard-required the `longhorn` StorageClass (native track only) —
now takes `LOKI_STORAGE_CLASS` as an override, fixed here since it's a
real gap, not AKS-specific behavior. Set it to `${AKS_STORAGE_CLASS}`
(`managed-csi-tagged` in this repo's own aks.env) as shown above. Its
Loki/Alloy Helm installs also now set explicit CPU/memory requests+limits
on every container — needed to pass Module 06's `require-resource-limits`
ClusterPolicy (cluster-wide, not just `online-boutique`) if Module 06 ran
first, and harmless either way otherwise.

Module 09's `verify.sh` will always report `Alloy: N-1/N nodes ready` on
AKS, where N is the total node count including the system pool — Alloy
(like every other app/log-shipping DaemonSet in this track) doesn't
tolerate the system pool's taint, matching this track's own rule that the
system pool never runs application Pods. This isn't a failure to fix; on
AKS, `N-1/N` is the expected steady state (all `online-boutique` and
`monitoring` namespace logs still ship — nothing on the system pool needs
covering here).

Module 03 is **not** in this list — `enable-secrets.sh` above replaces it
when `AKS_KEY_VAULT_NAME` is set (Key Vault Secrets Provider instead of
Sealed Secrets; see [Platform Decisions](#platform-decisions)). Without a
Key Vault, run Module 03's own native `setup.sh` instead, with one fixup
its `redis-cart-statefulset-with-auth.yaml` needs on AKS (hardcodes
`storageClassName: local-path`, an immutable StatefulSet field once
applied):

```bash
bash modules/03-config-secrets/scripts/setup.sh
sed "s/storageClassName: local-path/storageClassName: ${AKS_STORAGE_CLASS}/" \
  modules/03-config-secrets/manifests/redis-cart-statefulset-with-auth.yaml \
  | kubectl apply -n online-boutique -f -
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

## Optional: Cloudflare Tunnel

An alternative to enable-networking.sh's public LoadBalancer + cert-manager/
ACME path — useful when a domain is already proxied through Cloudflare
(orange-clouded), since ACME HTTP-01 can't complete against a record that
doesn't yet resolve to this cluster's LoadBalancer IP:

```bash
# Generate a tunnel token in the Cloudflare Zero Trust dashboard
# (Networks > Tunnels > create/select a tunnel > Install connector > Docker)
# and set CF_TUNNEL_TOKEN in aks.env — never commit a real value.
bash platforms/aks/scripts/aks-track.sh enable-cf-tunnel
```

Runs the `cloudflared` connector pods only (2 replicas, spread across
nodes). Public-hostname routing — which Cloudflare hostname maps to which
in-cluster Service — is dashboard-side config on the tunnel this token
belongs to, not something this script or its manifest configures.

## Dedicated Rancher Management Cluster

The recommended architecture is standalone Azure VMs, not an AKS cluster or
this workload/lab cluster. The dedicated implementation lives in
[`management/`](management/): it provisions 2 Ubuntu 24.04 VMs (1
control-plane + 1 worker) in a new, dedicated resource group
(`rg-ics-ms-prod-sgp-001`, not `rg-nextops-prod-jkt-001` — confirmed live via
`az group list` that nothing existing was suitable to reuse for an isolated
management cluster), bootstraps a native kubeadm cluster across them
(mirroring `modules/01-cluster-setup/scripts/setup-control-plane.sh` and
`setup-worker.sh` — no control-plane taint removal needed, since Rancher now
schedules on the dedicated worker instead), and installs Rancher on the
worker behind a dedicated Cloudflare Tunnel — same Helm-based install
pattern as `platforms/ack/management/`, adjusted for a single-worker
cluster (1 Rancher replica, no pod anti-affinity). 2 nodes, not 1: an
earlier single-node design was found live not to reliably survive a reboot
(see `management/README.md`'s "Known issue" — cilium/cilium#44194).

Use that track for the platform-management deployment. The Module 14
equivalent below remains available only for curriculum parity on an isolated
lab cluster; do not use it when this cluster already hosts a real workload.

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
Velero, only present when `AKS_ENABLE_AKS_BACKUP` is unset/`0`), and
Rancher (if installed). It does not disable the managed add-ons
`enable-managed-addons.sh` turned on, does not touch the AKS Backup Vault
or its Terraform-managed resources (destroy those via `terraform destroy`
or by setting `enable_aks_backup = false`), and does not touch the AKS
cluster or its node pools — those are Azure-billed resources this track
doesn't own. Modules run natively (03/06/09/10/11/12/15/16) and
Istio/Kiali/Tempo (`enable-servicemesh.sh`) aren't covered — clean those
up with their own native `destroy.sh`/`helm uninstall` if needed.

## Module Compatibility

| Module | AKS status | AKS treatment |
|---|---|---|
| 00 Prerequisites | Adapt | `check-prerequisites.sh` — same tool checks as Module 00, `az` replaces `ssh` as the one required addition. |
| 01 Cluster Setup | Replace | AKS owns the control plane, CNI, kubelet, and node lifecycle. |
| 02 Core Workloads | Supported | Use `deploy-core-workloads.sh`; Azure Disk CSI replaces local-path. |
| 03 Config & Secrets | Adapt | `enable-secrets.sh` — Key Vault Secrets Provider instead of Sealed Secrets when `AKS_KEY_VAULT_NAME` is set (no `kubeseal`/sealed-secrets-controller at all); ConfigMap and the redis-cart-with-auth/cartservice-with-auth manifests still reused unmodified from Module 03. Without a Key Vault, run Module 03's own native setup.sh instead — see "Run natively, unmodified" below for its one required fixup. |
| 04 Networking & Gateway | Adapt | `enable-networking.sh` — reuses Module 04's ClusterIssuers/HTTPRoute/NetworkPolicy unmodified, Gateway swapped to `approuting-istio`. |
| 05 Storage | Replace | `enable-storage.sh` — redis-cart is already on managed-csi as of Module 02; this confirms CSI snapshot support and takes a real snapshot. |
| 06 Security Policy | Supported | Run its existing setup after Module 02. |
| 07 Scalability & HA | Adapt | `enable-scaling.sh` — skips installing metrics-server/VPA/KEDA (AKS ships/manages them already), reuses Module 07's HPA/VPA/ScaledObject/PDB manifests unmodified. |
| 08 Observability | Adapt | `enable-observability.sh` — `nodeExporter.enabled=true` (opposite of native — no separate DaemonSet to collide with), skips the native PodMonitor. Grafana's admin password comes from Key Vault when `AKS_KEY_VAULT_NAME` is set, native kubeseal flow otherwise; cert-manager's ServiceMonitor and the PrometheusRule reused unmodified either way. |
| 09 Logging | Adapt | Run its existing setup after Module 08, with `LOKI_STORAGE_CLASS=${AKS_STORAGE_CLASS}` — its `setup.sh` hardcoded the `longhorn` StorageClass, now parameterized. See "Run natively, unmodified" below. |
| 10 Package Management | Supported | Run its existing setup, or use `charts/`/`kustomize/` directly — infra-agnostic either way. |
| 11 GitOps & CI/CD | Supported | Run its existing setup — needs a real Git remote, same requirement as native. |
| 12 Progressive Delivery | Supported | Run its existing setup — required before `enable-servicemesh.sh` (frontend must already be a Rollout). |
| 13 Cluster Operations | Replace | `enable-backup.sh` — no etcd snapshot step (AKS backs up its own control plane). Azure Backup for AKS (Backup Vault/Extension from `terraform/backup.tf`) when `AKS_ENABLE_AKS_BACKUP=1`; otherwise Velero/MinIO/backup/restore manifests reused unmodified from Module 13, only the storage class changed. Node drain drill reused either way, scoped to the workload pool only. |
| 14 Multi-Cluster | Replace | `enable-multicluster.sh` + `promote-canary.sh` — Rancher install and canary-app.yaml reused unmodified from Module 14, only rancher-values.yaml's GatewayClass differs. Second cluster via a Terraform workspace, not bootstrapped VMs. |
| 15 Multi-Tenancy & Cost | Supported | Run its existing setup after Module 08. |
| 16 Supply Chain Security | Supported | Run its existing setup after Modules 02 and 06. |
| 17 Service Mesh | Adapt | `enable-servicemesh.sh` — self-managed Istio via Helm (not the AKS Istio add-on, which conflicts with application-routing's Gateway); everything else reused unmodified from Module 17 except Tempo's storage class. |
| 18 Chaos Engineering | Mostly supported | Chaos Mesh's core scenarios (PodChaos/NetworkChaos/StressChaos/Workflow) run unmodified — AKS uses containerd too, same runtime/socketPath. Only the SSH node-failure drill doesn't apply (no SSH to AKS nodes); the AKS capacity GameDay (`docs/aks-autoscaling-simulation.md`) is a separate, additional AKS-specific scenario. |
| 99 Capstone | Supported | `inject-incident.sh`/`destroy.sh`/`check-readiness.sh` have zero infra-specific assumptions — verified by reading them, not assumed. Works once Modules 11, and this track's `enable-networking.sh` and Module 18's native setup.sh, are in place. `check-readiness.sh` itself still checks native modules' `verify.sh` paths, though — for an AKS run, check readiness manually via this track's own `verify.sh` plus each natively-run module's `verify.sh` instead. |

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
- Key Vault Secrets Provider is used instead of Sealed Secrets when a Key
  Vault is available (`AKS_KEY_VAULT_NAME` set) — real secret storage
  instead of a from-scratch demo mechanism, and removes an entire
  dependency chain (`kubeseal` CLI, sealed-secrets-controller, Module 03
  needing to run before anything that needs a secret) that caused two
  separate real bugs during this track's development. Sealed Secrets
  remains the default with no Key Vault configured — it's still the
  better choice for a from-scratch lab with nothing else to lean on.
- Prometheus/Grafana (`enable-observability.sh`) deliberately stays
  self-managed (kube-prometheus-stack) rather than switching to Azure
  Monitor managed Prometheus/Grafana — that matches Module 08's own
  mechanism, which is the point of this track's module-parity goal. A
  managed-service swap here would be a reasonable production
  recommendation, just a different goal than what this repo teaches.
- Backup (`enable-backup.sh`) uses Azure Backup for AKS instead of
  Velero+MinIO when `AKS_ENABLE_AKS_BACKUP=1` — a deliberate departure
  from Module 13's own mechanism, unlike the other rows in this table.
  Azure Backup for AKS's internal PV snapshot step creates its disk
  snapshots without any way to pass custom tags, so subscriptions with a
  mandatory-tag Azure Policy (`Require a tag on resources`, `deny` effect)
  will see every backup complete as `CompletedWithWarnings` — cluster
  resources back up fine, PV data doesn't — until that policy is disabled
  or exempted for the backup resource group. Velero+MinIO doesn't have
  this problem because it snapshots through this repo's own
  `VolumeSnapshotClass` (`manifests/volumesnapshotclass.yaml`), which
  already carries the required tags. Velero+MinIO remains the default
  (`AKS_ENABLE_AKS_BACKUP=0`) for that reason — it's the mechanism that
  works regardless of the subscription's tag policy; switch to Azure
  Backup for AKS once you've confirmed (or exempted) your own policy.

## References

- [AKS application-routing Gateway API](https://learn.microsoft.com/azure/aks/app-routing-gateway-api)
- [AKS Vertical Pod Autoscaler](https://learn.microsoft.com/azure/aks/vertical-pod-autoscaler)
- [AKS Azure Disk CSI storage](https://learn.microsoft.com/azure/aks/create-volume-azure-disk)
