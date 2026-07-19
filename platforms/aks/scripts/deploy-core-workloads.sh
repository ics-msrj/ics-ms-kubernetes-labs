#!/usr/bin/env bash

# Deploys Module 02's application layer on AKS without installing the
# kubeadm-only local-path provisioner. Redis uses the managed Azure Disk CSI
# StorageClass supplied by AKS instead.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_config
require_cluster

# AKS's built-in `managed-csi` StorageClass creates disks with no tags —
# this subscription's tag-requirement policies deny that outright, leaving
# every PVC on it stuck Pending (ProvisioningFailed). If AKS_STORAGE_CLASS
# points at our own tagged StorageClass instead of the stock one, apply it
# (idempotent) before anything tries to claim a volume from it.
if [[ "${AKS_STORAGE_CLASS}" == "managed-csi-tagged" ]]; then
  [[ -n "${AKS_DISK_ENCRYPTION_SET_ID:-}" ]] || die "AKS_DISK_ENCRYPTION_SET_ID must be set in aks.env when AKS_STORAGE_CLASS=managed-csi-tagged."
  sed "s|__DISK_ENCRYPTION_SET_ID__|${AKS_DISK_ENCRYPTION_SET_ID}|g" \
    "${PLATFORM_DIR}/manifests/storageclass-managed-csi-tagged.yaml" | kubectl apply -f -
fi
kubectl get storageclass "${AKS_STORAGE_CLASS}" >/dev/null || die "StorageClass ${AKS_STORAGE_CLASS} not found."

MODULE_DIR="${REPO_ROOT}/modules/02-core-workloads"
UPSTREAM_MANIFEST="${REPO_ROOT}/workloads/online-boutique/upstream/kubernetes-manifests.yaml"

log_info "Creating the Online Boutique namespace and deploying the vendored workload..."
kubectl apply -f "${MODULE_DIR}/manifests/namespace.yaml"
kubectl apply -n online-boutique -f "${UPSTREAM_MANIFEST}"

log_info "Replacing redis-cart with an Azure Disk CSI-backed StatefulSet..."
kubectl delete deployment redis-cart -n online-boutique --ignore-not-found=true
sed "s/storageClassName: local-path/storageClassName: ${AKS_STORAGE_CLASS}/" \
  "${MODULE_DIR}/manifests/redis-cart-statefulset.yaml" | kubectl apply -n online-boutique -f -

kubectl apply -n online-boutique -f "${MODULE_DIR}/manifests/cart-housekeeping-cronjob.yaml"
log_warn "The kubeadm node-exporter DaemonSet is intentionally not installed on AKS. Use kube-prometheus-stack's managed node exporter in the AKS observability adapter."

for deployment in frontend cartservice checkoutservice currencyservice emailservice paymentservice productcatalogservice recommendationservice shippingservice adservice loadgenerator; do
  kubectl rollout status "deployment/${deployment}" -n online-boutique --timeout=180s || log_warn "${deployment} is not Ready yet."
done
kubectl rollout status statefulset/redis-cart -n online-boutique --timeout=180s || log_warn "redis-cart is not Ready yet."
log_ok "Module 02 application layer is deployed with ${AKS_STORAGE_CLASS}."
