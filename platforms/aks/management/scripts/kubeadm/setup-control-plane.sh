#!/bin/bash
# =============================================================================
# Rancher Management Cluster — kubeadm control-plane setup
#
# Adapted from modules/01-cluster-setup/scripts/setup-control-plane.sh — same
# steps verbatim (system prereqs, containerd, kubeadm/kubelet/kubectl,
# kubeadm init, kubectl config, Cilium, final checks), plus two additions
# found live on this track's earlier single-node design:
#   - Step 1b installs a boot-time cleaner for stale Cilium eBPF state (see
#     its own header comment — cilium/cilium#44194).
#   - Step 6 auto-installs helm if missing (module 01's own script assumes
#     it's already present; it isn't on a fresh VM).
# No control-plane taint removal here, unlike the old single-node design —
# this track now has a real worker node for Rancher/cert-manager/cloudflared
# to schedule on.
#
# Run this ON the control-plane VM (Ubuntu 24.04) — bootstrap-control-plane.sh
# (the caller, run from your workstation) scp's this file and invokes it over
# SSH:
#   sudo CONTROL_PLANE_IP=<vm-private-ip> bash /tmp/setup-control-plane.sh
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
# Must match terraform's var.subnet_cidr.
CLUSTER_SUBNET_CIDR="${CLUSTER_SUBNET_CIDR:-10.90.0.0/26}"

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

  # Found live: this image ships ufw active by default, deny-incoming, with
  # only 22/tcp allowed — the Azure NSG (see terraform/main.tf) already
  # allows VNet-internal traffic and is the intended perimeter, but ufw sits
  # in front of it at the OS level and blocked the worker's kubeadm join
  # (6443) even though the NSG itself was correctly configured. Widen it to
  # the cluster's own subnet rather than disabling ufw outright.
  if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow from "${CLUSTER_SUBNET_CIDR}" comment 'cluster-internal' || true
    log_ok "ufw opened for cluster-internal subnet (${CLUSTER_SUBNET_CIDR})"
  fi
}

# =============================================================================
# Step 1b: Install a boot-time cleaner for stale Cilium eBPF pinned state
#
# Root cause identified: cilium/cilium#44194 — "TCX BPF programs not cleaned
# up on Cilium agent restart, causing duplicate attachments and network
# failure." Matches this track's earlier single-node symptoms exactly (Attach
# Mode: TCX, Routing: Tunnel [vxlan] Host: Legacy, ClusterIP/DNS unreachable,
# only nodes that rebooted/restarted Cilium affected). Per that issue, merely
# detaching stale links is NOT sufficient without also restarting Cilium —
# and the reverse (restarting Cilium's pod alone, tried first) is also not
# sufficient without clearing the stale pinned state first. /sys/fs/bpf
# (bpffs) is mounted by the kernel very early at boot and persists its pinned
# maps AND links across both pod restarts and full VM reboots, so Cilium's
# new agent can end up reconciling against/alongside stale pre-reboot state
# instead of a truly clean slate. Wiping the entire bpffs tree before
# containerd (and therefore Cilium) ever starts forces every boot to attach
# fresh TCX programs with nothing stale to duplicate against. Confirmed the
# underlying breakage was reproducible across 3 separate reboots on the old
# single-node design (an unexpected crash, a deliberate Azure VM resize, and
# a normal kernel-update reboot) — restarting the Cilium/kube-proxy pods
# after the fact did NOT recover it; only a full VM rebuild did, each time.
# Applied on both control-plane and worker — each runs its own Cilium agent.
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
# Full recursive wipe, not just tc/globals: cilium/cilium#44194's stale
# state is pinned TCX bpf_links (a different kernel object from the pinned
# maps under tc/globals alone), and their exact pin path isn't guaranteed
# stable across Cilium versions — clearing everything under the mount is
# the only way to be sure nothing stale survives into the new boot. Safe on
# this VM: nothing else uses bpffs here, this is a dedicated Cilium-only node.
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
    log_info "helm not found — installing (module 01's script assumes it's already present, it isn't on a fresh VM)..."
    curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod +x /tmp/get_helm.sh
    /tmp/get_helm.sh
    log_ok "helm installed: $(helm version --short)"
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
  echo "  Rancher Management Cluster — Control Plane Setup"
  echo "  Node: ${NODE_NAME} (${CONTROL_PLANE_IP})"
  echo "  K8s:  v${K8S_VERSION}"
  echo "  CNI:  Cilium v${CILIUM_VERSION}"
  echo "============================================================"
  echo ""

  step1_system_prereqs
  step1b_bpf_cleanup_unit
  step2_containerd
  step3_kubeadm
  step4_kubeadm_init
  step5_kubectl_config
  step6_cilium
  step7_finalize

  echo ""
  echo "============================================================"
  echo "  Control plane setup complete!"
  echo "  Next: from your workstation,"
  echo "    bash platforms/aks/management/scripts/platform-track.sh bootstrap-worker"
  echo "============================================================"
  echo ""

  log_info "Join command for the worker:"
  cat /tmp/join-command.sh
}

main "$@"
