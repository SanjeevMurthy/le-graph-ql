# 05 — Chaos Engineering for GraphQL Platforms

> **Purpose**
> Chaos engineering validates that GraphQL systems fail gracefully under real-world fault conditions — subgraph failures, latency spikes, connection exhaustion, and authentication outages. This document defines a chaos experiment library, gameday procedures, and success criteria specific to GraphQL's partial-data semantics. Written for platform engineers, SREs, and reliability engineers who need to verify that their incident response assumptions hold before an actual incident tests them.

---

## Why GraphQL Needs Chaos Engineering Specifically

Standard chaos engineering validates that services survive node failures and network partitions. GraphQL platforms have three additional failure properties that standard chaos testing does not address:

**Partial data behavior is hard to reason about statically.** A federated query spanning four subgraphs produces a response where some fields are populated and others are null depending on which subgraphs succeeded. Whether that partial response is acceptable — from a correctness standpoint, a client UX standpoint, and an SLO standpoint — depends on the criticality of each field. This behavior cannot be verified by reading the code; it must be observed under real fault injection.

**Subgraph failure modes interact with query planning in unexpected ways.** The Apollo Router's query planner resolves entities across subgraphs using a static plan generated at request time. When a subgraph is slow or unavailable, the query plan does not change — the router still attempts to call that subgraph, applies its configured timeout, and propagates either partial data or a complete null depending on the field's nullability. Planners cache these plans. Cache invalidation under a subgraph restart, or plan correctness after memory pressure eviction, is a property that must be tested empirically.

**DataLoader batching under concurrency is hard to test with unit tests.** Unit tests for DataLoaders typically use a single-request context with predictable concurrency. Production load involves hundreds of concurrent requests, each with their own DataLoader instance, all competing for the same database connection pool. Whether batching degrades gracefully or causes query stacking and pool exhaustion under high concurrency requires a load injection tool, not a unit test.

---

## Prerequisites

Before running any chaos experiment:

```
[ ] SLO dashboards are instrumented and baseline values are recorded
[ ] On-call engineer is aware that a chaos experiment is running
[ ] A rollback procedure is documented and rehearsed
[ ] The experiment is scoped to staging OR a production blast radius limit is defined
[ ] Incident channel is open for the duration of the experiment
[ ] Grafana dashboards are bookmarked: SLO overview, per-subgraph error rates, DataLoader metrics
```

---

## Chaos Experiment Library

### Experiment 1 — Kill a Subgraph Pod Mid-Request

**Scenario:** A subgraph pod is deleted during active request processing to simulate a pod crash or eviction event.

**Hypothesis:** The router detects the subgraph failure within its health check interval, returns partial data with a populated `errors[]` array for the affected fields, and continues serving complete responses for operations that do not depend on the failing subgraph. The overall error rate stays below 5% because the router's retry and fallback behavior handles the transition.

**Blast radius:** Operations that resolve fields from the affected subgraph. Other operations are unaffected.

**Tool:** `kubectl delete pod`

**Inject command:**

```bash
# Identify the subgraph pod to kill
kubectl get pods -n graphql-platform -l subgraph=orders

# Delete the pod mid-load (run k6 load first, then delete)
kubectl delete pod -n graphql-platform -l subgraph=orders --grace-period=0

# Start a k6 load test in a separate terminal first
k6 run --vus 50 --duration 60s - <<EOF
import http from 'k6/http';
import { check } from 'k6';

export default function() {
  const payload = JSON.stringify({
    query: `{
      currentUser {
        id
        name
        orders { id total status }
        profile { email }
      }
    }`
  });

  const res = http.post('https://api.staging.example.com/graphql', payload, {
    headers: { 'Content-Type': 'application/json' }
  });

  const body = JSON.parse(res.body);
  check(res, { 'status is 200': (r) => r.status === 200 });
  check(body, {
    'data present': (b) => b.data !== undefined,
    'profile field present when orders null': (b) =>
      b.data === null || b.data.currentUser?.profile !== undefined,
  });
}
EOF
```

**Success criteria:**

```promql
# Overall error rate stays below 5%
sum(rate(apollo_router_graphql_error_total[2m]))
/ sum(rate(apollo_router_graphql_requests_total[2m]))
< 0.05

# Partial errors appear on orders field specifically (not complete errors)
sum(rate(apollo_router_graphql_error_total{error_type="partial", path=~".*orders.*"}[2m])) > 0

# Complete errors remain low (router is not failing all operations)
sum(rate(apollo_router_graphql_error_total{error_type="complete"}[2m]))
/ sum(rate(apollo_router_graphql_requests_total[2m]))
< 0.01

# Subgraph recovery: orders subgraph error rate drops to 0 within 60s of pod restart
rate(apollo_router_subgraph_request_error_total{subgraph_name="orders"}[1m]) == 0
```

**Verification checklist:**
- `errors[]` array in the response body references the `orders` field path, not a top-level error
- `data.currentUser.profile` is still populated (cross-subgraph field from a different subgraph)
- `data.currentUser.orders` is `null` with a corresponding error entry
- No resolver panic or router crash observed in logs

**Rollback:**

```bash
# Kubernetes will restart the pod automatically via the Deployment controller.
# If the pod does not restart within 60 seconds:
kubectl rollout restart deployment/orders-subgraph -n graphql-platform

# Confirm recovery
kubectl rollout status deployment/orders-subgraph -n graphql-platform
```

---

### Experiment 2 — Inject 500ms Latency into a Subgraph

**Scenario:** Network latency of 500ms is injected between the router and a specific subgraph to simulate a slow database, a noisy neighbour, or upstream service degradation.

**Hypothesis:** The router times out the affected subgraph within its configured subgraph timeout (default: 30s, or lower if configured), returns partial data for the fields that resolved before the timeout, and the affected subgraph's timeout error appears in `errors[]`. The overall p99 latency stays within `configured_timeout + 100ms` because the timeout is enforced before the overall request deadline.

**Blast radius:** Operations that resolve fields from the affected subgraph will be slower; all other operations are unaffected.

**Tool:** Chaos Mesh `NetworkChaos`

**Chaos Mesh manifest:**

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: orders-subgraph-latency
  namespace: graphql-platform
spec:
  action: delay
  mode: all
  selector:
    namespaces:
      - graphql-platform
    labelSelectors:
      subgraph: orders
  delay:
    latency: 500ms
    correlation: "25"
    jitter: 50ms
  direction: both
  duration: 10m
```

**Inject:**

```bash
# Apply the NetworkChaos resource
kubectl apply -f chaos-experiments/orders-subgraph-latency.yaml

# Watch the effect in real time
watch -n 2 'kubectl get networkchaos orders-subgraph-latency -n graphql-platform -o jsonpath="{.status}"'
```

**Success criteria:**

```promql
# Overall p99 stays within configured timeout + 100ms
# (assumes subgraph timeout is configured to 2000ms)
histogram_quantile(0.99,
  sum by (le) (
    rate(apollo_router_graphql_request_duration_seconds_bucket[5m])
  )
) < 2.1

# Orders subgraph timeout error appears in errors[]
increase(
  apollo_router_subgraph_request_error_total{
    subgraph_name="orders",
    error_type="timeout"
  }[5m]
) > 0

# Operations NOT involving orders subgraph are unaffected
histogram_quantile(0.99,
  sum by (le, operation_name) (
    rate(apollo_router_graphql_request_duration_seconds_bucket{
      operation_name!~".*order.*"
    }[5m])
  )
) < 0.5
```

**Rollback:**

```bash
kubectl delete networkchaos orders-subgraph-latency -n graphql-platform
```

---

### Experiment 3 — Saturate the DataLoader with Concurrent Requests

**Scenario:** A k6 load test drives a high number of concurrent virtual users all executing the same operation that triggers DataLoader batch resolution, to verify that batching holds under concurrency and does not degrade into N+1 query patterns.

**Hypothesis:** DataLoader batching holds under concurrency. The number of database queries issued per unit of time stays within 2x of the single-user baseline. The database connection pool does not saturate. No N+1 regression is observable in the database slow query log.

**Blast radius:** Database connection pool pressure. Other subgraphs are not affected. Risk: connection pool exhaustion if batching fails.

**Tool:** k6

**Load test script:**

```javascript
// k6-dataloader-concurrency.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '30s', target: 10 },   // warm up
    { duration: '2m',  target: 200 },  // concurrency ramp
    { duration: '2m',  target: 200 },  // sustained high concurrency
    { duration: '30s', target: 0 },    // ramp down
  ],
  thresholds: {
    http_req_duration: ['p(99)<2000'],
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  const payload = JSON.stringify({
    operationName: 'GetProductsWithReviews',
    query: `
      query GetProductsWithReviews {
        products(first: 20) {
          edges {
            node {
              id
              name
              reviews(first: 5) {
                edges {
                  node {
                    id
                    rating
                    author { id name }
                  }
                }
              }
            }
          }
        }
      }
    `,
  });

  const res = http.post(
    'https://api.staging.example.com/graphql',
    payload,
    { headers: { 'Content-Type': 'application/json' } }
  );

  check(res, {
    'status 200': (r) => r.status === 200,
    'no errors[]': (r) => !JSON.parse(r.body).errors,
    'products present': (r) => JSON.parse(r.body).data?.products?.edges?.length > 0,
  });

  sleep(0.1);
}
```

**Inject:**

```bash
k6 run k6-dataloader-concurrency.js --out prometheus=http://localhost:9090/api/v1/write
```

**Success criteria:**

```promql
# Database query rate stays within 2x of the single-user baseline
# (record baseline_db_query_rate before the test, then compare)
rate(database_queries_total{subgraph="products"}[1m])
/ on() group_left() scalar(baseline_db_query_rate)
< 2.0

# DataLoader batch size p5 stays above 2 (batching is active)
# (requires custom DataLoader metric — see docs/14-observability/03-metrics.md)
histogram_quantile(0.05,
  sum by (le) (
    rate(graphql_dataloader_batch_size_bucket[5m])
  )
) > 2

# Database connection pool saturation check
database_connection_pool_active / database_connection_pool_size < 0.9

# No spike in N+1 indicator: total DB queries per GraphQL request
rate(database_queries_total[1m])
/ rate(apollo_router_graphql_requests_total[1m])
< 25  # adjust threshold to 2x your single-user P50 ratio
```

**Rollback:** Reduce k6 VU count or terminate the test. No infrastructure change is required.

---

### Experiment 4 — Send a Complexity-Bomb Query

**Scenario:** A deeply nested query designed to maximise query complexity is sent to the router to verify that the complexity limit fires and rejects the query before any resolver is invoked.

**Hypothesis:** The router's query complexity analyser computes the complexity score of the bomb query before execution begins, the score exceeds the configured maximum complexity threshold, and the router returns `HTTP 200` with `errors[0].extensions.code = "QUERY_COMPLEXITY_EXCEEDED"`. No resolver is called. Database query metrics do not increase.

**Blast radius:** Zero production impact. The query is rejected at the validation phase, not the execution phase. No subgraph is called.

**Tool:** Custom script

**Inject command:**

```bash
# Send the complexity bomb query
curl -s -X POST https://api.staging.example.com/graphql \
  -H 'Content-Type: application/json' \
  -d '{
    "operationName": "ComplexityBomb",
    "query": "query ComplexityBomb { a: user(id: \"1\") { b: friends { c: friends { d: friends { e: friends { f: friends { id name email orders { id total items { id sku quantity product { id name description } } } } } } } } } }"
  }' | jq .
```

**Expected response:**

```json
{
  "data": null,
  "errors": [
    {
      "message": "Query complexity 4320 exceeds maximum allowed complexity of 1000",
      "locations": [],
      "extensions": {
        "code": "QUERY_COMPLEXITY_EXCEEDED",
        "complexity": 4320,
        "max_complexity": 1000
      }
    }
  ]
}
```

**Success criteria:**

```promql
# Complexity limit rejection counter increments
increase(
  apollo_router_query_planning_failure_total{
    reason="complexity_limit_exceeded"
  }[5m]
) > 0

# Resolver invocation rate does NOT increase (no resolver was called)
# (compare before/after: subgraph request count should not change)
delta(apollo_router_subgraph_requests_total[2m]) == 0

# Error rate for other operations is unchanged
rate(apollo_router_graphql_error_total[2m])
# should be flat — same as before experiment
```

**Verification checklist:**
- HTTP response status is 200 (not 400 or 500)
- `errors[0].extensions.code` is `QUERY_COMPLEXITY_EXCEEDED`
- No subgraph was called (check subgraph request logs — no new requests for the duration of the bomb query)
- The router access log shows the request as rejected at the planning phase

**Apollo Router configuration reference (`router.yaml`):**

```yaml
# Ensure limits are configured before running this experiment
limits:
  max_depth: 15
  max_aliases: 30
  max_complexity: 1000
  max_height: 200
  max_root_fields: 20
```

**Rollback:** No rollback needed. Query rejection leaves no state.

---

### Experiment 5 — Expire JWKS Keys Simultaneously

**Scenario:** JWKS signing keys are rotated in staging IAM while 100 authenticated requests are in-flight to verify that the router handles key rotation without dropping authenticated sessions.

**Hypothesis:** The router caches JWKS keys and refreshes them in the background. In-flight requests authenticated with the previous key are validated successfully using the cached key material. New requests after key rotation are validated using the new key material. Fewer than 1% of requests during the rotation window receive a 401 response.

**Blast radius:** All authenticated requests during the rotation window. Unauthenticated / public operations are unaffected.

**Tool:** IAM key rotation script + concurrent authenticated request sender

**Inject procedure:**

```bash
# Step 1: Generate concurrent authenticated requests (run in background)
# Replace with your actual token and endpoint
TOKEN=$(get-staging-token)  # your token acquisition script

for i in $(seq 1 100); do
  curl -s -X POST https://api.staging.example.com/graphql \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"query": "{ currentUser { id name email } }"}' \
    --max-time 10 \
    -o /tmp/chaos-response-${i}.json &
done

# Step 2: Immediately rotate JWKS keys (while requests are in-flight)
# This is IAM-provider-specific; example for a custom JWKS provider:
./scripts/rotate-jwks-staging.sh

# Step 3: Wait for all requests to complete
wait

# Step 4: Count 401 responses
grep -l '"errors"' /tmp/chaos-response-*.json | wc -l
```

**JWKS rotation script reference (`rotate-jwks-staging.sh`):**

```bash
#!/bin/bash
set -euo pipefail

# Generate new RSA key pair
openssl genrsa -out /tmp/new-signing-key.pem 2048
openssl rsa -in /tmp/new-signing-key.pem -pubout -out /tmp/new-signing-key-pub.pem

# Upload new JWKS to staging key server
# (implementation depends on your IAM provider)
curl -X PUT https://auth.staging.example.com/jwks \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(./scripts/pem-to-jwks.py /tmp/new-signing-key-pub.pem)"

echo "JWKS rotated at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

**Success criteria:**

```promql
# 401 rate during rotation window stays below 1%
sum(rate(apollo_router_graphql_error_total{
  error_type="auth",
  http_status="401"
}[2m]))
/ sum(rate(apollo_router_graphql_requests_total[2m]))
< 0.01

# JWKS cache refresh is observed in router metrics
increase(
  apollo_router_authentication_jwks_refresh_total[5m]
) > 0

# No complete error spike overall
sum(rate(apollo_router_graphql_error_total{error_type="complete"}[2m]))
/ sum(rate(apollo_router_graphql_requests_total[2m]))
< 0.01
```

**Verification checklist:**
- Router logs show JWKS cache refresh triggered after key rotation
- In-flight requests (initiated before rotation) completed with 200, not 401
- New requests after rotation succeed with the new key material
- No user-visible authentication errors in APM

**Rollback:**

```bash
# If rotation causes widespread auth failures, roll back to previous JWKS
./scripts/restore-jwks-staging.sh --key-id previous
```

---

### Experiment 6 — Fill the Apollo Router Document Cache

**Scenario:** 10,000 distinct operation documents are sent to the router rapidly to fill the query plan cache and trigger cache eviction under memory pressure, to verify that cache eviction does not cause incorrect query planning for previously cached operations.

**Hypothesis:** The router evicts least-recently-used query plans from the document cache as memory pressure rises. Operations that were evicted are re-planned correctly on next request. Operations that remain cached continue to produce correct plans. No schema validation errors occur, and no query produces incorrect field resolution after the cache churn.

**Blast radius:** Router CPU and memory pressure. Other services are not affected. Risk: router OOM if memory limit is too low — run in staging only.

**Tool:** k6 document cache filler script

**Inject command:**

```javascript
// k6-cache-fill.js
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  vus: 100,
  iterations: 10000,
};

// Generate distinct operation documents by varying field selection sets
function generateQuery(seed) {
  const fields = ['id', 'name', 'email', 'createdAt', 'updatedAt', 'status'];
  // Select a different subset of fields for each seed value
  const selectedFields = fields.filter((_, i) => (seed >> i) & 1 || i === 0);
  return `
    query CacheFillOp_${seed} {
      currentUser {
        ${selectedFields.join('\n        ')}
      }
    }
  `;
}

export default function () {
  const seed = Math.floor(Math.random() * 10000);
  const payload = JSON.stringify({
    operationName: `CacheFillOp_${seed}`,
    query: generateQuery(seed),
  });

  const res = http.post(
    'https://api.staging.example.com/graphql',
    payload,
    { headers: { 'Content-Type': 'application/json' } }
  );

  check(res, {
    'status 200': (r) => r.status === 200,
    'no schema validation errors': (r) => {
      const body = JSON.parse(r.body);
      if (!body.errors) return true;
      return !body.errors.some(e =>
        e.extensions?.code === 'GRAPHQL_VALIDATION_FAILED' ||
        e.extensions?.code === 'INVALID_QUERY_PLAN'
      );
    },
  });
}
```

**Inject:**

```bash
k6 run k6-cache-fill.js

# After the cache fill, immediately re-test previously known operations
# to verify they still plan correctly
k6 run --vus 20 --duration 60s known-operations-regression-test.js
```

**Success criteria:**

```promql
# No schema validation errors (would indicate incorrect plan after eviction)
increase(
  apollo_router_query_planning_failure_total{reason="validation_failed"}[10m]
) == 0

# Query plan cache eviction is observable (confirms the experiment is working)
increase(apollo_router_cache_eviction_total{cache="query_plan"}[10m]) > 0

# Re-planning latency spike is acceptable (evicted operations take longer on next request)
histogram_quantile(0.99,
  sum by (le) (
    rate(apollo_router_query_planning_time_seconds_bucket[5m])
  )
) < 0.5  # 500ms planning time is acceptable under cache pressure

# No router OOM events
kube_pod_container_status_restarts_total{
  namespace="graphql-platform",
  container="router"
}  # should not increase
```

**Rollback:**

```bash
# If router OOM loop occurs, reduce document cache size in router config
# and redeploy
kubectl rollout restart deployment/apollo-router -n graphql-platform
```

---

## Chaos Mesh Setup

Chaos Mesh is a Kubernetes-native chaos engineering platform. Install it before running network-based experiments.

```bash
# Install Chaos Mesh via Helm
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update

helm install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-testing \
  --create-namespace \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
  --version 2.6.3
```

**Verify installation:**

```bash
kubectl get pods -n chaos-testing
kubectl get crd | grep chaos-mesh
```

**RBAC for platform engineers to run chaos experiments:**

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: chaos-engineer
  namespace: graphql-platform
rules:
  - apiGroups: ["chaos-mesh.org"]
    resources: ["networkchaos", "podchaos", "stresschaos", "iochaos"]
    verbs: ["get", "list", "watch", "create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: chaos-engineer-binding
  namespace: graphql-platform
subjects:
  - kind: Group
    name: platform-engineers
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: chaos-engineer
  apiGroup: rbac.authorization.k8s.io
```

---

## AWS Fault Injection Simulator

For experiments on AWS-managed infrastructure (EKS node failures, RDS connection disruption, ALB latency injection):

```json
{
  "description": "GraphQL orders subgraph — RDS connection disruption",
  "stopConditions": [
    {
      "source": "aws:cloudwatch:alarm",
      "value": "arn:aws:cloudwatch:us-east-1:123456789012:alarm:GraphQL-SLO-Breach"
    }
  ],
  "targets": {
    "RDSCluster": {
      "resourceType": "aws:rds:cluster",
      "resourceArns": [
        "arn:aws:rds:us-east-1:123456789012:cluster:orders-db-staging"
      ],
      "selectionMode": "ALL"
    }
  },
  "actions": {
    "DisruptRDSConnections": {
      "actionId": "aws:rds:failover-db-cluster",
      "parameters": {},
      "targets": { "Clusters": "RDSCluster" }
    }
  },
  "roleArn": "arn:aws:iam::123456789012:role/FISExperimentRole"
}
```

**Key FIS configuration points:**
- Always configure stop conditions tied to your SLO alarm — if SLO breach occurs, FIS stops the experiment automatically
- Use IAM resource-based policies to limit FIS scope to staging accounts
- Tag all FIS experiment templates with `Environment: staging` and `Team: platform`

---

## Gameday Procedure

### Planning Phase (1 Week Before)

**Participants:** Incident commander, platform engineers (2–3), representative from each affected subgraph team, engineering lead

**Deliverables before gameday:**

```
[ ] Hypothesis document — one paragraph per experiment: what we believe will happen and why
[ ] Blast radius map — which services, which clients, which data paths are in scope
[ ] Rollback plan — documented and assigned to a specific engineer
[ ] Monitoring readiness — all success criteria PromQL queries saved in Grafana
[ ] Notification sent to all teams — at least 48 hours advance notice
[ ] Staging environment verified as representative of production (data shape, traffic pattern)
[ ] On-call pager suspended for staging during experiment window (staging alerts paused)
```

**Hypothesis document template:**

```markdown
## Experiment: {Name}

**Date:** {YYYY-MM-DD}
**Duration:** {N} minutes
**Incident commander:** {Name}
**Rollback owner:** {Name}

### Hypothesis
If {fault condition}, then {expected system behavior} because {reasoning about the system}.

### Observable signals
We will observe success via:
- {Metric 1}: expected value {X}
- {Metric 2}: expected value {Y}

### Blast radius
- Services affected: {list}
- Client impact: {description or "none — staging only"}
- Data risk: {description or "none"}

### Rollback trigger
We will abort and rollback if:
- {Metric} exceeds {threshold}
- {System behavior} is observed
```

---

### Execution Phase

**Announce in incident channel:**

```
@channel GAMEDAY STARTING
Experiment: {name}
Duration: {N} minutes
Hypothesis: {one sentence}
Rollback owner: {name}
Dashboard: {link}
This is a PLANNED chaos experiment — do not page.
```

**Execution sequence:**

```
T-5 min   Final checklist: dashboards open, rollback script ready, team on call
T+0 min   Inject fault condition
T+0 min   Begin recording observations (screenshots, log snippets, metric values)
T+5 min   Check success criteria metrics — is the system behaving as hypothesized?
T+N min   Stop experiment (remove fault injection)
T+N+5     Observe recovery — does the system return to baseline?
T+N+15    Capture final metric screenshots
```

**If the system does NOT behave as hypothesized:**

1. Execute the documented rollback immediately — do not investigate first
2. Confirm system health is restored before analysis
3. Record the unexpected behavior (screenshots, log lines)
4. Do not re-run the experiment — schedule a follow-up after root cause analysis

---

### Retrospective Phase

Conduct a 30-minute retrospective within 24 hours of the gameday. Cover:

**1. Did the system behave as expected?**
- If yes: the hypothesis is validated. Document the experiment results and mark the hypothesis as confirmed.
- If no: the hypothesis is falsified. This is the primary value of chaos engineering — you found a gap before a real incident exposed it.

**2. What did we learn?**
- About the system: failure modes, recovery behavior, blast radius accuracy
- About our monitoring: did dashboards show what we needed? Were there gaps?
- About our runbooks: did the rollback procedure work as documented?

**3. What do we change?**
- Prioritized action items with owners and due dates
- Any experiment that falsified its hypothesis produces at least one architecture change or monitoring improvement

---

## Success Criteria — GraphQL Chaos Resilience

A GraphQL platform is chaos-resilient when it meets all of the following criteria:

### Error Semantics Correctness

```
[ ] Subgraph failure produces partial data + errors[], not a complete failure
[ ] errors[].path correctly identifies which field failed
[ ] errors[].extensions.code is populated and meaningful
[ ] data.{non-failing fields} are correctly populated when one subgraph fails
```

### SLO Preservation

```promql
# The platform's SLO holds during single-subgraph failure
# (one subgraph failure should not breach the SLO)
sum(rate(apollo_router_graphql_error_total{error_type="complete"}[5m]))
/ sum(rate(apollo_router_graphql_requests_total[5m]))
< 0.001  # 99.9% success rate maintained during partial failure
```

### Recovery Behavior

```
[ ] Router detects subgraph failure within health check interval (≤ 30s)
[ ] Router resumes sending requests to recovered subgraph within 60s
[ ] Query plan cache is not corrupted by a subgraph restart
[ ] JWKS cache refreshes correctly after key rotation
```

### Security Controls Under Load

```
[ ] Complexity limit fires before resolvers execute (no partial execution on bomb query)
[ ] JWKS rotation does not drop in-flight authenticated requests
[ ] Auth failures return 401 with GraphQL errors[], not raw HTTP 500
```

### DataLoader Integrity

```
[ ] Batch size stays above 2 under 200 concurrent VUs (batching is active)
[ ] Database connection pool does not saturate under concurrent load
[ ] N+1 query rate (DB queries / GraphQL requests) does not double under concurrency
```

---

## CI Integration — Automated Hypothesis Validation

Full gamedays are not automated — they require human observation and judgment. However, a subset of experiments can run automatically in staging CI to catch regressions between deployments.

**What to automate:**

| Experiment | Automation | Trigger |
|-----------|------------|---------|
| Complexity bomb | Yes — deterministic output | Every deployment to staging |
| JWKS rotation | Yes — if JWKS rotation is scripted | Weekly on a schedule |
| Kill a subgraph pod | Partially — observe error semantics only | Weekly on a schedule |
| DataLoader concurrency | Yes — k6 script + PromQL check | Every deployment to staging |
| Latency injection | No — requires human observation of partial data correctness | Gameday only |
| Document cache fill | No — requires human review of planning correctness | Gameday only |

**Automated CI step — complexity limit verification:**

```yaml
# .github/workflows/chaos-smoke.yaml
name: Chaos Smoke Tests

on:
  push:
    branches: [main, staging]

jobs:
  complexity-limit:
    name: Verify complexity limit fires
    runs-on: ubuntu-latest
    environment: staging
    steps:
      - uses: actions/checkout@v4

      - name: Send complexity bomb query
        id: complexity_test
        run: |
          RESPONSE=$(curl -s -X POST ${{ secrets.STAGING_GRAPHQL_URL }} \
            -H 'Content-Type: application/json' \
            -d '{"operationName":"ComplexityBomb","query":"query ComplexityBomb { a: user(id: \"1\") { b: friends { c: friends { d: friends { id name orders { id } } } } } }"}')

          echo "response=$RESPONSE" >> $GITHUB_OUTPUT

          # Assert complexity limit fired
          echo $RESPONSE | jq -e '.errors[0].extensions.code == "QUERY_COMPLEXITY_EXCEEDED"'
          echo $RESPONSE | jq -e '.data == null'

      - name: Verify no resolver was called
        run: |
          # Check Prometheus metric for subgraph requests — should not have increased
          SUBGRAPH_REQUESTS=$(curl -s "${{ secrets.PROMETHEUS_URL }}/api/v1/query?query=delta(apollo_router_subgraph_requests_total[2m])" | jq '.data.result[0].value[1]')
          if [ "$SUBGRAPH_REQUESTS" != "0" ]; then
            echo "ERROR: Subgraph requests increased after complexity bomb — complexity limit not firing before resolvers"
            exit 1
          fi

  dataloader-regression:
    name: DataLoader N+1 regression check
    runs-on: ubuntu-latest
    environment: staging
    steps:
      - uses: actions/checkout@v4

      - name: Install k6
        run: |
          sudo apt-get install -y gpg
          curl -s https://dl.k6.io/key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
          echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
          sudo apt-get update && sudo apt-get install -y k6

      - name: Run DataLoader concurrency test
        run: k6 run --vus 50 --duration 60s chaos-experiments/k6-dataloader-concurrency.js

      - name: Check N+1 ratio via Prometheus
        run: |
          DB_RATE=$(curl -s "${{ secrets.PROMETHEUS_URL }}/api/v1/query?query=rate(database_queries_total[1m])%2Frate(apollo_router_graphql_requests_total[1m])" | jq '.data.result[0].value[1]')
          THRESHOLD=25  # adjust to 2x your baseline
          if (( $(echo "$DB_RATE > $THRESHOLD" | bc -l) )); then
            echo "N+1 regression detected: DB/GQL ratio is $DB_RATE (threshold: $THRESHOLD)"
            exit 1
          fi
```

---

## Tooling Reference

| Tool | Purpose | Documentation |
|------|---------|---------------|
| Chaos Mesh | Kubernetes-native network and pod chaos | https://chaos-mesh.org/docs/ |
| AWS FIS | AWS-managed fault injection for RDS, EKS, ALB | https://docs.aws.amazon.com/fis/ |
| k6 | Load testing and concurrency simulation | https://k6.io/docs/ |
| kubectl | Pod deletion, rollout restart | https://kubernetes.io/docs/reference/kubectl/ |
| Grafana | Dashboard observation during experiments | https://grafana.com/docs/ |
| Prometheus | PromQL success criteria evaluation | https://prometheus.io/docs/querying/basics/ |

---

## Validation Checklist

```
[ ] All six experiments have been run at least once in staging
[ ] Each experiment result is documented in the team wiki (pass or fail)
[ ] Experiments that revealed gaps have associated action items in the platform backlog
[ ] Automated chaos smoke tests run on every staging deployment
[ ] Gameday schedule: at least one full gameday per quarter
[ ] Rollback procedures are documented and have been exercised
[ ] Chaos engineering results feed into post-mortem action items when gaps are found
[ ] Chaos Mesh is installed and RBAC is configured in the staging cluster
[ ] AWS FIS stop conditions are tied to the production SLO CloudWatch alarm
```

---

## Related Topics

- [01-incident-classification.md](./01-incident-classification.md) — Severity framework that chaos experiments validate
- [02-on-call-procedures.md](./02-on-call-procedures.md) — First-response procedures tested by chaos gamedays
- [03-incident-response-playbooks.md](./03-incident-response-playbooks.md) — Playbooks exercised during gameday scenarios
- [14-observability/05-slos-and-alerting.md](../14-observability/05-slos-and-alerting.md) — SLO definitions that chaos success criteria reference
- [06-performance-and-scaling/README.md](../06-performance-and-scaling/README.md) — DataLoader performance patterns validated by Experiment 3

## References

- [Principles of Chaos Engineering](https://principlesofchaos.org/) — original chaos engineering principles
- [Chaos Mesh Documentation](https://chaos-mesh.org/docs/) — Chaos Mesh manifests and controller reference
- [AWS Fault Injection Simulator User Guide](https://docs.aws.amazon.com/fis/latest/userguide/what-is.html)
- [k6 Documentation](https://k6.io/docs/) — load testing script reference
- [Apollo Router Configuration — Limits](https://www.apollographql.com/docs/router/configuration/traffic-shaping/) — complexity limit configuration
- [Google SRE Workbook — Implementing SLOs](https://sre.google/workbook/implementing-slos/) — SLO success criteria framework
