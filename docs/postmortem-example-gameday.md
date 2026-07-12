# Postmortem: Checkout slowness and cart instability during GameDay drill

**Date**: 2026-07-12
**Author**: Lab student (worked example — written for Module 18)
**Severity**: SEV2 (degraded, user-facing — checkout still completed, just slowly, with occasional cart pod restarts)
**Status**: final

This is a **blameless** postmortem for a *drill*: `modules/18-chaos-engineering/manifests/workflow-combined-incident.yaml` was applied by a study partner without telling the responder which fault(s) were active — the point of the exercise was to reach the two root causes below using only Module 08/09's observability stack, the same way a real on-call would.

## Summary

For roughly 3 minutes, `currencyservice` calls became slow and intermittently failed, and `cartservice` pods restarted twice. These turned out to be two unrelated injected faults running at the same time, not one cascading failure — the drill's actual lesson.

## Impact

- **User-facing?** Yes — checkout pages loaded noticeably slower; a small number of add-to-cart requests during the two `cartservice` restarts likely failed client-side (unconfirmed, drill only, no real user traffic)
- **Duration**: 14:02:10 → 14:05:30 (~3m20s)
- **Scope**: `currencyservice` and `cartservice` in the `online-boutique` namespace only

## Timeline

| Time | Event |
|---|---|
| 14:02:10 | First symptom: Grafana's Online Boutique dashboard (Module 08) shows `currencyservice` p99 latency jump from ~15ms to over 1s |
| 14:02:45 | `cartservice` pod restart count increments by 1 (`kube-state-metrics` panel) |
| 14:03:00 | Started diagnosis — two symptoms noticed at once, initial (wrong) hypothesis: a single cascading failure starting in currencyservice and taking cartservice down with it |
| 14:03:20 | Checked Kiali traffic graph: the edge into `currencyservice` shows a mix of slow and red (failed) requests, but no edge shows `cartservice` calling `currencyservice` — the two are not on the same call path from the mesh's point of view. Cascading-failure hypothesis dropped. |
| 14:03:50 | `kubectl logs -n online-boutique deployment/cartservice --previous` after the second restart shows no error, no OOM, no panic — just a clean SIGTERM. Consistent with something external killing the pod, not an application crash. |
| 14:04:10 | Loki query (Module 09, Grafana Explore) for `{namespace="online-boutique"} \|= "currencyservice"` shows repeated `context deadline exceeded` / retry log lines matching Module 17's `VirtualService` retry policy (3 attempts, `perTryTimeout: 2s`) actually firing — confirms currencyservice's issue is network-layer, not a code bug |
| 14:04:40 | `kubectl get events -n online-boutique --sort-by=.lastTimestamp` shows `Killing` events for two different `cartservice` pods, no `Unhealthy` liveness-probe events before either — ruling out a probe failure and pointing at something killing pods directly |
| 14:05:00 | Root cause identified for both (see below) |
| 14:05:30 | No mitigation needed — both faults were on a bounded `duration`/`deadline` and self-terminated; confirmed via `kubectl get workflow,podchaos,networkchaos -n online-boutique` returning empty |

## Detection

- **How was this detected?** Grafana dashboard (latency panel) plus pod restart count, both from Module 08's existing Prometheus — no dedicated alert fired, because no `PrometheusRule` in this repo currently alerts on `currencyservice` latency specifically (see Action Items)
- **Time to detect** (incident start → first human awareness): effectively 0 — the responder was actively watching the dashboard during the drill window, which is not realistic for an unattended production system
- **Could it have been detected sooner?** Not really sooner, but more *reliably* — an alert would catch this without someone staring at a dashboard at the right moment

## Root Cause

Two independent, unrelated faults, both injected by the same `Workflow` object as a deliberate compound-incident drill:

1. **`currencyservice` latency/errors**: a `NetworkChaos` (`action: netem`) object added 1200ms±300ms latency and 15% packet loss to `currencyservice`'s outbound traffic. This wasn't a currencyservice bug — the retry/circuit-breaking policy from Module 17 (`currencyservice-resilience.yaml`) was working exactly as designed, retrying into a genuinely degraded network path.
2. **`cartservice` restarts**: a `PodChaos` (`action: pod-kill`) object killed a `cartservice` pod. Unrelated to currencyservice entirely — confirmed by Kiali showing no call-path connection between the two services for this workload.

The diagnostic trap this drill was built to expose: two simultaneous symptoms look like one cascading failure until you check whether the affected services actually call each other.

## Diagnosis Process

1. Saw two symptoms at once (currencyservice latency, cartservice restarts) → assumed cascading failure by default, the common (and wrong) instinct
2. Checked Kiali's traffic graph for a call-path edge between the two services → found none → dropped the cascading-failure hypothesis
3. Checked `cartservice`'s previous-container logs for a crash signature → found none, just clean termination → pointed at an external kill, not an app bug
4. Checked Loki for currencyservice-related log lines → found retry/timeout messages matching Module 17's known retry configuration → confirmed network-layer cause, not application-layer
5. Checked `kubectl get events` for the actual eviction/kill signal on the `cartservice` pods → confirmed `Killing`, no prior `Unhealthy` → ruled out probe-driven restart, consistent with a direct pod-kill

## Resolution

No manual mitigation was required — both faults were scoped with a bounded lifetime (`duration: "20s"` per pod-kill occurrence inside a 200s `deadline` window, `duration: "180s"` for the network fault) by design, since this was a drill and not a real incident. In a real incident with an unbounded cause, the mitigation for each root cause would be independent: restart/replace the affected `currencyservice` path (or wait out a real network issue) and confirm `cartservice`'s replica count recovers on its own via its Deployment controller.

## What Went Well

- Module 17's retry/circuit-breaking policy for `currencyservice` behaved exactly as designed under real (injected) network degradation — this was the first time it had been exercised by anything other than the manual fault-injection bonus
- Kiali's traffic graph was the single fastest way to disprove the cascading-failure hypothesis — a call-path question answered visually in seconds instead of by reading logs

## What Went Poorly

- No `PrometheusRule` alerts on `currencyservice` latency specifically — detection relied entirely on someone already watching the dashboard, which doesn't hold in a real unattended incident
- The two-simultaneous-faults case wasn't obvious until Kiali was checked — a responder without service-mesh visibility (i.e., before Module 17) would have taken meaningfully longer to separate the two root causes

## Action Items

| Action | Owner | Priority |
|---|---|---|
| Add a `PrometheusRule` alerting on `currencyservice` p99 latency > 1s for 2m (extends Module 08's `online-boutique-alerts` PrometheusRule) | lab student | P1 |
| When two symptoms appear together, check the mesh call graph (Kiali) for an actual edge between them BEFORE assuming a cascade | lab student (process note, not a ticket) | P2 |
