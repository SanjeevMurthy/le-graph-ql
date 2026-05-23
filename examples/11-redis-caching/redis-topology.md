# Redis Topology for GraphQL Caching at Scale

Companion docs: `../../docs/17-caching-strategies/`

Choosing the right Redis deployment topology is as important as configuring the cache itself. A poorly chosen topology can introduce the exact availability and performance problems that caching is meant to solve. This document covers all production-relevant Redis deployment modes, with specific guidance for Apollo Router entity caching and subgraph response caching workloads.

---

## Single-Node Redis

Single-node Redis is appropriate only for local development and CI/CD test environments. It must never be used in production for any caching workload that affects user-visible requests.

```yaml
# docker-compose.yml — development only
services:
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    command: redis-server --save "" --appendonly no
    # --save "" disables RDB snapshots (not needed for ephemeral dev cache)
    # --appendonly no disables AOF persistence (not needed for cache data)
    # Both flags reduce disk I/O and startup time for development
```

### Why single-node is unacceptable for production

| Risk | Impact |
|------|--------|
| Single point of failure | Redis restart = all cache lost = cache stampede on all subgraphs simultaneously |
| No replication | In-memory data cannot be recovered after restart |
| No failover | If the node crashes, there is no automatic promotion of a replica |
| Bounded throughput | All operations serialized through one CPU core; limited to ~100K ops/s |
| No horizontal scale | Cannot grow beyond a single server's RAM |

A cache stampede from a single-node Redis restart is particularly dangerous because it hits all subgraphs at once. Every entity that was cached across thousands of unique entity IDs becomes a cache miss, and all those misses hit the database simultaneously. This is a common root cause of production database overload incidents.

---

## Redis Sentinel

Redis Sentinel provides high availability for a single-shard Redis deployment. It monitors primary and replica instances and automatically promotes a replica to primary if the primary becomes unavailable.

### Topology

```
+----------+    replication    +----------+
| Primary  | ----------------> | Replica  |
| :6379    |                   | :6379    |
+----------+                   +----------+
     |
     | replication
     v
+----------+
| Replica  |
| :6379    |
+----------+

+-------------+  +-------------+  +-------------+
| Sentinel 1  |  | Sentinel 2  |  | Sentinel 3  |
| :26379      |  | :26379      |  | :26379      |
+-------------+  +-------------+  +-------------+
```

Minimum configuration: 1 primary + 2 replicas + 3 Sentinels. The 3-Sentinel quorum prevents split-brain: a Sentinel cannot initiate failover unless at least 2 Sentinels agree the primary is down. Running Sentinels on the same hosts as Redis instances is acceptable (cost savings in staging).

### Sentinel configuration (`sentinel.conf`)

```ini
# Run on each Sentinel node
# sentinel.conf

# The master to monitor. Parameters: <master-name> <primary-ip> <primary-port> <quorum>
# quorum: number of Sentinels that must agree before initiating failover.
# For 3 Sentinels, quorum=2 means any 2 must agree.
sentinel monitor mymaster redis-primary.cache.svc.cluster.local 6379 2

# How long (ms) the primary must be unreachable before Sentinels mark it as
# subjectively down. 5000ms (5s) balances responsiveness vs false positives
# from transient network blips.
sentinel down-after-milliseconds mymaster 5000

# How many replicas can be reconfigured at once during failover.
# 1 means replicas are updated one at a time — if a replica fails during
# reconfiguration, at least one good replica remains serving reads.
sentinel parallel-syncs mymaster 1

# Failover timeout in milliseconds. If failover takes longer than this,
# Sentinel considers it failed and retries. 10000ms = 10 seconds.
sentinel failover-timeout mymaster 10000

# AUTH password if Redis requires authentication.
# Must match the requirepass in the primary and replica redis.conf.
sentinel auth-pass mymaster ${REDIS_PASSWORD}
```

### Apollo Router connection string for Sentinel

```yaml
# router.yaml
entity_caching:
  redis:
    urls:
      # Sentinel URL format: redis+sentinel://<sentinel1>,<sentinel2>,<sentinel3>/<master-name>
      # The Router connects to the Sentinel nodes and asks them for the current primary's address.
      - "redis+sentinel://sentinel-0.cache.svc:26379,sentinel-1.cache.svc:26379,sentinel-2.cache.svc:26379/mymaster"
```

### Failover behavior and time expectations

| Phase | Duration |
|-------|----------|
| Primary goes down → Sentinels detect (down-after-milliseconds) | 5 seconds |
| Sentinel quorum forms and agrees | 1–2 seconds |
| Replica promoted to primary | < 1 second |
| Clients (Router) notified and reconnected | 1–5 seconds |
| Total expected failover window | 10–30 seconds |

During the failover window, entity cache lookups will fail (Redis unreachable). Apollo Router is configured with `timeout: { milliseconds: 2 }` — each cache operation fails fast and the request proceeds as a cache miss. Subgraph latency increases during failover, but requests are not blocked or failed.

---

## Redis Cluster

Redis Cluster provides horizontal sharding across multiple primary nodes. Data is distributed across 16,384 hash slots, each assigned to a primary. Each primary has one or more replicas for HA.

### When to use Redis Cluster

| Condition | Recommendation |
|-----------|---------------|
| Cache data > 50 GB | Cluster required (Sentinel is single-shard, bounded by one server's RAM) |
| Write throughput > 100K ops/s | Cluster required (single primary is CPU-bound) |
| Horizontal scale-out needed | Cluster required |
| Cache data < 50 GB, HA needed | Sentinel (simpler to operate) |

### Minimum topology

```
Primary-0        Primary-1        Primary-2
(slots 0-5460)   (slots 5461-10922) (slots 10923-16383)
|                |                |
Replica-0        Replica-1        Replica-2
```

Minimum viable cluster: 3 primaries + 3 replicas (6 nodes total). Redis Cluster requires at least 3 primaries to prevent split-brain — a cluster with 2 primaries cannot form a quorum if one is unreachable.

### Slot distribution and hash tags

Redis Cluster distributes keys across 16,384 hash slots using CRC16:

```
slot = CRC16(key) % 16384
```

For most cache use cases, this automatic distribution is ideal — keys spread evenly across the cluster. However, batch operations (MGET, pipeline) fail if keys land on different slots. If you need to batch-delete all entity cache entries for a specific entity type, use hash tags to force co-location:

```
# Without hash tag — random slot distribution
router:entity:products:Product:{"id":"1"}  -> slot 3241
router:entity:products:Product:{"id":"2"}  -> slot 8892
# MGET across different slots requires cluster-aware client, fine for reads

# With hash tag — force all Product entities to one slot (use cautiously)
# Hash tags are identified by the {} portion; only the text inside {} determines the slot
{router:entity:products:Product}:{"id":"1"}  -> always same slot
{router:entity:products:Product}:{"id":"2"}  -> always same slot
# Now SCAN + MDEL works within a single slot
```

Apollo Router applies hash tags automatically for its own key format. If you are implementing custom invalidation via Redis SCAN (see `entity-cache-config.md`), use the hash tag pattern to ensure SCAN + DEL operates within a single slot.

### Apollo Router connection string for Cluster

```yaml
# router.yaml
entity_caching:
  redis:
    # Provide at least 3 seed node URLs. The cluster-aware client discovers
    # the full topology from these seeds. You do not need to list every node.
    urls:
      - "redis://redis-0.cache.svc.cluster.local:6379"
      - "redis://redis-1.cache.svc.cluster.local:6379"
      - "redis://redis-2.cache.svc.cluster.local:6379"
```

---

## AWS ElastiCache for Redis

AWS ElastiCache is the managed Redis option for AWS deployments. It eliminates operational burden (patching, backups, hardware) at the cost of some configuration flexibility.

### Choosing ElastiCache mode

| ElastiCache Mode | Corresponds to | When to use |
|-----------------|---------------|-------------|
| Single-node cluster | Development only | Never in production |
| Cluster Mode Disabled (CMDisabled) | Redis Sentinel-equivalent | Cache < 50 GB, standard HA |
| Cluster Mode Enabled (CMEnabled) | Redis Cluster | Cache > 50 GB, horizontal scale |

### ElastiCache Cluster Mode Enabled configuration (Terraform)

```hcl
resource "aws_elasticache_replication_group" "graphql_cache" {
  replication_group_id = "graphql-entity-cache"
  description          = "Redis Cluster for Apollo Router entity caching"

  # Redis version — use 7.x for LMPOP, OBJECT FREQ, and improved cluster features
  engine_version = "7.0"

  # node_type determines the instance size (memory and CPU).
  # cache.r7g.large = 13.07 GB RAM. Choose based on the memory sizing formula below.
  node_type = "cache.r7g.large"

  # Number of node groups (shards) in the cluster.
  # 3 shards provides the minimum recommended cluster for production.
  # Each shard has one primary + num_cache_clusters-1 replicas.
  num_node_groups = 3

  # Number of replica nodes per shard (not counting the primary).
  # 1 replica per shard = sufficient for most GraphQL workloads.
  replicas_per_node_group = 1

  # Enable cluster mode (required for Cluster topology, disables single-shard mode)
  automatic_failover_enabled = true

  # Enable in-transit encryption. Use "rediss://" (double-s) in Apollo Router URLs.
  transit_encryption_enabled = true

  # Enable at-rest encryption for entity data stored on disk (RDB snapshots, AOF).
  at_rest_encryption_enabled = true

  # AUTH token for password authentication. Required when TLS is enabled.
  # Store in AWS Secrets Manager; inject as environment variable into Router pods.
  auth_token = var.redis_auth_token

  # Maintenance window — scheduled during low-traffic period.
  maintenance_window = "sun:05:00-sun:06:00"

  # Automatic minor version upgrades — enable for security patches.
  auto_minor_version_upgrade = true

  # Subnet group — must span multiple AZs for cross-AZ replication.
  subnet_group_name = aws_elasticache_subnet_group.cache.name

  # Security group — restrict to Router pod security group only.
  security_group_ids = [aws_security_group.redis.id]

  tags = {
    Service     = "apollo-router"
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
```

### Apollo Router connection string for ElastiCache

```yaml
# router.yaml
entity_caching:
  redis:
    urls:
      # Use rediss:// (double-s) for TLS. Include auth token in URL.
      # ElastiCache Cluster Mode Enabled uses the configuration endpoint
      # which auto-discovers all cluster nodes.
      - "rediss://:${REDIS_AUTH_TOKEN}@graphql-entity-cache.cluster.cfg.use1.cache.amazonaws.com:6379"
```

---

## Redis Memory Sizing

Undersizing Redis causes evictions, which reduce hit rates and increase subgraph load. Oversizing wastes money. Use this formula to estimate the required memory for entity caching.

### Sizing formula

```
required_memory_bytes =
  (avg_entity_size_bytes * num_unique_entities * replication_factor) / eviction_ratio
```

| Variable | Description |
|----------|-------------|
| `avg_entity_size_bytes` | Average serialized size of one entity (JSON) including key overhead |
| `num_unique_entities` | Number of distinct entities that will be cached (not requests, unique IDs) |
| `replication_factor` | 1 for non-replicated; 2 for 1 replica; add 10–15% overhead for Redis metadata |
| `eviction_ratio` | 0.8 — leave 20% headroom so Redis evicts gracefully before hitting the memory limit |

### Worked example: e-commerce platform

Assumptions:
- Product catalog: 100,000 unique products
- Average product entity size: 1,024 bytes (1 KB) serialized as JSON
- Category tree: 5,000 unique categories, 512 bytes each
- User profiles: 500,000 users, 256 bytes each (only recently active users warm in cache)
- Replication factor: 1 (primary + 1 replica)

```
Products:
  1,024 bytes * 100,000 entities = 102.4 MB * 2 (replication) = 204.8 MB

Categories:
  512 bytes * 5,000 entities = 2.56 MB * 2 = 5.12 MB

User profiles (assume 10% active at any time = 50,000 warm):
  256 bytes * 50,000 entities = 12.8 MB * 2 = 25.6 MB

Total raw data: 235.52 MB
Redis overhead (10% for keys, hash tables, expiry data): 23.55 MB
Subtotal: 259 MB

Headroom (divide by 0.8 to leave 20% free):
  259 MB / 0.8 = 323 MB
```

For this e-commerce example, `cache.r6g.large` (6.38 GB RAM) is more than sufficient. If you add query plan cache and APQ cache, add approximately 50–200 MB depending on query diversity.

Size up by 2x when first deploying — cache memory is cheap compared to the cost of a cache stampede from a maxed-out Redis node.

---

## Eviction Policy

Redis eviction policy controls what happens when Redis reaches its `maxmemory` limit.

| Policy | Behavior | Appropriate for caching? |
|--------|----------|--------------------------|
| `noeviction` | Reject writes when memory is full | No — causes cache write failures under memory pressure |
| `allkeys-lru` | Evict least recently used keys across all keys | Yes — the correct choice for entity/response caches |
| `volatile-lru` | Evict LRU keys only from keys with an expiry set | Yes if non-cache data is also in Redis; LRU among TTL-bearing keys |
| `allkeys-lfu` | Evict least frequently used keys | Good alternative to allkeys-lru for hot/cold access patterns |
| `volatile-ttl` | Evict keys with shortest TTL remaining | Not recommended — evicts keys about to expire anyway (no benefit) |

### Configure `allkeys-lru` in `redis.conf`

```ini
# redis.conf
# Set maximum memory for this Redis instance.
# When this limit is reached, eviction policy kicks in.
# Intentionally set below the physical RAM to leave headroom for OS page cache.
maxmemory 4gb

# LRU eviction across all keys.
# This allows Redis to automatically manage the working set — frequently accessed
# entities stay warm, infrequently accessed entities are evicted to make room.
maxmemory-policy allkeys-lru

# LRU approximation sample size. Higher = more accurate eviction, more CPU.
# 5 is the Redis default and is sufficient for most workloads.
# Increase to 10 for a more precise LRU approximation at ~2x CPU cost.
maxmemory-samples 5
```

### Why `noeviction` is wrong for cache workloads

If Redis hits its memory limit with `noeviction`, every cache write fails with `OOM command not allowed when used memory > 'maxmemory'`. The Apollo Router logs these as write errors and falls through to subgraph fetches — effectively making the cache read-only. New entities cannot be stored. Hit rate declines over time as entries expire without replacement. The result is a slow-motion cache stampede.

---

## Redis Observability

Monitor these metrics to maintain cache health. Integrate with Prometheus via `redis_exporter` (Oliver006's redis_exporter is the standard for Kubernetes deployments).

### Key metrics

| Metric | Alert threshold | Meaning |
|--------|----------------|---------|
| `redis_memory_used_bytes` | > 85% of `maxmemory` | Memory pressure; evictions likely to increase |
| `redis_evicted_keys_total` | > 0 (rate > 100/s is concerning) | Keys being evicted — size Redis larger or reduce TTLs |
| `redis_keyspace_hits_total` | See below | Raw hit count |
| `redis_keyspace_misses_total` | See below | Raw miss count |
| `redis_connected_clients` | > 80% of `maxclients` | Connection pool exhaustion risk |
| `redis_replication_lag` | > 1 second | Replica falling behind primary |
| `redis_up` | 0 = alert | Redis instance is down |

### Hit rate calculation

```promql
# Prometheus query for Redis cache hit rate (5-minute window)
rate(redis_keyspace_hits_total[5m])
/
(
  rate(redis_keyspace_hits_total[5m])
  + rate(redis_keyspace_misses_total[5m])
)
```

Target hit rates:
- Product/category entity cache: > 85%
- Response cache (public queries): > 70%
- APQ cache: > 98% (after initial warm-up period)
- Query plan cache: > 99% (query shapes rarely change)

### Replication lag alert

```yaml
# Prometheus alerting rule
- alert: RedisReplicationLagHigh
  expr: redis_replication_lag > 1
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "Redis replica lagging behind primary by {{ $value }}s"
    description: "If the primary fails now, failover will result in {{ $value }}s of data loss."
```

### Useful `redis-cli` diagnostic commands

```bash
# Overall info — memory, keyspace, replication
redis-cli info all

# Real-time command monitoring (use sparingly in production — high output volume)
redis-cli monitor

# Slow log — commands that exceeded the slowlog-log-slower-than threshold
redis-cli slowlog get 10

# Memory breakdown by key pattern
redis-cli --memkeys --memkeys-samples 0 --pattern "router:entity:*"

# Key count by type
redis-cli info keyspace

# Check cluster health
redis-cli cluster info
redis-cli cluster nodes
```

---

## Key Design Decisions

1. **Sentinel for most deployments, Cluster for large-scale.** The operational complexity of Redis Cluster (slot migration, cluster-aware clients, cross-slot operation restrictions) is justified only when data exceeds one server's RAM or throughput exceeds one CPU core. Most GraphQL platforms with fewer than 200 million daily requests are better served by Redis Sentinel on ElastiCache.

2. **allkeys-lru over volatile-lru for pure cache deployments.** If Redis is used exclusively for caching (no session store, no pub/sub, no application queues), `allkeys-lru` is simpler and more effective. All keys have TTLs anyway; `allkeys-lru` just adds eviction pressure before TTL expiry when needed.

3. **20% headroom on maxmemory.** Redis's LRU approximation and metadata overhead are non-trivial. Setting `maxmemory` to 80% of physical RAM ensures eviction begins before the system runs out of memory, preventing OOM kills.

4. **rediss:// (TLS) required for production.** Redis AUTH passwords are transmitted in plaintext without TLS. On a shared network (multi-tenant Kubernetes cluster, VPC with many services), plaintext Redis traffic is a real eavesdropping risk. Use TLS even for internal cluster traffic in regulated environments.

5. **redis_exporter for observability, not just application-level metrics.** Apollo Router exposes cache hit/miss counts via Prometheus, but Redis-level metrics (memory, evictions, replication lag) require the redis_exporter sidecar. Both are needed — application metrics tell you whether the cache is useful; Redis metrics tell you whether the cache is healthy.

---

## Related Documentation

- `../../docs/17-caching-strategies/` — full caching strategy overview
- `../../examples/11-redis-caching/entity-cache-config.md` — Router entity cache configuration
- `../../examples/11-redis-caching/response-cache-patterns.md` — subgraph response cache
- `../../examples/06-kubernetes/` — Kubernetes deployment, Helm charts for Redis Sentinel/Cluster
- `../../examples/08-terraform/` — Terraform modules for ElastiCache provisioning
