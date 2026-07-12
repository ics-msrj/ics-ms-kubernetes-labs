# Module 14 — Multi-Cluster Management

**Duration**: ~60 minutes | **Level**: Advanced | **Prerequisite**: [Module 13](../13-cluster-operations/)

---

## Overview

Every module so far has assumed one cluster. This module provisions a **second, genuinely separate kubeadm cluster** and installs **Rancher** on the primary one to manage both from a single pane of glass — the actual point of this module isn't Rancher's UI, it's what "multi-cluster management" requires to be true at all: more than one cluster, actually reachable, actually distinct.

## Learning Objectives

After this module you will:
- Have proven to yourself that Module 01's bootstrap scripts are genuinely reusable infrastructure, not a one-off — this module runs the exact same `setup-control-plane.sh`/`setup-worker.sh` against a second set of VMs with zero modification.
- Understand Rancher's import model: an existing, independently-functioning cluster gets an agent deployed into it that phones home — Rancher doesn't take over how that cluster runs, it becomes another window onto it.
- Know why this module's Rancher install uses Gateway API mode, not Ingress — and that this isn't a stylistic choice this repo made early and never revisited: ingress-nginx retired in March 2026, and Rancher's own chart reflects that.

## Prerequisites

- [Module 04](../04-networking-gateway/) verified — Rancher exposes itself through the same `cilium` GatewayClass.
- **A second, small set of VMs** — 1 control-plane + 1 worker is enough (this cluster never runs Online Boutique — only Rancher's own agent, plus a minimal single-Deployment canary in Step 5). Provision them exactly like Module 01: bring your own, or reuse the optional Terraform in `modules/01-cluster-setup/terraform/aws/` with `terraform workspace new cluster2` first, so its state stays independent of the primary cluster's.
- Fill in `SECOND_CONTROL_PLANE_PUBLIC_IP`, `SECOND_CONTROL_PLANE_PRIVATE_IP`, `SECOND_WORKER_PUBLIC_IPS` in `lab.env`.

## Architecture

```
Primary cluster (Modules 01-13)  Second cluster (this module's import demo only)
┌─────────────────────────────┐    ┌─────────────────────────────┐
│ Rancher                     │    │ cattle-cluster-agent        │
│ (Gateway API, cilium)       │    │ deployed by the import      │
│ rancher.<APP_DOMAIN>        │    │ manifest (Step 3), runs     │
│ runs on the primary cluster │    │ on the second cluster       │
└─────────────────────────────┘    └─────────────────────────────┘
kubeconfig.yaml (:6443 tunnel)   kubeconfig-cluster2.yaml (:6444 tunnel)

Rancher <-> cattle-cluster-agent: the agent 'phones home' to Rancher over the
network Module 04's Gateway exposes it on -- Rancher never reaches INTO the
second cluster on its own.
```

## Theory

**Reusing Module 01's scripts is the actual demonstration.** `setup.sh` doesn't reimplement cluster bootstrap — it `scp`s the identical `setup-control-plane.sh` and `setup-worker.sh` from Module 01 onto new VMs and runs them with different IP variables. If those scripts had hidden assumptions specific to the first cluster (a hardcoded IP, a name baked in somewhere), this would fail. That they don't is what "reusable infrastructure" actually means in practice, not just in principle.

**What "importing" a cluster into Rancher does and doesn't do.** The second cluster is fully independent before, during, and after this module — it has its own etcd, its own control plane, its own API server, reachable on its own via `kubeconfig-cluster2.yaml` whether or not Rancher is involved. Importing it deploys `cattle-cluster-agent`, which opens an outbound connection *from* the second cluster *to* Rancher — this is why import works even when Rancher can't reach the second cluster's API server directly (a common real-world case: clusters behind NAT, in different networks, in different clouds). Rancher becomes a place to *observe and act on* the second cluster; it does not become that cluster's control plane.

**Why Gateway API here too.** Rancher's Helm chart historically assumed an Ingress controller; as of the version this module installs, it has a documented `networkExposure.type: gateway` path using the same `Gateway`/`HTTPRoute` resources every other exposed service in this repo (Grafana, ArgoCD) has used since Module 04 and Module 08. `tls.source: rancher` is the one exception to this repo's usual cert-manager/Let's Encrypt pattern — Rancher generates and manages its own internal CA, which is appropriate for what is, like Prometheus (Module 08), primarily an internal admin surface.

**Why the promotion demo (Step 5) isn't an ArgoCD ApplicationSet.** An `ApplicationSet` with a cluster generator is the idiomatic ArgoCD-native answer to "deploy this to every registered cluster" — but ArgoCD's controller runs as pods *inside* the primary cluster, and it would need to reach the second cluster's real API server (port 6443) directly, over the network, to register it. That means exposing 6443 publicly — something Module 01's entire design deliberately avoids everywhere else in this repo (API access is always via SSH tunnel, never a public listener). The Rancher agent gets away with a cross-cluster connection because it's the *reverse* direction, over the *already-public* Gateway on port 443 (see this Theory section's second paragraph) — a genuinely different, already-safe network path, not the same thing with a different name. `promote-canary.sh` gets the same pedagogical result (one declarative source, converging identically on two independent clusters) by reusing the two SSH tunnels that already exist, from the workstation, instead of asking ArgoCD to reach across a boundary this repo otherwise never crosses.

## Lab

### Step 1 — Deploy

```bash
bash modules/14-multi-cluster-mgmt/scripts/setup.sh
```

### Step 2 — Verify

```bash
bash modules/14-multi-cluster-mgmt/scripts/verify.sh
```

The import check will show a `WARN` at this point — that's expected, Step 3 hasn't happened yet.

### Step 3 — Import the second cluster (manual)

1. Open `https://rancher.<APP_DOMAIN>`, log in with the bootstrap password `setup.sh` printed, set a real admin password.
2. **Clusters** → **Import Existing** → choose **Generic**.
3. Rancher shows a `kubectl apply -f https://rancher.<APP_DOMAIN>/v3/import/<token>.yaml` command — copy it.
4. Run it against the **second** cluster specifically:
   ```bash
   KUBECONFIG=modules/14-multi-cluster-mgmt/kubeconfig-cluster2.yaml kubectl apply -f https://rancher.<APP_DOMAIN>/v3/import/<token>.yaml
   ```
5. Back in the Rancher UI, watch the cluster state move to `Active` (a minute or two).

### Step 4 — Verify again, and try centralized RBAC

```bash
bash modules/14-multi-cluster-mgmt/scripts/verify.sh
```

In the Rancher UI: **Users & Authentication** → create a Standard User → **Cluster Members** on the second cluster only → add that user with a scoped role (not Owner). Log in as them (or inspect their effective permissions) and confirm they can see the second cluster but not the primary one — this is Rancher's RBAC layered *above* each cluster's own, not a replacement for it.

### Step 5 — Promote the same manifest to both clusters

```bash
bash modules/14-multi-cluster-mgmt/scripts/promote-canary.sh
```

Applies `manifests/canary-app.yaml` to both clusters via their two independent SSH tunnels, then proves convergence: the same container image on both, and each cluster's own copy correctly reporting which cluster it's running on. This is the actual "multi-cluster" payoff Rancher's single-pane-of-glass view can *show* you but doesn't *do* for you — Rancher lets you see two clusters at once, it doesn't promote anything between them.

## Failure Simulation

| Scenario | How to break it | Detect | Recover |
|---|---|---|---|
| Agent connectivity lost | `KUBECONFIG=modules/14-multi-cluster-mgmt/kubeconfig-cluster2.yaml kubectl delete deployment cattle-cluster-agent -n cattle-system` | Rancher shows the second cluster's state degrade away from `Active` | Re-run the import command from Step 3 — it's idempotent |
| Rancher itself down | `kubectl scale deployment rancher -n cattle-system --replicas=0` | `https://rancher.<APP_DOMAIN>` stops responding — but both clusters keep running completely unaffected (this is the point of Theory's second paragraph) | `kubectl scale deployment rancher -n cattle-system --replicas=1` |
| Over-broad RBAC grant | Add a Standard User as Cluster Owner instead of a scoped role | They can now do anything on that cluster, including deleting it from Rancher | Downgrade their role — same principle as Module 06's RBAC, one layer up |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Second cluster bootstrap fails partway | Same causes as Module 01 (containerd/cgroup driver, swap, etc.) — this is the identical script | Module 01's Troubleshooting table applies unchanged; SSH in and check `systemctl status kubelet` |
| `:6444` tunnel keeps dying | Same SSH keepalive considerations as the primary cluster's `:6443` tunnel | Re-run the `ssh -f -N -L 6444:...` command `setup.sh` prints on failure |
| Import command never reaches `Active` | `cattle-cluster-agent` can't reach Rancher outbound — check the second cluster's egress (firewall/security group) | `KUBECONFIG=modules/14-multi-cluster-mgmt/kubeconfig-cluster2.yaml kubectl logs -n cattle-system deployment/cattle-cluster-agent` |
| Rancher UI shows a certificate warning | Expected — `tls.source: rancher` is a self-signed internal CA, the same tradeoff Module 08 made for Prometheus/Alertmanager | Accept it for a lab; a real deployment would set `tls.source: secret` referencing a cert-manager-issued certificate the same way `frontend`/`grafana`/`argocd` already do |
| `promote-canary.sh` fails on the second cluster only | The `:6444` tunnel died between Step 1 and now | Same fix as the `:6444` tunnel row above — re-establish it, then re-run |

## Cleanup

```bash
bash modules/14-multi-cluster-mgmt/scripts/destroy.sh
```

## Key Takeaways

- Multi-cluster management tooling has nothing to manage without genuinely separate clusters — this module proved that by standing up a real second one, not simulating it.
- "Import" means deploying an outbound-connecting agent, not taking ownership of a cluster's control plane — the imported cluster works identically with or without Rancher watching it.
- Centralized RBAC in a tool like Rancher is an additional layer on top of each cluster's own RBAC (Module 06), not a replacement for it.
- Not every cross-cluster problem has an ArgoCD-native answer without a real infrastructure tradeoff — recognizing when a "more idiomatic" pattern would quietly require breaking a security decision made elsewhere is as important as knowing the pattern exists.

## Next Module

[Module 15 — Multi-Tenancy & Cost](../15-multi-tenancy-cost/) — ResourceQuota, LimitRange, and cost visibility for multiple teams sharing one cluster.
