# 03 — Incident Response Playbooks

> **Purpose**
> This document provides step-by-step response playbooks for the five most common GraphQL platform incidents. Each playbook follows the same structure: symptoms, diagnostic steps, mitigation options (in order of speed), and root cause patterns. Written to be executed during an active incident — no prior reading assumed beyond the on-call handbook.

---

## How to Use These Playbooks

1. Run the diagnostic sequence from `02-on-call-procedures.md` first to identify which playbook applies.
2. Start with the fastest mitigation option — verify improvement before attempting a more invasive approach.
3. Post each action to the incident channel before executing it.
4. Do not skip steps even if you believe you already know the root cause. Confirmation before action prevents cascading mistakes.

---

## Playbook Index

| Incident | Section | Typical SEV |
|----------|---------|-------------|
| Router OOM | [Section 1](#1-router-oom) | SEV1 |
| Subgraph Timeout Cascade | [Section 2](#2-subgraph-timeout-cascade) | SEV1–SEV2 |
| Schema Composition Failure | [Section 3](#3-schema-composition-failure) | SEV2 |
| Authentication Outage | [Section 4](#4-authentication-outage) | SEV1–SEV2 |
| DataLoader Memory Leak | [Section 5](#5-dataloader-memory-leak) | SEV2–SEV3 |

---

## 1. Router OOM

### Symptoms

- Multiple `apollo-router` pods in `OOMKilled` or `CrashLoopBackOff` state
- `kube_pod_container_status_restarts_total{container="apollo-router"}` increasing rapidly
- Complete error rate approaches 100% between pod restarts
- Router memory metric `process_resident_memory_bytes{app="apollo-router"}` spiked before kill

**What the on-call engineer observes:**
```
GraphQL SLO dashboard: error rate 95%, burn rate > 100x
Router metrics dashboard: memory at 3.8GB (limit: 4GB), then 0 (restart), then 3.8GB again
kubectl get pods -n graphql: STATUS CrashLoopBackOff RESTARTS 7 (2m ago)
```

### Diagnosis

**Step 1: Confirm OOM kill**
```bash
kubectl describe pod -n graphql -l app=apollo-router | grep -A5 "Last State"
# Expect: Reason: OOMKilled
```

**Step 2: Identify the query causing the allocation**

OOM in Apollo Router is almost always caused by one of:
a) A client sending an unbounded query (deeply nested lists with no pagination limit)
b) A response object that is too large (e.g., `getProducts` returning 50,000 items)
c) A query complexity regression (complexity limit disabled or misconfigured)

Check query complexity histogram *before* the OOM event:
```promql
# Top operations by complexity score in last 30 minutes
topk(10,
  histogram_quantile(0.99,
    sum by (le, operation_name) (
      rate(apollo_router_graphql_complexity_score_bucket[30m])
    )
  )
)
```

Check Loki logs for large responses:
```
{app="apollo-router"} | json | response_size_bytes > 10000000
| line_format "{{.timestamp}} op={{.graphql_operation_name}} size={{.response_size_bytes}} client={{.client_name}}"
```

**Step 3: Confirm memory trend in traces**

Look in Tempo for spans from the time window before the OOM kill. Find operations with unusually long duration and check if they correlate with large response sizes.

### Mitigation (in order of speed)

**Option A: Kill pods and let Kubernetes reschedule (fastest — 2 min)**
```bash
# Delete all router pods — Kubernetes recreates them from the Deployment
kubectl delete pods -n graphql -l app=apollo-router
```

This gives temporary relief for 30–120 seconds while new pods warm up. The OOM loop will resume if the offending query is still being sent.

**Option B: Apply an emergency complexity limit (3 min)**

Add a complexity limit to the router configuration. This is the definitive mitigation if the root cause is an unbounded query.

```yaml
# router.yaml — add complexity limiting
preview_operation_limits:
  max_depth: 15
  max_height: 200
  max_aliases: 30
  max_root_fields: 20
  max_complexity: 5000
```

Apply via ConfigMap and rollout:
```bash
kubectl patch configmap apollo-router-config -n graphql \
  --patch '{"data": {"router.yaml": "...complexity config..."}}'
kubectl rollout restart deployment/apollo-router -n graphql
kubectl rollout status deployment/apollo-router -n graphql --timeout=120s
```

**Option C: Identify and block the offending client (5 min)**

If a single client is sending the unbounded query, rate-limit or block it:
```yaml
# router.yaml — add client-specific rate limiting
traffic_shaping:
  all:
    global_rate_limit:
      capacity: 1000
      interval: 1s
  router:
    rate_limit:
      mode: header
      header: x-client-name
      capacity: 100
      interval: 1s
```

**Option D: Temporarily scale up memory limits (last resort)**

Do not do this without engineering lead approval — it treats the symptom, not the cause:
```bash
kubectl set resources deployment/apollo-router -n graphql \
  --limits=memory=8Gi --requests=memory=4Gi
```

### Root Cause Patterns

| Root Cause | How to Identify | Permanent Fix |
|------------|----------------|---------------|
| No complexity limit configured | Absence of `max_complexity` in router config | Add complexity limit in router config |
| Client sending unbounded query | High complexity score in logs for specific client | Add per-client complexity limit; work with client team |
| Pagination bypassed in resolver | `getProducts` returning all records instead of page | Add pagination enforcement in resolver |
| Complexity limit too high | Limit set to 100,000 — effectively infinite | Reduce limit based on observed p99 complexity |

**Post-mitigation confirmation:**
```promql
# Router memory should stabilize below 2GB
avg(process_resident_memory_bytes{app="apollo-router"}) < 2e9

# No further OOM restarts
rate(kube_pod_container_status_restarts_total{container="apollo-router"}[5m]) == 0
```

---

## 2. Subgraph Timeout Cascade

### Symptoms

- One subgraph begins returning slow responses (p99 > 2000ms)
- Operations that depend on that subgraph start accumulating errors or timeouts
- Other subgraphs may start appearing slow due to router thread exhaustion (cascade)
- Router CPU spikes as it retries and waits for the slow subgraph

**What the on-call engineer observes:**
```
Subgraph health dashboard: orders subgraph p99 = 8,200ms (baseline: 180ms)
SLO dashboard: partial error rate rising — checkout operations affected
Router metrics: request queue depth rising, concurrent connections at limit
```

### Diagnosis

**Step 1: Isolate the slow subgraph**
```promql
# p99 latency by subgraph — identify the outlier
histogram_quantile(0.99,
  sum by (le, subgraph_name) (
    rate(apollo_router_subgraph_request_duration_seconds_bucket[5m])
  )
) * 1000  # ms
```

**Step 2: Determine if it is the subgraph or its downstream**
```bash
# Direct health check to the subgraph (bypass router)
curl -w "@curl-format.txt" -s -o /dev/null \
  http://orders-subgraph.graphql.svc.cluster.local:4000/health

# Check subgraph pod logs
kubectl logs -n graphql -l app=orders-subgraph --since=5m | grep -E "error|timeout|slow"

# Check subgraph database connection pool
# (look for "connection pool exhausted" or similar)
kubectl logs -n graphql -l app=orders-subgraph --since=5m | grep -i "pool"
```

**Step 3: Check if the slowness is spreading (cascade detection)**
```promql
# All subgraphs — is more than one slowing down?
sum by (subgraph_name) (
  rate(apollo_router_subgraph_request_timeout_total[5m])
)
```

If multiple subgraphs are showing timeouts after the first one, the cascade has begun. The router is holding connections open waiting for the slow subgraph, reducing available threads for other subgraphs.

**Step 4: Check for a recent deployment**
```bash
kubectl rollout history deployment/orders-subgraph -n graphql
```

A deployment in the last 30 minutes is the most likely cause.

### Mitigation

**Option A: Enable partial data mode (fastest — 1 min)**

Apollo Router can be configured to return partial data when a subgraph times out, rather than failing the entire operation. If this is not already enabled:

```yaml
# router.yaml
traffic_shaping:
  all:
    timeout: 30s
  subgraphs:
    orders:
      timeout: 2s   # Reduce from default (30s) to fail fast
```

Apply and rollout:
```bash
kubectl patch configmap apollo-router-config -n graphql \
  --patch '{"data":{"router.yaml":"...timeout config..."}}'
kubectl rollout restart deployment/apollo-router -n graphql
```

With a 2-second subgraph timeout, the router will fail fast and return partial data (with an error in `errors[]`) rather than holding all threads waiting 30 seconds.

**Option B: Roll back the offending subgraph (3 min)**

If a deployment correlation is confirmed:
```bash
kubectl rollout undo deployment/orders-subgraph -n graphql
kubectl rollout status deployment/orders-subgraph -n graphql --timeout=120s
```

Monitor the subgraph p99 latency — it should return to baseline within 2 minutes.

**Option C: Scale the slow subgraph (5 min)**

If the slowness is caused by resource exhaustion (CPU or memory) rather than a code regression:
```bash
kubectl scale deployment/orders-subgraph -n graphql --replicas=10
```

Confirm pod readiness:
```bash
kubectl get pods -n graphql -l app=orders-subgraph -w
```

**Option D: Circuit-break the slow subgraph**

Use this only if partial data mode is acceptable for the affected operations and the subgraph cannot recover quickly:

```yaml
# router.yaml — add circuit breaker for orders subgraph
traffic_shaping:
  subgraphs:
    orders:
      timeout: 1s
      # When timeout threshold is exceeded, return null for orders fields
      # with a predictable error message
```

This allows checkout operations to proceed without order history, rather than failing entirely.

### Root Cause Patterns

| Root Cause | Diagnostic Signal | Permanent Fix |
|------------|-----------------|---------------|
| Missing database index after schema change | Slow query log in subgraph DB | Add index; add query analysis to CI |
| Memory leak in subgraph process | Memory grows over time, GC pauses | Identify and fix memory leak |
| Upstream dependency down (payment provider, etc.) | Subgraph timeout cascades from one external call | Add circuit breaker in subgraph for external calls |
| Thundering herd after deployment | Latency spike at deployment time, recovers | Pre-warm with canary deployment |
| Connection pool exhausted | `connection pool` errors in subgraph logs | Increase pool size; fix connection leaks |

**Post-mitigation confirmation:**
```promql
# Subgraph p99 should return to baseline
histogram_quantile(0.99,
  sum by (le, subgraph_name) (
    rate(apollo_router_subgraph_request_duration_seconds_bucket[5m])
  )
) * 1000 < 500  # ms
```

---

## 3. Schema Composition Failure

### Symptoms

- CI pipeline failing with schema composition errors
- New subgraph deployments blocked — rover compose returns non-zero exit code
- Apollo GraphOS (or self-hosted schema registry) shows composition errors
- No new schema version published in the last `N` hours (unusual for active teams)

**Note:** A schema composition failure does not immediately affect live traffic. The current published schema continues serving. The urgency is that no subgraph team can deploy until the composition is fixed.

**What the engineer observes:**
```
CI: "Failed to compose supergraph: ... Field 'Product.price' is defined differently in 'catalog' and 'pricing' subgraphs"
Schema registry: Last successful composition: 4 hours ago
Deployment pipeline: ALL subgraph deployments blocked
```

### Diagnosis

**Step 1: Read the composition error message**

The error message from `rover supergraph compose` is specific. Common patterns:

```
# Conflicting field type
Error: Field 'Product.price' has type 'Float!' in subgraph 'catalog'
       but type 'Int!' in subgraph 'pricing'.
       Subgraphs must agree on the type of shared fields.

# Missing @key directive
Error: Type 'Order' in subgraph 'orders' is referenced by 'checkout'
       subgraph via @provides but does not define a @key.

# Inaccessible field used as @key
Error: @key field 'User.externalId' in subgraph 'identity' is marked @inaccessible
       but is used as an @key in subgraph 'orders'.
```

**Step 2: Identify the offending subgraph**

```bash
# Run composition locally to see the full error
rover supergraph compose --config supergraph.yaml 2>&1 | grep "Error"

# Check which subgraph's SDL was most recently changed
git log --oneline docs/schemas/ | head -10
```

**Step 3: Check which change broke composition**

```bash
# Find the PR that introduced the breaking change
git log --all --oneline --grep="schema" | head -20

# Compare current SDL with last known-good version
git diff HEAD~1 schemas/pricing/schema.graphql
```

### Mitigation

**Option A: Revert the offending subgraph schema (fastest — 5 min)**

```bash
# Identify the commit that broke composition
git log --oneline schemas/pricing/schema.graphql

# Revert the file to the last working version
git checkout {last-good-commit} -- schemas/pricing/schema.graphql

# Create a PR with the revert and fast-track it through review
git commit -m "fix(schema): revert pricing schema to restore composition"
```

**Option B: Fix the composition conflict (10–30 min)**

If the breaking change is intentional (both subgraph teams agreed on the type change), the fix is to align the other subgraph's schema to match:

```graphql
# Before (conflicting): pricing subgraph uses Int!
type Product @key(fields: "id") {
  id: ID!
  price: Int!  # Wrong — catalog uses Float!
}

# After (aligned): pricing subgraph matches catalog
type Product @key(fields: "id") {
  id: ID!
  price: Float!  # Now matches — composition will succeed
}
```

**Option C: Override and ship with federation-compatible types**

If the type difference is semantically equivalent (e.g., `ID` vs `String` for identifier fields), use the `@override` directive or restructure as a value type:

```graphql
# pricing subgraph — use @external for fields owned by catalog
type Product @key(fields: "id") {
  id: ID!
  price: Float!  # Matches catalog
}
```

### Root Cause Patterns

| Root Cause | How It Happens | Prevention |
|------------|---------------|-----------|
| Type drift between subgraphs | Two teams independently evolve a shared type without coordination | Schema change review process; GraphOS schema checks in CI |
| Missing @key after refactor | Team renames a field that was used as a federation @key | rover subgraph check in CI before merge |
| @inaccessible field referenced externally | Team hides a field that another subgraph's @key depends on | Cross-subgraph @key validation in CI |
| Breaking change in shared value type | Changing `Float!` to `Int!` on a field used by multiple subgraphs | Schema governance review; breaking change policy |

**Post-mitigation confirmation:**
```bash
# Composition should succeed
rover supergraph compose --config supergraph.yaml
echo "Exit code: $?"  # Should be 0

# New schema version published to registry
rover subgraph introspect http://pricing-subgraph/graphql
```

---

## 4. Authentication Outage

### Symptoms

- 401 or 403 errors spiking across all authenticated operations
- `apollo_router_graphql_error_total{error_code="UNAUTHENTICATED"}` rising fast
- JWKS endpoint health check failing (or HTTP 5xx responses)
- Public (unauthenticated) operations continue working normally

**What the on-call engineer observes:**
```
SLO dashboard: complete error rate 40% (all mutations failing; most queries failing)
Loki logs: UNAUTHENTICATED errors dominating — all with auth_error=true label
Grafana: JWKS fetch failure count rising — last successful fetch was 8 minutes ago
Public operations (no auth required): still returning 200 OK with data
```

### Diagnosis

**Step 1: Confirm the auth system is the problem**

```bash
# Check JWKS endpoint directly
curl -v https://auth.internal.example.com/.well-known/jwks.json

# Expected: HTTP 200 with JSON body containing "keys" array
# Failing: HTTP 503, connection refused, or timeout
```

**Step 2: Check JWKS key rotation timing**

```bash
# Check when JWKS keys were last rotated
# (auth team should have a record of this)

# Check if router is caching stale JWKS keys
kubectl logs -n graphql -l app=apollo-router --since=15m | grep -i "jwks\|jwt\|auth"
```

Apollo Router caches JWKS keys. After a key rotation, there is a window where the router has cached the old keys and is rejecting valid JWTs signed with the new keys. The default JWKS cache TTL in the router is typically 60 seconds. If keys were rotated more aggressively than expected, or the cache TTL is too long, all requests fail during the gap.

**Step 3: Check if the issue is JWKS endpoint availability or key mismatch**

```bash
# Decode a failing JWT to see what kid (key ID) it expects
# (request the token from the client team or generate a test token)
echo {JWT_TOKEN_BASE64} | base64 -d | python3 -m json.tool

# Check which key ID is in the JWKS endpoint
curl -s https://auth.internal.example.com/.well-known/jwks.json | python3 -m json.tool | grep kid
```

If the JWT `kid` does not match any key in the JWKS endpoint, the auth system rotated keys and the router needs to flush its JWKS cache.

### Mitigation

**Option A: Force JWKS cache refresh in router (fastest — 1 min)**

```bash
# Restart the router to flush JWKS cache
kubectl rollout restart deployment/apollo-router -n graphql
kubectl rollout status deployment/apollo-router -n graphql --timeout=120s
```

This forces the router to re-fetch the JWKS keys. New pods will use the current JWKS endpoint.

**Option B: Enable anonymous fallback for public operations**

If the auth service is completely down and will take > 30 minutes to recover, temporarily allow public operations without authentication. This limits the blast radius.

```yaml
# router.yaml — allow unauthenticated access to explicitly listed operations
authentication:
  router:
    jwt:
      jwks:
        - url: "https://auth.internal.example.com/.well-known/jwks.json"
      # Allow operations that do not carry a token (public operations)
      ignore_missing_tokens: false  # Keep this strict unless opting into the fallback
```

Discuss this mitigation with the engineering lead before applying — it may have security implications.

**Option C: Point to backup JWKS endpoint**

If the primary JWKS endpoint is down but a replica exists:
```yaml
# router.yaml — add fallback JWKS URL
authentication:
  router:
    jwt:
      jwks:
        - url: "https://auth.internal.example.com/.well-known/jwks.json"
        - url: "https://auth-backup.internal.example.com/.well-known/jwks.json"
```

**Option D: Coordinate with auth team on key rotation**

If the issue is key rotation timing:
1. Ask the auth team to re-issue tokens signed with the still-cached key (temporary rollback of key rotation)
2. OR extend the JWKS cache TTL in the router and accept that key revocations take longer to propagate

### Root Cause Patterns

| Root Cause | How to Identify | Permanent Fix |
|------------|----------------|---------------|
| JWKS endpoint downtime | `curl` to JWKS endpoint fails | Add JWKS endpoint to uptime monitoring; add HA replica |
| Key rotation without router coordination | JWT kid not in JWKS; rotation was recent | Implement graceful key rotation with overlap window |
| JWKS cache TTL too short (too many fetches) | JWKS fetch errors during key rotation window | Extend TTL; implement key rotation overlap period |
| Router JWKS cache TTL too long | Old keys cached after rotation — new tokens rejected | Reduce TTL; implement key rotation notification to flush cache |
| Expired signing certificate | Certificate expiry in auth system | Implement certificate expiry alerting with 30-day warning |

**Post-mitigation confirmation:**
```promql
# UNAUTHENTICATED error rate should drop to near zero
rate(apollo_router_graphql_error_total{error_code="UNAUTHENTICATED"}[5m]) < 0.001
```

---

## 5. DataLoader Memory Leak

### Symptoms

- Subgraph pod memory grows continuously across multiple requests
- Memory is never garbage-collected between requests
- Gradual latency increase as GC pauses lengthen
- Eventually: OOMKill of subgraph pods (without the obvious large-query signal of router OOM)
- DataLoader batch size remains high (batching is working) — this is *not* an N+1 issue

**What the on-call engineer observes:**
```
Subgraph health dashboard (orders): memory growing from 512MB to 1.8GB over 4 hours
Pod restarts starting: OOMKilled every ~2 hours, then memory climbs again
DataLoader batch size: normal (10–20 per batch) — not an N+1 regression
Request rate: unchanged — the leak grows even at constant load
```

### Diagnosis

**Step 1: Confirm the memory growth pattern**
```promql
# Orders subgraph memory over time — should be stable, not growing
process_resident_memory_bytes{app="orders-subgraph"}
```

If the memory graph shows a steady upward trend across multiple pod restarts (memory climbs after each restart), it is a per-request leak, not a one-time large allocation.

**Step 2: Take a heap snapshot**

```bash
# Connect to the pod
kubectl exec -it -n graphql $(kubectl get pods -n graphql -l app=orders-subgraph -o name | head -1) -- /bin/sh

# Trigger heap snapshot (Node.js example)
node --inspect=0.0.0.0:9229 &
# Then use Chrome DevTools remote debugging to take a heap snapshot
```

Alternatively, if the subgraph exposes a diagnostics endpoint:
```bash
curl http://orders-subgraph.graphql.svc.cluster.local:4000/debug/heap-snapshot
```

**Step 3: Identify DataLoader not scoped to request**

The most common cause of DataLoader memory leaks is a DataLoader instance that is created at module load time (singleton) rather than per-request. This means every key loaded across all requests accumulates in the DataLoader's internal cache forever.

**Leaking pattern (DataLoader created as module singleton):**
```typescript
// WRONG — DataLoader created once at module load time
// Cache grows indefinitely across all requests
const userLoader = new DataLoader(async (ids) => {
  return fetchUsers(ids);
});

export const resolvers = {
  Order: {
    user: (order) => userLoader.load(order.userId),  // Cache never cleared!
  }
};
```

**Correct pattern (DataLoader scoped to request context):**
```typescript
// CORRECT — DataLoader created per request in context factory
export function createContext(req: Request) {
  return {
    loaders: {
      // New DataLoader per request — cache cleared when request ends
      user: new DataLoader(async (ids) => fetchUsers(ids)),
      product: new DataLoader(async (ids) => fetchProducts(ids)),
    }
  };
}

export const resolvers = {
  Order: {
    user: (order, _, ctx) => ctx.loaders.user.load(order.userId),
  }
};
```

Look for this pattern in the codebase:
```bash
# In the subgraph repository, search for DataLoader instantiation outside of context factory
grep -r "new DataLoader" --include="*.ts" .
# Any DataLoader not inside a `createContext` function is a potential leak
```

### Mitigation

**Option A: Rolling restart to recover memory (immediate — 2 min)**

```bash
kubectl rollout restart deployment/orders-subgraph -n graphql
kubectl rollout status deployment/orders-subgraph -n graphql --timeout=120s
```

This is temporary mitigation only. The leak will resume. Set a reminder to implement the permanent fix within 24 hours.

**Option B: Deploy a fix to scope DataLoader per-request (1–2 hours)**

Work with the subgraph team to move DataLoader instantiation into the per-request context factory. This is the only permanent fix.

```typescript
// In the Apollo Server or Yoga context factory
const context = ({ req }): Context => ({
  loaders: {
    userLoader: new DataLoader<string, User>((ids) => batchGetUsers(ids)),
    productLoader: new DataLoader<string, Product>((ids) => batchGetProducts(ids)),
  },
  user: extractUserFromRequest(req),
});
```

**Option C: Temporarily disable DataLoader caching (5 min, not recommended for production)**

```typescript
// Disable the DataLoader cache as a stop-gap — batching still works
const userLoader = new DataLoader(async (ids) => fetchUsers(ids), {
  cache: false  // No cache — no leak. But also no deduplication benefit.
});
```

This prevents the leak without fixing the root cause, but at the cost of sending duplicate queries for the same key within a single request.

### Root Cause Patterns

| Root Cause | Code Signal | Prevention |
|------------|-------------|-----------|
| DataLoader as module singleton | `new DataLoader(...)` at file/module level, not in context | Lint rule: ban DataLoader instantiation outside context factory |
| Context not per-request in serverless | Lambda handler reusing context between invocations | Always create fresh context in handler function |
| Large batching window holding keys in memory | `maxBatchSize` very large + long `batchScheduleFn` | Cap `maxBatchSize` to < 500; use default batch schedule |
| Test suite using shared DataLoader between test cases | Shared context across tests | Create fresh context per test case |

**Post-mitigation monitoring:**

```promql
# Memory should stabilize after DataLoader fix is deployed
# Healthy: flat line at ~200MB after GC
# Leaking: upward slope
process_resident_memory_bytes{app="orders-subgraph"}

# Verify DataLoader batch size is still healthy (fix did not break batching)
histogram_quantile(0.05,
  sum by (le, loader_name) (
    rate(graphql_dataloader_batch_size_bucket{subgraph="orders"}[5m])
  )
) > 5  # p5 batch size should be > 5 (not 1, which would be N+1)
```

---

## Post-Playbook Checklist

After any playbook execution:

```
[ ] Mitigation applied and confirmed effective (metrics recovering)
[ ] Root cause hypothesis documented in incident channel
[ ] Rollback commands and applied changes logged in incident channel
[ ] On-call handoff notes updated if shift is ending soon
[ ] Subgraph team notified if their service was involved
[ ] SLO burn rate checked — is the error budget still draining?
[ ] Post-mortem required? (budget consumed > 20% during incident)
[ ] Permanent fix scheduled? (add to platform backlog if mitigation is temporary)
```

---

## Related Topics

- [01-incident-classification.md](./01-incident-classification.md) — Severity classification
- [02-on-call-procedures.md](./02-on-call-procedures.md) — Diagnostic sequence and escalation
- [04-post-mortem-process.md](./04-post-mortem-process.md) — Post-mortem template after resolution
- [14-observability/02-distributed-tracing.md](../14-observability/02-distributed-tracing.md) — Trace-based diagnosis

## References

- [Apollo Router Configuration Reference](https://www.apollographql.com/docs/router/configuration/overview/)
- [DataLoader Best Practices](https://github.com/graphql/dataloader#caching-per-request)
- [Apollo Federation Error Handling](https://www.apollographql.com/docs/federation/entities/#handling-entity-resolution-errors)
- [Kubernetes Pod Disruption](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)
- [Circuit Breaker Pattern](https://docs.microsoft.com/en-us/azure/architecture/patterns/circuit-breaker)
