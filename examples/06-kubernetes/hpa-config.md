# Horizontal Pod Autoscaling for Apollo Router

> Companion doc: [../../docs/15-kubernetes-deployment/](../../docs/15-kubernetes-deployment/)

This file covers four autoscaling approaches for the Apollo Router, progressing from simple
to sophisticated: standard CPU/memory HPA, custom metrics HPA via Prometheus Adapter, KEDA
ScaledObject as an HPA alternative, and VPA for subgraphs. It also covers the Prometheus
Adapter installation and scale behavior tuning to prevent flapping.

For the base Deployment manifest that these HPA resources target, see
[router-deployment.md](./router-deployment.md).

---

## 1. Standard HPA v2 — CPU and Memory Baseline

The standard HPA scales on CPU and memory utilization reported by the Metrics Server.
This is the lowest-friction starting point. It is not the most precise signal for a
GraphQL router (which is IO-bound, not CPU-bound during normal operation), but it is
universally available and works without additional infrastructure.

```yaml
# router-hpa-standard.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: apollo-router-hpa
  namespace: graphql-platform
  labels:
    app.kubernetes.io/name: apollo-router
    app.kubernetes.io/part-of: graphql-platform
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: apollo-router

  # minReplicas: never scale below 3 for a production service.
  # 3 replicas provides: (a) fault tolerance across 3 AZs, (b) PodDisruptionBudget
  # compliance (minAvailable: 2 requires at least 3 pods to tolerate a single drain),
  # (c) a baseline warm cache (APQ, query plan cache) across replicas.
  minReplicas: 3

  # maxReplicas: upper bound on autoscaling. Set this to a value your cluster can
  # actually schedule — check available node capacity and node autoscaler limits.
  # 20 pods at 500m CPU request = 10 CPU cores required; ensure your node pool can grow.
  maxReplicas: 20

  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          # averageUtilization: 60 means scale up when average CPU across all pods
          # exceeds 60% of the request (500m * 0.6 = 300m per pod).
          # Lower targets (e.g., 50%) scale up earlier with more headroom but
          # result in more pods at idle. 60% is a good balance for latency-sensitive
          # services — you want capacity before saturation, not at saturation.
          averageUtilization: 60

    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          # averageUtilization: 70 for memory. Memory scaling is less reactive
          # than CPU — allocating memory does not immediately indicate a spike.
          # 70% gives the router room to grow its in-process caches before
          # triggering a scale-out.
          # Note: if you are using Redis for APQ and query plan caches, memory
          # pressure is unlikely to be the primary scaling signal. Include it
          # anyway as a safety net for unexpected allocation growth.
          averageUtilization: 70

  behavior:
    scaleUp:
      # stabilizationWindowSeconds: wait this long after a scale-up event before
      # considering another scale-up. 60s gives newly started pods time to become
      # Ready and start handling traffic before the HPA recalculates desired replicas.
      # Without this, the HPA would keep scaling up while new pods are still initializing.
      stabilizationWindowSeconds: 60

      policies:
        # Add up to 4 pods per 60-second window during a scale-up event.
        # This is fast enough to handle a traffic spike (most spikes ramp over minutes)
        # without hammering your cluster with too many simultaneous pod starts.
        - type: Pods
          value: 4
          periodSeconds: 60
        # Also allow scaling by 100% of current replica count if that is faster.
        # This handles exponential traffic growth (e.g., viral event) where adding
        # 4 pods at a time would be too slow.
        - type: Percent
          value: 100
          periodSeconds: 60
      # selectPolicy: Max means the HPA picks whichever policy allows the larger
      # scale-up. This gives you both fast percentage-based growth AND a minimum
      # of 4 pods per window.
      selectPolicy: Max

    scaleDown:
      # stabilizationWindowSeconds: this is the most important tuning parameter
      # for preventing flapping. The HPA waits 300s (5 minutes) after the last
      # scale-down trigger before computing the desired replica count for a scale-down.
      # This means if traffic spikes briefly, the router does not immediately
      # scale back down and then up again when the next spike arrives.
      # 300s is conservative — use 600s if you see frequent flapping.
      stabilizationWindowSeconds: 300

      policies:
        # Remove at most 1 pod per 120-second window during scale-down.
        # Slow scale-down is asymmetric with fast scale-up by design:
        # the cost of scaling down too fast (latency spikes when traffic returns)
        # is higher than the cost of running a few extra pods (wasted compute).
        # See "Scale behavior tuning" section for the rationale on this asymmetry.
        - type: Pods
          value: 1
          periodSeconds: 120
      selectPolicy: Min
      # selectPolicy: Min ensures the most conservative policy is applied.
      # Combined with a single policy, this enforces the 1-pod-per-120s limit strictly.
```

---

## 2. Custom Metrics HPA — Scale on Request Rate

CPU utilization is an imprecise proxy for GraphQL router load. A router serving many
simple queries may use less CPU than one serving few complex queries with large responses.
A better signal is the actual request rate: `apollo_router_http_requests_total`.

This section shows how to expose that Prometheus metric to the Kubernetes HPA via the
Prometheus Adapter.

### Prometheus Adapter ConfigMap — metric mapping rule

```yaml
# prometheus-adapter-configmap.yaml
# This ConfigMap is consumed by the Prometheus Adapter deployment.
# It defines how to translate Prometheus metric queries into Kubernetes custom metrics.
apiVersion: v1
kind: ConfigMap
metadata:
  name: adapter-config
  # Install the adapter in the monitoring namespace alongside Prometheus.
  namespace: monitoring
data:
  config.yaml: |
    rules:
      # Custom metric: http_requests_per_second
      # This rule transforms apollo_router_http_requests_total (a counter) into
      # a per-second rate (a gauge) that the HPA can use directly.
      - seriesQuery: 'apollo_router_http_requests_total{namespace!="",pod!=""}'
        # resources: map Prometheus label names to Kubernetes resource types.
        # namespace and pod labels in the Prometheus metric correspond to
        # k8s.namespace and k8s.pod resources. This enables the HPA to get
        # per-pod values and compute the average across the Deployment.
        resources:
          overrides:
            namespace:
              resource: namespace
            pod:
              resource: pod
        # name: defines the custom metric name as it appears in the Kubernetes API.
        # The HPA will reference this as pods/http_requests_per_second.
        name:
          matches: "^(.*)_total$"
          # as: rewrite the metric name. "_total" suffix (counter convention)
          # is replaced with "_per_second" to signal that this is a rate.
          as: "${1}_per_second"
        # metricsQuery: the PromQL expression used to compute the metric value.
        # rate over 2m provides a smoothed rate that is less spiky than instant rate.
        # <<.LabelMatchers>> is replaced by the Adapter with label selectors that
        # scope the query to the specific namespace and pod.
        metricsQuery: 'rate(<<.Series>>{<<.LabelMatchers>>}[2m])'

      # Custom metric: graphql_persisted_query_cache_hit_rate
      # Cache hit rate is useful for capacity planning but is less useful as
      # an HPA signal (it does not directly correlate with load). Include it
      # as an informational custom metric accessible via kubectl.
      - seriesQuery: 'apollo_router_cache_hit_total{namespace!="",pod!=""}'
        resources:
          overrides:
            namespace:
              resource: namespace
            pod:
              resource: pod
        name:
          matches: "^(.*)_total$"
          as: "${1}_per_second"
        metricsQuery: 'rate(<<.Series>>{<<.LabelMatchers>>}[2m])'
```

### HPA using the custom request-rate metric

```yaml
# router-hpa-custom-metrics.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: apollo-router-hpa-rps
  namespace: graphql-platform
  labels:
    app.kubernetes.io/name: apollo-router
    app.kubernetes.io/part-of: graphql-platform
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: apollo-router

  minReplicas: 3
  maxReplicas: 20

  metrics:
    # Combine CPU with the custom RPS metric.
    # The HPA always scales to satisfy ALL metrics — it takes the maximum of the
    # desired replica counts calculated from each metric. This means:
    # - CPU at 80% (suggests 4 pods needed) + RPS at 200 req/s (suggests 5 pods needed) -> scale to 5
    # - CPU at 20% (suggests 1 pod needed) + RPS at 150 req/s (suggests 4 pods needed) -> scale to 4
    # This composite approach handles both CPU-bound scenarios (complex queries) and
    # IO-bound scenarios (many simple queries).
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60

    - type: Pods
      pods:
        metric:
          # Name must match the "as" value in the Prometheus Adapter config.
          name: apollo_router_http_requests_per_second
        target:
          type: AverageValue
          # averageValue: 100 means scale up when each pod is handling more than
          # 100 requests/second on average. Adjust this based on your router's
          # observed throughput per pod from load testing.
          # At 500m CPU request, Apollo Router typically handles 200-500 req/s
          # for simple queries, 50-100 req/s for complex federated queries.
          # 100 req/s per pod is a conservative target that provides headroom.
          averageValue: "100"

  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 4
          periodSeconds: 60
        - type: Percent
          value: 100
          periodSeconds: 60
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 120
      selectPolicy: Min
```

### Verify the custom metric is available

```bash
# Check that the Prometheus Adapter is serving the custom metric
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1" | jq '.resources[].name' | grep router

# Query the current metric value
kubectl get --raw \
  "/apis/custom.metrics.k8s.io/v1beta1/namespaces/graphql-platform/pods/*/apollo_router_http_requests_per_second" \
  | jq '.items[] | {pod: .describedObject.name, value: .value}'
```

---

## 3. KEDA ScaledObject — Alternative to Custom HPA

KEDA (Kubernetes Event-Driven Autoscaling) is a superset of the standard HPA. It supports
the same Kubernetes-native HPA behavior but adds support for external event sources
(Kafka, SQS, Prometheus, etc.) with simpler configuration than the Prometheus Adapter approach.

Use KEDA if you are already running it in your cluster or if you need to scale on multiple
external metrics simultaneously. KEDA creates and manages an underlying HPA for you.

```yaml
# router-keda-scaledobject.yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: apollo-router-keda
  namespace: graphql-platform
  labels:
    app.kubernetes.io/name: apollo-router
    app.kubernetes.io/part-of: graphql-platform
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: apollo-router

  # pollingInterval: how often KEDA polls the external metric source.
  # 15s matches the Prometheus scrape interval so you are not polling faster
  # than data is available. Polling faster than the scrape interval gives
  # stale data every other poll, which is wasteful.
  pollingInterval: 15

  # cooldownPeriod: seconds after the last active event before scaling to zero.
  # For a production API, minReplicaCount: 3 means cooldownPeriod is only relevant
  # if you set minReplicaCount: 0 for a dev/staging environment.
  # In production keep minReplicaCount >= 3 and this field has no practical effect.
  cooldownPeriod: 300

  minReplicaCount: 3
  maxReplicaCount: 20

  # advanced: fine-grained HPA behavior, same semantics as the HPA v2 behavior block.
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:
          stabilizationWindowSeconds: 60
          policies:
            - type: Pods
              value: 4
              periodSeconds: 60
            - type: Percent
              value: 100
              periodSeconds: 60
          selectPolicy: Max
        scaleDown:
          stabilizationWindowSeconds: 300
          policies:
            - type: Pods
              value: 1
              periodSeconds: 120
          selectPolicy: Min

  triggers:
    - type: prometheus
      metadata:
        # serverAddress: URL of your Prometheus instance.
        serverAddress: http://prometheus-operated.monitoring.svc.cluster.local:9090

        # metricName: a label for this trigger in KEDA's internal tracking.
        # Does not need to match the Prometheus metric name.
        metricName: apollo_router_rps

        # query: PromQL expression evaluated against Prometheus.
        # rate over 2m provides a smoothed rate. Sum across all pods in the
        # namespace, then divide by the number of pods to get per-pod average.
        # KEDA compares the threshold against this query result / current replicas.
        query: |
          sum(rate(apollo_router_http_requests_total{namespace="graphql-platform"}[2m]))

        # threshold: desired requests/second across the total deployment.
        # KEDA divides this by the per-pod target to determine desired replicas.
        # 300 total req/s / 100 per pod = 3 pods at baseline.
        # 1200 total req/s / 100 per pod = 12 pods at peak.
        threshold: "100"

        # ignoreNullValues: true means KEDA does not scale down to zero when
        # the metric returns no data (e.g., Prometheus is temporarily unavailable).
        # Default is true — change to false only in dev environments where you
        # want to scale to zero on idle.
        ignoreNullValues: "true"

    # Secondary trigger on CPU utilization via Prometheus metrics.
    # This handles CPU-bound scenarios (complex nested queries) that do not
    # show up in request rate but do cause latency degradation.
    - type: prometheus
      metadata:
        serverAddress: http://prometheus-operated.monitoring.svc.cluster.local:9090
        metricName: apollo_router_cpu_utilization
        query: |
          avg(
            rate(container_cpu_usage_seconds_total{
              namespace="graphql-platform",
              container="apollo-router"
            }[2m])
          ) / avg(
            kube_pod_container_resource_requests{
              namespace="graphql-platform",
              container="apollo-router",
              resource="cpu"
            }
          ) * 100
        # threshold: 60 means scale up when average CPU utilization exceeds 60%.
        # This matches the CPU averageUtilization target in the standard HPA.
        threshold: "60"
        ignoreNullValues: "true"
```

### When to choose KEDA vs. native HPA with Prometheus Adapter

| Criterion | KEDA | HPA + Prometheus Adapter |
|---|---|---|
| Already in your stack | Use if already installed | Use if you prefer fewer CRDs |
| Multi-source triggers | Native (Kafka, SQS, Prometheus, Redis, ...) | Prometheus only |
| Scale to zero | Supported | Not supported (minReplicas >= 1) |
| Configuration complexity | Lower | Higher (Adapter ConfigMap rules) |
| Cluster compatibility | Requires KEDA installation | Requires Prometheus Adapter installation |
| HPA conflict | Cannot coexist with a separate HPA on the same Deployment | Is the HPA |

---

## 4. VPA for Subgraphs — Recommendation Mode

VerticalPodAutoscaler (VPA) adjusts CPU and memory requests/limits for individual pods.
For stateless GraphQL subgraphs, VPA in `Off` mode (recommendation only) is the correct
choice. `Auto` mode is explicitly not recommended.

```yaml
# subgraph-vpa-products.yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: products-subgraph-vpa
  namespace: team-products
  labels:
    app.kubernetes.io/name: products-subgraph
    app.kubernetes.io/part-of: graphql-platform
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: products-subgraph

  updatePolicy:
    # updateMode: Off means VPA computes recommendations but NEVER modifies pod specs.
    # Recommendations are visible via `kubectl describe vpa products-subgraph-vpa`.
    # You apply them manually after review.
    #
    # Why NOT Auto mode for stateless GraphQL subgraphs?
    #
    # Auto mode evicts pods to apply new resource requests. For a stateless subgraph
    # with replicas: 3, VPA might evict 2 pods simultaneously (it has no coordination
    # with PDB unless you configure minReplicas). Even with PDB, VPA-triggered evictions
    # can cause momentary latency spikes as pods restart and warm their DataLoader caches.
    #
    # Additionally, VPA and HPA conflict when both target the same metric (CPU/memory).
    # If you use HPA for scale-out and VPA Auto for resource right-sizing, they can
    # fight each other: HPA scales out because CPU is high; VPA tries to increase CPU
    # request on existing pods, causing evictions that reduce capacity, causing HPA to
    # scale out again.
    #
    # The safe operational pattern is:
    # - VPA Off: collect recommendations for 1-2 weeks
    # - Review recommendations manually
    # - Update the Deployment resource requests in your Helm values
    # - Let Helm manage the actual requests via CI/CD
    updateMode: "Off"

  resourcePolicy:
    containerPolicies:
      - containerName: products-subgraph
        # minAllowed: VPA will not recommend below these values.
        # Set minAllowed to match your current requests to prevent VPA from
        # recommending downsizing before you are confident in the production baseline.
        minAllowed:
          cpu: "100m"
          memory: "256Mi"
        # maxAllowed: VPA will not recommend above these values.
        # Prevents runaway recommendations for pathological query patterns.
        maxAllowed:
          cpu: "2000m"
          memory: "4Gi"
        # controlledResources: only generate recommendations for these resources.
        # Omitting memory here means VPA only recommends CPU changes.
        # Include memory once you have confidence in the memory baseline.
        controlledResources: ["cpu", "memory"]
```

### Reading VPA recommendations

```bash
kubectl describe vpa products-subgraph-vpa -n team-products

# Output includes:
# Recommendation:
#   Container Recommendations:
#     Container Name: products-subgraph
#     Lower Bound:
#       Cpu:     120m
#       Memory:  320Mi
#     Target:               <-- use these values in your Deployment
#       Cpu:     350m
#       Memory:  512Mi
#     Uncapped Target:
#       Cpu:     350m
#       Memory:  512Mi
#     Upper Bound:
#       Cpu:     800m
#       Memory:  1Gi
```

---

## 5. Scale Behavior Tuning — Asymmetric Scale Up / Down

The key insight for autoscaling a latency-sensitive API is that scale-up and scale-down
should have asymmetric speed. Scale up fast, scale down slow.

```yaml
# This behavior block can be applied to any HPA in this file.
# It is shown separately here for clarity.
behavior:
  scaleUp:
    # stabilizationWindowSeconds: 60 — wait 1 minute after last scale-up event.
    # Why 60s? New pods take approximately 20-30s to become Ready (image pull,
    # JVM/Node startup, readiness probe warmup). Without a stabilization window,
    # the HPA sees the metric still above threshold while new pods are initializing
    # and adds even more pods. 60s gives pods time to start receiving traffic and
    # reducing the per-pod metric before the HPA recalculates.
    stabilizationWindowSeconds: 60

    policies:
      # Pods policy: add up to 4 pods per 60s.
      # Provides fast burst capacity — from 3 to 7 pods in one minute.
      - type: Pods
        value: 4
        periodSeconds: 60

      # Percent policy: double the replica count per 60s.
      # Handles exponential traffic growth better than a fixed pod count.
      # At 3 replicas: adds 3 pods. At 10 replicas: adds 10 pods.
      - type: Percent
        value: 100
        periodSeconds: 60

    # Max: use whichever policy allows more pods. Faster scale-up wins.
    selectPolicy: Max

  scaleDown:
    # stabilizationWindowSeconds: 300 — wait 5 minutes before scaling down.
    # Why 300s? This prevents the "sawtooth" pattern where traffic is bursty
    # over 5-minute intervals. Common traffic patterns: scheduled jobs, batch
    # imports, social media bursts. If you scale down during a 3-minute lull
    # and traffic returns in minute 4, you have a latency spike while pods scale
    # back up. The 5-minute window absorbs most burst-pause patterns.
    stabilizationWindowSeconds: 300

    policies:
      # Remove at most 1 pod per 120s.
      # Combined with 300s stabilization: it takes at minimum 10 minutes to
      # scale from 20 pods to 3 pods (10 removals * 2 minutes each, ignoring
      # stabilization resets). This is intentionally slow.
      - type: Pods
        value: 1
        periodSeconds: 120

    # Min: use the most conservative policy. Slower scale-down wins.
    selectPolicy: Min
```

### Why is asymmetric scaling correct for GraphQL APIs?

**The cost of scaling up too slowly** is latency degradation and potential SLA violation.
Users experience slow responses. Revenue is impacted in e-commerce scenarios.

**The cost of scaling down too fast** is running extra pods for a few minutes longer.
At $0.04/hour per pod (typical spot pricing), 5 extra pods for 10 minutes costs $0.033.

The cost asymmetry strongly favors a bias toward "keep more pods longer." The goal of
autoscaling is not to minimize pod count — it is to minimize latency variance while
staying within cost budget. Budget the minimum replica count for steady-state and let
the scaleDown policies handle the cost floor.

---

## 6. Prometheus Adapter Installation

The Prometheus Adapter is required for the custom metrics HPA in section 2.
KEDA (section 3) does not require the Prometheus Adapter.

```bash
# Add the Prometheus Community Helm chart repository
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install the Prometheus Adapter
# --set prometheus.url: point to your Prometheus instance
# --set prometheus.port: default Prometheus HTTP port
# logLevel: 4 enables verbose logging during initial setup; reduce to 1 in production
helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.url=http://prometheus-operated.monitoring.svc.cluster.local \
  --set prometheus.port=9090 \
  --set logLevel=1 \
  --set resources.requests.cpu=100m \
  --set resources.requests.memory=128Mi \
  --set resources.limits.cpu=500m \
  --set resources.limits.memory=256Mi \
  --values prometheus-adapter-values.yaml \
  --wait
```

```yaml
# prometheus-adapter-values.yaml
# Override the default adapter config with our custom metric rules.
# This replaces the adapter's default ConfigMap with our own.
rules:
  # existing: [] removes the default rules that translate CPU/memory metrics.
  # We define our own rules in the configMap above. Keeping default rules is
  # fine but increases the number of custom metrics registered, which adds
  # API server load.
  existing: []

  # custom: inline rule definitions (alternative to separate ConfigMap)
  custom:
    - seriesQuery: 'apollo_router_http_requests_total{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace:
            resource: namespace
          pod:
            resource: pod
      name:
        matches: "^(.*)_total$"
        as: "${1}_per_second"
      metricsQuery: 'rate(<<.Series>>{<<.LabelMatchers>>}[2m])'
```

### Custom metric naming convention

Apollo Router exposes metrics with the `apollo_router_` prefix. The Prometheus Adapter
translates them into Kubernetes custom metric names following the pattern:

```
Prometheus metric name          -> Kubernetes custom metric name
apollo_router_http_requests_total   -> apollo_router_http_requests_per_second
apollo_router_cache_hit_total       -> apollo_router_cache_hit_per_second
```

The `_per_second` suffix is applied by the Adapter rule's `as` substitution. This naming
convention makes it clear in the HPA manifest that the metric is a rate, not a counter.

```bash
# List all available custom metrics
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1 | jq -r '.resources[].name'

# Query a specific metric value for all pods in a namespace
kubectl get --raw \
  "/apis/custom.metrics.k8s.io/v1beta1/namespaces/graphql-platform/pods/*/apollo_router_http_requests_per_second" \
  | jq '.items[] | {pod: .describedObject.name, rps: .value}'
```

---

## Key Design Decisions

**Why not use external metrics (type: External) for the HPA instead of type: Pods?**
`type: Pods` computes the average metric value per pod and compares it to the target, which
gives the HPA the correct "how many pods do I need" calculation. `type: External` compares
the raw metric total to the threshold, requiring you to pre-compute the per-pod target into
the total (e.g., threshold = 100 req/s * 3 pods = 300). This is fragile because the
threshold is now coupled to the replica count. Use `type: Pods` with `averageValue` for
per-pod metrics.

**Why does the KEDA ScaledObject sum all pods and use a per-pod threshold rather than
querying a pre-averaged metric?**
Prometheus aggregates metrics at query time. Computing the sum and letting KEDA divide by
current replicas is more reliable than computing an average in PromQL, because PromQL
averages can be skewed by pods that recently started (lower traffic) or are about to be
terminated (no traffic). KEDA's internal division against current replicas gives the correct
desired replica count.

**Why is VPA in Off mode instead of using Initial mode?**
Initial mode applies VPA recommendations only at pod creation time (not eviction). At first
glance this seems safe — no evictions. However, Initial mode means the first version of a
pod gets VPA-computed requests, but subsequent rollouts (Deployment updates) get fresh VPA
recommendations that may differ. This creates inconsistency between pods created at different
times during a rolling deploy. Explicit values in the Deployment manifest, updated after
reviewing VPA recommendations, are more predictable.

---

## Related Documentation

- [router-deployment.md](./router-deployment.md) — base Deployment that HPA targets
- [subgraph-deployment.md](./subgraph-deployment.md) — subgraph Deployment with its own HPA
- [Chapter 15 — Kubernetes Deployment](../../docs/15-kubernetes-deployment/README.md)
- [Chapter 14 — Observability](../../docs/14-observability/README.md)
- [examples/10-open-telemetry](../10-open-telemetry/) — metrics exposed by Apollo Router
