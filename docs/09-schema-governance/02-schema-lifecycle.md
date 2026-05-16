# 02 — Schema Field Lifecycle

> **Purpose:** Define the complete lifecycle of a GraphQL schema field from initial addition through active use, deprecation, sunset warning, and final removal. Cover the `@deprecated` directive in depth, deprecation SLA policy, usage analytics tooling, the sunset workflow, and a comprehensive reference of breaking versus safe schema changes.

## Learning Objectives

- [ ] Explain the four lifecycle stages of a schema field and the entry/exit criteria for each stage
- [ ] Use the `@deprecated` directive correctly, including its limitations in the GraphQL specification
- [ ] Apply the 90-day (or 180-day enterprise) deprecation SLA and document it in the schema
- [ ] Query Apollo GraphOS and GraphQL Hive usage reports to identify clients still using deprecated fields
- [ ] Execute the complete sunset workflow: deprecate, notify, monitor, gate on zero usage, remove
- [ ] Classify any schema change as breaking or safe using the complete reference table
- [ ] Implement a field rename using the dual-field migration pattern without a breaking change

---

## Overview: The Problem of Perpetual Fields

GraphQL's "never remove, only add" philosophy is frequently misquoted as an absolute rule. It is not. It is a statement about the natural pressure in GraphQL development: because you cannot version a GraphQL API the way you version a REST endpoint, removals are riskier. Without tooling and process, the risk of removal is high enough that fields accumulate indefinitely — the "append-only schema" anti-pattern.

The lifecycle model solves this by making removal safe rather than preventing it. A field that enters the lifecycle correctly — added with a description, deprecated with a clear reason and replacement, monitored until usage drops to zero, then removed — creates no production incidents. The goal of schema governance is to make this lifecycle the default path, not the exception.

The absence of a lifecycle model creates a specific kind of technical debt: schema bloat. A schema with dozens of deprecated fields, no usage data, and no removal dates is a schema that no team trusts. Developers write defensive queries that handle both the old and new field. New team members learn the wrong API surface. The schema becomes a historical artifact rather than an intentional contract.

### GraphQL Has No Version Number — and That Is Intentional

REST APIs evolve through versioning: `/api/v1/users` and `/api/v2/users` coexist, each with a defined support window. GraphQL deliberately omits versioning from the specification. The reasons are architectural:

- **Versioning at the URL level is coarse-grained.** A REST version bumps the entire API. A GraphQL field is individually addressable — you can deprecate one field while every other field remains stable.
- **Versioning creates duplication.** Maintaining `/v1` and `/v2` doubles the implementation and testing surface. GraphQL's approach is to run the old and new API surface simultaneously through the deprecation period, with the same underlying implementation.
- **Versioning does not solve the coordination problem.** REST versioning requires client teams to migrate just as GraphQL deprecation does. The lifecycle model is equivalent — with better tooling for tracking compliance.

The tradeoff is that GraphQL requires more discipline around individual field lifecycle management than REST versioning. A REST `v1 → v2` migration is visible and mandatory. A GraphQL field deprecation is granular and optional, which makes monitoring usage compliance more important.

---

## Architecture: Field Lifecycle Pipeline

```mermaid
flowchart LR
    subgraph Stage1["Stage 1: Active"]
        A1[Field defined\nin schema]
        A2[Full operation\ncount in registry]
        A3[No @deprecated\ndirective]
    end

    subgraph Stage2["Stage 2: Deprecated"]
        B1[@deprecated added\nwith reason + replacement]
        B2[RFC approved\nand documented]
        B3[Consuming teams\nnotified via changelog]
        B4[Usage monitored\nvia registry analytics]
    end

    subgraph Stage3["Stage 3: Sunset Warning"]
        C1[30 days before\nremoval date]
        C2[Direct notification\nto consuming teams]
        C3[@inaccessible added\nin federation]
        C4[Usage must reach 0\nbefore removal]
    end

    subgraph Stage4["Stage 4: Removed"]
        D1[Field removed\nfrom subgraph SDL]
        D2[Schema published\nto registry]
        D3[Composition validated\nwithout field]
    end

    Stage1 -- "Breaking change RFC\napproved; replacement\nfield exists" --> Stage2
    Stage2 -- "30 days before\nremoval date" --> Stage3
    Stage3 -- "Usage = 0\nor SLA expired" --> Stage4
    Stage4 -- "New field added\nfor next iteration" --> Stage1

    classDef clientNode fill:#dbeafe,stroke:#3B82F6,color:#1e3a8a
    classDef routerNode fill:#e8f4f8,stroke:#0ea5e9,color:#0c4a6e
    classDef subgraphNode fill:#f0fdf4,stroke:#22c55e,color:#14532d
    classDef registryNode fill:#fdf4ff,stroke:#a855f7,color:#581c87
    classDef ciNode fill:#fff7ed,stroke:#f97316,color:#7c2d12

    class A1,A2,A3 subgraphNode
    class B1,B2,B3,B4 ciNode
    class C1,C2,C3,C4 registryNode
    class D1,D2,D3 clientNode
```

---

## Core Concepts

### The Four Lifecycle Stages

#### Stage 1: Active

A field is active from the moment it is published to the schema registry. During its active stage, the field has no `@deprecated` directive, and the schema description should document its purpose, type constraints, and any nullability contract the client can rely on.

Active fields are monitored for usage to inform future deprecation decisions. Apollo GraphOS and GraphQL Hive both record per-field operation counts. Even for active fields, this data is valuable: a field with zero usage in 90 days is a candidate for early deprecation.

**Entry criteria:** Field added to subgraph SDL and published to schema registry.

**Exit criteria:** A replacement is designed, RFC is approved, and the team is ready to begin the migration period.

#### Stage 2: Deprecated

Deprecation is the public commitment to remove a field on a defined schedule. The `@deprecated` directive signals to clients that the field is in its end-of-life stage and provides the replacement. The deprecation date and removal date are documented in the schema description.

A field moves to deprecated only when:
1. A replacement field (or alternative API pattern) is available
2. The RFC has been approved by the schema review board
3. All consuming teams have been notified

**Entry criteria:** RFC approved, replacement field available, `@deprecated` directive added.

**Exit criteria:** 30 days before the removal date (triggers sunset warning stage).

#### Stage 3: Sunset Warning

Thirty days before the scheduled removal date, the field enters the sunset warning stage. The schema team sends a direct notification to all teams that still show active usage of the field in the registry. In federated schemas, `@inaccessible` may be added to hide the field from the supergraph client-facing schema while preserving it in the subgraph SDL for the deprecation period.

If usage has already dropped to zero before the 30-day window, the field may be removed immediately without entering the formal sunset warning stage.

**Entry criteria:** 30 days before removal date OR last usage detected in registry analytics.

**Exit criteria:** Field usage reaches zero in the registry, OR removal date passes.

#### Stage 4: Removed

The field is deleted from the subgraph SDL, the subgraph is published to the registry, and composition is validated without the field. The schema changelog records the removal.

If any production client was still using the field when it was removed and experiences an error, the team follows the schema incident playbook in `04-team-governance.md`.

**Entry criteria:** Zero usage in registry analytics AND (removal date passed OR usage = 0 and removal is approved).

**Exit criteria:** New iteration — the API surface continues without the field.

---

### The @deprecated Directive

The `@deprecated` directive is defined in the GraphQL specification. Its behavior and limitations are important to understand before using it in production.

#### Specification Definition

```graphql
directive @deprecated(
  reason: String = "No longer supported"
) on FIELD_DEFINITION | ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION | ENUM_VALUE
```

The directive accepts one argument, `reason`, which is a human-readable explanation of why the field is deprecated and, critically, what clients should use instead.

#### Field-Level Deprecation (the Common Case)

```graphql
type User {
  """
  The user's login name.

  @deprecated Use `handle` instead. This field will be removed on 2026-09-01.
  Migration guide: https://engineering.internal/schema-rfcs/RFC-042
  """
  username: String! @deprecated(reason: "Use `handle` instead. Removal date: 2026-09-01.")

  """
  The user's unique handle, replacing `username`.
  Handles are unique across the platform and follow the pattern @{handle}.
  """
  handle: String!
}
```

The `reason` string appears in GraphQL explorers (GraphiQL, Apollo Sandbox, Altair) as a tooltip and in introspection results under `deprecationReason`. It should be concise but complete — the client developer reading it in their IDE deserves enough information to migrate without leaving the editor.

#### Argument-Level Deprecation (Added in GraphQL 2021 spec)

Before the October 2021 specification revision, `@deprecated` was only valid on `FIELD_DEFINITION` and `ENUM_VALUE`. The argument-level `@deprecated` was added in the 2021 spec:

```graphql
type Query {
  users(
    role: UserRole
    status: UserStatus @deprecated(reason: "Use `activeOnly: Boolean` instead.")
    activeOnly: Boolean
  ): [User!]!
}
```

Not all GraphQL servers support argument-level `@deprecated` yet. Verify your server library's compliance before using it. Apollo Server (via `graphql-js` 16+) supports it.

#### Input Field Deprecation

Input object fields can also be deprecated, though this is less commonly needed:

```graphql
input CreateUserInput {
  username: String @deprecated(reason: "Use `handle` instead.")
  handle: String!
  email: String!
}
```

#### What @deprecated Does NOT Do

- It does **not** prevent clients from using the field. The field is fully functional; it is only marked for future removal. Clients that ignore the directive will continue to work until the field is actually removed.
- It does **not** change query execution behavior. Deprecated fields are resolved identically to active fields.
- It does **not** set a removal date. The removal date is a governance policy, not a schema feature. Document it in the `reason` string and in the schema description.
- It does **not** automatically notify clients. Notification is a process responsibility, not a schema feature.

---

### Deprecation SLA

The deprecation SLA defines the minimum time between the addition of `@deprecated` and the removal of the field. The SLA protects consuming teams by guaranteeing they have sufficient time to migrate.

| Consumer category | Minimum deprecation SLA | Rationale |
|---|---|---|
| Internal teams (all server-side) | 90 days | Teams can update their operations within a sprint cycle |
| Internal mobile clients (iOS/Android) | 90 days | App store review cycles add 1–2 weeks per release |
| Enterprise clients (partner APIs) | 180 days | Partner development cycles, procurement, and testing windows are longer |
| Public API consumers (open ecosystem) | 365 days | Unknown client diversity; maximum conservative window |

The SLA clock starts on the date the `@deprecated` directive is published to the production schema registry — not the date the RFC was approved, not the date the PR merged to the feature branch.

#### SLA Documentation in Schema

```graphql
type Order {
  """
  The total order amount in cents (USD).

  DEPRECATED: Use `totalAmountV2` instead, which supports multi-currency.
  Deprecated on: 2026-01-15
  Removal date: 2026-04-15 (90-day SLA)
  RFC: https://github.com/org/repo/pull/1234
  """
  totalAmount: Int @deprecated(reason: "Use `totalAmountV2` for multi-currency support. Removal: 2026-04-15.")

  """
  The total order amount with currency information.
  Supports USD, EUR, GBP, JPY, and AUD.
  """
  totalAmountV2: Money!
}

type Money {
  amount: Int!
  currency: CurrencyCode!
}

enum CurrencyCode {
  USD
  EUR
  GBP
  JPY
  AUD
}
```

---

### Usage Analytics: Identifying Active Consumers

The most powerful tool for safe field removal is knowing exactly which operations are still using a deprecated field. Both Apollo GraphOS and GraphQL Hive provide this data.

#### Apollo GraphOS Field Usage Report

Apollo GraphOS records every operation that reaches the router and associates each field access with the operation name and client identity. The Studio UI provides a field usage dashboard; the API provides programmatic access.

```bash
# Using rover to get field usage data
rover graph fetch $APOLLO_GRAPH_ID@production > current-schema.graphql

# GraphOS Insights API (REST) — get field usage for the last 30 days
curl "https://graphql.api.apollographql.com/api/graphql" \
  -H "x-api-key: $APOLLO_KEY" \
  -H "content-type: application/json" \
  -d '{
    "query": "query FieldUsage($graphId: ID!, $from: Timestamp!, $to: Timestamp!) { graph(id: $graphId) { stats(from: $from, to: $to) { fieldLatencies { groupBy { field } metrics { fieldHistogram { durationMs { p50 } } } requestsWithErrorsCount { totalCount } } } } }",
    "variables": {
      "graphId": "my-graph",
      "from": "-2592000",
      "to": "-0"
    }
  }'
```

In Apollo Studio, navigate to **Fields** under your graph variant. Filter by "Deprecated" to see a list of deprecated fields with their 30-day operation count. A field with 0 operations in 30 days is a candidate for removal. A field with non-zero operations shows you exactly which operations are using it.

#### GraphQL Hive Usage Tracking

GraphQL Hive's usage reporting agent collects operation telemetry and provides per-field usage reports:

```typescript
// In your GraphQL server — configure Hive usage reporting
import { createServer } from "@graphql-yoga/node";
import { useHive } from "@graphql-hive/client";

const server = createServer({
  schema,
  plugins: [
    useHive({
      enabled: true,
      token: process.env.HIVE_TOKEN,
      usage: {
        enabled: true,
        // Include client name and version for per-client breakdown
        clientInfo(context) {
          return {
            name: context.req.headers["x-client-name"] ?? "unknown",
            version: context.req.headers["x-client-version"] ?? "0.0.0",
          };
        },
        // Exclude internal health check operations
        exclude: [/HealthCheck/],
      },
      reporting: {
        enabled: true,
        author: "ci-pipeline",
        commit: process.env.GIT_SHA ?? "local",
      },
    }),
  ],
});
```

The Hive web interface shows per-field usage broken down by client name and version. This is the data you need to answer the question "which specific client version is still using `User.username`?"

#### Programmatic Usage Check for CI Gate

Use the registry API to gate field removal on confirmed zero usage:

```typescript
// check-field-usage.ts
// Run this script before the PR that removes a deprecated field merges.
// Fails with exit code 1 if any deprecated fields still have active usage.

import { execSync } from "child_process";

interface FieldUsageResult {
  fieldName: string;
  typeName: string;
  operationCount30Days: number;
  lastSeenAt: string | null;
}

async function checkDeprecatedFieldUsage(
  graphId: string,
  apiKey: string,
  fieldsToRemove: Array<{ typeName: string; fieldName: string }>
): Promise<void> {
  const query = `
    query DeprecatedFieldUsage($graphId: ID!) {
      graph(id: $graphId) {
        variant(name: "production") {
          fieldInsights {
            nodes {
              field { parent { name } name }
              usage30Days: referencingOperationCount(
                filter: { from: "-2592000", to: "0" }
              )
              lastSeenAt
            }
          }
        }
      }
    }
  `;

  const response = await fetch(
    "https://graphql.api.apollographql.com/api/graphql",
    {
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "content-type": "application/json",
      },
      body: JSON.stringify({ query, variables: { graphId } }),
    }
  );

  const data = await response.json();
  const nodes = data.data.graph.variant.fieldInsights.nodes;

  const stillInUse: FieldUsageResult[] = [];

  for (const { typeName, fieldName } of fieldsToRemove) {
    const node = nodes.find(
      (n: any) =>
        n.field.parent.name === typeName && n.field.name === fieldName
    );

    if (node && node.usage30Days > 0) {
      stillInUse.push({
        typeName,
        fieldName,
        operationCount30Days: node.usage30Days,
        lastSeenAt: node.lastSeenAt,
      });
    }
  }

  if (stillInUse.length > 0) {
    console.error(
      "ERROR: The following deprecated fields still have active usage:"
    );
    for (const f of stillInUse) {
      console.error(
        `  ${f.typeName}.${f.fieldName}: ${f.operationCount30Days} operations in last 30 days (last seen: ${f.lastSeenAt})`
      );
    }
    process.exit(1);
  }

  console.log(
    "All deprecated fields have zero usage in the last 30 days. Safe to remove."
  );
}

// Usage: specify fields you intend to remove in this PR
checkDeprecatedFieldUsage(process.env.APOLLO_GRAPH_ID!, process.env.APOLLO_KEY!, [
  { typeName: "User", fieldName: "username" },
  { typeName: "Order", fieldName: "totalAmount" },
]);
```

---

## Real-World Implementation: Deprecating User.username in Favor of User.handle

This section walks through a complete, realistic field deprecation and removal for a federated Users subgraph.

### Context

The Users subgraph currently exposes a `username` field. The product team has decided to rename the concept to `handle` to better reflect the product brand. The `handle` field includes a `@` prefix and uniqueness guarantees that `username` does not have. This is a breaking change — removing `username` — that requires RFC approval and a 90-day migration window.

### Step 1: Design the Replacement Field

Before adding `@deprecated`, the replacement field must be available. Add `handle` to the schema first:

```graphql
# users-subgraph/schema.graphql — Step 1: Add handle field (non-breaking)
type User @key(fields: "id") {
  id: ID!

  """
  The user's login name. Unique across the platform.
  """
  username: String!

  """
  The user's public handle, displayed as @{handle} throughout the platform.
  Handles are unique and follow the format: 3-20 lowercase alphanumeric characters
  and underscores, starting with a letter.
  Replaces `username` with stronger uniqueness guarantees.
  """
  handle: String!

  email: String!
  createdAt: DateTime!
}
```

Publish this change and validate that `handle` returns correct data. This is a safe (non-breaking) change. No RFC required.

### Step 2: Add @deprecated to username (After RFC Approval)

After the RFC (RFC-042) is approved by the schema review board:

```graphql
# users-subgraph/schema.graphql — Step 2: Deprecate username
type User @key(fields: "id") {
  id: ID!

  """
  The user's login name. Unique across the platform.

  DEPRECATED: Use `handle` instead. `handle` provides the same value with
  additional uniqueness guarantees and the @{handle} display format.

  Deprecated: 2026-01-15
  Removal date: 2026-04-15 (90-day enterprise SLA)
  RFC: https://github.com/org/repo/pull/1234
  Migration guide: https://engineering.internal/schema-rfcs/RFC-042
  """
  username: String!
    @deprecated(
      reason: "Use `handle` instead. `handle` returns the same value. Removal date: 2026-04-15. RFC-042."
    )

  """
  The user's public handle, displayed as @{handle} throughout the platform.
  Handles are unique and follow the format: 3-20 lowercase alphanumeric characters
  and underscores, starting with a letter.
  """
  handle: String!

  email: String!
  createdAt: DateTime!
}
```

### Step 3: Notify Consuming Teams

After publishing the deprecation to production, send the migration notification:

```markdown
# Schema Change Notification — RFC-042
**Date:** 2026-01-15
**Subgraph:** users
**Change:** `User.username` deprecated in favor of `User.handle`
**Removal date:** 2026-04-15

## What You Need to Do

Replace `username` with `handle` in all your GraphQL operations by **2026-04-15**.

**Before:**
\`\`\`graphql
query GetUser($id: ID!) {
  user(id: $id) {
    username
    email
  }
}
\`\`\`

**After:**
\`\`\`graphql
query GetUser($id: ID!) {
  user(id: $id) {
    handle
    email
  }
}
\`\`\`

Both fields return identical values during the migration period. No data migration is required.

## Usage Report as of 2026-01-15

| Client | Operations using username | Last seen |
|---|---|---|
| iOS app v2.x | 3 operations | 2026-01-14 |
| Android app | 2 operations | 2026-01-14 |
| Partner: Acme Corp | 1 operation | 2026-01-10 |
| Admin dashboard | 1 operation | 2026-01-13 |

## Questions?

Contact the Users team in #users-team-graphql or comment on RFC-042.
```

### Step 4: Monitor Usage Through the Migration Period

Set up a weekly automated usage check that posts to the schema governance Slack channel:

```bash
#!/bin/bash
# check-deprecated-usage.sh — run weekly via cron or GitHub Actions schedule

DEPRECATED_FIELDS='["User.username", "Order.totalAmount"]'

for field in $(echo "$DEPRECATED_FIELDS" | jq -r '.[]'); do
  TYPE=$(echo "$field" | cut -d. -f1)
  FIELD=$(echo "$field" | cut -d. -f2)

  COUNT=$(rover graph introspect "$APOLLO_GRAPH_ID@production" \
    --format json | \
    jq --arg type "$TYPE" --arg field "$FIELD" \
    '.data.__schema.types[] | select(.name == $type) | .fields[] | select(.name == $field and .isDeprecated == true) | .name' \
    2>/dev/null)

  echo "Deprecated field $field — current usage being checked via Studio API..."
done
```

### Step 5: Add @inaccessible Before Removal (Federation)

In Apollo Federation, add `@inaccessible` 14 days before removal to hide the field from the supergraph schema. This gives the router's query planner time to adapt and provides a warning to clients that the field is being removed imminently:

```graphql
# users-subgraph/schema.graphql — Step 5: Add @inaccessible (14 days before removal)
type User @key(fields: "id") {
  id: ID!

  """[REMOVING 2026-04-15] Use `handle` instead."""
  username: String!
    @deprecated(
      reason: "Use `handle` instead. Removal: 2026-04-15. RFC-042."
    )
    @inaccessible

  handle: String!
  email: String!
  createdAt: DateTime!
}
```

Note: `@inaccessible` prevents the field from appearing in the supergraph schema exposed to clients, while the subgraph resolver still exists. This is a clean way to verify that no query planner paths depend on the field before its complete removal.

### Step 6: Remove the Field

After confirming zero usage in the registry analytics:

```graphql
# users-subgraph/schema.graphql — Step 6: Remove username entirely
type User @key(fields: "id") {
  id: ID!
  handle: String!
  email: String!
  createdAt: DateTime!
}
```

Update the resolver to remove the `username` field implementation and publish to the registry. The deprecation lifecycle is complete.

---

## Complete Breaking vs. Safe Changes Reference

| Change | Safe? | Notes |
|---|---|---|
| **Adding a nullable field to a type** | Safe | Existing queries are unaffected; the new field is simply not queried |
| **Adding a non-null field to an output type** | Safe | Resolvers must return a value; clients can ignore the field |
| **Adding a non-null field to an INPUT type** | **BREAKING** | Existing mutations that do not include the field will fail validation |
| **Adding a nullable field to an INPUT type** | Safe | Existing mutations are unaffected; new field defaults to null |
| **Removing a field from an output type** | **BREAKING** | Clients querying that field will receive an error |
| **Removing a field from an INPUT type** | **BREAKING** | Clients sending that field will receive an error |
| **Renaming a field** | **BREAKING** | Treated as remove + add; use the dual-field pattern instead |
| **Changing field type (any change)** | **BREAKING** | Type mismatch at runtime; even Int→Float is a breaking change in strict clients |
| **Changing nullable to non-null (output)** | **BREAKING** | Clients written for nullable handling may break; resolver must never return null |
| **Changing non-null to nullable (output)** | Safe | More permissive; clients handling non-null will still work |
| **Changing nullable to non-null (input)** | **BREAKING** | Existing callers not sending the field now fail |
| **Changing non-null to nullable (input)** | Safe | More permissive; clients sending the field still work |
| **Adding an optional argument to a field** | Safe | Existing calls without the argument still work |
| **Adding a required argument to a field** | **BREAKING** | Existing calls without the argument fail |
| **Removing an argument from a field** | **BREAKING** | Clients sending that argument will receive an error |
| **Renaming an argument** | **BREAKING** | Treated as remove + add |
| **Adding an enum value** | Context-dependent | Safe for output types (clients receive a new value). Potentially breaking for input types (if the client rejects unknown values) or for exhaustive switch statements in typed clients. |
| **Removing an enum value** | **BREAKING** | Clients that send the removed value (input) or handle the removed value (output) break |
| **Adding a new query root field** | Safe | Does not affect existing queries |
| **Removing a query root field** | **BREAKING** | Clients using the removed query receive an error |
| **Adding a new mutation root field** | Safe | Does not affect existing mutations |
| **Removing a mutation root field** | **BREAKING** | Clients calling the removed mutation receive an error |
| **Changing @key fields (federation)** | **BREAKING** | Affects all subgraphs referencing the entity and the composition |
| **Adding @requires to a field (federation)** | Context-dependent | Changes the query plan; may cause composition warnings; not immediately client-breaking |
| **Adding @provides to a field (federation)** | Safe | Optimization hint; does not affect existing queries |
| **Adding a new directive** | Safe (if non-execution) | Introspection changes; does not affect query execution |
| **Removing a directive** | Context-dependent | Depends on whether clients or the router rely on the directive |
| **Making a type implement a new interface** | Safe | Existing queries are unaffected |
| **Removing an interface from a type** | **BREAKING** | Clients using fragments on that interface break |
| **Changing description/documentation** | Safe | Not part of query execution |
| **Adding @deprecated** | Safe | Does not affect execution |
| **Removing @deprecated** | Safe | Does not affect execution |

---

## Production Considerations

### Performance: Resolver Impact During Deprecation

During the deprecation period, both `username` and `handle` fields are live and must be resolved. If the underlying data source has different identifiers for the two concepts, this means two database reads per user. Mitigate by:

1. Resolving both from the same database column during the transition (alias at the resolver layer, not the database layer)
2. Using DataLoader to batch the additional field resolution with existing user lookups
3. Monitoring the p99 latency of affected queries in production before and after adding the new field

### Security: Deprecation Does Not Hide Sensitive Fields

`@deprecated` does not prevent introspection or query execution. A field containing sensitive data that is marked deprecated is still accessible. If a deprecated field exposes sensitive data that should be restricted before its scheduled removal, use `@inaccessible` in federation immediately rather than waiting for the removal date.

### Scaling: Usage Analytics at High Volume

At high request volumes (>10K operations/second), sampling is required for usage analytics. Both Apollo GraphOS and GraphQL Hive support operation sampling:

```typescript
// GraphQL Hive — configure sampling for high-traffic environments
useHive({
  usage: {
    enabled: true,
    sampleRate: 0.1, // Sample 10% of operations — sufficient for deprecation tracking
    // Use deterministic sampling based on operation name for consistent per-operation stats
    sampler({ operationName }) {
      return operationName === "HealthCheck" ? 0 : 0.1;
    },
  },
});
```

Apollo GraphOS router sampling configuration:

```yaml
# router.yaml
telemetry:
  apollo:
    field_level_instrumentation_sampler: "always_on"
    # For high volume, use probabilistic sampling:
    # field_level_instrumentation_sampler:
    #   static: 0.1
```

### Observability: Tracking the Deprecation Lifecycle

Add deprecation metrics to your schema governance observability stack:

```typescript
// Emit a custom metric per deprecated field usage to your metrics system
// This allows alerting when a field's usage is not declining as expected

interface DeprecationMetric {
  fieldName: string;
  typeName: string;
  operationCount: number;
  removalDate: string;
  daysUntilRemoval: number;
}

async function emitDeprecationMetrics(metrics: DeprecationMetric[]): Promise<void> {
  for (const metric of metrics) {
    // Emit to Datadog, Prometheus, or your observability platform
    // datadog.gauge("graphql.deprecated_field.usage", metric.operationCount, {
    //   field: `${metric.typeName}.${metric.fieldName}`,
    //   days_until_removal: metric.daysUntilRemoval,
    // });
    
    if (metric.daysUntilRemoval <= 14 && metric.operationCount > 0) {
      // Alert: usage not at zero with 14 days to removal
      console.warn(
        `ALERT: ${metric.typeName}.${metric.fieldName} has ${metric.operationCount} operations ` +
        `with ${metric.daysUntilRemoval} days until removal (${metric.removalDate})`
      );
    }
  }
}
```

---

## Best Practices

1. **Never add `@deprecated` without a replacement.** A deprecated field without a clear replacement path puts consumers in an impossible situation. The replacement must be in production before the deprecation is announced.

2. **Always include the removal date in the `reason` string.** The `reason` is the most visible communication channel for deprecation metadata. Include the date, the replacement, and a link to the RFC or migration guide. Clients see this in their IDE.

3. **Publish the deprecation to staging first, then production.** This gives you a chance to verify the lint and check pipeline treats the change correctly before it is visible to production clients.

4. **Use the schema description field for verbose migration documentation.** The `reason` string is limited in practice by IDE display width. Use the field's `"""description"""` for full migration documentation, including code examples.

5. **Automate the weekly usage check.** Do not rely on manual checks of the studio dashboard. A GitHub Actions scheduled workflow that queries the registry API and posts the results to a Slack channel is more reliable and creates a written record.

6. **Gate field removal on zero usage, not just on the SLA expiry.** The SLA is the maximum wait time. If usage drops to zero after 45 days, remove the field at 45 days, not at 90. The SLA protects consumers; zero usage proves consumers have migrated.

7. **Communicate the removal date as a range, not a deadline.** Tell consuming teams "we will remove this field between April 1 and April 30" rather than "April 15 exactly." This gives the schema team flexibility to wait for zero usage without breaking a public commitment.

---

## Anti-Patterns

**Anti-pattern: Append-only schema.** Never removing deprecated fields creates a schema that is difficult to understand, has misleading documentation, and creates ongoing maintenance burden for resolver implementations. Every deprecated field must have a scheduled removal date.

**Anti-pattern: Deprecating without a replacement.** `@deprecated(reason: "This field is no longer needed")` with no replacement is not a deprecation — it is an announcement of incompetence. The replacement must exist.

**Anti-pattern: Removing without usage confirmation.** Removing a field because "we think nobody is using it" without checking the operations registry is the most common cause of schema-related production incidents.

**Anti-pattern: Using @deprecated as a "do not use" signal for active fields.** Some teams add `@deprecated` to fields that they want to discourage for design reasons but do not plan to remove. This misuses the directive and trains clients to ignore deprecation warnings.

**Anti-pattern: Silent removal.** Removing a deprecated field without notifying consuming teams is a governance failure, even if the SLA has technically expired. Always send the 30-day sunset warning.

---

## Operational Notes

- **SLA clock starts at production publish, not PR merge.** If a PR merges on Monday but the schema is not published to production until Wednesday, the 90-day clock starts Wednesday.

- **External partner SLAs require contractual documentation.** For partner API consumers, the 180-day SLA should be referenced in the API consumer agreement or SLA document, not just the internal governance policy.

- **Resolver cleanup is separate from schema removal.** Remove the `@deprecated` directive and delete the field from the SDL first (with a schema publish). Then clean up the resolver implementation in a separate PR. Keeping them synchronized in the same PR increases the risk of a rollback affecting both.

- **Monitor for resolver errors after removal.** After removing a deprecated field, watch for resolver-level errors in your APM for 24 hours. If a client was querying the field despite the zero-usage signal in the registry (possible if the registry sampling rate was low), errors will appear in your APM before they appear as client-reported incidents.

---

## References

- [GraphQL Specification — @deprecated directive](https://spec.graphql.org/October2021/#sec--deprecated)
- [Apollo GraphOS — Field Usage Insights](https://www.apollographql.com/docs/graphos/metrics/field-usage)
- [GraphQL Hive — Schema Usage Reporting](https://the-guild.dev/graphql/hive/docs/features/usage-reporting)
- [graphql-inspector — Deprecated Usage Detection](https://the-guild.dev/graphql/inspector/docs/essentials/deprecated)
- [Apollo Federation — @inaccessible directive](https://www.apollographql.com/docs/federation/federated-types/federated-directives#inaccessible)

---

## Related Topics

- [01 — Governance Framework](./01-governance-framework.md) — the RFC process and schema review board that govern breaking changes
- [03 — Breaking Change Policies](./03-breaking-change-policies.md) — complete breaking change classification and `rover subgraph check` integration
- [04 — Team Governance](./04-team-governance.md) — inter-team coordination for cross-subgraph deprecations
- [03 — Schema Design](../03-schema-design/README.md) — field design principles that reduce future deprecation pressure
- [14 — Observability](../14-observability/README.md) — APM integration for post-removal error monitoring
