# Federation Anti-Patterns

> Federation mistakes are expensive. A schema design error can be fixed in a PR. A topology mistake — like two subgraphs sharing a database, or 80 subgraphs where 8 would suffice — requires an organizational restructure to correct. This document covers the ten most common federation anti-patterns.

---

## Table of Contents

1. [Shared Database Between Subgraphs](#1-shared-database-between-subgraphs)
2. [Cross-Subgraph Direct Calls](#2-cross-subgraph-direct-calls)
3. [Overloaded @key](#3-overloaded-key)
4. [Subgraph Per Microservice](#4-subgraph-per-microservice)
5. [Missing Composition Check in CI](#5-missing-composition-check-in-ci)
6. [@requires Abuse](#6-requires-abuse)
7. [Ignoring Query Plan Cost](#7-ignoring-query-plan-cost)
8. [Anonymous Subgraph Ownership](#8-anonymous-subgraph-ownership)
9. [Hard-coded Subgraph URLs](#9-hard-coded-subgraph-urls)
10. [Schema-First Without Contract Tests](#10-schema-first-without-contract-tests)

---

## 1. Shared Database Between Subgraphs

**Severity**: Critical  
**Layer**: Domain Architecture

### What It Looks Like

```
┌─────────────────────┐    ┌─────────────────────┐
│   Users Subgraph    │    │   Orders Subgraph   │
│  (team-identity)    │    │  (team-commerce)    │
└────────┬────────────┘    └──────────┬──────────┘
         │                            │
         └────────────┬───────────────┘
                      ▼
              ┌───────────────┐
              │  PostgreSQL   │
              │  (shared DB)  │
              └───────────────┘
```

Both `users-subgraph` and `orders-subgraph` connect to the same `postgres://prod-db:5432/platform` database. The `orders` service reads directly from the `users` table.

### Why It Happens

The organization migrated from a monolith to microservices but did not decompose the database. The subgraph split was done at the GraphQL API layer only. Sharing the database is "temporary" until the DB split is done — which never happens because it requires coordinated downtime.

### What Goes Wrong

- **Coupled release trains**: a schema migration by team-identity that alters the `users` table can break the orders subgraph at deploy time, even though the orders team made no changes.
- **No domain isolation**: the orders subgraph can read (and accidentally write) user data. There is no enforcement of domain boundaries.
- **Database becomes the bottleneck**: both subgraphs compete for connection pool slots. Peak load from an orders spike degrades user authentication.
- **Testing is impossible in isolation**: the orders subgraph cannot be tested without the full database schema, including all user tables.

### The Correct Alternative

Each subgraph owns its own data store. Cross-subgraph data access is done through **entity resolution** — not direct database joins:

```graphql
# orders-subgraph: knows customer.id, resolves Order fields
type Order @key(fields: "id") {
  id: ID!
  customerId: ID!       # FK reference, not a JOIN
  total: Float!
}

# users-subgraph: resolves User fields when given an id
type User @key(fields: "id") {
  id: ID!
  email: String!
  displayName: String!
}

# The router stitches them:
# query { order(id: "o-1") { id total customer { email } } }
# → orders-subgraph: fetch order (gets customerId)
# → users-subgraph: fetch user by id (entity resolution)
```

The database split is the prerequisite for genuine federation. Without it, you have GraphQL federation syntax on top of a shared-database monolith.

---

## 2. Cross-Subgraph Direct Calls

**Severity**: High  
**Layer**: Topology

### What It Looks Like

```typescript
// In orders-subgraph resolvers:
const resolvers = {
  Order: {
    customer: async (order) => {
      // Direct HTTP call to users-subgraph, bypassing the router
      const response = await fetch(
        `http://users-subgraph:4001/graphql`,
        {
          method: 'POST',
          body: JSON.stringify({
            query: `{ user(id: "${order.customerId}") { email displayName } }`,
          }),
        }
      );
      return response.json().data.user;
    },
  },
};
```

### Why It Happens

The orders resolver needs user data. The developer knows the users-subgraph URL. Calling it directly is the obvious solution and avoids thinking about entity resolution.

### What Goes Wrong

- **Query planning is bypassed**: the router's query planner cannot optimize the full query if subgraphs are calling each other. Fan-out is invisible and uncontrolled.
- **Auth context is lost**: the router propagates JWT claims and request headers. A direct subgraph-to-subgraph call does not carry the same auth context, leading to authorization bypass bugs.
- **Observability is broken**: the distributed trace has a gap. The call from `orders-subgraph` to `users-subgraph` does not appear in the query plan trace.
- **Circular dependencies**: subgraph A calls B, B calls C, C calls A — a deadlock waiting to happen.
- **Service mesh policies are bypassed**: mTLS, rate limiting, and circuit breaking configured at the router layer are not applied to direct calls.

### The Correct Alternative

Use **`@key` entity resolution** — the correct federation pattern for cross-subgraph data access:

```graphql
# orders-subgraph: extend User with a stub key reference
extend type User @key(fields: "id") {
  id: ID! @external
}

type Order @key(fields: "id") {
  id: ID!
  customer: User!   # router resolves this via users-subgraph
}
```

The router's query planner sees that `Order.customer` requires a `User` entity, fetches the `id` from the order, and calls the users-subgraph's `_entities` resolver with the key. No direct calls. Full observability. Auth context propagated.

---

## 3. Overloaded @key

**Severity**: Medium  
**Layer**: Entity Design

### What It Looks Like

```graphql
# orders-subgraph
type Order @key(fields: "id region tenantId customerId createdYear") {
  id: ID!
  region: String!
  tenantId: ID!
  customerId: ID!
  createdYear: Int!
  # ... rest of order fields
}
```

A 5-field composite `@key` because the team wanted to encode partitioning metadata into the key.

### Why It Happens

The data is partitioned by `(tenantId, region, createdYear)` in the database for performance. The developer carries the partitioning key into the GraphQL entity key to ensure the entity resolver can efficiently locate the row.

### What Goes Wrong

- **Complicates every entity reference**: any subgraph that references `Order` must provide all 5 fields in the `@key` representation. This propagates the partitioning concern to every consumer.
- **Fragile composition**: if the partitioning strategy changes (e.g., you stop partitioning by year), the `@key` must change — a potentially breaking federation change.
- **Performance myth**: the router fetches entities by key. Adding more fields to the key does not make the fetch faster unless the resolver actually uses them for query optimization — which should happen inside the resolver, not in the key.
- **Testing complexity**: integration tests must construct valid 5-field key objects.

### The Correct Alternative

Use a **single opaque ID** as the `@key`. Handle partitioning inside the resolver:

```graphql
type Order @key(fields: "id") {
  id: ID!     # encodes region/tenant/year internally (e.g. "ord_us-east_t123_2024_abc")
  region: String!
  tenantId: ID!
}
```

The resolver decodes the `id` to extract partitioning metadata:

```typescript
const resolvers = {
  Order: {
    __resolveReference: async ({ id }) => {
      const { region, tenantId, year } = decodeOrderId(id);
      return db.findOrder(id, { region, tenantId, year }); // efficient lookup
    },
  },
};
```

The partitioning concern is encapsulated in the resolver. The federation key is simple.

---

## 4. Subgraph Per Microservice

**Severity**: High  
**Layer**: Topology

### What It Looks Like

```
Supergraph (router)
├── user-profile-subgraph          (team-identity, service: user-profile-svc)
├── user-authentication-subgraph   (team-identity, service: auth-svc)
├── user-preferences-subgraph      (team-identity, service: prefs-svc)
├── order-creation-subgraph        (team-commerce, service: order-create-svc)
├── order-fulfillment-subgraph     (team-commerce, service: order-fulfill-svc)
├── order-history-subgraph         (team-commerce, service: order-history-svc)
├── payment-processing-subgraph    (team-payments, service: payment-svc)
├── payment-refunds-subgraph       (team-payments, service: refunds-svc)
...
80 subgraphs total
```

### Why It Happens

The organization has a strong "one service, one subgraph" convention. It starts as good hygiene (service isolation) but gets applied mechanically to every microservice, including internal services that expose only 3 types.

### What Goes Wrong

- **Query plan fan-out**: a single query requesting user profile, order history, and payment status now spans 6 subgraphs. The router makes 6 serial or parallel calls instead of 2-3. Each network hop adds latency.
- **Composition node count grows**: `rover supergraph compose` with 80 subgraph definitions takes longer, fails more often, and produces more complex composition errors.
- **Operational overhead**: 80 subgraphs mean 80 deployment pipelines, 80 schema registrations, 80 sets of health checks, and 80 on-call rotations.
- **Gateway memory**: the router holds the full supergraph schema in memory. At 80 subgraphs with 50 types each, this is a significant schema size.

### The Correct Alternative

Map subgraphs to **domain boundaries**, not service boundaries. Multiple services can be represented by one subgraph if they belong to the same domain:

```
Supergraph (router)
├── identity-subgraph      (team-identity: profile + auth + preferences)
├── commerce-subgraph      (team-commerce: orders + fulfillment + history)
├── payments-subgraph      (team-payments: processing + refunds)
├── catalog-subgraph       (team-catalog: products + inventory + pricing)
├── notifications-subgraph (team-platform: email + push + webhooks)
```

A subgraph can be a **gateway to multiple internal services**:

```
identity-subgraph
  ├── → user-profile-svc (HTTP)
  ├── → auth-svc (HTTP)
  └── → prefs-svc (HTTP)
```

Target 5–15 subgraphs for most organizations. Expand only when teams and domains clearly separate.

---

## 5. Missing Composition Check in CI

**Severity**: Critical  
**Layer**: CI/CD

### What It Looks Like

```yaml
# .github/workflows/deploy-subgraph.yml — anti-pattern
name: Deploy Subgraph
on:
  push:
    branches: [main]

jobs:
  deploy:
    steps:
      - uses: actions/checkout@v4
      - run: npm install && npm run build
      - run: kubectl apply -f k8s/  # deploy without checking composition
```

### Why It Happens

Teams add the composition check "later." The subgraph works locally. The deployment pipeline was built before federation was added. Under deadline pressure, composition checks are skipped.

### What Goes Wrong

A subgraph change that renames a type, removes a field, or changes a `@key` can break **composition** at the supergraph level without any individual subgraph failing its tests:

```
Error: [users-subgraph] User.displayName is marked @external 
but is not present in orders-subgraph which declares 
@requires(fields: "displayName")

Composition failed. Supergraph schema not updated.
```

Without the CI check, this error surfaces when the router attempts to recompose — which happens on the **next deploy of any subgraph**, potentially hours or days later, making root cause analysis difficult.

### The Correct Alternative

Run `rover subgraph check` on every PR:

```yaml
# .github/workflows/deploy-subgraph.yml
name: Deploy Subgraph
on:
  push:
    branches: [main]
  pull_request:

jobs:
  schema-check:
    steps:
      - uses: actions/checkout@v4
      - name: Install Rover
        run: curl -sSL https://rover.apollo.dev/nix/latest | sh
      - name: Check schema composition
        env:
          APOLLO_KEY: ${{ secrets.APOLLO_KEY }}
        run: |
          rover subgraph check my-graph@production \
            --name users \
            --schema ./schema.graphql
  deploy:
    needs: schema-check   # deploy only if composition check passes
    steps:
      - run: kubectl apply -f k8s/
```

`rover subgraph check` validates:
1. The subgraph schema composes successfully with all other subgraphs.
2. No breaking changes are introduced to client operations tracked in GraphOS.

Block deployment on composition check failure. No exceptions.

---

## 6. @requires Abuse

**Severity**: High  
**Layer**: Query Planning

### What It Looks Like

```graphql
# shipping-subgraph
extend type User @key(fields: "id") {
  id: ID! @external

  # Pulling 10 fields from users-subgraph for a single computed field
  firstName: String! @external
  lastName: String! @external
  email: String! @external
  addressLine1: String! @external
  addressLine2: String @external
  city: String! @external
  state: String! @external
  postalCode: String! @external
  country: String! @external
  phoneNumber: String @external

  shippingLabel: ShippingLabel! @requires(fields: "firstName lastName email addressLine1 addressLine2 city state postalCode country phoneNumber")
}
```

### Why It Happens

The shipping label generation requires address data. The shipping subgraph does not own address data — it is in the users-subgraph. `@requires` is the correct federation primitive for this pattern. Requiring 10 fields feels justified because all 10 are needed for the label.

### What Goes Wrong

- **Inter-subgraph coupling**: the shipping-subgraph now has an implicit contract with the users-subgraph on 10 specific field names. Renaming `addressLine1` to `streetAddress` in users-subgraph is now a breaking change for the shipping subgraph.
- **Query plan bloat**: any query that requests `shippingLabel` triggers a fetch of 10 fields from the users-subgraph, regardless of whether the client requested any of those fields.
- **Composition errors multiply**: 10 `@external` fields, each a potential source of composition failure.

### The Correct Alternative

Model the dependency as a **dedicated input type** and fetch it as a unit, or move the computation to the owning subgraph:

**Option A: Dedicated input object**
```graphql
# users-subgraph: expose a compound address type
type ShippingAddress {
  firstName: String!
  lastName: String!
  email: String!
  addressLine1: String!
  addressLine2: String
  city: String!
  state: String!
  postalCode: String!
  country: String!
  phone: String
}

type User @key(fields: "id") {
  id: ID!
  shippingAddress: ShippingAddress  # one field, not ten
}

# shipping-subgraph
extend type User @key(fields: "id") {
  id: ID! @external
  shippingAddress: ShippingAddress! @external

  shippingLabel: ShippingLabel! @requires(fields: "shippingAddress { ... }")
}
```

**Option B: Move to the owning subgraph** — if users-subgraph owns address data, move `shippingLabel` computation there as well.

---

## 7. Ignoring Query Plan Cost

**Severity**: High  
**Layer**: Performance

### What It Looks Like

```graphql
# Schema designed without thinking about query plan traversal:
type Query {
  # Requires: router → products-subgraph
  products(category: ID!): [Product!]!
}

type Product @key(fields: "id") {
  id: ID!
  name: String!
  # Requires: router → inventory-subgraph (1 call per product)
  inventory: InventoryStatus!
  # Requires: router → pricing-subgraph (1 call per product)
  currentPrice: Price!
  # Requires: router → reviews-subgraph (1 call per product)
  reviewSummary: ReviewSummary!
}
```

Query: `{ products(category: "electronics") { name inventory { inStock } currentPrice { amount } reviewSummary { avgRating } } }`

### Why It Happens

Each field is designed by the team that owns it. The inventory team adds `inventory`, the pricing team adds `currentPrice`. Nobody models the full query plan.

### What Goes Wrong

For 50 products in a category:
- 1 call to products-subgraph
- 50 calls to inventory-subgraph (one per product, no batch `@key`)
- 50 calls to pricing-subgraph
- 50 calls to reviews-subgraph

Total: **151 subgraph calls** for one client query. The router becomes a fan-out amplifier.

### The Correct Alternative

1. **Ensure every `@key` entity supports batch `_entities` resolution** — `_entities` is the router's mechanism for batching entity lookups:

```typescript
// inventory-subgraph: resolves multiple products in one call
const resolvers = {
  Product: {
    __resolveReference: async (representations) => {
      // DataLoader batches all product IDs
      const ids = representations.map(r => r.id);
      const inventories = await db.findInventories(ids);
      return inventories;
    },
  },
};
```

2. **Analyze query plans in development** using Apollo Sandbox's query plan inspector before shipping schemas.

3. **Co-locate frequently accessed fields** — if 90% of `Product` queries also request `currentPrice`, consider co-locating pricing in the products-subgraph to eliminate an inter-subgraph hop.

---

## 8. Anonymous Subgraph Ownership

**Severity**: Medium  
**Layer**: Governance

### What It Looks Like

```yaml
# supergraph-config.yaml
subgraphs:
  users:
    routing_url: https://users.internal/graphql
    schema:
      subgraph_url: https://users.internal/graphql
  # No OWNERS file. No team attribution. No Slack channel.
  notifications:
    routing_url: https://notifications.internal/graphql
  legacy-data:
    routing_url: https://legacy.internal/graphql
  # "legacy-data" was written by an engineer who left 18 months ago
```

### Why It Happens

Subgraphs are created by teams, but team membership changes. Engineers leave or move to other teams. The `legacy-data` subgraph was necessary at the time and is still running in production, but nobody claims ownership.

### What Goes Wrong

- Schema changes are blocked: nobody can approve PRs to `legacy-data` because nobody knows who owns it.
- Incidents are not routed: when `legacy-data` returns errors, the on-call engineer has no team to page.
- The subgraph accumulates technical debt: no owner means no one feels responsible for upgrades, security patches, or schema improvements.
- It becomes a **dumping ground**: teams add fields to `legacy-data` because it has no owner to reject them.

### The Correct Alternative

Enforce ownership as a hard requirement for subgraph registration:

```yaml
# subgraph-registry.yaml
subgraphs:
  users:
    routing_url: https://users.internal/graphql
    owner: team-identity
    slack: "#team-identity"
    pagerduty: "identity-oncall"
    codeowners: "@team-identity"
    slo:
      availability: 99.9%
      p99_latency: 200ms
  notifications:
    routing_url: https://notifications.internal/graphql
    owner: team-platform
    slack: "#team-platform"
    pagerduty: "platform-oncall"
```

Block subgraph registration without an `owner` field. Automate CODEOWNERS generation from this registry. Route incident alerts to the owning team's PagerDuty.

---

## 9. Hard-coded Subgraph URLs

**Severity**: High  
**Layer**: Operational

### What It Looks Like

```yaml
# router.yaml — anti-pattern
supergraph:
  listen: 0.0.0.0:4000
  path: /graphql

override_subgraph_url:
  users: http://10.0.1.45:4001/graphql      # hard-coded pod IP
  orders: http://10.0.1.46:4002/graphql     # hard-coded pod IP
  products: http://orders-prod-abc.internal/graphql  # hard-coded hostname
```

### Why It Happens

The initial deployment was done manually. Pod IPs were copied from `kubectl get pods -o wide`. The deployment "works" and is never revisited because changing it requires a router restart.

### What Goes Wrong

- **Pod IP churn**: in Kubernetes, pod IPs change on every restart, rollout, or node failure. Hard-coded pod IPs break immediately on the next deployment.
- **No service discovery**: adding a new subgraph replica requires a router config change and restart.
- **No canary routing**: hard-coded URLs prevent traffic splitting between subgraph versions for canary deployments.
- **Zero-downtime deployments fail**: when the orders service rolls to a new pod, the router continues pointing at the old (now terminated) IP.

### The Correct Alternative

Use Kubernetes **Service DNS names**, not pod IPs:

```yaml
# router.yaml — correct
override_subgraph_url:
  users: http://users-subgraph.graphql-platform.svc.cluster.local:4001/graphql
  orders: http://orders-subgraph.graphql-platform.svc.cluster.local:4002/graphql
  products: http://products-subgraph.graphql-platform.svc.cluster.local:4003/graphql
```

Or use **Apollo GraphOS Managed Federation** to eliminate URL configuration from `router.yaml` entirely — the router fetches the supergraph schema (including subgraph URLs) from GraphOS at startup, enabling zero-config URL management:

```yaml
# router.yaml — managed federation
apollo:
  key: ${APOLLO_KEY}
  graph_ref: my-graph@production
# No override_subgraph_url needed — GraphOS manages this
```

---

## 10. Schema-First Without Contract Tests

**Severity**: High  
**Layer**: Testing

### What It Looks Like

```
Process:
1. Team designs schema in SDL ✓
2. Team reviews SDL in PR ✓
3. Schema is merged to registry ✓
4. Team implements resolvers ✗ (no test that implementation matches schema)
5. 6 weeks later: client queries for User.displayName, resolver returns undefined
```

### Why It Happens

Schema-first development is the correct pattern. Writing SDL before implementation encourages API thinking. But the process stops at "schema merged = done." The implementation step has no automated validation that the resolvers actually satisfy the schema contract.

### What Goes Wrong

- **Schema drift**: the registered schema says `User.displayName: String!` but the resolver returns `null`. Clients discover this at runtime.
- **Missing resolvers**: a new field is added to the schema but the resolver is not implemented. The field silently returns `undefined` (which becomes `null`), causing non-null propagation failures.
- **Type mismatch**: the schema says `Order.total: Float!` but the resolver returns a formatted string `"$42.50"`.

### The Correct Alternative

Implement **schema contract tests** that validate resolver implementations against the schema:

```typescript
// __tests__/contract/user.contract.test.ts
import { buildSubgraphSchema } from '@apollo/subgraph';
import { addMocksToSchema } from '@graphql-tools/mock';
import { execute } from 'graphql';
import { userResolvers } from '../../resolvers/user';
import { userTypeDefs } from '../../schema/user';

describe('User subgraph contract', () => {
  const schema = buildSubgraphSchema([{ typeDefs: userTypeDefs, resolvers: userResolvers }]);

  it('User.displayName resolves to a non-null string', async () => {
    const result = await execute({
      schema,
      document: gql`{ user(id: "1") { displayName } }`,
    });
    expect(result.errors).toBeUndefined();
    expect(typeof result.data?.user?.displayName).toBe('string');
  });

  it('User.orders returns a valid connection', async () => {
    const result = await execute({
      schema,
      document: gql`{ user(id: "1") { orders(first: 5) { edges { node { id } } pageInfo { hasNextPage } } } }`,
    });
    expect(result.errors).toBeUndefined();
    expect(result.data?.user?.orders?.edges).toBeInstanceOf(Array);
  });
});
```

Also use **`rover subgraph introspect`** in CI to validate that the running subgraph's introspection matches the registered schema:

```bash
rover subgraph introspect http://users-subgraph:4001/graphql \
  | rover subgraph check my-graph@production --name users --schema -
```

---

## Summary

| Anti-Pattern | Root Cause | Impact | Fix Complexity |
|---|---|---|---|
| Shared Database | Incomplete decomposition | Domain coupling, shared failure | Very High (DB split required) |
| Cross-Subgraph Calls | Direct path instinct | Auth bypass, observability gap | Medium (entity resolution refactor) |
| Overloaded @key | DB partitioning leak | Coupling, composition fragility | Medium (simplify key) |
| Subgraph Per Microservice | Mechanical rule application | Fan-out explosion | High (consolidate subgraphs) |
| Missing Composition CI | CI not updated | Production composition failures | Low (add rover check) |
| @requires Abuse | Convenience over design | Inter-subgraph coupling | Medium (redesign dependencies) |
| Ignoring Query Plan Cost | Siloed field design | N+1 at federation layer | High (schema + resolver redesign) |
| Anonymous Ownership | Team churn | Governance failure | Low (registry + CODEOWNERS) |
| Hard-coded Subgraph URLs | Manual deployment origins | Broken deployments | Low (use k8s DNS or GraphOS) |
| Schema-First Without Tests | Testing process gap | Schema drift | Medium (add contract tests) |

---

## References

- [Apollo Federation — Entity Resolution](https://www.apollographql.com/docs/federation/entities)
- [Rover CLI — subgraph check](https://www.apollographql.com/docs/rover/subgraphs/#checking-a-subgraph)
- [Apollo Router — Query Planning](https://www.apollographql.com/docs/router/executing-operations/query-plans)
- [Federation Spec — @requires](https://www.apollographql.com/docs/federation/federated-types/federated-directives/#requires)

## Related Topics

- [Federation](../07-federation/README.md)
- [Supergraph Architecture](../08-supergraph-architecture/README.md)
- [Schema Governance](../09-schema-governance/README.md)
- [CI/CD Automation](../11-ci-cd-automation/README.md)
