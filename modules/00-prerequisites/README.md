# Module 00 — Prerequisites

**Duration**: ~20 minutes | **Level**: Beginner | **Prerequisite**: none

---

## Overview

Before touching a cluster, you need a working local toolchain and a lab configuration file. This module installs and verifies everything every later module assumes is already present: `kubectl`, `helm`, `kustomize`, `git`, an SSH client, `yq`, and `jq`.

This module does **not** touch any cluster or VM — it only prepares your local workstation.

## Learning Objectives

After this module you will:
- Have every CLI tool later modules depend on, at a compatible version.
- Understand the `lab.env` convention used to configure every module in this repo.
- Know how to re-verify your toolchain at any point (`verify.sh`).

## Prerequisites

- A Linux or macOS workstation (WSL2 is fine on Windows) with `bash`, `curl`, and either `apt` (Debian/Ubuntu) or `brew` (macOS) available.
- Sudo access on your workstation, to install CLI tools.

## Architecture

```
┌─────────────────────────────┐
│        Your Workstation      │
│                               │
│  kubectl · helm · kustomize  │
│  git · ssh · yq · jq          │
│                               │
│        lab.env (config)      │
└───────────────┬───────────────┘
                │  (nothing provisioned yet —
                │   Module 01 creates the cluster)
                ▼
           (no cluster)
```

## Theory

Every module in this lab follows the same contract: a `README.md`, a `manifests/` directory, and `setup.sh` / `verify.sh` / `destroy.sh` scripts (see the [root README](../../README.md#module-contract)). Scripts read shared configuration from a single `lab.env` file at the repo root, rather than hardcoding values — this is what lets the same scripts work whether your VMs are on AWS, a homelab, or a laptop hypervisor. `lab.env` is git-ignored on purpose: it will eventually hold real IPs and possibly credentials, and none of that belongs in version control.

| Tool | Why it's required | First needed in |
|------|--------------------|------------------|
| `kubectl` | Talk to the cluster | Module 01 |
| `helm` | Install packaged add-ons (CNI extras, ingress, monitoring, …) | Module 01+ |
| `kustomize` | Overlay-based manifest composition | Module 10 (standalone; `kubectl` bundles an older version) |
| `git` | Clone Online Boutique, track your own manifests, GitOps | Module 02, Module 11 |
| `ssh` | Reach the VMs you provision for `kubeadm` | Module 01 |
| `yq` | Read/edit YAML from scripts (`lab.env`-driven templating) | Module 01+ |
| `jq` | Read/edit JSON from scripts (`kubectl -o json` output) | Module 01+ |
| `k9s` *(recommended, not required)* | Fast terminal UI for exploring cluster state | any time |

`docker` is **not** required for this lab: every module deploys Online Boutique using the images Google publishes (`gcr.io/google-samples/microservices-demo/*`), so you never need to build a container image yourself. If a later module has you build a custom image, that module's README will call out `docker` as an added prerequisite at that point.

## Lab

### Step 1 — Copy the lab configuration file

```bash
cp lab.env.example lab.env
```

You don't need to edit it yet — Module 01 will tell you exactly which fields to fill in once you have VMs.

### Step 2 — Install the toolchain

```bash
bash modules/00-prerequisites/scripts/setup.sh
```

This installs any of `kubectl`, `helm`, `kustomize`, `yq`, `jq`, `k9s` that aren't already on your `PATH`, using `apt` (Debian/Ubuntu) or `brew` (macOS). `git` and `ssh` are assumed to already be present as part of a normal dev workstation setup — the script checks for them but won't install them.

### Step 3 — Verify

```bash
bash modules/00-prerequisites/scripts/verify.sh
```

Every line must show `PASS` before moving on to [Module 01 — Cluster Setup](../01-cluster-setup/).

## Failure Simulation

Not applicable — this module has no running system to break yet. Failure simulation starts in Module 06 once there's a cluster and workload to target.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `verify.sh` reports a tool as `MISSING` after `setup.sh` ran | Install script couldn't detect your package manager, or install failed silently | Re-run `setup.sh` and read its output for the failing step; install that one tool manually and re-run `verify.sh` |
| `verify.sh` reports a version below the minimum | An old version was already on your `PATH` from a previous install | Upgrade that tool manually (e.g. `brew upgrade helm`), or remove the old binary so `setup.sh` can install a current one |
| `command not found: yq` after install | `yq` installed to a directory not on your `PATH` (common with the standalone binary install path) | Check where `setup.sh` placed it (printed at the end) and add that directory to your `PATH` |

## Cleanup

```bash
bash modules/00-prerequisites/scripts/destroy.sh
```

Nothing is provisioned in this module, so there is nothing to tear down — this script only removes local scratch files `setup.sh` may have created (e.g. downloaded install archives), and leaves your installed tools in place.

## Key Takeaways

- Every module reads shared config from `lab.env` at the repo root — copy `lab.env.example` once, then extend it as later modules ask for more fields.
- `setup.sh` / `verify.sh` / `destroy.sh` is the same three-command pattern for every module in this repo.
- No cluster exists yet. That's Module 01.

## Next Module

[Module 01 — Cluster Setup](../01-cluster-setup/) — bootstrap a real multi-node cluster with `kubeadm`.
