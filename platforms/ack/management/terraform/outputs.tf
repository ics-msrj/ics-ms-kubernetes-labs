output "cluster_id" { value = alicloud_cs_managed_kubernetes.this.id }
output "cluster_name" { value = alicloud_cs_managed_kubernetes.this.name }
output "management_nodepool_id" { value = alicloud_cs_kubernetes_node_pool.management.node_pool_id }
output "kubeconfig_path" { value = var.kubeconfig_output_path }

output "next_steps" {
  value = <<-EOT
    export KUBECONFIG=${var.kubeconfig_output_path}
    chmod 600 "$KUBECONFIG"
    kubectl get nodes
    Copy ../config/platform.env.example to ../config/platform.env.
    Set ACK_MANAGEMENT_CLUSTER_ID=${alicloud_cs_managed_kubernetes.this.id}.
    Set ACK_MANAGEMENT_KUBECTL_CONTEXT from: kubectl config current-context.
  EOT
}
