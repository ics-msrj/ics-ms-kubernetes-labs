# Module 15 — Multi-Tenancy & Cost

**Duration**: ~60 minutes | **Level**: Advanced | **Prerequisite**: [Module 08](../08-observability/)

---

## Overview

Two questions that come up the moment more than one team shares a cluster: "can one team's workload starve another's" (answered here with `ResourceQuota`/`LimitRange`) and "what is each team actually costing us" (answered with **OpenCost**, reusing Module 08's Prometheus rather than installing a second one).

## Learning Objectives

After this module you will:
- Know the difference between `ResourceQuota` (a hard ceiling on a namespace's total consumption) and `LimitRange` (a default/bound applied per-container) — they solve adjacent but distinct problems.
- Understand that OpenCost doesn't meter cost directly — it computes cost allocation *from* metrics a Prometheus you already have is collecting, which is why pointing it at Module 08's Prometheus is a one-block config change, not a new metrics pipeline.
- Be able to explain why this module doesn't use Hierarchical Namespaces, even though it was in the original plan.

## Prerequisites

- [Module 08](../08-observability/) verified — OpenCost queries its Prometheus directly.
- [Module 02](../02-core-workloads/) (and optionally [Module 10](../10-package-management/)) verified — this module applies quotas to the namespaces they created.

## A note on what changed from the original plan

The original curriculum for this module listed **Hierarchical Namespaces (HNC)** alongside ResourceQuota/LimitRange. Checking before building it: HNC's [last release was v1.1.0 in June 2023](https://github.com/kubernetes-sigs/hierarchical-namespaces/releases) — over three years old with no signs of active maintenance. Building a module around it now would teach a tool that's functionally abandoned. This module uses plain per-namespace `ResourceQuota`/`LimitRange` instead — less automated than HNC's namespace-tree propagation, but it's the mechanism that's actually still maintained and that HNC was layered on top of in the first place.

This module also compared **OpenCost** against **Kubecost** before building: both work, and Kubecost's free tier genuinely doesn't require any account or license token (worth stating plainly — that's a real correction to a common assumption). The difference that mattered here: Kubecost's chart bundles its own Prometheus *and* its own Grafana by default (`global.prometheus.enabled: true`, `global.grafana.enabled: true`) — reusing Module 08's existing ones instead requires deliberately flipping both off. OpenCost's chart has no bundled Prometheus at all; it's built to point at one you already have. Given this repo already has a Prometheus (Module 08) it makes no sense to duplicate, OpenCost was the better fit. If you'd rather run Kubecost:

```bash
helm install kubecost kubecost/cost-analyzer -n kubecost --create-namespace \
  --set global.prometheus.enabled=false \
  --set global.prometheus.fqdn=http://monitoring-kube-prometheus-prometheus.monitoring.svc:9090 \
  --set global.grafana.enabled=false \
  --set global.grafana.fqdn=monitoring-grafana.monitoring.svc \
  --set serviceMonitor.enabled=true \
  --set-string serviceMonitor.additionalLabels.release=monitoring
```

## Architecture

```
┌─────────────────────────┐        ┌──────────────────────────────┐
│      online-boutique      │        │   online-boutique-packaged      │
│  ResourceQuota: 4 CPU,     │        │   ResourceQuota: 2 CPU,          │
│    4Gi requests            │        │     2Gi requests                 │
│  LimitRange: 100m/64Mi      │        │   LimitRange: 100m/64Mi          │
│    default per container    │        │     default per container        │
└─────────────────────────┘        └──────────────────────────────┘
              "tenant A"                          "tenant B"

                    ┌──────────────────┐
                    │     OpenCost        │
                    │  queries Prometheus  │───▶ Module 08's Prometheus
                    │  computes $/namespace │      (no second Prometheus)
                    └──────────────────┘
                    (kubectl port-forward — internal tool, same tier as
                     Prometheus/Alertmanager, no public Gateway exposure)
```

## Theory

**Why both a ResourceQuota and a LimitRange, not just one.** `ResourceQuota` caps the *sum* across a namespace — `requests.cpu: "4"` means every container's CPU request in `online-boutique` added together can't exceed 4 cores, full stop, regardless of how that's distributed across pods. It says nothing about any *individual* container. `LimitRange` is the opposite granularity: it sets defaults and bounds *per container* (`defaultRequest`, `default`, `min`, `max`) — critically, it's also what makes `ResourceQuota` practical to enforce at all for containers that don't specify their own resources, since a `ResourceQuota` on `requests.cpu`/`requests.memory` requires *every* pod in that namespace to have those fields set, or admission rejects it outright. `LimitRange`'s `defaultRequest` is what backfills that requirement automatically.

**Why "tenant" here means two namespaces running the same app, not two different apps.** A real multi-tenant cluster usually has genuinely different teams/apps per namespace. This repo doesn't — `online-boutique` and `online-boutique-packaged` are the same application, deployed two different ways (Modules 02-09's direct manifests vs. Module 10's Helm chart). The *mechanism* this module demonstrates — a hard resource ceiling scoped to a namespace, enforced at admission time — is identical regardless of what's actually running in each; treating these two as stand-in tenants exercises the real thing without inventing throwaway placeholder workloads just to have "two teams."

**What OpenCost actually computes, and why it needed a Prometheus that already has real data.** OpenCost doesn't meter your cloud bill or watch a wallet — it takes metrics Prometheus already has (CPU/memory *requests* and *usage* per pod, from kube-state-metrics and cAdvisor, both of which Module 08 already scrapes) and multiplies by a cost model (on-prem/native defaults to a configurable flat rate per CPU-hour/GB-hour, since there's no cloud billing API to query here — that's the `opencost.exporter.defaultClusterId`/pricing config you'd customize for a real deployment). This is why pointing it at an *existing*, already-populated Prometheus instead of a fresh empty one matters: OpenCost's allocation numbers are only as good as the historical data behind them.

## Lab

### Step 1 — Deploy

```bash
bash modules/15-multi-tenancy-cost/scripts/setup.sh
```

### Step 2 — Verify

```bash
bash modules/15-multi-tenancy-cost/scripts/verify.sh
```

This actually tries to create a pod that violates the quota (`requests.cpu: 10`) and confirms it's rejected — not just that the `ResourceQuota` object exists.

### Step 3 — Look at real cost allocation

```bash
kubectl port-forward -n opencost svc/opencost 9090:9090
```

Open `http://localhost:9090` — break down cost by namespace and compare `online-boutique` against `online-boutique-packaged`. They run the same services, so their costs should be close; a large, unexplained gap is worth investigating (mismatched replica counts, a stuck rollout, orphaned resources).

### Step 4 — Watch the LimitRange backfill a missing resource spec

```bash
kubectl run no-resources-test -n online-boutique --image=busybox:1.36 --restart=Never --command -- sleep 3600
kubectl get pod no-resources-test -n online-boutique -o jsonpath='{.spec.containers[0].resources}'
```

Even though this pod spec never mentioned `resources` at all, it now has the `LimitRange`'s `defaultRequest`/`default` values — this is also *why* it was allowed to be created at all under a `ResourceQuota` that requires every pod to declare its CPU/memory requests. Clean up: `kubectl delete pod no-resources-test -n online-boutique`.

## Failure Simulation

| Scenario | How to break it | Detect | Recover |
|---|---|---|---|
| Noisy-neighbor risk without a quota | `kubectl delete resourcequota online-boutique-quota -n online-boutique`, then imagine an HPA misconfiguration scaling frontend to 50 replicas | Nothing stops it anymore — that's the point being illustrated, not a script to run for real | `kubectl apply -f modules/15-multi-tenancy-cost/manifests/resourcequota-online-boutique.yaml` |
| Quota too tight for real usage | Lower `requests.cpu` in the ResourceQuota below current actual usage, then trigger a Rollout (Module 12) or HPA scale-up | New/updated pods start failing to schedule with a `forbidden: exceeded quota` event | Raise the quota, or reduce actual usage first |
| OpenCost's numbers go stale | `kubectl scale deployment monitoring-kube-prometheus-prometheus -n monitoring --replicas=0` (via the underlying StatefulSet, or delete the Prometheus pod) | OpenCost's UI keeps showing old data — it caches; `/healthz` may still return 200 briefly | Restore Prometheus, give OpenCost a few minutes to catch back up |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| A previously-working `kubectl apply` now fails with `forbidden: exceeded quota` | Real usage grew past the quota (more replicas, a new CronJob, etc.) | `kubectl describe resourcequota online-boutique-quota -n online-boutique` shows used vs. hard per resource |
| New pods stuck `Pending` after adding the quota | Same as above, or a `LimitRange.max` now rejects a container's existing explicit resources | `kubectl describe limitrange online-boutique-limits -n online-boutique`; check the failing pod's actual resource requests against `min`/`max` |
| OpenCost shows $0 or no data for a namespace | Prometheus doesn't have data for that namespace yet (cold start), or the ServiceMonitor's `release: monitoring` label is missing | `kubectl get servicemonitor -n opencost --show-labels`; give it a few Prometheus scrape intervals |
| OpenCost `/allocation` API returns an error | Can't reach Prometheus — check the `serviceName`/`namespaceName`/`port` in `opencost-values.yaml` match Module 08's actual Prometheus Service | `kubectl logs -n opencost deployment/opencost` |

## Cleanup

```bash
bash modules/15-multi-tenancy-cost/scripts/destroy.sh
```

## Key Takeaways

- `ResourceQuota` caps the sum for a namespace; `LimitRange` sets defaults/bounds per container — real multi-tenancy needs both, not one or the other.
- Verify a tool is still maintained before building a module around it — this one nearly included HNC on the strength of an old plan, and a two-minute release-history check changed that.
- Cost visibility tooling is metrics math, not a new data source — OpenCost's entire value here came from a Prometheus Module 08 had already been running for seven modules.

## Next Module

[Module 16 — Supply Chain Security](../16-supply-chain-security/) — image scanning, signing, and SBOM.
