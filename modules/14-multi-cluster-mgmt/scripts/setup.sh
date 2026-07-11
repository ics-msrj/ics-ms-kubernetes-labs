#!/bin/bash
# =============================================================================
# Module 14 — Multi-Cluster Management — setup.sh
#
# 1. Bootstraps a second, small kubeadm cluster (reuses Module 01's own
#    setup-control-plane.sh/setup-worker.sh against NEW VMs — the exact
#    same mechanism, pointed somewhere else) — this cluster only exists to
#    be imported into Rancher, it never runs Online Boutique
# 2. Installs Rancher on the PRIMARY cluster (Gateway API mode)
#
# Importing the second cluster into Rancher is a manual UI step — see the
# README. Rancher's registration flow generates a one-time, instance-
# specific command; scripting it blind risks silently mis-targeting the
# wrong cluster, which is exactly the kind of mistake this step deserves
# a human watching for.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "${MODULE_DIR}/../.." && pwd)"

RANCHER_CHART_VERSION="${RANCHER_CHART_VERSION:-2.14.3}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/lab.env" ] && source "${REPO_ROOT}/lab.env"
APP_DOMAIN="${APP_DOMAIN:-}"
SECOND_SSH_USER="${SECOND_SSH_USER:-ubuntu}"

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} kubectl cannot reach the primary cluster. Complete Module 01 first." >&2
  exit 1
fi
if ! kubectl get gatewayclass cilium &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} GatewayClass 'cilium' not found. Complete Module 04 first." >&2
  exit 1
fi
if [[ -z "$APP_DOMAIN" || "$APP_DOMAIN" == "shop.example.com" ]]; then
  echo -e "${RED}[ERROR]${NC} Set a real APP_DOMAIN in lab.env (Rancher will be reachable at rancher.\${APP_DOMAIN})." >&2
  exit 1
fi
if [[ -z "${SECOND_CONTROL_PLANE_PUBLIC_IP:-}" || -z "${SECOND_WORKER_PUBLIC_IPS:-}" ]]; then
  echo -e "${RED}[ERROR]${NC} SECOND_CONTROL_PLANE_PUBLIC_IP / SECOND_WORKER_PUBLIC_IPS not set in lab.env." >&2
  echo "  Provision a second, small set of VMs first (see this module's README) — the" >&2
  echo "  same way you provisioned the first cluster in Module 01." >&2
  exit 1
fi

RANCHER_DOMAIN="rancher.${APP_DOMAIN}"

echo ""
echo "============================================================"
echo "  Module 14 — Multi-Cluster Management — Setup"
echo "============================================================"
echo ""

# --- Step 1: bootstrap the second cluster ---
CLUSTER1_SCRIPTS="${REPO_ROOT}/modules/01-cluster-setup/scripts"

if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "${SECOND_SSH_USER}@${SECOND_CONTROL_PLANE_PUBLIC_IP}" "test -f /etc/kubernetes/admin.conf" 2>/dev/null; then
  log_info "Second cluster's control-plane already initialized — skipping bootstrap"
else
  log_info "Bootstrapping the second cluster's control-plane..."
  scp -o StrictHostKeyChecking=accept-new "${CLUSTER1_SCRIPTS}/setup-control-plane.sh" \
    "${SECOND_SSH_USER}@${SECOND_CONTROL_PLANE_PUBLIC_IP}:/tmp/"
  ssh "${SECOND_SSH_USER}@${SECOND_CONTROL_PLANE_PUBLIC_IP}" \
    "sudo CONTROL_PLANE_IP=${SECOND_CONTROL_PLANE_PRIVATE_IP:-$SECOND_CONTROL_PLANE_PUBLIC_IP} NODE_NAME=cluster2-control bash /tmp/setup-control-plane.sh"
  log_ok "Second cluster control-plane ready"

  log_info "Joining worker(s) to the second cluster..."
  scp "${SECOND_SSH_USER}@${SECOND_CONTROL_PLANE_PUBLIC_IP}:/tmp/join-command.sh" /tmp/join-command-cluster2.sh
  idx=1
  for WORKER_IP in ${SECOND_WORKER_PUBLIC_IPS}; do
    scp /tmp/join-command-cluster2.sh "${SECOND_SSH_USER}@${WORKER_IP}:/tmp/join-command.sh"
    scp "${CLUSTER1_SCRIPTS}/setup-worker.sh" "${SECOND_SSH_USER}@${WORKER_IP}:/tmp/"
    ssh "${SECOND_SSH_USER}@${WORKER_IP}" "sudo NODE_NAME=cluster2-worker-0${idx} bash /tmp/setup-worker.sh"
    idx=$((idx + 1))
  done
  rm -f /tmp/join-command-cluster2.sh
  log_ok "Second cluster ready"
fi

log_info "Exporting the second cluster's kubeconfig..."
SECOND_KUBECONFIG="${MODULE_DIR}/kubeconfig-cluster2.yaml"
mkdir -p "$MODULE_DIR"
scp -o StrictHostKeyChecking=accept-new "${SECOND_SSH_USER}@${SECOND_CONTROL_PLANE_PUBLIC_IP}:~/.kube/config" "$SECOND_KUBECONFIG"
kubectl config set-cluster kubernetes --server="https://127.0.0.1:6444" --insecure-skip-tls-verify=true --kubeconfig="$SECOND_KUBECONFIG" >/dev/null
pkill -f "ssh.*6444:" 2>/dev/null || true
sleep 1
ssh -f -N -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes \
  -L "6444:${SECOND_CONTROL_PLANE_PRIVATE_IP:-$SECOND_CONTROL_PLANE_PUBLIC_IP}:6443" \
  "${SECOND_SSH_USER}@${SECOND_CONTROL_PLANE_PUBLIC_IP}"
sleep 2
KUBECONFIG="$SECOND_KUBECONFIG" kubectl get nodes &>/dev/null \
  && log_ok "Second cluster reachable at KUBECONFIG=${SECOND_KUBECONFIG} (tunnel on :6444, independent of the primary cluster's :6443 tunnel)" \
  || log_warn "Could not reach the second cluster yet — retry: ssh -f -N -L 6444:${SECOND_CONTROL_PLANE_PRIVATE_IP:-$SECOND_CONTROL_PLANE_PUBLIC_IP}:6443 ${SECOND_SSH_USER}@${SECOND_CONTROL_PLANE_PUBLIC_IP}"

# --- Step 2: Rancher on the primary cluster ---
log_info "Installing cert-manager CRDs check (Rancher's chart expects cert-manager present)..."
kubectl get deployment cert-manager -n cert-manager &>/dev/null \
  || { echo -e "${RED}[ERROR]${NC} cert-manager not found. Complete Module 04 first." >&2; exit 1; }

log_info "Installing Rancher v${RANCHER_CHART_VERSION}..."
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest &>/dev/null || true
helm repo update rancher-latest &>/dev/null
helm upgrade --install rancher rancher-latest/rancher \
  --version "${RANCHER_CHART_VERSION}" \
  --namespace cattle-system --create-namespace \
  -f "${MODULE_DIR}/manifests/rancher-values.yaml" \
  --set hostname="${RANCHER_DOMAIN}" \
  --wait --timeout 5m
log_ok "Rancher ready"

log_info "Waiting for the bootstrap password..."
for i in $(seq 1 20); do
  kubectl get secret bootstrap-secret -n cattle-system &>/dev/null && break
  sleep 5
done
BOOTSTRAP_PASSWORD=$(kubectl get secret bootstrap-secret -n cattle-system -o jsonpath='{.data.bootstrapPassword}' 2>/dev/null | base64 -d)

echo ""
echo "============================================================"
echo "  Setup complete. Run: bash modules/14-multi-cluster-mgmt/scripts/verify.sh"
echo ""
echo "  Rancher:            https://${RANCHER_DOMAIN}"
echo "  Bootstrap password:  ${BOOTSTRAP_PASSWORD:-<not found — see: kubectl get secret bootstrap-secret -n cattle-system>}"
echo "  (you'll be asked to set a real admin password on first login)"
echo ""
echo "  Next: import the second cluster — this is a manual UI step,"
echo "  see modules/14-multi-cluster-mgmt/README.md Step 3."
echo "============================================================"
echo ""
