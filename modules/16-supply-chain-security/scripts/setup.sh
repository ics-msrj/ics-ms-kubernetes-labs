#!/bin/bash
# =============================================================================
# Module 16 — Supply Chain Security — setup.sh
#
# 1. Installs Trivy Operator (continuous vulnerability scanning, cluster-wide)
# 2. Generates an SBOM for one real running image (trivy CLI, one-off)
# 3. Deploys a self-hosted registry, pushes a small test image into it
#    (crane — no Docker needed anywhere in this repo)
# 4. Generates a cosign keypair, signs that image
# 5. Extends Module 06's Kyverno with an image-signature-verification policy,
#    scoped to a brand new supply-chain-demo namespace only
#
# Installs trivy/cosign/crane on this workstation if missing — same
# just-in-time pattern Module 03 used for kubeseal.
#
# Idempotent: safe to re-run. Re-running regenerates the cosign keypair
# (expected — nothing here needs to persist across runs, see README).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "${MODULE_DIR}/../.." && pwd)"
GENERATED_DIR="${MODULE_DIR}/generated"
KYVERNO_ALLOW_INSECURE_FILE="${GENERATED_DIR}/kyverno-registry-client-allow-insecure.before"

TRIVY_VERSION="${TRIVY_VERSION:-0.72.0}"
CRANE_VERSION="${CRANE_VERSION:-0.21.7}"
# Pinned to the 2.x line deliberately, not "whatever's latest" — cosign
# 3.x's default `sign` output changed to the newer sigstore bundle
# format (an OCI image index wrapping an
# application/vnd.dev.sigstore.bundle.v0.3+json artifact, tagged
# sha256-<digest> with no suffix). Found live: Kyverno v1.18.2's
# verifyImages couldn't find a signature in that format at all
# ("no signatures found"), even though the image genuinely was signed —
# confirmed by checking the registry's own tag list and manifest
# directly. cosign 2.x still writes the older sha256-<digest>.sig tag
# scheme (a plain detached signature manifest) that this Kyverno
# version's verifier actually understands. No CLI flag on cosign 3.x
# was found to opt back into that format (--use-signing-config and
# --registry-referrers-mode both looked plausible, neither changed the
# artifact type) — this is Kyverno needing a newer bundle-aware verifier,
# not something fixable by more cosign flags.
COSIGN_VERSION="${COSIGN_VERSION:-2.6.4}"
TRIVY_OPERATOR_CHART_VERSION="${TRIVY_OPERATOR_CHART_VERSION:-0.34.0}"
REGISTRY_STORAGE_CLASS="${REGISTRY_STORAGE_CLASS:-longhorn}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} kubectl cannot reach a cluster. Complete Module 01 first." >&2
  exit 1
fi
if ! kubectl get clusterpolicy require-resource-limits &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Kyverno not found. Complete Module 06 first." >&2
  exit 1
fi
if ! kubectl get storageclass "${REGISTRY_STORAGE_CLASS}" &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} StorageClass ${REGISTRY_STORAGE_CLASS} not found. Complete Module 05 first, or set REGISTRY_STORAGE_CLASS to an existing one." >&2
  exit 1
fi
if ! command -v yq &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} yq not found. Complete Module 00 first." >&2
  exit 1
fi
if ! command -v jq &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} jq not found. Complete Module 00 first." >&2
  exit 1
fi

mkdir -p "$GENERATED_DIR"

echo ""
echo "============================================================"
echo "  Module 16 — Supply Chain Security — Setup"
echo "============================================================"
echo ""

# --- Step 0: workstation tools ---
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) ARCH="amd64"; ARCH_ALT="x86_64" ;;
  arm64|aarch64) ARCH="arm64"; ARCH_ALT="arm64" ;;
  *) echo "Unsupported architecture: $ARCH_RAW" >&2; exit 1 ;;
esac

if ! command -v trivy &>/dev/null; then
  log_info "Installing trivy v${TRIVY_VERSION}..."
  TRIVY_OS="$(echo "$OS" | sed 's/./\U&/')"
  curl -fsSL -o /tmp/trivy.tar.gz "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_${TRIVY_OS}-64bit.tar.gz"
  tar -xzf /tmp/trivy.tar.gz -C /tmp trivy
  sudo mv /tmp/trivy /usr/local/bin/trivy
  rm -f /tmp/trivy.tar.gz
fi
if ! command -v crane &>/dev/null; then
  log_info "Installing crane v${CRANE_VERSION}..."
  CRANE_OS="$(echo "$OS" | sed 's/./\U&/')"
  curl -fsSL -o /tmp/crane.tar.gz "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_${CRANE_OS}_${ARCH_ALT}.tar.gz"
  tar -xzf /tmp/crane.tar.gz -C /tmp crane
  sudo mv /tmp/crane /usr/local/bin/crane
  rm -f /tmp/crane.tar.gz
fi
if ! command -v cosign &>/dev/null; then
  log_info "Installing cosign v${COSIGN_VERSION}..."
  curl -fsSL -o /tmp/cosign "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-${OS}-${ARCH}"
  chmod +x /tmp/cosign
  sudo mv /tmp/cosign /usr/local/bin/cosign
fi
log_ok "trivy, crane, cosign available"

# --- Step 1: Trivy Operator ---
log_info "Installing Trivy Operator v${TRIVY_OPERATOR_CHART_VERSION}..."
helm repo add aqua https://aquasecurity.github.io/helm-charts/ &>/dev/null || true
helm repo update aqua &>/dev/null
# --set resources.* is required, not cosmetic — the chart's top-level
# resources: {} (the operator's own Deployment) is blocked by the
# Kyverno require-resource-limits ClusterPolicy (Module 06), same
# recurring pattern as every other chart install in this repo. The scan
# Job containers it spawns per-workload already have sane defaults
# (trivy.resources in the chart's own values.yaml) and don't need an
# override here.
helm upgrade --install trivy-operator aqua/trivy-operator \
  --version "${TRIVY_OPERATOR_CHART_VERSION}" \
  --namespace trivy-system --create-namespace \
  --set resources.requests.cpu=100m \
  --set resources.requests.memory=128Mi \
  --set resources.limits.cpu=500m \
  --set resources.limits.memory=512Mi \
  --wait --timeout 3m
log_ok "Trivy Operator ready — scanning every workload cluster-wide"

# --- Step 2: SBOM for a real image ---
log_info "Generating an SBOM for frontend's image (trivy CLI, one-off)..."
trivy image --format cyclonedx --output "${GENERATED_DIR}/frontend-sbom.json" \
  us-central1-docker.pkg.dev/google-samples/microservices-demo/frontend:v0.10.5 \
  || log_warn "SBOM generation failed — check network access to pull the image's layers for analysis"
[ -s "${GENERATED_DIR}/frontend-sbom.json" ] && log_ok "SBOM saved: ${GENERATED_DIR}/frontend-sbom.json"

# --- Step 3: self-hosted registry + test image ---
log_info "Deploying the self-hosted registry (storageClassName: ${REGISTRY_STORAGE_CLASS})..."
kubectl create namespace supply-chain-demo --dry-run=client -o yaml | kubectl apply -f -
# Scratch-copy substitution, not an edit to the committed manifest — same
# non-destructive pattern Module 10's setup.sh uses for its own
# storage-class override: registry.yaml's committed default (longhorn)
# stays correct for native learners, only the applied copy changes.
# document_index == 0 targets the PVC specifically — a plain top-level
# yq eval would also stamp .spec.storageClassName onto the Deployment
# and Service documents below it, which isn't a valid field there.
REGISTRY_MANIFEST="${GENERATED_DIR}/registry.yaml"
yq eval '(select(document_index == 0) | .spec.storageClassName) = "'"${REGISTRY_STORAGE_CLASS}"'"' \
  "${MODULE_DIR}/manifests/registry.yaml" > "${REGISTRY_MANIFEST}"
kubectl apply -f "${REGISTRY_MANIFEST}"
kubectl rollout status deployment/registry -n supply-chain-demo --timeout=120s

REGISTRY_PF_PID=""
cleanup_registry_port_forward() {
  if [[ -n "${REGISTRY_PF_PID}" ]]; then
    kill "${REGISTRY_PF_PID}" 2>/dev/null || true
  fi
}
trap cleanup_registry_port_forward EXIT

kubectl port-forward --address 127.0.0.1 -n supply-chain-demo svc/registry 5000:5000 &>/dev/null &
REGISTRY_PF_PID=$!
sleep 3

log_info "Pushing a small test image into the registry (crane, no Docker needed)..."
crane copy busybox:1.36 localhost:5000/test-image:v1 --insecure
log_ok "Pushed localhost:5000/test-image:v1"

# --- Step 4: cosign keypair + signing ---
log_info "Generating a fresh cosign keypair..."
rm -f "${GENERATED_DIR}/cosign.key" "${GENERATED_DIR}/cosign.pub"
(cd "$GENERATED_DIR" && COSIGN_PASSWORD="" cosign generate-key-pair)
log_ok "Keypair generated: ${GENERATED_DIR}/cosign.key (private, git-ignored), ${GENERATED_DIR}/cosign.pub (public)"

log_info "Signing the test image..."
# --tlog-upload=false is required, not optional — without it cosign 2.x
# submits a real entry to the public Sigstore transparency log (Rekor)
# for this throwaway test image, a permanent public record this
# self-contained lab has no business creating. Pure --key signing
# doesn't need the transparency log at all: verification here happens
# entirely offline, against the public key baked into the Kyverno
# policy below, never against Rekor.
COSIGN_PASSWORD="" cosign sign --key "${GENERATED_DIR}/cosign.key" --allow-insecure-registry --tlog-upload=false -y localhost:5000/test-image:v1
log_ok "Image signed"

cleanup_registry_port_forward
REGISTRY_PF_PID=""

# --- Step 5: Kyverno verifyImages policy ---
log_info "Allowing Kyverno's registry client to reach our plain-HTTP in-cluster registry..."
KYVERNO_ALLOW_INSECURE_BEFORE="$(helm get values kyverno -n kyverno --all -o json | jq -r '.registryClient.allowInsecure // false')"
if [[ "${KYVERNO_ALLOW_INSECURE_BEFORE}" != "true" && "${KYVERNO_ALLOW_INSECURE_BEFORE}" != "false" ]]; then
  echo -e "${RED}[ERROR]${NC} Could not determine Kyverno's current registryClient.allowInsecure value." >&2
  exit 1
fi
printf '%s\n' "${KYVERNO_ALLOW_INSECURE_BEFORE}" > "${KYVERNO_ALLOW_INSECURE_FILE}"
helm upgrade kyverno kyverno/kyverno -n kyverno --reuse-values \
  --set registryClient.allowInsecure=true \
  --wait --timeout 3m
log_ok "Kyverno registry client updated"

log_info "Applying the image-signature-verification policy (supply-chain-demo only)..."
cp "${MODULE_DIR}/manifests/kyverno-policy-verify-image-signature.yaml" "${GENERATED_DIR}/policy.yaml"
yq eval ".spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.publicKeys = load_str(\"${GENERATED_DIR}/cosign.pub\")" \
  -i "${GENERATED_DIR}/policy.yaml"
kubectl apply -f "${GENERATED_DIR}/policy.yaml"

log_info "Waiting for the policy to become ready..."
# Kyverno 3.x reports readiness via status.conditions[type=Ready], not the
# older status.ready boolean this loop originally checked — same fix
# already applied in Module 06's scripts, found live here the same way:
# status.ready never became "true" even once the policy genuinely was
# ready (status.conditions showed Ready/True the whole time). Also:
# `VAR=$(kubectl ...)` is NOT exempt from set -e the way `cmd && break`
# is — a single transient kubectl failure here previously killed the
# whole script silently, mid-loop, with no error message at all
# (confirmed live). `|| true` makes a transient failure degrade to an
# empty READY value for that one iteration instead of exiting.
for i in $(seq 1 20); do
  READY=$(kubectl get clusterpolicy verify-signed-images-supply-chain-demo -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [[ -z "$READY" ]] && READY=$(kubectl get clusterpolicy verify-signed-images-supply-chain-demo -o jsonpath='{.status.ready}' 2>/dev/null || true)
  [[ "$READY" == "True" || "$READY" == "true" ]] && break
  sleep 3
done
[[ "$READY" == "True" || "$READY" == "true" ]] \
  && log_ok "Policy ready" \
  || log_warn "Policy not ready yet — check: kubectl get clusterpolicy verify-signed-images-supply-chain-demo -o yaml"

log_info "Deploying a pod using the SIGNED image (should be admitted)..."
kubectl delete pod signed-image-test -n supply-chain-demo --ignore-not-found=true --wait=true &>/dev/null
# Explicit resources: Module 06's require-resource-limits ClusterPolicy is
# cluster-wide (no namespace restriction), so it applies here too — this
# namespace has no LimitRange to backfill defaults the way online-boutique does.
kubectl run signed-image-test -n supply-chain-demo \
  --image=registry.supply-chain-demo.svc.cluster.local:5000/test-image:v1 \
  --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"signed-image-test","image":"registry.supply-chain-demo.svc.cluster.local:5000/test-image:v1","command":["sleep","3600"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"50m","memory":"32Mi"}}}]}}'
log_ok "Signed image admitted successfully"

echo ""
echo "============================================================"
echo "  Setup complete. Run: bash modules/16-supply-chain-security/scripts/verify.sh"
echo "============================================================"
echo ""
