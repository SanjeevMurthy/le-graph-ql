# OpenTelemetry for GraphQL Federation — End-to-End Observability

<!-- Companion docs: ../../docs/14-observability/ -->

This example demonstrates a complete OpenTelemetry observability setup for a GraphQL Federation
v2 platform. It covers distributed tracing from the client request through the Apollo Router
and into each subgraph, metrics collection with Prometheus and Grafana, and structured log
aggregation with Loki. All observability signals are correlated by trace ID, enabling you to
jump from a Grafana dashboard panel to the specific Jaeger trace for a slow or failed request.

---

## What This Example Demonstrates

**End-to-end distributed tracing**

Every GraphQL request generates an OpenTelemetry trace that spans the entire request lifecycle:
client request ingress at the router, query planning, subgraph fan-out, subgraph execution, and
response assembly. Each subgraph produces child spans under the router's root span via W3C
`traceparent`/`tracestate` header propagation. In Jaeger or Grafana Tempo, you can see the exact
breakdown of where latency was incurred: planning vs. subgraph A vs. subgraph B.

**Metrics: the three golden signals plus GraphQL-specific metrics**

Apollo Router emits Prometheus-compatible metrics covering:
- Traffic: request rate by operation name, operation type, and response status.
- Latency: request duration histograms enabling P50/P99/P999 calculation.
- Errors: error rate by error type (schema validation, resolver error, subgraph error).
- Cache: query planning cache hit rate and CDN cache hit rate.
- GraphQL-specific: query planning time (a leading indicator of schema complexity problems),
  subgraph-level latency histograms, and active connection count.

**Structured logs**

Apollo Router emits JSON-structured logs that include the trace ID, operation name, operation
hash, client identity, and response status on every request. Loki ingests these logs and indexes
the trace ID, enabling log-to-trace and trace-to-log correlation in Grafana.

---

## The Three Pillars: Traces, Metrics, Logs

| Pillar | Tool | Purpose | Retention |
|--------|------|---------|-----------|
| Traces | Jaeger or Grafana Tempo | Per-request latency breakdown, subgraph attribution, error root cause | 7 days (sampled) |
| Metrics | Prometheus + Thanos | Time-series aggregations for dashboards and alerting | 90 days |
| Logs | Loki | Structured request logs for ad-hoc investigation | 30 days |
| Visualization | Grafana | Unified dashboards, alert rules, trace/log/metric correlation | — |

---

## Architecture

```
+-------------------+
|   GraphQL Client  |
|  (browser / app)  |
+-------------------+
         |
         | HTTP POST /graphql
         v
+-------------------+
|   Apollo Router   | <-- Emits: OTLP traces, Prometheus metrics, JSON logs
|   (Rust gateway)  |
+-------------------+
    |         |
    |         |  HTTP (subgraph queries)
    v         v    with traceparent headers
+-------+  +----------+  +--------+
| users |  | products |  | orders |  ... subgraphs
+-------+  +----------+  +--------+
    |           |              |
    +-----+-----+--------------+
          |
          | OTLP gRPC (port 4317)
          v
+-------------------------+
|  OTel Collector         |
|  (Deployment, 2 pods)   |
+-------------------------+
    |         |        |
    v         v        v
+-------+ +------+ +------+
| Jaeger| | Prom | | Loki |
| /Tempo| | RW   | | HTTP |
+-------+ +------+ +------+
    |         |
    v         v
+----------------------------+
|        Grafana             |
|  (dashboards + alerts)     |
+----------------------------+
```

The OTel Collector acts as a central telemetry processing hub. It receives OTLP from the router
and all subgraphs, applies tail-based sampling (always keep errors and slow requests, sample 10%
of fast successful requests), adds Kubernetes pod and node metadata, and fans out to the
appropriate backends.

---

## Prerequisites

| Component | Version | Purpose |
|-----------|---------|---------|
| Apollo Router | 1.40+ | Emits OTLP traces, Prometheus metrics, structured logs |
| OTel Collector | 0.95+ | `otelcol-contrib` build (includes all receivers/processors/exporters) |
| Jaeger | 1.55+ or Grafana Tempo 2.4+ | Distributed trace storage and query |
| Prometheus | 2.50+ | Metrics storage |
| Grafana | 10.3+ | Dashboards, alerting, trace/metric/log correlation |
| Loki | 2.9+ | Log aggregation |
| Kubernetes | 1.28+ | Deployment target for all components |

For local development, all backends can be run via Docker Compose. The OTel Collector runs as
a single container, and sampling is disabled to capture all traces.

---

## File Navigation

| File | Description |
|------|-------------|
| `README.md` | This file. Architecture overview, prerequisites. |
| `router-telemetry-config.md` | Complete `router.yaml` telemetry section. Tracing with OTLP gRPC, custom span attributes, subgraph spans, Prometheus metrics endpoint, custom instruments, structured logging, and baggage propagation. |
| `otel-collector-config.md` | Complete OTel Collector configuration. Receivers, processors (batch, memory limiter, filter, resource detection), exporters (Jaeger/Tempo, Prometheus, Loki), pipelines, Kubernetes deployment, and tail-based sampling. |
| `grafana-dashboards.md` | Grafana dashboard PromQL queries, Prometheus alerting rules (PrometheusRule YAML), and Jaeger trace search recipes. |

---

## Quick Start

```bash
# 1. Add the telemetry configuration to your router.yaml
#    (see router-telemetry-config.md for the full config)
kubectl apply -f kubernetes/router-config.yaml

# 2. Deploy the OTel Collector
#    (see otel-collector-config.md for the full collector config)
kubectl apply -f kubernetes/otel-collector.yaml

# 3. Deploy Jaeger (all-in-one for dev, production Jaeger Operator for prod)
kubectl apply -f https://github.com/jaegertracing/jaeger-operator/releases/download/v1.55.0/jaeger-operator.yaml

# 4. Verify traces are flowing
kubectl port-forward svc/jaeger-query 16686:16686
# Open http://localhost:16686 and search for service: apollo-router
```

---

## Related Documentation

- `../../docs/14-observability/` — Full observability strategy: SLOs, alerting policy, on-call
  runbooks, and the observability maturity model for GraphQL platforms.
- `../../docs/15-kubernetes-deployment/` — Kubernetes deployment patterns for Apollo Router,
  including resource requests, HPA configuration, and pod disruption budgets.
- `../../examples/09-hive/hive-router-config.md` — Hive usage reporting via OpenTelemetry,
  which reuses the same OTLP pipeline described in this example.
- `../../docs/09-schema-governance/` — Schema governance, including how usage analytics from
  the OTel pipeline feed into Hive's usage-informed breaking change detection.

---

## Key Design Decisions

**OTel Collector as intermediary (not direct export)**
Apollo Router exports traces to the OTel Collector rather than directly to Jaeger or Tempo. This
indirection is intentional: the Collector applies tail-based sampling before forwarding to the
trace backend. Without the Collector, every trace would be sent to Jaeger (100% sampling), which
is expensive to store and query at production traffic volumes. With the Collector's tail-based
sampler, only errors and slow requests are guaranteed to be stored; fast successful requests are
sampled at 10%, reducing storage by ~90% while preserving full fidelity for the requests that
matter.

**Deployment (not DaemonSet) for the Collector**
The OTel Collector runs as a Deployment (2 replicas) rather than a DaemonSet. For the Apollo
Router workload, which is typically concentrated on a small number of large instances, a
Deployment provides equivalent coverage with far fewer collector pods. A DaemonSet would run one
collector pod per node across the entire cluster, most of which would receive no router traffic.
See `otel-collector-config.md` for the detailed rationale.

**W3C trace context propagation**
All trace context propagation uses the W3C `traceparent`/`tracestate` headers (not Jaeger's
`uber-trace-id` or Zipkin's `b3` headers). W3C trace context is the OTel standard and is
supported by all major tracing backends and instrumentation libraries. Using a single propagation
format across the router and all subgraphs ensures clean parent-child span relationships in the
trace UI without requiring format translation.
