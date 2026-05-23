# Query Security — Defending Against Malicious GraphQL Queries

Companion docs: `../../docs/05-security/`

GraphQL's flexibility is a double-edged sword. Clients can request exactly the data they need — but a malicious client can also request data in shapes that exhaust CPU, memory, or database connections. This document covers query depth limiting, complexity scoring, alias abuse prevention, introspection control, CORS configuration, variable injection risks, batch request limiting, and rate limiting.

---

## Query Depth Limiting

Query depth is the maximum nesting level of a GraphQL query. Unlike REST, where endpoint nesting is fixed by the URL design, GraphQL nesting is arbitrarily deep.

### What "depth" means in GraphQL

```graphql
# Depth 1
{ products { id } }

# Depth 2
{ user { orders { id } } }

# Depth 6 — approaching the attack threshold
{
  user(id: "1") {
    orders {
      items {
        product {
          reviews {
            user {
              displayName
            }
          }
        }
      }
    }
  }
}

# Depth 8+ — exponential resolver invocations on recursive/circular types
{
  user(id: "1") {
    friends {           # N users
      friends {         # N^2 users
        friends {       # N^3 users
          friends {     # N^4 users
            id name     # N^4 database queries
          }
        }
      }
    }
  }
}
```

In a schema where `User.friends` returns `[User!]`, each nesting level multiplies the resolver invocation count by the average friend count. At depth 8 with an average of 10 friends per user, a single query triggers up to 10^7 (10 million) resolver calls.

### Apollo Router `max_depth` configuration

```yaml
# router.yaml
limits:
  # Maximum allowed query depth. Queries exceeding this depth are rejected
  # before execution with a 400 Bad Request and an informative error message.
  # The Router counts depth from the root operation (Query/Mutation/Subscription).
  #
  # 12 is a conservative default for complex e-commerce schemas with deep entity graphs.
  # Simple schemas can use 6-8. Adjust based on the deepest legitimate query in your client.
  max_depth: 12

  # Reject queries with more than this many total fields (the sum of all fields
  # across all selection sets in the query document).
  # 500 prevents "width attacks" — queries that select hundreds of fields at
  # the same level to amplify data volume.
  max_height: 500

  # Maximum number of root fields (fields on the query root, before field selection).
  # Limits the number of top-level resolvers that run in parallel.
  max_root_fields: 20

  # Maximum number of aliases in a single query. Aliases allow renaming fields:
  # { a1: user(id: 1) { name } a2: user(id: 2) { name } }
  # Without a limit, an attacker can alias the same field 1000 times to invoke
  # the resolver 1000 times in one request.
  max_aliases: 30
```

### Finding the right `max_depth` for your schema

Before setting `max_depth`, run this analysis to find the depth of the deepest legitimate client query:

```bash
# Extract all queries from your client codebase and measure their depths
# Using graphql-depth-limit or similar tool
find ./src -name "*.graphql" -o -name "*.gql" | \
  xargs grep -h "query\|mutation\|subscription" | \
  # Parse and measure depth — use a custom script or graphql-inspector
  node scripts/measure-query-depth.js

# Alternatively, use Apollo Studio's operation insights to see max depth
# across all observed client operations in the last 30 days.
```

Set `max_depth` to the observed maximum + 2 to allow for iteration without breaking existing clients.

---

## Query Complexity Limiting

Query complexity assigns a cost to each field and rejects queries whose total cost exceeds a threshold. This is more fine-grained than depth limiting — a query that is not very deep but selects a massive number of fields (or expensive computed fields) can still be rejected.

### Apollo Router `max_height` (field count) limit

The `max_height` limit in `router.yaml` (see above) counts total fields. This is a simple complexity proxy. For most GraphQL APIs it is sufficient.

### Subgraph-level complexity scoring with `graphql-query-complexity`

For APIs with expensive fields (fields that trigger external API calls, full-text search, or aggregations), assign weighted complexity scores:

```bash
npm install graphql-query-complexity
```

```typescript
// src/plugins/complexity.ts
import {
  createComplexityPlugin,
  simpleEstimator,
  fieldExtensionsEstimator,
} from 'graphql-query-complexity';

// The maximum allowed complexity score for a single query.
// Define this based on empirical measurement of your heaviest legitimate operations.
const MAX_QUERY_COMPLEXITY = 1000;

export const complexityPlugin = {
  requestDidStart: () => ({
    didResolveOperation: ({ request, document, schema, contextValue }) => {
      const complexity = getComplexity({
        schema,
        operationName: request.operationName,
        query: document,
        variables: request.variables,
        estimators: [
          // fieldExtensionsEstimator reads complexity from schema field extensions.
          // Apply this first so per-field overrides take precedence.
          fieldExtensionsEstimator(),

          // simpleEstimator assigns a flat cost to each field.
          // cost: 1 is the baseline — most fields cost 1.
          simpleEstimator({ defaultComplexity: 1 }),
        ],
      });

      if (complexity > MAX_QUERY_COMPLEXITY) {
        throw new GraphQLError(
          `Query complexity ${complexity} exceeds maximum allowed ${MAX_QUERY_COMPLEXITY}.`,
          { extensions: { code: 'QUERY_TOO_COMPLEX', complexity } }
        );
      }

      // Log complexity for monitoring — track the P99 complexity of production queries
      // to inform future limit adjustments.
      console.log(`Query complexity: ${complexity}`, {
        operationName: request.operationName,
        complexity,
      });
    },
  }),
};
```

### Assigning per-field complexity via extensions

```typescript
// In your type definitions (using makeExecutableSchema)
const typeDefs = `
  type Query {
    # Mark expensive fields with their relative cost using field extensions
    searchProducts(query: String!, filters: ProductFilters): [Product!]!
    productAnalytics(id: ID!, period: DateRange!): Analytics
  }
`;

const resolvers = {
  Query: {
    searchProducts: {
      resolve: (_, args, context) => {
        // ... full-text search implementation ...
      },
      // The complexity estimator reads this extensions object
      extensions: {
        complexity: ({ args, childComplexity }) =>
          // Search is expensive: base cost 50 + child field cost
          // childComplexity accounts for nested fields the client selected
          50 + childComplexity,
      },
    },

    productAnalytics: {
      resolve: (_, args, context) => {
        // ... heavy aggregation query ...
      },
      extensions: {
        complexity: ({ args }) => {
          // Wider date ranges cost more to compute
          const days = daysBetween(args.period.from, args.period.to);
          return Math.min(days * 2, 200);  // Cap at 200 to prevent absurd scores
        },
      },
    },
  },
};
```

---

## Alias Abuse

GraphQL field aliases allow clients to rename fields in the response. This is a legitimate feature for requesting the same field multiple times with different arguments. It becomes an attack vector when used to invoke the same resolver hundreds of times in one request:

```graphql
# Legitimate alias use
{
  currentProduct: product(id: "prod-1") { name }
  compareProduct: product(id: "prod-2") { name }
}

# Alias amplification attack — 1 HTTP request = N resolver invocations
{
  p1: product(id: "1") { name stockLevel reviews { ... } }
  p2: product(id: "2") { name stockLevel reviews { ... } }
  p3: product(id: "3") { name stockLevel reviews { ... } }
  # ... p999 ...
}
```

With 999 aliases, a single request triggers 999 database queries (or DataLoader batches — DataLoader handles this reasonably, but the database load is still real).

### Router alias limit

```yaml
# router.yaml
limits:
  # Maximum aliases per query. 30 allows legitimate comparisons and complex UIs
  # without allowing amplification attacks.
  # Note: this counts ALL aliases in the document, not just root-level ones.
  max_aliases: 30
```

When `max_aliases` is exceeded, the Router returns:

```json
{
  "errors": [{
    "message": "Maximum number of aliases (30) exceeded.",
    "extensions": { "code": "REQUEST_VALIDATION_ERROR" }
  }]
}
```

---

## Introspection Control

GraphQL introspection (`__schema`, `__type`) is useful for development tools and schema exploration. In production, it is an attack enablement tool. Disable it unless you have a specific need.

### Disabling introspection in `router.yaml`

```yaml
# router.yaml

# Disable the Apollo Sandbox (browser-based GraphQL IDE embedded in the Router).
# Sandbox is automatically disabled when NODE_ENV=production but explicit
# config is more reliable than environment variable inference.
sandbox:
  enabled: false

# Disable the Router's landing page (the default "Welcome to Apollo Router"
# page that loads when accessing the root URL in a browser).
# In production, the root URL should return 404 or redirect to your docs.
homepage:
  enabled: false

# Disable introspection queries entirely.
# When disabled, queries containing __schema or __type return a clear error.
# This prevents schema enumeration without revealing that introspection is
# available but restricted — the error is explicit.
introspection: false
```

### When to keep introspection enabled

| Scenario | Recommendation |
|---------|---------------|
| Public GraphQL API (GitHub, Shopify pattern) | Keep introspection enabled — your schema IS your public API contract |
| Internal API with authenticated users only | Restrict introspection to authenticated users via the `@authenticated` directive on `__schema` |
| API with APQ (persisted queries) enforced | Introspection is moot — only pre-registered queries can execute anyway |
| Development / staging | Always enabled — tooling depends on it |

### Persisted queries as an introspection alternative

If all legitimate clients use persisted (pre-registered) queries, the schema is not exposed through introspection AND unknown queries cannot execute. This is a stronger security posture than disabling introspection alone.

```yaml
# router.yaml
# APQ enforcement: only pre-registered queries can execute.
# Unknown queries are rejected regardless of whether they contain valid GraphQL.
apq:
  enabled: true
  # When mode is "require", the Router rejects any query not in the persisted query manifest.
  mode: require
```

With APQ in `require` mode, an attacker who somehow obtains the schema cannot construct and execute new queries — the manifest acts as an allowlist.

---

## Batch Request Limiting

Apollo Server (and many GraphQL clients) support sending multiple operations in a single HTTP request as a JSON array:

```json
[
  { "query": "{ products { id name } }" },
  { "query": "{ user(id: \"42\") { email } }" },
  { "query": "{ orders { total } }" }
]
```

Without limits, a single HTTP request can bundle arbitrarily many operations, bypassing per-request rate limits.

### Apollo Router batch limiting

```yaml
# router.yaml
batching:
  # Enable batch request processing. Disable entirely if your clients do not
  # use batching — this eliminates the attack surface.
  enabled: true

  mode: batch_http_link
  # mode options:
  # - batch_http_link: Apollo Client BatchHTTPLink format (JSON array)
  # - relay: Relay batch format

  # Maximum number of operations in a single batch request.
  # 10 is reasonable for Apollo Client's default batching behavior
  # (which batches all operations fired within a 10ms window).
  max_batch_size: 10
```

---

## Variable Injection

### Why GraphQL is not inherently vulnerable to SQL injection

GraphQL variables are separate from the query document and are strongly typed. A resolver that uses variables correctly passes them to the database driver as separate parameters, never as string interpolation.

```typescript
// SAFE — parameterized query; userId is a bind parameter, never string-concatenated
const result = await pool.query(
  'SELECT * FROM products WHERE category_id = $1 AND price > $2',
  [args.categoryId, args.minPrice]   // Passed as parameters, not interpolated
);

// SAFE — Prisma ORM; all arguments are parameterized automatically
const products = await prisma.product.findMany({
  where: {
    categoryId: args.categoryId,
    price: { gt: args.minPrice },
  },
});
```

The PostgreSQL driver and Prisma both treat variable values as opaque data, not executable SQL fragments. A variable value of `'; DROP TABLE products; --` is stored as a string literal, not executed.

### What IS dangerous in GraphQL resolvers

```typescript
// DANGEROUS — raw string concatenation in a SQL query
// An attacker who controls args.sortField can inject SQL
const result = await pool.query(
  `SELECT * FROM products ORDER BY ${args.sortField} ${args.sortDir}`,
  //                              ^^^^^^^^^^^^^^^^ USER CONTROLLED — NEVER DO THIS
);

// FIX — validate against an allowlist of known column names
const ALLOWED_SORT_FIELDS = new Set(['name', 'price', 'created_at']);
if (!ALLOWED_SORT_FIELDS.has(args.sortField)) {
  throw new GraphQLError('Invalid sort field', { extensions: { code: 'BAD_USER_INPUT' } });
}
const result = await pool.query(
  `SELECT * FROM products ORDER BY ${args.sortField} ${args.sortDir === 'desc' ? 'DESC' : 'ASC'}`,
);

// DANGEROUS — passing user input to shell commands
import { exec } from 'child_process';
exec(`ffmpeg -i ${args.videoUrl} -o output.mp4`);
// args.videoUrl = "input.mp4; rm -rf /; echo" — command injection

// FIX — use a library with argument arrays instead of shell string interpolation
import { execFile } from 'child_process';
execFile('ffmpeg', ['-i', args.videoUrl, '-o', 'output.mp4']);
```

### Validating input variables

Use a schema validation library to reject malformed variables before they reach the resolver:

```typescript
// Using Zod for input validation in resolvers
import { z } from 'zod';

const CreateProductInputSchema = z.object({
  name: z.string().min(1).max(255),
  price: z.number().positive(),
  categoryId: z.string().uuid(),  // Reject non-UUID strings before they hit the DB
  description: z.string().max(10000).optional(),
});

Mutation: {
  createProduct: async (_, { input }, context) => {
    // Validate and parse input — throws ZodError if invalid
    const validated = CreateProductInputSchema.parse(input);
    return productRepository.create(validated, context.orgId);
  },
},
```

---

## CORS Configuration

Cross-Origin Resource Sharing (CORS) is more complex for GraphQL than REST because:

1. GraphQL endpoints are always `POST /graphql` — the same URL for all operations. REST CORS rules typically allow wildcards because each endpoint has specific behavior. GraphQL requires more nuanced rules.
2. GraphQL APIs often combine cookie-based session auth with bearer token auth. Cookie auth with CORS wildcard is a CSRF vulnerability.
3. Browser-based schema polling tools (Apollo Sandbox, GraphQL Playground) make their own CORS preflight requests.

### Complete `cors` section in `router.yaml`

```yaml
# router.yaml
cors:
  # List of origins that are allowed to make cross-origin requests.
  # Use exact origins in production — do not use wildcards for authenticated APIs.
  # Wildcards are acceptable ONLY for fully public, unauthenticated APIs.
  origins:
    - "https://app.mycompany.com"
    - "https://admin.mycompany.com"
    - "https://mobile.mycompany.com"
    # Staging environment — add explicitly if staging has a different origin
    - "https://staging.mycompany.com"

  # Do not use allow_any_origin: true for authenticated APIs.
  # This allows ANY website to make credentialed requests to your GraphQL API
  # in the context of a logged-in user's browser session.
  # allow_any_origin: false  # This is the default — do not override

  # HTTP methods to allow in cross-origin requests.
  # GraphQL only uses POST (queries/mutations) and GET (APQ hash-only requests).
  # OPTIONS is automatically handled for preflight.
  methods:
    - POST
    - GET

  # Headers that clients are allowed to send in cross-origin requests.
  # Include all headers your clients need to send.
  allow_headers:
    - Content-Type       # Required for JSON body
    - Authorization      # JWT bearer token
    - Apollo-Require-Preflight  # Apollo Client CSRF protection
    - X-Correlation-ID   # Request tracing
    - X-Apollo-Operation-Name   # For APQ and operation logging

  # Headers that the browser is allowed to read from the response.
  # Expose custom response headers if clients need them (e.g., rate limit headers).
  expose_headers:
    - X-RateLimit-Remaining
    - X-RateLimit-Reset

  # Allow credentials (cookies, Authorization headers) in cross-origin requests.
  # Required if your API uses cookie-based sessions. When true, allow_any_origin
  # must be false (the browser enforces this — the combination is an error).
  allow_credentials: true

  # How long (in seconds) browsers should cache the preflight response.
  # 3600 seconds (1 hour) reduces preflight OPTIONS request overhead.
  max_age_in_seconds: 3600
```

### CSRF protection for GraphQL

Apollo Client 3.x adds a `Apollo-Require-Preflight` header to all requests. This header triggers a CORS preflight for cross-origin requests, which prevents CSRF attacks that use form submissions or `fetch()` without custom headers (which don't trigger preflight). Include this header in `allow_headers` above.

---

## Rate Limiting

Rate limiting in Apollo Router is configured via `traffic_shaping`. Limits can be applied globally or per-client.

### Complete `traffic_shaping` configuration

```yaml
# router.yaml
traffic_shaping:
  all:
    # Global rate limit — applies to all requests regardless of client identity.
    # This is a fallback; per-client limits below are more granular.
    deduplicate_query: true  # Deduplicate identical in-flight queries to reduce backend load

  router:
    # Rate limit all incoming requests (before authentication).
    # Configured as a token bucket: capacity tokens, refilled at rate tokens/interval.
    global_rate_limit:
      capacity: 1000       # Bucket capacity — allows 1000 requests before throttling
      interval: 1s         # Refill interval — bucket refills to capacity every second

  subgraph:
    # Per-subgraph rate limits — protect individual subgraphs from Router overload.
    all:
      # Limit total requests the Router sends to any subgraph per second.
      # Prevents a single slow subgraph from being overwhelmed.
      global_rate_limit:
        capacity: 500
        interval: 1s

      # Retry configuration for transient subgraph errors.
      retry:
        enabled: true
        min_jitter_ms: 100
        max_jitter_ms: 500

    products:
      # The products subgraph handles expensive search operations — tighter limit.
      global_rate_limit:
        capacity: 200
        interval: 1s
```

### Per-client rate limiting using coprocessor (advanced)

Apollo Router's built-in `traffic_shaping` applies global limits. For per-client limits (throttle individual users or API keys), use a coprocessor that checks Redis:

```typescript
// coprocessor/src/rate-limiter.ts
// Apollo Router coprocessor — runs as a sidecar to the Router
// and intercepts requests before they execute.

import { createClient } from 'redis';

const redis = createClient({ url: process.env.REDIS_URL });
await redis.connect();

export async function checkRateLimit(
  clientId: string,    // Extracted from JWT sub claim in the request
  limitPerMinute: number = 100
): Promise<{ allowed: boolean; remaining: number; resetAt: number }> {
  const key = `rate-limit:${clientId}`;
  const now = Date.now();
  const windowStart = now - 60_000;  // 60-second sliding window

  // Use Redis sorted sets for a sliding window rate limiter.
  // Score = timestamp (ms); members = unique request IDs (prevent dedup issues).
  const pipeline = redis.pipeline();
  pipeline.zRemRangeByScore(key, 0, windowStart);  // Remove old entries
  pipeline.zAdd(key, { score: now, value: `${now}-${Math.random()}` });
  pipeline.zCard(key);              // Count requests in current window
  pipeline.expire(key, 120);        // TTL: 2 minutes (window + buffer)
  const [,, countResult] = await pipeline.exec() as any;

  const count = countResult as number;
  const allowed = count <= limitPerMinute;
  const resetAt = Math.floor((windowStart + 60_000) / 1000);

  return {
    allowed,
    remaining: Math.max(0, limitPerMinute - count),
    resetAt,
  };
}
```

---

## Key Design Decisions

1. **Depth + height + alias limits are all required — they cover different attack surfaces.** Depth prevents recursive resolver amplification. Height (field count) prevents wide-query data exfiltration. Alias limits prevent same-resolver amplification. Omitting any one leaves a gap.

2. **Introspection disabled plus APQ enforcement is defense in depth.** Disabling introspection raises the bar for schema discovery. APQ enforcement makes the schema irrelevant — without a registered query, execution is blocked regardless.

3. **`max_aliases: 30` is conservative but correct for most production schemas.** Almost no legitimate UI requires more than 10-20 aliases. The risk of breaking a legitimate client is low; the risk of alias amplification without a limit is high.

4. **CORS `allow_credentials: true` requires an explicit `origins` list, never a wildcard.** The browser enforces this combination regardless of server config — a wildcard with `allow_credentials` causes preflight failures. Being explicit in config documents intent and prevents accidental wildcard configuration.

5. **Parameterized queries are the only defense against SQL injection in resolvers.** All other controls (input validation, depth limits) are supplementary. The database driver's parameterized query interface is the authoritative boundary between user data and executable SQL.

6. **Rate limiting in Apollo Router covers the gateway; coprocessor covers per-client limits.** Built-in `traffic_shaping` protects global capacity. Per-client limits (preventing one API consumer from starving others) require a coprocessor with a shared state store (Redis).

---

## Related Documentation

- `../../docs/05-security/` — full security guide
- `../../examples/12-security/jwt-authentication.md` — JWT auth and claim extraction
- `../../examples/12-security/field-level-authorization.md` — field-level authorization
- `../../examples/05-persisted-queries/` — APQ configuration and enforcement
- `../../examples/02-apollo-router/` — base Router configuration
- `../../docs/17-caching-strategies/` — APQ cache (layer 2) for query document storage
