# Apollo GraphOS Resources — Terraform Configuration
#
# Companion documentation: ../../docs/11-ci-cd-automation/
#
# This file provisions all Apollo GraphOS resources and the AWS Secrets Manager
# secret that stores the GraphOS API key for use by CI/CD pipelines and the
# Apollo Router at runtime.
#
# Resources created:
#   - apollographql_graph            — the supergraph entity in GraphOS
#   - apollographql_variant (x2)     — staging and production variants
#   - apollographql_api_key          — scoped key for CI publish operations
#   - aws_secretsmanager_secret      — secret container for the API key
#   - aws_secretsmanager_secret_version — the actual key value
#
# Provider requirements: apollographql/graphos ~> 0.3, hashicorp/aws ~> 5.30

terraform {
  required_providers {
    apollographql = {
      source  = "apollographql/graphos"
      # Pin to a minor version range. Patch releases are backward-compatible;
      # minor bumps may add required fields. Lock to ~> 0.3 until the provider
      # reaches 1.0 and stabilizes its API.
      version = "~> 0.3"
    }
    aws = {
      source  = "hashicorp/aws"
      # AWS provider 5.x is required for ElastiCache Redis 7 support and the
      # latest IRSA improvements. Do not use 4.x — it lacks several resource
      # arguments used in this configuration.
      version = "~> 5.30"
    }
  }
}

# ---------------------------------------------------------------------------
# Provider: apollographql/graphos
# ---------------------------------------------------------------------------

provider "apollographql" {
  # The Apollo API key is read from the APOLLO_KEY environment variable.
  # Never hard-code this value. In CI, inject it from a secrets manager
  # (AWS Secrets Manager, GitHub Actions secrets, Vault).
  # The provider will fail initialization if APOLLO_KEY is unset.
  #
  # Required scope: Graph Admin (for creating graphs and variants)
  # In practice, organizations create a dedicated service account key with
  # Admin scope for Terraform, separate from the CI publish-only key.
  api_key = var.apollo_admin_key
}

# ---------------------------------------------------------------------------
# Variable declarations for this file
# (In a real module these would live in variables.tf)
# ---------------------------------------------------------------------------

variable "apollo_admin_key" {
  description = "Apollo GraphOS Admin API key. Inject from environment — never commit this value."
  type        = string
  sensitive   = true
}

variable "graphos_graph_id" {
  description = "The Apollo GraphOS graph ID (slug). Must be globally unique within the Apollo platform."
  type        = string
  # Example: "my-platform-graph"
}

variable "graphos_graph_title" {
  description = "Human-readable display name for the graph in the Apollo Studio UI."
  type        = string
  default     = "My Platform Graph"
}

variable "aws_region" {
  description = "AWS region for Secrets Manager and other regional resources."
  type        = string
  default     = "us-east-1"
}

variable "environment_tag" {
  description = "Environment tag applied to all AWS resources (staging or production)."
  type        = string
  validation {
    condition     = contains(["staging", "production"], var.environment_tag)
    error_message = "environment_tag must be 'staging' or 'production'."
  }
}

# ---------------------------------------------------------------------------
# Resource: apollographql_graph
#
# The graph represents the entire supergraph entity in Apollo GraphOS.
# Variants (see below) are children of this graph and correspond to deployment
# environments. The graph ID becomes part of all API key prefixes and is
# referenced in rover CLI commands.
# ---------------------------------------------------------------------------

resource "apollographql_graph" "platform" {
  # graph_id must be a lowercase, hyphen-separated slug. It cannot be changed
  # after creation without deleting and recreating the graph, which would
  # invalidate all existing API keys.
  graph_id = var.graphos_graph_id

  # title appears in the Apollo Studio UI and is purely cosmetic.
  title = var.graphos_graph_title

  # description is shown on the graph overview page in Studio.
  description = "Federated supergraph for the platform team. Managed by Terraform."

  # visibility controls whether unauthenticated users can view the schema
  # on the public Apollo registry. "private" is the correct setting for
  # internal enterprise graphs.
  visibility = "private"
}

# ---------------------------------------------------------------------------
# Resource: apollographql_variant (staging)
#
# The staging variant receives schema publishes from the CI pipeline on
# feature branches and the main branch before promotion to production.
# Public introspection is enabled so internal developers can explore the
# schema without credentials.
# ---------------------------------------------------------------------------

resource "apollographql_variant" "staging" {
  # graph_id links this variant to its parent graph.
  graph_id = apollographql_graph.platform.graph_id

  # variant_name appears in rover CLI references: my-graph@staging
  variant_name = "staging"

  # is_protected_variant prevents accidental deletion via the API.
  # Staging should be protected to avoid breaking the CI pipeline.
  is_protected_variant = true

  # schema_introspection_enabled allows any client to introspect the schema
  # without authentication. Acceptable in staging where the graph is not
  # publicly reachable, but must be false in production.
  schema_introspection_enabled = true

  # has_schema_proposals enables the schema proposal workflow for this variant.
  # Teams can submit, review, and approve schema changes before publishing.
  has_schema_proposals = true

  depends_on = [apollographql_graph.platform]
}

# ---------------------------------------------------------------------------
# Resource: apollographql_variant (production)
#
# The production variant serves live traffic. Introspection is disabled to
# prevent schema enumeration by external parties. Schema proposals are enabled
# so changes must go through review before hitting production.
# ---------------------------------------------------------------------------

resource "apollographql_variant" "production" {
  graph_id = apollographql_graph.platform.graph_id

  variant_name = "production"

  is_protected_variant = true

  # Disable introspection in production. This prevents clients from
  # discovering the full schema structure, which is valuable both for
  # security hardening (reduces attack surface for introspection-based
  # attacks) and for controlling the API surface that is officially supported.
  schema_introspection_enabled = false

  # Production proposals require approval before publish is allowed.
  has_schema_proposals = true

  depends_on = [apollographql_graph.platform]
}

# ---------------------------------------------------------------------------
# Resource: apollographql_api_key
#
# A scoped API key for CI/CD pipeline use. This key has publish-only scope,
# meaning it can push subgraph SDL documents to GraphOS but cannot perform
# administrative operations (rename graph, delete variants, manage members).
#
# If this key is accidentally committed to source control or exposed in CI
# logs, the blast radius is limited to unauthorized schema publishes.
# Rotate this key by tainting this resource and applying.
# ---------------------------------------------------------------------------

resource "apollographql_api_key" "ci_publish" {
  graph_id = apollographql_graph.platform.graph_id

  # key_name is a human-readable label shown in the Apollo Studio key management UI.
  # Include the environment and purpose so the key can be identified and rotated
  # independently from other keys.
  key_name = "terraform-managed-ci-publish-${var.environment_tag}"

  # role controls what operations the key can perform.
  # GRAPH_ADMIN — full administrative access (use for Terraform only)
  # CONTRIBUTOR  — schema publish, operation registry (use for CI/CD)
  # OBSERVER     — read-only schema access
  # DOCUMENTER   — schema description editing only
  role = "CONTRIBUTOR"
}

# ---------------------------------------------------------------------------
# Data source: apollographql_subgraph
#
# Reference an existing subgraph by name and variant. This is used to read
# the current published schema for inspection or to compose cross-subgraph
# outputs without managing the subgraph as a Terraform resource.
#
# Subgraphs are typically not managed by Terraform directly — they are
# published by the owning service's CI/CD pipeline via rover. Terraform
# manages the graph and variant containers; individual subgraph SDL is
# owned by the subgraph team.
# ---------------------------------------------------------------------------

data "apollographql_subgraph" "products" {
  graph_id     = apollographql_graph.platform.graph_id
  variant_name = apollographql_variant.production.variant_name

  # subgraph_name matches the name used in `rover subgraph publish --name`
  subgraph_name = "products"
}

data "apollographql_subgraph" "users" {
  graph_id      = apollographql_graph.platform.graph_id
  variant_name  = apollographql_variant.production.variant_name
  subgraph_name = "users"
}

# ---------------------------------------------------------------------------
# AWS Secrets Manager: Store the GraphOS CI/CD API key
#
# The API key generated above is stored in AWS Secrets Manager so that:
# 1. The Apollo Router can retrieve it at startup (via IRSA — no env var)
# 2. CI/CD pipelines retrieve it without hard-coding credentials
# 3. Key rotation is a single Terraform taint+apply, not a multi-system update
#
# The secret ARN is exported as an output so the IRSA policy in
# eks-irsa-roles.tf can scope read access to exactly this secret.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "apollo_ci_key" {
  # Naming convention: environment/service/purpose
  # Using a path prefix allows IAM policies to grant access to all secrets
  # under a prefix (e.g., "graphql-platform/production/*") without listing
  # individual ARNs.
  name = "graphql-platform/${var.environment_tag}/apollo-ci-key"

  description = "Apollo GraphOS CI/CD API key with CONTRIBUTOR scope. Managed by Terraform. Rotate by tainting apollographql_api_key.ci_publish."

  # recovery_window_in_days specifies the deletion delay before the secret is
  # permanently deleted. 7 days is the minimum; use 30 days in production to
  # allow for accidental deletion recovery. Set to 0 to force immediate deletion
  # (only in development/testing environments).
  recovery_window_in_days = 30

  tags = {
    Environment = var.environment_tag
    ManagedBy   = "terraform"
    Service     = "graphql-platform"
    # cost allocation tag — important for attributing Secrets Manager costs
    # to the right team in multi-account AWS environments
    Team        = "platform"
  }
}

resource "aws_secretsmanager_secret_version" "apollo_ci_key" {
  secret_id = aws_secretsmanager_secret.apollo_ci_key.id

  # The actual API key value from the apollographql_api_key resource.
  # We store the full key string (service:<graph-id>:<hash>) as the secret value.
  # The Apollo Router and rover CLI expect the full prefixed format.
  secret_string = apollographql_api_key.ci_publish.key

  # lifecycle prevent_destroy is intentionally NOT set here because key rotation
  # requires destroying and recreating the secret version. If you need to prevent
  # accidental destruction, set it on the secret (not the version) resource.
}

# ---------------------------------------------------------------------------
# AWS Secrets Manager: Store the Apollo Router key
#
# A separate secret holds the Apollo API key used by the Apollo Router at
# runtime for schema usage reporting and operation monitoring. This is the
# key the Router reads on startup, separate from the CI publish key.
# Using separate secrets allows separate rotation schedules and separate
# IAM access grants.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "apollo_router_key" {
  name        = "graphql-platform/${var.environment_tag}/apollo-router-key"
  description = "Apollo GraphOS API key for Apollo Router runtime (schema reporting, operation monitoring). Managed by Terraform."

  recovery_window_in_days = 30

  tags = {
    Environment = var.environment_tag
    ManagedBy   = "terraform"
    Service     = "apollo-router"
    Team        = "platform"
  }
}

resource "aws_secretsmanager_secret_version" "apollo_router_key" {
  secret_id = aws_secretsmanager_secret.apollo_router_key.id

  # This references a variable rather than a Terraform-managed resource key
  # because the Router key is typically a long-lived Admin key managed outside
  # of this module. Inject it via a tfvars file or CI environment variable.
  secret_string = var.apollo_router_api_key
}

variable "apollo_router_api_key" {
  description = "Apollo GraphOS API key for the Apollo Router runtime (not the CI publish key)."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "graph_id" {
  description = "The Apollo GraphOS graph ID. Use in rover CLI: rover subgraph publish <graph_id>@<variant>"
  value       = apollographql_graph.platform.graph_id
}

output "staging_variant_name" {
  description = "The staging variant name. References: my-graph@staging"
  value       = apollographql_variant.staging.variant_name
}

output "production_variant_name" {
  description = "The production variant name. References: my-graph@production"
  value       = apollographql_variant.production.variant_name
}

output "ci_api_key_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the CI/CD Apollo API key. Used in IRSA IAM policies."
  value       = aws_secretsmanager_secret.apollo_ci_key.arn
}

output "router_api_key_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Apollo Router API key. Used in IRSA IAM policies."
  value       = aws_secretsmanager_secret.apollo_router_key.arn
}

output "products_subgraph_schema_hash" {
  description = "The current schema hash of the products subgraph in production."
  value       = data.apollographql_subgraph.products.active_schema_hash
}
