#!/usr/bin/env bash
# =============================================================================
# GKE Platform Track — check-prerequisites.sh (Module 00 equivalent)
#
# Same idea as modules/00-prerequisites/scripts/verify.sh and the AKS
# track's own check-prerequisites.sh — check everything up front, not one
# failure at a time — with the one real substitution this track needs:
# `gcloud` replaces `ssh`/`az` (GKE operation never SSHes to a node),
# everything else (kubectl/helm/jq/git) is identical to the native
# track's own requirements.
# =============================================================================
set -uo pipefail

FAIL=0

version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

check_version() {
  local name="$1" min="$2" got="$3"
  if [ -z "$got" ]; then
    printf "  %-12s FAIL  (not found)\n" "$name"
    FAIL=1
  elif version_ge "$got" "$min"; then
    printf "  %-12s PASS  (%s, minimum %s)\n" "$name" "$got" "$min"
  else
    printf "  %-12s FAIL  (found %s, need >= %s)\n" "$name" "$got" "$min"
    FAIL=1
  fi
}

check_present() {
  local name="$1" required="$2"
  if command -v "$name" >/dev/null 2>&1; then
    printf "  %-12s PASS  (present)\n" "$name"
  elif [ "$required" = "required" ]; then
    printf "  %-12s FAIL  (not found)\n" "$name"
    FAIL=1
  else
    printf "  %-12s SKIP  (optional, not found)\n" "$name"
  fi
}

echo "== GKE Platform Track — Prerequisites verification =="
echo

echo "Required tools:"
check_version kubectl 1.28.0 "$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"v[0-9.]*"' | head -1 | grep -o '[0-9][0-9.]*')"
check_version helm    3.14.0 "$(helm version --short 2>/dev/null | grep -o 'v[0-9][0-9.]*' | head -1 | tr -d v)"
check_version git     2.30.0 "$(git --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1)"
check_version jq      1.6    "$(jq --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1)"
check_present gcloud required
check_present terraform optional

echo
echo "GCP session:"
if gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
  ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
  printf "  %-12s PASS  (logged in: %s)\n" "gcloud auth" "${ACCOUNT}"
else
  printf "  %-12s FAIL  (run: gcloud auth login)\n" "gcloud auth"
  FAIL=1
fi
if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  printf "  %-12s PASS  (found)\n" "adc"
else
  printf "  %-12s FAIL  (run: gcloud auth application-default login — needed by Terraform, not just gcloud/kubectl)\n" "adc"
  FAIL=1
fi

echo
echo "Lab configuration:"
if [ -f "platforms/gke/config/gke.env" ]; then
  printf "  %-12s PASS  (found)\n" "gke.env"
else
  printf "  %-12s FAIL  (run: cp platforms/gke/config/gke.env.example platforms/gke/config/gke.env)\n" "gke.env"
  FAIL=1
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All checks passed. Continue with platforms/gke/README.md's Cluster/Foundation steps."
else
  echo "One or more checks failed. Fix the FAILs above, then re-run this script." >&2
fi
exit "$FAIL"
