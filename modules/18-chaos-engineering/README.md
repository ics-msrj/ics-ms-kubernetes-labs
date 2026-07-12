# Module 18 — Chaos Engineering & Incident Response

**Duration**: ~120 minutes | **Level**: Advanced | **Prerequisite**: [Module 17](../17-service-mesh/)

---

## Overview

Every module so far has ended with a **Failure Simulation** table — break something on purpose, detect it, recover it. This module is what all of those were building toward: real, tool-driven fault injection via Chaos Mesh, against the real `online-boutique` namespace, detected using nothing but the observability stack already built (Module 08's Prometheus/Grafana, Module 09's Loki, Module 17's Kiali) — then written up as an actual postmortem.

Six scenarios, each chosen because it exercises a specific control this repo already built rather than injecting failure for its own sake: a pod-kill against Module 07's PDB, network degradation against Module 17's retry policy, CPU stress against Module 07's VPA, a real node failure reusing Module 01's VMs, a combined incident, and a "blind" drill that forces you to actually diagnose instead of already knowing the answer.

## Learning Objectives

After this module you will:
- Be able to distinguish a genuine cascading failure from two unrelated faults that just happen to be visible at the same time — by checking the actual call graph (Kiali) instead of assuming.
- Know the practical difference between a chaos framework's in-cluster fault injection (Chaos Mesh: pod/network/stress faults, entirely inside Kubernetes) and a real node failure (nothing in-cluster can do this — it needs actual VM access, same as Module 01's SSH pattern).
- Be able to write a blameless postmortem that separates detection, diagnosis, and root cause into distinct sections — because conflating them is the most common reason postmortems end up useless six months later.

## Prerequisites

- [Module 07](../07-scalability-ha/) verified — this module's experiments specifically exercise the PDB, HPA, and VPA objects built there.
- [Module 08](../08-observability/) and [Module 09](../09-logging/) verified — detection in this module uses only what's already running, no new observability tooling.
- [Module 17](../17-service-mesh/) verified — Kiali is how you'll tell two simultaneous faults apart, and `currencyservice`'s resilience policy is what Scenario 2 actually exercises.

## Architecture

```
                        chaos-mesh namespace
        ┌───────────────────────────────────────┐
        │ chaos-controller-manager              │  reconciles PodChaos/
        │ chaos-daemon (1 per node, privileged, │  NetworkChaos/StressChaos/
        │   talks to containerd via             │  Workflow CRDs against
        │   /run/containerd/containerd.sock)    │  online-boutique
        │ chaos-dashboard (optional UI)         │
        └───────────────────────────────────────┘
                            │ injects faults into
                            ▼
              online-boutique namespace (real, same as Module 17)
┌────────────────────────┐  ┌────────────────────────┐  ┌────────────────────────┐
│ cartservice            │  │ currencyservice        │  │ productcatalogservice  │
│ (pod-kill target)      │  │ (network chaos         │  │ (CPU stress target,    │
│ Module 07's PDB        │  │ target, Module 17's    │  │ Module 07's VPA)       │
│ under test             │  │ retry policy under     │  │                        │
│                        │  │ test)                  │  │                        │
└────────────────────────┘  └────────────────────────┘  └────────────────────────┘
                            │ detected via
                            ▼
        Module 08 Prometheus/Grafana + Module 09 Loki + Module 17 Kiali
                     (nothing new — same stack every prior module used)

   Node-level failure (Scenario 4) bypasses Chaos Mesh entirely — real SSH
   to a real worker VM, same pattern as Module 01's own destroy.sh.
```

## Theory

**Why a chaos framework, when `kubectl delete`/`scale`/`patch` already broke plenty of things in this repo.** Every earlier Failure Simulation table used ad hoc `kubectl` commands, and that was the right call for those — a one-off, deliberate, hard-edged failure (delete this Secret, scale this Deployment to zero) is exactly what `kubectl` is for. What it can't easily do is *graded* or *time-bounded* failure: 15% packet loss instead of 100%, a stress load that ramps for exactly 5 minutes and then stops on its own, two unrelated faults running concurrently with independent lifetimes. Chaos Mesh's CRDs (`PodChaos`, `NetworkChaos`, `StressChaos`, `Workflow`) exist specifically for that middle ground between "nothing's wrong" and "it's completely deleted" — which is where most real production incidents actually live.

**What Chaos Mesh cannot do, and why Scenario 4 doesn't use it.** `chaos-daemon` runs *inside* the cluster, one per node, and does its work by reaching into the target pod's network/cgroup namespace from the host side — everything it touches is still a process the kubelet is managing. It has no mechanism to take the node's kubelet itself down; that's not a missing feature, it's the actual boundary of "in-cluster fault injection." Chaos Mesh does ship a separate agent (`chaosd` + `PhysicalMachineChaos`) for exactly this, but wiring it up means storing SSH credentials to your VMs as a Kubernetes Secret Chaos Mesh's controller can read — a real security tradeoff for a capability Module 01's own SSH access already provides for free. Scenario 4 reuses that instead.

**Why the combined-incident scenario is the actual point of this module, not a bonus.** A single injected fault teaches you to read one signal. Real incidents are rarely that clean — two things break near-simultaneously more often than textbook cascading-failure diagrams suggest, and the instinct to assume they're related is strong and frequently wrong. Scenario 5/6's `Workflow` runs `cartservice` pod-kills and `currencyservice` network chaos in parallel specifically so the diagnostic step — checking whether the two symptoms are even on the same call path, via Kiali — is the actual skill being tested, not an afterthought.

## Lab

### Step 1 — Install Chaos Mesh

```bash
bash modules/18-chaos-engineering/scripts/setup.sh
bash modules/18-chaos-engineering/scripts/verify.sh
```

This installs the chaos framework only. Nothing in `online-boutique` is touched yet.

### Step 2 — Scenario 1: pod-kill on cartservice

```bash
kubectl apply -f modules/18-chaos-engineering/manifests/podchaos-cartservice-kill.yaml
watch kubectl get pods -n online-boutique -l app=cartservice
```

Expect a brief restart. Checkout should keep working throughout — that's Module 07's `pdb-cartservice.yaml` and the Deployment's own self-healing doing their job.

### Step 3 — Scenario 2: network degradation on currencyservice

```bash
kubectl apply -f modules/18-chaos-engineering/manifests/networkchaos-currencyservice-netem.yaml
```

Browse the app, check prices convert. Then open Grafana → Online Boutique dashboard (Module 08) and watch `currencyservice` latency climb, and Kiali (Module 17) to watch the retry behavior on that edge live.

### Step 4 — Scenario 3: CPU stress on productcatalogservice

```bash
kubectl apply -f modules/18-chaos-engineering/manifests/stresschaos-productcatalogservice-cpu.yaml
kubectl describe vpa productcatalogservice -n online-boutique
```

Watch the VPA's `status.recommendation` shift as the stress runs — this is the first time in the repo that VPA has seen real elevated CPU usage to react to.

### Step 5 — Scenario 4: real node failure

```bash
bash modules/18-chaos-engineering/scripts/gameday-node-failure.sh break
kubectl get nodes -w
# ... observe, then:
bash modules/18-chaos-engineering/scripts/gameday-node-failure.sh recover
```

### Step 6 — Scenario 5/6: the blind combined-incident drill

This is the real exercise. Ideally with a study partner: one person applies the workflow without telling the other, and the other diagnoses using only Grafana/Loki/Kiali — no reading the manifest first.

```bash
kubectl apply -f modules/18-chaos-engineering/manifests/workflow-combined-incident.yaml
```

Work through: what's the first symptom you'd actually notice? Is it one failure or two? What in Kiali proves it either way? Once you've reached a real answer, compare against [`docs/postmortem-example-gameday.md`](../../docs/postmortem-example-gameday.md) — a fully worked postmortem for this exact drill — then write your own using [`docs/postmortem-template.md`](../../docs/postmortem-template.md).

## Alternative: LitmusChaos

This module implements Chaos Mesh, but [LitmusChaos](https://litmuschaos.io/) is the other major CNCF chaos engineering project and worth knowing. Where Chaos Mesh is a deep single-cluster fault-injection engine, LitmusChaos is built around a shared `ChaosHub` of reusable experiments and a multi-cluster `ChaosCenter` — its strongest features (AWS/GCP/Azure cloud-provider faults, GitOps-driven chaos pipelines across clusters) are out of scope for this repo's single kubeadm-VM track, which is why it isn't the implemented tool here. If you want to try it:

```bash
helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/
helm repo update
helm install chaos litmuschaos/litmus \
  --namespace litmus --create-namespace \
  --version 3.29.1 \
  --set portal.frontend.service.type=ClusterIP
kubectl port-forward -n litmus svc/chaos-litmus-frontend-service 9091:9091
```

Open `http://localhost:9091`, create an account, connect a "self-agent" (installs Litmus's execution plane into the current cluster), then browse the `ChaosHub` for a pod-delete experiment against `cartservice` — the same fault as this module's Scenario 1, run through Litmus's experiment/workflow model instead of a raw CRD. This isn't scripted by `setup.sh`/`verify.sh` — it's a manual exploration, not part of the automated lab.

## Failure Simulation

This module's own scenarios, plus every other module's, are indexed in [`docs/failure-simulation-matrix.md`](../../docs/failure-simulation-matrix.md) — the single reference this repo has been pointing at since Module 06.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `chaos-daemon` pods `CrashLoopBackOff` | Wrong `chaosDaemon.runtime`/`socketPath` for the actual CRI in use | Confirm containerd: `ssh <node> "sudo crictl info \| grep -i runtime"`, matches `setup.sh`'s `--set chaosDaemon.runtime=containerd` |
| A `PodChaos`/`NetworkChaos`/`StressChaos` object never seems to do anything | Label selector doesn't match any pod | `kubectl get pods -n online-boutique -l app=<target> --show-labels` |
| Dashboard login rejected | Wrong or expired token | Re-run `kubectl create token -n chaos-mesh <sa-name>` — tokens are short-lived by default |
| `gameday-node-failure.sh` fails to connect | `WORKER_PUBLIC_IPS`/`SSH_USER` not set in `lab.env`, or the SSH key isn't loaded in your agent | Same requirements as Module 01 — confirm `ssh ${SSH_USER}@<ip>` works manually first |
| Node never comes back `Ready` after `recover` | kubelet takes a few seconds to re-register; occasionally needs a second look | `ssh <node> "sudo systemctl status kubelet"`, check its logs if it's not `active` |

## Cleanup

```bash
bash modules/18-chaos-engineering/scripts/destroy.sh
```

If you ran Scenario 4, make sure `gameday-node-failure.sh recover` was called first — `destroy.sh` only removes Chaos Mesh itself, it has no knowledge of a stopped kubelet.

## Key Takeaways

- A dedicated chaos framework earns its place for *graded* and *time-bounded* failure (partial packet loss, a stress ramp that self-terminates, concurrent independent faults) — for hard-edged one-off breaks, plain `kubectl` (every earlier module's approach) is still the right tool.
- In-cluster chaos tooling has a real boundary: it can't take a node itself down. Knowing that boundary matters as much as knowing the tool's capabilities.
- Two simultaneous symptoms are not automatically one root cause — check the actual call graph before writing the postmortem's Root Cause section.

## Next Module

[Module 99 — Capstone](../99-capstone/) — combine every module built so far into one end-to-end scenario: deploy, take traffic, absorb an injected failure, detect, diagnose, recover, and write the postmortem, all without a script telling you what to do next.
