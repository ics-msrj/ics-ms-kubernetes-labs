#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_config
require_storage_config
require_cluster

kubectl get storageclass "${ACK_STORAGE_CLASS}" >/dev/null \
  || die "StorageClass ${ACK_STORAGE_CLASS} was not found."

module_dir="${REPO_ROOT}/modules/02-core-workloads"
upstream_manifest="${REPO_ROOT}/workloads/online-boutique/upstream/kubernetes-manifests.yaml"

log_info "Creating Online Boutique and deploying the vendored workload..."
kubectl apply -f "${module_dir}/manifests/namespace.yaml"
kubectl apply -n online-boutique -f "${upstream_manifest}"

log_info "Pinning application Pods to ${ACK_WORKLOAD_LABEL_KEY}=${ACK_WORKLOAD_LABEL_VALUE}..."
for deployment in frontend cartservice checkoutservice currencyservice emailservice paymentservice productcatalogservice recommendationservice shippingservice adservice loadgenerator; do
  kubectl patch deployment "${deployment}" -n online-boutique --type merge \
    -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"${ACK_WORKLOAD_LABEL_KEY}\":\"${ACK_WORKLOAD_LABEL_VALUE}\"}}}}}"
done

log_info "Replacing redis-cart with an ACK CSI-backed StatefulSet..."
kubectl delete deployment redis-cart -n online-boutique --ignore-not-found=true
sed "s/storageClassName: local-path/storageClassName: ${ACK_STORAGE_CLASS}/" \
  "${module_dir}/manifests/redis-cart-statefulset.yaml" | kubectl apply -n online-boutique -f -
kubectl patch statefulset redis-cart -n online-boutique --type merge \
  -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"${ACK_WORKLOAD_LABEL_KEY}\":\"${ACK_WORKLOAD_LABEL_VALUE}\"}}}}}"
kubectl apply -n online-boutique -f "${module_dir}/manifests/cart-housekeeping-cronjob.yaml"

log_warn "The native node-exporter DaemonSet is intentionally not installed on ACK. The ACK observability adapter will configure node metrics after live validation."
for deployment in frontend cartservice checkoutservice currencyservice emailservice paymentservice productcatalogservice recommendationservice shippingservice adservice loadgenerator; do
  kubectl rollout status "deployment/${deployment}" -n online-boutique --timeout=180s \
    || log_warn "${deployment} is not Ready yet."
done
kubectl rollout status statefulset/redis-cart -n online-boutique --timeout=180s \
  || log_warn "redis-cart is not Ready yet."
log_ok "Module 02 application layer is deployed with ${ACK_STORAGE_CLASS}."
