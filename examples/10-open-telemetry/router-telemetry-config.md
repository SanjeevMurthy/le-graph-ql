# Apollo Router Telemetry Configuration — Production Reference

<!-- Companion docs: ../../docs/14-observability/ -->

This document provides the complete `router.yaml` telemetry section for a production Apollo Router
deployment. It covers OTLP gRPC trace export with batch processing, custom span attributes for
GraphQL operation context, per-subgraph child spans, the Prometheus metrics endpoint with key
metrics, custom instruments, structured JSON logging, and W3C baggage propagation for request
correlation.

All configuration is designed to be safe for high-traffic production deployments. Tuning
recommendations are provided for each configurable parameter with the rationale for the default
values.

---

## Complete router.yaml — Telemetry Section

The following is a production-ready `router.yaml`. Copy this and merge it with your existing
router configuration. The telemetry section is independent of supergraph, traffic shaping, and
authorization configuration.

```yaml
# router.yaml
# Apollo Router configuration — telemetry section.
# Reference: https://www.apollographql.com/docs/router/configuration/telemetry/

telemetry:

  # ==========================================================================
  # SECTION 1: Tracing — OTLP gRPC Exporter
  # ==========================================================================
  exporters:
    tracing:
      # The OTLP gRPC exporter sends spans to the OpenTelemetry Collector.
      # gRPC is preferred over HTTP because it supports streaming and has lower
      # per-message overhead than HTTP/1.1, which matters at high span rates.
      otlp:
        # Enable the OTLP exporter. Set to false to disable tracing entirely
        # without removing the configuration (useful for emergency cost control).
        enabled: true

        # The OTel Collector gRPC endpoint. Use an environment variable so the
        # same router.yaml works in multiple environments (dev, staging, prod).
        # The endpoint does NOT include the /v1/traces path — that is part of
        # the OTLP HTTP protocol, not gRPC.
        endpoint: "${env.OTEL_COLLECTOR_ENDPOINT:-http://otel-collector.monitoring.svc.cluster.local:4317}"

        # gRPC metadata (HTTP/2 headers) for authenticating with the Collector.
        # If your Collector is secured with a token (e.g., Grafana Cloud OTLP),
        # add the Authorization header here.
        # For an internal Cluster-local Collector, authentication is optional but
        # recommended as defense-in-depth.
        grpc:
          metadata:
            # Uncomment and set if your Collector requires authentication.
            # Authorization: "Bearer ${env.OTEL_COLLECTOR_TOKEN}"

        # Batch processor — controls how spans are buffered before export.
        # Batching is critical for efficiency: exporting spans one at a time would
        # overwhelm the Collector and add per-span network overhead.
        batch_processor:
          # Maximum number of spans held in the buffer waiting to be exported.
          # At default Apollo Router throughput (~5 spans per request), 2048 spans
          # buffers approximately 400 concurrent requests before back-pressure applies.
          # Increase to 8192 for very high-traffic deployments (>1000 req/s per router pod).
          max_queue_size: 2048

          # How long to wait before sending a batch even if it is not full.
          # 5000ms = export at least every 5 seconds regardless of batch fill level.
          # Lower values (1000ms) reduce trace latency (time from request completion
          # to trace visibility in Jaeger) at the cost of more frequent small exports.
          scheduled_delay: 5000

          # Maximum number of spans in a single export RPC.
          # 512 is a good balance between payload size and export frequency.
          # If spans are frequently dropped (watch the OTel Collector metrics for
          # dropped_spans), increasing this value reduces the number of export RPCs.
          max_export_batch_size: 512

          # Maximum time in milliseconds to wait for an export RPC to complete.
          # If the Collector is slow or unreachable, exports are aborted after this
          # timeout and spans are dropped. 30s is generous; reduce to 10s if you want
          # faster back-pressure propagation.
          max_export_timeout: 30000

  # ==========================================================================
  # SECTION 2: Tracing — Custom Span Attributes
  # ==========================================================================
  instrumentation:
    spans:
      # Attributes added to the root router span (one per GraphQL request).
      router:
        attributes:
          # The GraphQL operation name as declared in the query document.
          # Example: "GetUserProfile", "SearchProducts"
          # This is the most useful attribute for filtering traces in Jaeger:
          # "show me all traces for the GetUserProfile operation".
          graphql.operation.name:
            # The router extracts the operation name from the parsed query.
            # Using the built-in selector avoids the overhead of string parsing
            # in a Rhai script.
            operation_name: true

          # The operation type: "query", "mutation", or "subscription".
          # Useful for filtering: mutations are typically more sensitive to latency
          # than queries, and subscriptions have a completely different performance profile.
          graphql.operation.type:
            operation_kind: true

          # The normalized operation hash. Apollo Router computes a hash of the
          # operation document after normalization (variable values removed).
          # This hash is stable across equivalent queries and can be used to
          # correlate traces with Apollo Studio operation statistics.
          graphql.operation.hash:
            operation_hash: true

          # HTTP request method. Included for completeness and for dashboards
          # that filter by HTTP method (distinguishing GET vs POST queries).
          http.method:
            request_header: ":method"

          # Client name from the x-client-name header.
          # Allows filtering traces by which client application made the request.
          # Must be set by the client application in all GraphQL requests.
          client.name:
            request_header: "x-client-name"

          # Client version from the x-client-version header.
          # Useful for correlating errors with specific app releases.
          client.version:
            request_header: "x-client-version"

      # Attributes added to subgraph spans (one per subgraph call within a request).
      subgraph:
        attributes:
          # The name of the subgraph being called.
          # This is the most important subgraph attribute — it allows you to see
          # in a trace waterfall which subgraph contributed the most latency.
          subgraph.name: true

          # The GraphQL operation type sent to the subgraph.
          subgraph.graphql.operation.type: true

          # The HTTP response status code from the subgraph.
          # A 200 response can still contain GraphQL errors — subgraph errors
          # are a separate attribute. But 5xx from a subgraph indicates a
          # subgraph infrastructure failure.
          http.status_code:
            response_status: 200

  # ==========================================================================
  # SECTION 3: Trace Context Propagation
  # ==========================================================================
  propagation:
    # W3C Trace Context (traceparent / tracestate headers).
    # This is the IETF standard and the OTel default. All subgraphs that are
    # instrumented with OTel SDKs will automatically join the router's trace
    # as child spans when they receive these headers.
    trace_context: true

    # Baggage propagation. See Section 7 for baggage configuration.
    # Baggage propagates key-value pairs across service boundaries — unlike
    # trace context, baggage values are accessible in application code.
    baggage: true

    # Disable Zipkin B3 and Jaeger propagation formats.
    # Using a single propagation format eliminates format translation overhead
    # and prevents ambiguous span relationship errors in multi-format traces.
    zipkin: false
    jaeger: false

  # ==========================================================================
  # SECTION 4: Metrics — Prometheus Endpoint
  # ==========================================================================
  metrics:
    prometheus:
      # Enable the Prometheus metrics scrape endpoint.
      # Prometheus scrapes this endpoint every 15 seconds (configurable in
      # the Prometheus scrape config).
      enabled: true

      # The path at which Prometheus metrics are exposed.
      # Standard convention is /metrics. Do not change without updating the
      # Prometheus scrape config.
      path: /metrics

      # The port for the metrics endpoint. Using a dedicated port (9090) separate
      # from the GraphQL port (4000) allows firewall rules and Kubernetes NetworkPolicy
      # to restrict metrics access to the monitoring namespace only.
      listen: 0.0.0.0:9090

    # Key metrics emitted by Apollo Router:
    #
    # apollo_router_http_requests_total{status, method, query_analysis_type}
    #   Counter: total HTTP requests handled by the router.
    #   Use rate() to get requests per second.
    #
    # apollo_router_http_request_duration_seconds{status, query_analysis_type}
    #   Histogram: request duration in seconds, with standard OTel buckets.
    #   Use histogram_quantile(0.99, ...) to get P99 latency.
    #
    # apollo_router_cache_hit_count{kind, storage, type}
    #   Counter: query planning cache hits. High hit rate = healthy planning cache.
    #
    # apollo_router_cache_miss_count{kind, storage, type}
    #   Counter: query planning cache misses. Spike = new or diverse operations.
    #
    # apollo_router_query_planning_time_seconds
    #   Histogram: time spent in the query planner. P99 >100ms indicates
    #   schema complexity issues or cache inefficiency.
    #
    # apollo_router_uplink_fetch_duration_seconds
    #   Histogram: time to fetch the supergraph from Hive CDN / GraphOS Uplink.
    #
    # apollo_router_http_requests_in_flight
    #   Gauge: current number of in-flight requests. Use to detect traffic spikes
    #   and tune the router's connection pool sizes.

  # ==========================================================================
  # SECTION 5: Custom Metrics — Instruments
  # ==========================================================================
  # Custom instruments augment the built-in Apollo Router metrics with
  # GraphQL-specific counters and histograms.

  instruments:
    # Count the number of times each GraphQL operation is executed.
    # The operation_name label enables per-operation rate tracking without
    # requiring a separate trace query.
    graphql_operation_execution_count:
      # Counter type: increments by 1 on every completed operation.
      type: counter
      description: "Number of GraphQL operations executed, by operation name and type."
      unit: "{operation}"
      value: 1
      condition:
        # Only count operations that complete successfully (no transport error).
        # HTTP-level errors (4xx, 5xx before reaching the GraphQL layer) are
        # counted separately by apollo_router_http_requests_total.
        not:
          eq:
            - response_status: 500
            - 500
      attributes:
        graphql.operation.name:
          operation_name: true
        graphql.operation.type:
          operation_kind: true
        # Include the response status to distinguish successful operations from
        # operations that completed with GraphQL errors.
        response.graphql_errors:
          response_errors: true

    # Histogram of response sizes by operation.
    # Large responses indicate N+1 patterns or over-fetching.
    # Alert if P99 response size exceeds your client network budget.
    graphql_response_size_bytes:
      type: histogram
      description: "Size of GraphQL response bodies in bytes, by operation."
      unit: "By"
      value:
        response_header: "content-length"
      attributes:
        graphql.operation.name:
          operation_name: true

  # ==========================================================================
  # SECTION 6: Logging
  # ==========================================================================
  logging:
    format:
      # JSON format for structured log ingestion.
      # Loki, CloudWatch Logs, and Datadog all have first-class JSON log parsing.
      # Plain text logs require regex parsing which is fragile and error-prone.
      stdout:
        format: json
        tty_format: text  # Use human-readable format when running with a TTY (local dev)

    # Log level per component.
    # "info" for the router: logs one line per request with operation name, status, duration.
    # "warn" for other components to reduce noise.
    #
    # Use ROUTER_LOG=apollo_router=debug for temporary debugging — never leave
    # debug logging enabled in production (it logs resolver data which may contain PII).
    filter: "${env.ROUTER_LOG:-info}"

    # Sampling rate for request logs.
    # 1.0 = log every request. For >1000 req/s, reduce to 0.1 to log 10% of requests.
    # Errors and traces are always logged regardless of this sampling rate.
    sampling_ratio: "${env.LOG_SAMPLING_RATIO:-1.0}"

    # Fields included in every request log line.
    # These match the span attributes in Section 2 for easy log-to-trace correlation.
    fields:
      trace_id: true
      span_id: true
      operation_name: true
      operation_type: true
      client_name:
        request_header: "x-client-name"

  # ==========================================================================
  # SECTION 7: Baggage Propagation
  # ==========================================================================
  # Baggage propagates key-value pairs through the distributed request context.
  # Unlike trace attributes (which are only visible in the trace backend), baggage
  # values are accessible in application code via the OTel Baggage API.
  # Use baggage for values that need to influence behavior in downstream services,
  # not just for observation.

  # The x-request-id header is injected into baggage so subgraphs can use it
  # for their own logging and correlation without re-reading the HTTP header.
  # This is especially useful for subgraphs that receive queries from the router
  # rather than directly from clients (they don't have access to the original
  # client request headers).
  baggage:
    propagate:
      # Inject x-request-id from the incoming request header into baggage.
      # Subgraphs can extract this from the OTel Baggage context.
      - request_header: "x-request-id"
        key: "request_id"

      # Inject the user's tenant ID if present.
      # This allows subgraphs to log with the tenant ID without needing to
      # parse the Authorization header or call an identity service.
      - request_header: "x-tenant-id"
        key: "tenant_id"
```

---

## Environment Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `OTEL_COLLECTOR_ENDPOINT` | `http://otel-collector.monitoring.svc.cluster.local:4317` | OTel Collector gRPC endpoint |
| `OTEL_COLLECTOR_TOKEN` | — | Bearer token for authenticated Collectors (Grafana Cloud) |
| `ROUTER_LOG` | `info` | Log level filter. Use `apollo_router=debug` for debugging. |
| `LOG_SAMPLING_RATIO` | `1.0` | Fraction of request log lines to emit (0.0–1.0) |

---

## Kubernetes ConfigMap

Mount `router.yaml` as a Kubernetes ConfigMap to deploy the router with telemetry configuration:

```yaml
# kubernetes/router-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: apollo-router-config
  namespace: graphql
data:
  router.yaml: |
    supergraph:
      listen: 0.0.0.0:4000
    # ... paste the full router.yaml content here, or use Helm values to render it

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: apollo-router
  namespace: graphql
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: router
          image: ghcr.io/apollographql/router:v1.52.0
          ports:
            - containerPort: 4000  # GraphQL
              name: graphql
            - containerPort: 9090  # Prometheus metrics
              name: metrics
          env:
            - name: OTEL_COLLECTOR_ENDPOINT
              value: "http://otel-collector.monitoring.svc.cluster.local:4317"
            - name: ROUTER_LOG
              value: "info"
          volumeMounts:
            - name: router-config
              mountPath: /dist/config
      volumes:
        - name: router-config
          configMap:
            name: apollo-router-config
```

**Prometheus ServiceMonitor for automatic scraping:**

```yaml
# kubernetes/router-service-monitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: apollo-router
  namespace: monitoring
  labels:
    # Must match your Prometheus Operator's serviceMonitorSelector.
    app: apollo-router
spec:
  namespaceSelector:
    matchNames:
      - graphql
  selector:
    matchLabels:
      app: apollo-router
  endpoints:
    - port: metrics     # Must match the named port in the Service
      path: /metrics
      interval: 15s     # Scrape every 15 seconds
      scrapeTimeout: 10s
```

---

## Related Documentation

- `../../docs/14-observability/` — Observability strategy and SLO definitions.
- `otel-collector-config.md` — OTel Collector configuration for receiving traces from the router.
- `grafana-dashboards.md` — PromQL queries and alert rules using the metrics defined in this file.
- `../../examples/09-hive/hive-router-config.md` — Hive usage reporting, which shares the OTLP
  pipeline configured in Section 4 of this file.

---

## Key Design Decisions

**Batch processor tuning**
The default `scheduled_delay` of 5000ms (5 seconds) is deliberately conservative. A lower value
(500ms) would reduce trace latency (time from request to Jaeger visibility) but would cause more
frequent, smaller export RPCs to the Collector. At high throughput, frequent small exports can
overload the Collector's gRPC connection pool. The 5-second delay is acceptable because trace
visibility latency is not an SLO metric — traces are used for post-hoc investigation, not for
real-time alerting.

**Separate metrics port (9090) from GraphQL port (4000)**
Separating the metrics endpoint onto a distinct port allows Kubernetes NetworkPolicy to restrict
metrics access to the monitoring namespace (Prometheus) while allowing the GraphQL port to be
exposed to the ingress. This prevents an unauthenticated external user from reaching `/metrics`,
which exposes operational information (operation names, error rates) that could be used for
reconnaissance.

**operation_name as a span attribute, not a trace name**
The GraphQL operation name is added as a span attribute rather than used as the span name. The
span name is set to the HTTP method and route (`POST /graphql`) to follow OTel HTTP semantic
conventions. Using the operation name as the span name would create high-cardinality span names,
which causes performance problems in some trace backends (Jaeger's span name index grows
unboundedly with unique names).

**Baggage for x-request-id, not trace ID**
The `x-request-id` is propagated via baggage rather than using the OTel trace ID directly. This
is because external systems (API gateways, WAFs, CDNs) inject `x-request-id` before the request
reaches the router, so it predates the trace and can be used to correlate trace data with
gateway-level access logs. The OTel trace ID is generated by the router at ingress and is not
present in upstream system logs.
