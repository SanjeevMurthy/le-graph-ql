# Security Configuration for GraphQL APIs

Companion docs: `../../docs/05-security/`

GraphQL introduces a distinct security surface compared to REST. The flexibility that makes GraphQL powerful — arbitrary query shapes, nested relations, introspection — is also the attack surface. A GraphQL API that is not explicitly hardened is vulnerable to query complexity attacks, introspection abuse, authorization bypass through federation, and data leakage via over-fetching. This directory covers production-grade defenses for each attack vector.

---

## GraphQL Threat Model

Understanding the threat model is a prerequisite for configuring defenses correctly. The attacks below are GraphQL-specific and are not covered by generic REST security controls.

### Threat 1: Introspection Abuse

GraphQL's introspection system (`__schema`, `__type`) reveals the complete API schema — every type, field, argument, directive, and their descriptions. Attackers use introspection to:

- Map the entire API in seconds with tools like `graphql-voyager` or `graphdoc`
- Identify sensitive fields (`creditCard`, `ssn`, `internalId`) that would otherwise require guessing
- Find deprecated fields still in use that may lack the same security controls as modern fields
- Enumerate all available mutations (including admin mutations) to prioritize attack paths

Mitigation: disable introspection in production (or restrict to authenticated internal users). Persisted queries make introspection moot — if only pre-registered queries can execute, the schema enumeration yields no exploitable access.

### Threat 2: Query Complexity Attacks

GraphQL allows arbitrarily deep queries. An attacker can craft a query that takes seconds to execute and returns megabytes of data:

```graphql
# Depth attack — exponential resolver invocations through circular references
{
  user(id: "1") {
    friends {
      friends {
        friends {
          friends {
            friends { id name }
          }
        }
      }
    }
  }
}

# Width attack — hundreds of root-level fields in one query
{
  p1: product(id: "1") { ... }
  p2: product(id: "2") { ... }
  # ... p999: product(id: "999") { ... }
}
```

Mitigation: depth limiting, complexity scoring, and alias count limits at the Router layer.

### Threat 3: Injection via Variables

GraphQL variables are passed separately from the query document and are strongly typed. However, if resolver implementations pass variable values directly to SQL queries, shell commands, or eval-like constructs, injection is possible. This is a resolver implementation problem, not a GraphQL protocol problem.

Mitigation: always use parameterized queries in resolvers. Never concatenate user-provided strings into SQL or command strings.

### Threat 4: Authorization Bypass via Federation

In a federated architecture, each subgraph has its own authorization logic. A bypass can occur when:
- A subgraph trusts the `x-user-id` header without verifying it came from the Router (direct subgraph access)
- An `@key` field is accepted as proof of ownership without an ownership check (e.g., any user can query `User:42` without proving they are user 42)
- A mutation in Subgraph A changes state that Subgraph B's authorization assumes is invariant

Mitigation: network-level controls (deny direct subgraph access), Router JWT validation, and explicit ownership checks in resolver authorization logic.

### Threat 5: Subscription Abuse

GraphQL subscriptions establish long-lived WebSocket connections. Attackers can:
- Open thousands of subscriptions to exhaust server connection limits
- Subscribe to high-frequency events to exfiltrate data at high bandwidth
- Craft subscription filters that trigger disproportionate server-side work

Mitigation: subscription rate limiting, connection limits per client, and subscription authorization.

---

## Defense Layers

```
Client
  |
  v
+-----------------------------------------------+
|              Apollo Router                     |
|                                                |
|  Layer 1: JWT Authentication                  |
|    - JWKS validation                          |
|    - Token extraction from Authorization header|
|    - Claim injection into subgraph headers    |
|                                                |
|  Layer 2: Query Security                      |
|    - Depth limit (limits.max_depth)           |
|    - Complexity limit (limits.max_height)     |
|    - Alias limit (limits.max_aliases)         |
|    - APQ enforcement (persisted queries only) |
|    - Introspection disabled                   |
|    - CORS enforcement                         |
|    - Rate limiting (traffic_shaping)          |
+-----------------------------------------------+
          |                   |
          v                   v
+------------------+  +------------------+
|  Users Subgraph  |  | Products Subgraph|
|                  |  |                  |
|  Layer 3:        |  |  Layer 3:        |
|  Field-Level Auth|  |  Field-Level Auth|
|  @requiresScopes |  |  @requiresScopes |
|  @authenticated  |  |  @authenticated  |
|  Resolver checks |  |  Resolver checks |
+------------------+  +------------------+
          |
          v
+------------------+
|  OPA (optional)  |
|                  |
|  Layer 4:        |
|  Policy Engine   |
|  Complex rules   |
|  Audit logging   |
+------------------+
          |
          v
+------------------+
| PostgreSQL /     |
| MongoDB / etc.   |
|                  |
|  Layer 5:        |
|  Row-Level Sec   |
|  Parameterized   |
|  Queries         |
+------------------+
```

---

## File Navigation

| File | What it covers |
|------|---------------|
| `README.md` | Threat model, defense layers, prerequisites, related docs |
| `jwt-authentication.md` | Router JWT plugin config, claim extraction, header injection, multi-IdP, service-to-service auth |
| `field-level-authorization.md` | `@requiresScopes`, `@authenticated`, custom directives, resolver auth, multi-tenant isolation, audit logging |
| `query-security.md` | Depth/complexity limits, alias abuse, introspection control, CORS, rate limiting, variable injection |

---

## Prerequisites

| Requirement | Minimum Version | Notes |
|-------------|----------------|-------|
| Apollo Router | 1.40.0 | `@authenticated` and `@requiresScopes` directives require Router 1.35+; JWT plugin stable in 1.30+ |
| Apollo Federation | 2.4.0 | `@authenticated` and `@requiresScopes` are Federation 2.4 directives |
| Node.js (subgraphs) | 20 LTS | Required for `@apollo/server` v4 |
| Auth0 / Okta / Cognito | Any | Any OIDC-compliant IdP that provides a JWKS endpoint |
| OPA | 0.58+ | Optional; for policy-as-code authorization in complex access control scenarios |
| `graphql-middleware` | 6.x | For field-level middleware (audit logging, authorization wrappers) |
| `graphql-query-complexity` | 0.12+ | For resolver-level complexity scoring in subgraphs |

---

## Quick Security Audit Checklist

Before deploying a GraphQL API to production, verify each item:

| Check | Verified? |
|-------|-----------|
| Introspection disabled in production Router | |
| GraphQL Playground / Sandbox disabled in production | |
| JWT validation configured with JWKS polling | |
| Subgraph ports blocked from direct external access (NetworkPolicy) | |
| `max_depth` limit configured in `router.yaml` | |
| `max_height` (field count) limit configured | |
| `max_aliases` limit configured | |
| CORS `allow_any_origin: false` in production | |
| Rate limiting configured per-client | |
| `@cacheControl(scope: PRIVATE)` on all user-specific data | |
| Persisted queries enforced (APQ allowlist mode) | |
| No raw SQL string concatenation in resolvers | |
| Audit logging on sensitive field access | |
| TLS (`rediss://`) for Redis connections | |
| Redis AUTH token configured and rotated | |

---

## Common Misconfigurations

### Misconfig 1: Trusting subgraph-injected headers without network controls

If the Users subgraph trusts the `x-user-id` header unconditionally, an attacker who can reach the subgraph port directly can set `x-user-id: admin` and bypass authentication entirely. The subgraph must be unreachable from outside the cluster.

### Misconfig 2: Introspection enabled in production

Many teams disable GraphQL Sandbox but leave `introspection: true`. Introspection queries are regular GraphQL queries — disabling the Sandbox UI does not disable the `__schema` introspection query.

### Misconfig 3: Not verifying JWT `aud` claim

A JWT issued for service A (`aud: "service-a"`) should not be accepted by service B. Configuring JWKS validation without checking the `aud` claim allows token reuse across services.

### Misconfig 4: Overly permissive CORS

`allow_any_origin: true` (CORS wildcard) allows any website to make GraphQL requests in the browser context of a logged-in user. For public APIs with no cookies, this is acceptable. For APIs that use cookie-based auth or return user-specific data, it is a CSRF risk.

### Misconfig 5: DataLoader shared across requests

A module-level DataLoader that persists across requests can serve one user's data to another if request context is not properly isolated. Always create DataLoader instances in the per-request context factory.

---

## Related Documentation

- `../../docs/05-security/` — comprehensive security guide
- `../../examples/07-opa-policies/` — OPA integration for policy-as-code authorization
- `../../examples/05-persisted-queries/` — APQ enforcement as a query allowlist
- `../../examples/11-redis-caching/` — caching with security scope (`PUBLIC` vs `PRIVATE`)
- `../../examples/02-apollo-router/` — base Router configuration
- `../../examples/06-kubernetes/` — NetworkPolicy for subgraph isolation
