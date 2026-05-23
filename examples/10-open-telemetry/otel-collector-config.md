# OpenTelemetry Collector Configuration — GraphQL Platform Reference

<!-- Companion docs: ../../docs/14-observability/ -->

This document provides the complete OpenTelemetry Collector configuration for a GraphQL Federation
platform. It covers all receivers, processors, exporters, and pipeline definitions, along with the
Kubernetes Deployment manifest and a tail-based sampling configuration for cost-effective trace
storage.

---

## Complete otel-collector-config.yaml

```yaml
# otel-collector-config.yaml
# OpenTelemetry Collector configuration for a GraphQL Federation observability pipeline.
# Uses otelcol-contrib (the contrib distribution) which includes all receivers,
# processors, and exporters referenced in this config.
# Version: requires otelcol-contrib 0.95+

# ---------------------------------------------------------------------------
# RECEIVERS
# ---------------------------------------------------------------------------
# Receivers define how the Collector ingests telemetry data.
# The Collector acts as a pull/push aggregation point — all services send to it
# rather than directly to backends, enabling centralized processing and fan-out.
receivers:

  # OTLP receiver: the primary receiver for all Apollo Router and subgraph telemetry.
  # Apollo Router uses the gRPC endpoint; some language SDKs (Python, Ruby) may
  # prefer the HTTP endpoint.
  otlp:
    protocols:
      grpc:
        # gRPC OTLP endpoint. Port 4317 is the OTel standard for gRPC OTLP.
        # Use 0.0.0.0 binding for Kubernetes pod networking.
        endpoint: 0.0.0.0:4317

        # Maximum message size in bytes. gRPC has a 4MB default; at high span rates
        # a single batch from the router can exceed this. 128MB is generous but safe.
        max_recv_msg_size_mib: 128

        # Keepalive settings prevent long-running gRPC streams from timing out
        # behind Kubernetes Services (which have a 15-minute idle TCP timeout).
        keepalive:
          server_parameters:
            # Send a PING every 30 seconds on idle connections.
            time: 30s
            # If no response to PING within 5 seconds, close the connection.
            timeout: 5s

      http:
        # HTTP OTLP endpoint. Port 4318 is the OTel standard for HTTP OTLP.
        # The path /v1/traces, /v1/metrics, and /v1/logs are standard sub-paths.
        endpoint: 0.0.0.0:4318

  # Prometheus self-scrape receiver: the Collector scrapes its own /metrics endpoint
  # and sends the data through the metrics pipeline. This allows monitoring the
  # Collector's health (dropped spans, queue depths, export errors) from the same
  # Grafana dashboard used for the GraphQL platform.
  prometheus:
    config:
      scrape_configs:
        - job_name: "otel-collector"
          # Scrape the Collector's own Prometheus metrics.
          scrape_interval: 30s
          static_configs:
            - targets: ["localhost:8888"]

# ---------------------------------------------------------------------------
# PROCESSORS
# ---------------------------------------------------------------------------
# Processors transform, filter, and enrich telemetry data in the pipeline.
# Processors are applied in the order listed in each pipeline's processors array.
processors:

  # Batch processor: accumulates spans/metrics/logs before forwarding to exporters.
  # Critical for efficiency — without batching, each span would trigger a separate
  # network call to the backend.
  batch:
    # Wait up to 1 second before flushing a partial batch.
    # Lower values reduce export latency; higher values improve compression efficiency.
    # 1 second is a good balance for a GraphQL gateway that handles bursty traffic.
    timeout: 1s

    # Maximum number of spans (or metric points or log records) in a single batch.
    # 1024 is a good default; increase to 2048 for very high throughput pipelines.
    # If this size is reached before the timeout, the batch is flushed immediately.
    send_batch_size: 1024

    # Hard maximum for batch size. Batches will not exceed this even if more data
    # is queued. Prevents oversized payloads that could be rejected by backends.
    send_batch_max_size: 2048

  # Memory limiter: prevents the Collector from consuming unlimited memory during
  # traffic spikes, which would cause OOM kills and telemetry data loss.
  memory_limiter:
    # Check memory usage every 1 second.
    check_interval: 1s

    # Hard limit: when the Collector's memory usage reaches this percentage of
    # the container's memory limit, it starts refusing new data (back-pressure).
    # Set to 75% to leave headroom before the container is OOM-killed.
    # For a container with a 1Gi memory limit, this triggers at ~768Mi.
    limit_percentage: 75

    # Spike limit: the Collector applies soft back-pressure when memory usage
    # exceeds this percentage, shedding excess load gracefully before hitting
    # the hard limit. Set to 20% below the hard limit.
    spike_limit_percentage: 55

  # Resource detection processor: automatically detects Kubernetes metadata from
  # the pod's environment (via downward API) and attaches it to all telemetry.
  # This eliminates manual attribute configuration in each subgraph service.
  resourcedetection:
    # Use the environment detector, which reads attributes from OTel standard
    # environment variables (OTEL_RESOURCE_ATTRIBUTES).
    # The k8snode detector reads node metadata from the Kubernetes API.
    detectors: [env, k8snode]
    timeout: 5s
    override: false  # Do not override attributes already set by the SDK

  # Resource processor: add static and dynamic attributes to all telemetry.
  # Used for attributes that cannot be auto-detected (environment name, cluster name).
  resource:
    attributes:
      # The deployment environment (production, staging, development).
      # Injected from a Kubernetes ConfigMap or env var at deploy time.
      - key: deployment.environment
        value: "${env.DEPLOYMENT_ENVIRONMENT:-production}"
        action: upsert

      # Kubernetes cluster name — useful when sending data from multiple clusters
      # to the same Grafana instance.
      - key: k8s.cluster.name
        value: "${env.K8S_CLUSTER_NAME:-prod-cluster}"
        action: upsert

      # The GraphQL platform name — distinguishes GraphQL telemetry from other
      # services in a shared observability backend.
      - key: graphql.platform
        value: "apollo-federation-v2"
        action: upsert

  # Filter processor: drop telemetry that is not useful in the backend.
  # Dropping data at the Collector is cheaper than storing and querying it.
  filter:
    error_mode: ignore  # Log filter errors but do not drop the entire span

    traces:
      span:
        # Drop health check spans. The router's /health and /ready endpoints are
        # polled by Kubernetes every 5 seconds, generating ~1M low-value spans per day.
        # These spans contain no useful information and inflate trace storage costs.
        - 'attributes["http.route"] == "/health"'
        - 'attributes["http.route"] == "/ready"'
        - 'attributes["http.route"] == "/.well-known/apollo/server-health"'
        # Drop introspection queries. Introspection is used by developer tooling,
        # not real user traffic. Introspection spans can dominate trace counts in
        # development-heavy environments.
        - 'attributes["graphql.operation.name"] == "IntrospectionQuery"'

    metrics:
      metric:
        # Drop high-cardinality metrics with operation_name labels if the operation
        # count per time window exceeds the cardinality budget.
        # (Add specific metric exclusions here if cardinality becomes an issue.)

    logs:
      log_record:
        # Drop DEBUG-level logs from subgraphs. These are verbose and are not
        # needed in production. Enable temporarily for debugging by removing this filter.
        - 'severity_number < SEVERITY_NUMBER_INFO'

  # Attributes processor: transform attribute values for normalization.
  attributes:
    actions:
      # Normalize empty operation names to a sentinel value.
      # The router emits an empty string for anonymous operations; Jaeger and
      # Prometheus handle empty label values poorly.
      - key: graphql.operation.name
        value: "<anonymous>"
        action: insert  # Only inserts if the key is absent or empty

  # Tail-based sampling processor: make sampling decisions after all spans in a
  # trace have arrived (or after a timeout). This is more powerful than head-based
  # sampling because it can inspect error flags and latency before deciding to sample.
  # See Section 6 for full tail sampling configuration.
  tail_sampling:
    # Wait this long after the first span arrives before making a sampling decision.
    # Set to the P99 latency of a complete trace (router + slowest subgraph) plus
    # a margin for network jitter. If traces take up to 2 seconds end-to-end,
    # a 5-second decision wait covers the 99.9th percentile.
    decision_wait: 5s

    # Maximum number of traces held in memory awaiting a sampling decision.
    # At 1000 req/s with a 5s decision window, this needs to hold 5000 traces.
    # Each trace uses ~4KB in memory; 10000 traces = ~40MB.
    num_traces: 10000

    # Expected number of new spans per second per trace. Used for internal
    # optimization — does not affect the sampling decision itself.
    expected_new_traces_per_sec: 100

    policies:
      # Policy 1: Always sample traces that contain any span with an error status.
      # These are the most valuable traces — they represent actual failures.
      # error=true covers both HTTP 5xx and GraphQL partial errors.
      - name: sample-errors
        type: status_code
        status_code:
          status_codes: [ERROR]

      # Policy 2: Always sample slow traces (end-to-end latency > 500ms).
      # Slow traces are used for latency regression investigation.
      # The threshold should be set to ~2x your P99 latency SLO.
      # If your P99 SLO is 200ms, sample all traces >400ms.
      - name: sample-slow-requests
        type: latency
        latency:
          # Threshold in milliseconds. 500ms catches the slowest ~1% of requests
          # at a healthy P99 of 200ms.
          threshold_ms: 500

      # Policy 3: Probabilistic sampling for healthy fast requests.
      # Sample 10% of requests that are not errors and not slow.
      # At 1000 req/s, this keeps ~100 traces/s in Jaeger — enough for
      # statistical analysis without overwhelming storage.
      - name: sample-10-percent-healthy
        type: probabilistic
        probabilistic:
          # 0.1 = 10% sampling rate.
          # Increase to 0.5 during an incident to get better trace coverage.
          sampling_percentage: 10

# ---------------------------------------------------------------------------
# EXPORTERS
# ---------------------------------------------------------------------------
# Exporters define where processed telemetry is sent.
exporters:

  # OTLP trace exporter to Jaeger or Grafana Tempo.
  # Both Jaeger (1.35+) and Grafana Tempo accept OTLP natively.
  # Switch between them by changing the endpoint without modifying any other config.
  otlp/traces:
    endpoint: "${env.JAEGER_OTLP_ENDPOINT:-http://jaeger-collector.monitoring.svc.cluster.local:4317}"
    tls:
      # Enable TLS for production-external Jaeger instances.
      # For cluster-internal Jaeger, TLS is optional.
      insecure: "${env.JAEGER_TLS_INSECURE:-true}"

    # Retry configuration: if the trace backend is temporarily unavailable,
    # the exporter retries with exponential backoff. Retries are bounded by
    # the memory_limiter configured above.
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      randomization_factor: 0.5  # Randomize retry timing to prevent thundering herd
      multiplier: 1.5            # Exponential backoff factor
      max_interval: 30s
      max_elapsed_time: 300s     # Give up after 5 minutes of retries

  # Prometheus remote_write exporter: sends metrics to Prometheus or Thanos.
  # Remote write is preferred over pulling from the Collector's /metrics endpoint
  # because it pushes data reliably even when the Collector restarts.
  prometheusremotewrite:
    endpoint: "${env.PROMETHEUS_REMOTE_WRITE_ENDPOINT:-http://prometheus.monitoring.svc.cluster.local:9090/api/v1/write}"
    tls:
      insecure: "${env.PROMETHEUS_TLS_INSECURE:-true}"

    # Add cluster and environment labels to all metrics.
    # These labels are critical for multi-cluster Prometheus federation where
    # metrics from multiple clusters are stored in a shared Thanos instance.
    external_labels:
      cluster: "${env.K8S_CLUSTER_NAME:-prod-cluster}"
      environment: "${env.DEPLOYMENT_ENVIRONMENT:-production}"

    # Write ahead log (WAL) for metrics: buffer metrics locally if the remote
    # write endpoint is temporarily unavailable. Prevents metric gaps during
    # Prometheus restarts or brief network interruptions.
    wal:
      directory: /var/otelcol/wal
      buffer_duration: 5m   # Keep up to 5 minutes of metrics in the WAL
      truncate_frequency: 1m

  # Loki HTTP exporter for structured logs.
  loki:
    endpoint: "${env.LOKI_ENDPOINT:-http://loki.monitoring.svc.cluster.local:3100}/loki/api/v1/push"
    tls:
      insecure: "${env.LOKI_TLS_INSECURE:-true}"

    # Loki labels are indexed and searchable; all other log fields are stored as
    # unindexed metadata. Choose labels carefully — high-cardinality labels
    # (like user ID or operation hash) will cause Loki performance problems.
    # Good labels: service_name, environment, namespace.
    # Bad labels: user_id, request_id, operation_name (too many unique values).
    default_labels_enabled:
      exporter: false  # Do not add an "exporter" label to every log line
      job: true        # Add "job" label derived from service.name attribute
      instance: false  # Do not add "instance" label (too high cardinality)
      level: true      # Add "level" label (info, warn, error)

    headers:
      # Loki multi-tenancy: send logs to a specific Loki tenant.
      # Remove if not using Loki multi-tenancy.
      X-Scope-OrgID: "${env.LOKI_TENANT_ID:-graphql-platform}"

  # Debug exporter: logs telemetry to the Collector's stdout.
  # Use only for troubleshooting — never enable in production.
  # Enable by adding "debug" to a pipeline's exporters list temporarily.
  debug:
    verbosity: detailed
    sampling_initial: 5       # Log first 5 occurrences of each event type
    sampling_thereafter: 100  # Then log every 100th occurrence

# ---------------------------------------------------------------------------
# EXTENSIONS
# ---------------------------------------------------------------------------
extensions:
  # Health check endpoint for Kubernetes liveness/readiness probes.
  health_check:
    endpoint: 0.0.0.0:13133

  # pprof: Go profiling endpoint for Collector performance analysis.
  # Expose only inside the cluster, never to the internet.
  pprof:
    endpoint: 0.0.0.0:1777

  # zpages: debug pages for the Collector's internal pipeline state.
  # Useful for diagnosing dropped spans and exporter failures during incidents.
  zpages:
    endpoint: 0.0.0.0:55679

# ---------------------------------------------------------------------------
# PIPELINES
# ---------------------------------------------------------------------------
# Pipelines connect receivers to processors to exporters.
# Each signal type (traces, metrics, logs) has its own pipeline.
service:

  extensions:
    - health_check
    - pprof
    - zpages

  pipelines:

    # Traces pipeline: receives OTLP, applies tail sampling, exports to Jaeger/Tempo.
    traces:
      receivers:
        - otlp
      processors:
        # Order matters. memory_limiter must be first to apply back-pressure before
        # other processors consume memory. batch must be last (just before export)
        # for efficiency. Sampling goes after filtering to avoid sampling already-
        # filtered-out spans.
        - memory_limiter
        - filter
        - resourcedetection
        - resource
        - attributes
        - tail_sampling
        - batch
      exporters:
        - otlp/traces

    # Metrics pipeline: receives OTLP metrics (from the router) and scraped
    # Collector self-metrics, then exports to Prometheus.
    metrics:
      receivers:
        - otlp
        - prometheus  # Self-scrape of the Collector's own metrics
      processors:
        - memory_limiter
        - resourcedetection
        - resource
        - batch
      exporters:
        - prometheusremotewrite

    # Logs pipeline: receives OTLP logs from the router and subgraphs,
    # filters verbose logs, and exports to Loki.
    logs:
      receivers:
        - otlp
      processors:
        - memory_limiter
        - filter   # Drop DEBUG logs before they reach the batch buffer
        - resourcedetection
        - resource
        - attributes
        - batch
      exporters:
        - loki
```

---

## 5. Kubernetes Deployment

**DaemonSet vs Deployment for the Collector**

For the Apollo Router workload, a Deployment (not a DaemonSet) is the correct architecture for
the OTel Collector.

A DaemonSet runs one Collector pod per node. This makes sense for log collection (where each
node's log files need to be collected locally) or for sidecar-heavy architectures where every
pod on a node sends traces to the node-local Collector.

For Apollo Router, which runs as a small number of large pods (typically 3-10 router replicas
across a subset of nodes), a DaemonSet would provision collector pods on every node in the
cluster — including nodes that receive no router traffic. This wastes resources and complicates
Prometheus service discovery.

A Deployment with 2 replicas provides:
- High availability (2 Collector pods, each an independent target for the router's OTLP export).
- Efficient resource use (Collector only runs where it is needed).
- Simple horizontal scaling: add replicas as traffic grows.

**The router is configured to send OTLP to the Collector Service (load-balanced across all
Collector pods), not to a specific pod IP. This ensures that Collector pod restarts and scaling
events are transparent to the router.**

```yaml
# kubernetes/otel-collector.yaml
---
# ConfigMap: the otel-collector-config.yaml content from above.
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: monitoring
data:
  otel-collector-config.yaml: |
    # (paste full otel-collector-config.yaml content here, or use Helm to render it)

---
# Deployment: 2 replicas for HA.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: monitoring
  labels:
    app: otel-collector
spec:
  replicas: 2

  # Pod anti-affinity: schedule the two Collector replicas on different nodes.
  # If a node fails, one Collector replica survives and the router continues
  # sending traces (to the surviving replica).
  template:
    metadata:
      labels:
        app: otel-collector
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: otel-collector
              topologyKey: kubernetes.io/hostname

      containers:
        - name: otel-collector
          # Use the contrib distribution: includes all receivers, processors, and
          # exporters referenced in the config. The core distribution lacks the
          # Loki exporter, k8snode resource detector, and tail_sampling processor.
          image: otel/opentelemetry-collector-contrib:0.95.0

          command:
            - /otelcol-contrib
            - --config
            - /etc/otelcol/otel-collector-config.yaml

          ports:
            - containerPort: 4317
              name: otlp-grpc
            - containerPort: 4318
              name: otlp-http
            - containerPort: 8888
              name: prometheus
            - containerPort: 13133
              name: health-check

          resources:
            requests:
              # 0.5 CPU handles ~5000 spans/second with standard processors.
              # At peak GraphQL traffic, the Collector is CPU-bound on span processing.
              cpu: 500m
              # 512Mi handles the tail_sampling buffer (10000 traces * ~4KB per trace
              # = ~40MB) plus processor overhead. The memory_limiter prevents OOM.
              memory: 512Mi
            limits:
              cpu: 2000m
              # The memory_limiter kicks in at 75% of this limit (384Mi).
              # The container limit provides a safety margin above the soft limit.
              memory: 1Gi

          env:
            - name: DEPLOYMENT_ENVIRONMENT
              valueFrom:
                configMapKeyRef:
                  name: platform-config
                  key: environment
            - name: K8S_CLUSTER_NAME
              valueFrom:
                configMapKeyRef:
                  name: platform-config
                  key: cluster-name
            - name: JAEGER_OTLP_ENDPOINT
              value: "http://jaeger-collector.monitoring.svc.cluster.local:4317"
            - name: PROMETHEUS_REMOTE_WRITE_ENDPOINT
              value: "http://prometheus.monitoring.svc.cluster.local:9090/api/v1/write"
            - name: LOKI_ENDPOINT
              value: "http://loki.monitoring.svc.cluster.local:3100"

          livenessProbe:
            httpGet:
              path: /
              port: 13133
            initialDelaySeconds: 10
            periodSeconds: 30

          readinessProbe:
            httpGet:
              path: /
              port: 13133
            initialDelaySeconds: 5
            periodSeconds: 10

          volumeMounts:
            - name: config
              mountPath: /etc/otelcol
            - name: wal
              mountPath: /var/otelcol/wal

      volumes:
        - name: config
          configMap:
            name: otel-collector-config
        - name: wal
          # EmptyDir for the Prometheus WAL. This is ephemeral — if the pod
          # restarts, up to `buffer_duration` (5 minutes) of metrics may be lost.
          # For production, use a PersistentVolumeClaim here.
          emptyDir: {}

---
# Service: exposes the Collector's OTLP ports within the cluster.
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: monitoring
spec:
  selector:
    app: otel-collector
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
    - name: otlp-http
      port: 4318
      targetPort: 4318
    - name: prometheus
      port: 8888
      targetPort: 8888
```

---

## Related Documentation

- `../../docs/14-observability/` — Observability strategy, SLOs, and alerting policy.
- `router-telemetry-config.md` — Apollo Router configuration that sends OTLP to this Collector.
- `grafana-dashboards.md` — Grafana dashboards and Prometheus alerts for the metrics flowing
  through this pipeline.

---

## Key Design Decisions

**Tail-based sampling over head-based sampling**
Head-based sampling makes the sampling decision at the start of the request, before any outcome
is known. A 10% head-based sample would randomly discard 90% of traces, including all error
traces and slow traces. Tail-based sampling waits for the full trace to arrive (up to 5 seconds),
then applies policies: always keep errors, always keep slow traces (>500ms), sample 10% of the
rest. This produces a trace store where errors and latency outliers have 100% representation,
which is exactly what engineers need during incident investigation.

**Separate pipelines for traces, metrics, and logs**
Using separate pipelines allows independent scaling and configuration of each signal type. The
traces pipeline uses tail sampling (memory-intensive); the metrics pipeline does not. The logs
pipeline applies aggressive filtering (drop DEBUG). If you merged all signals into one pipeline,
you could not apply signal-specific processors.

**WAL for Prometheus remote write**
The write-ahead log ensures that metrics are not lost during brief Prometheus unavailability
(rolling restarts, pod evictions). Without the WAL, a 30-second Prometheus restart would create
a gap in all metric time series, which can trigger spurious alert firings if the alerting rule
evaluates during the gap.
