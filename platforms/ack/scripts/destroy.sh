#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_config
require_cluster

echo "This deletes only lab Kubernetes resources in ${ACK_CLUSTER_NAME}."
echo "It does not delete the ACK cluster, node pools, ALB, VPC, or Resource Group."
echo "It does not delete Backup Center records, OSS vault data, or ECS snapshots."
read -rp "Delete Online Boutique and the ACK lab snapshot class? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }

kubectl delete namespace online-boutique-restore-drill --ignore-not-found=true --wait=true
kubectl delete namespace online-boutique --ignore-not-found=true --wait=true
kubectl delete volumesnapshotclass ack-essd-snapshot --ignore-not-found=true
log_ok "ACK application resources removed. Review Backup Center records, OSS data, ECS snapshots, and any legacy MinIO/Velero resources separately."
