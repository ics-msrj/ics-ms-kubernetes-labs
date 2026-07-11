# Module 10 — Package Management

**Duration**: ~60 minutes | **Level**: Intermediate | **Prerequisite**: [Module 09](../09-logging/)

---

## Overview

Every module so far has deployed Online Boutique from a vendored, static manifest. This module authors a real **Helm chart** for it — one template driving 9 structurally similar services via a `range` loop — and layers **Kustomize** overlays on top for per-environment differences. Both land in fresh namespaces; the `online-boutique` namespace every other module depends on is untouched.

## Learning Objectives

After this module you will:
- Be able to explain what a Helm chart buys you that a static manifest doesn't: one template plus a `values.yaml` list, instead of 9 near-duplicate YAML blocks that drift the moment someone edits one and forgets the other eight.
- Know when to reach for Kustomize instead of (or on top of) Helm — patch-based composition for environment differences, without needing every difference to be a `{{ .Values.x }}` the chart author anticipated in advance.
- Understand why `helmCharts` chart inflation in Kustomize needs `--enable-helm` and, for a chart outside the kustomization root, `--load-restrictor LoadRestrictionsNone` — and why those are opt-in, not defaults.

## Prerequisites

- [Module 09](../09-logging/) verified.
- [Module 05](../05-storage/) verified — the chart's `redis-cart` StatefulSet uses the `longhorn` StorageClass.
- `kustomize` CLI (Module 00).

## Architecture

```
charts/online-boutique/                    kustomize/
├── Chart.yaml                             ├── base/
├── values.yaml   ← 9 services as data     │   └── kustomization.yaml  (helmCharts: inflate the chart above)
└── templates/                             └── overlays/
    ├── generic-service.yaml  ← 1 template,     ├── dev/      1 replica, 100m CPU limit, 500Mi redis — DEPLOYED LIVE
    │    range-looped over values.services      ├── staging/  2 replicas — render/diff only
    ├── frontend.yaml         (special-cased)    └── prod/     3 replicas, 400m CPU, 5Gi redis — render/diff only
    ├── loadgenerator.yaml    (special-cased)
    └── redis-cart.yaml       (special-cased)

    helm install -> online-boutique-packaged   kubectl apply (dev only) -> online-boutique-dev
    (proves the chart works standalone)         (proves the overlay pipeline works end to end)
```

## Theory

**Why 9 services share one template.** `currencyservice`, `productcatalogservice`, `checkoutservice`, `shippingservice`, `cartservice`, `emailservice`, `paymentservice`, `recommendationservice`, and `adservice` are structurally identical: one container, one gRPC port, a `Deployment`+`Service`+`ServiceAccount` trio. They differ only in port number, env vars, resource sizing, and (for two of them) probe timing — every one of which is now a field in a `values.yaml` list entry, not a hand-copied YAML block. `frontend`, `loadgenerator`, and `redis-cart` are deliberately **not** forced into that same loop — frontend's HTTP-cookie-based probes, loadgenerator's init container, and redis-cart's StatefulSet+PVC shape are genuinely different, and a template that tried to parameterize away three fundamentally different pod shapes into one `range` would be harder to read than three short, honest templates. Knowing which differences are "a values.yaml field" versus "a reason to special-case" is most of what chart authoring actually is.

**Where the loop's `---` separators actually live.** Every iteration of `generic-service.yaml`'s range emits a Deployment, a Service, and a ServiceAccount — and needs a `---` immediately before the Deployment of *every* iteration, including the first, or two adjacent documents silently merge into one invalid YAML mapping (this repo's own chart hit exactly that bug during authoring — worth reproducing once: delete the leading `---` inside the range and run `helm template` to watch it happen). Helm inserts `---` automatically *between files* when concatenating a chart's output; it does nothing for multiple documents your own range loop produces *within* one file.

**Helm chart vs. Kustomize overlay — different questions.** The chart answers "what is this application, structurally, as a reusable unit?" — the answer is the same regardless of which environment installs it. Kustomize's `overlays/{dev,staging,prod}` answer "how does *this* environment differ from the base?" — replica count, resource ceilings, storage size — via patches against the chart's *rendered* output, not by inventing new `values.yaml` fields for every possible per-environment knob a chart author would otherwise have to anticipate. This module deliberately shows both, on the same chart, because the real-world question is rarely "Helm or Kustomize" — production pipelines frequently run both, exactly as `kustomize/base/kustomization.yaml`'s `helmCharts` field does here.

**Why only `dev` gets applied live.** `staging` and `prod`'s entire teaching value is in their *diff* against `dev` and against each other — `diff generated/dev.yaml generated/prod.yaml` shows precisely what changes between environments, which is the actual skill. Running all three simultaneously in a lab cluster would mean 33 more Online Boutique pods for no additional insight over reading the diff.

## Lab

### Step 1 — Deploy

```bash
bash modules/10-package-management/scripts/setup.sh
```

### Step 2 — Verify

```bash
bash modules/10-package-management/scripts/verify.sh
```

### Step 3 — Read the chart, then break it on purpose

```bash
helm template online-boutique charts/online-boutique --set redisCart.password=x | less
```

Remove the leading `---` from inside `generic-service.yaml`'s range (see Theory above) and re-run — watch it fail with a YAML "mapping key already defined" error. Put it back.

### Step 4 — Diff the overlays

```bash
diff modules/10-package-management/generated/dev.yaml modules/10-package-management/generated/staging.yaml
diff modules/10-package-management/generated/staging.yaml modules/10-package-management/generated/prod.yaml
```

### Step 5 — Change a value, re-render, re-diff

Edit `charts/online-boutique/values.yaml` — bump `recommendationservice`'s memory request — then:

```bash
helm template charts/online-boutique --set redisCart.password=x | grep -A3 "name: recommendationservice$"
kustomize build kustomize/overlays/prod --enable-helm --helm-command helm --load-restrictor LoadRestrictionsNone | grep -A3 "name: recommendationservice$"
```

Confirm the change flows through both paths — the chart is the single source of truth both consume.

## Failure Simulation

| Scenario | How to break it | Detect | Recover |
|---|---|---|---|
| Chart values typo | Set an invalid resource value: `helm upgrade online-boutique charts/online-boutique -n online-boutique-packaged --set services[0].resources.requests.cpu=notanumber` | `helm upgrade` fails at the API server with a clear validation error before anything changes | Fix the value, re-run |
| Overlay patch targets a renamed resource | Rename `frontend` to something else in `values.yaml`, re-render `overlays/dev` | `kustomize build` errors: patch target not found | Update the overlay's `target.name` to match, or revert the rename |
| Drift between chart default and overlay expectation | Change `redisCart.storageSize` in the chart's `values.yaml` without updating `overlays/prod`'s patch | prod's patch still forces `5Gi` regardless — no error, just silently overrides your new default | This is why `diff`-ing overlays after any chart change (Step 5) matters — nothing will warn you automatically |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `kustomize build` fails with a security/load-restrictor error | The chart lives outside the kustomization root (`../../charts`) and Kustomize blocks that by default | Always pass `--load-restrictor LoadRestrictionsNone` for this repo's overlays — already done in `setup.sh` |
| `kustomize build` fails with "no repo specified for pull" | `helmGlobals.chartHome` missing or wrong — Kustomize is trying to fetch the chart from a registry instead of finding it locally | Confirm `kustomize/base/kustomization.yaml` has `helmGlobals.chartHome: ../../charts` and the chart is at `charts/online-boutique` |
| Chart renders with duplicate or missing objects | A multi-document template file (like `generic-service.yaml`) is missing a `---` somewhere in a loop | `helm template ... \| python3 -c "import yaml,sys; list(yaml.safe_load_all(sys.stdin))"` — a YAML parse error here means a separator is missing |
| `online-boutique-dev` pods can't reach redis-cart | The dev overlay's redis-cart Secret still has the chart's placeholder password | `setup.sh` already overwrites it post-apply — if you re-ran only `kustomize build` \| `kubectl apply` without the follow-up `kubectl create secret` step, redo that step |

## Cleanup

```bash
bash modules/10-package-management/scripts/destroy.sh
```

## Key Takeaways

- A chart earns a `range` loop when services are *structurally* identical and differ only in data — forcing genuinely different shapes (frontend, loadgenerator, redis-cart here) into the same loop trades a few lines saved for a template nobody can read.
- Kustomize overlays patch a base's *rendered* output — they don't require the base's author to have anticipated every future per-environment knob as a values field.
- Helm and Kustomize aren't a fork in the road — `kustomize/base/kustomization.yaml`'s `helmCharts` field composes them directly, which is a completely normal thing for a real pipeline to do.

## Next Module

[Module 11 — GitOps & CI/CD](../11-gitops-cicd/) — stop running `setup.sh` by hand; let ArgoCD reconcile from Git instead.
