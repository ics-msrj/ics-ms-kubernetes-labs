#!/usr/bin/env bash
# Module 00 — Prerequisites — destroy.sh
# This module provisions nothing on a cluster or VM, so there is nothing to
# tear down. It only clears any leftover scratch directories setup.sh may
# have failed to clean up (setup.sh normally removes these itself on exit).
set -uo pipefail

shopt -s nullglob
leftover=(/tmp/k8s-lab-00-prereqs.*)
if [ "${#leftover[@]}" -eq 0 ]; then
  echo "Nothing to clean up."
else
  rm -rf "${leftover[@]}"
  echo "Removed leftover scratch directories: ${leftover[*]}"
fi

echo "Installed CLI tools (kubectl, helm, kustomize, yq, jq, k9s) were left in place — this script does not uninstall them."
