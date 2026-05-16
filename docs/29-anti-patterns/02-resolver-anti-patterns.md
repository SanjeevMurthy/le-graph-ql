# Resolver Anti-Patterns

> Resolvers are the runtime implementation of a GraphQL schema. Schema anti-patterns are visible in SDL and can be caught in code review. Resolver anti-patterns are often invisible until load hits — and by then the damage is done. This document covers the ten most common resolver-level mistakes.

---

## Table of Contents

1. [N+1 Without DataLoader](#1-n1-without-dataloader)
2. [Database Logic in Resolvers](#2-database-logic-in-resolvers)
3. [Throwing for Expected Errors](#3-throwing-for-expected-errors)
4. [Fat Context Object](#4-fat-context-object)
5. [DataLoader Outside Context](#5-dataloader-outside-context)
6. [Synchronous Resolvers Blocking Event Loop](#6-synchronous-resolvers-blocking-event-loop)
7. [Ignoring Resolver Timeout](#7-ignoring-resolver-timeout)
8. [Inconsistent Null Handling](#8-inconsistent-null-handling)
9. [Circular DataLoader Dependencies](#9-circular-dataloader-dependencies)
10. [Over-fetching in Resolvers](#10-over-fetching-in-resolvers)

---

## 1. N+1 Without DataLoader

**Severity**: Critical  
**Layer**: Performance

### What It Looks Like

```typescript
// Schema:
// type Order { id: ID!, customer: User! }
// type Query { orders: [Order!]! }

const resolvers = {
  Query: {
    orders: () => db.query('SELECT * FROM orders LIMIT 100'),
  },
  Order: {
    // Anti-pattern: one DB call per order
    customer: (order) => db.query(
      'SELECT * FROM users WHERE id = $1',
      [order.customerId]
    ),
  },
};
```

### Why It Happens

The resolver model encourages thinking about each field in isolation. `Order.customer` resolves "the customer for this order" — which naturally leads to a single lookup. The N+1 problem only becomes apparent when you realize this resolver runs once per order in the list.

### What Goes Wrong

100 orders → 101 database queries: 1 for the order list, 100 for customer lookups. At 1,000 concurrent users with a query like this, the database receives 100,000 queries per second from a single GraphQL operation. Latency spikes, connection pool exhausts, and the database falls over.

**Query log evidence:**
```sql
SELECT * FROM orders LIMIT 100;           -- 1 query
SELECT * FROM users WHERE id = 'u-001';   -- repeated 100 times
SELECT * FROM users WHERE id = 'u-002';
-- ... 98 more identical queries
```

### The Correct Alternative

Use **DataLoader** — a batching and caching utility that collects individual keys across a tick of the event loop and issues a single batched query:

```typescript
import DataLoader from 'dataloader';

// In context factory (created once per request):
function createContext() {
  return {
    loaders: {
      user: new DataLoader(async (userIds: readonly string[]) => {
        const users = await db.query(
          'SELECT * FROM users WHERE id = ANY($1)',
          [userIds]
        );
        // Return results in the same order as input keys
        const userMap = new Map(users.map(u => [u.id, u]));
        return userIds.map(id => userMap.get(id) ?? null);
      }),
    },
  };
}

const resolvers = {
  Order: {
    // DataLoader batches all customer IDs within one tick
    customer: (order, _args, context) =>
      context.loaders.user.load(order.customerId),
  },
};
```

**Result**: 100 orders → 2 database queries: 1 for orders, 1 batched query for all customer IDs. Scales linearly regardless of list size.

---

## 2. Database Logic in Resolvers

**Severity**: High  
**Layer**: Architecture

### What It Looks Like

```typescript
const resolvers = {
  Query: {
    orders: async (_parent, { filter }, context) => {
      // Raw SQL in resolver
      let query = 'SELECT o.*, u.email as customer_email FROM orders o';
      query += ' JOIN users u ON o.customer_id = u.id';
      if (filter?.status) {
        query += ` WHERE o.status = '${filter.status}'`; // SQL injection risk
      }
      if (filter?.startDate) {
        query += ` AND o.created_at >= '${filter.startDate}'`;
      }
      query += ' ORDER BY o.created_at DESC LIMIT 50';
      return db.raw(query);
    },
  },
};
```

### Why It Happens

It is the fastest path to a working resolver. In early development, the separation between "API layer" and "data layer" feels like premature abstraction. The query is written once, it works, and it ships.

### What Goes Wrong

- **SQL injection** from string interpolation (demonstrated above).
- **Untestable**: unit testing this resolver requires a database connection. No mocks possible.
- **No reuse**: the same join pattern is copy-pasted into 5 other resolvers when other query types need orders.
- **Tight coupling**: switching from PostgreSQL to a different database requires rewriting resolvers.
- **Authorization bypass**: business logic like "only return orders for the current user" lives in SQL strings, not in auditable authorization layers.

### The Correct Alternative

Extract a **repository or service layer** between resolvers and the database:

```typescript
// repository/OrderRepository.ts
class OrderRepository {
  async findByFilter(filter: OrderFilter, userId: string): Promise<Order[]> {
    return db
      .select('orders.*')
      .from('orders')
      .join('users', 'orders.customer_id', 'users.id')
      .where('orders.customer_id', userId)           // authorization enforced here
      .modify((qb) => {
        if (filter.status) qb.where('status', filter.status);
        if (filter.startDate) qb.where('created_at', '>=', filter.startDate);
      })
      .orderBy('created_at', 'desc')
      .limit(50);
  }
}

// resolver
const resolvers = {
  Query: {
    orders: (_parent, { filter }, context) =>
      context.repositories.order.findByFilter(filter, context.user.id),
  },
};
```

Resolvers become thin translation layers. Business logic, SQL, and authorization live in testable, composable repository methods.

---

## 3. Throwing for Expected Errors

**Severity**: High  
**Layer**: Error Handling

### What It Looks Like

```typescript
const resolvers = {
  Mutation: {
    createOrder: async (_parent, { input }, context) => {
      const product = await context.repositories.product.findById(input.productId);
      if (!product) {
        throw new Error('Product not found');  // anti-pattern for expected error
      }
      if (product.stock < input.quantity) {
        throw new Error('Insufficient stock');  // anti-pattern
      }
      return context.repositories.order.create(input, context.user.id);
    },
  },
};
```

### Why It Happens

`throw` is idiomatic in many programming languages for signaling failure. The resolver error handling middleware converts thrown errors to GraphQL errors, so it "works." Teams accustomed to REST's HTTP status codes treat 404 (not found) and 422 (unprocessable) as exceptional states to be signaled through the error channel.

### What Goes Wrong

In GraphQL, thrown errors populate the `errors` array and set `data` to `null` for that field. For expected business errors:

- **Partial data is lost**: if a query fetches 5 fields and one throws, the client may receive `null` for all fields depending on nullability.
- **Error messages are opaque**: `"Product not found"` is a string — clients cannot branch on it reliably without string parsing.
- **Error types are invisible in the schema**: the possible failure modes of `createOrder` are not documented anywhere in the schema.
- **Monitoring noise**: expected errors (stock depletion) appear in error rate dashboards alongside unexpected errors (database connection failures), causing alert fatigue.

### The Correct Alternative

Return **error union types** for expected, domain-level errors. Reserve `throw` for unexpected, infrastructure-level failures:

```typescript
// Schema:
// union CreateOrderResult = Order | ProductNotFound | InsufficientStock | InvalidInput

const resolvers = {
  Mutation: {
    createOrder: async (_parent, { input }, context) => {
      const product = await context.repositories.product.findById(input.productId);
      if (!product) {
        return { __typename: 'ProductNotFound', productId: input.productId };
      }
      if (product.stock < input.quantity) {
        return {
          __typename: 'InsufficientStock',
          available: product.stock,
          requested: input.quantity,
        };
      }
      // Only throw for unexpected infrastructure failures
      const order = await context.repositories.order.create(input, context.user.id);
      return { __typename: 'Order', ...order };
    },
  },
};
```

Infrastructure errors (DB connection lost, network timeout) should still throw — they are not part of the business domain and belong in the `errors` transport layer with appropriate HTTP 500 behavior.

---

## 4. Fat Context Object

**Severity**: High  
**Layer**: Correctness / Serverless

### What It Looks Like

```typescript
// context.ts — anti-pattern: everything in context
const context = {
  user: currentUser,
  db: dbConnection,           // connection re-used across requests
  redis: redisClient,
  config: appConfig,
  userPreferences: {},        // mutable state per-request — dangerous
  requestId: generateId(),
  resolvedEntities: {},       // cache of resolved entities — shared across requests?
  abFlags: await getABFlags(userId), // async data fetched eagerly for every request
};
```

### Why It Happens

Context is a convenient catch-all for "stuff resolvers need." It starts with `user` and `db`, then engineers add `redis`, then `config`, then per-request mutable state for caching, then AB flags. The object grows unchecked.

### What Goes Wrong

**In serverless environments (Lambda, Cloud Run, Vercel)**:
- Handler functions are reused across invocations. If `context` is assigned to a module-level variable (a common mistake), mutable state from request A leaks into request B.
- `resolvedEntities: {}` populated during request A is still populated at the start of request B.

**In all environments**:
- Eagerly fetching `abFlags` on every request adds latency even for queries that do not use AB flags.
- Passing raw `db` connections through context makes it easy to bypass the repository layer and write inline SQL in resolvers.
- Large context objects consume significant heap per request — at high concurrency this adds up.

### The Correct Alternative

Keep context **minimal and factory-scoped**:

```typescript
// context.ts — minimal, factory pattern
function createContext(req: Request): Context {
  return {
    user: req.user,             // from auth middleware, already validated
    requestId: req.id,
    loaders: createDataLoaders(),  // DataLoader instances, request-scoped
    // Expose service layer, not raw DB:
    services: {
      order: new OrderService(db),
      user: new UserService(db),
    },
  };
}

// For lazy data like AB flags:
type Context = {
  user: AuthenticatedUser;
  requestId: string;
  loaders: DataLoaders;
  services: Services;
  // Lazy: only computed when first accessed
  getAbFlags: () => Promise<ABFlags>;
};
```

DataLoaders must always be created fresh per request — they are the one stateful piece that is intentionally request-scoped.

---

## 5. DataLoader Outside Context

**Severity**: Critical  
**Layer**: Performance

### What It Looks Like

```typescript
import DataLoader from 'dataloader';

const resolvers = {
  Order: {
    customer: (order) => {
      // Anti-pattern: new DataLoader created per-resolver invocation
      const userLoader = new DataLoader(async (ids) => {
        const users = await db.query('SELECT * FROM users WHERE id = ANY($1)', [ids]);
        return ids.map(id => users.find(u => u.id === id));
      });
      return userLoader.load(order.customerId);
    },
  },
};
```

### Why It Happens

DataLoader documentation shows creation and use together. Engineers copy the example without understanding that DataLoader's batching mechanism depends on a shared instance accumulating keys across multiple resolver invocations within the same tick.

### What Goes Wrong

When `new DataLoader(...)` is called inside the resolver, a new DataLoader instance is created for every single `Order` resolved. Each instance sees only one key (the one immediately loaded), so no batching ever occurs. The result is exactly the N+1 problem — DataLoader syntax with none of the batching benefit.

100 orders → 101 database queries, despite using DataLoader.

### The Correct Alternative

Create DataLoader instances in the **request context factory** (once per request):

```typescript
// context.ts
function createDataLoaders() {
  return {
    user: new DataLoader<string, User | null>(async (ids) => {
      const users = await db.query(
        'SELECT * FROM users WHERE id = ANY($1)',
        [[...ids]]
      );
      const map = new Map(users.map(u => [u.id, u]));
      return ids.map(id => map.get(id) ?? null);
    }),

    product: new DataLoader<string, Product | null>(async (ids) => {
      const products = await db.query(
        'SELECT * FROM products WHERE id = ANY($1)',
        [[...ids]]
      );
      const map = new Map(products.map(p => [p.id, p]));
      return ids.map(id => map.get(id) ?? null);
    }),
  };
}

// Resolver uses the shared, request-scoped loader:
const resolvers = {
  Order: {
    customer: (order, _args, context) =>
      context.loaders.user.load(order.customerId),
  },
};
```

The DataLoader accumulates all `order.customerId` values from all 100 `Order.customer` resolver invocations within one tick, then issues a single batched query.

---

## 6. Synchronous Resolvers Blocking Event Loop

**Severity**: High  
**Layer**: Performance / Concurrency

### What It Looks Like

```typescript
const resolvers = {
  Query: {
    analyzeReport: (_parent, { reportId }) => {
      const report = fs.readFileSync(`/data/reports/${reportId}.json`); // blocking I/O
      const data = JSON.parse(report.toString());

      // CPU-heavy synchronous computation
      let result = 0;
      for (let i = 0; i < data.rows.length; i++) {
        result += computeComplexMetric(data.rows[i]); // 200ms of CPU per call
      }
      return { score: result };
    },
  },
};
```

### Why It Happens

Node.js resolvers are written as if they are isolated threads. Engineers accustomed to multi-threaded runtimes (Java, Go) do not realize that synchronous CPU work in a Node.js resolver blocks all other concurrent requests.

### What Goes Wrong

Node.js has a single-threaded event loop. A resolver that takes 200ms of CPU time blocks all other GraphQL operations for those 200ms. At 50 concurrent users, 10 such operations queue up → first-in users wait 2 seconds. The server appears hung.

`fs.readFileSync` has an additional problem: it blocks the event loop during disk I/O, preventing even network I/O from being processed.

### The Correct Alternative

```typescript
import { Worker } from 'worker_threads';
import { promisify } from 'util';
import fs from 'fs/promises';  // async I/O

const resolvers = {
  Query: {
    analyzeReport: async (_parent, { reportId }) => {
      // Async I/O — does not block event loop
      const raw = await fs.readFile(`/data/reports/${reportId}.json`, 'utf8');
      const data = JSON.parse(raw);

      // Offload CPU work to a worker thread
      const score = await runInWorkerThread(computeComplexMetric, data.rows);
      return { score };
    },
  },
};
```

For CPU-intensive work: use `worker_threads`, `piscina` (worker thread pool), or offload to a dedicated compute service. For blocking I/O: always use async variants (`fs.promises`, async database drivers).

---

## 7. Ignoring Resolver Timeout

**Severity**: High  
**Layer**: Reliability

### What It Looks Like

```typescript
const resolvers = {
  Query: {
    weatherForecast: async (_parent, { location }) => {
      // No timeout — waits indefinitely
      const response = await fetch(`https://api.weather.example.com/forecast?loc=${location}`);
      return response.json();
    },
  },
};
```

### Why It Happens

In development, the external API always responds quickly. Adding a timeout feels like defensive programming for a problem that has never been observed. It adds code complexity for seemingly no benefit.

### What Goes Wrong

When the external weather API experiences a 30-second timeout, every `weatherForecast` resolver waits 30 seconds before failing. The GraphQL server holds a connection open for each waiting request. At 100 concurrent users querying weather, the server is holding 100 open connections, exhausting the connection pool for all other operations. The entire GraphQL server becomes unresponsive due to one slow dependency.

This is the **cascading dependency failure** pattern — one slow downstream drags down the entire graph.

### The Correct Alternative

Apply timeouts at every external call boundary:

```typescript
import AbortController from 'abort-controller';

const resolvers = {
  Query: {
    weatherForecast: async (_parent, { location }, context) => {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 2000); // 2s timeout

      try {
        const response = await fetch(
          `https://api.weather.example.com/forecast?loc=${location}`,
          { signal: controller.signal }
        );
        return response.json();
      } catch (error) {
        if (error.name === 'AbortError') {
          context.logger.warn('Weather API timeout', { location });
          return null; // graceful degradation — field is nullable
        }
        throw error;
      } finally {
        clearTimeout(timeout);
      }
    },
  },
};
```

Set timeout budgets as part of SLO definitions. Use circuit breakers (e.g., `opossum`) for dependencies that fail repeatedly. Design fields that call external APIs as **nullable** so a timeout results in a partial response rather than a complete failure.

---

## 8. Inconsistent Null Handling

**Severity**: Medium  
**Layer**: API Contract

### What It Looks Like

```typescript
const resolvers = {
  User: {
    // Returns null when no profile
    profile: (user) => db.findProfile(user.id) ?? null,
    // Returns empty array when no orders
    orders: (user) => db.findOrders(user.id) ?? [],
    // Throws when no address
    address: (user) => {
      const addr = db.findAddress(user.id);
      if (!addr) throw new Error('Address not found');
      return addr;
    },
    // Returns a sentinel object when no settings
    settings: (user) => db.findSettings(user.id) ?? { theme: 'default', notifications: true },
  },
};
```

### Why It Happens

Multiple engineers write different resolvers over time. No shared convention is established for the "no data" case. Each engineer applies their own intuition: null, empty array, throw, or default value.

### What Goes Wrong

- Clients cannot predict the behavior of absent data. Is `profile: null` "no profile" or "error"? Is `orders: []` "no orders" or "orders not loaded"?
- Type checking fails: `orders` is typed `[Order!]!` but returns `[]`, while `address` is typed `Address` but throws — the schema and implementation are misaligned.
- Alert fatigue: `address` throws for every user without an address, creating error noise that obscures real errors.

### The Correct Alternative

Establish and enforce a **null handling convention** in resolver guidelines:

```typescript
// Convention:
// - Nullable schema field + no data → return null (never throw)
// - Non-nullable list field + no data → return []
// - Non-nullable scalar field + no data → this is a data integrity bug; throw
// - Optional related entity + not found → return null (not an error)

const resolvers = {
  User: {
    profile: (user) => db.findProfile(user.id),       // null if not found — schema: Profile
    orders: (user) => db.findOrders(user.id),          // [] if none — schema: [Order!]!
    address: (user) => db.findAddress(user.id),        // null if none — schema: Address
    settings: (user) => db.findSettings(user.id),      // null if none — schema: UserSettings
  },
};
```

Document the convention. Enforce it in resolver code reviews. Use TypeScript to make the return types explicit.

---

## 9. Circular DataLoader Dependencies

**Severity**: High  
**Layer**: Correctness

### What It Looks Like

```typescript
// Users loader resolves user entities
const userLoader = new DataLoader(async (ids) => {
  const users = await db.findUsers(ids);
  // For each user, load their primary org (triggers orgLoader)
  return Promise.all(users.map(async (user) => ({
    ...user,
    primaryOrg: await orgLoader.load(user.primaryOrgId), // loads org
  })));
});

// Orgs loader resolves org entities
const orgLoader = new DataLoader(async (ids) => {
  const orgs = await db.findOrgs(ids);
  // For each org, load the owner (triggers userLoader!)
  return Promise.all(orgs.map(async (org) => ({
    ...org,
    owner: await userLoader.load(org.ownerId), // back to userLoader
  })));
});
```

### Why It Happens

Convenience: eagerly resolving related entities inside a DataLoader batch function avoids writing separate resolvers for `User.primaryOrg` and `Org.owner`. The circular dependency is not obvious when each loader is written in isolation.

### What Goes Wrong

`userLoader` calls `orgLoader`, which calls `userLoader`. DataLoader detects that the batch is not being resolved (because the batch function itself is waiting for another batch) and throws:

```
DataLoaderBatchLoadFnError: DataLoader must be constructed with a function which accepts Array<key> and returns Promise<Array<value>>, but the function did not return a Promise of an Array of the same length as the Array of keys.
```

In some cases, it manifests as a hang with no error — the event loop advances but neither batch ever resolves.

### The Correct Alternative

DataLoader batch functions should **only load the raw entities** for the given IDs. Related entity resolution belongs in field resolvers:

```typescript
// userLoader: only loads User rows
const userLoader = new DataLoader(async (ids) => {
  const users = await db.findUsers(ids);
  const map = new Map(users.map(u => [u.id, u]));
  return ids.map(id => map.get(id) ?? null);
});

// orgLoader: only loads Org rows
const orgLoader = new DataLoader(async (ids) => {
  const orgs = await db.findOrgs(ids);
  const map = new Map(orgs.map(o => [o.id, o]));
  return ids.map(id => map.get(id) ?? null);
});

// Resolvers handle cross-entity traversal:
const resolvers = {
  User: {
    primaryOrg: (user, _args, context) =>
      context.loaders.org.load(user.primaryOrgId),
  },
  Org: {
    owner: (org, _args, context) =>
      context.loaders.user.load(org.ownerId),
  },
};
```

Each DataLoader is a flat entity loader. The graph traversal is expressed in resolver field definitions, where GraphQL manages the traversal order.

---

## 10. Over-fetching in Resolvers

**Severity**: Medium  
**Layer**: Performance

### What It Looks Like

```typescript
const resolvers = {
  Query: {
    users: () => db.query('SELECT * FROM users'),  // fetches all 47 columns
  },
  User: {
    // Even though client only requests { id, email }, we fetched everything
    orders: (user) => db.query('SELECT * FROM orders WHERE customer_id = $1', [user.id]),
  },
};
```

Client query:
```graphql
query { users { id email } }  # only wants 2 fields
```

### Why It Happens

`SELECT *` is the default pattern. The resolver knows the return type is `User` with 47 fields, so it fetches all 47. The resolver does not know what subset of fields the client actually requested.

### What Goes Wrong

- **Wasted I/O and memory**: fetching `bio`, `preferences`, `internalMetadata`, and 44 other columns when the client only needs `id` and `email`.
- **Serialization overhead**: large rows serialize to large JavaScript objects, consuming GC pressure.
- **At scale**: with 100 concurrent queries each returning 1,000 users × 47 columns, this is significant unnecessary work on the database and network.

### The Correct Alternative

Use **query projection** by extracting requested fields from resolver `info`:

```typescript
import { graphqlFields } from 'graphql-fields';

const resolvers = {
  Query: {
    users: (_parent, _args, _context, info) => {
      // Extract only the fields the client requested
      const requestedFields = Object.keys(graphqlFields(info));
      // Validate against column whitelist for SQL safety
      const safeFields = requestedFields
        .filter(f => ALLOWED_USER_COLUMNS.has(f))
        .join(', ') || 'id';

      return db.query(`SELECT ${safeFields} FROM users`);
    },
  },
};
```

For complex cases, use a **query builder** (Knex, Prisma select) and pass field projections through the service layer. For federation, the router handles field selection at the subgraph query level — subgraph resolvers receive only the fields requested in the subgraph query.

---

## Summary

| Anti-Pattern | Root Cause | Failure Mode | Fix Effort |
|---|---|---|---|
| N+1 Without DataLoader | Isolated resolver thinking | Database overload | Medium (add DataLoader to context) |
| Database Logic in Resolvers | Fast path in development | Untestable, SQL injection | High (extract repository layer) |
| Throwing for Expected Errors | REST error model carryover | Partial data loss | Medium (error union types) |
| Fat Context Object | Convenience accumulation | State leakage in serverless | Medium (minimize + factory) |
| DataLoader Outside Context | Misunderstood DataLoader | N+1 despite DataLoader | Low (move to context) |
| Synchronous Event Loop Block | Multi-thread mental model | Server freeze | Medium (async + worker threads) |
| Ignoring Resolver Timeout | "Works in development" | Cascading failure | Low (add AbortController) |
| Inconsistent Null Handling | No team convention | Unpredictable clients | Low (establish + document convention) |
| Circular DataLoader Deps | Convenience in batch fn | Deadlock / hang | Medium (separate loaders from traversal) |
| Over-fetching in Resolvers | SELECT * default | Wasted I/O at scale | Medium (projection via info) |

---

## References

- [DataLoader — Batching and Caching](https://github.com/graphql/dataloader)
- [graphql-fields — Extract requested fields from info](https://github.com/robrichard/graphql-fields)
- [Node.js Worker Threads](https://nodejs.org/api/worker_threads.html)
- [opossum — Circuit Breaker for Node.js](https://github.com/nodeshift/opossum)

## Related Topics

- [Resolvers & Execution](../04-resolvers-and-execution/README.md)
- [Performance and Scaling](../06-performance-and-scaling/README.md)
- [Caching Strategies](../17-caching-strategies/README.md)
- [Schema Anti-patterns](./01-schema-anti-patterns.md)
