# Supergraph Configuration

Rover CLI configuration, Apollo Router config, and all publish/check commands for the three-subgraph e-commerce supergraph.

---

## supergraph.yaml

Used by `rover supergraph compose` (static composition) and `rover dev` (live development). Each subgraph entry points to a running endpoint or a local SDL file.

```yaml
# supergraph.yaml
federation_version: =2.6

subgraphs:
  users:
    routing_url: http://localhost:4001/graphql
    schema:
      subgraph_url: http://localhost:4001/graphql
      # For CI without running servers, use a file reference instead:
      # file: ./users-subgraph/schema.graphql

  products:
    routing_url: http://localhost:4002/graphql
    schema:
      subgraph_url: http://localhost:4002/graphql
      # file: ./products-subgraph/schema.graphql

  orders:
    routing_url: http://localhost:4003/graphql
    schema:
      subgraph_url: http://localhost:4003/graphql
      # file: ./orders-subgraph/schema.graphql
```

**Note:** `routing_url` is the URL the deployed router uses to reach the subgraph. In Kubernetes this would be a cluster-internal service URL like `http://users-service.graphql.svc.cluster.local/graphql`. `subgraph_url` is where `rover` fetches the SDL during composition — typically the same URL in local dev.

---

## router.yaml

Apollo Router configuration. Covers CORS, JWT authentication, query complexity limits, persisted queries, and OpenTelemetry. Place this file alongside the router binary.

```yaml
# router.yaml
server:
  listen: 0.0.0.0:4000

# ---------------------------------------------------------------------------
# CORS — restrict in production to known client origins
# ---------------------------------------------------------------------------
cors:
  origins:
    - https://app.example.com
    - https://admin.example.com
  # Allow the Apollo Sandbox during development only
  # Remove this in production
  allow_any_origin: false
  methods:
    - GET
    - POST
    - OPTIONS
  headers:
    - Content-Type
    - Authorization
    - X-Request-ID
    - Apollo-Require-Preflight

# ---------------------------------------------------------------------------
# Authentication — JWT validation via JWKS endpoint
# ---------------------------------------------------------------------------
authentication:
  router:
    jwt:
      jwks:
        - url: https://auth.example.com/.well-known/jwks.json
          issuer: https://auth.example.com/
          algorithms:
            - RS256
      # Claims to propagate as subgraph headers
      header_name: Authorization
      header_value_prefix: Bearer

# ---------------------------------------------------------------------------
# Authorization — field-level access control
# ---------------------------------------------------------------------------
authorization:
  # Require @requiresScopes or @authenticated directives for protected fields
  directives:
    enabled: true
  preview_directives:
    enabled: true

# ---------------------------------------------------------------------------
# Subgraph header propagation — forward auth context to all subgraphs
# ---------------------------------------------------------------------------
headers:
  all:
    request:
      - propagate:
          matching: "^x-.*"        # propagate all x- headers
      - propagate:
          named: Authorization     # propagate auth token
      - insert:
          name: X-Router-Version
          value: "1.0.0"

# ---------------------------------------------------------------------------
# Query complexity and depth limits
# ---------------------------------------------------------------------------
limits:
  max_depth: 15
  max_height: 200
  max_aliases: 30
  max_root_fields: 20

# ---------------------------------------------------------------------------
# Traffic shaping — timeouts and circuit breakers per subgraph
# ---------------------------------------------------------------------------
traffic_shaping:
  all:
    timeout: 30s
    retry:
      min_per_sec: 10
      retry_on: "5xx"
      max_retries: 2
  subgraphs:
    users:
      timeout: 5s
    products:
      timeout: 10s
    orders:
      timeout: 15s

# ---------------------------------------------------------------------------
# Persisted queries (operation allowlisting)
# ---------------------------------------------------------------------------
persisted_queries:
  enabled: true
  safelist:
    enabled: true
    require_id: false  # set to true for strict allowlist mode

# ---------------------------------------------------------------------------
# Supergraph schema polling (when using Apollo GraphOS managed federation)
# ---------------------------------------------------------------------------
uplink:
  poll_interval: 10s
  timeout: 30s

# ---------------------------------------------------------------------------
# OpenTelemetry — export traces and metrics
# ---------------------------------------------------------------------------
telemetry:
  exporters:
    tracing:
      otlp:
        enabled: true
        endpoint: http://otel-collector:4317
        grpc:
          metadata:
            "x-honeycomb-team": "${env.HONEYCOMB_API_KEY}"
    metrics:
      prometheus:
        enabled: true
        path: /metrics
        listen: 0.0.0.0:9090

  instrumentation:
    spans:
      router:
        request:
          attributes:
            http.method: true
            http.url: true
            graphql.operation.name: true
            graphql.operation.type: true
      subgraph:
        request:
          attributes:
            subgraph.name: true
            graphql.operation.name: true

  # Include query plan details in traces (disable in high-cardinality prod)
  apollo:
    send_variable_values: none    # never, sanitize, all
    send_headers: none            # never, forward_headers_only, all

# ---------------------------------------------------------------------------
# Health check endpoint
# ---------------------------------------------------------------------------
health_check:
  enabled: true
  path: /health
  listen: 0.0.0.0:8088
```

---

## Local Development: rover dev

`rover dev` is the primary local development workflow. It composes from live subgraph endpoints and starts a router instance with hot reload.

```bash
# Start rover dev — press Ctrl+C to stop
rover dev --config supergraph.yaml --router-config router.yaml

# Override the router port (default 4000)
rover dev --config supergraph.yaml --supergraph-port 4000
```

During `rover dev`, you can add a new subgraph to a running session:

```bash
rover dev --url http://localhost:4004/graphql --name shipping
```

Apollo Sandbox opens automatically at `http://localhost:4000`. Query plans are visible in the Sandbox's "Query Plan" tab.

---

## Schema Publish Commands

Run these commands from CI after each subgraph deployment. The `APOLLO_KEY` environment variable must be set to your Apollo GraphOS API key.

```bash
# Set in CI environment (never commit this)
export APOLLO_KEY=service:my-graph:xxxxxxxxxxxxxxxx
export APOLLO_GRAPH_REF=my-graph@main

# Publish Users subgraph schema
rover subgraph publish "${APOLLO_GRAPH_REF}" \
  --name users \
  --schema ./users-subgraph/schema.graphql \
  --routing-url https://users.internal.example.com/graphql

# Publish Products subgraph schema
rover subgraph publish "${APOLLO_GRAPH_REF}" \
  --name products \
  --schema ./products-subgraph/schema.graphql \
  --routing-url https://products.internal.example.com/graphql

# Publish Orders subgraph schema
rover subgraph publish "${APOLLO_GRAPH_REF}" \
  --name orders \
  --schema ./orders-subgraph/schema.graphql \
  --routing-url https://orders.internal.example.com/graphql
```

When publishing to a staging variant:

```bash
rover subgraph publish "my-graph@staging" \
  --name users \
  --schema ./users-subgraph/schema.graphql \
  --routing-url https://users.staging.internal.example.com/graphql
```

---

## Schema Check Commands

Run `rover subgraph check` in pull request pipelines **before** deploying a subgraph. The check validates that the proposed schema change composes correctly with all other subgraphs and does not introduce breaking changes to active clients.

```bash
# Check the Users subgraph schema (run in PR pipeline)
rover subgraph check "${APOLLO_GRAPH_REF}" \
  --name users \
  --schema ./users-subgraph/schema.graphql

# Check with a validation period (consider ops from the last 7 days)
rover subgraph check "${APOLLO_GRAPH_REF}" \
  --name orders \
  --schema ./orders-subgraph/schema.graphql \
  --validation-period 7d

# Exit code 0 = safe to deploy; non-zero = breaking change detected
# Use $? in CI to gate the deployment:
if ! rover subgraph check "${APOLLO_GRAPH_REF}" \
  --name products \
  --schema ./products-subgraph/schema.graphql; then
  echo "Schema check failed — blocking deployment"
  exit 1
fi
```

---

## Static Composition (CI without GraphOS)

If you are not using Apollo GraphOS managed federation, compose statically from SDL files:

```bash
# Compose from local SDL files
rover supergraph compose \
  --config supergraph.yaml \
  --output supergraph.graphql

# Start the router with the composed schema
./router \
  --config router.yaml \
  --supergraph supergraph.graphql
```

The output `supergraph.graphql` is a supergraph SDL that embeds the query plan schema. Commit it to your repository and use it as a health check artifact in your deployment pipeline.

---

## Environment Variable Reference

| Variable | Required | Description |
|---|---|---|
| `APOLLO_KEY` | Yes (managed federation) | API key for Apollo GraphOS |
| `APOLLO_GRAPH_REF` | Yes (managed federation) | Graph ref in `graph-id@variant` format |
| `USERS_DB_URL` | Yes | PostgreSQL connection string for Users subgraph |
| `PRODUCTS_DB_URL` | Yes | PostgreSQL connection string for Products subgraph |
| `ORDERS_DB_URL` | Yes | PostgreSQL connection string for Orders subgraph |
| `HONEYCOMB_API_KEY` | No | Honeycomb telemetry API key (injected into router.yaml) |
| `NODE_ENV` | Yes | `development` or `production` — controls logging verbosity |
