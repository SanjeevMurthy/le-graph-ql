# 05 — SLOs and Alerting for GraphQL

> **Purpose**
> This document defines SLO specifications for a federated GraphQL platform, provides complete Prometheus alerting rule YAML for multi-window multi-burn-rate alerts, covers error budget calculation, PagerDuty routing policy configuration, Slack alert templates, runbook link conventions, and Grafana SLO dashboard JSON. Written for SREs and platform engineers who own the reliability contract and on-call process.

---

## Learning Objectives

After reading this document you will be able to:

1. Define GraphQL-specific SLOs that correctly account for the single-endpoint, variable-query-shape model.
2. Write multi-window multi-burn-rate alert rules in Prometheus for each SLO.
3. Calculate error budgets and burn rates from raw Prometheus metrics.
4. Configure PagerDuty routing policies that distinguish page-worthy incidents from Slack notifications.
5. Write Slack alert templates that are actionable (include runbook links, affected operations, and current burn rate).
6. Build a Grafana SLO dashboard that shows error budget consumption in real time.

---

## SLO Design Principles for GraphQL

### Why Standard SLO Definitions Fail for GraphQL

A naive SLO definition for a REST API — "99.9% of requests succeed in < 500ms" — applied to a GraphQL single endpoint produces a meaningless signal. Two problems:

1. **Latency SLOs must be per-operation-category, not per-endpoint.** A complex bulk export query that takes 8 seconds is acceptable; an interactive product page query that takes 8 seconds is a page-worthy incident.

2. **Error SLOs must distinguish complete from partial failures.** GraphQL returns `HTTP 200` for both successful responses and error responses. The `errors[]` array in the response body must be the source of truth, and partial errors (one field failed) are categorically different from complete errors (entire operation returned `data: null`).

### SLO Taxonomy

Define separate SLOs for each operation category:

| Category | Example Operations | Latency SLI Target | Error SLI Target |
|----------|------------------|--------------------|-----------------|
| Interactive queries | `GetProductPage`, `SearchProducts`, `GetCart` | p99 < 500ms | complete error rate < 0.1% |
| Mutations | `AddToCart`, `CheckoutOrder`, `UpdateProfile` | p99 < 1000ms | complete error rate < 0.05% |
| Background / bulk queries | `ExportOrders`, `GenerateReport`, `BulkSync` | p99 < 30s | complete error rate < 1% |
| Subscriptions | `OrderStatusUpdated`, `InventoryChanged` | connection establishment p99 < 2000ms | disconnection error rate < 0.5% |
| Internal / service-to-service | `GetProductsForRecommendation`, `_entities` | p99 < 200ms | complete error rate < 0.1% |

---

## SLI Definitions

### SLI 1: Request Latency

```
SLI = proportion of requests where duration < threshold
    = count(requests where duration <= threshold) / count(all requests)

Good event: request.duration <= threshold for that operation category
Bad event:  request.duration >  threshold for that operation category

Measurement: apollo_router_graphql_request_duration_seconds histogram,
             filtered by operation_name regex for each category
```

### SLI 2: Error Rate

```
SLI = proportion of requests that completed without complete errors
    = count(requests where graphql.error.count{error_type="complete"} == 0)
      / count(all requests)

Good event: no complete errors in the response
Bad event:  data: null in the response body

Measurement: apollo_router_graphql_error_total{error_type="complete"} counter
             divided by apollo_router_graphql_requests_total counter
```

### SLI 3: Availability

```
SLI = proportion of time periods where the service is responding
    = 1 - (time periods where p95 latency > 10x normal SLO threshold)

This is a proxy availability SLI. True availability (the ability to receive
and process requests) is measured by the error SLI; this catches brownouts
where requests are technically succeeding but taking so long as to be
functionally unavailable.
```

---

## SLO Specifications

### SLO 1: Interactive Query Latency

```yaml
# SLO specification document (for reference; not a machine-readable format)
slo:
  name: "interactive-query-latency"
  description: "99.5% of interactive queries complete in under 500ms (rolling 30 days)"
  service: "apollo-router"
  sli:
    metric: apollo_router_graphql_request_duration_seconds_bucket
    good_event_filter:
      operation_name: "~GetProductPage|SearchProducts|GetCart|GetUserProfile|GetCheckout"
      le: "0.5"
    total_event_filter:
      operation_name: "~GetProductPage|SearchProducts|GetCart|GetUserProfile|GetCheckout"
  target: 0.995   # 99.5%
  rolling_window: 30d
  error_budget:
    total_minutes: 43200          # 30d × 24h × 60m
    allowed_bad_minutes: 216      # 43200 × (1 - 0.995)
```

### SLO 2: Complete Error Rate

```yaml
slo:
  name: "complete-error-rate"
  description: "99.9% of all operations succeed without complete GraphQL errors (rolling 30 days)"
  service: "apollo-router"
  sli:
    good_events: apollo_router_graphql_requests_total - apollo_router_graphql_error_total{error_type="complete"}
    total_events: apollo_router_graphql_requests_total
  target: 0.999   # 99.9%
  rolling_window: 30d
  error_budget:
    # At 1000 RPS for 30 days: 2,592,000,000 total requests
    # Allowed bad requests: 2,592,000,000 × 0.001 = 2,592,000
```

### SLO 3: Mutation Success Rate

```yaml
slo:
  name: "mutation-success-rate"
  description: "99.95% of mutations succeed (rolling 30 days). Mutations have a stricter SLO because they modify state."
  service: "apollo-router"
  sli:
    good_events: "apollo_router_graphql_requests_total{operation_type='mutation'} - apollo_router_graphql_error_total{operation_type='mutation', error_type='complete'}"
    total_events: "apollo_router_graphql_requests_total{operation_type='mutation'}"
  target: 0.9995
  rolling_window: 30d
```

---

## Multi-Window Multi-Burn-Rate Alerting

Multi-window multi-burn-rate (MWMBR) alerting is the recommended approach from the Google SRE Workbook. It fires when the error budget is being consumed faster than sustainable — at different burn rates for different severity levels.

### Understanding Burn Rate

A burn rate of 1.0 means the SLO budget is being consumed at exactly the rate it would be fully exhausted at the end of the window. A burn rate of 10 means the budget is being consumed 10x faster than sustainable.

```
burn_rate = error_rate / (1 - SLO_target)

For 99.9% SLO (error_budget = 0.1%):
  current_error_rate = 1%
  burn_rate = 0.01 / 0.001 = 10

At burn_rate = 10:
  30d budget exhausted in: 30d / 10 = 3 days → PAGE
```

### Alert Severity Tiers

| Severity | Burn Rate | Detection Window | Time to Budget Exhaustion | Action |
|----------|-----------|-----------------|--------------------------|--------|
| Critical (P1) | > 14.4x | 1h | < 2 days | PagerDuty page |
| High (P2) | > 6x | 6h | < 5 days | PagerDuty page |
| Warning (P3) | > 3x | 1d | < 10 days | Slack notification |
| Info (P4) | > 1x | 3d | Budget exhaustion possible | Slack notification |

### Prometheus Alerting Rules — Complete File

```yaml
# rules/graphql-slo-alerts.yaml
groups:
  # ─────────────────────────────────────────────
  # SLO 1: Interactive Query Latency
  # ─────────────────────────────────────────────
  - name: graphql_slo_interactive_latency
    rules:
      # Burn rate recording rules (needed for multi-window)
      - record: job:graphql_interactive_latency_budget_burn:1h
        expr: |
          1 - (
            sum(rate(
              apollo_router_graphql_request_duration_seconds_bucket{
                operation_name=~"GetProductPage|SearchProducts|GetCart|GetUserProfile|GetCheckout",
                le="0.5"
              }[1h]
            ))
            /
            sum(rate(
              apollo_router_graphql_request_duration_seconds_count{
                operation_name=~"GetProductPage|SearchProducts|GetCart|GetUserProfile|GetCheckout"
              }[1h]
            ))
          ) / 0.005   # (1 - 0.995 SLO target)

      - record: job:graphql_interactive_latency_budget_burn:5m
        expr: |
          1 - (
            sum(rate(
              apollo_router_graphql_request_duration_seconds_bucket{
                operation_name=~"GetProductPage|SearchProducts|GetCart|GetUserProfile|GetCheckout",
                le="0.5"
              }[5m]
            ))
            /
            sum(rate(
              apollo_router_graphql_request_duration_seconds_count{
                operation_name=~"GetProductPage|SearchProducts|GetCart|GetUserProfile|GetCheckout"
              }[5m]
            ))
          ) / 0.005

      - record: job:graphql_interactive_latency_budget_burn:6h
        expr: |
          1 - (
            sum(rate(
              apollo_router_graphql_request_duration_seconds_bucket{
                operation_name=~"GetProductPage|SearchProducts|GetCart|GetUserProfile|GetCheckout",
                le="0.5"
              }[6h]
            ))
            /
            sum(rate(
              apollo_router_graphql_request_duration_seconds_count{
                operation_name=~"GetProductPage|SearchProducts|GetCart|GetUserProfile|GetCheckout"
              }[6h]
            ))
          ) / 0.005

      - record: job:graphql_interactive_latency_budget_burn:1d
        expr: |
          1 - (
            sum(rate(
              apollo_router_graphql_request_duration_seconds_bucket{
                operation_name=~"GetProductPage|SearchProducts|GetCart|GetUserProfile|GetCheckout",
                le="0.5"
              }[1d]
            ))
            /
            sum(rate(
              apollo_router_graphql_request_duration_seconds_count{
                operation_name=~"GetProductPage|SearchProducts|GetCart|GetUserProfile|GetCheckout"
              }[1d]
            ))
          ) / 0.005

      # Alert rules (multi-window multi-burn-rate)
      - alert: GraphQLInteractiveLatencyCritical
        expr: |
          job:graphql_interactive_latency_budget_burn:1h > 14.4
          AND
          job:graphql_interactive_latency_budget_burn:5m > 14.4
        for: 2m
        labels:
          severity: critical
          slo: interactive-query-latency
          team: graphql-platform
        annotations:
          summary: "GraphQL interactive query latency SLO burning critically"
          description: |
            Burn rate is {{ $value | humanize }}x sustainable (threshold: 14.4x).
            At this rate, the 30-day error budget will be exhausted in {{ div 720 $value | humanizeDuration }}.
          runbook_url: "https://runbooks.internal.example.com/graphql/latency-slo"
          dashboard_url: "https://grafana.internal.example.com/d/graphql-slo"

      - alert: GraphQLInteractiveLatencyHigh
        expr: |
          job:graphql_interactive_latency_budget_burn:6h > 6
          AND
          job:graphql_interactive_latency_budget_burn:1h > 6
        for: 15m
        labels:
          severity: high
          slo: interactive-query-latency
          team: graphql-platform
        annotations:
          summary: "GraphQL interactive query latency SLO burning fast"
          description: |
            Burn rate is {{ $value | humanize }}x sustainable (threshold: 6x).
            Budget exhaustion in {{ div 720 $value | humanizeDuration }}.
          runbook_url: "https://runbooks.internal.example.com/graphql/latency-slo"

      - alert: GraphQLInteractiveLatencyWarning
        expr: |
          job:graphql_interactive_latency_budget_burn:1d > 3
          AND
          job:graphql_interactive_latency_budget_burn:6h > 3
        for: 1h
        labels:
          severity: warning
          slo: interactive-query-latency
          team: graphql-platform
        annotations:
          summary: "GraphQL interactive query latency SLO budget draining"
          description: |
            Burn rate is {{ $value | humanize }}x sustainable (threshold: 3x).
            Budget exhaustion in {{ div 720 $value | humanizeDuration }}.
          runbook_url: "https://runbooks.internal.example.com/graphql/latency-slo"

  # ─────────────────────────────────────────────
  # SLO 2: Complete Error Rate
  # ─────────────────────────────────────────────
  - name: graphql_slo_error_rate
    rules:
      - record: job:graphql_error_budget_burn:1h
        expr: |
          (
            sum(rate(apollo_router_graphql_error_total{error_type="complete"}[1h]))
            /
            sum(rate(apollo_router_graphql_requests_total[1h]))
          ) / 0.001   # (1 - 0.999 SLO target)

      - record: job:graphql_error_budget_burn:5m
        expr: |
          (
            sum(rate(apollo_router_graphql_error_total{error_type="complete"}[5m]))
            /
            sum(rate(apollo_router_graphql_requests_total[5m]))
          ) / 0.001

      - record: job:graphql_error_budget_burn:6h
        expr: |
          (
            sum(rate(apollo_router_graphql_error_total{error_type="complete"}[6h]))
            /
            sum(rate(apollo_router_graphql_requests_total[6h]))
          ) / 0.001

      - record: job:graphql_error_budget_burn:1d
        expr: |
          (
            sum(rate(apollo_router_graphql_error_total{error_type="complete"}[1d]))
            /
            sum(rate(apollo_router_graphql_requests_total[1d]))
          ) / 0.001

      - alert: GraphQLErrorRateCritical
        expr: |
          job:graphql_error_budget_burn:1h > 14.4
          AND
          job:graphql_error_budget_burn:5m > 14.4
        for: 2m
        labels:
          severity: critical
          slo: complete-error-rate
          team: graphql-platform
        annotations:
          summary: "GraphQL complete error rate SLO burning critically"
          description: |
            Complete error burn rate {{ $value | humanize }}x budget consumption rate.
            Current error rate: {{ printf "%.3f" (query "job:graphql_complete_error_rate:5m" | first | value) }}%.
            Budget exhaustion in approximately {{ div 720 $value | humanizeDuration }}.
          runbook_url: "https://runbooks.internal.example.com/graphql/error-slo"
          dashboard_url: "https://grafana.internal.example.com/d/graphql-slo"

      - alert: GraphQLErrorRateHigh
        expr: |
          job:graphql_error_budget_burn:6h > 6
          AND
          job:graphql_error_budget_burn:1h > 6
        for: 15m
        labels:
          severity: high
          slo: complete-error-rate
          team: graphql-platform
        annotations:
          summary: "GraphQL complete error rate SLO burning fast"
          description: |
            Complete error burn rate {{ $value | humanize }}x budget consumption rate.
          runbook_url: "https://runbooks.internal.example.com/graphql/error-slo"

      - alert: GraphQLErrorRateWarning
        expr: |
          job:graphql_error_budget_burn:1d > 3
          AND
          job:graphql_error_budget_burn:6h > 3
        for: 1h
        labels:
          severity: warning
          slo: complete-error-rate
          team: graphql-platform
        annotations:
          summary: "GraphQL error budget draining — investigate"
          description: |
            Burn rate {{ $value | humanize }}x. Error budget may be exhausted before end of 30-day window.
          runbook_url: "https://runbooks.internal.example.com/graphql/error-slo"

  # ─────────────────────────────────────────────
  # SLO 3: Mutation Success Rate (stricter)
  # ─────────────────────────────────────────────
  - name: graphql_slo_mutation_errors
    rules:
      - record: job:graphql_mutation_error_budget_burn:1h
        expr: |
          (
            sum(rate(apollo_router_graphql_error_total{error_type="complete", operation_type="mutation"}[1h]))
            /
            sum(rate(apollo_router_graphql_requests_total{operation_type="mutation"}[1h]))
          ) / 0.0005   # (1 - 0.9995 SLO target)

      - record: job:graphql_mutation_error_budget_burn:5m
        expr: |
          (
            sum(rate(apollo_router_graphql_error_total{error_type="complete", operation_type="mutation"}[5m]))
            /
            sum(rate(apollo_router_graphql_requests_total{operation_type="mutation"}[5m]))
          ) / 0.0005

      - alert: GraphQLMutationErrorRateCritical
        expr: |
          job:graphql_mutation_error_budget_burn:1h > 14.4
          AND
          job:graphql_mutation_error_budget_burn:5m > 14.4
        for: 2m
        labels:
          severity: critical
          slo: mutation-success-rate
          team: graphql-platform
        annotations:
          summary: "GraphQL mutation error SLO burning critically — state mutations may be failing"
          description: |
            Mutation complete error burn rate {{ $value | humanize }}x budget rate.
            Mutations represent state changes; this may indicate data inconsistency.
          runbook_url: "https://runbooks.internal.example.com/graphql/mutation-error-slo"

  # ─────────────────────────────────────────────
  # Non-SLO operational alerts
  # ─────────────────────────────────────────────
  - name: graphql_operational_alerts
    rules:
      - alert: GraphQLSubgraphDown
        expr: |
          absent(apollo_router_subgraph_requests_total{subgraph_name="products"})
          OR
          absent(apollo_router_subgraph_requests_total{subgraph_name="orders"})
          OR
          absent(apollo_router_subgraph_requests_total{subgraph_name="identity"})
        for: 5m
        labels:
          severity: critical
          team: graphql-platform
        annotations:
          summary: "No traffic reaching subgraph — subgraph may be down"
          description: "Apollo Router is not recording any requests to one or more subgraphs."
          runbook_url: "https://runbooks.internal.example.com/graphql/subgraph-down"

      - alert: GraphQLHighComplexityQueries
        expr: |
          histogram_quantile(0.99,
            sum by (le, client_name) (
              rate(apollo_router_graphql_complexity_score_bucket[5m])
            )
          ) > 5000
        for: 10m
        labels:
          severity: warning
          team: graphql-platform
        annotations:
          summary: "High-complexity queries detected from client {{ $labels.client_name }}"
          description: |
            p99 query complexity from {{ $labels.client_name }} is {{ $value }}.
            This may indicate a client sending unbounded queries. Review and apply cost limits.
          runbook_url: "https://runbooks.internal.example.com/graphql/query-complexity"

      - alert: GraphQLPlanCacheColdStart
        expr: |
          job:apollo_router_plan_cache_hit_ratio:5m < 0.5
        for: 5m
        labels:
          severity: warning
          team: graphql-platform
        annotations:
          summary: "GraphQL query plan cache hit rate low — possible cold start"
          description: |
            Plan cache hit ratio: {{ $value | humanizePercentage }}.
            Expected > 90% at steady state. This is normal for 2-3 minutes after a router deployment.
            If persisting > 10 minutes, investigate router configuration or client operation variability.
          runbook_url: "https://runbooks.internal.example.com/graphql/plan-cache"

      - alert: GraphQLSubgraphHighErrorRate
        expr: |
          job:graphql_subgraph_error_rate:5m > 0.01
        for: 5m
        labels:
          severity: high
          team: graphql-platform
        annotations:
          summary: "Subgraph {{ $labels.subgraph_name }} error rate > 1%"
          description: |
            Subgraph {{ $labels.subgraph_name }} error rate: {{ $value | humanizePercentage }}.
            This may be causing partial errors in the supergraph.
          runbook_url: "https://runbooks.internal.example.com/graphql/subgraph-errors"

      - alert: GraphQLDataLoaderN1Regression
        expr: |
          job:graphql_dataloader_batch_size:p5_5m < 2
          AND
          job:graphql_dataloader_batch_size:p5_5m offset 1h > 5
        for: 15m
        labels:
          severity: high
          team: graphql-platform
        annotations:
          summary: "DataLoader {{ $labels.loader_name }} batch size has dropped — possible N+1 regression"
          description: |
            Current p5 batch size for {{ $labels.loader_name }} in {{ $labels.subgraph_name }}: {{ $value }}.
            1 hour ago: {{ query "job:graphql_dataloader_batch_size:p5_5m offset 1h" | first | value }}.
            This suggests a code change broke DataLoader batching.
          runbook_url: "https://runbooks.internal.example.com/graphql/n1-regression"

      - alert: GraphQLRouterHighCPU
        expr: |
          avg(rate(process_cpu_seconds_total{app="apollo-router"}[5m])) > 0.8
        for: 10m
        labels:
          severity: warning
          team: graphql-platform
        annotations:
          summary: "Apollo Router CPU usage > 80% — possible query complexity spike"
          description: |
            Router CPU: {{ $value | humanizePercentage }}.
            High CPU is typically caused by query planning for complex federated operations.
            Check top operations by complexity.
          runbook_url: "https://runbooks.internal.example.com/graphql/router-cpu"
```

---

## Error Budget Calculation

### 30-Day Error Budget

```
Error Budget = (1 - SLO target) × window duration

For the 99.9% error rate SLO over 30 days:
  Error budget = (1 - 0.999) × 30d × 24h × 60min × 60sec
               = 0.001 × 2,592,000 seconds
               = 2,592 seconds of "bad" request-time

At 1000 RPS:
  Total requests in 30d = 1000 × 2,592,000 = 2,592,000,000
  Allowed bad requests  = 2,592,000,000 × 0.001 = 2,592,000 requests
```

### Real-Time Error Budget Remaining

```promql
# Error budget remaining for the complete error rate SLO (30d window)
# Returns a value between 0 and 1 (fraction of budget remaining)
1 - (
  (
    sum(increase(apollo_router_graphql_error_total{error_type="complete"}[30d]))
    /
    sum(increase(apollo_router_graphql_requests_total[30d]))
  )
  / 0.001   # (1 - SLO target)
)
```

### Error Budget Burn Rate Dashboard Queries

```promql
# Current 1-hour burn rate (most sensitive indicator)
job:graphql_error_budget_burn:1h

# Current 6-hour burn rate (confirms sustained burn)
job:graphql_error_budget_burn:6h

# Error budget remaining — fraction (0 = exhausted, 1 = full)
1 - (
  sum(increase(apollo_router_graphql_error_total{error_type="complete"}[30d]))
  /
  (sum(increase(apollo_router_graphql_requests_total[30d])) * 0.001)
)

# Time to budget exhaustion at current 1h burn rate
(1 / job:graphql_error_budget_burn:1h) * 720   # hours until exhaustion
```

---

## PagerDuty Routing Configuration

### Service and Escalation Policy

```yaml
# Defined in PagerDuty UI or via Terraform provider:

# Service: GraphQL Platform
service:
  name: "GraphQL Platform"
  escalation_policy: "graphql-platform-escalation"
  alert_grouping:
    type: intelligent   # Group alerts by similarity
    timeout: 600        # 10 minutes — group related alerts together
  auto_resolve_timeout: 14400   # 4 hours — auto-resolve if no new alerts

# Escalation Policy: graphql-platform-escalation
escalation_policy:
  name: "GraphQL Platform On-Call Escalation"
  rules:
    - escalation_delay_in_minutes: 5
      targets:
        - type: schedule
          id: "graphql-platform-primary"   # Primary on-call rotation

    - escalation_delay_in_minutes: 20
      targets:
        - type: schedule
          id: "graphql-platform-secondary"  # Secondary on-call

    - escalation_delay_in_minutes: 40
      targets:
        - type: user
          id: "engineering-manager"          # Manager escalation
```

### PagerDuty Alertmanager Configuration

```yaml
# alertmanager.yaml
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'slo', 'subgraph_name']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 3h
  receiver: 'slack-graphql-platform'

  routes:
    # Critical SLO burns — always page
    - matchers:
        - severity = "critical"
        - slo =~ ".+"
      receiver: 'pagerduty-graphql-critical'
      continue: true   # Also send to Slack

    # High severity SLO burns — page during business hours, Slack off-hours
    - matchers:
        - severity = "high"
        - slo =~ ".+"
      receiver: 'pagerduty-graphql-high'
      continue: true

    # Operational non-SLO critical alerts
    - matchers:
        - severity = "critical"
        - alertname = "GraphQLSubgraphDown"
      receiver: 'pagerduty-graphql-critical'
      continue: true

    # Warnings — Slack only
    - matchers:
        - severity = "warning"
      receiver: 'slack-graphql-platform'

receivers:
  - name: 'pagerduty-graphql-critical'
    pagerduty_configs:
      - routing_key: "${PAGERDUTY_ROUTING_KEY_CRITICAL}"
        severity: critical
        description: '{{ template "pagerduty.graphql.description" . }}'
        details:
          slo: '{{ range .Alerts }}{{ .Labels.slo }}{{ end }}'
          burn_rate: '{{ range .Alerts }}{{ .Annotations.burn_rate }}{{ end }}'
          runbook: '{{ range .Alerts }}{{ .Annotations.runbook_url }}{{ end }}'
        links:
          - text: "Grafana SLO Dashboard"
            href: "https://grafana.internal.example.com/d/graphql-slo"
          - text: "Runbook"
            href: '{{ (index .Alerts 0).Annotations.runbook_url }}'

  - name: 'pagerduty-graphql-high'
    pagerduty_configs:
      - routing_key: "${PAGERDUTY_ROUTING_KEY_HIGH}"
        severity: error
        description: '{{ template "pagerduty.graphql.description" . }}'

  - name: 'slack-graphql-platform'
    slack_configs:
      - api_url: "${SLACK_WEBHOOK_URL}"
        channel: '#graphql-incidents'
        title: '{{ template "slack.graphql.title" . }}'
        text: '{{ template "slack.graphql.text" . }}'
        color: '{{ template "slack.graphql.color" . }}'
        actions:
          - type: button
            text: "View Dashboard"
            url: "https://grafana.internal.example.com/d/graphql-slo"
          - type: button
            text: "Open Runbook"
            url: '{{ (index .Alerts 0).Annotations.runbook_url }}'

templates:
  - '/etc/alertmanager/templates/*.tmpl'
```

---

## Slack Alert Templates

```
{{/* templates/graphql-alerts.tmpl */}}

{{/* PagerDuty description */}}
{{ define "pagerduty.graphql.description" }}
[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}
SLO: {{ .CommonLabels.slo }}
Severity: {{ .CommonLabels.severity }}
{{ range .Alerts }}{{ .Annotations.description }}{{ end }}
{{ end }}

{{/* Slack alert title */}}
{{ define "slack.graphql.title" }}
{{ if eq .Status "firing" }}
  {{ if eq (index .Alerts 0).Labels.severity "critical" }}:fire:{{ end }}
  {{ if eq (index .Alerts 0).Labels.severity "high" }}:warning:{{ end }}
  {{ if eq (index .Alerts 0).Labels.severity "warning" }}:bell:{{ end }}
{{ else }}:white_check_mark:{{ end }}
[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}
{{ end }}

{{/* Slack alert body */}}
{{ define "slack.graphql.text" }}
{{ range .Alerts }}
*Summary:* {{ .Annotations.summary }}

*Details:*
{{ .Annotations.description }}

*Labels:*
• Severity: `{{ .Labels.severity }}`
• SLO: `{{ .Labels.slo }}`
• Environment: `{{ .Labels.environment }}`
{{ if .Labels.subgraph_name }}• Subgraph: `{{ .Labels.subgraph_name }}`{{ end }}

*Links:*
• <{{ .Annotations.runbook_url }}|Runbook>
• <{{ .Annotations.dashboard_url | default "https://grafana.internal.example.com/d/graphql-slo" }}|SLO Dashboard>

*Started:* {{ .StartsAt | humanizeTimestamp }}
{{ end }}
{{ end }}

{{/* Slack color coding */}}
{{ define "slack.graphql.color" }}
{{ if eq .Status "resolved" }}good{{ else }}
  {{ if eq (index .Alerts 0).Labels.severity "critical" }}danger{{ else }}warning{{ end }}
{{ end }}
{{ end }}
```

---

## Runbook Link Conventions

Runbooks are the single most important artifact for on-call engineers. All alert `runbook_url` annotations must follow this convention:

```
Format: https://runbooks.internal.example.com/graphql/{alert-name-slug}

Examples:
  https://runbooks.internal.example.com/graphql/latency-slo
  https://runbooks.internal.example.com/graphql/error-slo
  https://runbooks.internal.example.com/graphql/mutation-error-slo
  https://runbooks.internal.example.com/graphql/subgraph-down
  https://runbooks.internal.example.com/graphql/n1-regression
  https://runbooks.internal.example.com/graphql/router-cpu
  https://runbooks.internal.example.com/graphql/plan-cache
  https://runbooks.internal.example.com/graphql/query-complexity
```

### Runbook Template Structure

Each runbook must include these sections:

```markdown
# Runbook: {AlertName}

## Alert Description
What the alert means in plain language.

## Severity and SLO Impact
- Severity: Critical / High / Warning
- SLO affected: {slo-name}
- Budget consumption rate at this alarm threshold: {burn_rate}x

## Diagnosis Steps
1. (First step — usually check the Grafana dashboard panel)
2. (Isolate scope: all operations? one subgraph? one client?)
3. (Check recent deployments)
4. (Open a representative trace from the exemplar)
5. (Check correlated logs in Loki)

## Remediation Options
- Option A: Rollback (when root cause is a recent deployment)
- Option B: Scale subgraph (when cause is traffic spike)
- Option C: Circuit break (when external dependency is failing)

## Escalation
If not resolved in {N} minutes, escalate to {team/person}.

## Post-Incident
- File a post-mortem if error budget was consumed by more than 20%
- Update this runbook with any new learnings
```

---

## Grafana SLO Dashboard JSON

The following is the structure for a production SLO dashboard. The full dashboard JSON is managed in the repository at `dashboards/graphql-slo.json`.

```json
{
  "title": "GraphQL Platform SLO",
  "uid": "graphql-slo",
  "schemaVersion": 39,
  "refresh": "30s",
  "time": { "from": "now-30d", "to": "now" },
  "panels": [
    {
      "id": 1,
      "title": "Error Budget Remaining — Complete Error Rate SLO",
      "type": "gauge",
      "gridPos": { "x": 0, "y": 0, "w": 6, "h": 6 },
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "orientation": "auto",
        "showThresholdLabels": true,
        "showThresholdMarkers": true
      },
      "targets": [{
        "expr": "(1 - (sum(increase(apollo_router_graphql_error_total{error_type=\"complete\"}[30d])) / (sum(increase(apollo_router_graphql_requests_total[30d])) * 0.001))) * 100",
        "legendFormat": "Budget remaining %"
      }],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "red", "value": null },
              { "color": "yellow", "value": 25 },
              { "color": "green", "value": 75 }
            ]
          }
        }
      }
    },
    {
      "id": 2,
      "title": "Error Budget Burn Rate — 1h window",
      "type": "timeseries",
      "gridPos": { "x": 6, "y": 0, "w": 18, "h": 6 },
      "targets": [
        {
          "expr": "job:graphql_error_budget_burn:1h",
          "legendFormat": "1h burn rate"
        },
        {
          "expr": "job:graphql_error_budget_burn:6h",
          "legendFormat": "6h burn rate"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "custom": {
            "thresholdsStyle": { "mode": "dashed+area" }
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 3 },
              { "color": "orange", "value": 6 },
              { "color": "red", "value": 14.4 }
            ]
          }
        },
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "14.4x threshold (page)" },
            "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }]
          }
        ]
      },
      "options": {
        "legend": { "displayMode": "list", "placement": "bottom" }
      }
    },
    {
      "id": 3,
      "title": "SLO Status — 30-Day Rolling",
      "type": "table",
      "gridPos": { "x": 0, "y": 6, "w": 24, "h": 8 },
      "targets": [
        {
          "expr": "job:graphql_complete_error_rate:5m * 100",
          "legendFormat": "Complete Error Rate (%)",
          "instant": true
        },
        {
          "expr": "job:apollo_router_graphql_request_duration_seconds:p99_5m{operation_type=\"query\"} * 1000",
          "legendFormat": "Query p99 Latency (ms)",
          "instant": true
        },
        {
          "expr": "job:graphql_error_budget_burn:1h",
          "legendFormat": "1h Burn Rate",
          "instant": true
        }
      ],
      "transformations": [
        { "id": "merge" },
        { "id": "sortBy", "options": { "fields": [{ "desc": true, "displayName": "1h Burn Rate" }] } }
      ]
    }
  ],
  "annotations": {
    "list": [
      {
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "enable": true,
        "expr": "changes(kube_deployment_status_replicas_available{deployment=\"apollo-router\"}[5m]) > 0",
        "name": "Router deployments",
        "step": "60s",
        "titleFormat": "Router deployment"
      }
    ]
  }
}
```

---

## Error Budget Policy

The error budget policy defines how the organization responds when error budget is consumed. This policy must be written down and agreed to by engineering leadership.

```
GRAPHQL PLATFORM ERROR BUDGET POLICY
Effective: 2026-01-01
Review cycle: Quarterly

Budget Remaining > 75%: Business as usual. Feature development priority.

Budget Remaining 50-75%: Review on-call incidents. Confirm no systematic
  issue. Normal feature development continues.

Budget Remaining 25-50%: Reliability work required. At least 20% of team
  sprint capacity allocated to reliability improvements. New features
  require explicit approval from platform lead.

Budget Remaining 0-25%: Feature freeze. All sprint capacity allocated to
  reliability. No new features shipped until budget recovered above 50%.

Budget Exhausted (0%): Incident declared. Immediate triage. No deployments
  until root cause resolved and budget begins recovering. Post-mortem required
  within 5 business days.

Exceptions: Scheduled maintenance with advance notice (7+ days) and
  customer communication does not count against the error budget.
```

---

## Validation Checklist

```
[ ] Recording rules are evaluated by Prometheus (check /rules endpoint)
[ ] Alert rules appear under /alerts in Prometheus — inactive state is correct
[ ] Fire a test alert for each severity level and verify PagerDuty receives it
[ ] Fire a test alert and verify Slack #graphql-incidents receives the notification
[ ] Slack alert includes correct runbook link and dashboard link
[ ] PagerDuty escalation policy tested: primary receives, secondary escalation fires after 5m
[ ] SLO dashboard loads and shows current error budget remaining
[ ] Error budget gauge shows correct percentage (validate against manual calculation)
[ ] Burn rate chart shows threshold lines at 3x, 6x, 14.4x
[ ] Deployment annotations appear on the SLO dashboard (test with a staging deployment)
[ ] All runbook URLs are reachable (curl each URL in CI)
[ ] Error budget policy document reviewed and signed off by engineering leadership
```

---

## Related Topics

- [01-opentelemetry.md](./01-opentelemetry.md) — OTel SDK and metric emission
- [02-distributed-tracing.md](./02-distributed-tracing.md) — Trace exemplars for alert diagnosis
- [03-metrics.md](./03-metrics.md) — Recording rules consumed by SLO alert rules
- [04-query-analytics.md](./04-query-analytics.md) — Per-operation analytics for SLO scoping
- [Observability README](./README.md) — Incident diagnosis flow and four golden signals
- [Policy as Code](../13-policy-as-code/README.md) — Rate limiting and complexity limits that protect the error budget
- [CI/CD Automation](../11-ci-cd-automation/README.md) — Deployment gates that use SLO data

---

## References

- [Google SRE Workbook — Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/)
- [Google SRE Book — Four Golden Signals](https://sre.google/sre-book/monitoring-distributed-systems/)
- [Prometheus Alerting Rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
- [Alertmanager Configuration](https://prometheus.io/docs/alerting/latest/configuration/)
- [Alertmanager Notification Templates](https://prometheus.io/docs/alerting/latest/notifications/)
- [PagerDuty Alertmanager Integration](https://www.pagerduty.com/docs/guides/prometheus-integration-guide/)
- [Grafana Alerting](https://grafana.com/docs/grafana/latest/alerting/)
- [Multi-Window Multi-Burn-Rate Alerts](https://sre.google/workbook/alerting-on-slos/#6-multiwindow-multi-burn-rate-alerts)
- [Error Budget Policies](https://sre.google/workbook/error-budget-policy/)
