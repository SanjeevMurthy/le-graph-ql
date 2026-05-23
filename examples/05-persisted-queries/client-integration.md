# Client Integration for Persisted Queries

> Companion docs: [../../docs/05-security/](../../docs/05-security/) and
> [../../docs/17-caching-strategies/](../../docs/17-caching-strategies/)

This file covers the complete client-side setup for persisted queries across every major
client stack. Each section is self-contained — read only the section relevant to your
technology. All examples assume you have already configured the Apollo Router (see
[apq-setup.md](./apq-setup.md) for APQ or [manifest-based-pq.md](./manifest-based-pq.md)
for manifest-based PQ).

---

## 1. Apollo Client (React / TypeScript)

### Dependencies

```bash
npm install @apollo/client crypto-hash
# crypto-hash provides a consistent SHA-256 implementation that works in both
# browser (Web Crypto API) and Node.js (server-side rendering) environments.
# The built-in SubtleCrypto works in modern browsers but is unavailable in
# older browser targets and some Node.js contexts. crypto-hash normalizes this.
```

### Complete ApolloClient setup with link chain

```typescript
// src/lib/apollo-client.ts
import {
  ApolloClient,
  InMemoryCache,
  HttpLink,
  from,
  ApolloLink,
  Observable,
} from "@apollo/client";
import { onError } from "@apollo/client/link/error";
import { createPersistedQueryLink } from "@apollo/client/link/persisted-queries";
import { setContext } from "@apollo/client/link/context";
import { sha256 } from "crypto-hash";

// ---
// Error handling link — sits at the top of the chain so it catches errors
// from all downstream links including the persisted query link.
const errorLink = onError(({ graphQLErrors, networkError, operation }) => {
  if (graphQLErrors) {
    graphQLErrors.forEach(({ message, extensions }) => {
      // Log PersistedQueryNotFound separately — it indicates the APQ cache
      // was cleared (Redis restart, TTL expiry) or a hash mismatch bug.
      // In production with manifest-based PQ this should never appear.
      if (extensions?.code === "PERSISTED_QUERY_NOT_FOUND") {
        console.warn(
          `[APQ] PersistedQueryNotFound for operation: ${operation.operationName}`,
          { message }
        );
      } else {
        console.error(
          `[GraphQL error]: ${message}`,
          { operation: operation.operationName, extensions }
        );
      }
    });
  }
  if (networkError) {
    console.error(`[Network error]: ${networkError}`);
  }
});

// ---
// Auth link — injects the authorization token into every request header.
// Placed AFTER persistedQueryLink so the token is present on both the
// hash-only request and the fallback full-query request.
const authLink = setContext((_, { headers }) => {
  // Read token from wherever your auth state lives.
  // Using a synchronous read here; for async token refresh, use async setContext.
  const token =
    typeof window !== "undefined"
      ? window.localStorage.getItem("access_token")
      : null;

  return {
    headers: {
      ...headers,
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      // x-client-version helps the server correlate errors with client deploys
      "x-client-version": process.env.NEXT_PUBLIC_APP_VERSION ?? "unknown",
    },
  };
});

// ---
// Persisted query link — handles hash computation and the retry protocol.
// Must be the first link that processes outgoing operations (before authLink
// and httpLink) so it can intercept the response and issue the retry with
// full query body if needed.
const persistedQueryLink = createPersistedQueryLink({
  sha256,

  // useGETForHashedQueries: true sends hash-only requests as HTTP GET.
  // GET requests are cacheable at the CDN/proxy layer, which enables
  // full response caching for queries (not mutations).
  // Disable this if: (a) your variables are large (>2KB URL limit),
  //                  (b) your CDN does not support query-string based caching,
  //                  (c) you have CORS restrictions on GET from different origins.
  useGETForHashedQueries: true,

  // disable: (error) => boolean — return true to stop using APQ for this operation.
  // By default, Apollo Client disables APQ for a request if it receives an
  // unexpected server error (not PERSISTED_QUERY_NOT_FOUND). This is safe behavior.
  // In manifest PQ mode, you can make this stricter:
  // disable: () => false — never fall back, always use hash only.
  // Only set this after confirming all operations are in the manifest.
});

// ---
// HTTP link — performs the actual fetch. Configure timeouts and credentials here.
const httpLink = new HttpLink({
  uri: process.env.NEXT_PUBLIC_GRAPHQL_URL ?? "http://localhost:4000/",

  // credentials: "include" sends cookies with cross-origin requests.
  // Required if your router validates session cookies for authentication.
  // Use "same-origin" for same-domain deployments (more restrictive, safer).
  credentials: "same-origin",

  // fetchOptions: customize the underlying fetch call.
  // The abort controller timeout ensures hung connections do not block the UI.
  fetchOptions: {
    // Note: fetch timeout via AbortController is the correct approach.
    // Setting a timeout in fetchOptions is non-standard; use AbortController instead.
  },

  // fetch: (uri, options) => custom fetch with timeout and abort handling
  fetch: (uri, options) => {
    const controller = new AbortController();
    // 30 second timeout — long enough for complex queries, short enough to avoid
    // hanging the UI indefinitely on network issues.
    const timeoutId = setTimeout(() => controller.abort(), 30_000);
    return fetch(uri, { ...options, signal: controller.signal }).finally(() =>
      clearTimeout(timeoutId)
    );
  },
});

// ---
// Assemble the link chain.
// Evaluation order for outgoing operations (left to right):
//   errorLink -> persistedQueryLink -> authLink -> httpLink
//
// errorLink wraps everything so it catches errors from all links.
// persistedQueryLink intercepts before auth so it can re-run the full chain on retry.
// authLink injects headers just before the HTTP request.
// httpLink executes the request.
export const client = new ApolloClient({
  link: from([errorLink, persistedQueryLink, authLink, httpLink]),

  cache: new InMemoryCache({
    // typePolicies: configure per-type cache behavior.
    // Providing explicit key fields prevents cache collisions for types
    // where the default `id` field is not the correct cache key.
    typePolicies: {
      Product: {
        keyFields: ["id"],
      },
      User: {
        keyFields: ["id"],
      },
    },
  }),

  // defaultOptions: apply globally to all queries/mutations unless overridden.
  defaultOptions: {
    watchQuery: {
      // fetchPolicy: "cache-and-network" shows cached data immediately while
      // refreshing in the background. Good UX for most read-heavy views.
      fetchPolicy: "cache-and-network",
      errorPolicy: "all",
    },
    query: {
      fetchPolicy: "network-only",
      errorPolicy: "all",
    },
    mutate: {
      errorPolicy: "all",
    },
  },

  // connectToDevTools: expose cache state in Apollo Client DevTools browser extension.
  // Only meaningful in development — no security risk but wastes postMessage overhead
  // in production.
  connectToDevTools: process.env.NODE_ENV === "development",
});
```

### Usage in a React component

```typescript
// src/features/products/ProductPage.tsx
import { useQuery } from "@apollo/client";
import { gql } from "@apollo/client";

// This operation will be included in the persisted query manifest.
// The name "GetProduct" is the stable identifier used in Studio reporting.
const GET_PRODUCT = gql`
  query GetProduct($id: ID!) {
    product(id: $id) {
      id
      name
      price
      category {
        id
        name
      }
    }
  }
`;

export function ProductPage({ productId }: { productId: string }) {
  const { data, loading, error } = useQuery(GET_PRODUCT, {
    variables: { id: productId },
    // fetchPolicy: "cache-first" is appropriate for product detail pages
    // where data changes infrequently.
    fetchPolicy: "cache-first",
  });

  // No persisted query code needed here — the link chain handles everything.
  if (loading) return <div>Loading...</div>;
  if (error) return <div>Error: {error.message}</div>;
  return <div>{data?.product.name}</div>;
}
```

---

## 2. urql

### Dependencies

```bash
npm install urql @urql/exchange-persisted @urql/exchange-graphcache graphql
```

### Complete urql client setup

```typescript
// src/lib/urql-client.ts
import { createClient, fetchExchange, mapExchange } from "urql";
import { cacheExchange } from "@urql/exchange-graphcache";
import { persistedExchange } from "@urql/exchange-persisted";
import { authExchange } from "@urql/exchange-auth";

// authExchange handles token injection and token refresh.
// It must come before persistedExchange because persisted exchange needs
// to see the final headers (including auth) for the retry request.
const auth = authExchange(async (utilities) => {
  // getToken is called once at initialization and after every token refresh.
  let token = localStorage.getItem("access_token") ?? "";

  return {
    addAuthToOperation(operation) {
      if (!token) return operation;
      return utilities.appendHeaders(operation, {
        authorization: `Bearer ${token}`,
      });
    },
    didAuthError(error) {
      return error.graphQLErrors.some(
        (e) => e.extensions?.code === "UNAUTHENTICATED"
      );
    },
    async refreshAuth() {
      // Implement your token refresh logic here.
      // On refresh failure, redirect to login.
      const newToken = await refreshAccessToken();
      token = newToken;
      localStorage.setItem("access_token", newToken);
    },
    willAuthError(operation) {
      // Return true to eagerly refresh before the token expires.
      // This prevents a failed request followed by a retry.
      return isTokenExpiringSoon(token);
    },
  };
});

export const client = createClient({
  url: process.env.NEXT_PUBLIC_GRAPHQL_URL ?? "http://localhost:4000/",

  exchanges: [
    // mapExchange: lightweight middleware for logging and error handling.
    // Placed first to observe all operations and results.
    mapExchange({
      onError(error, operation) {
        console.error(
          `[urql] Error in operation ${operation.query.definitions[0]?.name?.value}:`,
          error
        );
      },
    }),

    // cacheExchange: normalized client-side cache.
    // Must come before persistedExchange and fetchExchange.
    cacheExchange({
      // keys: define how to derive the cache key for each type.
      // Without this, urql defaults to `id` — fine for most types.
      keys: {
        Product: (data) => data.id as string,
        User: (data) => data.id as string,
        // For types without a natural ID (e.g., pagination metadata),
        // return null to prevent caching.
        PageInfo: () => null,
      },
    }),

    // auth exchange handles token injection and refresh
    auth,

    // persistedExchange: APQ and manifest-based PQ protocol.
    persistedExchange({
      preferGetForPersistedQueries: true,

      // enforcePersistedQueries: set to true in production with manifest PQ.
      // Set to false in development or APQ-only setups where unknown queries
      // should still work via fallback.
      enforcePersistedQueries:
        process.env.NODE_ENV === "production" &&
        process.env.NEXT_PUBLIC_PQ_ENFORCED === "true",

      // handleError: called when PersistedQueryNotFound is received.
      // In enforcePersistedQueries mode this indicates a bug —
      // the hash is in the client but not in the server manifest.
      handleError: (error, retry) => {
        if (
          error.graphQLErrors.some(
            (e) => e.extensions?.code === "PERSISTED_QUERY_NOT_FOUND"
          )
        ) {
          // Log to your error tracking system (Sentry, Datadog, etc.)
          console.error("[PQ] PersistedQueryNotFound — manifest may be stale");
          // retry() falls back to full query. Remove this call in strict mode.
          retry();
        }
      },
    }),

    // fetchExchange must always be last
    fetchExchange,
  ],
});
```

---

## 3. Mobile: Apollo iOS (Swift)

Apollo iOS generates Swift code from your GraphQL operations and supports manifest-based
persisted queries natively since version 1.3.0.

### Dependencies (Package.swift)

```swift
// Package.swift
dependencies: [
    .package(
        url: "https://github.com/apollographql/apollo-ios",
        // Pin to a specific version for reproducible builds.
        // Apollo iOS 1.x has stable PQ support.
        from: "1.7.0"
    )
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "Apollo", package: "apollo-ios"),
            .product(name: "ApolloWebSocket", package: "apollo-ios"),
        ]
    )
]
```

### Code generation with PQ manifest output

```yaml
# apollo-codegen-config.yml
schemaNamespace: MyAppAPI
input:
  schemaSearchPaths:
    - "**/*.graphqls"
  operationSearchPaths:
    - "**/*.graphql"
output:
  schemaTypes:
    moduleType:
      swiftPackageManager: {}
    path: "./Sources/Schema"
  operations:
    inSchemaModule: {}
  # Generate the persisted query manifest alongside Swift code.
  # This manifest is the same format as the one generated by
  # @apollo/generate-persisted-query-manifest on the web side.
  operationManifest:
    path: "./operationManifest.json"
    # apollo: use Apollo's hash normalization (compatible with Apollo Router)
    # sha256: raw SHA-256 without normalization (use only if router is configured accordingly)
    version: apollo
```

### Apollo iOS client configuration

```swift
// Sources/MyApp/Network/NetworkClient.swift
import Apollo
import ApolloAPI

class NetworkClient {
    static let shared = NetworkClient()

    private(set) lazy var client: ApolloClient = {
        // Read the persisted query manifest bundled with the app.
        // The manifest is generated at build time and included as a bundle resource.
        guard
            let manifestURL = Bundle.main.url(
                forResource: "operationManifest",
                withExtension: "json"
            ),
            let manifestData = try? Data(contentsOf: manifestURL)
        else {
            fatalError("operationManifest.json not found in app bundle")
        }

        // PersistedQueryManifest parses the manifest and provides hash lookups.
        let manifest = try! PersistedQueryManifest(from: manifestData)

        let store = ApolloStore(
            cache: InMemoryNormalizedCache()
        )

        let provider = NetworkInterceptorProvider(
            store: store,
            client: URLSessionClient()
        )

        // NetworkTransport with PQ configuration.
        // APQNetworkTransport automatically handles the two-round-trip protocol.
        let transport = RequestChainNetworkTransport(
            interceptorProvider: provider,
            endpointURL: URL(string: "https://api.example.com/graphql")!,
            additionalHeaders: [
                "x-client-version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                "x-platform": "ios",
            ],
            autoPersistQueries: true,
            // useGETForQueries: true enables GET requests for hash-only queries,
            // enabling CDN response caching. Only use if your CDN is configured
            // to cache GraphQL GET responses.
            useGETForQueries: false,
            // requestBodyCreator: provides the manifest-based hash lookup.
            // Without this, Apollo iOS falls back to computing the hash at runtime
            // (APQ behavior). Providing the manifest enables manifest-based PQ.
            requestBodyCreator: APQRequestBodyCreator(manifest: manifest)
        )

        return ApolloClient(networkTransport: transport, store: store)
    }()
}
```

### Making a query in Swift

```swift
// Usage — no PQ-specific code needed at the call site
NetworkClient.shared.client.fetch(
    query: GetProductQuery(id: productId)
) { result in
    switch result {
    case .success(let graphQLResult):
        if let product = graphQLResult.data?.product {
            print("Product: \(product.name)")
        }
    case .failure(let error):
        print("Error: \(error)")
    }
}
```

---

## 4. REST Clients and curl — Manual Persisted Query Format

For backend-to-backend calls or integration testing where you are not using a GraphQL
client library, you must manually construct the persisted query request format.

### Computing the correct hash

```bash
# Apollo's hash normalization:
# 1. Parse the query document
# 2. Remove redundant whitespace (collapse to single spaces, trim)
# 3. Sort field selections alphabetically within each selection set (optional, depends on config)
# 4. Compute SHA-256 of the resulting string

# Simple case: single-line query with no extra whitespace
QUERY='query GetProduct($id: ID!) { product(id: $id) { id name price } }'
HASH=$(printf '%s' "$QUERY" | sha256sum | cut -d' ' -f1)
echo "$HASH"
```

### Standard APQ request (hash only — after warm cache)

```bash
curl -s -X POST https://api.example.com/graphql \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer eyJhbGci...' \
  -d "{
    \"variables\": {
      \"id\": \"product-123\"
    },
    \"extensions\": {
      \"persistedQuery\": {
        \"version\": 1,
        \"sha256Hash\": \"$HASH\"
      }
    }
  }" | jq .
```

### GET request format (CDN-cacheable)

```bash
# Variables and extensions must be URL-encoded JSON
VARIABLES='{"id":"product-123"}'
EXTENSIONS="{\"persistedQuery\":{\"version\":1,\"sha256Hash\":\"$HASH\"}}"

curl -s -G "https://api.example.com/graphql" \
  -H 'Authorization: Bearer eyJhbGci...' \
  --data-urlencode "variables=$VARIABLES" \
  --data-urlencode "extensions=$EXTENSIONS" | jq .
```

### Full request format for registering a new operation (APQ fallback)

```bash
curl -s -X POST https://api.example.com/graphql \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer eyJhbGci...' \
  -d "{
    \"query\": \"$QUERY\",
    \"variables\": {
      \"id\": \"product-123\"
    },
    \"extensions\": {
      \"persistedQuery\": {
        \"version\": 1,
        \"sha256Hash\": \"$HASH\"
      }
    }
  }" | jq .
```

---

## 5. Verifying PQ is Working

### Response headers to inspect

```bash
curl -v -X POST https://api.example.com/graphql \
  -H 'Content-Type: application/json' \
  -d '{"extensions":{"persistedQuery":{"version":1,"sha256Hash":"<your-hash>"}}}' \
  2>&1 | grep -E '^[<>]|x-apollo'

# Look for:
# < x-apollo-cache-hit: true      -- APQ cache hit on the router
# < x-cache: HIT                  -- CDN cache hit (only with GET requests)
# < x-request-id: ...             -- useful for correlating with router logs
```

### Apollo Studio PQ usage report

In Apollo Studio, navigate to Operations > Persisted Queries. You will see:

- Registered operations count and their names
- Request count per operation hash
- Operations with zero requests in the last 30 days (safe to remove from manifest)
- Hash mismatch errors (should be exactly zero — investigate immediately if non-zero)

### Router logs confirming cache hits

```bash
# In router logs (JSON format), APQ cache hits appear as:
# { "level": "debug", "message": "persisted query found", "hash": "abc123...", "operation": "GetProduct" }

# Cache misses appear as:
# { "level": "debug", "message": "persisted query not found", "hash": "abc123...", "returnedNotFound": true }

# Enable debug logging in router.yaml for local testing only:
# telemetry:
#   tracing:
#     common:
#       enabled: true
# (debug logging in production is too verbose — use trace sampling instead)
```

---

## 6. Debugging

### PersistedQueryNotFound

```
Error: { "errors": [{ "message": "PersistedQueryNotFound",
                       "extensions": { "code": "PERSISTED_QUERY_NOT_FOUND" } }] }
```

This error means the router received a hash it does not recognize. Common causes:

| Cause | Diagnosis | Fix |
|---|---|---|
| APQ cache was cleared (Redis restart, TTL expired) | Check Redis availability and TTL config | Wait for client library to automatically retry with full query; ensure Redis TTL > deploy cycle |
| Router restarted with empty in-memory cache | Check router restart logs | Switch to Redis-backed APQ for multi-replica deployments |
| Hash mismatch: client hashing differently than server expects | Compare `sha256sum` of normalized query against manifest ID | Ensure client uses Apollo's normalization library, not a hand-rolled hash |
| Manifest not yet published for new operation | Check `rover persisted-queries list` | Publish manifest before deploying client |
| `require_id: true` enabled before clients updated | Check timeline of config changes | Use rolling transition strategy (see manifest-based-pq.md) |

### Hash mismatch (PERSISTED_QUERY_HASH_MISMATCH)

```
Error: { "errors": [{ "message": "PersistedQueryHashMismatch",
                       "extensions": { "code": "PERSISTED_QUERY_HASH_MISMATCH" } }] }
```

The router received a request with both a hash and a query body, but the SHA-256 of the
query body does not match the provided hash. This is almost always caused by:

1. Sending a modified query body alongside a stale hash
2. A middleware layer (BFF, service mesh) that modifies the request body after the hash
   is computed but before the router receives it
3. Character encoding issues (UTF-8 vs UTF-16 — GraphQL queries must be hashed as UTF-8)

```bash
# Verify locally: compute the hash yourself and compare to what the client sends
echo -n "query GetProduct(\$id: ID!) { product(id: \$id) { id name price } }" | sha256sum
```

### Common pitfalls

| Pitfall | Symptom | Resolution |
|---|---|---|
| Hash computed on prettified query | Hash mismatch | Always hash the minified/normalized query string, not the human-readable one |
| Fragment definitions not included in hash input | PERSISTED_QUERY_NOT_FOUND on queries with fragments | Ensure client includes all inline fragments in the hash input |
| Operation includes `__typename` injection | Hash in manifest does not match runtime hash | Apollo Client automatically injects `__typename` — the hash must be computed AFTER injection, which Apollo Client handles correctly; do not hash the raw gql string manually |
| Variables included in hash | Hash changes per request | Variables are never included in the hash; only the query document is hashed |

---

## 7. Migration Path: Ad-Hoc Queries to Persisted Queries

Migrating a running production system from arbitrary query strings to persisted queries
without a flag day requires a phased approach. This avoids coordinating client and server
deploys simultaneously.

### Phase 1 — Enable APQ, no enforcement (week 1)

```yaml
# router.yaml — APQ enabled, require_id false (default)
apq:
  enabled: true
  router:
    cache:
      redis:
        urls: ["redis://${REDIS_HOST}:6379"]
        ttl: 86400
```

Deploy this router config first. All existing clients continue working unchanged.
New clients with `createPersistedQueryLink` configured start warming the APQ cache.

Metric to track: APQ cache hit rate. Target > 90% before moving to Phase 2.

### Phase 2 — Add manifest generation to CI (week 2)

```bash
# Add to build pipeline (does not affect production yet)
npx generate-persisted-query-manifest
rover persisted-queries publish ${APOLLO_GRAPH_REF} --manifest persisted-query-manifest.json
```

Keep publishing on every CI run. The manifest accumulates operations as your CI runs.
Monitor Studio to confirm all operations are appearing in the manifest.

Metric to track: operations in manifest vs. operations seen in Studio traffic. Target 100% coverage.

### Phase 3 — Enable safelist in staging (week 3)

```yaml
# router.staging.yaml
persisted_queries:
  enabled: true
  safelist:
    enabled: true
    require_id: false   # safelist enabled but not enforced yet
```

Run your full integration test suite against staging. All operations should pass.
Any test that uses raw query strings (not via a client library) will reveal gaps.

### Phase 4 — Enforce require_id in staging (week 4)

```yaml
# router.staging.yaml
persisted_queries:
  enabled: true
  safelist:
    enabled: true
    require_id: true   # strict enforcement
```

Any test failure at this stage reveals an operation not in the manifest. Fix by either:
- Adding the operation to your client source and regenerating the manifest, or
- Updating the test to use the client library instead of raw query strings.

### Phase 5 — Enforce require_id in production (week 5+)

Enable `require_id: true` in the production router config during a low-traffic window.
Monitor for five minutes after deploy. Roll back immediately if error rate increases.

After a successful enforcement period of 30 days with zero PersistedQueryNotFound errors,
you can declare the migration complete and update your runbooks to reflect the new operational
baseline.

---

## Key Design Decisions

**Why use crypto-hash instead of the browser's built-in SubtleCrypto?**
SubtleCrypto returns a Promise, which requires async handling in the link chain. Some
environments (older React Native, SSR contexts) do not have SubtleCrypto available at all.
The `crypto-hash` library provides a consistent, synchronous-friendly API that works in
all JavaScript environments and delegates to native crypto implementations when available,
avoiding pure-JS fallbacks.

**Why is the migration phased over five weeks rather than a single deployment?**
The main risk in migrating to persisted queries is discovering operations that were not
captured in the manifest — either legacy client versions in the wild, or test harnesses
that bypass the client library. A phased approach makes each failure mode observable and
reversible in isolation. A flag-day migration risks simultaneous failures from multiple
sources that are harder to diagnose.

**Why does Apollo iOS require the manifest to be bundled with the app?**
Mobile app deployments cannot be updated as frequently as web clients. The manifest bundled
with the app is the authoritative record of which operations that version of the app can
send. When you publish a new manifest to GraphOS you should ensure backward compatibility
with all app store-distributed versions still in active use — typically the current and
two previous minor versions.

**Why are variables never included in the hash?**
Variables are runtime data, not part of the operation structure. Including variables in
the hash would produce a unique hash per unique variable set, defeating the entire purpose
of query caching. The hash identifies the operation's shape; the variables parameterize
its execution. The router caches query plans by operation hash and executes them with
whatever variables arrive.

---

## Related Documentation

- [apq-setup.md](./apq-setup.md) — APQ configuration and Redis cache setup
- [manifest-based-pq.md](./manifest-based-pq.md) — build-time manifest generation and publishing
- [Chapter 05 — Security](../../docs/05-security/README.md)
- [Chapter 17 — Caching Strategies](../../docs/17-caching-strategies/README.md)
- [examples/02-apollo-router](../02-apollo-router/) — full router.yaml reference
- [examples/12-security](../12-security/) — complementary security controls
