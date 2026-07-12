# Kubernetes Learning Lab

> Hands-on, production-style Kubernetes labs — from a bare VM to an enterprise-grade platform. Every module runs the same real workload: [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo), Google Cloud's 11-service microservices demo (Go, Python, Node.js, Java, C#, gRPC).

---

## Status

This repository is a ground-up rewrite, built and validated one module at a time, in order. All 19 numbered modules plus the Capstone are complete — the table below reflects that. Each module still stands alone: read its README, run `setup.sh`, run `verify.sh`.

## Who Is This For?

| Level | What You'll Learn |
|-------|--------------------|
| Beginner | Kubernetes core objects, cluster setup, networking basics |
| Intermediate | Security, storage, scaling, observability, packaging |
| Advanced | GitOps, progressive delivery, service mesh, chaos engineering, incident response |

## Track

**Single track: native Kubernetes via `kubeadm` on your own VMs** (cloud, on-prem, or bare metal — you provide SSH access to a handful of Ubuntu VMs). No managed Kubernetes service is required. This keeps every concept explicit: you build the control plane, the CNI, and every add-on yourself instead of relying on a cloud provider's defaults.

## Workload — Online Boutique

All modules deploy and operate the same application: [`GoogleCloudPlatform/microservices-demo`](https://github.com/GoogleCloudPlatform/microservices-demo), an 11-service e-commerce demo (frontend, cart, checkout, payment, shipping, currency, product catalog, recommendation, ads, email, load generator) communicating over gRPC, backed by Redis. It is a widely recognized reference workload with genuine multi-service failure modes — useful for everything from basic Deployments to service mesh and chaos engineering.

See [`workloads/online-boutique/`](workloads/online-boutique/) for how it's vendored and what's layered on top of the upstream manifests.

## Curriculum

| # | Module | Level | Status |
|---|--------|-------|--------|
| 00 | [Prerequisites](modules/00-prerequisites/) | Beginner | ✅ |
| 01 | [Cluster Setup](modules/01-cluster-setup/) | Beginner | ✅ |
| 02 | [Core Workloads](modules/02-core-workloads/) | Beginner | ✅ |
| 03 | [Config & Secrets](modules/03-config-secrets/) | Beginner | ✅ |
| 04 | [Networking & Gateway API](modules/04-networking-gateway/) | Intermediate | ✅ |
| 05 | [Storage](modules/05-storage/) | Intermediate | ✅ |
| 06 | [Security Policy](modules/06-security-policy/) | Intermediate | ✅ |
| 07 | [Scalability & HA](modules/07-scalability-ha/) | Intermediate | ✅ |
| 08 | [Observability](modules/08-observability/) | Intermediate | ✅ |
| 09 | [Logging](modules/09-logging/) | Intermediate | ✅ |
| 10 | [Package Management](modules/10-package-management/) | Intermediate | ✅ |
| 11 | [GitOps & CI/CD](modules/11-gitops-cicd/) | Advanced | ✅ |
| 12 | [Progressive Delivery](modules/12-progressive-delivery/) | Advanced | ✅ |
| 13 | [Cluster Operations](modules/13-cluster-operations/) | Advanced | ✅ |
| 14 | [Multi-Cluster Management](modules/14-multi-cluster-mgmt/) | Advanced | ✅ |
| 15 | [Multi-Tenancy & Cost](modules/15-multi-tenancy-cost/) | Advanced | ✅ |
| 16 | [Supply Chain Security](modules/16-supply-chain-security/) | Advanced | ✅ |
| 17 | [Service Mesh](modules/17-service-mesh/) | Advanced | ✅ |
| 18 | [Chaos Engineering & Incident Response](modules/18-chaos-engineering/) | Advanced | ✅ |
| 99 | [Capstone](modules/99-capstone/) | Advanced | ✅ |

See [CURRICULUM.md](CURRICULUM.md) for full module details, learning objectives, and architecture notes.

## Module Contract

Every module follows the same structure, so once you know one module you know them all:

```
modules/NN-name/
├── README.md      # Objective, Architecture, Prerequisites, Setup, Verify,
│                   # Failure Simulation, Troubleshooting, Destroy, Key Takeaways
├── manifests/      # Kubernetes YAML / Helm values / Kustomize overlays
└── scripts/
    ├── setup.sh    # idempotent — safe to re-run
    ├── verify.sh   # exits non-zero if the module isn't healthy
    └── destroy.sh  # tolerates partially-created resources
```

## Quick Start

```bash
git clone <this-repo> && cd <repo-name>
cat modules/00-prerequisites/README.md   # start here
```

Each module's README is self-contained: read it, run `setup.sh`, run `verify.sh`, then move to the next module. Full walkthrough starts at [`modules/00-prerequisites/`](modules/00-prerequisites/).

## lab.sh — optional CLI

A thin wrapper around the exact commands above — it doesn't replace reading a module's README, it just saves looking up paths and remembering which modules deviate from the standard `setup.sh`/`verify.sh`/`destroy.sh` contract (Module 01's VM bootstrap, Module 99's `check-readiness.sh`, and a few modules' extra one-off scripts like Module 14's `promote-canary.sh`).

```bash
./lab.sh list              # every module, number + name + status
./lab.sh scripts 14        # what scripts a module actually has
./lab.sh setup   02        # bash modules/02-core-workloads/scripts/setup.sh
./lab.sh verify  02
./lab.sh destroy 02
./lab.sh run 18 gameday-node-failure.sh break   # any non-standard script, by name
./lab.sh status             # runs every module's verify.sh; non-zero if any fail
```

## Repository Structure

```
.
├── README.md
├── CURRICULUM.md
├── lab.sh                     # optional CLI wrapper around every module's scripts (see below)
├── modules/                   # 00 → 99, one directory per module (see Module Contract above)
├── workloads/
│   └── online-boutique/       # vendored upstream manifests + our overlays
├── charts/
│   └── online-boutique/       # Helm chart authored in Module 10
├── kustomize/
│   ├── base/                  # inflates charts/online-boutique
│   └── overlays/               # dev, staging, prod (Module 10)
├── gitops/
│   ├── root-app.yaml           # App-of-Apps root (Module 11)
│   └── apps/                   # child Applications ArgoCD reads from Git
├── .gitlab-ci.yml              # primary CI (Module 11)
├── .github/workflows/          # mirrored CI on the GitHub remote
├── scripts/                   # reserved for future cross-module helpers
└── docs/                      # failure-simulation matrix, assessment checklists, diagrams
```
