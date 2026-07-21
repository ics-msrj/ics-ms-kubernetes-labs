#!/usr/bin/env bash

set -uo pipefail

FAIL=0
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

check_version() {
  local name="$1" minimum="$2" got="$3"
  if [[ -z "${got}" ]]; then
    printf "  %-12s FAIL  (not found)\n" "${name}"
    FAIL=1
  elif version_ge "${got}" "${minimum}"; then
    printf "  %-12s PASS  (%s, minimum %s)\n" "${name}" "${got}" "${minimum}"
  else
    printf "  %-12s FAIL  (found %s, need >= %s)\n" "${name}" "${got}" "${minimum}"
    FAIL=1
  fi
}

check_present() {
  local name="$1" required="$2"
  if command -v "${name}" >/dev/null 2>&1; then
    printf "  %-12s PASS  (present)\n" "${name}"
  elif [[ "${required}" == "required" ]]; then
    printf "  %-12s FAIL  (not found)\n" "${name}"
    FAIL=1
  else
    printf "  %-12s SKIP  (optional, not found)\n" "${name}"
  fi
}

echo "== ACK Platform Track - Prerequisites verification =="
echo
echo "Required tools:"
check_version kubectl 1.28.0 "$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"v[0-9.]*"' | head -1 | grep -o '[0-9][0-9.]*')"
check_version helm 3.14.0 "$(helm version --short 2>/dev/null | grep -o 'v[0-9][0-9.]*' | head -1 | tr -d v)"
check_version git 2.30.0 "$(git --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1)"
check_version jq 1.6 "$(jq --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1)"
check_present aliyun required
check_present terraform optional

echo
echo "Alibaba Cloud CLI profile:"
if aliyun configure list 2>/dev/null | grep -q '^'; then
  printf "  %-12s PASS  (run 'aliyun configure list' to confirm the selected profile)\n" "aliyun"
else
  printf "  %-12s FAIL  (configure an Alibaba Cloud CLI profile first)\n" "aliyun"
  FAIL=1
fi

echo
echo "ACK configuration:"
if [[ -f "platforms/ack/config/ack.env" ]]; then
  printf "  %-12s PASS  (found)\n" "ack.env"
else
  printf "  %-12s FAIL  (run: cp platforms/ack/config/ack.env.example platforms/ack/config/ack.env)\n" "ack.env"
  FAIL=1
fi

echo
if [[ "${FAIL}" -eq 0 ]]; then
  echo "All checks passed. Continue with platforms/ack/README.md."
else
  echo "One or more checks failed. Fix the FAILs above, then re-run this script." >&2
fi
exit "${FAIL}"
