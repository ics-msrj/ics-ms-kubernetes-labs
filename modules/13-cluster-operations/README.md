# Module 13 — Cluster Operations

**Duration**: ~90 minutes | **Level**: Advanced | **Prerequisite**: [Module 12](../12-progressive-delivery/)

---

## Overview

Everything a managed Kubernetes service (EKS/GKE/AKS) does for you behind the scenes, this module does by hand: etcd backups, application/volume disaster recovery, node maintenance, and control-plane version upgrades. Half of this is scripted because it's safe to automate; half is a careful manual walkthrough because it genuinely isn't — see [Risk Tiers](#risk-tiers-why-half-of-this-isnt-scripted) below before you run anything.

## Learning Objectives

After this module you will:
- Be able to take a real etcd snapshot and explain why saving it *on the same node etcd runs on* isn't a backup — it's a copy that dies with the node.
- Understand what `EnableCSI` buys Velero: backing up PersistentVolume *data*, not just the Kubernetes objects that reference it — and why that only works because Module 05 already had VolumeSnapshot support installed.
- Know the actual mechanics of `kubectl drain`: it cordons, it evicts (not deletes) evictable pods respecting PodDisruptionBudgets, and it does nothing to DaemonSet pods or emptyDir data unless told to.
- Understand kubeadm's upgrade order (control plane before any worker, `kubeadm upgrade node` before kubelet on each node) and why that order isn't arbitrary.

## Prerequisites

- [Module 05](../05-storage/) verified — Velero's volume backups use Longhorn's VolumeSnapshotClass.
- [Module 07](../07-scalability-ha/) verified — the node drain drill is a real test of the PodDisruptionBudgets that module created.

## Risk Tiers — why half of this isn't scripted

| Operation | Automated? | Why |
|---|---|---|
| etcd snapshot (backup) | Yes | Read-only against etcd — cannot make things worse |
| Velero backup/restore | Yes | Restores into a *new* namespace, never overwrites the original |
| Node cordon/drain/uncordon | Yes | Fully reversible; respects PDBs by design |
| kubeadm upgrade *readiness check* | Yes (`check-upgrade-readiness.sh`) | `kubeadm upgrade plan` is documented upstream as read-only — it fetches version info and reports, it never applies anything. Knowing you're behind carries none of the risk that actually upgrading does. |
| **etcd restore** | **No — manual walkthrough only** | Requires stopping the API server and replacing etcd's data directory on your only control-plane node. Get a step wrong here and you have no working cluster and no easy undo. |
| **kubeadm version upgrade** (the actual `apply`) | **No — manual walkthrough only** | Touches every control-plane component and every kubelet. A script that gets this wrong mid-upgrade can leave the cluster in a half-upgraded state that's genuinely hard to reason about remotely. |

Both manual procedures below are real, complete, and safe to follow carefully — they're just not something this repo will run against your cluster without you watching every step.

## Architecture

```
┌──────────────┐     kubectl exec + kubectl cp     ┌──────────────────┐
│  etcd (static  │ ─────────────────────────────────▶│  modules/13.../    │
│  pod, control-  │   (no SSH, no host etcdctl        │  backups/            │
│  plane)         │    install needed)                 │  (git-ignored)       │
└──────────────┘                                     └──────────────────┘

┌──────────────┐    S3 API    ┌──────────┐   CSI VolumeSnapshot   ┌────────────┐
│    Velero      │ ────────────▶│  MinIO    │◀───────────────────────│  Longhorn    │
│  (+ CSI plugin) │             │ (Longhorn- │   (Module 05)           │  PVCs         │
│                 │             │  backed)   │                         │              │
└───────┬────────┘             └──────────┘                         └────────────┘
        │ backs up
        ▼
  online-boutique  ──restore (namespaceMapping)──▶  online-boutique-restore-drill
  (untouched)                                        (proof the backup is real)
```

## Theory

**Why an etcd snapshot saved next to etcd isn't a backup.** `etcdctl snapshot save` writing to `/tmp` on the control-plane node protects you from etcd corruption — it does nothing if that node's disk fails entirely, which is a large fraction of the reasons you'd want a backup in the first place. `setup.sh` runs the snapshot via `kubectl exec` into the etcd static pod (using the exact `etcdctl` bundled in that pod's own image — no separate host install, no version-matching guesswork) and immediately `kubectl cp`s the result out to your workstation, then deletes the copy left in the pod. The snapshot only counts as a backup once it's off that node.

**What `EnableCSI` actually changes about a Velero backup.** Without it, Velero backs up Kubernetes *objects* — a PersistentVolumeClaim's YAML, not the data a PersistentVolume actually holds. `EnableCSI` tells Velero's CSI plugin to create a real `VolumeSnapshot` (Module 05's CRDs, Longhorn's driver) for every PVC in scope, and reference that snapshot in the backup — restoring later provisions a new PVC *from* that snapshot, with the data intact. `velero.io/csi-volumesnapshot-class: "true"` on Module 05's `longhorn` VolumeSnapshotClass is the one-line reason the CSI plugin knows which VolumeSnapshotClass to use; miss that label and Velero backs up objects only, silently, with no error to tell you volume data isn't included.

**Why the restore drill uses `namespaceMapping` instead of restoring in place.** A restore into the *same* namespace it was backed up from will, depending on what's already there, either be rejected (objects already exist) or overwrite live state — neither is what you want for *proving a backup works*. `namespaceMapping: {online-boutique: online-boutique-restore-drill}` restores every object into a parallel namespace, so `verify.sh` can compare Deployment counts between the two and know, concretely, that the backup captured everything — with zero risk to the namespace every other module depends on.

**What `kubectl drain` actually guarantees.** `cordon` alone just marks a node unschedulable for *new* pods — nothing currently running moves. `drain` additionally evicts every already-running pod that can be safely evicted, using the Eviction API (which checks PodDisruptionBudgets — Module 07's `frontend`/`cartservice` PDBs are exactly what's being respected here, not a separate check this module invented). `--ignore-daemonsets` is required because DaemonSet pods (node-exporter, Alloy) are meant to run on every node, including ones being drained for maintenance, not evicted — trying to evict them without that flag just fails the drain. `--delete-emptydir-data` is required because `emptyDir` volumes have no meaning to migrate — that data was always node-local and disposable by definition.

## Lab

### Step 1 — Deploy the automated parts

```bash
bash modules/13-cluster-operations/scripts/setup.sh
```

### Step 2 — Verify

```bash
bash modules/13-cluster-operations/scripts/verify.sh
```

### Step 3 — Inspect the restore drill

```bash
kubectl get deployments -n online-boutique-restore-drill
kubectl get pvc -n online-boutique-restore-drill   # a genuinely new PVC, provisioned from the CSI snapshot
```

Clean it up once you've looked: `kubectl delete namespace online-boutique-restore-drill`.

### Step 4 — Check upgrade readiness (read-only, safe to run any time)

```bash
bash modules/13-cluster-operations/scripts/check-upgrade-readiness.sh
```

This runs `kubeadm upgrade plan` on the control-plane over SSH and reports every node's current kubelet version — nothing is changed. Use this to actually decide whether Step 5 below is worth doing right now, instead of guessing.

### Step 5 — Manual walkthrough: kubeadm version upgrade

**Check current versions first** — this repo pinned `v1.34.9` in Module 01; treat the version numbers below as an example, not a fixed target. Check [kubernetes.io/releases](https://kubernetes.io/releases/) for what's actually current before you run this for real.

On the **control-plane** (SSH in):

```bash
# 1. See what kubeadm itself thinks is available/safe
sudo apt-mark unhold kubeadm
sudo apt-get update && sudo apt-get install -y kubeadm=1.35.6-*
sudo apt-mark hold kubeadm
sudo kubeadm upgrade plan

# 2. Apply it (this upgrades control plane components — apiserver, controller-manager, scheduler, etcd config)
sudo kubeadm upgrade apply v1.35.6

# 3. Upgrade kubelet and kubectl on this node
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.35.6-* kubectl=1.35.6-*
sudo apt-mark hold kubelet kubectl
sudo systemctl restart kubelet
```

On **each worker** (one at a time — never drain two nodes simultaneously, or Online Boutique loses redundancy entirely):

```bash
# From your workstation: drain it first
kubectl drain <worker-node> --ignore-daemonsets --delete-emptydir-data

# SSH to that worker
sudo apt-mark unhold kubeadm
sudo apt-get update && sudo apt-get install -y kubeadm=1.35.6-*
sudo apt-mark hold kubeadm
sudo kubeadm upgrade node

sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.35.6-* kubectl=1.35.6-*
sudo apt-mark hold kubelet kubectl
sudo systemctl restart kubelet

# Back on your workstation
kubectl uncordon <worker-node>
kubectl get nodes   # confirm the new version before moving to the next worker
```

### Step 6 — Manual walkthrough: etcd restore drill

**Only attempt this if you're prepared to rebuild the cluster from Module 01 if something goes wrong.** This is the single most disruptive operation in this entire repository.

```bash
# On the control-plane:

# 1. Stop the API server (moving its static pod manifest out of the watched directory stops it)
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/

# 2. Stop etcd the same way
sudo mv /etc/kubernetes/manifests/etcd.yaml /tmp/

# 3. Move the old data directory aside (don't delete — keep it until you've confirmed the restore worked)
sudo mv /var/lib/etcd /var/lib/etcd.bak

# 4. Restore from a snapshot (copy one from modules/13-cluster-operations/backups/ to the control-plane first)
sudo ETCDCTL_API=3 etcdctl snapshot restore /path/to/your/etcd-snapshot-*.db \
  --data-dir=/var/lib/etcd

# 5. Bring etcd and the API server back
sudo mv /tmp/etcd.yaml /etc/kubernetes/manifests/
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/

# 6. Confirm
kubectl get nodes
kubectl get pods -A
```

Anything created *after* the snapshot was taken will be gone — this is a point-in-time restore, not a sync. If it goes wrong: `sudo mv /var/lib/etcd.bak /var/lib/etcd` and move both manifests back to restore exactly where you started.

## Failure Simulation

| Scenario | How to break it | Detect | Recover |
|---|---|---|---|
| BackupStorageLocation unreachable | `kubectl scale deployment minio -n velero --replicas=0` | New backups fail; `kubectl describe backupstoragelocation default -n velero` shows `Unavailable` | `kubectl scale deployment minio -n velero --replicas=1` |
| Drain blocked by a PDB | Drain a node while a PDB-protected Deployment only has its minimum healthy replicas already down elsewhere | `kubectl drain` hangs printing eviction errors referencing the PDB by name | Fix the other replica first — never `--disable-eviction` to force past it without understanding why |
| Backup silently missing volume data | Remove the `velero.io/csi-volumesnapshot-class` label, take a new backup | `kubectl describe backup <name> -n velero` shows 0 volume snapshots taken, no error | Re-add the label (`setup.sh` does this — re-run it), take a fresh backup |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| etcd snapshot step fails immediately | Wrong etcd pod name, or this isn't a single-control-plane cluster | `kubectl get pods -n kube-system -l component=etcd`; the pod name is always `etcd-<node-name>` |
| Velero backup phase `PartiallyFailed` | Usually one resource type Velero couldn't back up (check its own RBAC) — rarely fatal to the overall backup | `kubectl logs -n velero deployment/velero`; `velero backup describe` if you have the CLI, or `kubectl describe backup <name> -n velero` |
| Restore namespace has Deployments but 0 running pods | Images unreachable, or a Secret the restored Deployments need wasn't included in the backup scope | `kubectl get events -n online-boutique-restore-drill --sort-by=.lastTimestamp`; Secrets ARE included by default unless explicitly excluded |
| `kubeadm upgrade plan` refuses to run | Version skew — kubeadm requires the *current* kubeadm binary to already match the *current* cluster version before it will plan an upgrade | `kubeadm version`; `kubectl version` — these should agree with what's actually running before upgrading kubeadm itself further |

## Cleanup

```bash
bash modules/13-cluster-operations/scripts/destroy.sh
```

## Key Takeaways

- A backup that lives on the same failure domain as what it backs up isn't a backup — off-node (or off-cluster) is the entire point.
- Velero + CSI snapshots is what makes "backup" mean data, not just YAML — verify the VolumeSnapshotClass label if a backup ever looks suspiciously fast or small.
- `kubectl drain` is PDB-aware eviction, not deletion — the mechanism this module exercised is the same one a real node replacement or OS patching cycle depends on.
- The two operations this module deliberately didn't automate (etcd restore, kubeadm upgrade) are exactly the two most likely to actually be needed under pressure in a real incident — know the manual steps cold, don't just know a script exists.

## Next Module

[Module 14 — Multi-Cluster Management](../14-multi-cluster-mgmt/) — Rancher, managing more than one cluster from one place.
