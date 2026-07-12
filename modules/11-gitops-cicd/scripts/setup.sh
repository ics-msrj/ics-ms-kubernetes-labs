#!/bin/bash
# =============================================================================
# Module 11 — GitOps & CI/CD — setup.sh
#
# Two-phase, because this repo has to reference its own remote URL:
#   Phase 1 (first run): substitutes GITOPS_REPO_URL into gitops/apps/*.yaml
#     (files ArgoCD reads directly from Git — they can't use the sed-into-a-
#     pipe trick every other module's templated manifests use) and stops,
#     asking you to commit and push that change.
#   Phase 2 (after you've pushed): installs ArgoCD, exposes it via the
#     Gateway, and applies the App-of-Apps root — from that point on, ArgoCD
#     reconciles the two child apps from Git, not this script.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "${MODULE_DIR}/../.." && pwd)"

ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.1.3}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/lab.env" ] && source "${REPO_ROOT}/lab.env"
APP_DOMAIN="${APP_DOMAIN:-}"
TLS_ISSUER="${TLS_ISSUER:-letsencrypt-staging}"
GITOPS_REPO_URL="${GITOPS_REPO_URL:-}"
GITOPS_REPO_REVISION="${GITOPS_REPO_REVISION:-main}"
GRAFANA_DOMAIN="grafana.${APP_DOMAIN}"
ARGOCD_DOMAIN="argocd.${APP_DOMAIN}"

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} kubectl cannot reach a cluster. Complete Module 01 first." >&2
  exit 1
fi
if [[ ! -d "${REPO_ROOT}/charts/online-boutique" ]] || [[ ! -f "${REPO_ROOT}/kustomize/overlays/dev/kustomization.yaml" ]]; then
  echo -e "${RED}[ERROR]${NC} charts/online-boutique or kustomize/overlays/dev missing. Complete Module 10 first." >&2
  exit 1
fi
if [[ -z "$GITOPS_REPO_URL" || "$GITOPS_REPO_URL" == *"<you>"* ]]; then
  echo -e "${RED}[ERROR]${NC} Set a real GITOPS_REPO_URL in lab.env — see its comment for the expected GitLab (primary) / GitHub (mirror) setup." >&2
  exit 1
fi

echo ""
echo "============================================================"
echo "  Module 11 — GitOps & CI/CD — Setup"
echo "============================================================"
echo ""

# --- Phase 1: does gitops/apps/ still have the placeholder? ---
if grep -q "__GITOPS_REPO_URL__" "${REPO_ROOT}/gitops/apps/"*.yaml 2>/dev/null; then
  log_info "Substituting GITOPS_REPO_URL into gitops/apps/*.yaml (ArgoCD reads these directly from Git)..."
  for f in "${REPO_ROOT}/gitops/apps/"*.yaml; do
    sed -i \
      -e "s|__GITOPS_REPO_URL__|${GITOPS_REPO_URL}|g" \
      -e "s|__GITOPS_REPO_REVISION__|${GITOPS_REPO_REVISION}|g" \
      "$f"
  done
  log_ok "Updated $(ls "${REPO_ROOT}/gitops/apps/"*.yaml | wc -l) file(s)"
  echo ""
  echo "============================================================"
  echo "  PAUSE — this needs to reach your Git remote before continuing."
  echo ""
  echo "  git -C '${REPO_ROOT}' add gitops/apps/"
  echo "  git -C '${REPO_ROOT}' commit -m 'gitops: point Applications at this repo'"
  echo "  git -C '${REPO_ROOT}' push origin ${GITOPS_REPO_REVISION}"
  echo ""
  echo "  Then re-run this script to install ArgoCD and apply the root app."
  echo "============================================================"
  echo ""
  exit 0
fi

log_info "Checking ${GITOPS_REPO_URL} is reachable..."
git ls-remote "$GITOPS_REPO_URL" &>/dev/null \
  && log_ok "Remote reachable" \
  || { echo -e "${RED}[ERROR]${NC} Could not reach ${GITOPS_REPO_URL} — push your commit first (see Phase 1 instructions above, or this repo's README)." >&2; exit 1; }

# --- Phase 2: install ArgoCD ---
log_info "Generating and bcrypt-hashing a random ArgoCD admin password..."
ARGOCD_PASSWORD="$(openssl rand -hex 12)"
ARGOCD_BCRYPT_HASH=$(kubectl run argocd-htpasswd-$$ --image=httpd:2.4.62-alpine --restart=Never --rm -q -i --timeout=30s \
  --overrides="{\"spec\":{\"containers\":[{\"name\":\"argocd-htpasswd-$$\",\"image\":\"httpd:2.4.62-alpine\",\"resources\":{\"requests\":{\"cpu\":\"10m\",\"memory\":\"16Mi\"},\"limits\":{\"cpu\":\"50m\",\"memory\":\"32Mi\"}}}]}}" -- \
  htpasswd -nbBC 10 "" "${ARGOCD_PASSWORD}" </dev/null 2>/dev/null | tr -d ':\n' | sed 's/\$2y/\$2a/')

if [[ -z "$ARGOCD_BCRYPT_HASH" ]]; then
  echo -e "${RED}[ERROR]${NC} Failed to generate the bcrypt hash — check the ephemeral httpd pod can run in this cluster." >&2
  exit 1
fi

log_info "Installing ArgoCD v${ARGOCD_CHART_VERSION}..."
helm repo add argo https://argoproj.github.io/argo-helm &>/dev/null || true
helm repo update argo &>/dev/null
helm upgrade --install argocd argo/argo-cd \
  --version "${ARGOCD_CHART_VERSION}" \
  --namespace argocd --create-namespace \
  -f "${MODULE_DIR}/manifests/argocd-values.yaml" \
  --set-string configs.secret.argocdServerAdminPassword="${ARGOCD_BCRYPT_HASH}" \
  --wait --timeout 5m
log_ok "ArgoCD ready"

# --- Expose via the Gateway ---
log_info "Extending the Gateway with an argocd.${APP_DOMAIN} listener..."
sed -e "s|__TLS_ISSUER__|${TLS_ISSUER}|g" -e "s|__GRAFANA_DOMAIN__|${GRAFANA_DOMAIN}|g" -e "s|__ARGOCD_DOMAIN__|${ARGOCD_DOMAIN}|g" \
  "${MODULE_DIR}/manifests/gateway-argocd-listener.yaml" | kubectl apply -f -
sed "s|__ARGOCD_DOMAIN__|${ARGOCD_DOMAIN}|g" "${MODULE_DIR}/manifests/httproute-argocd.yaml" | kubectl apply -f -
kubectl wait certificate argocd-tls -n online-boutique --for=condition=Ready --timeout=300s \
  || log_warn "Certificate not Ready yet — check: kubectl describe certificate argocd-tls -n online-boutique"

# --- App-of-Apps ---
log_info "Applying the App-of-Apps root..."
sed -e "s|__GITOPS_REPO_URL__|${GITOPS_REPO_URL}|g" -e "s|__GITOPS_REPO_REVISION__|${GITOPS_REPO_REVISION}|g" \
  "${REPO_ROOT}/gitops/root-app.yaml" | kubectl apply -f -

log_info "Waiting for the App-of-Apps to sync (this can take a couple of minutes)..."
for app in root-app online-boutique-packaged online-boutique-dev; do
  for i in $(seq 1 30); do
    kubectl get application "$app" -n argocd &>/dev/null && break
    sleep 5
  done
done
kubectl wait application root-app online-boutique-packaged online-boutique-dev -n argocd \
  --for=jsonpath='{.status.sync.status}'=Synced --timeout=180s \
  || log_warn "Not all Applications synced yet — check: kubectl get application -n argocd"

echo ""
echo "============================================================"
echo "  Setup complete. Run: bash modules/11-gitops-cicd/scripts/verify.sh"
echo ""
echo "  ArgoCD:  https://${ARGOCD_DOMAIN}"
echo "  Login:   admin / ${ARGOCD_PASSWORD}"
echo "  (save this now — it's only ever printed here, never stored in Git)"
echo "============================================================"
echo ""
unset ARGOCD_PASSWORD ARGOCD_BCRYPT_HASH
