# Resolver Patterns

> **Purpose:** This document covers seven resolver-level design patterns for enterprise GraphQL. Resolvers are the implementation layer where schema contracts meet data access. These patterns address the most important resolver concerns: eliminating N+1 queries, managing request-scoped state, ensuring testability, containing failures, and securing pagination cursors. Each pattern includes a complete TypeScript implementation example.

---

## Pattern 1: DataLoader Batch-by-Foreign-Key

### Problem

A query for `orders { customer { name } }` resolves 100 orders, each of which calls `context.db.users.findById(order.customerId)`. This fires 100 individual database queries — one per order. At 1000 requests per second, this produces 100,000 database queries per second against the `users` table. The database connection pool exhausts. Queries queue. Latency spikes.

This is the N+1 problem: 1 query to fetch N orders, then N queries to fetch each customer.

### Solution

Use Facebook's [DataLoader](https://github.com/graphql/dataloader) to batch all foreign-key lookups within a single request tick into a single database query.

```typescript
// dataloaders/UserDataLoader.ts
import DataLoader from 'dataloader';
import type { User } from '../models/User';
import type { DatabaseClient } from '../database';

// The key type is the foreign key — customerId: string
// The value type is the resolved entity — User
export function createUserDataLoader(db: DatabaseClient): DataLoader<string, User | null> {
  return new DataLoader<string, User | null>(
    async (userIds: readonly string[]): Promise<(User | null)[]> => {
      // Single batched database query for all keys
      const users = await db.query<User>(
        `SELECT * FROM users WHERE id = ANY($1::uuid[])`,
        [[...userIds]]
      );

      // Build a lookup map: userId -> User
      const userMap = new Map<string, User>(
        users.map((user) => [user.id, user])
      );

      // CRITICAL: return results in the same order as the input keys.
      // DataLoader requires order-preserving results.
      return userIds.map((id) => userMap.get(id) ?? null);
    },
    {
      // Cache within the request lifetime only.
      // DataLoader's default cache is per-DataLoader-instance.
      // We create a new instance per request, so this is request-scoped.
      cache: true,

      // Maximum batch size — prevents one enormous query
      maxBatchSize: 1000,

      // Optional: batch scheduling delay (default is process.nextTick)
      batchScheduleFn: (callback) => setTimeout(callback, 0),
    }
  );
}
```

Resolver usage — the pattern is identical regardless of how many orders are fetched:

```typescript
// resolvers/Order.ts
import type { OrderResolvers } from '../generated/types';

export const OrderResolvers: OrderResolvers = {
  Order: {
    // This resolver is called N times (once per order).
    // DataLoader batches all N calls into one DB query.
    customer: async (order, _args, context) => {
      return context.dataloaders.user.load(order.customerId);
    },

    // Batch by IDs when the foreign key is a list
    tags: async (order, _args, context) => {
      return context.dataloaders.tag.loadMany(order.tagIds);
    },
  },
};
```

Context factory creates one DataLoader instance per request:

```typescript
// context/factory.ts — see also Pattern 5: Context Factory
export async function createRequestContext(req: Request): Promise<GraphQLContext> {
  const db = await getConnectionFromPool();
  return {
    db,
    dataloaders: {
      // New instance per request — no cross-request cache contamination
      user: createUserDataLoader(db),
      product: createProductDataLoader(db),
      order: createOrderDataLoader(db),
      tag: createTagDataLoader(db),
    },
  };
}
```

DataLoader for a one-to-many relationship (e.g., orders by customer ID):

```typescript
// dataloaders/OrdersByCustomerDataLoader.ts
export function createOrdersByCustomerDataLoader(
  db: DatabaseClient
): DataLoader<string, Order[]> {
  return new DataLoader<string, Order[]>(
    async (customerIds: readonly string[]): Promise<Order[][]> => {
      const orders = await db.query<Order>(
        `SELECT * FROM orders WHERE customer_id = ANY($1::uuid[]) ORDER BY created_at DESC`,
        [[...customerIds]]
      );

      // Group orders by customer_id
      const ordersByCustomer = new Map<string, Order[]>();
      for (const customerId of customerIds) {
        ordersByCustomer.set(customerId, []);
      }
      for (const order of orders) {
        ordersByCustomer.get(order.customerId)!.push(order);
      }

      return customerIds.map((id) => ordersByCustomer.get(id) ?? []);
    }
  );
}
```

### Trade-offs

| Gain | Cost |
|---|---|
| Reduces N+1 to 1+1 automatically | DataLoader must be created per request — requires context factory discipline |
| Request-scoped cache prevents redundant fetches for the same entity | Batching adds a tick of latency (typically <1ms) — not perceptible at scale |
| Works for both foreign key lookups and list relationship lookups | Does not batch queries with different filters or complex WHERE clauses |
| Zero resolver-level changes once DataLoader is in context | Large batches may exceed database parameter limits — requires `maxBatchSize` |

### When to Use

- Every resolver that loads an entity by ID or foreign key
- Any `{ parent { child { grandchild } } }` resolver chain

### When Not to Use

- Root query resolvers that apply complex filters (use direct query with indexes)
- Aggregation resolvers (COUNT, SUM) — batch those with SQL aggregation queries
- Single-entity resolvers that are guaranteed to fetch at most one record

---

## Pattern 2: Resolver Chain Memoization

### Problem

A query requests `order { customer { name } }` and `order { customer { email } }`. Both `name` and `email` are on the `Customer` type. Each is resolved by a separate field resolver that calls `context.dataloaders.customer.load(order.customerId)`. DataLoader deduplicates within a batch, but what about cases where the parent resolver itself is expensive — such as fetching the order from a REST service — and is called multiple times in a query tree?

### Solution

Cache the parent resolver's result within the request using a `Map` keyed by a stable identifier. The memoization is not DataLoader's job — DataLoader handles the batch-by-key pattern. Memoization handles the case where the **resolver function itself** is called redundantly.

```typescript
// utilities/requestMemoize.ts
export function requestMemoize<TKey, TResult>(
  fn: (key: TKey) => Promise<TResult>
): (key: TKey) => Promise<TResult> {
  const cache = new Map<TKey, Promise<TResult>>();

  return (key: TKey): Promise<TResult> => {
    if (cache.has(key)) {
      return cache.get(key)!;
    }
    const result = fn(key);
    cache.set(key, result);
    return result;
  };
}
```

Applied to a resolver that wraps an expensive REST call:

```typescript
// services/ShippingService.ts
import { requestMemoize } from '../utilities/requestMemoize';

export class ShippingService {
  private readonly memoizedFetch: (orderId: string) => Promise<ShippingInfo | null>;

  constructor(private readonly httpClient: HttpClient) {
    // Memoize per-instance — one ShippingService instance per request
    this.memoizedFetch = requestMemoize(async (orderId: string) => {
      const response = await this.httpClient.get(`/shipping/orders/${orderId}`);
      if (response.status === 404) return null;
      return response.json() as ShippingInfo;
    });
  }

  async getShippingInfo(orderId: string): Promise<ShippingInfo | null> {
    return this.memoizedFetch(orderId);
  }
}
```

The memoization is transparent to resolvers:

```typescript
// resolvers/Order.ts
export const OrderResolvers: OrderResolvers = {
  Order: {
    // Called once per field query, but if the same orderId is resolved
    // multiple times in the query tree, ShippingService memoizes the result
    trackingInfo: async (order, _args, context) => {
      return context.services.shipping.getShippingInfo(order.id);
    },
    estimatedDelivery: async (order, _args, context) => {
      // Same underlying fetch as trackingInfo — memoized
      const info = await context.services.shipping.getShippingInfo(order.id);
      return info?.estimatedDelivery ?? null;
    },
  },
};
```

### Trade-offs

| Gain | Cost |
|---|---|
| Eliminates redundant upstream calls for the same entity in one request | Requires the service to be instantiated per request (context factory) |
| Works for REST, gRPC, and any async data source | Memoization is in-process memory — does not work across subgraph fetches |
| Transparent to resolver code | Stale-within-request: if the data changes mid-request, the cache returns the old value |

### When to Use

- Resolvers that call REST or gRPC services where the same entity may be requested from multiple fields in the same query
- Any expensive computation that depends only on stable per-request inputs

### When Not to Use

- Data that changes mid-request (e.g., balance after a mutation in the same request)
- Queries that intentionally refetch the same entity to detect concurrent changes

---

## Pattern 3: Optimistic DataLoader

### Problem

A query resolves `order { lineItems { product { name price } } }`. After fetching the order, the resolver knows the set of `productId` values from `order.lineItems`. The DataLoader for products will eventually batch all product IDs. But if the parent resolver pre-registers those IDs before the child resolvers fire, the DataLoader can prefetch them in parallel with other work, reducing sequential fetch latency.

### Solution

Prime the DataLoader with known keys immediately after loading the parent entity, before the child resolvers execute:

```typescript
// resolvers/Order.ts
export const OrderResolvers: OrderResolvers = {
  Order: {
    lineItems: async (order, args, context) => {
      // After loading line items, we know all productIds.
      // Prime the product DataLoader BEFORE child resolvers run.
      // When product resolvers call .load(productId), the result is already cached.
      const lineItems = await context.dataloaders.lineItem.load(order.id);

      // Optimistic pre-load: prime the product DataLoader with all known productIds
      lineItems.forEach((lineItem) => {
        if (!context.dataloaders.product.cacheMap?.has(lineItem.productId)) {
          context.dataloaders.product.prime(
            lineItem.productId,
            // If we have the product data from a join, prime it directly.
            // If not, just schedule a load so DataLoader batches them together.
            context.dataloaders.product.load(lineItem.productId)
          );
        }
      });

      return lineItems;
    },
  },
};
```

More commonly: optimistic loading via a join query that loads related entities in one shot:

```typescript
// dataloaders/OrderWithLineItemsDataLoader.ts
export function createOrderWithLineItemsDataLoader(
  db: DatabaseClient,
  productDataLoader: DataLoader<string, Product | null>
): DataLoader<string, OrderWithLineItems | null> {
  return new DataLoader<string, OrderWithLineItems | null>(
    async (orderIds: readonly string[]) => {
      // Join query fetches orders AND their line items AND their products in one query
      const rows = await db.query<OrderLineItemProductRow>(
        `SELECT o.*, li.id as line_item_id, li.quantity, li.unit_price,
                p.id as product_id, p.name as product_name, p.sku
         FROM orders o
         JOIN line_items li ON li.order_id = o.id
         JOIN products p ON p.id = li.product_id
         WHERE o.id = ANY($1::uuid[])`,
        [[...orderIds]]
      );

      // Prime the product DataLoader with fetched products — no extra query needed
      const productMap = new Map<string, Product>();
      for (const row of rows) {
        if (!productMap.has(row.product_id)) {
          const product = mapRowToProduct(row);
          productMap.set(row.product_id, product);
          productDataLoader.prime(row.product_id, product);
        }
      }

      return orderIds.map((id) => {
        const orderRows = rows.filter((r) => r.order_id === id);
        if (orderRows.length === 0) return null;
        return mapRowsToOrderWithLineItems(orderRows);
      });
    }
  );
}
```

### Trade-offs

| Gain | Cost |
|---|---|
| Reduces sequential fetch round trips | Requires knowledge of which child entities will be needed |
| Join queries can be faster than separate batched queries | Join queries increase data transfer volume |
| Priming is transparent to child resolvers | Over-fetching if child fields are conditionally selected |

### When to Use

- Deep query patterns like `order { lineItems { product { ... } } }` where the parent knows the child IDs
- Performance-critical paths where latency matters more than simplicity

### When Not to Use

- Shallow query patterns — optimistic loading adds complexity without benefit
- Highly conditional schemas where you cannot predict which child fields will be requested

---

## Pattern 4: Repository Pattern for Resolvers

### Problem

Resolvers call `context.db.query(...)` directly. Test suites must spin up a real database or mock the database client at a low level. When the database schema changes, every resolver that references the table must be updated. Business logic (filters, pagination, sorting) is duplicated across resolvers.

### Solution

Inject a **repository** into the context. The repository encapsulates all data access for a domain entity. Resolvers call repository methods. Tests inject a fake repository.

```typescript
// repositories/OrderRepository.ts
import type { DatabaseClient } from '../database';
import type { Order, OrderFilter, PaginationArgs } from '../models';

export interface IOrderRepository {
  findById(id: string): Promise<Order | null>;
  findByCustomerId(customerId: string): Promise<Order[]>;
  findManyByIds(ids: readonly string[]): Promise<(Order | null)[]>;
  findWithFilters(filter: OrderFilter, pagination: PaginationArgs): Promise<Order[]>;
  countWithFilters(filter: OrderFilter): Promise<number>;
  create(input: CreateOrderInput): Promise<Order>;
  updateStatus(id: string, status: OrderStatus): Promise<Order>;
}

export class PostgresOrderRepository implements IOrderRepository {
  constructor(private readonly db: DatabaseClient) {}

  async findById(id: string): Promise<Order | null> {
    const rows = await this.db.query<Order>(
      'SELECT * FROM orders WHERE id = $1 LIMIT 1',
      [id]
    );
    return rows[0] ?? null;
  }

  async findManyByIds(ids: readonly string[]): Promise<(Order | null)[]> {
    const rows = await this.db.query<Order>(
      'SELECT * FROM orders WHERE id = ANY($1::uuid[])',
      [[...ids]]
    );
    const map = new Map(rows.map((r) => [r.id, r]));
    return ids.map((id) => map.get(id) ?? null);
  }

  async findWithFilters(
    filter: OrderFilter,
    pagination: PaginationArgs
  ): Promise<Order[]> {
    const { whereClause, params } = buildOrderWhereClause(filter);
    const { limitClause, offsetClause } = buildPaginationClauses(pagination);
    return this.db.query<Order>(
      `SELECT * FROM orders ${whereClause} ORDER BY created_at DESC ${limitClause} ${offsetClause}`,
      params
    );
  }

  async create(input: CreateOrderInput): Promise<Order> {
    const [order] = await this.db.query<Order>(
      `INSERT INTO orders (customer_id, status, total_amount, total_currency)
       VALUES ($1, 'PENDING', $2, $3)
       RETURNING *`,
      [input.customerId, input.total.amount, input.total.currency]
    );
    return order;
  }
}

// Fake for testing — no database required
export class InMemoryOrderRepository implements IOrderRepository {
  private orders: Map<string, Order> = new Map();

  async findById(id: string): Promise<Order | null> {
    return this.orders.get(id) ?? null;
  }

  async findManyByIds(ids: readonly string[]): Promise<(Order | null)[]> {
    return ids.map((id) => this.orders.get(id) ?? null);
  }

  // ... other methods
  seed(orders: Order[]): void {
    orders.forEach((o) => this.orders.set(o.id, o));
  }
}
```

Resolver using the repository interface:

```typescript
// resolvers/Query.ts
export const QueryResolvers: QueryResolvers = {
  Query: {
    order: async (_root, { id }, context) => {
      return context.repositories.order.findById(id);
    },
    orders: async (_root, { filter, first, after }, context) => {
      const pagination = decodePagination(first, after);
      const [items, total] = await Promise.all([
        context.repositories.order.findWithFilters(filter, pagination),
        context.repositories.order.countWithFilters(filter),
      ]);
      return buildConnection(items, total, pagination);
    },
  },
};
```

Test using InMemoryOrderRepository:

```typescript
// resolvers/__tests__/Query.order.test.ts
import { createTestContext } from '../testHelpers';
import { InMemoryOrderRepository } from '../../repositories/OrderRepository';

test('order resolver returns null for unknown ID', async () => {
  const repo = new InMemoryOrderRepository();
  const context = createTestContext({ repositories: { order: repo } });

  const result = await QueryResolvers.Query.order!(null, { id: 'unknown' }, context, {} as any);
  expect(result).toBeNull();
});

test('order resolver returns order by ID', async () => {
  const repo = new InMemoryOrderRepository();
  const order = buildTestOrder({ id: 'order-1' });
  repo.seed([order]);

  const context = createTestContext({ repositories: { order: repo } });
  const result = await QueryResolvers.Query.order!(null, { id: 'order-1' }, context, {} as any);

  expect(result).toEqual(order);
});
```

### Trade-offs

| Gain | Cost |
|---|---|
| Resolvers are testable without a database | Repository interface must be maintained alongside the implementation |
| Data access logic is centralized and reusable | Additional abstraction layer — more files, more indirection |
| Schema changes require updating the repository, not every resolver | Teams must resist the temptation to add resolver-specific logic to repositories |

### When to Use

- Any production GraphQL service with more than one developer
- Services with integration test suites

### When Not to Use

- Single-resolver scripts, CLI tools, and prototypes

---

## Pattern 5: Context Factory

### Problem

DataLoaders, database connections, authentication state, logger instances, and service clients are constructed inside resolvers — or worse, as module-level globals. Module-level DataLoaders share their cache across requests. Resolvers that construct their own database connections exhaust the connection pool. Authentication state is re-parsed on every resolver call.

### Solution

Build all per-request state **once** in a context factory function that is called by the server framework per request. Resolvers receive the context object and use it — they never construct infrastructure.

```typescript
// context/factory.ts
import type { Request } from 'express';
import { verifyJwt, type AuthPayload } from '../auth/jwt';
import { getConnectionFromPool } from '../database/pool';
import { createLogger } from '../observability/logger';
import { createUserDataLoader } from '../dataloaders/UserDataLoader';
import { createOrderDataLoader } from '../dataloaders/OrderDataLoader';
import { createProductDataLoader } from '../dataloaders/ProductDataLoader';
import { PostgresOrderRepository } from '../repositories/OrderRepository';
import { PostgresProductRepository } from '../repositories/ProductRepository';
import { ShippingService } from '../services/ShippingService';

export interface GraphQLContext {
  // Authentication
  auth: AuthPayload | null;
  requestId: string;

  // Observability
  logger: Logger;
  tracer: Tracer;

  // Data access
  dataloaders: {
    user: DataLoader<string, User | null>;
    order: DataLoader<string, Order | null>;
    product: DataLoader<string, Product | null>;
  };
  repositories: {
    order: IOrderRepository;
    product: IProductRepository;
  };
  services: {
    shipping: ShippingService;
  };
}

export async function createContext(req: Request): Promise<GraphQLContext> {
  const requestId = req.headers['x-request-id'] as string ?? crypto.randomUUID();
  const logger = createLogger({ requestId });

  // Parse auth once — all resolvers share this result
  let auth: AuthPayload | null = null;
  const authHeader = req.headers.authorization;
  if (authHeader?.startsWith('Bearer ')) {
    try {
      auth = await verifyJwt(authHeader.slice(7));
    } catch (err) {
      logger.warn({ err }, 'JWT verification failed');
    }
  }

  // Acquire one DB connection per request
  const db = await getConnectionFromPool();

  // One DataLoader instance per entity type per request
  const dataloaders = {
    user: createUserDataLoader(db),
    order: createOrderDataLoader(db),
    product: createProductDataLoader(db),
  };

  // Repository instances share the DB connection
  const repositories = {
    order: new PostgresOrderRepository(db),
    product: new PostgresProductRepository(db),
  };

  // Services are instantiated per request (enables per-request memoization)
  const httpClient = createAuthenticatedHttpClient(auth?.token);
  const services = {
    shipping: new ShippingService(httpClient),
  };

  return { auth, requestId, logger, tracer: globalTracer, dataloaders, repositories, services };
}
```

Apollo Server integration:

```typescript
// server.ts
import { ApolloServer } from '@apollo/server';
import { expressMiddleware } from '@apollo/server/express4';
import { createContext } from './context/factory';

const server = new ApolloServer<GraphQLContext>({ typeDefs, resolvers });
await server.start();

app.use(
  '/graphql',
  expressMiddleware(server, {
    context: async ({ req }) => createContext(req),
  })
);
```

### Trade-offs

| Gain | Cost |
|---|---|
| Auth, connections, and services are built once per request | Context factory is a critical path — errors here fail all requests |
| DataLoaders are request-scoped by construction | Adds startup latency per request (connection acquisition, JWT verification) |
| Resolvers are thin and testable | Context object grows large as the service grows |

### When to Use

- Always. There is no alternative to a context factory that does not have worse properties.

---

## Pattern 6: Field-Level Error Isolation

### Problem

A resolver for `order.trackingInfo` makes a call to the shipping service. The shipping service is temporarily unavailable. The resolver throws an unhandled exception. GraphQL catches the exception, sets `trackingInfo` to null, and if `trackingInfo` was declared non-null, propagates null upward, nullifying the entire `order` object. A shipping service outage makes orders unrenderable.

### Solution

Catch errors at the field level. Return `null` on failure and push a structured error to the `errors` array. Declare fields that can independently fail as nullable.

```typescript
// utilities/resolverGuard.ts
import type { GraphQLResolveInfo } from 'graphql';
import type { GraphQLContext } from '../context/factory';

/**
 * Wraps a resolver function with error isolation.
 * On failure: returns null and logs the error.
 * The error is appended to the response errors array by GraphQL's execution engine
 * when the resolver throws — this wrapper makes the throw explicit and logged.
 */
export function withErrorIsolation<TResult, TParent = unknown, TArgs = Record<string, unknown>>(
  fieldName: string,
  resolver: (parent: TParent, args: TArgs, context: GraphQLContext, info: GraphQLResolveInfo) => Promise<TResult | null>
): (parent: TParent, args: TArgs, context: GraphQLContext, info: GraphQLResolveInfo) => Promise<TResult | null> {
  return async (parent, args, context, info) => {
    try {
      return await resolver(parent, args, context, info);
    } catch (err) {
      context.logger.error(
        { err, fieldName, path: info.path },
        `Field resolver error: ${fieldName}`
      );
      // Re-throw so GraphQL adds this to the errors array with the correct path.
      // GraphQL will set this field to null in the response.
      throw err;
    }
  };
}
```

Resolver implementation with explicit error isolation:

```typescript
// resolvers/Order.ts
import { withErrorIsolation } from '../utilities/resolverGuard';
import { GraphQLError } from 'graphql';

export const OrderResolvers: OrderResolvers = {
  Order: {
    // Core fields: should never fail, so no isolation wrapper needed
    id: (order) => toGlobalId('Order', order.id),
    status: (order) => order.status,
    total: (order) => order.total,

    // External service fields: isolated — failure returns null, not a cascade
    trackingInfo: withErrorIsolation('Order.trackingInfo', async (order, _args, context) => {
      return context.services.shipping.getShippingInfo(order.id);
    }),

    // Cross-subgraph fields: isolated
    customer: withErrorIsolation('Order.customer', async (order, _args, context) => {
      return context.dataloaders.user.load(order.customerId);
    }),

    // Computed field with non-trivial logic: isolated
    discountedTotal: withErrorIsolation('Order.discountedTotal', async (order, _args, context) => {
      const promotions = await context.services.promotions.getAppliedPromotions(order.id);
      return calculateDiscountedTotal(order.total, promotions);
    }),
  },
};
```

The resulting response on shipping service failure:

```json
{
  "data": {
    "order": {
      "id": "T3JkZXI6MTIz",
      "status": "SHIPPED",
      "total": { "amount": 4999, "currency": "USD" },
      "trackingInfo": null,
      "customer": { "name": "Alice Chen" }
    }
  },
  "errors": [
    {
      "message": "Shipping service unavailable",
      "path": ["order", "trackingInfo"],
      "extensions": {
        "code": "SERVICE_UNAVAILABLE",
        "requestId": "req_abc123"
      }
    }
  ]
}
```

### Trade-offs

| Gain | Cost |
|---|---|
| Partial data responses are genuinely useful | Clients must be coded to handle null fields alongside error entries |
| Shipping service outage does not prevent order rendering | Errors array must be monitored — it's not an HTTP 5xx |
| Error path is precise: `["order", "trackingInfo"]` | Requires fields to be nullable (see Nullable by Default pattern) |

### When to Use

- Fields that depend on external services, subgraph fetches, or complex computations
- Any field that can fail without making the parent object meaningless

---

## Pattern 7: Cursor Encryption

### Problem

A cursor in a paginated list encodes `{ offset: 42, sortKey: "createdAt" }` or `{ id: 12345 }` in plain Base64. Clients decode the cursor, discover the database row ID, increment it to fetch adjacent rows outside the pagination API, or infer the total number of records in the database. Row IDs in cursors are an information disclosure vulnerability.

### Solution

Encrypt cursors with a server-side secret. The cursor is opaque to clients. Clients cannot decode or forge cursors.

```typescript
// utilities/cursor.ts
import { createCipheriv, createDecipheriv, randomBytes } from 'crypto';

const CURSOR_SECRET = process.env.CURSOR_ENCRYPTION_KEY!; // 32-byte hex key
const ALGORITHM = 'aes-256-gcm';

interface CursorPayload {
  offset: number;
  sortField: string;
  sortValue: string | number;
  sortDirection: 'ASC' | 'DESC';
}

export function encodeCursor(payload: CursorPayload): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv(
    ALGORITHM,
    Buffer.from(CURSOR_SECRET, 'hex'),
    iv
  );

  const plaintext = JSON.stringify(payload);
  const encrypted = Buffer.concat([
    cipher.update(plaintext, 'utf8'),
    cipher.final(),
  ]);
  const authTag = cipher.getAuthTag();

  // Combine iv + authTag + ciphertext, base64url encode
  const combined = Buffer.concat([iv, authTag, encrypted]);
  return combined.toString('base64url');
}

export function decodeCursor(cursor: string): CursorPayload {
  try {
    const combined = Buffer.from(cursor, 'base64url');
    const iv = combined.slice(0, 12);
    const authTag = combined.slice(12, 28);
    const ciphertext = combined.slice(28);

    const decipher = createDecipheriv(
      ALGORITHM,
      Buffer.from(CURSOR_SECRET, 'hex'),
      iv
    );
    decipher.setAuthTag(authTag);

    const plaintext = decipher.update(ciphertext) + decipher.final('utf8');
    return JSON.parse(plaintext) as CursorPayload;
  } catch {
    throw new GraphQLError('Invalid cursor', {
      extensions: { code: 'BAD_USER_INPUT' },
    });
  }
}
```

Integration in a connection resolver:

```typescript
// resolvers/Query.products.ts
export const productsConnectionResolver = async (
  _root: unknown,
  args: { first?: number; after?: string; filter?: ProductFilter },
  context: GraphQLContext
) => {
  const limit = Math.min(args.first ?? 20, 100);
  let offset = 0;

  if (args.after) {
    const payload = decodeCursor(args.after);
    offset = payload.offset + 1; // next page starts after the last item
  }

  const items = await context.repositories.product.findWithFilters(
    args.filter ?? {},
    { limit: limit + 1, offset } // fetch one extra to determine hasNextPage
  );

  const hasNextPage = items.length > limit;
  const pageItems = hasNextPage ? items.slice(0, limit) : items;

  return {
    edges: pageItems.map((item, index) => ({
      node: item,
      cursor: encodeCursor({
        offset: offset + index,
        sortField: 'createdAt',
        sortValue: item.createdAt.toISOString(),
        sortDirection: 'DESC',
      }),
    })),
    pageInfo: {
      hasNextPage,
      hasPreviousPage: offset > 0,
      startCursor: pageItems.length > 0 ? encodeCursor({ offset, sortField: 'createdAt', sortValue: pageItems[0].createdAt.toISOString(), sortDirection: 'DESC' }) : null,
      endCursor: pageItems.length > 0 ? encodeCursor({ offset: offset + pageItems.length - 1, sortField: 'createdAt', sortValue: pageItems[pageItems.length - 1].createdAt.toISOString(), sortDirection: 'DESC' }) : null,
    },
    totalCount: await context.repositories.product.count(args.filter ?? {}),
  };
};
```

### Trade-offs

| Gain | Cost |
|---|---|
| Cursors are fully opaque — clients cannot decode or forge them | Encryption adds ~0.1ms per cursor encode/decode |
| Prevents database row ID exposure via cursor inspection | Encrypted cursors are longer than plain Base64 (~50% longer) |
| Forged cursors fail with `BAD_USER_INPUT` rather than returning data | Requires secure key management and rotation strategy |
| Key rotation invalidates existing cursors — clients must re-fetch first page | |

### When to Use

- Any public API with cursor-based pagination
- Any API where database row IDs would constitute an information disclosure if exposed

### When Not to Use

- Internal admin tools where cursor forgery is not a threat model
- Prototypes where developer visibility into cursor contents is useful for debugging
