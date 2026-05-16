# Case Study 05 — Platform Migration Playbook

> **Purpose:** This document synthesizes cross-cutting migration patterns from all four
> case studies in this collection. It is a practical reference for engineering teams
> planning a GraphQL migration, not a theoretical framework. Every pattern here was
> observed in at least two of the four case studies and is documented with the failure
> mode it prevents.

---

## The Three Migration Archetypes

All GraphQL migrations fall into one of three archetypes, distinguished by what exists
before the migration begins. The archetypes are not mutually exclusive — a migration can
shift between archetypes as it progresses.

### Archetype 1: Greenfield Federation

A new product (or a new domain within an existing product) is built as a GraphQL
subgraph from the start. No legacy API exists. The subgraph is the first implementation.

This is the lowest-risk archetype. The team designs the schema before writing any
resolver. Entity boundaries, `@key` selection, and nullability decisions are made once,
deliberately. The first client built against the API was designed for GraphQL and does
not need to be migrated.

**When it applies:** New product domains, greenfield API development, new team joining
an existing supergraph.

**Failure mode unique to this archetype:** Premature stabilization. Teams designing a
greenfield schema sometimes lock in decisions early to avoid churn, then discover that
the schema does not match the actual usage patterns after the first client ships. The
mitigation is explicit pre-stable markers (`@deprecated`, experimental field tags) and
a defined stabilization process.

### Archetype 2: REST Strangler Fig

An existing REST API is progressively replaced by a GraphQL layer. The GraphQL layer
proxies requests to the existing REST API (and possibly directly to the database). REST
endpoints are deprecated and removed only after all known clients have migrated.

This was the pattern used in the e-commerce migration (Case Study 01) and the financial
services migration (Case Study 02). It is the lowest-disruption archetype for production
systems with existing client traffic.

**When it applies:** Existing REST APIs with active client traffic, teams that cannot
afford a cutover period, organizations with slow client release cycles (iOS App Store).

**Failure mode unique to this archetype:** The proxy layer becomes permanent. In the
e-commerce case, the "thin adapter" subgraphs were expected to be removed once the
backend services were migrated to publish their own schema. This did not happen for most
services. Plan explicitly for the adapter removal phase, or accept that you are building
a permanent translation layer.

### Archetype 3: Monolith Decomposition

A monolithic application with an internal API (or no formal API) is decomposed into
subgraphs as it is decomposed into services. The GraphQL schema boundary and the service
boundary are designed together.

**When it applies:** Monolith-to-microservices migrations, legacy systems being rebuilt.

**Failure mode unique to this archetype:** GraphQL schema boundaries do not match service
boundaries. Teams design subgraph boundaries to mirror their organizational structure
(Conway's Law) rather than to minimize cross-subgraph entity resolution. The result is
a supergraph where every query requires fan-out to 8 subgraphs because the entity that
anchors the query is distributed across team boundaries. The mitigation is to design
entity boundaries before service boundaries — the subgraph schema should drive the
service split, not the other way around.

---

## Phase-by-Phase Migration Template

This template applies to all three archetypes, with notes on archetype-specific
adjustments at each phase.

### Phase 0: Discovery and Schema Design (Weeks 1–4)

**Objective:** Understand the current API surface, identify entity boundaries, and
produce a draft supergraph schema before writing any code.

Activities:
1. Audit all existing API consumers. Identify every client (web, mobile, server-to-
   server, partner integrations) and the specific endpoints each consumes. This audit
   will surface integrations you did not know existed (this happened in three of four
   case studies).
2. Identify the canonical entities. What are the core domain objects (Product, User,
   Order, Account)? How many different representations does each entity have in the
   current API surface? Each representation is a future `@key` definition.
3. Design the subgraph boundary map. Which team owns which subgraph? The boundary map
   must be agreed to by all affected teams before development begins.
4. Draft the schema SDL for the first subgraph. Review with the client teams that will
   consume it. Collect feedback before implementation.
5. Confirm the error handling contract. For each field, decide: is this field `nullable`
   if the subgraph is degraded? What happens to the parent query if this field's
   subgraph is completely unavailable? These decisions made in Phase 0 prevent
   debugging in Phase 2.

**Exit criteria:** Subgraph boundary map approved by all team leads, first subgraph
schema reviewed and signed off by at least one client team.

**Archetype notes:**
- *Greenfield:* Phase 0 is longer (weeks 3–6) because there is no existing API to audit.
  The schema design phase is the primary work product.
- *Strangler Fig:* Audit the existing REST API response shapes carefully. The GraphQL
  schema is often richer (no envelope objects, proper types instead of strings) — these
  differences must be communicated to client teams before migration.
- *Monolith Decomposition:* Phase 0 includes mapping database tables to entity boundaries.
  This is the hardest activity in this phase.

### Phase 1: Infrastructure Setup (Weeks 3–6, parallel with Phase 0)

**Objective:** Router, schema registry, CI pipeline, and observability are operational
before the first client migrates any traffic.

Activities:
1. Deploy Apollo Router (or equivalent) to the production environment. Route 0% of client
   traffic to it.
2. Configure the schema registry (Apollo GraphOS, Hive, or Cosmo). Publish the first
   subgraph schema.
3. Add schema check CI jobs to all subgraph repositories. Schema checks should be running
   before any resolver code is written.
4. Configure OpenTelemetry tracing at the router and in the first subgraph. Verify that
   field-level traces are visible in the observability platform.
5. Synthetic traffic tests. Send production-representative query shapes to the GraphQL
   endpoint (with no clients migrated) to validate latency and error behavior.

**Exit criteria:** Router and first subgraph deployed in production, schema checks passing
in CI, field-level traces visible in observability dashboard, synthetic load test
completed within SLA.

**Critical mistake to avoid:** Skipping observability setup until after the first client
migrates. Field-level traces are necessary to diagnose issues during client migration.
Without them, you are debugging production issues with HTTP-level observability only.

### Phase 2: Subgraph Rollout and Client Migration (Months 2–N)

**Objective:** Migrate one subgraph's worth of client traffic per sprint (or per
milestone, depending on scope). Each migration follows the dark launch → ramp → validate
→ deprecate pattern.

Migration procedure per subgraph:
1. Deploy the subgraph. Verify health in production with synthetic traffic.
2. Implement the equivalent GraphQL operation for one client team's use case.
3. Dark launch: route 1% of that client's traffic to the GraphQL path. Monitor error
   rate, latency delta, and data correctness.
4. Ramp: 10% → 50% → 100% over two weeks. Each increase follows a 24-hour observation
   period.
5. At 100% for this client: deprecate the corresponding REST endpoints (add deprecation
   header, log warnings, set removal timeline).
6. Repeat for remaining client teams consuming this subgraph's data.

**Error rate threshold for pausing ramp:** If the GraphQL error rate exceeds the REST
baseline by more than 0.5 absolute percentage points at any ramp stage, stop the ramp
and investigate before proceeding.

**Archetype notes:**
- *Strangler Fig:* Do not remove REST endpoints until all clients at all versions have
  migrated. Use access log monitoring to confirm zero traffic for at least 14 days before
  scheduling removal. Account for slow-release-cycle clients (iOS App Store).

### Phase 3: REST Decommission and Cleanup (Months N to N+3)

**Objective:** Remove deprecated REST endpoints and adapter subgraphs that were
introduced as temporary translation layers.

Activities:
1. Monitor REST endpoint access logs for zero-traffic status.
2. For each endpoint showing zero traffic for 14+ days: send deprecation notice to the
   API changelog, wait 30 days, remove.
3. Review adapter subgraphs. If the underlying service can now publish its schema
   directly (subgraph-as-source-of-truth rather than adapter), plan the migration of the
   subgraph to eliminate the adapter layer.
4. Update CLAUDE.md and architecture documentation to reflect the decommissioned components.

---

## Risk Registry

These are the risks that occurred in the case studies, with their severity and mitigations.

| Risk | Severity | Case Study | Mitigation |
|---|---|---|---|
| Breaking change reaches mobile clients before App Store review cycle completes | High | CS-01 | Schema checks in CI blocking breaking changes; deprecated fields kept for 6+ months |
| Adapter subgraph calls REST API that changes response format silently | High | CS-01, CS-02 | Contract tests (Pact or equivalent) between adapter and REST API; alerts on response shape mismatch |
| Entity resolution fan-out causes N+1 at subgraph boundaries | High | CS-01 | DataLoader for entity batch loading; query plan review in staging before client migration |
| Tenant isolation failure in multi-tenant context | Critical | CS-02, CS-03 | OPA policy enforcement at router layer; DataLoader tenant-isolation key; integration tests for cross-tenant access |
| Subscription registration storm on breaking news / flash event | High | CS-04 | Per-user subscription rate limiting; subscription deduplication at router |
| Slow-client backpressure causing OOM in subscription server | High | CS-04 | Per-connection message queue bound; slow client detection and graceful disconnect |
| Schema check CI job not catching breaking change (field rename vs add+deprecate) | Medium | CS-01 | Apollo schema check `--severity=ERROR` for breaking changes; weekly breaking change review |
| Observability not in place when first client migrates | Medium | CS-01, CS-04 | Phase 1 exit criteria requires field-level traces before any client migration |
| Partner / server-to-server integrations missed in consumer audit | Medium | CS-01 | Consumer audit as Phase 0 exit criteria; access log analysis for undocumented callers |
| Persisted query enforcement blocking internal tooling | Low | CS-02 | Internal tools audit during persisted query enforcement rollout; grace period before hard enforcement |
| Read replica lag causing stale data in analytics subgraph | Low | CS-02 | Explicit `@tag` indicating staleness tolerance; document replication lag in schema description |

---

## Client Migration Strategy

### Parallel Endpoint Coexistence

The REST endpoint and the GraphQL endpoint must run in parallel during the migration
period. Both must be actively monitored. The GraphQL endpoint is not the primary path
until it is confirmed stable at 100% of a client's traffic.

Do not degrade the REST endpoint's infrastructure during the parallel period. The REST
endpoint must be a viable rollback target. If the REST service's database is removed,
or its dependencies are degraded, rollback is no longer available.

### Deprecation Timeline

The deprecation timeline should be published before migration begins and communicated
to all known API consumers:

```
T+0: GraphQL endpoint deployed in production (no clients migrated)
T+4 weeks: First client migrated (dark launch begins)
T+3 months: All internal clients migrated to GraphQL
T+6 months: Partner integration migration deadline communicated
T+9 months: REST endpoints marked deprecated (HTTP 301 header added)
T+12 months: REST endpoints removed (no longer available)
```

This timeline was compressed in all four case studies (the e-commerce migration took
14 months end-to-end, the financial services migration took 18 months). The timeline is a
negotiation, not a fixed deadline. It should be based on the actual client migration
velocity observed in Phase 2.

### Usage Tracking

Every REST API call during the parallel period should be logged with the client identifier
(user-agent, API key, or authenticated identity). This data drives the decommission
decision. An endpoint with zero traffic for 14 days is safe to remove. An endpoint with
50 calls per week needs investigation before removal.

Apollo Router provides per-operation usage metrics through Apollo GraphOS. REST access
logs (from the load balancer or the REST service's middleware) provide the equivalent
for the REST endpoints.

---

## The "Never Break Production" Constraint

This constraint is simple to state and requires discipline to maintain:

1. **Additive changes only during migration.** Add new fields. Do not remove or rename
   existing fields until all known clients have confirmed they are not using them.

2. **Deprecate before removing.** Fields that will be removed must be marked `@deprecated`
   in the schema with a deprecation reason that explains the replacement. Deprecation
   must be in production for at least one full client release cycle (12 weeks minimum
   for mobile clients with App Store review).

3. **Breaking change CI gate.** Apollo schema checks must be configured with breaking
   change severity set to `ERROR` (not `WARN`). Breaking changes that have not been
   pre-approved via the RFC process must not merge.

4. **The rollback window.** For the first 30 days after a subgraph goes live for client
   traffic, maintain the ability to roll back the router to route all traffic for that
   domain back to REST. After 30 days of stable operation, rollback can be relaxed (but
   the REST endpoint should remain live until the full decommission phase).

---

## Migration Health Metrics

Track these metrics throughout the migration. Review them weekly with the team. An
adverse trend in any metric should pause the migration until root cause is identified.

| Metric | Target | Measurement |
|---|---|---|
| % clients migrated to GraphQL (by client type) | Week-over-week increase | Apollo GraphOS operation usage by client user-agent |
| GraphQL error rate vs REST baseline | ≤ REST baseline + 0.1% | Router error rate metric per operation |
| GraphQL p99 latency vs REST baseline | ≤ REST baseline + 10% | Router latency histogram per operation |
| Schema check pass rate (CI) | 100% | CI dashboard |
| Breaking changes blocked by schema check | Track count | CI metric — should trend toward zero over time |
| REST endpoint traffic (deprecated endpoints) | Week-over-week decrease | Load balancer access logs |
| Rollback events | 0 per sprint | Incident tracker |

---

## Rollback Decision Criteria and Procedure

### When to Roll Back

Trigger an immediate rollback of a specific subgraph's client traffic to REST if any of
the following occur:

- GraphQL error rate for the subgraph's operations exceeds the REST baseline by more
  than 2 absolute percentage points for more than 5 minutes.
- A data correctness incident is reported (client receives wrong data, not an error).
- The subgraph is unavailable and the null-handling contract produces degraded user
  experience not matching the production SLA.
- A security incident is detected (unauthorized data access, authentication bypass).

### Rollback Procedure

For the Strangler Fig archetype, rollback is a traffic routing change at the client or
load balancer level:

```
1. Set feature flag / traffic routing to send 0% of traffic to GraphQL for the affected
   domain.
   Time to complete: < 2 minutes for feature-flag-based routing.

2. Verify REST error rate returns to baseline (monitor for 5 minutes).

3. Create incident ticket with timestamp, affected operation, error signature.

4. Do not re-migrate the affected traffic until root cause is identified and a fix is
   deployed and validated in staging.
```

For the Greenfield archetype (no REST fallback), rollback means deploying the previous
subgraph version:

```
1. Identify the last known-good subgraph image tag from the deployment history.
2. Roll back the subgraph deployment to the known-good image.
   Time to complete: < 5 minutes (Kubernetes rollout undo).
3. If the router is serving a composed schema that depends on the broken subgraph schema,
   roll back the schema in the registry to the last published good version.
   Use: rover subgraph publish --schema <last-good-schema> --variant production
4. Verify router is serving the rolled-back schema (check the router's live schema
   endpoint or Apollo GraphOS studio).
```

### Post-Rollback

After a rollback:
- A post-incident review is required before re-attempting the migration.
- The incident is documented in the migration risk registry.
- The migration phase-gate criteria are reviewed: did the rollback trigger indicate a
  gap in staging testing, observability, or the migration procedure?

---

## References and Related Topics

- [E-Commerce Supergraph Migration](./01-ecommerce-supergraph.md)
- [Financial Services GraphQL](./02-financial-services-graphql.md)
- [SaaS Multi-Tenant Architecture](./03-saas-multi-tenant-architecture.md)
- [Media Platform Subscriptions](./04-media-streaming-subscriptions.md)
- [CI/CD Automation](../11-ci-cd-automation/README.md) — schema checks, automated rollback
- [Observability](../14-observability/README.md) — field-level tracing, migration metrics
- [Schema Governance](../09-schema-governance/README.md) — breaking change policy, deprecation lifecycle
- [Supergraph Architecture](../08-supergraph-architecture/README.md) — router canary deployments
- [Security](../05-security/README.md) — tenant isolation patterns
