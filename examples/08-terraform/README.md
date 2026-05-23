# Terraform Modules for Apollo GraphOS and AWS Infrastructure

Companion documentation: `../../docs/11-ci-cd-automation/` and `../../docs/15-kubernetes-deployment/`

This directory contains production-ready Terraform configurations for provisioning:

1. **Apollo GraphOS resources** — supergraph, variants (staging and production), scoped
   API keys for CI/CD
2. **AWS ElastiCache (Redis)** — entity cache and APQ (Automatic Persisted Query) cache
   for Apollo Router, with clustering, multi-AZ failover, and CloudWatch alarms
3. **AWS IAM roles via IRSA** — fine-grained per-pod IAM roles for the Apollo Router,
   each subgraph service, and CI/CD (GitHub Actions OIDC)

All configurations use Terraform workspaces to manage staging and production environments
from the same codebase with environment-specific variable overrides.

---

## What Is Provisioned

```
Apollo GraphOS (apollographql provider)
  |-- my-platform-graph (apollographql_graph)
  |     |-- staging variant   (public schema introspection)
  |     |-- production variant (private schema, restricted introspection)
  |-- CI/CD API key (publish scope only, stored in AWS Secrets Manager)

AWS (hashicorp/aws provider)
  |-- ElastiCache
  |     |-- Subnet group (private subnets)
  |     |-- Redis replication group (cluster mode, 1 shard x 2 replicas, r7g.large)
  |     |-- Security group (ingress from EKS node SG only)
  |     |-- CloudWatch alarms (CacheMisses, ReplicationLag)
  |     |-- Auth token (random_password -> Secrets Manager)
  |
  |-- IAM roles (IRSA — IAM Roles for Service Accounts)
        |-- apollo-router role      (Secrets Manager read, SSM read, Redis VPC access)
        |-- products-subgraph role  (RDS access, product-specific secrets)
        |-- ci-cd-github-actions role (schema publish permissions)
```

---

## Module Structure

```
examples/08-terraform/
  README.md                  — This file
  graphos-resources.tf       — Apollo GraphOS graph, variants, API keys, Secrets Manager
  eks-irsa-roles.tf          — IAM roles for Router pod, subgraph pods, CI/CD OIDC
  elasticache-redis.tf       — Redis cluster, security groups, CloudWatch alarms
  variables.tf               — (not included) Input variable declarations
  outputs.tf                 — (not included) Root module outputs
  terraform.tfvars.example   — (not included) Example variable values
```

In a real deployment these files live in a single Terraform root module. Teams with
many subgraphs should refactor `eks-irsa-roles.tf` into a reusable child module
parameterized by service account namespace, service account name, and IAM policy ARN.

---

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Terraform | >= 1.6.0 | Infrastructure provisioning |
| AWS CLI | >= 2.13.0 | AWS authentication, `aws eks get-token` |
| Apollo GraphOS API key | Admin scope | Provider authentication |
| rover CLI | >= 0.24.0 | Manual schema publishes, local validation |
| kubectl | >= 1.28 | Annotating ServiceAccounts with role ARNs |

**Provider versions (declared in `required_providers`):**

| Provider | Source | Version |
|---|---|---|
| apollographql/graphos | `apollographql/graphos` | `~> 0.3` |
| hashicorp/aws | `hashicorp/aws` | `~> 5.30` |
| hashicorp/random | `hashicorp/random` | `~> 3.6` |

---

## Quick Start

**1. Authenticate**

```bash
# AWS credentials — use your preferred method (SSO, env vars, instance profile)
export AWS_PROFILE=platform-prod
aws sso login

# Apollo GraphOS — the provider reads from the environment variable
export APOLLO_KEY=service:my-graph:xxxxxxxxxxxxxxxxxxxxxxxxxx
```

**2. Initialize Terraform**

```bash
cd examples/08-terraform

terraform init \
  -backend-config="bucket=my-org-terraform-state" \
  -backend-config="key=graphql-platform/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=terraform-lock"
```

**3. Select or create a workspace**

```bash
# List workspaces
terraform workspace list

# Select an existing workspace
terraform workspace select production

# Or create a new one (first-time setup)
terraform workspace new staging
```

**4. Review the plan**

```bash
terraform plan \
  -var="aws_region=us-east-1" \
  -var="eks_cluster_name=graphql-platform-production" \
  -var="vpc_id=vpc-0abc123" \
  -var="private_subnet_ids=[\"subnet-0aaa\",\"subnet-0bbb\",\"subnet-0ccc\"]" \
  -var="graphos_graph_id=my-platform-graph" \
  -out=tfplan
```

**5. Apply**

```bash
terraform apply tfplan
```

**6. Annotate Kubernetes ServiceAccounts with the IRSA role ARNs**

Terraform outputs the role ARNs. Apply them to the ServiceAccounts that the Router and
subgraph pods use:

```bash
# Get role ARNs from Terraform output
ROUTER_ROLE_ARN=$(terraform output -raw apollo_router_role_arn)

# Annotate the ServiceAccount in the cluster
kubectl annotate serviceaccount apollo-router \
  --namespace graphql-platform \
  eks.amazonaws.com/role-arn="$ROUTER_ROLE_ARN" \
  --overwrite
```

---

## State Management

Remote state is stored in S3 with DynamoDB locking. This prevents concurrent applies
from two engineers or two CI runs corrupting the state file.

```hcl
# backend.tf (not shown in the file listing but required for production use)
terraform {
  backend "s3" {
    bucket         = "my-org-terraform-state"
    key            = "graphql-platform/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    kms_key_id     = "arn:aws:kms:us-east-1:123456789012:key/mrk-abc123"

    # DynamoDB table provides optimistic locking to prevent concurrent applies.
    # The table must have a partition key named "LockID" of type String.
    dynamodb_table = "terraform-lock"
  }
}
```

**S3 bucket configuration requirements:**
- Versioning enabled (allows state rollback)
- Server-side encryption with KMS key
- Block all public access
- Bucket policy restricting access to the platform team IAM role

**DynamoDB table:**
- Table name: `terraform-lock`
- Partition key: `LockID` (String)
- Billing mode: PAY_PER_REQUEST (lock operations are infrequent)

---

## Workspace-Specific Variable Values

Terraform workspaces share the same `.tf` files but use different variable values.
Use a `terraform.tfvars` file per workspace or pass `-var` flags in CI.

| Variable | staging | production |
|---|---|---|
| `eks_cluster_name` | `graphql-platform-staging` | `graphql-platform-production` |
| `redis_node_type` | `cache.t4g.medium` | `cache.r7g.large` |
| `redis_num_replicas` | `1` | `2` |
| `graphos_variant` | `staging` | `production` |
| `schema_introspection_enabled` | `true` | `false` |

---

## Key Design Decisions

**One root module, two workspaces rather than two directories.** A separate directory
per environment creates drift — engineers modify staging configs without porting the
change to production. A single module with workspace-differentiated variables ensures
structural parity between environments.

**IRSA over node IAM roles.** Attaching IAM policies to the EKS node group gives every
pod on the node access to all policies. IRSA binds a specific IAM role to a specific
Kubernetes ServiceAccount, so the Apollo Router pod can only access the secrets it needs,
not the products subgraph's RDS credentials. This is the least-privilege model for EKS.

**Redis auth token generated by Terraform and stored in Secrets Manager.** The alternative
(a pre-created token stored in a human-readable config file) is a common credential leak
vector. Terraform generates the token with `random_password`, stores it in Secrets Manager
immediately, and never outputs it in plaintext. The Apollo Router retrieves the token
from Secrets Manager at startup via IRSA.

**Apollo GraphOS API key scoped to publish only.** The CI/CD key created by Terraform
cannot administer the graph (rename, delete, change settings). If the key is leaked from
a CI environment, the blast radius is limited to unauthorized schema publishes, not
administrative takeover of the graph.

---

## Related Documentation

- `../../docs/11-ci-cd-automation/` — CI/CD pipeline integration, Terraform in GitHub
  Actions, plan/apply workflows
- `../../docs/15-kubernetes-deployment/` — Kubernetes deployment patterns, IRSA setup,
  ServiceAccount annotations, Helm chart integration
- `../../examples/06-kubernetes/` — Kubernetes manifests for the Apollo Router and
  subgraph services (references IRSA role ARNs from Terraform outputs)
- `../../examples/02-apollo-router/` — Apollo Router configuration including Redis cache
  and Secrets Manager secret references
