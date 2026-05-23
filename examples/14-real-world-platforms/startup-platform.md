# Startup GraphQL Platform Reference Architecture

Companion docs: `../../docs/23-production-case-studies/`, `../../docs/08-supergraph-architecture/`

---

## Context

This reference architecture is designed for a startup or early-stage product team with the following characteristics:

- 30-60 engineers total across 4-8 product teams
- No dedicated infrastructure or platform team; engineering time is precious
- 5-10 subgraphs covering the core product domains
- Primary concern: shipping product features quickly without accumulating technical debt that blocks future scaling
- Budget constraint: minimize paid tooling until clear ROI is established

The guiding principle at this stage is deliberate restraint. The temptation is to build the "right" architecture from day one — 20 subgraphs, full GitOps, OPA policies — but premature complexity is as harmful as technical debt. This architecture makes the minimum commitments required for a healthy GraphQL platform with clean paths to upgrade as the team grows.

---

## 1. Team Topology

At the startup scale, there is no GraphQL Platform Team. Responsibility for GraphQL is distributed across product teams, with a lightweight coordination mechanism.

**Ownership model:**

- Each product team owns one or more subgraphs end-to-end: schema design, resolver implementation, DataLoader setup, deployment, and on-call.
- One engineer per team (or at most, two) self-designates as the "GraphQL champion" — the person who stays current with GraphQL best practices, reviews schema PRs for their team, and represents their team in cross-team schema discussions.
- Champions form a lightweight "GraphQL Guild" that meets bi-weekly to discuss patterns, share learnings, and coordinate cross-cutting changes.

**What to avoid at this stage:**

- A central "GraphQL team" that becomes a bottleneck — product teams will route around it and abandon GraphQL for REST when they need to move fast.
- Strict schema RFC processes — they are valuable later but at 5 subgraphs, the overhead outweighs the benefit.
- Formal breaking change management — at this stage, moving fast and communicating informally is more valuable than process.

The investment in champions pays off: each champion understands the full GraphQL toolchain and can onboard their team. When the organization is ready to form a platform team, champions are the natural hire pool.

---

## 2. Technology Stack

| Component | Choice | Rationale |
|---|---|---|
| Router | Apollo Router (open source) | Free, production-grade, performs well to millions of QPS. No vendor lock-in for core routing. |
| Schema registry | Apollo GraphOS (free tier) | Free tier supports 1 graph, unlimited schema pushes, 10M operations/month. Adequate for early-stage. |
| Subgraph framework | `@apollo/subgraph` + Apollo Server 4 | Best-documented, largest community, TypeScript support. |
| CI/CD | GitHub Actions | Most startups are already on GitHub. Rover CLI integrates natively. |
| Subgraph hosting | Railway, Render, or Fly.io | Low operational overhead, reasonable free tiers, auto-scaling. Avoid Kubernetes until you have a platform engineer. |
| Error tracking | Sentry | Best-in-class free tier, native Node.js and TypeScript support. |
| Monorepo tooling | Turborepo | Fast build caching, simple configuration, actively maintained. |

**Apollo GraphOS free tier limits (as of 2024):**

| Limit | Free Tier |
|---|---|
| Graphs | 1 |
| Variants | 3 (dev, staging, prod) |
| Operations tracked per month | 10M |
| Schema checks | Unlimited |
| Operation checks | Unlimited (against last 30 days) |
| Schema push retention | 30 days |

At 10M operations/month, you would need roughly 3-4 requests/second sustained to hit the limit. Most early-stage products are well below this. Upgrade to the serverless plan when you approach the limit; the cost is proportional to usage.

---

## 3. Subgraph Layout — Recommended Starting Split

For a typical SaaS product, four to six subgraphs is the right starting point. Below is the recommended split and the rationale for each boundary:

```
subgraphs/
  users/       — Authentication, user profiles, teams, roles, permissions
  billing/     — Subscriptions, invoices, payment methods, feature entitlements
  content/     — The core product domain (replace "content" with your domain noun)
  notifications/ — Email, push, in-app notifications; notification preferences
```

**Why these four and not more:**

Domain boundaries at the startup stage should follow team ownership, not theoretical ideal boundaries. If you have four product teams (core product, growth/billing, user management, notifications), four subgraphs means each team owns exactly one subgraph. Perfect alignment.

**Why not separate subgraphs for every resource type:**

A common startup mistake is creating one subgraph per REST resource or database table — `users-subgraph`, `profiles-subgraph`, `addresses-subgraph`. This multiplies operational overhead (each subgraph needs its own deploy pipeline, health checks, and monitoring) without providing the primary benefit of federation (team autonomy). Wait until two teams would otherwise need to merge conflicts in the same subgraph before splitting it.

**When to add a fifth or sixth subgraph:**

- A new product line or acquisition that should be isolated
- A performance-critical subgraph that needs independent scaling
- A compliance boundary (e.g., HIPAA PHI data isolated from the rest of the graph)
- A new team that owns a distinct domain that has grown out of an existing subgraph

---

## 4. Monorepo Structure

```
repo-root/
  apps/
    web/                    — React/Next.js frontend
    mobile/                 — React Native
    api-gateway/            — Apollo Router (config only, binary is downloaded)
  subgraphs/
    users/
      src/
        schema.graphql
        resolvers/
        datasources/
        __tests__/
      package.json
      tsconfig.json
      Dockerfile
    billing/
      ...
    content/
      ...
    notifications/
      ...
  packages/
    graphql-utils/
      src/
        dataloader-helpers.ts   — Generic DataLoader factory with batch and cache
        auth-middleware.ts      — JWT verification middleware for Apollo Server
        error-types.ts          — Standardized GraphQL error codes and factory functions
        pagination.ts           — Relay cursor pagination helpers
      package.json
    codegen-config/
      codegen.yml               — Shared GraphQL Code Generator configuration
  turbo.json
  package.json
```

### Shared Packages

The `packages/graphql-utils` package is the most important shared library in the monorepo. It prevents every subgraph from re-implementing the same patterns differently.

```typescript
// packages/graphql-utils/src/dataloader-helpers.ts

import DataLoader from 'dataloader';
import type { Pool } from 'pg';

/**
 * Creates a DataLoader for batch-loading records by ID from a PostgreSQL table.
 *
 * @param pool - pg connection pool
 * @param tableName - table to query (used in FROM clause, not parameterized)
 * @param idColumn - primary key column name (default: 'id')
 *
 * Example:
 *   const userLoader = createPgIdLoader(pool, 'users');
 *   const user = await userLoader.load('usr_01ABCDEF');
 */
export function createPgIdLoader<T extends { id: string }>(
  pool: Pool,
  tableName: string,
  idColumn: string = 'id'
): DataLoader<string, T | null> {
  return new DataLoader<string, T | null>(
    async (ids: readonly string[]): Promise<(T | null)[]> => {
      const placeholders = ids.map((_, i) => `$${i + 1}`).join(', ');
      const { rows } = await pool.query<T>(
        `SELECT * FROM ${tableName} WHERE ${idColumn} = ANY(ARRAY[${placeholders}]::text[])`,
        [...ids]
      );

      // DataLoader requires results in the same order as the input keys,
      // and requires an exact 1:1 mapping (null for missing records).
      const rowMap = new Map(rows.map((r) => [r[idColumn as keyof T] as string, r]));
      return ids.map((id) => rowMap.get(id) ?? null);
    },
    {
      // Cache results for the lifetime of this DataLoader instance.
      // DataLoaders are created per-request in the ApolloServer context
      // function, so cache lifetime = request lifetime.
      cache: true,

      // Maximum batch size — do not send more than 1000 IDs in a single
      // IN clause. PostgreSQL can handle more, but large IN clauses can
      // cause query plan instability.
      maxBatchSize: 1000,
    }
  );
}
```

### Turborepo Configuration

```json
// turbo.json
{
  "$schema": "https://turbo.build/schema.json",
  "tasks": {
    "build": {
      // Build outputs are cached; turbo skips rebuilding unchanged packages
      "outputs": ["dist/**"],
      "dependsOn": ["^build"]
    },
    "test": {
      "outputs": [],
      "dependsOn": ["^build"]
    },
    "graphql:check": {
      // Run rover subgraph check for changed subgraphs only
      "outputs": [],
      "cache": false,    // Schema checks should always run against live registry
      "dependsOn": []
    },
    "graphql:publish": {
      "outputs": [],
      "cache": false,
      "dependsOn": ["build", "test"]
    }
  }
}
```

---

## 5. Schema Governance

At the startup scale, governance is lightweight and trust-based. The mechanisms are:

**CODEOWNERS file:**

```
# .github/CODEOWNERS
# GraphQL champion for each subgraph must review schema changes
/subgraphs/users/*.graphql          @team-user-management
/subgraphs/billing/*.graphql        @team-growth
/subgraphs/content/*.graphql        @team-core-product
/subgraphs/notifications/*.graphql  @team-notifications

# Shared packages require review from any two champions
/packages/graphql-utils/            @graphql-champions
```

**PR review guidelines (document in CONTRIBUTING.md):**

- Any new type or field requires GraphQL champion approval
- Breaking schema changes (removing or renaming fields) require a comment from the champion confirming the change is safe (no known clients)
- New subgraphs require async approval from all champions (GitHub discussion, not a meeting)

There is no formal RFC process at this stage. Async GitHub discussions work fine for a team of 50.

---

## 6. CI/CD — GitHub Actions

```yaml
# .github/workflows/graphql.yml
# This single workflow handles schema checks on PR and publishes on merge.
# It runs only when GraphQL-related files change to minimize CI time.

name: GraphQL CI/CD

on:
  push:
    branches: [main]
    paths:
      - 'subgraphs/**'
      - 'packages/graphql-utils/**'
  pull_request:
    paths:
      - 'subgraphs/**'

env:
  APOLLO_KEY: ${{ secrets.APOLLO_KEY }}
  APOLLO_GRAPH_REF: my-graph@main

jobs:
  schema-check:
    # Run on PRs only — checks the proposed schema changes against the registry
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    strategy:
      matrix:
        # Run checks for all subgraphs in parallel
        # Add new subgraphs to this list when created
        subgraph: [users, billing, content, notifications]
      fail-fast: false  # Check all subgraphs even if one fails
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install Rover CLI
        run: |
          curl -sSL https://rover.apollo.dev/nix/latest | sh
          echo "$HOME/.rover/bin" >> $GITHUB_PATH

      - name: Check subgraph schema
        run: |
          rover subgraph check $APOLLO_GRAPH_REF \
            --name ${{ matrix.subgraph }} \
            --schema subgraphs/${{ matrix.subgraph }}/src/schema.graphql

  publish:
    # Run on merge to main — publishes the new schema to the registry
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    strategy:
      matrix:
        subgraph: [users, billing, content, notifications]
      # Publish subgraphs sequentially to avoid composition conflicts
      max-parallel: 1
    steps:
      - uses: actions/checkout@v4

      - name: Install Rover CLI
        run: |
          curl -sSL https://rover.apollo.dev/nix/latest | sh
          echo "$HOME/.rover/bin" >> $GITHUB_PATH

      - name: Publish subgraph schema
        run: |
          rover subgraph publish $APOLLO_GRAPH_REF \
            --name ${{ matrix.subgraph }} \
            --schema subgraphs/${{ matrix.subgraph }}/src/schema.graphql \
            --routing-url https://${{ matrix.subgraph }}.internal.example.com/graphql
```

---

## 7. Observability

At the startup stage, Apollo Studio's built-in observability is sufficient. No additional infrastructure is required.

**Apollo Studio provides:**

- Operation-level performance metrics: latency p50/p95/p99, error rate, request volume
- Field-level usage statistics: which fields are used, by which operations
- Error tracking: which operations are throwing errors and what the errors are
- Schema change history: who changed what and when
- Breaking change detection: which registered client operations would break after a schema change

**Complementing Studio with Sentry:**

Configure Apollo Server's error formatter to report unexpected errors to Sentry:

```typescript
// subgraphs/*/src/server.ts
import * as Sentry from '@sentry/node';

const server = new ApolloServer({
  schema,
  formatError: (formattedError, error) => {
    // Only report unexpected errors — not client errors (bad input, auth failures)
    if (
      formattedError.extensions?.code !== 'BAD_USER_INPUT' &&
      formattedError.extensions?.code !== 'UNAUTHENTICATED' &&
      formattedError.extensions?.code !== 'FORBIDDEN'
    ) {
      Sentry.captureException(error);
    }
    // Return the formatted error to the client (do not expose stack traces)
    return formattedError;
  },
});
```

---

## 8. Cost Profile — When to Upgrade from the Free Tier

| Trigger | Recommended Upgrade |
|---|---|
| Approaching 10M operations/month | Apollo GraphOS Serverless (usage-based pricing) |
| Need more than 3 schema variants | Apollo GraphOS Serverless |
| Need operation registry / persisted queries | Apollo GraphOS Serverless |
| Need schema proposals / governance workflow | Apollo GraphOS Dedicated |
| Need SSO for the Studio UI | Apollo GraphOS Dedicated |
| Regulatory compliance requirements | Apollo GraphOS Dedicated with Enterprise SLA |

The move from free to Serverless is the most common transition point. Serverless pricing is approximately $0.02 per 1,000 operations beyond the free tier (verify current pricing at apollographql.com/pricing). A product doing 50M operations/month would pay approximately $800/month — well within budget for a startup that depends on its API.

---

## 9. Common Startup Mistakes

These are the most frequent mistakes made by startup teams building their first GraphQL platform. Each represents a real cost in technical debt or operational incidents.

**Mistake 1: Too many subgraphs too early**

A common pattern is mapping every REST API endpoint or every database table to its own subgraph. The result: 20 subgraphs owned by a team of 5 engineers. Each subgraph has its own CI pipeline, health checks, deployment manifest, and on-call responsibility. The operational overhead crushes the team. Recommendation: 1 subgraph per team owning it, start with 4-6.

**Mistake 2: Skipping DataLoader**

The most reliable path to production incidents is omitting DataLoader. A query that fetches 10 products with their reviews and authors will issue O(10 * 10 * 10) = 1,000 database queries without DataLoader. With DataLoader, it issues 3 batched queries. DataLoader is not optional — it is a prerequisite for any list field that has nested resolvers.

**Mistake 3: No schema governance until it's too late**

At 5 engineers, informal schema coordination works fine. At 20 engineers, it breaks down. The window between "we need governance" and "we're in pain" is short. Invest in the CODEOWNERS file and champion designation early. The process cost is low; the cost of schema chaos is high.

**Mistake 4: Using `*` imports in resolvers**

GraphQL resolvers frequently end up importing types from multiple subgraphs or packages. Teams that use `import * from '...'` create circular dependency risks that are hard to debug. Use explicit named imports and let TypeScript's strict mode catch missing type exports at build time.

**Mistake 5: Not setting `MAX_QUERY_COMPLEXITY` before going to production**

Without complexity limits, any authenticated (or unauthenticated if the API is public) user can craft a query that exhausts your database connection pool. Set conservative limits (`max_depth: 10`, `MAX_QUERY_COMPLEXITY: 500`) on day one. Tune them upward based on real traffic, but start strict.

---

## Key Design Decisions

**Why Railway/Render over AWS/GCP at this stage:** Managed PaaS platforms eliminate the operational overhead of configuring VPCs, IAM roles, load balancers, and autoscaling groups. A startup that is not yet at the scale where those abstractions provide value should not pay the engineering time cost to operate them. Migrating from Railway to EKS when you have a platform engineer is a week's work; the technical debt is manageable.

**Why Turborepo over Nx at this scale:** Both are viable. Turborepo has simpler configuration and a smaller API surface, which maps better to a startup where not every engineer knows the build tooling. Nx has more power for complex monorepos with many custom generators. Start with Turborepo; switch to Nx if you need its additional features.

**Why max-parallel: 1 in the publish job:** Publishing subgraphs concurrently can cause composition failures if two subgraphs are published simultaneously and each references types from the other. Sequential publication ensures each publication completes and the registry composes successfully before the next one begins. The latency cost (an extra 30 seconds per subgraph) is acceptable in a deployment pipeline.

---

## Related Documentation

- `../../docs/08-supergraph-architecture/` — Technical reference for Apollo Federation v2 composition
- `../../docs/11-ci-cd-automation/` — Complete CI/CD patterns including multi-environment promotion
- `../../docs/09-schema-governance/` — Detailed schema governance processes that grow with your organization
- `../../docs/06-performance-and-scaling/` — DataLoader deep dive and resolver performance patterns
