#!/bin/bash
# =============================================================================
# Rancher Management Cluster — kubeadm worker setup
#
# Adapted from modules/01-cluster-setup/scripts/setup-worker.sh — same steps
# verbatim (system prereqs, containerd, kubeadm/kubelet, join cluster, kubectl
# convenience), plus the same boot-time Cilium eBPF state cleaner as
# setup-control-plane.sh's step1b (see its header comment — cilium/cilium#44194).
# This node runs its own Cilium agent (DaemonSet) once joined, so it needs
# the same fix.
#
# Run this ON the worker VM (Ubuntu 24.04) — bootstrap-worker.sh (the caller,
# run from your workstation) scp's this file plus /tmp/join-command.sh
# (copied from the control plane) and invokes it over SSH:
#   sudo bash /tmp/setup-worker.sh
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
# Must match terraform's var.subnet_cidr.
CLUSTER_SUBNET_CIDR="${CLUSTER_SUBNET_CIDR:-10.90.0.0/26}"

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

  # Same fix as setup-control-plane.sh's step1 — this image ships ufw active
  # by default (deny-incoming, only 22/tcp allowed), which blocks
  # cluster-internal traffic the Azure NSG already permits.
  if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow from "${CLUSTER_SUBNET_CIDR}" comment 'cluster-internal' || true
    log_ok "ufw opened for cluster-internal subnet (${CLUSTER_SUBNET_CIDR})"
  fi
}

# =============================================================================
# Step 1b: Install a boot-time cleaner for stale Cilium eBPF pinned state
#
# Same fix and rationale as setup-control-plane.sh's step1b — this node runs
# its own Cilium agent once it joins, subject to the identical
# cilium/cilium#44194 stale-TCX-link failure mode on reboot.
# =============================================================================
step1b_bpf_cleanup_unit() {
  log_section "Step 1b: Install boot-time Cilium eBPF state cleaner"

  cat > /etc/systemd/system/clear-stale-cilium-bpf.service <<'EOF'
[Unit]
Description=Clear stale Cilium eBPF pinned maps/links before containerd/Cilium start
DefaultDependencies=no
Before=containerd.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'find /sys/fs/bpf -mindepth 1 -delete 2>/dev/null; exit 0'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable clear-stale-cilium-bpf.service
  log_ok "clear-stale-cilium-bpf.service installed and enabled (runs on every future boot)"
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
  echo "  Rancher Management Cluster — Worker Node Setup"
  echo "  Node: ${NODE_NAME} (${NODE_IP})"
  echo "  K8s:  v${K8S_VERSION}"
  echo "============================================================"
  echo ""

  step1_system_prereqs
  step1b_bpf_cleanup_unit
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
