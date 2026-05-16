# Cost Optimization for Enterprise GraphQL Infrastructure

> **Purpose**
> This section covers cost optimization strategies for enterprise GraphQL infrastructure across compute, database, observability, and API tooling licensing layers. GraphQL introduces cost dynamics that do not exist in REST — query planning CPU, DataLoader memory amplification, and per-operation observability cardinality. Each document identifies the cost driver, quantifies it, and provides actionable levers to reduce it. Written for platform engineers, engineering managers, and infrastructure architects who own the GraphQL platform budget.

---

## Why GraphQL Cost Optimization Is Different

Standard infrastructure cost optimization focuses on right-sizing compute and reducing idle capacity. GraphQL adds three cost dimensions that require specialized treatment:

**Query planning CPU.** The Apollo Router replans every unique operation shape. At 10,000 RPS with 500 unique operations, query planning is constant CPU work. A plan cache hit rate below 90% can double router CPU cost. This is invisible to engineers who treat the router as a transparent proxy.

**DataLoader memory per request.** Well-implemented DataLoaders batch database queries but keep entity sets in memory for the lifetime of the request. At 1,000 concurrent requests, each with a DataLoader holding 100 product objects: 100,000 objects in memory across the subgraph fleet. This amplification is proportional to request concurrency, not RPS, making memory costs non-linear.

**Observability cardinality cost.** A naive metrics implementation that creates a time series per `operation_name × client_id × field_path` can generate 10–100 million active series at scale. At Prometheus/Mimir pricing, this is often the largest cost driver in a mature GraphQL platform — exceeding compute costs.

---

## Cost Layer Map

| Layer | Primary Cost Drivers | Key Optimization | Documents |
|-------|---------------------|-----------------|-----------|
| Compute | Router CPU (query planning), subgraph pod count | Spot instances, HPA tuning, node pool selection | [01](./01-compute-cost-optimization.md) |
| Database | N+1 queries, connection overhead, hot data reads | DataLoader batching, read replicas, response cache | [02](./02-database-cost-optimization.md) |
| Observability | Trace volume, metric cardinality, log verbosity | Tail-based sampling, recording rules, log filtering | [03](./03-observability-cost-optimization.md) |
| API Licensing | GraphOS tiers, schema registry tooling, APM | Open-source alternatives, tier right-sizing | [04](./04-api-licensing-cost-optimization.md) |
| Cost Allocation | Unattributed costs, no per-team visibility | Kubecost chargeback, showback dashboards | [05](./05-cost-allocation-and-showback.md) |

---

## Section Map

```
34-cost-optimization/
├── README.md                              ← You are here — purpose and navigation
├── 01-compute-cost-optimization.md        ← Router CPU, subgraph pods, node pools
├── 02-database-cost-optimization.md       ← DataLoader, connection pooling, read replicas
├── 03-observability-cost-optimization.md  ← Trace sampling, metric cardinality, log filtering
├── 04-api-licensing-cost-optimization.md  ← GraphOS, Hive, open-source alternatives
└── 05-cost-allocation-and-showback.md     ← Per-team attribution and chargeback
```

---

## Quick Wins by Cost Category

Before reading the full documents, these are the highest-impact optimizations most teams implement first:

**Compute:** Enable spot/preemptible instances for subgraphs. Subgraphs are stateless — they are safe to run on spot with a proper PodDisruptionBudget. Typical saving: 60–70% of subgraph compute cost.

**Database:** Confirm DataLoader batching is working via the `graphql_dataloader_batch_size` metric. A single N+1 regression in a high-traffic subgraph can 100x the database query rate. This is a latency problem and a cost problem simultaneously.

**Observability:** Switch from 100% trace sampling to tail-based sampling with 100% error trace retention and 1–5% success trace sampling. At 10,000 RPS this reduces trace storage cost by 90–99% with no loss of error visibility.

**API Licensing:** If using GraphOS Serverless with under 10M operations per month, you are on the free tier — no action needed. If approaching that limit, evaluate Hive (self-hosted, zero licensing cost) as a registry alternative before committing to GraphOS Dedicated pricing.

---

## Cost Efficiency Baseline Metrics

Before optimizing, measure your current baseline:

```promql
# Cost per million GraphQL operations (compute cost proxy — CPU hours)
# Total router + subgraph CPU hours in the last 30 days
sum(
  increase(process_cpu_seconds_total{namespace="graphql-platform"}[30d])
) / 3600   # Convert seconds to hours

# Divide total monthly infrastructure cost by monthly operation count
# Cost per million ops = (monthly_infra_cost_USD / monthly_operations) * 1_000_000

# Monthly operation count
sum(increase(apollo_router_graphql_requests_total[30d]))
```

The industry benchmark for a well-optimized federated GraphQL platform is **$0.05–$0.20 per million operations** at scale (1B+ operations/month), depending on operation complexity. If you are above $0.50/million operations, there is significant optimization headroom.

---

## Related Topics

- [06-performance-and-scaling/README.md](../06-performance-and-scaling/README.md) — Performance improvements that also reduce cost
- [15-kubernetes-deployment/README.md](../15-kubernetes-deployment/README.md) — Kubernetes resource configuration
- [32-production-runbooks/05-capacity-scaling-runbook.md](../32-production-runbooks/05-capacity-scaling-runbook.md) — Post-event scale-down procedure
- [14-observability/README.md](../14-observability/README.md) — Observability stack architecture
