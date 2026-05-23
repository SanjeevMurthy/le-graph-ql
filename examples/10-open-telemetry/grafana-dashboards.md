# Grafana Dashboards and Alerting — GraphQL Federation Platform

<!-- Companion docs: ../../docs/14-observability/ -->

This document provides production-ready Grafana dashboard PromQL queries, Prometheus alerting
rules (as a Kubernetes PrometheusRule resource), and Jaeger trace search recipes for monitoring
an Apollo Federation v2 platform. All PromQL expressions are complete and tested against the
metrics emitted by Apollo Router as configured in `router-telemetry-config.md`.

---

## 1. Key Dashboard Panels with PromQL Queries

The following panels form the core of the GraphQL Platform Overview dashboard. Each panel
includes the PromQL expression, recommended visualization type, and tuning notes.

---

### Panel: Request Rate (Operations per Second)

**Visualization:** Time series, unit: ops/s

**PromQL:**
```promql
# Total request rate across all router instances, smoothed over a 5-minute window.
# Using rate() over 5m reduces noise from second-level traffic spikes while
# remaining responsive to sustained traffic changes.
# The result is in requests per second.
rate(apollo_router_http_requests_total[5m])
```

**By operation type (query vs mutation):**
```promql
# Break down by GraphQL operation type to distinguish read and write traffic.
# Mutation spikes often indicate retry storms from mobile clients after a failure.
sum by (operation_type) (
  rate(apollo_router_http_requests_total{operation_type=~"query|mutation"}[5m])
)
```

**By operation name (top 10):**
```promql
# Show request rate for the 10 most frequently called operations.
# Helps identify which operations are driving traffic growth.
# Remove the topk() wrapper to see all operations (may be too many for a chart).
topk(10,
  sum by (graphql_operation_name) (
    rate(apollo_router_http_requests_total[5m])
  )
)
```

---

### Panel: Error Rate (Percentage)

**Visualization:** Time series, unit: percent (0-100), alert threshold line at 5%

**PromQL — HTTP 5xx error rate:**
```promql
# Fraction of requests that returned a 5xx HTTP status code.
# 5xx errors from the router indicate infrastructure failures (OOM, panic, subgraph unavailable).
# Note: GraphQL errors (resolver errors, validation errors) return HTTP 200 with an
# "errors" field in the JSON body — they are NOT captured by this metric.
100 * (
  rate(apollo_router_http_requests_total{http_response_status_code=~"5.."}[5m])
  /
  rate(apollo_router_http_requests_total[5m])
)
```

**PromQL — GraphQL partial error rate:**
```promql
# Fraction of requests where the GraphQL response contained at least one error.
# This is the more important signal for GraphQL — HTTP 200 with errors is normal
# for partial failures (one subgraph fails, others succeed).
100 * (
  rate(apollo_router_graphql_error_requests_total[5m])
  /
  rate(apollo_router_http_requests_total[5m])
)
```

**PromQL — Error rate by operation name:**
```promql
# Per-operation error rate. Useful for identifying which specific operations
# are failing. An operation with a 100% error rate is completely broken.
100 * (
  sum by (graphql_operation_name) (
    rate(apollo_router_http_requests_total{http_response_status_code=~"5.."}[5m])
  )
  /
  sum by (graphql_operation_name) (
    rate(apollo_router_http_requests_total[5m])
  )
)
```

---

### Panel: P99 Request Latency

**Visualization:** Time series, unit: seconds (or milliseconds), alert threshold line at 2s

**PromQL — Overall P99:**
```promql
# P99 end-to-end request latency for the Apollo Router.
# histogram_quantile requires the _bucket metric with the le label.
# The 5m rate window smooths out second-level spikes in the bucket counts.
histogram_quantile(
  0.99,
  rate(apollo_router_http_request_duration_seconds_bucket[5m])
)
```

**PromQL — P50 and P99 side by side:**
```promql
# Show both P50 (median) and P99 on the same chart.
# A gap between P50 and P99 indicates a long tail — some requests are
# significantly slower than the typical request. Investigate with Jaeger.
histogram_quantile(0.99, rate(apollo_router_http_request_duration_seconds_bucket[5m]))
histogram_quantile(0.50, rate(apollo_router_http_request_duration_seconds_bucket[5m]))
```

**PromQL — P99 by operation name:**
```promql
# Per-operation P99 latency. Use this to identify which operations are slow
# rather than just knowing that the overall P99 is high.
# "sum by (graphql_operation_name, le)" preserves the le (bucket boundary) label
# which is required by histogram_quantile.
histogram_quantile(
  0.99,
  sum by (graphql_operation_name, le) (
    rate(apollo_router_http_request_duration_seconds_bucket[5m])
  )
)
```

---

### Panel: P99 Latency by Subgraph

**Visualization:** Bar chart or heatmap, unit: seconds

**PromQL:**
```promql
# P99 latency for requests sent by the router to each subgraph.
# This reveals which subgraph is the bottleneck when the overall P99 is high.
# apollo_router_http_request_duration_seconds_bucket has a "subgraph" label when
# the router is configured to emit per-subgraph metrics.
histogram_quantile(
  0.99,
  sum by (subgraph, le) (
    rate(apollo_router_http_request_duration_seconds_bucket{subgraph!=""}[5m])
  )
)
```

**PromQL — Subgraph P99 vs Router P99 (latency contribution):**
```promql
# Compare subgraph P99 against overall router P99.
# If subgraph "products" P99 = 800ms and router P99 = 850ms, products is the
# primary latency contributor. If subgraph P99 = 100ms but router P99 = 850ms,
# the latency is in query planning or in the router itself (look at planning time).

# Subgraph P99:
histogram_quantile(
  0.99,
  sum by (subgraph, le) (
    rate(apollo_router_http_request_duration_seconds_bucket{subgraph!=""}[5m])
  )
)

# Overall router P99 (for comparison):
histogram_quantile(
  0.99,
  rate(apollo_router_http_request_duration_seconds_bucket{subgraph=""}[5m])
)
```

---

### Panel: Cache Hit Rate (Query Planning Cache)

**Visualization:** Gauge, unit: percent (0-100), color: red < 70%, yellow 70-85%, green > 85%

**PromQL:**
```promql
# Query planning cache hit rate.
# A low hit rate (<70%) means the router is re-planning queries frequently,
# which adds latency and CPU overhead. Causes: high operation diversity,
# cache evictions due to cache size limits, or too many unique operation variants.
100 * (
  rate(apollo_router_cache_hit_count{kind="query planner"}[5m])
  /
  (
    rate(apollo_router_cache_hit_count{kind="query planner"}[5m])
    +
    rate(apollo_router_cache_miss_count{kind="query planner"}[5m])
  )
)
```

**PromQL — APQ (Automatic Persisted Query) cache hit rate:**
```promql
# APQ cache hit rate (if using persisted queries).
# A high APQ hit rate means clients are sending query hashes instead of full
# query documents, reducing bandwidth and validation overhead.
100 * (
  rate(apollo_router_cache_hit_count{kind="apq"}[5m])
  /
  (
    rate(apollo_router_cache_hit_count{kind="apq"}[5m])
    +
    rate(apollo_router_cache_miss_count{kind="apq"}[5m])
  )
)
```

---

### Panel: Query Planning Time P99

**Visualization:** Time series, unit: seconds, alert threshold at 100ms

**PromQL:**
```promql
# P99 time spent in the Apollo Router query planner.
# The query planner converts a GraphQL operation into a fetch plan (which subgraphs
# to call, in what order, with what queries). Planning time increases with:
# - Schema complexity (more types, more joins between subgraphs)
# - Operation complexity (deeply nested queries, many __typename introspections)
# - Cache misses (a cache miss forces a fresh plan)
# P99 > 100ms indicates schema or query complexity issues.
# P99 > 500ms is a critical problem that will dominate request latency.
histogram_quantile(
  0.99,
  rate(apollo_router_query_planning_time_seconds_bucket[5m])
)
```

---

### Panel: Active Connections

**Visualization:** Stat or gauge, unit: connections

**PromQL:**
```promql
# Number of active HTTP connections to the router.
# This is a gauge (not a counter), so do not use rate().
# A sustained spike in active connections indicates:
# - Slow subgraphs holding connections open (downstream latency)
# - Slow clients (mobile on poor networks)
# - Connection leak in the router (no keep-alive timeout configured)
apollo_router_http_requests_in_flight
```

---

### Panel: Router Pod Memory Usage

**Visualization:** Time series, unit: bytes

**PromQL:**
```promql
# Memory working set for Apollo Router pods.
# container_memory_working_set_bytes excludes inactive file cache, making it
# the best metric for actual memory pressure (what the OOM killer looks at).
# If this approaches the container memory limit, increase limits or reduce
# the query planning cache size.
container_memory_working_set_bytes{
  namespace="graphql",
  pod=~"apollo-router-.*",
  container="router"
}
```

**PromQL — Memory usage as % of limit:**
```promql
# Memory usage relative to the container limit. Alert if consistently >80%.
100 * (
  container_memory_working_set_bytes{
    namespace="graphql",
    pod=~"apollo-router-.*",
    container="router"
  }
  /
  container_spec_memory_limit_bytes{
    namespace="graphql",
    pod=~"apollo-router-.*",
    container="router"
  }
)
```

---

## 2. Prometheus Alert Rules

The following `PrometheusRule` resource is ready for `kubectl apply`. It uses the Prometheus
Operator CRD. If not using the Prometheus Operator, extract the `groups` section and add it
directly to your `prometheus.yml` `rule_files`.

```yaml
# kubernetes/graphql-platform-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: graphql-platform-alerts
  namespace: monitoring
  labels:
    # Must match your Prometheus Operator's ruleSelector labels.
    app: kube-prometheus-stack
    role: alert-rules
spec:
  groups:
    # -----------------------------------------------------------------------
    # Group: Apollo Router — Availability and Error Rate
    # -----------------------------------------------------------------------
    - name: apollo-router.availability
      # How often Prometheus evaluates these rules.
      # 1 minute balances alert responsiveness with evaluation cost.
      interval: 1m
      rules:

        # Alert: RouterDown
        # Fires when no healthy Apollo Router pods are serving traffic.
        # This is a P0 (service outage) alert — all GraphQL clients are broken.
        - alert: RouterDown
          expr: |
            sum(
              kube_deployment_status_replicas_available{
                namespace="graphql",
                deployment="apollo-router"
              }
            ) == 0
          # No "for" clause: fire immediately on first evaluation.
          # A router with 0 replicas is an immediate outage, not a transient blip.
          labels:
            severity: critical
            team: platform
            # Runbook links are essential for on-call engineers who receive the alert
            # at 3am and need immediate context on how to respond.
            runbook: "https://wiki.example.com/runbooks/graphql/router-down"
          annotations:
            summary: "Apollo Router has 0 available replicas"
            description: |
              The Apollo Router Deployment in namespace graphql has 0 available replicas.
              All GraphQL API traffic is failing. Immediate action required.
              Check: kubectl get pods -n graphql -l app=apollo-router

        # Alert: ErrorRateHigh
        # Fires when the HTTP 5xx error rate exceeds 5% for 5 consecutive minutes.
        # 5% threshold with a 5-minute window avoids false positives from transient
        # errors during deployments or brief subgraph restarts.
        - alert: ErrorRateHigh
          expr: |
            (
              rate(apollo_router_http_requests_total{
                http_response_status_code=~"5.."
              }[5m])
              /
              rate(apollo_router_http_requests_total[5m])
            ) > 0.05
          for: 5m
          labels:
            severity: critical
            team: platform
            runbook: "https://wiki.example.com/runbooks/graphql/error-rate-high"
          annotations:
            summary: "GraphQL error rate is above 5%"
            description: |
              The HTTP 5xx error rate for Apollo Router has exceeded 5% for more than 5 minutes.
              Current error rate: {{ printf "%.1f" (mul $value 100) }}%
              Investigate with: kubectl logs -n graphql -l app=apollo-router --since=10m
              Check Jaeger for error traces: service=apollo-router, tags: error=true

        # Alert: GraphQLPartialErrorRateHigh
        # GraphQL errors are returned as HTTP 200 with an "errors" key.
        # A high partial error rate indicates resolver failures or schema mismatches.
        - alert: GraphQLPartialErrorRateHigh
          expr: |
            (
              rate(apollo_router_graphql_error_requests_total[5m])
              /
              rate(apollo_router_http_requests_total[5m])
            ) > 0.10
          for: 5m
          labels:
            severity: warning
            team: platform
            runbook: "https://wiki.example.com/runbooks/graphql/partial-errors-high"
          annotations:
            summary: "GraphQL partial error rate is above 10%"
            description: |
              More than 10% of GraphQL responses contain errors (HTTP 200 with errors field).
              This is typically caused by resolver failures in one or more subgraphs.
              Current partial error rate: {{ printf "%.1f" (mul $value 100) }}%

    # -----------------------------------------------------------------------
    # Group: Apollo Router — Latency
    # -----------------------------------------------------------------------
    - name: apollo-router.latency
      interval: 1m
      rules:

        # Alert: LatencyHigh
        # Fires when the overall P99 request latency exceeds 2 seconds for 5 minutes.
        # 2 seconds is a reasonable SLO for a GraphQL API serving interactive UIs.
        # Adjust the threshold to match your specific SLO.
        - alert: LatencyHigh
          expr: |
            histogram_quantile(
              0.99,
              rate(apollo_router_http_request_duration_seconds_bucket[5m])
            ) > 2
          for: 5m
          labels:
            severity: warning
            team: platform
            runbook: "https://wiki.example.com/runbooks/graphql/latency-high"
          annotations:
            summary: "GraphQL P99 latency is above 2 seconds"
            description: |
              The P99 request latency for Apollo Router has exceeded 2 seconds for 5 minutes.
              Current P99 latency: {{ printf "%.2f" $value }}s
              Check subgraph latencies to identify the bottleneck.
              Check query planning time — may indicate schema complexity regression.

        # Alert: SubgraphLatencyHigh
        # Fires if any individual subgraph has a P99 latency above 1.5 seconds.
        # This catches cases where one slow subgraph is pulling up the overall P99.
        - alert: SubgraphLatencyHigh
          expr: |
            histogram_quantile(
              0.99,
              sum by (subgraph, le) (
                rate(apollo_router_http_request_duration_seconds_bucket{subgraph!=""}[5m])
              )
            ) > 1.5
          for: 5m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "Subgraph {{ $labels.subgraph }} P99 latency is above 1.5 seconds"
            description: |
              Subgraph {{ $labels.subgraph }} P99 latency: {{ printf "%.2f" $value }}s.
              Check the subgraph's pod logs and its own metrics for resource exhaustion.

        # Alert: QueryPlanningTimeSlow
        # Fires if query planning P99 exceeds 200ms.
        # This is a leading indicator of schema complexity problems, not an end-user
        # visible issue yet, but it will become one as traffic grows.
        - alert: QueryPlanningTimeSlow
          expr: |
            histogram_quantile(
              0.99,
              rate(apollo_router_query_planning_time_seconds_bucket[5m])
            ) > 0.2
          for: 10m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "GraphQL query planning P99 exceeds 200ms"
            description: |
              Query planning P99: {{ printf "%.0f" (mul $value 1000) }}ms.
              Possible causes: schema complexity growth, cache size too small, or new
              high-complexity operations being introduced.

    # -----------------------------------------------------------------------
    # Group: Apollo Router — Cache Efficiency
    # -----------------------------------------------------------------------
    - name: apollo-router.cache
      interval: 5m  # Cache metrics change slowly; evaluate every 5 minutes
      rules:

        # Alert: CacheMissRateHigh
        # Fires when the query planning cache miss rate exceeds 50% for 15 minutes.
        # A consistently high miss rate indicates the cache is too small for the
        # operation diversity, or that many operations are not being cached (anonymous
        # operations without a normalized form are not cacheable).
        - alert: CacheMissRateHigh
          expr: |
            (
              rate(apollo_router_cache_miss_count{kind="query planner"}[5m])
              /
              (
                rate(apollo_router_cache_hit_count{kind="query planner"}[5m])
                +
                rate(apollo_router_cache_miss_count{kind="query planner"}[5m])
              )
            ) > 0.50
          for: 15m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "Query planning cache miss rate is above 50%"
            description: |
              The query planning cache miss rate is {{ printf "%.1f" (mul $value 100) }}%.
              This causes excessive query re-planning overhead. Consider:
              1. Increasing the query planning cache size in router.yaml.
              2. Enforcing persisted queries to reduce operation diversity.
              3. Reviewing recent schema changes that may have invalidated the cache.

    # -----------------------------------------------------------------------
    # Group: Apollo Router — Infrastructure
    # -----------------------------------------------------------------------
    - name: apollo-router.infrastructure
      interval: 1m
      rules:

        # Alert: RouterPodMemoryHigh
        # Fires when any router pod is using more than 85% of its memory limit.
        # At 90%+, the risk of OOM kill increases significantly.
        - alert: RouterPodMemoryHigh
          expr: |
            (
              container_memory_working_set_bytes{
                namespace="graphql",
                pod=~"apollo-router-.*",
                container="router"
              }
              /
              container_spec_memory_limit_bytes{
                namespace="graphql",
                pod=~"apollo-router-.*",
                container="router"
              }
            ) > 0.85
          for: 5m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "Apollo Router pod {{ $labels.pod }} memory usage is above 85%"
            description: |
              Pod {{ $labels.pod }} memory usage: {{ printf "%.0f" (mul $value 100) }}% of limit.
              If not resolved, the pod risks OOM kill and all in-flight requests will fail.
              Consider increasing the memory limit or reducing query planning cache size.

        # Alert: RouterReplicasMismatch
        # Fires when the available replicas are fewer than the desired replicas for 10 minutes.
        # This catches degraded (not fully down) deployments — e.g., 1 of 3 pods is healthy.
        - alert: RouterReplicasMismatch
          expr: |
            kube_deployment_status_replicas_available{
              namespace="graphql",
              deployment="apollo-router"
            }
            <
            kube_deployment_spec_replicas{
              namespace="graphql",
              deployment="apollo-router"
            }
          for: 10m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "Apollo Router has fewer replicas than desired"
            description: |
              Available replicas: {{ $value }}, desired replicas: check kube_deployment_spec_replicas.
              Some router pods are unhealthy. Traffic is being served by fewer pods than expected,
              reducing fault tolerance.
```

---

## 3. Useful Jaeger Trace Search Queries

These search queries are entered in the Jaeger UI (or equivalent Grafana Tempo queries) for
ad-hoc investigation during incidents or performance reviews.

---

**Find all error traces from Apollo Router in the last hour:**

```
Service:    apollo-router
Operation:  http_request
Tags:       error=true
Lookback:   1h
```

This is the starting point for every GraphQL incident investigation. Filter further by operation
name once you identify the failing operation.

---

**Find slow traces (>1 second) for a specific operation:**

```
Service:    apollo-router
Operation:  http_request
Tags:       graphql.operation.name=GetUserProfile
Min Duration: 1s
Lookback:   3h
```

Use this to find the specific traces that contributed to a P99 latency spike. The span waterfall
in Jaeger shows exactly where the 1+ second was spent (planning, users subgraph, products
subgraph, etc.).

---

**Trace a specific request by request ID (when reported by a user):**

```
Service:    apollo-router
Tags:       request_id=<value from x-request-id header>
Lookback:   24h
```

When a user reports "my request at 14:23 was slow or failed", extract the `x-request-id` from
their browser's network tab (if instrumented) or from your API gateway logs, then search by it
in Jaeger. This finds the exact trace for that specific request.

---

**Find traces where the products subgraph was slow:**

```
Service:    apollo-router
Tags:       subgraph=products
Min Duration: 500ms
Lookback:   1h
```

This shows all traces where the products subgraph span took more than 500ms. Useful for isolating
subgraph-specific latency issues from end-to-end latency.

---

**Find traces with subgraph HTTP errors:**

```
Service:    apollo-router
Tags:       subgraph=users, http.status_code=503
Lookback:   30m
```

Identifies traces where the users subgraph returned a 503 error. Useful during or after a
subgraph deployment to verify that errors are resolved.

---

**Find traces for anonymous (unnamed) operations:**

```
Service:    apollo-router
Tags:       graphql.operation.name=<anonymous>
Lookback:   1h
Min Duration: 100ms
```

Anonymous operations (queries without a `query` operation name) often come from ad-hoc tools
or poorly instrumented clients. They are harder to optimize because they cannot be tracked over
time. This query helps identify how many anonymous operations are being executed.

---

**Find all traces from a specific client version (for regression testing):**

```
Service:    apollo-router
Tags:       client.name=ios-app, client.version=2.4.1
Lookback:   6h
```

Use after deploying a new client version to verify that the new version's operations are
performing as expected and not introducing new errors.

---

## Related Documentation

- `../../docs/14-observability/` — SLO definitions, alerting policy, and on-call runbooks for
  the GraphQL platform.
- `router-telemetry-config.md` — Apollo Router configuration that emits the metrics used in
  the PromQL queries above.
- `otel-collector-config.md` — OTel Collector configuration, including the Prometheus and Loki
  exporters that make these dashboards possible.

---

## Key Design Decisions

**Histogram quantiles over averages**
All latency panels use `histogram_quantile()` rather than averages (`rate()` over a sum).
Averages mask the long tail: if 99% of requests take 50ms and 1% take 5 seconds, the average
is ~100ms — which looks fine but the 1% of users getting 5-second responses are having a
terrible experience. Histogram quantiles directly answer "what is the 99th percentile experience?"

**Using `for:` clauses on all alerts except RouterDown**
The `for:` clause requires the alert condition to be continuously true for a minimum duration
before firing. This prevents transient spikes from triggering pages. For example, an error rate
spike during a rolling deployment might last 30 seconds but not trigger `ErrorRateHigh` (which
requires 5 consecutive minutes). `RouterDown` is the exception: zero replicas is immediately
actionable and the false positive risk (deploying new replicas takes >1 minute to reach Ready)
is manageable.

**Separate alert groups with different evaluation intervals**
Cache-related alerts evaluate every 5 minutes instead of 1 minute because cache metrics change
slowly and frequent evaluation does not add value. Using longer intervals for stable metrics
reduces Prometheus evaluation load and rule engine overhead in large deployments with hundreds
of rules.

**Runbook links in alert annotations**
Every critical alert includes a `runbook` label with the URL of the response playbook. An
on-call engineer receiving a page at 3am should never have to search for what to do — the
runbook link in the alert notification provides the immediate next steps.
