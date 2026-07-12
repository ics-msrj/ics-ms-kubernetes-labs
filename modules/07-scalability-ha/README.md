# Module 07 — Scalability & HA

**Duration**: ~90 minutes | **Level**: Intermediate | **Prerequisite**: [Module 06](../06-security-policy/)

---

## Overview

Four mechanisms that all answer some version of "how many pods, and how big," but on different axes: **HPA** (more replicas, reactively, by CPU), **VPA** (right-size one replica's resource requests, by observed history), **KEDA** (replicas driven by something other than CPU/memory — here, a schedule, including scale-to-zero), and **PodDisruptionBudget** (a floor on availability during *voluntary* disruption — node drains, not crashes).

## Learning Objectives

After this module you will:
- Know why HPA and VPA should not both actively manage the same resource metric on the same workload — and how this module sidesteps that by pointing them at different services.
- Understand PodDisruptionBudget's actual scope: it constrains `kubectl drain` and similar voluntary evictions, not node crashes or OOM kills — nothing can stop those from happening.
- Have used KEDA for something HPA fundamentally cannot do on its own: scale a workload to zero replicas and back.

## Prerequisites

- [Module 06](../06-security-policy/) verified.

## Architecture

```
                    metrics-server
                          │
                          │ CPU/memory usage
              ┌───────────┼───────────┐
              ▼                       ▼
      ┌───────────────┐      ┌──────────────────┐
      │  HPA (frontend) │      │  VPA (productcatalog- │
      │  reactive,      │      │  service), mode: Off   │
      │  replica count  │      │  recommends only,      │
      │  2 -> 5         │      │  never applies         │
      └───────────────┘      └──────────────────┘

      ┌────────────────────────────┐
      │  KEDA ScaledObject           │
      │  (loadgenerator)              │
      │  cron trigger, 0 -> 3 reps    │
      │  independent of CPU/memory    │
      └────────────────────────────┘

      ┌────────────────────────────┐
      │  PodDisruptionBudget          │
      │  (frontend, cartservice)      │
      │  minAvailable: 1 — blocks a   │
      │  voluntary drain that would   │
      │  take the last pod down       │
      └────────────────────────────┘
```

## Theory

**Why HPA and VPA can't both drive CPU on one workload.** HPA changes replica *count* in response to CPU; VPA (in `Auto`/`Recreate` mode) changes a pod's CPU *request* in response to the same signal. Point both at the same Deployment on the same metric and they fight: VPA resizing the request changes what "50% utilization" even means, which changes HPA's target, which changes load per pod, which VPA reacts to again. This module avoids the conflict two ways at once: HPA targets `frontend`, VPA targets `productcatalogservice` — different workloads — and VPA is additionally set to `updateMode: "Off"`, so even a future change to add VPA to `frontend` would need a deliberate mode change first, not an accidental one.

**What VPA in `Off` mode is actually for.** Every resource request in Online Boutique's manifests is a guess made once, by whoever wrote them, and never revisited. VPA's recommender watches real usage over time and computes what the request *should* be — in `Off` mode, that recommendation is purely informational (`kubectl describe vpa productcatalogservice -n online-boutique`), which is the responsible way to introduce VPA into a system you don't want a new automated actor abruptly resizing pods in. `Auto`/`Recreate` modes exist for when you trust the recommendation enough to let VPA act on it — evicting and recreating the pod with new requests, which is itself a disruption worth being deliberate about.

**Why KEDA, when HPA already exists.** HPA needs a metric to react to, and `minReplicas` has a floor of however many pods you're willing to always keep running — it cannot express "zero, most of the time." KEDA sits in front of HPA (every `ScaledObject` creates a managed HPA underneath it — `kubectl get hpa -n online-boutique` after this module's setup shows one named `keda-hpa-loadgenerator-cron`) and adds scalers for triggers HPA has no built-in concept of: queue depth, a cron schedule, external metrics. `loadgenerator` scaling to zero outside its cron window is the simplest possible demonstration of "pay for compute you're actually using," which is the entire pitch of event-driven autoscaling.

**What a PodDisruptionBudget does and doesn't protect against.** `minAvailable: 1` tells the eviction API: "reject any voluntary eviction that would drop healthy replicas below 1." `kubectl drain` calls that eviction API and respects the rejection — that's the entire mechanism. It has no effect on a node that hard-crashes, a container that OOM-kills, or `kubectl delete pod --force`. This is why `frontend` and `cartservice` needed **2 replicas** before their PDBs meant anything: a PDB with `minAvailable: 1` against a Deployment that only ever runs 1 replica doesn't protect availability, it just permanently blocks the one voluntary eviction that pod will ever face — worth knowing before you copy this pattern onto a single-replica workload.

## Lab

### Step 1 — Deploy

```bash
bash modules/07-scalability-ha/scripts/setup.sh
```

### Step 2 — Verify

```bash
bash modules/07-scalability-ha/scripts/verify.sh
```

### Step 3 — Watch HPA react to real load

```bash
kubectl get hpa frontend -n online-boutique -w
```

In another terminal, generate load beyond what `loadgenerator`'s default 10 simulated users produce:

```bash
kubectl run -n online-boutique load-burst --image=busybox:1.36.1 --restart=Never --rm -it \
  --overrides='{"spec":{"containers":[{"name":"load-burst","image":"busybox:1.36.1","resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"50m","memory":"32Mi"}}}]}}' -- \
  /bin/sh -c "while true; do wget -q -O- http://frontend/ >/dev/null; done"
```

Watch `TARGETS` climb past 50% and `REPLICAS` grow, up to `maxReplicas: 5`. Stop the load generator (Ctrl-C, then it self-deletes via `--rm`) and watch it scale back down — HPA's default scale-down stabilization window means this takes a few minutes, deliberately, to avoid flapping.

### Step 4 — Read VPA's recommendation

```bash
kubectl describe vpa productcatalogservice -n online-boutique
```

Compare `Target` under `Container Recommendations` against the actual `resources.requests` in `workloads/online-boutique/upstream/kubernetes-manifests.yaml` — that gap is exactly what `Auto` mode would act on.

### Step 5 — Try to drain a node

```bash
kubectl get pods -n online-boutique -l app=frontend -o wide   # which node(s)?
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
```

If both `frontend` replicas ever landed on the same node, the drain pauses on evicting the second one — `kubectl get pdb -n online-boutique` shows `disruptionsAllowed: 0` at that moment. `kubectl uncordon <node>` when done.

## Failure Simulation

| Scenario | How to break it | Detect | Recover |
|---|---|---|---|
| HPA can't read metrics | `kubectl delete deployment metrics-server -n kube-system` | `kubectl get hpa frontend -n online-boutique` shows `TARGETS: <unknown>/50%` | Re-run `setup.sh` |
| PDB blocks a drain indefinitely | `kubectl drain` a node holding the only healthy replica of a `minAvailable`-protected app while its partner replica is already down | `kubectl drain` hangs, printing eviction errors referencing the PDB | Fix the other replica first, or accept the drain will wait; never `--disable-eviction` to force past it without understanding why it's blocked |
| KEDA scales to zero mid-demo | Wait until you're outside the cron window (or edit the `start`/`end` to force it) | `kubectl get deployment loadgenerator -n online-boutique` shows `0/0` replicas | Expected behavior — wait for the window, or `kubectl edit scaledobject loadgenerator-cron -n online-boutique` to test a different window |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `kubectl top nodes` / `kubectl top pods` never works | Very common on kubeadm: kubelet's serving certificate isn't signed by a CA metrics-server trusts by default | This module's Helm install already sets `--kubelet-insecure-tls` for exactly this reason — if it's still failing, check `kubectl logs -n kube-system deployment/metrics-server` |
| VPA recommendation never appears | Recommender needs real metrics history — right after install, there's none yet | Give it several minutes of the pod actually running under real load; `verify.sh` treats this as a warning, not a failure, for the same reason |
| `ScaledObject` shows `Ready: False` | `keda-operator` not ready, or a typo in the cron expression | `kubectl describe scaledobject loadgenerator-cron -n online-boutique`; `kubectl logs -n keda deployment/keda-operator` |
| PDB shows `disruptionsAllowed: 0` and nothing is draining | Fewer healthy replicas than `minAvailable` requires — check *why* first | `kubectl get pods -n online-boutique -l app=<name>` — a genuinely unhealthy pod, not a drain, is the more common real-world cause |

## Cleanup

```bash
bash modules/07-scalability-ha/scripts/destroy.sh
```

## Key Takeaways

- HPA reacts to a metric by changing replica count; VPA reacts to history by changing a pod's resource request — same-workload, same-metric overlap between them is a footgun, not a feature.
- KEDA generates a regular HPA underneath every `ScaledObject` — it's an additional layer of triggers on top of HPA, not a replacement for it.
- A PodDisruptionBudget only ever governs voluntary evictions, and it needs more than one replica to protect anything at all.

## Next Module

[Module 08 — Observability](../08-observability/) — Prometheus, Grafana, and Alertmanager, so "TARGETS: <unknown>" never has to mean guessing again.
