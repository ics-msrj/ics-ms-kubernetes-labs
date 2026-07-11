#!/usr/bin/env bash
# Module 00 — Prerequisites — setup.sh
# Installs any missing required tools: kubectl, helm, kustomize, yq, jq.
# Checks (but does not install) git and ssh. k9s is installed if missing but optional.
# Idempotent: safe to re-run: already-present tools are left untouched.
set -euo pipefail

SCRATCH_DIR="$(mktemp -d /tmp/k8s-lab-00-prereqs.XXXXXX)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) ARCH="amd64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH_RAW" >&2; exit 1 ;;
esac

INSTALL_DIR="/usr/local/bin"

have() { command -v "$1" >/dev/null 2>&1; }

install_kubectl() {
  have kubectl && { echo "kubectl already installed, skipping."; return; }
  echo "Installing kubectl..."
  local version
  version="$(curl -Ls https://dl.k8s.io/release/stable.txt)"
  curl -Lo "$SCRATCH_DIR/kubectl" "https://dl.k8s.io/release/${version}/bin/${OS}/${ARCH}/kubectl"
  chmod +x "$SCRATCH_DIR/kubectl"
  sudo mv "$SCRATCH_DIR/kubectl" "$INSTALL_DIR/kubectl"
}

install_helm() {
  have helm && { echo "helm already installed, skipping."; return; }
  echo "Installing helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$SCRATCH_DIR/get-helm-3.sh"
  chmod +x "$SCRATCH_DIR/get-helm-3.sh"
  "$SCRATCH_DIR/get-helm-3.sh"
}

install_kustomize() {
  have kustomize && { echo "kustomize already installed, skipping."; return; }
  echo "Installing kustomize..."
  curl -fsSL "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash -s -- "$SCRATCH_DIR"
  sudo mv "$SCRATCH_DIR/kustomize" "$INSTALL_DIR/kustomize"
}

install_yq() {
  have yq && { echo "yq already installed, skipping."; return; }
  echo "Installing yq..."
  curl -Lo "$SCRATCH_DIR/yq" "https://github.com/mikefarah/yq/releases/latest/download/yq_${OS}_${ARCH}"
  chmod +x "$SCRATCH_DIR/yq"
  sudo mv "$SCRATCH_DIR/yq" "$INSTALL_DIR/yq"
}

install_jq() {
  have jq && { echo "jq already installed, skipping."; return; }
  echo "Installing jq..."
  if [ "$OS" = "darwin" ] && have brew; then
    brew install jq
  elif have apt-get; then
    sudo apt-get update -qq && sudo apt-get install -y jq
  else
    echo "No supported package manager found for jq — install it manually: https://jqlang.org/download/" >&2
    return 1
  fi
}

install_k9s_optional() {
  have k9s && { echo "k9s already installed, skipping."; return; }
  echo "Installing k9s (recommended, optional)..."
  if [ "$OS" = "darwin" ] && have brew; then
    brew install derailed/k9s/k9s || echo "k9s install failed — optional, continuing." >&2
    return
  fi
  local tarball="k9s_${OS^}_${ARCH}.tar.gz"
  if curl -fsSL -o "$SCRATCH_DIR/k9s.tar.gz" "https://github.com/derailed/k9s/releases/latest/download/${tarball}"; then
    tar -xzf "$SCRATCH_DIR/k9s.tar.gz" -C "$SCRATCH_DIR" k9s
    sudo mv "$SCRATCH_DIR/k9s" "$INSTALL_DIR/k9s"
  else
    echo "k9s install failed — optional, continuing." >&2
  fi
}

check_only() {
  local tool="$1" install_hint="$2"
  if have "$tool"; then
    echo "$tool already present."
  else
    echo "WARNING: $tool not found. $install_hint" >&2
  fi
}

echo "== Module 00 — installing/checking prerequisites for OS=$OS ARCH=$ARCH =="
install_kubectl
install_helm
install_kustomize
install_yq
install_jq
install_k9s_optional
check_only git "Install via your OS package manager (e.g. apt install git / brew install git)."
check_only ssh "Install an OpenSSH client via your OS package manager."

echo
echo "Done. Run: bash modules/00-prerequisites/scripts/verify.sh"
