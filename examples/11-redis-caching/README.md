# Redis Caching for GraphQL Federation

Companion docs: `../../docs/17-caching-strategies/`

This directory demonstrates production Redis caching patterns for Apollo Federation v2. GraphQL caching is not a single layer — it is a stack of complementary caches operating at different granularities, from individual resolved entities all the way down to raw HTTP response bytes. Getting this wrong leads to stale data for users, or worse, serving one user's private data to another.

---

## The Four Caching Layers

A production Apollo Federation stack has four distinct places where Redis adds value. Understanding where each cache sits, what it stores, and how it gets invalidated is the prerequisite for configuring any of them correctly.

```
Client
  |
  v
+---------------------------+
|     Apollo Router         |
|                           |
|  1. Query Plan Cache      |  -- Caches the execution plan for a parsed query.
|     (Redis)               |     Avoids re-planning on repeated identical queries.
|                           |
|  2. APQ Cache             |  -- Stores full query documents by SHA-256 hash.
|     (Redis)               |     Clients send hash; Router retrieves document.
|                           |
|  3. Entity Cache          |  -- Caches resolved entities by __typename + @key.
|     (Redis)               |     Prevents redundant subgraph fetches for the
|                           |     same entity across different queries.
+---------------------------+
       |          |
       v          v
+----------+  +----------+
| Subgraph |  | Subgraph |
|  Users   |  | Products |
|          |  |          |
|  4. Response Cache       |  -- Full GraphQL response cache at subgraph level.
|     (Redis via Keyv)     |     Keyed by query + variables + session.
+----------+  +----------+
       |          |
       v          v
+----------+  +----------+
| Postgres |  | Postgres |
| (users)  |  |(products)|
+----------+  +----------+
```

### Layer 1: Query Plan Cache

The Router parses each incoming GraphQL document and produces a query plan — a tree of fetch operations across subgraphs. Parsing and planning is CPU-intensive. The query plan cache stores the result of this computation keyed by the normalized query document.

- Stored in: Redis (or in-memory with persistence to Redis)
- TTL: typically unlimited; invalidated when schema composition changes
- Cache miss cost: 5–50ms of planning overhead per query
- What is NOT stored: the query result, only the execution plan

### Layer 2: APQ Cache (Automatic Persisted Queries)

APQ reduces bandwidth by replacing full query text with a SHA-256 hash. On first request, the client sends the hash; the Router looks it up in the APQ cache. On cache miss, the client resends the full document, which is stored and confirmed. Subsequent requests use only the hash.

- Stored in: Redis
- TTL: typically 30 days (queries rarely change)
- Cache miss behavior: protocol-level retry (two round trips on first use)
- Security benefit: with a strict APQ allowlist, only pre-registered queries can execute

### Layer 3: Entity Cache

The highest-value cache for federation workloads. When multiple queries reference the same `User`, `Product`, or `Order` entity, the Router serves subsequent requests from Redis without touching the subgraph. This is covered in detail in `entity-cache-config.md`.

- Stored in: Redis
- TTL: configurable per subgraph and per entity type
- Key anatomy: `{subgraph-name}:{TypeName}:{serialized-key-fields}`
- Cache miss cost: one subgraph HTTP round trip per unique entity

### Layer 4: Response Cache

Full GraphQL response caching at the subgraph level, implemented with `@apollo/server-plugin-response-cache`. Suitable for read-heavy, rarely-changing data (product catalogs, public content). Private user data requires session-keyed cache entries.

- Stored in: Redis (via Keyv adapter)
- TTL: derived from `@cacheControl(maxAge: N)` directives in the schema
- Session handling: private responses keyed by user ID from JWT claims
- Covered in detail in `response-cache-patterns.md`

---

## Architecture Overview

The diagram below shows how a single GraphQL request flows through all four caching layers. Cache hits at higher layers short-circuit the lower layers entirely.

```
Client request: query { user(id: "42") { name orders { total } } }

Step 1: APQ lookup
  Router checks Redis for query hash abc123
  HIT  -> proceed to step 2 with full query document from cache
  MISS -> client retries with full document; document stored in cache

Step 2: Query Plan lookup
  Router checks Redis for plan keyed by normalized query
  HIT  -> use cached plan, skip to step 3
  MISS -> plan the query (5-50ms), store in cache, proceed

Step 3: Entity Cache lookup
  Router checks Redis for User:42 and associated Order entities
  HIT  -> serve from cache, no subgraph calls
  MISS -> fetch from Users subgraph and Orders subgraph

Step 4 (on entity cache miss): Subgraph Response Cache
  Users subgraph checks Redis for cached response to this query+variables
  HIT  -> return cached response to Router
  MISS -> resolve via DataLoader -> PostgreSQL
```

---

## File Navigation

| File | What it covers |
|------|---------------|
| `README.md` | Architecture overview, layer descriptions, prerequisites, related docs |
| `entity-cache-config.md` | Router `router.yaml` entity caching config, cache key anatomy, per-user vs shared caching, invalidation, metrics |
| `response-cache-patterns.md` | Subgraph response cache plugin, `@cacheControl` directive, session-keyed caching, stampede prevention |
| `redis-topology.md` | Redis deployment modes (Sentinel, Cluster, ElastiCache), memory sizing, eviction policy, observability |

---

## Prerequisites

| Requirement | Minimum Version | Notes |
|-------------|----------------|-------|
| Apollo Router | 1.40.0 | Entity caching requires 1.40+; earlier versions support only APQ and query plan cache |
| Redis | 7.0 | Redis 7 adds multi-part keys and improves cluster slot migration; required for hash-tag-based key design |
| Node.js (subgraphs) | 20 LTS | Required for `@apollo/server` v4 and `@apollo/server-plugin-response-cache` |
| Apollo Server | 4.x | v3 cache plugin API is incompatible with v4 |
| `@keyv/redis` | 2.x | Keyv adapter for Redis; v3 has breaking API changes |
| Redis Cluster | 3+ nodes | Required for production; single-node Redis is a single point of failure |
| TLS certificates | Any CA | Required for `rediss://` connections in production |

### Redis Cluster vs Sentinel: When to Choose Which

| Criterion | Redis Sentinel | Redis Cluster |
|-----------|---------------|---------------|
| Use case | HA with a single shard | HA + horizontal shaling |
| Data volume | < 50 GB total | > 50 GB total |
| Throughput | < 100K ops/s | > 100K ops/s |
| Failover time | 10–30 seconds | Near-instant (client-side retry) |
| Operational complexity | Low | High |
| Apollo Router support | `redis+sentinel://` URL format | `redis://` cluster node URLs |
| Minimum nodes | 1 primary + 2 replicas + 3 sentinels | 3 primaries + 3 replicas |

For most production deployments serving fewer than 50 million requests per day, Redis Sentinel on AWS ElastiCache with Multi-AZ is the right choice. Redis Cluster is for very large platforms only.

---

## Quick Start

```bash
# Start Redis for local development
docker run -d --name redis-dev -p 6379:6379 redis:7-alpine

# Verify connection
redis-cli ping
# Expected: PONG

# Start Apollo Router with entity caching enabled
REDIS_URL=redis://localhost:6379 \
  ./router --config router.yaml --supergraph supergraph.graphql

# Watch cache activity in real time
redis-cli monitor | grep "entity\|apq\|plan"
```

---

## Security Considerations

Before enabling Redis caching, understand the data boundary implications:

1. **Shared cache = shared data by default.** The entity cache does not include auth context in cache keys by default. If `User:42` is cached after Alice resolves it, Bob's query will receive the same cached response. This is correct for public entities (products, articles) but catastrophic for private entities (account details, medical records). Always configure `@cacheControl(scope: PRIVATE)` for user-specific data.

2. **Redis must be in the same trust boundary as the Router.** Never expose Redis to the public internet. Redis has no TLS by default and its AUTH password is easily brute-forced on an open port. Use Kubernetes NetworkPolicy or security groups to restrict Redis access to the Router pod only.

3. **Cache poisoning via key collision.** If subgraph names or entity key values are attacker-controlled, an adversary could craft cache keys that collide with existing entries. Ensure entity key field values are always validated (e.g., UUID format) before being used in cache lookups.

---

## Related Documentation

- `../../docs/17-caching-strategies/` — conceptual overview of all caching strategies
- `../../docs/05-security/` — security implications of caching (scope: PUBLIC vs PRIVATE)
- `../../docs/01-federation-overview/` — Apollo Federation entity resolution and `@key` directive
- `../../examples/02-apollo-router/` — baseline Router configuration (required before adding caching)
- `../../examples/06-kubernetes/` — Redis deployment via Helm chart in Kubernetes
