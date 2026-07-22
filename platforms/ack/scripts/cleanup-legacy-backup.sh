#!/usr/bin/env bash
# Removes only the abandoned MinIO/Velero lab attempt. It never touches csdr
# or the native ACK Backup Center vault.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_command helm
require_config
require_cluster

echo "This removes the legacy MinIO/Velero namespace 'velero' and its lab PVC."
echo "It does not remove ACK Backup Center resources in namespace csdr."
read -rp "Continue? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }

helm uninstall velero -n velero >/dev/null 2>&1 || true
helm uninstall minio -n velero >/dev/null 2>&1 || true
kubectl delete namespace velero --ignore-not-found=true --wait=true
log_ok "Legacy MinIO/Velero lab resources removed. Review retained ESSD disks in the ECS console."
