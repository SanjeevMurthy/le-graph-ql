# 03 — Metrics for GraphQL

> **Purpose**
> This document defines the complete metric taxonomy for a federated GraphQL platform across four layers (router, subgraph, DataLoader, data source), covers Prometheus scrape configuration, recording rules for per-operation percentiles, Grafana dashboard construction (including importable JSON structure), Grafana Mimir for long-term storage, and cardinality management strategies. Written for platform engineers and SREs who own the metrics pipeline and dashboard layer.

---

## Learning Objectives

After reading this document you will be able to:

1. Enumerate the complete set of metrics produced at each layer of a federated GraphQL stack and explain the alerting use case for each.
2. Configure Prometheus scrape annotations and ServiceMonitor resources for Apollo Router and subgraph pods.
3. Write recording rules that pre-compute per-operation latency percentiles without label cardinality explosion.
4. Build a Grafana dashboard for GraphQL operations covering the four golden signals.
5. Deploy Grafana Mimir as a Prometheus-compatible long-term storage backend with multi-tenancy.
6. Identify high-cardinality label risks in GraphQL metrics and apply mitigation strategies.

---

## Complete Metric Taxonomy

### Layer 1: Router Metrics

These metrics are emitted by Apollo Router. They represent the external view of the GraphQL API.

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `apollo_router_http_requests_total` | Counter | `status`, `method`, `path` | Total HTTP requests at the transport layer |
| `apollo_router_graphql_requests_total` | Counter | `operation_name`, `operation_type`, `client_name`, `client_version` | Total GraphQL operations processed |
| `apollo_router_graphql_request_duration_seconds` | Histogram | `operation_name`, `operation_type`, `client_name` | End-to-end operation latency (p50/p95/p99) |
| `apollo_router_graphql_error_total` | Counter | `operation_name`, `error_code`, `error_type`, `client_name` | GraphQL error count (`error_type`: `complete`\|`partial`) |
| `apollo_router_query_planning_time_seconds` | Histogram | `operation_name` | Time spent in the query planner |
| `apollo_router_query_planning_cache_hit_total` | Counter | `operation_name` | Plan cache hits |
| `apollo_router_query_planning_cache_miss_total` | Counter | `operation_name` | Plan cache misses |
| `apollo_router_graphql_complexity_score` | Histogram | `operation_name`, `client_name` | Complexity score distribution |
| `apollo_router_graphql_depth` | Histogram | `operation_name`, `client_name` | Query depth distribution |
| `apollo_router_subgraph_requests_total` | Counter | `subgraph_name`, `status` | Subgraph fetch count |
| `apollo_router_subgraph_request_duration_seconds` | Histogram | `subgraph_name` | Per-subgraph fetch latency |
| `apollo_router_subgraph_error_total` | Counter | `subgraph_name`, `error_code` | Subgraph fetch errors |
| `apollo_router_session_count` | Gauge | `state` | Active WebSocket / subscription sessions |
| `apollo_router_cache_hit_total` | Counter | `cache_type`, `operation_name` | Document / plan / response cache hits |
| `apollo_router_cache_miss_total` | Counter | `cache_type`, `operation_name` | Cache misses |
| `apollo_router_policy_violations_total` | Counter | `violation_type`, `client_name` | Rate limit / complexity / depth violations |
| `apollo_router_coprocessor_requests_total` | Counter | `stage`, `status` | Rhai coprocessor invocations |
| `apollo_router_coprocessor_duration_seconds` | Histogram | `stage` | Coprocessor execution latency |

### Layer 2: Subgraph Metrics

Each subgraph emits these metrics via the OTel SDK, converted to Prometheus format by the OTel Collector.

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `graphql_subgraph_http_requests_total` | Counter | `subgraph_name`, `status_code`, `operation_name` | Subgraph request count |
| `graphql_subgraph_request_duration_seconds` | Histogram | `subgraph_name`, `operation_name` | Subgraph response latency |
| `graphql_subgraph_error_total` | Counter | `subgraph_name`, `error_code`, `operation_name` | Subgraph application errors |
| `graphql_resolver_duration_seconds` | Histogram | `subgraph_name`, `parent_type`, `field_name` | Resolver execution latency |
| `graphql_resolver_error_total` | Counter | `subgraph_name`, `parent_type`, `field_name`, `error_code` | Resolver errors |

### Layer 3: DataLoader Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `graphql_dataloader_batch_size` | Histogram | `subgraph_name`, `loader_name` | Distribution of batch sizes (N+1 detection) |
| `graphql_dataloader_load_duration_seconds` | Histogram | `subgraph_name`, `loader_name` | Batch fetch duration |
| `graphql_dataloader_cache_hits_total` | Counter | `subgraph_name`, `loader_name` | In-memory cache hits |
| `graphql_dataloader_cache_misses_total` | Counter | `subgraph_name`, `loader_name` | Cache misses (required DB/API fetch) |

### Layer 4: Data Source Metrics

These are emitted by database drivers and HTTP client instrumentation.

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `db_client_operation_duration_seconds` | Histogram | `db_system`, `db_name`, `db_operation`, `subgraph_name` | Database query latency |
| `db_client_connection_pool_idle` | Gauge | `db_name`, `pool_name` | Idle connections |
| `db_client_connection_pool_used` | Gauge | `db_name`, `pool_name` | Active connections |
| `db_client_connection_pool_pending_requests` | Gauge | `db_name`, `pool_name` | Waiting connection requests |
| `http_client_request_duration_seconds` | Histogram | `http_host`, `http_method`, `http_status_code`, `subgraph_name` | External API latency |
| `redis_command_duration_seconds` | Histogram | `command`, `subgraph_name` | Redis command latency |
| `redis_connection_pool_idle` | Gauge | `pool_name` | Idle Redis connections |

---

## Prometheus Scrape Configuration

### Apollo Router — Direct Scrape

Apollo Router exposes a `/metrics` endpoint in Prometheus exposition format on port 9090 by default. Configure a ServiceMonitor (Prometheus Operator) to scrape it:

```yaml
# kubernetes/router-service-monitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: apollo-router
  namespace: graphql-platform
  labels:
    release: prometheus   # Match Prometheus Operator selector
spec:
  selector:
    matchLabels:
      app: apollo-router
  endpoints:
    - port: metrics
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_name]
          targetLabel: pod
        - sourceLabels: [__meta_kubernetes_namespace]
          targetLabel: namespace
      metricRelabelings:
        # Drop high-cardinality metrics not needed for alerting
        - sourceLabels: [__name__]
          regex: "go_.*"
          action: drop
```

### Subgraph Pods — Annotation-Based Scrape

Subgraphs annotate their pods so that Prometheus auto-discovers them:

```yaml
# kubernetes/products-subgraph-deployment.yaml
spec:
  template:
    metadata:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics"
```

If using Prometheus Operator, use a PodMonitor instead:

```yaml
# kubernetes/products-subgraph-pod-monitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: products-subgraph
  namespace: graphql-platform
spec:
  selector:
    matchLabels:
      app: products-subgraph
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      interval: 15s
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_label_subgraph_name]
          targetLabel: subgraph_name
        - sourceLabels: [__meta_kubernetes_pod_name]
          targetLabel: pod
```

### Prometheus Global Configuration

```yaml
# prometheus.yaml
global:
  scrape_interval: 15s
  scrape_timeout: 10s
  evaluation_interval: 15s
  external_labels:
    cluster: "prod-us-east-1"
    environment: "production"

rule_files:
  - /etc/prometheus/rules/*.yaml

scrape_configs:
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__

remote_write:
  - url: "http://mimir.observability.svc.cluster.local:9009/api/v1/push"
    queue_config:
      max_samples_per_send: 10000
      max_shards: 30
      capacity: 50000
    metadata_config:
      send: true
```

---

## Recording Rules

Recording rules pre-compute expensive queries so that Grafana dashboards load in milliseconds. Without recording rules, `histogram_quantile()` over high-cardinality operation_name histograms is slow and expensive.

```yaml
# rules/graphql-recording-rules.yaml
groups:
  - name: graphql_operation_percentiles
    interval: 60s
    rules:
      # Pre-compute p50/p95/p99 per operation_name over 5-minute window
      - record: job:apollo_router_graphql_request_duration_seconds:p50_5m
        expr: |
          histogram_quantile(0.50,
            sum by (operation_name, operation_type, le) (
              rate(apollo_router_graphql_request_duration_seconds_bucket[5m])
            )
          )

      - record: job:apollo_router_graphql_request_duration_seconds:p95_5m
        expr: |
          histogram_quantile(0.95,
            sum by (operation_name, operation_type, le) (
              rate(apollo_router_graphql_request_duration_seconds_bucket[5m])
            )
          )

      - record: job:apollo_router_graphql_request_duration_seconds:p99_5m
        expr: |
          histogram_quantile(0.99,
            sum by (operation_name, operation_type, le) (
              rate(apollo_router_graphql_request_duration_seconds_bucket[5m])
            )
          )

  - name: graphql_subgraph_percentiles
    interval: 60s
    rules:
      - record: job:apollo_router_subgraph_request_duration_seconds:p99_5m
        expr: |
          histogram_quantile(0.99,
            sum by (subgraph_name, le) (
              rate(apollo_router_subgraph_request_duration_seconds_bucket[5m])
            )
          )

  - name: graphql_error_rates
    interval: 60s
    rules:
      # Overall complete error rate
      - record: job:graphql_complete_error_rate:5m
        expr: |
          sum(rate(apollo_router_graphql_error_total{error_type="complete"}[5m]))
          /
          sum(rate(apollo_router_graphql_requests_total[5m]))

      # Per-operation error rate (for top 20 operations by volume)
      - record: job:graphql_operation_error_rate:5m
        expr: |
          sum by (operation_name) (
            rate(apollo_router_graphql_error_total{error_type="complete"}[5m])
          )
          /
          sum by (operation_name) (
            rate(apollo_router_graphql_requests_total[5m])
          )

      # Per-subgraph error rate
      - record: job:graphql_subgraph_error_rate:5m
        expr: |
          sum by (subgraph_name) (
            rate(apollo_router_subgraph_error_total[5m])
          )
          /
          sum by (subgraph_name) (
            rate(apollo_router_subgraph_requests_total[5m])
          )

  - name: graphql_request_rates
    interval: 15s
    rules:
      # Total request rate
      - record: job:apollo_router_graphql_requests_total:rate5m
        expr: |
          sum(rate(apollo_router_graphql_requests_total[5m]))

      # Request rate by operation type
      - record: job:apollo_router_graphql_requests_total:rate5m:by_type
        expr: |
          sum by (operation_type) (
            rate(apollo_router_graphql_requests_total[5m])
          )

      # Top operations by request rate
      - record: job:apollo_router_graphql_requests_total:rate5m:by_operation
        expr: |
          topk(20, sum by (operation_name) (
            rate(apollo_router_graphql_requests_total[5m])
          ))

  - name: graphql_cache_efficiency
    interval: 60s
    rules:
      # Plan cache hit ratio
      - record: job:apollo_router_plan_cache_hit_ratio:5m
        expr: |
          sum(rate(apollo_router_query_planning_cache_hit_total[5m]))
          /
          (
            sum(rate(apollo_router_query_planning_cache_hit_total[5m]))
            + sum(rate(apollo_router_query_planning_cache_miss_total[5m]))
          )

  - name: graphql_dataloader_n1_detection
    interval: 60s
    rules:
      # DataLoader batch size p5 (low value = potential N+1)
      - record: job:graphql_dataloader_batch_size:p5_5m
        expr: |
          histogram_quantile(0.05,
            sum by (loader_name, subgraph_name, le) (
              rate(graphql_dataloader_batch_size_bucket[5m])
            )
          )

      # DataLoader batch size p95 (high value = healthy batching)
      - record: job:graphql_dataloader_batch_size:p95_5m
        expr: |
          histogram_quantile(0.95,
            sum by (loader_name, subgraph_name, le) (
              rate(graphql_dataloader_batch_size_bucket[5m])
            )
          )
```

---

## Grafana Dashboard

### Dashboard Structure

A production GraphQL dashboard should have these panels organized into rows:

```
Row: Overview
├── [Stat] Request Rate (rps)
├── [Stat] Error Rate (%)
├── [Stat] p99 Latency (ms)
└── [Stat] Plan Cache Hit Ratio (%)

Row: Latency
├── [Time Series] p50 / p95 / p99 — by operation_type
├── [Table] Top 10 Slowest Operations (p99)
├── [Time Series] p99 Latency by Subgraph
└── [Heatmap] Latency Distribution (all operations)

Row: Traffic
├── [Time Series] Request Rate by Operation Type
├── [Bar Chart] Top 20 Operations by Volume
├── [Time Series] Subgraph Fetch Rate (fan-out ratio)
└── [Time Series] Active Subscriptions

Row: Errors
├── [Time Series] Complete Error Rate
├── [Time Series] Partial Error Rate
├── [Table] Error Breakdown by Operation
└── [Time Series] Error Rate by Subgraph

Row: Cache
├── [Time Series] Plan Cache Hit Ratio
├── [Time Series] Document Cache Hit Ratio
├── [Time Series] Response Cache Hit Ratio
└── [Time Series] Query Planning Duration p99

Row: DataLoaders (N+1 Detection)
├── [Heatmap] Batch Size Distribution by Loader
├── [Table] Loaders with Low Batch Size (potential N+1)
├── [Time Series] DataLoader Cache Hit Ratio
└── [Time Series] DataLoader Load Duration p99

Row: Infrastructure
├── [Time Series] Router CPU Usage
├── [Time Series] Router Memory Usage
├── [Time Series] DB Connection Pool Usage
└── [Time Series] DB Query Duration p99
```

### Grafana Dashboard JSON (Core Panels)

The following is a minimal importable JSON for the Overview and Latency rows. Production dashboards should be managed as code (Grafonnet or raw JSON in a ConfigMap).

```json
{
  "title": "GraphQL Platform Overview",
  "uid": "graphql-platform-overview",
  "schemaVersion": 39,
  "refresh": "30s",
  "time": { "from": "now-1h", "to": "now" },
  "templating": {
    "list": [
      {
        "name": "environment",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "query": "label_values(apollo_router_graphql_requests_total, environment)",
        "refresh": 1
      },
      {
        "name": "operation_name",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "query": "label_values(apollo_router_graphql_requests_total{environment=\"$environment\"}, operation_name)",
        "refresh": 2,
        "multi": true,
        "includeAll": true,
        "allValue": ".*"
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "title": "Request Rate",
      "type": "stat",
      "gridPos": { "x": 0, "y": 0, "w": 6, "h": 4 },
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background" },
      "targets": [{
        "expr": "sum(job:apollo_router_graphql_requests_total:rate5m{environment=\"$environment\"})",
        "legendFormat": "rps"
      }],
      "fieldConfig": {
        "defaults": {
          "unit": "reqps",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 5000 },
              { "color": "red", "value": 10000 }
            ]
          }
        }
      }
    },
    {
      "id": 2,
      "title": "Complete Error Rate",
      "type": "stat",
      "gridPos": { "x": 6, "y": 0, "w": 6, "h": 4 },
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background" },
      "targets": [{
        "expr": "job:graphql_complete_error_rate:5m{environment=\"$environment\"} * 100",
        "legendFormat": "error %"
      }],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "decimals": 3,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 0.05 },
              { "color": "red", "value": 0.1 }
            ]
          }
        }
      }
    },
    {
      "id": 3,
      "title": "p99 Latency (all operations)",
      "type": "stat",
      "gridPos": { "x": 12, "y": 0, "w": 6, "h": 4 },
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background" },
      "targets": [{
        "expr": "max(job:apollo_router_graphql_request_duration_seconds:p99_5m{environment=\"$environment\"}) * 1000",
        "legendFormat": "p99 ms"
      }],
      "fieldConfig": {
        "defaults": {
          "unit": "ms",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 300 },
              { "color": "red", "value": 500 }
            ]
          }
        }
      }
    },
    {
      "id": 4,
      "title": "Plan Cache Hit Ratio",
      "type": "stat",
      "gridPos": { "x": 18, "y": 0, "w": 6, "h": 4 },
      "targets": [{
        "expr": "job:apollo_router_plan_cache_hit_ratio:5m{environment=\"$environment\"} * 100",
        "legendFormat": "hit %"
      }],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "red", "value": null },
              { "color": "yellow", "value": 70 },
              { "color": "green", "value": 90 }
            ]
          }
        }
      }
    },
    {
      "id": 10,
      "title": "Operation Latency — p50 / p95 / p99",
      "type": "timeseries",
      "gridPos": { "x": 0, "y": 4, "w": 16, "h": 8 },
      "targets": [
        {
          "expr": "job:apollo_router_graphql_request_duration_seconds:p50_5m{environment=\"$environment\", operation_name=~\"$operation_name\"} * 1000",
          "legendFormat": "p50 {{operation_name}}"
        },
        {
          "expr": "job:apollo_router_graphql_request_duration_seconds:p95_5m{environment=\"$environment\", operation_name=~\"$operation_name\"} * 1000",
          "legendFormat": "p95 {{operation_name}}"
        },
        {
          "expr": "job:apollo_router_graphql_request_duration_seconds:p99_5m{environment=\"$environment\", operation_name=~\"$operation_name\"} * 1000",
          "legendFormat": "p99 {{operation_name}}"
        }
      ],
      "fieldConfig": {
        "defaults": { "unit": "ms" }
      }
    },
    {
      "id": 11,
      "title": "Top 10 Slowest Operations (p99)",
      "type": "table",
      "gridPos": { "x": 16, "y": 4, "w": 8, "h": 8 },
      "targets": [{
        "expr": "topk(10, job:apollo_router_graphql_request_duration_seconds:p99_5m{environment=\"$environment\"}) * 1000",
        "legendFormat": "{{operation_name}}",
        "instant": true
      }],
      "transformations": [
        { "id": "sortBy", "options": { "fields": [{ "desc": true, "displayName": "Value" }] } }
      ],
      "fieldConfig": {
        "defaults": { "unit": "ms" }
      }
    }
  ]
}
```

### Grafana Dashboard Provisioning

Store dashboards as ConfigMaps and provision them automatically:

```yaml
# kubernetes/grafana-dashboard-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: graphql-platform-dashboard
  namespace: observability
  labels:
    grafana_dashboard: "1"   # Picked up by the Grafana sidecar
data:
  graphql-platform.json: |
    { ... dashboard JSON ... }
```

---

## Grafana Mimir — Long-Term Storage

Prometheus has a default retention of 15 days and is not designed for multi-cluster federation at scale. Grafana Mimir provides a Prometheus-compatible long-term storage backend.

### Why Mimir over Thanos

| Dimension | Mimir | Thanos |
|-----------|-------|--------|
| Ingestion API | Prometheus remote_write | Sidecar or receive |
| Multi-tenancy | Built-in | Requires configuration |
| Compaction | Built-in | Separate process |
| Operational complexity | Low-medium | Medium-high |
| Recommended for | New deployments | Existing Thanos investments |

### Mimir Deployment — Helm Values

```yaml
# helm/mimir-values.yaml
mimir:
  structuredConfig:
    common:
      storage:
        backend: s3
        s3:
          bucket_name: my-org-mimir-metrics
          endpoint: s3.us-east-1.amazonaws.com
          region: us-east-1

    blocks_storage:
      s3:
        bucket_name: my-org-mimir-blocks
      tsdb:
        retention_period: 90d   # 3 months of metrics

    ruler_storage:
      s3:
        bucket_name: my-org-mimir-ruler

    alertmanager_storage:
      s3:
        bucket_name: my-org-mimir-alertmanager

    limits:
      ingestion_rate: 100000
      ingestion_burst_size: 200000
      max_label_names_per_series: 30
      max_label_value_length: 2048
      max_global_series_per_user: 1500000   # Cardinality limit per tenant
      ruler_max_rules_per_rule_group: 100
      compactor_blocks_retention_period: 90d
```

### Multi-Tenancy Configuration

For organizations with multiple GraphQL environments (production, staging, development) sharing a Mimir cluster:

```yaml
# Prometheus remote_write with tenant ID header
remote_write:
  - url: "http://mimir.observability.svc.cluster.local:9009/api/v1/push"
    headers:
      X-Scope-OrgID: "production"   # Mimir tenant ID
    queue_config:
      max_samples_per_send: 10000
      max_shards: 20
```

---

## Cardinality Management

### High-Cardinality Risk Assessment

| Label | Cardinality | Risk | Mitigation |
|-------|-------------|------|------------|
| `operation_name` | ~200 (named ops) | Low-Medium | Enforce named ops at router; reject anonymous |
| `client_name` | ~50 clients | Low | Client registration gate |
| `client_version` | ~200 (versions) | Medium | Roll up old versions using recording rules |
| `field_path` | ~10,000+ fields | Critical | Never use as Prometheus label; use GraphOS/Hive |
| `graphql.document` | Unbounded | Critical | Never use as label; use hash |
| `user_id` | Millions | Critical | Never use as label; attribute to `client_name` |
| `subgraph_name` | ~10 subgraphs | Low | Safe |
| `error_code` | ~20 codes | Low | Safe |
| `http_status_code` | ~10 codes | Low | Safe |

### Anonymous Operation Rejection

Anonymous operations produce `operation_name=""` or `operation_name="anonymous"`, which conflates all unrelated queries into one label value. Reject them at the router:

```js
// router.yaml — Rhai script to reject anonymous operations in production
[[plugins]]
  [plugins.rhai]
    scripts = ["./scripts/require-operation-name.rhai"]
```

```rust
// scripts/require-operation-name.rhai
fn supergraph_service(service) {
  let request_callback = |request| {
    let body = request.body;
    if !body.contains_key("operationName") || body["operationName"] == "" {
      return #{
        control: #{
          break: #{
            status: 400,
            body: #{ errors: [#{ message: "operationName is required for all requests" }] }
          }
        }
      };
    }
  };
  service.map_request(request_callback);
}
```

### Label Dropping with MetricRelabelings

Drop labels that inflate cardinality before they reach Prometheus:

```yaml
# ServiceMonitor — drop high-cardinality labels at scrape time
metricRelabelings:
  # Drop graphql_document label if it somehow appears
  - sourceLabels: [__name__]
    targetLabel: graphql_document
    replacement: ""

  # Normalize client version: keep only major.minor, drop patch
  - sourceLabels: [client_version]
    regex: '(\d+\.\d+)\.\d+'
    targetLabel: client_version
    replacement: '$1'

  # Drop metrics for operations with zero traffic (stale series)
  - sourceLabels: [__name__, operation_name]
    regex: 'apollo_router_graphql_requests_total;(.*)'
    action: drop
    # Note: Use recording rules and absent() to detect zero-traffic operations instead
```

### Prometheus Cardinality Query

Monitor cardinality growth in Prometheus:

```promql
# Total unique series count
prometheus_tsdb_head_series

# Series count by metric name (top 20 high-cardinality metrics)
topk(20, count by (__name__) ({__name__!=""}))

# Series with the label that has the most unique values
count by (operation_name) (apollo_router_graphql_request_duration_seconds_bucket)
```

### Exemplars — Linking Metrics to Traces

Exemplars are trace ID annotations attached to histogram samples. They enable clicking from a Grafana panel to a representative trace without requiring high-cardinality labels.

Configure exemplar storage in Prometheus:

```yaml
# prometheus.yaml
global:
  scrape_interval: 15s

storage:
  exemplars:
    max_exemplars: 100000   # Per-tsdb; ~100k exemplars stored
```

Enable exemplar scraping in ServiceMonitor:

```yaml
spec:
  endpoints:
    - port: metrics
      enableHttp2: false
      honorTimestamps: true
      trackTimestampsStaleness: true
```

Emit exemplars from the router — Apollo Router 1.40+ automatically includes exemplars with `trace_id` when OTel is enabled.

---

## Operational Runbook: Metrics

### Alert: `GraphQLHighCompleteErrorRate`

**Symptom:** `job:graphql_complete_error_rate:5m > 0.001` (>0.1% complete errors)

**Diagnosis steps:**
1. Check which operation(s) have elevated errors: `job:graphql_operation_error_rate:5m > 0.01`
2. Check which subgraph(s) are erroring: `job:graphql_subgraph_error_rate:5m > 0.01`
3. Check if a deployment happened in the last 30 minutes: look at deployment events on the dashboard
4. Open an exemplar trace from the error histogram to see the full trace with error details
5. Cross-reference with Loki: `{service_name="apollo-router"} | json | level="error"`

### Alert: `GraphQLPlanCacheMissRate`

**Symptom:** `job:apollo_router_plan_cache_hit_ratio:5m < 0.70` (<70% plan cache hit rate)

**Cause:** Cold start after deployment, or client sending many unique operation shapes.

**Remediation:** Verify that clients send consistent `operationName` fields. Check if a client bug is generating dynamic query strings.

### Alert: `GraphQLDataLoaderN1Regression`

**Symptom:** `job:graphql_dataloader_batch_size:p5_5m < 2` for a loader that previously batched well

**Cause:** A code change removed the DataLoader or broke batch accumulation timing.

**Remediation:** Review recent deployments to the affected subgraph. Check if `maxBatchSize` was inadvertently set to 1.

---

## Related Topics

- [01-opentelemetry.md](./01-opentelemetry.md) — OTel SDK setup and Collector configuration
- [02-distributed-tracing.md](./02-distributed-tracing.md) — Trace exemplars and Tempo integration
- [05-slos-and-alerting.md](./05-slos-and-alerting.md) — Alert rules consuming these recording rules
- [Performance and Scaling](../06-performance-and-scaling/README.md) — Connection pool and cache metrics
- [Federation](../07-federation/README.md) — Subgraph topology defines subgraph_name label space

---

## References

- [Prometheus Recording Rules](https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/)
- [Prometheus Operator — ServiceMonitor](https://prometheus-operator.dev/docs/user-guides/getting-started/)
- [Grafana Mimir Documentation](https://grafana.com/docs/mimir/latest/)
- [Grafana Dashboard Provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)
- [Prometheus Exemplars](https://prometheus.io/docs/prometheus/latest/exemplars/)
- [Apollo Router Metrics Reference](https://www.apollographql.com/docs/router/configuration/telemetry/instrumentation/instruments/)
- [OpenTelemetry Semantic Conventions — Metrics](https://opentelemetry.io/docs/specs/semconv/general/metrics/)
- [PromQL Cheat Sheet](https://promlabs.com/promql-cheat-sheet/)
