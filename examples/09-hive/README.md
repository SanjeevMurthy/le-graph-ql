# GraphQL Hive — Schema Registry and Observability Platform

<!-- Companion docs: ../../docs/09-schema-governance/, ../../docs/14-observability/ -->

GraphQL Hive is an open-source schema registry, schema change validation platform, and usage
analytics service for GraphQL APIs. It provides the same class of capabilities as Apollo GraphOS
(formerly Apollo Studio) but is fully open-source, self-hostable, and free to operate at any scale
without per-seat or per-operation pricing.

This example directory demonstrates how to integrate GraphQL Hive into a Federation v2 workflow:
publishing subgraph schemas, enforcing schema checks in CI/CD, routing through the Hive CDN, and
optionally running a fully self-hosted Hive deployment.

---

## What GraphQL Hive Provides

GraphQL Hive is organized around four core capabilities:

**Schema Registry**
Hive stores every published version of every subgraph schema (or a monolithic schema) with full
history. You can compare any two versions, see which team published a change, correlate a schema
version with a git commit, and roll back to a previous version by republishing it.

**Schema Checks (Breaking Change Detection)**
Before merging a pull request that modifies a subgraph schema, `hive schema:check` compares the
proposed schema against the current registry state. It reports added fields (safe), removed fields
(breaking), changed argument types (breaking), and renamed types (breaking). When usage reporting
is enabled, Hive can additionally determine whether a "breaking" field is actually used by any
real clients — suppressing false positives for fields with zero usage.

**Usage Reporting and Analytics**
Subgraphs and the router report executed operations to Hive. The Hive dashboard shows operation
counts, error rates, latency percentiles, and which clients call which fields. This data feeds back
into schema checks: a field that looks unused in code but appears in 10,000 daily operations will
be flagged rather than silently dropped.

**CDN for Supergraph Schema Delivery**
When using Federation v2, the router needs to load the composed supergraph SDL. Hive provides a
CDN endpoint from which Apollo Router (or Hive Gateway) can pull the latest composed supergraph
schema. This is the direct equivalent of the Apollo GraphOS Uplink.

---

## When to Choose Hive Over Apollo GraphOS

| Criterion | Apollo GraphOS | GraphQL Hive |
|-----------|---------------|--------------|
| License | Proprietary (SaaS) | MIT (open source, self-hostable) |
| Pricing | Per-seat + per-operation tiers | Free; infrastructure cost only if self-hosted |
| Self-hosting | No | Yes — full Docker Compose / Kubernetes support |
| Federation support | Federation v1 and v2 | Federation v2, Stitching, standalone |
| Usage-based breaking change detection | Yes (Insights) | Yes (Usage Reporting) |
| Apollo Router compatibility | Native (GraphOS Uplink) | Supported via Hive CDN endpoint |
| Slack / webhook alerts | Yes | Yes |
| SSO / OIDC | Enterprise tier | Included in open-source build |

Choose Hive when:
- Your organization requires data residency control (regulated industries, EU data sovereignty).
- You want to avoid per-operation or per-seat pricing at scale (>50 engineers, >1B ops/month).
- You are already self-hosting your infrastructure and prefer operational consistency.
- You want to contribute to or inspect the schema registry source code.

Choose Apollo GraphOS when:
- You want a fully managed, zero-ops SaaS with SLA guarantees.
- You are deeply invested in the Apollo ecosystem (Apollo Connectors, Cloud Router, Contracts).
- Your team is small and the managed tier fits within the free quota.

---

## Architecture

```
                         Hive Cloud (or Self-Hosted)
                        +---------------------------------+
                        |  Schema Registry (PostgreSQL)   |
  CI/CD pipeline        |  Usage Analytics (ClickHouse)   |
  hive schema:publish   |  CDN (CloudFlare / self-hosted) |
  hive schema:check     +---------------------------------+
         |                        ^            |
         |                        |            | supergraph SDL
         v                        |            v
  Subgraph Services         Usage Reports   Apollo Router
  (users, products,    ------(OpenTelemetry)---> or Hive Gateway
   orders, ...)               from router        |
                                                 v
                                            GraphQL Clients
```

Data flow during a request:
1. A client sends a GraphQL operation to Apollo Router (or Hive Gateway).
2. The router resolves the operation against the supergraph schema loaded from the Hive CDN.
3. The router fans out to subgraphs over HTTP.
4. After the response is sent, the router reports the operation to the Hive Usage service.
5. The Hive Usage service aggregates data into ClickHouse for the dashboard.

Data flow during a schema deployment:
1. CI runs `hive schema:check --service users subgraphs/users/schema.graphql`.
2. Hive composes the proposed schema with all other registered subgraphs and validates it.
3. If the check passes, CI runs `hive schema:publish --service users ...` on merge.
4. Hive publishes the new composed supergraph SDL to its CDN.
5. Apollo Router polls the Hive CDN and loads the updated supergraph within seconds.

---

## File Navigation

| File | Description |
|------|-------------|
| `README.md` | This file. Overview, architecture, quick start. |
| `hive-cli-usage.md` | Complete Hive CLI reference for schema publishing, checking, and usage reporting in a Federation v2 workflow. Includes full GitHub Actions CI/CD job. |
| `hive-router-config.md` | Configuring Apollo Router and Hive Gateway to use the Hive CDN for supergraph schema delivery. Includes usage reporting from the router and schema version pinning. |
| `self-hosted-hive.md` | Running GraphQL Hive self-hosted with Docker Compose. Includes full compose file, OIDC setup, PostgreSQL migrations, backup strategy, and production sizing guide. |

---

## Prerequisites

| Requirement | Version | Purpose |
|-------------|---------|---------|
| Node.js | 18+ | Required to run `@graphql-hive/cli` |
| `@graphql-hive/cli` | Latest | Publish and check schemas, report usage |
| Apollo Router | 1.40+ | Serves the supergraph; polls Hive CDN |
| Docker + Compose | 24+ | Required only for self-hosted Hive |
| A Hive account | — | Cloud: app.graphql-hive.com; or self-hosted |

To create a Hive account and project, visit https://app.graphql-hive.com or run a self-hosted
instance (see `self-hosted-hive.md`). After creating a project of type "Federation", create a
"Registry Write" token for publishing and a "CDN Access" token for router schema delivery.

---

## Quick Start

```bash
# 1. Install the Hive CLI globally
npm install -g @graphql-hive/cli

# 2. Authenticate — set your registry write token as an env var
export HIVE_TOKEN="your-registry-write-token"

# 3. Publish the users subgraph schema to Hive
hive schema:publish \
  --service users \
  --url http://users-service/graphql \
  --author "$(git log -1 --format='%an')" \
  --commit "$(git rev-parse HEAD)" \
  subgraphs/users/schema.graphql

# 4. Check a schema change before merging a PR
hive schema:check \
  --service users \
  subgraphs/users/schema.graphql
```

For configuring Apollo Router to load schemas from the Hive CDN, see `hive-router-config.md`.

---

## Related Documentation

- `../../docs/09-schema-governance/` — Schema governance principles, breaking change policies,
  approval workflows, and schema review processes.
- `../../docs/14-observability/` — Observability strategy for GraphQL: tracing, metrics, usage
  analytics, and alerting.
- `../../docs/11-ci-cd-automation/` — CI/CD pipeline patterns for GraphQL, including schema check
  gates and automated publishing.
- `../../docs/07-federation/` — Apollo Federation v2 architecture and subgraph design patterns.

---

## Key Design Decisions

**Open-source over proprietary registry**
Selecting Hive over Apollo GraphOS was driven by the requirement for full data residency control
and avoidance of per-operation pricing at scale. The operational overhead of self-hosting Hive
(three stateful services: PostgreSQL, ClickHouse, Redis) is acceptable given the cost and
compliance benefits.

**CDN-based schema delivery**
Apollo Router is configured to poll the Hive CDN for the composed supergraph schema rather than
embedding the schema in the container image. This decouples schema deployments from router
deployments: a subgraph schema change takes effect across all router replicas within seconds
without any router restart or redeployment.

**Usage-informed breaking change detection**
Enabling usage reporting from the router provides Hive with field-level usage data. This changes
the schema check from a purely structural analysis to an impact analysis: a breaking change to a
field with zero usage in the past 30 days is treated as safe, reducing false positive friction in
the development workflow.
