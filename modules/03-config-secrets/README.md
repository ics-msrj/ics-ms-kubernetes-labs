# Module 03 — Config & Secrets

**Duration**: ~60 minutes | **Level**: Beginner | **Prerequisite**: [Module 02](../02-core-workloads/)

---

## Overview

Externalize configuration from container images using ConfigMaps, and manage a real secret — a Redis password — safely enough to commit the result to Git, using Sealed Secrets. Online Boutique ships with no real secrets to manage, so this module adds one deliberately: Redis AUTH on `redis-cart`.

## Learning Objectives

After this module you will:
- Know when a ConfigMap is the right tool (non-sensitive, shared, changeable-without-a-rebuild config) and be able to point at Online Boutique's own duplicated `DISABLE_PROFILER` env var as the "before" state.
- Understand exactly why a plain Kubernetes `Secret` is not safe to commit to Git (it's base64, not encryption) and what Sealed Secrets changes about that.
- Be able to trace a real secret end to end: generated → sealed → committed-safely → decrypted in-cluster → consumed by two different workloads two different ways (a CLI flag, and a connection-string env var).

## Prerequisites

- [Module 02](../02-core-workloads/) verified — Online Boutique running in the `online-boutique` namespace.

## Architecture

```
 you                    kubeseal (CLI)              cluster
  │                          │                          │
  ├─ openssl rand ──────────▶│                          │
  │  (random password,       │                          │
  │   never touches disk)    │                          │
  │                          ├─ fetch public cert ─────▶│  sealed-secrets-controller
  │                          │◀── public cert ───────────┤  (holds the private key —
  │                          │                          │   nothing else ever does)
  │                          ├─ encrypt ─┐               │
  │                          │           ▼               │
  │                    SealedSecret (ciphertext,          │
  │                    safe to commit) ─────────────────▶│
  │                                                       ├─ decrypts ─▶ Secret
  │                                                       │              (redis-cart-credentials)
  │                                                       │                  │
  │                                                       │      ┌───────────┼───────────┐
  │                                                       │      ▼                       ▼
  │                                                       │  redis-cart              cartservice
  │                                                       │  (--requirepass)     (REDIS_ADDR=...,password=...)
```

## Theory

**ConfigMap — the `DISABLE_PROFILER` duplication.** Six of Online Boutique's eleven Deployments hardcode `DISABLE_PROFILER: "1"` as an inline env var. That's harmless at 6 copies, but it's the same failure mode as any duplicated constant: change it in 5 places and forget the 6th, and now behavior is inconsistent for a reason that isn't visible from any single manifest. A shared ConfigMap plus `envFrom` fixes that — one value, six consumers, and `kubectl rollout restart` picks up a change without touching an image.

**Why a plain `Secret` isn't a secret.** `kubectl get secret redis-cart-credentials -o yaml` shows `data.password: <base64>` — base64 is an encoding, not encryption, reversible by anyone with `base64 -d` and no key at all. A plain Secret manifest committed to Git is a plaintext credential committed to Git, full stop. Kubernetes Secrets exist to control *runtime* access (via RBAC) and *transit* (etcd-at-rest encryption, if configured) — they were never meant to be safe to check into version control.

**Sealed Secrets' actual model.** The `sealed-secrets-controller` generates an asymmetric keypair on first install and keeps the private key inside the cluster, never exporting it. `kubeseal` fetches the *public* key from the controller (or from a saved cert file) and uses it to encrypt a Secret client-side into a `SealedSecret` custom resource. Encrypting with a public key is one-way: only the matching private key — which lives only inside the one cluster that generated it — can decrypt it. That's why a `SealedSecret` is safe to commit: it's ciphertext bound to one specific cluster's key. It's also why this repo doesn't commit a static example `SealedSecret` — reseal it against *your* cluster's controller, or it will never decrypt (this is also why `setup.sh` regenerates the password on every run: there's no way to recover the previous one, by design).

**Why cartservice's connection string, not a mounted file.** Some secrets are naturally consumed as files (a TLS cert, an SSH key); others are naturally consumed as a single scalar value. A Redis password is the latter — cartservice takes it as part of a connection string, so `secretKeyRef` into an env var is the direct fit. `redis-cart` takes it as a CLI flag instead (`--requirepass`), read from the same Secret via the same mechanism — one Secret, two different consumption patterns, which is the point of this module's second scenario.

## Lab

### Step 1 — Deploy

```bash
bash modules/03-config-secrets/scripts/setup.sh
```

Watch the middle of the output: it generates a password with `openssl rand`, immediately pipes it through `kubeseal` into `modules/03-config-secrets/generated/redis-cart-sealedsecret.yaml` (git-ignored — see why in Theory above), and applies that. The plain password only ever exists in a shell variable, and is `unset` right after use.

### Step 2 — Verify

```bash
bash modules/03-config-secrets/scripts/verify.sh
```

This specifically confirms AUTH is *enforced*, not just configured: it runs an unauthenticated `PING` against `redis-cart` and expects it to be **rejected** (`NOAUTH`), then runs an authenticated one using the real password read back out of the (decrypted) Secret and expects `PONG`.

### Step 3 — Inspect the SealedSecret vs. the Secret

```bash
cat modules/03-config-secrets/generated/redis-cart-sealedsecret.yaml   # ciphertext — safe to read, safe to commit
kubectl get secret redis-cart-credentials -n online-boutique -o yaml   # base64 — NOT safe to commit
```

### Step 4 — Confirm the app still works end to end

```bash
kubectl port-forward -n online-boutique svc/frontend 8080:80
```

Add something to your cart at `http://localhost:8080` — if checkout still works, cartservice authenticated to Redis correctly.

## Failure Simulation

| Scenario | How to break it | Detect | Recover |
|---|---|---|---|
| Wrong/missing Redis password | `kubectl delete secret redis-cart-credentials -n online-boutique` | `cartservice` pods start `CrashLoopBackOff` or error-logging Redis connection failures; `redis-cart` itself is unaffected (it already has `--requirepass` baked into its running process) | Re-run `setup.sh` — a new SealedSecret is generated and applied |
| Controller loses its private key | `kubectl delete deployment sealed-secrets-controller -n kube-system` then reapply the controller manifest fresh (new keypair is generated) | Any *new* SealedSecret you seal fails to decrypt against the *old* ciphertext; existing already-decrypted Secrets in the cluster are unaffected until they're deleted and need re-sealing | This is why the controller's private key itself needs backing up in a real environment — out of scope for this lab, but worth knowing the failure mode exists |
| ConfigMap deleted while Deployments reference it | `kubectl delete configmap online-boutique-shared-config -n online-boutique`, then `kubectl rollout restart deployment/currencyservice -n online-boutique` | New pods stuck `CreateContainerConfigError` — existing running pods are unaffected until they restart | `kubectl apply -f modules/03-config-secrets/manifests/shared-config-configmap.yaml` |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `kubeseal` fails with a connection/cert error | Controller not ready yet, or `KUBECONFIG` not pointed at this cluster | `kubectl get pods -n kube-system -l name=sealed-secrets-controller`; confirm `kubectl cluster-info` works first |
| Secret never appears after applying the SealedSecret | Controller couldn't decrypt it — usually a stale SealedSecret sealed against a *different* cluster's key (e.g. after Module 01's `destroy.sh` + a fresh rebuild) | `kubectl logs -n kube-system deployment/sealed-secrets-controller`; re-run `setup.sh` to generate and seal a fresh one |
| `cartservice` logs show a Redis auth error | `REDIS_ADDR`'s password segment doesn't match the current Secret — usually from applying an older cached SealedSecret | Re-run `setup.sh` end to end so the password used to seal and the password `redis-cart` enforces are the same generation |
| The 6 ConfigMap-consuming Deployments show `CreateContainerConfigError` | ConfigMap missing or applied to the wrong namespace | `kubectl get configmap online-boutique-shared-config -n online-boutique` |

## Cleanup

```bash
bash modules/03-config-secrets/scripts/destroy.sh
```

## Key Takeaways

- ConfigMap for shared, non-sensitive config; Secret for anything you wouldn't paste in a public Slack channel — and a plain Secret manifest is exactly as public as wherever you commit it.
- Sealed Secrets' security model is asymmetric encryption bound to one cluster's private key — that's *why* the ciphertext is safe to commit, and *why* it's useless against any other cluster.
- The same Secret can feed a CLI flag (`redis-cart`) and a connection-string env var (`cartservice`) — the consumption pattern depends on the workload, not the Secret.

## Next Module

[Module 04 — Networking & Gateway API](../04-networking-gateway/) — stop using `kubectl port-forward` and expose `frontend` properly.
