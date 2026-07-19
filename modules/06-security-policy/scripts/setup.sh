#!/bin/bash
# =============================================================================
# Module 06 — Security Policy — setup.sh
#
# 1. Labels online-boutique for Pod Security Admission (restricted)
# 2. Applies RBAC: a read-only 'viewer' and a least-privilege 'ci-deployer'
# 3. Installs Kyverno and two ClusterPolicies (no ':latest' tags, resource
#    limits required)
#
# Idempotent: safe to re-run.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"

KYVERNO_CHART_VERSION="${KYVERNO_CHART_VERSION:-3.8.2}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} kubectl cannot reach a cluster. Complete Module 01 first." >&2
  exit 1
fi
if ! kubectl get namespace online-boutique &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Namespace online-boutique not found. Complete Module 02 first." >&2
  exit 1
fi

echo ""
echo "============================================================"
echo "  Module 06 — Security Policy — Setup"
echo "============================================================"
echo ""

# --- Step 1: Pod Security Admission ---
log_info "Labeling online-boutique for restricted Pod Security Admission..."
kubectl label namespace online-boutique \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted \
  --overwrite
log_ok "PSA labels applied — only affects pods created from now on, existing pods are untouched"

# restricted PSA has four requirements, not three: no privileged containers,
# runAsNonRoot, capabilities.drop:[ALL] + allowPrivilegeEscalation:false —
# and seccompProfile set. The vendored upstream manifest
# (workloads/online-boutique/upstream/kubernetes-manifests.yaml) and
# Module 02's own redis-cart-statefulset.yaml set the first three but not
# the fourth. That's invisible right after this label is applied (PSA
# doesn't touch already-Running pods), and only surfaces the next time
# something tries to create a *new* pod from one of these templates — a
# rollout restart, a scale-up (Module 07's own scale-to-2-replicas step
# included), or a node reschedule. Found by hitting exactly that
# FailedCreate on a live cluster, not by reading the PodSecurity spec.
# Patched here instead of hand-editing the vendored manifest, and kept
# idempotent/harmless to re-run even after Module 03 has already patched
# cartservice/redis-cart itself.
log_info "Patching seccompProfile into every workload's pod template (restricted PSA requires it; upstream doesn't set it)..."
for kind in deployment statefulset; do
  for name in $(kubectl get "$kind" -n online-boutique -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl patch "$kind" "$name" -n online-boutique --type merge \
      -p '{"spec":{"template":{"spec":{"securityContext":{"seccompProfile":{"type":"RuntimeDefault"}}}}}}' >/dev/null
  done
done
log_ok "seccompProfile patched onto every Deployment/StatefulSet"

# --- Step 2: RBAC ---
log_info "Applying RBAC (viewer, ci-deployer)..."
kubectl apply -f "${MODULE_DIR}/manifests/rbac-viewer.yaml"
kubectl apply -f "${MODULE_DIR}/manifests/rbac-ci-deployer.yaml"
log_ok "RBAC applied"

# --- Step 3: Kyverno ---
if kubectl get deployment kyverno-admission-controller -n kyverno &>/dev/null; then
  log_info "Kyverno already installed — skipping"
else
  log_info "Installing Kyverno v${KYVERNO_CHART_VERSION}..."
  helm repo add kyverno https://kyverno.github.io/kyverno/ &>/dev/null || true
  helm repo update kyverno &>/dev/null
  helm install kyverno kyverno/kyverno \
    --version "${KYVERNO_CHART_VERSION}" \
    --namespace kyverno --create-namespace
fi

log_info "Waiting for Kyverno controllers to roll out..."
for dep in kyverno-admission-controller kyverno-background-controller kyverno-cleanup-controller kyverno-reports-controller; do
  kubectl rollout status "deployment/${dep}" -n kyverno --timeout=180s
done
log_ok "Kyverno ready"

log_info "Applying policies (no ':latest' tags, resource limits required)..."
kubectl apply -f "${MODULE_DIR}/manifests/kyverno-policy-disallow-latest-tag.yaml"
kubectl apply -f "${MODULE_DIR}/manifests/kyverno-policy-require-resource-limits.yaml"

log_info "Waiting for policies to become ready..."
for policy in disallow-latest-tag require-resource-limits; do
  for i in $(seq 1 20); do
    # Kyverno 3.x reports readiness via status.conditions[type=Ready], not
    # the older status.ready boolean — check conditions first, fall back
    # to the old field for older chart versions.
    READY=$(kubectl get clusterpolicy "$policy" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    [[ -z "$READY" ]] && READY=$(kubectl get clusterpolicy "$policy" -o jsonpath='{.status.ready}' 2>/dev/null)
    [[ "$READY" == "True" || "$READY" == "true" ]] && break
    sleep 3
  done
  [[ "$READY" == "True" || "$READY" == "true" ]] \
    && log_ok "Policy ${policy} ready" \
    || log_warn "Policy ${policy} not ready yet — check: kubectl get clusterpolicy ${policy} -o yaml"
done

echo ""
echo "============================================================"
echo "  Setup complete. Run: bash modules/06-security-policy/scripts/verify.sh"
echo "============================================================"
echo ""
