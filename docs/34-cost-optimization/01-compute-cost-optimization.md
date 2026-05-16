# 01 — Compute Cost Optimization for GraphQL

> **Purpose**
> Compute cost analysis and optimization for the Apollo Router and subgraph pods in a Kubernetes-hosted federated GraphQL platform. Covers query planning CPU cost, right-sizing with VPA, spot/preemptible instances for stateless subgraphs, scale-to-zero for non-production, cost allocation by team, and node pool selection by workload type. Written for platform engineers and infrastructure architects who own the GraphQL platform budget.

---

## Cost Drivers

### Driver 1: Router CPU — Query Planning

The Apollo Router replans every unique operation shape that is not in the query plan cache. Query planning for a federated operation involves:

1. Parsing the operation document into an AST
2. Validating against the supergraph schema
3. Building a query plan (which subgraphs to call, in which order, with which field sets)
4. Caching the plan by a hash of the operation string

At steady state with a warm cache (> 90% hit rate), query planning adds < 1ms per request. At cache miss rates > 10%, query planning becomes the dominant CPU consumer.

**Cost calculation example:**

```
Scenario: 1,000 RPS with 10% cache miss rate (poor plan reuse)
  Cache misses per second: 100
  Average planning time per miss: 15ms on a single CPU core
  CPU cores consumed by planning: 100 × 0.015s = 1.5 CPU cores
  At 3 router pods (0.5 cores each): 100% CPU on all planning-related work

Scenario: 1,000 RPS with 95% cache hit rate (typical with named operations)
  Cache misses per second: 50
  Average planning time per miss: 15ms
  CPU cores consumed by planning: 50 × 0.015s = 0.75 CPU cores
  At 3 router pods: 25% CPU on planning — 3x more efficient
```

**Optimization:** Enforce named operations in all clients. Unnamed operations (ad-hoc queries from development tools hitting production) cannot be reused across requests and thrash the plan cache.

```promql
# Monitor plan cache hit rate — target: > 95%
job:apollo_router_plan_cache_hit_ratio:5m

# Find operations contributing to cache misses (anonymous operations)
topk(10,
  sum by (operation_name) (
    rate(apollo_router_graphql_requests_total{operation_name=""}[5m])
  )
)
# Empty operation_name = unnamed operation = cannot be cached
```

### Driver 2: Subgraph Pod Count

At 10 subgraphs × 5 pods each = 50 subgraph pods. At a typical `c5.xlarge` (4 vCPU, 8 GB RAM) at $0.192/hour on-demand:

```
On-demand cost: 50 pods × 0.25 vCPU request × ($0.192/hour / 4 vCPU) = $0.60/hour
Monthly (720 hours): $432/month

At 60% spot discount:
Spot cost: $432 × 0.40 = $172.80/month
Monthly saving: $259.20
```

### Driver 3: DataLoader Memory Per Request

DataLoaders maintain in-memory cache of resolved entities for the lifetime of one request. Memory cost is proportional to request concurrency (not RPS):

```
Scenario: 1,000 concurrent GraphQL requests
  Each request resolves 100 Product entities via DataLoader
  Each Product object in memory: ~2KB (fields + overhead)
  Memory per request: 100 × 2KB = 200KB
  Total DataLoader memory at 1,000 concurrent: 1,000 × 200KB = 200MB

  At $0.006/GB-hour for EKS memory (general approximation):
  200MB × $0.006/GB-hour = $0.0012/hour = ~$0.86/month
  
  This is small — but a DataLoader memory leak (entities not cleared per request)
  can grow unbounded and cause OOM pod restarts, which increases incident cost
  and forced horizontal scaling cost.
```

---

## Right-Sizing with VPA

The Vertical Pod Autoscaler (VPA) analyzes actual resource usage and recommends CPU and memory requests. Without VPA, most Kubernetes resources are overprovisioned because engineers set conservative limits.

```yaml
# vpa.yaml — VPA for the products subgraph
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: products-subgraph-vpa
  namespace: graphql-platform
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: products
  updatePolicy:
    updateMode: "Off"        # Recommendation mode only — do not auto-apply in production
  resourcePolicy:
    containerPolicies:
      - containerName: products
        minAllowed:
          cpu: 100m
          memory: 128Mi
        maxAllowed:
          cpu: 2000m
          memory: 2Gi
```

```bash
# Get VPA recommendations after running in Off mode for 24 hours
kubectl get vpa products-subgraph-vpa -n graphql-platform -o json \
  | jq '.status.recommendation.containerRecommendations[] | {
    container: .containerName,
    lowerBound: .lowerBound,
    target: .target,
    upperBound: .upperBound
  }'

# Example output:
# {
#   "container": "products",
#   "lowerBound": {"cpu": "85m", "memory": "210Mi"},
#   "target":     {"cpu": "180m", "memory": "350Mi"},   ← apply this as requests
#   "upperBound": {"cpu": "620m", "memory": "980Mi"}
# }

# If current requests are cpu: 500m, memory: 1Gi
# VPA target is cpu: 180m, memory: 350Mi
# Savings: 64% CPU reduction, 65% memory reduction per pod
# Monthly saving for 5 pods on c5.xlarge: significant
```

**Profile query planning CPU cost by operation complexity:**

```promql
# Histogram of query planning time by operation complexity score
histogram_quantile(0.99,
  sum by (le, operation_name) (
    rate(apollo_router_query_planning_time_seconds_bucket[5m])
  )
)
# Operations with high planning time at p99 are candidates for:
#   - Persisted queries (plan cached by ID, not by operation string hash)
#   - Query complexity limits (prevent unbounded operations from consuming planning CPU)
```

---

## Spot/Preemptible Instances for Subgraphs

GraphQL subgraphs are stateless — they hold no session state and all in-flight requests are independent. This makes them ideal candidates for spot instances, which offer 60–70% discount over on-demand.

### PodDisruptionBudget for Safe Spot Draining

Before moving subgraphs to spot, configure a PodDisruptionBudget to ensure at least one pod remains available during spot node preemption:

```yaml
# pdb.yaml — PodDisruptionBudget for the products subgraph
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: products-pdb
  namespace: graphql-platform
spec:
  minAvailable: 2      # Keep at least 2 pods available during eviction
  selector:
    matchLabels:
      app: products
```

### Node Pool Configuration for Spot

```yaml
# EKS managed node group — spot instances for subgraphs
# terraform/eks-subgraph-spot.tf (Terraform example)
resource "aws_eks_node_group" "subgraph_spot" {
  cluster_name    = var.cluster_name
  node_group_name = "subgraph-spot"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  capacity_type = "SPOT"

  # Multiple instance types = better spot availability
  instance_types = ["c5.xlarge", "c5a.xlarge", "c5d.xlarge", "c4.xlarge"]

  scaling_config {
    desired_size = 10
    min_size     = 5
    max_size     = 30
  }

  labels = {
    "workload-type" = "graphql-subgraph"
    "spot"          = "true"
  }

  taint {
    key    = "spot"
    value  = "true"
    effect = "NO_SCHEDULE"
  }
}
```

```yaml
# Tolerate the spot taint in subgraph deployments
# helm/subgraphs/products/values.yaml
tolerations:
  - key: "spot"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"

nodeSelector:
  workload-type: "graphql-subgraph"

# Prefer spot nodes but fall back to on-demand if spot is unavailable
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 80
        preference:
          matchExpressions:
            - key: "spot"
              operator: "In"
              values: ["true"]
```

**Cost savings calculation:**

```
On-demand c5.xlarge: $0.192/hour
Spot c5.xlarge:      $0.072/hour (typical ~62% discount)

10 spot subgraph nodes × 720 hours × $0.072 = $518/month
10 on-demand nodes   × 720 hours × $0.192 = $1,382/month
Monthly saving: $864/month
Annual saving:  $10,368/year

Note: Apollo Router should remain on on-demand (see Node Pool Optimization below).
```

---

## Scale-to-Zero for Non-Production with KEDA

Non-production environments (development, QA) should run only during business hours. KEDA ScaledObjects with cron triggers shut them down overnight and on weekends.

```yaml
# keda-cron-scaler.yaml — scale non-prod GraphQL platform to zero overnight
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: graphql-platform-business-hours
  namespace: graphql-platform-dev
spec:
  scaleTargetRef:
    name: apollo-router
  minReplicaCount: 0         # Allow true scale-to-zero
  maxReplicaCount: 3
  triggers:
    - type: cron
      metadata:
        timezone: "America/New_York"
        start: "30 8 * * 1-5"    # 8:30 AM Mon-Fri — scale up
        end: "0 20 * * 1-5"      # 8:00 PM Mon-Fri — scale down
        desiredReplicas: "3"     # Scale to 3 during business hours
```

```yaml
# Apply the same pattern to all non-prod subgraphs
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: products-subgraph-business-hours
  namespace: graphql-platform-dev
spec:
  scaleTargetRef:
    name: products
  minReplicaCount: 0
  maxReplicaCount: 2
  triggers:
    - type: cron
      metadata:
        timezone: "America/New_York"
        start: "30 8 * * 1-5"
        end: "0 20 * * 1-5"
        desiredReplicas: "2"
```

**Cost saving for dev environment:**

```
Assuming 10 non-prod nodes at $0.192/hour on-demand:
Business hours per month: 8 business days/month × 11.5h = 92 hours (approximate)
  (actually ~21 working days × 11.5h = 241.5 hours)
Off-hours per month: 720 - 241.5 = 478.5 hours

Without scale-to-zero: 10 nodes × 720h × $0.192 = $1,382/month
With scale-to-zero:    10 nodes × 241.5h × $0.192 = $464/month
Monthly saving: $918/month (66% reduction)
```

---

## Cost Allocation by Team — Kubecost Chargeback

Namespace-level resource quotas enable per-team cost attribution. Each subgraph team's namespace has a resource quota that maps to a monthly compute budget.

```yaml
# namespace-quota.yaml — resource quota per subgraph team namespace
apiVersion: v1
kind: ResourceQuota
metadata:
  name: products-team-quota
  namespace: graphql-products
spec:
  hard:
    requests.cpu: "10"        # 10 CPU cores maximum across all pods
    requests.memory: "20Gi"   # 20 GB RAM maximum
    limits.cpu: "20"
    limits.memory: "40Gi"
    pods: "50"                # Maximum 50 pods in namespace
```

```bash
# Kubecost query: cost per namespace per month
curl -s "https://kubecost.internal.example.com/model/allocation" \
  --data-urlencode "window=30d" \
  --data-urlencode "aggregate=namespace" \
  | jq '.data[] | select(.name | startswith("graphql")) | {
    team: .name,
    cpuCost: (.cpuCost | tostring | .[0:6]),
    memoryCost: (.ramCost | tostring | .[0:6]),
    totalCost: (.totalCost | tostring | .[0:7])
  }'

# Example output:
# {"team": "graphql-products",    "cpuCost": "123.4", "memoryCost": "45.2", "totalCost": "168.6"}
# {"team": "graphql-orders",      "cpuCost": "89.1",  "memoryCost": "31.8", "totalCost": "120.9"}
# {"team": "graphql-inventory",   "cpuCost": "67.3",  "memoryCost": "28.9", "totalCost": "96.2"}
# {"team": "graphql-platform",    "cpuCost": "245.6", "memoryCost": "87.4", "totalCost": "333.0"}
```

---

## Reserved Instances for Baseline Router Capacity

The Apollo Router must run on on-demand or reserved instances (never spot) because it is the single entry point for all GraphQL traffic. A spot preemption of all router pods would cause a complete outage.

**Strategy:** Reserve instances for the minimum replica count (steady-state baseline). Use on-demand for burst scaling above the baseline.

```
Router baseline configuration:
  minReplicas: 5       ← Reserve 5 instances (1-year or 3-year reserved)
  maxReplicas: 20      ← Burst to 20 on-demand during traffic peaks

Reserved instance cost (c5.2xlarge, 1-year, no upfront):
  On-demand: $0.384/hour
  1-year RI: $0.238/hour (38% discount)
  3-year RI: $0.166/hour (57% discount)

5 routers × 720 hours/month:
  On-demand:  5 × 720 × $0.384 = $1,382/month
  1-year RI:  5 × 720 × $0.238 = $857/month  (saving: $525/month)
  3-year RI:  5 × 720 × $0.166 = $598/month  (saving: $784/month)
```

---

## Node Pool Optimization: Workload-Specific Pools

Different GraphQL workloads have different hardware requirements:

| Workload | CPU/Memory Profile | Recommended Instance | Rationale |
|----------|-------------------|---------------------|-----------|
| Apollo Router | CPU-intensive (query planning) | c5.2xlarge (compute-optimized) | Query planning is CPU-bound, not memory-bound |
| Subgraphs | Balanced (DataLoader memory + resolver CPU) | m5.xlarge (general purpose) | DataLoader keeps entities in memory; balanced profile fits |
| Recommendation subgraph | Memory-intensive (ML model in memory) | r5.xlarge (memory-optimized) | Large in-memory model; memory cost dominates |
| Non-prod / dev | Burstable (low average, occasional spikes) | t3.medium (burstable) | Dev traffic is bursty; burstable instances are 50% cheaper |

```hcl
# terraform/eks-node-pools.tf — separate node pools by workload type
resource "aws_eks_node_group" "router_compute" {
  cluster_name    = var.cluster_name
  node_group_name = "router-compute"
  capacity_type   = "ON_DEMAND"       # Never spot for the router
  instance_types  = ["c5.2xlarge"]

  labels = { "workload-type" = "graphql-router" }
}

resource "aws_eks_node_group" "subgraph_spot" {
  cluster_name    = var.cluster_name
  node_group_name = "subgraph-spot"
  capacity_type   = "SPOT"
  instance_types  = ["m5.xlarge", "m5a.xlarge", "m4.xlarge"]

  labels = { "workload-type" = "graphql-subgraph" }
}
```

---

## Compute Cost Summary

| Optimization | Effort | Monthly Saving | Risk |
|-------------|--------|----------------|------|
| Spot instances for subgraphs | Medium (PDB, toleration config) | $500–$2,000 | Low (stateless workloads) |
| Scale-to-zero dev/QA | Low (KEDA YAML) | $300–$1,000 | None |
| VPA right-sizing | Low (VPA in Off mode, review, apply) | $100–$500 | Low |
| Router reserved instances | Low (AWS console) | $200–$800 | None |
| Node pool specialization | Medium (Terraform) | $100–$300 | Low |
| Plan cache optimization | Medium (enforce named operations) | Indirect (reduces pod count) | None |

---

## References and Related Topics

- [06-performance-and-scaling/README.md](../06-performance-and-scaling/README.md) — Query planning optimization (intersects with CPU cost)
- [05-cost-allocation-and-showback.md](./05-cost-allocation-and-showback.md) — Per-team cost visibility via kubecost
- [32-production-runbooks/05-capacity-scaling-runbook.md](../32-production-runbooks/05-capacity-scaling-runbook.md) — Post-event scale-down to reduce compute cost
- [KEDA Cron Scaler](https://keda.sh/docs/2.14/scalers/cron/) — Scale-to-zero configuration
- [Kubecost Documentation](https://docs.kubecost.com/) — Kubernetes cost allocation
- [AWS EC2 Reserved Instances](https://aws.amazon.com/ec2/pricing/reserved-instances/) — RI pricing and purchase options
- [VPA Documentation](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler) — VPA setup and operation
