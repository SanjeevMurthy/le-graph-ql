# 05 — Capacity Scaling Runbook

> **Purpose**
> Procedures for scaling the GraphQL platform during planned traffic events (product launches, marketing campaigns) and reactive scaling during unexpected load spikes. Covers pre-event preparation checklists, day-of monitoring, horizontal and vertical scaling procedures for the router and subgraphs, database read replica scaling, and post-event scale-down with cost reporting. Written for platform engineers and SREs managing capacity.

---

## Trigger Conditions

**Planned scaling (execute at T-48h before event):**
- Marketing campaign or product launch with expected > 1.5x normal traffic
- Flash sale, seasonal peak (Black Friday, back-to-school), or live event integration
- Load test scheduled to validate capacity at 2x+ expected peak

**Reactive scaling (execute immediately):**
- PagerDuty alert: `GraphQLRouterHighCPU` (CPU > 80% for 10 minutes)
- HPA has reached `maxReplicas` and traffic is still increasing
- Subgraph error rate increasing due to pod saturation (not code errors)
- Database connection pool wait time > 100ms sustained

---

## Pre-Event Checklist (T-48 Hours)

### Capacity Planning

```
[ ] Confirm expected traffic multiplier with marketing/product team
    Example: "We expect 3x normal peak traffic from 2pm–4pm on launch day"

[ ] Run load test at 2x expected peak (see load testing procedure below)

[ ] Review HPA current configuration:
    kubectl get hpa -n graphql-platform
    Confirm: maxReplicas is at least 2x expected peak replicas

[ ] Review current resource requests and limits:
    kubectl get deployment apollo-router -n graphql-platform \
      -o jsonpath='{.spec.template.spec.containers[0].resources}'

[ ] Verify Redis response cache is populated:
    redis-cli -h $REDIS_HOST info stats | grep keyspace_hits
    Target: hit_rate > 80% for cacheable operations

[ ] Confirm Redis cluster can handle expected cache write rate:
    redis-cli -h $REDIS_HOST info replication
    Target: replication lag < 10ms

[ ] Pre-warm query plan cache by running representative operations:
    for op in $(cat ops/representative-operations.txt); do
      curl -sf -X POST $PROD_URL -H "Content-Type: application/json" \
        -d "{\"query\": \"$op\"}" > /dev/null
    done
    # Run after pre-scaling, before traffic arrives

[ ] Notify subgraph teams to pre-scale their HPAs:
    Template: "Launch event on [date]. Expected 3x traffic from [time] to [time].
    Please increase your HPA minReplicas to [N] before [time-1h]."

[ ] Verify database can handle increased query rate:
    SELECT count(*) FROM pg_stat_activity;
    # Current connections vs max_connections in postgresql.conf
    # Headroom should be > 50%
```

### Pre-Event Load Test

```bash
# Run k6 load test at 2x expected peak
# Assumes k6 is installed: https://k6.io/docs/getting-started/installation/

cat > /tmp/graphql-load-test.js << 'EOF'
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '2m', target: 200 },   // Ramp up to 200 VUs
    { duration: '10m', target: 200 },  // Hold at 200 VUs (simulate peak)
    { duration: '2m', target: 0 },     // Ramp down
  ],
  thresholds: {
    http_req_duration: ['p(99)<1000'],  // p99 < 1000ms
    http_req_failed: ['rate<0.001'],    // Error rate < 0.1%
  },
};

const ROUTER_URL = __ENV.ROUTER_URL || 'https://graphql-staging.internal.example.com/graphql';

export default function () {
  const payload = JSON.stringify({
    operationName: 'GetProductPage',
    query: `query GetProductPage($id: ID!) {
      product(id: $id) { id name price inventory { available } }
    }`,
    variables: { id: `prod-${Math.floor(Math.random() * 1000)}` },
  });

  const res = http.post(ROUTER_URL, payload, {
    headers: { 'Content-Type': 'application/json' },
  });

  check(res, {
    'status is 200': (r) => r.status === 200,
    'no graphql errors': (r) => !JSON.parse(r.body).errors,
    'data is not null': (r) => JSON.parse(r.body).data !== null,
  });

  sleep(0.5);
}
EOF

ROUTER_URL="https://graphql-staging.internal.example.com/graphql" \
  k6 run /tmp/graphql-load-test.js

# Review output:
# - p99 latency should be < 1000ms at peak
# - Error rate should be < 0.1%
# - If either threshold fails: increase staging HPA maxReplicas and retest
```

---

## Pre-Event Checklist (T-1 Hour)

```
[ ] Lower alert thresholds to catch issues earlier during the event:
    # Temporarily lower the burn rate threshold for faster alerting
    # Edit Prometheus rules or use alerting override (document what was changed)

[ ] Set up war room Slack channel: #war-room-{event-name}-{date}
    Message template:
    "War room open for [product launch / campaign]. Traffic window: [time range].
    Dashboard: https://grafana.internal.example.com/d/graphql-platform
    On-call: @{primary} @{secondary}
    Runbook: https://runbooks.internal.example.com/graphql/capacity-scaling"

[ ] Verify on-call rotation is correct and primary/secondary are reachable:
    PagerDuty: check current on-call for graphql-platform service

[ ] Pre-scale router to expected peak minimum replicas:
    kubectl scale deployment apollo-router --replicas={peak-min} -n graphql-platform
    (Do not rely on HPA to scale up quickly enough — pre-scale proactively)

[ ] Pre-scale critical subgraphs:
    for subgraph in products orders inventory identity; do
      kubectl scale deployment $subgraph --replicas={peak-min} -n graphql-platform
    done

[ ] Open Grafana dashboard with 1-minute refresh:
    URL: https://grafana.internal.example.com/d/graphql-platform?refresh=1m

[ ] Confirm PagerDuty notifications will reach on-call via phone (not just app):
    Test alert: pagerduty test notification for graphql-platform service

[ ] Brief the subgraph team leads via #war-room channel:
    "We're expecting 3x traffic starting at 2pm. Please be available."
```

---

## Day-Of Monitoring

### Grafana Dashboard Setup

Open the GraphQL Platform dashboard with these panels visible:

1. **Traffic vs Capacity Headroom** — requests per second vs HPA utilization percentage
2. **p99 Latency by Operation** — identify first signs of degradation
3. **Error Rate** — complete error rate, must stay < 0.1%
4. **Router CPU** — should stay below 70% (30% headroom)
5. **HPA Replicas** — current vs max for router and all subgraphs
6. **Database Connection Pool** — waiting connections gauge

```promql
# Traffic vs capacity headroom gauge
# Current RPS as percentage of estimated capacity
(
  sum(rate(apollo_router_graphql_requests_total[1m]))
  /
  (kube_deployment_status_replicas_available{deployment="apollo-router"} * 500)
) * 100
# Assumes 500 RPS per router pod at normal latency — adjust to your benchmarks
# Alert manually if this gauge exceeds 80%
```

### Continuous Monitoring During Event

Every 5 minutes during the traffic event, check:

```bash
# Quick health check — run in a loop during the event
while true; do
  echo "=== $(date -u) ==="

  # Current RPS
  echo -n "RPS: "
  curl -s "https://prometheus.internal.example.com/api/v1/query" \
    --data-urlencode 'query=sum(rate(apollo_router_graphql_requests_total[1m]))' \
    | jq -r '.data.result[0].value[1]'

  # p99 latency in ms
  echo -n "p99 (ms): "
  curl -s "https://prometheus.internal.example.com/api/v1/query" \
    --data-urlencode 'query=histogram_quantile(0.99, sum by (le) (rate(apollo_router_graphql_request_duration_seconds_bucket[1m]))) * 1000' \
    | jq -r '.data.result[0].value[1]'

  # Error rate
  echo -n "Error rate: "
  curl -s "https://prometheus.internal.example.com/api/v1/query" \
    --data-urlencode 'query=sum(rate(apollo_router_graphql_error_total{error_type="complete"}[1m])) / sum(rate(apollo_router_graphql_requests_total[1m]))' \
    | jq -r '.data.result[0].value[1]'

  # Router replicas
  echo -n "Router pods: "
  kubectl get deployment apollo-router -n $NAMESPACE \
    -o jsonpath='{.status.availableReplicas}/{.spec.replicas}'
  echo

  sleep 60
done
```

---

## Scaling Procedures

### Horizontal Scaling — Increase Router Replicas

```bash
# Method 1: Direct kubectl scale (immediate, for emergency)
kubectl scale deployment apollo-router \
  --replicas=20 \
  -n $NAMESPACE

# Method 2: Helm values update (preferred — tracked in Git)
helm upgrade apollo-router $ROUTER_CHART \
  --namespace $NAMESPACE \
  --reuse-values \
  --set autoscaling.minReplicas=10 \
  --set autoscaling.maxReplicas=30

# Method 3: Patch HPA directly (for temporary override during event)
kubectl patch hpa apollo-router -n $NAMESPACE \
  --patch '{"spec": {"minReplicas": 15, "maxReplicas": 40}}'

# Verify scaling in progress
kubectl get hpa apollo-router -n $NAMESPACE
kubectl rollout status deployment/apollo-router -n $NAMESPACE
```

### Horizontal Scaling — Increase Subgraph Replicas

```bash
# Scale all critical subgraphs at once
declare -A PEAK_REPLICAS=(
  ["products"]=20
  ["orders"]=15
  ["inventory"]=10
  ["identity"]=8
  ["recommendations"]=8
)

for subgraph in "${!PEAK_REPLICAS[@]}"; do
  replicas=${PEAK_REPLICAS[$subgraph]}
  echo "Scaling $subgraph to $replicas replicas"
  kubectl patch hpa $subgraph -n $NAMESPACE \
    --patch "{\"spec\": {\"minReplicas\": $replicas}}"
done

# Verify all subgraphs are scaling
kubectl get hpa -n $NAMESPACE --sort-by='.metadata.name'
```

### Vertical Scaling — Increase Pod CPU/Memory Limits

For cases where horizontal scaling is not possible (e.g., database connection limits restrict pod count):

```bash
# Increase router CPU limit for query planning-intensive workloads
kubectl patch deployment apollo-router -n $NAMESPACE \
  --patch '{
    "spec": {
      "template": {
        "spec": {
          "containers": [{
            "name": "router",
            "resources": {
              "requests": {"cpu": "2000m", "memory": "2Gi"},
              "limits":   {"cpu": "4000m", "memory": "4Gi"}
            }
          }]
        }
      }
    }
  }'

# Note: This triggers a rolling restart — verify rollout completes
kubectl rollout status deployment/apollo-router -n $NAMESPACE

# IMPORTANT: Vertical scaling via kubectl patch is not tracked in Git.
# Follow up with a Helm values update and PR to make this persistent.
```

### Database — Enable Additional Read Replicas

For sustained high read traffic to subgraph databases:

```bash
# PostgreSQL on RDS — add read replica via AWS CLI
aws rds create-db-instance-read-replica \
  --db-instance-identifier products-db-replica-2 \
  --source-db-instance-identifier products-db-primary \
  --db-instance-class db.r6g.xlarge \
  --availability-zone us-east-1b \
  --region us-east-1

# Wait for replica to become available (typically 5–15 minutes)
aws rds wait db-instance-available \
  --db-instance-identifier products-db-replica-2

# Update the subgraph's DATABASE_READ_URL environment variable to include the new replica
# (round-robin or use PgBouncer to load-balance across replicas)
kubectl set env deployment/products \
  -n $NAMESPACE \
  DATABASE_READ_URL="postgresql://products-db-replica-2.cluster.us-east-1.rds.amazonaws.com:5432/products"

# For Terraform-managed databases, apply infrastructure changes instead:
# terraform apply -target=aws_db_instance.products_replica_2
```

---

## Post-Event Scale-Down

Wait 24 hours after the traffic event ends before scaling down. Traffic tails off gradually and a premature scale-down can cause a second incident.

### Step 1: Verify Traffic Has Returned to Baseline (T+24h)

```promql
# Confirm RPS is back to normal baseline
sum(rate(apollo_router_graphql_requests_total[30m]))
# If this is within 20% of your normal daily average: safe to scale down
```

### Step 2: Scale Down Router and Subgraphs

```bash
# Restore original HPA minimums
helm upgrade apollo-router $ROUTER_CHART \
  --namespace $NAMESPACE \
  --reuse-values \
  --set autoscaling.minReplicas=5 \      # Restore original minimum
  --set autoscaling.maxReplicas=20       # Restore original maximum

# Restore subgraph minimums
declare -A NORMAL_REPLICAS=(
  ["products"]=5
  ["orders"]=4
  ["inventory"]=3
  ["identity"]=3
  ["recommendations"]=3
)

for subgraph in "${!NORMAL_REPLICAS[@]}"; do
  replicas=${NORMAL_REPLICAS[$subgraph]}
  kubectl patch hpa $subgraph -n $NAMESPACE \
    --patch "{\"spec\": {\"minReplicas\": $replicas}}"
done

# Verify scale-down is happening (may take a few minutes for HPA to reduce)
kubectl get hpa -n $NAMESPACE
kubectl get pods -n $NAMESPACE | grep -c Running
```

### Step 3: Remove Temporary Database Replicas

```bash
# Delete the temporary read replica created for the event
aws rds delete-db-instance \
  --db-instance-identifier products-db-replica-2 \
  --skip-final-snapshot

# Update DATABASE_READ_URL back to the permanent replicas
kubectl set env deployment/products \
  -n $NAMESPACE \
  DATABASE_READ_URL="postgresql://products-db-replica-1.cluster.us-east-1.rds.amazonaws.com:5432/products"
```

### Step 4: Restore Normal Alert Thresholds

```bash
# If alert thresholds were temporarily lowered in the pre-event checklist,
# restore them now. Edit the Prometheus alert rules and apply:

kubectl apply -f rules/graphql-slo-alerts.yaml -n monitoring

# Verify the rules are loaded
curl -s https://prometheus.internal.example.com/api/v1/rules \
  | jq '.data.groups[].rules[] | select(.name | test("GraphQL")) | .name'
```

### Step 5: Post-Event Cost Report

After scale-down, generate a cost report for the event:

```bash
# Kubecost: get cost for the graphql-platform namespace during the event window
# Replace with your kubecost endpoint and date range
curl -s "https://kubecost.internal.example.com/model/allocation" \
  --data-urlencode "window=2026-05-16T14:00:00Z,2026-05-16T18:00:00Z" \
  --data-urlencode "aggregate=namespace" \
  --data-urlencode "namespace=graphql-platform" \
  | jq '.data[] | {namespace: .name, totalCost: .totalCost}'

# RDS read replica cost (example: db.r6g.xlarge at ~$0.48/hour in us-east-1)
# Replica lived for: 4 hours event + 24 hours wait-for-scale-down = 28 hours
# Cost: 28h × $0.48/h = $13.44

# Post the cost report to #graphql-platform-ops:
# "Event: Product Launch 2026-05-16
#  Duration: 4h traffic event, 24h scale-down tail
#  Infrastructure cost delta vs normal day: $XXX
#  Most expensive component: [router / products subgraph / RDS replica]
#  Efficiency: operations processed at peak RPS at cost of $X per million operations"
```

---

## Verification Checklist — Post Scale-Down

```
[ ] RPS has returned to normal baseline (within 20%)
[ ] HPA minReplicas restored to normal values for all deployments
[ ] Temporary database replicas deleted
[ ] DATABASE_READ_URL environment variables restored to permanent replicas
[ ] Alert thresholds restored to normal values
[ ] Prometheus rules applied and verified
[ ] Cost report generated and posted to #graphql-platform-ops
[ ] War room Slack channel archived
[ ] Post-event retrospective scheduled (within 5 business days)
```

---

## References and Related Topics

- [04-performance-degradation-runbook.md](./04-performance-degradation-runbook.md) — If latency degrades during the event
- [06-performance-and-scaling/README.md](../06-performance-and-scaling/README.md) — Horizontal and vertical scaling architecture
- [34-cost-optimization/05-cost-allocation-and-showback.md](../34-cost-optimization/05-cost-allocation-and-showback.md) — Cost reporting methodology
- [14-observability/05-slos-and-alerting.md](../14-observability/05-slos-and-alerting.md) — Alert thresholds and burn rate definitions
- [Kubernetes HPA Documentation](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/) — HPA configuration reference
- [k6 Load Testing](https://k6.io/docs/) — Load test scripting reference
- [AWS RDS Read Replicas](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ReadRepl.html) — Creating and deleting read replicas
