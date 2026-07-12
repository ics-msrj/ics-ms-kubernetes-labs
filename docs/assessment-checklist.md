# Assessment Checklist

A self-check, not a test — pass criteria for each level, phrased as things you should be able to actually *do* (or explain, concretely) rather than topics you've merely read about. Use it to find real gaps before Module 99, or as a rubric if you're running this curriculum as team training.

Each item should be checkable in one of two ways: **run it** (a command that either works or doesn't) or **explain it** (in your own words, no notes) — noted per item. If you can't do either, that's the gap to close, not a box to quietly check anyway.

## Beginner (Modules 00-03)

- [ ] **Run**: `kubeadm init`/`kubeadm join` a control-plane + at least one worker from scratch, no copy-pasted config you don't understand.
- [ ] **Explain**: why this repo's `kubeadm init` uses CLI flags instead of a `kubeadm.k8s.io` YAML config file.
- [ ] **Run**: deploy Online Boutique, get a real cart-persistence bug to reproduce (Module 02's `emptyDir` vs `StatefulSet` scenario), then fix it.
- [ ] **Explain**: the actual difference between a `Deployment` and a `StatefulSet`, using `redis-cart` as the concrete example, not the textbook definition.
- [ ] **Run**: rotate `redis-cart`'s password via a new SealedSecret without downtime.
- [ ] **Explain**: why a SealedSecret is safe to commit to Git and a plain Kubernetes `Secret` isn't (what's actually encrypted, and against what key).

## Intermediate (Modules 04-10)

- [ ] **Run**: get HTTPS working end-to-end through the Gateway API, either with a real domain or `TLS_ISSUER=selfsigned`.
- [ ] **Run**: apply a `NetworkPolicy` that blocks a specific pod-to-pod path, then prove it with a real probe pod — not just by reading the YAML and assuming it works.
- [ ] **Run**: take a Longhorn volume snapshot, delete the PVC, restore from the snapshot.
- [ ] **Explain**: the difference between `PodSecurity` admission (namespace-wide labels) and a Kyverno `ClusterPolicy` (arbitrary rule) — what each can and can't see.
- [ ] **Run**: trigger the HPA with real load (not just `kubectl scale` by hand) and watch it scale back down.
- [ ] **Run**: query a real PromQL expression against this cluster's Prometheus that answers a question you made up yourself, not one copied from a README.
- [ ] **Run**: find one specific log line in Loki that explains why a pod you deliberately broke actually failed.
- [ ] **Explain**: when you'd reach for a Helm chart vs. a Kustomize overlay for the same change — in terms of the actual question each answers, not "it depends."

## Advanced (Modules 11-18)

- [ ] **Run**: push a change to Git and watch ArgoCD sync it with zero `kubectl apply` on your part; deliberately cause drift and watch `selfHeal` revert it.
- [ ] **Explain**: why `ignoreDifferences` is needed for the `redis-cart-credentials` Secret in this repo's ArgoCD Application — the actual secrets-vs-GitOps tension it's solving.
- [ ] **Run**: promote a canary Rollout past a real `AnalysisTemplate` gate, and separately, abort one that's failing.
- [ ] **Run**: take a real `etcd` snapshot and explain (don't need to execute) the restore procedure and why it's riskier than the backup.
- [ ] **Explain**: what actually breaks (and what doesn't) when a node is imported into Rancher, using this repo's second-cluster setup as the concrete case.
- [ ] **Run**: show a real difference in ResourceQuota-enforced behavior between two "tenant" namespaces in this cluster.
- [ ] **Run**: get a signed image admitted and an unsigned or wrong-key image rejected by the same Kyverno `verifyImages` policy.
- [ ] **Run**: use Kiali to prove mTLS is active on a live call path, and explain what a `PeerAuthentication` set to `PERMISSIVE` instead of `STRICT` would actually allow.
- [ ] **Run**: diagnose which of two simultaneous Chaos Mesh faults caused which symptom, using only Kiali/Grafana/Loki — not by reading the manifest first.
- [ ] **Explain**: the actual boundary of in-cluster chaos tooling — what Chaos Mesh can fault-inject and what it structurally cannot (and why Module 18's node-failure drill doesn't use it).

## Capstone-level (Module 99)

- [ ] **Run**: pass `check-readiness.sh` with every module you care about reporting `READY`, without having to re-read that module's README to remember how.
- [ ] **Run**: detect an injected incident using only Grafana/Loki/Kiali/ArgoCD — no hints, no manifest-reading first.
- [ ] **Explain**: correctly separate two or more simultaneous root causes instead of writing up one cascading-failure story that happens to fit the symptoms.
- [ ] **Write**: a postmortem (`docs/postmortem-template.md`) with action items specific enough that each one could be opened as a ticket verbatim.

## Using this as team training

If you're running this curriculum with a group: have each learner self-check against this list before moving to the next tier, then spot-check a few "Run" items live rather than trusting every checkbox — the value of this list is catching *false* confidence, not enforcing a stage-gate.
