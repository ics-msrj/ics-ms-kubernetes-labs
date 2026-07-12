# Module 11 — GitOps & CI/CD

**Duration**: ~120 minutes | **Level**: Advanced | **Prerequisite**: [Module 10](../10-package-management/)

---

## Overview

Every module up to this point ran `setup.sh` by hand. This module installs **ArgoCD** and hands it the two artifacts Module 10 built — the Helm chart and the `dev` Kustomize overlay — as an **App-of-Apps**, so from here on, the desired state lives in Git and ArgoCD keeps the cluster matching it, not a script you remember to re-run.

## Learning Objectives

After this module you will:
- Understand the App-of-Apps pattern: one root `Application` that itself manages a directory of child `Application` manifests, instead of applying each child by hand.
- Be able to state precisely what `selfHeal: true` does — and prove it, by manually drifting a Deployment and watching ArgoCD put it back.
- Know why secrets and GitOps are in genuine tension (a Secret's real value can't live in Git) and how `ignoreDifferences` is one honest way to handle that, not a workaround to be embarrassed about.

## Prerequisites

- [Module 10](../10-package-management/) verified — this module adopts `online-boutique-packaged` and `online-boutique-dev` exactly as it left them.
- **This repository pushed to a real Git remote** — ArgoCD syncs from Git over the network; nothing in this module works against an uncommitted local checkout. This repo assumes GitLab as `origin` (primary) with GitHub as a public mirror — see `lab.env.example`'s `GITOPS_REPO_URL` comment for the exact commands if you haven't set that up yet.

## Architecture

```
Git (GitLab, primary)
  │
  │  gitops/apps/*.yaml  (committed, real repo URL — ArgoCD reads these directly)
  ▼
┌─────────────────────────┐
│ root-app (App-of-Apps)  │  applied once, by hand, via setup.sh
└────────────┬────────────┘
             │ manages, one Application per child
    ┌───────┴────────┐
    ▼                ▼
┌───────────────────────────┐  ┌───────────────────────────┐
│ online-boutique-packaged  │  │ online-boutique-dev       │
│ (Helm source)             │  │ (Kustomize source)        │
└───────────────────────────┘  └───────────────────────────┘
  -> online-boutique-packaged namespace (Module 10's chart)
  -> online-boutique-dev namespace (Module 10's overlay)
```

## Theory

**App-of-Apps, and why it's not just "one more layer."** A single root `Application` whose `source.path` is a directory of *other* `Application` manifests means adding a third environment later is a `git add` + `git push`, not a new `helm install`/`kubectl apply` command anyone has to remember to run. `gitops/root-app.yaml` is the one object this module applies imperatively — the two children in `gitops/apps/` are never `kubectl apply`'d directly by anything in this repo; ArgoCD discovers and reconciles them purely because they exist in the directory the root `Application` points at.

**`selfHeal` is the difference between GitOps as documentation and GitOps as enforcement.** Without it, ArgoCD would show an app `OutOfSync` after someone runs `kubectl scale` by hand, but wait for a human to click "Sync." With `selfHeal: true`, that drift gets reverted automatically, typically within a few minutes. `verify.sh` doesn't just check this is configured — it manually scales `recommendationservice` to zero and confirms ArgoCD puts it back, because a `selfHeal: true` line in a YAML file you never watched actually fire is a claim, not a fact.

**Why `ignoreDifferences` exists on both child Applications.** Module 10's `redis-cart-credentials` Secret holds a real random password, generated at install time, never committed anywhere. The chart's own `values.yaml` still has to define *some* default (`redisCart.password: "changeme-override-at-install"`) so `helm lint`/`helm template` don't fail on a required value. Without `ignoreDifferences`, ArgoCD would see the live Secret (real password) differ from what Git's default values would render (the placeholder) and either fight to overwrite it every sync (with `selfHeal: true`, this would actually break Redis auth) or sit permanently `OutOfSync` (without it). Neither is right — the honest answer is "ArgoCD doesn't own this field," which is exactly what `ignoreDifferences` declares. A fully GitOps-native version of this problem sources the password from a `SealedSecret` committed next to the Application instead — the same tool Module 03 used, applied one layer further up.

**Why ArgoCD's own Kustomize builds needed a config change.** `kustomize.buildOptions: "--enable-helm ..."` in `argocd-values.yaml` isn't optional — ArgoCD's repo-server runs `kustomize build` internally to render the `online-boutique-dev` Application, and without that flag it has no way to know Module 10's `kustomize/base` needs Helm chart inflation enabled. This is the same flag `setup.sh` and this repo's CI pipelines pass by hand; ArgoCD needed to be told separately, because it isn't reading this repo's shell scripts, only its manifests.

## Lab

### Step 1 — Push this repo, if you haven't

```bash
git remote add origin git@gitlab.com:<you>/kubernetes-learning-lab.git
git remote add github git@github.com:<you>/kubernetes-learning-lab.git
git push origin main
git push github main
```

Set `GITOPS_REPO_URL` in `lab.env` to your GitLab URL.

### Step 2 — Deploy (two-phase)

```bash
bash modules/11-gitops-cicd/scripts/setup.sh
```

First run: substitutes your real repo URL into `gitops/apps/*.yaml` and stops, printing the exact `git add`/`commit`/`push` to run. Do that, then run `setup.sh` again — this second run installs ArgoCD and applies the root Application.

### Step 3 — Verify

```bash
bash modules/11-gitops-cicd/scripts/verify.sh
```

Watch it happen live: `verify.sh`'s last check scales `recommendationservice` to zero and waits for ArgoCD to revert it — you can watch this in the ArgoCD UI at the same time.

### Step 4 — Make a real GitOps change

```bash
# Edit charts/online-boutique/values.yaml — bump currencyservice's memory request
git add charts/online-boutique/values.yaml
git commit -m "bump currencyservice memory request"
git push origin main
```

Watch `https://argocd.<APP_DOMAIN>` — within ArgoCD's reconciliation window (a few minutes, or click **Refresh** to force it now), `online-boutique-packaged` picks up the change with no `helm upgrade` command run by anyone.

### Step 5 — Watch CI run

Push any change and check your GitLab pipeline (or GitHub Actions, on the mirror) — both validate the chart and overlays the same way `verify.sh`'s Step 4 change just flowed through live.

## Failure Simulation

| Scenario | How to break it | Detect | Recover |
|---|---|---|---|
| Drift you *want* to keep temporarily | `kubectl scale deployment frontend -n online-boutique-packaged --replicas=0` for an incident | ArgoCD reverts it within minutes (that's `selfHeal` working as designed) — if you need it to stay down, you must change Git, or pause auto-sync: `argocd app set online-boutique-packaged --sync-policy none` | Re-enable: `argocd app set online-boutique-packaged --sync-policy automated` |
| A bad commit to `main` | Push a chart change with an invalid YAML value | ArgoCD shows the Application `Degraded`/sync failing; `kubectl describe application online-boutique-packaged -n argocd` names the exact error | `git revert` the bad commit, push — ArgoCD reconciles back automatically |
| CI catches what ArgoCD would have deployed anyway | Push a Kustomize overlay patch targeting a resource name that doesn't exist | The `kustomize-build` CI job fails before merge — this is *exactly* why the same validation exists in CI and not only inside ArgoCD's own sync attempt | Fix the patch target, push again |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `setup.sh` exits at "PAUSE" every time, even after pushing | You edited `gitops/apps/*.yaml` again after the substitution (regenerating the placeholder), or pushed to a different branch than `GITOPS_REPO_REVISION` | `grep __GITOPS_REPO_URL__ gitops/apps/*.yaml` should return nothing; confirm `git branch --show-current` matches `GITOPS_REPO_REVISION` in `lab.env` |
| `git ls-remote` check fails in `setup.sh` | Repo not actually pushed yet, or `GITOPS_REPO_URL` uses SSH syntax but this workstation has no SSH key configured for GitLab/GitHub | Test manually: `git ls-remote $GITOPS_REPO_URL`; for a public repo, prefer the `https://` form, which needs no key at all |
| Application stuck `Unknown`/`Progressing` forever | `argocd-repo-server` can't reach the Git remote (DNS/outbound network from the cluster), or the path in the Application doesn't exist at that revision | `kubectl logs -n argocd deployment/argocd-repo-server`; confirm `path:` in the Application matches a real directory at `targetRevision` |
| `online-boutique-dev` Application fails to render | `kustomize.buildOptions` missing `--enable-helm`/`--load-restrictor` in `argocd-values.yaml`, or it didn't take effect | `kubectl get cm argocd-cm -n argocd -o yaml \| grep kustomize.buildOptions`; re-run `setup.sh` if missing |
| Redis auth breaks right after Module 11 adopts an app | `ignoreDifferences` missing/misconfigured for `redis-cart-credentials`, so ArgoCD overwrote the real password with the chart's placeholder default | `kubectl get application online-boutique-packaged -n argocd -o yaml \| grep -A5 ignoreDifferences`; re-apply the sealed/real Secret and confirm the ignoreDifferences block is present |

## Cleanup

```bash
bash modules/11-gitops-cicd/scripts/destroy.sh
```

## Key Takeaways

- App-of-Apps turns "add an environment" into a Git commit — the root Application is the only thing anyone ever applies by hand.
- `selfHeal: true` is enforcement, not just drift detection — prove it by causing drift yourself, don't take the YAML's word for it.
- Secrets don't fit cleanly into "everything lives in Git" — `ignoreDifferences` (or a SealedSecret committed alongside the Application) are honest answers; silently letting ArgoCD fight your secret manager is not.

## Next Module

[Module 12 — Progressive Delivery](../12-progressive-delivery/) — Argo Rollouts, canary and blue-green releases, automated analysis.
