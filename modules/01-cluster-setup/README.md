# Module 01 — Cluster Setup

**Duration**: ~60 minutes | **Level**: Beginner | **Prerequisite**: [Module 00](../00-prerequisites/)

---

## Overview

Bootstrap a real multi-node Kubernetes cluster with `kubeadm`: one control-plane node and one or more worker nodes, talking over `containerd`, networked by Cilium. By the end of this module you'll have a cluster you built yourself, node by node — not a managed service that hid the interesting parts.

## Learning Objectives

After this module you will:
- Understand what `kubeadm init`/`kubeadm join` actually do, and why swap, cgroup driver, and kernel modules matter before either command runs.
- Know the difference between a cluster's pod CIDR and service CIDR, and where each is configured.
- Have installed a CNI (Cilium) via Helm and understand why nothing schedules successfully without one.
- Be able to reach your cluster's API server securely from your workstation over an SSH tunnel, without exposing it publicly.

## Prerequisites

- [Module 00](../00-prerequisites/) verified (`verify.sh` all PASS).
- **VMs**: at least 2 Ubuntu 22.04/24.04 VMs (1 control-plane + 1+ worker) that you can SSH into as a sudo-capable user. Recommended minimum for running Online Boutique plus later modules (observability, service mesh): control-plane 2 vCPU/4GB, each worker 4 vCPU/8GB+. You provide these — see "Getting VMs" below.
- The VMs' security group / firewall must allow: SSH (22) from your workstation, TCP 6443 (API server) from your workstation, and unrestricted traffic between the VMs themselves (node-to-node and pod-to-pod).

### Getting VMs

Two options — pick one:

1. **Bring your own VMs** (recommended if you already have somewhere to run them — a cloud account, a homelab, Proxmox, whatever). Just make sure they meet the prerequisites above, then skip straight to [Step 1](#step-1--fill-in-labenv).
2. **Use the optional Terraform example** in [`terraform/aws/`](terraform/aws/) to provision raw EC2 instances:
   ```bash
   cd modules/01-cluster-setup/terraform/aws
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars — set allowed_cidr to your own IP (curl ifconfig.me)
   terraform init
   terraform apply
   terraform output next_steps
   ```
   This is a reference implementation for one provider, not a requirement — nothing else in this repo depends on Terraform or on AWS specifically.

## Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                        Your Workstation                        │
│                                                                  │
│   kubectl ──── SSH tunnel (localhost:6443) ────┐                │
└─────────────────────────────────────────────────┼────────────────┘
                                                    │
                              ┌─────────────────────▼─────────────────────┐
                              │           control-plane VM                 │
                              │  kube-apiserver · etcd · scheduler         │
                              │  controller-manager · kubelet · containerd │
                              │  Cilium agent                              │
                              └─────────────────────┬─────────────────────┘
                                                     │ kubeadm join
                    ┌────────────────────────────────┼────────────────────────────────┐
                    ▼                                ▼                                ▼
           ┌─────────────────┐             ┌─────────────────┐             ┌─────────────────┐
           │    worker VM     │             │    worker VM     │             │  worker VM (n)   │
           │ kubelet          │             │ kubelet          │             │ kubelet          │
           │ containerd       │             │ containerd       │             │ containerd       │
           │ Cilium agent     │             │ Cilium agent     │             │ Cilium agent     │
           └─────────────────┘             └─────────────────┘             └─────────────────┘
```

## Theory

`kubeadm` automates the mechanical parts of standing up a cluster (certificates, static pod manifests, token-based node bootstrapping) but deliberately does none of the following for you, because they're host-level decisions kubeadm can't make safely on your behalf:

- **Swap must be off.** The kubelet refuses to start with swap enabled by default — the scheduler's resource accounting assumes memory limits are real memory limits, and swap breaks that assumption.
- **The cgroup driver must match between containerd and kubelet.** Both default to `systemd` on modern Ubuntu; a mismatch here is the single most common "kubelet won't start" cause on a fresh install.
- **A CNI plugin isn't optional.** Until one is installed, nodes report `Ready` but pods stay `Pending` forever — kubeadm sets up everything except pod networking, by design, because CNI choice is meant to be yours.

**Why Cilium, and why not the kube-proxy replacement mode?** Cilium is eBPF-based, which gives it two properties that matter for this lab beyond "it's a CNI": (1) `cilium status` and Hubble (introduced properly in Module 17) give you L3-L7 visibility into pod traffic that Calico/iptables-based CNIs don't expose as directly, useful once you're debugging NetworkPolicy and service mesh behavior in later modules; (2) it's a widely-used production choice, so what you learn here transfers. This module installs Cilium purely as a CNI (`kubeProxyReplacement=false`) — `kube-proxy` (installed by kubeadm) still handles Services. Full kube-proxy replacement is a legitimate advanced configuration but adds a failure mode this module doesn't need you debugging yet.

**Why an SSH tunnel instead of exposing the API server?** `kubeadm init` binds the API server to the control-plane's private IP. Rather than opening port 6443 to the internet, `export-kubeconfig.sh` forwards `localhost:6443` on your workstation to the control-plane's private IP over SSH — the same pattern you'd use to reach an internal service in any environment without a public LoadBalancer.

## Lab

### Step 1 — Fill in `lab.env`

```bash
# Edit lab.env at the repo root — fill in from your VMs (or `terraform output next_steps` if you used Terraform):
SSH_USER=ubuntu
CONTROL_PLANE_PUBLIC_IP=<control-plane public/reachable IP>
CONTROL_PLANE_PRIVATE_IP=<control-plane private IP — same as public if you only have one>
WORKER_PUBLIC_IPS="<worker1 IP> <worker2 IP> ..."
```

### Step 2 — Bootstrap the control plane

```bash
source lab.env
scp modules/01-cluster-setup/scripts/setup-control-plane.sh "${SSH_USER}@${CONTROL_PLANE_PUBLIC_IP}:/tmp/"
ssh "${SSH_USER}@${CONTROL_PLANE_PUBLIC_IP}" \
  "sudo CONTROL_PLANE_IP=${CONTROL_PLANE_PRIVATE_IP} NODE_NAME=k8s-control bash /tmp/setup-control-plane.sh"
```

This takes ~5 minutes. It ends by printing a join command — you don't need to copy it by hand, Step 3 does that for you.

### Step 3 — Join the workers

```bash
scp "${SSH_USER}@${CONTROL_PLANE_PUBLIC_IP}:/tmp/join-command.sh" /tmp/
idx=1
for WORKER_IP in ${WORKER_PUBLIC_IPS}; do
  scp /tmp/join-command.sh "${SSH_USER}@${WORKER_IP}:/tmp/"
  scp modules/01-cluster-setup/scripts/setup-worker.sh "${SSH_USER}@${WORKER_IP}:/tmp/"
  ssh "${SSH_USER}@${WORKER_IP}" "sudo NODE_NAME=k8s-worker-0${idx} bash /tmp/setup-worker.sh"
  idx=$((idx + 1))
done
```

### Step 4 — Export kubeconfig and connect

```bash
bash modules/01-cluster-setup/scripts/export-kubeconfig.sh
export KUBECONFIG=$(pwd)/modules/01-cluster-setup/kubeconfig.yaml
kubectl get nodes
```

### Step 5 — Verify

```bash
bash modules/01-cluster-setup/scripts/verify.sh
```

Every line must show `PASS` before moving on to [Module 02](../02-core-workloads/).

## Failure Simulation

| Scenario | How to break it | Detect | Recover |
|---|---|---|---|
| Kill the SSH tunnel | `pkill -f "ssh.*6443"` mid-session | `kubectl get nodes` hangs or times out | Re-run `export-kubeconfig.sh`, or the manual `ssh -f -N -L 6443:...` command it prints |
| Stop kubelet on a worker | `ssh <worker> "sudo systemctl stop kubelet"` | `kubectl get nodes` shows that node `NotReady` after ~40s | `ssh <worker> "sudo systemctl start kubelet"` |

Deeper failure injection (killing containerd, corrupting etcd, node network partition) is covered once there's a real workload to lose — see Module 13 (Cluster Operations) and Module 18 (Chaos Engineering).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `kubeadm init` hangs at "waiting for kubelet" | cgroup driver mismatch between containerd and kubelet, or swap still on | `swapoff -a`, confirm `SystemdCgroup = true` in `/etc/containerd/config.toml`, `systemctl restart containerd` |
| Nodes show `Ready` but all pods stay `Pending` | No CNI installed yet, or Cilium pods aren't Running | `kubectl get pods -n kube-system -l k8s-app=cilium` — if empty, re-run step 6 of `setup-control-plane.sh` manually |
| `kubectl get nodes` times out from your workstation | SSH tunnel not running, or `CONTROL_PLANE_PRIVATE_IP` wrong | Re-run `export-kubeconfig.sh`; confirm the private IP is the one `kubeadm init` actually advertised (`kubectl -n kube-system get cm kubeadm-config -o yaml` from the control-plane itself) |
| Worker never appears in `kubectl get nodes` | `join-command.sh` copied before it was generated, or a stale token (tokens expire after 24h) | On the control-plane: `kubeadm token create --print-join-command`, copy the fresh output to the worker, re-run `setup-worker.sh` |
| `Instance profile` / IAM errors during `terraform apply` | Only relevant if using the optional AWS path — your AWS credentials lack EC2/IAM permissions | Use an IAM principal with EC2 full access, or provision VMs another way |

## Cleanup

```bash
bash modules/01-cluster-setup/scripts/destroy.sh
```

Resets `kubeadm` on every node over SSH and removes the local kubeconfig. VMs themselves are **not** deleted — if you used the optional Terraform path, also run `terraform destroy` in `terraform/aws/`.

## Key Takeaways

- `kubeadm` handles the Kubernetes-specific bootstrap; you're responsible for the host prerequisites (swap, cgroup driver, kernel modules) and the CNI choice.
- A cluster with `Ready` nodes and no CNI is not a usable cluster — pods will never leave `Pending`.
- Reaching a private API server through an SSH tunnel is a reusable pattern, not a lab-only trick.

## Next Module

[Module 02 — Core Workloads](../02-core-workloads/) — deploy Online Boutique and cover every core Kubernetes workload type.
