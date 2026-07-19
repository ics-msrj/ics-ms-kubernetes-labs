# =============================================================================
# GKE platform track — cluster provisioning.
#
# Mirrors platforms/aks/terraform/main.tf's role: this provisions an actual
# GKE cluster — the control plane, CNI, and node OS are GKE's responsibility
# from the moment this applies. Everything after this is
# platforms/gke/scripts/gke-track.sh connect/preflight/... against what
# Terraform creates here.
#
# State is local by default — for a real team setup, configure a remote
# backend (a GCS bucket) before running this for real.
# =============================================================================

provider "google" {
  # Pinned explicitly — without this, the provider silently follows
  # whatever `gcloud config get-value project` currently reports, which can
  # change out from under a session (the same failure mode the AKS track's
  # subscription_id pinning exists to avoid).
  project = var.project_id
  region  = var.region
}

# APIs this configuration and the scripts after it depend on. All were
# already enabled on this project when checked, but declaring them here
# makes that a Terraform-verified fact rather than an assumption — and
# keeps a from-scratch project working without a manual `gcloud services
# enable` step first. disable_on_destroy = false: this is a shared,
# pre-existing production project (ics-nextops-production), not a
# throwaway one this configuration owns outright — destroying the cluster
# must never disable APIs something else in the project also depends on.
resource "google_project_service" "required" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# A dedicated VPC — this configuration never deploys into the project's
# `default` VPC (shared, auto-mode, wide-open default firewall rules; not
# something this configuration should adopt or modify), same reasoning as
# the AKS track never adopting an existing resource group's tags.
resource "google_compute_network" "lab" {
  name                    = var.network_name
  project                 = var.project_id
  auto_create_subnetworks = false

  depends_on = [google_project_service.required]
}

resource "google_compute_subnetwork" "lab" {
  name          = "${var.network_name}-subnet"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.lab.id
  ip_cidr_range = var.subnet_cidr

  # Secondary ranges required for a VPC-native (alias IP) cluster —
  # GKE-managed IP allocation for Pods/Services references these by name
  # below, rather than this configuration hand-managing IP math.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}

# Required for GKE's regional Gateway API load balancers (the
# gke-l7-regional-external-managed GatewayClass Module 04's adapter
# uses) — a real GCP infrastructure prerequisite this configuration
# missed on the first pass, found by actually running enable-networking.sh
# against a live Gateway: "error ensuring load balancer: ... Invalid
# value for field 'resource.target' ... An active proxy-only subnetwork
# is required in the same region and VPC as the forwarding rule." Purely
# infrastructure — Envoy-based regional/internal GCP load balancers
# (Gateway API, Internal HTTP(S) LB) reserve IPs from a subnet of this
# dedicated purpose, never assigned to VMs, Pods, or anything else.
resource "google_compute_subnetwork" "proxy_only" {
  name          = "${var.network_name}-proxy-only"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.lab.id
  ip_cidr_range = var.proxy_only_subnet_cidr
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# Dedicated node service account — the GKE default is the project's Compute
# Engine default service account, which typically carries broad Editor-like
# access project-wide. Nodes get a minimal, purpose-built identity instead,
# same reasoning as the AKS track's least-privilege role assignments
# (kubelet_identity's AcrPull, the DES-scoped Contributor grant, etc.).
resource "google_service_account" "gke_nodes" {
  project = var.project_id
  # account_id has a hard 30-char ceiling (unlike most GCP resource name
  # limits, which run 63+) — truncated defensively so a longer
  # cluster_name (e.g. this repo's own platform-org-env-region-seq
  # convention) doesn't blow past it.
  account_id   = substr("${var.cluster_name}-nodes", 0, 30)
  display_name = "GKE nodes — ${var.cluster_name}"
}

resource "google_project_iam_member" "gke_nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_container_cluster" "lab" {
  name     = var.cluster_name
  project  = var.project_id
  location = var.zone # zonal, not regional — one control plane, not three; cheaper and simpler for a lab

  network    = google_compute_network.lab.id
  subnetwork = google_compute_subnetwork.lab.id

  # VPC-native cluster — required for GKE Gateway API support
  # (enable-managed-addons.sh) and for the standard Persistent Disk CSI
  # snapshot workflow Module 05 needs.
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Dataplane V2 (Cilium-based, GA) — the same CNI technology the native
  # kubeadm track and the AKS track both use, just GKE-managed instead of
  # self-installed or Azure-managed. Also gets NetworkPolicy support for
  # free (Module 04's NetworkPolicy manifests need this).
  datapath_provider = "ADVANCED_DATAPATH"

  release_channel {
    channel = var.kubernetes_release_channel
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  addons_config {
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  deletion_protection = var.deletion_protection

  # The standard Terraform pattern for GKE: create the cluster with its
  # forced default node pool, then immediately remove it — every real node
  # pool below (system, workload) is a separate, independently-managed
  # google_container_node_pool resource instead. Mirrors the AKS track's
  # explicit default_node_pool ("system") + azurerm_kubernetes_cluster_node_pool
  # ("workload") split, just via GKE's own required mechanism for it.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Even though this default pool is removed seconds after creation, GKE
  # still provisions it briefly using whatever service account this block
  # names — and falls back to the project's default Compute Engine SA if
  # it's left unset. That SA doesn't exist in this project (deleted, a
  # real precondition failure hit on the first apply attempt: "Verify if
  # principal exists and is valid"), so it must be pointed at our own
  # node SA explicitly, same as both real node pools below.
  node_config {
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  resource_labels = var.labels

  depends_on = [google_project_service.required]
}

# Hosts only GKE system components — this repo's application and
# load-test Pods are never scheduled here (see the workload node pool
# below and its matching nodeSelector-based manifests), same rule as the
# AKS track's system node pool.
resource "google_container_node_pool" "system" {
  name     = "system"
  project  = var.project_id
  location = var.zone
  cluster  = google_container_cluster.lab.name

  node_count = var.system_node_count

  node_config {
    machine_type    = var.system_node_machine_type
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = var.labels
  }
}

# Autoscaling — this is where Online Boutique and every later add-on run.
resource "google_container_node_pool" "workload" {
  name     = "workloadpool"
  project  = var.project_id
  location = var.zone
  cluster  = google_container_cluster.lab.name

  autoscaling {
    min_node_count = var.workload_min_count
    max_node_count = var.workload_max_count
  }

  node_config {
    machine_type    = var.workload_node_machine_type
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels = merge(var.labels, {
      (var.workload_node_label_key) = var.workload_node_label_value
    })
  }
}

# For custom images — not required for the stock Online Boutique
# manifests (those pull public images directly).
resource "google_artifact_registry_repository" "lab" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_registry_repo_id
  format        = "DOCKER"
  labels        = var.labels

  depends_on = [google_project_service.required]
}
