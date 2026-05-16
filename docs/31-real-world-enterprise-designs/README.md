# 31 — Real-World Enterprise Designs

> **Purpose:** Prescriptive architecture design documents for enterprise GraphQL deployments.
> Unlike case studies — which are retrospective — these are the actual design documents you
> would produce at the beginning of a project: requirements, constraints, architecture decision
> records (ADRs), entity ownership maps, federation topology, and phased implementation plans.
> Each document is written at the level of detail that would pass a principal engineer review.

---

## How to Read These Design Documents

Each design document follows a consistent structure:

1. **System Overview** — Scope, stakeholders, and the business context that makes this design
   necessary. What system are we building, and why does the GraphQL layer exist?

2. **Requirements** — Functional and non-functional requirements with concrete numbers.
   "Fast" is not a requirement. "p99 < 100ms at 10,000 RPS measured at the router" is.

3. **Constraints** — What cannot change. Legacy systems that cannot be replaced, compliance
   mandates, organizational boundaries, contractual obligations. Architecture decisions only
   make sense inside their constraint envelope.

4. **Bounded Contexts and Entity Ownership** — The domain decomposition. Which team owns
   which types. How ownership boundaries map to subgraph boundaries.

5. **Federation Topology** — The supergraph design: which subgraphs exist, what they own,
   how they reference each other via `@key`, and which entities cross multiple subgraphs.

6. **Architecture Decision Records (ADRs)** — The three to five hardest decisions, documented
   with context, options considered, the decision made, and the trade-offs accepted. ADRs are
   permanent records — they should not be edited when circumstances change. Superseding ADRs
   are added instead.

7. **Implementation Phases** — How to build this in a sequence that delivers value
   incrementally and avoids the big-bang failure mode.

---

## When to Use These Documents

These designs are starting points, not blueprints. Real deployments differ from these designs
in dozens of ways that depend on team topology, existing technology choices, and organizational
constraints that are impossible to anticipate from the outside. Use these documents to:

- Understand the problem structure of a domain before designing your own solution
- Identify the ADRs your team will need to write
- Calibrate scope and phasing for your own project
- Stress-test your own architecture by comparing entity ownership decisions

Do not copy-paste these designs into production without adapting them to your actual
constraints. The most dangerous thing an architect can do is apply a template to a problem
that does not fit the template.

---

## Design Index

| Design | Domain | Scale | Core Challenges |
|---|---|---|---|
| [01 — Global Retail Supergraph](./01-global-retail-supergraph.md) | Global Retail | 500M SKUs, 50M DAU, 12 markets | SAP integration, real-time inventory, GDPR, PCI, 100ms SLO |
| [02 — Financial Platform Design](./02-financial-platform-design.md) | Financial Services | 10K professional users | SEC audit trail, sub-100ms trade execution, multi-region data residency |
| [03 — Healthcare Data Platform](./03-healthcare-data-platform.md) | Healthcare | Multi-hospital network | HIPAA PHI, HL7 FHIR, field-level role masking, immutable audit logs |
| [04 — Gaming Platform Design](./04-gaming-platform-design.md) | Gaming | 100M players | Real-time leaderboards, anti-cheat, event sourcing, in-game economy |
| [05 — Developer Tools Platform](./05-developer-tools-platform.md) | Developer Tools | GitHub/GitLab-scale | Recursive types, event sourcing, webhook delivery, PAT rate limits |

---

## Cross-Cutting Themes

Reading across all five designs, the following architectural decisions appear repeatedly and
should be resolved early in any enterprise GraphQL project:

**Entity ownership is a team decision, not a schema decision.** The hardest part of drawing
subgraph boundaries is not the technical question of which fields belong together — it is the
organizational question of which team is responsible for keeping those fields correct. Subgraph
boundaries that map to team ownership boundaries have dramatically lower coordination overhead
than subgraph boundaries drawn along technical or domain lines that cut across team ownership.

**Compliance is an architecture input, not an architecture afterthought.** GDPR, PCI, HIPAA,
SEC audit requirements, and data residency mandates are not features to add to a finished
architecture. They constrain the architecture from the start. Schema contracts, field-level
authorization, immutable audit logs, and data residency boundaries must be designed in from
the first ADR. Retrofitting compliance onto a running system is five times more expensive than
designing for it upfront and is the source of most GraphQL security incidents.

**The router is the control plane.** Authentication, rate limiting, persisted query enforcement,
field-level tracing, and traffic shaping all belong at the router, not in individual subgraphs.
Subgraphs should assume the request is authenticated and the operation is pre-approved. This
separation of concerns makes subgraphs simpler and makes the security posture auditable at one
layer rather than distributed across fifteen services.

**Schema contracts are organizational agreements.** The technical mechanism (`@tag` + `rover
contract`) is simple. The hard part is getting product, engineering, legal, and security to
agree on which fields are in the public contract and which are internal. This negotiation
must happen before schema contracts are created — schema contracts cannot be used to force the
organizational conversation, only to enforce the outcome of it.

---

## Navigation Map

| File | Purpose |
|---|---|
| [README.md](./README.md) | This file. Overview, how to read, index. |
| [01-global-retail-supergraph.md](./01-global-retail-supergraph.md) | Supergraph design for a global retailer with SAP, GDPR, and real-time inventory |
| [02-financial-platform-design.md](./02-financial-platform-design.md) | GraphQL platform for a financial services firm with SEC compliance |
| [03-healthcare-data-platform.md](./03-healthcare-data-platform.md) | HIPAA-compliant API for a multi-hospital network with FHIR integration |
| [04-gaming-platform-design.md](./04-gaming-platform-design.md) | Real-time GraphQL for a 100M-player gaming platform |
| [05-developer-tools-platform.md](./05-developer-tools-platform.md) | GraphQL API for a developer tools platform with recursive types and webhooks |

---

## Related Topics

- [Federation](../07-federation/README.md)
- [Supergraph Architecture](../08-supergraph-architecture/README.md)
- [Security](../05-security/README.md)
- [Schema Governance](../09-schema-governance/README.md)
- [Production Case Studies](../23-production-case-studies/README.md)
- [Reference Architectures](../30-reference-architectures/README.md)
- [Production Runbooks](../32-production-runbooks/README.md)
