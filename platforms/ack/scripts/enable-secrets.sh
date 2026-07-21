#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

MODULE_DIR="${REPO_ROOT}/modules/03-config-secrets"
GENERATED_DIR="${MODULE_DIR}/generated"
SEALED_SECRETS_VERSION="${SEALED_SECRETS_VERSION:-0.38.4}"

require_command kubectl
require_command kubeseal
require_storage_config
require_cluster
kubectl get namespace online-boutique >/dev/null || die "Run deploy-core-workloads first."

kubectl apply -f "${MODULE_DIR}/manifests/sealed-secrets-controller.yaml"
kubectl rollout status deployment/sealed-secrets-controller -n kube-system --timeout=180s
kubectl apply -n online-boutique -f "${MODULE_DIR}/manifests/shared-config-configmap.yaml"
kubectl apply -n online-boutique -f "${MODULE_DIR}/manifests/shared-config-deployments.yaml"

mkdir -p "${GENERATED_DIR}"
redis_password="$(openssl rand -hex 16)"
kubectl create secret generic redis-cart-credentials -n online-boutique \
  --from-literal="password=${redis_password}" --dry-run=client -o yaml \
  | kubeseal --format=yaml --controller-namespace=kube-system --controller-name=sealed-secrets-controller \
  >"${GENERATED_DIR}/redis-cart-sealedsecret.yaml"
unset redis_password
kubectl apply -n online-boutique -f "${GENERATED_DIR}/redis-cart-sealedsecret.yaml"

for _ in $(seq 1 15); do
  kubectl get secret redis-cart-credentials -n online-boutique >/dev/null 2>&1 && break
  sleep 2
done
kubectl get secret redis-cart-credentials -n online-boutique >/dev/null \
  || die "Sealed Secrets did not create redis-cart-credentials."

# The native manifest hard-codes local-path, which is invalid and immutable
# after Module 02 has created ACK's CSI-backed StatefulSet.
sed "s|storageClassName: local-path|storageClassName: ${ACK_STORAGE_CLASS}|" \
  "${MODULE_DIR}/manifests/redis-cart-statefulset-with-auth.yaml" \
  | kubectl apply -n online-boutique -f -
kubectl apply -n online-boutique -f "${MODULE_DIR}/manifests/cartservice-with-redis-auth.yaml"
kubectl rollout status statefulset/redis-cart -n online-boutique --timeout=300s
kubectl rollout status deployment/cartservice -n online-boutique --timeout=300s
log_ok "Module 03 equivalent is ready with ACK CSI storage."
