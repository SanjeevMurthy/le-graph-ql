# Products Subgraph — Complete Kubernetes Manifests

> Companion doc: [../../docs/15-kubernetes-deployment/](../../docs/15-kubernetes-deployment/)

This file contains production-ready Kubernetes manifests for the Products subgraph — one
of the team-owned subgraphs in the Apollo Federation supergraph. The Products subgraph is
a Node.js/TypeScript service built with Apollo Server and the `@apollo/subgraph` package.

Every resource is annotated with reasoning specific to GraphQL subgraph workloads. The key
differences from a generic REST microservice are: DataLoader-aware resource sizing (subgraphs
batch N+1 resolution using DataLoader, making their IO pattern distinctly different from
REST), a readiness probe that validates schema availability, and a NetworkPolicy that enforces
the contract that subgraphs only accept traffic from the router — never directly from clients.

Apply these manifests after the router namespace and IRSA infrastructure are in place
(see [router-deployment.md](./router-deployment.md)).

---

## 1. Namespace

```yaml
# products-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-products
  labels:
    # team: products is the primary selector used by:
    # (1) the router's NetworkPolicy egress rule (allows traffic to this namespace)
    # (2) VPA targeting (see hpa-config.md)
    # (3) cost allocation tooling (Kubecost labels, FinOps dashboards)
    team: products

    # part-of: graphql-platform signals that this namespace is a subgraph of the
    # platform supergraph, distinguishing it from unrelated team namespaces.
    app.kubernetes.io/part-of: graphql-platform

    environment: production

    # squad: products-catalog maps to the owning squad for PagerDuty routing and
    # Slack alerting. Not a Kubernetes-standard label; specific to your org's tooling.
    squad: products-catalog
```

---

## 2. ServiceAccount with IRSA Annotation for Database Access

```yaml
# products-serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: products-subgraph
  namespace: team-products
  labels:
    app.kubernetes.io/name: products-subgraph
    app.kubernetes.io/part-of: graphql-platform
  annotations:
    # IRSA annotation grants this pod access to the products database secret
    # and any other AWS resources the Products subgraph needs (S3 for image assets,
    # SQS for async order events, etc.).
    # The IAM role should have ONLY the permissions this service requires:
    #   - secretsmanager:GetSecretValue on the products DB secret ARN
    #   - s3:GetObject on the products-images bucket (if applicable)
    # It should NOT have access to the users or orders DB secrets — those belong
    # to their respective service accounts.
    eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/products-subgraph-irsa-role"
    eks.amazonaws.com/token-expiration-seconds: "3600"
automountServiceAccountToken: true
```

---

## 3. ConfigMap — Application Configuration

```yaml
# products-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: products-subgraph-config
  namespace: team-products
  labels:
    app.kubernetes.io/name: products-subgraph
    app.kubernetes.io/part-of: graphql-platform
data:
  # DB_HOST and DB_PORT are non-secret configuration.
  # The database hostname is not a secret — it is derivable from the infrastructure
  # setup. Only the credentials (username/password) are secret.
  # Separating non-secret from secret config makes ConfigMap diffs readable in PRs.
  DB_HOST: "products-db.us-east-1.rds.amazonaws.com"
  DB_PORT: "5432"
  DB_NAME: "products"

  # DB_POOL_MIN and DB_POOL_MAX: database connection pool sizing.
  # GraphQL subgraphs with DataLoader exhibit a distinctive connection pattern:
  # DataLoader batches multiple resolver calls into a single DB query. This means
  # the subgraph makes fewer, larger queries rather than many small ones.
  # A pool of 5-10 connections is typically sufficient for a subgraph with moderate
  # traffic, because DataLoader reduces concurrent query count compared to N+1 resolution.
  # Oversizing the pool (e.g., 50 connections) wastes database file descriptors
  # and connection overhead without improving throughput.
  DB_POOL_MIN: "2"
  DB_POOL_MAX: "10"

  # DB_POOL_IDLE_TIMEOUT_MS: release idle connections after this many milliseconds.
  # 30000ms (30s) is appropriate for a production subgraph — long enough to avoid
  # constant reconnection overhead during quiet periods, short enough to release
  # connections before a database maintenance window runs out of connection slots.
  DB_POOL_IDLE_TIMEOUT_MS: "30000"

  # DATALOADER_BATCH_SIZE: maximum number of keys DataLoader batches in one call.
  # Higher values reduce DB round trips but increase memory usage per batch.
  # 100 is the DataLoader default and a reasonable production value.
  # If you are seeing high-memory usage during peak traffic, reduce to 50.
  DATALOADER_BATCH_SIZE: "100"

  # DATALOADER_BATCH_SCHEDULE_FN_DELAY_MS: how long DataLoader waits before
  # dispatching a batch. Default is 0 (current tick), which is correct for most cases.
  # Setting this to a small positive value (1-5ms) can improve batch fill rates
  # in high-concurrency scenarios at the cost of slightly increased P50 latency.
  DATALOADER_BATCH_SCHEDULE_FN_DELAY_MS: "0"

  # PORT: the port the subgraph listens on.
  PORT: "4001"

  # LOG_LEVEL: info in production. debug in staging.
  LOG_LEVEL: "info"

  # APOLLO_SCHEMA_REPORTING: false for subgraphs — only the router reports to Studio.
  # Each subgraph enabling schema reporting would create noise in Studio's schema history.
  APOLLO_SCHEMA_REPORTING: "false"
```

---

## 4. ExternalSecret — Database Credentials

```yaml
# products-externalsecret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: products-subgraph-secrets
  namespace: team-products
  labels:
    app.kubernetes.io/name: products-subgraph
    app.kubernetes.io/part-of: graphql-platform
spec:
  refreshInterval: "15m"
  # 15 minutes is shorter than the router's 1h refresh because database credentials
  # are rotated more frequently (RDS Secrets Manager rotation default is 7 days,
  # but some teams rotate daily). A 15m refresh ensures the K8s Secret is updated
  # within one rotation window.

  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager

  target:
    name: products-subgraph-secrets
    creationPolicy: Owner
    deletionPolicy: Retain

    template:
      engineVersion: v2
      type: Opaque

  data:
    - secretKey: DB_USER
      remoteRef:
        key: "arn:aws:secretsmanager:us-east-1:123456789012:secret:team-products/db-credentials"
        property: "username"
        version: "AWSCURRENT"

    - secretKey: DB_PASSWORD
      remoteRef:
        key: "arn:aws:secretsmanager:us-east-1:123456789012:secret:team-products/db-credentials"
        property: "password"
        version: "AWSCURRENT"

    - secretKey: REDIS_URL
      remoteRef:
        # Subgraphs share the platform Redis for DataLoader request deduplication cache
        # (if using a shared Redis cache layer). Using a separate secret from the router's
        # Redis URL means credentials can be rotated independently.
        key: "arn:aws:secretsmanager:us-east-1:123456789012:secret:team-products/redis-url"
        version: "AWSCURRENT"
```

---

## 5. Deployment

```yaml
# products-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: products-subgraph
  namespace: team-products
  labels:
    app.kubernetes.io/name: products-subgraph
    app.kubernetes.io/version: "2.14.3"
    app.kubernetes.io/part-of: graphql-platform
    team: products
spec:
  # replicas: 3 provides AZ-level fault tolerance.
  # Unlike the router (which handles ALL traffic), subgraphs handle only the
  # traffic routed to them. 3 replicas is appropriate for a medium-traffic subgraph.
  # For low-traffic internal subgraphs, 2 replicas may suffice; for high-traffic
  # product catalogs serving millions of reads, use HPA to scale dynamically.
  replicas: 3

  revisionHistoryLimit: 5

  selector:
    matchLabels:
      app.kubernetes.io/name: products-subgraph

  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0

  template:
    metadata:
      labels:
        app.kubernetes.io/name: products-subgraph
        app.kubernetes.io/version: "2.14.3"
        app.kubernetes.io/part-of: graphql-platform
        team: products
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9091"
        prometheus.io/path: "/metrics"
        checksum/config: "PLACEHOLDER_REPLACED_BY_HELM"

    spec:
      serviceAccountName: products-subgraph
      terminationGracePeriodSeconds: 30
      # 30s is sufficient for a Node.js subgraph. The preStop hook (sleep 5) gives
      # the router time to deregister the pod, then the remaining 25s allows in-flight
      # DataLoader batches and DB queries to complete.

      securityContext:
        runAsNonRoot: true
        # Node.js official images run as root by default. Either use a non-root
        # base image (node:20-alpine with USER node) or explicitly set runAsUser.
        # The node user in the official Alpine image is UID 1000.
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault

      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: products-subgraph

      # affinity: anti-affinity to spread pods across nodes within an AZ.
      # Unlike the router which uses topologySpreadConstraints for both AZ and node,
      # subgraphs use podAntiAffinity for node-level spreading. Both approaches are
      # valid; affinity rules give you more expressive control over co-location policy.
      affinity:
        podAntiAffinity:
          # preferredDuringSchedulingIgnoredDuringExecution: soft constraint.
          # Kubernetes prefers to schedule pods on different nodes but will not
          # block scheduling if no qualifying node is available (e.g., a 2-node cluster).
          # Use requiredDuringSchedulingIgnoredDuringExecution only if you are certain
          # your cluster always has enough nodes.
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app.kubernetes.io/name: products-subgraph
                # kubernetes.io/hostname: prefer pods on different nodes.
                topologyKey: kubernetes.io/hostname

      # initContainers: run database migrations before the subgraph starts.
      # This is the recommended pattern for schema migrations in Kubernetes:
      # the init container runs the migration, and the main container starts only
      # after the migration succeeds. If the migration fails, the Deployment is
      # blocked and the rollout does not proceed.
      #
      # Why an init container rather than running migrations in the app startup code?
      # App startup code runs in EVERY pod, including all replicas simultaneously.
      # Concurrent migrations from multiple pods can cause deadlocks or double-migration
      # errors. The init container approach ensures migrations run once per rollout
      # (whichever pod starts the init container first; other pods wait).
      # Use a distributed lock (Redlock, pg_try_advisory_lock) inside the migration
      # tool as an additional guard.
      initContainers:
        - name: db-migrate
          image: registry.example.com/products-subgraph:2.14.3
          command: ["node", "dist/scripts/migrate.js"]
          envFrom:
            - configMapRef:
                name: products-subgraph-config
            - secretRef:
                name: products-subgraph-secrets
          resources:
            # Init containers for migrations should have generous memory limits
            # to handle large data migrations without OOM. CPU can be low since
            # migrations are not latency-sensitive.
            limits:
              cpu: "500m"
              memory: "512Mi"
            requests:
              cpu: "100m"
              memory: "256Mi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            # readOnlyRootFilesystem: false for the migration container because
            # some migration tools write lock files or temp files to the filesystem.
            # The main container (below) has readOnlyRootFilesystem: true.
            capabilities:
              drop: ["ALL"]

      containers:
        - name: products-subgraph
          image: registry.example.com/products-subgraph:2.14.3

          ports:
            - name: http
              containerPort: 4001
              protocol: TCP
            - name: metrics
              # Expose Prometheus metrics on a separate port.
              # This port is scraped by the ServiceMonitor but not exposed via
              # Service port 4001, ensuring metrics are internal-only.
              containerPort: 9091
              protocol: TCP

          envFrom:
            - configMapRef:
                name: products-subgraph-config
            - secretRef:
                name: products-subgraph-secrets

          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace

            # NODE_OPTIONS: Node.js runtime configuration.
            # --max-old-space-size=512: cap the V8 heap at 512MB.
            # Without this, Node.js will use as much heap as the OS allows, which
            # can exceed the container memory limit and trigger an OOM kill.
            # Set this to ~70% of the memory limit (limits.memory=1Gi -> 700MB).
            # GraphQL subgraphs with DataLoader cache responses in memory —
            # setting this too low evicts cached data and hurts performance;
            # setting it too high risks OOM kills.
            - name: NODE_OPTIONS
              value: "--max-old-space-size=700"

            # NODE_ENV: production enables optimizations in Apollo Server and
            # disables development-only features (stack traces in errors, etc.).
            - name: NODE_ENV
              value: "production"

            # UV_THREADPOOL_SIZE: Node.js libuv thread pool size.
            # Default is 4. For subgraphs with heavy database I/O (connection pool
            # operations, file system operations), increasing this to 8 can improve
            # throughput. For pure-in-memory or Redis workloads, 4 is sufficient.
            # This does NOT need to match the number of CPU cores.
            - name: UV_THREADPOOL_SIZE
              value: "8"

          resources:
            requests:
              # cpu: 250m for a subgraph is lower than the router (500m) because
              # subgraphs are IO-bound, not CPU-bound. A Node.js subgraph spends
              # the majority of its time awaiting database responses (DataLoader
              # batch dispatch) and network I/O to the router. CPU usage spikes
              # briefly during JSON serialization of large responses and during
              # query parsing, but these are short bursts.
              #
              # GraphQL subgraphs vs. typical REST services:
              # - REST service: CPU-bound during business logic, IO-bound during DB queries
              # - GraphQL subgraph: IO-bound during field resolution (DataLoader awaits),
              #   CPU-bound only during document parsing (one-time per operation type)
              #   and response serialization
              # This means subgraphs typically need less CPU than a comparable REST service
              # at the same request rate.
              cpu: "250m"

              # memory: 512Mi accounts for: Node.js heap (see NODE_OPTIONS above for cap),
              # DataLoader in-memory cache (bounded by DATALOADER_BATCH_SIZE * entry size),
              # require() module cache (loaded once at startup, roughly 100-200MB for a
              # production Node.js server with ORM and GraphQL libraries),
              # and in-flight request buffers.
              memory: "512Mi"

            limits:
              # cpu: 1000m (1 core). Node.js is single-threaded for JavaScript execution
              # and cannot use more than 1 core for pure JS work. The UV thread pool
              # uses additional cores for I/O operations. In practice, a Node.js process
              # rarely sustains more than 0.8 cores; 1 core provides burst headroom
              # for GC and heavy serialization without CPU throttling.
              # Do NOT set the CPU limit to 250m (equal to request) — this would
              # throttle GC and cause latency spikes at any non-trivial traffic level.
              cpu: "1000m"

              # memory: 1Gi. NODE_OPTIONS capped the V8 heap at 700MB, but the process
              # also uses memory outside the heap (buffers, native modules, OS overhead).
              # 1Gi gives a 300MB buffer above the heap cap.
              # If you see OOM kills with 1Gi limits and 700MB heap, investigate for
              # memory leaks in DataLoader cache (unbounded cache growth), stream buffering
              # of large file responses, or native module memory.
              memory: "1Gi"

          readinessProbe:
            httpGet:
              # /.well-known/apollo/server-health returns 200 when the subgraph is ready.
              # This endpoint is provided by @apollo/subgraph and validates that:
              # (1) The GraphQL schema is loaded and valid
              # (2) The server is accepting connections
              # It does NOT validate database connectivity — that is intentional.
              # If the database is unavailable, the subgraph should still be ready
              # (it will return errors for DB-dependent queries, but the pod should
              # remain in the Endpoints list so the router can reach it and return
              # proper GraphQL errors rather than connection refused errors).
              path: /.well-known/apollo/server-health
              port: http
            initialDelaySeconds: 10
            # Node.js startup (require() module loading) takes 3-8 seconds for a
            # typical production server. 10s gives comfortable startup headroom.
            periodSeconds: 10
            failureThreshold: 3
            successThreshold: 1
            timeoutSeconds: 5

          livenessProbe:
            # Liveness uses the same endpoint as readiness but with more lenient timing.
            # A liveness failure restarts the pod (destructive); a readiness failure
            # only removes the pod from Service endpoints (non-destructive).
            # For subgraphs, Node.js can enter an event loop starved state (stuck in
            # a tight loop) that shows CPU usage but does not serve requests. The liveness
            # probe detects this by checking the HTTP endpoint response.
            httpGet:
              path: /.well-known/apollo/server-health
              port: http
            initialDelaySeconds: 20
            periodSeconds: 20
            failureThreshold: 3
            timeoutSeconds: 5

          # startupProbe: allows slow-starting containers more time to initialize
          # without the liveness probe killing them prematurely.
          # For Node.js subgraphs with large require() trees, startup can take up to 15s.
          # The startupProbe runs until it succeeds (or exhausts failureThreshold * periodSeconds),
          # at which point the liveness/readiness probes take over.
          startupProbe:
            httpGet:
              path: /.well-known/apollo/server-health
              port: http
            # failureThreshold * periodSeconds = 30 * 5 = 150s maximum startup time.
            # This is very generous. In practice, the subgraph starts in 5-15s.
            failureThreshold: 30
            periodSeconds: 5

          lifecycle:
            preStop:
              exec:
                # sleep 5 before SIGTERM: gives the router (and kube-proxy) time to
                # remove this pod from the Service Endpoints list before the subgraph
                # stops accepting connections. Without this, the router may send
                # requests to the pod during the 1-2 second propagation window between
                # pod deletion and Endpoints update, causing connection refused errors.
                #
                # Why 5 seconds specifically?
                # kube-proxy watches the Endpoints API and updates iptables rules.
                # The propagation latency is typically <1s within a healthy cluster.
                # 5s provides margin for slow nodes, high API server load, or
                # cloud LB deregistration (which can take 1-5s depending on provider).
                command: ["/bin/sh", "-c", "sleep 5"]

          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]

          volumeMounts:
            - name: tmp
              mountPath: /tmp
            # Node.js applications sometimes write to /home/node or /app/tmp.
            # Mount a tmpfs for any writable path your application needs.
            - name: app-tmp
              mountPath: /app/tmp

      volumes:
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: app-tmp
          emptyDir:
            medium: Memory
            sizeLimit: 128Mi

      dnsPolicy: ClusterFirst
      restartPolicy: Always
```

---

## 6. Service (ClusterIP on Port 4001)

```yaml
# products-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: products-subgraph
  namespace: team-products
  labels:
    app.kubernetes.io/name: products-subgraph
    app.kubernetes.io/part-of: graphql-platform
    team: products
spec:
  type: ClusterIP

  selector:
    app.kubernetes.io/name: products-subgraph

  ports:
    - name: http
      # port 4001: the subgraph port. Apollo Router's supergraph config
      # references this service as:
      #   products: http://products-subgraph.team-products.svc.cluster.local:4001/graphql
      # The /graphql path suffix must match your subgraph's router registration.
      port: 4001
      targetPort: http
      protocol: TCP
    - name: metrics
      port: 9091
      targetPort: metrics
      protocol: TCP

  sessionAffinity: None
  # sessionAffinity: None is correct for stateless subgraphs. DataLoader state is
  # per-request (created and discarded within a single operation). No session state
  # is held between requests at the subgraph layer.
```

---

## 7. NetworkPolicy — Router-Only Ingress

```yaml
# products-networkpolicy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: products-subgraph-netpol
  namespace: team-products
  labels:
    app.kubernetes.io/name: products-subgraph
    app.kubernetes.io/part-of: graphql-platform
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: products-subgraph

  policyTypes:
    - Ingress
    - Egress

  ingress:
    # ONLY allow traffic from pods in the graphql-platform namespace (the router).
    # This is the critical security control for subgraphs: clients never have
    # direct HTTP access to a subgraph endpoint. All traffic must flow through
    # the router, which enforces authentication, persisted query allowlisting,
    # rate limiting, and field-level authorization.
    #
    # If a subgraph accepts direct client connections, the entire security model
    # (persisted queries, JWT validation, OPA policies) can be bypassed.
    - from:
        - namespaceSelector:
            matchLabels:
              app.kubernetes.io/part-of: graphql-platform
          podSelector:
            matchLabels:
              app.kubernetes.io/name: apollo-router
      ports:
        - protocol: TCP
          port: 4001

    # Allow Prometheus to scrape metrics from the monitoring namespace.
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 9091

  egress:
    # Allow outbound traffic to the products database (RDS PostgreSQL on port 5432).
    # The database is outside the cluster (AWS RDS), so we allow egress to port 5432
    # without a namespace selector (external IPs cannot be matched by namespaceSelector).
    - ports:
        - protocol: TCP
          port: 5432

    # Allow outbound traffic to Redis (if using a cluster-internal Redis cache).
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: redis
      ports:
        - protocol: TCP
          port: 6379

    # Allow outbound to OpenTelemetry Collector for distributed tracing.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
      ports:
        - protocol: TCP
          port: 4317  # OTLP gRPC

    # DNS resolution (required for all hostname-based connections above).
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53

    # Allow HTTPS for any external API calls the subgraph makes
    # (image CDN, third-party pricing APIs, etc.).
    # If you know the specific external endpoints, replace this with explicit
    # CIDR blocks for those IPs. A blanket port-443 rule is permissive but
    # acceptable for most threat models — the subgraph cannot exfiltrate
    # sensitive data without also receiving it first, which requires the router
    # to send a query, which requires the router to receive a valid client request.
    - ports:
        - protocol: TCP
          port: 443
```

---

## 8. PodDisruptionBudget

```yaml
# products-pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: products-subgraph-pdb
  namespace: team-products
  labels:
    app.kubernetes.io/name: products-subgraph
    app.kubernetes.io/part-of: graphql-platform
spec:
  # minAvailable: 1 for subgraphs (compared to 2 for the router).
  # The router itself is highly available (3 replicas, minAvailable: 2).
  # A single available subgraph replica can still serve all traffic routed to it
  # by the router. The PDB ensures at least 1 pod is always available during
  # voluntary disruptions (node drains, cluster upgrades).
  #
  # If your subgraph handles extremely high traffic (>10k req/s), increase to
  # minAvailable: 2 to ensure continued low-latency service during disruptions.
  minAvailable: 1

  selector:
    matchLabels:
      app.kubernetes.io/name: products-subgraph
```

---

## 9. HPA for the Products Subgraph

```yaml
# products-hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: products-subgraph-hpa
  namespace: team-products
  labels:
    app.kubernetes.io/name: products-subgraph
    app.kubernetes.io/part-of: graphql-platform
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: products-subgraph

  # minReplicas: 3 for production (same reasoning as router).
  # During off-peak hours, you might lower this to 2 for cost savings if your
  # SLA tolerates the brief scale-up latency when traffic returns.
  minReplicas: 3
  maxReplicas: 15

  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          # 70% target for Node.js subgraphs: higher than the router's 60% because
          # Node.js is more predictable in CPU usage (single-threaded JS, bounded GC).
          # The router (Rust async) has less predictable CPU spikes during query planning.
          averageUtilization: 70

    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          # 75%: Node.js memory usage is relatively stable between GC cycles.
          # Scaling on memory catches DataLoader cache growth (unbounded DataLoader
          # without maxBatchSize can accumulate large in-flight maps).
          averageUtilization: 75

  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 3
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

---

## 10. ServiceMonitor for Prometheus

```yaml
# products-servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: products-subgraph
  namespace: monitoring
  labels:
    app: kube-prometheus-stack
    app.kubernetes.io/name: products-subgraph
    app.kubernetes.io/part-of: graphql-platform
    team: products
spec:
  jobLabel: app.kubernetes.io/name

  namespaceSelector:
    matchNames:
      - team-products

  selector:
    matchLabels:
      app.kubernetes.io/name: products-subgraph

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
        # team label from pod enables per-team dashboards in Grafana
        # without hard-coding namespace names in dashboard queries.
        - sourceLabels: [__meta_kubernetes_pod_label_team]
          targetLabel: team

      metricRelabelings:
        # dataloader_batch_size is a histogram with high cardinality.
        # Keep it but drop the per-batch-key label to prevent unbounded cardinality.
        - sourceLabels: [__name__]
          regex: "dataloader_batch_.*"
          targetLabel: batch_key
          replacement: "_aggregated"
          action: replace
```

---

## Applying the Full Subgraph Stack

```bash
# Apply in dependency order
kubectl apply -f products-namespace.yaml
kubectl apply -f products-serviceaccount.yaml
kubectl apply -f products-configmap.yaml
kubectl apply -f products-externalsecret.yaml

# Wait for ESO to sync the secret before the Deployment references it
kubectl wait externalsecret products-subgraph-secrets \
  --namespace team-products \
  --for=condition=Ready \
  --timeout=60s

# Apply the remaining resources
kubectl apply -f products-deployment.yaml
kubectl apply -f products-service.yaml
kubectl apply -f products-networkpolicy.yaml
kubectl apply -f products-pdb.yaml
kubectl apply -f products-hpa.yaml
kubectl apply -f products-servicemonitor.yaml

# Verify the Deployment is healthy
kubectl rollout status deployment/products-subgraph -n team-products

# Verify pods are spread across AZs
kubectl get pods -n team-products -o wide \
  -l app.kubernetes.io/name=products-subgraph \
  --sort-by='.spec.nodeName'
```

---

## Key Design Decisions

**Why is cpu request 250m for the subgraph versus 500m for the router?**
Apollo Router (Rust, multi-threaded async) uses multiple OS threads and can leverage
multiple CPU cores simultaneously — especially during query planning and parallel subgraph
fetch coordination. Node.js is single-threaded for JavaScript execution. During a typical
GraphQL resolution cycle, a Node.js subgraph awaits DataLoader batches (blocking I/O,
not CPU) for the majority of request time. The CPU burst happens during JSON parsing and
serialization. 250m request with 1000m limit allows the burst without over-provisioning
the baseline. If you migrate the subgraph to a multi-threaded runtime (Go, Rust, Java),
revisit both the request and limit.

**Why is the readiness probe on `/.well-known/apollo/server-health` rather than a custom
`{ __typename }` query?**
A `{ __typename }` health check query goes through the full GraphQL stack (parse, validate,
execute) on every probe. At a 10s interval across 3 pods, this is 18 unnecessary query
executions per minute, generating false traffic in analytics dashboards and query plan cache
noise. The `/.well-known/apollo/server-health` endpoint bypasses the GraphQL layer entirely
and checks only that the HTTP server is alive and the schema is loaded — exactly the right
readiness signal. Use a real query health check only if your readiness definition includes
"can execute a real query against the database."

**Why does the NetworkPolicy allow port 443 egress without destination restriction?**
Restricting egress to specific IP CIDRs for external APIs (third-party product data
enrichment, pricing services) requires maintaining the IP list as those services change
their infrastructure. For most threat models, the risk of a compromised subgraph exfiltrating
data via HTTPS is lower than the operational cost of breaking the service when a vendor
rotates their IP addresses. Teams with strict compliance requirements (PCI DSS, FedRAMP)
should replace the blanket port 443 rule with egress to known-good IP CIDRs and a firewall
egress gateway for all other outbound traffic.

**Why is minAvailable: 1 in the PDB rather than 2?**
A GraphQL subgraph is accessed through the router, which has its own 3-replica HA setup.
If one subgraph pod goes offline during a voluntary disruption (node drain), the router
continues sending traffic to the remaining pods. The router-level health check prevents
sending queries to the disrupted pod. A single remaining subgraph pod is sufficient to
serve traffic during the brief window (seconds to minutes) of a node drain. Setting
minAvailable: 2 for a 3-replica subgraph would slow down cluster maintenance operations
without meaningful reliability improvement, because the router's fault tolerance already
absorbs the subgraph pod count reduction.

---

## Related Documentation

- [router-deployment.md](./router-deployment.md) — router manifests that send traffic to this subgraph
- [hpa-config.md](./hpa-config.md) — advanced HPA patterns including VPA for subgraphs
- [Chapter 15 — Kubernetes Deployment](../../docs/15-kubernetes-deployment/README.md)
- [Chapter 14 — Observability](../../docs/14-observability/README.md)
- [examples/01-federation](../01-federation/) — the federation schema this subgraph implements
- [examples/10-open-telemetry](../10-open-telemetry/) — distributed tracing setup
