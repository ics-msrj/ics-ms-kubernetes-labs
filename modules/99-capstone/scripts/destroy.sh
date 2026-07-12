#!/bin/bash
# =============================================================================
# Module 99 — Capstone — destroy.sh
#
# Reverses inject-incident.sh: repoints ArgoCD back at the real branch,
# deletes the capstone-drill branch from your GitOps remote, confirms
# frontend-tls was reissued, and removes any leftover Chaos Mesh object.
# Safe to run even if you diagnosed and recovered everything by hand
# already — every step below tolerates already being fixed.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "${MODULE_DIR}/../.." && pwd)"
GENERATED_DIR="${MODULE_DIR}/generated"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

echo ""
echo "================================================================"
echo "  Module 99 — Capstone — Cleanup"
echo "================================================================"
echo ""

# --- GitOps: repoint ArgoCD back, delete the drill branch ---
RESTORE_REVISION="main"
if [[ -f "${GENERATED_DIR}/argocd-target-revision.before" ]]; then
  RESTORE_REVISION="$(cat "${GENERATED_DIR}/argocd-target-revision.before")"
fi

if kubectl get application online-boutique-packaged -n argocd &>/dev/null; then
  CURRENT="$(kubectl get application online-boutique-packaged -n argocd -o jsonpath='{.spec.source.targetRevision}')"
  if [[ "$CURRENT" == "capstone-drill" ]]; then
    kubectl patch application online-boutique-packaged -n argocd --type merge \
      -p "{\"spec\":{\"source\":{\"targetRevision\":\"${RESTORE_REVISION}\"}}}" &>/dev/null
    log_ok "online-boutique-packaged repointed back to ${RESTORE_REVISION}"
  else
    log_info "online-boutique-packaged already on '${CURRENT}' — nothing to repoint"
  fi
else
  log_warn "ArgoCD Application online-boutique-packaged not found — skipping"
fi

if git -C "$REPO_ROOT" ls-remote --exit-code --heads origin capstone-drill &>/dev/null; then
  git -C "$REPO_ROOT" push origin --delete capstone-drill &>/dev/null \
    && log_ok "capstone-drill branch deleted from origin" \
    || log_warn "Could not delete capstone-drill branch — remove it manually: git push origin --delete capstone-drill"
else
  log_info "No capstone-drill branch on origin — nothing to delete"
fi

git -C "$REPO_ROOT" worktree prune &>/dev/null || true
rm -f "${GENERATED_DIR}/argocd-target-revision.before"

# --- TLS: confirm reissued ---
if kubectl get secret frontend-tls -n online-boutique &>/dev/null; then
  log_ok "frontend-tls Secret present"
else
  log_warn "frontend-tls Secret still missing — cert-manager may still be reissuing, or the issuer needs attention (see Module 04)"
fi

# --- Chaos Mesh: remove any leftover fault ---
kubectl delete podchaos capstone-paymentservice-kill -n online-boutique --ignore-not-found=true &>/dev/null
log_ok "Chaos object removed (if it was still present)"

echo ""
echo "================================================================"
echo "  Module 99 cleanup complete."
echo "================================================================"
echo ""
