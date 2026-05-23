# Response Cache Patterns — Subgraph-Level GraphQL Caching

Companion docs: `../../docs/17-caching-strategies/`

Subgraph response caching complements Router entity caching by caching complete GraphQL responses at the subgraph boundary. This is most effective for queries that return public, read-heavy data — product listings, article feeds, category trees — where the same query with the same variables will return the same result for many users.

This document covers `@apollo/server-plugin-response-cache` with Redis via Keyv, session-keyed private caching, cache invalidation by tag, and cache stampede prevention.

---

## `@cacheControl` Directive

The `@cacheControl` directive is the declarative interface for declaring caching hints in a GraphQL schema. Hints are set on types and fields and flow upward through the query — the response plugin reads these hints to determine the TTL and scope of the cached response.

### Declaring cache hints in SDL

```graphql
# products subgraph — schema.graphql

# Cache product data for 10 minutes.
# scope: PUBLIC means this data is safe to share across all users.
type Product @key(fields: "id") @cacheControl(maxAge: 600, scope: PUBLIC) {
  id: ID!
  name: String!
  description: String
  price: Float!

  # This field makes a real-time inventory call. Override the type-level TTL
  # with a much shorter value so inventory accuracy degrades gracefully.
  stockLevel: Int @cacheControl(maxAge: 15)

  # Reviews are user-generated and updated more often than product data.
  # Override to a 2-minute TTL.
  reviews: [Review!] @cacheControl(maxAge: 120)
}

# A category is near-static taxonomy. Long TTL is appropriate.
type Category @cacheControl(maxAge: 3600, scope: PUBLIC) {
  id: ID!
  name: String!
  slug: String!
  parentCategory: Category
}

# User order history is private. scope: PRIVATE means the cache key includes
# the session ID, creating per-user cache partitions.
type Order @cacheControl(maxAge: 60, scope: PRIVATE) {
  id: ID!
  status: OrderStatus!
  total: Float!
  items: [OrderItem!]
}

# Queries on the root type also participate in cache hint propagation.
type Query {
  product(id: ID!): Product         # Inherits Product type hint: maxAge 600
  products(category: ID): [Product] # Inherits Product type hint: maxAge 600
  featuredProducts: [Product]       # Can be explicitly overridden here too

  # Explicitly mark as uncacheable (real-time search results must not be cached)
  searchProducts(query: String!): [Product] @cacheControl(maxAge: 0)
}
```

### How `maxAge` propagates through a query

The response plugin selects the **minimum** `maxAge` across all types and fields touched by the query. This is the conservative behavior: a single field with `maxAge: 0` makes the entire response uncacheable, even if every other field in the response has a long TTL.

```graphql
# This query touches Product (maxAge: 600) and stockLevel (maxAge: 15)
query GetProduct($id: ID!) {
  product(id: $id) {
    name        # Product.name — inherits type maxAge: 600
    price       # Product.price — inherits type maxAge: 600
    stockLevel  # Explicit maxAge: 15 on this field
  }
}
# Effective response maxAge: min(600, 600, 600, 15) = 15 seconds
```

```graphql
# This query does NOT include stockLevel — longer TTL applies
query GetProductDetails($id: ID!) {
  product(id: $id) {
    name
    description
    price
  }
}
# Effective response maxAge: 600 seconds
```

Design schemas with cache TTL in mind. A high-cardinality field with a short TTL will drag down the effective TTL of every query that includes it.

---

## Apollo Server Response Cache Plugin — Full Setup

### Dependencies

```bash
npm install @apollo/server \
  @apollo/server-plugin-response-cache \
  @apollo/utils.keyvadapter \
  keyv \
  @keyv/redis
```

### TypeScript setup — `src/server.ts`

```typescript
import { ApolloServer } from '@apollo/server';
import { startStandaloneServer } from '@apollo/server/standalone';
import responseCachePlugin from '@apollo/server-plugin-response-cache';
import { KeyvAdapter } from '@apollo/utils.keyvadapter';
import Keyv from 'keyv';
import KeyvRedis from '@keyv/redis';

// --- Cache store setup ---

// KeyvRedis creates a Redis-backed store for the Keyv adapter.
// The namespace prefix ('gql-cache') ensures response cache keys do not
// collide with other Redis keys (entity cache, APQ cache, application data).
const keyvRedis = new KeyvRedis(process.env.REDIS_URL!, {
  // Use a key prefix so all response cache entries can be scanned/deleted
  // as a group without touching unrelated Redis keys.
  keyPrefix: 'gql-cache:',
});

keyvRedis.on('error', (err) => {
  // Log but do not throw — cache errors should degrade gracefully, not crash the server.
  // The Apollo Server response cache plugin handles Keyv errors by falling through
  // to the resolver without caching.
  console.error('Redis cache error:', err);
});

// KeyvAdapter wraps the Keyv instance to conform to the KeyValueCache interface
// expected by @apollo/server-plugin-response-cache.
const redisCache = new KeyvAdapter(new Keyv({ store: keyvRedis }));

// --- Context type ---

interface MyContext {
  // The user ID extracted from the validated JWT. Populated by the context function below.
  // Null for unauthenticated requests (public queries).
  userId: string | null;
  // Roles from the JWT claims — used by field-level authorization in resolvers.
  userRoles: string[];
  // The full request object — needed for IP-based rate limiting and logging.
  req: import('http').IncomingMessage;
}

// --- Server setup ---

const server = new ApolloServer<MyContext>({
  typeDefs,  // Your schema definitions — loaded from subgraph SDL files
  resolvers,

  plugins: [
    responseCachePlugin<MyContext>({
      // sessionId is called for every incoming request. Return a string that
      // uniquely identifies the user session, or null for public requests.
      //
      // When sessionId returns null, the response is eligible for the shared
      // public cache (scope: PUBLIC entries). When it returns a non-null string,
      // the cache key includes the session ID, creating a per-user partition
      // for scope: PRIVATE entries.
      //
      // IMPORTANT: If you return the raw JWT as the session ID, Redis will contain
      // one cache entry per unique JWT — JWTs rotate on refresh, causing cache thrash.
      // Use the stable user ID from JWT claims, not the JWT string itself.
      sessionId: (requestContext) => {
        return requestContext.contextValue.userId ?? null;
      },

      // shouldReadFromCache is called before the resolver runs.
      // Return false to bypass the cache for specific requests (e.g., mutations,
      // or requests with cache-busting query params).
      shouldReadFromCache: async (requestContext) => {
        // Never read from cache for mutations — mutations have side effects
        // and must always execute against the data source.
        if (requestContext.request.operationName?.toLowerCase().includes('mutation')) {
          return false;
        }
        // Respect an explicit cache-bypass header for debugging (internal use only).
        const bypassHeader = requestContext.request.http?.headers.get('x-bypass-cache');
        if (bypassHeader === 'true') {
          return false;
        }
        return true;
      },

      // shouldWriteToCache is called after the resolver runs but before the response
      // is sent. Return false to prevent caching this specific response.
      shouldWriteToCache: async (requestContext) => {
        // Do not cache responses that contain errors — partial data with errors
        // should not be served to subsequent users.
        if (requestContext.errors && requestContext.errors.length > 0) {
          return false;
        }
        // Do not cache null data responses — these often indicate resolver errors
        // that did not surface as explicit GraphQL errors.
        if (requestContext.response.body.kind === 'single' &&
            requestContext.response.body.singleResult.data === null) {
          return false;
        }
        return true;
      },

      // generateCacheKey allows customizing the cache key beyond the default
      // (query document + variables + sessionId). Use this to add dimensions
      // like locale, currency, or A/B test variant to the cache key.
      generateCacheKey: (requestContext, keyData) => {
        const locale = requestContext.request.http?.headers.get('x-locale') ?? 'en-US';
        const currency = requestContext.request.http?.headers.get('x-currency') ?? 'USD';
        // Append locale and currency to the default cache key.
        // The default keyData already contains the hashed query + variables + sessionId.
        return `${keyData}:${locale}:${currency}`;
      },

      // cache specifies which cache store to use. By default, the plugin uses
      // the server's requestContext.cache, but we override to use our Redis store
      // with its dedicated key prefix.
      cache: redisCache,
    }),
  ],
});

const { url } = await startStandaloneServer(server, {
  context: async ({ req }): Promise<MyContext> => {
    // Extract user from the JWT injected by Apollo Router.
    // The Router has already validated the JWT and extracted claims into
    // the x-user-id and x-user-roles headers. Subgraphs trust these headers
    // because they are in the Router's network trust boundary.
    const userId = req.headers['x-user-id'] as string | undefined ?? null;
    const rolesHeader = req.headers['x-user-roles'] as string | undefined ?? '';
    const userRoles = rolesHeader ? rolesHeader.split(',') : [];

    return { userId, userRoles, req };
  },
  listen: { port: 4001 },
});

console.log(`Products subgraph ready at ${url}`);
```

---

## Session-Based Cache Keys

The `sessionId` function is the primary mechanism for creating per-user cache partitions. Understanding its interaction with `@cacheControl` scope is essential.

### Public responses (scope: PUBLIC)

When `sessionId` returns `null` AND the query only touches `scope: PUBLIC` fields, the response is stored in a shared cache partition with no session component in the key:

```
cache key: sha256(query + variables):en-US:USD
```

All users (authenticated and unauthenticated) receive the same cached response. This is correct and expected for product listings, category trees, and public articles.

### Private responses (scope: PRIVATE)

When `sessionId` returns a non-null value AND the query touches any `scope: PRIVATE` field, the response is stored in a per-user partition:

```
cache key: sha256(query + variables + sessionId):en-US:USD
```

Alice and Bob each have their own cache entry for the same query. Their private data cannot cross-contaminate.

### Mixed queries

A query that touches both `scope: PUBLIC` and `scope: PRIVATE` fields is treated as `scope: PRIVATE` — the response cache uses the most restrictive scope in the query.

```graphql
# This query is cached as PRIVATE because Order has scope: PRIVATE
query MyDashboard($userId: ID!) {
  user(id: $userId) {
    name       # scope: PUBLIC
    orders {   # scope: PRIVATE  <-- this makes the entire response PRIVATE
      id
      total
    }
  }
}
```

---

## Cache Invalidation by Tag

The response cache plugin does not have built-in tag-based invalidation, but you can implement it via `generateCacheKey` and Redis SCAN. The pattern: embed a tag in the cache key, then scan and delete all keys matching the tag.

### Adding entity tags to cache keys

```typescript
generateCacheKey: (requestContext, keyData) => {
  // Collect entity IDs mentioned in the query variables.
  // This is a simplified approach — for full coverage, inspect the response
  // data to extract all entity IDs after resolution.
  const productId = requestContext.request.variables?.id as string | undefined;
  const tag = productId ? `product:${productId}` : 'product:all';
  return `${keyData}:${tag}`;
},
```

### Invalidating all cache entries for a product

```typescript
// src/cache/invalidation.ts
import Redis from 'ioredis';

export async function invalidateProductCache(
  redis: Redis,
  productId: string
): Promise<number> {
  const pattern = `gql-cache:*:product:${productId}*`;
  let cursor = '0';
  let deletedCount = 0;

  do {
    // Use SCAN instead of KEYS to avoid blocking Redis during iteration.
    // SCAN is O(N) but non-blocking; KEYS is O(N) and blocks the event loop.
    const [nextCursor, keys] = await redis.scan(
      cursor,
      'MATCH',
      pattern,
      'COUNT',
      100  // Scan 100 keys per iteration — tune based on key count
    );
    cursor = nextCursor;

    if (keys.length > 0) {
      // DEL accepts multiple keys in a single command — more efficient than
      // one DEL per key.
      deletedCount += await redis.del(...keys);
    }
  } while (cursor !== '0');

  return deletedCount;
}
```

This function is called from the Products service mutation resolvers:

```typescript
// In the Products subgraph resolver
Mutation: {
  updateProduct: async (_, { id, input }, context) => {
    const updated = await productRepository.update(id, input);

    // Invalidate the response cache for this product after a successful update.
    // This runs asynchronously — the mutation response is sent to the client
    // immediately without waiting for cache invalidation to complete.
    invalidateProductCache(redis, id).catch((err) => {
      console.error(`Cache invalidation failed for product ${id}:`, err);
      // Do not re-throw — a cache invalidation failure is not a mutation failure.
      // The TTL-based expiry will eventually serve fresh data even if this fails.
    });

    return updated;
  },
}
```

---

## DataLoader and Response Cache Interaction

DataLoader is a request-scoped batch-loading utility. It caches entity lookups within a single request execution cycle. The Redis response cache operates across requests.

### How they interact

```
Request 1: GET /graphql (query: product(id: "A"), product(id: "B"))
  - DataLoader batches: SELECT * FROM products WHERE id IN ('A', 'B')
  - DataLoader in-memory cache: { A: {...}, B: {...} }   <-- valid only for this request
  - Response written to Redis: key=sha256(query)          <-- valid across requests

Request 2: GET /graphql (same query, same variables)
  - Response cache HIT in Redis
  - DataLoader is never called (resolver never runs)
  - DataLoader cache: not used
```

DataLoader's in-memory cache is not useful for caching across requests and is intentionally discarded at the end of each request. The Redis response cache serves that cross-request function.

### DataLoader must be created per-request

A common mistake is creating a single DataLoader instance at module startup (singleton). This causes DataLoader's in-memory cache to persist across requests, which can serve stale data or cross-user data.

```typescript
// WRONG — DataLoader as module singleton (cross-request cache contamination)
const productLoader = new DataLoader((ids) => loadProducts(ids));

// CORRECT — DataLoader created fresh in the context function (per-request)
context: async ({ req }) => ({
  userId: req.headers['x-user-id'] ?? null,
  loaders: {
    // New DataLoader per request — in-memory cache scoped to this request only
    product: new DataLoader((ids: readonly string[]) => loadProducts(ids)),
  },
})
```

---

## Cache Stampede Prevention

A cache stampede (thundering herd) occurs when a popular cache entry expires and many requests arrive simultaneously before the cache is repopulated. All requests find a miss, all execute the resolver, all write the same result — wasting resources and amplifying database load.

### Prevention pattern: SET NX with background revalidation

The pattern: when a cached entry is near expiry, one request acquires a lock and revalidates in the background. Other requests continue to serve the stale value until the fresh value is available.

```typescript
// src/cache/stampede-prevention.ts
import Redis from 'ioredis';

interface CacheResult<T> {
  data: T;
  stale: boolean;
}

export async function getWithStampedeProtection<T>(
  redis: Redis,
  key: string,
  ttlSeconds: number,
  // staleness threshold — if the entry has fewer than staleThreshold seconds remaining,
  // trigger a background refresh while still serving the cached value.
  staleThresholdSeconds: number,
  fetchFresh: () => Promise<T>
): Promise<CacheResult<T>> {
  const raw = await redis.get(key);
  const ttlRemaining = await redis.ttl(key);

  if (raw !== null) {
    const data = JSON.parse(raw) as T;
    const isNearExpiry = ttlRemaining > 0 && ttlRemaining < staleThresholdSeconds;

    if (isNearExpiry) {
      // Attempt to acquire a refresh lock using SET NX (set if not exists).
      // Only one instance will succeed — others skip the background refresh.
      const lockKey = `${key}:refresh-lock`;
      const lockAcquired = await redis.set(
        lockKey,
        '1',
        'EX', 30,  // Lock expires in 30 seconds (prevents lock leakage if refresh fails)
        'NX'       // Only set if the key does not already exist
      );

      if (lockAcquired === 'OK') {
        // We acquired the lock — refresh in the background, do not block this response.
        fetchFresh()
          .then((fresh) => redis.set(key, JSON.stringify(fresh), 'EX', ttlSeconds))
          .catch((err) => console.error('Background cache refresh failed:', err))
          .finally(() => redis.del(lockKey));
      }
    }

    // Return the cached value (possibly stale) immediately.
    return { data, stale: isNearExpiry };
  }

  // Cache miss — fetch fresh and populate.
  const fresh = await fetchFresh();
  await redis.set(key, JSON.stringify(fresh), 'EX', ttlSeconds);
  return { data: fresh, stale: false };
}
```

Usage in a resolver:

```typescript
Query: {
  featuredProducts: async (_, __, context) => {
    const { data } = await getWithStampedeProtection(
      redis,
      'featured-products',
      600,  // 10-minute TTL
      60,   // Start background refresh if TTL drops below 60 seconds
      () => productRepository.findFeatured()
    );
    return data;
  },
}
```

---

## Key Design Decisions

1. **Keyv + KeyvAdapter over ioredis directly.** The `@apollo/server-plugin-response-cache` API requires a `KeyValueCache` interface. Using `KeyvAdapter(new Keyv({ store: keyvRedis }))` provides this interface while keeping the Redis client layer swappable (you can replace KeyvRedis with an in-memory store for tests).

2. **User ID as session key, not raw JWT.** JWTs rotate on token refresh; using the raw JWT string as the session ID creates unbounded cache growth. Using the stable `sub` claim (user ID) from the JWT ensures cache entries are reused across token refreshes.

3. **Async cache invalidation after mutations.** Blocking the mutation response on cache invalidation completion couples mutation latency to Redis performance. Async invalidation allows the mutation to return immediately while the cache is cleaned up in the background. TTL-based expiry serves as the safety net if async invalidation fails.

4. **Error responses are not cached.** Caching an error response and serving it to subsequent users would mask transient failures and make outages appear permanent. The `shouldWriteToCache` hook excludes any response containing errors.

5. **stampede prevention via SET NX, not Redis SETNX.** `SETNX` is a legacy command superseded by `SET key value NX`. The `SET ... NX` form allows setting an expiry atomically in the same command, preventing lock leakage without a separate `EXPIRE` call.

---

## Related Documentation

- `../../docs/17-caching-strategies/` — full caching strategy overview
- `../../examples/11-redis-caching/entity-cache-config.md` — Router-level entity caching
- `../../examples/11-redis-caching/redis-topology.md` — Redis deployment modes
- `../../examples/12-security/jwt-authentication.md` — JWT claim extraction used as session ID
- `../../docs/05-security/` — caching and security interaction (`scope: PUBLIC` vs `scope: PRIVATE`)
