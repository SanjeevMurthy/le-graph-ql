# Hive Router Configuration — CDN Schema Delivery and Usage Reporting

<!-- Companion docs: ../../docs/09-schema-governance/, ../../docs/14-observability/ -->

This document covers configuring Apollo Router (and the alternative Hive Gateway) to fetch the
composed supergraph schema from the GraphQL Hive CDN, report operation usage back to Hive for
analytics and usage-informed schema checks, and manage schema version pinning for reproducible
deployments.

---

## 1. Why Use the Hive CDN for Schema Delivery

Apollo Router requires a composed supergraph SDL to start serving requests. The SDL can be:

1. Embedded in the router container image at build time.
2. Loaded from a file mounted into the container.
3. Polled from a remote URL at startup and periodically thereafter.

Option 3 — polling from a remote URL — is strongly preferred in production because it decouples
schema deployments from router deployments. When a subgraph schema is published and Hive
recomposes the supergraph, the updated SDL becomes available on the Hive CDN. Running router
replicas pick up the new schema on their next poll interval (default: 10 seconds) without any
restart, redeployment, or rolling restart.

The Hive CDN is the equivalent of the Apollo GraphOS Uplink. It:
- Serves the latest valid composed supergraph SDL via HTTPS.
- Is backed by Cloudflare's global CDN for low-latency delivery and high availability.
- Supports pinning to a specific schema version via the CDN URL.
- Requires a CDN Access Token (separate from the Registry Write token used by the CLI).

---

## 2. Apollo Router Configuration — Hive CDN Schema Delivery

The standard Apollo Router configuration uses `uplink` to poll Apollo GraphOS. To use the Hive
CDN instead, configure the `supergraph.schema_source` block.

**router.yaml:**

```yaml
# router.yaml
# Apollo Router configuration for Hive CDN schema delivery.
# Reference: https://www.apollographql.com/docs/router/configuration/overview

supergraph:
  schema_source:
    # Use a remote URL for schema delivery rather than a local file.
    # This enables hot schema reloading without router restarts.
    url:
      # The Hive CDN endpoint for this target's composed supergraph SDL.
      # Constructed as: https://cdn.graphql-hive.com/artifacts/v1/<target-id>/supergraph
      # Set this as an environment variable — the CDN endpoint contains the target ID
      # which is not secret but is environment-specific (production vs staging).
      endpoint: "${env.HIVE_CDN_ENDPOINT}"

      # Authentication header for the Hive CDN.
      # This is the "CDN Access" token, distinct from the "Registry Write" token used by the CLI.
      # CDN Access tokens have read-only access and are safe to distribute to router instances.
      headers:
        X-Hive-CDN-Key: "${env.HIVE_CDN_TOKEN}"

      # How often the router polls the CDN for a new supergraph SDL.
      # 10 seconds is the recommended default — fast enough to pick up schema changes quickly
      # without generating excessive CDN traffic.
      poll_interval: 10s
```

**Environment variables required:**

| Variable | Description | Where to Get It |
|----------|-------------|-----------------|
| `HIVE_CDN_ENDPOINT` | CDN URL for the supergraph SDL | Hive dashboard > Target > Settings > CDN |
| `HIVE_CDN_TOKEN` | CDN Access Token | Hive dashboard > Target > Settings > Tokens |

**Example CDN endpoint format:**

```
https://cdn.graphql-hive.com/artifacts/v1/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/supergraph
```

The UUID in the URL is the Hive target ID. It is not secret but is environment-specific. Use
separate CDN endpoints for production, staging, and development targets.

**Kubernetes deployment — injecting secrets:**

```yaml
# kubernetes/router-deployment.yaml (excerpt)
spec:
  containers:
    - name: apollo-router
      image: ghcr.io/apollographql/router:v1.52.0
      env:
        - name: HIVE_CDN_ENDPOINT
          valueFrom:
            secretKeyRef:
              name: hive-credentials
              key: cdn-endpoint
        - name: HIVE_CDN_TOKEN
          valueFrom:
            secretKeyRef:
              name: hive-credentials
              key: cdn-token
      volumeMounts:
        - name: router-config
          mountPath: /etc/router
      command:
        - /dist/router
        - --config
        - /etc/router/router.yaml
```

---

## 3. Hive Gateway — Alternative to Apollo Router

GraphQL Hive provides its own gateway implementation (`@graphql-hive/gateway`) as an alternative
to Apollo Router. Hive Gateway is fully open-source, written in TypeScript, and designed to be a
drop-in replacement for Apollo Router in environments where TypeScript-based extensibility is
preferred over Rust-based Router plugins.

**When to choose Hive Gateway over Apollo Router:**
- You need deep TypeScript-based plugin customization without the complexity of Rust Rhai scripting.
- You are using GraphQL Stitching (not Apollo Federation) and need native Stitching support.
- You want a single vendor for schema registry, observability, and gateway.

**Installation:**

```bash
npm install @graphql-hive/gateway
```

**gateway.config.ts:**

```typescript
// gateway.config.ts
// Full Hive Gateway configuration for a Federation v2 supergraph.
import { defineConfig } from "@graphql-hive/gateway";

export const gatewayConfig = defineConfig({
  // Load the supergraph schema from the Hive CDN.
  // This is the equivalent of the Apollo Router supergraph.schema_source.url block.
  hive: {
    // The Hive CDN endpoint for this target's composed supergraph SDL.
    // Same format as used by Apollo Router above.
    endpoint: process.env.HIVE_CDN_ENDPOINT!,

    // CDN Access Token for authenticating with the Hive CDN.
    key: process.env.HIVE_CDN_TOKEN!,

    // Poll interval in milliseconds. 10000ms = 10 seconds.
    pollInterval: 10_000,
  },

  // Usage reporting configuration.
  // Hive Gateway has built-in usage reporting — no separate plugin needed.
  reporting: {
    // Enable usage reporting to the Hive Usage service.
    enabled: true,

    // The Registry Write token for the target. This authorizes the gateway to post
    // usage data to the Hive API. Distinct from the CDN Access Token.
    token: process.env.HIVE_TOKEN!,

    // Sample rate for usage reporting.
    // 1.0 = report all operations. Reduce for very high traffic (>10K ops/min).
    sampleRate: 1.0,

    // Extract client identity from request headers for per-client usage breakdown.
    // This allows the Hive dashboard to show "Which clients use which fields?"
    clientInfo({ request }) {
      return {
        name: request.headers.get("x-client-name") ?? "unknown",
        version: request.headers.get("x-client-version") ?? "0.0.0",
      };
    },
  },

  // HTTP server configuration.
  server: {
    // Port the gateway listens on. Override with PORT env var for Kubernetes.
    port: parseInt(process.env.PORT ?? "4000"),

    // Bind to 0.0.0.0 for Kubernetes pod networking.
    // Binding to 127.0.0.1 (the default) would prevent the service from receiving
    // traffic routed by kube-proxy.
    hostname: "0.0.0.0",
  },

  // CORS configuration for browser clients.
  cors: {
    origin: process.env.ALLOWED_ORIGINS?.split(",") ?? [],
    credentials: true,
  },

  // Disable introspection in production.
  // Introspection exposes the full schema to unauthenticated clients.
  // Enable in development by setting ALLOW_INTROSPECTION=true.
  introspection: process.env.ALLOW_INTROSPECTION === "true",
});
```

**Starting Hive Gateway:**

```bash
# Development
npx hive-gateway dev --config gateway.config.ts

# Production (after TypeScript compilation)
node dist/gateway.js
```

---

## 4. Usage Reporting from Apollo Router

Apollo Router does not natively integrate with Hive's usage reporting API. Instead, usage data is
collected via OpenTelemetry. Hive provides an OpenTelemetry-compatible collector endpoint that
receives spans from the router and extracts operation usage data.

**router.yaml — telemetry section for Hive usage reporting:**

```yaml
# router.yaml
telemetry:
  exporters:
    tracing:
      otlp:
        # Hive's OpenTelemetry collector endpoint.
        # This endpoint accepts OTLP/HTTP trace data and converts it to Hive usage reports.
        endpoint: "${env.HIVE_USAGE_ENDPOINT}"

        # Hive requires the registry write token as a Bearer auth header.
        # The "Authorization" header name is case-insensitive in HTTP/2 but Hive
        # expects the capitalized form for OTLP/HTTP.
        headers:
          Authorization: "Bearer ${env.HIVE_TOKEN}"

        # Protocol: use HTTP/protobuf. Hive's collector endpoint does not support gRPC.
        protocol: http

  instrumentation:
    spans:
      router:
        # Add the operation name and type to every router-level span.
        # Hive uses these attributes to aggregate usage by operation.
        attributes:
          graphql.operation.name:
            request_header: x-graphql-operation-name
          graphql.operation.type: true

      subgraph:
        # Enable subgraph-level spans. Hive uses these to track which subgraph
        # fields are resolved for each operation.
        attributes:
          subgraph.name: true
          subgraph.graphql.operation.type: true
```

**Hive usage endpoint:**

For Hive Cloud:
```
https://usage.graphql-hive.com
```

For self-hosted Hive, replace with the URL of your deployed usage service:
```
https://hive.internal.example.com/usage
```

---

## 5. Schema Version Pinning

By default, Apollo Router polls the Hive CDN for the latest composed supergraph SDL. In some
scenarios, you need to pin to a specific schema version:

- **Reproducible deployments**: Pin a deployment artifact to the exact schema version that was
  tested and approved, preventing a concurrent schema change from affecting the deployment.
- **Rollback**: Roll back to a known-good schema version after a bad publish without redeploying
  the router.
- **Canary deployments**: Run a canary router fleet on a new schema version while keeping the
  stable fleet on the previous version.

**Pinning to a specific Hive schema version:**

Each published schema version in Hive has a commit ID (the git SHA passed via `--commit` during
`hive schema:publish`). The CDN supports fetching the supergraph SDL for a specific commit:

```
https://cdn.graphql-hive.com/artifacts/v1/<target-id>/supergraph?actionId=<action-id>
```

The `actionId` is the Hive internal schema action ID, visible in the Hive dashboard under
Schema History. It is a UUID, not the git SHA.

Alternatively, pin via the git commit by appending the commit SHA as a query parameter (only
supported when the schema was published with `--commit`):

```
https://cdn.graphql-hive.com/artifacts/v1/<target-id>/supergraph?commit=abc1234
```

**router.yaml for pinned schema:**

```yaml
supergraph:
  schema_source:
    url:
      # Pin to a specific schema version by commit SHA.
      # The router will not pick up newer versions until this URL is updated.
      endpoint: "${env.HIVE_CDN_ENDPOINT}?commit=${env.PINNED_SCHEMA_COMMIT}"
      headers:
        X-Hive-CDN-Key: "${env.HIVE_CDN_TOKEN}"
      # Reduce poll frequency when pinned — the version will never change.
      poll_interval: 300s
```

For production deployments, inject `PINNED_SCHEMA_COMMIT` as a deployment-time environment
variable from the CI/CD pipeline, set to the specific commit SHA that passed staging validation.

---

## 6. Fallback Behavior When Hive CDN Is Unreachable

Apollo Router handles CDN unavailability as follows:

**At startup:**
- If the router cannot fetch the supergraph SDL on startup (CDN unreachable, network error,
  auth failure), it retries with exponential backoff for up to 30 seconds.
- If all retries are exhausted, the router exits with a non-zero exit code.
- Kubernetes will restart the pod, which triggers another attempt on restart.
- This behavior prevents a router with a stale or unknown schema from silently serving traffic
  during a CDN outage.

**During runtime:**
- If a poll to the Hive CDN fails while the router is already running, the router logs a warning
  and continues serving traffic using the last successfully loaded supergraph SDL.
- This is the "last known good" behavior — the router never degrades its service due to a CDN
  poll failure.
- Consecutive poll failures trigger a `WARN` log at each poll interval. Configure alerting on
  this log pattern to detect prolonged CDN unavailability.
- The in-memory schema is retained indefinitely — there is no TTL after which the router refuses
  requests due to a stale schema.

**Caching for faster startup:**

To reduce startup time and provide a local fallback, mount a copy of the supergraph SDL as a
Kubernetes ConfigMap and configure the router to use it as a startup seed:

```yaml
supergraph:
  schema_source:
    url:
      endpoint: "${env.HIVE_CDN_ENDPOINT}"
      headers:
        X-Hive-CDN-Key: "${env.HIVE_CDN_TOKEN}"
      poll_interval: 10s
      # Use a local file as the initial schema during startup.
      # After startup, the router immediately polls the CDN and may update to a newer version.
      fallback_file: /etc/router/supergraph-seed.graphql
```

The seed file is updated by a CI/CD job that fetches the current supergraph SDL from the CDN and
commits it to the ConfigMap. On pod restart, the router starts instantly from the seed and then
upgrades to the latest CDN version within one poll interval.

---

## Related Documentation

- `../../docs/09-schema-governance/` — Schema governance policies and schema version lifecycle.
- `../../docs/14-observability/` — Full observability strategy including usage analytics.
- `hive-cli-usage.md` — Publishing schemas to Hive from CI/CD, which triggers CDN updates.
- `self-hosted-hive.md` — Running the Hive CDN as part of a self-hosted deployment.
- `../../examples/10-open-telemetry/router-telemetry-config.md` — Full Apollo Router telemetry
  configuration, including the usage reporting telemetry setup described in section 4 above.

---

## Key Design Decisions

**CDN Access Token separate from Registry Write Token**
The router uses a CDN Access Token, not the Registry Write Token used by the CLI. This follows the
principle of least privilege: the router only needs to read the composed schema, not publish
schemas or manage tokens. If the CDN token is leaked (e.g., via a misconfigured logging pipeline
that captures environment variables), the blast radius is limited to read access on the schema
SDL — it cannot be used to overwrite or corrupt the schema registry.

**Using Apollo Router over Hive Gateway**
For this federation, Apollo Router is preferred because it is written in Rust and provides
significantly better CPU and memory efficiency at high request rates. Hive Gateway is the right
choice when TypeScript plugin extensibility is needed, but the performance trade-off is
significant at scale.

**Polling over webhook push**
The Hive CDN uses a polling model rather than pushing schema updates to routers. Polling is
preferred because it works across NAT boundaries, does not require the router to expose an
inbound port, and is resilient to transient network failures (a missed push would require explicit
retry logic, whereas a missed poll is automatically retried on the next poll interval).
