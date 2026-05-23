# Automated Persisted Queries (APQ) — Setup and Configuration

> Companion docs: [../../docs/05-security/](../../docs/05-security/) and
> [../../docs/17-caching-strategies/](../../docs/17-caching-strategies/)

Automated Persisted Queries solve a well-defined problem: clients need to send the same
query text on every request, which wastes bandwidth and makes CDN caching impractical.
APQ moves the query registration step to runtime. The first time a client executes an
operation it sends the hash only; the server says "I don't know that hash, please send
the query text"; the client resends with both; the server caches and responds. Every
subsequent request from any client uses only the hash.

This is "automated" because there is no separate build or publish step. The client library
handles hash computation and the retry protocol transparently.

---

## 1. How APQ Works: The Two-Round-Trip Protocol

```
Request 1 (optimistic — hash only)
  Client  ---> POST /graphql
               { "extensions": { "persistedQuery": { "version": 1, "sha256Hash": "abc123" } } }

  Router  ---> Cache miss
  Router  <--- 200 OK
               { "errors": [{ "message": "PersistedQueryNotFound",
                               "extensions": { "code": "PERSISTED_QUERY_NOT_FOUND" } }] }

Request 2 (fallback — hash + full query)
  Client  ---> POST /graphql
               { "query": "query GetProduct($id: ID!) { product(id: $id) { name price } }",
                 "extensions": { "persistedQuery": { "version": 1, "sha256Hash": "abc123" } } }

  Router  ---> Cache miss on hash, receives full query text, validates hash matches query,
               stores hash -> query in APQ cache, executes query
  Router  <--- 200 OK  (normal response)

All subsequent requests from any client
  Client  ---> POST /graphql
               { "extensions": { "persistedQuery": { "version": 1, "sha256Hash": "abc123" } } }

  Router  ---> Cache HIT on hash
  Router  <--- 200 OK  (normal response, no re-parsing)
```

The hash is a lowercase hex-encoded SHA-256 of the query string after normalization (consistent
whitespace, sorted field aliases per Apollo spec). The client library handles normalization;
you should never compute hashes manually in application code.

### What the router validates on Request 2

When the router receives a query document alongside a hash it computes the SHA-256 of the
received document and compares it to the provided hash. If they do not match the request is
rejected with `PERSISTED_QUERY_HASH_MISMATCH`. This prevents a class of attack where a
malicious client registers a benign hash with a harmful query body.

---

## 2. APQ Configuration in router.yaml

```yaml
# router.yaml

apq:
  # Master switch. Set to false only if you are migrating away from APQ and need
  # to drain the cache; do not disable in a running system without testing fallback.
  enabled: true

  router:
    cache:
      # in_memory is the default. Good for single-router deployments or development.
      # For production with multiple router replicas, switch to Redis (section below)
      # so all replicas share the same cache state.
      in_memory:
        # How many distinct operations to hold in the LRU cache.
        # 512 covers a typical SPA with dozens of operations with generous headroom.
        # Each entry stores the raw query string (~1-3 KB average), so 512 entries
        # uses roughly 1-2 MB of heap — not a meaningful memory concern.
        # Do NOT set this to an extremely large number: the cache is not sharded
        # and LRU eviction under high variety of operations causes thundering herd.
        limit: 512

# Optional: set to true to enter lockdown mode (see section 8)
# require_id: true
```

---

## 3. Redis-Backed APQ Cache (Multi-Router Production)

When you run more than one router replica, each replica starts with an empty in-memory APQ
cache. This means every replica independently absorbs the two-round-trip overhead for every
new operation. Under a rolling deployment, newly started replicas have cold caches and add
latency spikes until they warm up. Redis solves this by giving all replicas shared cache state.

```yaml
# router.yaml

apq:
  enabled: true
  router:
    cache:
      redis:
        # Connection URL. In production this should be read from an environment variable
        # injected by your secrets manager (ExternalSecret -> K8s Secret -> envFrom).
        # Do not hardcode credentials here.
        urls:
          - "redis://${REDIS_HOST}:${REDIS_PORT}"

        # How long an APQ entry lives in Redis. 24 hours is a sensible default:
        # long enough that a deploy doesn't invalidate the warm cache, short enough
        # that stale entries from schema migrations are eventually evicted.
        ttl: 86400 # seconds = 24 hours

        # Redis connection pool size per router pod. Keep this low; APQ cache
        # lookups are O(1) and extremely fast. 5 connections is sufficient for
        # hundreds of requests/second per pod.
        pool_size: 5

        # Timeout for Redis operations. If Redis is unavailable, APQ lookups
        # time out and fall back gracefully — the router still executes the
        # query if the full query text was sent. APQ is a performance optimization,
        # not a hard dependency.
        timeout:
          connect: "500ms"
          read: "200ms"
          write: "200ms"

        # TLS is required for any Redis deployment outside the same pod/node.
        # In AWS ElastiCache, enable In-Transit Encryption on the cluster.
        tls:
          enabled: true
```

### Why Redis over in-memory for multi-replica deployments

| Scenario | In-memory | Redis |
|---|---|---|
| Single replica | Works fine | Adds unnecessary dependency |
| Rolling deploy (new pods) | Cold cache, latency spike | Warm immediately from shared state |
| Replica autoscale event | Cold cache | Warm immediately |
| Redis failure | APQ degrades gracefully (falls back to full-query) | N/A |
| Memory pressure | LRU eviction within router process | External; does not affect router heap |

---

## 4. Apollo Client Configuration for APQ

```typescript
// src/lib/apollo-client.ts
import {
  ApolloClient,
  InMemoryCache,
  HttpLink,
  from,
} from "@apollo/client";
import { createPersistedQueryLink } from "@apollo/client/link/persisted-queries";
import { sha256 } from "crypto-hash"; // or any SHA-256 implementation

// createPersistedQueryLink MUST be the first link in the chain.
// It intercepts operations before they reach the HTTP layer, computes the hash,
// sends the optimistic hash-only request, and handles the PersistedQueryNotFound
// retry transparently. Your application code never needs to know any of this.
const persistedQueryLink = createPersistedQueryLink({
  sha256,
  // useGETForHashedQueries: true enables GET requests for hash-only queries.
  // GET requests are cacheable by CDNs and proxies. Only enable this if:
  // 1. Your variables are small enough to fit in a URL (~2 KB limit)
  // 2. You want CDN-level response caching
  // Mutations always use POST regardless of this setting.
  useGETForHashedQueries: true,
});

const httpLink = new HttpLink({
  uri: process.env.NEXT_PUBLIC_GRAPHQL_URL ?? "http://localhost:4000/",
  // credentials: "include" is required if your router validates session cookies.
  // For token-based auth, use headers instead.
  credentials: "include",
});

// Link chain evaluation order: persistedQueryLink -> httpLink
// The persisted query link wraps the HTTP link, so it can intercept the response
// and decide whether to retry.
const client = new ApolloClient({
  link: from([persistedQueryLink, httpLink]),
  cache: new InMemoryCache(),
  // connectToDevTools: only in development — exposes cache state in browser devtools
  connectToDevTools: process.env.NODE_ENV === "development",
});

export default client;
```

### Adding auth headers alongside APQ

```typescript
import { setContext } from "@apollo/client/link/context";

const authLink = setContext((_, { headers }) => {
  const token = localStorage.getItem("access_token");
  return {
    headers: {
      ...headers,
      authorization: token ? `Bearer ${token}` : "",
    },
  };
});

// Auth link goes BETWEEN persisted query link and HTTP link.
// Order: persistedQueryLink -> authLink -> httpLink
// If you put authLink before persistedQueryLink, the retry logic in
// persistedQueryLink will not have access to the correct headers context.
const client = new ApolloClient({
  link: from([persistedQueryLink, authLink, httpLink]),
  cache: new InMemoryCache(),
});
```

---

## 5. urql Configuration for APQ

```typescript
// src/lib/urql-client.ts
import { createClient, fetchExchange } from "urql";
import { persistedExchange } from "@urql/exchange-persisted";
import { cacheExchange } from "@urql/exchange-graphcache";

const client = createClient({
  url: process.env.NEXT_PUBLIC_GRAPHQL_URL ?? "http://localhost:4000/",

  exchanges: [
    // cacheExchange must come before persistedExchange in the array.
    // urql evaluates exchanges left to right for outgoing operations.
    cacheExchange({
      // schema: introspectedSchema, // provide for offline schema awareness
    }),

    persistedExchange({
      // preferGetForPersistedQueries: true sends hash-only requests as GET.
      // Same CDN-cacheability benefit as Apollo Client's useGETForHashedQueries.
      preferGetForPersistedQueries: true,

      // enforcePersistedQueries: false means urql falls back to full-query POST
      // when it receives PersistedQueryNotFound. Set to true only after you have
      // confirmed all operations are registered in the server APQ cache (or
      // switched to manifest-based PQ).
      enforcePersistedQueries: false,

      // generateHash is optional. By default urql uses SubtleCrypto (Web Crypto API).
      // Provide a custom implementation if you need Node.js server-side rendering
      // compatibility where SubtleCrypto is not available.
      // generateHash: async (query) => myCustomSha256(query),
    }),

    // fetchExchange must be last — it performs the actual HTTP request
    fetchExchange,
  ],
});

export default client;
```

---

## 6. Testing APQ Manually with curl

These commands demonstrate the exact two-request protocol. Run them against a local router.

### Step 1 — Compute the SHA-256 hash of your query

```bash
# Normalize the query first (collapse whitespace) then hash.
# Apollo's normalization removes unnecessary whitespace but preserves structure.
QUERY='query GetUser($id: ID!) { user(id: $id) { id name email } }'
HASH=$(echo -n "$QUERY" | sha256sum | cut -d' ' -f1)
echo "Hash: $HASH"
# Hash: a9b0d89f... (example — your actual hash will differ)
```

### Step 2 — Send the hash-only request (expect PersistedQueryNotFound)

```bash
curl -s -X POST http://localhost:4000/ \
  -H 'Content-Type: application/json' \
  -d "{
    \"variables\": {\"id\": \"user-1\"},
    \"extensions\": {
      \"persistedQuery\": {
        \"version\": 1,
        \"sha256Hash\": \"$HASH\"
      }
    }
  }" | jq .

# Expected response:
# {
#   "errors": [
#     {
#       "message": "PersistedQueryNotFound",
#       "extensions": {
#         "code": "PERSISTED_QUERY_NOT_FOUND"
#       }
#     }
#   ]
# }
```

### Step 3 — Send hash + full query (expect success + cache registration)

```bash
curl -s -X POST http://localhost:4000/ \
  -H 'Content-Type: application/json' \
  -d "{
    \"query\": \"$QUERY\",
    \"variables\": {\"id\": \"user-1\"},
    \"extensions\": {
      \"persistedQuery\": {
        \"version\": 1,
        \"sha256Hash\": \"$HASH\"
      }
    }
  }" | jq .

# Expected response: normal GraphQL response with data
# {
#   "data": {
#     "user": { "id": "user-1", "name": "Alice", "email": "alice@example.com" }
#   }
# }
```

### Step 4 — Send hash only again (expect direct success, cache hit)

```bash
# Same command as Step 2 — this time the router finds the hash in cache
curl -s -X POST http://localhost:4000/ \
  -H 'Content-Type: application/json' \
  -d "{
    \"variables\": {\"id\": \"user-1\"},
    \"extensions\": {
      \"persistedQuery\": {
        \"version\": 1,
        \"sha256Hash\": \"$HASH\"
      }
    }
  }" | jq .

# Expected: data response with no PersistedQueryNotFound error
```

### Testing with GET (CDN-cacheable path)

```bash
# URL-encode the extensions JSON
curl -s -G http://localhost:4000/ \
  --data-urlencode "variables={\"id\":\"user-1\"}" \
  --data-urlencode "extensions={\"persistedQuery\":{\"version\":1,\"sha256Hash\":\"$HASH\"}}" | jq .
```

---

## 7. APQ Metrics in Apollo Studio

Apollo Studio's Operations page surfaces APQ effectiveness automatically when you connect
the router with an Apollo GraphOS API key.

Key metrics to monitor:

| Metric | What it tells you | Healthy range |
|---|---|---|
| Cache hit rate | % of APQ requests resolved from cache | > 90% in steady state |
| PersistedQueryNotFound rate | New operations being registered | Spikes on deploys, near zero otherwise |
| Hash mismatch errors | Client sending wrong hash | Should be exactly 0 |
| Operation count by hash | Most frequent operations | Useful for query plan cache sizing |

To enable Studio reporting:

```yaml
# router.yaml
telemetry:
  apollo:
    # Injected from environment — never hardcode
    key: "${APOLLO_KEY}"
    graph_ref: "${APOLLO_GRAPH_REF}"
    # field_level_instrumentation_sampler: 0.01  # sample 1% of fields for Studio
```

---

## 8. require_id Mode — Lockdown for Production

`require_id: true` transforms APQ from a performance optimization into a security control.
In this mode the router rejects any operation that does not arrive with a hash that resolves
to a registered query. The fallback path (send hash + full query) is disabled.

```yaml
# router.yaml
apq:
  enabled: true
  router:
    cache:
      redis:
        urls:
          - "redis://${REDIS_HOST}:${REDIS_PORT}"
        ttl: 86400

# Reject any request that does not carry a known persisted query hash.
# This is functionally equivalent to manifest-based PQ but uses the APQ
# runtime cache rather than a build-time manifest.
# WARNING: enabling this before your APQ cache is warm will cause 100% of
# requests to fail. Use the transition strategy below.
persisted_queries:
  enabled: true
  safelist:
    enabled: true
    require_id: true
```

### Transition strategy for enabling require_id without an outage

```
Phase 1 (days 1–7): Enable APQ without require_id.
  - Measure: PersistedQueryNotFound rate drops to near zero as clients warm the cache.
  - Confirm: APQ hit rate > 95% across all client versions.

Phase 2 (day 8): Enable require_id in staging.
  - Deploy staging with require_id: true.
  - Run smoke tests and confirm all operations are served from cache.
  - Check that no legitimate client generates PersistedQueryNotFound in staging logs.

Phase 3 (day 10): Enable require_id in production during low-traffic window.
  - Monitor error rate for 30 minutes post-deploy.
  - Roll back immediately if PersistedQueryNotFound errors appear from real clients.

Phase 4 (ongoing): Maintain cache TTL discipline.
  - If TTL expires (default 24h) and a pod restarts between client deploys,
    a brief registration burst occurs. Ensure Redis TTL matches your deploy cadence.
  - Consider moving to manifest-based PQ (see manifest-based-pq.md) for
    stronger guarantees — the manifest persists indefinitely and survives cache flushes.
```

---

## Key Design Decisions

**Why SHA-256 and not a shorter hash?**
The APQ spec uses SHA-256 because it is a standard that client libraries, proxies, and CDNs
all implement consistently. A shorter hash (e.g., CRC32) would reduce the identifier to a few
bytes but would introduce collision risk across a large operation catalogue and is not supported
by any mainstream GraphQL client library.

**Why does the router validate the hash on registration rather than trusting the client?**
If the router trusted the hash claimed by the client, a malicious actor could register a harmful
query under a hash that does not match it. By recomputing the SHA-256 on receipt and rejecting
mismatches, the router ensures the hash -> query mapping is canonical. This is the `PERSISTED_QUERY_HASH_MISMATCH` error.

**Why is Redis preferred over a distributed in-memory cache (e.g., Hazelcast)?**
Apollo Router is designed to be a thin, stateless proxy. Coupling it to a peer-discovery cluster
management system would add operational complexity. Redis is a well-understood external dependency
that the rest of the infrastructure (rate limiting, session, query plan cache) already uses.
A single Redis logical database can serve all APQ, query plan cache, and rate limit state.

**Why does PersistedQueryNotFound return HTTP 200 rather than 404?**
The GraphQL-over-HTTP spec defines errors as application-level concerns returned in the `errors`
array with HTTP 200. Returning HTTP 404 would cause some client libraries to treat the response
as a transport error and not read the body for retry information. `PERSISTED_QUERY_NOT_FOUND`
in the `extensions.code` field is the correct signal for client-side retry logic.

---

## Related Documentation

- [manifest-based-pq.md](./manifest-based-pq.md) — stronger security with build-time manifests
- [client-integration.md](./client-integration.md) — complete client setup for all stacks
- [Chapter 05 — Security](../../docs/05-security/README.md)
- [Chapter 17 — Caching Strategies](../../docs/17-caching-strategies/README.md)
- [examples/02-apollo-router](../02-apollo-router/) — full router.yaml reference
