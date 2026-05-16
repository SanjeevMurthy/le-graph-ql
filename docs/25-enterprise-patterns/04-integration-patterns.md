# Integration Patterns

> **Purpose:** This document covers seven integration patterns for GraphQL in the context of surrounding enterprise systems: event stores, CQRS architectures, multi-client BFF deployments, legacy REST migration, distributed transactions, and resilience. GraphQL rarely lives in isolation — it is a presentation layer over complex backend architectures. These patterns address how to connect it correctly.

---

## Pattern 1: Event Sourcing + GraphQL

### Problem

The system uses an event store (EventStoreDB, Kafka with log compaction) as its source of truth. Events are immutable facts: `OrderPlaced`, `OrderShipped`, `PaymentReceived`. There is no `orders` table to query. GraphQL resolvers expect a queryable read model, but the event store is not optimized for random-access queries.

### Solution

Maintain **read models** (also called projections) that are built from the event stream and optimized for GraphQL queries. GraphQL resolvers query the read models. Subscriptions push new events to connected clients.

```
┌─────────────────────────────────────────────────────────────────┐
│  Write Side (Event Store)          Read Side (Read Models)       │
│                                                                  │
│  Client ──► Command Service        Event Processor              │
│               │                     │                           │
│               ▼                     ▼                           │
│          Event Store ──────────► Order Read Model (PostgreSQL)  │
│          (Kafka / ESDB)         ► User Stats Model (Redis)      │
│               │                 ► Search Index (Elasticsearch)  │
│               │                     │                           │
│               └─────────────────────┤                           │
│                    Subscriptions     ▼                           │
│                    (WebSocket)    GraphQL Subgraph               │
└─────────────────────────────────────────────────────────────────┘
```

Schema design for an event-sourced system:

```graphql
type Query {
  # Queries hit the read model, not the event store
  order(id: ID!): Order
  orders(filter: OrderFilter, first: Int, after: String): OrderConnection!
  orderAggregates(customerId: ID!): OrderAggregates!
}

type Subscription {
  # Subscribe to the event stream projected to this customer's orders
  orderStatusChanged(customerId: ID!): OrderStatusChangedEvent!
  orderEvents(orderId: ID!): OrderEvent!
}

# The Order type reflects the current read model projection
type Order {
  id: ID!
  status: OrderStatus!
  total: Money!
  events: [OrderEvent!]!   # Full event history queryable from the read model
  customer: User
}

# Event types are queryable facts, not just metadata
union OrderEvent =
  | OrderPlacedEvent
  | OrderShippedEvent
  | OrderCancelledEvent
  | PaymentReceivedEvent

type OrderPlacedEvent {
  eventId: ID!
  occurredAt: ISO8601DateTime!
  orderId: ID!
  customerId: ID!
  lineItems: [OrderLineItem!]!
  total: Money!
}
```

Subscription resolver using Kafka consumer:

```typescript
// resolvers/Subscription.ts
import { PubSub } from 'graphql-subscriptions';
import type { KafkaConsumer } from '../events/KafkaConsumer';

export function createSubscriptionResolvers(
  pubsub: PubSub,
  kafka: KafkaConsumer
) {
  // Bridge Kafka events to GraphQL subscriptions
  kafka.on('order.status.changed', (event: OrderStatusChangedMessage) => {
    pubsub.publish(`ORDER_STATUS_CHANGED:${event.customerId}`, {
      orderStatusChanged: {
        orderId: event.orderId,
        previousStatus: event.previousStatus,
        newStatus: event.newStatus,
        occurredAt: event.timestamp,
      },
    });
  });

  return {
    Subscription: {
      orderStatusChanged: {
        subscribe: (_root: unknown, { customerId }: { customerId: string }) =>
          pubsub.asyncIterator(`ORDER_STATUS_CHANGED:${customerId}`),
      },
    },
  };
}
```

### Trade-offs

| Gain | Cost |
|---|---|
| Read models are optimized for each query pattern independently | Read models introduce eventual consistency — queries may lag the event stream |
| Event history is queryable as first-class data | Read model maintenance adds operational complexity |
| Subscriptions bridge event stream to real-time clients naturally | Multiple read models must stay in sync — consistency gaps are possible |

### When to Use

- Systems already using event sourcing as their primary persistence model
- Audit-heavy domains (finance, healthcare, compliance) where full event history is a requirement
- Systems that need multiple query representations of the same data

---

## Pattern 2: CQRS with GraphQL

### Problem

A GraphQL API handles both `query` (reads) and `mutation` (writes). At scale, reads and writes have very different characteristics: reads are high-volume, cacheable, and can tolerate read replicas; writes are low-volume, require consistency, and go to the primary database. Using the same GraphQL server and database connection pool for both creates contention.

### Solution

Route queries to a **read subgraph** backed by read replicas. Route mutations to **write subgraphs** backed by command services. The router enforces the split. Subscriptions bridge the async consistency gap.

```
┌────────────────────────────────────────────────────┐
│                  Apollo Router                      │
│    query { ... }    →    Read Subgraph              │
│    mutation { ... } →    Write Subgraph             │
│    subscription     →    Subscription Subgraph      │
└────────────────────────────────────────────────────┘

Read Subgraph                 Write Subgraph
│                             │
▼                             ▼
Read Replica Cluster          Command Service
(PostgreSQL Replica)          (Primary DB + event bus)
(Elasticsearch)
(Redis Cache)
```

Router configuration to enforce CQRS routing:

```yaml
# router.yaml — coprocessor that validates operation type routing
coprocessor:
  url: http://cqrs-policy-service:8080/enforce
  router:
    request:
      headers: true
      body: true
```

```typescript
// cqrs-policy-service: ensures mutations never reach read subgraph
app.post('/enforce', (req, res) => {
  const { body } = req.body;
  const operationType = parseOperationType(body.query);

  // This policy is enforced at the router level, but the subgraph schema
  // also enforces it: read subgraph has no Mutation type
  if (operationType === 'mutation' && req.body.subgraph === 'read-subgraph') {
    return res.json({
      control: 'reject',
      response: {
        statusCode: 400,
        body: JSON.stringify({
          errors: [{ message: 'Mutations are not permitted on the read subgraph' }],
        }),
      },
    });
  }

  return res.json({ control: 'continue' });
});
```

Handling eventual consistency in the schema — add a `syncedAt` timestamp to indicate data freshness:

```graphql
type Order {
  id: ID!
  status: OrderStatus!
  total: Money!

  # Indicates when this read model was last synced from the write side
  # Clients can display a "data as of X" message for time-sensitive fields
  readModelSyncedAt: ISO8601DateTime!
}

type CreateOrderResult {
  # On mutation success, return enough data for the client to
  # display confirmation without needing a refetch
  order: Order!
  # Estimated time until the read model reflects this write
  eventualConsistencyEstimateMs: Int!
}
```

### Trade-offs

| Gain | Cost |
|---|---|
| Read and write paths scale independently | Eventual consistency: reads may lag writes by milliseconds to seconds |
| Read replicas absorb query load without affecting write throughput | Client complexity: must handle stale data gracefully |
| Write path is isolated from read spikes | Two schema surfaces to maintain (read subgraph + write subgraphs) |

### When to Use

- High-read, low-write workloads (e-commerce catalog, content delivery)
- Systems where query complexity is high and read replicas would provide meaningful relief
- Systems already using event-driven architectures

### When Not to Use

- Read-after-write consistency requirements that cannot tolerate even millisecond lag (financial transaction confirmation screens)
- Simple CRUD applications where read/write isolation adds complexity without benefit

---

## Pattern 3: BFF (Backend for Frontend) Pattern

### Problem

A Web client, iOS app, and Android app all query the same GraphQL supergraph. The web client needs rich, desktop-optimized responses with many fields. The mobile app needs bandwidth-optimized responses: fewer fields, smaller images, no pagination overhead. The mobile app also needs push notification subscriptions the web client doesn't use. Serving both from one schema creates tension: every field must satisfy both consumers, or consumers over-fetch.

### Solution

Deploy **thin, purpose-built GraphQL layers per client type**. Each BFF is a GraphQL subgraph (or a standalone server) that:
- Applies schema contracts (`@tag`) to expose only the client's relevant schema surface
- Contains client-specific resolvers for platform-specific behavior (push tokens, device-specific pagination sizes)
- Is maintained by the client team that owns the consumer

```
                              Apollo Router (Supergraph)
                            /            |             \
                     Mobile BFF      Web BFF       Partner API BFF
                   (iOS + Android)  (React/Next)   (External developers)
                        |               |                  |
                  Mobile Schema    Full Schema       Public Schema
                  (bandwidth       (all fields,      (@tag: "public"
                   optimized,       desktop UI        contract graph)
                   push tokens)     fields)
```

Mobile BFF schema contract configuration:

```yaml
# mobile-bff-contract.yaml
name: mobile-bff
filter:
  include:
    - mobile
    - public
  exclude:
    - internal
    - desktop-only
```

Mobile BFF resolver additions (client-specific logic):

```typescript
// mobile-bff/resolvers/User.ts
// The mobile BFF adds push notification management — not in the core schema
export const MobileBFFUserResolvers = {
  User: {
    // Mobile-specific: push notification preferences
    pushNotificationSettings: async (user: UserRef, _args: unknown, context: MobileBFFContext) => {
      return context.pushService.getSettings(user.id, context.deviceId);
    },
  },

  Mutation: {
    // Mobile-specific mutation: register device for push
    registerDevicePushToken: async (
      _root: unknown,
      { token, platform }: { token: string; platform: 'IOS' | 'ANDROID' },
      context: MobileBFFContext
    ) => {
      return context.pushService.registerToken(context.auth.userId, token, platform);
    },
  },
};
```

Mobile BFF applies platform-specific defaults:

```typescript
// mobile-bff/middleware/defaults.ts
// Override default pagination size for mobile bandwidth constraints
export function applyMobileDefaults(operation: DocumentNode): DocumentNode {
  // Rewrite first: default to 10 items, max 25 (vs web: default 20, max 100)
  return visit(operation, {
    Argument(node) {
      if (node.name.value === 'first' && node.value.kind === 'NullValue') {
        return { ...node, value: { kind: 'IntValueNode', value: '10' } };
      }
    },
  });
}
```

### Trade-offs

| Gain | Cost |
|---|---|
| Each client gets a schema and resolver set optimized for its needs | Multiple BFF layers to maintain, deploy, and monitor |
| Client teams own their BFF — no central schema team bottleneck | Schema changes must propagate to relevant BFFs |
| Bandwidth optimization is enforced at the schema layer | BFFs can diverge — requires governance to prevent duplication of business logic in BFFs |

### When to Use

- Applications with genuinely different client types (mobile vs web vs embedded device)
- Consumer teams that have significantly different schema consumption patterns
- Organizations with dedicated client teams that can own their BFF

### When Not to Use

- Applications with a single client type
- Teams too small to maintain multiple BFF layers alongside the core schema

---

## Pattern 4: GraphQL as API Gateway

### Problem

A REST API gateway (Kong, AWS API Gateway, custom Express router) routes requests to microservices. Every client must know multiple REST endpoints. Schema versioning is done via URL `/v1`, `/v2`. Clients receive over-specified responses and must filter fields. Adding a new field requires REST API changes, gateway routing changes, and client changes in parallel.

### Solution

Replace the REST gateway with Apollo Router as the entry point. All clients send GraphQL queries. The router resolves fields against subgraphs that may still use REST internally.

```
BEFORE:
Client → REST Gateway → /users → Users Service (REST)
                      → /orders → Orders Service (REST)
                      → /products → Products Service (REST)

AFTER:
Client → Apollo Router → Users Subgraph (wraps Users REST API or native)
                       → Orders Subgraph (wraps Orders REST API or native)
                       → Products Subgraph (native DB access)
```

REST-wrapping subgraph (Strangler Fig starting point):

```typescript
// users-subgraph/resolvers/Query.ts
// Phase 1: subgraph wraps the existing REST API
// Phase 2: replace with native database access (Strangler Fig pattern)
export const QueryResolvers = {
  Query: {
    user: async (_root: unknown, { id }: { id: string }, context: UsersContext) => {
      // Currently delegates to REST API
      const response = await context.legacyRestClient.get(`/users/${fromGlobalId(id).id}`);
      if (response.status === 404) return null;
      return mapRestUserToGraphQLUser(await response.json());
    },
  },
};
```

What fits well as a GraphQL API gateway:
- Aggregating data from multiple services into a single client response
- Type-safe schema as the API contract
- Field selection eliminates over-fetching
- Subscriptions replace REST polling

What does not fit well:
- File uploads — use a REST endpoint for binary uploads, return a GraphQL mutation with the file metadata
- Webhook receivers — these are REST push endpoints, not GraphQL
- Health check and readiness endpoints — REST `GET /healthz` is simpler and compatible with load balancer checks

### Trade-offs

| Gain | Cost |
|---|---|
| Single client entry point with typed schema | Learning curve for teams accustomed to REST gateway configuration |
| Field selection eliminates over-fetching | Complex query plans can be harder to debug than REST routing |
| Schema introspection replaces REST API documentation | Not all traffic patterns fit GraphQL (file uploads, webhooks) |

### When to Use

- New system designs with multiple frontend clients and multiple backend services
- Systems already investing in Apollo Federation

### When Not to Use

- High-throughput binary data transfer
- Simple two-tier CRUD applications with one client and one database

---

## Pattern 5: Strangler Fig for REST Migration

### Problem

A mature REST API has 200 endpoints. A new GraphQL layer is being introduced. Migrating all 200 endpoints at once is too risky. Rolling back would require reverting both the REST API and the GraphQL layer simultaneously. The migration must be incremental, reversible, and transparent to clients.

### Solution

Each GraphQL resolver starts by wrapping the existing REST endpoint. The resolver facade is the "fig" that grows around the REST tree. As each REST endpoint is replaced by native data access, the facade is removed. When all resolvers use native access, the REST API tree is dead and can be removed.

```typescript
// products-subgraph/resolvers/Query.ts

// PHASE 1: REST wrapper — resolver delegates to existing REST API
export const queryResolvers_Phase1 = {
  Query: {
    product: async (_root: unknown, { id }: { id: string }, context: ProductsContext) => {
      const legacyId = fromGlobalId(id).id;
      const response = await context.legacyRestClient.get(`/api/v1/products/${legacyId}`);
      if (response.status === 404) return null;
      const data = await response.json();
      return mapLegacyProductToGraphQL(data);
    },
  },
};

// PHASE 2: Hybrid — hot product reads from cache, cold from REST
export const queryResolvers_Phase2 = {
  Query: {
    product: async (_root: unknown, { id }: { id: string }, context: ProductsContext) => {
      const legacyId = fromGlobalId(id).id;

      // Try cache first (new infrastructure)
      const cached = await context.cache.get<Product>(`product:${legacyId}`);
      if (cached) return cached;

      // Fall back to REST (legacy)
      const response = await context.legacyRestClient.get(`/api/v1/products/${legacyId}`);
      if (response.status === 404) return null;
      const product = mapLegacyProductToGraphQL(await response.json());

      await context.cache.set(`product:${legacyId}`, product, 300);
      return product;
    },
  },
};

// PHASE 3: Native — full database access, REST wrapper removed
export const queryResolvers_Phase3 = {
  Query: {
    product: async (_root: unknown, { id }: { id: string }, context: ProductsContext) => {
      return context.repositories.product.findById(fromGlobalId(id).id);
    },
  },
};
```

Track migration progress with a feature flag per resolver:

```typescript
// config/migrationFlags.ts
export const MIGRATION_FLAGS = {
  PRODUCTS_USE_NATIVE_DB: process.env.PRODUCTS_USE_NATIVE_DB === 'true',
  USERS_USE_NATIVE_DB: process.env.USERS_USE_NATIVE_DB === 'true',
  ORDERS_USE_NATIVE_DB: process.env.ORDERS_USE_NATIVE_DB === 'true',
};
```

### Trade-offs

| Gain | Cost |
|---|---|
| Migration is incremental — one resolver at a time | Two code paths to maintain during migration |
| Rollback is a feature flag flip | REST API must remain operational throughout the migration |
| Clients are unaffected — GraphQL schema is stable | REST wrapper latency adds overhead during migration phase |

### When to Use

- Any migration from REST to GraphQL where big-bang migration is too risky
- Legacy REST APIs with high traffic where a rollback path is required

---

## Pattern 6: Saga Pattern for Distributed Mutations

### Problem

A `placeOrder` mutation must: (1) reserve inventory, (2) charge the payment method, (3) create the order record, (4) send a confirmation email. If payment fails after inventory was reserved, the inventory reservation must be released. If the email service fails, the order was already created and paid — a partial failure that must be handled. Standard GraphQL mutations have no compensating transaction mechanism.

### Solution

Implement a **saga orchestrator** in a dedicated mutation subgraph. The orchestrator executes each step and tracks saga state. On failure, it executes compensating mutations in reverse order.

```typescript
// order-saga-subgraph/resolvers/Mutation.placeOrder.ts
import { SagaOrchestrator, type SagaStep } from '../saga/Orchestrator';

export const placeOrderMutation = async (
  _root: unknown,
  { input }: { input: PlaceOrderInput },
  context: SagaContext
) => {
  const saga = new SagaOrchestrator('place-order', context.logger);

  // Define steps with forward and compensating actions
  const steps: SagaStep[] = [
    {
      name: 'reserve-inventory',
      execute: async () => {
        const reservation = await context.inventoryService.reserve({
          productId: input.productId,
          quantity: input.quantity,
          orderId: saga.sagaId,
        });
        return { reservationId: reservation.id };
      },
      compensate: async (stepData: { reservationId: string }) => {
        await context.inventoryService.release(stepData.reservationId);
      },
    },
    {
      name: 'charge-payment',
      execute: async () => {
        const charge = await context.paymentService.charge({
          customerId: input.customerId,
          amount: input.total,
          idempotencyKey: `saga:${saga.sagaId}:payment`,
        });
        return { chargeId: charge.id };
      },
      compensate: async (stepData: { chargeId: string }) => {
        await context.paymentService.refund(stepData.chargeId);
      },
    },
    {
      name: 'create-order-record',
      execute: async () => {
        const order = await context.repositories.order.create({
          ...input,
          sagaId: saga.sagaId,
        });
        return { orderId: order.id };
      },
      compensate: async (stepData: { orderId: string }) => {
        await context.repositories.order.markCancelled(stepData.orderId, 'saga-rollback');
      },
    },
    {
      name: 'send-confirmation-email',
      execute: async (previousStepData: { orderId: string }) => {
        // Email failure does NOT roll back — it's a best-effort step
        try {
          await context.emailService.sendOrderConfirmation(
            input.customerId,
            previousStepData.orderId
          );
        } catch (err) {
          context.logger.warn({ err }, 'Confirmation email failed — order still created');
        }
        return {};
      },
      compensate: async () => {
        // No compensation for email
      },
    },
  ];

  const result = await saga.execute(steps);

  if (!result.success) {
    return {
      __typename: 'PlaceOrderFailure',
      failedStep: result.failedStep,
      error: result.error,
      compensationStatus: result.compensationStatus,
    };
  }

  return {
    __typename: 'PlaceOrderSuccess',
    orderId: result.stepData['create-order-record'].orderId,
  };
};
```

Schema for the saga mutation:

```graphql
union PlaceOrderResult =
  | PlaceOrderSuccess
  | PlaceOrderFailure

type PlaceOrderSuccess {
  orderId: ID!
  order: Order!
}

type PlaceOrderFailure {
  failedStep: String!
  error: String!
  compensationStatus: CompensationStatus!
}

enum CompensationStatus {
  FULLY_COMPENSATED
  PARTIALLY_COMPENSATED
  COMPENSATION_FAILED
}
```

### Trade-offs

| Gain | Cost |
|---|---|
| Distributed mutations have compensating rollback | Significant implementation complexity |
| Each step is observable and logged | Eventual consistency — saga state must be persisted for recovery after crash |
| Schema expresses the possible outcomes clearly | Idempotency keys required for every service call (replayability) |

### When to Use

- Multi-step mutations that cross service boundaries where partial failure requires rollback
- Financial or inventory operations where consistency is a business requirement

### When Not to Use

- Single-service mutations — use database transactions instead
- Simple two-step operations where the second step is idempotent and self-healing

---

## Pattern 7: Circuit Breaker in Resolvers

### Problem

The Reviews subgraph calls a Reviews microservice for `product.reviews`. The Reviews microservice experiences a latency spike. Resolvers start queueing, holding database connections and memory. The timeout (30 seconds) fires for each request. The connection pool exhausts. The entire subgraph becomes unavailable — not because Reviews is critical to all queries, but because its slow failure cascades into resource exhaustion.

### Solution

Wrap external service calls in a **circuit breaker** (using `opossum` in Node.js). When the circuit opens, the resolver returns null immediately (partial data) rather than holding resources and waiting for a timeout.

```typescript
// services/ReviewsService.ts
import CircuitBreaker from 'opossum';
import type { HttpClient } from '../http/client';
import type { ReviewsResponse } from '../models/Review';

export class ReviewsService {
  private readonly breaker: CircuitBreaker;

  constructor(private readonly httpClient: HttpClient) {
    // The function to protect
    const fetchReviews = async (productId: string): Promise<ReviewsResponse> => {
      const response = await this.httpClient.get(`/products/${productId}/reviews`);
      if (!response.ok) throw new Error(`Reviews service error: ${response.status}`);
      return response.json();
    };

    this.breaker = new CircuitBreaker(fetchReviews, {
      // Circuit opens when 50% of calls in a 10s window fail
      errorThresholdPercentage: 50,
      // Wait 5 seconds before attempting to close the circuit
      resetTimeout: 5000,
      // Calls that take longer than 2 seconds are treated as failures
      timeout: 2000,
      // Minimum number of calls before calculating error rate
      volumeThreshold: 5,
    });

    // Observability: emit circuit state changes to metrics
    this.breaker.on('open', () => {
      metrics.increment('circuit_breaker.opened', { service: 'reviews' });
    });
    this.breaker.on('close', () => {
      metrics.increment('circuit_breaker.closed', { service: 'reviews' });
    });
    this.breaker.on('halfOpen', () => {
      metrics.increment('circuit_breaker.half_open', { service: 'reviews' });
    });
  }

  async getProductReviews(productId: string): Promise<ReviewsResponse | null> {
    try {
      return await this.breaker.fire(productId);
    } catch (err) {
      // Circuit is open or call failed — return null for graceful degradation
      return null;
    }
  }
}
```

Resolver with circuit breaker — partial data on circuit open:

```typescript
// resolvers/Product.ts
export const ProductResolvers: ProductResolvers = {
  Product: {
    reviews: async (product, args, context) => {
      const result = await context.services.reviews.getProductReviews(product.id);
      if (result === null) {
        // Circuit is open — return empty connection with a flag
        // The error will appear in the errors array via Field-Level Error Isolation
        return null;
      }
      return buildReviewsConnection(result, args);
    },
  },
};
```

PromQL query to alert on circuit breaker opens:

```promql
# Alert when circuit breaker is open for more than 30 seconds
increase(circuit_breaker_opened_total{service="reviews"}[30s]) > 0

# Alert when more than 10% of review resolver calls return null (circuit open)
rate(graphql_field_null_total{field="Product.reviews"}[5m])
  / rate(graphql_field_executions_total{field="Product.reviews"}[5m])
  > 0.1
```

### Trade-offs

| Gain | Cost |
|---|---|
| Downstream failure does not cascade into resource exhaustion | Requires circuit breaker library and configuration per service call |
| Partial data responses remain fast even when downstream is degraded | Circuit state must be monitored — open circuit is a production alert |
| Circuit recovery is automatic — half-open state probes the downstream | Fallback behavior (null) must be acceptable to clients |

### When to Use

- Any resolver that calls an external microservice, third-party API, or cross-subgraph entity
- Any service call with a latency SLA where timeout-based failure is too slow

### When Not to Use

- Direct database queries protected by the database connection pool — the pool's queue mechanism handles back-pressure more appropriately
- Idempotent read queries where retry is preferable to circuit opening

---

## References and Related Topics

- [Chapter 07: Apollo Federation v2](../07-federation/README.md) — federation mechanics underlying federation patterns
- [Chapter 14: Observability](../14-observability/README.md) — instrumentation for circuit breakers and saga state tracking
- [Chapter 26: Production Failure Scenarios](../26-production-failure-scenarios/README.md) — what happens when integration patterns are absent
- [Chapter 29: Anti-Patterns](../29-anti-patterns/README.md) — common integration mistakes to avoid
- Martin Fowler, [Saga Pattern](https://martinfowler.com/articles/patterns-of-distributed-systems/saga.html)
- Netflix, [Hystrix Circuit Breaker](https://github.com/Netflix/Hystrix/wiki/How-it-Works)
- [opossum](https://nodeshift.dev/opossum/) — Node.js circuit breaker library
