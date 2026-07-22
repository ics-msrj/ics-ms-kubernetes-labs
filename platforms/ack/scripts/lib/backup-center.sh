#!/usr/bin/env bash

BACKUP_CENTER_MANIFEST_DIR="${PLATFORM_DIR}/manifests/backup-center"
BACKUP_CENTER_NAMESPACE="csdr"

require_backup_center() {
  require_command kubectl
  require_config
  require_storage_config
  require_backup_config
  require_cluster

  kubectl get namespace "${BACKUP_CENTER_NAMESPACE}" >/dev/null \
    || die "Backup Center namespace csdr was not found. Install migrate-controller and authorize its RAM role in the ACK console first."
  kubectl get crd applicationbackups.csdr.alibabacloud.com >/dev/null \
    || die "ApplicationBackup CRD was not found. Verify the migrate-controller installation."
  kubectl get deployment csdr-controller -n "${BACKUP_CENTER_NAMESPACE}" >/dev/null \
    || die "csdr-controller deployment was not found. Verify the migrate-controller installation."
  kubectl get deployment csdr-velero -n "${BACKUP_CENTER_NAMESPACE}" >/dev/null \
    || die "csdr-velero deployment was not found. Verify the migrate-controller installation."
}

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

render_backup_center_manifest() {
  local template="$1"
  local backup_name="${2:-__ACK_BACKUP_NAME__}"
  local restore_name="${3:-__ACK_RESTORE_NAME__}"
  local region bucket location prefix ttl source_namespace restore_namespace

  region="$(escape_sed_replacement "${ACK_REGION}")"
  bucket="$(escape_sed_replacement "${ACK_BACKUP_BUCKET}")"
  location="$(escape_sed_replacement "${ACK_BACKUP_LOCATION}")"
  prefix="$(escape_sed_replacement "${ACK_BACKUP_PREFIX}")"
  ttl="$(escape_sed_replacement "${ACK_BACKUP_TTL}")"
  source_namespace="$(escape_sed_replacement "${ACK_BACKUP_NAMESPACE}")"
  restore_namespace="$(escape_sed_replacement "${ACK_RESTORE_NAMESPACE}")"
  backup_name="$(escape_sed_replacement "${backup_name}")"
  restore_name="$(escape_sed_replacement "${restore_name}")"

  sed \
    -e "s|__ACK_REGION__|${region}|g" \
    -e "s|__ACK_BACKUP_BUCKET__|${bucket}|g" \
    -e "s|__ACK_BACKUP_LOCATION__|${location}|g" \
    -e "s|__ACK_BACKUP_PREFIX__|${prefix}|g" \
    -e "s|__ACK_BACKUP_TTL__|${ttl}|g" \
    -e "s|__ACK_BACKUP_NAMESPACE__|${source_namespace}|g" \
    -e "s|__ACK_RESTORE_NAMESPACE__|${restore_namespace}|g" \
    -e "s|__ACK_BACKUP_NAME__|${backup_name}|g" \
    -e "s|__ACK_RESTORE_NAME__|${restore_name}|g" \
    "${template}"
}

wait_for_backup_center_phase() {
  local resource="$1"
  local name="$2"
  local phase=""
  local elapsed=0

  while (( elapsed < ACK_BACKUP_WAIT_TIMEOUT_SECONDS )); do
    phase="$(kubectl get "${resource}" "${name}" -n "${BACKUP_CENTER_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "${phase}" in
      Completed)
        log_ok "${resource}/${name} completed"
        return 0
        ;;
      Failed|PartiallyFailed)
        kubectl describe "${resource}" "${name}" -n "${BACKUP_CENTER_NAMESPACE}" >&2 || true
        die "${resource}/${name} phase is ${phase}."
        ;;
    esac
    sleep 10
    elapsed=$((elapsed + 10))
  done

  kubectl describe "${resource}" "${name}" -n "${BACKUP_CENTER_NAMESPACE}" >&2 || true
  die "Timed out waiting for ${resource}/${name} after ${ACK_BACKUP_WAIT_TIMEOUT_SECONDS}s."
}
