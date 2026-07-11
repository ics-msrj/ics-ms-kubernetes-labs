# Module 06 — Security Policy

**Duration**: ~90 minutes | **Level**: Intermediate | **Prerequisite**: [Module 05](../05-storage/)

---

## Overview

Three layers of security that operate at three different altitudes, all applied to the same running app: **RBAC** (who can call the Kubernetes API, and for what), **Pod Security Admission** (what a pod spec is allowed to request, e.g. no privileged containers), and **Kyverno policy-as-code** (arbitrary custom rules — image tags, resource limits — neither of the other two can express).

## Learning Objectives

After this module you will:
- Be able to state exactly what each of the three layers can and can't see — RBAC has no idea what's inside a pod spec; PSA has no idea who's making the API call; Kyverno can see both but replaces neither.
- Know how to test an RBAC grant directly (`kubectl auth can-i --as=...`) instead of reading YAML and hoping.
- Understand why Pod Security Admission is enforced at admission time only — it validates new pods, it does not retroactively touch what's already running.

## Prerequisites

- [Module 05](../05-storage/) verified.

## Architecture

```
 API request                    Pod creation request                Pod spec content
      │                                  │                                  │
      ▼                                  ▼                                  ▼
┌───────────┐                  ┌──────────────────┐              ┌──────────────────┐
│   RBAC     │                  │  Pod Security      │              │     Kyverno        │
│            │                  │  Admission          │              │  ClusterPolicy      │
│ "Can this  │                  │  (built into        │              │  (custom rules,     │
│ identity   │                  │   the API server)    │              │   admission webhook) │
│ do this    │                  │                     │              │                     │
│ verb, on   │                  │ "Is this pod spec   │              │ "Does the image tag │
│ this       │                  │  privileged/        │              │  say :latest? Are   │
│ resource?" │                  │  hostNetwork/       │              │  resource limits    │
│            │                  │  running as root?"  │              │  missing?"          │
└───────────┘                  └──────────────────┘              └──────────────────┘
   viewer, ci-deployer            online-boutique:                  disallow-latest-tag
   ServiceAccounts                  restricted                      require-resource-limits
```

## Theory

**RBAC answers "who," nothing else.** A `Role` + `RoleBinding` says *this identity* may perform *these verbs* on *these resources*, scoped to a namespace (`ClusterRole`/`ClusterRoleBinding` for cluster-wide). It has no opinion on what a Deployment's pod template contains — a `Role` that allows `create` on `deployments` permits creating a Deployment running as root with `hostNetwork: true`, if nothing else stops it. That's what the next two layers are for. This module's two ServiceAccounts (`viewer`, `ci-deployer`) exist to make that concrete: `ci-deployer` can `patch` Deployments (what a CI pipeline needs) but was never granted access to `secrets` at all — not "read-only access to secrets," *no rule mentioning secrets exists*. `kubectl auth can-i` asks the API server the same question it asks itself on every real request, which is why it's the actual verification here, not just a description of the YAML's intent.

**Pod Security Admission answers "is this pod spec safe," at creation time only.** The three Pod Security Standards — `privileged`, `baseline`, `restricted` — are built into the API server, no controller to install. `restricted` is the strict end: no privileged containers, must run as non-root, must drop all Linux capabilities, no host namespaces. Every container Online Boutique ships already sets `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` (visible in `workloads/online-boutique/upstream/kubernetes-manifests.yaml` since Module 02) — which is *why* labeling the namespace `restricted` in this module doesn't break anything. That's not a coincidence to gloss over: it's evidence that "secure by default" from the very first module was a real decision with a payoff, not a slogan. The label only affects pods **created after** it's applied — it doesn't re-evaluate what's already running, which `verify.sh` confirms by checking existing pods are untouched while a freshly-attempted privileged pod gets rejected.

**Kyverno covers what neither of the above can.** "No `:latest` tags" and "every container needs resource limits" aren't security-context fields PSA understands, and they're not an RBAC concern at all — they're organization-specific rules about *content*, the same category of thing a linter enforces in CI, except enforced at the API server as an admission webhook, so nothing can bypass it by skipping CI. `validationFailureAction: Enforce` means Kyverno actually rejects violating requests (the alternative, `Audit`, only logs/reports — a reasonable rollout strategy for a new policy in a real environment, but this module goes straight to enforcing since we already know the fleet complies).

## Lab

### Step 1 — Deploy

```bash
bash modules/06-security-policy/scripts/setup.sh
```

### Step 2 — Verify

```bash
bash modules/06-security-policy/scripts/verify.sh
```

Every enforcement check here actually attempts the forbidden action and confirms it's rejected — not just checks that a policy object exists.

### Step 3 — Feel the difference yourself

```bash
# RBAC: viewer can look, not touch
kubectl auth can-i get pods -n online-boutique --as=system:serviceaccount:online-boutique:viewer       # yes
kubectl auth can-i delete pods -n online-boutique --as=system:serviceaccount:online-boutique:viewer     # no

# PSA: try to run something restricted forbids
kubectl run root-test -n online-boutique --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"root-test","image":"busybox:1.36","securityContext":{"runAsUser":0}}]}}'
# -> forbidden: violates PodSecurity "restricted"

# Kyverno: try to deploy an unpinned image
kubectl run latest-test -n online-boutique --image=nginx --restart=Never
# -> rejected by the disallow-latest-tag policy before PSA even gets a turn
```

### Step 4 — See what over-privileging actually grants (and revert it)

Walk through [`manifests/bonus/rbac-overprivileged-example.yaml`](manifests/bonus/rbac-overprivileged-example.yaml) — apply it, run the `kubectl auth can-i` command in its header comment, then remove it.

## Failure Simulation

| Scenario | How to break it | Detect | Recover |
|---|---|---|---|
| CI pipeline identity compromised | Assume `ci-deployer`'s token is leaked — what's the actual blast radius? | `kubectl auth can-i --list --as=system:serviceaccount:online-boutique:ci-deployer` shows the full, small grant | This *is* the recovery — the point of least privilege is that "compromised" doesn't mean "game over" |
| A real deploy needs to loosen a policy | Try shipping a genuinely un-pinned base image through `disallow-latest-tag` | `kubectl describe clusterpolicy disallow-latest-tag` / the rejected request's error message names the exact rule | Either fix the image tag (the almost-always-correct answer) or add a scoped `exclude` block to the policy — never disable the whole policy to unblock one deploy |
| PSA silently doesn't apply where you think it does | Deploy a workload into a *different* namespace than `online-boutique` | It succeeds even if it would've violated `restricted` — labels are per-namespace, not cluster-wide | `kubectl get ns --show-labels` to audit which namespaces actually enforce anything |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `verify.sh`'s privileged-pod probe unexpectedly succeeds | PSA labels didn't apply, or applied to the wrong namespace | `kubectl get namespace online-boutique -o jsonpath='{.metadata.labels}'` |
| `kubectl auth can-i` gives an unexpected answer | RBAC objects applied to the wrong namespace, or a typo in the ServiceAccount name | `kubectl get role,rolebinding -n online-boutique`; confirm the ServiceAccount exists: `kubectl get sa -n online-boutique` |
| Kyverno policy shows `ready: false` for a long time | `kyverno-admission-controller` not ready yet, or a policy YAML syntax error | `kubectl get clusterpolicy <name> -o yaml` — check `.status` for a message; `kubectl get pods -n kyverno` |
| A legitimate deploy gets rejected unexpectedly | One of the two Kyverno policies is stricter than intended for a real edge case | `kubectl get events -n online-boutique --field-selector reason=PolicyViolation`; adjust the policy's `match`/`exclude` rather than disabling it |

## Cleanup

```bash
bash modules/06-security-policy/scripts/destroy.sh
```

## Key Takeaways

- RBAC, Pod Security Admission, and policy engines answer different questions and don't substitute for each other — a hardened cluster needs all three, not the strongest one.
- `kubectl auth can-i --as=` is how you verify an RBAC grant is what you think it is — reading the YAML is not verification.
- Security controls that were designed in from Module 02 onward (non-root, dropped capabilities, pinned image tags) are why this module's `restricted` PSA and Kyverno policies could go straight to enforcing without breaking anything — retrofitting this onto an existing insecure fleet is a much bigger project than turning it on for one that was already built this way.

## Next Module

[Module 07 — Scalability & HA](../07-scalability-ha/) — HPA, VPA, KEDA, and PodDisruptionBudgets.
