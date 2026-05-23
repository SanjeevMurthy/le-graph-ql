# Apollo Router — Complete Kubernetes Manifests

> Companion doc: [../../docs/15-kubernetes-deployment/](../../docs/15-kubernetes-deployment/)

This file contains production-ready Kubernetes manifests for deploying Apollo Router. Every
field is annotated with the reasoning behind its value, not just a description of what it
does. The manifests are written in dependency order: apply them top to bottom.

All manifests use the namespace `graphql-platform`. Subgraph namespaces follow the pattern
`team-<name>` and are covered in [subgraph-deployment.md](./subgraph-deployment.md).

---

## 1. Namespace

```yaml
# router-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: graphql-platform
  labels:
    # app.kubernetes.io labels are the Kubernetes-recommended labeling convention.
    # They enable consistent filtering across kubectl, Lens, k9s, and Helm.
    app.kubernetes.io/part-of: graphql-platform

    # team label is used by NetworkPolicy selectors to identify the owning team.
    # Without consistent team labels, namespaceSelector in NetworkPolicy must
    # match on name only, which breaks when you rename the namespace.
    team: platform

    # environment label allows you to apply policies (OPA Gatekeeper, Kyverno)
    # that enforce different rules per environment without separate clusters.
    environment: production

    # kubernetes.io/metadata.name is automatically set by Kubernetes >= 1.21.
    # Including it here documents that NetworkPolicy selectors can use it.
    # kubernetes.io/metadata.name: graphql-platform  (set automatically; do not include)
```

---

## 2. ServiceAccount with IRSA Annotation (AWS)

```yaml
# router-serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: apollo-router
  namespace: graphql-platform
  labels:
    app.kubernetes.io/name: apollo-router
    app.kubernetes.io/part-of: graphql-platform
  annotations:
    # eks.amazonaws.com/role-arn enables IAM Roles for Service Accounts (IRSA).
    # With IRSA, the pod's service account token is exchanged for temporary AWS
    # credentials scoped to exactly the IAM role specified here. This replaces
    # node-level IAM roles (which grant ALL pods on the node the same access)
    # and static IAM access key environment variables (which require rotation and
    # cannot be scoped per workload).
    #
    # The IAM role should have:
    #   - secretsmanager:GetSecretValue on the specific secret ARNs used by this service
    #   - No other permissions — principle of least privilege
    eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/apollo-router-irsa-role"

    # eks.amazonaws.com/token-expiration-seconds: how often the projected service
    # account token rotates. 3600 (1 hour) is the minimum. AWS STS tokens issued
    # via IRSA also expire at 1 hour, so aligning them prevents credential gaps.
    # Default is 86400 (24h) which is unnecessarily long for a production service.
    eks.amazonaws.com/token-expiration-seconds: "3600"

# Why a dedicated ServiceAccount per workload?
# - Audit: CloudTrail logs show which role (and therefore which service) accessed which secret
# - Blast radius: a compromised router pod can only access router secrets, not subgraph secrets
# - Rotation: the router role's permissions can be modified independently of other services
# - Compliance: IRSA satisfies SOC2 / ISO 27001 requirements for least-privilege credential access
automountServiceAccountToken: true
# automountServiceAccountToken: true is required for IRSA to inject the token volume.
# Set to false on ServiceAccounts for pods that do not need AWS API access.
```

---

## 3. ConfigMap — router.yaml

```yaml
# router-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: apollo-router-config
  namespace: graphql-platform
  labels:
    app.kubernetes.io/name: apollo-router
    app.kubernetes.io/part-of: graphql-platform
data:
  # router.yaml is mounted into the pod at /app/config/router.yaml.
  # Environment variable interpolation in this file uses ${VAR_NAME} syntax,
  # which Apollo Router resolves at startup from the pod environment.
  # Secrets (APOLLO_KEY, REDIS_URL) are injected via envFrom pointing to the
  # Kubernetes Secret synced by ExternalSecret — they never appear in this ConfigMap.
  router.yaml: |
    # supergraph: configure how the router communicates with subgraphs.
    # The schema is provided via --supergraph flag at startup (or fetched from
    # Apollo Uplink when managed federation is used).
    supergraph:
      # listen: the address the router binds to inside the container.
      # 0.0.0.0 is required in Kubernetes — 127.0.0.1 would prevent the
      # Kubernetes health probes (originating from the node) from reaching the pod.
      listen: "0.0.0.0:4000"

      # introspection: false disables the GraphQL introspection endpoint in production.
      # Introspection reveals your full schema to anyone with HTTP access.
      # Enable in staging/dev, disable in production.
      introspection: false

    # sandbox: false disables the Apollo Sandbox UI.
    # The sandbox is useful in development but should never be exposed in production.
    sandbox:
      enabled: false

    homepage:
      enabled: false

    # headers: configure which request headers flow from clients to subgraphs.
    headers:
      all:
        request:
          # Forward the authorization header so subgraphs can validate JWTs.
          - propagate:
              matching: "^authorization$"
          # Forward x-request-id for distributed tracing correlation.
          - propagate:
              matching: "^x-request-id$"
          # Forward x-client-version for analytics and compatibility checks.
          - propagate:
              matching: "^x-client-version$"

    # cors: Cross-Origin Resource Sharing configuration.
    cors:
      # origins: explicitly list allowed origins. Never use "*" in production
      # as it permits any website to make authenticated requests to your API.
      origins:
        - "https://app.example.com"
        - "https://admin.example.com"
      # allow_credentials: true required if clients send cookies or Authorization headers.
      allow_credentials: true
      # max_age: how long browsers cache the preflight response.
      # 86400 = 24 hours — reduces preflight request overhead.
      max_age: 86400

    # apq: Automated Persisted Queries.
    apq:
      enabled: true
      router:
        cache:
          redis:
            # REDIS_URL injected from Secret — format: redis://host:port
            urls:
              - "${REDIS_URL}"
            # ttl: 24 hours — long enough to survive a rolling deploy.
            # Short enough that stale operations from a schema migration are evicted.
            ttl: 86400

    # persisted_queries: manifest-based PQ enforcement.
    persisted_queries:
      enabled: true
      safelist:
        enabled: true
        # require_id: true rejects any operation not in the registered manifest.
        # This is the primary security control for lockdown mode.
        # See examples/05-persisted-queries/manifest-based-pq.md for the full workflow.
        require_id: true

    # traffic_shaping: configure timeouts and retry behavior per subgraph.
    traffic_shaping:
      all:
        # timeout: maximum time to wait for any subgraph response.
        # 30s is appropriate for GraphQL — most queries should complete in <500ms,
        # but some analytics or search queries legitimately take longer.
        # Setting this too low causes spurious 504s; too high lets hung subgraphs
        # block the router worker thread pool.
        timeout: 30s

        # experimental_retry: automatic retry on subgraph connection errors.
        # Only safe for idempotent operations (queries). Mutations are never retried.
        experimental_retry:
          min_per_sec: 10
          ttl: 10s
          retry_mutations: false

    # telemetry: observability configuration.
    telemetry:
      apollo:
        # APOLLO_KEY and APOLLO_GRAPH_REF injected from Secret
        key: "${APOLLO_KEY}"
        graph_ref: "${APOLLO_GRAPH_REF}"
        # field_level_instrumentation_sampler: sample 1% of field-level metrics.
        # Field-level metrics are expensive — 1% sampling gives meaningful data
        # without impacting throughput.
        field_level_instrumentation_sampler: 0.01

      exporters:
        tracing:
          otlp:
            # OTEL_EXPORTER_OTLP_ENDPOINT injected from ConfigMap (not a secret)
            endpoint: "${OTEL_ENDPOINT}"
            protocol: grpc
            # batch_processor: buffer spans before exporting to reduce network overhead.
            batch_processor:
              max_export_batch_size: 512
              max_queue_size: 2048
              scheduled_delay: 5s

      metrics:
        prometheus:
          # enabled: true exposes /metrics on a separate port (9090).
          # Scraped by ServiceMonitor (see section 10).
          # Keeping metrics on a separate port prevents clients from accessing
          # internal cardinality-unlimited metrics.
          enabled: true
          listen: "0.0.0.0:9090"
          path: /metrics
```

---

## 4. ExternalSecret — AWS Secrets Manager to Kubernetes Secret

```yaml
# router-externalsecret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: apollo-router-secrets
  namespace: graphql-platform
  labels:
    app.kubernetes.io/name: apollo-router
    app.kubernetes.io/part-of: graphql-platform
spec:
  # refreshInterval: how often ESO polls Secrets Manager for changes.
  # 1 hour is appropriate for secrets that change infrequently (API keys, connection strings).
  # For frequently-rotated secrets (DB passwords with 24h rotation), use 15m or less.
  # A shorter interval increases Secrets Manager API call costs.
  refreshInterval: "1h"

  secretStoreRef:
    # ClusterSecretStore is cluster-scoped and can be referenced from any namespace.
    # SecretStore is namespace-scoped and must be created in the same namespace.
    # Use ClusterSecretStore for shared infrastructure (AWS credentials) and
    # SecretStore for tenant-specific credentials.
    kind: ClusterSecretStore
    name: aws-secrets-manager

  target:
    # name: the Kubernetes Secret that ESO will create/update.
    # The Deployment references this Secret via envFrom.
    name: apollo-router-secrets
    creationPolicy: Owner
    # deletionPolicy: Retain prevents the Kubernetes Secret from being deleted
    # when the ExternalSecret is deleted. This protects against accidental data loss
    # during namespace cleanup. Change to Delete for ephemeral environments.
    deletionPolicy: Retain

    template:
      # engineVersion: v2 supports complex templating with sprig functions.
      engineVersion: v2
      type: Opaque

  data:
    - secretKey: APOLLO_KEY
      remoteRef:
        # key: the full ARN or name of the secret in Secrets Manager.
        # Using full ARN avoids naming collisions across AWS accounts.
        key: "arn:aws:secretsmanager:us-east-1:123456789012:secret:graphql-platform/apollo-key"
        # version: AWSCURRENT fetches the currently active version.
        # To pin to a specific version during rotation, use the version ID.
        version: "AWSCURRENT"

    - secretKey: APOLLO_GRAPH_REF
      remoteRef:
        key: "arn:aws:secretsmanager:us-east-1:123456789012:secret:graphql-platform/apollo-graph-ref"
        version: "AWSCURRENT"

    - secretKey: REDIS_URL
      remoteRef:
        key: "arn:aws:secretsmanager:us-east-1:123456789012:secret:graphql-platform/redis-url"
        # property: extracts a specific JSON key from a JSON-formatted secret.
        # The secret in Secrets Manager is {"url":"redis://...","password":"..."}
        property: "url"
        version: "AWSCURRENT"

    - secretKey: OTEL_ENDPOINT
      remoteRef:
        key: "arn:aws:secretsmanager:us-east-1:123456789012:secret:graphql-platform/otel-endpoint"
        version: "AWSCURRENT"
```

---

## 5. Deployment

```yaml
# router-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: apollo-router
  namespace: graphql-platform
  labels:
    app.kubernetes.io/name: apollo-router
    app.kubernetes.io/version: "1.40.0"
    app.kubernetes.io/part-of: graphql-platform
    app.kubernetes.io/managed-by: helm
spec:
  # replicas: 3 provides fault tolerance across 3 AZs.
  # With topologySpreadConstraints below, one pod per AZ.
  # Minimum replicas for production is 2 (for zero-downtime rolling deploys).
  # 3 allows one pod to be unavailable (AZ failure, rolling update) while still
  # satisfying minAvailable: 2 in the PodDisruptionBudget.
  replicas: 3

  # revisionHistoryLimit: retain last 5 ReplicaSets for quick rollback.
  # Higher values consume etcd storage. 5 is a reasonable balance.
  revisionHistoryLimit: 5

  selector:
    matchLabels:
      app.kubernetes.io/name: apollo-router

  strategy:
    type: RollingUpdate
    rollingUpdate:
      # maxSurge: allow 1 extra pod beyond desired replicas during rollout.
      # With replicas: 3, this means up to 4 pods run simultaneously during a deploy.
      # Higher maxSurge speeds up deployments but requires more cluster capacity.
      maxSurge: 1
      # maxUnavailable: 0 ensures the deployment never goes below 3 healthy pods.
      # Combined with maxSurge: 1, this is the "blue-green" rolling strategy:
      # bring up new pod, verify it is healthy, then terminate old pod.
      maxUnavailable: 0

  template:
    metadata:
      labels:
        app.kubernetes.io/name: apollo-router
        app.kubernetes.io/version: "1.40.0"
        app.kubernetes.io/part-of: graphql-platform
      annotations:
        # prometheus.io annotations are the legacy scrape config approach.
        # ServiceMonitor (section 10) is preferred with Prometheus Operator.
        # Keep these annotations for compatibility with older Prometheus setups.
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics"

        # checksum/config: rolling hash of the ConfigMap content.
        # When the ConfigMap changes, this annotation changes, triggering a
        # rolling restart of pods. Without this, Kubernetes does not automatically
        # restart pods when ConfigMap content changes.
        # In Helm this is: checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
        checksum/config: "PLACEHOLDER_REPLACED_BY_HELM"

    spec:
      serviceAccountName: apollo-router
      # serviceAccountName must match the ServiceAccount with the IRSA annotation.
      # Without this, the pod gets the default ServiceAccount which has no AWS permissions.

      # terminationGracePeriodSeconds: how long Kubernetes waits after sending SIGTERM
      # before force-killing the pod. Apollo Router handles SIGTERM by stopping accepting
      # new connections while finishing in-flight requests.
      # 30s is generous for GraphQL — most requests complete in <500ms.
      # Set this higher (60s) if you support long-running subscriptions over HTTP.
      terminationGracePeriodSeconds: 30

      # securityContext: pod-level security settings applied to all containers.
      securityContext:
        # runAsNonRoot: prevents the container from running as root (UID 0).
        # Apollo Router's official image runs as UID 1000.
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        # fsGroup: ensures mounted volumes are accessible to the container's GID.
        # Set to match runAsGroup so volume mounts (ConfigMap, tmpfs) are readable.
        fsGroup: 1000
        # seccompProfile: RuntimeDefault applies the container runtime's default
        # seccomp profile, which blocks dangerous syscalls. This is the recommended
        # baseline for all production workloads in Kubernetes 1.25+.
        seccompProfile:
          type: RuntimeDefault

      # topologySpreadConstraints: distribute pods across availability zones.
      # Without this, Kubernetes might schedule all 3 pods in the same AZ,
      # making the service vulnerable to a single AZ failure.
      topologySpreadConstraints:
        - maxSkew: 1
          # topology key for AZ distribution. In AWS EKS, nodes are labeled
          # with topology.kubernetes.io/zone automatically.
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          # DoNotSchedule means Kubernetes refuses to schedule a pod if it would
          # violate the spread constraint. Use ScheduleAnyway for less strict behavior
          # (when you prefer availability over balance).
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: apollo-router

        - maxSkew: 1
          # Also spread across nodes within an AZ to protect against node failure.
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          # ScheduleAnyway for hostname: we prefer spread but will accept co-location
          # on the same node if no alternative is available (e.g., single-AZ dev cluster).
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: apollo-router

      # initContainers: run to completion before main container starts.
      # Use for: schema validation, config validation, dependency health checks.
      initContainers:
        - name: config-validator
          image: ghcr.io/apollographql/router:v1.40.0
          command:
            - /dist/router
            - "--config"
            - /app/config/router.yaml
            - "--schema"
            - /app/config/supergraph.graphql
            - "--validate"
          # The --validate flag parses and validates the config and schema without
          # starting the server. If this fails, the pod never reaches Running state,
          # which blocks the rolling deploy and preserves the old version.
          volumeMounts:
            - name: router-config
              mountPath: /app/config
              readOnly: true
          resources:
            # Init containers should have minimal resources — they run once and exit.
            limits:
              cpu: "200m"
              memory: "128Mi"
            requests:
              cpu: "50m"
              memory: "64Mi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]

      containers:
        - name: apollo-router
          image: ghcr.io/apollographql/router:v1.40.0
          # image tag: always use a specific version, never "latest" in production.
          # "latest" makes rollbacks impossible and causes unexpected version changes
          # when pods are rescheduled. Pin to a semver tag and update via Helm.

          args:
            - "--config"
            - /app/config/router.yaml
            # --supergraph: path to the composed supergraph schema.
            # In managed federation (Apollo Uplink), omit this flag and configure
            # the Apollo key instead — the router fetches the schema from Uplink.
            # For self-hosted supergraph, bake the schema into the ConfigMap or
            # a separate init container that downloads it from your schema registry.
            - "--supergraph"
            - /app/config/supergraph.graphql
            # --log: structured JSON logging for parsing by log aggregators (Datadog, Loki).
            # Use "info" in production. "debug" generates ~10x more log volume.
            - "--log"
            - "info"

          ports:
            - name: http
              containerPort: 4000
              protocol: TCP
            - name: metrics
              containerPort: 9090
              protocol: TCP

          # envFrom: inject the entire Secret as environment variables.
          # This keeps the Deployment manifest free of secret values.
          # The Secret is created/updated by ExternalSecret (section 4).
          envFrom:
            - secretRef:
                name: apollo-router-secrets

          # env: non-secret environment variables.
          # K8s downward API provides pod metadata without querying the API server.
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: NODE_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.hostIP

          resources:
            requests:
              # cpu: 500m (0.5 cores) is a realistic baseline for Apollo Router
              # handling moderate traffic (~500 req/s). The router is event-loop
              # based (Rust async) and is IO-bound, not CPU-bound. Requests saturate
              # CPU primarily during query planning (complex nested queries) and
              # JSON serialization of large responses.
              cpu: "500m"
              # memory: 512Mi covers the APQ in-memory cache (if Redis unavailable),
              # query plan cache (default 512 entries), and in-flight request buffers.
              # Router memory usage is predictable and bounded — it does not grow
              # with traffic volume, only with query complexity and cache configuration.
              memory: "512Mi"
            limits:
              # cpu limit: 2000m (2 cores). CPU is burstable — this allows the router
              # to handle traffic spikes (e.g., marketing campaigns) without throttling.
              # Setting the CPU limit too low causes CFS throttling which adds latency
              # worse than CPU saturation would. Better to allow burst than to throttle.
              cpu: "2000m"
              # memory limit: 2Gi. If the router exceeds this, the pod is OOM-killed
              # and restarted. 2Gi provides generous headroom above normal usage (512Mi)
              # to handle response buffering for large query results. If you see
              # OOM kills, investigate large query responses or query plan cache growth.
              memory: "2Gi"

          readinessProbe:
            httpGet:
              # /.well-known/apollo/server-health returns 200 when the router is ready.
              # It checks that: (1) the schema is loaded, (2) APQ cache is initialized,
              # (3) the router can accept connections. It does NOT check subgraph health.
              # Subgraph health is the subgraph's responsibility.
              path: /.well-known/apollo/server-health
              port: http
            # initialDelaySeconds: how long to wait before the first probe.
            # Apollo Router starts fast (<2s), but give it 5s for schema loading
            # and cache initialization.
            initialDelaySeconds: 5
            # periodSeconds: probe frequency. 10s is standard — short enough to detect
            # issues quickly, long enough to not spam the endpoint.
            periodSeconds: 10
            # failureThreshold: how many consecutive failures before the pod is
            # marked NotReady and removed from Service endpoints. 3 failures (30s)
            # gives the router time to recover from transient issues before traffic stops.
            failureThreshold: 3
            # successThreshold: how many consecutive successes to mark pod as Ready.
            # 1 is standard for readinessProbe.
            successThreshold: 1
            timeoutSeconds: 5

          livenessProbe:
            httpGet:
              path: /.well-known/apollo/server-health
              port: http
            # initialDelaySeconds: liveness probe should start later than readiness.
            # If liveness fires before the app is ready, it kills a healthy pod that
            # is still initializing. 15s ensures readiness has already passed.
            initialDelaySeconds: 15
            periodSeconds: 20
            # failureThreshold: higher than readiness — we want liveness to kill only
            # truly stuck pods, not pods under temporary load. 3 failures (60s) means
            # the pod is unresponsive for a full minute before being restarted.
            failureThreshold: 3
            timeoutSeconds: 5

          lifecycle:
            preStop:
              exec:
                # preStop hook runs BEFORE SIGTERM is sent.
                # sleep 5 gives the load balancer (Ingress, kube-proxy) time to
                # propagate the pod's removal from Endpoints before the router stops
                # accepting connections. Without this sleep, in-flight requests from
                # the load balancer arrive at the pod after it has started shutting down,
                # causing connection reset errors visible to clients.
                # 5s is sufficient for kube-proxy and most cloud LBs to deregister.
                command: ["/bin/sh", "-c", "sleep 5"]

          securityContext:
            # allowPrivilegeEscalation: false prevents the process from gaining
            # more privileges than its parent (e.g., via setuid binaries).
            allowPrivilegeEscalation: false
            # readOnlyRootFilesystem: true prevents the container from writing to
            # the container filesystem. Apollo Router does not need to write to disk
            # at runtime — all config is injected via ConfigMap mounts. This limits
            # the impact of a container escape or code injection attack.
            readOnlyRootFilesystem: true
            capabilities:
              # Drop ALL Linux capabilities. Apollo Router requires no special capabilities.
              # Most container workloads should drop ALL and add back only what is needed.
              drop: ["ALL"]

          volumeMounts:
            - name: router-config
              mountPath: /app/config
              readOnly: true
            # tmp: writable tmpfs mount for any runtime temp files.
            # Required because readOnlyRootFilesystem is true but some libraries
            # (e.g., glibc resolver) write to /tmp.
            - name: tmp
              mountPath: /tmp

      volumes:
        - name: router-config
          configMap:
            name: apollo-router-config
            # defaultMode: 0444 makes mounted files read-only by all users.
            # 0444 = r--r--r--. The container runs as UID 1000 (group 1000),
            # which can read but not write the config.
            defaultMode: 0444
        - name: tmp
          emptyDir:
            # medium: Memory makes /tmp a tmpfs (RAM-backed) mount.
            # Faster than disk, cleaned on pod restart, and invisible to the
            # container filesystem (not persisted to the node).
            medium: Memory
            # sizeLimit: cap the tmpfs size to prevent a misbehaving process
            # from filling node memory via /tmp writes.
            sizeLimit: 64Mi

      # dnsPolicy: ClusterFirst uses kube-dns for service discovery.
      # This is the default and correct setting for most pods.
      dnsPolicy: ClusterFirst

      # restartPolicy: Always is required for Deployment pods.
      restartPolicy: Always
```

---

## 6. Service (ClusterIP)

```yaml
# router-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: apollo-router
  namespace: graphql-platform
  labels:
    app.kubernetes.io/name: apollo-router
    app.kubernetes.io/part-of: graphql-platform
spec:
  # type: ClusterIP means the Service is only reachable inside the cluster.
  # External traffic reaches the router via the Ingress (section 7).
  # Never use type: LoadBalancer for individual microservices — it creates
  # one cloud LB per service, which is expensive and hard to manage at scale.
  type: ClusterIP

  selector:
    app.kubernetes.io/name: apollo-router

  ports:
    - name: http
      port: 4000
      targetPort: http
      protocol: TCP
    - name: metrics
      # Expose metrics on a separate port so the Ingress can restrict
      # external access to port 4000 only, while ServiceMonitor can still
      # scrape /metrics on port 9090 from inside the cluster.
      port: 9090
      targetPort: metrics
      protocol: TCP

  # sessionAffinity: None means requests are distributed across all healthy pods
  # without sticky sessions. Apollo Router is stateless — all state lives in Redis
  # (APQ cache, query plan cache) or in the upstream subgraphs. Sticky sessions
  # would reduce the effectiveness of pod autoscaling and cause uneven load distribution.
  sessionAffinity: None
```

---

## 7. Ingress (NGINX)

```yaml
# router-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: apollo-router
  namespace: graphql-platform
  labels:
    app.kubernetes.io/name: apollo-router
    app.kubernetes.io/part-of: graphql-platform
  annotations:
    # kubernetes.io/ingress.class is deprecated in favour of spec.ingressClassName
    # in Kubernetes 1.18+. Use spec.ingressClassName below.

    # nginx.ingress.kubernetes.io/ssl-redirect: redirect HTTP to HTTPS.
    # Required — never serve a GraphQL API over plain HTTP in production.
    nginx.ingress.kubernetes.io/ssl-redirect: "true"

    # nginx.ingress.kubernetes.io/force-ssl-redirect: enforce HTTPS even when
    # X-Forwarded-Proto header claims the request is already HTTPS.
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"

    # proxy-connect-timeout: time to establish a TCP connection to the backend pod.
    # 15s is generous — within the cluster, connections should establish in <10ms.
    # A high timeout here helps during rolling deploys when new pods are starting.
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "15"

    # proxy-read-timeout: time to wait for the backend to send response data.
    # 120s accommodates long-running GraphQL subscriptions (which use HTTP streaming)
    # and slow analytics queries. Standard REST services use 60s.
    # If you see clients timing out on subscriptions, increase this further.
    nginx.ingress.kubernetes.io/proxy-read-timeout: "120"

    # proxy-send-timeout: time to transmit the request to the backend.
    # 30s is sufficient for even the largest GraphQL mutation payloads.
    nginx.ingress.kubernetes.io/proxy-send-timeout: "30"

    # proxy-body-size: maximum request body size allowed by NGINX.
    # GraphQL query bodies are typically small (<10KB), but batched requests and
    # file uploads (multipart) can be larger. 10m (10 MB) is permissive enough
    # for file upload mutations while blocking absurdly large payloads.
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"

    # Rate limiting: protect against DDoS and API abuse.
    # limit-rps: requests per second per client IP. 100 rps is appropriate for
    # an authenticated API where each client IP represents a single user session.
    # For CDN-fronted deployments, rate limit on authenticated user ID header instead.
    nginx.ingress.kubernetes.io/limit-rps: "100"
    nginx.ingress.kubernetes.io/limit-connections: "20"

    # limit-whitelist: exempt your own internal health check IPs from rate limiting.
    # Without this, monitoring systems trigger rate limit alerts on their health checks.
    nginx.ingress.kubernetes.io/limit-whitelist: "10.0.0.0/8,172.16.0.0/12"

    # Enable CORS at the Ingress level only if the router itself does NOT handle CORS.
    # If router.yaml has CORS configured (which it does in our ConfigMap), do NOT
    # add CORS annotations here — double-CORS headers cause browser errors.
    # nginx.ingress.kubernetes.io/enable-cors: "false"  (do not enable — router handles CORS)

    # Upstream keepalive: maintain persistent connections to router pods.
    # This reduces TCP handshake overhead for high-frequency GraphQL clients.
    nginx.ingress.kubernetes.io/upstream-keepalive-connections: "50"
    nginx.ingress.kubernetes.io/upstream-keepalive-requests: "100"

    # X-Forwarded-For: preserve the original client IP for rate limiting and audit logs.
    nginx.ingress.kubernetes.io/use-forwarded-headers: "true"
    nginx.ingress.kubernetes.io/compute-full-forwarded-for: "true"
spec:
  # ingressClassName: nginx specifies which Ingress Controller handles this resource.
  # Must match the IngressClass resource installed by your NGINX Ingress Controller.
  ingressClassName: nginx

  tls:
    - hosts:
        - api.example.com
      # secretName: references a Kubernetes TLS Secret containing the certificate
      # and private key. Managed by cert-manager with Let's Encrypt in most setups.
      secretName: apollo-router-tls

  rules:
    - host: api.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: apollo-router
                port:
                  name: http
```

---

## 8. PodDisruptionBudget

```yaml
# router-pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: apollo-router-pdb
  namespace: graphql-platform
  labels:
    app.kubernetes.io/name: apollo-router
    app.kubernetes.io/part-of: graphql-platform
spec:
  # minAvailable: 2 means Kubernetes will not voluntarily disrupt more than 1 pod
  # at a time. With replicas: 3, this ensures at least 2 pods are always running
  # during node drains (maintenance, cluster upgrades), voluntary evictions, or
  # rolling restarts triggered by tools like kubectl rollout restart.
  #
  # Why 2 and not 1? With minAvailable: 1, a node drain could coincide with a
  # pod crash and leave you with 0 ready pods. 2 provides the margin.
  #
  # Why not maxUnavailable: 1? maxUnavailable and minAvailable are equivalent
  # here (replicas=3), but minAvailable is easier to reason about as traffic grows:
  # "always keep at least 2 pods" holds regardless of current replica count.
  minAvailable: 2

  selector:
    matchLabels:
      app.kubernetes.io/name: apollo-router
```

---

## 9. NetworkPolicy

```yaml
# router-networkpolicy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: apollo-router-netpol
  namespace: graphql-platform
  labels:
    app.kubernetes.io/name: apollo-router
    app.kubernetes.io/part-of: graphql-platform
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: apollo-router

  # policyTypes: declaring both Ingress and Egress is explicit about intent.
  # If you declare only Ingress, all Egress is still allowed by default.
  # Declaring both forces you to explicitly permit each Egress destination,
  # which is the secure baseline.
  policyTypes:
    - Ingress
    - Egress

  ingress:
    # Allow inbound traffic from the NGINX Ingress Controller namespace only.
    # The ingress controller needs to reach router pods on port 4000.
    # All other ingress is blocked — including direct pod-to-pod access from
    # other namespaces, preventing lateral movement.
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - protocol: TCP
          port: 4000

    # Allow Prometheus (or any monitoring pod with the label) to scrape metrics.
    # Keeping metrics on port 9090 means this rule does not need to overlap with
    # the production traffic rule on port 4000.
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 9090

  egress:
    # Allow outbound traffic to each team's subgraph namespace on port 4001.
    # Adding a new subgraph team requires adding a new egress rule here.
    # This is intentionally explicit — you must consciously permit each subgraph,
    # preventing accidental connectivity to unrelated services.
    - to:
        - namespaceSelector:
            matchLabels:
              team: products
      ports:
        - protocol: TCP
          port: 4001

    - to:
        - namespaceSelector:
            matchLabels:
              team: users
      ports:
        - protocol: TCP
          port: 4001

    - to:
        - namespaceSelector:
            matchLabels:
              team: orders
      ports:
        - protocol: TCP
          port: 4001

    # Allow outbound traffic to Redis for APQ cache and query plan cache.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: redis
      ports:
        - protocol: TCP
          port: 6379

    # Allow outbound traffic to the OpenTelemetry Collector.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
      ports:
        - protocol: TCP
          port: 4317  # OTLP gRPC

    # Allow DNS resolution (kube-dns). Without this, all hostname lookups fail.
    # Port 53 UDP/TCP is required for DNS.
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

    # Allow outbound HTTPS to Apollo GraphOS Uplink (schema and PQ manifest sync).
    # Uplink is a public endpoint; we allow port 443 to all destinations.
    # If you have strict egress policies, pin this to Apollo's IP ranges.
    - ports:
        - protocol: TCP
          port: 443
```

---

## 10. ServiceMonitor (Prometheus Operator)

```yaml
# router-servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: apollo-router
  # ServiceMonitor can be in a different namespace from the target Service.
  # The Prometheus Operator's namespaceSelector in the Prometheus resource
  # determines which namespaces it watches for ServiceMonitors.
  # Putting it in the monitoring namespace keeps all monitoring config centralized.
  namespace: monitoring
  labels:
    # app label must match the label selector in the Prometheus resource's
    # serviceMonitorSelector. Without this, the ServiceMonitor is not picked up.
    app: kube-prometheus-stack
    app.kubernetes.io/name: apollo-router
    app.kubernetes.io/part-of: graphql-platform
spec:
  # jobLabel: the label on the Service to use as the Prometheus job label.
  # app.kubernetes.io/name = "apollo-router" becomes job="apollo-router" in metrics.
  jobLabel: app.kubernetes.io/name

  # namespaceSelector: which namespaces to look for matching Services.
  namespaceSelector:
    matchNames:
      - graphql-platform

  selector:
    matchLabels:
      app.kubernetes.io/name: apollo-router

  endpoints:
    - port: metrics
      # path: /metrics is the standard Prometheus exposition path.
      # Apollo Router with prometheus telemetry enabled serves metrics here.
      path: /metrics
      # interval: scrape every 15 seconds. Standard for most workloads.
      # Apollo Router metrics include histogram buckets for request durations,
      # APQ cache hit/miss counters, and query plan cache statistics.
      interval: 15s
      # scrapeTimeout: must be less than interval.
      scrapeTimeout: 10s

      # relabelings: rewrite or add labels to scraped metrics.
      relabelings:
        # Add namespace and pod labels to every metric for cross-dimensional queries.
        - sourceLabels: [__meta_kubernetes_pod_name]
          targetLabel: pod
        - sourceLabels: [__meta_kubernetes_namespace]
          targetLabel: namespace
        # Add AZ label for per-zone capacity planning queries.
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node

      # metricRelabelings: filter or rename metrics after scraping.
      metricRelabelings:
        # Drop high-cardinality per-operation metrics that are already captured
        # by Apollo Studio at higher quality. Keeping them in Prometheus would
        # create unbounded label cardinality.
        # apollo_router_graphql_requests_total has an "operation_name" label
        # that creates one time series per unique operation name.
        # Aggregate by dropping the operation_name label for this counter.
        - sourceLabels: [__name__, operation_name]
          regex: "apollo_router_graphql_requests_total;.+"
          targetLabel: operation_name
          replacement: "_aggregated"
          action: replace
```

---

## Key Design Decisions

**Why ClusterIP instead of LoadBalancer for the Service?**
Creating a LoadBalancer Service for each microservice creates one cloud load balancer per
service, which is expensive at scale (an ALB in AWS costs ~$18/month plus data transfer).
The Ingress resource consolidates all external traffic through a single load balancer
(the Ingress Controller). ClusterIP services are internal to the cluster and cost nothing.

**Why is the metrics port separate from the application port?**
Exposing metrics on port 9090 (not 4000) means the Ingress can route port 4000 traffic
to clients while keeping metrics unreachable from outside the cluster. Without separation,
you would need Ingress path-based restrictions to block `/metrics`, which are easy to
misconfigure. Port separation is structurally secure.

**Why is terminationGracePeriodSeconds 30 and the preStop hook only 5 seconds?**
The preStop hook runs first (sleep 5), then SIGTERM is sent, then Kubernetes waits
terminationGracePeriodSeconds minus the preStop duration for the process to exit.
In practice: 5s drain window for LB deregistration, then up to 25s for in-flight requests
to complete. Most GraphQL requests finish in under 500ms, so the 25s window is ample.
Subscriptions that last longer should be explicitly terminated by the client when the
connection reset error occurs during deployment.

**Why topologySpreadConstraints across both AZ and hostname?**
AZ spread alone does not protect against two pods on the same node in the same AZ.
Node spread with `ScheduleAnyway` is a best-effort preference — it will not block scheduling
if the cluster is small. AZ spread with `DoNotSchedule` is a hard requirement — the cluster
must have nodes in at least 3 AZs for the Deployment to reach 3 replicas. This is an
intentional design choice: if the cluster is not properly distributed, we want the
Deployment to fail visibly rather than silently co-locating pods.

---

## Related Documentation

- [hpa-config.md](./hpa-config.md) — horizontal pod autoscaling for the router
- [subgraph-deployment.md](./subgraph-deployment.md) — subgraph manifests
- [Chapter 15 — Kubernetes Deployment](../../docs/15-kubernetes-deployment/README.md)
- [examples/02-apollo-router](../02-apollo-router/) — full router.yaml configuration
- [examples/05-persisted-queries](../05-persisted-queries/) — persisted query setup referenced in ConfigMap
