# Entity Cache Configuration — Apollo Router with Redis

Companion docs: `../../docs/17-caching-strategies/`

Entity caching is the highest-leverage Redis integration for Apollo Federation. Rather than caching entire query responses (which are unique per query shape), entity caching stores the resolved representation of individual federated entities. Any subsequent query that touches the same entity — regardless of the surrounding query shape — gets a cache hit. On a platform with 50 query shapes that all reference the same `Product` entity, a single cache warm-up serves all 50.

---

## What Entity Caching Does

In Federation, when a downstream subgraph needs to resolve fields on an entity owned by another subgraph, the Router constructs a `_entities` query and sends it to the owning subgraph. For example:

```graphql
# Router sends this to the Products subgraph to resolve Product fields
# referenced in a query that originates from the Orders subgraph:
query {
  _entities(representations: [{ __typename: "Product", id: "prod-999" }]) {
    ... on Product {
      name
      price
      stockLevel
    }
  }
}
```

Without entity caching, every query that touches `Product:prod-999` triggers this subgraph fetch. With entity caching enabled, the Router checks Redis first. If the entity is cached, the subgraph is never called.

This has asymmetric value: entities that are read frequently but updated rarely (products, categories, configuration) have very high cache hit rates. Entities that are per-user or high-write (shopping carts, notifications) should use shorter TTLs or be excluded from caching.

---

## Complete `router.yaml` Entity Caching Config

```yaml
# router.yaml
# Entity caching configuration for Apollo Router 1.40+
# Reference: https://www.apollographql.com/docs/router/configuration/entity-caching

entity_caching:
  # Master switch for the feature. Set to false to disable globally
  # without removing the config (useful for debugging cache-related issues).
  enabled: true

  redis:
    # Redis connection URLs. Provide multiple URLs when using Redis Cluster;
    # the Router will use cluster-aware connection logic and hash-slot routing.
    # For a single Redis instance (dev only), use a single-element array.
    # Production must use either Cluster or Sentinel (see redis-topology.md).
    urls:
      - "${REDIS_URL_1}"   # e.g., redis://redis-0.cache.svc.cluster.local:6379
      - "${REDIS_URL_2}"   # e.g., redis://redis-1.cache.svc.cluster.local:6379
      - "${REDIS_URL_3}"   # e.g., redis://redis-2.cache.svc.cluster.local:6379

    # Use rediss:// (with double-s) for TLS connections. Required in production.
    # For AWS ElastiCache with in-transit encryption enabled, use rediss://.
    # Example: - "rediss://:${REDIS_AUTH_TOKEN}@cluster.abc.cache.amazonaws.com:6379"

    # Global default TTL (time-to-live) for all cached entities, in seconds.
    # 300 seconds (5 minutes) is a reasonable starting point for most entities.
    # Override per-subgraph below for entities with different staleness tolerances.
    # Setting this too high increases the risk of serving stale data after writes.
    # Setting this too low reduces hit rates and increases subgraph load.
    ttl: 300

    # How long the Router waits for a Redis operation before giving up.
    # If Redis is unavailable or slow, the Router must not block query execution.
    # A 2ms timeout ensures that a Redis failure degrades to cache misses,
    # not to query timeouts. The Router continues the request without the cache.
    timeout:
      milliseconds: 2

    # Connection pool configuration. The Router maintains a pool of connections
    # to Redis to avoid per-request connection overhead.
    connection_pool:
      # Maximum number of simultaneous Redis connections from this Router instance.
      # In a Kubernetes deployment with 3 Router replicas, total connections to Redis
      # will be (3 replicas * pool_size). Keep this below the Redis maxclients limit.
      pool_size: 20

      # How long to wait for a connection from the pool before failing.
      # If all pool connections are in use, new requests wait up to this duration.
      # 1ms is intentionally tight — if all 20 connections are busy, something
      # is wrong and we should fail fast rather than queue indefinitely.
      wait_timeout:
        milliseconds: 1

  # Per-subgraph TTL overrides. These take precedence over the global TTL.
  # Use these to tune caching behavior per entity type without touching the
  # global default.
  subgraph:
    products:
      # Products change infrequently (price updates happen in batch jobs at midnight,
      # stock levels are eventually consistent anyway). 10 minutes is safe.
      ttl: 600

    users:
      # User profile data (name, email, avatar) is more sensitive and changes
      # more often than products. Use a shorter TTL.
      # NOTE: For fields like payment methods or addresses, configure
      # @cacheControl(scope: PRIVATE) — see the per-user caching section below.
      ttl: 60

    orders:
      # Orders are actively mutated (status changes, payment updates).
      # Very short TTL; alternatively, disable entity caching for this subgraph.
      ttl: 10

    categories:
      # Categories are a near-static taxonomy. Long TTL is appropriate.
      # Invalidate explicitly when a category hierarchy changes.
      ttl: 3600

    inventory:
      # Real-time stock counts must not be cached too aggressively.
      # If a product goes out of stock, users should see that quickly.
      ttl: 15

  # Cache invalidation configuration.
  # The Router supports invalidating cached entities via its admin API.
  invalidation:
    # Enable the invalidation endpoint on the Router's admin port.
    # The admin port (default 8088) should NOT be exposed outside the cluster.
    enabled: true

    # Shared secret for invalidation API requests. Requests without a matching
    # X-Invalidation-Token header are rejected. Store in a Kubernetes Secret.
    shared_key: "${ENTITY_CACHE_INVALIDATION_KEY}"

    # Listen on the admin port for invalidation requests. Default: 8088.
    listen: "0.0.0.0:8088"
```

---

## Cache Key Anatomy

Understanding the cache key structure is critical for debugging, designing invalidation strategies, and reasoning about cache isolation.

A cached entity key has this shape:

```
router:entity:{subgraph-name}:{TypeName}:{serialized-key-fields}
```

For a `Product` entity with `@key(fields: "id")`:

```
router:entity:products:Product:{"id":"prod-999"}
```

For a `User` entity with a compound key `@key(fields: "orgId userId")`:

```
router:entity:users:User:{"orgId":"org-42","userId":"user-7"}
```

For Redis Cluster, hash tags are added automatically to ensure key placement in a predictable slot:

```
{router:entity:products:Product}:{"id":"prod-999"}
```

### What is NOT in the cache key by default

The following information is deliberately excluded from the default cache key:

| Excluded field | Reason |
|---------------|--------|
| `Authorization` header | Including auth in cache keys would make the cache per-user, destroying hit rates for public entities |
| `Cookie` header | Same as above |
| `x-user-id` header | Auth context should not pollute entity cache keys unless explicitly required |
| Query variables beyond `@key` fields | The entity cache stores the entity representation, not the query result |
| Requested field set | All fields of the entity are cached, not just the fields requested in this query |

### Security Implication: Shared Entity Cache

Because auth context is not in the cache key, the entity cache is shared across all users by default. This is the correct behavior for public entities. For entities containing private data, you must configure `@cacheControl(scope: PRIVATE)` — see the next section.

Example of the risk: if `User:42` contains a field `creditCardLastFour`, and `User:42` is in the shared entity cache, any authenticated user whose query touches `User:42` will receive the same cached response — including Alice's credit card digits served to Bob if Bob's query somehow accesses `User:42`.

The safeguard: `@cacheControl(scope: PRIVATE)` causes the Router to include the session identifier in the cache key, making it per-user. Alternatively, mark sensitive entity types as uncacheable: `@cacheControl(maxAge: 0)`.

---

## Per-User vs Shared Caching

### Public entities (default behavior)

No extra config needed. The entity cache is shared. All users resolving `Product:prod-999` get the same cached result.

```graphql
# products subgraph schema
type Product @key(fields: "id") {
  id: ID!
  name: String!
  price: Float!
  description: String
  # No @cacheControl directive = uses global TTL from router.yaml
}
```

### Private entities (per-user caching)

Add `@cacheControl(scope: PRIVATE)` to the entity type. The Router includes the session ID in the cache key, creating per-user cache partitions.

```graphql
# users subgraph schema
type User @key(fields: "id") @cacheControl(maxAge: 60, scope: PRIVATE) {
  id: ID!
  email: String!
  displayName: String
  # These fields are safe to include because scope: PRIVATE partitions by session
  billingAddress: Address
  paymentMethods: [PaymentMethod!]
}
```

With `scope: PRIVATE`, the cache key becomes:

```
router:entity:users:User:{session-id}:{"id":"user-42"}
```

This means each user has their own cached copy of their `User` entity. Hit rates are lower (a cold cache for every new user) but data isolation is guaranteed.

### Uncacheable entities

For entities that must never be cached (real-time stock, active sessions, feature flags that must be instantly updated):

```graphql
type CartItem @key(fields: "id") @cacheControl(maxAge: 0) {
  id: ID!
  quantity: Int!
  # maxAge: 0 tells the Router this entity cannot be cached
}
```

---

## Cache Invalidation

### Invalidating a specific entity

When a product is updated via a mutation in the Products service, the service should notify the Router to invalidate the cached entity:

```bash
# HTTP POST to the Router admin port (8088) — internal cluster traffic only
curl -X POST http://router-admin.router.svc.cluster.local:8088/invalidate/entity \
  -H "Content-Type: application/json" \
  -H "X-Invalidation-Token: ${ENTITY_CACHE_INVALIDATION_KEY}" \
  -d '{
    "subgraph": "products",
    "type": "Product",
    "key": { "id": "prod-999" }
  }'
```

### Invalidating all entities of a type

After a bulk product import or price update job:

```bash
curl -X POST http://router-admin.router.svc.cluster.local:8088/invalidate/entity \
  -H "Content-Type: application/json" \
  -H "X-Invalidation-Token: ${ENTITY_CACHE_INVALIDATION_KEY}" \
  -d '{
    "subgraph": "products",
    "type": "Product"
  }'
```

### Invalidation via Redis directly (emergency use only)

If the Router admin API is unavailable:

```bash
# Delete all Product entity cache entries (use with caution in production)
redis-cli --scan --pattern "router:entity:products:Product:*" | xargs redis-cli del
```

This approach is not transactional and should be considered a last resort. Prefer the admin API.

---

## Metrics

Apollo Router exposes Prometheus metrics for entity cache performance. Configure the following dashboards:

### Key metrics

| Metric | Labels | Target |
|--------|--------|--------|
| `apollo_router_cache_hit_count_total` | `storage=redis, type=entity, subgraph=<name>` | > 80% hit rate for product/category entities |
| `apollo_router_cache_miss_count_total` | `storage=redis, type=entity, subgraph=<name>` | < 20% for stable entities |
| `apollo_router_cache_storage_type` | `storage=redis` | Must always be `redis` in production |
| `apollo_router_cache_operation_duration` | `operation=get/set` | P99 < 2ms |

### Calculating hit rate

```
hit_rate = cache_hit_count / (cache_hit_count + cache_miss_count)
```

Alert if hit rate for the `products` subgraph drops below 70% — this indicates either a TTL that is too short, a Redis availability issue, or a schema change that is invalidating keys unexpectedly.

### Grafana query examples

```promql
# Entity cache hit rate per subgraph (5-minute window)
rate(apollo_router_cache_hit_count_total{type="entity"}[5m])
/
(
  rate(apollo_router_cache_hit_count_total{type="entity"}[5m])
  + rate(apollo_router_cache_miss_count_total{type="entity"}[5m])
)
```

---

## Redis Cluster Mode

### Why single-node Redis is unacceptable for production

Single-node Redis is a single point of failure. If the Redis node restarts, reboots, or encounters a network partition:
- The entire entity cache is lost simultaneously
- All in-flight requests become cache misses
- The sudden traffic spike hits all subgraphs at once — this is a cache stampede
- Recovery time is proportional to cache warm-up time, which can be minutes

### Redis Cluster URL format

```yaml
entity_caching:
  redis:
    urls:
      # TLS-disabled (development or internal cluster with no TLS requirement)
      - "redis://redis-0.cache.svc.cluster.local:6379"
      - "redis://redis-1.cache.svc.cluster.local:6379"
      - "redis://redis-2.cache.svc.cluster.local:6379"

      # TLS-enabled with password auth (production, AWS ElastiCache)
      # - "rediss://:${REDIS_AUTH_TOKEN}@master.my-cluster.abc123.use1.cache.amazonaws.com:6379"
```

The Router uses cluster-aware client logic when multiple URLs are provided. It discovers the full cluster topology from the provided seed nodes and routes commands to the correct hash slot.

### Hash tag design for cluster key locality

When using Redis Cluster, related keys can be forced onto the same hash slot using hash tags: `{tag}`. This is relevant for batch operations (e.g., invalidating all entities for a given `orgId`):

```
# Without hash tag — key distributes to any of 16384 slots
router:entity:products:Product:{"id":"prod-999"}

# With hash tag — all Product entities land on the same slot
# (used when you need SCAN or atomic operations across entity keys)
{router:entity:products:Product}:{"id":"prod-999"}
```

Apollo Router applies hash tags automatically. If you need to perform manual Redis operations (e.g., bulk invalidation via SCAN), use the hash tag pattern to avoid cross-slot operations, which are unsupported in Redis Cluster.

---

## Key Design Decisions

1. **TTL per subgraph, not per field.** Apollo Router's entity caching TTL is configured at the subgraph granularity, not per individual entity type or field. This is a current limitation. If you need field-level TTL control, implement `@cacheControl` in the subgraph schema and rely on the response cache (layer 4) for that granularity.

2. **Cache miss behavior: fail open.** The Router is configured with a 2ms Redis timeout and will serve requests without caching if Redis is unavailable. This is intentional: a Redis outage degrades to increased subgraph load, not user-facing errors. The alternative — failing closed — would make every request fail whenever Redis is down, which is unacceptable.

3. **No auth context in entity cache keys by default.** This maximizes hit rates for public entities at the cost of requiring explicit `@cacheControl(scope: PRIVATE)` for private entities. The mental model is opt-in privacy, not opt-out. Every team adding an entity type must explicitly declare its caching scope.

4. **Admin invalidation API over Redis SCAN.** Direct Redis key manipulation is fragile (key format can change across Router versions) and non-transactional. The Router admin API provides a stable interface for invalidation and is the supported path.

5. **Cluster mode required for production.** See the Redis Cluster section above. The cost of a cache stampede from single-node Redis failure outweighs the operational simplicity of single-node deployment.

---

## Related Documentation

- `../../docs/17-caching-strategies/` — full conceptual overview of caching layers
- `../../docs/01-federation-overview/` — how `@key` and `_entities` work in Federation
- `../../examples/02-apollo-router/` — base `router.yaml` configuration
- `../../examples/11-redis-caching/redis-topology.md` — Redis deployment modes
- `../../examples/11-redis-caching/response-cache-patterns.md` — subgraph-level response cache
