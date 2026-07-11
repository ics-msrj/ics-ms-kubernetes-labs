#!/bin/bash
# =============================================================================
# Module 01 — Control Plane Setup Script
#
# Run this ON the control-plane VM (Ubuntu 22.04/24.04):
#   scp modules/01-cluster-setup/scripts/setup-control-plane.sh <user>@<CONTROL_IP>:/tmp/
#   ssh <user>@<CONTROL_IP>
#   sudo CONTROL_PLANE_IP=<control-plane-private-ip> bash /tmp/setup-control-plane.sh
#
# What this script does:
#   1. System prerequisites (swap off, kernel modules, sysctl)
#   2. Install containerd runtime
#   3. Install kubeadm, kubelet, kubectl
#   4. Initialize the cluster with kubeadm
#   5. Configure kubectl for the current user
#   6. Install Cilium CNI (via Helm)
#   7. Print the join command for workers
#
# Before running: check https://kubernetes.io/releases/ for the current
# stable minor version and set K8S_VERSION/K8S_PATCH_VERSION accordingly —
# the defaults below are a known-good starting point, not necessarily latest.
# =============================================================================

set -euo pipefail

# --- Config ---
K8S_VERSION="${K8S_VERSION:-1.34}"
K8S_PATCH_VERSION="${K8S_PATCH_VERSION:-1.34.9}"
K8S_PACKAGE_VERSION="${K8S_PACKAGE_VERSION:-${K8S_PATCH_VERSION}-1.1}"
CILIUM_VERSION="${CILIUM_VERSION:-1.19.5}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-$(hostname -I | awk '{print $1}')}"
NODE_NAME="${NODE_NAME:-$(hostname -s)}"

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $(date '+%H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_section() { echo -e "\n${BLUE}>>> $* <<<${NC}"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "Run this script as root, for example: sudo bash /tmp/setup-control-plane.sh"
    exit 1
  fi
}

validate_config() {
  if [[ -z "${CONTROL_PLANE_IP}" ]]; then
    log_error "CONTROL_PLANE_IP could not be detected. Set CONTROL_PLANE_IP=<node-private-ip> and rerun."
    exit 1
  fi
}

# =============================================================================
# Step 1: System prerequisites
# =============================================================================
step1_system_prereqs() {
  log_section "Step 1: System prerequisites"

  log_info "Disabling swap..."
  swapoff -a
  sed -i '/swap/d' /etc/fstab
  log_ok "Swap disabled"

  log_info "Loading kernel modules..."
  cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter
  log_ok "Kernel modules loaded: overlay, br_netfilter"

  log_info "Configuring sysctl..."
  cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system -q
  log_ok "sysctl params applied"

  log_info "Updating apt..."
  apt-get update -qq
  apt-get install -y -qq \
    apt-transport-https ca-certificates curl gnupg lsb-release \
    software-properties-common wget jq
  log_ok "Base packages installed"
}

# =============================================================================
# Step 2: Install containerd
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
  log_ok "containerd installed"

  # kubelet requires the systemd cgroup driver — this is the #1 cause of
  # "kubelet won't start" on a fresh kubeadm install if skipped.
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

  systemctl enable --now containerd
  systemctl restart containerd
  log_ok "containerd configured with SystemdCgroup=true and started"
}

# =============================================================================
# Step 3: Install kubeadm, kubelet, kubectl
# =============================================================================
step3_kubeadm() {
  log_section "Step 3: Install kubeadm, kubelet, kubectl"

  if command -v kubeadm &>/dev/null; then
    log_info "kubeadm already installed: $(kubeadm version -o short)"
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
  log_ok "kubeadm ${K8S_PACKAGE_VERSION}, kubelet, kubectl installed and pinned"

  systemctl enable kubelet
  log_ok "kubelet service enabled"
}

# =============================================================================
# Step 4: Initialize cluster with kubeadm
# =============================================================================
step4_kubeadm_init() {
  log_section "Step 4: Initialize Kubernetes cluster"

  if [[ -f /etc/kubernetes/admin.conf ]]; then
    log_info "Cluster already initialized (/etc/kubernetes/admin.conf exists) — skipping"
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubeadm token create --print-join-command > /tmp/join-command.sh
    chmod +x /tmp/join-command.sh
    log_ok "Fresh worker join command saved to /tmp/join-command.sh"
    return
  fi

  log_info "Pod CIDR: ${POD_CIDR}"
  log_info "Service CIDR: ${SERVICE_CIDR}"
  log_info "API server advertise address: ${CONTROL_PLANE_IP}"

  # Pin the kubelet's advertised node IP to the private IP — matters whenever
  # the VM has more than one IP (e.g. a cloud VM with a public + private IP).
  echo "KUBELET_EXTRA_ARGS=--node-ip=${CONTROL_PLANE_IP}" > /etc/default/kubelet
  systemctl daemon-reload

  # CLI flags instead of a kubeadm YAML config: the structured config API
  # (kubeadm.k8s.io/v1betaN) has changed shape across releases (v1beta3 ->
  # v1beta4 introduced a breaking change to kubeletExtraArgs, for example),
  # while these flags have been stable for many releases. Cgroup driver is
  # not set explicitly — kubeadm auto-detects it from containerd, which
  # step 2 already configured with SystemdCgroup=true.
  log_info "Running kubeadm init..."
  kubeadm init \
    --apiserver-advertise-address="${CONTROL_PLANE_IP}" \
    --pod-network-cidr="${POD_CIDR}" \
    --service-cidr="${SERVICE_CIDR}" \
    --node-name="${NODE_NAME}" \
    --kubernetes-version="v${K8S_PATCH_VERSION}" \
    --cri-socket="unix:///run/containerd/containerd.sock" \
    --upload-certs 2>&1 | tee /tmp/kubeadm-init.log

  log_ok "kubeadm init completed"

  kubeadm token create --print-join-command > /tmp/join-command.sh
  chmod +x /tmp/join-command.sh
  log_ok "Join command saved to /tmp/join-command.sh"
  echo ""
  echo "=== JOIN COMMAND ==="
  cat /tmp/join-command.sh
  echo ""
  echo "===================="
}

# =============================================================================
# Step 5: Configure kubectl for the current user and root
# =============================================================================
step5_kubectl_config() {
  log_section "Step 5: Configure kubectl"

  REAL_USER="${SUDO_USER:-$USER}"
  REAL_HOME=$(eval echo "~${REAL_USER}")

  mkdir -p "${REAL_HOME}/.kube"
  cp /etc/kubernetes/admin.conf "${REAL_HOME}/.kube/config"
  chown "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.kube/config"
  log_ok "kubectl configured for user ${REAL_USER}"

  export KUBECONFIG=/etc/kubernetes/admin.conf
  echo 'export KUBECONFIG=/etc/kubernetes/admin.conf' >> /root/.bashrc

  kubectl completion bash > /etc/bash_completion.d/kubectl 2>/dev/null || true
  echo 'source /etc/bash_completion.d/kubectl' >> "${REAL_HOME}/.bashrc"
  echo "alias k=kubectl" >> "${REAL_HOME}/.bashrc"
  echo "complete -o default -F __start_kubectl k" >> "${REAL_HOME}/.bashrc"

  log_ok "kubectl completion and alias configured"
}

# =============================================================================
# Step 6: Install Cilium CNI
# =============================================================================
step6_cilium() {
  log_section "Step 6: Install Cilium CNI"

  export KUBECONFIG=/etc/kubernetes/admin.conf

  if kubectl get daemonset cilium -n kube-system &>/dev/null; then
    log_info "Cilium already installed — skipping"
    return
  fi

  if ! command -v helm &>/dev/null; then
    log_error "helm not found on this node. Install it (see Module 00) or run Cilium install from your workstation against this cluster's kubeconfig."
    exit 1
  fi

  log_info "Adding Cilium Helm repo..."
  helm repo add cilium https://helm.cilium.io/ >/dev/null
  helm repo update >/dev/null

  log_info "Installing Cilium v${CILIUM_VERSION} (pod CIDR: ${POD_CIDR})..."
  helm install cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --set kubeProxyReplacement=false \
    --set ipam.mode=cluster-pool \
    --set ipam.operator.clusterPoolIPv4PodCIDRList="{${POD_CIDR}}" \
    --set operator.replicas=1

  log_info "Waiting for Cilium pods to be ready (this takes ~1-2 minutes)..."
  kubectl wait pods \
    -n kube-system -l k8s-app=cilium \
    --for=condition=Ready \
    --timeout=300s \
    2>/dev/null || log_warn "Cilium pods still starting — check with: kubectl get pods -n kube-system -l k8s-app=cilium"

  log_ok "Cilium CNI installed"
}

# =============================================================================
# Step 7: Final checks
# =============================================================================
step7_finalize() {
  log_section "Step 7: Final checks"

  export KUBECONFIG=/etc/kubernetes/admin.conf

  log_info "Waiting for control-plane node to be Ready..."
  kubectl wait node "${NODE_NAME}" \
    --for=condition=Ready \
    --timeout=180s

  log_ok "Control-plane node is Ready"

  echo ""
  kubectl get nodes -o wide
  echo ""
  kubectl get pods -n kube-system
}

# =============================================================================
# Main
# =============================================================================
main() {
  require_root
  validate_config

  echo ""
  echo "============================================================"
  echo "  K8s Learning Lab — Control Plane Setup"
  echo "  Node: ${NODE_NAME} (${CONTROL_PLANE_IP})"
  echo "  K8s:  v${K8S_VERSION}"
  echo "  CNI:  Cilium v${CILIUM_VERSION}"
  echo "============================================================"
  echo ""

  step1_system_prereqs
  step2_containerd
  step3_kubeadm
  step4_kubeadm_init
  step5_kubectl_config
  step6_cilium
  step7_finalize

  echo ""
  echo "============================================================"
  echo "  Control plane setup complete!"
  echo "  Next steps:"
  echo ""
  echo "  1. Copy the join command to each worker, then run setup-worker.sh:"
  echo ""
  echo "     CONTROL_IP=<control_plane_public_ip>"
  echo "     WORKER_IPS='<worker1_public_ip> <worker2_public_ip>'"
  echo ""
  echo "     scp \${SSH_USER:-ubuntu}@\${CONTROL_IP}:/tmp/join-command.sh /tmp/"
  echo "     idx=1"
  echo "     for WORKER_IP in \${WORKER_IPS}; do"
  echo "       scp /tmp/join-command.sh \${SSH_USER:-ubuntu}@\${WORKER_IP}:/tmp/"
  echo "       scp modules/01-cluster-setup/scripts/setup-worker.sh \${SSH_USER:-ubuntu}@\${WORKER_IP}:/tmp/"
  echo "       ssh \${SSH_USER:-ubuntu}@\${WORKER_IP} \"sudo NODE_NAME=k8s-worker-0\${idx} bash /tmp/setup-worker.sh\""
  echo "       idx=\$((idx + 1))"
  echo "     done"
  echo ""
  echo "  2. Export kubeconfig to your workstation:"
  echo "     bash modules/01-cluster-setup/scripts/export-kubeconfig.sh"
  echo "============================================================"
  echo ""

  log_info "Join command for workers:"
  cat /tmp/join-command.sh
}

main "$@"
