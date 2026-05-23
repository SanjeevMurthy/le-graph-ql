# EKS IRSA Roles — IAM Roles for Service Accounts
#
# Companion documentation: ../../docs/15-kubernetes-deployment/
#
# IRSA (IAM Roles for Service Accounts) allows Kubernetes pods to assume AWS IAM
# roles without static credentials. The mechanism works via the EKS OIDC provider:
# the kubelet projects a signed service account token into the pod, and the AWS STS
# AssumeRoleWithWebIdentity API validates the token against the OIDC provider and
# returns temporary credentials.
#
# Three roles are created:
#   1. apollo-router-role      — for the Apollo Router pod in graphql-platform namespace
#   2. products-subgraph-role  — for the products service in team-products namespace
#   3. github-actions-ci-role  — for GitHub Actions via OIDC federation (not IRSA)
#
# Usage after apply:
#   kubectl annotate serviceaccount <sa-name> -n <namespace> \
#     eks.amazonaws.com/role-arn=$(terraform output -raw <role_output_name>)
#
# Provider requirements: hashicorp/aws ~> 5.30

# ---------------------------------------------------------------------------
# Variable declarations
# ---------------------------------------------------------------------------

variable "eks_cluster_name" {
  description = "Name of the EKS cluster. Used to look up the OIDC provider URL."
  type        = string
}

variable "github_org" {
  description = "GitHub organization name for the OIDC trust policy. Used to scope GitHub Actions role assumption to this org only."
  type        = string
  # Example: "my-org"
}

variable "github_repo" {
  description = "GitHub repository name (without org prefix) for the CI/CD role trust policy."
  type        = string
  # Example: "graphql-platform"
}

variable "aws_account_id" {
  description = "AWS account ID. Used in ARN construction for resource-based policy scoping."
  type        = string
}

# ---------------------------------------------------------------------------
# Data sources: EKS cluster and OIDC provider
# ---------------------------------------------------------------------------

# Retrieve the EKS cluster metadata to extract the OIDC provider URL.
# The OIDC provider URL is embedded in the cluster's identity configuration
# and has the form: https://oidc.eks.<region>.amazonaws.com/id/<cluster-id>
data "aws_eks_cluster" "platform" {
  name = var.eks_cluster_name
}

# Look up the OIDC provider resource in IAM.
# The provider must be created separately (typically when provisioning the EKS cluster).
# aws_iam_openid_connect_provider gives us the provider ARN needed for trust policies.
data "aws_iam_openid_connect_provider" "eks" {
  # The OIDC provider URL from the cluster — strip the https:// prefix because
  # aws_iam_openid_connect_provider.url does not include it.
  url = data.aws_eks_cluster.platform.identity[0].oidc[0].issuer
}

# Extract the OIDC provider URL without the https:// prefix.
# Trust policy conditions use the bare URL as the principal identifier.
locals {
  oidc_provider_url = replace(
    data.aws_eks_cluster.platform.identity[0].oidc[0].issuer,
    "https://",
    ""
  )

  # OIDC provider ARN shorthand for reuse in trust policies
  oidc_provider_arn = data.aws_iam_openid_connect_provider.eks.arn
}

# ---------------------------------------------------------------------------
# IAM Role 1: Apollo Router
#
# The Apollo Router pod runs in the graphql-platform namespace under the
# apollo-router ServiceAccount. Its IAM permissions are:
#   - Read the Apollo API key from Secrets Manager (for schema reporting)
#   - Read the Redis auth token from Secrets Manager
#   - Read configuration parameters from SSM Parameter Store
#   - The Redis cluster is accessed via VPC networking — no IAM needed for
#     the connection itself, but ElastiCache IAM auth (when configured) would
#     require elasticache:Connect permission.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "apollo_router_trust" {
  statement {
    effect = "Allow"

    principals {
      type = "Federated"
      # The OIDC provider ARN acts as the principal for IRSA trust policies.
      identifiers = [local.oidc_provider_arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      # The sub claim in the projected service account token identifies the
      # specific namespace and ServiceAccount. Scoping to the exact sub value
      # prevents other ServiceAccounts in the cluster from assuming this role.
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:graphql-platform:apollo-router"]
    }

    condition {
      test     = "StringEquals"
      # Require the audience claim to be sts.amazonaws.com.
      # This prevents tokens issued for other audiences (e.g., third-party OIDC
      # consumers) from being used to assume this AWS role.
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "apollo_router_permissions" {
  # Allow the Router to read the Apollo API key from Secrets Manager.
  # Scoped to the exact secret ARN — not a prefix — to enforce least privilege.
  statement {
    sid    = "ReadApolloRouterKey"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      # Reference the secret ARN created in graphos-resources.tf.
      # In a real module, pass this as a variable or use a data source.
      aws_secretsmanager_secret.apollo_router_key.arn,
    ]
  }

  # Allow the Router to read the Redis auth token.
  statement {
    sid    = "ReadRedisAuthToken"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      # elasticache-redis.tf creates this secret; reference its ARN.
      aws_secretsmanager_secret.redis_auth_token.arn,
    ]
  }

  # Allow the Router to read router configuration from SSM Parameter Store.
  # Parameters are stored under /graphql-platform/<env>/router/ prefix.
  statement {
    sid    = "ReadRouterConfig"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/graphql-platform/${var.environment_tag}/router/*",
    ]
  }

  # Allow the Router to use KMS to decrypt SSM SecureString parameters.
  # Required when parameters are encrypted with a customer-managed KMS key
  # rather than the default AWS-managed key.
  statement {
    sid    = "DecryptSSMParameters"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [
      "arn:aws:kms:${var.aws_region}:${var.aws_account_id}:key/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apollo_router" {
  name = "graphql-platform-apollo-router-${var.environment_tag}"

  # The trust policy defines who can assume this role.
  # Using the IRSA mechanism: the EKS OIDC provider validates the projected
  # service account token and the trust condition gates assumption to the
  # specific namespace/ServiceAccount pair.
  assume_role_policy = data.aws_iam_policy_document.apollo_router_trust.json

  # max_session_duration controls how long temporary credentials are valid.
  # 3600 seconds (1 hour) is the default. Shorter durations reduce the window
  # of exposure if credentials are leaked, but require more frequent renewals.
  # The AWS SDK and Kubernetes token rotator handle renewal automatically.
  max_session_duration = 3600

  tags = {
    Environment = var.environment_tag
    ManagedBy   = "terraform"
    Service     = "apollo-router"
    Team        = "platform"
  }
}

resource "aws_iam_role_policy" "apollo_router_permissions" {
  name   = "apollo-router-permissions"
  role   = aws_iam_role.apollo_router.id
  policy = data.aws_iam_policy_document.apollo_router_permissions.json
}

# ---------------------------------------------------------------------------
# IAM Role 2: Products Subgraph
#
# The products subgraph pod runs in the team-products namespace under the
# products-subgraph ServiceAccount. Its IAM permissions are scoped to:
#   - Read its own database credentials from Secrets Manager
#   - Access the PostgreSQL RDS instance (IAM authentication)
#   - Read product-specific configuration from SSM
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "products_subgraph_trust" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      # team-products namespace, products-subgraph ServiceAccount
      values   = ["system:serviceaccount:team-products:products-subgraph"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "products_subgraph_permissions" {
  # Read database credentials from Secrets Manager.
  # The products subgraph stores its RDS password under a dedicated path
  # separate from other services, preventing cross-service secret access.
  statement {
    sid    = "ReadProductsDbCredentials"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:team-products/${var.environment_tag}/db-credentials*",
    ]
  }

  # Read products-specific configuration from SSM.
  # The /team-products/ prefix namespace ensures the products team manages
  # their own parameters without platform team involvement.
  statement {
    sid    = "ReadProductsConfig"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/team-products/${var.environment_tag}/*",
    ]
  }

  # Allow RDS IAM authentication for the products PostgreSQL instance.
  # RDS IAM auth generates a short-lived token (15-minute TTL) in place of
  # a static password. The rds-db:connect action is required for this.
  #
  # Resource format: arn:aws:rds-db:<region>:<account>:dbuser:<db-resource-id>/<iam-user>
  # The db-resource-id is the unique RDS resource identifier (not the instance ID).
  statement {
    sid    = "RDSIAMAuthentication"
    effect = "Allow"
    actions = [
      "rds-db:connect",
    ]
    resources = [
      "arn:aws:rds-db:${var.aws_region}:${var.aws_account_id}:dbuser:${var.products_db_resource_id}/products_app_user",
    ]
  }

  # KMS decrypt for encrypted SSM parameters
  statement {
    sid    = "DecryptProductsSSMParameters"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [
      "arn:aws:kms:${var.aws_region}:${var.aws_account_id}:key/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

variable "products_db_resource_id" {
  description = "RDS resource identifier for the products database (format: db-XXXXXXXXXXXXXXXX). Used in the rds-db:connect IAM resource ARN for IAM authentication."
  type        = string
}

resource "aws_iam_role" "products_subgraph" {
  name               = "graphql-platform-products-subgraph-${var.environment_tag}"
  assume_role_policy = data.aws_iam_policy_document.products_subgraph_trust.json
  max_session_duration = 3600

  tags = {
    Environment = var.environment_tag
    ManagedBy   = "terraform"
    Service     = "products-subgraph"
    Team        = "team-products"
  }
}

resource "aws_iam_role_policy" "products_subgraph_permissions" {
  name   = "products-subgraph-permissions"
  role   = aws_iam_role.products_subgraph.id
  policy = data.aws_iam_policy_document.products_subgraph_permissions.json
}

# ---------------------------------------------------------------------------
# IAM Role 3: GitHub Actions CI/CD
#
# This role is assumed by GitHub Actions via OIDC federation — not IRSA.
# GitHub exposes an OIDC provider at https://token.actions.githubusercontent.com
# that issues tokens containing claims about the workflow, repo, and branch.
#
# The role is scoped to:
#   - Read the Apollo CI/CD API key from Secrets Manager (to run rover subgraph publish)
#   - Describe EKS clusters (for kubectl context configuration in deploy steps)
#   - ECR push/pull access for Router and subgraph container images
# ---------------------------------------------------------------------------

# Data source: GitHub Actions OIDC provider
# This provider is global (not regional) and is shared across all repos
# in the organization. Create it once per AWS account.
data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_actions_ci_trust" {
  statement {
    effect = "Allow"

    principals {
      type = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github_actions.arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    # Scope trust to tokens issued for workflows in the specific repo.
    # The sub claim format is: repo:<org>/<repo>:ref:refs/heads/<branch>
    # or repo:<org>/<repo>:environment:<env-name>
    # Using StringLike with wildcard allows any branch or environment in the repo.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      # GitHub Actions tokens use "sts.amazonaws.com" as the audience
      # when configured for AWS credential exchange.
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "github_actions_ci_permissions" {
  # Read the Apollo CI publish API key from Secrets Manager.
  # CI needs this to call `rover subgraph publish` in the schema publish step.
  statement {
    sid    = "ReadApolloCIKey"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      aws_secretsmanager_secret.apollo_ci_key.arn,
    ]
  }

  # Describe EKS clusters so CI can generate a kubeconfig for deployment steps.
  # eks:DescribeCluster is required by `aws eks update-kubeconfig`.
  statement {
    sid    = "DescribeEKSCluster"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
      "eks:ListClusters",
    ]
    resources = [
      "arn:aws:eks:${var.aws_region}:${var.aws_account_id}:cluster/${var.eks_cluster_name}",
    ]
  }

  # ECR login and image push/pull for building and deploying container images.
  # GetAuthorizationToken is a global action (resource: *) — it cannot be scoped
  # to a specific registry. The repository-specific actions (BatchCheckLayer,
  # PutImage, etc.) are scoped to the platform and subgraph image repositories.
  statement {
    sid    = "ECRLogin"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]  # GetAuthorizationToken cannot be scoped by resource
  }

  statement {
    sid    = "ECRPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [
      # Scope push/pull to the specific ECR repositories for this platform.
      "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/graphql-platform/*",
    ]
  }
}

resource "aws_iam_role" "github_actions_ci" {
  name               = "graphql-platform-github-actions-ci-${var.environment_tag}"
  assume_role_policy = data.aws_iam_policy_document.github_actions_ci_trust.json

  # GitHub Actions workflows typically complete within 30-60 minutes.
  # 3600 seconds covers most workflows with margin for slow builds.
  max_session_duration = 3600

  tags = {
    Environment = var.environment_tag
    ManagedBy   = "terraform"
    Service     = "ci-cd"
    Team        = "platform"
  }
}

resource "aws_iam_role_policy" "github_actions_ci_permissions" {
  name   = "github-actions-ci-permissions"
  role   = aws_iam_role.github_actions_ci.id
  policy = data.aws_iam_policy_document.github_actions_ci_permissions.json
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "apollo_router_role_arn" {
  description = "ARN of the IAM role for the Apollo Router pod. Annotate the apollo-router ServiceAccount in the graphql-platform namespace with this ARN."
  value       = aws_iam_role.apollo_router.arn
}

output "products_subgraph_role_arn" {
  description = "ARN of the IAM role for the products subgraph pod. Annotate the products-subgraph ServiceAccount in team-products namespace."
  value       = aws_iam_role.products_subgraph.arn
}

output "github_actions_ci_role_arn" {
  description = "ARN of the IAM role for GitHub Actions CI/CD. Configure in the GitHub Actions workflow with: role-to-assume: <this ARN>"
  value       = aws_iam_role.github_actions_ci.arn
}

output "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider. Required if adding new IRSA roles for additional subgraphs."
  value       = local.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "URL of the EKS OIDC provider (without https:// prefix). Use in trust policy condition variable construction."
  value       = local.oidc_provider_url
}
