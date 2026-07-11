#!/bin/bash
# =============================================================================
# Module 08 — Observability — setup.sh
#
# 1. Installs kube-prometheus-stack (Prometheus Operator, Prometheus,
#    Alertmanager, Grafana, kube-state-metrics) — node-exporter disabled,
#    Module 02's DaemonSet is reused via PodMonitor instead
# 2. Enables cert-manager's ServiceMonitor (for the certificate-expiry alert)
# 3. Applies PodMonitor, PrometheusRule, and a sealed Grafana admin password
# 4. Extends Module 04's Gateway with a grafana.<APP_DOMAIN> listener +
#    HTTPRoute — Grafana only; Prometheus/Alertmanager have no built-in auth
#    and stay port-forward-only on purpose (see README)
#
# Idempotent: safe to re-run.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "${MODULE_DIR}/../.." && pwd)"
GENERATED_DIR="${MODULE_DIR}/generated"

KPS_CHART_VERSION="${KPS_CHART_VERSION:-87.15.1}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-1.21.0}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/lab.env" ] && source "${REPO_ROOT}/lab.env"
APP_DOMAIN="${APP_DOMAIN:-}"
TLS_ISSUER="${TLS_ISSUER:-letsencrypt-staging}"
GRAFANA_DOMAIN="grafana.${APP_DOMAIN}"

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} kubectl cannot reach a cluster. Complete Module 01 first." >&2
  exit 1
fi
if ! kubectl get gateway frontend-gateway -n online-boutique &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Gateway frontend-gateway not found. Complete Module 04 first." >&2
  exit 1
fi
if ! command -v kubeseal &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} kubeseal not found. Complete Module 03 first." >&2
  exit 1
fi

echo ""
echo "============================================================"
echo "  Module 08 — Observability — Setup"
echo "  Grafana: https://${GRAFANA_DOMAIN}"
echo "============================================================"
echo ""

# --- Step 0: kube-scheduler / kube-controller-manager metrics ---
# kubeadm binds both to 127.0.0.1 by default (a deliberate hardening
# default — their metrics endpoints have no auth of their own), which
# means Prometheus can never reach them from inside the cluster network.
# 0.0.0.0 here means "listen on every local interface of this node," NOT
# "open to the internet" — that's a separate, unrelated control (a
# firewall/security-group CIDR rule), and Module 01's Terraform never
# opens these ports externally regardless of this change.
SSH_USER="${SSH_USER:-ubuntu}"
if [[ -n "${CONTROL_PLANE_PUBLIC_IP:-}" ]]; then
  log_info "Setting --bind-address=0.0.0.0 on kube-scheduler and kube-controller-manager..."
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${SSH_USER}@${CONTROL_PLANE_PUBLIC_IP}" '
    for f in kube-scheduler kube-controller-manager; do
      manifest="/etc/kubernetes/manifests/${f}.yaml"
      if sudo grep -q -- "--bind-address=127.0.0.1" "$manifest" 2>/dev/null; then
        sudo sed -i "s/--bind-address=127.0.0.1/--bind-address=0.0.0.0/" "$manifest"
        echo "  patched ${f}"
      else
        echo "  ${f} already 0.0.0.0 (or flag not found) — skipping"
      fi
    done
  ' || log_warn "Could not patch bind-address over SSH — the two Prometheus targets will show DOWN until this is done manually"
  log_ok "kubelet will restart both static pods automatically (a few seconds of scheduling/reconciliation pause, expected)"
else
  log_warn "CONTROL_PLANE_PUBLIC_IP not set in lab.env — skipping the bind-address patch. kube-scheduler/kube-controller-manager targets will show DOWN in Prometheus until this is done manually (see README Troubleshooting)."
fi

# --- Step 1: sealed Grafana admin password ---
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
for i in $(seq 1 15); do
  kubectl get secret grafana-admin-credentials -n monitoring &>/dev/null && break
  sleep 2
done
log_ok "Grafana admin credentials sealed and applied"

# --- Step 2: kube-prometheus-stack ---
log_info "Installing kube-prometheus-stack v${KPS_CHART_VERSION} (this can take a few minutes)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts &>/dev/null || true
helm repo update prometheus-community &>/dev/null
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "${KPS_CHART_VERSION}" \
  --namespace monitoring --create-namespace \
  --set nodeExporter.enabled=false \
  --set grafana.admin.existingSecret=grafana-admin-credentials \
  --set grafana.admin.userKey=admin-user \
  --set grafana.admin.passwordKey=admin-password \
  --wait --timeout 10m
log_ok "kube-prometheus-stack ready"

log_info "Waiting for Prometheus and Alertmanager pods (created by the operator, can take a minute)..."
for i in $(seq 1 30); do
  PROM_UP=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  AM_UP=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  [[ "$PROM_UP" -ge 1 && "$AM_UP" -ge 1 ]] && break
  sleep 10
done
[[ "$PROM_UP" -ge 1 && "$AM_UP" -ge 1 ]] \
  && log_ok "Prometheus and Alertmanager pods are Running" \
  || log_warn "Prometheus/Alertmanager pods not up yet — check: kubectl get pods -n monitoring"

# --- Step 3: cert-manager metrics ---
log_info "Enabling cert-manager's ServiceMonitor (for the certificate-expiry alert)..."
helm repo add jetstack https://charts.jetstack.io &>/dev/null || true
helm repo update jetstack &>/dev/null
helm upgrade cert-manager jetstack/cert-manager \
  --version "v${CERT_MANAGER_VERSION}" \
  --namespace cert-manager \
  --reuse-values \
  --set prometheus.servicemonitor.enabled=true
log_ok "cert-manager metrics enabled"

# --- Step 4: PodMonitor + PrometheusRule ---
log_info "Applying PodMonitor (node-exporter) and PrometheusRule..."
kubectl apply -f "${MODULE_DIR}/manifests/podmonitor-node-exporter.yaml"
kubectl apply -f "${MODULE_DIR}/manifests/prometheusrule-alerts.yaml"
log_ok "Applied"

# --- Step 5: expose Grafana via the Gateway ---
log_info "Extending the Gateway with a grafana.${APP_DOMAIN} listener..."
sed -e "s|__TLS_ISSUER__|${TLS_ISSUER}|g" -e "s|__GRAFANA_DOMAIN__|${GRAFANA_DOMAIN}|g" \
  "${MODULE_DIR}/manifests/gateway-grafana-listener.yaml" | kubectl apply -f -
sed "s|__GRAFANA_DOMAIN__|${GRAFANA_DOMAIN}|g" "${MODULE_DIR}/manifests/httproute-grafana.yaml" | kubectl apply -f -

log_info "Waiting for the grafana-tls certificate to be issued..."
kubectl wait certificate grafana-tls -n online-boutique --for=condition=Ready --timeout=300s \
  || log_warn "Certificate not Ready yet — check: kubectl describe certificate grafana-tls -n online-boutique"

echo ""
echo "============================================================"
echo "  Setup complete. Run: bash modules/08-observability/scripts/verify.sh"
echo ""
echo "  Grafana:      https://${GRAFANA_DOMAIN}  (admin / see generated/grafana-admin-sealedsecret.yaml's source password — or: "
echo "                kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d)"
echo "  Prometheus:   kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090"
echo "  Alertmanager: kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-alertmanager 9093:9093"
echo "============================================================"
echo ""
