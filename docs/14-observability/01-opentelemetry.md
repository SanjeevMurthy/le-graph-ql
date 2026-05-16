# 01 — OpenTelemetry for GraphQL

> **Purpose**
> This document covers end-to-end OpenTelemetry instrumentation for a federated GraphQL platform: Apollo Router native OTLP configuration, OTel SDK setup for Node.js, Java, and Go subgraphs, OTel Collector DaemonSet deployment, head-based and tail-based sampling strategies, trace context propagation across subgraph boundaries, resource attribute conventions, and OTLP exporter tuning. Written for platform engineers and SREs who own the instrumentation layer.

---

## Learning Objectives

After reading this document you will be able to:

1. Configure Apollo Router to emit traces and metrics via OTLP without an additional SDK.
2. Instrument Node.js, Java, and Go subgraphs using language-specific OTel SDKs with both auto-instrumentation and manual spans.
3. Deploy and configure an OTel Collector DaemonSet that receives, processes, and exports telemetry to Tempo, Prometheus, and Loki.
4. Choose and configure head-based or tail-based sampling strategies for cost-effective trace retention.
5. Verify that trace context (W3C TraceContext headers) propagates correctly across the router-to-subgraph boundary.
6. Apply consistent resource attributes across all telemetry producers so that traces, metrics, and logs are co-indexable.

---

## Apollo Router Native OTel Configuration

Apollo Router (v1.40+) ships with a built-in OpenTelemetry subsystem. No external SDK or agent is required for the router process itself. All configuration lives in `router.yaml`.

### Minimal OTLP Configuration

```yaml
# router.yaml
telemetry:
  exporters:
    tracing:
      otlp:
        enabled: true
        endpoint: "http://otel-collector.observability.svc.cluster.local:4317"
        protocol: grpc
        grpc:
          timeout_secs: 5
    metrics:
      otlp:
        enabled: true
        endpoint: "http://otel-collector.observability.svc.cluster.local:4317"
        protocol: grpc

  # Resource attributes applied to all spans and metrics from this router instance
  resource:
    service.name: "apollo-router"
    service.version: "${ROUTER_VERSION}"
    deployment.environment: "${ENVIRONMENT}"   # production | staging | development
    k8s.cluster.name: "${CLUSTER_NAME}"
    k8s.namespace.name: "${POD_NAMESPACE}"
    k8s.pod.name: "${POD_NAME}"
    k8s.node.name: "${NODE_NAME}"
```

### Full Telemetry Block — Traces, Metrics, and Instruments

```yaml
# router.yaml — complete telemetry section for production
telemetry:
  instrumentation:
    spans:
      router:
        attributes:
          # Capture the operation name on the root span
          graphql.operation.name:
            request_header: "apollographql-client-name"
          graphql.operation.type: true
          graphql.document.hash: true          # SHA-256 of normalized document
          http.request.method: true
          http.response.status_code: true
          client.id:
            request_header: "x-client-id"
          client.version:
            request_header: "x-client-version"

      subgraph:
        attributes:
          subgraph.name: true
          subgraph.operation.name: true
          http.response.status_code: true
          graphql.error.count:
            response_body: "$.errors.length()"

    instruments:
      router:
        http.server.request.duration: true     # latency histogram per operation
        http.server.request.body.size: true
        graphql.router.cache.hit: true
        graphql.router.query_planning.time: true

      subgraph:
        http.client.request.duration: true     # per-subgraph fetch latency

  exporters:
    tracing:
      otlp:
        enabled: true
        endpoint: "http://otel-collector.observability.svc.cluster.local:4317"
        protocol: grpc
        grpc:
          timeout_secs: 5
          headers:
            x-tenant-id: "${TENANT_ID}"
        batch_processor:
          max_export_batch_size: 512
          max_queue_size: 2048
          scheduled_delay_millis: 5000
          max_export_timeout_millis: 30000

    metrics:
      prometheus:
        enabled: true
        listen: "0.0.0.0:9090"
        path: "/metrics"
      otlp:
        enabled: true
        endpoint: "http://otel-collector.observability.svc.cluster.local:4317"
        protocol: grpc
        temporality: delta   # Use delta for Prometheus remote_write compatibility

  resource:
    service.name: "apollo-router"
    service.version: "${ROUTER_VERSION}"
    deployment.environment: "${ENVIRONMENT}"
    k8s.cluster.name: "${CLUSTER_NAME}"
    k8s.namespace.name: "${POD_NAMESPACE}"
    k8s.pod.name: "${POD_NAME}"
    k8s.node.name: "${NODE_NAME}"
```

### Sampling at the Router Level

Apollo Router supports head-based sampling natively. Configure a sampling ratio per environment:

```yaml
telemetry:
  exporters:
    tracing:
      otlp:
        enabled: true
        endpoint: "http://otel-collector.observability.svc.cluster.local:4317"
      common:
        sampler: "parentbased_traceidratio"
        sampler_arg: "0.05"   # 5% head-based sampling in production
        # For tail-based sampling, set sampler to "always_on" here
        # and configure the OTel Collector tail_sampling processor
```

---

## Node.js Subgraph SDK Setup

### Dependencies

```bash
npm install \
  @opentelemetry/sdk-node \
  @opentelemetry/auto-instrumentations-node \
  @opentelemetry/exporter-trace-otlp-grpc \
  @opentelemetry/exporter-metrics-otlp-grpc \
  @opentelemetry/sdk-metrics \
  @opentelemetry/resources \
  @opentelemetry/semantic-conventions
```

### Instrumentation Bootstrap — `tracing.ts`

This file must be loaded before any application code using `--require ./tracing.js` or `NODE_OPTIONS=--require ./tracing.js`.

```typescript
// src/tracing.ts
import { NodeSDK } from '@opentelemetry/sdk-node';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-grpc';
import { OTLPMetricExporter } from '@opentelemetry/exporter-metrics-otlp-grpc';
import { PeriodicExportingMetricReader } from '@opentelemetry/sdk-metrics';
import { Resource } from '@opentelemetry/resources';
import {
  SEMRESATTRS_SERVICE_NAME,
  SEMRESATTRS_SERVICE_VERSION,
  SEMRESATTRS_DEPLOYMENT_ENVIRONMENT,
} from '@opentelemetry/semantic-conventions';
import { BatchSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { credentials } from '@grpc/grpc-js';

const resource = Resource.default().merge(
  new Resource({
    [SEMRESATTRS_SERVICE_NAME]: process.env.OTEL_SERVICE_NAME ?? 'products-subgraph',
    [SEMRESATTRS_SERVICE_VERSION]: process.env.SERVICE_VERSION ?? '0.0.0',
    [SEMRESATTRS_DEPLOYMENT_ENVIRONMENT]: process.env.ENVIRONMENT ?? 'development',
    'k8s.cluster.name': process.env.CLUSTER_NAME ?? 'local',
    'k8s.namespace.name': process.env.POD_NAMESPACE ?? 'default',
    'k8s.pod.name': process.env.POD_NAME ?? 'unknown',
    'subgraph.name': process.env.SUBGRAPH_NAME ?? 'products',
  })
);

const collectorEndpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT
  ?? 'http://localhost:4317';

const traceExporter = new OTLPTraceExporter({
  url: collectorEndpoint,
  credentials: credentials.createInsecure(),
});

const metricExporter = new OTLPMetricExporter({
  url: collectorEndpoint,
  credentials: credentials.createInsecure(),
});

const sdk = new NodeSDK({
  resource,
  spanProcessor: new BatchSpanProcessor(traceExporter, {
    maxExportBatchSize: 512,
    maxQueueSize: 2048,
    scheduledDelayMillis: 5000,
  }),
  metricReader: new PeriodicExportingMetricReader({
    exporter: metricExporter,
    exportIntervalMillis: 15_000,
  }),
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-fs': { enabled: false },  // Too noisy
      '@opentelemetry/instrumentation-http': {
        requestHook: (span, request) => {
          // Suppress health check noise
          if ('path' in request && request.path === '/health') {
            span.setAttribute('sampling.priority', 0);
          }
        },
      },
      '@opentelemetry/instrumentation-pg': { enhancedDatabaseReporting: false },
    }),
  ],
});

sdk.start();

process.on('SIGTERM', () => {
  sdk.shutdown()
    .then(() => process.exit(0))
    .catch(() => process.exit(1));
});
```

### Manual Resolver Spans — GraphQL Yoga / Apollo Server

```typescript
// src/plugins/tracing-plugin.ts
import { Plugin } from 'graphql-yoga';
import { trace, SpanStatusCode, context, propagation } from '@opentelemetry/api';

const tracer = trace.getTracer('graphql-resolvers', '1.0.0');

export function resolverTracingPlugin(): Plugin {
  return {
    onExecute({ args }) {
      const operationName = args.operationName ?? 'anonymous';
      const operationType = args.document.definitions
        .find((d): d is OperationDefinitionNode => d.kind === 'OperationDefinition')
        ?.operation ?? 'query';

      return {
        onResolverCalled({ info, args: resolverArgs }) {
          // Only instrument non-trivial resolvers (skip scalar field resolution)
          if (info.parentType.name === '__Schema' || info.parentType.name === '__Type') {
            return;
          }

          const span = tracer.startSpan(`resolver ${info.parentType.name}.${info.fieldName}`, {
            attributes: {
              'graphql.field.name': info.fieldName,
              'graphql.field.path': info.path.join('.'),
              'graphql.parent_type': info.parentType.name,
              'graphql.operation.name': operationName,
              'graphql.operation.type': operationType,
            },
          });

          return {
            onResolverDone({ result, error }) {
              if (error) {
                span.recordException(error);
                span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
              }
              span.end();
            },
          };
        },
      };
    },
  };
}
```

### DataLoader Span Instrumentation

```typescript
// src/dataloaders/product-loader.ts
import DataLoader from 'dataloader';
import { trace, SpanStatusCode } from '@opentelemetry/api';

const tracer = trace.getTracer('dataloader', '1.0.0');

export function createProductLoader(db: Database): DataLoader<string, Product> {
  return new DataLoader<string, Product>(
    async (ids: readonly string[]) => {
      const span = tracer.startSpan('dataloader.batch products', {
        attributes: {
          'dataloader.name': 'ProductLoader',
          'dataloader.batch_size': ids.length,
          'dataloader.keys': ids.slice(0, 10).join(','), // Sample first 10 for debugging
        },
      });

      try {
        const products = await db.query(
          'SELECT * FROM products WHERE id = ANY($1)',
          [ids]
        );

        // Preserve DataLoader contract: return results in same order as keys
        const productMap = new Map(products.map((p) => [p.id, p]));
        const ordered = ids.map((id) => productMap.get(id) ?? new Error(`Product ${id} not found`));

        span.setAttribute('dataloader.cache_hit_count', ids.length - products.length);
        span.end();
        return ordered;
      } catch (error) {
        span.recordException(error as Error);
        span.setStatus({ code: SpanStatusCode.ERROR });
        span.end();
        throw error;
      }
    },
    {
      maxBatchSize: 500,
      cache: true,
    }
  );
}
```

---

## Java Subgraph SDK Setup (Spring Boot)

### Maven Dependencies

```xml
<!-- pom.xml -->
<dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>io.opentelemetry</groupId>
      <artifactId>opentelemetry-bom</artifactId>
      <version>1.38.0</version>
      <type>pom</type>
      <scope>import</scope>
    </dependency>
  </dependencies>
</dependencyManagement>

<dependencies>
  <dependency>
    <groupId>io.opentelemetry.instrumentation</groupId>
    <artifactId>opentelemetry-spring-boot-starter</artifactId>
    <version>2.5.0-alpha</version>
  </dependency>
  <dependency>
    <groupId>io.opentelemetry</groupId>
    <artifactId>opentelemetry-exporter-otlp</artifactId>
  </dependency>
</dependencies>
```

### Application Properties

```yaml
# application.yaml
otel:
  exporter:
    otlp:
      endpoint: "${OTEL_EXPORTER_OTLP_ENDPOINT:http://localhost:4317}"
      protocol: grpc
  resource:
    attributes:
      service.name: "${OTEL_SERVICE_NAME:orders-subgraph}"
      service.version: "@project.version@"
      deployment.environment: "${ENVIRONMENT:development}"
      k8s.cluster.name: "${CLUSTER_NAME:local}"
      k8s.namespace.name: "${POD_NAMESPACE:default}"
      k8s.pod.name: "${POD_NAME:unknown}"
      subgraph.name: "orders"
  traces:
    sampler: parentbased_always_on   # Tail sampling in Collector
    exporter: otlp
  metrics:
    exporter: otlp
  logs:
    exporter: otlp

spring:
  application:
    name: orders-subgraph
```

### Manual Resolver Instrumentation — DGS Framework

```java
// src/main/java/com/example/orders/resolvers/OrderFetcher.java
package com.example.orders.resolvers;

import com.netflix.graphql.dgs.DgsComponent;
import com.netflix.graphql.dgs.DgsQuery;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;

@DgsComponent
public class OrderFetcher {

    private static final Tracer tracer = GlobalOpenTelemetry.getTracer("graphql-resolvers", "1.0.0");

    @DgsQuery
    public List<Order> orders(DataFetchingEnvironment env) {
        String clientId = env.getGraphQlContext().get("clientId");

        Span span = tracer.spanBuilder("resolver Query.orders")
            .setAttribute("graphql.field.name", "orders")
            .setAttribute("graphql.parent_type", "Query")
            .setAttribute("client.id", clientId != null ? clientId : "unknown")
            .startSpan();

        try (Scope scope = span.makeCurrent()) {
            List<Order> orders = orderService.findByClientId(clientId);
            span.setAttribute("graphql.result.count", orders.size());
            return orders;
        } catch (Exception e) {
            span.recordException(e);
            span.setStatus(StatusCode.ERROR, e.getMessage());
            throw e;
        } finally {
            span.end();
        }
    }
}
```

---

## Go Subgraph SDK Setup

### Module Dependencies

```go
// go.mod additions
require (
    go.opentelemetry.io/otel v1.28.0
    go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.28.0
    go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc v1.28.0
    go.opentelemetry.io/otel/sdk v1.28.0
    go.opentelemetry.io/otel/sdk/metric v1.28.0
    go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.53.0
    go.opentelemetry.io/contrib/instrumentation/database/sql/otelsql v0.53.0
)
```

### Bootstrap — `otel.go`

```go
// internal/observability/otel.go
package observability

import (
    "context"
    "os"
    "time"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
    "go.opentelemetry.io/otel/sdk/metric"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
    "google.golang.org/grpc"
    "google.golang.org/grpc/credentials/insecure"
)

func InitOTel(ctx context.Context) (shutdown func(context.Context) error, err error) {
    collectorEndpoint := getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317")

    conn, err := grpc.DialContext(ctx, collectorEndpoint,
        grpc.WithTransportCredentials(insecure.NewCredentials()),
        grpc.WithBlock(),
    )
    if err != nil {
        return nil, err
    }

    res, err := resource.New(ctx,
        resource.WithAttributes(
            semconv.ServiceName(getenv("OTEL_SERVICE_NAME", "identity-subgraph")),
            semconv.ServiceVersion(getenv("SERVICE_VERSION", "0.0.0")),
            semconv.DeploymentEnvironment(getenv("ENVIRONMENT", "development")),
            semconv.K8SClusterName(getenv("CLUSTER_NAME", "local")),
            semconv.K8SNamespaceName(getenv("POD_NAMESPACE", "default")),
            semconv.K8SPodName(getenv("POD_NAME", "unknown")),
        ),
    )
    if err != nil {
        return nil, err
    }

    // Traces
    traceExporter, err := otlptracegrpc.New(ctx, otlptracegrpc.WithGRPCConn(conn))
    if err != nil {
        return nil, err
    }
    tp := sdktrace.NewTracerProvider(
        sdktrace.WithResource(res),
        sdktrace.WithBatcher(traceExporter,
            sdktrace.WithMaxExportBatchSize(512),
            sdktrace.WithBatchTimeout(5*time.Second),
        ),
        sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.AlwaysSample())),
    )
    otel.SetTracerProvider(tp)

    // Metrics
    metricExporter, err := otlpmetricgrpc.New(ctx, otlpmetricgrpc.WithGRPCConn(conn))
    if err != nil {
        return nil, err
    }
    mp := metric.NewMeterProvider(
        metric.WithResource(res),
        metric.WithReader(metric.NewPeriodicReader(metricExporter,
            metric.WithInterval(15*time.Second),
        )),
    )
    otel.SetMeterProvider(mp)

    return func(ctx context.Context) error {
        if err := tp.Shutdown(ctx); err != nil {
            return err
        }
        return mp.Shutdown(ctx)
    }, nil
}

func getenv(key, fallback string) string {
    if v := os.Getenv(key); v != "" {
        return v
    }
    return fallback
}
```

---

## OTel Collector DaemonSet Configuration

Deploy the OTel Collector as a DaemonSet so that each node has a local Collector. Application pods send telemetry to `localhost:4317` (or to the pod IP via a hostPort), avoiding network hops and reducing latency.

### Kubernetes DaemonSet Manifest

```yaml
# kubernetes/otel-collector-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: otel-collector
  namespace: observability
  labels:
    app: otel-collector
spec:
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8888"
        prometheus.io/path: "/metrics"
    spec:
      hostNetwork: false
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.102.0
          args:
            - "--config=/etc/otelcol/config.yaml"
          ports:
            - name: otlp-grpc
              containerPort: 4317
              hostPort: 4317
            - name: otlp-http
              containerPort: 4318
              hostPort: 4318
            - name: prometheus
              containerPort: 8888
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          resources:
            requests:
              cpu: 200m
              memory: 400Mi
            limits:
              cpu: 1000m
              memory: 1Gi
          volumeMounts:
            - name: config
              mountPath: /etc/otelcol
          livenessProbe:
            httpGet:
              path: /
              port: 13133
            initialDelaySeconds: 10
          readinessProbe:
            httpGet:
              path: /
              port: 13133
            initialDelaySeconds: 5
      volumes:
        - name: config
          configMap:
            name: otel-collector-config
      tolerations:
        - operator: Exists
          effect: NoSchedule
```

### Collector ConfigMap — Full Pipeline

```yaml
# kubernetes/otel-collector-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
            max_recv_msg_size_mib: 64
          http:
            endpoint: 0.0.0.0:4318
      # Scrape Collector's own metrics
      prometheus:
        config:
          scrape_configs:
            - job_name: otel-collector
              static_configs:
                - targets: ["localhost:8888"]

    processors:
      batch:
        send_batch_size: 1024
        timeout: 10s
        send_batch_max_size: 2048

      memory_limiter:
        check_interval: 1s
        limit_mib: 850         # 85% of 1Gi container limit
        spike_limit_mib: 200

      # Scrub PII from span attributes before export
      transform/scrub_pii:
        error_mode: ignore
        trace_statements:
          - context: span
            statements:
              # Remove raw query variables — may contain PII
              - delete_key(attributes, "graphql.variables")
              # Replace user-identifying values with hashed equivalents
              - set(attributes["user.id"], SHA256(attributes["user.id"]))
                where attributes["user.id"] != nil

      # Enrich spans with k8s resource attributes
      resource:
        attributes:
          - action: upsert
            key: k8s.node.name
            value: "${NODE_NAME}"
          - action: upsert
            key: cloud.provider
            value: "aws"       # or gcp, azure

      # Tail-based sampling (see Sampling Strategies section)
      tail_sampling:
        decision_wait: 30s
        num_traces: 100000
        expected_new_traces_per_sec: 1000
        policies:
          - name: errors-policy
            type: status_code
            status_code:
              status_codes: [ERROR]
          - name: slow-traces
            type: latency
            latency:
              threshold_ms: 2000
          - name: graphql-mutations
            type: string_attribute
            string_attribute:
              key: "graphql.operation.type"
              values: ["mutation"]
          - name: probabilistic-baseline
            type: probabilistic
            probabilistic:
              sampling_percentage: 2   # 2% baseline of all other traces
          - name: composite
            type: composite
            composite:
              max_total_spans_per_second: 5000
              policy_order:
                - errors-policy
                - slow-traces
                - graphql-mutations
                - probabilistic-baseline

    exporters:
      # Traces → Grafana Tempo
      otlp/tempo:
        endpoint: "tempo.observability.svc.cluster.local:4317"
        tls:
          insecure: true
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s
          max_elapsed_time: 300s

      # Metrics → Prometheus remote_write (Mimir or Prometheus)
      prometheusremotewrite:
        endpoint: "http://mimir.observability.svc.cluster.local:9009/api/v1/push"
        tls:
          insecure: true
        resource_to_telemetry_conversion:
          enabled: true

      # Logs → Loki (if OTLP logs are used)
      loki:
        endpoint: "http://loki.observability.svc.cluster.local:3100/loki/api/v1/push"
        tls:
          insecure: true
        default_labels_enabled:
          exporter: false
          job: true
          instance: true
          level: true

      # Debug exporter — disable in production
      debug:
        verbosity: basic

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      pprof:
        endpoint: 0.0.0.0:1777

    service:
      extensions: [health_check, pprof]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, transform/scrub_pii, resource, tail_sampling, batch]
          exporters: [otlp/tempo]

        metrics:
          receivers: [otlp, prometheus]
          processors: [memory_limiter, resource, batch]
          exporters: [prometheusremotewrite]

        logs:
          receivers: [otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [loki]
```

---

## Sampling Strategies

### Head-Based Sampling

Head-based sampling makes the keep/drop decision at the start of the trace, before any spans are collected. It is simpler and cheaper but cannot guarantee that interesting traces (errors, slow spans) are retained.

**When to use:** Development and staging environments, or when cost is the primary constraint and you can afford to miss some interesting traces.

```
Application (SDK) ─→ sampler decides keep/drop ─→ Collector receives only kept traces
```

**Apollo Router configuration:**
```yaml
telemetry:
  exporters:
    tracing:
      common:
        sampler: "parentbased_traceidratio"
        sampler_arg: "0.10"   # 10% of traces in staging
```

**Node.js SDK configuration:**
```typescript
import { TraceIdRatioBasedSampler, ParentBasedSampler } from '@opentelemetry/sdk-trace-base';

const sdk = new NodeSDK({
  sampler: new ParentBasedSampler({
    root: new TraceIdRatioBasedSampler(0.10),  // 10%
  }),
  // ...
});
```

### Tail-Based Sampling

Tail-based sampling buffers complete traces in the OTel Collector before making the sampling decision. It can guarantee 100% retention of error traces and slow traces.

**When to use:** Production environments where cost control AND complete error/latency trace retention are both required.

**Architecture:**

```mermaid
flowchart LR
    APP[Application\nsampler=always_on] -->|100% of spans| COLL[OTel Collector\ntail_sampling processor]
    COLL -->|30s buffer| DECIDE{Sampling\nDecision}
    DECIDE -->|errors / slow / mutations| TEMPO[Tempo\n100% retained]
    DECIDE -->|2% baseline| TEMPO
    DECIDE -->|dropped| DROP[/dev/null]
```

**Key tuning parameters for the `tail_sampling` processor:**

| Parameter | Recommended | Notes |
|-----------|-------------|-------|
| `decision_wait` | 30s | Must exceed max expected trace duration + clock skew |
| `num_traces` | 100000 | In-memory buffer size; ~1KB per trace = 100MB RAM |
| `expected_new_traces_per_sec` | Set to actual RPS | Drives buffer allocation |

### Sampling Strategy Comparison

| Dimension | Head-Based | Tail-Based |
|-----------|------------|------------|
| Decision point | Trace start | Trace completion |
| Guarantees error traces | No | Yes |
| Memory overhead | None (app-side) | High (Collector buffer) |
| Complexity | Low | Medium-High |
| Collector requirement | Optional | Required |
| Cost at 10k RPS | Low | Medium |
| Recommended for | Dev / staging | Production |

---

## Trace Context Propagation

### W3C TraceContext Standard

Apollo Router propagates trace context using the W3C TraceContext standard (RFC 7540). The `traceparent` header carries the trace ID, parent span ID, and sampling flag between the router and each subgraph.

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             ^^  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^^^^^^^^^^^^  ^^
             version  trace-id (128-bit hex)       parent-id (64-bit) flags
```

### Verifying Propagation

Use the Apollo Router's request debugging headers in a development environment to confirm trace context is propagated to subgraphs:

```bash
# Check that traceparent header is forwarded to subgraph
curl -v -X POST http://localhost:4000/graphql \
  -H "Content-Type: application/json" \
  -H "traceparent: 00-aaaabbbbccccddddaaaabbbbccccdddd-0011223344556677-01" \
  -d '{"query": "{ products { id } }", "operationName": "GetProducts"}'

# Check the router debug log for subgraph request headers:
# {"level":"debug","message":"Sending subgraph request",
#  "subgraph":"products",
#  "headers":{"traceparent":"00-aaaabbbbccccddddaaaabbbbccccdddd-<new-span-id>-01"}}
```

### Baggage Propagation

Use W3C Baggage to carry operation-level context to subgraphs without modifying span attributes:

```typescript
// In the router Rhai plugin or upstream middleware:
// Set baggage so subgraphs know the operation name and client ID
// without parsing the GraphQL document themselves.

// Node.js subgraph — read baggage from incoming request context
import { propagation, context } from '@opentelemetry/api';

function extractBaggageMiddleware(req: Request, res: Response, next: NextFunction) {
  const ctx = propagation.extract(context.active(), req.headers);
  const baggage = propagation.getBaggage(ctx);

  if (baggage) {
    const operationName = baggage.getEntry('graphql.operation.name')?.value;
    const clientId = baggage.getEntry('client.id')?.value;
    req.graphqlContext = { operationName, clientId };
  }
  next();
}
```

### Configuration — Apollo Router Baggage Forwarding

```yaml
# router.yaml
headers:
  subgraphs:
    all:
      request:
        - propagate:
            named: "traceparent"
        - propagate:
            named: "tracestate"
        - propagate:
            named: "baggage"
```

---

## Resource Attribute Conventions

Consistent resource attributes across all services enable cross-service trace correlation and dashboard filtering. Use the OpenTelemetry Semantic Conventions as the primary reference.

| Attribute | Source | Values | Notes |
|-----------|--------|--------|-------|
| `service.name` | SDK resource | `apollo-router`, `products-subgraph` | Must be unique per service |
| `service.version` | SDK resource | Semantic version string | From `package.json` / `pom.xml` |
| `deployment.environment` | SDK resource | `production`, `staging`, `development` | Drives alert routing |
| `k8s.cluster.name` | Downward API env | e.g., `prod-us-east-1` | Required for multi-cluster setups |
| `k8s.namespace.name` | Downward API env | e.g., `graphql-platform` | |
| `k8s.pod.name` | Downward API env | Pod name | For per-pod debugging |
| `k8s.node.name` | Downward API env | Node hostname | For node-level saturation |
| `subgraph.name` | Manual resource | e.g., `products`, `orders` | GraphQL-specific; not in OTel semconv |
| `cloud.provider` | Manual resource | `aws`, `gcp`, `azure` | For cloud-specific debugging |
| `cloud.region` | Manual resource | e.g., `us-east-1` | For multi-region alerting |

### Kubernetes Downward API — Inject Resource Attributes via Env

```yaml
# kubernetes/deployment.yaml (subgraph Deployment)
env:
  - name: OTEL_SERVICE_NAME
    value: "products-subgraph"
  - name: OTEL_SERVICE_VERSION
    value: "1.4.2"
  - name: ENVIRONMENT
    value: "production"
  - name: CLUSTER_NAME
    value: "prod-us-east-1"
  - name: SUBGRAPH_NAME
    value: "products"
  - name: POD_NAMESPACE
    valueFrom:
      fieldRef:
        fieldPath: metadata.namespace
  - name: POD_NAME
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
  - name: NODE_NAME
    valueFrom:
      fieldRef:
        fieldPath: spec.nodeName
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://$(NODE_NAME):4317"  # Send to DaemonSet Collector on same node
```

---

## OTLP Exporter Tuning

### Batch Processor Settings

| Setting | Default | Production Recommendation | Notes |
|---------|---------|--------------------------|-------|
| `max_export_batch_size` | 512 | 512–1024 | Higher = fewer RPCs, more memory |
| `max_queue_size` | 2048 | 4096–8192 | Increase if exporter falls behind |
| `scheduled_delay_millis` | 5000 | 5000 | 5s is a good balance |
| `max_export_timeout_millis` | 30000 | 30000 | Must exceed network RTT |

### Compression

Enable gzip compression to reduce network bandwidth between applications and the Collector:

```typescript
// Node.js — enable gzip
import { CompressionAlgorithm } from '@opentelemetry/otlp-exporter-base';

const exporter = new OTLPTraceExporter({
  url: 'http://localhost:4317',
  compression: CompressionAlgorithm.GZIP,
});
```

```yaml
# OTel Collector — accept compressed payloads (default behavior, no config needed)
# Compress outbound exports:
exporters:
  otlp/tempo:
    endpoint: "tempo.observability.svc.cluster.local:4317"
    compression: gzip
```

### Retry and Circuit Breaking

```yaml
# OTel Collector exporter retry configuration
exporters:
  otlp/tempo:
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      randomization_factor: 0.5
      multiplier: 1.5
      max_interval: 30s
      max_elapsed_time: 300s   # Give up after 5 minutes of retries
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000         # Buffered spans during transient Tempo outage
```

---

## Validation Checklist

After deploying instrumentation, verify the following:

```
[ ] Apollo Router emits spans to the OTel Collector (check Collector logs for received spans)
[ ] Each subgraph appears as a child span of the router root span (verify in Tempo)
[ ] traceparent header is present in subgraph request logs
[ ] DataLoader batch spans appear with dataloader.batch_size attribute
[ ] Error traces include span events with exception.type and exception.message
[ ] PII scrubbing: graphql.variables attribute is absent from exported spans
[ ] Resource attributes include service.name, deployment.environment, k8s.pod.name
[ ] Metrics appear in Prometheus: query graphql_router_http_requests_total
[ ] Tail sampling: error traces are always retained (inject a test error and verify)
[ ] Memory usage of OTel Collector stays below 85% of limit under load
```

---

## Related Topics

- [02-distributed-tracing.md](./02-distributed-tracing.md) — Trace schema design, TraceQL, Tempo deployment
- [03-metrics.md](./03-metrics.md) — Metric taxonomy, recording rules, Grafana dashboards
- [05-slos-and-alerting.md](./05-slos-and-alerting.md) — SLO definitions and alert rule configuration
- [Federation](../07-federation/README.md) — Subgraph topology (defines trace structure)
- [Security Overview](../05-security/README.md) — PII handling and variable scrubbing policy

---

## References

- [OpenTelemetry Specification](https://opentelemetry.io/docs/specs/otel/)
- [OpenTelemetry Collector Configuration](https://opentelemetry.io/docs/collector/configuration/)
- [Apollo Router Telemetry Configuration](https://www.apollographql.com/docs/router/configuration/telemetry/overview)
- [W3C TraceContext Specification](https://www.w3.org/TR/trace-context/)
- [OTel Node.js SDK](https://opentelemetry.io/docs/languages/js/)
- [OTel Java Instrumentation](https://opentelemetry.io/docs/languages/java/instrumentation/)
- [OTel Go SDK](https://opentelemetry.io/docs/languages/go/)
- [OTel Semantic Conventions — Resource](https://opentelemetry.io/docs/specs/semconv/resource/)
- [Tail Sampling Processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor)
