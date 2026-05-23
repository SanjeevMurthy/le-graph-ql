# Depth and Breadth Limits in Apollo Router

Companion docs: `../../docs/06-performance-and-scaling/`, `../../docs/05-security/`

---

## 1. Depth vs Breadth vs Aliases — Definitions and Threat Models

Before configuring limits, it is important to understand exactly what each limit measures and what attack or accident it prevents. Using the wrong limit (or only one limit) leaves gaps that a determined attacker can exploit.

### Depth

Depth is the length of the longest chain of nested selection sets in a query. Each level of nesting corresponds to at least one additional resolver call and typically an additional database or service call.

```graphql
# This query has depth 4:
# query (1) -> products (2) -> reviews (3) -> author (4)
query {
  products(first: 10) {     # depth 2
    reviews(first: 10) {    # depth 3
      author {              # depth 4
        id
        name
      }
    }
  }
}
```

Without a depth limit, an attacker can construct a query that nests 50 or 100 levels deep. Even with DataLoader, each additional level of nesting multiplies the number of resolver calls and the total latency. A depth-100 query against a recursive type (like a `comments` type that has a `replies: [Comment]` field) can generate an unbounded number of resolver calls.

### Breadth (Height)

Breadth (Apollo Router calls this `max_height`) is the total number of field selections across the entire query document, counting all selection sets at all nesting levels, including inside fragments. A query can have shallow depth but enormous breadth if it requests hundreds of fields at each level.

```graphql
# Depth 2, but breadth can be very high if many fields are selected
query {
  user(id: "1") {
    id name email phone address bio avatarUrl coverUrl
    createdAt updatedAt deletedAt lastLoginAt lastActiveAt
    # ... 200 more scalar fields ...
  }
}
```

A wide query forces the resolver to load and serialize a very large object. It also defeats DataLoader batching efficiency when combined with pagination: if you request 100 objects each with 200 fields, the serialization cost alone is significant.

### Aliases

Aliases allow renaming a field in the query response. This is legitimate for requesting the same field with different arguments in one query:

```graphql
query {
  cheapProducts: products(first: 10, priceBelow: 20) { id name }
  expensiveProducts: products(first: 10, priceAbove: 200) { id name }
}
```

However, aliases can be abused to amplify query cost by repeating the same expensive field many times under different names, bypassing naive deduplication:

```graphql
query {
  r1: recommendations(userId: "x") { id }
  r2: recommendations(userId: "x") { id }
  r3: recommendations(userId: "x") { id }
  # ... r100 ...
}
```

Without an alias limit, each aliased field is executed independently. Even if the underlying resolver response is identical, each alias forces a resolver call.

---

## 2. Complete router.yaml Limits Configuration

```yaml
# router.yaml
# Apollo Router configuration for query complexity structural limits.
# These limits operate at the parsing and validation layer — before any
# subgraph receives the query. They protect against structurally malicious
# or accidental runaway queries at near-zero cost.

limits:
  # Maximum nesting depth of any query document.
  #
  # Rationale for 12: Our deepest legitimate query pattern is:
  #   query -> organization -> projects -> tasks -> comments -> author -> profile
  # That chain is 7 levels deep. We chose 12 to give 5 levels of headroom
  # for unexpected legitimate nesting (e.g., inline fragments, interfaces)
  # without being so loose that recursive-type attacks become feasible.
  #
  # Typical values: 7-15. Start conservative; increase only when blocked by
  # a legitimate use case, and document what that use case is.
  max_depth: 12

  # Maximum total number of field selections across the entire document,
  # including all inline fragments and fragment spreads.
  #
  # Rationale for 200: Our widest legitimate operation is a dashboard query
  # that fetches ~80 fields across user profile, recent activity, and team
  # data. We chose 200 to give 2.5x headroom for fragments and interface
  # fields that expand to multiple concrete type selections.
  #
  # Note: This counts field selections in the document, not in the response.
  # A field selected inside a fragment that is spread 3 times counts 3 times.
  max_height: 200

  # Maximum number of root-level fields in a query or mutation.
  # Root fields are the top-level selections directly inside `query { }`.
  #
  # Rationale for 20: Our batch query pattern (fetching many independent
  # entities in one round-trip) legitimately uses up to 12 root fields.
  # We chose 20 for headroom. More than 20 root fields usually indicates
  # either an overly ambitious query that should be split, or an alias abuse
  # pattern. Mutations are capped more aggressively because batch mutations
  # create transactional complexity and are rarely legitimate at scale.
  max_root_fields: 20

  # Maximum number of aliased field selections in a query document.
  #
  # Rationale for 30: Aliases are primarily used for two legitimate patterns:
  # (1) Requesting the same field with different arguments (2-4 aliases typical),
  # (2) Renaming fields for cleaner client-side destructuring (5-10 aliases).
  # We allow 30 to cover even large dashboard queries with many aliased
  # parallel requests. More than 30 is a strong signal of abuse.
  max_aliases: 30

  # Maximum number of directives applied across the document.
  # Directives include @include, @skip, @defer, @stream, and any custom
  # schema directives. Each directive requires evaluation overhead.
  #
  # Rationale for 20: Most queries use 0-3 directives for @include/@skip
  # conditional fields. We allow 20 to cover fragment-heavy operations
  # that apply @include at multiple points.
  max_directives: 20

  # Parser cache stores the parsed AST of recently-seen query documents.
  # Parsing a large query document into an AST is CPU-intensive: a 200-field
  # query can take 2-5ms to parse. Under load (thousands of QPS), parsing
  # costs become significant. Caching the AST against the query hash eliminates
  # repeated parsing for the same query text.
  #
  # This interacts with APQ (Automatic Persisted Queries): APQ sends the hash
  # on the second request, so the parser cache provides no additional benefit
  # for APQ requests (the query body is not re-sent). The parser cache
  # primarily benefits clients that send the full query body on every request.
  experimental_parser_cache:
    redis:
      # Use a dedicated Redis instance or namespace for parser cache.
      # Avoid sharing with application cache to prevent cache pollution
      # if one instance is flushed during a deployment.
      urls:
        - redis://router-parser-cache-01:6379
        - redis://router-parser-cache-02:6379  # replica for read redundancy

      # TTL of 3600 seconds (1 hour). Most query shapes in production are
      # stable over this window. Longer TTLs increase hit rate but consume
      # more Redis memory for rarely-used query shapes.
      ttl: 3600

      # Key prefix isolates the parser cache namespace in a shared Redis.
      key_prefix: "apollo_parser_cache:"
```

---

## 3. Query Examples at the Limits

### A Legitimate Depth-12 Query: Product Catalog Hierarchy

This query represents a realistic scenario for an e-commerce platform where the data model has deep natural nesting. Depth 12 is at the absolute limit and requires justification.

```graphql
# Depth count: query(1) > marketplace(2) > region(3) > catalog(4) >
#              category(5) > subcategory(6) > products(7) >
#              variants(8) > inventory(9) > warehouse(10) >
#              location(11) > address(12)
query MarketplaceCatalogDeep {
  marketplace(id: "global") {
    region(code: "US") {
      catalog {
        category(slug: "electronics") {
          subcategory(slug: "laptops") {
            products(first: 5) {
              variants(first: 3) {
                inventory {
                  warehouse {
                    location {
                      address {
                        city
                        state
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
```

Note: This query should probably be split. Fetching warehouse address nested inside a product catalog query is a design smell — warehouse data should be fetched separately. This example justifies the limit but does not recommend this query pattern.

### A Breadth-Approaching Query: Dashboard Data Fetch

This query uses fragments to aggregate wide dashboard data in one request. The total field count approaches 200 across all fragments.

```graphql
# Total field selections: approximately 180 across all fragments
query UserDashboard($userId: ID!) {
  user(id: $userId) {
    ...UserProfile       # ~25 fields
    ...UserStats         # ~20 fields
    ...RecentActivity    # ~30 fields via list
    ...TeamMemberships   # ~40 fields via list
    ...BillingInfo       # ~20 fields
    ...NotificationPrefs # ~15 fields
    ...ApiKeyList        # ~30 fields via list
  }
}

fragment UserProfile on User { id name email phone bio ... }
fragment UserStats on User { loginCount queryCount lastActive ... }
# ... etc.
```

### An Alias Abuse Query (Rejected at 30 Aliases)

```graphql
# This query would be rejected if the alias count exceeds max_aliases: 30
# Each alias forces a separate resolver execution of the expensive
# recommendations field.
query AliasAbuse {
  r1:  recommendations(userId: "target", algorithm: "v1") { id title }
  r2:  recommendations(userId: "target", algorithm: "v2") { id title }
  r3:  recommendations(userId: "target", algorithm: "v3") { id title }
  r4:  recommendations(userId: "target", algorithm: "v4") { id title }
  # ... continues to r31+ which would be rejected
}
```

---

## 4. Parser Cache — Why It Matters Under Load

Query parsing converts the raw query string into an Abstract Syntax Tree (AST) that the execution engine can traverse. For a typical production query (50-150 fields, multiple fragments), parsing takes approximately 1-5 milliseconds of CPU time.

At 1,000 queries per second, parsing alone consumes 1-5 CPU-seconds per second — meaning 1-5 dedicated CPU cores just for parsing. At 10,000 QPS, this becomes a dominant cost.

The parser cache stores the parsed AST keyed on a hash of the query string (typically SHA-256 of the normalized query body). On a cache hit, the router skips parsing entirely and proceeds directly to validation and planning.

**Cache key design:** The key is the hash of the raw query string, not the hash including variables. Variables are not part of the AST. Two queries with the same structure but different variable values produce the same AST and should hit the same cache entry.

**Interaction with APQ:** Automatic Persisted Queries send only the hash on repeated requests (after the first full-body request). When APQ is active, the router already knows the query body from its APQ manifest without re-parsing. The parser cache provides no additional benefit for APQ requests. In a fully APQ-enabled deployment, disable the parser cache to save Redis capacity.

**Memory sizing:** A parsed AST for a typical query is approximately 50-200 KB in serialized form. A parser cache with 10,000 unique query shapes requires 500 MB to 2 GB. Size your Redis instance accordingly and monitor the `apollo_router_cache_hit_count` and `apollo_router_cache_miss_count` metrics.

---

## 5. Monitoring Limit Violations

Apollo Router emits Prometheus metrics for all validation limit violations. These metrics are the primary signal for detecting attacks and client bugs.

```yaml
# prometheus.yml — scrape config for Apollo Router metrics
scrape_configs:
  - job_name: 'apollo-router'
    static_configs:
      - targets: ['router:9090']
    metrics_path: '/metrics'
```

Key metrics for query limit monitoring:

| Metric | Labels | Alert Condition |
|---|---|---|
| `apollo_router_graphql_error_total` | `code="GRAPHQL_VALIDATION_FAILED"` | > 10/min sustained |
| `apollo_router_query_planning_time_seconds` | percentile | P99 > 100ms |
| `apollo_router_cache_hit_count` | `kind="parser"` | Hit rate < 70% |
| `apollo_router_cache_miss_count` | `kind="parser"` | Rising trend |

```yaml
# alertmanager-rules.yml
groups:
  - name: apollo-router-query-limits
    rules:
      - alert: HighQueryValidationFailureRate
        expr: |
          rate(apollo_router_graphql_error_total{
            code="GRAPHQL_VALIDATION_FAILED"
          }[5m]) > 0.5
        for: 2m
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "High rate of query validation failures on Apollo Router"
          description: |
            {{ $value | printf "%.1f" }} validation failures per second over the
            last 5 minutes. This may indicate a client bug (sending malformed or
            overly complex queries) or a denial-of-service attempt.
            Check the router logs for the client IP and query shape.
          runbook_url: "https://wiki.internal/runbooks/apollo-router-validation-failures"

      - alert: QueryDepthLimitViolations
        # Apollo Router includes the specific limit type in structured logs
        # but not always in metrics labels. Use log-based alerting for per-limit
        # breakdown if your observability platform supports it.
        expr: |
          sum(rate(apollo_router_graphql_error_total{
            code="GRAPHQL_VALIDATION_FAILED"
          }[10m])) > 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Sustained query limit violations detected"
```

### Log-Based Detection

Apollo Router structured logs include the specific limit that was violated. Configure log shipping to your SIEM or log aggregation platform and alert on these log patterns:

```json
{
  "level": "WARN",
  "message": "GraphQL validation failed",
  "error.message": "Maximum depth limit of 12 exceeded, found 15",
  "client.address": "203.0.113.47",
  "http.request.headers.x-forwarded-for": "...",
  "graphql.operation.name": "DeepNestedQuery"
}
```

---

## 6. Per-Client Limit Overrides via Rhai

Not all clients should be subject to the same limits. Internal services (service-to-service calls within the cluster) may legitimately need deeper or wider queries for analytics, data export, or admin tooling. Trusted partners may have negotiated higher limits. External anonymous clients should have the strictest limits.

Apollo Router supports Rhai scripting for request-level logic. The following script reads a client tier from the JWT claims and applies different depth limits based on the tier.

```rhai
// rhai/query-limits-override.rhai
// This script runs during the supergraph_request stage, before validation.
// It sets context variables that the router uses to override default limits.

fn supergraph_service(service) {
    let request_callback = |request| {
        // Read the client tier from a validated JWT claim.
        // The JWT has already been verified at this point by the router's
        // authentication plugin; we are only reading claims here, not verifying.
        let client_tier = "external"; // default for unauthenticated requests

        let auth_header = request.headers["authorization"];
        if auth_header != () {
            // In a real implementation, claims are available via request.context
            // after the JWT authentication plugin runs.
            let claims = request.context["jwt_claims"];
            if claims != () && claims["client_tier"] != () {
                client_tier = claims["client_tier"];
            }
        }

        // Apply per-tier overrides.
        // These values are additive overrides on top of the base router.yaml
        // limits. They cannot exceed a hard maximum defined in router.yaml
        // (not shown here) to prevent privilege escalation via JWT manipulation.
        if client_tier == "internal" {
            // Internal services: no depth or height limit (they own the schema
            // and are trusted to not abuse it). Root field limit still applies
            // to prevent accidental fan-out in internal automation.
            request.context["query_limits_override"] = #{
                max_depth: 50,
                max_height: 1000,
                max_root_fields: 50,
                max_aliases: 100,
            };
        } else if client_tier == "partner" {
            // Partners: double the default limits for agreed-upon use cases.
            request.context["query_limits_override"] = #{
                max_depth: 20,
                max_height: 400,
                max_root_fields: 30,
                max_aliases: 50,
            };
        }
        // External clients use the default limits from router.yaml.
        // No override is set.

        request
    };

    service.map_request(request_callback);
}
```

```yaml
# router.yaml — enable the Rhai script
rhai:
  scripts: "./rhai"
  main: "query-limits-override.rhai"
```

Note: Rhai-based limit overrides require testing against your specific Apollo Router version. The context key names (`query_limits_override`) may vary. Validate against the Router release notes and test in a staging environment before enabling in production.

---

## Key Design Decisions

**Why not just rely on complexity scoring:** Structural limits (depth, breadth, aliases) are cheaper to evaluate than complexity scoring because they only count syntactic properties of the query document, not the semantic cost of each field. Depth checking is O(n) in the depth of the query. Complexity scoring requires traversing the schema and calling estimator functions per field. Use structural limits as a fast, cheap outer gate; use complexity scoring for finer-grained control.

**Why max_root_fields: 20 specifically:** This was derived from examining the actual distribution of root field counts in production traffic. The P99 of root fields per query was 8. 20 gives more than double the P99 with substantial headroom. If your P99 is much lower, a tighter limit reduces the attack surface.

**Why the parser cache uses Redis rather than in-process memory:** Apollo Router can run as many replicas behind a load balancer. An in-process cache would have a cold start on each router instance restart and would not benefit from queries that another replica has already parsed. Redis provides a shared cache across all replicas, meaning a query parsed once by any replica is cached for all replicas. The network round-trip to Redis (~0.5ms) is much less than re-parsing (~2ms for a typical query).

**Why aliases have their own limit separate from breadth:** A query with 30 aliased fields can have a breadth of 150+ when the aliased list selections are counted. Breadth alone catches this, but the alias count limit catches the pattern earlier and with a more specific error message. Per-limit error messages help client teams understand exactly what to fix.

---

## Related Documentation

- `../../docs/06-performance-and-scaling/` — How structural limits interact with the DataLoader batching model and caching strategies
- `../../docs/05-security/` — Complete threat model including depth/breadth attack scenarios and mitigations
- `../../docs/15-kubernetes-deployment/` — Redis deployment patterns for the parser cache in Kubernetes
- `../../docs/14-observability/` — Full Prometheus and Grafana setup for monitoring limit violations
