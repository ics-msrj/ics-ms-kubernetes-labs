# Module 04 — Networking & Gateway API

**Duration**: ~90 minutes | **Level**: Intermediate | **Prerequisite**: [Module 03](../03-config-secrets/)

---

## Overview

Stop reaching `frontend` through `kubectl port-forward` and expose it properly: a Cilium-implemented Gateway API `Gateway`, an automatically-issued TLS certificate via cert-manager, and a `NetworkPolicy` that finally makes good on Module 03's "zero trust" framing by locking `redis-cart` down to the one service that should reach it.

## Learning Objectives

After this module you will:
- Understand the Gateway API's role split — `GatewayClass` (an implementation, provided by Cilium), `Gateway` (a listener/entry point, yours), `HTTPRoute` (routing rules, yours) — and why that's a deliberate improvement over Ingress's single flat object.
- Know how cert-manager automates certificate issuance end to end: `ClusterIssuer` → `Certificate` (auto-created from a Gateway's TLS listener) → `Challenge` → a Secret cert-manager keeps renewed.
- Be able to state, precisely, what a `NetworkPolicy` did and didn't change — and prove it, not just assert it.

## Prerequisites

- [Module 03](../03-config-secrets/) verified.
- **A real domain** you control, with an A record pointing at a node's public IP, if using the default `letsencrypt-staging` issuer — HTTP-01 validation needs port 80 reachable from the internet at that domain. No domain? Run this module with `TLS_ISSUER=selfsigned` instead (see Lab, Step 1).
- `APP_DOMAIN` set to that real domain in `lab.env` (not the `shop.example.com` placeholder).

## Architecture

```
        Internet
            │
            │  https://<APP_DOMAIN>
            ▼
  ┌───────────────────────────┐
  │  Cilium Gateway (hostNetwork)  │  ← one Envoy per node, ports 80/443 directly on the host
  │  GatewayClass: cilium          │
  └──────────────┬─────────────┘
                 │  HTTPRoute: host == APP_DOMAIN
                 ▼
         ┌───────────────┐
         │   frontend     │  (Service, ClusterIP — unchanged since Module 02)
         └───────┬───────┘
                 │
   ┌─────────────┼──────────────────────────────┐
   ▼             ▼                               ▼
cartservice  productcatalogservice  ...   redis-cart ◀── NetworkPolicy: only cartservice may reach this

cert-manager:
  ClusterIssuer (selfsigned | letsencrypt-staging | letsencrypt-production)
        │ watches Gateway's cert-manager.io/cluster-issuer annotation
        ▼
   Certificate (frontend-tls) → Challenge (if ACME) → Secret (frontend-tls)
        used by the Gateway's HTTPS listener
```

## Theory

**Why Gateway API instead of Ingress.** `Ingress` squashes routing rules, TLS config, and infrastructure-provider behavior into one object with an escape hatch of vendor-specific annotations — every ingress controller ends up with its own dialect. Gateway API splits that into roles: a platform team owns the `GatewayClass` (which implementation, i.e. Cilium here) and the `Gateway` (which ports, which TLS certs); an application team owns `HTTPRoute` objects that attach to it. That split is why `httproute-frontend.yaml` in this module doesn't mention TLS, ports, or the implementation at all — it only says "route this hostname to this Service," which is genuinely portable across any Gateway API implementation.

**Why hostNetwork mode specifically.** Cilium's Gateway API normally provisions its Envoy proxy behind a `LoadBalancer`-type Service — fine on a cloud with a load balancer controller, useless on bare `kubeadm` where that Service would sit `<pending>` forever. `gatewayAPI.hostNetwork.enabled=true` makes Cilium's Envoy bind directly to ports 80/443 on the host network of every node instead, which is reachable the same way SSH to that node is: by the node's own IP. That's what makes "point your DNS A record at a node's IP" a complete instruction on this cluster.

**Why cert-manager needs a live HTTP-01 challenge (for Let's Encrypt).** Let's Encrypt has to verify you actually control `APP_DOMAIN` before issuing anything. HTTP-01 does that by asking your infrastructure to serve a specific token at `http://<APP_DOMAIN>/.well-known/acme-challenge/<token>` — if that request reaches Let's Encrypt's validator successfully, you've proven control of whatever's answering on port 80 at that domain. cert-manager automates the whole exchange: it creates a temporary `HTTPRoute` for the challenge path, waits for Let's Encrypt to hit it, and cleans up. This is also exactly why a domain and reachable port 80 aren't optional for that path — there's no way to prove domain ownership over HTTP without them. `selfsigned` skips this whole exchange (and the trust it buys you) entirely, which is the tradeoff described in Prerequisites.

**Why `redis-cart-allow-cartservice-only` is enough — no separate "default deny" object.** A `NetworkPolicy` that selects a pod and declares ingress rules makes that pod deny everything outside those rules, implicitly. Selecting `app: redis-cart` with one `from` rule for `app: cartservice` *is* the default-deny for that pod — nothing else needs to be written. (What that implicit deny does to the *rest* of the namespace if you scope a policy that way at `podSelector: {}` — matching everything — is the [bonus exercise](manifests/bonus/networkpolicy-default-deny-ingress.yaml) below; it's deliberately not part of this module's default state, because doing that for real means writing an explicit allow for every one of Online Boutique's caller→callee edges, which is more scope than this module signed up for.)

## Lab

### Step 1 — Choose your TLS path

```bash
# Real domain, DNS pointed at a node's public IP, port 80/443 reachable:
#   set ACME_EMAIL in lab.env, leave TLS_ISSUER=letsencrypt-staging (the default)
# No real domain:
export TLS_ISSUER=selfsigned
```

### Step 2 — Deploy

```bash
bash modules/04-networking-gateway/scripts/setup.sh
```

### Step 3 — Verify

```bash
bash modules/04-networking-gateway/scripts/verify.sh
```

### Step 4 — Browse it for real

```bash
curl -vk "https://${APP_DOMAIN}"   # -k ignores trust errors — expected with selfsigned or letsencrypt-staging
```

Open it in a browser. With `letsencrypt-staging`, expect a trust warning (staging certs are deliberately untrusted — that's what keeps them off the production rate limit). Once that works end to end, switch:

```bash
TLS_ISSUER=letsencrypt-production bash modules/04-networking-gateway/scripts/setup.sh
```

### Step 5 — Prove the NetworkPolicy, not just trust it

```bash
kubectl run probe --image=busybox:1.36.1 --restart=Never -n online-boutique --rm -it \
  --overrides='{"spec":{"containers":[{"name":"probe","image":"busybox:1.36.1","resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"50m","memory":"32Mi"}}}]}}' \
  -- sh -c "nc -zv -w3 redis-cart 6379"
```

This should hang/fail — this pod isn't labeled `app=cartservice`. That's `verify.sh`'s own test, made visible.

## Failure Simulation

| Scenario | How to break it | Detect | Recover |
|---|---|---|---|
| Certificate stuck pending | Point `APP_DOMAIN`'s DNS at the wrong IP, or block port 80 | `kubectl describe certificate frontend-tls -n online-boutique` shows the Challenge not completing | Fix DNS/firewall, or fall back to `TLS_ISSUER=selfsigned` |
| Gateway stops routing | `kubectl delete httproute frontend -n online-boutique` | `curl https://${APP_DOMAIN}` fails/404s; `kubectl get httproute` shows it gone | `kubectl apply` the templated HTTPRoute again (or re-run `setup.sh`) |
| Full namespace lockdown | Apply [`bonus/networkpolicy-default-deny-ingress.yaml`](manifests/bonus/networkpolicy-default-deny-ingress.yaml) | Every pod-to-pod call inside the namespace starts failing except `redis-cart` (already had its own allow rule) | `kubectl delete -f` the same file |
| L7 HTTP enforcement | Apply [`bonus/ciliumnetworkpolicy-loadgenerator-l7.yaml`](manifests/bonus/ciliumnetworkpolicy-loadgenerator-l7.yaml) | `loadgenerator`'s POST-based checkout simulation starts failing while GETs keep working | `kubectl delete -f` the same file |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `GatewayClass 'cilium' not Accepted` | Gateway API CRDs weren't installed before Cilium's `gatewayAPI.enabled=true` took effect | Re-run `setup.sh` — it installs the CRDs first; if it's still stuck, `kubectl describe gatewayclass cilium` |
| Gateway never `Programmed` | Cilium Envoy pods not running, or `hostNetwork` port 80/443 already in use on the node (another process bound to it) | `kubectl get pods -n kube-system -l k8s-app=cilium`; `ss -tlnp | grep -E ':80|:443'` on the node |
| `Certificate` stuck, `Challenge` shows connection refused/timeout | Port 80 not actually reachable from the internet at `APP_DOMAIN` — a firewall/security-group rule, or DNS pointing at the wrong node | `curl http://<APP_DOMAIN>/.well-known/acme-challenge/test` from a machine outside your network while a challenge is in flight |
| Let's Encrypt production returns a rate-limit error | Too many certificate requests for the same hostname this week | Wait out the window, or keep using `letsencrypt-staging` while iterating — see [Let's Encrypt's rate limit docs] for exact numbers, which change over time |
| `verify.sh`'s NetworkPolicy probes hang for a long time before failing | Expected for the "denied" probe — it's a 3-second timeout inside the pod (`nc -w3`), not an error | None needed; if it hangs past ~25s something else is wrong — check `kubectl get networkpolicy -n online-boutique` |

## Cleanup

```bash
bash modules/04-networking-gateway/scripts/destroy.sh
```

## Key Takeaways

- Gateway API's `GatewayClass`/`Gateway`/`HTTPRoute` split maps to who actually owns each decision (implementation / infrastructure / routing) — that's the whole reason it replaced Ingress's single annotated object.
- `hostNetwork` mode is what makes Gateway API workable on bare-metal/native clusters without a cloud LoadBalancer — know this pattern, it's not Cilium-specific.
- A `NetworkPolicy`'s scope is exactly its `podSelector` — one targeted policy doesn't touch anything outside that selector, which is both its safety and its limitation (see the bonus default-deny exercise for the difference).

## Next Module

[Module 05 — Storage](../05-storage/) — replace the `local-path` placeholder from Module 02 with a real treatment of StorageClass, CSI, and VolumeSnapshot.
