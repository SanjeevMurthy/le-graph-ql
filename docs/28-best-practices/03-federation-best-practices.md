# Federation Best Practices

> **Purpose:** Twenty-plus federation design and operational rules for enterprise GraphQL deployments using Apollo Federation v2. Each rule addresses a failure mode unique to federated systems: database coupling, composition failures in production, broken entity resolution, and cross-team schema conflicts. Apply these rules from the first subgraph design session.

---

## BP-F-01: One Subgraph Per Bounded Context — Not One Per Microservice

**Rule:** Subgraph boundaries must align with Domain-Driven Design (DDD) bounded contexts, not with microservice deployment units. A single bounded context may be served by multiple microservices internally. Those microservices present a single subgraph to the federation.

**Rationale:** When subgraph boundaries match microservice boundaries, a single user-facing operation may require fetching data from 15+ subgraphs. Every cross-subgraph boundary requires a `_entities` fetch — a round trip from the router to a subgraph. More subgraphs means more round trips means higher latency. Bounded context alignment reduces the number of cross-subgraph joins while maintaining team autonomy.

The bounded context boundary is where the ubiquitous language changes. "Order" means different things in the Fulfillment context vs. the Billing context — that's where the subgraph boundary belongs.

**Counter-example:**

```yaml
# BAD: One subgraph per microservice — over-split
subgraphs:
  - name: order-service          # Microservice 1
  - name: order-line-items       # Microservice 2 — too fine-grained
  - name: order-status           # Microservice 3
  - name: order-payments         # Microservice 4
  - name: order-shipping         # Microservice 5
  # Fetching one order now requires 5 cross-subgraph round trips
```

**Correct:**

```yaml
# GOOD: One subgraph per bounded context
subgraphs:
  - name: orders          # Bounded context: Order Management
    # Internally: order-service, order-line-items, order-status microservices
  - name: payments        # Bounded context: Payment Processing
    # Internally: payment-gateway, refund-service microservices
  - name: fulfillment     # Bounded context: Fulfillment & Shipping
    # Internally: warehouse, shipping, tracking microservices
  - name: catalog         # Bounded context: Product Catalog
  - name: identity        # Bounded context: Identity & Access
```

---

## BP-F-02: Never Share a Database Between Subgraphs

**Rule:** Each subgraph must have exclusive ownership of its data store. No two subgraphs may read from or write to the same database, table, or schema. If two subgraphs need the same data, one must own it and expose it via the federation entity mechanism.

**Rationale:** Shared databases couple subgraphs at the data layer. A schema migration in the shared database requires coordinated deployment across all subgraphs that depend on it — exactly the coupling that federation is designed to eliminate. Database sharing also makes independent scaling impossible: if the orders subgraph needs a read replica but the payments subgraph does not, they cannot scale independently when sharing a database.

**Counter-example:**

```
# BAD: Two subgraphs sharing the same PostgreSQL instance and schema
orders-subgraph  → orders_db.public.orders
payments-subgraph → orders_db.public.orders  # Shared table!
```

**Correct:**

```
# GOOD: Each subgraph owns its data store exclusively
orders-subgraph   → orders_db (PostgreSQL, dedicated instance)
payments-subgraph → payments_db (PostgreSQL, dedicated instance)

# When payments-subgraph needs order data:
# 1. Query the orders-subgraph via _entities
# 2. The router plans the fetch automatically via @key
```

Federated entity ownership:

```graphql
# orders-subgraph: owns Order
type Order @key(fields: "id") {
  id: ID!
  status: OrderStatus!
  lineItems: [OrderLineItem!]!
}

# payments-subgraph: references Order but does NOT own it
extend type Order @key(fields: "id") {
  id: ID! @external
  """Payment captured for this order. Owned by the payments subgraph."""
  payments: [Payment!]!
}
```

---

## BP-F-03: Explicitly Define `@key` Fields — Avoid Compound Keys With Many Fields

**Rule:** Use single-field `@key` wherever possible. Compound `@key` directives must be limited to two fields maximum. Never use a compound key with three or more fields as the primary entity identifier.

**Rationale:** Compound keys increase the payload size of `_entities` queries (the router must send all key fields for every entity in the batch). They also couple the entity resolution mechanism to a specific business identifier — if that identifier changes, entity resolution breaks across all subgraphs that reference the entity. Single-field UUID keys are stable, minimal, and portable.

**Counter-example:**

```graphql
# BAD: Compound key with 4 fields — fragile and verbose
type OrderLineItem @key(fields: "orderId productId warehouseId quantity") {
  orderId: ID!
  productId: ID!
  warehouseId: ID!
  quantity: Int!
}
```

**Correct:**

```graphql
# GOOD: Single UUID key — stable, minimal, portable
type OrderLineItem @key(fields: "id") {
  """Stable UUID identifier. Immutable after creation."""
  id: ID!
  orderId: ID!
  productId: ID!
  quantity: Int!
}
```

When a compound key is genuinely necessary (e.g., a composite primary key with no surrogate ID):

```graphql
# Acceptable: 2-field compound key when no surrogate key exists
type UserRoleAssignment @key(fields: "userId roleId") {
  userId: ID!
  roleId: ID!
  grantedAt: DateTime!
  grantedBy: User!
}
```

---

## BP-F-04: Use `@shareable` Sparingly — Prefer Single Canonical Ownership

**Rule:** A type or field marked `@shareable` can be resolved by multiple subgraphs. Use `@shareable` only for stable, read-only value types (e.g., `Money`, `Address`, `GeoPoint`) that have no ownership semantics. Never mark mutable entity types as `@shareable`.

**Rationale:** `@shareable` means "this field can be resolved by any subgraph that defines it." This sounds convenient but creates ambiguity about which subgraph is authoritative. For mutable entities, divergent reads become possible: the orders subgraph and the shipping subgraph return different values for the same `@shareable` field on `Order`. Canonical ownership prevents this.

**Correct:**

```graphql
# GOOD: Value types can be @shareable — they are immutable and have no owner
type Money @shareable {
  amount: Int!
  currency: CurrencyCode!
}

type GeoPoint @shareable {
  latitude: Float!
  longitude: Float!
}

# BAD: Do not make mutable entities @shareable
# type Order @shareable { ... }  # Ambiguous ownership, divergent reads possible
```

---

## BP-F-05: Always Run Composition Check in CI Before Merging Any Subgraph Change

**Rule:** Every pull request that modifies a subgraph schema must run `rover subgraph check` as a required CI check. The PR cannot merge if the composition check fails. This is non-negotiable.

**Rationale:** Composition failures discovered in production bring down the entire supergraph. The router cannot start without a valid composed supergraph. A composition error in one subgraph makes the entire API unavailable for all clients. CI composition checks catch these failures before deployment.

**GitHub Actions implementation:**

```yaml
# .github/workflows/schema-check.yml
name: Schema Check

on:
  pull_request:
    paths:
      - 'src/**/*.graphql'
      - 'schema/**'

jobs:
  schema-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Rover CLI
        run: curl -sSL https://rover.apollo.dev/nix/latest | sh

      - name: Add Rover to PATH
        run: echo "$HOME/.rover/bin" >> $GITHUB_PATH

      - name: Check subgraph schema
        env:
          APOLLO_KEY: ${{ secrets.APOLLO_KEY }}
          APOLLO_GRAPH_REF: ${{ vars.APOLLO_GRAPH_REF }}
        run: |
          rover subgraph check $APOLLO_GRAPH_REF \
            --name orders \
            --schema ./schema/orders.graphql \
            --routing-url https://orders.internal/graphql
```

---

## BP-F-06: Deploy Subgraphs Independently With Decoupled Release Trains

**Rule:** Subgraph deployments must be fully independent. No subgraph deployment should require a coordinated, simultaneous deployment of another subgraph. Each team deploys on their own schedule.

**Rationale:** Coordinated deployments reintroduce the coupling that federation eliminates. If the orders subgraph deployment requires the shipping subgraph to deploy simultaneously, teams cannot ship independently. Use schema evolution rules (backward-compatible additions only; deprecation before removal) to maintain forward and backward compatibility across independent deployments.

**Deployment independence checklist:**

```
Before deploying a subgraph change, verify:

□ New fields are added (not removed) — additions are backward compatible
□ No existing field types are changed to a breaking variant
□ No @key fields are modified (immutable contract)
□ No @required fields have been added without a default
□ Composition check passes against the current live supergraph
□ The subgraph has been tested with the current router version
□ A rollback procedure is documented and verified
```

---

## BP-F-07: Use `@tag` and Schema Contracts to Expose Different API Surfaces

**Rule:** Use Apollo Federation `@tag` annotations to segment the supergraph into contract graphs. External partners receive a contract graph that exposes only `@tag(name: "partner")` fields. Internal tooling receives a contract graph for `@tag(name: "internal")` fields. Never build separate schemas for different audiences.

**Rationale:** Without schema contracts, the options are: expose everything (including internal admin fields) to external partners, or maintain separate schemas (a maintenance nightmare). `@tag` annotations on fields and types let a single supergraph serve multiple client audiences with different schema surfaces, all from one source of truth.

**SDL annotations:**

```graphql
type Order @key(fields: "id") {
  """Available to all clients."""
  id: ID!

  """Available to all clients."""
  status: OrderStatus!

  """Only available to internal tools (e.g., admin dashboards)."""
  internalNotes: String @tag(name: "internal")

  """Available to external partners via the partner contract graph."""
  trackingNumber: String @tag(name: "partner") @tag(name: "internal")

  """Only available to internal billing tools."""
  billingDetails: BillingDetails @tag(name: "internal") @tag(name: "billing")
}
```

**Contract definition in GraphOS:**

```yaml
# contract: partner-api
filter:
  include_tags:
    - partner
  exclude_types:
    - AdminUser
    - InternalMetrics
```

---

## BP-F-08: Set Subgraph Query Timeouts in router.yaml

**Rule:** Every subgraph must have an explicit query timeout configured in `router.yaml`. The timeout must be tuned to the subgraph's SLA — not set to a single global value.

**Rationale:** Without per-subgraph timeouts, one slow or unresponsive subgraph holds the router's response indefinitely. The router connection pool fills with pending requests, starving other operations. Per-subgraph timeouts allow the router to return partial data from healthy subgraphs and a structured error for the timed-out subgraph.

**router.yaml configuration:**

```yaml
# router.yaml
traffic_shaping:
  all:
    # Global default timeout for all subgraph requests
    timeout: 30s

  router:
    timeout: 60s  # Total request timeout at the router

subgraph:
  # Per-subgraph timeout overrides
  orders:
    timeout: 5s       # Orders are critical, fail fast
  recommendations:
    timeout: 500ms    # Non-critical, aggressive timeout with empty-list fallback
  search:
    timeout: 3s
  identity:
    timeout: 2s       # Auth data — must be fast
  analytics:
    timeout: 10s      # Analytics can take longer — not user-facing critical path
```

---

## BP-F-09: Monitor Entity Resolution Rate — A Spike Signals Federation-Level N+1

**Rule:** Export a metric for `_entities` query rate per subgraph per operation. Alert when the `_entities` call count for a single operation exceeds (list size × expected subgraph count). A spike in entity resolution calls is the federation equivalent of a resolver-level N+1.

**Rationale:** In a federated schema, a query that returns a list of 100 orders and then accesses a field owned by the shipping subgraph should generate one `_entities` fetch with 100 order IDs. If it generates 100 individual `_entities` fetches, there is a query planning problem or a missing `@key` relationship that the router cannot batch. This failure is invisible without the metric.

**Prometheus alert rule:**

```yaml
# alerts/federation.yml
groups:
  - name: federation
    rules:
      - alert: EntityResolutionNPlus1Suspected
        expr: |
          rate(apollo_router_subgraph_requests_total{
            subgraph_name!="",
            query_name=~".*"
          }[5m])
          / on(query_name) group_left()
          rate(apollo_router_requests_total[5m]) > 50
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Possible federation N+1: {{ $labels.subgraph_name }}"
          description: >
            Subgraph {{ $labels.subgraph_name }} is receiving >50x more requests
            than the router is receiving operations. Suspected entity resolution N+1.
```

---

## BP-F-10: Write Contract Tests for `@requires` Dependencies Between Subgraphs

**Rule:** Any field that uses `@requires` to depend on data from another subgraph must have a contract test that verifies the required fields are actually present in the owning subgraph's `__resolveReference` response.

**Rationale:** `@requires` creates an implicit contract: the shipping subgraph requires `weight` and `dimensions` to be present on the `Product` type, provided by the catalog subgraph. If the catalog subgraph changes or removes those fields, the shipping subgraph's `shippingEstimate` field silently fails — the required data is null at runtime. Contract tests catch this before deployment.

**SDL:**

```graphql
# catalog-subgraph
type Product @key(fields: "id") {
  id: ID!
  name: String!
  weightGrams: Int!
  dimensionsCm: Dimensions!
}

# shipping-subgraph
extend type Product @key(fields: "id") {
  id: ID! @external
  weightGrams: Int! @external
  dimensionsCm: Dimensions! @external

  """Shipping cost estimate. Requires weight and dimensions from catalog."""
  shippingEstimate(destinationPostalCode: String!): ShippingEstimate!
    @requires(fields: "weightGrams dimensionsCm { length width height }")
}
```

**Contract test:**

```typescript
// shipping-subgraph/src/__tests__/product-requires.contract.test.ts
describe('@requires contract: Product.shippingEstimate', () => {
  test('shippingEstimate receives weightGrams and dimensionsCm from router', async () => {
    // Simulate the router calling _entities with the required fields
    const response = await executeSubgraphQuery(`
      query($representations: [_Any!]!) {
        _entities(representations: $representations) {
          ... on Product {
            shippingEstimate(destinationPostalCode: "10001") {
              estimatedDays
              cost { amount currency }
            }
          }
        }
      }
    `, {
      representations: [{
        __typename: 'Product',
        id: 'prod-1',
        // @requires fields — must be present in the representation
        weightGrams: 500,
        dimensionsCm: { length: 20, width: 15, height: 10 },
      }]
    });

    expect(response.errors).toBeUndefined();
    expect(response.data._entities[0].shippingEstimate.estimatedDays).toBeGreaterThan(0);
  });

  test('shippingEstimate handles missing weightGrams gracefully', async () => {
    // Verify the error case is handled — catalog returned null for weightGrams
    const response = await executeSubgraphQuery(`...`, {
      representations: [{ __typename: 'Product', id: 'prod-1', weightGrams: null, dimensionsCm: null }]
    });
    expect(response.data._entities[0].shippingEstimate).toBeNull();
  });
});
```

---

## BP-F-11: Prefix Subgraph Mutations With the Domain Name to Prevent Collisions

**Rule:** Mutations in subgraphs that may share names across domain boundaries must be prefixed with the domain name. Use `catalogCreateProduct` or `catalog_createProduct` — not `createProduct` which conflicts with `inventory_createProduct`.

**Rationale:** When 50 subgraphs all define a `createProduct` mutation, composition fails. Even if the current 5 subgraphs don't conflict, the schema grows over time. Consistent prefixing from the start prevents composition conflicts and makes the mutation namespace self-organizing.

**Counter-example:**

```graphql
# catalog-subgraph — will conflict if any other subgraph defines createProduct
type Mutation {
  createProduct(input: CreateProductInput!): CreateProductResult!
}
```

**Correct:**

```graphql
# catalog-subgraph — domain-prefixed, no collision possible
type Mutation {
  catalogCreateProduct(input: CatalogCreateProductInput!): CatalogCreateProductResult!
  catalogUpdateProduct(input: CatalogUpdateProductInput!): CatalogUpdateProductResult!
  catalogArchiveProduct(input: CatalogArchiveProductInput!): CatalogArchiveProductResult!
}

# inventory-subgraph — distinct namespace
type Mutation {
  inventoryAdjustStock(input: InventoryAdjustStockInput!): InventoryAdjustStockResult!
  inventoryTransferStock(input: InventoryTransferStockInput!): InventoryTransferStockResult!
}
```

---

## BP-F-12: Keep `@key` Fields Immutable — Changing Them Is a Breaking Change

**Rule:** Once an entity type has been published to the schema registry with a `@key`, the fields designated as the key must never change. Key fields are immutable. If you need a different key structure, introduce a new `@key` using `resolvable: false` compatibility, but do not remove or modify the existing key.

**Rationale:** The `@key` fields are the identity of an entity across the federation. When the router fetches an entity via `_entities`, it sends a representation containing the `@key` fields. If those fields change, every subgraph that references the entity will send a representation using the old fields — the entity cannot be resolved. This is a federation-wide breaking change.

**Counter-example:**

```graphql
# BEFORE: Order keyed by id
type Order @key(fields: "id") {
  id: ID!
  # ...
}

# BAD: Changing the key — breaks all subgraphs that reference Order
type Order @key(fields: "orderNumber") {  # Key changed!
  orderNumber: String!
  # ...
}
```

**Correct approach for adding an alternative key:**

```graphql
# GOOD: Add a new @key without removing the existing one
type Order @key(fields: "id") @key(fields: "orderNumber") {
  id: ID!
  orderNumber: String!
  # ...
}

# Resolver must handle both representations
const resolvers = {
  Order: {
    __resolveReference: async (reference) => {
      if (reference.id) {
        return orderRepo.findById(reference.id);
      }
      if (reference.orderNumber) {
        return orderRepo.findByOrderNumber(reference.orderNumber);
      }
      throw new Error('Unresolvable Order reference');
    },
  },
};
```

---

## BP-F-13: Use `@inaccessible` to Hide Internal Fields From the Supergraph

**Rule:** Fields and types used for internal federation mechanics (join keys, internal identifiers) that should not appear in the client-facing supergraph must be marked `@inaccessible`.

**Rationale:** Some fields exist purely as federation join keys — they are not meaningful to clients. Exposing them clutters the supergraph schema and may reveal internal identifiers that clients have no reason to query. `@inaccessible` removes them from the composed supergraph while keeping them available for entity resolution.

**Correct:**

```graphql
# orders-subgraph
type Order @key(fields: "id") {
  id: ID!
  status: OrderStatus!
  # Internal field used as a join key to the fulfillment subgraph
  # Not meaningful to clients — hidden from the supergraph
  fulfillmentId: ID! @inaccessible
}

# fulfillment-subgraph
extend type Order @key(fields: "id") {
  id: ID! @external
  fulfillmentId: ID! @external @inaccessible
  fulfillmentStatus: FulfillmentStatus!
    @requires(fields: "fulfillmentId")
}
```

---

## BP-F-14: Version Subgraph Schema Changes With a Changelog

**Rule:** Every subgraph must maintain a schema changelog. Each entry records: the change, whether it is breaking/non-breaking, the affected fields, and the PR number. The changelog is reviewed in composition PR reviews.

**Rationale:** In a federated system with 50 subgraphs, understanding the history of schema changes requires tooling and process — not just git history. A structured changelog makes it possible to audit which subgraph introduced a breaking change, when deprecations were announced, and whether SLA timelines for removal were honored.

**Example changelog format:**

```markdown
# Orders Subgraph Schema Changelog

## 2025-01-15 — PR #4821
- **NON-BREAKING** Added `estimatedDeliveryDate: Date` to `Order` type
- **NON-BREAKING** Added `OrderDeliveryEstimate` type

## 2025-01-08 — PR #4790
- **DEPRECATION** `Order.shippingAddress` deprecated. Use `Order.shippingDetails` (added this PR).
  Removal target: 2025-04-01.
- **NON-BREAKING** Added `Order.shippingDetails: ShippingDetails`

## 2024-12-20 — PR #4620 [REMOVAL — announced 2024-09-20]
- **BREAKING** Removed `Order.legacyTrackingUrl` (deprecated 2024-09-20; 90-day window honored)
```

---

## BP-F-15: Test `__resolveReference` With All Expected Representation Shapes

**Rule:** Every subgraph entity's `__resolveReference` resolver must be tested with all valid representation shapes: the primary `@key`, any alternative `@key` values, and invalid representations that should return `null`.

**Correct:**

```typescript
describe('Order __resolveReference', () => {
  test('resolves by primary UUID key', async () => {
    await db.seed.order({ id: 'order-uuid-1', status: 'CONFIRMED' });
    const result = await resolvers.Order.__resolveReference({ id: 'order-uuid-1' }, context);
    expect(result?.id).toBe('order-uuid-1');
  });

  test('resolves by order number key', async () => {
    await db.seed.order({ id: 'order-uuid-2', orderNumber: 'ORD-2025-001' });
    const result = await resolvers.Order.__resolveReference(
      { orderNumber: 'ORD-2025-001' }, context
    );
    expect(result?.orderNumber).toBe('ORD-2025-001');
  });

  test('returns null for non-existent order', async () => {
    const result = await resolvers.Order.__resolveReference(
      { id: 'non-existent-uuid' }, context
    );
    expect(result).toBeNull();
  });
});
```

---

## BP-F-16: Use Health Check Endpoints on All Subgraphs for Router Startup Validation

**Rule:** Every subgraph must expose a `/.well-known/apollo/server-health` endpoint that returns HTTP 200 when the subgraph is healthy. The router startup must verify subgraph health before accepting traffic.

**Correct:**

```yaml
# router.yaml — subgraph health check configuration
health_check:
  enabled: true
  listen: 0.0.0.0:8088
  path: /health

# Kubernetes readiness probe for the router
readinessProbe:
  httpGet:
    path: /health?ready
    port: 8088
  initialDelaySeconds: 10
  periodSeconds: 5
  failureThreshold: 3
```

```typescript
// Subgraph health endpoint
app.get('/.well-known/apollo/server-health', async (req, res) => {
  try {
    await db.query('SELECT 1'); // Verify database connectivity
    res.json({ status: 'pass' });
  } catch (error) {
    res.status(503).json({ status: 'fail', reason: 'Database unavailable' });
  }
});
```

---

## BP-F-17: Use Progressive Rollout for Schema Changes — Not Big-Bang Deployments

**Rule:** Significant schema changes (new required fields, type changes, new entities) should be introduced progressively: first in a canary subgraph deployment, then validated in a staging supergraph, then promoted to production. Never deploy a schema change directly to the production supergraph without a canary validation step.

**Rationale:** A composition error or runtime entity resolution failure in production affects all clients immediately. Progressive rollout limits blast radius: a failed canary deployment affects a small percentage of traffic before the team can roll back.

**Deployment pipeline:**

```
schema change PR
  → rover subgraph check (CI)
  → merge to main
  → deploy subgraph to staging cluster
  → rover subgraph publish (staging graph variant)
  → run integration test suite against staging supergraph
  → deploy subgraph to production (canary: 5% traffic)
  → monitor entity resolution error rate (5 min)
  → promote to 100% traffic or rollback
```

---

## BP-F-18: Document Subgraph Ownership in the Schema Registry

**Rule:** Every subgraph must have a registered owner in the schema registry (GraphOS or Apollo Studio): a team name, Slack channel, and on-call contact. This is required for incident response.

**Rationale:** When the router reports a composition error or a subgraph times out, the platform team needs to know which team owns that subgraph and how to reach them. Without documented ownership, incident response time is multiplied by the time spent discovering who owns the broken subgraph.

**GraphOS metadata annotation:**

```yaml
# supergraph.yaml
subgraphs:
  orders:
    routing_url: https://orders.internal/graphql
    schema:
      file: ./subgraphs/orders.graphql
    # Custom metadata visible in GraphOS Studio
    metadata:
      owner_team: order-management
      slack_channel: "#team-orders"
      oncall_rotation: https://pagerduty.company.com/schedules/orders
      sla_p99_ms: 500
      runbook: https://wiki.company.com/runbooks/orders-subgraph

  payments:
    routing_url: https://payments.internal/graphql
    schema:
      file: ./subgraphs/payments.graphql
    metadata:
      owner_team: payments-platform
      slack_channel: "#team-payments"
      oncall_rotation: https://pagerduty.company.com/schedules/payments
      sla_p99_ms: 1000
```

---

## BP-F-19: Validate Supergraph Composition in a Dedicated Integration Environment

**Rule:** Maintain a dedicated integration environment (distinct from staging) where all subgraph schemas are composed together continuously against their latest main-branch versions. Any team can observe the current composition health of the entire supergraph at any time.

**Rationale:** Staging environments typically run the current production subgraph versions, not the latest development versions. Without an integration environment, a composition conflict between two subgraphs in development is only discovered when both attempt to deploy — too late. The integration environment catches cross-team conflicts early.

---

## BP-F-20: Limit Federation Depth — Maximum Three Hops per Operation

**Rule:** A single GraphQL operation must not require more than three cross-subgraph entity resolution hops. If an operation requires four or more sequential entity fetches across subgraph boundaries, the schema boundaries are wrong.

**Rationale:** Each cross-subgraph hop is a sequential round trip: the router cannot fetch the next entity until it receives the previous entity's key. Three sequential hops at 20ms each add 60ms of irreducible latency. Four hops add 80ms. Five hops add 100ms. Poor subgraph boundaries that require deep sequential joins make latency SLOs impossible to meet.

**Query plan analysis:**

```bash
# Use rover to inspect query plans and count sequential fetch nodes
rover supergraph compose --config supergraph.yaml > supergraph.graphql

# Enable query plan introspection in the router (non-production only)
# router.yaml:
# sandbox:
#   enabled: true
# Then POST to /query-plan with the operation
```

---

## References and Related Topics

- [Apollo Federation v2 Documentation](https://www.apollographql.com/docs/federation/) — official federation reference
- [Apollo Rover CLI](https://www.apollographql.com/docs/rover/) — `rover subgraph check`, `rover subgraph publish`
- [Apollo GraphOS](https://www.apollographql.com/docs/graphos/) — schema registry, schema checks, contract graphs
- [Chapter 07: Federation](../07-federation/README.md) — federation concepts and directives
- [Chapter 08: Supergraph Architecture](../08-supergraph-architecture/README.md) — broader supergraph design
- [Chapter 09: Schema Governance](../09-schema-governance/README.md) — cross-team governance process
- [Chapter 11: CI/CD Automation](../11-ci-cd-automation/README.md) — `rover subgraph check` in pull request pipelines
- [Chapter 12: GitHub Actions](../12-github-actions/README.md) — CI workflow implementations
- [Anti-Patterns](../29-anti-patterns/README.md) — documented federation failure post-mortems
- [03-enterprise-architecture.md](../30-reference-architectures/03-enterprise-architecture.md) — these practices applied at 50-subgraph scale
