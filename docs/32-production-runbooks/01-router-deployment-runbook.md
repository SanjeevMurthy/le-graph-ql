# 01 — Apollo Router Deployment Runbook

> **Purpose**
> Step-by-step procedure for deploying a new Apollo Router version to the production GraphQL platform. Covers pre-deployment validation, staged rollout via Helm canary, 15-minute monitoring window, health verification, and rollback. Execute this runbook for every router version upgrade. Written for platform engineers and SREs responsible for the federated GraphQL gateway.

---

## Trigger Conditions

Execute this runbook when:

- Apollo Router releases a new version and the platform team decides to upgrade (planned upgrade)
- A security advisory requires an emergency router patch
- A router configuration change requires a restart (router.yaml modification)

**Not** for schema-only changes — see `02-subgraph-deployment-runbook.md`.

---

## Pre-Requisites

```
[ ] Common environment variables set (see 32-production-runbooks/README.md)
[ ] Apollo Router changelog reviewed for the target version
[ ] router.yaml validated against the target version's configuration schema
[ ] Staging environment available and healthy
[ ] Maintenance window confirmed if this is a high-risk upgrade (major version)
[ ] On-call engineer informed of planned deployment window
[ ] Grafana dashboard open at: https://grafana.internal.example.com/d/graphql-platform
```

---

## Phase 0: Pre-Deployment — Review and Validation

### Step 1: Review the Router Changelog

Before touching any environment, read the Apollo Router changelog for the target version:

```bash
# Check current production version
kubectl get deployment apollo-router -n $NAMESPACE \
  -o jsonpath='{.spec.template.spec.containers[0].image}' && echo

# Expected output: ghcr.io/apollographql/router:v1.x.y
# Note the current version for rollback reference

# Open the changelog for the target version
# https://github.com/apollographql/router/releases/tag/vX.Y.Z
```

Specifically check for:
- **Breaking configuration changes** — keys renamed or removed in `router.yaml`
- **CHANGELOG entries tagged "breaking"** — any behavior change that affects routing or response format
- **Minimum supergraph SDL version requirements** — some router releases require recomposition
- **Plugin API changes** — if custom Rhai scripts or coprocessors are in use

### Step 2: Validate router.yaml Against the New Version

```bash
# Clone or pull the router chart at the target version
export TARGET_ROUTER_VERSION="1.52.0"  # Update to target version

# Validate current router.yaml against the new version's schema
# Apollo Router provides a config validation command
docker run --rm \
  -v $(pwd)/router.yaml:/router.yaml \
  ghcr.io/apollographql/router:v${TARGET_ROUTER_VERSION} \
  --config /router.yaml \
  --validate-config

# Expected: "Configuration is valid" with no warnings or errors
# If warnings appear: review each one. Deprecated keys must be updated before production.
```

### Step 3: Check for Deprecated Configuration Keys

```bash
# List all configuration keys in current router.yaml that are deprecated in the target version
# (Refer to the router migration guide in the changelog)

# Common deprecated keys to check (examples from router v1.x):
grep -n "experimental_" router.yaml        # experimental_ keys often graduate or are removed
grep -n "subscription.mode" router.yaml    # restructured in v1.40+
grep -n "traffic_shaping.router" router.yaml  # renamed in some versions

# Update any deprecated keys before proceeding
```

### Step 4: Validate Supergraph Composition Still Passes

```bash
# Ensure the current supergraph schema is compatible with the target router version
rover supergraph compose \
  --config supergraph.yaml \
  --output /tmp/supergraph-composed.graphql

echo "Exit code: $?"
# Expected: exit code 0 — composition successful

# Validate the composed schema is valid
wc -l /tmp/supergraph-composed.graphql
# Should be non-zero — composition produced output
```

---

## Phase 1: Staging Deployment

### Step 5: Update Helm Chart Values in Staging

```bash
# Locate the Helm values file for staging
cat helm/staging/values.yaml | grep -A 3 "router:"

# Update the router image tag
# Edit helm/staging/values.yaml:
# router:
#   image:
#     tag: "v1.52.0"   ← update this value

# In practice, use your GitOps tool (ArgoCD / Flux) to update the tag.
# If applying manually:
helm upgrade $ROUTER_RELEASE $ROUTER_CHART \
  --namespace $STAGING_NAMESPACE \
  --version $TARGET_ROUTER_VERSION \
  --reuse-values \
  --set router.image.tag="v${TARGET_ROUTER_VERSION}" \
  --wait \
  --timeout 5m

# Watch the rollout
kubectl rollout status deployment/apollo-router -n $STAGING_NAMESPACE --timeout=5m
```

### Step 6: Smoke Test in Staging

```bash
STAGING_ROUTER_URL="https://graphql-staging.internal.example.com/graphql"

# Health check
curl -sf "$STAGING_ROUTER_URL/../health" | jq .
# Expected: {"status": "pass"}

# Basic introspection (confirms schema is loaded)
curl -sf -X POST "$STAGING_ROUTER_URL" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ __typename }"}' | jq .
# Expected: {"data": {"__typename": "Query"}}

# Run a representative operation (substitute your actual operation)
curl -sf -X POST "$STAGING_ROUTER_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "operationName": "GetProductPage",
    "query": "query GetProductPage($id: ID!) { product(id: $id) { id name price } }",
    "variables": {"id": "prod-123"}
  }' | jq .
# Expected: data.product is non-null, no errors[] array

echo "Staging smoke test: PASSED"
```

### Step 7: Verify Metrics Flowing in Staging

```bash
# Wait 2 minutes for metrics to populate, then verify
# Check Prometheus for staging router metrics

curl -s "https://prometheus.internal.example.com/api/v1/query" \
  --data-urlencode 'query=up{job="apollo-router-staging"}' | jq '.data.result[0].value[1]'
# Expected: "1"

# Confirm request metrics are flowing (should see traffic from smoke test)
curl -s "https://prometheus.internal.example.com/api/v1/query" \
  --data-urlencode 'query=sum(rate(apollo_router_graphql_requests_total{namespace="graphql-platform-staging"}[5m]))' \
  | jq '.data.result[0].value[1]'
# Expected: a non-zero value
```

---

## Phase 2: Production Canary (10%)

### Step 8: Update Production Helm Values — Canary Revision

The canary strategy uses Kubernetes Deployment with two separate Deployments managed by the HPA — one at the previous version (`apollo-router-stable`) and one at the new version (`apollo-router-canary`). Alternatively, use a single Deployment with a phased rollout via `maxSurge`.

```bash
# Strategy: use Helm with maxSurge to roll 10% of pods first
# Then pause and verify before completing the rollout

helm upgrade $ROUTER_RELEASE $ROUTER_CHART \
  --namespace $NAMESPACE \
  --version $TARGET_ROUTER_VERSION \
  --reuse-values \
  --set router.image.tag="v${TARGET_ROUTER_VERSION}" \
  --set router.deployment.strategy.type=RollingUpdate \
  --set router.deployment.strategy.rollingUpdate.maxSurge=1 \
  --set router.deployment.strategy.rollingUpdate.maxUnavailable=0 \
  --wait=false    # Do NOT wait — we want to pause after the first pod

# Watch pods: wait until exactly 1 new pod is Running and Ready
kubectl get pods -n $NAMESPACE -l app=apollo-router -w

# Once 1 new pod is Running at the new version, pause the rollout
kubectl rollout pause deployment/apollo-router -n $NAMESPACE

# Verify the canary pod is running the new version
kubectl get pods -n $NAMESPACE -l app=apollo-router \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```

### Step 9: Monitor the Canary Pod — 15-Minute Window

Open Grafana at `https://grafana.internal.example.com/d/graphql-platform` and set the time range to `last 30 minutes`. Monitor the following panels for 15 minutes:

**Error rate — must stay below 0.1%:**
```promql
# Total error rate (all pods, canary included)
sum(rate(apollo_router_graphql_error_total{error_type="complete", namespace="graphql-platform"}[5m]))
/
sum(rate(apollo_router_graphql_requests_total{namespace="graphql-platform"}[5m]))
```

**p99 latency — must stay within 20% of baseline:**
```promql
# p99 across all router pods
histogram_quantile(0.99,
  sum by (le) (
    rate(apollo_router_graphql_request_duration_seconds_bucket{namespace="graphql-platform"}[5m])
  )
)
```

**Router memory usage — watch for memory leak:**
```promql
# Memory per router pod
process_resident_memory_bytes{app="apollo-router", namespace="graphql-platform"}
```

**Query plan cache hit rate — should recover to >90% within 5 minutes:**
```promql
job:apollo_router_plan_cache_hit_ratio:5m
```

**Subgraph error rates — verify no subgraph is newly failing:**
```promql
sum by (subgraph_name) (
  rate(apollo_router_subgraph_request_error_total{namespace="graphql-platform"}[5m])
)
/
sum by (subgraph_name) (
  rate(apollo_router_subgraph_requests_total{namespace="graphql-platform"}[5m])
)
```

### Step 10: Decision — Go or No-Go After 15 Minutes

**Go criteria (ALL must be true):**
```
[ ] Error rate < 0.1% (same as baseline)
[ ] p99 latency within 20% of baseline before deployment
[ ] Router memory stable (not growing continuously over 15 minutes)
[ ] Plan cache hit rate > 90% (after initial warm-up of 5 minutes)
[ ] No new subgraph error rate increase
[ ] No new alerts firing in Prometheus/PagerDuty
```

**No-go criteria (ANY triggers rollback):**
```
[ ] Error rate > 0.1% and rising
[ ] p99 latency > 1.2x pre-deployment baseline
[ ] Router memory growing without bound (possible memory leak in new version)
[ ] Plan cache hit rate < 50% after 10 minutes (cache issue in new version)
[ ] New subgraph errors that did not exist before
```

If **no-go**: jump to Phase 4 (Rollback). If **go**: proceed to Step 11.

---

## Phase 3: Full Promotion

### Step 11: Resume Rollout to 100%

```bash
# Resume the paused rollout — this will roll the remaining pods
kubectl rollout resume deployment/apollo-router -n $NAMESPACE

# Watch the rollout to completion
kubectl rollout status deployment/apollo-router -n $NAMESPACE --timeout=10m

# Verify all pods are at the new version
kubectl get pods -n $NAMESPACE -l app=apollo-router \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# All pods should show: ghcr.io/apollographql/router:v${TARGET_ROUTER_VERSION}
```

### Step 12: Final Health Verification

```bash
PROD_ROUTER_URL="https://graphql.internal.example.com/graphql"

# Health endpoint
curl -sf "${PROD_ROUTER_URL}/../health" | jq .
# Expected: {"status": "pass"}

# Introspection check
curl -sf -X POST "$PROD_ROUTER_URL" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ __typename }"}' | jq .
# Expected: {"data": {"__typename": "Query"}}

# Prometheus up check
curl -s "https://prometheus.internal.example.com/api/v1/query" \
  --data-urlencode 'query=up{job="apollo-router"}' \
  | jq '.data.result[].value[1]'
# Expected: "1" for every router pod

# Confirm router version in pod annotations
kubectl get deployment apollo-router -n $NAMESPACE \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Expected: ghcr.io/apollographql/router:v${TARGET_ROUTER_VERSION}
```

### Step 13: Verify Grafana Dashboard Shows No Anomalies

After the full rollout, monitor for an additional 15 minutes:

```promql
# Error rate should be at pre-deployment baseline
sum(rate(apollo_router_graphql_error_total{error_type="complete"}[5m]))
/
sum(rate(apollo_router_graphql_requests_total[5m]))

# p99 latency — confirm no regression
histogram_quantile(0.99,
  sum by (le) (
    rate(apollo_router_graphql_request_duration_seconds_bucket[5m])
  )
)

# Router CPU — query planning cost for new version
rate(process_cpu_seconds_total{app="apollo-router"}[5m])
```

---

## Phase 4: Rollback

Execute this phase if the no-go criteria in Step 10 are met, or if any anomaly appears after full promotion.

### Step 14: Immediate Rollback via Helm

```bash
# Find the previous Helm revision number
helm history $ROUTER_RELEASE -n $NAMESPACE

# Output example:
# REVISION  STATUS      CHART          APP VERSION    DESCRIPTION
# 47        superseded  router-1.51.0  1.51.0         Upgrade complete
# 48        deployed    router-1.52.0  1.52.0         Upgrade complete

# Roll back to the previous revision (47 in this example)
helm rollback $ROUTER_RELEASE 47 -n $NAMESPACE --wait --timeout 5m

# Watch rollback
kubectl rollout status deployment/apollo-router -n $NAMESPACE --timeout=5m

# Verify pod images are back to previous version
kubectl get pods -n $NAMESPACE -l app=apollo-router \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# Expected: all pods at the previous version
```

### Step 15: Verify Recovery After Rollback

```bash
# Check error rate has returned to baseline
curl -s "https://prometheus.internal.example.com/api/v1/query" \
  --data-urlencode 'query=sum(rate(apollo_router_graphql_error_total{error_type="complete"}[5m])) / sum(rate(apollo_router_graphql_requests_total[5m]))' \
  | jq '.data.result[0].value[1]'
# Expected: same as pre-upgrade baseline (< 0.001)

# Confirm pod count is back to expected replica count
kubectl get deployment apollo-router -n $NAMESPACE
# READY column should show: {N}/{N} (e.g., 5/5)

# Post rollback to #graphql-incidents Slack channel:
# "Router rollback complete. Version reverted from v1.52.0 to v1.51.0.
#  Error rate: [before] → [after]. Reason: [reason]. At: [timestamp]."
```

---

## Phase 5: Post-Deployment

### Step 16: Update CLAUDE.md and Platform Documentation

After a successful deployment:

```bash
# Update the router version recorded in CLAUDE.md
# Edit the "Current Router Version" section:
# Apollo Router: v1.52.0 (deployed 2026-05-16)

# If any router.yaml keys were changed, note them:
# router.yaml changes in v1.52.0:
#   - Renamed: traffic_shaping.router.timeout → traffic_shaping.global.timeout
#   - Removed: experimental_chaos (graduated to chaos)
```

### Step 17: Record the Deployment

Post to #graphql-platform-deploys:

```
Deployment: Apollo Router v1.52.0
Deployed by: @{your-name}
Time: 2026-05-16 14:30 UTC
Method: Canary (10%) → Full rollout
Canary window: 15 minutes — no anomalies
Status: SUCCESS

Pre/Post metrics:
  Error rate:  0.04% → 0.04%  (no change)
  p99 latency: 312ms → 318ms  (+2% — within threshold)
  CPU:         35%   → 37%    (slightly higher query planning — expected)

Config changes: none (drop-in version upgrade)
```

---

## Verification Checklist — Final State

```
[ ] All router pods running at target version (kubectl get pods)
[ ] /health endpoint returns {"status": "pass"}
[ ] Error rate at or below pre-deployment baseline for 30 minutes
[ ] p99 latency within 20% of pre-deployment baseline
[ ] Plan cache hit rate > 90%
[ ] No new PagerDuty alerts in the last 30 minutes
[ ] CLAUDE.md updated with new router version
[ ] Deployment posted to #graphql-platform-deploys
[ ] Helm history shows successful deployment as current revision
```

---

## References and Related Topics

- [Apollo Router Releases](https://github.com/apollographql/router/releases) — Changelog and migration guides
- [Apollo Router Configuration Reference](https://www.apollographql.com/docs/router/configuration/overview/) — router.yaml schema
- [02-subgraph-deployment-runbook.md](./02-subgraph-deployment-runbook.md) — Subgraph deployment with schema changes
- [04-performance-degradation-runbook.md](./04-performance-degradation-runbook.md) — Diagnosing latency regressions introduced by a deployment
- [14-observability/05-slos-and-alerting.md](../14-observability/05-slos-and-alerting.md) — SLO and alert definitions used in this runbook
- [33-incident-management/README.md](../33-incident-management/README.md) — Escalation procedures if rollback fails
