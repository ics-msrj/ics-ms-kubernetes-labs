#!/bin/bash
# =============================================================================
# Module 01 — Worker Node Setup Script
#
# Run this ON each worker VM (Ubuntu 22.04/24.04):
#   scp modules/01-cluster-setup/scripts/setup-worker.sh <user>@<WORKER_IP>:/tmp/
#   ssh <user>@<WORKER_IP>
#   sudo bash /tmp/setup-worker.sh
#
# Prerequisites:
#   - setup-control-plane.sh must be completed first
#   - /tmp/join-command.sh copied from the control plane onto this VM
# =============================================================================

set -euo pipefail

K8S_VERSION="${K8S_VERSION:-1.34}"
K8S_PATCH_VERSION="${K8S_PATCH_VERSION:-1.34.9}"
K8S_PACKAGE_VERSION="${K8S_PACKAGE_VERSION:-${K8S_PATCH_VERSION}-1.1}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $(date '+%H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_section() { echo -e "\n${BLUE}>>> $* <<<${NC}"; }

NODE_NAME="${NODE_NAME:-$(hostname -s)}"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "Run this script as root, for example: sudo bash /tmp/setup-worker.sh"
    exit 1
  fi
}

# =============================================================================
# Step 1: System prerequisites (identical to control-plane)
# =============================================================================
step1_system_prereqs() {
  log_section "Step 1: System prerequisites"

  swapoff -a
  sed -i '/swap/d' /etc/fstab
  log_ok "Swap disabled"

  cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter
  log_ok "Kernel modules loaded"

  cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system -q
  log_ok "sysctl params applied"

  apt-get update -qq
  apt-get install -y -qq \
    apt-transport-https ca-certificates curl gnupg lsb-release \
    software-properties-common wget jq
  log_ok "Base packages installed"
}

# =============================================================================
# Step 2: Install containerd (identical to control-plane)
# =============================================================================
step2_containerd() {
  log_section "Step 2: Install containerd runtime"

  if systemctl is-active containerd &>/dev/null; then
    log_info "containerd already running — skipping"
    return
  fi

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq containerd.io

  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

  systemctl enable --now containerd
  systemctl restart containerd
  log_ok "containerd configured with SystemdCgroup=true and started"
}

# =============================================================================
# Step 3: Install kubeadm, kubelet (kubectl optional on workers)
# =============================================================================
step3_kubeadm() {
  log_section "Step 3: Install kubeadm and kubelet"

  if command -v kubeadm &>/dev/null; then
    log_info "kubeadm already installed — skipping"
    return
  fi

  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
    https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

  apt-get update -qq
  apt-get install -y \
    "kubelet=${K8S_PACKAGE_VERSION}" \
    "kubeadm=${K8S_PACKAGE_VERSION}" \
    "kubectl=${K8S_PACKAGE_VERSION}"

  apt-mark hold kubelet kubeadm kubectl
  systemctl enable kubelet
  log_ok "kubeadm, kubelet, kubectl installed and pinned"
}

# =============================================================================
# Step 4: Join the cluster
# =============================================================================
step4_join_cluster() {
  log_section "Step 4: Join cluster"

  if [ -f /etc/kubernetes/kubelet.conf ]; then
    log_info "Node already joined (kubelet.conf exists) — skipping"
    return
  fi

  if [ ! -f /tmp/join-command.sh ]; then
    log_warn "/tmp/join-command.sh not found."
    log_warn "Copy it from the control-plane before running this script:"
    log_warn "  scp <user>@<CONTROL_IP>:/tmp/join-command.sh /tmp/"
    log_warn "  Then re-run: sudo bash /tmp/setup-worker.sh"
    exit 1
  fi

  log_info "Using join command from /tmp/join-command.sh"
  log_info "Node name: ${NODE_NAME}"
  log_info "Node IP: ${NODE_IP}"
  echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" > /etc/default/kubelet
  systemctl daemon-reload
  bash /tmp/join-command.sh --node-name "${NODE_NAME}"

  log_ok "Node ${NODE_NAME} joined the cluster"
}

# =============================================================================
# Step 5: Configure kubectl convenience (optional)
# =============================================================================
step5_kubectl_convenience() {
  log_section "Step 5: Configure kubectl convenience (optional)"

  REAL_USER="${SUDO_USER:-$USER}"
  REAL_HOME=$(eval echo "~${REAL_USER}")
  echo "alias k=kubectl" >> "${REAL_HOME}/.bashrc"
  kubectl completion bash > /etc/bash_completion.d/kubectl 2>/dev/null || true
  echo 'source /etc/bash_completion.d/kubectl' >> "${REAL_HOME}/.bashrc"
  log_ok "kubectl alias 'k' added for user ${REAL_USER}"
}

# =============================================================================
# Main
# =============================================================================
main() {
  require_root

  echo ""
  echo "============================================================"
  echo "  K8s Learning Lab — Worker Node Setup"
  echo "  Node: ${NODE_NAME} (${NODE_IP})"
  echo "  K8s:  v${K8S_VERSION}"
  echo "============================================================"
  echo ""

  step1_system_prereqs
  step2_containerd
  step3_kubeadm
  step4_join_cluster
  step5_kubectl_convenience

  echo ""
  echo "============================================================"
  echo "  Worker node setup complete!"
  echo ""
  echo "  Verify from your workstation:"
  echo "  kubectl get nodes"
  echo ""
  echo "  ${NODE_NAME} should appear in the node list."
  echo "============================================================"
  echo ""
}

main "$@"
