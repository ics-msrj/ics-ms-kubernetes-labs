# Module 16 — Supply Chain Security

**Duration**: ~60 minutes | **Level**: Advanced | **Prerequisite**: [Module 06](../06-security-policy/)

---

## Overview

Four questions about the images this cluster runs, each with a different answer: what's *in* them (SBOM), what's *wrong* with them (Trivy vulnerability scanning), who *made* them (cosign signing), and can the cluster *refuse* ones that fail either of the last two (Kyverno, extended). Nothing here touches Online Boutique's real images directly — signing requires a key we control, and Google's public images obviously aren't signed with it.

## Learning Objectives

After this module you will:
- Know the difference between an SBOM (what's inside an image — a manifest) and a vulnerability scan (which of those things are known-dangerous — a judgment, that changes over time as new CVEs are published against the *same* unchanged image).
- Understand what a cosign signature actually proves: that whoever holds the private key produced this exact image digest — not that the image is safe, not that it's free of vulnerabilities, just that its provenance is attributable.
- Be able to explain why the image-verification policy is scoped to one throwaway namespace, and what would need to be true cluster-wide before it could safely cover more.

## Prerequisites

- [Module 06](../06-security-policy/) verified — this module extends the same Kyverno install, and reuses its `require-resource-limits` policy interaction (see Troubleshooting).
- [Module 05](../05-storage/) verified — the self-hosted registry's storage is a Longhorn PVC.
- [Module 00](../00-prerequisites/)'s `yq` and `jq` — used to inject the generated public key safely and restore Kyverno's prior registry-client setting during cleanup.

## Architecture

```
┌─────────────────────┐      ┌─────────────────────────┐
│    Trivy Operator      │      │      supply-chain-demo       │  (new, isolated namespace)
│  scans every real       │      │                                │
│  running image           │      │  ┌───────────────────────┐  │
│  (online-boutique, etc.)  │      │  │      registry (self-       │  │
│  -> VulnerabilityReport   │      │  │      hosted, Longhorn-      │  │
│     CRDs                  │      │  │      backed)                 │  │
└─────────────────────┘      │  │                                │  │
                                │  │  test-image:v1 (signed) ✅   │  │
   trivy CLI (workstation,       │  │  unsigned-test:v1 (not) ❌   │  │
   one-off) ──▶ SBOM for           │  └───────────────────────┘  │
   frontend's real image             │             ▲                  │
                                       │             │ verifyImages     │
                                       │      Kyverno (Module 06,       │
                                       │      extended: registryClient. │
                                       │      allowInsecure=true)        │
                                       └─────────────────────────┘
```

## Theory

**SBOM vs. vulnerability scan — a manifest vs. a moving judgment.** `trivy image --format cyclonedx` produces a list of exactly what's inside an image — every package, every version, a fixed fact about that specific image digest that never changes. A vulnerability scan (Trivy Operator, running continuously) cross-references that same kind of inventory against a CVE database that updates daily — so an image that scanned clean last week can show new findings this week with *zero* changes to the image itself, because the *knowledge* about it changed. This is why Trivy Operator runs continuously instead of once: the SBOM is stable, the risk assessment isn't.

**What a signature does and doesn't claim.** `cosign sign --key cosign.key` produces a cryptographic statement: "the holder of this private key vouches for this exact image digest." It says nothing about code quality, nothing about vulnerabilities, nothing about intent — a maliciously-crafted image can be signed just as validly as a careful one, *by whoever holds the key*. What it's actually useful for is closing a different gap entirely: proving an image wasn't swapped or tampered with between whoever built it and whoever's about to run it. Vulnerability scanning and signing answer different questions; a real supply-chain policy needs both, which is why this module builds both instead of picking one.

**Why the verification policy only covers `supply-chain-demo`.** Every image in `online-boutique` comes from Google's public registry, signed (if at all) with a key this lab has no access to. A `verifyImages` policy matching those images against *our* public key would reject 100% of them — not a demonstration of security, just a broken application. The `imageReferences` pattern (`registry.supply-chain-demo.svc.cluster.local:5000/*`) scopes enforcement to exactly the one registry this lab controls end-to-end: the same discipline as Module 06's RBAC (`viewer`/`ci-deployer` scoped to what's actually needed) applied to image provenance instead of API verbs. Extending this cluster-wide for real would mean re-signing (or re-tagging with a re-signed copy from) every image actually in use — a real migration project, not a policy tweak.

**Why Kyverno needed `registryClient.allowInsecure=true`.** Verifying a signature means Kyverno's own controller has to reach out to the registry and fetch it — by default it assumes registries speak HTTPS, which our plain-HTTP self-hosted one (no TLS configured, deliberately, for lab simplicity) doesn't. This is a real gotcha worth knowing exists: a `verifyImages` policy that looks correctly configured can still fail purely because the registry connection itself was refused, not because the signature was invalid — `kubectl describe` the rejected pod's events to tell the two apart. `setup.sh` records Kyverno's prior setting and `destroy.sh` restores it, so the lab does not leave that global relaxation behind.

## Lab

### Step 1 — Deploy

```bash
bash modules/16-supply-chain-security/scripts/setup.sh
```

This installs `trivy`, `crane`, and `cosign` on your workstation if they're not already there (same pattern as Module 03's `kubeseal`).

### Step 2 — Verify

```bash
bash modules/16-supply-chain-security/scripts/verify.sh
```

This doesn't just check the policy object exists — it pushes a *second*, deliberately unsigned image into the same registry and confirms Kyverno rejects it, right next to the already-admitted signed one.

### Step 3 — Look at real findings

```bash
kubectl get vulnerabilityreports -n online-boutique
kubectl describe vulnerabilityreport -n online-boutique <one-from-the-list-above>
```

Expect real findings here — Online Boutique's images (like almost any real image) have some. That's not a problem this lab needs to fix; it's what the pipeline existing to catch them looks like in practice.

### Step 4 — Read the SBOM

```bash
cat modules/16-supply-chain-security/generated/frontend-sbom.json | less
```

### Step 5 — Try to sign with the wrong key

```bash
cosign generate-key-pair --output-key-prefix /tmp/wrong-key   # a second, unrelated keypair
kubectl port-forward -n supply-chain-demo svc/registry 5000:5000 &
COSIGN_PASSWORD="" cosign sign --key /tmp/wrong-key.key --allow-insecure-registry -y localhost:5000/test-image:v1
kubectl delete pod wrong-key-test -n supply-chain-demo --ignore-not-found
kubectl run wrong-key-test -n supply-chain-demo --image=registry.supply-chain-demo.svc.cluster.local:5000/test-image:v1 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"wrong-key-test","image":"registry.supply-chain-demo.svc.cluster.local:5000/test-image:v1","resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"50m","memory":"32Mi"}}}]}}'
```

Signed, but with a key Kyverno's policy doesn't trust — expect the same rejection as the fully-unsigned case. A signature existing isn't enough; it has to verify against the *specific* public key the policy names.

## Failure Simulation

| Scenario | How to break it | Detect | Recover |
|---|---|---|---|
| Wrong signing key (above) | Sign with an unrelated keypair | Pod creation rejected, same as unsigned | Sign with the correct key from `generated/cosign.key` |
| Registry unreachable | `kubectl scale deployment registry -n supply-chain-demo --replicas=0` | New pods referencing the registry's images fail admission (Kyverno can't fetch the signature to check it) — this looks identical to a rejected signature at first glance | `kubectl describe pod` shows a connection error, not a verification failure; `kubectl scale ... --replicas=1` |
| Scan coverage gap | `kubectl label namespace online-boutique trivy-operator.aquasecurity.github.io/skip=true` (if your Trivy Operator version honors a skip label — check its docs for the current mechanism) | That namespace stops appearing in fresh `VulnerabilityReport`s | Remove the label |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `signed-image-test` rejected even though it was actually signed correctly | Kyverno's `registryClient.allowInsecure` didn't take effect — check the `helm upgrade` in `setup.sh` actually completed | `kubectl get deployment kyverno-admission-controller -n kyverno -o yaml \| grep -A2 registryClient` (or check the controller's logs for a TLS/connection error, not a signature error) |
| `signed-image-test` also gets rejected by a *different* policy | Module 06's cluster-wide `require-resource-limits`/`disallow-latest-tag` policies apply here too — this namespace has no LimitRange to backfill missing resources the way `online-boutique` does | `kubectl describe pod signed-image-test -n supply-chain-demo` names the exact policy that blocked it; `setup.sh`'s pod already sets explicit resources for this reason |
| `crane copy ... --insecure` fails | The registry port-forward isn't up, or died between steps | Run `kubectl port-forward --address 127.0.0.1 -n supply-chain-demo svc/registry 5000:5000 &` manually, then retry |
| `cosign` CLI flags don't match this README | cosign v3 deprecated several verification-material/bundle-format flags in favor of new defaults (the `generate-key-pair`/`sign --key`/`verify --key` commands used here are unaffected — the changes are in Fulcio/Rekor keyless flows, which this module doesn't use) | `cosign sign --help` for the exact current flags on your installed version |
| No `VulnerabilityReport`s appear at all | Trivy Operator hasn't finished its first scan pass yet | `kubectl logs -n trivy-system deployment/trivy-operator`; give it a few minutes after install |

## Cleanup

```bash
bash modules/16-supply-chain-security/scripts/destroy.sh
```

## Key Takeaways

- SBOM = a fixed inventory of one image; vulnerability scanning = an assessment against a database that changes daily — the same image can need re-scanning without ever being rebuilt.
- A signature proves provenance (who), not safety (what) — pair it with scanning, don't substitute one for the other.
- Scoping an admission policy to exactly what it can correctly enforce (one self-controlled registry) beats a broken cluster-wide policy that "looks" more secure on paper.

## Next Module

[Module 17 — Service Mesh](../17-service-mesh/) — Istio, mTLS, and traffic management, on the app that's literally the canonical Istio demo.
