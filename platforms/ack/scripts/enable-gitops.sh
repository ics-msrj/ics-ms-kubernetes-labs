#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

APP_DIR="${REPO_ROOT}/gitops/apps/ack"
SEALED_DIR="${REPO_ROOT}/gitops/sealed-secrets/ack"

require_command kubectl
require_command helm
require_command git
require_command kubeseal
require_storage_config
require_gitops_config
require_cluster

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

if grep -q '__ACK_STORAGE_CLASS__\|__GITOPS_REPO_URL__' "${APP_DIR}"/*.yaml; then
  log_info "Generating ACK-specific SealedSecrets from the existing Module 10 credentials..."
  for namespace in online-boutique-packaged online-boutique-dev; do
    kubectl get secret redis-cart-credentials -n "${namespace}" >/dev/null \
      || die "redis-cart-credentials is missing in ${namespace}; run enable-packages first."
    # Module 10 created this Secret before GitOps. Mark it as controller-managed
    # before applying the SealedSecret so ownership can transition without
    # changing the existing password.
    kubectl annotate secret redis-cart-credentials -n "${namespace}" \
      sealedsecrets.bitnami.com/managed="true" --overwrite
    mkdir -p "${SEALED_DIR}/${namespace}"
    kubectl get secret redis-cart-credentials -n "${namespace}" -o json \
      | kubeseal --format=yaml --controller-namespace=kube-system --controller-name=sealed-secrets-controller \
      > "${SEALED_DIR}/${namespace}/redis-cart-sealedsecret.yaml"
  done

  repo_url_escaped="$(escape_sed_replacement "${ACK_GITOPS_REPO_URL}")"
  revision_escaped="$(escape_sed_replacement "${ACK_GITOPS_REPO_REVISION}")"
  storage_class_escaped="$(escape_sed_replacement "${ACK_STORAGE_CLASS}")"
  disk_size_escaped="$(escape_sed_replacement "${ACK_REDIS_DISK_SIZE}")"
  label_key_escaped="$(escape_sed_replacement "${ACK_WORKLOAD_LABEL_KEY}")"
  label_value_escaped="$(escape_sed_replacement "${ACK_WORKLOAD_LABEL_VALUE}")"
  sed -i \
    -e "s|__GITOPS_REPO_URL__|${repo_url_escaped}|g" \
    -e "s|__GITOPS_REPO_REVISION__|${revision_escaped}|g" \
    -e "s|__ACK_STORAGE_CLASS__|${storage_class_escaped}|g" \
    -e "s|__ACK_REDIS_DISK_SIZE__|${disk_size_escaped}|g" \
    -e "s|__ACK_WORKLOAD_LABEL_KEY__|${label_key_escaped}|g" \
    -e "s|__ACK_WORKLOAD_LABEL_VALUE__|${label_value_escaped}|g" \
    "${APP_DIR}"/*.yaml

  log_ok "ACK GitOps sources were prepared with encrypted, cluster-specific credentials."
  echo ""
  echo "================================================================"
  echo "  PAUSE — ArgoCD must fetch these files from Git."
  echo ""
  echo "  git add gitops/apps/ack gitops/sealed-secrets/ack"
  echo "  git commit -m 'gitops: add ACK applications'"
  echo "  git push origin ${ACK_GITOPS_REPO_REVISION}"
  echo ""
  echo "  In Cloudflare Zero Trust, add public hostname:"
  echo "  https://${ACK_ARGOCD_HOSTNAME} -> http://argocd-server.argocd.svc.cluster.local:80"
  echo ""
  echo "  Then re-run: bash platforms/ack/scripts/ack-track.sh enable-gitops"
  echo "================================================================"
  exit 0
fi

APP_DOMAIN_OVERRIDE="${APP_DOMAIN:-}" \
ARGOCD_DOMAIN_OVERRIDE="${ACK_ARGOCD_HOSTNAME}" \
ARGOCD_EXPOSURE="cloudflare-tunnel" \
GITOPS_REPO_URL_OVERRIDE="${ACK_GITOPS_REPO_URL}" \
GITOPS_REPO_REVISION_OVERRIDE="${ACK_GITOPS_REPO_REVISION}" \
GITOPS_APPS_PATH="gitops/apps/ack" \
GITOPS_COMMIT_PATHS="gitops/apps/ack gitops/sealed-secrets/ack" \
  bash "${REPO_ROOT}/modules/11-gitops-cicd/scripts/setup.sh"
