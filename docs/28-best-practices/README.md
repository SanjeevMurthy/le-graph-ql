# Chapter 28: Best Practices

> **Purpose:** This chapter consolidates enterprise-grade GraphQL best practices organized by layer. Each practice is stated as a rule, backed by rationale, and illustrated with a counter-example that shows what failure looks like. Engineers looking for a comprehensive checklist before launching or auditing a GraphQL system should start here.

---

## Why This Chapter Exists

GraphQL is permissive by design. Nothing in the spec prevents you from naming a mutation `orderCreate`, exposing raw database errors to clients, or skipping DataLoader and hammering your database with N+1 queries. The spec defines what is _valid_. These best practices define what is _good_.

Each practice here emerged from production failures at scale: teams that renamed types without deprecating them, resolvers that leaked stack traces, and subgraphs that shared a database and turned federation into a distributed monolith. These rules prevent those failures.

---

## Layer Map

| Layer | File | Practice Count |
|---|---|---|
| Schema Design | [01-schema-best-practices.md](./01-schema-best-practices.md) | 20+ |
| Resolvers & Execution | [02-resolver-best-practices.md](./02-resolver-best-practices.md) | 20+ |
| Federation | [03-federation-best-practices.md](./03-federation-best-practices.md) | 20+ |
| Security & Operations | [04-security-and-operations-best-practices.md](./04-security-and-operations-best-practices.md) | 20+ |

---

## Quick Reference: The Non-Negotiables

These practices are the minimum bar for any production GraphQL API. Violating any of them in production is a known risk with a known failure mode.

### Schema

| Rule | Failure Mode |
|---|---|
| Nullable by default; non-null only with a contract guarantee | A non-null field that returns `null` at runtime kills the entire parent object |
| Every public type and field has a `"""description"""` | Client portals, codegen, and LLM tools produce garbage without descriptions |
| Never reuse output types as input types | Input validation breaks; clients receive mutation payloads with fields irrelevant to writing |
| Use error unions on mutations | `throw` makes errors invisible to the type system; clients cannot statically type error states |
| Deprecate before removing, always include a reason | Removing fields without deprecation breaks clients silently |
| Use cursor-based pagination for any list that can grow | Offset pagination is O(n) at the database and breaks under concurrent inserts |

### Resolvers

| Rule | Failure Mode |
|---|---|
| Always use DataLoader for any fetch by ID or foreign key | Without DataLoader, each list item triggers an independent database query |
| Build DataLoaders in context factory, never inside resolvers | In-resolver DataLoader construction defeats batching — each request gets a fresh loader |
| Delegate business logic to a service layer | Resolvers that contain business logic become untestable and unreusable |
| Set timeouts on all external service calls | A slow downstream service stalls the entire request indefinitely |
| Never expose raw database error messages | Stack traces and SQL fragments leak schema internals and provide attack surface |

### Federation

| Rule | Failure Mode |
|---|---|
| One subgraph per bounded context, not per microservice | Over-splitting creates cross-subgraph joins for every query, degrading performance |
| Never share a database between subgraphs | Shared databases couple teams at the data layer, defeating federation's independence guarantee |
| Run composition check in CI before any merge | Composition errors discovered in production bring down the entire supergraph |
| Keep `@key` fields immutable | Changing a `@key` field breaks all entity resolution across the supergraph |

### Security & Operations

| Rule | Failure Mode |
|---|---|
| Disable introspection in production | Introspection gives attackers a complete schema map for targeted enumeration |
| Require `operationName` on all production clients | Anonymous operations cannot be traced, rate-limited, or audited by operation |
| Enable persisted queries in allowlist mode | Arbitrary query documents allow complexity abuse and data exfiltration |
| Set query complexity and depth limits | Unconstrained queries allow DoS via deeply nested or fan-out operations |
| Define SLOs before going to production | Without error budget definitions, incidents cannot be declared or managed |

---

## How to Use This Chapter

**For a new project:** Work through the schema and resolver files before writing your first resolver. The patterns are much easier to adopt at the start than to retrofit.

**For a production audit:** Use the Quick Reference table above as a checklist. File issues for every violation. Prioritize by failure mode severity.

**For code review:** Reference specific practice numbers (e.g., "BP-S-03: cursor pagination required") to ground review comments in documented rationale rather than personal preference.

**For onboarding:** Assign this README and the schema file to all new backend engineers before their first GraphQL PR.

---

## Prerequisites

- [Schema Design](../03-schema-design/README.md) — SDL fundamentals and type system
- [Resolvers and Execution](../04-resolvers-and-execution/README.md) — resolver lifecycle
- [Federation](../07-federation/README.md) — subgraph model
- [Security](../05-security/README.md) — authentication and authorization
- [Observability](../14-observability/README.md) — metrics, traces, logs

## Related Topics

- [Anti-Patterns](../29-anti-patterns/README.md) — the catalog of what to avoid, with failure post-mortems
- [Reference Architectures](../30-reference-architectures/README.md) — these practices applied to full deployment blueprints
- [Production Runbooks](../32-production-runbooks/README.md) — operational procedures that depend on these practices being in place
- [Schema Governance](../09-schema-governance/README.md) — enforcing these practices through process and tooling
