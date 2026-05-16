# 04 — API Licensing and Tooling Cost Optimization

> **Purpose**
> Cost analysis and optimization of GraphQL tooling licensing across schema registry, router, schema check CI, and observability APM. Covers Apollo GraphOS tier selection, Hive as a self-hosted zero-cost alternative, self-hosted Apollo Router, build-vs-buy for schema check CI, supergraph consolidation, and open-source observability stack total cost of ownership. Written for platform engineers and engineering managers evaluating or rationalizing GraphQL tooling spend.

---

## GraphQL Tooling Cost Landscape

The typical enterprise GraphQL platform tooling stack includes:

| Tool Category | Paid Option | Open-Source Option |
|---------------|------------|-------------------|
| Schema registry + analytics | Apollo GraphOS | Hive (self-hosted) |
| Router / gateway | Apollo Router (free, Apache 2.0) | Apollo Router, graphql-yoga |
| Schema check CI | GraphOS Checks | graphql-inspector (self-hosted) |
| APM / observability | Datadog APM, New Relic | Prometheus + Tempo + Loki |
| Error tracking | Sentry, Datadog | Grafana Faro (open-source) |

The router and schema check CI categories have free options that match or exceed the paid alternatives in most enterprise use cases. The schema registry and APM categories require careful tier selection or a build/host decision.

---

## Apollo GraphOS Tier Analysis

### Tier Structure (as of 2026)

```
Serverless (Free):
  - Up to 10 million operations/month included
  - Schema registry (unlimited schemas)
  - Basic schema checks (operation-based checks)
  - Apollo Studio UI
  - GraphOS managed federation

  Best for: teams < 10M ops/month, early-stage enterprise adoption,
            or teams that don't need advanced analytics or custom metrics

Enterprise (Contact Sales — estimated $2,000–$20,000+/month):
  - Unlimited operations
  - Advanced schema checks (field-level usage, client breakdown)
  - Custom metrics and contract checks
  - SSO integration (SAML, OIDC)
  - SLA and dedicated support
  - Audit log access

  Best for: 100M+ operations/month with strict compliance requirements,
            multiple teams needing centralized schema governance,
            when the cost of self-hosting Hive > Apollo Enterprise pricing
```

**Tier selection decision:**

```
Operations per month < 10M    → GraphOS Serverless (free)
Operations per month 10M–50M  → Evaluate: Hive self-hosted vs GraphOS Enterprise
Operations per month > 50M    → Hive self-hosted likely cheaper unless Enterprise
                                  features (SSO, audit log, SLA) are mandatory
Compliance requirements (SOC2, HIPAA) → GraphOS Enterprise provides audit log;
                                         self-hosted Hive requires your own compliance scope
```

### Monitoring Operations/Month for Tier Threshold

```promql
# Track operations per month to predict tier usage
# 30-day operation count
sum(increase(apollo_router_graphql_requests_total[30d]))

# Operations per month projection (based on last 7 days)
sum(increase(apollo_router_graphql_requests_total[7d])) * (30 / 7)

# Alert when approaching 10M threshold (90% of free tier)
sum(increase(apollo_router_graphql_requests_total[30d])) > 9000000
```

---

## Hive: Open-Source Schema Registry

Hive is a fully open-source, self-hostable alternative to Apollo GraphOS for schema registry and analytics. It provides:

- Schema registry with versioning and diff
- Field-level usage analytics (same capability as GraphOS field usage)
- Schema check CI integration (`hive schema:check`)
- Supergraph composition (federated SDL management)
- Grafana dashboard export

**Self-hosting cost:**

```
Hive infrastructure requirements (Kubernetes):
  - PostgreSQL (schema storage): db.t3.medium → $0.052/hour = $37.44/month
  - ClickHouse (analytics): m5.xlarge → $0.192/hour = $138.24/month
  - Redis (rate limiting, caching): cache.t3.micro → $0.016/hour = $11.52/month
  - Hive app pods: 3 × t3.small → $0.0208/hour × 3 = $44.93/month
  - Hive worker pods: 2 × t3.small = $29.95/month

Total self-hosted Hive: ~$262/month

vs. Apollo GraphOS Enterprise: $2,000–$20,000+/month (contact sales for exact pricing)

Break-even: At 1 engineer-week/quarter for Hive maintenance (~$7,500 in eng cost)
  + $262/month infrastructure = ~$3,762/quarter total cost
  vs. Apollo Enterprise minimum: ~$6,000/quarter

Net saving (conservative): ~$2,238/quarter = $8,952/year
At higher Apollo Enterprise tiers: $50,000+/year saving
```

### Hive CI Integration

```yaml
# .github/workflows/schema-check.yml — Hive schema check in CI
name: Schema Check

on:
  pull_request:
    paths:
      - '**/*.graphql'
      - '**/schema.graphql'

jobs:
  schema-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Hive CLI
        run: npm install -g @graphql-hive/cli

      - name: Run schema check
        env:
          HIVE_TOKEN: ${{ secrets.HIVE_TOKEN }}
        run: |
          hive schema:check \
            --service ${{ matrix.subgraph }} \
            --file schema.graphql \
            --registry https://hive.internal.example.com

      # Schema check passes/fails based on breaking changes against usage data
      # Equivalent to: rover subgraph check (Apollo GraphOS)
```

---

## Apollo Router: Already Free (Apache 2.0)

Apollo Router is open-source under Apache 2.0 and is free to self-host. There is no licensing cost for the router itself — only the infrastructure cost of running it.

```bash
# Verify router license
curl -s https://raw.githubusercontent.com/apollographql/router/main/LICENSE | head -3
# Apache License, Version 2.0

# Router is NOT the same as Apollo Router Enterprise
# Apollo Router Enterprise adds:
#   - Persisted queries (available via self-hosted mechanism)
#   - JWT authentication plugin (implement via coprocessor for free)
#   - Traffic shaping via GraphOS contract checks

# Most enterprise features can be implemented via:
#   - Rhai scripts (built-in, free)
#   - Coprocessors (external service, free to implement)
#   - Open Policy Agent integration (free)
```

**"Enterprise" features available for free:**

| GraphOS Enterprise Feature | Free Alternative |
|---------------------------|------------------|
| Persisted queries | Implement with Redis + Apollo Router's PQ manifest support |
| JWT authentication | Rhai script or coprocessor |
| Operation complexity limits | Apollo Router built-in (no enterprise license needed) |
| Demand control | Apollo Router demand control (available in OSS router since v1.40) |
| Response caching | Apollo Router subgraph response caching (OSS) |

---

## Build vs Buy: Schema Check CI

### Option A: Apollo GraphOS Checks (Buy)

GraphOS Checks requires a GraphOS account (free tier covers basic checks, Enterprise for full field usage):

```bash
# GraphOS schema check in CI
rover subgraph check my-graph@prod \
  --schema ./schema.graphql \
  --name products

# Capabilities:
#   - Operation-level breaking change detection (free tier)
#   - Field usage data (shows which clients use which fields) ← Enterprise only
#   - Contract checks (schema contracts for different audiences) ← Enterprise only
```

### Option B: graphql-inspector (Open Source, Self-Hosted)

```bash
# Install graphql-inspector
npm install --save-dev @graphql-inspector/cli

# Schema diff in CI — detect breaking changes
npx graphql-inspector diff \
  schema-baseline.graphql \
  schema.graphql \
  --rule suppressDeprecatedEnumValues

# Expected output:
# ✖ Field 'Product.oldPrice' was removed  ← breaking
# ⚠ Field 'Product.price' is deprecated   ← warning
# ✔ Field 'Product.newField' was added     ← safe
```

```yaml
# .github/workflows/schema-check.yml — self-hosted schema check
name: Schema Check

on:
  pull_request:
    paths:
      - '**/schema.graphql'

jobs:
  schema-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # Need full history to get baseline

      - name: Get baseline schema from registry
        run: |
          # Fetch current production schema from Hive
          hive schema:fetch \
            --service products \
            --output /tmp/schema-baseline.graphql

      - name: Check for breaking changes
        run: |
          npx @graphql-inspector/cli diff \
            /tmp/schema-baseline.graphql \
            ./schema.graphql \
            --fail-on-breaking

      - name: Check field usage (if breaking changes found)
        if: failure()
        run: |
          # Query Hive for field usage analytics
          hive operations:stats \
            --service products \
            --period 30d \
            --filter "field: Product.oldPrice"
          # If no clients use the field in last 30 days, breaking change is safe
```

**Build vs Buy comparison:**

| Capability | GraphOS (Free) | GraphOS (Enterprise) | graphql-inspector + Hive |
|-----------|---------------|---------------------|--------------------------|
| Breaking change detection | Yes | Yes | Yes |
| Field usage (which clients use field) | No | Yes | Yes (via Hive analytics) |
| Contract checks | No | Yes | No (build custom) |
| Operation-based checks | Yes | Yes | No (build custom) |
| CI integration | rover CLI | rover CLI | npx + Hive CLI |
| Monthly cost | $0 | Contact sales | $262 (Hive infra) |

**Recommendation:** Use graphql-inspector + Hive for teams < 5 subgraphs with straightforward governance needs. Use GraphOS Enterprise when multiple teams need centralized visibility, SSO, and audit log access.

---

## Supergraph Consolidation

Running multiple separate GraphQL APIs (each with its own schema registry entry, router instance, and tooling subscription) multiplies tooling cost. A federated supergraph consolidates them:

```
Before consolidation:
  5 separate GraphQL APIs
  5 separate GraphOS accounts or registry entries
  5 separate router deployments
  5 separate monitoring setups

After consolidation into one supergraph:
  1 schema registry (one GraphOS account or one Hive instance)
  1 router deployment (Apollo Router)
  1 monitoring stack
  5 subgraphs (teams keep ownership of their domain)

Cost reduction:
  Schema registry: 5 accounts → 1 = 80% reduction
  Router infrastructure: 5 × 3 router pods → 1 × 5 router pods = 40% reduction
  Monitoring: 5 stacks → 1 = 80% reduction in monitoring infrastructure
  Engineering: 1 platform team owns the gateway vs 5 teams each owning a gateway
```

---

## Open-Source Observability Stack vs Datadog APM

### Datadog APM Pricing (Estimated)

```
At 10,000 RPS:
  APM hosts: ~20 hosts (router + subgraph pods)
  Datadog APM cost: $31/host/month × 20 hosts = $620/month
  
  Trace ingestion: 10,000 RPS × 86,400s × 400 bytes/span × 25 spans
    = 8.64TB/day → Datadog charges for ingested traces
  Datadog trace ingestion: $0.10/GB → 8.64TB × 30 × $0.10 = $25,920/month

  Logs: 25.9TB/month (at 100% sampling) × $0.10/GB ingest = $2,590/month

  Total Datadog: $620 + $25,920 + $2,590 = $29,130/month (before any custom metrics)
```

### Open-Source Stack (Prometheus + Tempo + Loki)

```
Prometheus (metrics, 30d retention):
  2 pods × m5.xlarge: 2 × $0.192 × 720 = $276/month
  EBS (500GB): $40/month
  Total: $316/month

Grafana Tempo (traces, S3 backend, with tail sampling):
  3 Tempo pods × m5d.xlarge: 3 × $0.226 × 720 = $488/month
  S3 storage (4.1TB/month × $0.023): $94/month
  Total: $582/month

Grafana Loki (logs, with filtering — ~518GB/month):
  2 Loki pods × m5.xlarge: $276/month
  S3 log storage (518GB × $0.023): $11.91/month
  Total: $288/month

Grafana OSS (dashboard, 2 pods × t3.medium):
  2 × $0.0416 × 720 = $59/month

Total OSS stack: $316 + $582 + $288 + $59 = $1,245/month
Engineering overhead: ~0.5 FTE for platform maintenance

vs. Datadog total: $29,130/month
Monthly saving: $27,885/month ($334,620/year)
```

**Trade-off analysis:**

| Dimension | Datadog APM | Open-Source Stack |
|-----------|------------|-------------------|
| Setup time | 1 day (agent install) | 2–4 weeks |
| Maintenance | Zero (fully managed) | ~0.25–0.5 FTE/quarter |
| Auto-instrumentation quality | Excellent | Good (OTel) |
| GraphQL-specific dashboards | Generic (no GraphQL-native views) | Custom (you build them) |
| Alert management | Built-in | Prometheus Alertmanager |
| Mobile APM | Datadog RUM | Grafana Faro |
| Cost at scale | $29,130/month | $1,245/month |
| Cost at small scale (< 1k RPS) | ~$3,000/month | ~$400/month |

**Recommendation:** For teams > 1,000 RPS with a dedicated platform engineer, the open-source stack is 10–20x cheaper. For teams < 100 RPS with no platform expertise, Datadog's managed offering reduces operational burden that may exceed the cost difference.

---

## Total Cost of Ownership Comparison

### Scenario: Mid-Scale Enterprise (5,000 RPS, 5 Subgraphs)

```
GraphOS Enterprise + Datadog APM (All-Paid):
  Apollo GraphOS Enterprise:         $5,000/month (estimated mid-tier)
  Datadog APM (10 hosts):            $310/month
  Datadog Logs (259TB/month):        $12,950/month
  Datadog Traces (100% sampling):    $12,960/month
  Total tooling: $31,220/month = $374,640/year

GraphOS Serverless + Open-Source Observability (Hybrid):
  Apollo GraphOS Serverless:         $0/month (< 10M ops, 5k RPS × 86400 = 432M ops/day → exceeds free tier)
  → Use Hive self-hosted:            $262/month
  Prometheus + Loki + Tempo stack:   $1,245/month (as calculated above)
  Total tooling: $1,507/month = $18,084/year

Savings: $374,640 - $18,084 = $356,556/year
Platform engineer salary to maintain open-source stack: ~$180,000/year
Net saving: $356,556 - $180,000 = $176,556/year
ROI: positive at > 12 months
```

---

## Decision Matrix

| Team Size / RPS | Schema Registry | Router | Observability | Rationale |
|----------------|----------------|--------|---------------|-----------|
| < 5 engineers, < 1M ops/month | GraphOS Serverless | Apollo Router OSS | Datadog starter | Minimize ops burden |
| 5–20 engineers, 1M–50M ops/month | GraphOS Serverless or Hive | Apollo Router OSS | OSS stack | Hybrid: free registry, OSS obs |
| 20+ engineers, 50M+ ops/month | Hive self-hosted | Apollo Router OSS | OSS stack | Full open-source, max saving |
| Compliance-heavy (SOC2, HIPAA) | GraphOS Enterprise | Apollo Router OSS | Datadog or OSS | Enterprise audit log required |

---

## References and Related Topics

- [Apollo GraphOS Pricing](https://www.apollographql.com/pricing/) — Current tier structure and limits
- [Hive Schema Registry](https://the-guild.dev/graphql/hive) — Open-source self-hosted alternative
- [graphql-inspector](https://the-guild.dev/graphql/inspector) — Schema diff and breaking change detection
- [Apollo Router Apache 2.0 License](https://github.com/apollographql/router/blob/main/LICENSE) — License reference
- [03-observability-cost-optimization.md](./03-observability-cost-optimization.md) — Detailed observability stack cost math
- [11-ci-cd-automation/README.md](../11-ci-cd-automation/README.md) — CI pipeline using schema check tooling
- [09-schema-governance/README.md](../09-schema-governance/README.md) — Governance model that schema check CI enforces
