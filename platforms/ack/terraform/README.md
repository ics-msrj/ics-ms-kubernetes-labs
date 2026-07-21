# ACK Terraform Foundation

This module creates an ACK Managed Pro cluster and two managed node pools in
Jakarta. It consumes existing VPC, separate control-plane/node/Pod vSwitches,
Resource Group, KMS key, and key-pair IDs; it never creates or changes shared
networking. Pod vSwitches must not be the same as node or control-plane
vSwitches, and must be in matching zones for Terway.

It creates an ACK-managed NAT Gateway when `create_nat_gateway=true`; this is
required when the existing VPC has no outbound NAT/SNAT path. It can also create
an Internet-facing API-server SLB for local `kubectl`; immediately restrict its
listener with an ACK API-server network ACL after cluster creation. Use a
whitelist containing the administrator's current public `/32`,
`100.104.0.0/16` for ACK management, and the node-vSwitch CIDR. Configure it
from **ACK Console -> Cluster Information -> Basic Information -> Network ->
Set access control**. Omitting the ACK or node CIDR can break console and node
connectivity.

Before the first apply, activate Container Service for Kubernetes in the
Alibaba Cloud console and complete ACK Quick Authorization, including
`AliyunCSManagedSecurityRole` when using the KMS encryption key. The account
must also be permitted to create ACK Pro clusters. Because `workloadpool` is
autoscaled, activate Auto Scaling and authorize
`AliyunCSManagedAutoScalerRole` from **ACK Console -> Cluster -> Nodes -> Node
Pools -> Enable** before applying Terraform.

The cluster has no default workers. `systempool` is fixed at two pay-as-you-go
nodes. `workloadpool` is labelled `workload=autoscale` and scales from one to
four pay-as-you-go nodes. Terway shared ENI networking is selected. The API
server public endpoint follows `api_server_public_access` in `terraform.tfvars`.

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
