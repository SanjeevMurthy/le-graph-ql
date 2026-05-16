# Federation v2 Reference Implementation — E-Commerce Supergraph

This example is a complete, production-realistic Apollo Federation v2 supergraph for an e-commerce platform. It is the companion implementation for [Chapter 07: Apollo Federation v2](../../docs/07-federation/README.md) and [Chapter 08: Supergraph Architecture](../../docs/08-supergraph-architecture/README.md).

---

## What This Example Demonstrates

| Concept | Where It Appears |
|---|---|
| Entity ownership with `@key` | `User` in Users subgraph, `Product` in Products subgraph, `Order` in Orders subgraph |
| Cross-subgraph entity references | Orders subgraph references `User` and `Product` without owning them |
| `@external` + `@requires` | Orders subgraph requires `Product.price` to compute `LineItem.unitPrice` |
| `@provides` | Products subgraph provides `price` so the router avoids a round-trip in some query plans |
| `@shareable` | `Money` scalar fields declared shareable across subgraphs |
| Distributed entity resolution | The `_entities` query, `__resolveReference`, and DataLoader batching |
| N+1 prevention | DataLoader in every reference resolver — mandatory for production |
| Cursor pagination | `users(first, after)` following the Relay Connection spec |
| Query plan visualization | `entity-resolution-deep-dive.md` shows the full plan for a complex cross-subgraph query |

---

## Three-Subgraph Architecture

```
Client
  │
  ▼
Apollo Router :4000
  ├── Users Subgraph    :4001   owns User entity
  ├── Products Subgraph :4002   owns Product entity
  └── Orders Subgraph   :4003   owns Order entity
                                references User and Product
```

Each subgraph is an independent Node.js service using `@apollo/subgraph` and `graphql-yoga` (or Apollo Server 4). They connect to separate databases — PostgreSQL for Users and Orders, and either PostgreSQL or Elasticsearch for Products.

---

## Prerequisites

| Requirement | Version |
|---|---|
| Node.js | 20 LTS or later |
| Rover CLI | 0.23.0 or later |
| Apollo Router | 1.40.0 or later |
| `@apollo/subgraph` | 2.7.0 or later |
| Docker (optional) | 24.0 or later |

Install Rover:

```bash
curl -sSL https://rover.apollo.dev/nix/latest | sh
```

---

## Running Locally with `rover dev`

`rover dev` composes the supergraph from running subgraph endpoints in real-time and starts a local router instance. It is the recommended local development workflow.

```bash
# 1. Install dependencies in each subgraph directory
cd users-subgraph && npm install
cd ../products-subgraph && npm install
cd ../orders-subgraph && npm install

# 2. Start all three subgraphs (in separate terminals or with a process manager)
node users-subgraph/src/index.js     # listens on :4001
node products-subgraph/src/index.js  # listens on :4002
node orders-subgraph/src/index.js    # listens on :4003

# 3. Start rover dev — it composes and runs the router
rover dev --config supergraph.yaml

# 4. Open the Apollo Sandbox
open http://localhost:4000/graphql
```

`rover dev` watches for subgraph changes and recomposes the supergraph automatically. Hot reload works without restarting the router.

---

## File Navigation

| File | Purpose |
|---|---|
| `README.md` | This file — overview, architecture, how to run |
| `federation-v2-subgraphs.md` | Complete SDL and TypeScript resolver stubs for all three subgraphs |
| `supergraph-config.md` | `supergraph.yaml`, `router.yaml`, Rover publish/check commands |
| `entity-resolution-deep-dive.md` | `_entities` mechanics, DataLoader batching, query plan trace, error handling |

---

## Key Design Decisions

**Why three subgraphs?** Each maps to a bounded context with a distinct team, database, and deployment cadence. Users owns authentication and identity. Products owns catalog and inventory. Orders owns the transaction lifecycle and references User and Product by key only.

**Why DataLoader in reference resolvers?** Without DataLoader, a query that fetches 50 orders will trigger 50 separate `user` lookups and 50 × N `product` lookups against the database. DataLoader coalesces concurrent calls within a single tick into one batched database query. This is not optional for production — see `entity-resolution-deep-dive.md` for the full implementation.

**Why `@requires` on `LineItem.unitPrice`?** The unit price at order time is snapshotted from `Product.price` during order creation, but the Orders subgraph needs the `price` field from Products to validate it during certain mutations. Using `@requires` tells the router to fetch `price` from Products before calling Orders for that field — explicit dependency in the query plan rather than an implicit service-to-service call.
