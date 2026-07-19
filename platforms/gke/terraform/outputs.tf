output "project_id" {
  description = "GCP project ID — set as GKE_PROJECT_ID in platforms/gke/config/gke.env"
  value       = var.project_id
}

output "region" {
  description = "GCP region — set as GKE_REGION in platforms/gke/config/gke.env"
  value       = var.region
}

output "zone" {
  description = "GCP zone — set as GKE_ZONE in platforms/gke/config/gke.env"
  value       = var.zone
}

output "cluster_name" {
  description = "GKE cluster name — set as GKE_CLUSTER_NAME in platforms/gke/config/gke.env"
  value       = google_container_cluster.lab.name
}

output "workload_nodepool_name" {
  description = "Workload node pool name — set as GKE_WORKLOAD_NODEPOOL in platforms/gke/config/gke.env"
  value       = google_container_node_pool.workload.name
}

output "artifact_registry_repo" {
  description = "Artifact Registry repo path — set as GKE_ARTIFACT_REGISTRY in platforms/gke/config/gke.env if you push custom images"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.lab.repository_id}"
}

output "next_steps" {
  description = "Steps to continue the GKE platform track after this applies"
  value       = <<-EOT

  ================================================================
  GKE cluster is ready. Fill these into platforms/gke/config/gke.env
  (copy from gke.env.example first if you haven't):

  GKE_PROJECT_ID=${var.project_id}
  GKE_REGION=${var.region}
  GKE_ZONE=${var.zone}
  GKE_CLUSTER_NAME=${google_container_cluster.lab.name}
  GKE_WORKLOAD_NODEPOOL=${google_container_node_pool.workload.name}
  GKE_WORKLOAD_LABEL_KEY=${var.workload_node_label_key}
  GKE_WORKLOAD_LABEL_VALUE=${var.workload_node_label_value}
  GKE_ARTIFACT_REGISTRY=${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.lab.repository_id}

  Then follow platforms/gke/README.md from "Foundation":
    bash platforms/gke/scripts/gke-track.sh connect
    bash platforms/gke/scripts/gke-track.sh preflight
    bash platforms/gke/scripts/gke-track.sh enable-managed-addons
  ================================================================
  EOT
}
