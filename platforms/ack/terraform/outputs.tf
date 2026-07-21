output "cluster_id" { value = alicloud_cs_managed_kubernetes.this.id }
output "cluster_name" { value = alicloud_cs_managed_kubernetes.this.name }
output "workload_nodepool_id" { value = alicloud_cs_kubernetes_node_pool.workload.node_pool_id }
output "kubeconfig_path" { value = var.kubeconfig_output_path }
output "next_steps" {
  value = <<-EOT
    export KUBECONFIG=${var.kubeconfig_output_path}
    kubectl get nodes
    Set ACK_CLUSTER_ID=${alicloud_cs_managed_kubernetes.this.id} in ../config/ack.env.
    Set ACK_KUBECTL_CONTEXT from: kubectl config current-context
    Set ACK_STORAGE_CLASS from: kubectl get storageclass
  EOT
}
