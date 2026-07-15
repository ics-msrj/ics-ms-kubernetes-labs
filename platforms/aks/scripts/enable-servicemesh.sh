#!/usr/bin/env bash
# =============================================================================
# AKS Platform Track — enable-servicemesh.sh (Module 17 equivalent)
#
# Deliberately self-managed Istio via Helm — the same way Module 17 does
# it on the native track — NOT the AKS-managed Istio service mesh add-on
# (`az aks update --enable-azure-service-mesh`). Microsoft's own docs
# confirm that add-on cannot be combined with application-routing's
# Istio-based Gateway (--enable-app-routing-istio, already on from
# enable-managed-addons.sh); self-managed Istio has no such conflict,
# since App Routing owns north-south ingress and this owns east-west
# mesh traffic (sidecar injection, mTLS) — genuinely separate concerns.
#
# Needs Module 12 to have been run first (`bash modules/12-progressive-
# delivery/scripts/setup.sh`, unmodified — it's infra-agnostic) so
# frontend is already a Rollout, same dependency Module 17 has natively.
#
# No node-exporter exclusion step: Module 02's AKS adapter never deploys
# a node-exporter into online-boutique in the first place (kube-prometheus-
# stack's own, in the monitoring namespace, is what enable-observability.sh
# uses instead) — there's nothing in the injected namespace to exclude.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

NATIVE_MODULE_DIR="${REPO_ROOT}/modules/17-service-mesh"
ISTIO_VERSION="${ISTIO_VERSION:-1.30.2}"
KIALI_CHART_VERSION="${KIALI_CHART_VERSION:-2.28.0}"
TEMPO_CHART_VERSION="${TEMPO_CHART_VERSION:-1.24.4}"

require_command kubectl
require_command helm
require_cluster
kubectl get deployment monitoring-kube-prometheus-operator -n monitoring >/dev/null 2>&1 \
  || die "Prometheus not found. Run enable-observability.sh first."
kubectl get rollout frontend -n online-boutique >/dev/null 2>&1 \
  || die "Rollout frontend not found. Run modules/12-progressive-delivery/scripts/setup.sh first (unmodified — it's infra-agnostic)."

echo ""
echo "================================================================"
echo "  AKS Platform Track — Service Mesh (Module 17 equivalent)"
echo "================================================================"
echo ""

log_info "Installing Istio v${ISTIO_VERSION}..."
helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo update istio >/dev/null
kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install istio-base istio/base \
  --version "${ISTIO_VERSION}" --namespace istio-system --set defaultRevision=default \
  --wait --timeout 3m
helm upgrade --install istiod istio/istiod \
  --version "${ISTIO_VERSION}" --namespace istio-system \
  --wait --timeout 5m
log_ok "Istio control plane ready"

log_info "Labeling online-boutique for sidecar injection..."
kubectl label namespace online-boutique istio-injection=enabled --overwrite

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

log_info "Enforcing mTLS STRICT (reused unmodified from Module 17)..."
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/peerauthentication-strict-mtls.yaml"

log_info "Installing Tempo v${TEMPO_CHART_VERSION} (tempo-values.yaml storageClassName swapped to ${AKS_STORAGE_CLASS})..."
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update grafana >/dev/null
helm upgrade --install tempo grafana/tempo \
  --version "${TEMPO_CHART_VERSION}" \
  --namespace monitoring \
  -f "${PLATFORM_DIR}/manifests/tempo-values.yaml" \
  --wait --timeout 5m
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/grafana-tempo-datasource.yaml"
log_ok "Tempo ready, wired into Module 08's Grafana"

log_info "Enabling real application tracing on frontend and checkoutservice (reused unmodified from Module 17)..."
kubectl apply -n online-boutique -f "${NATIVE_MODULE_DIR}/manifests/frontend-rollout-with-tracing.yaml"
kubectl apply -n online-boutique -f "${NATIVE_MODULE_DIR}/manifests/checkoutservice-with-tracing.yaml"
kubectl rollout status deployment/checkoutservice -n online-boutique --timeout=180s
PHASE=""
for _ in $(seq 1 30); do
  PHASE=$(kubectl get rollout frontend -n online-boutique -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$PHASE" == "Healthy" ]] && break
  sleep 10
done
log_ok "Tracing enabled"

log_info "Applying retry/circuit-breaking policy for currencyservice (reused unmodified from Module 17)..."
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/currencyservice-resilience.yaml"

log_info "Installing Kiali v${KIALI_CHART_VERSION}..."
helm repo add kiali https://kiali.org/helm-charts >/dev/null 2>&1 || true
helm repo update kiali >/dev/null
helm upgrade --install kiali-server kiali/kiali-server \
  --version "${KIALI_CHART_VERSION}" \
  --namespace istio-system \
  -f "${NATIVE_MODULE_DIR}/manifests/kiali-values.yaml" \
  --set external_services.prometheus.url="http://monitoring-kube-prometheus-prometheus.monitoring.svc:9090" \
  --wait --timeout 3m
log_ok "Kiali ready"

echo ""
echo "================================================================"
echo "  Service mesh ready."
echo "  Kiali:  kubectl port-forward -n istio-system svc/kiali 20001:20001"
echo "  Traces: Grafana -> Explore -> Tempo datasource"
echo "================================================================"
echo ""
