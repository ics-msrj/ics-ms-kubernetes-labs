# ACK Rancher Management Platform

This directory provisions `ack-nextops-platform-jkt-001`, a dedicated ACK
management cluster for Rancher. It is not a workload cluster: do not deploy
Online Boutique, the curriculum modules, or application node pools here.

The initial scope is Rancher only. Headlamp, Argo CD, centralized observability,
and management-cluster backup automation are deliberately deferred until the
Rancher server and downstream access model are proven.

## Architecture

```text
Browser / Rancher agent
        |
Cloudflare DNS and Tunnel
        |
rancher.platform.next-ops.ai
        |
Rancher ClusterIP Service in ACK management cluster
        |
ACK workload, AKS workload, and GKE workload clusters
```

Cloudflare terminates public TLS and the in-cluster connector forwards HTTP to
the Rancher `ClusterIP` Service. Do not use a public application load balancer
for Rancher. Cloudflare Access may protect browser access, but must explicitly
bypass Rancher agent traffic: downstream cluster agents require direct,
long-lived HTTPS/WebSocket connectivity to the Rancher hostname.

## Provision

1. Review `terraform/README.md`; copy `terraform.tfvars.example` to the ignored
   `terraform.tfvars`, filling existing VPC, dedicated vSwitch, Resource Group,
   KMS key, and key pair identifiers.
2. Run `terraform init`, `terraform validate`, and `terraform plan -out=tfplan`.
   Review the billable ACK, ECS, ESSD, NAT, and API SLB resources before you run
   `terraform apply tfplan`.
3. Export the Terraform-generated kubeconfig and immediately restrict the ACK
   API endpoint network ACL to administrator, ACK-management, and node CIDRs.
4. Copy `config/platform.env.example` to the ignored `config/platform.env`; set
   the cluster ID, kubeconfig context, Cloudflare Tunnel token, and Rancher
   hostname.

## Install Rancher

```bash
export KUBECONFIG=/tmp/ack-nextops-platform-kubeconfig
chmod 600 "$KUBECONFIG"

bash platforms/ack/management/scripts/platform-track.sh preflight
bash platforms/ack/management/scripts/platform-track.sh bootstrap
bash platforms/ack/management/scripts/platform-track.sh enable-cloudflare
bash platforms/ack/management/scripts/platform-track.sh enable-rancher
```

Create the Cloudflare public-hostname route after Rancher is installed:

```text
https://rancher.platform.next-ops.ai
  -> http://rancher.cattle-system.svc.cluster.local:80
```

Retrieve the bootstrap password only from the local secret command printed by
the installer. Never commit it. In Rancher, import each workload cluster using
the generated one-time manifest and apply that manifest only to its intended
downstream cluster. Do not apply it to this management cluster.

After ACK, AKS, and GKE show **Connected**, verify:

```bash
bash platforms/ack/management/scripts/platform-track.sh verify-rancher
```

`cleanup-rancher` removes Rancher only. Downstream clusters continue running,
but their agents lose their management-server connection. Do not destroy the
management cluster until a Rancher backup/restore plan is tested.
