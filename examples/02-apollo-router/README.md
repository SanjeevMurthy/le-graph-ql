# Apollo Router — Production Configuration Reference

This example is the companion implementation for
[Chapter 08: Supergraph Architecture — 02 Router Configuration](../../docs/08-supergraph-architecture/02-router-configuration.md).

It provides a complete, annotated Apollo Router configuration for a production enterprise
deployment — every config section explained, every value justified, with realistic tuning
guidance for each option.

---

## What This Example Covers

| File | Purpose |
|------|---------|
| `router-config-reference.md` | Complete annotated `router.yaml` — every production-critical section |
| `rhai-scripts.md` | Five production Rhai scripts for request enforcement, client ID, cost headers, error scrubbing, and rate limiting |

---

## Prerequisites

| Requirement | Version | Purpose |
|-------------|---------|---------|
| Apollo Router | v1.40+ | The runtime being configured |
| Apollo GraphOS account | Enterprise (for some features) | Uplink schema delivery, entity caching |
| Redis | 7.x | Entity caching (if enabled) |
| JWKS-compatible identity provider | — | JWT authentication (Auth0, Okta, Cognito) |
| OpenTelemetry collector | — | Trace and metric export |

Install the router binary:

```bash
# macOS / Linux — installs the latest stable release
curl -sSL https://router.apollo.dev/download/nix/latest | sh

# Verify
./router --version
# apollo-router 1.x.y
```

---

## How to Apply This Configuration

### 1. Validate the config without starting the router

The router binary ships with a `--validate-config` flag that performs a full parse and
semantic validation of `router.yaml` without binding a port or connecting to subgraphs.
Use this in CI before every deployment.

```bash
./router --config router.yaml --validate-config
# Prints "Configuration is valid" or a structured error with the offending key path
```

### 2. Supply required environment variables

The config file uses `${VAR_NAME}` syntax to reference environment variables. Never
hard-code secrets in `router.yaml`. The following variables are required:

```bash
# Apollo GraphOS — required for uplink schema delivery and usage reporting
export APOLLO_KEY="service:my-graph:xxxxxxxxxxxxxxxxxxxx"
export APOLLO_GRAPH_REF="my-graph@production"

# JWT authentication — JWKS endpoint for token verification
export JWKS_URI="https://auth.example.com/.well-known/jwks.json"

# Redis — required if entity caching is enabled
export REDIS_URL="redis://redis-cache.cache.svc.cluster.local:6379/0"

# Subgraph URLs — injected per-environment
export USERS_SUBGRAPH_URL="http://users-subgraph.users.svc.cluster.local:4001"
export PRODUCTS_SUBGRAPH_URL="http://products-subgraph.products.svc.cluster.local:4002"
export ORDERS_SUBGRAPH_URL="http://orders-subgraph.orders.svc.cluster.local:4003"
export PAYMENTS_SUBGRAPH_URL="http://payments-subgraph.payments.svc.cluster.local:4004"

# Coprocessor — required if coprocessor is enabled
export COPROCESSOR_URL="http://router-coprocessor.gateway.svc.cluster.local:8080"

# OpenTelemetry — OTLP collector endpoint
export OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector.observability.svc.cluster.local:4317"
```

### 3. Start the router

```bash
# Self-managed schema (supergraph.graphql on disk)
./router --config router.yaml --supergraph supergraph.graphql

# GraphOS-managed schema (via uplink — APOLLO_KEY and APOLLO_GRAPH_REF required)
./router --config router.yaml
```

### 4. Hot reload

Apollo Router watches `router.yaml` for changes and reloads most configuration sections
without restart. To trigger a reload without changing the file:

```bash
kill -HUP $(pgrep -f "apollo-router")
```

Note: a small number of config keys (TLS certificates, plugin bindings) require a full
restart. Each key in `router-config-reference.md` notes whether it supports hot reload.

---

## Configuration File Layout

```
examples/02-apollo-router/
├── README.md                    # This file — prerequisites and how to apply
├── router-config-reference.md   # Complete annotated router.yaml
└── rhai-scripts.md              # Production Rhai scripts with explanations
```

In a real deployment, the router config lives alongside the Kubernetes manifests:

```
infra/
├── router/
│   ├── router.yaml              # Config (committed, no secrets)
│   ├── supergraph.graphql       # Supergraph schema (committed or fetched from uplink)
│   ├── kustomization.yaml       # Kubernetes deployment
│   └── scripts/
│       ├── enforce-operation-name.rhai
│       ├── client-identification.rhai
│       └── subgraph-error-scrubbing.rhai
```

---

## Key Design Decisions

### Self-managed vs. GraphOS-managed schema

The reference config covers both modes. Use `supergraph.path` for environments where
schema delivery is handled by your own CI/CD pipeline (maximum control, no GraphOS
dependency). Use uplink (`APOLLO_KEY` + `APOLLO_GRAPH_REF`) for environments where
Apollo GraphOS manages schema delivery and operation checks (recommended for production).

### JWT at the router vs. at subgraphs

This config validates JWTs at the router using the built-in `authentication` plugin.
Subgraphs receive extracted claims via forwarded headers (`x-user-id`, `x-user-roles`),
not raw tokens. This centralizes token verification and reduces the attack surface: a
subgraph bug that skips JWT validation cannot be exploited because the router has already
validated and extracted the claims before the subgraph sees the request.

### Coprocessor scope

The coprocessor is scoped to `RouterRequest` and `SubgraphRequest` only. Adding it to
`RouterResponse` and `SubgraphResponse` would double the number of coprocessor calls per
request. The response stages are covered instead by a lightweight Rhai script (see
`rhai-scripts.md`) which runs in-process and adds no network round-trip latency.

---

## Related Documentation

- [Chapter 08 — Router Configuration](../../docs/08-supergraph-architecture/02-router-configuration.md) — conceptual background for every config section
- [Chapter 05 — Security](../../docs/05-security/) — JWT, mTLS, persisted queries
- [Chapter 14 — Observability](../../docs/14-observability/) — telemetry pipeline and dashboards
- [Chapter 17 — Caching Strategies](../../docs/17-caching-strategies/) — Redis topology for entity caching
