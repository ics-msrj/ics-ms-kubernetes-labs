# Module 99 — Capstone

**Duration**: Open-ended | **Level**: Advanced | **Prerequisite**: Modules 00-18

---

## Overview

Every other module in this repo tells you exactly what to run and in what order. This one doesn't — on purpose. It assumes Modules 00-18 are already deployed and healthy, and adds nothing new except one thing: a real, undocumented incident, triggered by someone other than you (or by you, a few minutes in the past, if you're doing this solo and deliberately not reading `scripts/inject-incident.sh` first).

Your job is the same as every "Failure Simulation" row in this repo's [failure-simulation-matrix.md](../../docs/failure-simulation-matrix.md), except this time nothing tells you which row it is.

## Learning Objectives

After this module you will:
- Have proven — not just read about — that you can detect, diagnose, and recover from a real incident using this repo's observability stack alone, with no runbook telling you which command to try next.
- Be able to correctly separate multiple simultaneous root causes instead of forcing every symptom into one cascading-failure narrative — the same diagnostic trap Module 18's blind drill introduced, now without the module's own README hinting that multiple faults are even in play.
- Have written a real postmortem, end to end, using [`docs/postmortem-template.md`](../../docs/postmortem-template.md) — not a worked example to compare against, your own.

## Prerequisites

Modules 00-18, all verified. Run [Step 1](#step-1--confirm-readiness) below rather than trusting memory — it checks all of them for you.

The incident specifically touches Module 04 (Gateway/TLS), Module 07 (autoscaling/PDB), Module 08-09 (observability), Module 11 (GitOps), Module 15 (multi-tenancy), Module 17 (Kiali), and Module 18 (Chaos Mesh) — but detecting *that* it touches exactly those, and not others, is part of the exercise.

## Architecture

```
Your cluster, as built by Modules 00-18 — nothing new deployed by this module.

  online-boutique-packaged                  online-boutique
  (Module 10/11, ArgoCD-managed)             (Modules 02-09, 12, 17, 18)
  ---------------------------                ---------------------------
  productcatalogservice                      frontend (Gateway, TLS via frontend-tls)
    fault: GitOps drift can point              fault: frontend-tls Secret deleted,
    this at bad config                           edge-wide, cert-manager reissues
                                              paymentservice
  unaffected by the other two faults           fault: Chaos Mesh pod-kill, narrow

  Detection tools available (all already running, nothing new):
  Grafana + Prometheus (08) · Loki (09) · Kiali (17) · ArgoCD UI (11) · OpenCost (15)
```

## Theory

**Why "no script" is the actual point, not a gimmick.** Every module before this one optimized for something a training curriculum needs: repeatability, a clear success signal, a way to know you did it right. Real incidents don't come with any of that — nobody hands you the failing manifest's filename. The skill this module tests is whether the *habits* built by 18 modules of "detect it, diagnose it, recover it, write it up" actually transfer to a situation where you don't already know the shape of the answer.

**Why three faults, not one.** A single fault teaches you to read one signal in isolation. This repo's own history has a real example of why that's not enough: Module 18's combined-incident drill exists specifically because two simultaneous symptoms tempt you into one cascading-failure story instead of two separate ones. This module goes further — three faults, spanning three different namespaces/subsystems (GitOps-managed config, Gateway/TLS, in-cluster chaos), each requiring a genuinely different tool to even notice (ArgoCD's sync state, a browser/curl TLS error, Kiali's traffic graph). Getting the *count* right — realizing there are three problems, not one or two — is itself part of what's being tested.

**Why the GitOps fault never touches `main`.** This repo is meant to double as a public portfolio. A "bad commit" fault that actually landed on `main`'s history would be visible to anyone looking at the repo later, which is a real cost for a training exercise to impose. `inject-incident.sh` pushes the bad config to a disposable `capstone-drill` branch instead and repoints the live ArgoCD Application's `targetRevision` at it — same lesson (GitOps synced something bad, recovery means pointing back at what's known-good), zero trace left in the history that matters.

## Lab

### Step 1 — Confirm readiness

```bash
bash modules/99-capstone/scripts/check-readiness.sh
```

Fix anything relevant before continuing. This script installs nothing — it only checks.

### Step 2 — Wait for the incident

If you're doing this with a partner, tell them you're ready and stop reading this file. If you're doing this solo: have your past self (or a script you set up earlier and deliberately forgot the details of) run `scripts/inject-incident.sh` without you watching, then come back to this exact step.

Do not read `scripts/inject-incident.sh` before this point. It will tell you exactly what's about to happen, which defeats the entire exercise.

### Step 3 — Detect, diagnose, recover

No steps here. Use whatever combination of Grafana, Loki, Kiali, ArgoCD, `kubectl`, and your own judgment gets you to a real answer. A few honest hints, not the answer key:

- More than one thing is wrong.
- They are not all the same kind of problem.
- Not everything you check will be broken — ruling something out is progress too.

### Step 4 — Write the postmortem

Use [`docs/postmortem-template.md`](../../docs/postmortem-template.md). Real timestamps, pulled from Grafana/Loki/`kubectl get events` — not reconstructed from memory. If you want to see what a filled-out one looks like first, Module 18 has a worked example; this module deliberately doesn't, because by now you shouldn't need one.

### Step 5 — Compare against the real fault list

Only after your postmortem is written: `cat modules/99-capstone/scripts/inject-incident.sh`'s header comment lists exactly what was injected. Compare it against what you found. Any gap between the two is more useful than a clean match — write it down.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `inject-incident.sh` fails at the git push step | `GITOPS_REPO_URL`/`GITOPS_REPO_REVISION` not set, or no push access to your GitOps remote | Confirm `git push origin capstone-drill` works manually with your current credentials |
| ArgoCD Application stuck `OutOfSync` after `destroy.sh` | It takes a sync cycle to reconcile back to the restored `targetRevision` | `argocd app sync online-boutique-packaged`, or wait for the next auto-sync |
| `frontend-tls` doesn't reissue on its own | cert-manager/`ClusterIssuer` itself has an underlying problem, not just a deleted Secret | `kubectl describe certificate -n online-boutique`, check the issuer's own health (Module 04's own Troubleshooting table) |
| Readiness check reports Module 14 `NOT READY` | Module 14's second cluster is genuinely optional infrastructure this module's incident never touches | Ignore it for this drill unless you specifically want full coverage |

## Cleanup

```bash
bash modules/99-capstone/scripts/destroy.sh
```

Safe to run whether or not you fully recovered everything by hand first — every step tolerates already being fixed.

## Key Takeaways

- Eighteen modules of "detect it, diagnose it, recover it" are only worth what they transfer to a situation with no runbook — this module is the transfer test, not new material.
- Getting the *count* of simultaneous root causes right is as important as diagnosing any one of them correctly.
- A training exercise that touches a public-facing artifact (this repo's Git history) deserves the same care about blast radius as a real production action — the drill branch pattern here is worth reusing anywhere else a lab needs to simulate a "bad deploy" without leaving one behind.

## What's Next

There isn't a Module 100. If you made it here having actually run every module's `setup.sh`/`verify.sh`, broken things on purpose per the [failure-simulation-matrix.md](../../docs/failure-simulation-matrix.md), and gotten through this module's incident without a script — that's the curriculum. Go build something that isn't Online Boutique.
