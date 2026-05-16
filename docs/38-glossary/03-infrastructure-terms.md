# 03 — Infrastructure, Observability, and Operational Terms

> **Purpose:** Alphabetical definitions for infrastructure, observability, Kubernetes, service mesh, and reliability engineering terms used across this documentation. Each entry defines the term, explains why it matters for GraphQL platform operations, and links to the section where it is covered in depth.

---

**Alert Rule** — A Prometheus rule that evaluates a PromQL expression on a configured interval and fires an alert (via Alertmanager) when the expression evaluates to true. For GraphQL platforms, the most important alert rules target: SLO error budget burn rate (multi-window multi-burn-rate rules), subgraph error rates, and p99 latency thresholds. Alert rules are defined in YAML and deployed alongside the router and subgraph services. *See also:* Alertmanager, PromQL, SLO, Multi-Window Multi-Burn-Rate. *Covered in depth:* Section 14.

---

**Alertmanager** — The Prometheus component that receives alerts from Prometheus servers, deduplicates them, groups them by label sets, applies silences and inhibition rules, and routes them to notification receivers (PagerDuty, Slack, email). For a GraphQL platform, Alertmanager is configured with a routing tree that maps alert labels (severity, team, subgraph_name) to the appropriate notification channel. SEV1 alerts route to PagerDuty; SEV3 alerts route to Slack. *See also:* Alert Rule, Prometheus, SLO. *Covered in depth:* Section 14.

---

**ArgoCD** — A GitOps continuous delivery tool for Kubernetes that declaratively manages application state by syncing Kubernetes manifests from a Git repository. ArgoCD watches a Git repository, detects drift between the declared state in Git and the live state in the cluster, and automatically (or manually, depending on configuration) applies changes. For GraphQL platform teams, ArgoCD manages router deployments, subgraph deployments, and observability stack (Prometheus, Grafana, Loki) deployments via GitOps workflows. *See also:* GitOps, Helm, Helmfile. *Covered in depth:* Section 15.

---

**Backstage** — An open-source Internal Developer Platform (IDP) framework developed by Spotify, used to build self-service developer portals. In a GraphQL platform context, Backstage integrates with the schema registry to provide a subgraph catalog (showing every subgraph, its owner, its schema, and its SLOs), a service ownership map, golden path templates for new subgraph onboarding, and documentation search. The GraphQL schema can be surfaced in Backstage as a TechDoc or via a custom plugin. *See also:* Golden Path. *Covered in depth:* Section 20.

---

**Baggage (OTel context propagation)** — A key-value store that is propagated alongside a distributed trace, carried in HTTP headers. Unlike trace context (which identifies the trace and span), Baggage carries arbitrary application-level data across service boundaries — for example, the GraphQL operation name or the client identifier. In a federated supergraph, Baggage enables the router to propagate metadata (such as the original operation name) to subgraphs, where it appears in subgraph spans and logs. *See also:* OpenTelemetry, TraceContext, Span. *Covered in depth:* Section 14.

---

**Blue-Green Deployment** — A deployment strategy that maintains two identical production environments (blue and green). At any time, one is live (serving traffic) and the other is idle (the next release candidate). New releases are deployed to the idle environment, tested, and then traffic is switched. For GraphQL router upgrades, blue-green deployment provides instant rollback by switching traffic back to the previous environment without a Kubernetes rollout. The primary cost is running two identical router fleets simultaneously during the switchover window. *See also:* Canary Deployment. *Covered in depth:* Section 15.

---

**Burn Rate** — The rate at which an SLO error budget is consumed, expressed as a multiple of the steady-state consumption rate. A burn rate of 1x means the budget will be exhausted exactly at the end of the SLO window if the current error rate is sustained. A burn rate of 14.4x means the budget will be exhausted 14.4x faster — in approximately 2 days instead of 30. Burn rate alerts are the recommended alerting strategy for SLO-based alerting because they are sensitive to both the rate and the impact on the budget. *See also:* Error Budget, SLO, Multi-Window Multi-Burn-Rate, Alert Rule. *Covered in depth:* Section 14.

---

**Canary Deployment** — A deployment strategy that routes a small fraction of production traffic (e.g., 5%) to a new release candidate, while the majority of traffic continues to the stable version. Canary deployments reduce blast radius during rollouts — if the new release has bugs, only the canary fraction of users is affected. For GraphQL subgraphs, canary deployments can be implemented at the Kubernetes service level (weighted routing) or at the Apollo Router level (via traffic shaping configuration). *See also:* Blue-Green Deployment, HPA. *Covered in depth:* Section 15.

---

**Chaos Mesh** — A Kubernetes-native chaos engineering platform that injects faults into Kubernetes pods and network paths via CRDs (Custom Resource Definitions). Chaos Mesh supports: `NetworkChaos` (latency, packet loss, partition), `PodChaos` (pod kill, container kill, pod failure), `StressChaos` (CPU and memory stress), and `IOChaos` (file system fault injection). For GraphQL platform chaos engineering, Chaos Mesh is the primary tool for subgraph latency injection and pod kill experiments. *See also:* Circuit Breaker, Error Budget. *Covered in depth:* Section 33.

---

**Circuit Breaker** — A resilience pattern that detects repeated failures to a downstream service and "opens" the circuit — stopping requests to the failing service for a configured cooldown period — rather than continuing to attempt calls that are likely to fail. After the cooldown, the circuit enters a "half-open" state: a probe request is allowed through, and if it succeeds, the circuit closes. Apollo Router does not natively implement circuit breaking as of v1; circuit breaker behavior for subgraphs is typically implemented via service mesh (Istio, Linkerd) or a custom Rhai coprocessor. *See also:* Service Mesh, Chaos Mesh. *Covered in depth:* Section 16.

---

**Error Budget** — The maximum allowable amount of SLO failure within a defined period. If a service has a 99.9% availability SLO over 30 days, its error budget is 0.1% of request-minutes — approximately 43.8 minutes of downtime or 0.1% of requests returning errors. The error budget frames reliability as a resource: spending it on risky deployments is acceptable if the velocity benefit is worth the cost. Exhausting the error budget triggers a freeze on risky changes until the budget recovers. *See also:* SLO, Burn Rate, SLI. *Covered in depth:* Section 14.

---

**Exemplar** — A Prometheus feature that attaches a high-cardinality label (typically a trace ID) to a histogram observation, linking a specific metric data point to a distributed trace. When a histogram bucket is observed, an exemplar records `{ traceID: "abc123", value: 0.342 }`. In Grafana, exemplars appear as dots on histogram panels — clicking one opens the corresponding trace in Tempo. Exemplars are the bridge between metrics and traces in the Grafana LGTM stack, essential for going from "p99 is high" to "here is the specific slow trace." *See also:* Tempo, Prometheus, Grafana, Trace. *Covered in depth:* Section 14.

---

**ExternalSecret Operator** — A Kubernetes operator that synchronizes secrets from external secret management systems (AWS Secrets Manager, HashiCorp Vault, GCP Secret Manager) into Kubernetes Secrets. The operator watches `ExternalSecret` CRDs that declare which secret to fetch and how often to refresh it. For GraphQL platforms, ExternalSecret Operator manages: JWKS signing keys, database connection strings, schema registry API keys, and router configuration secrets. This avoids storing secrets in Git while keeping them available to Kubernetes pods as native Secrets. *See also:* Vault Agent Sidecar. *Covered in depth:* Section 15.

---

**GitOps** — A software delivery model in which the desired state of infrastructure and applications is declared in Git, and an automated operator (ArgoCD, Flux) continuously reconciles the live state of the cluster with the declared state in Git. GitOps provides: audit trail (every change is a Git commit), rollback (revert a commit to roll back), and consistency (the cluster always matches Git). For GraphQL platform teams, GitOps governs router configuration, subgraph Helm chart versions, and observability stack configuration. *See also:* ArgoCD, Helm, Helmfile. *Covered in depth:* Section 15.

---

**Golden Path** — A standardized, supported, opinionated path for accomplishing a common engineering task — in this context, creating and onboarding a new GraphQL subgraph. The golden path provides: a starter template (Helm chart, schema stub, CI pipeline, monitoring configuration), documentation, and automation that guides a team from a new subgraph concept to a production-ready deployment without requiring platform team assistance for each step. The golden path is the primary mechanism by which a platform team scales its impact. *See also:* Backstage. *Covered in depth:* Section 19.

---

**Grafana** — An open-source metrics visualization and dashboarding platform. In the Grafana LGTM stack (Loki, Grafana, Tempo, Mimir/Prometheus), Grafana is the unified UI for exploring metrics (Prometheus/Mimir), logs (Loki), and traces (Tempo). GraphQL platform teams use Grafana for: SLO dashboards (error rate, burn rate, budget remaining), per-operation latency histograms, per-subgraph error rate panels, and DataLoader batch size distributions. *See also:* Prometheus, Loki, Tempo, Exemplar. *Covered in depth:* Section 14.

---

**Head-Based Sampling** — A distributed tracing sampling strategy that decides whether to record a trace at the start (head) of the request, before any processing occurs. A common implementation samples 10% of all requests. Head-based sampling is simple and has low overhead, but it is blind to the outcome of the request — a 10% sample includes both fast and slow requests, and may miss low-frequency errors entirely. Contrast with tail-based sampling. *See also:* Tail-Based Sampling, Trace, OpenTelemetry. *Covered in depth:* Section 14.

---

**Helm** — The package manager for Kubernetes. Helm packages Kubernetes manifests as "charts" — versioned, parameterized bundles that can be installed, upgraded, and rolled back with a single command. GraphQL subgraphs are typically deployed as Helm charts, parameterized with environment-specific values (image tag, replica count, resource limits, ingress configuration). The Apollo Router has an official Helm chart. *See also:* Helmfile, ArgoCD, GitOps. *Covered in depth:* Section 15.

---

**Helmfile** — A declarative configuration tool that manages multiple Helm chart releases across multiple Kubernetes clusters and namespaces. Helmfile defines the desired state of all Helm releases in a single YAML file (or directory structure), enabling consistent deployment across environments (staging vs production). For GraphQL platform teams, Helmfile manages the full platform stack: router, subgraphs, Prometheus, Grafana, Loki, and Tempo, all as a versioned, reproducible deployment. *See also:* Helm, ArgoCD, GitOps. *Covered in depth:* Section 15.

---

**HPA (HorizontalPodAutoscaler)** — A Kubernetes resource that automatically scales the number of pod replicas in a Deployment based on observed resource utilization or custom metrics. For the Apollo Router, HPA is configured to scale on CPU utilization (scale out when CPU > 60%) with minimum and maximum replica counts. KEDA extends HPA to scale on arbitrary metrics (e.g., GraphQL request rate from Prometheus). Correct HPA configuration ensures the router scales to handle traffic spikes without manual intervention. *See also:* KEDA, VPA, PDB. *Covered in depth:* Section 15.

---

**KEDA (Kubernetes Event-Driven Autoscaler)** — A Kubernetes autoscaling tool that scales workloads based on external event sources and metrics beyond standard CPU/memory — including Prometheus metrics, message queue depth, and custom metrics endpoints. For GraphQL platforms, KEDA enables scaling the router or subgraphs based on GraphQL request rate (from Prometheus) rather than CPU, which is a more direct signal of actual load. KEDA works alongside HPA. *See also:* HPA, Prometheus, VPA. *Covered in depth:* Section 15.

---

**Kiali** — An observability console for Istio service meshes that visualizes service-to-service traffic, health, and configuration. For a GraphQL platform using Istio, Kiali shows the traffic topology between the router and subgraphs, traffic volume per connection, error rates, and mTLS status. It is particularly useful for verifying that mTLS is enforced between all router-to-subgraph connections and for diagnosing routing misconfigurations. *See also:* Service Mesh, mTLS, Istio. *Covered in depth:* Section 16.

---

**Kubecost** — A Kubernetes cost monitoring tool that attributes cloud infrastructure costs to specific namespaces, deployments, and labels. For GraphQL platform teams, Kubecost provides: per-subgraph compute cost (enabling cost attribution to owning teams), router infrastructure cost trending (router CPU cost as a function of request volume and query complexity), and efficiency reports (identifying over-provisioned subgraphs). *See also:* Grafana. *Covered in depth:* Section 34.

---

**LogQL** — The query language for Loki, Grafana's log aggregation system. LogQL syntax is similar to PromQL but operates on log streams instead of time series. A LogQL query consists of a log stream selector (filtering by labels like `{app="apollo-router", namespace="graphql-platform"}`) and optional pipeline stages (filtering by pattern, parsing JSON, extracting fields). For GraphQL platforms, LogQL is used to query router access logs, extract operation names from log entries, and correlate error logs with trace IDs. *See also:* Loki, PromQL, TraceID. *Covered in depth:* Section 14.

---

**Loki** — Grafana's horizontally scalable log aggregation system. Loki indexes log metadata (labels) but not log content, which makes it significantly cheaper to operate than Elasticsearch for log storage. Log content is queried via full-text search at query time. For GraphQL platforms, Loki ingests: Apollo Router access logs (including operation name, latency, error status), subgraph application logs, and Kubernetes pod lifecycle events. *See also:* LogQL, Grafana, Tempo. *Covered in depth:* Section 14.

---

**mTLS (mutual TLS)** — A TLS protocol variant in which both the client and server authenticate each other using certificates, rather than only the server authenticating to the client. In a GraphQL federated supergraph, mTLS is enforced between the Apollo Router and each subgraph using a service mesh (Istio or Linkerd), ensuring that only the router can call subgraph endpoints and eliminating the possibility of lateral movement within the cluster. SPIFFE/SPIRE manages certificate issuance for mTLS in zero-trust environments. *See also:* Service Mesh, SPIFFE, SPIRE, Zero-Trust Networking. *Covered in depth:* Section 16.

---

**Multi-Window Multi-Burn-Rate (MWMBR)** — The recommended SLO alerting strategy from the Google SRE Workbook. MWMBR uses two overlapping burn rate alerts per severity level: a short window (1h) for fast response and a long window (6h or 3d) for sustained slow burns. Both windows must be breached simultaneously to fire an alert, which reduces false positives. For GraphQL platforms, the recommended MWMBR configuration fires SEV1 alerts when the 1h burn rate exceeds 14.4x AND the 5m burn rate exceeds 14.4x. *See also:* Burn Rate, SLO, Error Budget, Alert Rule. *Covered in depth:* Section 14.

---

**NetworkPolicy** — A Kubernetes resource that defines which pods can send traffic to and receive traffic from other pods, based on label selectors, namespaces, and ports. For GraphQL platforms, NetworkPolicy implements the principle of least privilege at the network layer: only the router pods can reach subgraph pods on their GraphQL port; subgraph pods cannot communicate with each other directly. NetworkPolicy is a prerequisite for zero-trust networking within a Kubernetes cluster. *See also:* Zero-Trust Networking, mTLS. *Covered in depth:* Section 15.

---

**OPA (Open Policy Agent)** — A general-purpose policy engine that evaluates declarative policies written in the Rego language against structured data (JSON/YAML). For GraphQL platforms, OPA is used in two contexts: (1) schema policy enforcement — evaluating proposed schema changes against naming conventions, deprecation rules, and governance policies in CI; (2) runtime authorization — evaluating request context (JWT claims, operation name) against authorization policies in the Apollo Router coprocessor. *See also:* Zero-Trust Networking, Vault Agent Sidecar. *Covered in depth:* Section 13.

---

**OpenTelemetry (OTel)** — A CNCF observability framework that provides a standardized API, SDK, and protocol (OTLP) for collecting and exporting telemetry data: traces, metrics, and logs. Apollo Router has native OpenTelemetry support — it emits traces via OTLP and exports Prometheus metrics. Using OTel for all subgraphs and the router creates a consistent, vendor-neutral observability layer that works with Grafana Tempo, Jaeger, Zipkin, Honeycomb, or any OTLP-compatible backend. *See also:* OTLP, Span, Trace, TraceContext. *Covered in depth:* Section 14.

---

**OTLP (OpenTelemetry Protocol)** — The wire protocol used by OpenTelemetry to transmit telemetry data (traces, metrics, logs) from instrumented services to a collector or backend. OTLP uses gRPC or HTTP/Protobuf for transport. Apollo Router supports OTLP trace export to any compatible backend (Grafana Tempo, Jaeger, Honeycomb). Subgraphs instrument using the OpenTelemetry SDK and export via OTLP to a local or remote OTel Collector. *See also:* OpenTelemetry, Span, Trace. *Covered in depth:* Section 14.

---

**PDB (PodDisruptionBudget)** — A Kubernetes resource that limits voluntary disruptions (node drains, cluster upgrades, pod evictions) to a Deployment by declaring the minimum number of pods that must remain available during the disruption. For the Apollo Router, a PDB of `minAvailable: 2` ensures that at least two router replicas remain running during a node drain, preventing the router from being temporarily unavailable during routine cluster maintenance. PDB is essential for zero-downtime router upgrades. *See also:* HPA, VPA. *Covered in depth:* Section 15.

---

**PromQL** — The functional query language for Prometheus. PromQL queries time series data using selectors (label-based filtering), range vectors (time windows), and functions (rate, histogram_quantile, sum, max, etc.). For GraphQL platforms, PromQL is the language of SLO definitions, alert rules, and dashboard panels. Key GraphQL PromQL patterns include: `rate(apollo_router_graphql_error_total[5m])` for error rates, `histogram_quantile(0.99, ...)` for p99 latency, and multi-window burn rate expressions. *See also:* Prometheus, Alert Rule, Recording Rule. *Covered in depth:* Section 14.

---

**Prometheus** — An open-source monitoring system and time-series database. Prometheus scrapes metrics from instrumented services at a configured interval, stores them as time-series data, evaluates alert rules, and exposes a query API (PromQL). Apollo Router exposes Prometheus metrics at `/metrics` by default. Prometheus is the metrics backend for the standard GraphQL platform observability stack. *See also:* PromQL, Alertmanager, Grafana, Recording Rule. *Covered in depth:* Section 14.

---

**Recording Rule** — A Prometheus rule that pre-computes the result of a PromQL expression on a schedule and stores the result as a new time series. Recording rules reduce query latency for expensive expressions (like multi-subgraph aggregations or burn rate calculations) that would be too slow to compute at dashboard render time. For GraphQL platforms, recording rules pre-compute: per-operation error rates, SLO burn rates, and subgraph latency percentiles. *See also:* PromQL, Prometheus, Alert Rule. *Covered in depth:* Section 14.

---

**Service Mesh** — A dedicated infrastructure layer for service-to-service communication that provides: traffic management, mutual TLS (mTLS), load balancing, circuit breaking, and observability — without requiring application code changes. Istio and Linkerd are the most common service mesh implementations for Kubernetes. For GraphQL platforms, a service mesh enforces mTLS between the router and subgraphs and provides per-connection traffic metrics and tracing without subgraph code instrumentation. *See also:* mTLS, Circuit Breaker, Kiali. *Covered in depth:* Section 16.

---

**Service Monitor** — A Prometheus Operator CRD that declaratively configures Prometheus to scrape metrics from a Kubernetes Service. Rather than editing the Prometheus configuration file directly, teams create a `ServiceMonitor` resource that selects target services by label, specifies the metrics endpoint path and port, and optionally sets scrape interval and TLS configuration. The Prometheus Operator watches for new `ServiceMonitor` resources and automatically adds them to the Prometheus scrape configuration. *See also:* Prometheus, PromQL. *Covered in depth:* Section 14.

---

**SLI (Service Level Indicator)** — A specific, measurable property of a service that indicates its reliability from the user's perspective. Common GraphQL SLIs: availability (the fraction of requests that receive a non-error response), latency (the fraction of requests completed in under a threshold), and error rate (the fraction of requests that result in a GraphQL error in `errors[]`). SLIs are measured by querying Prometheus metrics. *See also:* SLO, Error Budget, PromQL. *Covered in depth:* Section 14.

---

**SLO (Service Level Objective)** — A target value or range for an SLI, over a defined measurement window. A GraphQL platform SLO example: "99.9% of all GraphQL requests complete without a complete error, measured over a rolling 30-day window." SLOs frame reliability as a contractual commitment to users. The error budget is derived from the SLO. SLO breach triggers escalation per the incident management severity framework. *See also:* SLI, Error Budget, Burn Rate. *Covered in depth:* Section 14.

---

**SPIFFE (Secure Production Identity Framework for Everyone)** — A CNCF standard for assigning cryptographically verifiable identities to workloads in dynamic infrastructure. A SPIFFE identity is a URI (`spiffe://cluster.local/ns/graphql-platform/sa/apollo-router`) embedded in an X.509 certificate (SVID). SPIFFE identities enable mTLS without static IP-based ACLs, because workload identity is tied to the process, not the network address. *See also:* SPIRE, mTLS, Zero-Trust Networking. *Covered in depth:* Section 16.

---

**SPIRE (SPIFFE Runtime Environment)** — The reference implementation of the SPIFFE standard. SPIRE consists of a server (that signs identity certificates) and an agent (that runs on each node and issues certificates to workloads). SPIRE integrates with Kubernetes via node attestation and workload attestation to automatically issue and rotate SPIFFE SVIDs for every pod. For GraphQL platforms, SPIRE provides the certificate infrastructure for mTLS between the router and all subgraphs. *See also:* SPIFFE, mTLS, Zero-Trust Networking. *Covered in depth:* Section 16.

---

**Span** — A single unit of work in a distributed trace. A span records: operation name, start time, duration, status (success or error), and key-value attributes. In a GraphQL request, the router creates a root span for the incoming request; each subgraph call creates a child span; within each subgraph, resolver execution, DataLoader batch calls, and database queries each create their own child spans. The full trace is the tree of spans for one request. *See also:* Trace, TraceID / SpanID, OpenTelemetry. *Covered in depth:* Section 14.

---

**Tail-Based Sampling** — A distributed tracing sampling strategy that decides whether to record a trace after the entire trace is complete — enabling sampling decisions based on the outcome (e.g., always sample errors, always sample slow requests, sample 1% of fast successful requests). Tail-based sampling is more useful than head-based sampling for debugging production issues because it guarantees that all errors and outliers are captured. It requires a trace collector that can buffer complete traces before making the sampling decision (e.g., OpenTelemetry Collector with the tail sampling processor). *See also:* Head-Based Sampling, Trace, OpenTelemetry. *Covered in depth:* Section 14.

---

**Tempo** — Grafana's distributed tracing backend. Tempo stores traces indexed by trace ID, enabling single-trace lookup but not full-text search across traces. Trace discovery uses Prometheus exemplars (which link metric data points to trace IDs) or trace search via TraceQL. For GraphQL platforms, Tempo stores traces emitted by Apollo Router and subgraphs via OTLP, and integrates with Grafana for trace visualization alongside metrics and logs. *See also:* OpenTelemetry, TraceQL, Exemplar, Grafana. *Covered in depth:* Section 14.

---

**Trace** — The complete record of a distributed request as it travels through multiple services. A trace consists of one or more spans arranged in a parent-child hierarchy. The root span is the entry point (typically the router receiving the client request); child spans represent subgraph calls, database queries, and cache lookups. Traces answer: "what happened during this specific request, how long did each step take, and where did the error occur?" *See also:* Span, TraceID / SpanID, OpenTelemetry, Tail-Based Sampling. *Covered in depth:* Section 14.

---

**TraceContext (W3C)** — The W3C standard HTTP header format for distributed trace propagation: `traceparent` (containing the trace ID, span ID, and sampling flag) and `tracestate` (vendor-specific trace state). Apollo Router propagates W3C TraceContext headers to all subgraph calls by default, enabling end-to-end trace correlation without manual header wiring. Subgraphs that extract the `traceparent` header and use it as the parent context automatically create child spans linked to the router's trace. *See also:* OpenTelemetry, Span, Baggage, TraceID. *Covered in depth:* Section 14.

---

**TraceID / SpanID** — The 128-bit (trace ID) and 64-bit (span ID) random identifiers that uniquely identify a distributed trace and a specific span within it. The trace ID is constant across all spans in one request; the span ID is unique per span. Both are encoded in the `traceparent` W3C header. In GraphQL observability, the trace ID is the primary key for navigating from a metric exemplar or a log entry to the corresponding distributed trace in Tempo. *See also:* Trace, Span, TraceContext, Exemplar. *Covered in depth:* Section 14.

---

**TraceQL** — The query language for searching and filtering traces in Grafana Tempo. TraceQL allows trace search by span attributes (e.g., `{.graphql.operation.name = "GetProductDetails" && duration > 2s}`), enabling discovery of slow or erroring traces by operation name, subgraph, or error type without relying on exemplars. TraceQL is particularly useful for investigating p99 latency regressions where exemplars have not been configured. *See also:* Tempo, Span, PromQL. *Covered in depth:* Section 14.

---

**Vault Agent Sidecar** — A HashiCorp Vault pattern in which a Vault Agent process runs as a sidecar container alongside the main application container in a Kubernetes pod. The Vault Agent authenticates to Vault using the pod's Kubernetes service account, fetches secrets, writes them to a shared volume, and refreshes them before they expire. For GraphQL platforms, Vault Agent sidecars manage: subgraph database credentials, signing keys, and third-party API tokens — keeping them out of Kubernetes Secrets (which are only base64-encoded, not encrypted at rest by default). *See also:* ExternalSecret Operator. *Covered in depth:* Section 15.

---

**VPA (VerticalPodAutoscaler)** — A Kubernetes resource that automatically adjusts container CPU and memory resource requests based on observed usage. Unlike HPA (which scales replica count), VPA scales per-container resource allocation. For GraphQL subgraphs with variable memory usage (due to DataLoader caching, query result buffering), VPA can right-size resource requests to reduce cost and prevent OOM kills. VPA and HPA can conflict — consult the official documentation for co-usage constraints. *See also:* HPA, KEDA, PDB. *Covered in depth:* Section 15.

---

**Zero-Trust Networking** — A security model in which no network connection is implicitly trusted based on its source IP or network location. Every connection must be authenticated and authorized, regardless of whether it originates inside or outside the cluster. For GraphQL platforms, zero-trust networking means: mTLS between all services (router to subgraph, subgraph to database), NetworkPolicy to restrict which pods can communicate with which, and SPIFFE/SPIRE for workload identity. The result is that a compromised subgraph pod cannot reach other subgraphs directly — only the router can. *See also:* mTLS, NetworkPolicy, SPIFFE, SPIRE, OPA. *Covered in depth:* Section 16.

---

## Related Topics

- [38-glossary/01-graphql-terms.md](./01-graphql-terms.md) — GraphQL language and runtime terminology
- [38-glossary/02-federation-terms.md](./02-federation-terms.md) — federation and supergraph terminology
- [14-observability](../14-observability/) — distributed tracing, metrics, and SLO implementation
- [15-kubernetes-deployment](../15-kubernetes-deployment/) — Kubernetes resources and deployment patterns
- [16-service-mesh-integration](../16-service-mesh-integration/) — service mesh configuration and mTLS
- [33-incident-management](../33-incident-management/) — incident response and chaos engineering
