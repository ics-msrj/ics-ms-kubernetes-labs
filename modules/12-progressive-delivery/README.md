# Module 12 — Progressive Delivery

**Duration**: ~90 minutes | **Level**: Advanced | **Prerequisite**: [Module 11](../11-gitops-cicd/)

---

## Overview

Every rollout so far has been all-or-nothing: `kubectl apply` changes a Deployment's pod template, and every replica gets replaced. This module installs **Argo Rollouts** and converts two services to two different progressive strategies — `frontend` gets a **canary** with an automated analysis gate; `productcatalogservice` gets **blue-green** with a manual promotion step.

## Learning Objectives

After this module you will:
- Know what a `Rollout` adds over a `Deployment`: staged replica cutover (`steps`), and — this module's actual point — an automated go/no-go gate via `AnalysisTemplate` instead of a human watching a dashboard.
- Understand canary and blue-green as genuinely different answers to "how much exposure should a new version get before it's fully live," not two names for the same thing.
- Know that `HorizontalPodAutoscaler` can target a `Rollout` exactly like a `Deployment` (same `/scale` subresource) — and that forgetting to retarget it when converting one to the other leaves it silently pointing at nothing.

## Prerequisites

- [Module 08](../08-observability/) verified — the canary's `AnalysisTemplate` queries the Prometheus that module installed.
- [Module 07](../07-scalability-ha/) verified — this module retargets its HPA.
- This module targets the **`online-boutique` namespace** (Modules 02-09's original, imperatively-managed one) — deliberately not `online-boutique-packaged`/`online-boutique-dev` from Modules 10-11, so this module's direct `kubectl patch` demos don't fight ArgoCD's `selfHeal`.

## Architecture

```
frontend (canary)                          productcatalogservice (blue-green)

  Rollout, replicas: 4                       Rollout, replicas: 1
  ┌─────────────────────────┐               ┌──────────────────────────┐
  │ step: setWeight 25        │               │ productcatalogservice      │ ← active Service
  │ step: pause 60s            │               │   (points at the OLD        │   (what everyone calls)
  │ step: analysis  ───────────┼─▶ Prometheus  │    revision until promoted) │
  │   (frontend-no-restarts)   │   (Module 08) │                              │
  │ step: setWeight 50         │               │ productcatalogservice-      │ ← preview Service
  │ step: pause 60s            │               │   preview                    │   (points at the NEW
  │ step: setWeight 100        │               │   (new revision goes here)  │    revision, staged)
  └─────────────────────────┘               │                              │
                                               │ Paused — waits for:         │
                                               │  kubectl argo rollouts       │
                                               │  promote productcatalog...   │
                                               └──────────────────────────┘
```

## Theory

**What a canary step actually gates.** `setWeight: 25` doesn't mean "25% of traffic, precisely" here — this module uses Argo Rollouts' basic replica-ratio canary (no dedicated traffic router), so 1 of 4 pods run the new revision and Kubernetes' normal Service load-balancing does the rest, which only approximates 25% of requests. Production setups pair Argo Rollouts with a traffic router — Istio, SMI, or [Argo Rollouts' own Gateway API plugin](https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi), which would manage `HTTPRoute` weights precisely (and would compose naturally with Module 04's Gateway) — deliberately out of scope here: it's a separate plugin binary this module didn't want to depend on without being able to verify it end-to-end. The `analysis` step is what actually matters regardless of routing precision: it queries Prometheus and the rollout does not proceed past it on failure.

**Why the AnalysisTemplate checks restarts, not error rate.** The honest constraint: Online Boutique's services expose no `/metrics` endpoint, so there is no request-success-rate metric anywhere in this cluster to query (Module 08's README says the same thing about its dashboards). `kube-state-metrics` (also Module 08) does track container restarts — real data, just a coarser signal than request-level success. `frontend-no-restarts`'s query asks "has anything under this rollout crash-looped in the last 2 minutes" — a legitimately useful automated gate, just not the one you'd reach for first if the services were instrumented.

**Canary vs. blue-green — genuinely different tools.** Canary trades a slower rollout for continuous partial exposure and an automated gate at each stage — right when you want real traffic testing a new version incrementally. Blue-green trades that gradualness for a clean, instant, fully-reversible cutover — right when partial exposure isn't meaningful (or is actively bad — imagine two versions of a schema-sensitive service both live at once) and you'd rather stage the whole new version, verify it directly against its `-preview` Service, then flip everything at once. `autoPromotionEnabled: false` is what makes that flip a decision instead of a timer.

**Why the HPA needed retargeting, and why that's not obvious.** `HorizontalPodAutoscaler.spec.scaleTargetRef` is just a reference — a `kind`, `name`, and `apiVersion`. Nothing stops you from applying an HPA against an object that doesn't exist; it just silently never scales anything. Converting `frontend` from a `Deployment` to a `Rollout` changed what kind of object owns those pods, so Module 07's HPA needed its `scaleTargetRef.kind` updated to match — `modules/12-progressive-delivery/manifests/hpa-frontend-rollout.yaml` is that same HPA, retargeted, not a new one. This is a real, easy-to-miss failure mode any time a workload's controller type changes.

## Lab

### Step 1 — Deploy

```bash
bash modules/12-progressive-delivery/scripts/setup.sh
```

### Step 2 — Verify

```bash
bash modules/12-progressive-delivery/scripts/verify.sh
```

This takes a few minutes — it triggers a real new revision on both Rollouts and watches them actually progress (frontend through its full canary + analysis; productcatalogservice into `Paused`), not just checking the objects exist.

### Step 3 — Watch a canary live

Optional: install the `kubectl argo rollouts` plugin ([install docs](https://argo-rollouts.readthedocs.io/en/stable/installation/#kubectl-plugin-installation)) for a live terminal dashboard:

```bash
kubectl argo rollouts get rollout frontend -n online-boutique --watch
```

In another terminal, trigger a new revision:

```bash
kubectl patch rollout frontend -n online-boutique --type merge \
  -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"lab-step\":\"$(date +%s)\"}}}}}"
```

Watch it step through `SetWeight(25)` → `Pause` → `Analysis` → `SetWeight(50)` → `Pause` → `SetWeight(100)` → `Healthy`.

### Step 4 — Promote a blue-green rollout by hand

```bash
kubectl patch rollout productcatalogservice -n online-boutique --type merge \
  -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"lab-step\":\"$(date +%s)\"}}}}}"
kubectl get rollout productcatalogservice -n online-boutique -w   # watch it reach Paused
kubectl argo rollouts promote productcatalogservice -n online-boutique
```

No plugin installed? The equivalent without it: `kubectl argo rollouts` is a thin wrapper — promotion can also be triggered by patching the Rollout's status via `kubectl patch rollout productcatalogservice -n online-boutique --type merge --subresource=status -p '{"status":{"pauseConditions":null}}'`, though the plugin is the documented, supported path.

## Failure Simulation

| Scenario | How to break it | Detect | Recover |
|---|---|---|---|
| Bad canary caught by analysis | Point `frontend-no-restarts`'s query at a metric that's always nonzero (edit the AnalysisTemplate), then trigger a new revision | The Rollout's canary halts at the `analysis` step instead of proceeding to `setWeight: 50` | `kubectl argo rollouts abort frontend -n online-boutique`, fix the query, re-apply |
| Forgotten HPA retarget | `kubectl patch hpa frontend -n online-boutique --type merge -p '{"spec":{"scaleTargetRef":{"kind":"Deployment"}}}'` | `kubectl describe hpa frontend -n online-boutique` shows it can't find its target; replica count stops responding to load | Re-apply `hpa-frontend-rollout.yaml` |
| Preview never gets checked before promotion | Promote productcatalogservice without ever querying `productcatalogservice-preview` directly | Nothing stops you — that's the point of this failure mode existing to think about, not a script to break | `kubectl exec` into any pod and query `productcatalogservice-preview:3550` before promoting, next time |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Rollout stuck at `setWeight: 25`, never reaches `Healthy` | The `analysis` step is failing — most likely Prometheus is unreachable, or the query genuinely found restarts | `kubectl get analysisrun -n online-boutique`; `kubectl describe analysisrun <name> -n online-boutique` shows the actual measured value |
| `frontend` HPA shows no metrics | Retarget didn't apply, or `metrics-server`/Module 07 isn't healthy | `kubectl get hpa frontend -n online-boutique -o yaml \| grep -A3 scaleTargetRef` |
| `productcatalogservice-preview` has no endpoints | The Rollout hasn't created a new ReplicaSet yet — nothing has changed since the last promotion | Trigger a new revision (Step 4) first |
| `kubectl argo rollouts` command not found | The plugin isn't installed — it's optional, not required by any script in this module | Either install it, or use the raw `kubectl patch --subresource=status` fallback (see Step 4) |

## Cleanup

```bash
bash modules/12-progressive-delivery/scripts/destroy.sh
```

## Key Takeaways

- `AnalysisTemplate` is what turns a staged rollout into an automated gate — without it, "canary" just means "slower," not "safer."
- Canary (gradual, continuous exposure) and blue-green (staged, instant cutover) solve different problems — pick based on whether partial exposure to two live versions at once is acceptable for that specific service.
- Changing a workload's controller kind (Deployment → Rollout) breaks anything that referenced the old kind by name — HPA here, but the same applies to PodDisruptionBudgets, VerticalPodAutoscalers, or anything else with a `scaleTargetRef`/`targetRef`.

## Next Module

[Module 13 — Cluster Operations](../13-cluster-operations/) — upgrades, etcd backup/restore, Velero, and node maintenance.
