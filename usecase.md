
# PRD / Blueprint: EKS Autoscaling Simulation & Job Orchestration

**Status:** Draft v2 (English, expanded) — ready for technical review before execution
**Date:** July 17, 2026
**Owner:** MSRJ — Lead Senior Developer, DevSecOps/Platform Engineering

---

## Table of Contents

1. Executive Summary & Objectives
2. Goals / Non-Goals
3. Track Comparison — Auto Mode vs Non-Auto Mode
4. Track A — Autoscaling Simulation
5. Track B — Job Orchestration & Alerting
6. Environment, Cost Guardrails & Teardown
7. Security Guardrails
8. Assumptions Log
9. Implementation Roadmap
10. Open Items for Next Iteration
11. Appendix — Glossary & Reference Snippets

---

## 1. Executive Summary & Objectives

This is a two-workstream lab engagement on Amazon EKS:

- **Track A — Autoscaling Simulation:** compare EKS Auto Mode against non-Auto Mode (self-managed Karpenter is explicitly excluded from Track A2 due to the warm-pool constraint below) under gradual-spike and sudden-spike load conditions. Simulation starts from a 1-node, minimum-spec baseline, applies vertical scaling first, then horizontal scaling, with a hard target of ≤5 minutes cold-to-ready for warmed capacity.
- **Track B — Job Orchestration & Alerting:** a midnight-scheduled job chain that runs multiple microservices sequentially (plus other jobs that run in parallel or on independent schedules), with webhook alerts fired at every process step — not just at the job level — so failures are isolated to the exact step that failed.

**Guiding principle:** minimize cost without compromising performance or reliability. This is explicitly not a one-directional optimization — every cost-saving decision in this document carries an explicit reliability guardrail, because aggressive scale-down without a buffer is itself a reliability risk.

---

## 2. Goals / Non-Goals

**Goals**

- Produce empirical, measurable data on scaling behavior (not just theoretical comparison) for both compute tracks
- Validate that a 5-minute cold-to-ready SLA is achievable and under what mechanism (warm pool type, sizing)
- Design a job orchestration pattern with per-step observability sufficient for 3am incident triage without human guesswork
- Produce a reusable set of guardrails (cost, security, reliability) that can graduate from lab to a production recommendation

**Non-Goals**

- This is not a final production architecture decision. Track A1 vs A2 is a controlled comparison; the production recommendation is a follow-on deliverable after this lab concludes.
- Not covering multi-region / DR scenarios in this phase.
- Not covering CI/CD pipeline design for the microservices themselves — assumes deployable images already exist.

---

## 3. Track Comparison — Auto Mode vs Non-Auto Mode


| Aspect                         | Track A1: EKS Auto Mode                                                                                                                                               | Track A2: Non-Auto Mode                                                                                                 |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Node provisioning engine       | Karpenter, managed by AWS                                                                                                                                             | Cluster Autoscaler + Managed Node Group                                                                                 |
| Why this pairing               | Karpenter (managed or self-hosted) talks directly to the EC2 Fleet API — it does not use an Auto Scaling Group, so ASG-based EC2 Warm Pool is not compatible with it | EC2 Warm Pool only works with ASG-backed node groups, which rules out Karpenter for this track                          |
| Warm pool mechanism            | Static capacity NodePool (`replicas` field set on the NodePool spec)                                                                                                  | EC2 Warm Pool via ASG lifecycle hook                                                                                    |
| Node OS / host access          | Bottlerocket only, no SSH/SSM host access, no custom AMI                                                                                                              | Any supported AMI, full host access available                                                                           |
| Kubernetes version requirement | 1.29+                                                                                                                                                                 | No specific constraint                                                                                                  |
| Cost model                     | Billed by duration × instance type of EC2 instances launched/managed by Auto Mode; no separate node-group management cost                                            | EC2 instance cost + partial cost for warm pool instances (Stopped or Running state, depending on lifecycle hook config) |
| Operational overhead           | Low — AWS manages node lifecycle, AMI patching, most add-ons (VPC CNI, EBS CSI, ALB Controller are built in)                                                         | Higher — you own NodePool/NodeClass or Launch Template config, AMI updates, and CA tuning                              |
| Consolidation / bin-packing    | Karpenter-native consolidation (`consolidationPolicy`)                                                                                                                | Cluster Autoscaler scale-down based on utilization thresholds                                                           |
| Purpose in this lab            | Baseline for "managed, reduced ops overhead"                                                                                                                          | Baseline for "full control, granular tuning"                                                                            |

The comparison objective is **lab-only**: results from both tracks feed into a follow-on production recommendation, not a same-day production decision.

---

## 4. Track A — Autoscaling Simulation

### 4.1 Baseline Sizing

- Start state: 1 node, right-sized to the **P50 baseline traffic** of the target workload — not an arbitrary small instance type. Sizing methodology:
  1. Run workload under normal (non-spike) load for a representative window
  2. Capture p50 CPU/memory utilization
  3. Choose the smallest instance type that fits p50 with ~20% headroom
- Rationale for starting at minimum: provisioning for 24/7 peak capacity is a FinOps anti-pattern — it hides the actual gap between demand and capacity, which is exactly the gap this simulation needs to measure. Starting small also makes the expand→consolidate cycle (the thing that proves cost savings) actually observable.

### 4.2 Scaling Phases

**Phase 1 — Vertical (VPA)**

- Deploy `VerticalPodAutoscaler` in `Auto` or `Initial` mode first (observe recommendations before enforcing) to validate resource requests are realistic before horizontal scaling is layered on top.
- Prefer in-place resize (supported from Kubernetes 1.27+, via `resizePolicy` and the `InPlacePodVerticalScaling` feature) where the workload's container runtime and readiness probes tolerate it; otherwise fall back to `Recreate` update mode.

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: workload-vpa
spec:
  targetRef:
    apiVersion: "apps/v1"
    kind: Deployment
    name: sample-workload
  updatePolicy:
    updateMode: "Auto"   # start with "Off" (recommend-only), then "Initial", then "Auto"
  resourcePolicy:
    containerPolicies:
      - containerName: '*'
        minAllowed:
          cpu: 100m
          memory: 128Mi
        maxAllowed:
          cpu: 2
          memory: 2Gi
```

> **Note:** running VPA and HPA on the *same metric* (CPU) simultaneously on the same workload is an anti-pattern (they fight each other). Once Phase 2 (HPA) is enabled, VPA should either be scoped to `Off`/recommendation-only, or restricted to resources not used by the HPA trigger (e.g., VPA on memory, HPA on custom RPS metric).

**Phase 2 — Horizontal (HPA + Karpenter / Cluster Autoscaler)**

- Track A1: HPA (pod-level) + Karpenter dynamic NodePool (node-level)
- Track A2: HPA (pod-level) + Cluster Autoscaler + Managed Node Group (node-level)

### 4.3 Metric Source & Trigger Design

- **Trigger engine: KEDA.** A single `ScaledObject` can declare multiple triggers — one `prometheus` type and one `aws-cloudwatch` type — against the same `scaleTargetRef`.
- **Relationship between the two sources: redundant/failover.** Both monitor the same underlying signal; HPA's native multi-metric behavior takes the **max** of all trigger-derived replica counts for scale-up decisions, and requires **all** triggers to agree before scaling down. This means:
  - Scale-up: whichever source reports first/highest wins — Prometheus will usually win in practice (see latency note below), CloudWatch acts as a redundant safety net.
  - Scale-down: conservative by default — both sources must agree capacity can shrink. This is deliberate and reinforces the reliability guardrail from the cost-saving principle in §1.
- **Grafana's role is visualization only** — it queries Prometheus and/or CloudWatch as datasources for dashboards. It is **not** in the trigger path and should not be confused with an active scaling signal source.

**Latency asymmetry to document explicitly:**


| Source                        | Typical latency                            | Practical role                                                    |
| ------------------------------- | -------------------------------------------- | ------------------------------------------------------------------- |
| Prometheus (scrape-based)     | ~15–30s                                   | Primary/fast-path trigger                                         |
| CloudWatch (standard metrics) | ~1–5 min (1 min with detailed monitoring) | Redundant safety net, not a true race partner for scale-up timing |

**Threshold normalization:** each source's formula is different (e.g., `sum(rate(http_requests_total[1m]))` in PromQL vs. `RequestCountPerTarget` in CloudWatch) — thresholds must be tuned independently per source so that "most aggressive wins" is a fair comparison, not a permanent bias toward one source.

Example dual-trigger `ScaledObject`:

```yaml
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: keda-aws-auth
  namespace: workload-ns
spec:
  podIdentity:
    provider: aws-eks   # or aws-iam via IRSA, depending on cluster identity setup
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: workload-scaledobject
  namespace: workload-ns
spec:
  scaleTargetRef:
    name: sample-workload
  minReplicaCount: 1
  maxReplicaCount: 20
  pollingInterval: 15
  cooldownPeriod: 120
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://prometheus-server.monitoring.svc.cluster.local:9090
        metricName: http_requests_rate
        query: sum(rate(http_requests_total{deployment="sample-workload"}[1m]))
        threshold: "100"          # requests/sec per replica target — tune from baseline
    - type: aws-cloudwatch
      authenticationRef:
        name: keda-aws-auth
      metadata:
        namespace: AWS/ApplicationELB
        dimensionName: LoadBalancer
        dimensionValue: app/<alb-name>/<alb-id>
        metricName: RequestCountPerTarget
        metricStat: "Sum"
        metricStatPeriod: "60"
        metricCollectionTime: "120"
        targetMetricValue: "100"  # normalize against the same effective target as Prometheus
        minMetricValue: "0"
        awsRegion: "ap-southeast-1"
        identityOwner: operator
```

**Resilience test case (must be validated, not assumed):**
Simulate CloudWatch API throttling/unavailability (e.g., via IAM deny on `cloudwatch:GetMetricData` for a controlled window) and confirm the `ScaledObject` continues to scale off the Prometheus trigger alone rather than stalling entirely. Document actual behavior — KEDA trigger failure handling can vary by scaler and version.

### 4.4 Warm Pool Design


| Track              | Mechanism                                                                | Notes                                                                                                                                                                                                                                                                                                                                                                                     |
| -------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A1 (Auto Mode)     | Static capacity NodePool — set the`replicas` field on the NodePool spec | Static-capacity NodePools are excluded from consolidation. Once`replicas` is set it cannot be removed from that NodePool — keep it as a separate NodePool from the dynamic one. Set `limits.nodes` above `replicas` to allow temporary scaling during AMI drift/expiration. For predictable AZ distribution, use one static NodePool per AZ rather than spanning zones in a single pool. |
| A2 (non-Auto Mode) | EC2 Warm Pool via ASG lifecycle hook (`aws autoscaling put-warm-pool`)   | Choose`Warmed:Stopped` (cheaper, slower resume — instance boot required) vs `Warmed:Running` (near-zero resume time, full compute cost) based on the 5-minute target; this trade-off needs an actual benchmark, not an assumption.                                                                                                                                                       |

Illustrative static NodePool skeleton (Auto Mode / Karpenter API):

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: warm-static-pool
spec:
  replicas: 2   # fixed warm capacity, excluded from consolidation
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["m5.large"]
      nodeClassRef:
        group: eks.amazonaws.com
        kind: NodeClass
        name: default
  limits:
    nodes: 4   # headroom above replicas for AMI drift/expiration handling
```

Illustrative EC2 Warm Pool CLI (Track A2):

```bash
aws autoscaling put-warm-pool \
  --auto-scaling-group-name eks-workload-nodegroup-asg \
  --pool-state Stopped \
  --min-size 2 \
  --max-group-prepared-capacity 4
```

**Target SLA:** ≤5 minutes from trigger to workload ready-to-serve — this includes node Ready, pod scheduling, and readiness-probe pass, not just node launch.

### 4.5 Test Scenarios

- **Gradual spike:** staged ramp-up in simulated users over minutes (e.g., a Locust `LoadTestShape` custom class stepping load up incrementally). Expectation: dynamic HPA + Karpenter/Cluster Autoscaler alone is sufficient — no warm pool dependency.
- **Sudden spike:** near-instant jump to high load. Expectation: from zero warmed capacity, node launch (~45–60s for Karpenter) + pod start + load balancer target registration risks breaching the 5-minute SLA — this is the explicit justification for warm pool as an insurance policy, not permanent standing capacity.

**Load generation: Locust**, run locally (spec: 8 cores / 40GB RAM).

- Estimated ceiling: with `--processes -1` (multi-process, bypassing Python GIL per process), roughly 1,000–3,000 RPS per worker process → **~8,000–20,000 RPS** aggregate, comfortably above lab-scale requirements. Memory is not a constraint at this scale.
- Pre-test tuning checklist:
  - `ulimit -n 65536` — file descriptor limit is a more common bottleneck than CPU at high connection counts
  - Expand `net.ipv4.ip_local_port_range` — ephemeral port exhaustion ceiling
  - Benchmark WSL2's NAT virtual network adapter overhead before the formal run — historically higher overhead than bare metal for high-connection-count workloads
  - Custom `LoadTestShape` class to explicitly encode gradual vs. sudden profiles
  - `locust-exporter` to expose `/metrics` for Prometheus scraping; a custom `request` event hook (`request` → `boto3.put_metric_data`) to push into CloudWatch — **this is an implementation action item**, not built-in like k6's native exporters
  - Run Locust master/worker in a separate namespace from the target workload so load-gen resource consumption doesn't get counted into the metrics that drive HPA triggers
- In-region deployment (EC2/pod) for load generation is **optional/fallback**, not a requirement — laptop is assessed as sufficient for this lab's scope given the spec above.

Example `LoadTestShape` skeleton (illustrative):

```python
from locust import LoadTestShape

class GradualThenSuddenShape(LoadTestShape):
    stages = [
        {"duration": 300, "users": 100, "spawn_rate": 5},    # gradual ramp
        {"duration": 600, "users": 500, "spawn_rate": 10},
        {"duration": 660, "users": 2000, "spawn_rate": 2000}, # sudden spike: near-instant
        {"duration": 900, "users": 2000, "spawn_rate": 10},   # sustain
        {"duration": 1200, "users": 100, "spawn_rate": 10},   # cool down / observe scale-down
    ]

    def tick(self):
        run_time = self.get_run_time()
        for stage in self.stages:
            if run_time < stage["duration"]:
                return (stage["users"], stage["spawn_rate"])
        return None
```

### 4.6 Success Metrics & Measurement Method


| Metric                           | Definition                                                                      | Measurement method                                                                                       |
| ---------------------------------- | --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Time-to-first-new-pod            | Time from threshold breach to a new pod entering`Pending`                       | Diff between Prometheus alert firing timestamp and pod creation timestamp (K8s event stream)             |
| Time-to-node-ready (TTNR)        | Time from pod`Pending` (unschedulable) to new node `Ready`                      | Diff between pod scheduling failure event and node`Ready` condition timestamp                            |
| End-to-end time-to-serve         | Time from threshold breach to pod passing readiness probe and receiving traffic | TTNR + pod start + readiness probe interval — this is what's actually compared against the 5-minute SLA |
| Error rate during scaling window | % failed requests during the transition period                                  | Locust request stats, filtered to the scaling window timestamps                                          |
| P95 latency during spike         | 95th percentile latency while load test is active                               | Locust response time percentiles, or Prometheus histogram                                                |
| Cost delta                       | Compute cost difference before vs. after simulation, per track                  | AWS Cost Explorer tagged by track/simulation run ID                                                      |

### 4.7 Cost-Performance-Reliability Policy

*(Structure defined now; concrete numbers to be filled after the first baseline benchmark run — see §10 Open Items.)*


| Parameter                        | Track A1 (Auto Mode)                                                                                                  | Track A2 (Non-Auto Mode)                                |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| HPA min/max replicas             | TBD after baseline                                                                                                    | TBD after baseline                                      |
| Node min/max (dynamic pool)      | TBD                                                                                                                   | TBD                                                     |
| Warm pool size                   | Formula: based on historical P95 spike delta vs. baseline capacity                                                    | Same formula, applied to warm pool min-size             |
| Idle-timeout /`consolidateAfter` | TBD — must avoid thrashing (scale-down immediately followed by scale-up costs more in re-provisioning than it saves) | Cluster Autoscaler`scale-down-unneeded-time` equivalent |
| Disruption budget                | `PodDisruptionBudget` + Karpenter disruption budget schedule (freeze during business hours if applicable)             | `PodDisruptionBudget` only                              |

### 4.8 Resilience Test Case

See §4.3 — CloudWatch throttled/unavailable scenario. Additional resilience case worth including: simulate Karpenter/Cluster Autoscaler controller restart mid-scale-out and confirm in-flight node provisioning is not orphaned or duplicated.

---

## 5. Track B — Job Orchestration & Alerting

### 5.1 Job Controller Architecture

- **Engine: Kubernetes CronJob + custom controller.**
- The custom controller generates a `JobRun` record per execution, tracking state (`pending` / `running` / `success` / `failed`) at both the job level and the per-step level.
- Each microservice step executes as its own Kubernetes `Job` (not directly as separate CronJobs) — the controller owns the sequencing logic and reads each step's exit status before deciding the next action.

Illustrative `JobRun` state object (as a Custom Resource, or minimally a ConfigMap/annotation-based record if a full CRD is out of scope for this phase):

```yaml
apiVersion: batch.internal/v1alpha1
kind: JobRun
metadata:
  name: nightly-etl-2026-07-18
spec:
  chain: nightly-etl
  triggeredAt: "2026-07-18T00:00:00+07:00"
status:
  overallState: running
  steps:
    - name: extract-orders
      state: success
      attempts: 1
      startedAt: "2026-07-18T00:00:05+07:00"
      finishedAt: "2026-07-18T00:01:40+07:00"
    - name: transform-orders
      state: running
      attempts: 1
      startedAt: "2026-07-18T00:01:41+07:00"
    - name: load-warehouse
      state: pending
      attempts: 0
```

### 5.2 Sequencing & Parallelism

- **Sequential jobs:** single controller state machine, steps execute strictly in order, each gated on the previous step's success.
- **Parallel jobs:** modeled as independent CronJob entries with independent schedules — not merged into a single state machine.
- **Jobs on different schedules:** each is its own CronJob entry; no shared state between unrelated job chains.

### 5.3 Retry & Idempotency Policy

- **Retry:** 3 attempts per step, exponential backoff (e.g., 30s → 2min → 8min between attempts — tune per step's expected recovery time).
- **After max retries exhausted:** **stop the chain** (no skip-and-continue) — downstream steps in a sequential microservice chain typically depend on data/state produced by the prior step, so continuing past a failed step risks processing on incomplete or stale data.
- **Idempotency is mandatory** on every step — each step must be safe to re-run without double-processing (same pattern already applied to the DataSync/Firestore idempotency work referenced in prior engagements: use a deterministic operation key or upsert semantics rather than blind insert/append).

Illustrative backoff logic (pseudo-code, controller-side):

```python
MAX_ATTEMPTS = 3
BACKOFF_SECONDS = [30, 120, 480]

def run_step(step, attempt=1):
    result = execute_k8s_job(step)
    if result.success:
        mark_step(step, "success")
        return True
    if attempt >= MAX_ATTEMPTS:
        mark_step(step, "failed")
        stop_chain(reason=f"{step.name} failed after {MAX_ATTEMPTS} attempts")
        return False
    sleep(BACKOFF_SECONDS[attempt - 1])
    return run_step(step, attempt + 1)
```

### 5.4 Alerting Design

- **Every event is alerted immediately — both failure and success, at every step**, per the original per-process visibility requirement (so the exact failing step is identifiable without re-tracing logs).
- **Implementation recommendation** (a delivery pattern, not a change to the alert-volume decision already made): post a root message per job-run, then have every step reply in-thread to that root message (e.g., Slack thread). This preserves full per-process granularity while preventing the main channel from flooding when multiple jobs run in parallel overnight.
- Webhook target: Slack (assumption — see Assumptions Log).

Illustrative webhook payload skeleton (per step):

```json
{
  "job_run_id": "nightly-etl-2026-07-18",
  "step": "transform-orders",
  "status": "failed",
  "attempt": 3,
  "started_at": "2026-07-18T00:01:41+07:00",
  "finished_at": "2026-07-18T00:03:12+07:00",
  "error_summary": "connection timeout to staging DB",
  "thread_ts": "1752796800.000100"
}
```

### 5.5 Failure Isolation

Because alerts are emitted per step rather than only at the job level, root cause is immediately identifiable from which step failed, without needing to re-trace logs from the start of the chain.

---

## 6. Environment, Cost Guardrails & Teardown

- **Environment:** separate sandbox/dev AWS account, isolated from production.
- **Cost cap:** AWS Budgets alarm with an explicit threshold (amount TBD — see Open Items).
- **Teardown is mandatory** after the simulation window closes — this is not optional cleanup, it's a cost guardrail:
  - EC2 Warm Pool (Track A2) continues to incur cost (partial or full, depending on `Stopped`/`Running` state) until explicitly deleted (`aws autoscaling delete-warm-pool`).
  - Static NodePool (Track A1) bills full compute cost for as long as `replicas` remains active.
- Teardown should be scripted/automated (not manual) to eliminate the risk of leaving warm capacity running unattended.

---

## 7. Security Guardrails

- **IRSA / Pod Identity** per microservice — least privilege, no shared IAM role across services.
- **PodDisruptionBudget (PDB)** on all critical workloads — protects against disruption during scale-down/consolidation events.
- **NetworkPolicy**: default-deny, with explicit allow rules between job steps and between microservices.

Illustrative default-deny NetworkPolicy skeleton:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: workload-ns
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

---

## 8. Assumptions Log


| # | Assumption                                                                                                     | Needs confirmation?                                                              |
| --- | ---------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| 1 | Webhook alert target = Slack                                                                                   | Yes, if a different channel/tool is intended                                     |
| 2 | Sample workload = generic HTTP API (autoscaling test) + dummy 3-step ETL (job orchestration test)              | Yes, if a real workload should be substituted                                    |
| 3 | Local-laptop load generation (8 cores / 40GB) is sufficient for the full scope, including sudden-spike testing | Validated based on stated spec — revisit if results show client-side bottleneck |
| 4 | Cost-Performance-Reliability policy (§4.7) is a structural placeholder                                        | Needs concrete numbers after the first baseline benchmark run                    |
| 5 | Sandbox/dev AWS account already exists or will be provisioned separately                                       | Needs confirmation of account ID / access                                        |

---

## 9. Implementation Roadmap

1. **Foundation setup** — sandbox account, baseline clusters for Track A1 and A2 (kept separate), IAM/IRSA, AWS Budgets alarm
2. **Observability layer** — Prometheus + CloudWatch Container Insights add-on + Grafana dashboards, KEDA installation
3. **Track A — Vertical scaling** — deploy VPA in recommend-only mode, validate right-sizing before enforcing
4. **Track A — Horizontal scaling** — HPA + KEDA `ScaledObject` (dual trigger), Karpenter (A1) / Cluster Autoscaler config (A2)
5. **Track A — Warm pool** — static NodePool (A1) vs. EC2 Warm Pool (A2), benchmark actual cold-to-ready time
6. **Track A — Load test execution** — Locust setup with OS-level tuning, run gradual then sudden spike scenarios, capture success metrics
7. **Track B — Job controller** — build custom controller, `JobRun` state tracking, retry/idempotency logic
8. **Track B — Alerting** — webhook integration, thread-per-job-run pattern
9. **Resilience testing** — CloudWatch throttled scenario, controller-restart-mid-scale scenario
10. **Review & finalize** — populate §4.7 with actual measured numbers, draft production recommendation
11. **Teardown** — scripted decommission of all sandbox resources, including warm pools

---

## 10. Open Items for Next Iteration

- Concrete values for §4.7 (min/max nodes, idle-timeout, warm pool sizing formula) — pending first baseline benchmark
- Confirm real workload (if any) to replace the dummy HTTP API / ETL chain
- AWS Budgets alarm threshold amount
- Slack channel/thread setup details for the alerting pattern
- Decide whether `JobRun` state is a full CRD (requires a CRD + controller build) or a lighter-weight ConfigMap/annotation-based record for this lab phase

---

## 11. Appendix — Glossary & Reference Snippets


| Term          | Meaning                                                                                      |
| --------------- | ---------------------------------------------------------------------------------------------- |
| VPA           | Vertical Pod Autoscaler — adjusts pod CPU/memory requests                                   |
| HPA           | Horizontal Pod Autoscaler — adjusts pod replica count                                       |
| KEDA          | Kubernetes Event-Driven Autoscaling — extends HPA with external trigger sources             |
| Karpenter     | Node autoscaler that provisions EC2 capacity directly via the EC2 Fleet API                  |
| NodePool      | Karpenter CRD defining node provisioning constraints (instance types, capacity type, limits) |
| Consolidation | Karpenter's bin-packing/cost-optimization mechanism that removes underutilized nodes         |
| TTNR          | Time-to-node-ready — metric defined in §4.6                                                |
| IRSA          | IAM Roles for Service Accounts — AWS IAM identity binding for Kubernetes pods               |
