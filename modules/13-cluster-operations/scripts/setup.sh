#!/bin/bash
# =============================================================================
# Module 13 — Cluster Operations — setup.sh
#
# Everything here is safe to automate (backup is read-only against etcd;
# Velero restores into a fresh namespace, not over the original; node
# maintenance is a full cordon/drain/uncordon cycle, fully reversible).
# The two genuinely risky operations — a kubeadm version upgrade and an
# etcd RESTORE — are deliberately NOT scripted; see the README's Lab
# section for those as careful, manual walkthroughs.
#
# 1. etcd snapshot backup (SSH to control-plane, snapshot saved locally too)
# 2. MinIO (self-hosted S3-compatible backup target, Longhorn-backed)
# 3. Velero (CSI snapshot integration — reuses Module 05's VolumeSnapshotClass)
# 4. Backup online-boutique, restore it into online-boutique-restore-drill
# 5. Node maintenance drill on one worker
#
# Idempotent: safe to re-run.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "${MODULE_DIR}/../.." && pwd)"
BACKUPS_DIR="${MODULE_DIR}/backups"

MINIO_CHART_VERSION="${MINIO_CHART_VERSION:-5.4.0}"
VELERO_CHART_VERSION="${VELERO_CHART_VERSION:-12.1.0}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} kubectl cannot reach a cluster. Complete Module 01 first." >&2
  exit 1
fi
if ! kubectl get namespace online-boutique &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Namespace online-boutique not found. Complete Module 02 first." >&2
  exit 1
fi
if ! kubectl get storageclass longhorn &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} StorageClass longhorn not found. Complete Module 05 first." >&2
  exit 1
fi

echo ""
echo "============================================================"
echo "  Module 13 — Cluster Operations — Setup"
echo "============================================================"
echo ""

# --- Step 1: etcd snapshot backup ---
# Runs entirely through the Kubernetes API (kubectl exec into the etcd
# static pod, kubectl cp the result out) — no SSH needed, and no separate
# etcdctl install on the host: this uses the exact etcdctl binary bundled
# in the running etcd server's own container image, guaranteed
# version-compatible.
log_info "Taking an etcd snapshot..."
mkdir -p "$BACKUPS_DIR"
CONTROL_PLANE_NODE=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
ETCD_POD="etcd-${CONTROL_PLANE_NODE}"
if ! kubectl get pod "$ETCD_POD" -n kube-system &>/dev/null; then
  log_warn "etcd static pod '${ETCD_POD}' not found — skipping the etcd backup step."
else
  SNAPSHOT_NAME="etcd-snapshot-$(date +%Y%m%d-%H%M%S).db"
  kubectl exec -n kube-system "$ETCD_POD" -- sh -c "
    ETCDCTL_API=3 etcdctl snapshot save /tmp/${SNAPSHOT_NAME} \
      --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key
  "
  kubectl cp "kube-system/${ETCD_POD}:/tmp/${SNAPSHOT_NAME}" "${BACKUPS_DIR}/${SNAPSHOT_NAME}"
  kubectl exec -n kube-system "$ETCD_POD" -- rm -f "/tmp/${SNAPSHOT_NAME}"
  log_ok "Snapshot saved off-node: ${BACKUPS_DIR}/${SNAPSHOT_NAME}"
fi

# --- Step 2: MinIO ---
log_info "Generating MinIO root credentials..."
MINIO_ROOT_USER="velero-$(openssl rand -hex 4)"
MINIO_ROOT_PASSWORD="$(openssl rand -hex 16)"

log_info "Installing MinIO v${MINIO_CHART_VERSION} (standalone, Longhorn-backed)..."
# resources.requests.memory=256Mi overrides the chart's own default of
# 16Gi — appropriate for a real production MinIO, but wildly oversized
# for a lab backup target and can fail to schedule on smaller lab VMs.
helm repo add minio https://charts.min.io/ &>/dev/null || true
helm repo update minio &>/dev/null
helm upgrade --install minio minio/minio \
  --version "${MINIO_CHART_VERSION}" \
  --namespace velero --create-namespace \
  --set mode=standalone \
  --set persistence.storageClass=longhorn \
  --set persistence.size=10Gi \
  --set rootUser="${MINIO_ROOT_USER}" \
  --set rootPassword="${MINIO_ROOT_PASSWORD}" \
  --set 'buckets[0].name=velero-backups' \
  --set 'buckets[0].policy=none' \
  --set 'buckets[0].purge=false' \
  --set resources.requests.memory=256Mi \
  --wait --timeout 5m
log_ok "MinIO ready"

# --- Step 3: Velero ---
log_info "Installing Velero v${VELERO_CHART_VERSION}..."
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts &>/dev/null || true
helm repo update vmware-tanzu &>/dev/null
CREDS_FILE="$(mktemp)"
cat > "$CREDS_FILE" <<EOF
[default]
aws_access_key_id=${MINIO_ROOT_USER}
aws_secret_access_key=${MINIO_ROOT_PASSWORD}
EOF
helm upgrade --install velero vmware-tanzu/velero \
  --version "${VELERO_CHART_VERSION}" \
  --namespace velero --create-namespace \
  -f "${MODULE_DIR}/manifests/velero-values.yaml" \
  --set-file credentials.secretContents.cloud="${CREDS_FILE}" \
  --wait --timeout 5m
rm -f "$CREDS_FILE"
unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
log_ok "Velero ready"

log_info "Labeling the longhorn VolumeSnapshotClass for Velero's CSI plugin..."
kubectl label volumesnapshotclass longhorn velero.io/csi-volumesnapshot-class=true --overwrite

log_info "Waiting for the BackupStorageLocation to become Available..."
for i in $(seq 1 20); do
  BSL_PHASE=$(kubectl get backupstoragelocation default -n velero -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$BSL_PHASE" == "Available" ]] && break
  sleep 5
done
[[ "$BSL_PHASE" == "Available" ]] \
  && log_ok "BackupStorageLocation is Available" \
  || log_warn "BackupStorageLocation phase is '${BSL_PHASE:-<none>}' — check: kubectl describe backupstoragelocation default -n velero"

# --- Step 4: backup + restore drill ---
log_info "Backing up online-boutique..."
kubectl delete backup online-boutique-backup -n velero --ignore-not-found=true --wait=true &>/dev/null
kubectl apply -f "${MODULE_DIR}/manifests/velero-backup-online-boutique.yaml"
for i in $(seq 1 30); do
  BACKUP_PHASE=$(kubectl get backup online-boutique-backup -n velero -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$BACKUP_PHASE" == "Completed" || "$BACKUP_PHASE" == "PartiallyFailed" || "$BACKUP_PHASE" == "Failed" ]] && break
  sleep 10
done
if [[ "$BACKUP_PHASE" == "Completed" ]]; then
  log_ok "Backup Completed"
else
  echo -e "${RED}[ERROR]${NC} Backup phase is '${BACKUP_PHASE:-<none>}' — check: kubectl describe backup online-boutique-backup -n velero" >&2
  exit 1
fi

log_info "Restoring into online-boutique-restore-drill..."
kubectl delete restore online-boutique-restore-drill -n velero --ignore-not-found=true --wait=true &>/dev/null
kubectl apply -f "${MODULE_DIR}/manifests/velero-restore-online-boutique.yaml"
for i in $(seq 1 30); do
  RESTORE_PHASE=$(kubectl get restore online-boutique-restore-drill -n velero -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$RESTORE_PHASE" == "Completed" || "$RESTORE_PHASE" == "PartiallyFailed" || "$RESTORE_PHASE" == "Failed" ]] && break
  sleep 10
done
[[ "$RESTORE_PHASE" == "Completed" ]] \
  && log_ok "Restore Completed into online-boutique-restore-drill" \
  || log_warn "Restore phase is '${RESTORE_PHASE:-<none>}' — check: kubectl describe restore online-boutique-restore-drill -n velero"

# --- Step 5: node maintenance drill ---
log_info "Running a cordon/drain/uncordon drill on one worker node..."
WORKER_NODE=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$WORKER_NODE" ]]; then
  log_warn "No worker node found (single-node cluster?) — skipping the drain drill."
else
  log_info "Cordoning ${WORKER_NODE}..."
  kubectl cordon "$WORKER_NODE"
  log_info "Draining ${WORKER_NODE} (respects PodDisruptionBudgets from Module 07)..."
  kubectl drain "$WORKER_NODE" --ignore-daemonsets --delete-emptydir-data --timeout=180s
  log_ok "${WORKER_NODE} drained — every evictable pod rescheduled elsewhere"
  log_info "Uncordoning ${WORKER_NODE}..."
  kubectl uncordon "$WORKER_NODE"
  log_ok "${WORKER_NODE} schedulable again"
fi

echo ""
echo "============================================================"
echo "  Setup complete. Run: bash modules/13-cluster-operations/scripts/verify.sh"
echo ""
echo "  MinIO console: kubectl port-forward -n velero svc/minio-console 9001:9001"
echo "  The kubeadm version upgrade and etcd restore procedures are manual —"
echo "  see modules/13-cluster-operations/README.md."
echo "============================================================"
echo ""
