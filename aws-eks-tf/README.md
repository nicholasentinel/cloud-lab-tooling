# aws-eks-tf — Private EKS Security Lab

Minimal, cost-optimized, **private** EKS cluster for a security research lab on AWS. Designed to host security agents (an EDR DaemonSet plus a cluster-level helper StatefulSet) alongside intentionally vulnerable workloads (misconfigured nginx, DVWA, etc.) without exposing those workloads to the internet.

## What gets deployed

- Dedicated VPC (default `10.30.0.0/16`) with public + private subnets across 2 AZs
- Internet Gateway + single NAT Gateway (egress only; per-AZ NAT optional)
- EKS cluster, IMDSv2-only worker nodes, control plane logs (api/audit/authenticator) to CloudWatch
- One managed node group, 2x `t3.small` Spot by default, 20 GB gp3 root volume each
- Dedicated least-privilege node IAM role
- KMS CMK (rotation on) for Kubernetes Secrets envelope encryption
- IAM OIDC provider for IRSA (pod-level AWS identity)
- Managed add-ons: VPC CNI (with native NetworkPolicy enabled), CoreDNS, kube-proxy, optionally EBS CSI driver via IRSA
- Public control plane endpoint **restricted** to `authorized_cidrs`; private endpoint also enabled so in-VPC workloads don't hairpin through NAT
- Cluster-admin access entry for the applying principal

## Prerequisites

- `terraform` >= 1.10 (required for the S3 backend's `use_lockfile = true`,
  which replaces the historical DynamoDB lock table)
- `aws` CLI v2 authenticated against an account with billing enabled:
  ```
  aws configure sso            # or: aws configure
  aws sts get-caller-identity  # sanity check
  ```
- The applying principal needs enough IAM to create VPC, EKS, EC2, IAM, KMS, and CloudWatch Logs resources. For a personal lab, an admin-equivalent user is easiest; tighten this down before reuse in a shared account.
- No service quotas to pre-raise in a fresh account for this footprint.

## Deploy

```
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum set authorized_cidrs and cluster_admin_principal_arns
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

State is local by default. For shared use, create an S3 bucket + DynamoDB lock table out of band and uncomment the backend block in `backend.tf`.

## Required `terraform.tfvars`

Copy `terraform.tfvars.example` to `terraform.tfvars` and set the two required
values. Everything else has a sensible default (commented in the example).

```hcl
# REQUIRED — CIDRs allowed to reach the public EKS API endpoint.
# At least one entry; 0.0.0.0/0 is rejected by validation.
# Find your workstation IP with:  curl -s https://ifconfig.me   then use <ip>/32
authorized_cidrs = [
  "203.0.113.42/32",
]

# REQUIRED — IAM user/role ARNs granted cluster-admin via EKS access entries.
# At least one entry; get your own with:  aws sts get-caller-identity --query Arn
cluster_admin_principal_arns = [
  "arn:aws:iam::123456789012:user/you",
]
```

| Field                          | Required | What to put                                                                 |
| ------------------------------ | -------- | --------------------------------------------------------------------------- |
| `authorized_cidrs`             | yes      | One or more source CIDRs (typically your workstation `/32`). No `0.0.0.0/0`. |
| `cluster_admin_principal_arns` | yes      | One or more IAM user/role ARNs to grant cluster-admin.                       |

Optional overrides (`region`, `cluster_name`, `cluster_version`, node sizing,
`vpc_cidr`, NAT/flow-log toggles, etc.) are listed and commented in
`terraform.tfvars.example` — uncomment and change only what you need.

## Access the cluster

```
$(terraform output -raw kubectl_configure_command)
kubectl get nodes
```

Because the cluster has a public control plane endpoint with `public_access_cidrs`, `kubectl` works from any source IP listed in `authorized_cidrs`. The nodes themselves have no public IPs and live in private subnets.

## Tear down

```
terraform destroy
```

NAT Gateways and the control plane accrue cost by the hour even when idle — destroy between sessions if you are not actively using the lab.

## Rough monthly cost estimate (us-west-2, list prices, April 2026)

| Item                                                 | Approx USD/mo |
|------------------------------------------------------|---------------|
| EKS control plane ($0.10/hr, flat)                   | ~$73          |
| 2x t3.small Spot + 20 GB gp3 root each               | ~$10–14       |
| NAT Gateway (1x, minimal traffic)                    | ~$32 + data   |
| CloudWatch Logs (control plane, 7-day retention)     | ~$0–1         |
| KMS CMK                                              | ~$1           |
| **Total (2 nodes, Spot, single NAT)**                | **~$120/mo**  |

> **NAT is the dominant variable cost on AWS**, unlike GCP where Cloud NAT is almost free for a lab-scale workload. Setting `single_nat_gateway = false` roughly doubles the NAT line item (~$32/mo per additional AZ). Removing NAT entirely is possible for a pure offline lab but breaks EKS add-on installs, image pulls from public registries, and any in-cluster agent that needs to reach an external management/ingest endpoint — you would need VPC endpoints for ECR + S3 + STS + EKS at minimum to compensate.

The EKS control plane is the dominant fixed cost (~$73/mo). Unlike GKE, AWS does not offer a free zonal cluster tier, so there's no equivalent "drop to $25/mo" escape hatch. Switching `use_spot_instances = false` adds ~$10-12/mo per t3.small on-demand.

## Agent sizing note

This module does **not** install any specific agent — you bring your own via Helm chart or manifests. The node group is sized assuming a typical EDR / workload-monitoring agent:

- 1 agent pod per node (DaemonSet) consuming ~500m CPU / 512 Mi–1 GiB memory
- 1 cluster-level helper pod (StatefulSet) — enable `enable_ebs_csi_driver` so its PVC provisions

`t3.small` (2 vCPU burstable, 2 GiB RAM) leaves enough headroom for an agent of that size plus a handful of lightweight lab pods. If you see OOMKilled agent pods or `MemoryPressure` on nodes: when `use_spot_instances = false`, bump `node_instance_type` to `t3.medium` (4 GiB). When Spot is on (default), replace `spot_instance_types` with a 4 GiB list, e.g. `["t3.medium", "t3a.medium", "t2.medium"]`.

## Warning — vulnerable workloads

> The threat model assumes pods in this cluster can be compromised. The module deliberately:
>
> - Gives nodes no public IPs; they live in private subnets behind NAT.
> - Restricts the EKS public endpoint to `authorized_cidrs` (0.0.0.0/0 is rejected by variable validation).
> - Attaches a least-privilege node IAM role (worker + CNI + ECR read; nothing else).
> - Requires IMDSv2 on worker nodes (hop limit 2 so pod networking still works). This defeats the classic SSRF-to-instance-credentials attack path.
> - Envelope-encrypts Kubernetes Secrets at rest with a customer-managed KMS key.
> - Enables native NetworkPolicy support in the VPC CNI — `NetworkPolicy` resources are enforced by eBPF on each node.
>
> It does **not** restrict egress from pods to the internet by default (NAT is open). Before running DVWA or similar, add:
>
> - A default-deny `NetworkPolicy` per namespace, explicitly allowlisting what the vulnerable pod actually needs.
> - Consider VPC endpoints for ECR/S3/STS so you can remove NAT entirely for a fully air-gapped test.
>
> The AWS VPC CNI also imposes one thing worth knowing for a security lab: **pods share the node's ENI IP pool and the node's security groups by default**. Pod-level SG isolation is available via `ENABLE_POD_ENI=true` + SecurityGroupPolicy CRs but is not enabled by default here; rely on NetworkPolicy for pod-to-pod controls.
>
> Never place a vulnerable pod in the `default` namespace without a policy in front of it.
