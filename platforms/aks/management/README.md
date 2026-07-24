# Rancher Management Cluster (Azure)

This directory provisions two Azure VMs — 1 control-plane + 1 worker —
running a native (kubeadm) Kubernetes cluster dedicated to Rancher. It is not
a workload cluster: do not deploy Online Boutique, the curriculum modules, or
application workloads here.

Deliberately 2 nodes, not 1: an earlier single-node design was found live not
to reliably survive a VM reboot (see "Known issue" below — cilium/cilium#44194).
Splitting control-plane and worker onto separate VMs contains the blast
radius if that bug recurs on either node (the other keeps running
independently) and lets them be patched one at a time instead of
simultaneously. The control-plane VM only runs etcd/apiserver/scheduler/
controller-manager/kube-proxy/Cilium; Rancher, cert-manager, and the
Cloudflare Tunnel connector all schedule on the worker (the control-plane's
standard kubeadm taint excludes them automatically — no manual node
affinity/selector needed).

The initial scope is Rancher only. Headlamp, Argo CD, centralized
observability, and management-cluster backup automation are deliberately
deferred until the Rancher server and downstream access model are proven —
same scoping as `platforms/ack/management/`.

## Architecture

```text
Admin workstation (SSH, kubeconfig via SSH tunnel — no public 6443)
        |
Azure control-plane VM (southeastasia) — kubeadm control plane + Cilium
        |
        | (kubeadm join, same VNet)
        |
Azure worker VM (southeastasia) — Rancher, cert-manager, cloudflared + Cilium
        |
Cloudflare DNS and Tunnel (outbound only from the worker)
        |
rancher.platform.next-ops.ai
        |
Rancher ClusterIP Service
        |
ACK workload, AKS workload, and GKE workload clusters
```

Cloudflare terminates public TLS; the in-cluster connector forwards HTTP to
the Rancher `ClusterIP` Service. Do not use a public load balancer or NodePort
for Rancher — the NSG (see `terraform/main.tf`) opens no inbound port on
either VM except SSH from an admin CIDR. Cloudflare Access may protect
browser access, but must explicitly bypass Rancher agent traffic: downstream
cluster agents require direct, long-lived HTTPS/WebSocket connectivity to the
Rancher hostname.

## Provision

1. Review `terraform/README.md`; copy `terraform.tfvars.example` to the
   ignored `terraform.tfvars`, filling `subscription_id`, `admin_cidr` (your
   own IP, never `0.0.0.0/0`), and `ssh_public_key_path`.
2. Run `terraform init`, `terraform validate`, and `terraform plan -out=tfplan`.
   Review the billable VMs, disks, public IPs, and NSG before you run
   `terraform apply tfplan`.
3. Copy `config/platform.env.example` to the ignored `config/platform.env`;
   fill both VMs' public/private IPs from the Terraform output, SSH user/key
   path, Cloudflare Tunnel token, and Rancher hostname.

## Install

```bash
bash platforms/aks/management/scripts/platform-track.sh preflight
bash platforms/aks/management/scripts/platform-track.sh bootstrap-control-plane
bash platforms/aks/management/scripts/platform-track.sh bootstrap-worker
bash platforms/aks/management/scripts/platform-track.sh export-kubeconfig
bash platforms/aks/management/scripts/platform-track.sh bootstrap
bash platforms/aks/management/scripts/platform-track.sh enable-cloudflare
bash platforms/aks/management/scripts/platform-track.sh enable-rancher
```

`bootstrap-control-plane` installs kubeadm + Cilium on the control-plane VM
(mirroring `modules/01-cluster-setup/scripts/setup-control-plane.sh`) and
fetches the worker join command to `generated/join-command.sh`.
`bootstrap-worker` copies that join command to the worker VM and joins it to
the cluster (mirroring `setup-worker.sh`). `export-kubeconfig` then starts
the SSH tunnel to the **control-plane** that every later step's `kubectl`
depends on — there is no public API server endpoint on this track.

Create the Cloudflare public-hostname route after Rancher is installed:

```text
https://rancher.platform.next-ops.ai
  -> http://rancher.cattle-system.svc.cluster.local:80
```

Retrieve the bootstrap password only from the local secret command printed by
the installer. Never commit it. In Rancher, import each workload cluster
using the generated one-time manifest and apply that manifest only to its
intended downstream cluster. Do not apply it to this management cluster.

After ACK, AKS, and GKE show **Connected**, verify:

```bash
bash platforms/aks/management/scripts/platform-track.sh verify
```

`cleanup-rancher` removes Rancher only. Downstream clusters continue running,
but their agents lose their management-server connection. Do not destroy
either VM until a Rancher backup/restore plan is tested.

## Fault tolerance

Still only 1 worker — if it fails, Rancher goes down until it's replaced and
reinstalled (there's nowhere else for it to reschedule to). The control-plane
losing its one node is likewise fatal to the whole cluster (no etcd
redundancy). This 2-node split is about containing and isolating failures
(patch/reboot one node without necessarily taking down the other, diagnose
which node actually broke) — it is not HA. Revisit if downstream-cluster
management becomes business-critical enough to justify a real 3-node
control-plane and multiple workers.

## Known issue: single-node kubeadm+Cilium did not reliably survive a VM reboot (2026-07-24)

Found live on an earlier single-node version of this track, reproduced
across 3 separate reboots (an unexpected crash, a deliberate Azure VM
resize, and a normal `apt upgrade` + kernel-update reboot): Cilium's service
datapath came back broken every time. Symptom: `cilium status`/
`cilium endpoint list` reported everything healthy, but `cilium bpf lb list`
showed real ClusterIP services (CoreDNS, the API server, etc.) with an empty
`0.0.0.0:0 non-routable` backend, and pod-to-ClusterIP traffic (even `ping`)
timed out completely. CoreDNS never became Ready, cert-manager-webhook and
cloudflared crash-looped behind it, and Rancher became unreachable.

**Root cause identified:** [cilium/cilium#44194](https://github.com/cilium/cilium/issues/44194)
— "TCX BPF programs not cleaned up on Cilium agent restart, causing
duplicate attachments and network failure." Matches exactly: `Attach Mode:
TCX`, `Routing: Tunnel [vxlan] Host: Legacy`, only nodes that
rebooted/restarted Cilium affected, nodes that never restarted worked fine.
Per that issue, merely detaching stale links isn't sufficient without also
restarting Cilium, and restarting Cilium's pod alone (tried first here) isn't
sufficient without clearing the stale pinned state first — `/sys/fs/bpf`
(bpffs) is a host-level mount that survives both pod restarts and full VM
reboots, so a fresh Cilium agent can end up reconciling against stale
pre-reboot links instead of a genuinely clean slate.

**Fix implemented:** `scripts/kubeadm/setup-control-plane.sh` and
`setup-worker.sh` both install and enable `clear-stale-cilium-bpf.service`
(step 1b) — a systemd oneshot, ordered before `containerd.service`, that
does a full recursive wipe of `/sys/fs/bpf` on every boot. Also fixed along
the way: `helm` isn't preinstalled on a fresh Ubuntu 24.04 image (module 01's
own script assumes it is) — step 6 now installs it if missing.

**Not yet independently re-verified end-to-end on this 2-node design** —
the single-node testing that identified the bug and implemented this fix
never got a clean "reboot a fully-bootstrapped stack, confirm it survives"
cycle before the design changed to 2 nodes. Before trusting either VM
through a routine kernel update: get the full stack (kubeadm → Cilium →
Rancher → Cloudflare Tunnel) up and verified stable first, then deliberately
reboot one node at a time and re-run `verify` before considering this closed.
