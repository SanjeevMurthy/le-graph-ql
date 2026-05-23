# Migrating from REST to GraphQL Federation Incrementally

Companion docs: `../../docs/23-production-case-studies/`, `../../docs/04-resolvers-and-execution/`

---

## 1. Migration Strategy Options

Three migration strategies are used in practice. The right choice depends on the size of the REST API surface, the number of active clients, and the organization's tolerance for risk.

### Option A: Big Bang Migration

Rewrite all REST endpoints as GraphQL resolvers in one release. Cut over all clients at once.

**When it works:** Greenfield system with no real production traffic. Internal API with a single client team that can coordinate the cutover.

**Why it fails for most organizations:** It requires freezing REST API development during the migration period (often 3-6 months for a mature API). It exposes all clients to migration risk simultaneously. Any schema design mistake affects the entire API surface. Post-migration debugging is harder because everything changed at once.

**Recommendation:** Only for new systems or very small APIs with fewer than 5 endpoints and 1-2 clients.

### Option B: Strangler Fig (Recommended)

Add GraphQL endpoints incrementally, migrating one domain at a time. REST and GraphQL run in parallel. Clients migrate feature-by-feature on their own schedule. REST endpoints are deprecated only after all clients have migrated.

**How it works:** Start with the highest-value domain (usually the core data type: `products`, `users`, `orders`). Wrap the existing REST service as a GraphQL subgraph without touching the REST implementation. Deploy the GraphQL endpoint. Migrate client features one at a time. After all features using a REST endpoint have migrated, deprecate and eventually remove the REST endpoint.

**Timeline:** 6-18 months for a mature API with 10-30 REST resources and 3-5 client teams.

**Recommendation:** The right choice for any API with active production traffic and multiple client teams.

### Option C: Parallel Implementation

Build a complete GraphQL API alongside the existing REST API using the same backing data sources (databases, internal services). Neither wraps the other — both are first-class implementations.

**When it works:** When the REST API has significant technical debt that should not be carried forward. When the GraphQL API will use a different data access pattern (e.g., migrating from a normalized REST API to a more denormalized GraphQL-first data model).

**Cost:** Approximately 2x the implementation effort. Requires careful synchronization between REST and GraphQL to ensure they return consistent data.

---

## 2. Wrapping REST Endpoints as a GraphQL Subgraph

The strangler fig pattern starts with wrapping existing REST endpoints. This is the fastest path to production GraphQL: no data access layer rewrite, no migration risk — just an adapter.

```typescript
// subgraphs/products/src/datasources/products-rest-datasource.ts
import { RESTDataSource } from '@apollo/datasource-rest';
import DataLoader from 'dataloader';

interface RestProduct {
  product_id: string;          // REST uses snake_case; GraphQL uses camelCase
  product_name: string;
  base_price_cents: number;
  category_id: string;
  in_stock: boolean;
  image_urls: string[];
  created_at: string;
  updated_at: string;
}

interface GraphQLProduct {
  id: string;
  name: string;
  price: number;               // Converted from cents to dollars
  categoryId: string;
  inStock: boolean;
  imageUrls: string[];
  createdAt: string;
  updatedAt: string;
}

function mapRestProductToGraphQL(rest: RestProduct): GraphQLProduct {
  return {
    id: rest.product_id,
    name: rest.product_name,
    // REST API stores price in cents; GraphQL schema uses dollars.
    // This conversion happens in the data source, not in the resolver,
    // so the resolver does not need to know about the REST representation.
    price: rest.base_price_cents / 100,
    categoryId: rest.category_id,
    inStock: rest.in_stock,
    imageUrls: rest.image_urls,
    createdAt: rest.created_at,
    updatedAt: rest.updated_at,
  };
}

export class ProductsRestDataSource extends RESTDataSource {
  override baseURL = process.env.PRODUCTS_REST_BASE_URL!;

  // Single product by ID — wraps GET /products/{id}
  async getProduct(id: string): Promise<GraphQLProduct | null> {
    try {
      const rest = await this.get<RestProduct>(`/products/${id}`);
      return mapRestProductToGraphQL(rest);
    } catch (error: any) {
      if (error.extensions?.response?.status === 404) return null;
      throw error;
    }
  }

  // Paginated product list — wraps GET /products?page=N&per_page=N
  // The REST API uses offset pagination; we adapt to cursor pagination here.
  async getProducts(args: {
    first?: number;
    after?: string;
  }): Promise<{ items: GraphQLProduct[]; hasNextPage: boolean }> {
    const perPage = args.first ?? 20;
    // Decode the cursor to get the page number. This is a simplified example;
    // a production cursor should be opaque to clients.
    const page = args.after ? parseInt(Buffer.from(args.after, 'base64').toString(), 10) : 1;

    const response = await this.get<{
      products: RestProduct[];
      total: number;
      page: number;
      per_page: number;
    }>(`/products`, {
      params: { page: String(page), per_page: String(perPage) },
    });

    return {
      items: response.products.map(mapRestProductToGraphQL),
      hasNextPage: page * perPage < response.total,
    };
  }

  // Batch loading multiple products — wraps GET /products?ids=1,2,3
  // The REST API has a batch endpoint; use it to avoid N+1 for DataLoader.
  async getProductsByIds(ids: readonly string[]): Promise<(GraphQLProduct | null)[]> {
    const response = await this.get<{ products: RestProduct[] }>('/products', {
      params: { ids: ids.join(',') },
    });

    const productMap = new Map(
      response.products.map((p) => [p.product_id, mapRestProductToGraphQL(p)])
    );
    // DataLoader requires results in the same order as input ids, null for missing
    return ids.map((id) => productMap.get(id) ?? null);
  }
}

// DataLoader for product entities — uses the batch REST endpoint
// This ensures that even if the REST API doesn't support GraphQL,
// we prevent N+1 queries by batching all product loads in one request.
export function createProductLoader(dataSource: ProductsRestDataSource) {
  return new DataLoader<string, GraphQLProduct | null>(
    (ids) => dataSource.getProductsByIds(ids),
    {
      cache: true,
      maxBatchSize: 100,
    }
  );
}
```

```typescript
// subgraphs/products/src/resolvers.ts
import type { Context } from './context';

export const resolvers = {
  Query: {
    product: async (_: unknown, { id }: { id: string }, ctx: Context) => {
      return ctx.loaders.product.load(id);
    },

    products: async (_: unknown, args: { first?: number; after?: string }, ctx: Context) => {
      return ctx.dataSources.productsRest.getProducts(args);
    },
  },

  Product: {
    // If a REST wrapper subgraph has a field that references another type
    // owned by a different subgraph (e.g., Category), use @external + @requires
    // in the schema or resolve it via the cross-subgraph entity mechanism.
    // See subgraph schema for @key definitions.
    category: async (product: any, _: unknown, ctx: Context) => {
      // This will trigger the categories subgraph entity resolution
      // via Apollo Federation's _entities query — no REST call here.
      return { __typename: 'Category', id: product.categoryId };
    },
  },
};
```

---

## 3. Schema Design from REST Resources

REST and GraphQL have fundamentally different mental models. A 1:1 translation of REST endpoints to GraphQL operations loses most of GraphQL's value. The translation principles are:

### REST Resources to GraphQL Types

| REST Pattern | GraphQL Pattern |
|---|---|
| `GET /users/{id}` | `query { user(id: ID!): User }` |
| `GET /users/{id}/orders` | `query { user(id: ID!) { orders: [Order] } }` or `query { orders(userId: ID!): [Order] }` |
| `POST /users` | `mutation { createUser(input: CreateUserInput!): User }` |
| `PUT /users/{id}` | `mutation { updateUser(id: ID!, input: UpdateUserInput!): User }` |
| `DELETE /users/{id}` | `mutation { deleteUser(id: ID!): DeleteUserResult }` |
| `POST /users/{id}/activate` | `mutation { activateUser(id: ID!): User }` |
| `GET /search?q=...&type=product` | `query { searchProducts(query: String!): SearchResult }` |

### Key Translation Decisions

**Relationships as nested fields, not separate queries:**

REST: A client makes `GET /orders/{id}` then `GET /users/{userId}` to get the order's user.

GraphQL: `query { order(id: ID!) { id items { ... } user { id name email } } }` — the relationship is traversed in one query. This is the core value proposition of GraphQL and should be reflected in the schema design, not suppressed by wrapping REST endpoints.

```graphql
# Weak GraphQL schema — 1:1 REST mapping, loses relationship value
type Query {
  order(id: ID!): Order
  userById(id: ID!): User  # REST: GET /users/{id}
}

type Order {
  id: ID!
  userId: ID!  # Client must make a second query to get the user — REST mentality
}

# Strong GraphQL schema — relationships as nested fields
type Query {
  order(id: ID!): Order
}

type Order {
  id: ID!
  user: User!  # Client gets user in the same query
}
```

**Input types for mutations:**

REST uses the request body directly. GraphQL uses `input` types, which provide type safety and documentation. Define one `input` type per mutation rather than accepting individual arguments.

```graphql
# REST: POST /orders with body { productId, quantity, shippingAddressId }
# GraphQL:
mutation CreateOrder($input: CreateOrderInput!) {
  createOrder(input: $input) {
    id
    status
    total { amount currency }
  }
}

input CreateOrderInput {
  productId: ID!
  quantity: Int!
  shippingAddressId: ID!
  couponCode: String   # Optional — REST might have used a separate endpoint
}
```

---

## 4. Running REST and GraphQL in Parallel

The strangler fig pattern requires both interfaces to serve the same data. This parallel period is typically 3-12 months depending on team size and API surface.

### Feature Flag Strategy

Client teams switch from REST to GraphQL on a per-feature basis using feature flags. This allows incremental migration with rollback capability.

```typescript
// In a React client app
import { useFeatureFlag } from '@company/feature-flags';
import { useQuery, gql } from '@apollo/client';

const GET_PRODUCT_GRAPHQL = gql`
  query GetProduct($id: ID!) {
    product(id: $id) {
      id name price
      category { name }
      reviews(first: 5) { id rating body }
    }
  }
`;

function ProductPage({ productId }: { productId: string }) {
  const useGraphQL = useFeatureFlag('product-page-use-graphql');

  if (useGraphQL) {
    return <ProductPageGraphQL productId={productId} />;
  }
  return <ProductPageREST productId={productId} />;
}
```

### Tracking Migration Progress

Track which product features have been migrated from REST to GraphQL. This data drives the REST deprecation timeline.

```typescript
// scripts/migration-tracker.ts
// Generates a report of REST endpoint usage vs GraphQL operation coverage.

interface MigrationStatus {
  endpoint: string;
  method: string;
  totalCallsLast30Days: number;
  graphqlEquivalent?: string;
  clientsMigrated: number;
  clientsRemaining: number;
  safeToDeprecate: boolean;
}

// In practice, this data comes from:
// - REST: API gateway access logs (count calls per endpoint)
// - GraphQL: Apollo Studio operation counts
// - Client tracking: manually maintained or inferred from the feature flags
```

---

## 5. Client Migration — Fragment Colocation Advantage

When clients migrate from REST to GraphQL, the most important architectural improvement they can make is adopting fragment colocation. REST clients typically fetch the entire resource and let each component pick the fields it needs. GraphQL with colocated fragments allows each component to declare exactly what it needs.

### Before: REST (Over-fetching)

```typescript
// REST: fetch the entire user object, each component picks fields
async function loadUser(id: string) {
  const response = await fetch(`/api/users/${id}`);
  return response.json(); // Returns 30 fields; most components use 3-5
}

function UserAvatar({ userId }: { userId: string }) {
  const user = useUser(userId); // Gets all 30 fields
  return <img src={user.avatarUrl} alt={user.name} />;
  // Uses only avatarUrl and name — 28 fields wasted
}
```

### After: GraphQL with Fragment Colocation

```typescript
// GraphQL: each component declares its own data requirements
const USER_AVATAR_FRAGMENT = gql`
  fragment UserAvatar on User {
    id
    avatarUrl
    name
  }
`;

function UserAvatar({ user }: { user: UserAvatarFragment }) {
  return <img src={user.avatarUrl} alt={user.name} />;
}

// The parent query includes the fragment — the network request only
// fetches the fields that components actually use
const GET_USER_PROFILE_PAGE = gql`
  query GetUserProfilePage($id: ID!) {
    user(id: $id) {
      ...UserAvatar
      ...UserBio
      ...UserStats
    }
  }
  ${USER_AVATAR_FRAGMENT}
  ${USER_BIO_FRAGMENT}
  ${USER_STATS_FRAGMENT}
`;
```

Fragment colocation is not just a performance optimization — it is a maintainability improvement. When a component's data requirements change, only that component's fragment needs to change. REST clients tend to add more fields to the fetch-all pattern over time, increasing over-fetching monotonically.

**Migration without a flag day:** Migrate each component's data requirement to a fragment independently. The parent query starts with the REST-equivalent full-object fetch and gradually replaces it with fragment-composed requests. No single "cutover" event is required.

---

## 6. Deprecating the REST API

REST endpoint deprecation follows a four-phase process. Never deprecate immediately after GraphQL launch; confirm actual migration with data first.

### Phase 1: Instrument (Week 0 — At GraphQL Launch)

Add response headers to every REST endpoint that has a GraphQL equivalent:

```typescript
// Express middleware — add to all REST routes with GraphQL equivalents
app.use((req, res, next) => {
  const deprecationMap: Record<string, { graphqlField: string; removeDate: string }> = {
    'GET /api/v1/products/:id': {
      graphqlField: 'Query.product',
      removeDate: '2025-06-01',
    },
    'GET /api/v1/products': {
      graphqlField: 'Query.products',
      removeDate: '2025-06-01',
    },
  };

  const key = `${req.method} ${req.route?.path}`;
  const deprecation = deprecationMap[key];

  if (deprecation) {
    // RFC 8594 Sunset header — the date after which the API will not be available
    res.set('Sunset', new Date(deprecation.removeDate).toUTCString());
    // RFC 8594 Deprecation header
    res.set('Deprecation', 'true');
    res.set(
      'Link',
      `<https://developers.example.com/graphql>; rel="successor-version"`
    );
    res.set('X-GraphQL-Equivalent', deprecation.graphqlField);
  }

  next();
});
```

### Phase 2: Identify Last Callers (Ongoing)

Parse API gateway access logs to identify clients still calling REST endpoints after the deprecation notice:

```bash
# Find unique callers of a deprecated REST endpoint in the last 7 days
# Assumes AWS ALB access logs format
grep "GET /api/v1/products" access.log \
  | awk '{print $3}' \              # Extract client IP
  | sort | uniq -c | sort -rn \     # Count and sort
  | head -20
```

For authenticated endpoints, the access log includes the user or service account making the request. Reach out directly to the remaining callers with migration help.

### Phase 3: Traffic Monitoring (Last 30 Days Before Removal)

Set up an alert for any traffic to the endpoint after the grace period:

```yaml
# cloudwatch-alarm.yaml
MetricAlarmConfig:
  AlarmName: "deprecated-rest-products-still-receiving-traffic"
  MetricName: "RequestCount"
  Namespace: "AWS/ApplicationELB"
  Dimensions:
    - Name: "TargetGroup"
      Value: "rest-api-products"
  Threshold: 0
  ComparisonOperator: "GreaterThanThreshold"
  TreatMissingData: "notBreaching"
  AlarmActions:
    - !Ref PlatformTeamSNSTopic
```

### Phase 4: Removal

Remove the REST route after the Sunset date. Monitor for a 24-hour spike in errors from any callers that missed the migration (they will receive a 404; their error logs will surface the issue).

---

## 7. Common Mistakes in REST-to-GraphQL Migrations

**Mistake 1: 1:1 mapping of REST endpoints to root-level GraphQL fields**

```graphql
# Anti-pattern: REST-shaped GraphQL
type Query {
  getUserById(id: ID!): User
  getUserOrders(userId: ID!): [Order]  # Should be User.orders
  getUserProfile(userId: ID!): Profile  # Should be User.profile
}
```

This loses GraphQL's core value: traversing relationships in a single query. Clients still make multiple queries for related data, which means they get none of the round-trip reduction benefit.

**Mistake 2: Keeping the REST data source as permanent architecture**

Wrapping REST endpoints in a subgraph is a transitional pattern, not a final state. Once the REST service is mature and the migration window closes, the subgraph should be refactored to access the database or internal service directly. Permanent REST wrapping adds a network hop on every request, adds a dependency on the REST API's availability, and prevents the subgraph from fully leveraging DataLoader.

Set a 12-month deadline from initial REST-wrapping deployment to direct data source migration.

**Mistake 3: Ignoring DataLoader during the REST wrapping phase**

REST data sources can use DataLoader if the REST API has a batch endpoint. If no batch endpoint exists, the DataLoader batch function must fall back to parallel individual requests (`Promise.all`). Even this is better than serial requests. Skipping DataLoader entirely during the REST wrapping phase means the new GraphQL API is slower than the REST API it replaced — the worst possible outcome for building confidence in the migration.

**Mistake 4: Migrating too many clients at once**

The strangler fig works because it allows rollback at the feature level. Migrating all clients simultaneously converts the migration from low-risk/incremental to high-risk/big-bang. Enforce the one-feature-at-a-time discipline even when clients are eager to migrate everything quickly.

**Mistake 5: Designing the GraphQL schema to match the REST response shape**

REST responses are shaped for over-the-wire transfer. GraphQL schemas are shaped for the client's usage patterns. A REST API that returns `{ "user_id": "123", "full_name": "Jane Smith" }` should become `type User { id: ID! name: String! }` — not a verbatim copy of the REST field names. Take the opportunity to improve the naming and structure.

---

## Key Design Decisions

**Why the strangler fig over the parallel implementation:** The parallel implementation requires 2x the implementation effort and creates a data consistency risk — two code paths reading the same data can return different results for the same request if there is any logic difference between them. The strangler fig keeps the data access layer unchanged (same REST API) and only adds an adapter layer. The risk profile is much lower.

**Why use `RESTDataSource` rather than `node-fetch` directly:** `RESTDataSource` provides automatic request deduplication (if the same URL is fetched twice in the same request, only one HTTP call is made), a consistent interface for passing authentication headers, and built-in response caching with proper cache-control header support. These are non-trivial to implement correctly with raw `node-fetch`.

**Why add the `Deprecation` and `Sunset` headers at REST launch rather than later:** Deprecation header awareness requires clients to update their HTTP client to log or alert on these headers. If the headers are added late in the process (after GraphQL is stable), clients have less time to instrument them. Adding the headers at GraphQL launch maximizes the observation window for migration tracking.

---

## Related Documentation

- `../../docs/04-resolvers-and-execution/` — DataLoader patterns and resolver design that apply equally to REST-wrapped and database-direct data sources
- `../../docs/11-ci-cd-automation/` — CI/CD pipeline setup for managing both REST and GraphQL deployments during the migration window
- `../../docs/08-supergraph-architecture/` — Apollo Federation entity model that enables cross-subgraph relationship traversal (the key benefit of migrating from REST)
- `../../docs/09-schema-governance/` — Schema design principles for designing GraphQL schemas that are not just REST in a GraphQL wrapper
