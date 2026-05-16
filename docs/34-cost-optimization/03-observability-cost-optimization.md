# 03 — Observability Cost Optimization for GraphQL

> **Purpose**
> Observability cost analysis and reduction strategies for a federated GraphQL platform at scale. Covers trace volume math at 10k RPS, tail-based sampling configuration, metric cardinality management, log volume reduction, Prometheus retention strategy, Grafana Mimir vs Prometheus cost comparison, and Tempo object storage backends. Written for platform engineers and SREs who own the observability stack budget.

---

## Cost Drivers at 10,000 RPS

The observability stack for a GraphQL platform at scale generates substantially more data than equivalent REST services, for three reasons:

1. **Per-operation trace depth.** A federated query fans out to N subgraphs, each with its own resolver spans and DataLoader spans. A 5-subgraph query generates 20–50 spans per trace vs 3–5 spans for a REST request.

2. **High cardinality from GraphQL operation names.** An API with 200 unique named operations × 50 client versions = 10,000 potential time series per metric if `operation_name` and `client_version` are both label dimensions.

3. **Error detail in the response body.** GraphQL errors are in `errors[]`, not in HTTP status codes. Capturing the full error response body in logs — including the `extensions.query` field — multiplies log volume 5–10x compared to a REST API.

---

## Trace Volume Math and Tail-Based Sampling

### 100% Trace Sampling Cost

```
At 10,000 RPS:
  Traces per second: 10,000
  Spans per trace (average, federated query): 25
  Total spans per second: 250,000
  Total spans per day: 250,000 × 86,400 = 21.6 billion spans

  Average span size (OTel JSON): 400 bytes
  Daily trace data volume: 21.6B × 400B = 8.64 TB/day

  Grafana Tempo storage (S3 backend): $0.023/GB-month
  Monthly trace storage: 8.64TB × 30 = 259.2 TB
  Monthly cost: 259,200 GB × $0.023 = $5,962/month at 100% sampling
```

### Tail-Based Sampling Cost Reduction

Tail-based sampling retains 100% of traces that contain errors or are outliers (high latency), and samples only a fraction of healthy traces:

```
Sampling configuration:
  Error traces: 100% retained
  Slow traces (> 2x p99 baseline): 100% retained
  Healthy traces: 1% sampled

At 10,000 RPS with 0.1% error rate:
  Error traces/second:   10,000 × 0.001 = 10
  Slow traces/second:    10,000 × 0.005 = 50  (assume 0.5% are outlier-slow)
  Healthy traces sampled: 10,000 × 0.994 × 0.01 = 99

  Total traces retained/second: 10 + 50 + 99 = 159 (vs 10,000)
  Sampling rate: 1.59%

  Monthly trace data volume: 259.2TB × 0.0159 = 4.12 TB
  Monthly cost: 4,120 GB × $0.023 = $94.76/month

Cost reduction: $5,962 → $94.76 = 98.4% reduction
Monthly saving: $5,867/month ($70,404/year)
```

### Tail-Based Sampling Configuration

```yaml
# otelcol-config.yaml — OpenTelemetry Collector with tail-based sampling
processors:
  tail_sampling:
    # Wait 10 seconds to see the full trace before making sampling decision
    decision_wait: 10s
    num_traces: 50000        # Max traces in memory waiting for decision
    expected_new_traces_per_sec: 10000

    policies:
      # Policy 1: Always keep error traces
      - name: error-traces
        type: status_code
        status_code:
          status_codes: [ERROR]

      # Policy 2: Always keep high-latency traces (> 2000ms)
      - name: slow-traces
        type: latency
        latency:
          threshold_ms: 2000

      # Policy 3: Always keep traces from specific clients (mobile, priority partners)
      - name: priority-clients
        type: string_attribute
        string_attribute:
          key: graphql.client.name
          values: ["ios-app", "android-app", "partner-api"]

      # Policy 4: Sample 1% of all other healthy traces
      - name: healthy-sample
        type: probabilistic
        probabilistic:
          sampling_percentage: 1

      # Policy 5: Composite — combine above policies with AND/OR logic
      # (This policy applies to traces that don't match policies 1-3)
      - name: default-low-volume
        type: composite
        composite:
          max_total_spans_per_second: 200    # Hard limit on ingested spans/second
          policy_order: [error-traces, slow-traces, priority-clients, healthy-sample]
          rate_allocation:
            - policy: error-traces
              percent: 60      # 60% of capacity for errors
            - policy: slow-traces
              percent: 25      # 25% for slow traces
            - policy: priority-clients
              percent: 10      # 10% for priority clients
            - policy: healthy-sample
              percent: 5       # 5% for healthy traces

exporters:
  otlp/tempo:
    endpoint: tempo.monitoring.svc.cluster.local:4317
    tls:
      insecure: true
```

---

## Metric Cardinality Management

### The Cardinality Explosion Problem

Naive metric labeling in a GraphQL platform creates exponential cardinality:

```
Labels: operation_name × client_id × client_version × field_path × subgraph_name

Dimensions:
  operation_name: 200 unique operations
  client_id: 50 client applications
  client_version: 10 versions in use simultaneously
  field_path: 500 field paths (type.field combinations)
  subgraph_name: 10 subgraphs

Total series if all labels used on one metric:
  200 × 50 × 10 × 500 × 10 = 500,000,000 active series

At Grafana Cloud pricing ($8/month per 1000 active series):
  500,000,000 / 1,000 × $8 = $4,000,000/month — obviously unacceptable
```

### Label Reduction Strategy

Apply these rules to every metric:

```yaml
# 1. Never combine high-cardinality labels on the same metric
# BAD: all four labels on one metric
apollo_router_graphql_request_duration_seconds{operation_name="GetProductPage",
  client_id="web-app", client_version="3.2.1", field_path="Product.price"}

# GOOD: separate metrics with controlled cardinality
# Metric 1: latency by operation (200 series)
apollo_router_graphql_request_duration_seconds{operation_name="GetProductPage"}

# Metric 2: latency by client (50 series)
apollo_router_graphql_request_duration_seconds{client_name="web-app"}

# Metric 3: latency by subgraph (10 series)
apollo_router_subgraph_request_duration_seconds{subgraph_name="products"}
```

```yaml
# prometheus.yml — relabeling to drop high-cardinality labels before storage
scrape_configs:
  - job_name: apollo-router
    static_configs:
      - targets: ['apollo-router.graphql-platform.svc:9090']

    metric_relabel_configs:
      # Drop the field_path label entirely — use recording rules for aggregations instead
      - source_labels: [field_path]
        target_label: field_path
        replacement: ''

      # Normalize client_version to major.minor only (drops patch version cardinality)
      - source_labels: [client_version]
        regex: '(\d+\.\d+)\.\d+'
        target_label: client_version
        replacement: '$1'

      # Drop unknown/malformed operation names (prevent cardinality from test tools)
      - source_labels: [operation_name]
        regex: '^$|^IntrospectionQuery$|^__ApolloGetServiceDefinition__$'
        action: drop
```

### Recording Rules Instead of High-Cardinality Raw Metrics

```yaml
# rules/graphql-cardinality-reduction.yaml
groups:
  - name: graphql_cardinality_reduction
    interval: 1m
    rules:
      # Pre-aggregate: error rate per subgraph (10 series vs 200×50 = 10,000)
      - record: job:graphql_subgraph_error_rate:5m
        expr: |
          sum by (subgraph_name) (
            rate(apollo_router_subgraph_request_error_total[5m])
          )
          /
          sum by (subgraph_name) (
            rate(apollo_router_subgraph_requests_total[5m])
          )

      # Pre-aggregate: p99 latency per operation category (not per operation name)
      # Map operations to categories to reduce from 200 → 5 series
      - record: job:graphql_latency_by_category:p99_5m
        expr: |
          histogram_quantile(0.99,
            sum by (le, operation_category) (
              label_replace(
                rate(apollo_router_graphql_request_duration_seconds_bucket[5m]),
                "operation_category",
                "interactive",
                "operation_name",
                "GetProductPage|SearchProducts|GetCart|GetUserProfile"
              )
            )
          )

      # Plan cache hit rate (1 series)
      - record: job:apollo_router_plan_cache_hit_ratio:5m
        expr: |
          sum(rate(apollo_router_cache_hit_count{kind="query planner"}[5m]))
          /
          sum(rate(apollo_router_cache_hit_count{kind="query planner"}[5m])
              + rate(apollo_router_cache_miss_count{kind="query planner"}[5m]))
```

**Cardinality cost comparison:**

| Approach | Active Series | Monthly Cost @ $0.008/series |
|----------|--------------|------------------------------|
| All labels, all metrics | 500,000,000 | $4,000,000 (theoretical) |
| Naive labeling (operation + client) | 10,000 | $80 |
| Recording rules only | 500 | $4 |
| Recommended approach (both) | 2,000 | $16 |

---

## Log Volume Reduction

### GraphQL-Specific Log Filtering Rules

```yaml
# fluent-bit-graphql-filter.yaml — Fluent Bit log filtering for GraphQL
[FILTER]
    Name          grep
    Match         apollo-router.*
    Exclude       log_level DEBUG      # No debug logs in production

[FILTER]
    Name          grep
    Match         apollo-router.*
    # Drop successful request logs (info level, status 200, no errors)
    # Only retain: warn, error, and request logs with errors[] present
    Exclude       log   ^.*"status":200.*"errors":\[\].*$

[FILTER]
    Name          lua
    Match         apollo-router.*
    script        /etc/fluent-bit/graphql-sanitize.lua
    call          sanitize_graphql_log

# graphql-sanitize.lua — remove query documents from logs (major volume reduction)
function sanitize_graphql_log(tag, timestamp, record)
    -- Remove the full query document from request logs
    -- Query documents can be 1-10KB each and are redundant with operation names
    if record["body"] ~= nil then
        local body = record["body"]
        -- Remove the "query" field from logged request bodies
        body = body:gsub('"query"%s*:%s*"[^"]*"', '"query":"<redacted>"')
        record["body"] = body
    end
    return 1, timestamp, record
end
```

**Log volume reduction impact:**

```
Without filtering:
  Router logs at 10,000 RPS: ~1KB per request log entry
  Daily volume: 10,000 × 86,400 × 1KB = 864GB/day
  Monthly: 25.9TB → at Loki pricing ($0.50/GB ingest) = $12,950/month

With filtering (retain only warn+ and error logs, ~2% of traffic):
  Daily volume: 864GB × 0.02 = 17.3GB/day
  Monthly: 518GB → $259/month
  Monthly saving: $12,691/month

Rule: Never log the GraphQL query document in production.
Log operation_name (a string like "GetProductPage") instead.
```

---

## Prometheus Retention and Storage Strategy

### Tiered Retention

```yaml
# prometheus.yml — storage retention configuration
global:
  scrape_interval: 15s
  evaluation_interval: 15s

storage:
  tsdb:
    retention.time: 30d      # Raw metrics: 30 days
    retention.size: 500GB    # Hard limit on disk usage

# Recording rules aggregates are stored separately via Thanos/Mimir
# and can be retained for 1 year at much lower cost
```

**Cost of raw metrics vs recording rules:**

```
Raw metrics (30d retention):
  At 100,000 active series (after cardinality management):
  Storage: 100,000 series × 2 bytes/sample × 4 samples/min × 43,200 min = 34.5 GB
  On SSD (gp2 EBS): 34.5GB × $0.10/GB-month = $3.45/month

Recording rules (1-year retention):
  Recording rules collapse many series into 1
  If 100 rules → 100 aggregate series at 1-year retention
  Storage: 100 series × 2 bytes/sample × 1 sample/min × 525,600 min = 105MB
  On S3 (Thanos/Mimir): 0.1GB × $0.023/GB-month × 12 months = $0.028/year
```

### Grafana Mimir vs Prometheus on SSDs

```
Prometheus on SSD (self-hosted, EBS gp3):
  10M active series (before cardinality management)
  Storage: 10M × 2B × 4/min × 43,200min = 3.45TB/month
  EBS cost: 3,450 GB × $0.08/GB-month = $276/month (gp3)
  + EC2 for Prometheus server: r5.4xlarge at $1.008/hour = $726/month
  Total: $1,002/month

Grafana Mimir (managed, object storage backend):
  At 10M series: contact sales
  Self-hosted Mimir on object storage (S3):
  S3: 3.45TB × $0.023/GB-month = $79.35/month
  Mimir pods: 6 × m5.xlarge at $0.192/hour = $830/month
  Total: $909/month
  
  At 100M series: S3 = $793/month, pods = similar → total ~$1,600/month
  vs Prometheus on SSD at 100M series: would need much more EBS → $2,700+/month

Break-even: Mimir object storage backend becomes cheaper than Prometheus on SSD
above approximately 50M active series.
```

---

## Tempo Object Storage Backend

```yaml
# tempo-config.yaml — use S3 as the backend for distributed trace storage
storage:
  trace:
    backend: s3
    s3:
      bucket: graphql-platform-traces
      region: us-east-1
      # IAM role for pod-level access (no credentials in config)
      # Use IRSA (IAM Roles for Service Accounts) in EKS

    # Bloom filters for efficient trace lookup by attribute
    # Reduces S3 GET requests when searching for a specific trace
    bloom_filter:
      false_positive_rate: 0.01
      shard_size_bytes: 100000

    # Cache frequently-accessed recent traces in local SSD
    # Prevents S3 GET costs for traces < 24h old (most queries)
    cache:
      backend: redis
      redis:
        endpoint: redis.monitoring.svc.cluster.local:6379
        timeout: 500ms
```

**S3 vs in-memory/SSD for trace storage:**

```
At 159 traces/second after tail-based sampling:
  Spans per second: 159 × 25 = 3,975
  Average span size: 400 bytes
  Daily trace data: 3,975 × 86,400 × 400B = 137.5GB/day
  Monthly: 4.1TB

  In-memory (Redis Cluster, 3-node r6g.2xlarge):
  Storage capacity: 3 × 52GB = 156GB ← only 38 hours of traces
  Cost: 3 × $0.655/hour × 720 = $1,414/month

  EKS local SSD (NVMe on m5d instances):
  400GB NVMe per m5d.xlarge at $0.226/hour
  3 nodes × 400GB = 1.2TB ← ~8 days of traces
  Cost: 3 × $0.226/hour × 720 = $488/month

  S3 (with local SSD cache for recent 24h):
  S3: 4.1TB × $0.023/GB-month = $94.3/month
  + 3 × m5d.xlarge for Tempo pods with local cache = $488/month
  Total: $582/month
  Retention: unlimited (set lifecycle policy to delete after 90 days)
  90-day retention: 4.1TB × 3 months = 12.3TB × $0.023 = $283/month

  Winner: S3 backend + local SSD cache = $582/month with unlimited retention
  vs in-memory = $1,414/month with only 38 hours retention
```

---

## Observability Cost Summary Table

| Component | Unoptimized Monthly Cost | Optimized Monthly Cost | Optimization |
|-----------|------------------------|----------------------|--------------|
| Trace storage (100% sampling) | $5,962 | $94 | Tail-based sampling (1.6% retention) |
| Metrics (cardinality) | $80 (naive) → $4M (extreme) | $16 | Recording rules, label reduction |
| Logs (full request bodies) | $12,950 | $259 | Filter to warn+, remove query documents |
| Prometheus storage (raw) | $276 (10M series) | $94 (100K series) | Cardinality management |
| Long-term metrics (Mimir/S3) | $0 | $0.03 | Recording rules on S3 |
| Trace storage backend | $1,414 (in-memory) | $582 (S3+cache) | Object storage |
| **Total** | **~$20,685** | **~$1,045** | **95% cost reduction** |

---

## References and Related Topics

- [14-observability/01-opentelemetry.md](../14-observability/01-opentelemetry.md) — OTel Collector configuration
- [14-observability/02-distributed-tracing.md](../14-observability/02-distributed-tracing.md) — Trace architecture and span structure
- [14-observability/03-metrics.md](../14-observability/03-metrics.md) — Metric naming and label conventions
- [14-observability/05-slos-and-alerting.md](../14-observability/05-slos-and-alerting.md) — Recording rules used for SLO tracking
- [OpenTelemetry Collector Tail Sampling Processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor) — Configuration reference
- [Grafana Mimir Documentation](https://grafana.com/docs/mimir/latest/) — Long-term metrics storage
- [Grafana Tempo S3 Configuration](https://grafana.com/docs/tempo/latest/configuration/#storage) — Object storage backend
- [Prometheus Recording Rules](https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/) — Cardinality reduction via pre-aggregation
