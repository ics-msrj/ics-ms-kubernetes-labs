#!/usr/bin/env bash

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
GRAFANA_DOMAIN="${ACK_GRAFANA_DOMAIN:-grafana.${APP_DOMAIN}}"

require_command kubectl
require_command helm
require_command kubeseal
require_cluster

use_alb_gateway=false
if kubectl get gateway frontend-gateway -n online-boutique >/dev/null 2>&1; then
  use_alb_gateway=true
else
  log_info "No ACK ALB Gateway exists; Grafana will use a Cloudflare Tunnel public hostname instead."
fi

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
mkdir -p "${GENERATED_DIR}"
grafana_password="$(openssl rand -hex 16)"
kubectl create secret generic grafana-admin-credentials -n monitoring \
  --from-literal=admin-user=admin --from-literal="admin-password=${grafana_password}" \
  --dry-run=client -o yaml \
  | kubeseal --format=yaml --controller-namespace=kube-system --controller-name=sealed-secrets-controller \
  >"${GENERATED_DIR}/grafana-admin-sealedsecret.yaml"
unset grafana_password
kubectl apply -n monitoring -f "${GENERATED_DIR}/grafana-admin-sealedsecret.yaml"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "${KPS_CHART_VERSION}" --namespace monitoring --create-namespace \
  --set nodeExporter.enabled=true \
  --set grafana.admin.existingSecret=grafana-admin-credentials \
  --set grafana.admin.userKey=admin-user --set grafana.admin.passwordKey=admin-password \
  --set prometheus-node-exporter.resources.requests.cpu=25m --set prometheus-node-exporter.resources.requests.memory=32Mi \
  --set prometheus-node-exporter.resources.limits.cpu=100m --set prometheus-node-exporter.resources.limits.memory=64Mi \
  --set kube-state-metrics.resources.requests.cpu=25m --set kube-state-metrics.resources.requests.memory=64Mi \
  --set kube-state-metrics.resources.limits.cpu=100m --set kube-state-metrics.resources.limits.memory=128Mi \
  --set prometheusOperator.resources.requests.cpu=50m --set prometheusOperator.resources.requests.memory=64Mi \
  --set prometheusOperator.resources.limits.cpu=200m --set prometheusOperator.resources.limits.memory=256Mi \
  --set prometheusOperator.admissionWebhooks.patch.resources.requests.cpu=10m \
  --set prometheusOperator.admissionWebhooks.patch.resources.requests.memory=32Mi \
  --set prometheusOperator.admissionWebhooks.patch.resources.limits.cpu=50m \
  --set prometheusOperator.admissionWebhooks.patch.resources.limits.memory=64Mi \
  --set prometheusOperator.prometheusConfigReloader.resources.requests.cpu=10m \
  --set prometheusOperator.prometheusConfigReloader.resources.requests.memory=32Mi \
  --set prometheusOperator.prometheusConfigReloader.resources.limits.cpu=50m \
  --set prometheusOperator.prometheusConfigReloader.resources.limits.memory=64Mi \
  --set grafana.resources.requests.cpu=50m --set grafana.resources.requests.memory=128Mi \
  --set grafana.resources.limits.cpu=200m --set grafana.resources.limits.memory=256Mi \
  --set grafana.sidecar.resources.requests.cpu=10m --set grafana.sidecar.resources.requests.memory=32Mi \
  --set grafana.sidecar.resources.limits.cpu=50m --set grafana.sidecar.resources.limits.memory=100Mi \
  --set prometheus.prometheusSpec.resources.requests.cpu=200m --set prometheus.prometheusSpec.resources.requests.memory=512Mi \
  --set prometheus.prometheusSpec.resources.limits.cpu=500m --set prometheus.prometheusSpec.resources.limits.memory=1Gi \
  --set alertmanager.alertmanagerSpec.resources.requests.cpu=25m --set alertmanager.alertmanagerSpec.resources.requests.memory=64Mi \
  --set alertmanager.alertmanagerSpec.resources.limits.cpu=100m --set alertmanager.alertmanagerSpec.resources.limits.memory=128Mi \
  --wait --timeout 10m

helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null
cert_manager_args=(
  --version "v${CERT_MANAGER_VERSION}"
  --namespace cert-manager
  --create-namespace
  --set crds.enabled=true
  --set prometheus.servicemonitor.enabled=true
  --set resources.requests.cpu=50m
  --set resources.requests.memory=64Mi
  --set resources.limits.cpu=200m
  --set resources.limits.memory=256Mi
  --set webhook.resources.requests.cpu=25m
  --set webhook.resources.requests.memory=32Mi
  --set webhook.resources.limits.cpu=100m
  --set webhook.resources.limits.memory=128Mi
  --set cainjector.resources.requests.cpu=25m
  --set cainjector.resources.requests.memory=64Mi
  --set cainjector.resources.limits.cpu=100m
  --set cainjector.resources.limits.memory=128Mi
  --set startupapicheck.resources.requests.cpu=10m
  --set startupapicheck.resources.requests.memory=32Mi
  --set startupapicheck.resources.limits.cpu=50m
  --set startupapicheck.resources.limits.memory=64Mi
)
if helm status cert-manager -n cert-manager >/dev/null 2>&1; then
  helm upgrade cert-manager jetstack/cert-manager --reuse-values "${cert_manager_args[@]}"
else
  helm install cert-manager jetstack/cert-manager "${cert_manager_args[@]}"
fi
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/prometheusrule-alerts.yaml"
if [[ "${use_alb_gateway}" == true ]]; then
  sed -e "s|__TLS_ISSUER__|${TLS_ISSUER}|g" -e "s|__APP_DOMAIN__|${APP_DOMAIN}|g" \
    -e "s|__GRAFANA_DOMAIN__|${GRAFANA_DOMAIN}|g" "${PLATFORM_DIR}/manifests/gateway-grafana-listener.yaml" | kubectl apply -f -
  sed "s|__GRAFANA_DOMAIN__|${GRAFANA_DOMAIN}|g" "${NATIVE_MODULE_DIR}/manifests/httproute-grafana.yaml" | kubectl apply -f -
  log_ok "Module 08 equivalent applied. Grafana: https://${GRAFANA_DOMAIN}"
else
  log_ok "Module 08 equivalent applied. Configure ${GRAFANA_DOMAIN} in Cloudflare Tunnel to route to http://monitoring-grafana.monitoring.svc.cluster.local:80."
fi
