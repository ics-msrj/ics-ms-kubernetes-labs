#!/bin/bash
# =============================================================================
# Module 07 — Scalability & HA — setup.sh
#
# 1. Installs metrics-server (--kubelet-insecure-tls — kubeadm's kubelet
#    serving certs aren't signed by a CA metrics-server trusts by default)
# 2. Installs the VPA components (recommender/updater/admission-controller)
# 3. Installs KEDA
# 4. Applies HPA (frontend), VPA in recommend-only mode (productcatalogservice),
#    a KEDA cron ScaledObject (loadgenerator), and PodDisruptionBudgets
#    (frontend, cartservice — cartservice is scaled to 2 replicas so its PDB
#    has more than one pod to actually protect)
#
# Idempotent: safe to re-run.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"

METRICS_SERVER_CHART_VERSION="${METRICS_SERVER_CHART_VERSION:-3.13.1}"
VPA_CHART_VERSION="${VPA_CHART_VERSION:-0.10.0}"
KEDA_CHART_VERSION="${KEDA_CHART_VERSION:-2.20.1}"

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
echo "  Module 07 — Scalability & HA — Setup"
echo "============================================================"
echo ""

# --- Step 1: metrics-server ---
log_info "Installing metrics-server v${METRICS_SERVER_CHART_VERSION}..."
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ &>/dev/null || true
helm repo update metrics-server &>/dev/null
helm upgrade --install metrics-server metrics-server/metrics-server \
  --version "${METRICS_SERVER_CHART_VERSION}" \
  --namespace kube-system \
  --set 'args={--kubelet-insecure-tls}'
kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s
log_info "Waiting for metrics to start flowing (metrics-server needs ~1 scrape cycle)..."
for i in $(seq 1 24); do
  kubectl top nodes &>/dev/null && break
  sleep 5
done
kubectl top nodes &>/dev/null \
  && log_ok "metrics-server is serving real metrics" \
  || log_warn "kubectl top nodes still failing — give it another minute, or check: kubectl logs -n kube-system deployment/metrics-server"

# --- Step 2: VPA ---
if kubectl get deployment vpa-vertical-pod-autoscaler-recommender -n kube-system &>/dev/null; then
  log_info "VPA already installed — skipping"
else
  log_info "Installing VPA v${VPA_CHART_VERSION}..."
  helm repo add autoscaler https://kubernetes.github.io/autoscaler &>/dev/null || true
  helm repo update autoscaler &>/dev/null
  helm install vpa autoscaler/vertical-pod-autoscaler \
    --version "${VPA_CHART_VERSION}" \
    --namespace kube-system
fi
for dep in vpa-vertical-pod-autoscaler-recommender vpa-vertical-pod-autoscaler-updater vpa-vertical-pod-autoscaler-admission-controller; do
  kubectl rollout status "deployment/${dep}" -n kube-system --timeout=120s
done
log_ok "VPA ready"

# --- Step 3: KEDA ---
if kubectl get deployment keda-operator -n keda &>/dev/null; then
  log_info "KEDA already installed — skipping"
else
  log_info "Installing KEDA v${KEDA_CHART_VERSION}..."
  helm repo add kedacore https://kedacore.github.io/charts &>/dev/null || true
  helm repo update kedacore &>/dev/null
  helm install keda kedacore/keda \
    --version "${KEDA_CHART_VERSION}" \
    --namespace keda --create-namespace
fi
for dep in keda-operator keda-operator-metrics-apiserver keda-admission-webhooks; do
  kubectl rollout status "deployment/${dep}" -n keda --timeout=120s
done
log_ok "KEDA ready"

# --- Step 4: apply autoscaling + PDB objects ---
log_info "Scaling cartservice to 2 replicas (so its PDB has something to protect)..."
kubectl scale deployment cartservice -n online-boutique --replicas=2
kubectl rollout status deployment/cartservice -n online-boutique --timeout=120s

log_info "Applying HPA, VPA, KEDA ScaledObject, and PodDisruptionBudgets..."
kubectl apply -f "${MODULE_DIR}/manifests/hpa-frontend.yaml"
kubectl apply -f "${MODULE_DIR}/manifests/vpa-productcatalogservice.yaml"
kubectl apply -f "${MODULE_DIR}/manifests/keda-scaledobject-loadgenerator.yaml"
kubectl apply -f "${MODULE_DIR}/manifests/pdb-frontend.yaml"
kubectl apply -f "${MODULE_DIR}/manifests/pdb-cartservice.yaml"
log_ok "Autoscaling and disruption-budget objects applied"

echo ""
echo "============================================================"
echo "  Setup complete. Run: bash modules/07-scalability-ha/scripts/verify.sh"
echo "============================================================"
echo ""
