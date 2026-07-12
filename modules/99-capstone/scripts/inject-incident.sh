#!/bin/bash
# =============================================================================
# Module 99 — Capstone — inject-incident.sh
#
# NOT referenced anywhere in this module's README Lab steps, on purpose —
# this is for whoever is running the drill AGAINST the responder (a study
# partner, a trainer, or yourself a few minutes in the past if you're doing
# this solo and deliberately not reading this file first). The responder's
# job is to detect, diagnose, and recover using only modules/99-capstone/
# README's readiness check and the observability stack already built —
# not this script.
#
# Three independent faults, injected together:
#
#   1. GitOps drift — pushes a bad commit to a NEW `capstone-drill` branch
#      (never the configured root-app revision — that branch is this repo's
#      public portfolio history and stays untouched) that halves
#      productcatalogservice's memory limit into OOMKilled territory. It then
#      repoints root-app at that branch, so root-app's own selfHeal keeps the
#      child Application on the drill branch rather than undoing the fault.
#      online-boutique-packaged only — online-boutique is unaffected.
#
#   2. TLS outage — deletes the frontend-tls Secret in online-boutique.
#      cert-manager's gateway-shim notices and reissues it automatically,
#      but external HTTPS access breaks for the reissuance window.
#      online-boutique only, edge-wide.
#
#   3. Chaos Mesh fault — PodChaos pod-kill on paymentservice in
#      online-boutique. Narrow: only the payment step of checkout fails,
#      self-terminates after `duration`.
#
# Recovery for each is real work, not just "wait it out" — see this
# module's README's Troubleshooting section AFTER you've written your
# postmortem, not before.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "${MODULE_DIR}/../.." && pwd)"
GENERATED_DIR="${MODULE_DIR}/generated"
DRILL_BRANCH="capstone-drill"
ROOT_REVISION_FILE="${GENERATED_DIR}/root-app-target-revision.before"

# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/lab.env" ] && source "${REPO_ROOT}/lab.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

if ! kubectl get application online-boutique-packaged -n argocd &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} ArgoCD Application online-boutique-packaged not found. Complete Module 11 first." >&2
  exit 1
fi
if ! kubectl get application root-app -n argocd &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} ArgoCD Application root-app not found. Complete Module 11 first." >&2
  exit 1
fi
if ! kubectl get secret frontend-tls -n online-boutique &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Secret frontend-tls not found in online-boutique. Complete Module 04 first." >&2
  exit 1
fi
if ! kubectl get crd podchaos.chaos-mesh.org &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Chaos Mesh CRDs not found. Complete Module 18 first." >&2
  exit 1
fi
if ! command -v yq &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} yq not found. Complete Module 00 first." >&2
  exit 1
fi

echo ""
echo "================================================================"
echo "  Module 99 — Capstone — INCIDENT INJECTION"
echo "================================================================"
echo ""
log_warn "This pushes a commit to a NEW 'capstone-drill' branch on your"
log_warn "GitOps remote (never main), repoints root-app at it, deletes the"
log_warn "frontend-tls Secret, and applies a Chaos Mesh PodChaos object."
log_warn "Only run this if you are the one deliberately triggering the drill."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

mkdir -p "$GENERATED_DIR"

WORKTREE_DIR=""
DRILL_PUSHED=false
cleanup_failed_injection() {
  if [[ -n "${WORKTREE_DIR}" && -d "${WORKTREE_DIR}" ]]; then
    git -C "$REPO_ROOT" worktree remove "$WORKTREE_DIR" --force &>/dev/null || true
  fi
  git -C "$REPO_ROOT" worktree prune &>/dev/null || true
  if [[ "${DRILL_PUSHED}" != "true" ]]; then
    git -C "$REPO_ROOT" branch -D "$DRILL_BRANCH" &>/dev/null || true
  fi
}
trap cleanup_failed_injection EXIT

# --- Vector 1: GitOps drift, isolated to a throwaway branch ---
log_info "[1/3] Preparing GitOps drift on a dedicated branch (main stays untouched)..."

ROOT_REVISION="$(kubectl get application root-app -n argocd -o jsonpath='{.spec.source.targetRevision}')"
if [[ -z "$ROOT_REVISION" || "$ROOT_REVISION" == "$DRILL_BRANCH" ]]; then
  echo -e "${RED}[ERROR]${NC} root-app has an invalid or already-active drill revision ('${ROOT_REVISION:-<none>}'). Run destroy.sh first." >&2
  exit 1
fi
printf '%s\n' "$ROOT_REVISION" > "$ROOT_REVISION_FILE"

if git -C "$REPO_ROOT" ls-remote --exit-code --heads origin "$DRILL_BRANCH" &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Remote branch ${DRILL_BRANCH} already exists. Run destroy.sh before injecting another drill." >&2
  exit 1
fi

git -C "$REPO_ROOT" fetch origin "$ROOT_REVISION" &>/dev/null
git -C "$REPO_ROOT" branch -D "$DRILL_BRANCH" &>/dev/null || true

WORKTREE_DIR="$(mktemp -d)"
git -C "$REPO_ROOT" worktree add -q -b "$DRILL_BRANCH" "$WORKTREE_DIR" "origin/${ROOT_REVISION}"

yq eval '(.services[] | select(.name == "productcatalogservice") | .resources.limits.memory) = "16Mi"' \
  -i "${WORKTREE_DIR}/charts/online-boutique/values.yaml"
yq eval '(.spec.source.targetRevision) = "capstone-drill"' \
  -i "${WORKTREE_DIR}/gitops/apps/online-boutique-packaged.yaml"

git -C "$WORKTREE_DIR" add charts/online-boutique/values.yaml gitops/apps/online-boutique-packaged.yaml
git -C "$WORKTREE_DIR" -c user.email="capstone-drill@localhost" -c user.name="Capstone Drill" \
  commit -q -m "perf: reduce productcatalogservice memory footprint"
git -C "$WORKTREE_DIR" push -q origin "$DRILL_BRANCH"
DRILL_PUSHED=true

git -C "$REPO_ROOT" worktree remove "$WORKTREE_DIR" --force
git -C "$REPO_ROOT" worktree prune
WORKTREE_DIR=""

kubectl patch application root-app -n argocd --type merge \
  -p "{\"spec\":{\"source\":{\"targetRevision\":\"${DRILL_BRANCH}\"}}}" &>/dev/null
for _ in $(seq 1 30); do
  CHILD_REVISION="$(kubectl get application online-boutique-packaged -n argocd -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null)"
  [[ "$CHILD_REVISION" == "$DRILL_BRANCH" ]] && break
  sleep 2
done
if [[ "${CHILD_REVISION:-}" != "$DRILL_BRANCH" ]]; then
  echo -e "${RED}[ERROR]${NC} root-app did not reconcile online-boutique-packaged to ${DRILL_BRANCH}. Run destroy.sh to restore ${ROOT_REVISION}." >&2
  exit 1
fi
log_ok "[1/3] root-app and online-boutique-packaged now sync from ${DRILL_BRANCH}"

# --- Vector 2: TLS outage ---
log_info "[2/3] Deleting frontend-tls Secret..."
kubectl delete secret frontend-tls -n online-boutique &>/dev/null
log_ok "[2/3] frontend-tls deleted — cert-manager will reissue, but not instantly"

# --- Vector 3: Chaos Mesh fault ---
log_info "[3/3] Applying PodChaos on paymentservice..."
kubectl apply -f "${MODULE_DIR}/manifests/podchaos-paymentservice-kill.yaml" &>/dev/null
log_ok "[3/3] Fault applied"
trap - EXIT

echo ""
echo "================================================================"
echo "  Incident injected. The responder starts now."
echo "================================================================"
echo ""
