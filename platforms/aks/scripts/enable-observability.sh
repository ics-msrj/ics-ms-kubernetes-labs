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
# that doesn't exist here. cert-manager's ServiceMonitor and the
# PrometheusRule are reused unmodified. The Grafana admin password comes
# from Key Vault Secrets Provider (see enable-secrets.sh) when
# AKS_KEY_VAULT_NAME is set — otherwise this falls back to the native
# kubeseal flow.
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
AKS_KEY_VAULT_NAME="${AKS_KEY_VAULT_NAME:-}"

require_command kubectl
require_cluster
kubectl get gateway frontend-gateway -n online-boutique >/dev/null 2>&1 \
  || die "Gateway frontend-gateway not found. Run enable-networking.sh first."

echo ""
echo "================================================================"
echo "  AKS Platform Track — Observability (Module 08 equivalent)"
echo "  Grafana: https://${GRAFANA_DOMAIN}"
echo "================================================================"
echo ""

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

if [[ -n "${AKS_KEY_VAULT_NAME}" ]]; then
  log_info "Ensuring grafana-admin-username/password exist in ${AKS_KEY_VAULT_NAME} (never overwritten if already present)..."
  az keyvault secret show --vault-name "${AKS_KEY_VAULT_NAME}" --name grafana-admin-username >/dev/null 2>&1 \
    || az keyvault secret set --vault-name "${AKS_KEY_VAULT_NAME}" --name grafana-admin-username --value admin >/dev/null
  if ! az keyvault secret show --vault-name "${AKS_KEY_VAULT_NAME}" --name grafana-admin-password >/dev/null 2>&1; then
    GRAFANA_PASSWORD="$(openssl rand -hex 16)"
    az keyvault secret set --vault-name "${AKS_KEY_VAULT_NAME}" --name grafana-admin-password --value "${GRAFANA_PASSWORD}" >/dev/null
    unset GRAFANA_PASSWORD
  fi

  KV_SECRETS_PROVIDER_CLIENT_ID=$(az aks show --subscription "${AKS_SUBSCRIPTION_ID}" --resource-group "${AKS_RESOURCE_GROUP}" --name "${AKS_CLUSTER_NAME}" \
    --query "addonProfiles.azureKeyvaultSecretsProvider.identity.clientId" -o tsv)
  TENANT_ID=$(az account show --subscription "${AKS_SUBSCRIPTION_ID}" --query tenantId -o tsv)
  log_info "Applying the Grafana SecretProviderClass (syncs into the grafana-admin-credentials Secret)..."
  sed -e "s|__KEYVAULT_SECRETS_PROVIDER_CLIENT_ID__|${KV_SECRETS_PROVIDER_CLIENT_ID}|g" \
      -e "s|__KEY_VAULT_NAME__|${AKS_KEY_VAULT_NAME}|g" \
      -e "s|__TENANT_ID__|${TENANT_ID}|g" \
      "${PLATFORM_DIR}/manifests/secretproviderclass-grafana.yaml" | kubectl apply -f -
  kubectl rollout status deployment/grafana-secrets-sync -n monitoring --timeout=120s
  for _ in $(seq 1 15); do
    kubectl get secret grafana-admin-credentials -n monitoring >/dev/null 2>&1 && break
    sleep 2
  done
  log_ok "grafana-admin-credentials Secret synced from Key Vault"
else
  require_command kubeseal
  log_info "AKS_KEY_VAULT_NAME not set — falling back to the native kubeseal flow..."
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
fi

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
sed -e "s|__TLS_ISSUER__|${TLS_ISSUER}|g" -e "s|__GRAFANA_DOMAIN__|${GRAFANA_DOMAIN}|g" -e "s|__APP_DOMAIN__|${APP_DOMAIN}|g" \
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
