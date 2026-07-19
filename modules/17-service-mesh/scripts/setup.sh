#!/bin/bash
# =============================================================================
# Module 17 — Service Mesh — setup.sh
#
# Applies to the REAL online-boutique namespace, not a throwaway one — a
# service mesh's entire point is securing/observing what's actually
# running. Every workload in that namespace gets restarted to pick up an
# injected Envoy sidecar; node-exporter (hostNetwork) is explicitly excluded.
#
# 1. Installs Istio (sidecar mode) — no separate Istio gateway, external
#    traffic keeps using Module 04's Cilium Gateway
# 2. Labels online-boutique for injection, restarts every workload
# 3. Enforces mTLS STRICT
# 4. Installs Tempo (added to Module 08/09's Grafana) and enables real
#    application-level tracing on frontend + checkoutservice
# 5. Adds retry/circuit-breaking resilience for currencyservice
# 6. Installs Kiali, pointed at Module 08's Prometheus
#
# Idempotent: safe to re-run.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"

ISTIO_VERSION="${ISTIO_VERSION:-1.30.2}"
KIALI_CHART_VERSION="${KIALI_CHART_VERSION:-2.28.0}"
TEMPO_CHART_VERSION="${TEMPO_CHART_VERSION:-1.24.4}"
TEMPO_STORAGE_CLASS="${TEMPO_STORAGE_CLASS:-longhorn}"

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
if ! kubectl get deployment monitoring-kube-prometheus-operator -n monitoring &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Prometheus not found. Complete Module 08 first." >&2
  exit 1
fi
if ! kubectl get storageclass "${TEMPO_STORAGE_CLASS}" &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} StorageClass ${TEMPO_STORAGE_CLASS} not found. Complete Module 05 first, or set TEMPO_STORAGE_CLASS to an existing one." >&2
  exit 1
fi

echo ""
echo "============================================================"
echo "  Module 17 — Service Mesh — Setup"
echo "============================================================"
echo ""

# --- Step 1: Istio (sidecar mode, no separate gateway) ---
log_info "Installing Istio v${ISTIO_VERSION}..."
helm repo add istio https://istio-release.storage.googleapis.com/charts &>/dev/null || true
helm repo update istio &>/dev/null
kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install istio-base istio/base \
  --version "${ISTIO_VERSION}" --namespace istio-system --set defaultRevision=default \
  --wait --timeout 3m
# pilot.resources.limits is required, not cosmetic — the chart sets
# requests by default but no limits, blocked by the Kyverno
# require-resource-limits ClusterPolicy (Module 06), same recurring
# pattern as every other chart install in this repo.
helm upgrade --install istiod istio/istiod \
  --version "${ISTIO_VERSION}" --namespace istio-system \
  --set pilot.resources.limits.cpu=1000m \
  --set pilot.resources.limits.memory=4096Mi \
  --wait --timeout 5m
log_ok "Istio control plane ready"

# --- Step 2: enable injection, restart every workload ---
log_info "Labeling online-boutique for sidecar injection..."
kubectl label namespace online-boutique istio-injection=enabled --overwrite

log_info "Excluding node-exporter (hostNetwork — incompatible with sidecar injection)..."
kubectl apply -f "${MODULE_DIR}/manifests/node-exporter-no-injection.yaml"

log_info "Restarting every Deployment/StatefulSet/Rollout in online-boutique to inject sidecars..."
for dep in currencyservice shippingservice cartservice emailservice paymentservice \
           recommendationservice adservice loadgenerator; do
  kubectl rollout restart "deployment/${dep}" -n online-boutique
done
kubectl rollout restart statefulset/redis-cart -n online-boutique

for dep in currencyservice shippingservice cartservice emailservice paymentservice \
           recommendationservice adservice loadgenerator; do
  kubectl rollout status "deployment/${dep}" -n online-boutique --timeout=180s \
    || log_warn "${dep} rollout not finished yet — check: kubectl get pods -n online-boutique"
done
kubectl rollout status statefulset/redis-cart -n online-boutique --timeout=120s
log_ok "Sidecars injected across online-boutique"

# --- Step 3: mTLS STRICT ---
log_info "Enforcing mTLS STRICT..."
kubectl apply -f "${MODULE_DIR}/manifests/peerauthentication-strict-mtls.yaml"

# --- Step 4: Tempo + tracing ---
log_info "Installing Tempo v${TEMPO_CHART_VERSION}..."
helm repo add grafana https://grafana.github.io/helm-charts &>/dev/null || true
helm repo update grafana &>/dev/null
# tempo.resources.* is required, not cosmetic — the chart's default
# resources: {} is blocked by the Kyverno require-resource-limits
# ClusterPolicy, same recurring pattern as every other chart install in
# this repo.
helm upgrade --install tempo grafana/tempo \
  --version "${TEMPO_CHART_VERSION}" \
  --namespace monitoring \
  -f "${MODULE_DIR}/manifests/tempo-values.yaml" \
  --set persistence.storageClassName="${TEMPO_STORAGE_CLASS}" \
  --set tempo.resources.requests.cpu=200m \
  --set tempo.resources.requests.memory=512Mi \
  --set tempo.resources.limits.cpu=1000m \
  --set tempo.resources.limits.memory=1Gi \
  --wait --timeout 5m
kubectl apply -f "${MODULE_DIR}/manifests/grafana-tempo-datasource.yaml"
log_ok "Tempo ready, wired into Module 08's Grafana"

log_info "Enabling real application tracing on frontend and checkoutservice..."
kubectl apply -n online-boutique -f "${MODULE_DIR}/manifests/frontend-rollout-with-tracing.yaml"
kubectl apply -n online-boutique -f "${MODULE_DIR}/manifests/checkoutservice-with-tracing.yaml"
kubectl rollout status deployment/checkoutservice -n online-boutique --timeout=180s
for i in $(seq 1 30); do
  PHASE=$(kubectl get rollout frontend -n online-boutique -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$PHASE" == "Healthy" ]] && break
  sleep 10
done
log_ok "Tracing enabled"

# --- Step 5: resilience for currencyservice ---
log_info "Applying retry/circuit-breaking policy for currencyservice..."
kubectl apply -f "${MODULE_DIR}/manifests/currencyservice-resilience.yaml"

# --- Step 6: Kiali ---
log_info "Installing Kiali v${KIALI_CHART_VERSION}..."
helm repo add kiali https://kiali.org/helm-charts &>/dev/null || true
helm repo update kiali &>/dev/null
helm upgrade --install kiali-server kiali/kiali-server \
  --version "${KIALI_CHART_VERSION}" \
  --namespace istio-system \
  -f "${MODULE_DIR}/manifests/kiali-values.yaml" \
  --set external_services.prometheus.url="http://monitoring-kube-prometheus-prometheus.monitoring.svc:9090" \
  --wait --timeout 3m
log_ok "Kiali ready"

echo ""
echo "============================================================"
echo "  Setup complete. Run: bash modules/17-service-mesh/scripts/verify.sh"
echo ""
echo "  Kiali:  kubectl port-forward -n istio-system svc/kiali 20001:20001"
echo "  Traces: Grafana (Module 08) -> Explore -> Tempo datasource"
echo "============================================================"
echo ""
