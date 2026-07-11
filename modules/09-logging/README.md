# Module 09 — Logging

**Duration**: ~60 minutes | **Level**: Intermediate | **Prerequisite**: [Module 08](../08-observability/)

---

## Overview

Metrics tell you *that* something is wrong (Module 08's alerts); logs tell you *why*. This module installs **Loki** (log storage, indexed by label rather than full-text) and **Grafana Alloy** (a DaemonSet that ships every pod's logs to it, cluster-wide), then wires Loki into the Grafana instance Module 08 already built.

## Learning Objectives

After this module you will:
- Know why Loki indexes labels (namespace, pod, container) instead of log content — and what that trades away versus a full-text search system.
- Understand how Alloy pulls logs through the Kubernetes API (the same mechanism as `kubectl logs`) instead of tailing files on the host, and why that's the modern default over the older hostPath-DaemonSet pattern.
- Be able to write and read a basic LogQL query, and correlate a log line with a metric or alert from Module 08.

## Prerequisites

- [Module 08](../08-observability/) verified — this module extends that Grafana install rather than creating a new one.
- [Module 05](../05-storage/) verified — Loki's storage is a Longhorn-backed PVC.

## Architecture

```
┌───────────┐  ┌───────────┐  ┌───────────┐
│  node A    │  │  node B    │  │  node C    │
│  Alloy pod │  │  Alloy pod │  │  Alloy pod │   DaemonSet — one per node
└─────┬─────┘  └─────┬─────┘  └─────┬─────┘
      │  discovery.kubernetes: watches the K8s API for pods
      │  loki.source.kubernetes: reads each pod's logs via that API
      │  (no hostPath, no /var/log/pods mount)
      └───────────────┬───────────────┘
                        ▼
                 loki-gateway
                        │
                        ▼
                 ┌───────────┐
                 │   Loki     │  SingleBinary, filesystem storage
                 │            │  on a Longhorn PVC (Module 05)
                 └─────┬─────┘
                        │ datasource (ConfigMap, sidecar-discovered)
                        ▼
                 Grafana (Module 08) — Explore view, LogQL
```

## Theory

**Why Loki doesn't index log content.** A full-text log search system (Elasticsearch, for instance) indexes every word of every log line — powerful, and expensive: the index can end up larger than the logs themselves. Loki indexes only a small set of *labels* (which this module sets to `namespace`, `pod`, `container`, `node` — see `manifests/alloy-config.alloy`) and stores the actual log text compressed, unindexed, in chunks. A query like `{namespace="online-boutique", container="cartservice"}` is a fast label lookup; filtering *inside* those results for a word (`|= "error"`) is a linear scan over just that narrowed set — cheap because the label filter already did the expensive part. This is why Loki-based logging pushes you toward consistent, low-cardinality labels: they're not just organization, they're the entire performance model.

**Why `loki.source.kubernetes` instead of tailing `/var/log/pods`.** The traditional DaemonSet log shipper (Promtail's original design, and still how Fluent Bit/Fluentd typically work) mounts the host's log directory and tails files directly — fast and battle-tested, but it needs a hostPath volume and runs with more implicit access to the node's filesystem than the job strictly requires. Alloy's `loki.source.kubernetes` component instead calls the same Kubernetes API `kubectl logs` uses — no hostPath mount, no dependency on a specific container runtime's on-disk log format, just the `pods`/`pods/log` RBAC the chart's own ClusterRole already grants. The tradeoff is scale: at very high log volume, the API server becomes a bottleneck no local file tail has — a real consideration for a large production fleet, a non-issue for this lab.

**Why Promtail isn't the tool here.** Promtail was Loki's original, purpose-built shipper — and Grafana Labs has moved it to maintenance mode, consolidating future development into Alloy (a general-purpose OpenTelemetry-Collector-style agent that also happens to speak Loki, Prometheus, and Tempo natively). Building a new lab around a maintenance-mode tool in 2026 would teach a dead end; Alloy is the actively developed successor for exactly this job.

**Why this module doesn't create a new Grafana.** `manifests/grafana-loki-datasource.yaml` is a ConfigMap, not a Helm value change to Module 08's release — Grafana's sidecar (already running, already watching for labeled ConfigMaps) picks it up on its own within about a minute. This is the same "extend, don't duplicate" pattern Module 08 used for `PodMonitor`/`ServiceMonitor` rather than reinstalling Prometheus.

## Lab

### Step 1 — Deploy

```bash
bash modules/09-logging/scripts/setup.sh
```

### Step 2 — Verify

```bash
bash modules/09-logging/scripts/verify.sh
```

This queries Loki's HTTP API directly and confirms a real `online-boutique` log line comes back — not just that the Pods are `Running`.

### Step 3 — Explore logs in Grafana

Open Grafana (`https://grafana.<APP_DOMAIN>` from Module 08) → **Explore** → select the **Loki** datasource. Try:

```logql
{namespace="online-boutique"}
```

```logql
{namespace="online-boutique"} |= "error"
```

```logql
{namespace="online-boutique", container="checkoutservice"}
```

```logql
sum by (container) (count_over_time({namespace="online-boutique"}[5m]))
```

That last one — log volume per container over time — is a genuine LogQL metric query, and a good Grafana panel candidate.

### Step 4 — Correlate a log with an alert

Re-trigger Module 08's `PodRestartingFrequently` alert:

```bash
kubectl run crash-test -n online-boutique --image=busybox:1.36 --restart=Always -- sh -c "exit 1"
```

Then in Grafana's Explore, query `{namespace="online-boutique", pod=~"crash-test.*"}` and read the actual failure — this is the "why" the metric alone never told you. Clean up: `kubectl delete pod crash-test -n online-boutique`.

## Failure Simulation

| Scenario | How to break it | Detect | Recover |
|---|---|---|---|
| Logs stop flowing | `kubectl delete daemonset alloy -n monitoring` | New log lines stop appearing in Grafana Explore (existing ones are still queryable — Loki still has what it already received) | Re-run `setup.sh` |
| Loki out of disk | Fill the PVC (or just watch `kubectl get pvc -n monitoring -l app.kubernetes.io/name=loki`) | Alloy logs show push failures (`kubectl logs -n monitoring daemonset/alloy`) | Expand the PVC live — same Longhorn `allowVolumeExpansion` capability Module 05 demonstrated |
| A high-cardinality label mistake | Add a label like `pod` *and* a per-request ID to `discovery.relabel` in `alloy-config.alloy` | Loki's ingestion gets dramatically slower/more expensive as label combinations explode | Don't do this for real — it's the classic Loki footgun, worth breaking once here to feel why |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `loki` StatefulSet never becomes ready | PVC not bound — check the Longhorn prerequisite (Module 05) is actually healthy | `kubectl get pvc -n monitoring -l app.kubernetes.io/name=loki`; `kubectl describe pod loki-0 -n monitoring` |
| Alloy pods `CrashLoopBackOff` | Syntax error in `alloy-config.alloy` — Alloy validates its config at startup and refuses to run on a bad one | `kubectl logs -n monitoring daemonset/alloy` — the error names the exact line |
| Grafana's Loki datasource test fails ("Explore" shows a connection error) | `loki-gateway` Service unreachable, or the datasource ConfigMap wasn't picked up yet | `kubectl get configmap grafana-loki-datasource -n monitoring --show-labels`; give the sidecar a minute, or restart it: `kubectl rollout restart deployment/monitoring-grafana -n monitoring` |
| Queries return nothing for a namespace you know is logging | Label mismatch — confirm what Alloy is actually setting: `curl` Loki's `/loki/api/v1/labels` and `/loki/api/v1/label/namespace/values` (see `verify.sh` for the exact query pattern) | Adjust the query to match what's actually indexed, or fix `discovery.relabel` in `alloy-config.alloy` |

## Cleanup

```bash
bash modules/09-logging/scripts/destroy.sh
```

## Key Takeaways

- Loki trades full-text indexing for label indexing — cheap, fast queries scoped by label, with the actual search happening only inside an already-narrow result set. Keep labels low-cardinality.
- Reading logs through the Kubernetes API (Alloy's `loki.source.kubernetes`) avoids hostPath entirely — know this is possible before reaching for the heavier traditional pattern.
- Extending an existing Grafana/Prometheus install with a labeled ConfigMap, instead of reinstalling or duplicating it, is a repeatable pattern — Module 08 used it for scrape targets, this module used it for a datasource.

## Next Module

[Module 10 — Package Management](../10-package-management/) — Helm chart authoring and Kustomize overlays.
