# Kubernetes Learning Lab — Curriculum

> Master plan for the lab: scope, design principles, and per-module objectives. This document is filled in module-by-module as each one is built — see the status column in [README.md](README.md).

---

## Design Principles

- **Production-first.** Every manifest and platform decision should map to real operational practice, not a toy example.
- **Security by default.** Least-privilege RBAC, non-root containers, restricted Pod Security Admission, no plaintext secrets in Git.
- **Failure-driven learning.** Every module beyond the basics includes a realistic failure scenario: how to break it, how to detect it, how to recover.
- **GitOps-first delivery.** After Module 11, application and platform state is reconciled from Git, not `kubectl apply` by hand.
- **Gateway API first.** Ingress is legacy; new networking labs use the Gateway API.
- **One workload throughout.** [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) is deployed, broken, secured, scaled, and observed in every module — no toy `nginx` placeholders.

## Scope

| Parameter | Decision |
|---|---|
| Track | Single: native Kubernetes via `kubeadm` on self-provisioned VMs |
| Workload | Online Boutique (upstream, GoogleCloudPlatform/microservices-demo) |
| Language | English |
| Delivery | Self-paced — README + scripts per module |
| Module automation | `setup.sh` / `verify.sh` / `destroy.sh` per module (unified CLI wrapper: TBD, tracked separately) |

## Module Contract

Every module directory follows the same shape and every README follows the same section order:

1. **Overview** — what you'll build
2. **Learning Objectives**
3. **Prerequisites**
4. **Architecture** — diagram of what this module adds
5. **Theory** — concepts, with real-world/enterprise context
6. **Lab** — step-by-step instructions
7. **Failure Simulation** — break it on purpose, then detect and recover
8. **Troubleshooting** — common failures and `kubectl`/tool commands to diagnose them
9. **Cleanup**
10. **Key Takeaways**
11. **Next Module**

---

## Module Details

### Module 00 — Prerequisites ✅
**Objective**: validate that local tooling and lab configuration are ready before touching a cluster.
**Topics**: `kubectl`, `helm`, `kustomize`, `git`, `yq`, `jq`, `lab.env` convention.

### Module 01 — Cluster Setup ✅
**Objective**: bootstrap a real multi-node Kubernetes cluster with `kubeadm` (1 control-plane + N workers) and install a CNI.
**Topics**: `kubeadm init`/`join`, containerd, Cilium (CNI-only mode), SSH-tunneled kubeconfig access. VMs are BYO by default; an optional Terraform example (AWS EC2) is included in `terraform/aws/`.

### Module 02 — Core Workloads ✅
**Objective**: deploy Online Boutique and understand every core workload type (Deployment, StatefulSet, DaemonSet, Job, CronJob) — including the ones Online Boutique doesn't use out of the box.
**Topics**: the 11 Online Boutique Deployments; `redis-cart` converted to a StatefulSet + PVC; `cart-housekeeping` CronJob; `frontend-smoke-test` Job; `node-exporter` DaemonSet; `local-path-provisioner` as a placeholder StorageClass ahead of Module 05.

### Module 03 — Config & Secrets ✅
**Objective**: externalize Online Boutique configuration and secrets from container images.
**Topics**: shared ConfigMap (`DISABLE_PROFILER`) across 6 Deployments via `envFrom`; Sealed Secrets (chosen over External Secrets Operator — no cloud secret backend exists on the native track); Redis AUTH on `redis-cart`, consumed by `redis-cart` itself (`--requirepass`) and by `cartservice` (connection-string env var).

### Module 04 — Networking & Gateway API ✅
**Objective**: expose Online Boutique's frontend externally and secure east-west traffic.
**Topics**: Cilium's Gateway API implementation (`hostNetwork` mode, no cloud LB needed); cert-manager with selfsigned/Let's Encrypt staging/Let's Encrypt production `ClusterIssuer`s selectable via `TLS_ISSUER`; `redis-cart` locked to `cartservice` via `NetworkPolicy`; bonus exercises for namespace-wide default-deny and Cilium L7 HTTP policy.

### Module 05 — Storage ✅
**Objective**: give Redis durable, node-independent storage and understand the PV/PVC/StorageClass lifecycle.
**Topics**: Longhorn (replicated block storage CSI driver, pinned v1.12.0) replacing Module 02's `local-path` placeholder; `numberOfReplicas` scaled to actual node count; VolumeSnapshot via `external-snapshotter` (pinned v8.6.0, cluster-wide/CSI-agnostic); snapshot-and-restore proven end to end in `verify.sh`; live volume expansion as a hands-on Lab step.

### Module 06 — Security Policy ✅
**Objective**: harden the cluster and workloads beyond defaults.
**Topics**: RBAC (`viewer` read-only + `ci-deployer` least-privilege ServiceAccounts, tested live via `kubectl auth can-i`); Pod Security Admission (`restricted` on `online-boutique`, proving Module 02's securityContexts already comply); Kyverno (chosen over OPA Gatekeeper — YAML-native) with `disallow-latest-tag` and `require-resource-limits` ClusterPolicies, both proven via live rejected admission requests in `verify.sh`.

### Module 07 — Scalability & HA ✅
**Objective**: make Online Boutique survive load spikes and node disruption.
**Topics**: metrics-server (`--kubelet-insecure-tls` for kubeadm); HPA on `frontend` (CPU, 2-5 replicas); VPA on `productcatalogservice` in recommend-only mode (deliberately a different workload/mode than HPA, to avoid the two fighting over the same metric); KEDA cron `ScaledObject` scaling `loadgenerator` to zero outside a schedule; PodDisruptionBudgets on `frontend`/`cartservice` (both bumped to 2 replicas first, since a PDB against a 1-replica Deployment protects nothing).

### Module 08 — Observability ✅
**Objective**: get metrics-based visibility into cluster and application health.
**Topics**: kube-prometheus-stack (chart 87.15.1); Module 02's node-exporter reused via `PodMonitor` (`nodeExporter.enabled=false` to avoid a hostNetwork port clash); cert-manager `ServiceMonitor` enabled for a certificate-expiry alert; `PrometheusRule` alerts tied to Modules 04/05/07 by name; Grafana exposed at `grafana.<APP_DOMAIN>` via a second Gateway listener with a Sealed-Secret admin password — Prometheus/Alertmanager deliberately kept `port-forward`-only (no built-in auth).

### Module 09 — Logging ✅
**Objective**: centralize logs across all 11 Online Boutique services (and the rest of the cluster).
**Topics**: Loki (chart 7.0.0, SingleBinary mode, filesystem storage on a Longhorn PVC); Grafana Alloy (chart 1.10.1, DaemonSet, chosen over EOL'd Promtail) shipping logs cluster-wide via `loki.source.kubernetes` (Kubernetes API-based, no hostPath); Loki wired into Module 08's existing Grafana via a sidecar-discovered datasource ConfigMap; LogQL exploration and log/alert correlation.

### Module 10 — Package Management ✅
**Objective**: package Online Boutique for repeatable delivery.
**Topics**: `charts/online-boutique/` — a real Helm chart, 9 services templated via one `range`-looped template over `values.services`, frontend/loadgenerator/redis-cart special-cased; deployed to `online-boutique-packaged` (zero risk to the live `online-boutique` namespace). `kustomize/base` (Kustomize's `helmCharts` inflator) + `overlays/dev|staging|prod` — dev deployed live to `online-boutique-dev`, staging/prod render-and-diff only.

### Module 11 — GitOps & CI/CD
**Objective**: move from manual `kubectl apply` to Git-reconciled delivery.
**Topics**: ArgoCD, App-of-Apps, a CI pipeline.
*Detailed lab content: not started.*

### Module 12 — Progressive Delivery
**Objective**: ship changes with automated risk mitigation instead of a single big-bang rollout.
**Topics**: Argo Rollouts, canary, blue-green, automated analysis.
*Detailed lab content: not started.*

### Module 13 — Cluster Operations
**Objective**: operate the cluster itself — the things a managed service would normally hide.
**Topics**: version upgrades, etcd backup/restore, Velero, node maintenance/draining.
*Detailed lab content: not started.*

### Module 14 — Multi-Cluster Management
**Objective**: manage more than one native cluster from a single control point.
**Topics**: Rancher (or equivalent), multi-cluster import, centralized RBAC.
*Detailed lab content: not started.*

### Module 15 — Multi-Tenancy & Cost
**Objective**: run multiple teams/tenants on shared infrastructure with fair resource allocation and cost visibility.
**Topics**: ResourceQuota, LimitRange, Hierarchical Namespaces, OpenCost.
*Detailed lab content: not started.*

### Module 16 — Supply Chain Security
**Objective**: trust the images running in the cluster.
**Topics**: Trivy (scanning), Cosign (signing), SBOM, image admission policy.
*Detailed lab content: not started.*

### Module 17 — Service Mesh
**Objective**: add mTLS, traffic shaping, and deep service-to-service observability. Online Boutique is the canonical Istio demo app — this module leans into that.
**Topics**: Istio, mTLS, traffic management, Kiali, distributed tracing.
*Detailed lab content: not started.*

### Module 18 — Chaos Engineering & Incident Response
**Objective**: practice detecting, diagnosing, and recovering from real failure — not just injecting it.
**Topics**: manual fault injection → Chaos Mesh/LitmusChaos, the [Failure Simulation Matrix](docs/failure-simulation-matrix.md), postmortem writing.
*Detailed lab content: not started.*

### Module 99 — Capstone
**Objective**: combine every prior module into one end-to-end enterprise scenario — deploy, take traffic, absorb an injected failure, detect, diagnose, recover, and write a postmortem.
*Detailed lab content: not started.*

---

## Cross-Cutting Documents

- [`docs/failure-simulation-matrix.md`](docs/failure-simulation-matrix.md) — catalog of realistic failure scenarios used across Modules 06–18 *(not yet written)*
- [`docs/assessment-checklist.md`](docs/assessment-checklist.md) — beginner/intermediate/advanced self-check criteria *(not yet written)*
