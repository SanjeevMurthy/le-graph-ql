# 23 — Production Case Studies

> **Purpose:** Anonymized architectural case studies from real enterprise GraphQL migrations
> and deployments. Each study documents the full decision arc: the organizational context that
> created the problem, the constraints that ruled out obvious solutions, the architecture that
> was chosen, the trade-offs that were accepted, and the measurable outcomes that resulted.
> These are not success stories — they are engineering records that include what went wrong
> and what the team would do differently.

---

## How to Read These Case Studies

Each case study follows a consistent structure:

1. **Context** — The organization, scale, and system topology before GraphQL. Knowing what
   existed makes the problem legible.
2. **Problem** — The specific pain, measured where possible. "Slow" is not a problem.
   "450ms p99 on the dashboard query with three mobile apps calling the same three endpoints
   in serial" is a problem.
3. **Constraints** — What the team could not change. Budget, compliance requirements, existing
   contracts, organizational politics. These constraints are where engineering decisions live.
4. **Solution** — What was built, with architecture diagrams and key configuration decisions.
5. **Trade-offs** — What the solution gave up. Every architecture trades one set of problems
   for another. Honest documentation names both sides.
6. **Outcome** — What actually happened, measured against the original problem statement.

Case studies are anonymized. Identifying details (company names, team names, exact product
names) have been removed or altered. Technical details — schema structure, query patterns,
infrastructure topology, measured outcomes — are preserved accurately.

---

## Case Study Index

| Case Study | Industry | Scale | Core Problem |
|---|---|---|---|
| [01 — E-Commerce Supergraph Migration](./01-ecommerce-supergraph.md) | Retail | 20 backend services, 3 mobile apps | Inconsistent data models, n+1 API calls, 6-month cross-service feature lag |
| [02 — Financial Services GraphQL at Scale](./02-financial-services-graphql.md) | Wealth Management SaaS | Multi-tenant, 200ms SLA | Cross-tenant data leakage, compliance audit gaps, 500ms+ dashboard latency |
| [03 — SaaS Multi-Tenant Schema Customization](./03-saas-multi-tenant-architecture.md) | B2B CRM SaaS | 500 enterprise tenants | Per-tenant custom fields, schema drift, no tenant-specific schema without separate deploys |
| [04 — Media Platform Subscriptions at Scale](./04-media-streaming-subscriptions.md) | Streaming Media | 10M concurrent users | WebSocket infrastructure at 10M connections, subscription hot spots, backpressure |
| [05 — Cross-Cutting Migration Playbook](./05-platform-migration-playbook.md) | Cross-industry | All of the above | Synthesized migration patterns, risk registry, rollback criteria |

---

## Recurring Themes

Reading across all five case studies, four patterns appear in every successful migration:

**The strangler fig works.** No team rewrote their entire API surface in one release. Every
successful migration ran new GraphQL alongside existing REST, migrated clients incrementally,
and decommissioned REST only after GraphQL had accumulated enough production history to be
trusted. Teams that tried "big bang" migrations are not in this case study collection because
they failed and reverted.

**The first subgraph is the hardest.** Once the router, schema registry, CI pipeline, and
DataLoader infrastructure exist, the second subgraph is a copy-paste-and-modify operation.
The engineering effort front-loads heavily. Teams that budget for a six-week first subgraph
and a two-week second subgraph are calibrated correctly. Teams that budget one week for the
first subgraph are not.

**Entity resolution changes the product roadmap.** In every case, once engineers could write
a resolver that crossed subgraph boundaries via `@key` / `_entities`, product features that
had been classified as "requires backend coordination — 6 weeks" became "another field in
the resolver — 3 days." This outcome surprised everyone, including the engineers who built
the platform. The velocity improvement is structural, not incidental.

**Observability must come first.** The teams that instrumented the router and subgraphs before
migrating clients caught problems in staging. The teams that instrumented after going to
production discovered them via customer complaints. Field-level latency tracing is the
specific capability that separated clean migrations from painful ones.

---

## How Case Studies Relate to Other Chapters

These case studies are application documents. They reference patterns from every chapter in
this repository. When a case study says "we applied field-level authorization using a custom
directive," the specification for how to do that is in
[Chapter 05 — Security](../05-security/README.md). When it says "we used persisted queries
for compliance," the implementation guide is in
[Chapter 11 — CI/CD Automation](../11-ci-cd-automation/README.md).

The case studies do not duplicate those specifications. They show why the decision was made
and what happened when it was applied under real constraints.

---

## Navigation Map

| File | Purpose |
|---|---|
| [README.md](./README.md) | This file. Overview, themes, how to read. |
| [01-ecommerce-supergraph.md](./01-ecommerce-supergraph.md) | Federated supergraph migration for a mid-size retailer |
| [02-financial-services-graphql.md](./02-financial-services-graphql.md) | Compliance-grade GraphQL for a wealth management platform |
| [03-saas-multi-tenant-architecture.md](./03-saas-multi-tenant-architecture.md) | Per-tenant schema customization without separate deployments |
| [04-media-streaming-subscriptions.md](./04-media-streaming-subscriptions.md) | 10M concurrent subscriptions on a streaming platform |
| [05-platform-migration-playbook.md](./05-platform-migration-playbook.md) | Cross-cutting migration patterns, risk registry, rollback criteria |

---

## Related Topics

- [Federation](../07-federation/README.md)
- [Supergraph Architecture](../08-supergraph-architecture/README.md)
- [Security](../05-security/README.md)
- [Performance and Scaling](../06-performance-and-scaling/README.md)
- [Observability](../14-observability/README.md)
- [CI/CD Automation](../11-ci-cd-automation/README.md)
- [System Design Scenarios](../24-system-design-scenarios/README.md)
