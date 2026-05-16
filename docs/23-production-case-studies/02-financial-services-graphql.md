# Case Study 02 — Financial Services GraphQL at Scale

> **Industry:** Wealth Management SaaS
> **Scale at migration start:** Multi-tenant platform, ~800 institutional clients (RIAs, broker-dealers), managing ~$200B AUM in aggregate
> **Regulatory environment:** SEC Rule 17a-4, FINRA 4370, SOC 2 Type II, periodic SEC examination
> **Migration duration:** 18 months
> **Outcome summary:** Zero cross-tenant data incidents post-migration (vs. 3 in 18 months prior), compliance audit passed without findings, 180ms p99 for primary dashboard operation (down from 520ms)

---

## Context

A wealth management SaaS company provided portfolio analytics, trading workflows, and client
reporting to Registered Investment Advisors (RIAs) and broker-dealers. The platform was
multi-tenant by design: each customer (an RIA or broker-dealer firm) had isolated data, and
each customer's end-clients (individual investors) had accounts within that tenant's scope.

The data isolation requirement was not optional or aspirational. It was a regulatory and
contractual obligation. Cross-tenant data disclosure — even accidental, even of a single
field — constituted a material breach of the customer agreement, triggered mandatory SEC
disclosure, and potentially exposed the company to FINRA enforcement action.

The platform served two primary personas:
- **Advisors** — authenticated employees of the RIA firm, reading portfolio data for their
  clients. All data scoped to the firm's tenant.
- **Investors** — end-clients of the RIA. Read-only access to their own portfolio. Cannot
  see data from other investors within the same firm, let alone other firms.

The backend was 14 REST microservices: portfolio positions, transactions, performance
analytics, account management, client management (CRM), trading, research, reporting,
billing, notifications, market data, documents, identity, and audit logging.

---

## Problem

Three categories of problems drove the migration.

### Cross-Tenant Data Leakage in Aggregation Endpoints

The most severe problem was a class of REST endpoints designed for aggregation. A
"portfolio overview" endpoint accepted a list of account IDs and returned aggregate
performance metrics. The endpoint was designed for multi-account views within a firm.
The bug was subtle: the endpoint validated that the requesting user was authenticated,
but it did not validate that all requested account IDs belonged to the requesting user's
tenant.

Over 18 months, three incidents occurred where a misconfigured client sent account IDs
from another tenant (in two cases due to a client-side state management bug that mixed
tenant contexts during navigation). The backend accepted the request and returned data
for accounts in a different firm.

Each incident required SEC disclosure, customer notification, and a formal incident
response. The third incident triggered a regulatory review.

The underlying architectural problem was that authorization logic was distributed across
14 services with no consistent enforcement pattern. Some services checked tenant scope.
Some checked user-level permissions. Some checked nothing and relied on the assumption
that callers would provide valid IDs. There was no single layer where tenant isolation
was enforced universally.

### Compliance Audit Trail Insufficient

SEC Rule 17a-4 requires that records of customer communications and business transactions
be preserved in a non-rewritable, non-erasable format. FINRA 4370 requires business
continuity planning documentation. The company's interpretation of these requirements
(validated with outside counsel) extended to API access logs: any API call that accessed
customer financial data had to be logged with the requesting user's identity, the
specific data accessed (field-level, not just endpoint-level), a timestamp, and an
immutable record that could not be altered by application code.

The existing REST audit logs captured endpoint access. They did not capture which fields
in the response were actually accessed, which was necessary for the field-level compliance
report the SEC examiner requested during the third incident review.

### 500ms+ Latency for Dashboard Loads

The advisor dashboard displayed aggregate portfolio performance for all of an advisor's
clients — potentially hundreds of portfolios. The dashboard backend loaded this data via
seven serial REST calls: account list, positions per account (batched but still sequential
with the account list call), performance metrics, transactions (last 30 days), alerts,
messages, and market data for the top holdings.

On a 10-advisor firm with 200 client accounts, the dashboard p99 was 520ms. On a 50-
advisor firm with 1,200 accounts, it was 1,800ms — which triggered the platform's own
SLA breach notification.

---

## Constraints

**Immutable audit log.** Any logging solution had to write to an immutable store that
application code could not alter. The company used AWS S3 with Object Lock (WORM mode).
Any GraphQL audit implementation had to write to S3 Object Lock within the request path.

**200ms SLA on portfolio data.** The customer contracts included a 200ms p99 SLA on
portfolio query operations. The migration could not regress this SLA.

**No anonymous operations.** Regulatory requirements mandated that every API request be
traceable to an authenticated identity. Anonymous or unauthenticated GraphQL requests
were not permitted under any circumstances.

**Persisted queries only.** After the third data incident, legal and compliance required
that the list of approved API operations be static and auditable. Ad-hoc queries — even
from authenticated advisors — were prohibited. Only pre-approved, registered operations
with a known query body were permitted.

**SOC 2 Type II scope.** The GraphQL layer had to be within the SOC 2 audit scope from
day one. This imposed specific requirements on logging, change management, and access
control that could not be deferred to a post-migration hardening phase.

---

## Solution

The architecture is a federated supergraph with security enforcement distributed across
three layers: the router (authentication and tenant injection), the subgraphs
(authorization and field-level audit), and a dedicated audit sidecar (immutable logging).

### Architecture Overview

```mermaid
graph TD
    subgraph "Client Tier"
        advisor["Advisor Browser\n(React SPA)"]
        investor["Investor Portal\n(React SPA)"]
    end

    subgraph "Edge"
        waf["WAF + mTLS Termination\n(AWS ALB)"]
    end

    subgraph "Supergraph Layer"
        router["Apollo Router\n• JWT validation\n• Tenant context injection\n• Persisted query enforcement\n• OPA policy sidecar"]
    end

    subgraph "Subgraphs"
        portfolio["Portfolio Subgraph\n(read replica — analytics)"]
        accounts["Accounts Subgraph\n(primary — write path)"]
        trading["Trading Subgraph\n(primary — write path)"]
        reporting["Reporting Subgraph\n(read replica — heavy queries)"]
        identity["Identity Subgraph\n(primary)"]
        market["Market Data Subgraph\n(external feed)"]
    end

    subgraph "Audit Layer"
        auditSidecar["Audit Sidecar\n(per-subgraph)"]
        s3worm["S3 Object Lock\n(WORM — immutable audit)"]
        auditIndex["Audit Search Index\n(OpenSearch — queryable copy)"]
    end

    subgraph "Policy Layer"
        opa["OPA Policy Engine\n(field-level auth)"]
        pqRegistry["Persisted Query Registry\n(Apollo GraphOS)"]
    end

    advisor --> waf
    investor --> waf
    waf --> router

    router --> opa
    router --> pqRegistry
    router --> portfolio
    router --> accounts
    router --> trading
    router --> reporting
    router --> identity
    router --> market

    portfolio --> auditSidecar
    accounts --> auditSidecar
    trading --> auditSidecar
    reporting --> auditSidecar

    auditSidecar --> s3worm
    auditSidecar --> auditIndex

    classDef client fill:#dbeafe,stroke:#3B82F6,color:#1e3a8a
    classDef router fill:#e8f4f8,stroke:#0ea5e9,color:#0c4a6e
    classDef subgraph fill:#f0fdf4,stroke:#22c55e,color:#14532d
    classDef audit fill:#fef9c3,stroke:#eab308,color:#713f12
    classDef policy fill:#fdf4ff,stroke:#a855f7,color:#581c87

    class advisor,investor client
    class waf,router router
    class portfolio,accounts,trading,reporting,identity,market subgraph
    class auditSidecar,s3worm,auditIndex audit
    class opa,pqRegistry policy
```

### OPA Policy Enforcement at the Field Level

The most architecturally significant decision was using Open Policy Agent (OPA) as a
policy engine called by Apollo Router via the coprocessor interface. The router calls OPA
before forwarding any request to a subgraph. OPA evaluates the request against policies
that enforce tenant scope.

The OPA policy for the portfolio subgraph:

```rego
package graphql.portfolio

import future.keywords.if

# Allow the request only if all requested account IDs belong to the tenant in context
deny[msg] if {
    input.operation_name == "PortfolioOverview"
    requested_account := input.variables.accountIds[_]
    not account_belongs_to_tenant(requested_account, input.tenant_id)
    msg := sprintf("account %v is not accessible to tenant %v", [requested_account, input.tenant_id])
}

account_belongs_to_tenant(account_id, tenant_id) if {
    data.accounts[account_id].tenant_id == tenant_id
}
```

The `tenant_id` in `input` is injected by the router from the validated JWT. Clients
cannot supply or manipulate the tenant context — it is derived exclusively from the
authentication token.

This architecture means tenant enforcement is no longer distributed across 14 service
implementations. It is in one place (the OPA policies), tested independently, and
updated without touching any service code.

### @auth Directive with Tenant Scope

The subgraph schemas use a custom `@auth` directive to declare field-level authorization
requirements inline:

```graphql
type Portfolio @key(fields: "id") {
  id: ID!
  accountId: ID!
  tenantId: ID! @auth(roles: ["ADMIN"], scope: "tenant")
  positions: [Position!]! @auth(roles: ["ADVISOR", "INVESTOR"])
  performanceMetrics: PerformanceMetrics! @auth(roles: ["ADVISOR", "INVESTOR"])
  # Only advisors can see the fee breakdown — investors cannot
  feeSchedule: FeeSchedule @auth(roles: ["ADVISOR"])
  # Only compliance officers can see raw transaction logs
  transactionLog: [Transaction!]! @auth(roles: ["ADVISOR", "COMPLIANCE"])
}
```

The `@auth` directive implementation in the router coprocessor checks the user's roles
(from the JWT) before the field resolves. If the role check fails, the field is omitted
from the response and an `UNAUTHORIZED` error extension is added. The client receives
partial data rather than an error, which is the correct behavior for a dashboard that
shows some data to advisors and a subset to investors.

### Field-Level Audit Logging to Immutable Store

Every resolver that accesses financial data emits an audit event before returning. The
audit event is structured:

```json
{
  "timestamp": "2024-03-15T14:23:11.042Z",
  "request_id": "req_9f2a8c3e",
  "operation_id": "apq:sha256:a1b2c3...",
  "operation_name": "PortfolioOverview",
  "user_id": "usr_advisor_12345",
  "tenant_id": "tenant_abc",
  "subgraph": "portfolio",
  "field_path": "query.portfolios.positions",
  "resolver_args": {"accountId": "acc_xyz789"},
  "data_accessed": ["position.symbol", "position.quantity", "position.marketValue"],
  "response_row_count": 47,
  "latency_ms": 23
}
```

The audit sidecar is a process that runs alongside each subgraph pod. The subgraph
publishes audit events to the sidecar over a Unix socket (in-process latency, no network
hop). The sidecar writes to S3 Object Lock synchronously before acknowledging. If the
S3 write fails, the sidecar returns an error to the subgraph, and the subgraph aborts the
resolver with an error. The design decision: **audit logging is synchronous and
non-optional**. A resolver that cannot produce an audit record does not execute.

This added roughly 8ms of latency per resolver call (S3 put latency in the same region).
The team accepted this trade-off. Compliance was not negotiable; 8ms was acceptable
against the 200ms SLA.

### Persisted Queries for Compliance

Only operations registered in the Apollo GraphOS persisted query list are accepted by the
router. The router configuration:

```yaml
# router.yaml
persisted_queries:
  enabled: true
  safelist:
    enabled: true
    require_id: true
```

With `safelist.enabled: true` and `safelist.require_id: true`, the router rejects any
operation that is not in the pre-registered list, even if the client sends the full query
body. This means:

- New operations require a schema check + persisted query registration PR, reviewed by
  the security team before they can execute in production.
- The full list of approved operations is auditable and version-controlled.
- Introspection is disabled in production (clients already have the schema via the
  development environment).

### Read Replicas as Separate Subgraphs for Analytics

The portfolio analytics queries — performance attribution, time-series returns, benchmark
comparison — are read-heavy, expensive queries that can tolerate slight data staleness
(sub-minute is acceptable; real-time is not required). They are also the primary cause of
the 1,800ms dashboard latency at scale: they ran on the primary database under the same
IOPS as the trading write path.

The solution separated the analytics query path into a dedicated subgraph that connects
to read replicas. The portfolio subgraph (primary) handles writes, entity resolution, and
real-time position data. The reporting subgraph (read replica) handles expensive
aggregations.

In the schema, this separation is invisible to clients — both are `Portfolio` fields:

```graphql
# portfolio subgraph (primary)
type Portfolio @key(fields: "id") {
  id: ID!
  positions: [Position!]!  # real-time, from primary
  cashBalance: Money!       # real-time, from primary
}

# reporting subgraph (read replica — analytics)
type Portfolio @key(fields: "id") {
  id: ID! @external
  performanceMetrics(period: PerformancePeriod!): PerformanceMetrics!
  benchmarkComparison(benchmarkId: ID!, period: PerformancePeriod!): BenchmarkResult!
  attribution: AttributionAnalysis!
}
```

The query planner directs `positions` and `cashBalance` to the primary subgraph and
`performanceMetrics` and `attribution` to the reporting subgraph. The router executes
both in parallel. The dashboard query now takes as long as the slower of the two parallel
requests, not the sum of all sequential requests.

### Query Complexity Limits Tuned to SLA

Each operation class has a complexity budget enforced at the router:

```yaml
# router.yaml
limits:
  max_depth: 10
  max_height: 50
  max_aliases: 15
  max_root_fields: 10

  # Per-operation-type complexity budgets
  # These were calibrated from production query traces
  # before the migration went live
  max_query_complexity: 1000      # read operations
  max_mutation_complexity: 200    # write operations (simpler, by design)
```

The complexity budget of 1,000 for read operations was calibrated against the observed
complexity of the most expensive legitimate dashboard query (complexity: 847) with a
15% headroom. Operations exceeding this budget are rejected with `COMPLEXITY_EXCEEDED`
before any subgraph is called.

---

## Security Architecture

**mTLS everywhere.** All communication between the router and subgraphs uses mutual TLS.
Certificates are rotated automatically via cert-manager on Kubernetes with a 24-hour
lifetime. A subgraph that presents an expired or unrecognized certificate is rejected.

**No anonymous operations.** The router rejects any request without a valid `Authorization`
header. The JWT contains: user ID, tenant ID, user roles, and an expiry. The JWT is signed
with RS256 using a key managed in AWS KMS. The router verifies the signature against the
public key fetched from the JWKS endpoint at startup.

**Field masking for PII in logs.** The router's telemetry configuration masks specific
argument values before emitting traces:

```yaml
# router.yaml
telemetry:
  exporters:
    tracing:
      common:
        # Mask PII fields in spans before export
        attributes:
          graphql.variables.ssn: { redact: "###-##-####" }
          graphql.variables.taxId: { redact: "[REDACTED]" }
          graphql.variables.dateOfBirth: { redact: "[REDACTED]" }
```

The S3 audit log does log these fields (unmasked) because the audit log is the compliance
record. The distributed trace (sent to the observability platform) does not.

---

## Trade-offs Accepted

**Persisted queries slow down development.** Every new operation requires a PR and review
before it works in production. During the initial migration, this added 1–2 days to any
feature that required a new query. The team accepted this as the correct trade-off given
the regulatory requirement. They reduced the overhead by making the PR process a GitHub
Action that runs schema checks automatically and routes to the security reviewer only if
checks pass.

**Synchronous audit logging adds latency.** The 8ms S3 write on every resolver call is
real and measurable. The team modeled several alternatives (async logging with a queue)
and rejected them because async logging creates a window where a request completes but
is not yet logged — which violates the immutability requirement (the log could be missing
records if the queue consumer fails before writing).

**OPA policy data store must be kept current.** The OPA policy for account-tenant mapping
requires a data store that maps account IDs to tenant IDs. This data store is populated
from the accounts service via a polling mechanism (every 30 seconds). If an account is
provisioned and a request for that account arrives within the 30-second window before OPA
picks up the new mapping, the request will be denied. The team accepted this false-negative
rate (denied requests for newly created accounts) as preferable to false-positive data
access.

---

## Outcome

Measured 90 days post-migration, against the original problem statement:

| Metric | Before | After |
|---|---|---|
| Cross-tenant data incidents | 3 in 18 months | 0 in 12 months post-migration |
| Dashboard query p99 (10-advisor firm, 200 accounts) | 520ms | 180ms |
| Dashboard query p99 (50-advisor firm, 1,200 accounts) | 1,800ms | 310ms |
| SEC audit findings related to API audit trail | 2 findings | 0 findings |
| Field-level audit coverage | 0% (endpoint-level only) | 100% of financial data resolvers |
| Operations blocked by persisted query enforcement | N/A | Blocked 847 unauthorized ad-hoc queries in first 90 days |

The 847 blocked unauthorized queries finding was unexpected. After deploying persisted
query enforcement, the router logged 847 rejected requests in 90 days that were not in
the approved operations list. Investigation traced them to an internal tooling script used
by the customer success team to pull portfolio data for support cases. The script was
using ad-hoc queries against the production API. Post-migration, the team registered
approved support operations in the persisted query list and issued the customer success
team credentials scoped to those operations only. This was a compliance gap that would
not have been discovered without the enforcement mechanism.

---

## What We Would Do Differently

**Build the OPA data sync before the migration, not during.** The account-tenant mapping
data store was built under time pressure during the migration and used a simple polling
mechanism. The 30-second window for newly created accounts is a known limitation that has
generated support tickets. A push-based mechanism (event-driven via account creation
events) would eliminate the window.

**Automate the persisted query PR process earlier.** The manual security review step for
each new persisted query became a bottleneck during the migration when 40+ operations
were being registered per sprint. The review automation (schema check + auto-approve if
no new fields) should have been built in sprint 1.

---

## References and Related Topics

- [Security](../05-security/README.md) — `@auth` directive, field masking, persisted queries
- [Policy as Code](../13-policy-as-code/README.md) — OPA integration with Apollo Router
- [Observability](../14-observability/README.md) — field-level audit logging, PII masking in traces
- [Supergraph Architecture](../08-supergraph-architecture/README.md) — router coprocessor interface
- [Federation](../07-federation/README.md) — subgraph patterns, read replica subgraphs
- [Migration Playbook](./05-platform-migration-playbook.md) — risk registry, rollback criteria
