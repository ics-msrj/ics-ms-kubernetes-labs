# Module 17 — Service Mesh

**Duration**: ~90 minutes | **Level**: Advanced | **Prerequisite**: [Module 08](../08-observability/)

---

## Overview

Online Boutique is Google's own canonical Istio demo app — this module is the payoff for that choice. Istio's Envoy sidecars get injected into the **real** `online-boutique` namespace (not a throwaway one, unlike several earlier modules — securing and observing traffic that doesn't actually exist teaches nothing). mTLS becomes mandatory, `currencyservice` gets automatic retries and circuit breaking, and two services light up with genuine distributed traces because — confirmed by reading their source, not assumed — they already have real OpenTelemetry instrumentation built in.

## Learning Objectives

After this module you will:
- Know exactly what a sidecar proxy adds that plain Kubernetes networking doesn't: automatic mTLS, retries, circuit breaking, and telemetry — all without changing application code, because the proxy sits in front of every container transparently.
- Understand why `hostNetwork` pods (Module 02's `node-exporter`) can't have a sidecar injected, and why that's a networking-model fact, not a configuration gap to work around.
- Be able to tell the difference between a trace with real application spans (frontend, checkoutservice — genuinely instrumented) and one with only proxy-level spans (every other service — Envoy still reports the hop, but with no visibility into what happened inside).

## Prerequisites

- [Module 08](../08-observability/) verified — Kiali reads Module 08's Prometheus, Tempo joins its Grafana.
- [Module 05](../05-storage/) verified — Tempo's storage is a Longhorn PVC.
- [Module 04](../04-networking-gateway/) verified — external traffic keeps using that Gateway; this module adds no second ingress path.

## Architecture

```
Internet ──▶ Cilium Gateway (Module 04, unchanged) ──▶ frontend Service
                                                              │
                                          ┌───────────────────┼──────────────────────┐
                                          ▼                                          ▼
                                 frontend pod                                cartservice pod
                                 ┌──────────────┐                          ┌──────────────┐
                                 │ app container  │◀── mTLS STRICC ──▶      │ app container  │
                                 │ + istio-proxy   │   (every hop,           │ + istio-proxy   │
                                 │   (Envoy)        │    every service        │   (Envoy)        │
                                 └──────────────┘    in online-boutique)    └──────────────┘
                                       │ real OTel spans                          │ proxy-level
                                       ▼ (app instrumented)                        ▼ spans only
                                     Tempo ◀────────────────────────────────────────┘
                                  (Module 08's Grafana, Explore -> Tempo)

                                 currencyservice: VirtualService (retry, timeout)
                                                  + DestinationRule (circuit breaking)

                                 Kiali ◀── mesh topology, reads Module 08's Prometheus
```

## Theory

**What a sidecar actually is.** Istio's injector adds a second container (`istio-proxy`, Envoy) to every pod in a labeled namespace, and rewrites the pod's iptables rules so all inbound and outbound traffic passes through it first — transparently, with zero application code changes. Every capability this module adds (mTLS, retries, circuit breaking, telemetry) is Envoy doing it at the network layer, which is exactly why `node-exporter` can't participate: it uses `hostNetwork: true`, meaning it shares the *node's* network namespace instead of getting its own — there's no per-pod network boundary for iptables to redirect into. This isn't a settings problem to fix; it's what `hostNetwork` means.

**Why mTLS here is "free" in a way TLS elsewhere in this repo wasn't.** Every other TLS setup in this repo (Module 04's Gateway, Module 08's Grafana) needed cert-manager and a `ClusterIssuer` — a real certificate authority relationship to manage. Istio's mTLS uses its *own* internal CA (`istiod`), automatically issuing and rotating short-lived certificates to every sidecar with no per-service configuration. `PeerAuthentication` with `mode: STRICT` is one object, cluster-namespace-scoped, and every one of the now-sidecar'd pods in `online-boutique` is covered — the tradeoff is that this PKI is Istio's own, separate from cert-manager's, and doesn't extend to anything outside the mesh.

**Real traces vs. proxy-only traces — and why this module didn't overclaim.** `src/frontend/main.go` and `src/checkoutservice/main.go` (checked directly against upstream before building this module, not assumed) both import `go.opentelemetry.io/otel`, propagate W3C trace-context headers, and export spans via OTLP gRPC — gated behind exactly two env vars, `ENABLE_TRACING=1` and `COLLECTOR_SERVICE_ADDR`. Setting those on frontend and checkoutservice turns on genuine application-level spans: what the code actually did, not just that a network hop happened. Every *other* service in the mesh still shows up in a trace — Envoy generates a span for any request passing through it, instrumented or not — but those spans only say "a call happened, this long," with nothing about what the receiving service did with it. Distinguishing which is which matters: claiming full distributed tracing when only two services are actually instrumented would be exactly the kind of overclaim this repo has avoided since Module 02.

## Lab

### Step 1 — Deploy

```bash
bash modules/17-service-mesh/scripts/setup.sh
```

Expect every pod in `online-boutique` to restart during this — that's sidecar injection happening, not a failure.

### Step 2 — Verify

```bash
bash modules/17-service-mesh/scripts/verify.sh
```

### Step 3 — Look at the mesh topology

```bash
kubectl port-forward -n istio-system svc/kiali 20001:20001
```

Open `http://localhost:20001` — the traffic graph shows every service in `online-boutique`, live, including the padlock icon Kiali draws on mTLS-secured connections.

### Step 4 — Look at a real trace

```bash
kubectl port-forward -n online-boutique svc/frontend 8080:80
```

Browse the app, add something to your cart, check out. Then in Grafana (Module 08) → **Explore** → **Tempo** datasource → search by `service.name = frontend`. Open a trace from a checkout — you'll see real spans for frontend's own handling *and* its call into checkoutservice, plus (thinner, proxy-only) spans for whatever checkoutservice called next.

### Step 5 — Prove the resilience policy under real failure

```bash
kubectl apply -f modules/17-service-mesh/manifests/bonus/virtualservice-currencyservice-fault-injection.yaml
```

Browse the app repeatedly — expect intermittent slowness on price-dependent pages (currencyservice now has a 50% chance of a 5s injected delay, forcing the retry policy from Step 1 to actually do something instead of sitting unused). Revert:

```bash
kubectl apply -f modules/17-service-mesh/manifests/currencyservice-resilience.yaml
```

## Failure Simulation

| Scenario | How to break it | Detect | Recover |
|---|---|---|---|
| mTLS accidentally loosened | `kubectl patch peerauthentication strict-mtls -n online-boutique --type merge -p '{"spec":{"mtls":{"mode":"PERMISSIVE"}}}'` | Kiali's padlock icons disappear from the traffic graph; plaintext connections would now be accepted (not just mTLS ones) | `kubectl apply -f modules/17-service-mesh/manifests/peerauthentication-strict-mtls.yaml` |
| currencyservice actually failing (not injected) | `kubectl scale deployment currencyservice -n online-boutique --replicas=0` | The retry policy retries into nothing and the request eventually times out at 5s — Kiali's graph shows the edge to currencyservice turn red | `kubectl scale deployment currencyservice -n online-boutique --replicas=1` |
| Fault injection left on by accident | Forget to revert Step 5 | Every affected page stays intermittently slow — this is exactly why the bonus file's own header comment tells you how to revert it | `kubectl apply -f modules/17-service-mesh/manifests/currencyservice-resilience.yaml` |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| A pod won't reach `2/2 Running` after restart | Sidecar injection failed or is still starting — check the injector webhook itself | `kubectl get pods -n online-boutique -o jsonpath='{.items[*].spec.containers[*].name}'`; `kubectl logs -n istio-system deployment/istiod` |
| App breaks after enabling mTLS STRICT | A caller *outside* the mesh (no sidecar) tries to reach a pod inside it directly | Confirm the caller also has injection enabled, or is calling through something that does (Module 04's Gateway → frontend still works because the Gateway terminates external TLS and hands off to the mesh at the Service boundary) |
| No traces appear in Tempo at all | `COLLECTOR_SERVICE_ADDR` unreachable, or the app never got real traffic to trace | `kubectl logs -n online-boutique deployment/checkoutservice \| grep -i trace`; generate real traffic first (Step 4) |
| Kiali shows no traffic graph / empty topology | Prometheus URL misconfigured, or mesh telemetry not flowing yet | `kubectl logs -n istio-system deployment/kiali`; confirm `external_services.prometheus.url` in `kiali-values.yaml` matches Module 08's actual Prometheus Service |
| `node-exporter` pods crash after this module | Something re-enabled injection on them (e.g., a manual `kubectl apply` of an older manifest without the exclusion annotation) | Re-apply `modules/17-service-mesh/manifests/node-exporter-no-injection.yaml` |

## Cleanup

```bash
bash modules/17-service-mesh/scripts/destroy.sh
```

## Key Takeaways

- A sidecar mesh adds mTLS/retries/circuit-breaking/telemetry at the network layer, transparently — and "transparently" has a real exception in `hostNetwork` pods, not a configurable one.
- Verify what's actually instrumented before claiming "distributed tracing" — this module checked two services' source code directly rather than assuming Istio alone produces application-level spans everywhere.
- Traffic resilience (retries, circuit breaking) and progressive delivery (Module 12's canary/blue-green) are different tools solving different problems — this module deliberately avoided re-doing Module 12's job.

## Next Module

[Module 18 — Chaos Engineering](../18-chaos-engineering/) — inject real failure and practice detecting, diagnosing, and recovering from it.
