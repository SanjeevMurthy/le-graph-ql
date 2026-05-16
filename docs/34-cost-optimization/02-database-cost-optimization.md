# 02 — Database Cost Optimization for GraphQL

> **Purpose**
> Database cost analysis and optimization strategies specific to federated GraphQL platforms. Covers DataLoader impact on query cost, read replica routing in resolvers, resolver-aware SQL column selection, PgBouncer connection pooling, response cache break-even analysis, and data archiving for historical resolvers. Written for backend engineers and platform architects who own subgraph database infrastructure.

---

## Cost Drivers

### Driver 1: N+1 Queries Without DataLoader Batching

The GraphQL execution model calls resolvers per field, per entity. Without batching, fetching `products { id price variants { stock } }` for 100 products generates:

```
100 queries: SELECT price FROM product_prices WHERE product_id = $1
100 queries: SELECT stock FROM inventory WHERE product_id = $1
= 200 separate database queries per GraphQL request
```

**Quantified cost:**

```
Without DataLoader (N+1):
  1,000 concurrent requests × 200 queries each = 200,000 queries/second
  At 0.1ms per query: 200,000 × 0.1ms = 20,000ms total DB time/second
  PostgreSQL instance required: r5.2xlarge at $0.504/hour = ~$363/month

With DataLoader batching (1 query per entity type per request):
  1,000 concurrent requests × 2 queries each = 2,000 queries/second
  At 5ms per batch query (100 IDs): 2,000 × 5ms = 10,000ms total DB time/second
  PostgreSQL instance required: r5.xlarge at $0.252/hour = ~$181/month
  
Monthly saving from DataLoader: $182/month
Annual saving: $2,184/year
Database cost reduction: 50%

At 10,000 RPS, the savings scale proportionally: ~$18,000/year.
```

The DataLoader batch query runs in ~2ms (network round-trip) + ~5ms (query execution with index) = 7ms total. Compare to 1,000 individual queries at 0.1ms each = 100ms total. DataLoader is 14x faster AND 100x cheaper in terms of database connection overhead.

---

## DataLoader Implementation for Cost Efficiency

```typescript
// products-subgraph/src/dataloaders/product-price.loader.ts
import DataLoader from 'dataloader';
import { pool } from '../database/pool';

interface ProductPrice {
  productId: string;
  price: number;
  currency: string;
}

// Batch function: called once per tick with all requested IDs
const batchLoadPrices = async (productIds: readonly string[]): Promise<ProductPrice[]> => {
  // Single query for all requested products
  const result = await pool.query<ProductPrice>(
    `SELECT product_id AS "productId", price, currency
     FROM product_prices
     WHERE product_id = ANY($1::uuid[])
       AND active = true`,
    [productIds]
  );

  // CRITICAL: return results in the same order as productIds
  const priceMap = new Map(result.rows.map(row => [row.productId, row]));
  return productIds.map(id => priceMap.get(id) ?? null);
};

export const createProductPriceLoader = () =>
  new DataLoader<string, ProductPrice | null>(batchLoadPrices, {
    cache: true,          // Cache within request context
    maxBatchSize: 500,    // Never batch more than 500 IDs (prevents query size limits)
  });

// IMPORTANT: create one DataLoader per request — never share across requests
// In your GraphQL context factory:
export const createContext = () => ({
  dataloaders: {
    productPrice: createProductPriceLoader(),
    // ... other loaders
  },
});
```

**Verify DataLoader batching is working:**

```promql
# Batch size p50 should be > 10 at normal traffic
# If p50 = 1: DataLoader is not batching — N+1 regression
histogram_quantile(0.50,
  sum by (le, loader_name) (
    rate(graphql_dataloader_batch_size_bucket[5m])
  )
)
```

---

## Read Replica Routing in Resolvers

Not all GraphQL queries need to hit the primary database. Analytical and read-heavy queries can route to read replicas, reducing load on the primary and allowing use of smaller (cheaper) primary instances.

```typescript
// database/pool.ts — connection pool with read/write routing
import { Pool } from 'pg';

// Write pool: primary database — used for mutations and strongly consistent reads
export const writePool = new Pool({
  connectionString: process.env.DATABASE_PRIMARY_URL,
  max: 20,
  idleTimeoutMillis: 30_000,
});

// Read pool: read replica(s) — used for queries
// For multiple replicas, use PgBouncer in front to load-balance
export const readPool = new Pool({
  connectionString: process.env.DATABASE_READ_URL,
  max: 50,          // Read replicas can handle more concurrent connections
  idleTimeoutMillis: 30_000,
});
```

```typescript
// resolvers/query.ts — route reads to replica, mutations to primary
import { writePool, readPool } from '../database/pool';

export const queryResolvers = {
  Query: {
    // Product listing: read-only, no consistency requirement → replica
    products: async (_, { filter }, ctx) => {
      const result = await readPool.query(
        `SELECT id, name, price FROM products WHERE $1`,
        [filter]
      );
      return result.rows;
    },

    // Order history: analytical query → replica
    orderHistory: async (_, { userId, page }, ctx) => {
      const result = await readPool.query(
        `SELECT * FROM orders WHERE user_id = $1 ORDER BY created_at DESC LIMIT 20 OFFSET $2`,
        [userId, page * 20]
      );
      return result.rows;
    },

    // Active cart: must be strongly consistent → primary
    cart: async (_, { cartId }, ctx) => {
      const result = await writePool.query(
        `SELECT * FROM carts WHERE id = $1 AND status = 'active'`,
        [cartId]
      );
      return result.rows[0];
    },
  },

  Mutation: {
    // All mutations always go to primary
    addToCart: async (_, args, ctx) => {
      return writePool.query(/* ... */);
    },
  },
};
```

**Read replica sizing:**

```
Rule of thumb: 80% of GraphQL queries are reads.
Primary handles 20% of queries + all mutations.
Read replicas handle 80% of queries.

Without read replicas: primary must handle 100% at peak RPS.
With 2 read replicas: primary handles 20% + replica each handles 40%.
Primary can be downsized: db.r5.2xlarge ($0.504/hour) → db.r5.xlarge ($0.252/hour)
Monthly saving on primary: (0.504 - 0.252) × 720 = $181/month
Two replicas add: 2 × $0.252 × 720 = $363/month
Net cost change: -$181 + $363 = +$182/month

BUT: replicas unlock horizontal scaling beyond what a single primary can handle.
At 10k RPS this is not optional — it is required for availability.
```

---

## Resolver-Aware SQL Column Selection

GraphQL resolvers receive `info.fieldNodes` which contains exactly which fields the client requested. Use this to generate SQL that selects only the needed columns, reducing query I/O and memory.

```typescript
// utils/graphql-fields.ts — extract requested fields from GraphQL info object
import { GraphQLResolveInfo } from 'graphql';

// Uses graphql-fields library: npm install graphql-fields
import graphqlFields from 'graphql-fields';

interface ProductRow {
  id: string;
  name?: string;
  price?: number;
  description?: string;
  inventory?: object;
  images?: string[];
}

// Map GraphQL field names to SQL column names (in case they differ)
const FIELD_TO_COLUMN: Record<string, string> = {
  id: 'id',
  name: 'name',
  price: 'base_price',
  description: 'long_description',
  // inventory and images are resolved by separate subgraphs — not in this table
};

export function buildProductSelectSQL(info: GraphQLResolveInfo): string {
  const requestedFields = graphqlFields(info);
  
  // Always include id (required for entity resolution and @key)
  const columns = new Set<string>(['id']);
  
  Object.keys(requestedFields).forEach(field => {
    const column = FIELD_TO_COLUMN[field];
    if (column) columns.add(column);
  });

  return Array.from(columns).join(', ');
}

// In resolver:
export const productResolver = async (_, { id }, ctx, info) => {
  const columns = buildProductSelectSQL(info);
  
  // Query only the columns the client actually requested
  const result = await readPool.query(
    `SELECT ${columns} FROM products WHERE id = $1`,
    [id]
  );
  return result.rows[0];
};
```

**Cost impact of column selection:**

```
products table: 25 columns, 10 million rows
Average row size (all columns): 2KB
Average row size (5 requested columns): 200 bytes

Query: SELECT * FROM products WHERE id IN (100 IDs)
  Data read from PostgreSQL: 100 × 2KB = 200KB
  Network transfer: 200KB per batch

Query: SELECT id, name, price, base_price, stock FROM products WHERE id IN (100 IDs)
  Data read from PostgreSQL: 100 × 200B = 20KB
  Network transfer: 20KB per batch

I/O reduction: 90% per query
At 10,000 batch queries/hour: 200KB × 10,000 = 2GB/hour → 200KB × 10,000 = 200MB/hour
RDS data transfer saving: negligible in same-region setup, but significant for cross-region
PostgreSQL shared_buffers efficiency: 10x more rows fit in buffer cache
```

---

## PgBouncer for Connection Pooling

GraphQL resolvers create a new execution context per request, and each subgraph pod maintains a connection pool. Without a shared connection pooler between pods and the database, connection counts grow multiplicatively:

```
Without PgBouncer:
  products subgraph: 10 pods × 20 connections each = 200 database connections
  orders subgraph:   8 pods × 20 connections each = 160 database connections
  inventory:         5 pods × 20 connections each = 100 database connections
  Total: 460 connections to PostgreSQL

PostgreSQL default max_connections: 100–200 on most managed instances
Result: Connection limit exceeded → queries fail → requires oversized database

With PgBouncer (transaction pooling mode):
  All subgraph pods connect to PgBouncer (cheap, many connections OK)
  PgBouncer maintains 10 connections to PostgreSQL (efficient connection reuse)
  100 resolver functions × 10 concurrent requests = 1,000 "connections"
  With PgBouncer: 10 actual PostgreSQL connections serve all 1,000 "connections"
```

```yaml
# pgbouncer-config.yaml — PgBouncer deployment in the graphql-platform namespace
apiVersion: v1
kind: ConfigMap
metadata:
  name: pgbouncer-config
  namespace: graphql-platform
data:
  pgbouncer.ini: |
    [databases]
    products = host=products-db.cluster.us-east-1.rds.amazonaws.com
               port=5432 dbname=products

    [pgbouncer]
    listen_addr = 0.0.0.0
    listen_port = 5432
    auth_type = md5
    auth_file = /etc/pgbouncer/userlist.txt

    # Transaction pooling: releases connection after each transaction
    # Safe for all GraphQL resolver patterns (each query is a transaction)
    pool_mode = transaction

    # 10 server connections per database per user
    default_pool_size = 10

    # Maximum clients: 1000 (resolvers × concurrent requests × pods)
    max_client_conn = 1000

    # Queued clients: allow up to 200 waiting connections
    reserve_pool_size = 20
    reserve_pool_timeout = 3

    # Connection lifetime
    server_lifetime = 3600
    server_idle_timeout = 600
```

**Connection overhead cost impact:**

```
PostgreSQL connection memory: ~10MB per connection (backend process)
Without PgBouncer: 460 connections × 10MB = 4.6GB RAM consumed by connections alone
  → Requires db.r5.2xlarge (61GB RAM) just for connection headroom

With PgBouncer: 10 connections × 10MB = 100MB RAM for connections
  → Can use db.r5.large (16GB RAM) with room for actual query buffers

Instance downgrade: db.r5.2xlarge ($0.504/hour) → db.r5.large ($0.126/hour)
Monthly saving: (0.504 - 0.126) × 720 = $272/month
Annual saving: $3,264/year
```

---

## Response Caching Hot Data — Break-Even Analysis

A Redis response cache stores the full GraphQL response for cacheable operations. The cache costs money (Redis cluster) but reduces database query cost and latency for frequently-requested identical responses.

**Break-even calculation:**

```
Scenario: 10,000 RPS, 60% of requests are identical product page queries

Without cache:
  6,000 cacheable requests/second hit the database
  At 10ms per request (database round trip): 60 CPU-seconds of DB work per second
  Database cost: db.r5.2xlarge at $0.504/hour = $362/month

With Redis cache (cache TTL = 60 seconds):
  Cache warm-up: 6,000 unique queries in the first 60 seconds = 6,000 cache entries
  Average cache hit rate: ~85% (some keys expire, some are unique per-user)
  Database queries after cache: 6,000 × 0.15 = 900 requests/second
  Database cost: db.r5.large at $0.252/hour = $181/month

Redis cluster cost: r6g.large (2 nodes for HA) at $0.166/hour × 2 = $239/month

Without cache total: $362/month
With cache total:    $181 (DB) + $239 (Redis) = $420/month

In this scenario: caching is NOT cost-effective on small instances.
It becomes cost-effective when database queries are more expensive:
  - Large database instances (db.r5.4xlarge+)
  - Cross-region replication cost
  - High I/O workloads billed per I/O operation (AWS RDS I/O-optimized pricing)

Break-even point: when database savings > Redis cluster cost
  Database must cost > $239/month MORE than the smaller post-cache instance
  This happens when: uncached DB cost > $420/month, i.e., at scale
```

---

## Archiving Unused Data for Historical Resolvers

Historical resolvers (order history > 1 year, archived products, old invoices) should query cold storage, not hot PostgreSQL. Keeping historical data in PostgreSQL increases:

- Database size and therefore instance cost
- Backup time and cost
- Query planner complexity (more rows to skip via index scans)

```typescript
// resolvers/order-history.resolver.ts — route by age
export const orderHistoryResolver = async (_, { userId, yearRange }) => {
  const { startYear, endYear } = yearRange;
  const currentYear = new Date().getFullYear();
  
  if (endYear < currentYear - 1) {
    // Historical data — query from S3 via Athena (cold storage)
    return queryAthenaOrderHistory(userId, startYear, endYear);
  } else {
    // Recent data — query from PostgreSQL (hot storage)
    return readPool.query(
      `SELECT * FROM orders WHERE user_id = $1 AND EXTRACT(year FROM created_at) >= $2`,
      [userId, startYear]
    );
  }
};

// Athena query for cold storage (S3 Parquet files, priced per TB scanned)
const queryAthenaOrderHistory = async (userId: string, startYear: number, endYear: number) => {
  const athena = new AWS.Athena();
  const result = await athena.startQueryExecution({
    QueryString: `
      SELECT * FROM orders_archive
      WHERE user_id = '${userId}'
        AND year BETWEEN ${startYear} AND ${endYear}
    `,
    ResultConfiguration: {
      OutputLocation: `s3://${process.env.ATHENA_RESULTS_BUCKET}/`,
    },
  }).promise();
  
  // ... poll for results
};
```

**Cost comparison: hot vs cold storage for 3 years of order history:**

```
Order data: 100 million orders, 500 bytes average
Total data: 50GB

Hot storage (PostgreSQL on RDS):
  Storage: 50GB × $0.115/GB-month (gp2) = $5.75/month
  I/O cost (SSD): $0.10 per million I/Os, estimated 10M I/O/month = $1.00/month
  Total: $6.75/month

Cold storage (S3 + Athena):
  S3 storage: 50GB × $0.023/GB-month = $1.15/month
  Athena queries: estimated 100 historical queries/month × 0.5GB scanned × $5/TB = $0.25/month
  Total: $1.40/month

Monthly saving: $5.35/month per 50GB of historical data
At 1TB of historical data: $107/month saving
```

---

## Database Cost Summary

| Optimization | Implementation | Monthly Saving | Complexity |
|-------------|---------------|----------------|-----------|
| DataLoader batching (N+1 fix) | Code change in subgraphs | $181–$1,800+ | Medium |
| Read replica routing | Environment variable + pool config | $181–$500 | Low |
| Column selection (graphql-fields) | Code change in resolvers | I/O reduction, indirect cost | Medium |
| PgBouncer connection pooling | Kubernetes deployment | $272–$1,000 | Medium |
| Redis response cache | Cache layer + TTL config | Varies (see break-even) | Medium |
| Data archiving to cold storage | Resolver routing logic | $5–$200 per 50GB | High |

---

## References and Related Topics

- [04-resolvers-and-execution/README.md](../04-resolvers-and-execution/README.md) — DataLoader implementation patterns
- [17-caching-strategies/README.md](../17-caching-strategies/README.md) — Response caching architecture
- [01-compute-cost-optimization.md](./01-compute-cost-optimization.md) — Compute savings that complement database savings
- [graphql-fields npm package](https://www.npmjs.com/package/graphql-fields) — Field extraction from GraphQL info object
- [PgBouncer Documentation](https://www.pgbouncer.org/config.html) — Transaction pooling configuration
- [Amazon Athena Pricing](https://aws.amazon.com/athena/pricing/) — Cost model for cold storage queries
- [RDS Instance Pricing](https://aws.amazon.com/rds/postgresql/pricing/) — Instance type comparison
