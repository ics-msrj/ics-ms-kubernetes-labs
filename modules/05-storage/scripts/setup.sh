#!/bin/bash
# =============================================================================
# Module 05 — Storage — setup.sh
#
# 1. Installs Longhorn's node prerequisite (open-iscsi, nfs-common) over SSH
# 2. Installs the VolumeSnapshot CRDs + snapshot-controller (cluster-wide,
#    CSI-driver-agnostic — this is what makes VolumeSnapshot objects work
#    at all, independent of which CSI driver backs them)
# 3. Installs Longhorn, replica count scaled to how many nodes you actually have
# 4. Migrates redis-cart from local-path (Module 02) to longhorn — this is a
#    genuine migration: the StatefulSet and its PVC are deleted and recreated,
#    so existing cart data does not survive (see README)
# 5. Takes a VolumeSnapshot of the fresh redis-cart PVC
#
# Idempotent for steps 1-3. Steps 4-5 are only re-run if redis-cart isn't
# already on the longhorn StorageClass.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "${MODULE_DIR}/../.." && pwd)"

LONGHORN_VERSION="${LONGHORN_VERSION:-1.12.0}"
SNAPSHOTTER_VERSION="${SNAPSHOTTER_VERSION:-8.6.0}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/lab.env" ] && source "${REPO_ROOT}/lab.env"
SSH_USER="${SSH_USER:-ubuntu}"

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} kubectl cannot reach a cluster. Complete Module 01 first." >&2
  exit 1
fi
if ! kubectl get statefulset redis-cart -n online-boutique &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} redis-cart StatefulSet not found. Complete Module 02 first." >&2
  exit 1
fi

echo ""
echo "============================================================"
echo "  Module 05 — Storage — Setup"
echo "============================================================"
echo ""

# --- Step 1: node prerequisites over SSH ---
log_info "Installing open-iscsi + nfs-common on every node..."
ALL_NODE_IPS="${CONTROL_PLANE_PUBLIC_IP:-} ${WORKER_PUBLIC_IPS:-}"
if [[ -z "${ALL_NODE_IPS// /}" ]]; then
  log_warn "No node IPs found in lab.env — skipping automatic prerequisite install."
  log_warn "Install manually on every node: sudo apt-get install -y open-iscsi nfs-common && sudo systemctl enable --now iscsid"
else
  for ip in $ALL_NODE_IPS; do
    log_info "  -> ${ip}"
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${SSH_USER}@${ip}" \
      "sudo apt-get update -qq && sudo apt-get install -y -qq open-iscsi nfs-common && sudo systemctl enable --now iscsid" \
      || log_warn "Prerequisite install failed on ${ip} — Longhorn pods on that node may not start"
  done
fi
log_ok "Node prerequisites installed"

# --- Step 2: VolumeSnapshot CRDs + snapshot-controller ---
if kubectl get crd volumesnapshots.snapshot.storage.k8s.io &>/dev/null; then
  log_info "VolumeSnapshot CRDs already installed — skipping"
else
  log_info "Installing VolumeSnapshot CRDs v${SNAPSHOTTER_VERSION}..."
  for crd in volumesnapshotclasses volumesnapshotcontents volumesnapshots; do
    kubectl apply -f "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_${crd}.yaml"
  done
fi
log_info "Installing snapshot-controller..."
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v${SNAPSHOTTER_VERSION}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v${SNAPSHOTTER_VERSION}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml"
kubectl rollout status deployment/snapshot-controller -n kube-system --timeout=120s
log_ok "snapshot-controller ready"

# --- Step 3: Longhorn ---
NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
REPLICA_COUNT=$(( NODE_COUNT < 3 ? NODE_COUNT : 3 ))
log_info "Installing Longhorn v${LONGHORN_VERSION} (${NODE_COUNT} node(s) -> ${REPLICA_COUNT} replicas per volume)..."
helm repo add longhorn https://charts.longhorn.io &>/dev/null || true
helm repo update longhorn &>/dev/null
helm upgrade --install longhorn longhorn/longhorn \
  --version "${LONGHORN_VERSION}" \
  --namespace longhorn-system --create-namespace \
  --set persistence.defaultClassReplicaCount="${REPLICA_COUNT}" \
  --set persistence.defaultClass=true

log_info "Waiting for Longhorn to roll out (this can take a few minutes)..."
kubectl rollout status daemonset/longhorn-manager -n longhorn-system --timeout=300s
kubectl rollout status deployment/longhorn-driver-deployer -n longhorn-system --timeout=180s
for i in $(seq 1 30); do
  kubectl get storageclass longhorn &>/dev/null && break
  sleep 5
done
kubectl get storageclass longhorn &>/dev/null \
  && log_ok "StorageClass 'longhorn' ready" \
  || { echo -e "${RED}[ERROR]${NC} StorageClass 'longhorn' never appeared — check: kubectl get pods -n longhorn-system" >&2; exit 1; }

# --- Step 4: migrate redis-cart ---
CURRENT_SC=$(kubectl get pvc redis-data-redis-cart-0 -n online-boutique -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
if [[ "$CURRENT_SC" == "longhorn" ]]; then
  log_info "redis-cart already on the longhorn StorageClass — skipping migration"
else
  log_warn "Migrating redis-cart from '${CURRENT_SC:-none}' to 'longhorn' — existing cart data will be lost."
  kubectl delete statefulset redis-cart -n online-boutique --ignore-not-found=true
  kubectl delete pvc redis-data-redis-cart-0 -n online-boutique --ignore-not-found=true --wait=true
  kubectl apply -n online-boutique -f "${MODULE_DIR}/manifests/redis-cart-statefulset-longhorn.yaml"
  kubectl rollout status statefulset/redis-cart -n online-boutique --timeout=180s
  log_ok "redis-cart is now backed by Longhorn (${REPLICA_COUNT} replicas)"
fi

# --- Step 5: snapshot ---
log_info "Applying VolumeSnapshotClass and taking a snapshot of redis-cart's volume..."
kubectl apply -f "${MODULE_DIR}/manifests/volumesnapshotclass.yaml"
kubectl delete volumesnapshot redis-cart-snapshot -n online-boutique --ignore-not-found=true --wait=true
kubectl apply -f "${MODULE_DIR}/manifests/redis-cart-snapshot.yaml"
log_info "Waiting for the snapshot to become ready..."
for i in $(seq 1 30); do
  READY=$(kubectl get volumesnapshot redis-cart-snapshot -n online-boutique -o jsonpath='{.status.readyToUse}' 2>/dev/null)
  [[ "$READY" == "true" ]] && break
  sleep 5
done
[[ "$READY" == "true" ]] \
  && log_ok "Snapshot redis-cart-snapshot is ready" \
  || log_warn "Snapshot not ready yet — check: kubectl describe volumesnapshot redis-cart-snapshot -n online-boutique"

echo ""
echo "============================================================"
echo "  Setup complete. Run: bash modules/05-storage/scripts/verify.sh"
echo "============================================================"
echo ""
