#!/usr/bin/env bash

# Deploys Module 02's application layer on GKE without installing the
# kubeadm-only local-path provisioner. Redis uses GKE's own Persistent
# Disk CSI StorageClass instead — no custom StorageClass needed here
# (unlike the AKS track's managed-csi-tagged workaround): this project has
# no mandatory-tag Org Policy, so the stock standard-rwo StorageClass
# works unmodified, confirmed present as the cluster default.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_config
require_cluster

kubectl get storageclass "${GKE_STORAGE_CLASS}" >/dev/null || die "StorageClass ${GKE_STORAGE_CLASS} not found."

MODULE_DIR="${REPO_ROOT}/modules/02-core-workloads"
UPSTREAM_MANIFEST="${REPO_ROOT}/workloads/online-boutique/upstream/kubernetes-manifests.yaml"

log_info "Creating the Online Boutique namespace and deploying the vendored workload..."
kubectl apply -f "${MODULE_DIR}/manifests/namespace.yaml"
kubectl apply -n online-boutique -f "${UPSTREAM_MANIFEST}"

log_info "Replacing redis-cart with a Persistent Disk CSI-backed StatefulSet..."
kubectl delete deployment redis-cart -n online-boutique --ignore-not-found=true
sed "s/storageClassName: local-path/storageClassName: ${GKE_STORAGE_CLASS}/" \
  "${MODULE_DIR}/manifests/redis-cart-statefulset.yaml" | kubectl apply -n online-boutique -f -

kubectl apply -n online-boutique -f "${MODULE_DIR}/manifests/cart-housekeeping-cronjob.yaml"
log_warn "The kubeadm node-exporter DaemonSet is intentionally not installed on GKE. Use kube-prometheus-stack's managed node exporter in a future GKE observability adapter."

for deployment in frontend cartservice checkoutservice currencyservice emailservice paymentservice productcatalogservice recommendationservice shippingservice adservice loadgenerator; do
  kubectl rollout status "deployment/${deployment}" -n online-boutique --timeout=180s || log_warn "${deployment} is not Ready yet."
done
kubectl rollout status statefulset/redis-cart -n online-boutique --timeout=180s || log_warn "redis-cart is not Ready yet."
log_ok "Module 02 application layer is deployed with ${GKE_STORAGE_CLASS}."
