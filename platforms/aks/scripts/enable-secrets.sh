#!/usr/bin/env bash
# =============================================================================
# AKS Platform Track — enable-secrets.sh (Module 03 equivalent)
#
# Unlike Module 03's native Sealed Secrets flow, this uses AKS's Key Vault
# Secrets Provider add-on (Terraform's key_vault_secrets_provider block) —
# a SecretProviderClass syncs real Key Vault secrets into the same K8s
# Secret names/keys the native manifests already expect
# (redis-cart-credentials / password), so redis-cart-statefulset-with-auth.
# yaml and cartservice-with-redis-auth.yaml are reused completely
# unmodified. Only the *source* of the Secret changes — no kubeseal, no
# sealed-secrets-controller, no in-cluster password generation.
#
# Requires AKS_KEY_VAULT_NAME set in aks.env (Terraform's key_vault_name
# must also be set, so the cluster actually has the add-on enabled).
#
# Idempotent: safe to re-run. Does NOT rotate the Key Vault password on
# re-run (unlike Module 03's native script, which deliberately reseals a
# fresh one every time) — this is app credential storage now, not a
# from-scratch demo secret, so silently rotating it on every run would
# just be surprising.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

NATIVE_MODULE_DIR="${REPO_ROOT}/modules/03-config-secrets"
AKS_KEY_VAULT_NAME="${AKS_KEY_VAULT_NAME:-}"

require_command kubectl
require_command az
require_config
require_cluster
[[ -n "${AKS_KEY_VAULT_NAME}" ]] || die "AKS_KEY_VAULT_NAME must be set in aks.env — this is the Key Vault the Terraform key_vault_secrets_provider block was pointed at."
kubectl get namespace online-boutique >/dev/null || die "Namespace online-boutique not found. Run deploy-core-workloads.sh first."

echo ""
echo "============================================================"
echo "  AKS Platform Track — Secrets (Module 03 equivalent)"
echo "============================================================"
echo ""

KV_SECRETS_PROVIDER_CLIENT_ID=$(az aks show --subscription "${AKS_SUBSCRIPTION_ID}" --resource-group "${AKS_RESOURCE_GROUP}" --name "${AKS_CLUSTER_NAME}" \
  --query "addonProfiles.azureKeyvaultSecretsProvider.identity.clientId" -o tsv)
[[ -n "${KV_SECRETS_PROVIDER_CLIENT_ID}" && "${KV_SECRETS_PROVIDER_CLIENT_ID}" != "null" ]] \
  || die "Key Vault Secrets Provider add-on identity not found — did terraform apply with key_vault_name set?"
TENANT_ID=$(az account show --subscription "${AKS_SUBSCRIPTION_ID}" --query tenantId -o tsv)

log_info "Ensuring redis-cart-password exists in ${AKS_KEY_VAULT_NAME} (never overwritten if already present)..."
if ! az keyvault secret show --vault-name "${AKS_KEY_VAULT_NAME}" --name redis-cart-password >/dev/null 2>&1; then
  REDIS_PASSWORD="$(openssl rand -hex 16)"
  az keyvault secret set --vault-name "${AKS_KEY_VAULT_NAME}" --name redis-cart-password --value "${REDIS_PASSWORD}" >/dev/null
  unset REDIS_PASSWORD
  log_ok "Generated a new redis-cart-password"
else
  log_info "redis-cart-password already exists — reusing it"
fi

log_info "Applying the redis-cart SecretProviderClass (syncs into the redis-cart-credentials Secret)..."
sed -e "s|__KEYVAULT_SECRETS_PROVIDER_CLIENT_ID__|${KV_SECRETS_PROVIDER_CLIENT_ID}|g" \
    -e "s|__KEY_VAULT_NAME__|${AKS_KEY_VAULT_NAME}|g" \
    -e "s|__TENANT_ID__|${TENANT_ID}|g" \
    "${PLATFORM_DIR}/manifests/secretproviderclass-redis-cart.yaml" | kubectl apply -f -
kubectl rollout status deployment/redis-cart-secrets-sync -n online-boutique --timeout=120s
for _ in $(seq 1 15); do
  kubectl get secret redis-cart-credentials -n online-boutique >/dev/null 2>&1 && break
  sleep 2
done
kubectl get secret redis-cart-credentials -n online-boutique >/dev/null 2>&1 \
  && log_ok "redis-cart-credentials Secret synced" \
  || die "redis-cart-credentials Secret never appeared — check: kubectl describe secretproviderclass redis-cart-secrets -n online-boutique"

log_info "Applying shared ConfigMap and the 6 Deployments that consume it (reused unmodified from Module 03)..."
kubectl apply -n online-boutique -f "${NATIVE_MODULE_DIR}/manifests/shared-config-configmap.yaml"
kubectl apply -n online-boutique -f "${NATIVE_MODULE_DIR}/manifests/shared-config-deployments.yaml"
log_ok "ConfigMap applied"

log_info "Enabling Redis AUTH on redis-cart (reused unmodified from Module 03)..."
sed "s/storageClassName: local-path/storageClassName: ${AKS_STORAGE_CLASS}/" \
  "${NATIVE_MODULE_DIR}/manifests/redis-cart-statefulset-with-auth.yaml" | kubectl apply -n online-boutique -f -

log_info "Updating cartservice to authenticate to redis-cart (reused unmodified from Module 03)..."
kubectl apply -n online-boutique -f "${NATIVE_MODULE_DIR}/manifests/cartservice-with-redis-auth.yaml"

log_info "Waiting for rollouts..."
kubectl rollout status statefulset/redis-cart -n online-boutique --timeout=120s
kubectl rollout status deployment/cartservice -n online-boutique --timeout=120s
for dep in currencyservice productcatalogservice shippingservice emailservice paymentservice recommendationservice; do
  kubectl rollout status "deployment/${dep}" -n online-boutique --timeout=120s \
    || log_warn "${dep} not ready yet — check: kubectl get pods -n online-boutique"
done

echo ""
echo "============================================================"
echo "  Secrets ready via Key Vault Secrets Provider."
echo "============================================================"
echo ""
