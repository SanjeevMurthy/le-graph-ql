# Federation and Architecture Interview Questions

> **Purpose:** Model answers for the six most common federation and architecture interview questions at staff and principal engineer level. These questions test whether you understand the full federation lifecycle — from bounded context decomposition through query planning, debugging, auth, and observability — and whether you can reason about architectural trade-offs at system scale.

---

## Question 1: How Would You Decompose a Monolithic GraphQL Schema into a Federated Supergraph?

### What the interviewer is evaluating

Your ability to apply domain-driven design principles to schema ownership boundaries, identify entities that cross subgraph lines, design a migration strategy that doesn't require a big-bang rewrite, and reason about the organizational changes that accompany a technical migration.

### Model Answer

"Schema decomposition is primarily a domain modeling problem, not a technical problem. The technical federation mechanics are straightforward — the hard part is drawing the right boundaries."

**Step 1 — Map bounded contexts using DDD:**

Before touching any code, analyze the monolithic schema by grouping types into domain contexts. Each context becomes a subgraph candidate.

```
Identity & Access:    User, Account, AuthSession, Permission, Role
Product Catalog:      Product, ProductVariant, Brand, Category, MediaItem
Orders:               Order, OrderItem, OrderStatus, OrderTimeline
Inventory:            InventoryPosition, Warehouse, StockEvent
Payments:             PaymentMethod, Transaction, Refund
Shipping:             Shipment, Carrier, TrackingEvent, DeliveryEstimate
Reviews:              Review, Rating, ReviewResponse
Notifications:        Notification, NotificationPreference, Channel
```

**Step 2 — Identify entities (cross-subgraph references):**

An entity is a type that multiple subgraphs need to reference. The entity is **owned** by one subgraph; other subgraphs **reference** it via its `@key`.

```graphql
# users-subgraph owns the User entity
type User @key(fields: "id") {
  id: ID!
  name: String!
  email: String!
  avatarUrl: String
}

# orders-subgraph references User without re-implementing its fields
type Order @key(fields: "id") {
  id: ID!
  customer: User!      # Reference — router fetches User from users-subgraph
  items: [OrderItem!]!
  total: Money!
  status: OrderStatus!
}
```

**Step 3 — Design the migration as a strangler fig (not a big bang):**

```
Phase 1: Stand up the router in front of the monolith
  - Deploy Apollo Router pointing to the existing monolith as a single subgraph
  - All traffic still flows through the monolith
  - Zero change to clients or query behavior

Phase 2: Extract one bounded context at a time
  - Start with a leaf domain (no cross-domain dependencies) — Reviews is ideal
  - Deploy the new subgraph, update router config
  - Remove the types from the monolith
  - Validate with composition checks and traffic comparison

Phase 3: Extract entity-heavy domains after leaf domains
  - Orders, Inventory, Payments depend on User — extract after Identity
  - Use @provides to avoid extra entity resolution fetches where possible

Phase 4: Decommission the monolith
  - Once all types are owned by subgraphs, the monolith is empty
  - Remove it from the router config
```

**Step 4 — Governance changes alongside the technical migration:**

Each extracted subgraph needs a team owner, a deployment pipeline, schema contribution guidelines, and an alert page. The technical migration fails without these organizational changes.

### Common Mistakes

- Starting with the most complex domain (Orders) instead of a leaf domain.
- Creating subgraph boundaries that mirror the database schema rather than the business domain.
- Not mentioning the strangler fig pattern — a big-bang migration is too risky for production traffic.
- Ignoring cross-cutting concerns like authentication and logging that need to be solved at the router layer.

### Follow-Up Questions

- "How do you handle a type that truly spans two bounded contexts?"
- "What happens to in-flight queries during a subgraph deployment?"
- "How do you decide when a subgraph is too small or too large?"

---

## Question 2: Explain How Apollo Federation Entity Resolution Works

### What the interviewer is evaluating

Your depth of understanding of the federation execution model — specifically how the `@key` directive, the `_entities` query, query planning, and reference resolvers interact. This is the most commonly tested federation internals question.

### Model Answer

"Entity resolution is the mechanism by which the router fetches data for a type that spans multiple subgraphs. Let me trace through a concrete example."

**Setup:**

```graphql
# users-subgraph
type User @key(fields: "id") {
  id: ID!
  name: String!
  email: String!
}

type Query {
  user(id: ID!): User
  me: User
}

# orders-subgraph
type User @key(fields: "id") {
  id: ID!
  # orders-subgraph extends User with order history
  orders(first: Int = 10, after: String): OrderConnection!
}

type Order @key(fields: "id") {
  id: ID!
  customer: User!
  total: Money!
  status: OrderStatus!
}

type Query {
  order(id: ID!): Order
  myOrders(first: Int, after: String): OrderConnection!
}
```

**Client query:**

```graphql
query {
  order(id: "ord_123") {
    id
    status
    total { amount currency }
    customer {
      name     # Owned by users-subgraph
      email    # Owned by users-subgraph
    }
  }
}
```

**Query planning — what the router does:**

```
Step 1: Fetch order from orders-subgraph
  Query:  { order(id: "ord_123") { id status total { amount currency } customer { id } } }
  Note:   Router adds customer { id } to fetch the @key field even if the client didn't request it

Step 2: Identify that customer.name and customer.email are owned by users-subgraph
  Router needs to fetch User { name email } for customer.id returned in Step 1

Step 3: Fetch user from users-subgraph using the _entities query
  Query:
    query ($representations: [_Any!]!) {
      _entities(representations: $representations) {
        ... on User {
          name
          email
        }
      }
    }
  Variables:
    {
      "representations": [
        { "__typename": "User", "id": "usr_456" }
      ]
    }
```

**The `_entities` query:**

Every subgraph that owns an entity must implement `_entities`. Apollo Router generates this query automatically from the supergraph SDL. The subgraph receives a list of `representations` (objects containing `__typename` + key fields) and must return the resolved entities in the same order.

**The reference resolver:**

```typescript
// users-subgraph reference resolver
const resolvers = {
  User: {
    // Called by the router when it sends an _entities query
    // with representations for User
    __resolveReference(representation: { id: string }, context: Context) {
      return context.loaders.user.load(representation.id);
      // DataLoader batches multiple _entities calls into one DB query
    }
  }
};
```

**Batching in entity resolution:**

When the router needs to resolve 10 orders, each with a different customer, it batches all 10 into a single `_entities` call with all 10 representations. The subgraph receives `representations` with 10 User objects and returns 10 resolved users. This is why DataLoader in reference resolvers is mandatory — without it, each representation triggers a separate database query.

**Query plan node types:**

```
Sequence[
  Fetch(orders-subgraph) {
    order(id: "ord_123") {
      id, status, total { amount currency }
      customer { id }        ← key field fetched automatically
    }
  },
  Flatten(path: "order.customer") {
    Fetch(users-subgraph) {
      _entities(representations: [{__typename: "User", id: $id}]) {
        ... on User { name, email }
      }
    }
  }
]
```

### Common Mistakes

- Saying "`@extends` is how subgraphs reference entities" — `@extends` was Apollo Federation v1 syntax. Federation v2 uses stub type definitions without `@extends`.
- Not knowing the `_entities` query name or shape — interviewers often ask you to write it.
- Not mentioning that the router auto-inserts the `@key` field into sub-fetches.
- Forgetting that reference resolvers must use DataLoader — not doing so creates N+1 at the federation level.

### Follow-Up Questions

- "What is `@provides` and how does it reduce entity resolution round trips?"
- "What happens if a reference resolver returns `null` for a non-nullable entity field?"
- "How does `@requires` change the query plan?"

---

## Question 3: A Subgraph Is Slow — How Do You Diagnose It?

### What the interviewer is evaluating

Your systematic debugging process, familiarity with distributed tracing tools in a federated context, and your ability to distinguish between multiple categories of subgraph slowness (resolver-level, database-level, network-level, federation-level).

### Model Answer

"I approach subgraph latency debugging in three phases: confirm the scope, isolate the layer, then fix the root cause."

**Phase 1 — Confirm scope using distributed traces:**

```
1. Open Apollo Studio > Operations > find the slow operation by p99 latency
2. Click through to a representative trace — Apollo Studio shows per-field timing
   annotated across subgraphs

Example trace output:
  [0ms]  Router receives query
  [2ms]  Fetch start: orders-subgraph
  [187ms] Fetch end: orders-subgraph    ← 185ms here, which is abnormal
  [189ms] Flatten + Fetch start: users-subgraph
  [195ms] Fetch end: users-subgraph
  [196ms] Router merges response
  [197ms] Client receives response

Conclusion: orders-subgraph is the slow component, not users-subgraph.
```

**Phase 2 — Isolate within the subgraph:**

Possible causes and how to distinguish them:

| Symptom | Likely Cause | Diagnostic |
|---|---|---|
| Slow consistently, all queries | Database connection pool exhaustion | `pg_stat_activity` — count waiting connections |
| Slow for specific operation | N+1 resolver — DataLoader missing | Apollo trace shows many small DB spans |
| Slow for large result sets | Missing database index | `EXPLAIN ANALYZE` on the query |
| Slow intermittently | Downstream service timeout | Subgraph logs — look for timeout errors |
| Slow after deployment | N+1 introduced in new resolver | `git diff` on resolvers, compare DB query counts |
| Slow under load only | Connection pool too small | DB connection metrics during load |

**Checking for N+1 in resolvers:**

```typescript
// Instrument the DataLoader batch function to log batch sizes
const userLoader = new DataLoader<string, User>(async (ids) => {
  // If batch size is consistently 1, DataLoader is not batching — investigate
  logger.info({ event: 'dataloader_batch', size: ids.length, entity: 'User' });
  const users = await db.query('SELECT * FROM users WHERE id = ANY($1)', [ids]);
  const map = new Map(users.map(u => [u.id, u]));
  return ids.map(id => map.get(id) ?? new Error(`User ${id} not found`));
});
```

If batch size is always 1, the DataLoader is being instantiated inside the resolver instead of the context factory.

**Phase 3 — Database-level investigation:**

```sql
-- Find slow queries in PostgreSQL slow query log
SELECT
  query,
  calls,
  mean_exec_time,
  total_exec_time,
  rows
FROM pg_stat_statements
WHERE mean_exec_time > 100  -- ms
ORDER BY mean_exec_time DESC
LIMIT 20;

-- Check for missing indexes
EXPLAIN ANALYZE
SELECT * FROM orders
WHERE customer_id = $1
ORDER BY created_at DESC
LIMIT 10;
-- Look for: "Seq Scan" on large tables = missing index
-- Want: "Index Scan" or "Bitmap Index Scan"
```

**Phase 4 — Federation-level investigation:**

If the subgraph's direct latency looks fine but total operation latency is high, check:
- Number of entity resolution round trips (check query plan in Studio)
- `@requires` chains causing sequential fetches
- Subgraph query timeout in the router config (a slow subgraph blocking the router thread)

```yaml
# router.yaml — check timeout configuration
subgraphs:
  orders:
    routing_url: http://orders-service:4002/graphql
    query_timeout: 5s   # If not set, defaults to 30s — may be blocking router
```

### Common Mistakes

- Going straight to code changes without looking at traces first.
- Not distinguishing between subgraph latency and federation overhead latency.
- Not checking DataLoader batch sizes — the most common root cause for resolver N+1.
- Forgetting to check database indexes — resolver code may be correct but the underlying query is doing a sequential scan.

### Follow-Up Questions

- "You've found that a DataLoader batch function is being called with batches of 1. What are the two most likely root causes?"
- "How do you reproduce a production performance issue locally?"
- "What's the difference between `@provides` and eliminating an entity resolution round trip at the database level?"

---

## Question 4: How Do You Handle Authentication and Authorization in a Federated Graph?

### What the interviewer is evaluating

Your understanding of the layered auth model in federation (token verification at the router, claims forwarding to subgraphs, field-level authorization), the trade-offs between auth at different layers, and your familiarity with OPA for field-level policy enforcement.

### Model Answer

"Authentication and authorization in federation operate at three distinct layers. Getting these layers right is critical because the wrong architecture either creates security holes (auth bypassed by direct subgraph access) or operational coupling (subgraphs making auth service calls on every request)."

**Layer 1 — Token verification at the router:**

The router is the single entry point. JWT verification happens here, before any subgraph sees the request.

```yaml
# router.yaml — Apollo Router JWT plugin
authentication:
  router:
    jwt:
      jwks:
        - url: https://auth.company.com/.well-known/jwks.json
          issuer: "https://auth.company.com"
      header_name: Authorization
      header_value_prefix: "Bearer "
```

The router verifies the token signature, expiration, issuer, and audience. If verification fails, the router returns a 401 before the query reaches any subgraph.

**Layer 2 — Claims forwarding to subgraphs:**

After verification, the router extracts claims from the JWT and forwards them to subgraphs via headers. Subgraphs trust these headers (they come from the router only, not external clients — enforced by network policy or mTLS).

```yaml
# router.yaml — forward claims to subgraphs
headers:
  subgraphs:
    all:
      request:
        - propagate:
            named: x-user-id         # Extracted from JWT sub claim
        - propagate:
            named: x-user-roles      # Extracted from JWT roles claim
        - propagate:
            named: x-tenant-id       # Extracted from JWT tenant claim
```

Subgraphs receive the claims without making any auth service calls — the router did the expensive work once.

**Layer 3 — Field-level authorization with OPA:**

For fine-grained authorization (can this user see this field?), integrate Open Policy Agent in a resolver middleware or plugin.

```typescript
// Resolver middleware pattern
function withFieldAuth(permission: string) {
  return (next: FieldResolver) => (root, args, context, info) => {
    const { userId, roles } = context.claims;

    const allowed = context.opa.evaluate({
      input: {
        user: { id: userId, roles },
        resource: { field: info.fieldName, type: info.parentType.name },
        action: permission
      },
      policy: 'data.graphql.authz.allow'
    });

    if (!allowed) {
      throw new GraphQLError('Forbidden', {
        extensions: { code: 'FORBIDDEN', field: info.fieldName }
      });
    }

    return next(root, args, context, info);
  };
}

// Usage in resolver definition
const resolvers = {
  User: {
    // Only the user themselves or an admin can see email
    email: withFieldAuth('read:user:email')(
      (user, _args, context) => {
        return user.id === context.claims.userId
          ? user.email
          : null;  // Return null for unauthorized, not throw
      }
    )
  }
};
```

**The OPA policy (Rego):**

```rego
package graphql.authz

default allow = false

# Users can read their own email
allow {
  input.resource.type == "User"
  input.resource.field == "email"
  input.user.id == input.resource.owner_id
}

# Admins can read any email
allow {
  input.resource.field == "email"
  "admin" in input.user.roles
}
```

**Securing subgraphs from direct access:**

Subgraphs must not be directly accessible from the internet — only from the router. Enforce this via:
- Kubernetes `NetworkPolicy` — allow ingress to subgraph only from router service account
- mTLS between router and subgraphs
- Service mesh (Istio) with authorization policies

Without network enforcement, an attacker who discovers a subgraph URL can bypass the router's auth entirely.

### Common Mistakes

- Making subgraphs verify JWT tokens themselves — this doubles the crypto work and requires every subgraph to maintain a JWKS cache.
- Not securing the network path to subgraphs — JWT verification at the router is useless if subgraphs are directly accessible.
- Using operation-level authorization only — a user might be allowed to run a query but not see specific fields in the response.
- Not considering service-to-service auth (machine tokens vs. user tokens) for backend federation clients.

### Follow-Up Questions

- "How do you handle authorization for a field that depends on data from another subgraph?"
- "What's the security model when one subgraph calls another's `@key` for entity resolution — is that authenticated?"
- "How do you audit field-level access denials for compliance?"

---

## Question 5: What Are the Trade-Offs Between Schema-First and Code-First GraphQL?

### What the interviewer is evaluating

Your ability to evaluate tooling choices against team workflow and organizational context — not just enumerate pros and cons but reason about when each approach is correct.

### Model Answer

**Schema-first — define the SDL, generate types:**

In schema-first, the SDL is the source of truth. You write `schema.graphql`, then generate TypeScript types, resolver stubs, and client query types from it.

```graphql
# schema.graphql — written by hand
type Product {
  id: ID!
  name: String!
  price: Money!
}

type Query {
  product(id: ID!): Product
}
```

```bash
# Generate TypeScript types from SDL
graphql-codegen --config codegen.yml
# Produces: resolvers.ts, types.ts, operations.d.ts
```

**Advantages of schema-first:**
- Schema is readable, diffable, and reviewable without running any code
- Schema review becomes a first-class PR artifact — non-engineers can read and provide feedback
- Tooling (Studio, Sandbox, graphql-eslint) operates directly on SDL
- Federation composition operates on SDL — aligns naturally with the subgraph contribution model
- The schema contract is explicit and version-controlled independent of implementation

**Disadvantages:**
- SDL and resolvers can drift — if you change `schema.graphql` without updating resolvers, you get runtime errors, not compile errors (unless you run `graphql-code-generator`)
- Duplication: you define the type in SDL, then implement it in TypeScript — two representations
- IDE support (autocomplete, jump-to-definition) is weaker than native TypeScript

**Code-first — generate SDL from code:**

In code-first, the SDL is derived from your TypeScript or Python code. Libraries like Nexus, TypeGraphQL, or Strawberry generate the schema at runtime from decorated class/function definitions.

```typescript
// TypeGraphQL example — SDL is generated from this
@ObjectType()
class Product {
  @Field(() => ID)
  id: string;

  @Field()
  name: string;

  @Field(() => Money)
  price: Money;
}

@Resolver(Product)
class ProductResolver {
  @Query(() => Product, { nullable: true })
  async product(@Arg('id') id: string): Promise<Product | null> {
    return this.productService.findById(id);
  }
}
```

**Advantages of code-first:**
- Single source of truth — the TypeScript class is both the type definition and the implementation
- Full IDE support: autocomplete, refactoring, type errors catch schema/resolver mismatches at compile time
- Easier to share types between the GraphQL layer and business logic
- Refactoring a type name updates the SDL automatically

**Disadvantages:**
- SDL is a build artifact — cannot be reviewed or diffed without running the build
- Schema governance is harder: `graphql-eslint` rules require the SDL file to exist statically
- Federation is awkward: `@key` and other directives require special decorator syntax
- Non-engineers cannot read the schema from the codebase without running code generation

**The verdict:**

Schema-first is correct for:
- Federated supergraphs where multiple teams contribute to a shared SDL
- Teams with API-first design culture (schema RFC before implementation)
- Organizations with schema governance, linting, and breaking change detection requirements

Code-first is correct for:
- Single-team, single-service GraphQL where schema and implementation are always in sync
- Teams with strong TypeScript culture and existing type hierarchies to leverage
- Rapid prototyping where SDL maintenance is friction

Most enterprise GraphQL platforms converge on schema-first because the SDL needs to exist as a static artifact for federation composition and governance tooling.

### Common Mistakes

- Treating this as a purely technical question — the team workflow and tooling ecosystem matter as much as the syntax.
- Not mentioning that federation composition requires SDL — code-first adds complexity in federation.
- Saying "code-first is always better because TypeScript" without acknowledging schema governance trade-offs.
- Not knowing the specific tools: schema-first (graphql-codegen), code-first (TypeGraphQL, Nexus, Strawberry).

### Follow-Up Questions

- "Your team is adopting federation. Which approach do you recommend and why?"
- "How do you enforce schema linting rules in a code-first project?"
- "What happens to schema-first/code-first in a polyglot organization where subgraphs use Python, Go, and TypeScript?"

---

## Question 6: Design the Observability Strategy for a GraphQL Supergraph

### What the interviewer is evaluating

Your understanding of how the four observability pillars (metrics, traces, logs, alerts) apply specifically to GraphQL — not just generic APM — and your knowledge of the golden signal adaptations needed for a protocol where all requests hit the same endpoint.

### Model Answer

"GraphQL observability requires adaptations to standard HTTP monitoring because the traditional signals don't map cleanly. All requests are POST to `/graphql` with 200 OK responses — so HTTP status code monitoring misses most failures, and URL-based routing metrics are meaningless."

**The four pillars adapted for GraphQL:**

**1. Metrics — Operation-level granularity:**

```
Standard HTTP metrics (useless for GraphQL):
  POST /graphql — p50: 20ms, p99: 500ms, error_rate: 0%
  (All queries, mutations, and subscriptions rolled together. The 0% error_rate
   hides GraphQL errors that return HTTP 200.)

GraphQL-specific metrics (useful):
  operation_latency{operation_name="GetProductPage", operation_type="query"} — histogram
  operation_latency{operation_name="Checkout", operation_type="mutation"} — histogram
  operation_errors_total{operation_name="Checkout", error_code="PAYMENT_DECLINED"} — counter
  field_resolver_latency{field="Product.variants", subgraph="catalog"} — histogram
  subgraph_fetch_duration{subgraph="orders"} — histogram
  entity_resolution_rate{entity="User", subgraph="users"} — counter
  persisted_query_hit_rate — gauge (ratio of cached vs. uncached query documents)
```

**2. Distributed traces — End-to-end per operation:**

Apollo Router generates OpenTelemetry traces with spans for:
- Router receives query
- Query plan generation
- Per-subgraph fetch (with subgraph name, URL, latency)
- Entity resolution fetches
- Router merges response

```yaml
# router.yaml — OTEL trace export
telemetry:
  tracing:
    propagation:
      trace_context: true
    exporters:
      otlp:
        endpoint: "http://otel-collector:4317"
        protocol: Grpc
    spans:
      router:
        attributes:
          graphql.operation.name: true
          graphql.operation.type: true
          graphql.document.hash: true   # Hash, not raw document — PII protection
      subgraph:
        attributes:
          subgraph.name: true
          graphql.operation.name: true
```

Trace-to-metric correlation: when p99 latency spikes, jump from the latency chart to a sampled trace from the same window to see exactly which subgraph or resolver is slow.

**3. Logging — Structured, operation-aware:**

```json
{
  "timestamp": "2025-01-15T14:32:01.234Z",
  "level": "info",
  "trace_id": "abc123def456",
  "operation_name": "Checkout",
  "operation_type": "mutation",
  "client_name": "web-checkout-v3",
  "client_version": "2.1.4",
  "duration_ms": 234,
  "subgraph_fetches": [
    { "subgraph": "orders", "duration_ms": 45 },
    { "subgraph": "payments", "duration_ms": 187 }
  ],
  "errors": [],
  "document_hash": "sha256:7f3d..."
}
```

Never log raw query documents or variable values in production — they may contain PII, payment data, or credentials. Log the operation name, document hash, and error count.

**4. Alerts — GraphQL golden signals:**

| Signal | Alert Condition | Runbook Link |
|---|---|---|
| Error rate by operation | `errors_total{operation_name="Checkout"} > 1% for 5m` | checkout-errors.md |
| p99 latency by subgraph | `subgraph_fetch_p99{subgraph="payments"} > 2s for 3m` | subgraph-latency.md |
| Subgraph availability | `subgraph_up{subgraph=~".*"} == 0` | subgraph-down.md |
| Router error rate | `router_errors_total / router_requests_total > 0.5%` | router-health.md |
| Entity resolution rate spike | `entity_resolutions_total increase > 10x p50` | n-plus-one-alert.md |
| Schema composition failure | `composition_check_failed` gauge in CI | schema-comp-failure.md |

**Operation-level SLOs:**

Define SLOs per operation, not per service:

```yaml
slos:
  - operation: GetProductPage
    target: p99 < 800ms, error_rate < 0.1%
  - operation: Checkout
    target: p99 < 3000ms, error_rate < 0.5%
  - operation: SearchProducts
    target: p99 < 600ms, error_rate < 0.2%
```

This granularity enables alerting on the operations that matter to the business, rather than blunt service-level metrics that hide per-operation regressions.

### Common Mistakes

- Treating GraphQL like REST — monitoring HTTP status codes and URL patterns. In GraphQL, `errors[]` in a 200 response body is where real failures live.
- Logging raw query documents — this is a PII and security risk.
- Not instrumenting entity resolution rate — a spike here indicates federation-level N+1.
- Defining SLOs at the service level rather than operation level — this hides which user flows are actually degraded.
- Not mentioning client name/version in logs and metrics — you can't trace a performance regression to a specific client deployment without it.

### Follow-Up Questions

- "How do you alert on a new operation that has no historical baseline?"
- "A client is sending anonymous queries with no `operationName`. How do you handle observability for those?"
- "How does field usage analytics from Apollo Studio complement your operational metrics?"

---

## Related Topics

- [Chapter 07: Federation](../07-federation/) — full federation reference
- [Chapter 14: Observability](../14-observability/) — detailed observability implementation guide
- [Chapter 05: Security](../05-security/) — auth implementation patterns
- [Chapter 09: Schema Governance](../09-schema-governance/) — governance processes for schema-first teams
- [03-system-design-questions.md](./03-system-design-questions.md) — principal-level architecture scenarios
- [Chapter 28: Best Practices — Federation](../28-best-practices/03-federation-best-practices.md) — opinionated federation rules
