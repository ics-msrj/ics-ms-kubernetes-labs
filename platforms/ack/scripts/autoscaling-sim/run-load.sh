#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

scenario="${1:?Usage: run-load.sh <baseline|gradual|spike>}"
case "${scenario}" in
  baseline) script_name="vpa-baseline.js" ;;
  gradual) script_name="gradual-ramp.js" ;;
  spike) script_name="sudden-spike.js" ;;
  *) die "Scenario must be baseline, gradual, or spike." ;;
esac

require_command kubectl
require_sim_config
require_cluster
kubectl -n "${NAMESPACE}" get deployment autoscale-target >/dev/null || die "Run apply first."
if [[ "${scenario}" != "baseline" ]]; then
  kubectl -n "${NAMESPACE}" get hpa autoscale-target >/dev/null \
    || die "Run vpa-check, review the recommendation, and enable-hpa before traffic profiles."
fi

new_artifact_dir "${scenario}"
job="k6-${scenario}-$(date -u +%H%M%S)"
cleanup_job() { kubectl -n "${NAMESPACE}" delete job "${job}" --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup_job EXIT INT TERM

"${SCRIPT_DIR}/collect-evidence.sh" "${scenario}-before" "${RUN_ARTIFACT_DIR}/before"
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: k6-runner
    app.kubernetes.io/part-of: ack-autoscale-simulation
    app.kubernetes.io/component: ${scenario}-load
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: k6-runner
        app.kubernetes.io/part-of: ack-autoscale-simulation
      annotations:
        cluster-autoscaler.kubernetes.io/safe-to-evict: "false"
    spec:
      serviceAccountName: k6-runner
      automountServiceAccountToken: false
      restartPolicy: Never
      nodeSelector:
        ${ACK_WORKLOAD_LABEL_KEY}: ${ACK_WORKLOAD_LABEL_VALUE}
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: k6
          image: grafana/k6:0.54.0
          imagePullPolicy: IfNotPresent
          args:
            - run
            - --summary-export=/tmp/summary.json
            - /scripts/${script_name}
          env:
            - name: TARGET_URL
              value: http://autoscale-target.${NAMESPACE}.svc:8080
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 12345
            runAsGroup: 12345
          volumeMounts:
            - name: scripts
              mountPath: /scripts
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: scripts
          configMap:
            name: k6-load-scripts
            defaultMode: 0444
        - name: tmp
          emptyDir: {}
EOF

log_info "Running ${scenario} profile as Job/${job}; evidence: ${RUN_ARTIFACT_DIR}"
kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${job}" --timeout=50m || {
  kubectl -n "${NAMESPACE}" logs "job/${job}" --all-containers >"${RUN_ARTIFACT_DIR}/k6.log" 2>&1 || true
  "${SCRIPT_DIR}/collect-evidence.sh" "${scenario}-failed" "${RUN_ARTIFACT_DIR}/after"
  die "Load job did not complete successfully. Evidence was retained."
}
kubectl -n "${NAMESPACE}" logs "job/${job}" --all-containers >"${RUN_ARTIFACT_DIR}/k6.log"
"${SCRIPT_DIR}/collect-evidence.sh" "${scenario}-after" "${RUN_ARTIFACT_DIR}/after"
log_ok "${scenario} profile completed. Review ${RUN_ARTIFACT_DIR}/k6.log and evidence snapshots."
