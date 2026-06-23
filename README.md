# cloud-lab-tooling

Self-contained tooling for standing up and operating short-lived cloud security
labs. Two independent pieces live here:

| Directory | What it is |
| --- | --- |
| [`burner-account-provisioning/`](burner-account-provisioning/) | A command-line client for the cloud-provisioner API — request short-lived ("burner") cloud accounts, mint console logins, manage their TTLs, and (with an admin key) view/update budgets. |
| [`aws-eks-tf/`](aws-eks-tf/) | Terraform for a minimal, cost-optimized, **private** EKS cluster intended as a security research lab — designed to host security agents alongside intentionally vulnerable workloads without exposing them to the internet. |

The two are unrelated and can be used on their own; this repo just collects them
in one place.

---

## Burner account provisioning CLI

An interactive, menu-driven wrapper around the caller-facing endpoints of the
provisioning API. It prints the `curl`-equivalent of each call (with the key
masked) and the HTTP status + response, so it doubles as a reference for the
API.

**Quick start:**

```sh
cd burner-account-provisioning
cp provision.config.example provision.config   # then fill in HOST (and optionally API_KEY)
./provision-cli.sh
```

`HOST` is required; the API key is prompted (hidden) on first use if not preset.
Settings can also come from environment variables, which override the config
file and are written back to it.

See the full guide: [`burner-account-provisioning/provision-cli.README.md`](burner-account-provisioning/provision-cli.README.md)

- [Dependencies](burner-account-provisioning/provision-cli.README.md#dependencies)
- [Configuration: config file vs. environment variables](burner-account-provisioning/provision-cli.README.md#configuration-provisionconfig-vs-environment-variables)
- [Usage](burner-account-provisioning/provision-cli.README.md#usage)
- [Roles](burner-account-provisioning/provision-cli.README.md#roles)

---

## AWS EKS security lab (Terraform)

A private EKS cluster sized and hardened for running an EDR/agent workload next
to deliberately vulnerable pods. Nodes have no public IPs, the control plane is
locked to an allow-list of source CIDRs, Secrets are envelope-encrypted with a
customer-managed KMS key, and worker nodes are IMDSv2-only.

**Quick start:**

```sh
cd aws-eks-tf
cp terraform.tfvars.example terraform.tfvars   # set authorized_cidrs and cluster_admin_principal_arns
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Two `terraform.tfvars` fields are required before apply:

- **`authorized_cidrs`** — the network door: source CIDRs allowed to reach the
  public Kubernetes API endpoint (typically your workstation `/32`). `0.0.0.0/0`
  is rejected.
- **`cluster_admin_principal_arns`** — the identity door: IAM user/role ARNs
  granted cluster-admin via EKS access entries. Must be non-empty, or the
  cluster has no administrators.

See the full guide: [`aws-eks-tf/README.md`](aws-eks-tf/README.md)

- [What gets deployed](aws-eks-tf/README.md#what-gets-deployed)
- [Prerequisites](aws-eks-tf/README.md#prerequisites)
- [Deploy](aws-eks-tf/README.md#deploy)
- [Required `terraform.tfvars`](aws-eks-tf/README.md#required-terraformtfvars)
- [Access the cluster](aws-eks-tf/README.md#access-the-cluster)
- [Tear down](aws-eks-tf/README.md#tear-down)
- [Cost estimate](aws-eks-tf/README.md#rough-monthly-cost-estimate-us-west-2-list-prices-april-2026)
- [Warning — vulnerable workloads](aws-eks-tf/README.md#warning--vulnerable-workloads)

---

## A note on secrets

Nothing in this repo contains real credentials, account IDs, or hostnames — the
examples use documentation-range placeholders (e.g. `203.0.113.x`,
`123456789012`). Files that hold real values are gitignored:

- `burner-account-provisioning/provision.config` — your API hostname and key
  (created at runtime, `chmod 600`). Commit only `provision.config.example`.
- `aws-eks-tf/terraform.tfvars` and `backend.hcl` — your account-specific
  inputs and remote-state config. Commit only the `*.example` templates.

Double-check before committing.
