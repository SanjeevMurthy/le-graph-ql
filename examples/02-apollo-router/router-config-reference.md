# Apollo Router Production Configuration Reference

Companion doc: [Chapter 08 — Apollo Federation v2 Production Architecture](../../docs/08-federation/federation-production.md)

This file is the annotated reference for `router.yaml` — the primary configuration surface for Apollo Router v1.40+. Every key is explained with its production rationale. Use this as the basis for your own environment-specific overlays.

Configuration precedence (highest to lowest): command-line flags > environment variables > `router.yaml` > defaults.

Hot-reload note: Apollo Router supports hot reload of most configuration sections via SIGHUP or `--hot-reload` flag. Sections that require a full restart are called out explicitly.

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Apollo Router | >= 1.40.0 | Several features (entity caching, coprocessor v2) require this version |
| Apollo GraphOS account | Enterprise tier | Required for: `authentication`, `authorization`, `entity_caching`, `coprocessor` |
| Redis | >= 6.2 | Required for `entity_caching` and distributed APQ |
| OTLP Collector | any | Required for `telemetry.exporters.tracing.otlp` |
| Schema Registry | GraphOS or self-hosted | Required for uplink-mode supergraph fetching |

---

## Environment Variables Referenced in This File

| Variable | Required | Example | Notes |
|---|---|---|---|
| `APOLLO_KEY` | Yes (uplink mode) | `service:my-graph:abc123` | GraphOS API key — never hardcode |
| `APOLLO_GRAPH_REF` | Yes (uplink mode) | `my-graph@production` | Graph ref for schema fetching |
| `JWKS_URL` | Yes | `https://auth.example.com/.well-known/jwks.json` | JWKS endpoint for JWT verification |
| `REDIS_URL` | Yes (caching) | `redis://redis.internal:6379` | Redis connection string |
| `COPROCESSOR_URL` | Yes (coprocessor) | `http://coprocessor.internal:4001` | Coprocessor service endpoint |
| `OTLP_ENDPOINT` | Yes (telemetry) | `http://otel-collector:4317` | OTLP gRPC collector endpoint |
| `ROUTER_ENV` | Yes | `production` | Used in config conditionals and span attributes |

---

## Complete Annotated `router.yaml`

```yaml
# ---------------------------------------------------------------------------
# server
#
# Controls the HTTP server the router binds to.
# Hot reload: host/port changes require restart. Timeout values are hot-reloadable.
# ---------------------------------------------------------------------------
server:
  # Bind to all interfaces in containerized deployments.
  # In bare-metal environments, bind to the specific interface facing the load balancer.
  listen: 0.0.0.0:4000

  # Health check endpoint. This path should be used for:
  #   - Kubernetes liveness/readiness probes
  #   - Load balancer health checks
  # Default is /.well-known/apollo/server-health — keep this unless your LB
  # infrastructure has a hardcoded path expectation.
  health_check:
    enabled: true
    listen: 0.0.0.0:8088  # Expose on a separate port so it is never behind auth middleware
    path: /health

  # Disable the landing page in production. The landing page is a browser UI
  # intended for development only. Exposing it in production leaks schema
  # information and wastes a round-trip for API clients.
  landing_page: false

  # The maximum time the router waits for an entire request/response cycle.
  # Set this to be slightly lower than your upstream load balancer timeout
  # so the router can return a proper error instead of the LB dropping the
  # connection with a 504.
  request_timeout: 30s

  # How long to wait for in-flight requests to complete during graceful shutdown.
  # Must be long enough for your slowest legitimate query to complete.
  # Set this lower than your Kubernetes terminationGracePeriodSeconds.
  shutdown_timeout: 30s

  # Enable HTTP/2 for clients that support it. Required for gRPC-based health
  # checks and improves multiplexing efficiency for heavy clients.
  experimental_http2: enable

---

# ---------------------------------------------------------------------------
# supergraph
#
# Controls how the router obtains and uses the supergraph schema.
# Two modes: uplink (recommended for production) and local file.
# Hot reload: polling intervals are hot-reloadable. Schema path is not.
# ---------------------------------------------------------------------------
supergraph:
  # --- MODE 1: Uplink (GraphOS Managed Federation) ---
  # The router polls GraphOS for schema updates. This enables zero-downtime
  # schema deployments, automated rollbacks, and launch approval workflows.
  # Requires APOLLO_KEY and APOLLO_GRAPH_REF environment variables.
  #
  # Uncomment this block and remove the `path` key below when using managed federation.
  #
  # uplink:
  #   # How often to poll for schema updates. 10s is the minimum GraphOS allows.
  #   # Lower values reduce propagation latency but increase API call frequency.
  #   poll_interval: 10s
  #
  #   # Timeout for each uplink fetch. If the fetch times out, the router
  #   # continues serving traffic with the last-known-good schema.
  #   timeout: 10s

  # --- MODE 2: Local File ---
  # Use this when you manage schema composition outside GraphOS (e.g., CI/CD
  # pipeline that runs `rover supergraph compose` and writes the output to a
  # mounted volume or config map).
  path: /etc/router/supergraph.graphql

  # Query planning configuration.
  # The query planner determines how to split a client operation across subgraphs.
  query_planning:
    # Cache size for query plans. Each unique operation/variables hash has its
    # own plan entry. Tune this based on your operation diversity.
    # A value of 1000 means up to 1000 distinct query plans are cached in memory.
    # Monitor `apollo_router_query_planning_requests_total` to see cache hit rate.
    cache:
      in_memory:
        limit: 1000

    # Experimental: enable the new query planner implementation.
    # Provides better performance for deeply federated schemas.
    # Test thoroughly before enabling in production.
    experimental_parallelism: auto

  # Introspection: disable in production. Introspection reveals your full schema
  # to any client, which is an information disclosure risk. Use GraphOS Schema
  # Registry or internal tooling to provide schema access to developers.
  introspection: false

---

# ---------------------------------------------------------------------------
# homepage
#
# The homepage is the browser UI shown when you navigate to the router root.
# Always disable in production — it leaks schema metadata.
# Hot reload: yes.
# ---------------------------------------------------------------------------
homepage:
  enabled: false

---

# ---------------------------------------------------------------------------
# sandbox
#
# Apollo Sandbox is the embedded GraphQL IDE. Disable in production for the
# same reasons as homepage — it reveals schema structure and provides a
# convenient interface for attackers to explore your API.
# Hot reload: yes.
# ---------------------------------------------------------------------------
sandbox:
  enabled: false

---

# ---------------------------------------------------------------------------
# cors
#
# Cross-Origin Resource Sharing configuration.
# This matters for browser-based clients that call the router directly.
# In server-to-server architectures (microservices, mobile apps), CORS is
# irrelevant but should still be locked down defensively.
#
# Hot reload: yes.
# ---------------------------------------------------------------------------
cors:
  # Set to false and provide an explicit `origins` list in production.
  # `allow_any_origin: true` is acceptable in development but never in production —
  # it allows any website to make credentialed requests to your API.
  allow_any_origin: false

  # List every domain that hosts a UI which talks to this router.
  # Wildcards are not supported for credentialed requests (the browser blocks them).
  origins:
    - https://app.example.com
    - https://admin.example.com
    - https://www.example.com
    # Include staging origins if this router instance serves staging traffic:
    # - https://staging.example.com

  # Only allow methods that your API actually uses.
  # GraphQL over HTTP uses POST for mutations/queries, GET for APQ cache hits.
  methods:
    - GET
    - POST
    - OPTIONS   # Required — browsers send OPTIONS preflight before POST

  # Headers the browser is allowed to send.
  # Include any custom headers your clients use for authentication or identification.
  allow_headers:
    - Content-Type          # Required for JSON POST bodies
    - Authorization         # JWT Bearer tokens
    - apollographql-client-name     # Apollo Studio client identification
    - apollographql-client-version  # Apollo Studio client identification
    - x-request-id          # Distributed tracing correlation ID

  # Headers the browser is allowed to read from the response.
  # Add custom response headers here if your UI reads them (e.g., x-query-cost).
  expose_headers:
    - x-query-cost
    - x-request-id

  # Whether to allow cookies/credentials to be sent cross-origin.
  # Set to true only if you use cookie-based sessions with the router.
  # If false, browsers will not send Authorization cookies.
  allow_credentials: false

  # How long browsers should cache the preflight response. 86400 = 24 hours.
  # Reduces OPTIONS preflight round-trips in production.
  max_age_secs: 86400

---

# ---------------------------------------------------------------------------
# headers
#
# Controls header propagation between the client, the router, and subgraphs.
# This is the primary mechanism for forwarding auth context, request IDs,
# and feature flags to downstream services without the subgraph needing to
# know about the router's header contract.
#
# Hot reload: yes.
# ---------------------------------------------------------------------------
headers:
  # Rules that apply to ALL subgraph requests unless overridden below.
  all:
    request:
      # Propagate the Authorization header verbatim to all subgraphs.
      # Subgraphs can then independently validate the JWT if needed,
      # or rely on the router's `authentication` plugin to do so.
      - propagate:
          named: authorization

      # Propagate distributed tracing headers so subgraph spans can be
      # correlated to the parent router span in your observability platform.
      - propagate:
          named: x-request-id
      - propagate:
          named: traceparent
      - propagate:
          named: tracestate
      - propagate:
          named: baggage

      # Propagate Apollo Studio client identification headers.
      # Required for per-client metrics in GraphOS Studio.
      - propagate:
          named: apollographql-client-name
      - propagate:
          named: apollographql-client-version

      # Insert a router-controlled header identifying which router instance
      # handled the request. Useful for debugging in multi-instance deployments.
      - insert:
          name: x-router-version
          value: "1.40.0"   # Parameterize with your actual router version

    response:
      # Remove internal headers that subgraphs might set but should never
      # reach the client. Add any headers your subgraphs use internally.
      - remove:
          named: x-internal-service-name
      - remove:
          named: x-pod-name

  # Per-subgraph overrides. Use these when a specific subgraph needs different
  # header handling than the global default.
  subgraphs:
    payments:
      request:
        # The payments subgraph requires a service-to-service API key
        # separate from the user JWT. Inject it from the router's environment.
        - insert:
            name: x-payments-api-key
            value: "${env.PAYMENTS_API_KEY}"

        # Remove the user Authorization header for this subgraph — the payments
        # service uses its own auth model and the JWT would be confusing/risky.
        - remove:
            named: authorization

    notifications:
      request:
        # Override the propagated client name with a fixed service identifier
        # so the notifications subgraph can log the router as the caller.
        - insert:
            name: x-caller-service
            value: "apollo-router"

---

# ---------------------------------------------------------------------------
# authentication
#
# JWT authentication plugin. Validates JWTs on incoming requests using JWKS.
# The router rejects requests with invalid tokens before they reach subgraphs.
#
# Requires: Apollo Router Enterprise license.
# Hot reload: jwks_urls are reloaded periodically without restart.
# ---------------------------------------------------------------------------
authentication:
  router:
    jwt:
      # JWKS endpoint for fetching public keys. The router caches JWKS and
      # refreshes it periodically. Supports multiple URLs for key rotation
      # or multi-tenant scenarios.
      jwks:
        - url: "${env.JWKS_URL}"
          # How often to poll for key rotation. Set this to match your
          # key rotation schedule. 60s is a safe default for most providers.
          poll_interval: 60s

      # The JWT claim to extract as the authenticated user identity.
      # This value is available in Rhai scripts via `context["sub"]`.
      # Common values: "sub", "email", "https://example.com/user_id"
      header_name: Authorization
      header_value_prefix: "Bearer "

      # Claims to extract and forward as request headers to subgraphs.
      # This allows subgraphs to trust router-verified identity without
      # re-validating the JWT on every request.
      # Note: these are FORWARDED claims, not enforcement rules.
      # Use `authorization` (below) for enforcement.

---

# ---------------------------------------------------------------------------
# authorization
#
# Directive-based authorization. Works with `@requiresScopes` and
# `@authenticated` directives in your subgraph schemas.
# The router enforces these at the query planning stage, before any
# subgraph requests are made.
#
# Requires: Apollo Router Enterprise license.
# Hot reload: yes.
# ---------------------------------------------------------------------------
authorization:
  # Reject requests that query fields requiring authentication if no valid
  # JWT is present. Without `require_authentication`, the router would
  # silently return null for unauthorized fields.
  require_authentication: false  # Set to true if ALL operations require auth

  # Preview: enables `@requiresScopes` directive enforcement.
  # Scopes are extracted from the `scope` claim in the validated JWT.
  # Example: `type Query { adminReport: Report @requiresScopes(scopes: [["admin"]]) }`
  preview_directives:
    enabled: true

---

# ---------------------------------------------------------------------------
# coprocessor
#
# The coprocessor is an external HTTP service that the router calls at specific
# pipeline stages. Use it for: custom auth logic, request enrichment, audit
# logging, complex rate limiting, or any logic that is too complex for Rhai.
#
# Requires: Apollo Router Enterprise license.
# Hot reload: URL and timeout are hot-reloadable.
# ---------------------------------------------------------------------------
coprocessor:
  url: "${env.COPROCESSOR_URL}"

  # Timeout for each coprocessor call. Keep this tight — the coprocessor is
  # in the critical path. If it times out, the router fails open or closed
  # depending on your error handling (default: fail open).
  timeout: 50ms

  router:
    # RouterRequest stage: called after the router receives the client request
    # but before query planning. Use for: request authentication, rate limiting,
    # request ID injection, or rejecting requests based on headers/body.
    request:
      headers: true       # Pass request headers to the coprocessor
      body: true          # Pass the raw GraphQL request body (JSON string)
      context: true       # Pass the router's request context
      sdl: false          # Do not pass the schema — expensive and rarely needed

    # RouterResponse stage: called after the router assembles the final response
    # but before sending to the client. Use for: response header injection,
    # audit logging, response modification.
    response:
      headers: true
      body: false         # Response body modification is expensive; avoid unless necessary
      context: true

  subgraph:
    # SubgraphRequest stage: called before each subgraph fetch.
    # Use for: per-subgraph auth enrichment, request signing, header injection.
    all:
      request:
        headers: true
        body: false       # Subgraph request body manipulation is rarely needed
        context: true
        uri: true         # Pass the subgraph URL (useful for routing decisions)

---

# ---------------------------------------------------------------------------
# traffic_shaping
#
# Controls timeouts, retries, and compression for subgraph requests.
# Hot reload: yes for all values in this section.
# ---------------------------------------------------------------------------
traffic_shaping:
  # Defaults applied to all subgraphs. Override per-subgraph below.
  all:
    # Timeout for each subgraph HTTP request. This is separate from the
    # top-level `request_timeout` — a single client request may fan out to
    # multiple subgraphs, each with this timeout budget.
    timeout: 5s

    # Retry configuration. Only retry on idempotent requests (queries).
    # Never retry mutations — they are not idempotent and retrying can cause
    # duplicate writes (double charges, double sends, etc.).
    retry:
      enabled: true
      # Minimum number of requests per second before retry is activated.
      # At low traffic, retry storms can amplify failures. This threshold
      # ensures retries only activate when the subgraph is genuinely degraded,
      # not when you have 1 req/s and it failed once.
      min_per_sec: 10
      # Fraction of requests that must succeed for retry to remain enabled.
      # 0.5 = disable retry when >50% of requests are failing (avoid amplification).
      retry_percent: 0.2
      # Allow retrying mutations? Set to false. Mutations are not idempotent.
      retry_mutations: false

    # Request body compression to subgraphs. Reduces bandwidth on large
    # query plans. gzip is universally supported.
    compression: gzip

    # Deduplicate identical in-flight subgraph requests.
    # When multiple client requests trigger the same subgraph entity fetch
    # simultaneously, the router coalesces them into a single fetch.
    # This is the "request coalescing" or "dataloader" pattern at the router level.
    experimental_enable_http2: true

  # Per-subgraph overrides. Tune based on each subgraph's SLA.
  subgraphs:
    # The inventory subgraph has a slow database and occasionally spikes.
    # Give it a longer timeout and more aggressive retry budget.
    inventory:
      timeout: 15s
      retry:
        enabled: true
        min_per_sec: 5
        retry_percent: 0.3

    # The payments subgraph must never be retried — all operations are writes.
    payments:
      timeout: 10s
      retry:
        enabled: false

    # The recommendations subgraph is non-critical. Fail fast.
    recommendations:
      timeout: 2s
      retry:
        enabled: false

---

# ---------------------------------------------------------------------------
# telemetry
#
# Observability configuration: distributed tracing and metrics.
# Hot reload: most values are hot-reloadable. Changing exporter URLs requires restart.
# ---------------------------------------------------------------------------
telemetry:
  exporters:
    tracing:
      # OTLP gRPC trace exporter. Sends spans to your OpenTelemetry Collector,
      # which can then forward to Jaeger, Tempo, Honeycomb, Datadog, etc.
      otlp:
        enabled: true
        endpoint: "${env.OTLP_ENDPOINT}"  # e.g., http://otel-collector:4317
        protocol: grpc
        # gRPC-specific settings
        grpc:
          # Metadata headers to send with every OTLP export RPC.
          # Use for auth tokens required by managed OTLP services.
          metadata:
            authorization:
              - "Bearer ${env.OTLP_AUTH_TOKEN}"
        # Batch export settings — tune for your traffic volume.
        batch_processor:
          # Maximum number of spans to hold before forcing a flush.
          max_queue_size: 2048
          # Maximum number of spans per export batch.
          max_export_batch_size: 512
          # Maximum time between scheduled flushes.
          scheduled_delay: 5s
          # Export timeout. If the collector is slow, drop spans rather than
          # blocking the router's request processing.
          max_export_timeout: 30s

    metrics:
      # Prometheus metrics endpoint for scraping by Prometheus server or
      # Prometheus-compatible agents (Victoria Metrics, Grafana Agent, etc.)
      prometheus:
        enabled: true
        listen: 0.0.0.0:9090
        path: /metrics

      # OTLP metrics exporter (optional — use if you prefer push-based metrics).
      # otlp:
      #   enabled: false
      #   endpoint: "${env.OTLP_ENDPOINT}"
      #   protocol: grpc

  # Instrumentation: controls what gets traced and how.
  instrumentation:
    tracing:
      # Sampling rate: 1.0 = trace 100% of requests.
      # In high-traffic production deployments, set this to 0.01-0.1 (1-10%)
      # to control storage costs. Use tail-based sampling in the collector
      # to retain 100% of error traces regardless of this setting.
      sampler: 0.1  # 10% sampling in production

      # Propagation formats to support on incoming requests.
      # w3c (traceparent/tracestate) is the standard. Include b3 if you have
      # legacy services still using Zipkin-style propagation.
      propagation:
        trace_context: true    # W3C TraceContext (traceparent/tracestate)
        baggage: true          # W3C Baggage (baggage header)
        b3: false              # Zipkin B3 (disable unless you have legacy services)
        jaeger: false          # Jaeger propagation format

    spans:
      # Default attributes to add to every span the router creates.
      # These make filtering in your observability platform much easier.
      default_attribute_requirement_level: recommended

      router:
        # Add custom attributes to the root router span.
        attributes:
          # Tag all spans with the environment name for multi-env deployments
          # that share a single observability backend.
          "deployment.environment":
            static: "${env.ROUTER_ENV}"
          # Include the client name in the span for per-client performance analysis.
          "graphql.client.name":
            request_header: apollographql-client-name
          "graphql.client.version":
            request_header: apollographql-client-version
          # Operation name for filtering traces by operation in Studio.
          "graphql.operation.name":
            operation_name: true
          "graphql.operation.type":
            operation_type: true

      subgraph:
        attributes:
          # Tag subgraph spans with the subgraph name for per-subgraph latency breakdowns.
          "graphql.subgraph.name":
            subgraph_name: true

    # Custom events (log-style structured events within spans).
    events:
      router:
        # Log the request body at DEBUG level. Never enable at INFO or above in
        # production — request bodies can contain PII (passwords, credit card numbers).
        request: never
        response: never
        # Log errors at ERROR level — these are surfaced in your APM tool.
        error: error

---

# ---------------------------------------------------------------------------
# apq
#
# Automated Persisted Queries (APQ). Clients send a hash of the operation;
# the router looks it up and executes the full operation.
# Benefits: reduces request payload size, enables CDN caching of GET requests.
#
# Hot reload: yes.
# ---------------------------------------------------------------------------
apq:
  enabled: true

  # APQ cache backend. Use Redis for multi-instance deployments so all
  # router replicas share the same APQ cache.
  # Without Redis, each replica has an independent in-memory cache, meaning
  # clients may get cache misses when load-balanced to a new replica.
  router:
    cache:
      redis:
        urls:
          - "${env.REDIS_URL}"
        # TTL for APQ entries. 24 hours is a good default — this is how long
        # a registered query remains valid without re-registration.
        ttl: 86400s

  # Require clients to use persisted queries only. In `require_id` mode,
  # the router rejects any request that sends an inline query string.
  # This prevents ad-hoc queries from being executed in production —
  # only pre-registered, reviewed operations are allowed.
  # Enable this after all your clients have migrated to APQ.
  # subgraph:
  #   all:
  #     enabled: true

---

# ---------------------------------------------------------------------------
# limits
#
# Query complexity limits. Protect against denial-of-service attacks via
# deeply nested or extremely wide queries.
#
# Hot reload: yes.
# Requires: Apollo Router 1.22+ for most limit types.
# ---------------------------------------------------------------------------
limits:
  # Maximum nesting depth of a query. A depth of 10 allows:
  # query { a { b { c { d { e { f { g { h { i { j } } } } } } } } } }
  # Queries deeper than this are rejected before execution.
  # Tune based on your deepest legitimate query. Start conservative (15)
  # and increase if legitimate operations are rejected.
  max_depth: 15

  # Maximum total number of fields in a query (width * depth).
  # Prevents "field explosion" attacks that select thousands of fields.
  max_height: 200

  # Maximum number of root-level fields in a single query.
  # Limits the fan-out from the router to subgraphs.
  max_root_fields: 20

  # Maximum number of field aliases. Aliases allow clients to request the
  # same field multiple times with different names — limiting this prevents
  # using aliases to bypass field-count limits.
  max_aliases: 30

  # Maximum number of directives in a query document.
  max_directives: 20

  # Parser cache: reuses parsed query ASTs across requests.
  # Significantly reduces CPU usage when the same operation is sent repeatedly
  # (which is the common case for any client using static operations).
  experimental_parser_cache:
    enabled: true

---

# ---------------------------------------------------------------------------
# entity_caching
#
# Redis-based cache for federated entity responses.
# When a subgraph returns an entity (identified by `__typename` + `id`),
# the router caches the response and serves it on subsequent requests.
# This is the primary cache layer for read-heavy federated deployments.
#
# Requires: Apollo Router Enterprise license.
# Requires: Redis.
# Hot reload: TTL values are hot-reloadable. Redis URL requires restart.
# ---------------------------------------------------------------------------
preview_entity_cache:
  enabled: true

  redis:
    urls:
      - "${env.REDIS_URL}"
    # Timeout for Redis operations. Keep tight — a slow Redis should not
    # block the router from falling through to the subgraph.
    timeout: 2ms
    # Cache key prefix to avoid collisions if multiple router instances
    # share the same Redis cluster for different environments.
    namespace: "router:entities:prod"

  # Default TTL for all entity types unless overridden below.
  # 60 seconds is a conservative default. Tune based on how frequently
  # your entities change and your tolerance for stale data.
  ttl: 60s

  # Enable cache invalidation via GraphOS Cache Purge API.
  # Allows external systems (e.g., a write service) to invalidate
  # specific entity cache entries when data changes.
  invalidation:
    enabled: true
    listen: 0.0.0.0:4001
    path: /invalidation

  # Per-subgraph TTL overrides.
  subgraph:
    # Product catalog: cache aggressively — changes infrequently.
    products:
      ttl: 300s   # 5 minutes
    # User profiles: cache briefly — changes frequently.
    users:
      ttl: 10s
    # Inventory: do not cache — always fetch live data.
    inventory:
      ttl: 0s

---

# ---------------------------------------------------------------------------
# subscription
#
# GraphQL Subscriptions support via HTTP callback protocol.
# The router receives subscription events from subgraphs via HTTP POST callbacks
# and streams them to connected clients via SSE (Server-Sent Events) or WebSocket.
#
# Hot reload: no — subscription configuration changes require restart.
# ---------------------------------------------------------------------------
subscription:
  enabled: true

  mode:
    # HTTP callback protocol: the router registers a callback URL with the subgraph.
    # The subgraph POSTs events to the callback URL when new data is available.
    # This is preferred over WebSocket for subgraph connections because:
    # - No persistent connection required between router and subgraph
    # - Works with standard HTTP load balancers and service meshes
    # - Easier to secure (just HTTPS + a shared secret)
    callback:
      # The public URL of this router instance that subgraphs will POST events to.
      # Must be reachable from subgraphs. In Kubernetes, this is typically the
      # ClusterIP service or an internal LoadBalancer.
      public_url: "http://router.graphql.svc.cluster.local:4000"

      # Interval at which the router sends a heartbeat to the subgraph to keep
      # the subscription registration alive. Set to less than the subgraph's
      # registration expiry (typically 5-15 minutes).
      heartbeat_interval: 5s

      # Per-subgraph callback URL overrides. Use when subgraphs are in different
      # network segments and need different router URLs.
      # subgraphs:
      #   realtime:
      #     public_url: "http://router-realtime.graphql.svc.cluster.local:4000"
```

---

## Key Design Decisions

**Why separate health check port (8088)?**
The health check must always be available, even when the router's main port (4000) is under auth middleware or TLS termination. A separate port ensures Kubernetes probes never get blocked by the authentication pipeline.

**Why disable introspection in production?**
Introspection allows any client to enumerate every type and field in your schema. This is valuable in development but a security risk in production. Use GraphOS Schema Registry, Postman, or generated documentation to give developers schema access without exposing the live API.

**Why is `retry_mutations: false` critical?**
GraphQL mutations are not idempotent — retrying a payment mutation charges a customer twice. The retry configuration defaults to false for mutations, but this is called out explicitly because misconfiguring it causes real financial harm.

**Why use uplink mode over local file mode?**
Uplink enables zero-downtime schema updates: compose a new supergraph, publish it to GraphOS, and all router instances fetch the update within `poll_interval` seconds. With local files, you must redeploy the router to pick up schema changes, which is slower and riskier.

**Why keep the coprocessor timeout at 50ms?**
The coprocessor is in the synchronous request path. If it is slow, every client request is slow. 50ms forces you to keep coprocessor logic lightweight and fast. Use async audit logging (fire-and-forget) for operations that do not need to block the request.

**Why use W3C TraceContext instead of B3?**
W3C TraceContext (`traceparent`/`tracestate`) is the CNCF-endorsed standard and is supported by all modern observability platforms (Datadog, Honeycomb, Grafana Tempo, Jaeger). B3 is a Zipkin legacy format. New deployments should standardize on W3C.

**Why namespace the Redis entity cache?**
If staging and production router instances share a Redis cluster (common in cost-optimized setups), namespacing prevents a staging deployment from polluting production cache entries or vice versa.

---

## Related Documentation

- [Chapter 08 — Federation Production Architecture](../../docs/08-federation/federation-production.md)
- [Chapter 09 — Authentication and Authorization Patterns](../../docs/09-auth/auth-patterns.md)
- [Chapter 10 — Observability and Tracing](../../docs/10-observability/tracing.md)
- [Chapter 11 — Caching Strategies](../../docs/11-caching/entity-caching.md)
- [Chapter 12 — Rate Limiting and Traffic Shaping](../../docs/12-traffic/rate-limiting.md)
- [Rhai Scripts Reference](./rhai-scripts.md) — companion file in this directory
