# Query Complexity Analysis — Example 13

Companion docs: `../../docs/06-performance-and-scaling/`, `../../docs/05-security/`

---

## Why Query Complexity Matters

GraphQL's flexible query language is both its greatest strength and its primary operational risk. Unlike REST, where the server controls exactly what data is returned per endpoint, GraphQL allows clients to compose arbitrary queries. A naive client — or a malicious actor — can craft a query that asks for deeply nested relationships across thousands of records, triggering millions of database rows and seconds of CPU time on a single request.

Consider this legitimate-looking but catastrophic query against an e-commerce schema:

```graphql
query {
  products(first: 100) {
    reviews(first: 100) {
      author {
        orders(first: 100) {
          lineItems(first: 100) {
            product {
              recommendations(first: 100) {
                id
                name
              }
            }
          }
        }
      }
    }
  }
}
```

This query, if executed without protection, resolves `100 * 100 * 100 * 100 * 100 = 10 billion` potential database lookups. Even with DataLoader batching, this is an unacceptable workload. Without complexity limits, a single request like this can starve your database connection pool, exhaust memory, and deny service to legitimate users.

### Two Approaches to Complexity Analysis

**Static complexity** assigns fixed weights to each field at schema definition time. A scalar field costs 1, a list field costs 10, a resolver that calls an expensive external API costs 25. The complexity analyzer sums up these weights for a given query document before execution begins. This approach is predictable and cheap to compute.

**Dynamic complexity** computes cost based on actual execution — how many items a resolver returned, how long it took, how many database calls it made. Dynamic complexity is accurate but arrives too late to reject a query before it runs. It is most useful for auditing, alerting, and after-the-fact rate limiting.

Production systems typically use static complexity for pre-execution rejection and dynamic instrumentation for ongoing observability. This example covers both approaches plus the structural limits (depth, breadth, aliases) that Apollo Router provides at the infrastructure layer.

---

## Files in This Example

| File | Description |
|---|---|
| `README.md` | This file. Overview and orientation. |
| `complexity-analysis.md` | Implementing query complexity scoring with `graphql-query-complexity` and Apollo Server 4. Includes field cost definitions, TypeScript estimator functions, threshold configuration, persisted query pre-computation, response headers, and test patterns. |
| `depth-and-breadth-limits.md` | Apollo Router structural limits: `max_depth`, `max_height`, `max_root_fields`, `max_aliases`, `max_directives`. Complete `router.yaml` configuration with rationale for every value, query examples at each limit, parser caching with Redis, and monitoring with Prometheus. |
| `field-cost-directives.md` | Schema-level cost annotations using `@cost` and `@listSize` directives. TypeScript implementation of a custom directive visitor, annotated e-commerce schema, federation compatibility, and VS Code tooling integration. |

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Node.js | >= 20 | Required for Apollo Server 4 and TypeScript toolchain |
| Apollo Server | 4.x | `@apollo/server` — used for `validationRules` hook |
| Apollo Router | >= 1.40 | Provides structural limits at the infrastructure layer |
| graphql-query-complexity | >= 0.12 | npm package for application-level complexity scoring |
| TypeScript | >= 5.0 | All code examples are TypeScript |
| Redis | >= 7 | Required only for `experimental_parser_cache` in Router |

---

## When to Use Each Layer

Complexity protection works best when layered. No single technique is sufficient on its own.

| Layer | Mechanism | Catches | Overhead |
|---|---|---|---|
| Router structural limits | `max_depth`, `max_height`, `max_aliases` | Structurally pathological queries | Near-zero (parse time) |
| Application complexity scoring | `graphql-query-complexity` | Cost-weighted budget violations | Low (validation phase) |
| Persisted queries | APQ / safelisting | All ad-hoc queries in production | Near-zero |
| Rate limiting | Router or API gateway | High-volume repeated queries | Low |
| Dynamic instrumentation | Field-level timing | Identifies expensive fields for tuning | Medium (adds per-field overhead) |

A startup should start with Router structural limits and persisted query safelisting. A growing platform should add application-level complexity scoring. An enterprise should also run dynamic instrumentation to feed cost data back into the static cost model.

---

## Quick Start

```bash
# Install graphql-query-complexity
npm install graphql-query-complexity

# Run the complexity analysis examples (requires ts-node or esbuild-register)
cd examples/13-query-complexity
npx ts-node --esm examples/basic-complexity.ts
```

---

## Related Documentation

- `../../docs/06-performance-and-scaling/` — DataLoader patterns, caching strategies, and resolver performance tuning that reduce the actual cost of expensive queries
- `../../docs/05-security/` — Authentication, authorization, field-level access control, and the full threat model for GraphQL APIs
- `../../docs/09-schema-governance/` — Schema design decisions that affect query complexity (connection patterns, depth of nesting, computed fields)
- `../../docs/14-observability/` — Metrics and tracing setup to measure query cost in production, which informs static cost model calibration
