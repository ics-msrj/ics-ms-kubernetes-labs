# ACK Rancher Management Cluster

This Terraform root provisions the dedicated ACK cluster for Rancher only. It
does not modify the existing ACK workload cluster or shared network resources.
Use distinct control-plane, node, and Pod vSwitches with non-overlapping
Service CIDRs. Three fixed management nodes are required by this root; do not
add application workloads or an autoscaling workload pool.

Before the first apply, activate ACK, complete Quick Authorization, authorize
`AliyunCSManagedSecurityRole`, and confirm the account can create an ACK Pro
cluster. If `api_server_public_access` is enabled, restrict the ACK API
listener immediately after creation to the administrator CIDR, ACK management
CIDR, and node-vSwitch CIDR.

```bash
cd platforms/ack/management/terraform
cp terraform.tfvars.example terraform.tfvars
# Fill existing Resource Group, vSwitch, KMS, key-pair, and instance values.
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
terraform show tfplan
# Review billable ACK, ECS, ESSD, NAT, and SLB resources before applying.
terraform apply tfplan
```

The generated kubeconfig, state, plans, `terraform.tfvars`, and `backend.hcl`
are ignored. Deletion protection is enabled. Do not disable it or destroy this
cluster until Rancher backup and downstream disconnection are deliberately
planned.
