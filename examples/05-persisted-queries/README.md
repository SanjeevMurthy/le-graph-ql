# examples/05-persisted-queries — Persisted Queries for Security and Performance

> Companion docs: [../../docs/05-security/](../../docs/05-security/) and
> [../../docs/17-caching-strategies/](../../docs/17-caching-strategies/)

Persisted queries give you two things simultaneously: a significant reduction in request payload
size and a powerful security control. Instead of sending the full query string on every request,
clients send a short SHA-256 hash identifier. The server resolves that hash to the stored query
text. An attacker who cannot submit arbitrary query strings cannot perform introspection-based
schema reconnaissance or run resource-exhausting queries that your clients never intended to send.

This directory covers both major approaches — Automated Persisted Queries (APQ) which work at
runtime without a build step, and manifest-based persisted queries which are the stronger
production choice because the server only accepts queries that existed at build time.

---

## Why Persisted Queries Matter

### Security

When a GraphQL server accepts arbitrary query strings from the network, any actor with HTTP
access can submit any query. Depth-limiting and complexity-scoring reduce the risk but still
require the server to parse and analyze each incoming document. Persisted queries change the
threat model entirely: in lockdown mode the server rejects any request whose hash does not
match a known operation. Attackers cannot probe your schema through introspection or craft
novel queries.

### Performance

A typical GraphQL query for a product listing page might be 800–2000 bytes of query text
plus variables. With persisted queries the identifier portion shrinks to 64 hex characters.
Over mobile connections or high-throughput service-to-service calls the cumulative saving is
meaningful. Parsing is also eliminated for cache hits — the server already has the validated
AST or the compiled query plan cached against that hash.

### CDN Compatibility

Because the query body is now a stable, short string, GET requests become practical. CDNs
can cache full responses keyed on the operation hash plus variable values, not the raw query.
Apollo Router supports converting APQ GET requests to cacheable responses automatically.

---

## Two Approaches

| Approach | When the manifest is built | Security level | Ops overhead |
|---|---|---|---|
| Automated Persisted Queries (APQ) | Never — hashes are registered at runtime | Medium: unknown queries are accepted the first time | Low |
| Manifest-based Persisted Queries | At CI build time, before deploy | High: only pre-registered queries accepted | Medium |

**APQ** is appropriate for internal APIs where you want the performance wins but accept that
the first execution of any new query succeeds before it is cached.

**Manifest-based PQ** is the correct choice for any public-facing API, for regulated industries,
or for teams that want the guarantee that production can never execute an operation that was
not reviewed and deployed.

---

## File Navigation

| File | Purpose |
|---|---|
| [README.md](./README.md) | This overview: concepts, modes, architecture, quick start |
| [apq-setup.md](./apq-setup.md) | APQ — runtime hashing, two-round-trip protocol, router config, Redis cache, client setup (Apollo Client + urql), curl testing, `require_id` lockdown |
| [manifest-based-pq.md](./manifest-based-pq.md) | Build-time manifests — generating with Rover CLI, manifest format, publishing to GraphOS, router enforcement, versioning strategy |
| [client-integration.md](./client-integration.md) | Client setup for Apollo Client (React/TypeScript), urql, Apollo iOS, REST/curl, debugging `PersistedQueryNotFound`, migration path |

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Apollo Router | >= 1.35.0 | Earlier versions have partial APQ support; `require_id` added in 1.35 |
| Rover CLI | >= 0.20.0 | Required for manifest publish; `rover persisted-queries` subcommand |
| Apollo GraphOS account | Any plan | Free Developer plan sufficient for APQ; manifest-based PQ requires Dedicated or Enterprise |
| `@apollo/client` | >= 3.7.0 | `createPersistedQueryLink` is stable in this range |
| `@urql/exchange-persisted` | >= 4.0.0 | urql v4 exchange |
| `@apollo/generate-persisted-query-manifest` | >= 1.0.0 | Build-time manifest extraction from client source |
| Redis | >= 6.0 | Optional — for multi-router APQ cache sharing; in-memory works for single-router setups |

---

## Quick Start

### Option A — APQ (lowest friction)

```bash
# 1. Enable APQ in router.yaml
cat >> router.yaml <<'EOF'
apq:
  enabled: true
  router:
    cache:
      in_memory:
        limit: 512
EOF

# 2. Start the router
router --config router.yaml --supergraph supergraph.graphql

# 3. Send your first APQ request — hash only (will receive PersistedQueryNotFound)
curl -s -X POST http://localhost:4000/ \
  -H 'Content-Type: application/json' \
  -d '{"extensions":{"persistedQuery":{"version":1,"sha256Hash":"ecf4edb46db40b5132295c0291d62fb65d6759a9eedfa4d5d612dd5ec54a6b38"}}}'

# 4. Retry with full query — router caches and responds
curl -s -X POST http://localhost:4000/ \
  -H 'Content-Type: application/json' \
  -d '{"query":"{__typename}","extensions":{"persistedQuery":{"version":1,"sha256Hash":"ecf4edb46db40b5132295c0291d62fb65d6759a9eedfa4d5d612dd5ec54a6b38"}}}'
```

### Option B — Manifest-based PQ (more secure)

```bash
# 1. Extract operations from client source
npx @apollo/generate-persisted-query-manifest \
  --config persisted-query-manifest.config.js \
  --output operations.json

# 2. Publish manifest to GraphOS
rover persisted-queries publish my-graph@production \
  --manifest operations.json

# 3. Enable enforcement in router.yaml
cat >> router.yaml <<'EOF'
persisted_queries:
  enabled: true
  safelist:
    enabled: true
    require_id: true
EOF

# 4. Test that arbitrary queries are now rejected
curl -s -X POST http://localhost:4000/ \
  -H 'Content-Type: application/json' \
  -d '{"query":"{__typename}"}' | jq .
# Expected: {"errors":[{"message":"PersistedQueryNotFound"}]}
```

---

## Architecture: Request Flow

```
Client (React/iOS/curl)
  |
  | POST /graphql
  | Body: { "extensions": { "persistedQuery": { "sha256Hash": "abc123..." } } }
  |
  v
Apollo Router
  |
  |--- Hash lookup (in-memory or Redis) ---> PQ Manifest / APQ Cache
  |         |
  |         |-- HIT: resolve to query AST, proceed to planning
  |         |
  |         +-- MISS (APQ): return PersistedQueryNotFound (client retries with full query)
  |         |
  |         +-- MISS (manifest mode, require_id: true): reject with 400
  |
  |--- Query plan cache (keyed on operation hash) ---> plan cache HIT: skip planning
  |
  v
Subgraph(s)
  |
  v
Response back to client
```

The query plan cache gets a particularly high hit rate when APQ is combined with a stable
manifest because the same hashes recur predictably. In practice, query plan cache hit rates
of 95%+ are achievable for well-structured SPAs, which translates directly to reduced CPU
cost on the router.

---

## Security Considerations

### APQ is not a security boundary by itself

APQ in default mode still accepts the first execution of any unknown query (the fallback
request that includes the full query body). This means APQ alone does not prevent schema
probing. To make APQ a security control you must enable `require_id: true` (see
[apq-setup.md](./apq-setup.md)), which transitions it from pure-APQ into something
functionally equivalent to manifest-based PQ.

### Hash collision risk

SHA-256 collision attacks are not a realistic concern for operational security. The hash
space (2^256) makes collisions computationally infeasible with current hardware.

### Replay attacks

A persisted query hash is not a secret. Anyone who can observe network traffic can replay
the same hash. Persisted queries defend against novel query injection, not replay of
legitimate operations. Rate limiting and authentication are separate controls.

---

## Related Documentation

- [Chapter 05 — Security](../../docs/05-security/README.md)
- [Chapter 17 — Caching Strategies](../../docs/17-caching-strategies/README.md)
- [Chapter 08 — Supergraph Architecture](../../docs/08-supergraph-architecture/README.md)
- [examples/02-apollo-router](../02-apollo-router/) — full router.yaml with all settings
- [examples/12-security](../12-security/) — OPA policies, JWT validation, depth limiting
