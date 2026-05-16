# Resolver Best Practices

> **Purpose:** Twenty-plus resolver implementation rules for production GraphQL APIs. Each rule addresses a specific failure mode observed at scale: N+1 query explosions, DataLoader misuse, business logic leakage into resolvers, missing timeouts, and unsafe error propagation. TypeScript code snippets illustrate correct patterns throughout.

---

## BP-R-01: Always Use DataLoader for Any Fetch by ID or Foreign Key

**Rule:** Every resolver that fetches a record by ID or navigates a foreign key relationship must use a DataLoader. No exceptions. A resolver that calls `userService.getById(id)` without DataLoader inside a list query is a confirmed N+1.

**Rationale:** When a list query returns 100 orders and each order resolver fetches its `customer`, without DataLoader this produces 100 independent database queries. DataLoader batches all 100 customer ID lookups into a single `SELECT * FROM users WHERE id = ANY($1)` query, regardless of how many list items are in the response. This is the single most impactful optimization available to GraphQL resolvers.

**Counter-example:**

```typescript
// BAD: Direct service call inside a list-returned resolver — guaranteed N+1
const resolvers = {
  Order: {
    customer: async (order, _args, context) => {
      // For each order in a list, this fires a separate database query
      return context.userService.getUserById(order.customerId);
    },
  },
};
```

**Correct:**

```typescript
// GOOD: DataLoader batches all customer fetches into a single query
const resolvers = {
  Order: {
    customer: async (order, _args, context) => {
      return context.loaders.userById.load(order.customerId);
    },
  },
};
```

Loader implementation (in context factory):

```typescript
import DataLoader from 'dataloader';
import type { User } from './types';

export function createUserByIdLoader(db: Database): DataLoader<string, User | null> {
  return new DataLoader<string, User | null>(
    async (ids: readonly string[]) => {
      const users = await db.query<User>(
        'SELECT * FROM users WHERE id = ANY($1)',
        [ids]
      );
      const userMap = new Map(users.map(u => [u.id, u]));
      // DataLoader requires results in the same order as the input keys
      return ids.map(id => userMap.get(id) ?? null);
    },
    { cache: true } // Per-request cache; cleared between requests
  );
}
```

---

## BP-R-02: Build DataLoaders in the Context Factory — Never Inside a Resolver

**Rule:** All DataLoaders must be instantiated once per request in the context factory function. Never instantiate a DataLoader inside a resolver function body.

**Rationale:** DataLoader batching works by collecting all `load()` calls that occur within the same event loop tick and batching them together. A DataLoader instantiated inside a resolver is a new instance for every resolver invocation — each instance has only one item to batch. The batching mechanism is completely defeated.

**Counter-example:**

```typescript
// BAD: DataLoader created inside the resolver — batching is completely broken
const resolvers = {
  Order: {
    customer: async (order, _args, context) => {
      // New DataLoader instance per resolver call = no batching
      const loader = new DataLoader(async (ids) =>
        context.db.query('SELECT * FROM users WHERE id = ANY($1)', [ids])
      );
      return loader.load(order.customerId);
    },
  },
};
```

**Correct:**

```typescript
// GOOD: Context factory builds all loaders once per request
import { createUserByIdLoader } from './loaders/userLoader';
import { createProductByIdLoader } from './loaders/productLoader';
import { createOrdersByCustomerIdLoader } from './loaders/ordersLoader';

export async function buildContext({ req }: { req: Request }): Promise<GraphQLContext> {
  const user = await validateJwt(req.headers.authorization);
  const db = await pool.connect();

  return {
    user,
    db,
    loaders: {
      userById: createUserByIdLoader(db),
      productById: createProductByIdLoader(db),
      ordersByCustomerId: createOrdersByCustomerIdLoader(db),
    },
  };
}
```

ApolloServer context registration:

```typescript
const server = new ApolloServer({ typeDefs, resolvers });

const { url } = await startStandaloneServer(server, {
  context: buildContext,
});
```

---

## BP-R-03: Delegate Business Logic to a Service Layer

**Rule:** Resolvers are thin coordinators. They extract arguments, call a service method, and return the result. All business logic — validation, state transitions, side effects, external service calls — lives in a service class or domain function. Resolvers contain no business logic.

**Rationale:** Business logic in resolvers is untestable without a GraphQL execution context, unreusable across resolvers, and invisible to domain engineers who do not know GraphQL. A service layer is independently testable with unit and integration tests, reusable from REST endpoints, CLI tools, or background jobs, and owned by domain engineers without GraphQL knowledge.

**Counter-example:**

```typescript
// BAD: Business logic embedded in the resolver
const resolvers = {
  Mutation: {
    createOrder: async (_parent, { input }, context) => {
      // Business logic directly in the resolver
      if (!context.user) throw new Error('Not authenticated');
      if (input.lineItems.length === 0) throw new Error('Order must have items');

      const inventory = await context.db.query(
        'SELECT quantity FROM inventory WHERE product_id = ANY($1)',
        [input.lineItems.map(li => li.productId)]
      );
      for (const item of input.lineItems) {
        const stock = inventory.find(i => i.product_id === item.productId);
        if (!stock || stock.quantity < item.quantity) {
          throw new Error(`Insufficient inventory for product ${item.productId}`);
        }
      }
      // ... 50 more lines of business logic
    },
  },
};
```

**Correct:**

```typescript
// GOOD: Resolver delegates entirely to the service layer
const resolvers = {
  Mutation: {
    createOrder: async (_parent, { input }, context): Promise<CreateOrderResult> => {
      return context.orderService.createOrder({
        customerId: context.user.id,
        input,
      });
    },
  },
};

// OrderService: independently testable, no GraphQL dependency
export class OrderService {
  constructor(
    private readonly orderRepo: OrderRepository,
    private readonly inventoryService: InventoryService,
    private readonly paymentService: PaymentService,
    private readonly eventBus: EventBus,
  ) {}

  async createOrder(params: CreateOrderParams): Promise<CreateOrderResult> {
    await this.validateLineItems(params.input.lineItems);
    const reservation = await this.inventoryService.reserve(params.input.lineItems);
    const order = await this.orderRepo.create({ ...params, reservationId: reservation.id });
    await this.eventBus.publish(new OrderCreatedEvent(order));
    return { __typename: 'CreateOrderSuccess', order };
  }
}
```

---

## BP-R-04: Return null and Push to Errors Array for Recoverable Field-Level Errors

**Rule:** For recoverable, field-level errors (a related entity was not found, a field computation failed), return `null` for the field and add a formatted error to the `info.errors` array. Reserve `throw` for non-recoverable infrastructure failures.

**Rationale:** Throwing inside a resolver surfaces an error in the top-level `errors` array with the full resolver path, but the error propagation depends on nullability. For nullable fields, the partial result is still returned. For non-null fields, the null propagates up the tree. Intentional `null` + formatted error gives you control over what clients receive without the unintended propagation behavior of an exception.

**Correct:**

```typescript
import { GraphQLError } from 'graphql';

const resolvers = {
  Order: {
    // shippingProvider is nullable — if lookup fails, return null + structured error
    shippingProvider: async (order, _args, context, info) => {
      try {
        return await context.loaders.shippingProviderById.load(order.shippingProviderId);
      } catch (error) {
        // Log the internal error
        context.logger.warn('shippingProvider lookup failed', {
          orderId: order.id,
          shippingProviderId: order.shippingProviderId,
          error: error.message,
        });

        // Return null with a structured error — does not kill the parent Order
        info.path &&
          context.errors.push(
            new GraphQLError('Shipping provider data temporarily unavailable', {
              extensions: {
                code: 'SHIPPING_PROVIDER_UNAVAILABLE',
                orderId: order.id,
              },
            })
          );
        return null;
      }
    },
  },
};
```

---

## BP-R-05: Set Timeouts on All External Service Calls

**Rule:** Every call to an external service (database, REST API, gRPC service, cache) must have an explicit timeout. Never allow a downstream service to hold a request indefinitely.

**Rationale:** Without timeouts, a slow or unresponsive downstream service stalls the entire GraphQL request until the connection is dropped by the client or the process runs out of file descriptors. Under load, stalled requests pile up, exhaust connection pools, and cascade into full service unavailability. Timeouts allow the resolver to fail fast, return a partial response, and release resources.

**Correct:**

```typescript
import AbortController from 'abort-controller';

async function fetchWithTimeout<T>(
  fn: (signal: AbortSignal) => Promise<T>,
  timeoutMs: number,
  label: string
): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    return await fn(controller.signal);
  } catch (error) {
    if (controller.signal.aborted) {
      throw new Error(`${label} timed out after ${timeoutMs}ms`);
    }
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

// Usage in a resolver
const resolvers = {
  Query: {
    productRecommendations: async (_parent, { productId }, context) => {
      return fetchWithTimeout(
        (signal) => context.recommendationService.getRecommendations(productId, { signal }),
        500, // 500ms — recommendations are non-critical, fail fast
        'productRecommendations'
      ).catch(() => []); // Graceful degradation: empty list, not an error
    },
  },
};
```

Database query timeout:

```typescript
// PostgreSQL: statement-level timeout per query
const result = await db.query({
  text: 'SELECT * FROM products WHERE category_id = $1',
  values: [categoryId],
  // Cancel query at the database server after 3 seconds
  queryTimeout: 3000,
});
```

---

## BP-R-06: Validate Business Rules at the Resolver Boundary

**Rule:** GraphQL's type system validates the _shape_ of inputs (required fields, scalar types). Business invariants (a quantity must be > 0, a date must be in the future, a user must have a specific role) must be validated at the resolver boundary — not assumed to be correct because the type system accepted the input.

**Rationale:** `Int!` accepts `-1`. `String!` accepts an empty string. `DateTime!` accepts a date in 1970. The type system enforces the GraphQL contract, not the business contract. Resolver-boundary validation is the last line of defense before business logic executes with invalid state.

**Correct:**

```typescript
import { UserInputError } from '@apollo/server/errors';

const resolvers = {
  Mutation: {
    createPromoCode: async (_parent, { input }, context): Promise<CreatePromoCodeResult> => {
      // Business rule validation at the resolver boundary
      const errors: FieldError[] = [];

      if (input.discountPercent <= 0 || input.discountPercent > 100) {
        errors.push({
          field: 'discountPercent',
          message: 'Discount percent must be between 1 and 100',
        });
      }

      if (new Date(input.expiresAt) <= new Date()) {
        errors.push({
          field: 'expiresAt',
          message: 'Expiration date must be in the future',
        });
      }

      if (input.maxUses !== undefined && input.maxUses < 1) {
        errors.push({
          field: 'maxUses',
          message: 'maxUses must be at least 1 if specified',
        });
      }

      if (errors.length > 0) {
        return {
          __typename: 'ValidationError',
          message: 'Invalid promo code configuration',
          fieldErrors: errors,
        };
      }

      return context.promoCodeService.createPromoCode(input);
    },
  },
};
```

---

## BP-R-07: Log All Resolver Errors With trace_id, field_path, and operation_name

**Rule:** Every caught error in a resolver must be logged with the OpenTelemetry trace ID, the full field path, the operation name, and any relevant entity identifiers. Errors without context are undebuggable in production.

**Rationale:** When a client reports "my orders page is broken," the support team needs to find the specific error in logs within minutes. Without trace IDs, field paths, and operation names, log searches return every error from every resolver. With structured logging, a single log query isolates the failure.

**Correct:**

```typescript
const resolvers = {
  Query: {
    order: async (_parent, { id }, context, info) => {
      const startTime = Date.now();
      try {
        return await context.loaders.orderById.load(id);
      } catch (error) {
        context.logger.error('Resolver error: Query.order', {
          traceId: context.traceId,
          operationName: info.operation.name?.value ?? 'anonymous',
          fieldPath: info.path,
          orderId: id,
          userId: context.user?.id,
          durationMs: Date.now() - startTime,
          errorCode: error.code ?? 'UNKNOWN',
          errorMessage: error.message,
          // Never log error.stack in production — too noisy; log in development
          ...(process.env.NODE_ENV === 'development' && { stack: error.stack }),
        });
        throw error; // Re-throw after logging; ApolloServer handles the response
      }
    },
  },
};
```

Structured log output (JSON):

```json
{
  "level": "error",
  "message": "Resolver error: Query.order",
  "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
  "operationName": "GetOrderDetails",
  "fieldPath": { "key": "order", "prev": null },
  "orderId": "01HGZ1BNV4EXKM3RQWAJPDS432",
  "userId": "usr_01HF3MPQBWXHV9K2JDCTDE6BH7",
  "durationMs": 3421,
  "errorCode": "CONNECTION_REFUSED",
  "errorMessage": "connect ECONNREFUSED 10.0.1.5:5432"
}
```

---

## BP-R-08: Use Integration Tests With a Real Database — Not Mocks

**Rule:** Resolver integration tests must use a real database (PostgreSQL in a Docker container or a dedicated test cluster). Mock-based tests that replace `db.query()` with fake responses do not validate SQL queries, index usage, constraint enforcement, or transaction behavior.

**Rationale:** The most common production GraphQL bugs are SQL bugs: wrong JOIN conditions, missing WHERE clauses, N+1 from incorrect eager loading, constraint violations. These bugs are invisible to mock-based tests. Integration tests against a real database catch them before deployment.

**Correct:**

```typescript
// jest.config.ts — integration test suite with real PostgreSQL
import { StartedPostgreSqlContainer, PostgreSqlContainer } from '@testcontainers/postgresql';
import { buildTestContext } from './test-helpers/context';

let container: StartedPostgreSqlContainer;
let db: Database;

beforeAll(async () => {
  container = await new PostgreSqlContainer('postgres:16-alpine')
    .withDatabase('testdb')
    .start();

  db = await connectDatabase(container.getConnectionUri());
  await runMigrations(db); // Apply all migrations to get to current schema
});

afterAll(async () => {
  await db.disconnect();
  await container.stop();
});

beforeEach(async () => {
  await db.query('BEGIN');
});

afterEach(async () => {
  await db.query('ROLLBACK'); // Each test runs in a transaction, rolled back after
});

test('createOrder returns InsufficientInventoryError when stock is zero', async () => {
  // Seed: product with zero inventory
  await db.query(
    "INSERT INTO products (id, name, inventory_count) VALUES ('prod-1', 'Widget', 0)"
  );

  const context = buildTestContext({ db, userId: 'user-1' });
  const result = await resolvers.Mutation.createOrder(
    null,
    { input: { lineItems: [{ productId: 'prod-1', quantity: 1 }] } },
    context
  );

  expect(result.__typename).toBe('InsufficientInventoryError');
  expect(result.unavailableItems).toHaveLength(1);
  expect(result.unavailableItems[0].productId).toBe('prod-1');
});
```

---

## BP-R-09: Use Keyset Cursor Pagination in All List Resolvers — Never Offset

**Rule:** All list resolver implementations must use keyset (cursor-based) pagination with a stable sort key. SQL `OFFSET` is forbidden in list resolver implementations.

**Rationale:** See BP-S-03 for the schema-level rationale. At the resolver level: keyset pagination requires an index on the sort column(s), runs in O(log n), and remains stable under concurrent writes. Offset pagination performs a full sort of all preceding rows on every page fetch and produces duplicate or missing items under concurrent inserts.

**Counter-example:**

```typescript
// BAD: Offset pagination at the resolver level
const resolvers = {
  Query: {
    orders: async (_parent, { limit = 20, offset = 0 }, context) => {
      // O(offset) scan; breaks under concurrent inserts; doesn't scale
      return context.db.query(
        'SELECT * FROM orders ORDER BY created_at DESC LIMIT $1 OFFSET $2',
        [limit, offset]
      );
    },
  },
};
```

**Correct:**

```typescript
import { decodeCursor, encodeCursor } from './cursor';

interface OrderCursor {
  createdAt: string;
  id: string;
}

const resolvers = {
  Query: {
    orders: async (_parent, { first = 20, after }, context) => {
      const cursor: OrderCursor | null = after ? decodeCursor<OrderCursor>(after) : null;

      const rows = await context.db.query<Order & { total_count: number }>(
        `SELECT *, COUNT(*) OVER() AS total_count
         FROM orders
         WHERE ($1::timestamptz IS NULL OR (created_at, id) < ($1::timestamptz, $2::uuid))
         ORDER BY created_at DESC, id DESC
         LIMIT $3`,
        [cursor?.createdAt ?? null, cursor?.id ?? null, first + 1]
      );

      const hasNextPage = rows.length > first;
      const edges = rows.slice(0, first).map(row => ({
        node: row,
        cursor: encodeCursor<OrderCursor>({ createdAt: row.created_at, id: row.id }),
      }));

      return {
        edges,
        pageInfo: {
          hasNextPage,
          hasPreviousPage: cursor !== null,
          startCursor: edges[0]?.cursor ?? null,
          endCursor: edges[edges.length - 1]?.cursor ?? null,
        },
        totalCount: rows[0]?.total_count ?? 0,
      };
    },
  },
};
```

---

## BP-R-10: Never Expose Raw Database Error Messages to the Client

**Rule:** All database errors caught in resolvers must be logged internally and replaced with a safe, generic message before surfacing in the GraphQL response. Never pass a `pg` error, Prisma error, or raw exception message through to the client.

**Rationale:** Database error messages reveal schema internals: table names (`relation "users" does not exist`), column names (`column "email" of relation "users" violates not-null constraint`), and constraint names (`duplicate key value violates unique constraint "users_email_key"`). This information aids SQL injection and enumeration attacks.

**Counter-example:**

```typescript
// BAD: Raw database error propagated to the client
const resolvers = {
  Mutation: {
    createUser: async (_parent, { input }, context) => {
      try {
        return await context.db.query('INSERT INTO users ...');
      } catch (error) {
        // error.message = 'duplicate key value violates unique constraint "users_email_key"'
        // This reveals the table name, column name, and constraint name
        throw new Error(error.message); // BAD: leak
      }
    },
  },
};
```

**Correct:**

```typescript
import { GraphQLError } from 'graphql';

function mapDatabaseError(error: DatabaseError): GraphQLError {
  // Handle known error codes with safe messages
  if (error.code === '23505') { // PostgreSQL unique_violation
    return new GraphQLError('A record with those values already exists', {
      extensions: { code: 'DUPLICATE_RECORD' },
    });
  }
  if (error.code === '23503') { // PostgreSQL foreign_key_violation
    return new GraphQLError('Referenced record does not exist', {
      extensions: { code: 'INVALID_REFERENCE' },
    });
  }
  // Unknown error: log internally, return generic message
  return new GraphQLError('An internal error occurred. Please try again.', {
    extensions: { code: 'INTERNAL_ERROR' },
  });
}

const resolvers = {
  Mutation: {
    createUser: async (_parent, { input }, context) => {
      try {
        return await context.userService.createUser(input);
      } catch (error) {
        if (isDatabaseError(error)) {
          context.logger.error('Database error in createUser', { error, input: sanitize(input) });
          throw mapDatabaseError(error);
        }
        throw error; // Re-throw non-database errors
      }
    },
  },
};
```

---

## BP-R-11: Prefer async/await — Avoid Synchronous CPU Work in Resolvers

**Rule:** All resolver functions must be async. Never perform synchronous CPU-intensive work (JSON parsing of large payloads, crypto operations, complex computations) inside a resolver without offloading to a worker thread.

**Rationale:** Node.js is single-threaded. Synchronous CPU work in a resolver blocks the event loop for all concurrent requests. A single resolver performing 100ms of synchronous computation serializes all other requests behind it, destroying concurrency and driving latency up by 100ms for every in-flight request.

**Counter-example:**

```typescript
// BAD: Synchronous CPU work blocks the event loop
const resolvers = {
  Query: {
    exportOrdersAsCsv: (_parent, { filter }, context) => {
      const orders = fetchOrdersSync(filter); // Synchronous fetch
      const csv = orders.map(o => `${o.id},${o.total},${o.status}`).join('\n'); // Fine
      const compressed = zlib.gzipSync(Buffer.from(csv)); // BLOCKS event loop
      return compressed.toString('base64');
    },
  },
};
```

**Correct:**

```typescript
import { promisify } from 'util';
import zlib from 'zlib';
const gzip = promisify(zlib.gzip);

const resolvers = {
  Query: {
    exportOrdersAsCsv: async (_parent, { filter }, context) => {
      const orders = await context.orderService.findOrders(filter);
      const csv = orders.map(o => `${o.id},${o.total},${o.status}`).join('\n');
      // Async gzip — does not block the event loop
      const compressed = await gzip(Buffer.from(csv));
      return compressed.toString('base64');
    },
  },
};
```

For heavy CPU work, use worker threads:

```typescript
import { Worker } from 'worker_threads';

function runInWorker<T>(workerFile: string, data: unknown): Promise<T> {
  return new Promise((resolve, reject) => {
    const worker = new Worker(workerFile, { workerData: data });
    worker.on('message', resolve);
    worker.on('error', reject);
  });
}
```

---

## BP-R-12: Cache Idempotent Resolver Results Within a Request

**Rule:** Resolver results that are idempotent (same inputs always produce the same output within a request) should be cached within the request context using a simple Map. Do not re-execute expensive lookups when the same data is needed multiple times within one operation.

**Rationale:** A GraphQL operation may request the same entity multiple times through different paths. Without caching, each path triggers an independent fetch. DataLoader handles this for entity-by-ID lookups (its per-request cache). For complex aggregations, configuration fetches, or permission checks, a request-scoped cache prevents redundant work.

**Correct:**

```typescript
// Request-scoped cache for expensive, idempotent operations
class RequestCache {
  private cache = new Map<string, Promise<unknown>>();

  getOrFetch<T>(key: string, fetch: () => Promise<T>): Promise<T> {
    if (!this.cache.has(key)) {
      this.cache.set(key, fetch());
    }
    return this.cache.get(key) as Promise<T>;
  }
}

// In context factory
const requestCache = new RequestCache();

// In resolvers
const resolvers = {
  Query: {
    // This query may appear multiple times in an operation (nested in different fragments)
    currentUser: async (_parent, _args, context) => {
      return context.requestCache.getOrFetch(
        `user:${context.user.id}`,
        () => context.userService.getUserById(context.user.id)
      );
    },
  },

  // Permission check called from multiple resolvers in one request
  Order: {
    sensitiveFinancialData: async (order, _args, context) => {
      const canAccess = await context.requestCache.getOrFetch(
        `permission:finance:${context.user.id}`,
        () => context.permissionService.hasFinanceAccess(context.user.id)
      );
      return canAccess ? order.financialDetails : null;
    },
  },
};
```

---

## BP-R-13: Implement Field-Level Authorization in Resolvers — Not Just Operation-Level

**Rule:** Authorization must be enforced at the field level for sensitive fields. A JWT check at the operation entry point is insufficient — a user authenticated to query orders must not be able to query another user's financial data through a field resolver.

**Rationale:** Operation-level auth verifies identity. Field-level auth verifies access to a specific resource. Without field-level auth, a lateral movement attack is straightforward: an authenticated user constructs a query that navigates to a different user's data through entity relationships.

**Correct:**

```typescript
import { ForbiddenError } from '@apollo/server/errors';

const resolvers = {
  Order: {
    // Only the order's customer or a finance admin can see payment details
    paymentDetails: async (order, _args, context) => {
      const isOrderOwner = order.customerId === context.user?.id;
      const isFinanceAdmin = context.user?.roles.includes('FINANCE_ADMIN');

      if (!isOrderOwner && !isFinanceAdmin) {
        throw new ForbiddenError('Access denied: paymentDetails requires ownership or FINANCE_ADMIN role');
      }

      return context.loaders.paymentDetailsByOrderId.load(order.id);
    },
  },

  User: {
    // Only the user themselves or HR admins can see salary information
    compensation: async (user, _args, context) => {
      const isSelf = user.id === context.user?.id;
      const isHrAdmin = context.user?.roles.includes('HR_ADMIN');

      if (!isSelf && !isHrAdmin) {
        return null; // Return null rather than throwing — less information disclosure
      }

      return context.loaders.compensationByUserId.load(user.id);
    },
  },
};
```

---

## BP-R-14: Use OpenTelemetry Spans in Resolvers for Distributed Tracing

**Rule:** Every resolver that performs an external call (database, service, cache) must create an OpenTelemetry child span. The span must include the operation name, field path, entity ID, and duration.

**Rationale:** Distributed tracing is the only way to understand where time is spent in a federated GraphQL system. Without spans at the resolver level, you can see that an operation took 3 seconds, but cannot determine which resolver or downstream service is responsible. Resolver-level spans provide complete visibility.

**Correct:**

```typescript
import { trace, context as otelContext, SpanStatusCode } from '@opentelemetry/api';

const tracer = trace.getTracer('graphql-resolvers');

function withSpan<T>(
  name: string,
  attributes: Record<string, string | number>,
  fn: () => Promise<T>
): Promise<T> {
  return tracer.startActiveSpan(name, { attributes }, async (span) => {
    try {
      const result = await fn();
      span.setStatus({ code: SpanStatusCode.OK });
      return result;
    } catch (error) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
      span.recordException(error);
      throw error;
    } finally {
      span.end();
    }
  });
}

const resolvers = {
  Query: {
    order: async (_parent, { id }, context, info) => {
      return withSpan('resolver.Query.order', {
        'graphql.field.name': 'order',
        'graphql.operation.name': info.operation.name?.value ?? 'anonymous',
        'order.id': id,
      }, () => context.loaders.orderById.load(id));
    },
  },
};
```

---

## BP-R-15: Never Silently Swallow Errors — Always Log Before Returning Null

**Rule:** When a resolver catches an error and returns `null` for graceful degradation, it must log the error before returning. Silent null returns are invisible failures that accumulate undetected.

**Rationale:** Graceful degradation (returning null instead of crashing the query) is correct behavior for non-critical fields. But if the error is not logged, the failure is invisible. Over time, a field that always returns null due to a bug appears to be "working" (the query succeeds) but the data is silently missing. Structured error logging with alert thresholds catches this pattern.

**Correct:**

```typescript
const resolvers = {
  Product: {
    relatedProducts: async (product, { first = 5 }, context) => {
      try {
        return await context.recommendationService.getRelatedProducts(product.id, first);
      } catch (error) {
        // Log before returning null — this failure is trackable and alertable
        context.logger.error('relatedProducts fetch failed', {
          traceId: context.traceId,
          productId: product.id,
          error: error.message,
          errorCode: error.code,
        });
        // Increment error counter for alerting
        context.metrics.increment('resolver.error', {
          resolver: 'Product.relatedProducts',
          errorCode: error.code ?? 'UNKNOWN',
        });
        return []; // Empty array — non-critical field, graceful degradation
      }
    },
  },
};
```

---

## BP-R-16: Use Resolver Middleware for Cross-Cutting Concerns

**Rule:** Cross-cutting concerns (auth checks, tracing, caching, rate limiting) must be implemented as resolver middleware using `graphql-middleware` or a similar mechanism — not copy-pasted into every resolver.

**Rationale:** Copy-pasting auth or logging code into every resolver is a maintenance hazard. When the auth logic changes, every resolver must be updated. Middleware applies the concern once, consistently, across all resolvers or a defined subset.

**Correct:**

```typescript
import { applyMiddleware } from 'graphql-middleware';
import { makeExecutableSchema } from '@graphql-tools/schema';

// Auth middleware — applied to all resolvers
const authMiddleware = {
  Query: {
    '*': async (resolve, parent, args, context, info) => {
      if (!context.user) {
        throw new AuthenticationError('Authentication required');
      }
      return resolve(parent, args, context, info);
    },
  },
};

// Tracing middleware — applied universally
const tracingMiddleware = async (resolve, parent, args, context, info) => {
  const fieldPath = `${info.parentType.name}.${info.fieldName}`;
  const start = Date.now();
  try {
    const result = await resolve(parent, args, context, info);
    context.metrics.histogram('resolver.duration', Date.now() - start, { field: fieldPath });
    return result;
  } catch (error) {
    context.metrics.increment('resolver.error', { field: fieldPath });
    throw error;
  }
};

const schema = applyMiddleware(
  makeExecutableSchema({ typeDefs, resolvers }),
  tracingMiddleware,
  authMiddleware
);
```

---

## BP-R-17: Implement Subscription Resolvers With Backpressure Handling

**Rule:** GraphQL subscription resolvers must handle backpressure. If a subscriber cannot consume events as fast as they are produced, the server must drop events or apply backpressure — never let the event queue grow unboundedly.

**Rationale:** An unbounded subscription event queue causes memory exhaustion. In high-throughput event systems (order status changes, inventory updates), a slow client connection causes the event buffer to grow without limit until the process runs out of memory and crashes.

**Correct:**

```typescript
import { PubSub } from 'graphql-subscriptions';

const pubsub = new PubSub();
const MAX_QUEUE_SIZE = 100; // Events per subscriber

const resolvers = {
  Subscription: {
    orderStatusUpdated: {
      subscribe: async function* (_parent, { orderId }, context) {
        if (!context.user) throw new AuthenticationError('Authentication required');

        const order = await context.loaders.orderById.load(orderId);
        if (order.customerId !== context.user.id) {
          throw new ForbiddenError('Access denied');
        }

        const asyncIterator = pubsub.asyncIterator([`ORDER_STATUS:${orderId}`]);
        let queueSize = 0;

        for await (const event of asyncIterator) {
          if (queueSize >= MAX_QUEUE_SIZE) {
            // Drop oldest event rather than growing queue
            continue;
          }
          queueSize++;
          yield event;
          queueSize--;

          // Auto-close subscription on terminal states
          if (['DELIVERED', 'CANCELLED'].includes(event.orderStatusUpdated.newStatus)) {
            return;
          }
        }
      },
    },
  },
};
```

---

## BP-R-18: Validate Resolver Arguments Against Maximum Limits

**Rule:** Any resolver argument that controls query scope (pagination `first`, list `limit`, date range span) must be validated against an explicit maximum. Never allow unbounded queries.

**Rationale:** A client requesting `first: 100000` on an orders query would fetch the entire orders table in one request. Without argument-level limits, a single malicious or misconfigured client can saturate database resources.

**Correct:**

```typescript
const MAX_PAGE_SIZE = 100;
const MAX_DATE_RANGE_DAYS = 365;

const resolvers = {
  Query: {
    orders: async (_parent, { first = 20, after, dateRange }, context) => {
      if (first < 1 || first > MAX_PAGE_SIZE) {
        throw new UserInputError(
          `'first' must be between 1 and ${MAX_PAGE_SIZE}. Received: ${first}`
        );
      }

      if (dateRange) {
        const daysDiff = differenceInDays(
          new Date(dateRange.to),
          new Date(dateRange.from)
        );
        if (daysDiff > MAX_DATE_RANGE_DAYS) {
          throw new UserInputError(
            `Date range cannot exceed ${MAX_DATE_RANGE_DAYS} days. Received: ${daysDiff} days`
          );
        }
      }

      return context.orderService.listOrders({ first, after, dateRange });
    },
  },
};
```

---

## BP-R-19: Test Resolver Authorization With Dedicated Permission Tests

**Rule:** Every field with authorization logic must have dedicated tests covering: unauthenticated access, authenticated-but-unauthorized access, and authorized access. Authorization is not covered by happy-path integration tests.

**Correct:**

```typescript
describe('Order.paymentDetails authorization', () => {
  test('returns null for unauthenticated requests', async () => {
    const context = buildTestContext({ user: null });
    const order = { id: 'order-1', customerId: 'user-2' };
    const result = await resolvers.Order.paymentDetails(order, {}, context);
    expect(result).toBeNull();
  });

  test('throws ForbiddenError for authenticated user who does not own the order', async () => {
    const context = buildTestContext({ user: { id: 'user-1', roles: [] } });
    const order = { id: 'order-1', customerId: 'user-2' }; // Different customer
    await expect(
      resolvers.Order.paymentDetails(order, {}, context)
    ).rejects.toThrow('Access denied');
  });

  test('returns payment details for the order owner', async () => {
    const context = buildTestContext({ user: { id: 'user-1', roles: [] } });
    const order = { id: 'order-1', customerId: 'user-1' }; // Same customer
    const result = await resolvers.Order.paymentDetails(order, {}, context);
    expect(result).not.toBeNull();
    expect(result.last4).toBeDefined();
  });

  test('returns payment details for FINANCE_ADMIN regardless of ownership', async () => {
    const context = buildTestContext({
      user: { id: 'admin-1', roles: ['FINANCE_ADMIN'] }
    });
    const order = { id: 'order-1', customerId: 'user-2' };
    const result = await resolvers.Order.paymentDetails(order, {}, context);
    expect(result).not.toBeNull();
  });
});
```

---

## BP-R-20: Use a Consistent Error Code Vocabulary Across All Resolvers

**Rule:** Define a shared error code enum used consistently across all resolvers. Every `GraphQLError` thrown must include an `extensions.code` value from this enum. Do not invent ad-hoc error code strings in individual resolvers.

**Correct:**

```typescript
// errors/codes.ts — shared across all resolvers
export const ErrorCodes = {
  // Auth
  UNAUTHENTICATED: 'UNAUTHENTICATED',
  FORBIDDEN: 'FORBIDDEN',

  // Input
  VALIDATION_ERROR: 'VALIDATION_ERROR',
  BAD_USER_INPUT: 'BAD_USER_INPUT',

  // Not found
  NOT_FOUND: 'NOT_FOUND',
  ENTITY_NOT_FOUND: 'ENTITY_NOT_FOUND',

  // Business errors
  DUPLICATE_RECORD: 'DUPLICATE_RECORD',
  INSUFFICIENT_INVENTORY: 'INSUFFICIENT_INVENTORY',
  PAYMENT_DECLINED: 'PAYMENT_DECLINED',
  CONFLICT: 'CONFLICT',

  // Infrastructure
  INTERNAL_ERROR: 'INTERNAL_ERROR',
  UPSTREAM_TIMEOUT: 'UPSTREAM_TIMEOUT',
  RATE_LIMITED: 'RATE_LIMITED',
} as const;

// Usage in a resolver
throw new GraphQLError('Order not found', {
  extensions: {
    code: ErrorCodes.NOT_FOUND,
    orderId: id,
  },
});
```

---

## References and Related Topics

- [DataLoader](https://github.com/graphql/dataloader) — the canonical batching and caching library
- [graphql-middleware](https://github.com/nicholasgasior/graphql-middleware) — resolver middleware framework
- [OpenTelemetry JavaScript SDK](https://opentelemetry.io/docs/instrumentation/js/) — distributed tracing instrumentation
- [graphql-scalars](https://the-guild.dev/graphql/scalars) — scalar type implementations for custom scalars
- [Chapter 04: Resolvers and Execution](../04-resolvers-and-execution/README.md) — resolver execution model
- [Chapter 06: Performance and Scaling](../06-performance-and-scaling/README.md) — caching, DataLoader, and optimization at scale
- [Chapter 14: Observability](../14-observability/README.md) — tracing and logging infrastructure
- [01-schema-best-practices.md](./01-schema-best-practices.md) — schema-level rules that complement resolver patterns
- [Anti-Patterns](../29-anti-patterns/README.md) — documented N+1 failures, mock-based test failures, and other resolver anti-patterns
