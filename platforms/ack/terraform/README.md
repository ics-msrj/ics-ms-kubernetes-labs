# ACK Terraform Foundation

This module creates an ACK Managed Pro cluster and two managed node pools in
Jakarta. It consumes existing VPC, separate control-plane/node/Pod vSwitches,
Resource Group, KMS key, and key-pair IDs; it never creates or changes shared
networking. Pod vSwitches must not be the same as node or control-plane
vSwitches, and must be in matching zones for Terway.

It creates an ACK-managed NAT Gateway when `create_nat_gateway=true`; this is
required when the existing VPC has no outbound NAT/SNAT path. It can also create
an Internet-facing API-server SLB for local `kubectl`; immediately restrict its
listener with an ACK API-server network ACL after cluster creation.

The cluster has no default workers. `systempool` is fixed at two pay-as-you-go
nodes. `workloadpool` is labelled `workload=autoscale` and scales from one to
four pay-as-you-go nodes. Terway shared ENI networking is selected and the API
server has no public SLB endpoint.

```bash
cd platforms/ack/terraform
cp terraform.tfvars.example terraform.tfvars
# Fill every replace-with value using the ACK/VPC/KMS console or aliyun CLI.
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
terraform output -raw next_steps
```

`tfplan`, `terraform.tfvars`, state, and the generated `/tmp` kubeconfig are
ignored. Review the plan carefully: an apply creates billable ACK, ECS, ESSD,
and related service resources. Alibaba Cloud risk-control or quota failures are
account-side conditions; Terraform does not bypass them.

Do not run `terraform destroy` until the lab is intentionally being removed.
The cluster has deletion protection enabled, so clear that protection through a
reviewed Terraform change first.
