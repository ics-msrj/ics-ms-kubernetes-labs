# Module 08 — Observability

**Duration**: ~90 minutes | **Level**: Intermediate | **Prerequisite**: [Module 07](../07-scalability-ha/)

---

## Overview

Install **kube-prometheus-stack** — Prometheus, Alertmanager, Grafana, kube-state-metrics, all wired together by the Prometheus Operator — and connect it to everything built so far: the node-exporter DaemonSet from Module 02, cert-manager's certificates from Module 04, and alert rules that reference Modules 05 and 07 by name.

## Learning Objectives

After this module you will:
- Know why `PodMonitor`/`ServiceMonitor` objects exist — the Prometheus Operator's way of letting you declare scrape targets as Kubernetes resources instead of editing a static `prometheus.yml`.
- Understand why installing a second node-exporter here would have been wrong, not just redundant, given what Module 02 already deployed.
- Be able to state a real reason Prometheus and Alertmanager stay `kubectl port-forward`-only while Grafana gets a public URL: authentication, not laziness.

## Prerequisites

- [Module 07](../07-scalability-ha/) verified.
- Module 04's Gateway and Module 03's Sealed Secrets controller both present (this module extends both).

## Architecture

```
┌─────────────────────────┐        ┌─────────────────────────┐
│  node-exporter (Mod. 02)  │        │   cert-manager (Mod. 04)  │
│  DaemonSet, hostNetwork   │        │   --set servicemonitor.   │
└────────────┬─────────────┘        │       enabled=true         │
             │ PodMonitor            └────────────┬─────────────┘
             │ (no Service needed)                  │ ServiceMonitor
             ▼                                       ▼
        ┌─────────────────────────────────────────────────┐
        │                    Prometheus                     │
        │  scrapes: node-exporter, cert-manager, kube-state- │
        │  metrics, kubelet, Cilium, cluster components      │
        └───────────────────────┬─────────────────────────┘
                                  │
                    ┌─────────────┼─────────────┐
                    ▼             ▼             ▼
              PrometheusRule  Alertmanager    Grafana
              (4 alerts tied  (port-forward   (exposed:
               to Mod. 04/    only — no        grafana.<APP_DOMAIN>,
               05/07)         built-in auth)   sealed admin password)
```

## Theory

**Why a second node-exporter would have been a bug, not just waste.** node-exporter binds `hostNetwork` port 9100 once per node by design — that's how it reads the *host's* CPU/memory/disk, not a container's. A second DaemonSet trying to bind the same host port on the same nodes doesn't run alongside the first; it fails to schedule, or fights over the port depending on scheduling order. `nodeExporter.enabled=false` on the Helm install and a `PodMonitor` pointed at Module 02's existing DaemonSet is the correct fix, not a workaround — and it's also the reason that DaemonSet earned a whole section of Module 02's README before this module ever needed it.

**PodMonitor vs. ServiceMonitor.** Both tell the Prometheus Operator "scrape this" — the difference is what they point at. A `ServiceMonitor` scrapes through a Service (load-balanced across whichever pods that Service selects); a `PodMonitor` scrapes pods directly by label, no Service required. node-exporter never got a Service in Module 02 (nothing needed to load-balance across it — each pod is the *only* source of metrics for its own node), which is exactly the situation `PodMonitor` exists for. cert-manager, by contrast, already has a Service, so its Helm chart creates a `ServiceMonitor` when asked.

**Why Grafana gets a public URL and Prometheus/Alertmanager don't.** This is a specific, checkable fact, not a vibe: `curl http://<prometheus>:9090/api/v1/query?query=up` returns data with no credentials, on every default install — Prometheus and Alertmanager have no built-in authentication layer at all. Grafana does (the sealed admin password `setup.sh` generates). Exposing the two without auth to the public internet means exposing every metric name, label, and value in the cluster to anyone with the URL — and for Alertmanager, the ability to silence real alerts. `kubectl port-forward` keeps them reachable when you need them without that exposure; Grafana, with its own login, is the one pane of glass this module puts a real domain on.

**Alerts that reference specific earlier modules, on purpose.** `HPAAtMaxReplicas` only means anything because Module 07 exists; `PersistentVolumeNearlyFull` only fires meaningfully because Module 05 gave `redis-cart` a real, expandable volume; `CertificateExpiringSoon` depends on Module 04's cert-manager install. Generic example alerts ("high CPU") would work in any tutorial and teach you nothing about *this* cluster — these are written to be useless anywhere else, which is what makes them worth reading closely.

## Lab

### Step 1 — Deploy

```bash
bash modules/08-observability/scripts/setup.sh
```

### Step 2 — Verify

```bash
bash modules/08-observability/scripts/verify.sh
```

### Step 3 — Log into Grafana

```bash
kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Open `https://grafana.<APP_DOMAIN>`, log in as `admin` with that password. Explore the pre-provisioned dashboards (Kubernetes cluster resources, node-exporter host metrics, kube-state-metrics workload health) — all populated with this cluster's real data, no configuration needed.

### Step 4 — Watch an alert actually fire

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-alertmanager 9093:9093
```

Open `http://localhost:9093`. Trigger `PodRestartingFrequently` for real:

```bash
kubectl run crash-test -n online-boutique --image=busybox:1.36 --restart=Always -- sh -c "exit 1"
```

Give it 15 minutes (the rule's evaluation window) — or lower `for`/the range in `manifests/prometheusrule-alerts.yaml` and re-apply it to see it faster while you're learning. Clean up after: `kubectl delete pod crash-test -n online-boutique`.

### Step 5 — Query Prometheus directly

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
```

Open `http://localhost:9090/targets` — confirm `online-boutique/node-exporter` and `cert-manager` both show `UP`.

## Failure Simulation

| Scenario | How to break it | Detect | Recover |
|---|---|---|---|
| Scrape target down | `kubectl scale deployment monitoring-kube-state-metrics -n monitoring --replicas=0` | `/targets` in the Prometheus UI shows it `DOWN`; Grafana panels relying on it go blank | `kubectl scale ... --replicas=1` |
| Alert rule silently stops firing | Delete the PrometheusRule: `kubectl delete prometheusrule online-boutique-alerts -n online-boutique` | `/rules` in the Prometheus UI no longer lists `online-boutique.rules` | Re-run `setup.sh` |
| Grafana locked out | Delete the sealed secret: `kubectl delete secret grafana-admin-credentials -n monitoring` | Grafana pod restarts into a fresh unclaimed admin state, or login fails depending on timing | Re-run `setup.sh` — it seals and applies a fresh password |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Prometheus/Alertmanager pods never appear | Prometheus Operator hasn't reconciled the `Prometheus`/`Alertmanager` custom resources yet | `kubectl get prometheus,alertmanager -n monitoring`; `kubectl logs -n monitoring deployment/monitoring-kube-prometheus-operator` |
| node-exporter target missing from Prometheus | `PodMonitor` label selector doesn't match, or missing the `release: monitoring` label Prometheus itself requires | `kubectl get podmonitor node-exporter -n online-boutique -o yaml`; confirm `release: monitoring` is present — the chart's Prometheus only watches `PodMonitor`s carrying its own release label by default |
| `CertificateExpiringSoon` never has data | cert-manager's ServiceMonitor didn't get created, or Prometheus hasn't discovered it yet | `kubectl get servicemonitor -n cert-manager`; `kubectl port-forward -n cert-manager <cert-manager pod> 9402:9402` then `curl localhost:9402/metrics \| grep certmanager_certificate_expiration` to confirm the metric name matches what the rule expects |
| Grafana shows "no data" on cluster dashboards | Datasource not yet synced, or Prometheus itself not up | `kubectl logs -n monitoring deployment/monitoring-grafana -c grafana`; confirm Prometheus pods are `Running` first |
| Grafana's "Kubernetes / API server" dashboard shows blank scheduler/controller-manager panels, `/targets` shows `kube-scheduler`/`kube-controller-manager` DOWN | kubeadm binds both to `127.0.0.1` by default (their metrics endpoints have no auth of their own, so this is a deliberate hardening default, not a bug) — unreachable from Prometheus running elsewhere in the pod network | `setup.sh` already patches this over SSH (`--bind-address=0.0.0.0` in `/etc/kubernetes/manifests/{kube-scheduler,kube-controller-manager}.yaml` — kubelet auto-restarts the static pods). If `CONTROL_PLANE_PUBLIC_IP` wasn't set when you ran it, do it manually: SSH to the control-plane, `sudo sed -i 's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/' /etc/kubernetes/manifests/kube-scheduler.yaml /etc/kubernetes/manifests/kube-controller-manager.yaml`. This does **not** expose them to the internet — that's governed separately by Module 01's security group/firewall rules, which were never opened for these ports |

## Cleanup

```bash
bash modules/08-observability/scripts/destroy.sh
```

## Key Takeaways

- `PodMonitor`/`ServiceMonitor` are how the Prometheus Operator turns "what to scrape" into a Kubernetes-native, GitOps-friendly resource — know when to reach for which.
- Not authenticating something is a decision with a blast radius, not a shortcut — Prometheus and Alertmanager's lack of built-in auth is the actual reason they stayed off the public Gateway this module built for Grafana.
- The most useful alerts in a real system name specific, known failure modes of *that* system — Module 05's PVC, Module 07's HPA ceiling, Module 04's certificate — not generic thresholds copied from a tutorial.

## Next Module

[Module 09 — Logging](../09-logging/) — centralize logs across all 11 Online Boutique services.
