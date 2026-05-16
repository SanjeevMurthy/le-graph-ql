# Apollo Router — Production Kubernetes Deployment

> Apollo Router is a Rust binary. It is fast, memory-efficient, and fundamentally stateless. These properties make it an ideal Kubernetes workload — it scales horizontally without coordination, restarts without draining connections, and consumes predictable resources under steady-state traffic. The Kubernetes manifests in this document are not starter templates; they are production specifications. Every field is present for a reason, and each reason is documented.

---

## Learning Objectives

- [ ] Deploy Apollo Router to Kubernetes with production-grade resource requests and limits
- [ ] Configure pod anti-affinity to spread router replicas across availability zones
- [ ] Set up a rolling update strategy that prevents downtime during router binary upgrades
- [ ] Mount `router.yaml` via ConfigMap and manage the Apollo API key via ExternalSecret or Vault sidecar
- [ ] Configure HPA with both CPU and custom RPS metrics
- [ ] Set a PodDisruptionBudget that maintains minimum availability during cluster maintenance
- [ ] Understand how the init container fetches the supergraph schema on cold start
- [ ] Write liveness and readiness probes that accurately reflect router health

---

## Overview

The Apollo Router Kubernetes deployment has six components that must be configured together:

1. **Deployment** — the router pod spec, resource sizing, update strategy, probes, and affinity rules
2. **Service** — ClusterIP for internal router access; optional LoadBalancer or NodePort for external
3. **ConfigMap** — `router.yaml` configuration (no secrets)
4. **Secret / ExternalSecret** — Apollo GraphOS API key and any signing secrets
5. **HorizontalPodAutoscaler** — scaling policy based on CPU and custom request-per-second metrics
6. **PodDisruptionBudget** — minimum availability guarantee during node drain or rolling updates

---

## Resource Sizing Reference

Apollo Router is a Rust binary with a small memory footprint at idle. Under production load, the CPU profile is dominated by query planning (O(n) with query complexity) and the memory profile is dominated by the in-memory supergraph schema and entity cache.

| Traffic Level | CPU Request | CPU Limit | Memory Request | Memory Limit | Recommended Replicas |
|--------------|-------------|-----------|----------------|--------------|---------------------|
| Dev / preview | 100m | 500m | 128Mi | 256Mi | 1 |
| Low (< 100 RPS) | 250m | 1000m | 256Mi | 512Mi | 2 |
| Medium (100-1000 RPS) | 500m | 2000m | 512Mi | 1Gi | 3-5 |
| High (> 1000 RPS) | 1000m | 4000m | 1Gi | 2Gi | 5-10 |
| Very high (> 5000 RPS) | 2000m | 8000m | 2Gi | 4Gi | 10+ (profile first) |

Note: These are starting points. Profile your specific query mix — operations with deep entity resolution fan-out consume more CPU per request than simple single-subgraph queries.

---

## Deployment Manifest

```yaml
# manifests/apollo-router/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: apollo-router
  namespace: graphql-platform
  labels:
    app.kubernetes.io/name: apollo-router
    app.kubernetes.io/component: router
    app.kubernetes.io/part-of: graphql-platform
    app.kubernetes.io/version: "1.48.0"   # pin the router version
  annotations:
    # Argo CD sync wave — router deploys after subgraphs are healthy
    argocd.argoproj.io/sync-wave: "10"
spec:
  replicas: 3   # Minimum 3 for HA across 3 AZs; HPA manages the ceiling
  selector:
    matchLabels:
      app.kubernetes.io/name: apollo-router
  strategy:
    type: RollingUpdate
    rollingUpdate:
      # Replace at most 1 pod at a time (conservative — router is stateless but
      # we want to avoid simultaneous loss of multiple replicas during schema reloads)
      maxUnavailable: 1
      # Allow one extra pod to exist during rollout to maintain capacity
      maxSurge: 1

  template:
    metadata:
      labels:
        app.kubernetes.io/name: apollo-router
        app.kubernetes.io/component: router
        app.kubernetes.io/version: "1.48.0"
      annotations:
        # Force pod restart when ConfigMap changes.
        # The hash is injected by Helm: {{ include "apollo-router.configHash" . }}
        checksum/config: "{{ sha256sum (print .Values.router.config) }}"
        # Prometheus scraping
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics"

    spec:
      serviceAccountName: apollo-router

      # ── Init Container: Fetch supergraph schema on cold start ───────────────
      # On first startup, the router needs a supergraph schema to serve traffic.
      # Rather than failing health checks until GraphOS delivers the schema via
      # polling (which can take up to 30s), an init container fetches it synchronously.
      initContainers:
        - name: fetch-supergraph-schema
          image: curlimages/curl:8.6.0
          command:
            - sh
            - -c
            - |
              set -e
              echo "Fetching supergraph schema from Apollo GraphOS..."
              curl -sSf \
                -H "x-api-key: ${APOLLO_KEY}" \
                "https://uplink.api.apollographql.com" \
                --data-raw '{"variables":{"ref":"'"${APOLLO_GRAPH_REF}"'","ifAfterId":null},"query":"query UplinkQuery($ref: String!, $ifAfterId: ID) { routerConfig(ref: $ref, ifAfterId: $ifAfterId) { __typename ... on RouterConfigResult { id minDelaySeconds } } }"}' \
                -o /dev/null
              echo "GraphOS connectivity verified."
              # Write a sentinel file so the main container knows the init ran
              touch /init-complete/ready
          env:
            - name: APOLLO_KEY
              valueFrom:
                secretKeyRef:
                  name: apollo-router-secrets
                  key: apollo-key
            - name: APOLLO_GRAPH_REF
              valueFrom:
                configMapKeyRef:
                  name: apollo-router-config
                  key: graph-ref
          volumeMounts:
            - name: init-complete
              mountPath: /init-complete

      containers:
        - name: apollo-router
          # Use the official Apollo Router image from GitHub Container Registry.
          # Pin to a specific digest in production (never use :latest).
          image: ghcr.io/apollographql/router:v1.48.0
          imagePullPolicy: IfNotPresent

          ports:
            - name: http
              containerPort: 4000
              protocol: TCP
            - name: metrics
              containerPort: 9090
              protocol: TCP
            - name: health
              containerPort: 8088
              protocol: TCP

          env:
            # Apollo GraphOS connection
            - name: APOLLO_KEY
              valueFrom:
                secretKeyRef:
                  name: apollo-router-secrets
                  key: apollo-key
            - name: APOLLO_GRAPH_REF
              valueFrom:
                configMapKeyRef:
                  name: apollo-router-config
                  key: graph-ref

            # Router telemetry
            - name: RUST_LOG
              value: "warn,apollo_router=info"

            # Pod identity for tracing (injected by Kubernetes downward API)
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName

          args:
            - "--config"
            - "/etc/router/router.yaml"
            - "--supergraph"
            - ""   # Empty: router fetches from GraphOS via APOLLO_KEY + APOLLO_GRAPH_REF

          volumeMounts:
            - name: router-config
              mountPath: /etc/router
              readOnly: true
            - name: init-complete
              mountPath: /init-complete
              readOnly: true

          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              cpu: "2000m"
              memory: "1Gi"

          # ── Readiness Probe ─────────────────────────────────────────────────
          # The router is ready only when it has successfully fetched and loaded
          # the supergraph schema from GraphOS. The /health endpoint returns
          # { "status": "pass" } only after schema is loaded.
          readinessProbe:
            httpGet:
              path: /health?ready
              port: health
              scheme: HTTP
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            successThreshold: 1
            failureThreshold: 3

          # ── Liveness Probe ──────────────────────────────────────────────────
          # The router process is alive if it responds to HTTP requests.
          # Use a longer initialDelaySeconds than readiness — give the schema
          # fetch time to complete before killing a pod that is simply warming up.
          livenessProbe:
            httpGet:
              path: /health
              port: health
              scheme: HTTP
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 5
            successThreshold: 1
            failureThreshold: 3

          # ── Startup Probe ───────────────────────────────────────────────────
          # Gives the router up to 60 seconds to start (schema fetch + parse)
          # before the liveness probe kicks in. Without this, slow schema fetches
          # on cold start cause the liveness probe to kill the pod in a restart loop.
          startupProbe:
            httpGet:
              path: /health
              port: health
              scheme: HTTP
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 12   # 12 * 5s = 60 seconds max startup time

          lifecycle:
            preStop:
              exec:
                # Give the router 15 seconds to finish in-flight requests before
                # the container is terminated. Without this, a rolling update
                # terminates pods while they are still processing queries.
                command: ["/bin/sh", "-c", "sleep 15"]

      # ── Pod Scheduling ────────────────────────────────────────────────────
      # Spread router replicas across availability zones.
      # Required anti-affinity: never place two router pods on the same node.
      # Preferred anti-affinity: prefer different AZs (fails gracefully if only one AZ exists).
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app.kubernetes.io/name: apollo-router
              topologyKey: kubernetes.io/hostname
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app.kubernetes.io/name: apollo-router
                topologyKey: topology.kubernetes.io/zone

      # ── Topology Spread Constraints (Kubernetes 1.19+) ──────────────────
      # Ensures router pods are evenly distributed across zones.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: apollo-router

      # Graceful termination: allow 30 seconds for in-flight requests to complete
      # (preStop sleep 15s + router drain time ~15s)
      terminationGracePeriodSeconds: 30

      # Security context for the pod
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault

      volumes:
        - name: router-config
          configMap:
            name: apollo-router-config
        - name: init-complete
          emptyDir: {}
```

---

## Service Manifest

```yaml
# manifests/apollo-router/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: apollo-router
  namespace: graphql-platform
  labels:
    app.kubernetes.io/name: apollo-router
    app.kubernetes.io/component: router
  annotations:
    # Expose Prometheus metrics endpoint for scraping
    prometheus.io/scrape: "true"
    prometheus.io/port: "9090"
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: apollo-router
  ports:
    - name: http
      port: 4000
      targetPort: http
      protocol: TCP
    - name: metrics
      port: 9090
      targetPort: metrics
      protocol: TCP
    - name: health
      port: 8088
      targetPort: health
      protocol: TCP

---
# Optional: External LoadBalancer for direct external access without Ingress.
# Use this only if you bypass the Ingress layer (e.g., for internal partner APIs).
# For public GraphQL traffic, prefer the Ingress path — it provides TLS termination,
# WAF integration, and rate limiting.
apiVersion: v1
kind: Service
metadata:
  name: apollo-router-external
  namespace: graphql-platform
  labels:
    app.kubernetes.io/name: apollo-router
    app.kubernetes.io/component: router-external
  annotations:
    # AWS: provision an NLB (Network Load Balancer) for low-latency TCP passthrough
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"
    # GCP equivalent: cloud.google.com/load-balancer-type: "Internal"
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: apollo-router
  ports:
    - name: http
      port: 4000
      targetPort: http
      protocol: TCP
  # Restrict access to specific CIDR blocks (e.g., corporate VPN range)
  loadBalancerSourceRanges:
    - "10.0.0.0/8"
    - "172.16.0.0/12"
```

---

## ConfigMap: router.yaml

```yaml
# manifests/apollo-router/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: apollo-router-config
  namespace: graphql-platform
  labels:
    app.kubernetes.io/name: apollo-router
data:
  graph-ref: "my-graph@production"   # Override per environment via Helm values

  router.yaml: |
    # Apollo Router configuration
    # Reference: https://www.apollographql.com/docs/router/configuration/overview/

    # ── Server ────────────────────────────────────────────────────────────────
    supergraph:
      listen: 0.0.0.0:4000
      path: /graphql
      # Introspection: disable in production, enable for internal tooling namespaces
      introspection: false
      # Query depth limit — prevents deeply nested malicious queries
      query_planning:
        experimental_query_planner_mode: new

    # ── Health check endpoint ─────────────────────────────────────────────────
    health_check:
      listen: 0.0.0.0:8088
      enabled: true
      path: /health

    # ── Sandbox (GraphQL Playground equivalent) ───────────────────────────────
    sandbox:
      enabled: false   # Never expose sandbox in production

    # ── CORS ──────────────────────────────────────────────────────────────────
    cors:
      # List the exact origins your web clients use.
      # Never use origins: ["*"] in production — it bypasses CORS protection.
      origins:
        - https://app.example.com
        - https://admin.example.com
      methods:
        - GET
        - POST
        - OPTIONS
      headers:
        - Content-Type
        - Authorization
        - Apollo-Require-Preflight
        - X-Request-ID

    # ── Authentication ────────────────────────────────────────────────────────
    authentication:
      router:
        jwt:
          jwks:
            - url: https://auth.example.com/.well-known/jwks.json
              # Cache JWKS for 5 minutes; refresh 30 seconds before expiry
              poll_interval: 60s
          # Claims to extract as request headers for subgraph propagation
          header_value_prefix: "Bearer"

    # ── Authorization ─────────────────────────────────────────────────────────
    authorization:
      # Require authentication for all operations (override per-operation with directives)
      require_authentication: true
      preview_directives:
        enabled: true

    # ── Traffic Shaping ───────────────────────────────────────────────────────
    traffic_shaping:
      router:
        # Global timeout for all client requests
        timeout: 30s
      # Per-subgraph overrides
      all:
        # Timeout applied to every subgraph fetch
        timeout: 15s
        # Retry once on connection errors (not on application errors)
        retry:
          min_per_sec: 10
          retry_on: "5xx"
          statuses:
            - 503
            - 504
      # Subgraph-specific overrides (higher timeout for slow upstream services)
      subgraphs:
        payments:
          timeout: 25s   # Payments service has slower SLA
          retry:
            retry_on: "5xx"
            statuses:
              - 503

    # ── Entity caching (Apollo Router Enterprise) ─────────────────────────────
    # Requires Apollo Router Enterprise license
    preview_entity_cache:
      enabled: true
      redis:
        urls:
          - redis://redis.graphql-platform.svc.cluster.local:6379
        timeout: 2ms
        ttl: 60s   # Default entity cache TTL; override per-type in subgraph schemas

    # ── Telemetry ─────────────────────────────────────────────────────────────
    telemetry:
      exporters:
        tracing:
          otlp:
            enabled: true
            endpoint: http://otel-collector.observability.svc.cluster.local:4317
            protocol: grpc
            batch_processor:
              max_export_batch_size: 512
              scheduled_delay: 5s
        metrics:
          prometheus:
            enabled: true
            listen: 0.0.0.0:9090
            path: /metrics

      instrumentation:
        spans:
          router:
            attributes:
              # Include these attributes on every root span
              "http.request.header.x-request-id":
                request_header: "x-request-id"
              "apollo.operation.name":
                operation_name: true
              "k8s.pod.name":
                env: "POD_NAME"
              "k8s.namespace.name":
                env: "POD_NAMESPACE"

    # ── Header propagation ────────────────────────────────────────────────────
    headers:
      all:
        # Forward these headers from client requests to all subgraph calls
        request:
          - propagate:
              named: "x-request-id"
          - propagate:
              named: "x-correlation-id"
          - propagate:
              named: "authorization"
          - propagate:
              named: "x-forwarded-for"
      subgraphs:
        # Inject router pod identity header for subgraph-side tracing correlation
        orders:
          request:
            - insert:
                name: "x-router-pod"
                value: "${env.POD_NAME}"

    # ── Persisted queries ─────────────────────────────────────────────────────
    persisted_queries:
      enabled: true
      # Safelist mode: only execute registered operations (blocks arbitrary queries)
      safelist:
        enabled: true
        require_id: false   # Set true to enforce PQ IDs for all production clients

    # ── Limits ────────────────────────────────────────────────────────────────
    limits:
      max_depth: 15
      max_height: 200
      max_aliases: 30
      max_root_fields: 20
```

---

## Secret Management

### Option A: ExternalSecret (recommended)

Use the [External Secrets Operator](https://external-secrets.io/) to sync secrets from Vault, AWS Secrets Manager, or GCP Secret Manager into Kubernetes secrets.

```yaml
# manifests/apollo-router/external-secret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: apollo-router-secrets
  namespace: graphql-platform
spec:
  refreshInterval: 1h   # Re-sync from Vault every hour
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-backend   # Defined by platform team; references Vault address + auth

  target:
    name: apollo-router-secrets   # Name of the Kubernetes Secret to create/update
    creationPolicy: Owner
    deletionPolicy: Retain         # Do not delete Secret if ExternalSecret is deleted

  data:
    - secretKey: apollo-key        # Key in the Kubernetes Secret
      remoteRef:
        key: secret/graphql-platform/apollo-router   # Path in Vault
        property: apollo_key                          # Field within the Vault secret

    - secretKey: jwt-signing-key
      remoteRef:
        key: secret/graphql-platform/apollo-router
        property: jwt_signing_key
```

### Option B: Vault Agent Sidecar

For environments where External Secrets Operator is not available:

```yaml
# Add to pod spec annotations:
metadata:
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "apollo-router"
    vault.hashicorp.com/agent-inject-secret-apollo-key: "secret/graphql-platform/apollo-router"
    vault.hashicorp.com/agent-inject-template-apollo-key: |
      {{- with secret "secret/graphql-platform/apollo-router" -}}
      {{ .Data.data.apollo_key }}
      {{- end }}
    # Mount the secret as a file at /vault/secrets/apollo-key
    # Then reference it in the container env as a file-based secret

# In the container spec, read the secret from the file:
# env:
#   - name: APOLLO_KEY
#     valueFrom:
#       secretKeyRef:
#         name: apollo-router-secrets   # Created by Vault Agent
#         key: apollo-key
```

---

## HorizontalPodAutoscaler

```yaml
# manifests/apollo-router/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: apollo-router
  namespace: graphql-platform
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: apollo-router

  minReplicas: 3    # Never below 3 — one per AZ minimum
  maxReplicas: 20   # Hard ceiling; adjust based on cluster capacity

  metrics:
    # ── Metric 1: CPU utilization ──────────────────────────────────────────
    # Scale up when average CPU across pods exceeds 70%.
    # Query planning is CPU-intensive; 70% target leaves headroom for spikes.
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70

    # ── Metric 2: Requests per second (custom metric) ────────────────────
    # Scale based on RPS using a custom metric exported by the router's
    # Prometheus endpoint and exposed via the Prometheus Adapter.
    # Metric name follows the convention: <namespace>_<metric> (kube-state-metrics format)
    - type: Pods
      pods:
        metric:
          name: apollo_router_http_requests_total_per_second
        target:
          type: AverageValue
          averageValue: "500"   # Scale up when any pod exceeds 500 RPS

  behavior:
    # ── Scale-up policy: fast ──────────────────────────────────────────────
    # Add up to 4 replicas per 60 seconds (handles traffic spikes quickly)
    scaleUp:
      stabilizationWindowSeconds: 30   # Short window — react to spikes fast
      policies:
        - type: Pods
          value: 4
          periodSeconds: 60
        - type: Percent
          value: 100
          periodSeconds: 60
      selectPolicy: Max   # Use whichever policy adds more pods

    # ── Scale-down policy: conservative ───────────────────────────────────
    # Remove at most 1 replica per 120 seconds.
    # Prevents thrashing when traffic oscillates around the threshold.
    scaleDown:
      stabilizationWindowSeconds: 300   # Wait 5 minutes before scaling down
      policies:
        - type: Pods
          value: 1
          periodSeconds: 120
```

---

## PodDisruptionBudget

```yaml
# manifests/apollo-router/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: apollo-router
  namespace: graphql-platform
spec:
  # Require at least 2 pods to be available at all times.
  # With 3 replicas, this allows draining 1 node at a time (1 pod evicted).
  # With 10 replicas (under HPA), this allows evicting 8 pods simultaneously.
  minAvailable: 2

  selector:
    matchLabels:
      app.kubernetes.io/name: apollo-router
```

---

## ServiceAccount and RBAC

```yaml
# manifests/apollo-router/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: apollo-router
  namespace: graphql-platform
  labels:
    app.kubernetes.io/name: apollo-router
  annotations:
    # AWS IRSA: bind the ServiceAccount to an IAM role for AWS Secrets Manager access
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/graphql-platform-apollo-router
    # GCP Workload Identity equivalent:
    # iam.gke.io/gcp-service-account: apollo-router@project.iam.gserviceaccount.com

---
# The router does not need to call the Kubernetes API.
# A minimal Role prevents privilege escalation if the router is compromised.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: apollo-router
  namespace: graphql-platform
rules:
  # No rules — the router has no Kubernetes API access needs.
  # Add rules only if a custom plugin requires Kubernetes API access (document why).
  []

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: apollo-router
  namespace: graphql-platform
subjects:
  - kind: ServiceAccount
    name: apollo-router
    namespace: graphql-platform
roleRef:
  kind: Role
  apiGroup: rbac.authorization.k8s.io
  name: apollo-router
```

---

## NetworkPolicy

```yaml
# manifests/apollo-router/networkpolicy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: apollo-router
  namespace: graphql-platform
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: apollo-router

  policyTypes:
    - Ingress
    - Egress

  ingress:
    # Allow traffic from the ingress namespace (NGINX Ingress Controller)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 4000
          protocol: TCP
    # Allow Prometheus scraping from the observability namespace
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
      ports:
        - port: 9090
          protocol: TCP
    # Allow health checks from kube-system (kubelet probes do not use NetworkPolicy)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - port: 8088
          protocol: TCP

  egress:
    # Allow traffic to all subgraph namespaces (teams publish their namespace labels)
    - to:
        - namespaceSelector:
            matchLabels:
              graphql-platform/role: subgraph
      ports:
        - port: 4001
          protocol: TCP
        - port: 4002
          protocol: TCP
        - port: 4003
          protocol: TCP
        # Add ports for additional subgraphs
    # Allow outbound to Apollo GraphOS (schema polling)
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - port: 443
          protocol: TCP
    # Allow traffic to OpenTelemetry collector
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
      ports:
        - port: 4317
          protocol: TCP
    # Allow DNS resolution
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
```

---

## Production Considerations

### Rolling Update Strategy

The `maxUnavailable: 1` setting in the rolling update strategy means that at any point during an update, at most one pod is unavailable. With `minAvailable: 2` in the PDB and a minimum of 3 replicas, this means:

- 3 replicas: 1 is being updated, 2 are serving traffic. PDB allows this.
- 10 replicas (under HPA): 1 is being updated, 9 are serving traffic. Excess capacity absorbs the missing replica.

Always wait for the `preStop` hook (15 seconds) plus the `terminationGracePeriodSeconds` (30 seconds) to fully drain. If you set `terminationGracePeriodSeconds` below 30, you risk connection resets on long-running GraphQL subscriptions.

### Cold Start Latency

The Apollo Router binary starts in under 1 second. The limiting factor is schema fetch from GraphOS. Under normal conditions this takes 3-10 seconds. The startup probe gives the router 60 seconds before the liveness probe begins. If your schema exceeds 10MB, increase `failureThreshold` on the startup probe.

### Schema Hot-Reload

Apollo Router polls GraphOS for supergraph config updates at a configurable interval (default: 10 seconds in managed mode). No pod restart is required for a schema update. The router atomically swaps the schema in memory. In-flight requests using the old schema complete normally. Monitor the `apollo_router_schema_change_total` Prometheus counter to verify hot-reloads are occurring.

### Metrics to Alert On

| Metric | Alert Condition | Severity |
|--------|----------------|----------|
| `apollo_router_http_requests_error_rate` | > 1% over 5 minutes | Warning |
| `apollo_router_http_requests_error_rate` | > 5% over 1 minute | Critical |
| `apollo_router_http_request_duration_seconds_p99` | > 2s over 5 minutes | Warning |
| `apollo_router_schema_load_error_total` | > 0 | Critical |
| Container CPU throttling | > 25% of requests throttled | Warning |
| HPA `currentReplicas` == `maxReplicas` | For > 5 minutes | Warning (approaching ceiling) |

---

## References

- [Apollo Router configuration reference](https://www.apollographql.com/docs/router/configuration/overview/)
- [Apollo Router Kubernetes deployment guide](https://www.apollographql.com/docs/router/containerization/kubernetes/)
- [External Secrets Operator](https://external-secrets.io/latest/)
- [Kubernetes HPA v2 API](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/horizontal-pod-autoscaler-v2/)
- [Vault Agent Sidecar Injector](https://developer.hashicorp.com/vault/docs/platform/k8s/injector)

---

## Related Topics

- [02-subgraph-deployment.md](./02-subgraph-deployment.md) — deployment patterns for GraphQL subgraphs
- [03-ingress-and-gateway.md](./03-ingress-and-gateway.md) — Ingress configuration routing traffic to this Service
- [04-autoscaling.md](./04-autoscaling.md) — KEDA and VPA as extensions to the HPA defined here
- [05-helm-charts.md](./05-helm-charts.md) — Helm templating these manifests for multi-environment deployment
