# Apollo Router Rhai Scripts — Production Reference

Companion doc: [Chapter 13 — Router Customization with Rhai](../../docs/13-rhai/rhai-customization.md)

Rhai is a scripting language embedded in Apollo Router for lightweight request/response transformations. It runs in the router process itself, synchronously, inside the request pipeline. Keep scripts fast: no I/O, no blocking calls, no heavy computation.

Rhai scripts fire at specific pipeline stages. Each script registers one or more callback functions corresponding to router lifecycle hooks.

---

## Pipeline Stages Available to Rhai

| Hook Function | Stage | Direction | Use Case |
|---|---|---|---|
| `router_request` | Router | Inbound | Validate/modify client request before query planning |
| `router_response` | Router | Outbound | Modify final response before sending to client |
| `supergraph_request` | Supergraph | Inbound | Access parsed operation after query planning begins |
| `supergraph_response` | Supergraph | Outbound | Modify response after all subgraph data is merged |
| `subgraph_request` | Subgraph | Inbound | Modify per-subgraph request before it is sent |
| `subgraph_response` | Subgraph | Outbound | Modify per-subgraph response before merging |

---

## Wiring Scripts into `router.yaml`

All scripts are wired under the `rhai` section of `router.yaml`. Each file registers its own hook functions. Multiple scripts can be loaded simultaneously.

```yaml
rhai:
  scripts: /etc/router/rhai      # Directory containing .rhai files
  main: main.rhai                # Entry point that imports other scripts
```

Or, load scripts individually (useful for testing one script in isolation):

```yaml
rhai:
  scripts: /etc/router/rhai
  main: enforce-operation-name.rhai
```

---

## Script 1: `enforce-operation-name.rhai`

**Purpose:** Reject anonymous GraphQL operations. Anonymous operations cannot be tracked in Apollo Studio, cannot be used with Automated Persisted Queries, and cannot be subject to operation-level authorization or rate limiting policies. Named operations are a prerequisite for production observability.

**Why this matters:** Without operation names, Studio reports show `(anonymous)` as the operation name, making it impossible to understand which feature or team is responsible for a given traffic pattern or error.

**Pipeline stage:** `router_request` — reject before any query planning work is done.

```rhai
// enforce-operation-name.rhai
//
// Rejects GraphQL operations that do not have an explicit operationName.
// Allows introspection queries and health checks to pass through unconditionally.
//
// Error contract: returns HTTP 400 with a structured GraphQL-style error body.

// Paths that are always allowed through, regardless of operation name.
// Health checks and OPTIONS preflights should never be blocked.
const ALLOWLIST_PATHS = [
    "/.well-known/apollo/server-health",
    "/health",
    "/metrics",
];

// Introspection operation names that are always allowed.
// Apollo Studio and tooling (rover, graphql-inspector) use these.
const INTROSPECTION_NAMES = [
    "IntrospectionQuery",
    "__ApolloGetServiceDefinition__",
    "__ApolloServiceDefinition__",
];

fn router_request(request) {
    // Allow non-POST requests through (e.g., GET requests for APQ cache hits,
    // OPTIONS preflight requests for CORS).
    let method = request.method;
    if method != "POST" {
        return request;
    }

    // Allow requests to health and metrics paths — these are not GraphQL requests.
    let path = request.uri.path;
    for allowlisted_path in ALLOWLIST_PATHS {
        if path == allowlisted_path {
            return request;
        }
    }

    // Parse the request body. The body is a JSON string at this stage.
    // If parsing fails, let the request through — the router will return
    // a proper parse error downstream.
    let body = request.body;
    if body == () {
        return request;
    }

    // Extract operationName from the JSON body.
    // The GraphQL-over-HTTP spec places operationName at the top level
    // of the JSON object: { "query": "...", "operationName": "...", "variables": {} }
    let operation_name = body["operationName"];

    // Null, missing, or empty string all count as anonymous.
    if operation_name == () || operation_name == "" {
        // Check if this is an introspection query by inspecting the query field.
        // Introspection queries start with `query` and contain `__schema` or `__type`.
        // We do a simple string check here rather than parsing the full AST.
        let query = body["query"];
        if query != () {
            let query_str = query.to_string();
            if query_str.contains("__schema") || query_str.contains("__type") {
                // This is an introspection query — allow it through.
                // Introspection is separately controlled by `supergraph.introspection`
                // in router.yaml; this script does not re-implement that check.
                return request;
            }
        }

        // Operation is anonymous and not introspection — reject it.
        // Return a structured error that matches GraphQL error conventions
        // so clients can handle it programmatically.
        log_warn(`Rejected anonymous operation from ${request.headers["apollographql-client-name"]}`);

        // Throw an error to halt pipeline processing and return a response.
        // The status code 400 signals a client error (bad request).
        throw #{
            status: 400,
            message: "Anonymous operations are not allowed. Provide an operationName in your request.",
            // Include a machine-readable error code for client-side handling.
            extensions: #{
                code: "ANONYMOUS_OPERATION_NOT_ALLOWED",
                // Point developers to documentation so they understand how to fix this.
                documentation: "https://docs.example.com/graphql/operation-names",
            },
        };
    }

    // The operation has a name. Allow known introspection names through without
    // further validation — they have legitimate reasons to be named differently.
    for introspection_name in INTROSPECTION_NAMES {
        if operation_name == introspection_name {
            return request;
        }
    }

    // Operation name is present and not reserved. Allow it through.
    // Optionally: validate that the name matches a naming convention here
    // (e.g., PascalCase, or starts with the client name as a namespace).
    return request;
}
```

### How to wire this into `router.yaml`

```yaml
rhai:
  scripts: /etc/router/rhai
  main: enforce-operation-name.rhai
```

To combine with other scripts, create a `main.rhai` that imports all of them:

```rhai
// main.rhai — entry point that loads all scripts
import "enforce-operation-name" as op_name;
import "client-identification" as client_id;
```

---

## Script 2: `client-identification.rhai`

**Purpose:** Enforce that all clients identify themselves via the standard Apollo client identification headers (`apollographql-client-name`, `apollographql-client-version`). Propagate these headers to subgraph requests and add them as span attributes for trace correlation.

**Why this matters:** Client identification is the foundation of per-client observability in Apollo Studio. Without it, you cannot distinguish between traffic from your iOS app, your web app, and your internal microservices. When a performance regression occurs, you cannot tell which client introduced it.

**Pipeline stages:** `router_request` (enforce and record) and `subgraph_request` (propagate).

```rhai
// client-identification.rhai
//
// Enforces Apollo client identification headers on all non-health-check requests.
// Propagates headers to subgraph requests.
// Adds client identity to the current span for trace correlation.
//
// Clients must send:
//   apollographql-client-name: "ios-app"          (required)
//   apollographql-client-version: "2.4.1"         (required)

// Environments where missing client headers are only warned, not rejected.
// This prevents blocking local development where clients may not yet send headers.
// In all other environments (staging, production), missing headers are rejected.
const PERMISSIVE_ENVIRONMENTS = ["development", "local"];

fn router_request(request) {
    // Skip enforcement for health checks and non-GraphQL paths.
    let path = request.uri.path;
    if path == "/health" || path == "/.well-known/apollo/server-health" {
        return request;
    }

    // Skip OPTIONS preflight requests — browsers send these before POST.
    if request.method == "OPTIONS" {
        return request;
    }

    let client_name = request.headers["apollographql-client-name"];
    let client_version = request.headers["apollographql-client-version"];

    // Determine current environment from the context.
    // This value is set by an `insert` header rule in router.yaml or
    // by reading an environment variable at startup via a Rhai global.
    let env = env_var("ROUTER_ENV");
    let is_permissive = false;
    for permissive_env in PERMISSIVE_ENVIRONMENTS {
        if env == permissive_env {
            is_permissive = true;
        }
    }

    // Check for missing client name.
    if client_name == () || client_name == "" {
        if is_permissive {
            // In development, log a warning but allow through.
            // This helps developers notice the missing header without breaking their flow.
            log_warn("Missing apollographql-client-name header — required in production");
        } else {
            // In production/staging, reject immediately.
            log_warn("Rejected request: missing apollographql-client-name");
            throw #{
                status: 400,
                message: "Header 'apollographql-client-name' is required.",
                extensions: #{
                    code: "MISSING_CLIENT_IDENTIFICATION",
                    header: "apollographql-client-name",
                },
            };
        }
    }

    // Check for missing client version.
    if client_version == () || client_version == "" {
        if is_permissive {
            log_warn("Missing apollographql-client-version header — required in production");
        } else {
            log_warn("Rejected request: missing apollographql-client-version");
            throw #{
                status: 400,
                message: "Header 'apollographql-client-version' is required.",
                extensions: #{
                    code: "MISSING_CLIENT_IDENTIFICATION",
                    header: "apollographql-client-version",
                },
            };
        }
    }

    // Store client identity in the request context so it is accessible
    // in the subgraph_request hook and in the response hook for logging.
    // Context values survive across all pipeline stages for a single request.
    request.context["client_name"] = client_name;
    request.context["client_version"] = client_version;

    return request;
}

fn subgraph_request(request) {
    // Propagate client identity to all subgraph requests.
    // This allows subgraph logs and traces to record which client triggered
    // each subgraph call, enabling end-to-end attribution.
    let client_name = request.context["client_name"];
    let client_version = request.context["client_version"];

    if client_name != () {
        request.subgraph.headers["apollographql-client-name"] = client_name;
    }
    if client_version != () {
        request.subgraph.headers["apollographql-client-version"] = client_version;
    }

    return request;
}
```

### How to wire this into `router.yaml`

```yaml
rhai:
  scripts: /etc/router/rhai
  main: client-identification.rhai

# Ensure the environment variable is available to the Rhai script.
# router.yaml does not need a special section for this — Rhai reads env vars
# directly via env_var(). Ensure ROUTER_ENV is set in your container spec.
```

Note: header propagation via Rhai (`request.subgraph.headers`) works alongside the `headers` propagation rules in `router.yaml`. They are additive — the Rhai script adds headers that are not covered by static propagation rules.

---

## Script 3: `request-cost-header.rhai`

**Purpose:** After query planning, read the estimated query plan cost from the router context and inject it as an `x-query-cost` response header. Log requests that exceed a cost threshold for investigation. This does not block requests — it is diagnostic-only.

**Why this matters:** Query plan cost is the router's internal estimate of how expensive an operation will be to execute (number of subgraph fetches, entity resolutions, etc.). Exposing it as a response header lets clients and API teams monitor cost trends without querying metrics systems. It is essential for identifying runaway queries before they cause incidents.

**Pipeline stages:** `supergraph_response` — cost is known only after query planning completes.

```rhai
// request-cost-header.rhai
//
// Injects the query plan cost estimate into the response as a header.
// Logs a warning when cost exceeds the configured threshold.
// Does NOT reject requests — purely diagnostic.
//
// The cost estimate reflects the number of resolver invocations the router
// estimates for this operation. It is not a wall-clock time estimate.

// Warn when query plan cost exceeds this value.
// Tune based on your schema complexity. Start with 100 and adjust after
// observing a week of production traffic histograms.
const COST_WARN_THRESHOLD = 100;

// Log at ERROR level (and alert on it) when cost exceeds this value.
// Queries this expensive are likely runaway operations or bugs.
const COST_ERROR_THRESHOLD = 500;

fn supergraph_response(response) {
    // Query plan cost is stored in the router context after planning completes.
    // The key name may vary by router version — check the Apollo Router changelog
    // if this returns null after a router upgrade.
    let cost = response.context["apollo_query_plan_cost"];

    // If cost is unavailable (e.g., APQ cache hit, introspection), skip.
    if cost == () {
        return response;
    }

    // Inject the cost as a response header.
    // Clients and API gateways can read this header to implement client-side
    // cost budgeting or alerting.
    response.headers["x-query-cost"] = cost.to_string();

    // Extract the operation name for log context.
    let operation_name = response.context["operation_name"];
    let client_name = response.context["client_name"];
    let request_id = response.headers["x-request-id"];

    // Log a warning for expensive queries. These logs should feed into
    // an alerting rule in your log aggregator (Datadog, Splunk, etc.).
    if cost >= COST_ERROR_THRESHOLD {
        log_error(`High query cost: cost=${cost} operation=${operation_name} client=${client_name} request_id=${request_id}`);
    } else if cost >= COST_WARN_THRESHOLD {
        log_warn(`Elevated query cost: cost=${cost} operation=${operation_name} client=${client_name} request_id=${request_id}`);
    }

    // Optionally: expose the threshold values so clients know what the limits are.
    response.headers["x-query-cost-warn-threshold"] = COST_WARN_THRESHOLD.to_string();

    return response;
}
```

### How to wire this into `router.yaml`

```yaml
rhai:
  scripts: /etc/router/rhai
  main: request-cost-header.rhai

# Ensure the x-query-cost header is exposed to browser clients via CORS.
cors:
  expose_headers:
    - x-query-cost
    - x-query-cost-warn-threshold
```

Note: the `apollo_query_plan_cost` context key is only available when query planning runs. Requests that hit the query plan cache (repeated operations) may not have this value populated with a freshly computed cost — they will receive the cached plan's cost from the context if it was stored there previously.

---

## Script 4: `subgraph-error-scrubbing.rhai`

**Purpose:** Intercept subgraph error responses before they are merged into the final client response. Remove or redact internal error details (database error messages, stack traces, internal service names) that should never reach external clients. Log the original error with the request ID so engineers can investigate.

**Why this matters:** Subgraph errors often contain internal details — Postgres error codes, internal hostnames, stack traces, or service names. These are security disclosures. A client that sees `ERROR: relation "users_v2" does not exist at character 38` learns your database schema. A client that sees `connection refused: db-primary-01.internal:5432` learns your network topology.

**Pipeline stage:** `subgraph_response` — intercept errors from each subgraph individually.

```rhai
// subgraph-error-scrubbing.rhai
//
// Scrubs internal error details from subgraph responses before they are merged
// into the final client-facing response.
//
// Strategy:
//   - Preserve the error path (which field failed) — clients need this to handle partial data
//   - Preserve the error "locations" (line/column) — useful for client-side debugging
//   - Replace the error message with a generic INTERNAL_SERVER_ERROR message
//   - Strip all extensions except the `code` field (strip stack traces, service details)
//   - Log the original error message with request ID for backend investigation

// Subgraphs that serve external clients get full scrubbing.
// Internal-only subgraphs (only called by trusted internal services) can be exempted.
// This list should contain ALL subgraphs in a public-facing deployment.
const SCRUB_SUBGRAPHS = [
    "users",
    "products",
    "orders",
    "payments",
    "inventory",
    "recommendations",
];

// Error messages that are safe to pass through verbatim because they are
// already client-friendly. This is an allowlist — anything not in this list
// gets scrubbed.
const SAFE_ERROR_CODES = [
    "NOT_FOUND",
    "UNAUTHENTICATED",
    "FORBIDDEN",
    "BAD_USER_INPUT",
    "VALIDATION_ERROR",
];

fn subgraph_response(response) {
    // Determine whether this subgraph's errors should be scrubbed.
    let subgraph_name = response.subgraph.name;
    let should_scrub = false;
    for scrub_subgraph in SCRUB_SUBGRAPHS {
        if subgraph_name == scrub_subgraph {
            should_scrub = true;
        }
    }

    if !should_scrub {
        return response;
    }

    // Check if the response contains errors.
    let errors = response.body["errors"];
    if errors == () || errors.len() == 0 {
        // No errors — nothing to scrub.
        return response;
    }

    // Extract the request ID for log correlation.
    let request_id = response.headers["x-request-id"];
    if request_id == () {
        request_id = "unknown";
    }

    // Process each error in the array.
    let scrubbed_errors = [];
    for error in errors {
        let original_message = error["message"];
        let original_extensions = error["extensions"];
        let error_code = "";

        // Extract the error code if present.
        if original_extensions != () {
            let code = original_extensions["code"];
            if code != () {
                error_code = code.to_string();
            }
        }

        // Check if this error code is on the safe allowlist.
        let is_safe = false;
        for safe_code in SAFE_ERROR_CODES {
            if error_code == safe_code {
                is_safe = true;
            }
        }

        if is_safe {
            // Safe error — pass through verbatim.
            scrubbed_errors.push(error);
        } else {
            // Unsafe error — log original and replace with generic message.
            // The log line must include enough context for an engineer to find
            // the subgraph trace without exposing the error to the client.
            log_error(`Scrubbed subgraph error: subgraph=${subgraph_name} request_id=${request_id} original_message="${original_message}" code="${error_code}"`);

            // Build a scrubbed error that preserves structure but removes content.
            let scrubbed = #{
                // Generic message that tells the client something failed
                // without revealing why or where.
                message: "Internal server error",
                // Preserve path — clients need this to handle partial responses correctly.
                // Without path, a client cannot determine which field to show a fallback for.
                path: error["path"],
                // Preserve locations — useful for client-side schema validation debugging.
                locations: error["locations"],
                // Include only the generic code. Strip stack traces, database details, etc.
                extensions: #{
                    code: "INTERNAL_SERVER_ERROR",
                    // Include the request ID so clients can reference it in support requests.
                    requestId: request_id,
                },
            };
            scrubbed_errors.push(scrubbed);
        }
    }

    // Replace the errors array with the scrubbed version.
    response.body["errors"] = scrubbed_errors;

    return response;
}
```

### How to wire this into `router.yaml`

```yaml
rhai:
  scripts: /etc/router/rhai
  main: subgraph-error-scrubbing.rhai
```

Important: this script only handles errors returned in the GraphQL response body (`{ "errors": [...] }`). HTTP-level errors from subgraphs (5xx responses) are handled separately by the router's error handling logic and formatted before this hook fires. Test both paths.

---

## Script 5: `per-client-rate-limit.rhai`

**Purpose:** In-memory sliding window rate limit keyed on `apollographql-client-name`. Rejects requests with HTTP 429 when a client exceeds 100 requests per minute. Returns a `Retry-After` header.

**Why this matters:** A single misbehaving client (a client with a bug that sends 10,000 req/s, a scraper, or a misconfigured CI pipeline) can saturate the router and degrade service for all other clients. A per-client rate limit isolates the blast radius.

**Production caveat:** In-memory rate limiting only works correctly on a single router instance. In a multi-replica deployment, each replica maintains an independent counter, so the effective rate limit per client is `limit * replica_count`. For multi-instance deployments, use the Redis-based rate limiting built into Apollo Router Enterprise (`traffic_shaping` with external Redis) or implement rate limiting in your coprocessor. This script is appropriate for: single-router deployments, as a backstop for single-client abuse, or as a starting point to understand the Rhai API.

**Pipeline stage:** `router_request` — reject before any work is done.

```rhai
// per-client-rate-limit.rhai
//
// Sliding window rate limiter keyed on apollographql-client-name.
// Limit: 100 requests per 60-second window per named client.
//
// WARNING: In-memory only. Not shared across router replicas.
// For multi-instance deployments, use Redis-based rate limiting instead.
// See: https://www.apollographql.com/docs/router/configuration/traffic-management

// Rate limit configuration.
const RATE_LIMIT_REQUESTS = 100;      // Maximum requests per window per client
const RATE_LIMIT_WINDOW_SECS = 60;    // Window size in seconds

// Clients in this list have a higher limit or are exempt entirely.
// Use for internal services, monitoring tools, or premium API tiers.
const EXEMPT_CLIENTS = [
    "internal-monitoring",
    "graphql-inspector",
    "apollo-studio-health",
];

// In-memory store: maps client name to an array of request timestamps (epoch seconds).
// Rhai module-level variables persist for the lifetime of the router process
// but are NOT shared between request-handling threads.
// This is safe because Rhai executes in a single-threaded context per worker.
let request_log = #{};

fn router_request(request) {
    // Skip rate limiting for health checks and non-POST requests.
    let path = request.uri.path;
    if path == "/health" || path == "/.well-known/apollo/server-health" {
        return request;
    }
    if request.method == "OPTIONS" {
        return request;
    }

    // Identify the client. Fall back to IP address if no client name header.
    let client_name = request.headers["apollographql-client-name"];
    if client_name == () || client_name == "" {
        // Use the remote IP as the key for unidentified clients.
        // This provides a basic backstop even when enforcement-operation-name.rhai
        // is not loaded or has not yet rejected the anonymous request.
        client_name = request.headers["x-forwarded-for"];
        if client_name == () {
            client_name = "unknown";
        }
    }

    // Exempt privileged clients from rate limiting.
    for exempt_client in EXEMPT_CLIENTS {
        if client_name == exempt_client {
            return request;
        }
    }

    // Get current epoch time in seconds.
    // Rhai does not have a native time() function — use the router-provided
    // `unix_now()` function (available in Apollo Router >= 1.30).
    let now = unix_now();

    // Retrieve or initialize the request log for this client.
    if !request_log.contains(client_name) {
        request_log[client_name] = [];
    }
    let timestamps = request_log[client_name];

    // Sliding window: discard timestamps older than the window boundary.
    let window_start = now - RATE_LIMIT_WINDOW_SECS;
    let fresh_timestamps = [];
    for ts in timestamps {
        if ts >= window_start {
            fresh_timestamps.push(ts);
        }
    }

    // Count requests in the current window.
    let request_count = fresh_timestamps.len();

    if request_count >= RATE_LIMIT_REQUESTS {
        // Client has exceeded the rate limit.
        // Calculate the retry-after time: when will the oldest request in
        // the window expire, making room for a new one?
        let oldest_ts = fresh_timestamps[0];
        let retry_after_secs = (oldest_ts + RATE_LIMIT_WINDOW_SECS) - now;
        if retry_after_secs < 1 {
            retry_after_secs = 1;
        }

        log_warn(`Rate limit exceeded: client=${client_name} count=${request_count} limit=${RATE_LIMIT_REQUESTS} window=${RATE_LIMIT_WINDOW_SECS}s`);

        // Do NOT update the request log for rejected requests.
        // We still need to persist the pruned timestamp list.
        request_log[client_name] = fresh_timestamps;

        throw #{
            status: 429,
            // RFC 7231 compliant error response.
            message: `Rate limit exceeded. Maximum ${RATE_LIMIT_REQUESTS} requests per ${RATE_LIMIT_WINDOW_SECS} seconds.`,
            headers: #{
                // Retry-After header tells clients when they can retry.
                // Clients that respect this header will back off correctly.
                "Retry-After": retry_after_secs.to_string(),
                // X-RateLimit headers are a de facto standard for rate limit visibility.
                "X-RateLimit-Limit": RATE_LIMIT_REQUESTS.to_string(),
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": (oldest_ts + RATE_LIMIT_WINDOW_SECS).to_string(),
            },
            extensions: #{
                code: "RATE_LIMITED",
                client: client_name,
                limit: RATE_LIMIT_REQUESTS,
                window_seconds: RATE_LIMIT_WINDOW_SECS,
                retry_after_seconds: retry_after_secs,
            },
        };
    }

    // Record this request timestamp in the sliding window log.
    fresh_timestamps.push(now);
    request_log[client_name] = fresh_timestamps;

    return request;
}
```

### How to wire this into `router.yaml`

```yaml
rhai:
  scripts: /etc/router/rhai
  main: per-client-rate-limit.rhai

# Ensure rate limit response headers reach browser clients.
cors:
  expose_headers:
    - Retry-After
    - X-RateLimit-Limit
    - X-RateLimit-Remaining
    - X-RateLimit-Reset
```

For production multi-replica deployments, replace this script with the built-in rate limiting:

```yaml
# router.yaml — built-in rate limiting (Enterprise, Redis-backed)
traffic_shaping:
  all:
    experimental_rate_limiting:
      enabled: true
      storage:
        redis:
          url: "${env.REDIS_URL}"
      mode:
        local:               # or "global" for cluster-wide limits
          capacity: 100
          interval: 60s
      key:
        header_name: apollographql-client-name
```

---

## Combining Scripts: `main.rhai`

When using multiple scripts, create a single entry point that imports all of them. Rhai does not automatically compose hook functions from multiple files — the `main` entry point must explicitly wire them.

```rhai
// main.rhai
//
// Entry point for all router Rhai customizations.
// Each import loads the module and exposes its hook functions.
//
// Load order matters for hooks that run at the same stage:
// functions registered by later imports override earlier ones
// for the same hook name. If two scripts both define router_request,
// only the last-imported one runs. Compose explicitly instead.

import "enforce-operation-name" as op_name;
import "client-identification" as client_id;
import "request-cost-header" as cost_header;
import "subgraph-error-scrubbing" as error_scrub;
import "per-client-rate-limit" as rate_limit;

// Compose router_request hooks explicitly.
// Each script's fn is called in sequence. If any throws, the pipeline halts.
fn router_request(request) {
    // Rate limiting first — fail fast before doing any other work.
    request = rate_limit::router_request(request);
    // Then enforce client identification.
    request = client_id::router_request(request);
    // Then enforce operation naming.
    request = op_name::router_request(request);
    return request;
}

fn supergraph_response(response) {
    response = cost_header::supergraph_response(response);
    return response;
}

fn subgraph_request(request) {
    request = client_id::subgraph_request(request);
    return request;
}

fn subgraph_response(response) {
    response = error_scrub::subgraph_response(response);
    return response;
}
```

```yaml
# router.yaml
rhai:
  scripts: /etc/router/rhai
  main: main.rhai
```

---

## Key Design Decisions

**Why Rhai instead of coprocessor for these scripts?**
Rhai runs in-process with zero network overhead. A coprocessor adds an HTTP round-trip (~1-5ms minimum) per request. For lightweight logic like header validation, operation name enforcement, and response header injection, in-process Rhai is faster and has fewer operational dependencies. Use a coprocessor when logic is complex enough to require a full programming language, external I/O, or shared mutable state across replicas.

**Why log the original error in the scrubbing script rather than sending it to a context key?**
The subgraph error context is available in `subgraph_response` but is discarded after the stage completes. Writing to a log stream is the reliable path — log aggregators (Datadog, Splunk, CloudWatch) can then correlate errors by `request_id`. Context keys can be used additionally to surface error codes in the router span.

**Why reject at `router_request` for rate limiting instead of `supergraph_request`?**
`router_request` fires before query planning. Rejecting here means no CPU is spent on parsing, query planning, or subgraph fan-out for rate-limited requests. Always reject as early in the pipeline as possible.

**Why use a sliding window instead of a fixed window for rate limiting?**
Fixed windows have a burst problem: a client can send 100 requests at 11:59:59 and 100 more at 12:00:01, effectively sending 200 requests in 2 seconds. A sliding window prevents this by always evaluating the most recent N seconds of history. The tradeoff is slightly higher memory usage (storing individual timestamps vs. a single counter).

**Why are the error scrubbing and rate limit scripts subgraph-name-aware?**
Not all subgraphs have the same security requirements. Internal-only subgraphs (called only by trusted internal services) may legitimately expose detailed error messages to their callers. A hardcoded allowlist of subgraphs to scrub is safer than a default-scrub-everything approach because it forces an explicit review when new subgraphs are added.

---

## Related Documentation

- [Chapter 13 — Router Customization with Rhai](../../docs/13-rhai/rhai-customization.md)
- [Chapter 08 — Apollo Federation v2 Production Architecture](../../docs/08-federation/federation-production.md)
- [Chapter 09 — Authentication and Authorization Patterns](../../docs/09-auth/auth-patterns.md)
- [Chapter 10 — Observability and Tracing](../../docs/10-observability/tracing.md)
- [Chapter 12 — Rate Limiting and Traffic Shaping](../../docs/12-traffic/rate-limiting.md)
- [Router Config Reference](./router-config-reference.md) — companion file in this directory
