# Module 02 — Core Workloads

**Duration**: ~90 minutes | **Level**: Beginner | **Prerequisite**: [Module 01](../01-cluster-setup/)

---

## Overview

Deploy [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) — 11 services plus Redis — and cover every core Kubernetes workload type in the process. Online Boutique ships as plain Deployments; this module adds what's missing (a StatefulSet, a Job, a CronJob, a DaemonSet) so you leave it having actually used all five.

## Learning Objectives

After this module you will:
- Know when to reach for a Deployment vs. a StatefulSet vs. a Job vs. a CronJob vs. a DaemonSet, based on what each actually guarantees.
- Understand why `redis-cart`'s original Deployment+`emptyDir` loses data on every pod restart, and what a StatefulSet+PVC changes about that.
- Be able to read `kubectl get pods -n online-boutique` and tell, from container count and restart count alone, roughly what's healthy and what isn't.
- Have a real (not toy) multi-service application running, ready for every subsequent module to build on.

## Prerequisites

- [Module 01](../01-cluster-setup/) verified — `kubectl get nodes` shows all nodes `Ready`.
- No cloud LoadBalancer is available on a bare kubeadm cluster — this module accesses the app via `kubectl port-forward`. Module 04 replaces that with a real Gateway.

## Architecture

```
                              ┌──────────────┐
                    ┌────────▶│   frontend    │◀──── you, via kubectl port-forward
                    │         └──────┬───────┘
                    │                │
     ┌──────────────┼────────────────┼────────────────┬─────────────────┐
     ▼              ▼                ▼                ▼                 ▼
┌─────────┐  ┌──────────────┐ ┌────────────┐  ┌───────────────┐  ┌───────────┐
│cartservice│ │productcatalog│ │  currency  │  │ recommendation │  │ adservice │
└────┬─────┘  │   service    │ │  service   │  │    service     │  └───────────┘
     │         └──────────────┘ └────────────┘  └───────┬────────┘
     ▼                                                    │
┌──────────┐                                    (calls productcatalogservice)
│redis-cart │  ◀── StatefulSet + PVC (this module's change)
│(StatefulSet)
└──────────┘

     frontend also calls → checkoutservice ──▶ shippingservice, paymentservice, emailservice, currencyservice, cartservice

     loadgenerator ──▶ frontend                     (Deployment: generates synthetic traffic)
     node-exporter                                  (DaemonSet: one pod per node, host metrics)
     cart-housekeeping                              (CronJob: every 15 min, redis-cart stats)
     frontend-smoke-test                            (Job: one-shot HTTP check, run by verify.sh)
```

## Theory

**Why a Deployment isn't the answer for everything.** A Deployment guarantees "N interchangeable, stateless replicas exist" — any pod can be killed and replaced by an identical one, in any order, and nothing downstream notices. That's exactly right for `frontend`, `cartservice`, `checkoutservice`, and the rest of Online Boutique's application tier: they hold no state between requests. It's exactly *wrong* for a database.

**StatefulSet — `redis-cart`.** Upstream Online Boutique deploys `redis-cart` as a Deployment with an `emptyDir` volume. `emptyDir` is tied to the pod, not the node or a disk — delete the pod (a routine reschedule, a node drain, a rollout) and every cart in it is gone. A StatefulSet changes two things that matter here: (1) each replica gets a stable identity (`redis-cart-0`, not a random suffix) and a stable PersistentVolumeClaim that follows it across reschedules, via `volumeClaimTemplates`; (2) replicas are created/deleted in order, one at a time. For a single-replica cache this mostly buys you #1 — the PVC survives pod death. Multi-replica ordered rollout starts mattering once you run a real clustered database (a topic Module 05 and Module 13 return to).

**Job — `frontend-smoke-test`.** A Job runs a pod to completion and stops — no restart, no replacement, just success or failure recorded. This is the same primitive a CI/CD pipeline uses for a post-deploy smoke test (Module 11 wires this into ArgoCD/CI properly). `backoffLimit` controls retry count on failure; `ttlSecondsAfterFinished` cleans up the pod automatically so completed Jobs don't accumulate.

**CronJob — `cart-housekeeping`.** A CronJob is a Job template plus a schedule. `concurrencyPolicy: Forbid` matters here specifically: if a run takes longer than 15 minutes, you want the next scheduled run skipped, not stacked on top of a still-running one.

**DaemonSet — `node-exporter`.** The only workload type where you don't set a replica count — one pod per node, automatically, including nodes that join later. Host-level metrics (CPU, memory, disk pressure) can only be collected from *on* the node they describe, which is exactly the guarantee a DaemonSet makes and a Deployment can't.

## Lab

### Step 1 — Deploy

```bash
bash modules/02-core-workloads/scripts/setup.sh
```

This creates the `online-boutique` namespace, installs a placeholder StorageClass (`local-path`, superseded properly in Module 05), deploys Online Boutique from the vendored upstream manifest, swaps `redis-cart` for a StatefulSet, and adds the CronJob and DaemonSet. First run pulls 11 container images — expect a few minutes.

### Step 2 — Verify

```bash
bash modules/02-core-workloads/scripts/verify.sh
```

### Step 3 — Look at it

```bash
kubectl port-forward -n online-boutique svc/frontend 8080:80
```

Open `http://localhost:8080` — browse products, add to cart, check out. Then kill the `cartservice` or `redis-cart` pod and reload the cart page:

```bash
kubectl delete pod -n online-boutique -l app=redis-cart
```

Because `redis-cart` is now a StatefulSet with a PVC, your cart survives that. (Try the same experiment against `productcatalogservice` — stateless, also fine, but for a different reason: it holds no state to lose in the first place.)

### Step 4 — Explore the workload types directly

```bash
kubectl get deployments,statefulsets,daemonsets,cronjobs,jobs -n online-boutique
kubectl get pods -n online-boutique -o wide          # one node-exporter pod per node
kubectl logs -n online-boutique job/frontend-smoke-test
kubectl get pvc -n online-boutique                    # redis-data-redis-cart-0, Bound
```

## Failure Simulation

| Scenario | How to break it | Detect | Recover |
|---|---|---|---|
| Cart data loss (the bug this module fixes) | Temporarily scale `redis-cart` back to the upstream Deployment+`emptyDir` pattern, add items to cart, delete the pod | Cart is empty after the pod restarts | This is why it's a StatefulSet now — confirm recovery instead: delete the `redis-cart-0` pod and confirm the cart survives |
| `productcatalogservice` down | `kubectl scale deployment productcatalogservice -n online-boutique --replicas=0` | Frontend product pages fail to load; `checkoutservice` calls fail | `kubectl scale deployment productcatalogservice -n online-boutique --replicas=1` |
| PVC can't bind | `kubectl delete -f modules/02-core-workloads/manifests/local-path-provisioner.yaml` before redis-cart starts | `redis-cart-0` stuck `Pending`; `kubectl get pvc` shows the claim `Pending` | Re-apply `local-path-provisioner.yaml` |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Pods stuck `ImagePullBackOff` | Outbound internet access blocked from the cluster nodes (all images are pulled from `us-central1-docker.pkg.dev` and Docker Hub) | Confirm nodes have outbound HTTPS access; check `kubectl describe pod <pod> -n online-boutique` for the exact registry error |
| `redis-cart-0` stuck `Pending` | PVC not bound — local-path-provisioner not installed or not ready | `kubectl get pvc -n online-boutique`, `kubectl get pods -n local-path-storage` |
| `checkoutservice` pods `CrashLoopBackOff` | Usually a downstream dependency (payment/shipping/email/currency/cart) isn't reachable yet | `kubectl logs -n online-boutique deployment/checkoutservice`; confirm the service it's calling has `Running` pods |
| `frontend-smoke-test` Job fails every time | `frontend` Service has no ready endpoints yet | `kubectl get endpoints frontend -n online-boutique`; wait for the `frontend` Deployment rollout to finish, then re-run `verify.sh` |
| `node-exporter` pods not `Running` on all nodes | Usually a `hostPath` permission issue on that node's filesystem | `kubectl describe pod -n online-boutique -l app=node-exporter` on the affected node |

## Cleanup

```bash
bash modules/02-core-workloads/scripts/destroy.sh
```

## Key Takeaways

- Pick a workload type by what guarantee you actually need: identical replaceable replicas (Deployment), stable identity + storage (StatefulSet), run-once-to-completion (Job), run-on-a-schedule (CronJob), or exactly-one-per-node (DaemonSet).
- `emptyDir` is pod-lifetime storage, not durable storage — if data needs to outlive the pod, that's a signal you need a StatefulSet (or at minimum a Deployment with a PVC, if you don't need per-replica identity).
- Everything from here on assumes Online Boutique is running in the `online-boutique` namespace — don't tear it down between modules unless a module's README explicitly tells you to.

## Next Module

[Module 03 — Config & Secrets](../03-config-secrets/) — externalize configuration from the container images you just deployed.
