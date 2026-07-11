# Module 05 — Storage

**Duration**: ~60 minutes | **Level**: Intermediate | **Prerequisite**: [Module 04](../04-networking-gateway/)

---

## Overview

Replace Module 02's `local-path` placeholder with real, node-independent storage: **Longhorn**, a distributed block storage CSI driver that replicates each volume across multiple nodes. Then prove disaster recovery actually works — take a snapshot of `redis-cart`'s volume and restore it into a brand new PVC.

## Learning Objectives

After this module you will:
- Know precisely what `local-path` couldn't do that a real CSI driver can: survive the loss of the node a volume's data physically lived on.
- Understand why a StorageClass's `provisioner` and `volumeBindingMode` matter, and why `storageClassName` inside a StatefulSet's `volumeClaimTemplates` is immutable — meaning changing storage backends is a migration, not a config edit.
- Be able to explain that VolumeSnapshot support is a separate, CSI-driver-agnostic layer (the `snapshot-controller` + `snapshot.storage.k8s.io` CRDs) installed once per cluster — not something Longhorn (or any CSI driver) bundles by itself.

## Prerequisites

- [Module 04](../04-networking-gateway/) verified.
- SSH access to every node still works (`SSH_USER`/`SSH_KEY_PATH`/IPs in `lab.env`) — `setup.sh` installs `open-iscsi` on each one, Longhorn's hard requirement.

## Architecture

```
Before (Module 02-04):                  After (Module 05):

┌────────────┐                          ┌────────────┐
│  worker-1   │                          │  worker-1   │
│ redis-cart  │                          │ redis-cart  │──┐
│  (pod)      │                          │  (pod)      │  │  replicated
│     │       │                          └─────┬──────┘  │  block storage
│  local-path │  ← tied to THIS node's disk.    │         │
│  (1 replica,│    Lose worker-1, lose the data.│    ┌────▼─────┐  ┌──────────┐
│   1 node)   │                                 └───▶│ worker-2  │  │ worker-3  │
└────────────┘                                       │ (replica) │  │ (replica) │
                                                       └──────────┘  └──────────┘
                                                       Longhorn — survives losing
                                                       any single node
```

## Theory

**What `local-path` actually was.** Module 02 needed *some* StorageClass to exist before Module 05 could give the topic a real treatment — `local-path-provisioner` creates a `hostPath`-backed volume on whichever node the pod happens to land on. That's real persistence across pod restarts (the original problem Module 02 solved), but zero persistence across *node* loss: the data lives on one disk, on one machine, with no copy anywhere else.

**What a CSI driver adds.** The Container Storage Interface is a standard plugin interface — any CSI driver can provision, attach, resize, snapshot, and delete volumes the same way, regardless of the underlying storage system. Longhorn's implementation specifically replicates each volume's data across multiple nodes (`numberOfReplicas` in the StorageClass — this module sets it to `min(3, node count)`), so losing the node a volume's *primary* replica was on doesn't lose the volume; Longhorn promotes a surviving replica.

**Why the migration deletes the StatefulSet.** `volumeClaimTemplates[].spec.storageClassName` is one of the fields the API server rejects changes to on an existing StatefulSet — by design, silently rewriting which storage backend a running stateful workload uses would be far more dangerous than refusing the edit. The correct move really is delete-and-recreate, which is also why the data doesn't survive: there's no `local-path` volume left to copy from once you've decided to stop using it. In a system where losing that data actually mattered, this is precisely the situation the second half of this module (VolumeSnapshot) exists to prevent next time.

**VolumeSnapshot is not part of any CSI driver.** `VolumeSnapshotClass`/`VolumeSnapshot`/`VolumeSnapshotContent` are Kubernetes CRDs from the `external-snapshotter` project, watched by one cluster-wide `snapshot-controller` — installed once, used by every CSI driver on the cluster that supports it (Longhorn does). This is why `setup.sh` installs it as a separate step before Longhorn's own install, not as something bundled in Longhorn's Helm chart.

## Lab

### Step 1 — Deploy

```bash
bash modules/05-storage/scripts/setup.sh
```

Watch for the migration warning in the middle of the output — it's expected, not an error.

### Step 2 — Verify

```bash
bash modules/05-storage/scripts/verify.sh
```

This doesn't just check the `VolumeSnapshot` object exists — it restores it into a real, independent PVC and confirms that PVC reaches `Bound`, then deletes it.

### Step 3 — Watch Longhorn survive a node problem (if you have 2+ workers)

```bash
kubectl get pods -n online-boutique -l app=redis-cart -o wide   # note which node redis-cart-0 is on
kubectl get pods -n longhorn-system -o wide | grep instance-manager  # replicas live here, across nodes
```

Cordon and drain the node `redis-cart-0` is running on (`kubectl cordon <node>`, `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`) and watch it get rescheduled onto another node — `kubectl get pvc redis-data-redis-cart-0 -n online-boutique` stays `Bound` throughout, because the data was never only on the node you just drained. `kubectl uncordon <node>` when you're done.

### Step 4 — Try a live volume expansion

```bash
kubectl patch pvc redis-data-redis-cart-0 -n online-boutique -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
kubectl get pvc redis-data-redis-cart-0 -n online-boutique -w   # watch capacity update, no pod restart needed
```

This works because Longhorn's StorageClass sets `allowVolumeExpansion: true` — confirmed by `verify.sh`.

## Failure Simulation

| Scenario | How to break it | Detect | Recover |
|---|---|---|---|
| Longhorn manager pod down on a node | `kubectl delete pod -n longhorn-system -l app=longhorn-manager --field-selector spec.nodeName=<node>` | That node's volumes show degraded replica health in `kubectl get pods -n longhorn-system` | DaemonSet recreates the pod automatically; verify with the Longhorn UI or `kubectl get pods -n longhorn-system -w` |
| Snapshot deleted | `kubectl delete volumesnapshot redis-cart-snapshot -n online-boutique` | `verify.sh`'s restore check fails | Re-run `setup.sh` — it recreates the snapshot |
| Under-replicated volume (fewer nodes than the configured replica count) | Run this module on a 1 or 2-node cluster | `kubectl get pods -n longhorn-system` shows healthy pods, but the Longhorn UI reports the volume as degraded, not healthy | Add more worker nodes, or accept fewer replicas for a lab — `setup.sh` already scales `numberOfReplicas` to your actual node count for this reason |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Longhorn manager pods `CrashLoopBackOff` | `open-iscsi`/`iscsid` not running on that node | SSH in and check: `systemctl status iscsid`; re-run `setup.sh`, or install manually per the Prerequisites note it prints |
| PVC stuck `Pending` on the `longhorn` StorageClass | Not enough schedulable disk space for the requested replica count across nodes | `kubectl describe pvc <name> -n online-boutique`; check available space per node in the Longhorn UI (`kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80`) |
| `VolumeSnapshot` stuck, never `readyToUse` | `snapshot-controller` not running, or CRDs installed in the wrong order | `kubectl get pods -n kube-system -l app=snapshot-controller`; `kubectl describe volumesnapshot redis-cart-snapshot -n online-boutique` |
| Restore-from-snapshot PVC stuck `Pending` | `VolumeSnapshotContent` not yet bound to the source snapshot | `kubectl describe volumesnapshotcontent` — give it another minute, this is usually just a timing race right after a fresh snapshot |

## Cleanup

```bash
bash modules/05-storage/scripts/destroy.sh
```

## Key Takeaways

- `local-path` is pod-restart-durable; a real CSI driver like Longhorn is node-loss-durable — know which one your workload actually needs.
- Changing `storageClassName` on an existing StatefulSet is a migration you plan (delete, recreate, accept or avoid data loss), not a live edit the API server will even allow.
- VolumeSnapshot is cluster-wide, CSI-agnostic infrastructure installed once — don't expect a CSI driver's own Helm chart to bring it along for free.

## Next Module

[Module 06 — Security Policy](../06-security-policy/) — RBAC, Pod Security Admission, and policy-as-code.
