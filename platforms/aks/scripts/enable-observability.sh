#!/usr/bin/env bash
# =============================================================================
# AKS Platform Track — enable-observability.sh (Module 08 equivalent)
#
# No SSH bind-address patch step at all (nothing to SSH to). The one
# real behavioral flip: Module 02's AKS adapter deliberately doesn't
# deploy the custom online-boutique-namespace node-exporter DaemonSet
# the native track relies on (see deploy-core-workloads.sh) — so this
# installs kube-prometheus-stack with nodeExporter.enabled=true (the
# chart's own default, opposite of Module 08's nodeExporter.enabled=false)
# instead of applying Module 08's PodMonitor, which targets a DaemonSet
# that doesn't exist here. Everything else — the sealed Grafana password,
# cert-manager's ServiceMonitor, the PrometheusRule — is reused unmodified.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

NATIVE_MODULE_DIR="${REPO_ROOT}/modules/08-observability"
GENERATED_DIR="${PLATFORM_DIR}/generated"
KPS_CHART_VERSION="${KPS_CHART_VERSION:-87.15.1}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-1.21.0}"
APP_DOMAIN="${APP_DOMAIN:-}"
TLS_ISSUER="${TLS_ISSUER:-letsencrypt-staging}"
GRAFANA_DOMAIN="grafana.${APP_DOMAIN}"

require_command kubectl
require_command kubeseal
require_cluster
kubectl get gateway frontend-gateway -n online-boutique >/dev/null 2>&1 \
  || die "Gateway frontend-gateway not found. Run enable-networking.sh first."

echo ""
echo "================================================================"
echo "  AKS Platform Track — Observability (Module 08 equivalent)"
echo "  Grafana: https://${GRAFANA_DOMAIN}"
echo "================================================================"
echo ""

log_info "Generating and sealing a random Grafana admin password..."
mkdir -p "$GENERATED_DIR"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
GRAFANA_PASSWORD="$(openssl rand -hex 16)"
kubectl create secret generic grafana-admin-credentials \
  --namespace monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="${GRAFANA_PASSWORD}" \
  --dry-run=client -o yaml \
  | kubeseal --format=yaml --controller-namespace=kube-system --controller-name=sealed-secrets-controller \
  > "${GENERATED_DIR}/grafana-admin-sealedsecret.yaml"
unset GRAFANA_PASSWORD
kubectl apply -n monitoring -f "${GENERATED_DIR}/grafana-admin-sealedsecret.yaml"
for _ in $(seq 1 15); do
  kubectl get secret grafana-admin-credentials -n monitoring >/dev/null 2>&1 && break
  sleep 2
done
log_ok "Grafana admin credentials sealed and applied"

log_info "Installing kube-prometheus-stack v${KPS_CHART_VERSION} (nodeExporter.enabled=true — AKS has no separate custom DaemonSet to avoid colliding with)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "${KPS_CHART_VERSION}" \
  --namespace monitoring --create-namespace \
  --set nodeExporter.enabled=true \
  --set grafana.admin.existingSecret=grafana-admin-credentials \
  --set grafana.admin.userKey=admin-user \
  --set grafana.admin.passwordKey=admin-password \
  --wait --timeout 10m
log_ok "kube-prometheus-stack ready"

log_info "Enabling cert-manager's ServiceMonitor (for the certificate-expiry alert)..."
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null
helm upgrade cert-manager jetstack/cert-manager \
  --version "v${CERT_MANAGER_VERSION}" \
  --namespace cert-manager \
  --reuse-values \
  --set prometheus.servicemonitor.enabled=true
log_ok "cert-manager metrics enabled"

log_info "Applying PrometheusRule (reused unmodified from Module 08 — no node-exporter PodMonitor needed, kube-prometheus-stack's own covers it)..."
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/prometheusrule-alerts.yaml"
log_ok "Applied"

log_info "Extending the Gateway with a grafana.${APP_DOMAIN} listener..."
sed -e "s|__TLS_ISSUER__|${TLS_ISSUER}|g" -e "s|__GRAFANA_DOMAIN__|${GRAFANA_DOMAIN}|g" \
  "${PLATFORM_DIR}/manifests/gateway-grafana-listener.yaml" | kubectl apply -f -
sed "s|__GRAFANA_DOMAIN__|${GRAFANA_DOMAIN}|g" "${NATIVE_MODULE_DIR}/manifests/httproute-grafana.yaml" | kubectl apply -f -

log_info "Waiting for the grafana-tls certificate to be issued..."
kubectl wait certificate grafana-tls -n online-boutique --for=condition=Ready --timeout=300s \
  || log_warn "Certificate not Ready yet — check: kubectl describe certificate grafana-tls -n online-boutique"

echo ""
echo "================================================================"
echo "  Observability ready."
echo "  Grafana:      https://${GRAFANA_DOMAIN}"
echo "  Prometheus:   kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090"
echo "================================================================"
echo ""
