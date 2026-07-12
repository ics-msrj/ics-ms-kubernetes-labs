#!/bin/bash
# =============================================================================
# Module 18 — Scenario 4 — Node-level failure (manual, real VM)
#
# Chaos Mesh's PodChaos/NetworkChaos/StressChaos all operate INSIDE the
# cluster — they can't take a whole node down. For that, this script
# reuses Module 01's own SSH access pattern (same SSH_USER, same
# WORKER_PUBLIC_IPS, no -i flag — relies on ssh-agent/default key exactly
# like modules/01-cluster-setup/scripts/destroy.sh) to stop kubelet on a
# real worker VM.
#
# Usage:
#   bash gameday-node-failure.sh break     — stop kubelet on the first worker
#   bash gameday-node-failure.sh recover   — start kubelet again on it
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "${MODULE_DIR}/../.." && pwd)"

# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/lab.env" ] && source "${REPO_ROOT}/lab.env"

SSH_USER="${SSH_USER:-ubuntu}"
WORKER_IPS="${WORKER_PUBLIC_IPS:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

ACTION="${1:-}"
if [[ "$ACTION" != "break" && "$ACTION" != "recover" ]]; then
  echo "Usage: $0 <break|recover>" >&2
  exit 1
fi

if [[ -z "$WORKER_IPS" ]]; then
  log_error "WORKER_PUBLIC_IPS not set in lab.env — nothing to target."
  exit 1
fi
# shellcheck disable=SC2206
WORKER_ARRAY=($WORKER_IPS)
TARGET_IP="${WORKER_ARRAY[0]}"

if [[ "$ACTION" == "break" ]]; then
  echo ""
  echo "================================================================"
  echo "  GameDay Scenario 4 — Node Failure"
  echo "================================================================"
  echo ""
  echo -e "${YELLOW}This stops kubelet on ${TARGET_IP} — every pod scheduled${NC}"
  echo -e "${YELLOW}there stops being managed until it's marked NotReady and its${NC}"
  echo -e "${YELLOW}pods are rescheduled elsewhere (or until you recover it).${NC}"
  echo ""
  read -rp "Continue? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_info "Aborted."
    exit 0
  fi
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${SSH_USER}@${TARGET_IP}" \
    "sudo systemctl stop kubelet"
  log_ok "kubelet stopped on ${TARGET_IP}"
  echo ""
  echo "  Detect with:"
  echo "    kubectl get nodes -w"
  echo "    (the node goes NotReady after ~40s; pods evict after the default"
  echo "     5-minute pod-eviction-timeout unless a PDB blocks it — Module 07's"
  echo "     pdb-cartservice.yaml / pdb-frontend.yaml may hold pods in place"
  echo "     on THIS node if it's the last one satisfying their minAvailable)"
  echo ""
  echo "  Recover with: bash $0 recover"
  echo ""
else
  log_info "Restarting kubelet on ${TARGET_IP}..."
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${SSH_USER}@${TARGET_IP}" \
    "sudo systemctl start kubelet"
  log_ok "kubelet started on ${TARGET_IP}"
  echo ""
  echo "  Confirm recovery: kubectl get nodes"
  echo ""
fi
