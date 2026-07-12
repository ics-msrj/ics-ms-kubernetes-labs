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
DRILL_BRANCH="capstone-drill"
ROOT_REVISION_FILE="${GENERATED_DIR}/root-app-target-revision.before"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

echo ""
echo "================================================================"
echo "  Module 99 — Capstone — Cleanup"
echo "================================================================"
echo ""

# --- GitOps: restore root-app first, then delete the drill branch ---
RESTORE_REVISION="main"
if [[ -f "$ROOT_REVISION_FILE" ]]; then
  RESTORE_REVISION="$(cat "$ROOT_REVISION_FILE")"
fi

if kubectl get application root-app -n argocd &>/dev/null; then
  CURRENT="$(kubectl get application root-app -n argocd -o jsonpath='{.spec.source.targetRevision}')"
  if [[ "$CURRENT" == "$DRILL_BRANCH" ]]; then
    kubectl patch application root-app -n argocd --type merge \
      -p "{\"spec\":{\"source\":{\"targetRevision\":\"${RESTORE_REVISION}\"}}}" &>/dev/null
    log_ok "root-app repointed back to ${RESTORE_REVISION}"
  else
    log_info "root-app already on '${CURRENT}' — nothing to repoint"
  fi
else
  log_warn "ArgoCD Application root-app not found — skipping"
fi

for _ in $(seq 1 30); do
  CHILD_REVISION="$(kubectl get application online-boutique-packaged -n argocd -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null)"
  [[ "$CHILD_REVISION" != "$DRILL_BRANCH" ]] && break
  sleep 2
done
if [[ "${CHILD_REVISION:-}" == "$DRILL_BRANCH" ]]; then
  log_warn "online-boutique-packaged still references ${DRILL_BRANCH}; keeping the branch available for ArgoCD"
elif git -C "$REPO_ROOT" ls-remote --exit-code --heads origin "$DRILL_BRANCH" &>/dev/null; then
  git -C "$REPO_ROOT" push origin --delete "$DRILL_BRANCH" &>/dev/null \
    && log_ok "${DRILL_BRANCH} branch deleted from origin" \
    || log_warn "Could not delete ${DRILL_BRANCH} from origin — remove it manually: git push origin --delete ${DRILL_BRANCH}"
else
  log_info "No ${DRILL_BRANCH} branch on origin — nothing to delete"
fi

git -C "$REPO_ROOT" worktree prune &>/dev/null || true
if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${DRILL_BRANCH}"; then
  git -C "$REPO_ROOT" branch -D "$DRILL_BRANCH" &>/dev/null \
    && log_ok "${DRILL_BRANCH} branch deleted locally" \
    || log_warn "Could not delete local ${DRILL_BRANCH} branch — it may still be checked out in another worktree"
fi
rm -f "$ROOT_REVISION_FILE"

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
