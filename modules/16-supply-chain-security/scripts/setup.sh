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

TRIVY_VERSION="${TRIVY_VERSION:-0.72.0}"
CRANE_VERSION="${CRANE_VERSION:-0.21.7}"
COSIGN_VERSION="${COSIGN_VERSION:-3.1.1}"
TRIVY_OPERATOR_CHART_VERSION="${TRIVY_OPERATOR_CHART_VERSION:-0.34.0}"

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
if ! kubectl get storageclass longhorn &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} StorageClass longhorn not found. Complete Module 05 first." >&2
  exit 1
fi
if ! command -v yq &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} yq not found. Complete Module 00 first." >&2
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
helm upgrade --install trivy-operator aqua/trivy-operator \
  --version "${TRIVY_OPERATOR_CHART_VERSION}" \
  --namespace trivy-system --create-namespace \
  --wait --timeout 3m
log_ok "Trivy Operator ready — scanning every workload cluster-wide"

# --- Step 2: SBOM for a real image ---
log_info "Generating an SBOM for frontend's image (trivy CLI, one-off)..."
trivy image --format cyclonedx --output "${GENERATED_DIR}/frontend-sbom.json" \
  us-central1-docker.pkg.dev/google-samples/microservices-demo/frontend:v0.10.5 \
  || log_warn "SBOM generation failed — check network access to pull the image's layers for analysis"
[ -s "${GENERATED_DIR}/frontend-sbom.json" ] && log_ok "SBOM saved: ${GENERATED_DIR}/frontend-sbom.json"

# --- Step 3: self-hosted registry + test image ---
log_info "Deploying the self-hosted registry..."
kubectl create namespace supply-chain-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${MODULE_DIR}/manifests/registry.yaml"
kubectl rollout status deployment/registry -n supply-chain-demo --timeout=120s

pkill -f "port-forward.*supply-chain-demo.*5000" 2>/dev/null || true
sleep 1
kubectl port-forward -n supply-chain-demo svc/registry 5000:5000 &>/dev/null &
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
COSIGN_PASSWORD="" cosign sign --key "${GENERATED_DIR}/cosign.key" --allow-insecure-registry -y localhost:5000/test-image:v1
log_ok "Image signed"

kill "$REGISTRY_PF_PID" 2>/dev/null || true

# --- Step 5: Kyverno verifyImages policy ---
log_info "Allowing Kyverno's registry client to reach our plain-HTTP in-cluster registry..."
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
for i in $(seq 1 20); do
  READY=$(kubectl get clusterpolicy verify-signed-images-supply-chain-demo -o jsonpath='{.status.ready}' 2>/dev/null)
  [[ "$READY" == "true" ]] && break
  sleep 3
done
[[ "$READY" == "true" ]] \
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
