#!/usr/bin/env bash
# =============================================================================
# GKE Platform Track — enable-observability.sh (Module 08 equivalent)
#
# No SSH bind-address patch step at all (nothing to SSH to). The one real
# behavioral flip: Module 02's GKE adapter deliberately doesn't deploy the
# custom online-boutique-namespace node-exporter DaemonSet the native
# track relies on (confirmed live: no such DaemonSet exists on this
# cluster) — so this installs kube-prometheus-stack with
# nodeExporter.enabled=true (the chart's own default, opposite of Module
# 08's nodeExporter.enabled=false) instead of applying Module 08's
# PodMonitor, which targets a DaemonSet that doesn't exist here.
# cert-manager's ServiceMonitor and the PrometheusRule are reused
# unmodified. This track has no GCP Secret Manager adapter yet (unlike
# AKS's Key Vault path) — the Grafana admin password always goes through
# the native kubeseal flow.
#
# Every container kube-prometheus-stack's chart creates needs explicit
# resources — Module 06's require-resource-limits ClusterPolicy is
# already active on this cluster by the time this normally runs (unlike
# AKS, where it happened to run before Module 06 the first time and so
# was never actually tested against it). Confirmed via `helm template`
# before ever applying live: node-exporter, kube-state-metrics, the
# prometheus-operator container, grafana, and both grafana sidecar
# containers all default to {} — prometheus and alertmanager's own
# containers already ship full resources, left alone here. Missed on
# the first pass and found by actually running this: the
# prometheus-operator admission-webhook patch Jobs (job-createSecret,
# job-patchWebhook) also default to {} — easy to miss since a
# resource-completeness check that only looks at Deployment/StatefulSet/
# DaemonSet silently skips Job/CronJob hooks entirely. Bigger miss: the
# actual Prometheus and Alertmanager StatefulSets aren't in the chart's
# templates at all — the operator synthesizes them at runtime from the
# Prometheus/Alertmanager CRDs, so `helm template` never shows them
# either. Their own main containers need `prometheus.prometheusSpec.
# resources` / `alertmanager.alertmanagerSpec.resources`, and the
# config-reloader sidecar the operator injects into both needs
# `prometheusOperator.prometheusConfigReloader.resources` (one shared
# setting for both StatefulSets, not per-instance) — found by watching
# the Prometheus/Alertmanager CRDs sit at RECONCILED=False against a
# live cluster and reading the operator's own logs, not by rendering
# the chart.
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
# Overridable, unlike the AKS track's derived grafana.${APP_DOMAIN} — set
# GKE_GRAFANA_DOMAIN in gke.env for a sibling-style domain instead of a
# subdomain of APP_DOMAIN.
GRAFANA_DOMAIN="${GKE_GRAFANA_DOMAIN:-grafana.${APP_DOMAIN}}"

require_command kubectl
require_command helm
require_command kubeseal
require_cluster
kubectl get gateway frontend-gateway -n online-boutique >/dev/null 2>&1 \
  || die "Gateway frontend-gateway not found. Run enable-networking.sh first."

echo ""
echo "================================================================"
echo "  GKE Platform Track — Observability (Module 08 equivalent)"
echo "  Grafana: https://${GRAFANA_DOMAIN}"
echo "================================================================"
echo ""

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

log_info "Sealing Grafana admin credentials (native kubeseal flow — no Secret Manager adapter on this track yet)..."
mkdir -p "$GENERATED_DIR"
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

log_info "Installing kube-prometheus-stack v${KPS_CHART_VERSION} (nodeExporter.enabled=true — GKE has no separate custom DaemonSet to avoid colliding with)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "${KPS_CHART_VERSION}" \
  --namespace monitoring --create-namespace \
  --set nodeExporter.enabled=true \
  --set grafana.admin.existingSecret=grafana-admin-credentials \
  --set grafana.admin.userKey=admin-user \
  --set grafana.admin.passwordKey=admin-password \
  --set prometheus-node-exporter.resources.requests.cpu=25m \
  --set prometheus-node-exporter.resources.requests.memory=32Mi \
  --set prometheus-node-exporter.resources.limits.cpu=100m \
  --set prometheus-node-exporter.resources.limits.memory=64Mi \
  --set kube-state-metrics.resources.requests.cpu=25m \
  --set kube-state-metrics.resources.requests.memory=64Mi \
  --set kube-state-metrics.resources.limits.cpu=100m \
  --set kube-state-metrics.resources.limits.memory=128Mi \
  --set prometheusOperator.resources.requests.cpu=50m \
  --set prometheusOperator.resources.requests.memory=64Mi \
  --set prometheusOperator.resources.limits.cpu=200m \
  --set prometheusOperator.resources.limits.memory=256Mi \
  --set prometheusOperator.admissionWebhooks.patch.resources.requests.cpu=10m \
  --set prometheusOperator.admissionWebhooks.patch.resources.requests.memory=32Mi \
  --set prometheusOperator.admissionWebhooks.patch.resources.limits.cpu=50m \
  --set prometheusOperator.admissionWebhooks.patch.resources.limits.memory=64Mi \
  --set prometheusOperator.prometheusConfigReloader.resources.requests.cpu=10m \
  --set prometheusOperator.prometheusConfigReloader.resources.requests.memory=32Mi \
  --set prometheusOperator.prometheusConfigReloader.resources.limits.cpu=50m \
  --set prometheusOperator.prometheusConfigReloader.resources.limits.memory=64Mi \
  --set grafana.resources.requests.cpu=50m \
  --set grafana.resources.requests.memory=128Mi \
  --set grafana.resources.limits.cpu=200m \
  --set grafana.resources.limits.memory=256Mi \
  --set grafana.sidecar.resources.requests.cpu=10m \
  --set grafana.sidecar.resources.requests.memory=32Mi \
  --set grafana.sidecar.resources.limits.cpu=50m \
  --set grafana.sidecar.resources.limits.memory=100Mi \
  --set prometheus.prometheusSpec.resources.requests.cpu=200m \
  --set prometheus.prometheusSpec.resources.requests.memory=512Mi \
  --set prometheus.prometheusSpec.resources.limits.cpu=500m \
  --set prometheus.prometheusSpec.resources.limits.memory=1Gi \
  --set alertmanager.alertmanagerSpec.resources.requests.cpu=25m \
  --set alertmanager.alertmanagerSpec.resources.requests.memory=64Mi \
  --set alertmanager.alertmanagerSpec.resources.limits.cpu=100m \
  --set alertmanager.alertmanagerSpec.resources.limits.memory=128Mi \
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

log_info "Extending the Gateway with a ${GRAFANA_DOMAIN} listener..."
sed -e "s|__TLS_ISSUER__|${TLS_ISSUER}|g" -e "s|__GRAFANA_DOMAIN__|${GRAFANA_DOMAIN}|g" -e "s|__APP_DOMAIN__|${APP_DOMAIN}|g" \
  "${PLATFORM_DIR}/manifests/gateway-grafana-listener.yaml" | kubectl apply -f -
sed "s|__GRAFANA_DOMAIN__|${GRAFANA_DOMAIN}|g" "${NATIVE_MODULE_DIR}/manifests/httproute-grafana.yaml" | kubectl apply -f -

log_info "Applying HealthCheckPolicy (GKE-specific — GCP's default / health check expects 200, Grafana 302s to /login there)..."
kubectl apply -f "${PLATFORM_DIR}/manifests/healthcheckpolicy-grafana.yaml"

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
