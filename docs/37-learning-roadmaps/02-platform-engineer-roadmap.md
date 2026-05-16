# 02 — Platform Engineer Learning Roadmap

> **Purpose:** A structured 8-week learning path for platform and SRE engineers who operate GraphQL infrastructure but may not implement application-layer GraphQL code. Each phase has a concrete milestone. Time estimates assume 5–8 hours of active learning per week alongside normal work.

---

## Who This Roadmap Is For

This roadmap is for engineers who:

- Operate Kubernetes clusters and manage shared platform services
- Write infrastructure-as-code (Helm charts, Terraform, Kustomize)
- Build and maintain CI/CD pipelines for application teams
- Own reliability, scalability, and observability for shared services
- Are responsible for the Apollo Router (or equivalent) deployment

You are not expected to write GraphQL schemas or implement resolvers. You need enough GraphQL knowledge to debug cross-subgraph query failures, identify performance bottlenecks in the query planner, configure the router correctly, and build operational tooling that application teams depend on.

**What you will be able to do after completing this roadmap:**

- Explain what happens during a federated query execution at the network and protocol level
- Operate a multi-subgraph staging environment (deploy, compose, validate, roll back)
- Deploy Apollo Router on Kubernetes with Istio mTLS and proper security configuration
- Build a Grafana dashboard showing GraphQL golden signals from Prometheus metrics
- Run chaos experiments against subgraph failures and verify the router degrades gracefully
- Diagnose common federated query failures using distributed traces

---

## Environment Setup

```bash
# Required tools
kubectl version --client          # v1.28+
helm version                      # v3.12+
docker --version                  # latest

# Optional but useful
k9s                              # TUI for Kubernetes
stern                            # Multi-pod log tailing
# For local Kubernetes cluster:
kind create cluster --name graphql-dev
# or
k3d cluster create graphql-dev
```

You will need a Kubernetes cluster (local or cloud) for Phases 3 and 4. Local clusters (kind, k3d) work for Phases 3 and 4. Phase 5 is easier with a cloud cluster that supports LoadBalancer services.

---

## Phase 1 — GraphQL Internals (1 Week)

**Sections:** [02-graphql-internals](../02-graphql-internals/), [04-resolvers-and-execution](../04-resolvers-and-execution/)

### Why Platform Engineers Need This

You cannot debug what you do not understand. When a federated query returns partial data, when the router reports a subgraph timeout, or when a schema composition error blocks a deployment, you need to understand the execution model to diagnose the problem. This phase gives you the mental model — not the implementation skills.

### What You Will Learn

- The execution pipeline: parse → validate → plan → execute → serialize
- What "query planning" means: how the router decomposes a query into subgraph requests
- What the `_entities` query is and how entity resolution works
- How DataLoader batching works and why N+1 queries happen without it
- What the execution context carries and why subgraphs need the right headers
- How errors propagate: the `errors` array, null propagation, and partial responses

### Recommended Reading Sequence

1. `02-graphql-internals/` — all files (2–2.5 hours)
2. `04-resolvers-and-execution/` — focus on DataLoader and error handling sections (1–1.5 hours)

### Hands-On Exercises

**Exercise 1.1 — Trace a federated query manually**

Using the Apollo Router's debug logging and `rover dev`:

```bash
# Start Apollo Router with debug logging
APOLLO_ROUTER_LOG=debug rover dev

# In another terminal, send a federated query
curl -X POST http://localhost:4000/graphql \
  -H "Content-Type: application/json" \
  -d '{"query": "query { orders { id user { name } } }", "operationName": "TestFederatedQuery"}'
```

In the router logs, identify:
1. The query plan (which subgraphs are called and in what order)
2. The `_entities` query sent to the Users subgraph
3. The entity variables (the list of user IDs extracted from the orders response)
4. The timing for each subgraph call

Draw a sequence diagram of what you observe.

**Exercise 1.2 — Identify the N+1 problem from logs**

Set up a subgraph with deliberate N+1 queries (no DataLoader) and observe the database query logs. Identify the pattern: N individual queries instead of 1 batch query. This gives you a concrete signal to look for when investigating slow subgraph response times.

### Phase 1 Milestone

**Explain federation to a non-GraphQL engineer.**

Without looking at your notes, explain to a colleague (or write a 1-page technical explanation):

1. What happens, step by step, when a client sends `query { orders { id user { name } } }` to a federated graph with an Orders subgraph and a Users subgraph
2. What the `_entities` query is and why the router sends it
3. What "query planning" means and how the router decides whether to call subgraphs in parallel or sequentially

If you can explain the `_entities` query and the entity resolution process clearly, you pass this milestone.

---

## Phase 2 — Federation + Supergraph Architecture (2 Weeks)

**Sections:** [07-federation](../07-federation/), [08-supergraph-architecture](../08-supergraph-architecture/), [09-schema-governance](../09-schema-governance/)

### What You Will Learn

- Apollo Router architecture: query planning, execution, plugin system, coprocessors
- Schema composition: what composition errors look like and how to fix them
- `@key`, `@external`, `@requires`, `@provides`: what these directives mean for query planning
- Schema registry: push, check, diff, and the role of the registry in CI/CD
- Breaking change detection: what types of changes break clients and how the registry catches them
- Router configuration: authentication, rate limiting, CORS, header forwarding, timeouts
- Graph variants: staging vs production compositions and why they must be separate

### Recommended Reading Sequence

1. `07-federation/` — all files (2.5–3 hours)
2. `08-supergraph-architecture/` — all files (2.5–3 hours)
3. `09-schema-governance/` — all files (1.5–2 hours)

### Hands-On Exercises

**Exercise 2.1 — Trigger and fix a composition error**

Using a local supergraph with two subgraphs, deliberately introduce composition errors:
- Remove a `@key` field from a type that another subgraph extends
- Add a field with the same name to two subgraphs without `@shareable`
- Use `@requires` on a field that is not marked `@external`

For each error, read the composition error output from Rover and understand what it means. Then fix the error.

**Exercise 2.2 — Configure Apollo Router**

Using the Apollo Router YAML configuration, implement:
- JWT authentication (extract JWT, validate against JWKS, forward claims as headers)
- CORS headers for your frontend domain
- Request timeout (global + per-subgraph)
- Header forwarding (forward `X-User-Id` to all subgraphs)
- Health check endpoint configuration

Test each configuration change with a curl request and verify the expected behavior.

**Exercise 2.3 — Operate a schema check**

Implement a schema check workflow:
```bash
# Check a subgraph schema change against the production graph
rover subgraph check my-graph@production \
  --name users \
  --schema ./schema.graphql

# Verify the check catches a breaking change
# Remove a field from the schema and run the check again
```

Understand the difference between: composition errors (cannot compose), breaking changes (breaks existing operations), and deprecation warnings (non-breaking but notable).

### Phase 2 Milestone

**Operate a multi-subgraph staging environment.**

Set up a complete staging environment:

1. Two subgraphs deployed to Kubernetes (use the example subgraphs from the federation section)
2. Apollo Router deployed in front of them
3. Schema registry with a `staging` variant separate from `production`
4. A deployment process that:
   - Runs composition check before deploying any subgraph change
   - Updates the schema registry after a successful subgraph deployment
   - Can roll back a subgraph deployment if the post-deployment schema check fails

Verify by: deploying a breaking schema change to staging, observing the schema check failure, and demonstrating that the rollback process restores the previous state without affecting the `production` variant.

---

## Phase 3 — Kubernetes + Service Mesh (2 Weeks)

**Sections:** [15-kubernetes-deployment](../15-kubernetes-deployment/), [16-service-mesh-integration](../16-service-mesh-integration/)

### What You Will Learn

- Kubernetes manifests for Apollo Router: Deployment, Service, HPA, PDB, resource limits
- ConfigMap and Secret management for router configuration (JWKS URLs, API keys)
- Helm chart structure for a federated GraphQL deployment
- Istio service mesh: how sidecar injection works, what mTLS provides
- Istio configuration for GraphQL: VirtualService, DestinationRule, retry policies
- mTLS between router and subgraphs: certificate management with SPIFFE/SPIRE
- Traffic management: canary deployments for subgraph changes, circuit breaking
- Subgraph discovery in Kubernetes: how the router finds subgraph endpoints

### Recommended Reading Sequence

1. `15-kubernetes-deployment/` — all files (2.5–3 hours)
2. `16-service-mesh-integration/` — all files (2.5–3 hours)

### Hands-On Exercises

**Exercise 3.1 — Deploy Apollo Router with Helm**

Create a Helm chart (or use the community Apollo Router chart) and deploy it to your local kind cluster:

```yaml
# values.yaml for Apollo Router Helm deployment
router:
  replicaCount: 2
  
  resources:
    requests:
      cpu: 250m
      memory: 256Mi
    limits:
      cpu: 1000m
      memory: 512Mi
  
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilizationPercentage: 70
  
  podDisruptionBudget:
    enabled: true
    minAvailable: 1
  
  config:
    supergraph:
      listen: "0.0.0.0:4000"
    health_check:
      listen: "0.0.0.0:8088"
```

**Exercise 3.2 — Configure Istio mTLS**

Install Istio into your cluster and configure mTLS for the GraphQL namespace:

```yaml
# PeerAuthentication — require mTLS for all communication in the namespace
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: graphql-mtls
  namespace: graphql
spec:
  mtls:
    mode: STRICT

# Verify mTLS is working
istioctl authn tls-check router-pod.graphql users-subgraph.graphql.svc.cluster.local
```

Verify that a request from the router to a subgraph without mTLS credentials is rejected.

**Exercise 3.3 — Implement a canary deployment**

Using Istio VirtualService, implement a canary deployment for a subgraph:
```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: users-subgraph
spec:
  http:
  - match:
    - headers:
        x-canary:
          exact: "true"
    route:
    - destination:
        host: users-subgraph
        subset: canary
  - route:
    - destination:
        host: users-subgraph
        subset: stable
      weight: 95
    - destination:
        host: users-subgraph
        subset: canary
      weight: 5
```

Verify that 5% of traffic goes to the canary and 95% to stable by watching response headers.

### Common Mistakes in Phase 3

- **Router resource limits too low.** Apollo Router processes all fan-out in memory. For federated queries with many subgraphs, memory usage spikes during composition. Start with 512Mi memory limit and increase based on profiling.
- **PDB missing.** Without a PodDisruptionBudget, node drains can take down all router replicas simultaneously. Always set `minAvailable: 1` for the router.
- **Subgraph connection pool too small.** The router maintains a connection pool to each subgraph. Under high concurrency, a small pool causes connection queue buildup. Configure pool size based on your expected peak RPS.

### External Resources

- [Apollo Router Helm chart](https://github.com/apollographql/helm-charts) — official Helm charts
- [Istio documentation](https://istio.io/latest/docs/) — service mesh reference
- [Kubernetes Deployments documentation](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) — deployment configuration
- [SPIFFE/SPIRE documentation](https://spiffe.io/docs/latest/) — workload identity for mTLS

### Phase 3 Milestone

**Deploy Apollo Router on Kubernetes with Istio mTLS.**

In your local cluster:

1. Deploy Apollo Router (2 replicas), two subgraphs, and the schema registry webhook handler
2. Enable Istio sidecar injection in the GraphQL namespace
3. Configure PeerAuthentication for STRICT mTLS
4. Verify with `istioctl` that mTLS is active between router and both subgraphs
5. Configure HPA for the router (scale on CPU + custom metric if available)
6. Configure PDB for the router (minAvailable: 1)
7. Demonstrate graceful router replica rollout without request interruption (rolling update with zero errors)

---

## Phase 4 — Observability + Platform Engineering (2 Weeks)

**Sections:** [14-observability](../14-observability/), [19-platform-engineering](../19-platform-engineering/), [20-internal-developer-platforms](../20-internal-developer-platforms/)

### What You Will Learn

- OpenTelemetry setup for Apollo Router and subgraphs (traces, metrics, logs)
- GraphQL-specific metrics: request rate, error rate, latency by operation name
- The four GraphQL golden signals and how to dashboard them
- Trace correlation across router and subgraphs: how to follow a single request through the full execution
- Alerting: SLO-based alerts vs symptom-based alerts for GraphQL
- Platform engineering for GraphQL: the "golden path" for new subgraph deployment
- Internal developer platform (IDP) capabilities: service catalog, schema registry integration, self-service tooling
- Backstage integration: registering subgraphs in the service catalog with schema metadata

### Recommended Reading Sequence

1. `14-observability/` — all files (2.5–3 hours)
2. `19-platform-engineering/` — all files (2.5–3 hours)
3. `20-internal-developer-platforms/` — all files (2–2.5 hours)

### Hands-On Exercises

**Exercise 4.1 — End-to-end OpenTelemetry setup**

Configure OpenTelemetry across your deployed stack:

```yaml
# Apollo Router YAML configuration for OpenTelemetry
telemetry:
  tracing:
    otlp:
      endpoint: "http://otel-collector:4317"
      protocol: grpc
  metrics:
    prometheus:
      enabled: true
      listen: "0.0.0.0:9090"
      path: /metrics
  
  # Instrumentation settings
  instrumentation:
    spans:
      router:
        attributes:
          graphql.operation.name:
            request_header: "x-operation-name"
          graphql.operation.type:
            static: "query"
```

Verify in Grafana Tempo that you can see a complete trace waterfall for a federated query: router span → subgraph A span → subgraph B span.

**Exercise 4.2 — Build a Grafana dashboard**

Build a Grafana dashboard for GraphQL golden signals using Prometheus metrics from Apollo Router:

```promql
# Request rate by operation
rate(apollo_router_http_requests_total[5m])

# Error rate (4xx + 5xx)
rate(apollo_router_http_requests_total{http_response_status_code=~"[45].."}[5m])
  / rate(apollo_router_http_requests_total[5m])

# P99 latency by operation
histogram_quantile(0.99, 
  rate(apollo_router_http_request_duration_seconds_bucket[5m])
)

# Subgraph fan-out rate
rate(apollo_router_subgraph_requests_total[5m])
```

Include: operation-level breakdown (separate panel per top-N operations), subgraph health (error rate per subgraph), and resource utilization (CPU, memory for router pods).

**Exercise 4.3 — Build a Backstage integration**

Register your subgraphs in a local Backstage instance:
- Create a `catalog-info.yaml` for each subgraph service
- Include GraphQL schema URL as an annotation
- Create a Backstage plugin (or use the GraphQL plugin) that shows the subgraph schema in the service catalog
- Add the schema check status as a CI annotation on the service entity

### Phase 4 Milestone

**Build a Grafana dashboard for GraphQL golden signals.**

Produce a Grafana dashboard that shows:

1. **Request rate** — total requests/sec, broken down by operation name (top 10 operations)
2. **Error rate** — percentage of requests returning errors, by operation name and error type
3. **Latency** — P50, P95, P99 latency per operation; router vs subgraph latency breakdown
4. **Subgraph health** — error rate per subgraph; subgraph response time; fan-out ratio (subgraph calls per client request)
5. **Router resource utilization** — CPU and memory usage for router pods; HPA scaling events

The dashboard must use operation name as the primary grouping dimension. Anonymous operations should be counted and flagged as a monitoring gap indicator (anonymous operations mean observability is broken for those queries).

---

## Phase 5 — Incident Management + Runbooks (1 Week)

**Sections:** [26-production-failure-scenarios](../26-production-failure-scenarios/), [32-production-runbooks](../32-production-runbooks/), [33-incident-management](../33-incident-management/)

### What You Will Learn

- Common federated GraphQL failure modes: subgraph unavailable, schema composition failure, query plan explosion, entity resolution timeout
- Partial failure semantics: what a partial response looks like and when clients should retry
- Runbook structure for GraphQL incidents: signals, investigation steps, remediation
- Chaos engineering for GraphQL: injecting subgraph failures, latency, and errors
- Incident response for schema-related outages: how to roll back a schema change

### Recommended Reading Sequence

1. `26-production-failure-scenarios/` — all files (1.5–2 hours)
2. `32-production-runbooks/` — all files (1.5–2 hours)
3. `33-incident-management/` — all files (1 hour)

### Hands-On Exercises

**Exercise 5.1 — Chaos experiment: subgraph failure**

Using Chaos Mesh or Istio fault injection, simulate a subgraph going down:

```yaml
# Istio fault injection — abort 100% of requests to users-subgraph
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: users-subgraph-fault
spec:
  http:
  - fault:
      abort:
        percentage:
          value: 100
        httpStatus: 503
    route:
    - destination:
        host: users-subgraph
```

Observe:
1. What the router returns to clients (partial response? full error?)
2. What the router's logs show (error message, subgraph name, error code)
3. Whether the HPA for the router changes during the failure
4. What your Grafana dashboard shows (error rate spike, which operation names are affected)

Write a one-page incident runbook based on your observations.

**Exercise 5.2 — Chaos experiment: high latency**

Inject 2-second latency into the users-subgraph and observe:
1. Whether the router times out (based on your configured subgraph timeout)
2. Whether the timeout causes a partial response or a full error
3. What the latency percentiles look like on your dashboard

Adjust the router's per-subgraph timeout configuration and observe the effect.

### Phase 5 Milestone

**Run a chaos experiment against a subgraph failure.**

Conduct a formal chaos experiment:

1. Define a hypothesis: "When the users-subgraph becomes unavailable, requests that require user data will return a partial response with an error in the `errors` array, and requests that do not require user data will complete successfully."
2. Set up monitoring: watch your Grafana dashboard during the experiment
3. Inject the failure: use Istio fault injection to take down the users-subgraph for 5 minutes
4. Observe: record what clients actually receive, what the dashboard shows, and whether any alerts fire
5. Restore: remove the fault injection and verify recovery
6. Write a post-experiment report: did the system behave as hypothesized? What would you change?

---

## Continuing Beyond This Roadmap

| Interest | Next Sections |
|----------|---------------|
| Advanced Kubernetes patterns | [15-kubernetes-deployment](../15-kubernetes-deployment/) deeper dive |
| Cost optimization | [34-cost-optimization](../34-cost-optimization/) |
| Edge GraphQL deployment | [36-future-trends/03-edge-and-serverless-graphql.md](../36-future-trends/03-edge-and-serverless-graphql.md) |
| Platform governance | [35-governance-models](../35-governance-models/) |
| Architecture decisions | [03-architect-roadmap.md](./03-architect-roadmap.md) |

---

## External Resources

- [Kubernetes documentation](https://kubernetes.io/docs/) — Deployments, HPA, PDB reference
- [Istio documentation](https://istio.io/latest/docs/) — service mesh configuration
- [Apollo Router documentation](https://www.apollographql.com/docs/router/) — complete router reference
- [OpenTelemetry documentation](https://opentelemetry.io/docs/) — instrumentation guides
- [Google SRE Book](https://sre.google/sre-book/table-of-contents/) — SRE principles applicable to GraphQL platform operations

---

## Related Sections

- [38-glossary/02-federation-terms.md](../38-glossary/02-federation-terms.md) — federation terminology
- [38-glossary/03-infrastructure-terms.md](../38-glossary/03-infrastructure-terms.md) — infrastructure and observability terminology
- [28-best-practices](../28-best-practices/) — consolidated best practices
