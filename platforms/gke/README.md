# GKE Platform Track

This is an additive managed-Kubernetes track for the repository — the GCP
counterpart to [`platforms/aks/`](../aks/). It preserves the existing
kubeadm curriculum and replaces only the responsibilities owned by GKE:
control plane, node runtime, CNI, CSI storage, node autoscaling, and
managed add-ons.

It must not run `modules/01-cluster-setup` against GKE. Never install a
second CNI, call `kubeadm`, modify the managed control plane, or SSH to
GKE nodes.

**Status: cluster live, Modules 02/03/04/05/06/07/08/09/10 all verified
live, plus Kubecost/NextOps Agent/Cloudflare Tunnel.** Terraform
has been applied against the real target project (`ics-nextops-production`)
— cluster `gke-nextops-production-sgp-001` is running. `check-prerequisites.sh`,
`connect.sh`, `preflight.sh`, and `enable-managed-addons.sh` (VPA +
Gateway API) all ran clean, zero fixes needed. `deploy-core-workloads.sh`
(Module 02) and `enable-storage.sh` (Module 05) both ran clean against
the live cluster — zero fixes needed. `enable-networking.sh` (Module 04)
needed two real fixes, both now in the repo (see its own header comment
and Terraform's `google_compute_subnetwork.proxy_only`): a missing
REGIONAL_MANAGED_PROXY subnet (a hard GCP prerequisite for
`gke-l7-regional-external-managed`, not documented anywhere obvious until
the Gateway's own error message named it), and GKE's LB rejecting a
TLS cert with an empty Subject — fixed via a `cert-manager.io/common-name`
annotation. Confirmed end-to-end: `curl` through the Gateway's real
external IP returns the actual Online Boutique frontend, `HTTP 200`.

Module 03 (secrets) has no dedicated adapter script, but its native
`setup.sh` (Sealed Secrets) needs **one fixup** on GKE — found by
actually running it, not by reading it (an earlier version of this note
claimed it needed nothing, which was wrong):
`redis-cart-statefulset-with-auth.yaml` hardcodes
`storageClassName: local-path`, an immutable StatefulSet field once
applied. Exact same issue, exact same fix, as the AKS track's own
documented Module 03 fixup:

```bash
bash modules/03-config-secrets/scripts/setup.sh
# setup.sh dies here — the fix below is expected, not a new bug:
sed "s/storageClassName: local-path/storageClassName: ${GKE_STORAGE_CLASS}/" \
  modules/03-config-secrets/manifests/redis-cart-statefulset-with-auth.yaml \
  | kubectl apply -n online-boutique -f -
# setup.sh never reached this manifest either, once it died above:
kubectl apply -n online-boutique -f modules/03-config-secrets/manifests/cartservice-with-redis-auth.yaml
```

Module 06 (security policy) runs fully natively — no adapter needed, `bash
modules/06-security-policy/scripts/setup.sh` followed by its own
`verify.sh`. Confirmed clean on GKE without any of the capacity trimming
the AKS track needed around Kyverno's `reports-controller` (this
project's CPU quota isn't the constraint AKS's was). Two native bugs
found and fixed in the process — neither GKE-specific, both affect the
AKS track too and any kubeadm cluster running Kyverno 3.x / scaling a
Deployment after Module 06:
- Both `setup.sh` and `verify.sh` polled `ClusterPolicy` readiness via
  `.status.ready`, a field Kyverno 3.x replaced with
  `.status.conditions[type=Ready]`. Both now check conditions first,
  falling back to the old field for older chart versions.
- The vendored upstream Online Boutique manifest sets 3 of the 4 fields
  `restricted` Pod Security Admission actually requires
  (`runAsNonRoot`, `allowPrivilegeEscalation: false`,
  `capabilities.drop: [ALL]`) but not the fourth (`seccompProfile`) —
  invisible right after Module 06 labels the namespace (PSA doesn't
  touch already-Running pods) and only surfaces the next time something
  tries to create a *new* pod from one of these templates, e.g. Module
  07's own `cartservice` scale-to-2 step (`FailedCreate: ... must set
  securityContext.seccompProfile.type`). Module 06's `setup.sh` now
  patches `seccompProfile: {type: RuntimeDefault}` onto every
  Deployment/StatefulSet in `online-boutique` right after applying the
  PSA label — see its own inline comment for the full story. Also fixed
  at the source for Module 03's `cartservice`/`redis-cart`
  redefinitions specifically (`cartservice-with-redis-auth.yaml`,
  `redis-cart-statefulset-with-auth.yaml`), and Module 06's own README
  corrected — it previously (incorrectly) claimed upstream already set
  everything `restricted` needs.

Module 07 (scaling) needs a small GKE adapter (`enable-scaling.sh`):
metrics-server and VPA are already covered (GKE ships metrics-server
pre-installed, confirmed live; VPA is the managed add-on
`enable-managed-addons.sh` already turned on — its controllers run as a
GKE-managed component, not visible as ordinary Deployments the way
AKS's `--enable-vpa` add-on is, but functionally proven live: VPA
actually computed a real recommendation for `productcatalogservice`).
Unlike AKS, GKE has **no managed KEDA** — `enable-scaling.sh` installs
it via the native module's own Helm chart, same as the kubeadm track
itself. Confirmed clean end-to-end (14/14 and 12/12 checks passing on
Module 06 and 07 respectively) once the `seccompProfile` bug above was
fixed.

Module 08 (observability) has a GKE adapter (`enable-observability.sh`)
— same shape as AKS's (kube-prometheus-stack with `nodeExporter.enabled=
true`, native kubeseal flow for the Grafana admin password, no GCP
Secret Manager adapter on this track yet), plus real fixes found live
and now baked into the script/manifests, none of them GKE-obvious ahead
of time:
- Every container across 5 separate places in the chart needed explicit
  Kyverno-compliant resources: the usual Deployment/DaemonSet
  containers, 2 admission-webhook `Job` hooks (`helm template` doesn't
  flag Jobs the way it flags Deployments if you're only checking
  Deployment/StatefulSet/DaemonSet), and — the one that actually cost
  the most debugging time — the Prometheus and Alertmanager
  StatefulSets themselves, which the operator synthesizes at runtime
  from CRDs and never appear in `helm template` output at all
  (`prometheus.prometheusSpec.resources` /
  `alertmanager.alertmanagerSpec.resources` /
  `prometheusOperator.prometheusConfigReloader.resources`).
- `cert-manager.io/common-name` (the AKS-track fix for GKE's
  empty-Subject-cert rejection) is Gateway-scoped — adding a second TLS
  listener (Grafana) to the same Gateway gives its Certificate the
  *same* wrong commonName as the first listener's domain. Functionally
  harmless (SAN is what actually matters for TLS validation, and SAN is
  correct per-listener) but cosmetically wrong; not re-architected since
  it doesn't block anything.
- GKE-specific, no AKS equivalent: GCP's default backend health check
  requests `/` and only accepts a plain `200` — Grafana 302-redirects
  `/` to `/login` (correct Grafana behavior), so the backend sat
  `UNHEALTHY` and every request 503'd until a `HealthCheckPolicy`
  (`manifests/healthcheckpolicy-grafana.yaml`, a GKE Gateway-specific
  CRD) pointed the check at `/api/health` instead.

Kubecost + NextOps Agent (ICS's internal FinOps cost-ingestion CronJob —
see the `nextops-agent-kubecost` memory entry, not part of this repo's
own curriculum) are also live on this cluster, mirroring the AKS setup:
Kubecost 2.8.6 (pinned — see Module 15's own README for why) reusing
this cluster's own Prometheus/Grafana, a dedicated
`kubecost-authproxy` (nginx basic auth, no built-in auth on Kubecost's
UI), and NextOps Agent — chart version **0.101.3**, which turned out to
already fix a real vendor bug (`KUBECOST_LABEL_KEYS` `NameError`) hit on
the AKS install's 0.101.2. Cloudflare Tunnel (`enable-cf-tunnel.sh`,
identical to the AKS track's) fronts Grafana and the frontend for
external access — installed clean on the first attempt, 2/2 connector
replicas registered.

Module 09 (logging) runs fully natively — same `LOKI_STORAGE_CLASS`
override as AKS (`LOKI_STORAGE_CLASS=${GKE_STORAGE_CLASS} bash
modules/09-logging/scripts/setup.sh`), and every Kyverno resource fix
already baked into the native script from the AKS work carried straight
over. Installed clean on the first attempt — no new bugs. One difference
worth noting, not a bug: `Alloy: 2/2 nodes` passes cleanly here, unlike
AKS's permanent `N-1/N` (system pool taint excludes it there) — this
cluster's system node doesn't carry a taint that blocks it.

Module 10 (package management) also runs natively (`REDIS_STORAGE_CLASS`
and `WORKLOAD_NODE_SELECTOR_KEY`/`_VALUE` env-var overrides, same
pattern as Module 09's `LOKI_STORAGE_CLASS`), but surfaced two real bugs
in `charts/online-boutique` itself — not platform-specific, would hit
native kubeadm and AKS too once someone actually deploys the chart with
more than one Pod scheduled under contention:
- `frontend` panics at startup (`environment variable
  "SHOPPING_ASSISTANT_SERVICE_ADDR" not set"`) — the chart's template
  never set it, even though the vendored upstream manifest (Module 02)
  does. No `shoppingassistantservice` needs to actually run; frontend
  just needs the env var to exist to not crash. Fixed in
  `charts/online-boutique/templates/frontend.yaml`.
- The chart had **no `nodeSelector` support at all** — on GKE this let
  `frontend`/`emailservice`/`recommendationservice` land on the system
  pool (96% CPU requests there) and CrashLoopBackOff on gRPC probe
  timeouts, with nothing in the apps' own logs hinting why (`kubectl
  describe pod` showed the real reason: `Liveness probe failed: timeout:
  ... within 1s`). Native kubeadm has no such pool split so never hits
  this; AKS's equivalent workloads have so far only ever been deployed
  through `deploy-core-workloads.sh`, which does set `nodeSelector`, so
  this gap in the *chart itself* was never exercised there either. Fixed
  by adding an empty-by-default `.Values.nodeSelector` to the chart
  (`values.yaml` + all 4 templates that create Pods) and overriding it
  from `setup.sh` on this platform. Kustomize's `helmCharts` inflation
  has no `--set` equivalent, so both the storage-class and node-selector
  overrides for the `dev`/`staging`/`prod` overlays are injected via a
  scratch copy of `kustomize/` with a generated `valuesInline` block —
  the committed `kustomize/` files are never touched.

`enable-backup` and the rest of the Module compatibility table are not
written yet.

## Prerequisites

```bash
bash platforms/gke/scripts/gke-track.sh check-prerequisites
```

Same idea as Module 00's own `verify.sh` and the AKS track's own
`check-prerequisites.sh`, with `gcloud` replacing `az`/`ssh` as the one
required tool this track needs that the native track doesn't.

## Cluster

No GKE cluster to point this at yet? [`terraform/`](terraform/)
provisions one (VPC, zonal cluster, system + autoscaling workload node
pools, Dataplane V2/Cilium, Workload Identity, Persistent Disk CSI,
Artifact Registry) — the GKE equivalent of the AKS track's own
`terraform/`. See [`terraform/README.md`](terraform/README.md), including
its cost note, before running `terraform apply`.

```bash
cd platforms/gke/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit project_id at minimum.
terraform init
terraform plan
terraform apply
terraform output -raw next_steps
```

## Foundation

```bash
cp platforms/gke/config/gke.env.example platforms/gke/config/gke.env
# Edit the project, cluster, workload pool, and domain settings
# (terraform's `next_steps` output has these values if you used it).

bash platforms/gke/scripts/gke-track.sh connect
bash platforms/gke/scripts/gke-track.sh preflight
bash platforms/gke/scripts/gke-track.sh enable-managed-addons

# Wait for the GKE update to finish, then refresh credentials and check again.
bash platforms/gke/scripts/gke-track.sh connect
bash platforms/gke/scripts/gke-track.sh preflight

bash platforms/gke/scripts/gke-track.sh deploy-core-workloads   # verified live
# Module 03 — see the fixup a few paragraphs above, setup.sh alone isn't enough
bash modules/03-config-secrets/scripts/setup.sh
bash platforms/gke/scripts/gke-track.sh enable-networking       # Module 04 — verified live
bash platforms/gke/scripts/gke-track.sh enable-storage          # Module 05 — verified live
bash modules/06-security-policy/scripts/setup.sh                # Module 06 — native, verified live
bash platforms/gke/scripts/gke-track.sh enable-scaling          # Module 07 — verified live
bash platforms/gke/scripts/gke-track.sh enable-observability    # Module 08 — verified live

# Optional — ICS-internal, not part of this repo's own curriculum:
bash platforms/gke/scripts/gke-track.sh enable-cf-tunnel        # needs CF_TUNNEL_TOKEN in gke.env
# Kubecost + NextOps Agent — see the nextops-agent-kubecost memory entry
# for the exact helm commands (version pins matter, see Module 15's README)
```

## Known differences from the AKS track (verified, not assumed)

- **No mandatory-tag policy.** This project has zero Org Policies
  enforcing labels (checked: `gcloud resource-manager org-policies list`
  returned none) — the entire class of "untagged resource creation
  denied outright" bugs the AKS track hit repeatedly (VMSS, disks,
  snapshots, AKS Backup's own internal snapshots) has no GCP equivalent
  here. `labels` in Terraform are for cost hygiene only, not a hard
  requirement.
- **Generous CPU quota.** `CPUS` quota in `asia-southeast1` is 5000 (vs.
  the 10-vCPU regional ceiling the AKS track's subscription had), so the
  workload node pool is sized larger from the start (e2-standard-4 vs.
  AKS's Standard_D2s_v3) specifically to avoid repeating the AKS track's
  whack-a-mole capacity trims (loadgenerator, frontend replicas, etc.)
  every time a new module's workload got added.
- **No managed KEDA.** AKS has a first-party managed KEDA add-on
  (`--enable-keda`); GKE does not — `enable-managed-addons.sh` only
  enables VPA and the Gateway API controller. Module 07's native KEDA
  install (self-managed via Helm) will still be needed here.
- **GKE Gateway API is a managed add-on** (`--gateway-api=standard`,
  GKE's own Gateway controller) — the GCP parallel to AKS's
  application-routing add-on, enabled the same way (a
  `gcloud container clusters update` call, not something Terraform
  manages, matching the AKS track's `lifecycle.ignore_changes` reasoning
  for the same kind of out-of-Terraform add-on state).
