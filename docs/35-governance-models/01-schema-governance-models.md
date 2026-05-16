# 01 — Schema Governance Models

> **Purpose:** Define and compare the three primary organizational models for governing a GraphQL supergraph schema — centralized, federated, and hybrid — with org charts, approval workflows, required tooling, scaling ceilings, and real-world adoption examples for each.

---

## The Governance Spectrum

Schema governance answers one question: **when a team wants to change the supergraph schema, who decides if that change is safe to ship?**

The answer defines your governance model. On one end, a single team reviews all changes. On the other, each team reviews its own changes. In practice, enterprises land somewhere in between — and where you land should be a deliberate architectural decision, not the default that formed as the organization grew.

```
CENTRALIZED ◄──────────────────────────────────► FEDERATED
  One team         Platform-gated         Domain teams
  reviews all      convention review      self-approve
  changes          + domain autonomy      all changes
                        ▲
                   Hybrid model
                   (recommended)
```

---

## Model 1: Centralized Governance

### Description

A dedicated API Platform team (sometimes called the API Guild or GraphQL Center of Excellence) owns the supergraph schema. Every change to any subgraph — new type, new field, deprecation, removal — requires review and approval from this central team before it can be published to the registry.

### Org Chart

```
┌─────────────────────────────────────────────────────────────────┐
│                        API Platform Team                         │
│   Schema architects · API standards owners · Change approvers   │
│               (5–12 engineers at large orgs)                    │
└──────────┬──────────┬──────────┬──────────┬────────────────────┘
           │          │          │          │
    ┌──────▼─┐  ┌─────▼──┐  ┌───▼────┐  ┌──▼─────┐
    │ Team A │  │ Team B │  │ Team C │  │ Team D │
    │(Users) │  │(Orders)│  │(Search)│  │(Payment│
    └────────┘  └────────┘  └────────┘  └────────┘
         ↑            ↑           ↑           ↑
    Schema PRs require API Platform review and approval
```

### Approval Workflow

```
1. Domain team opens PR with schema change
2. CI runs graphql-eslint + rover subgraph check (automated)
3. CI notifies API Platform team via Slack/GitHub mention
4. API Platform engineer reviews within SLA (typically 24–48h)
5. Reviewer checks: naming, nullability, backward compat, docs
6. Approve + merge OR request changes with specific guidance
7. Merge triggers CD: publish to staging registry
8. Staging smoke tests pass → publish to production
```

**Approval SLA:** 24 hours for non-breaking changes, 72 hours for breaking changes with RFC required.

### Required Tooling

| Tool | Purpose |
|---|---|
| GitHub CODEOWNERS | Auto-assign API Platform team to all `*.graphql` files |
| `graphql-eslint` | Catch naming/doc violations before human review |
| `rover subgraph check` | Breaking change detection in CI |
| GitHub branch protection | Require `api-platform` team approval before merge |
| Schema registry (GraphOS / Hive) | Single source of truth for composed schema |

**.github/CODEOWNERS configuration:**
```
# All GraphQL schema files require API Platform approval
**/*.graphql @your-org/api-platform
**/schema.graphql @your-org/api-platform
**/subgraph/**/*.graphql @your-org/api-platform
```

### Scaling Ceiling

Centralized governance works well up to approximately **5–8 subgraphs and 20–30 engineers**. Beyond that:

- Review queue becomes a bottleneck (API Platform team becomes the critical path for every team's velocity)
- Context load on reviewers increases — they cannot maintain deep knowledge of every domain
- Time-zone coverage gaps create multi-day delays for geographically distributed teams
- Teams learn to avoid schema changes, accumulating technical debt in resolvers instead

**Signal that centralized governance is breaking down:**
- Average schema PR review time exceeds 48 hours
- Teams open PRs with 20+ field changes to batch reviews
- Engineers bypass schema changes by putting business logic in resolvers
- API Platform team headcount request every quarter

### Real-World Examples

**Shopify (early API platform):** Centralized schema review through the GraphQL Patterns team, which reviews all storefront API changes. Works because Shopify's public API team is small and domain-coherent, and the public storefront API has stricter stability requirements than internal APIs. The pattern breaks down for Shopify's internal supergraph at scale.

**Large financial services firms:** Regulatory environments (SOX, PCI) drive centralized governance because every schema change is a potential audit event. The compliance requirement for change management records creates an organizational incentive for centralization regardless of scale. These organizations invest heavily in making the review queue move faster (dedicated approvers, automated pre-screening) rather than federating.

**GitHub (internal APIs):** GitHub uses a hybrid approach today, but the early GraphQL API (v4 launch in 2016) used centralized review for the public API surface with near-zero change volume — a configuration where centralized review is straightforward.

---

## Model 2: Federated Governance

### Description

Each domain team owns its subgraph schema completely. Teams can add fields, types, and deprecations to their subgraph without approval from any other team. Composition validation (automated) is the only gate. No human review required for schema changes.

### Org Chart

```
┌─────────────────────────┐
│  Platform Team          │
│  Infra only — no schema │
│  approval role          │
└─────────────────────────┘

┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│   Team A     │  │   Team B     │  │   Team C     │  │   Team D     │
│  Users       │  │  Orders      │  │  Search      │  │  Payment     │
│              │  │              │  │              │  │              │
│ Owns User    │  │ Owns Order   │  │ Owns Search  │  │ Owns Payment │
│ subgraph     │  │ subgraph     │  │ subgraph     │  │ subgraph     │
│ schema fully │  │ schema fully │  │ schema fully │  │ schema fully │
└──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘
        ↑                ↑                ↑                ↑
  CI composition check only — no human approval gate
```

### Approval Workflow

```
1. Domain team makes schema change in their subgraph repo
2. CI runs graphql-eslint (local lint rules)
3. CI runs rover subgraph check (composition validation + breaking change detection)
4. If check passes and change is non-breaking: merge immediately
5. If change is breaking: team decides — may require internal team discussion
6. Merge triggers CD: publish to staging, then production
7. No external approval required
```

### Required Tooling

| Tool | Purpose |
|---|---|
| `graphql-eslint` with shared config | Enforce baseline naming/quality rules per subgraph |
| `rover subgraph check` | Composition validation (catches cross-subgraph breaks) |
| Shared `graphql-eslint` npm package | Distribute lint rules across all subgraph repos |
| Schema registry (GraphOS / Hive) | Detect when a change breaks composition |
| Field usage analytics | Teams can see their own field usage |

**Shared lint config distribution:**
```json
// packages/graphql-lint-config/index.js
module.exports = {
  rules: {
    "@graphql-eslint/naming-convention": ["error", {
      "FieldDefinition": { "style": "camelCase" },
      "TypeDefinition": { "style": "PascalCase" },
      "EnumValueDefinition": { "style": "UPPER_CASE" }
    }],
    "@graphql-eslint/require-description": ["error", {
      "types": true,
      "FieldDefinition": true
    }],
    "@graphql-eslint/deprecation-reason": "error"
  }
};
```

### Scaling Ceiling

Federated governance works well when:
- All teams are disciplined about naming and documentation (rare at scale)
- Schema design expertise is distributed across all teams
- There are no public API consumers with strict stability guarantees
- Cross-subgraph schema coordination is rare (low `@requires` usage)

It breaks down when:
- Teams independently create `userId`, `user_id`, and `UserID` for the same concept
- Deprecation timelines are inconsistent — some teams remove after 1 week, others never remove
- Schema quality regresses team by team (undocumented fields, missing deprecation reasons)
- A new team joins and has no guidance on schema conventions

**Real failure mode:** Two teams both extend the `User` entity with a field called `settings`. Team A's `settings` returns `UserPreferences`. Team B's `settings` returns `AccountSettings`. Composition fails. Neither team knew about the other's field because there was no coordination mechanism.

**Scaling ceiling:** Works up to ~10 subgraphs with experienced GraphQL engineers on each team. Beyond that, consistency degrades noticeably.

### Real-World Examples

**Startups and early-stage platform teams:** When there are 2–4 subgraph teams with strong GraphQL experience, federated governance is the default. The coordination overhead of centralization is not worth it.

**Internal tooling platforms:** When the API consumers are internal and can accept breaking changes with short notice, fully federated governance is acceptable. The cost of a brief breaking change is lower than the cost of review bottlenecks.

**Netflix (GraphQL Federated Platform report):** Netflix's initial federated graph used decentralized team ownership with shared lint configs as the primary consistency mechanism. They later moved toward more structured coordination as the subgraph count grew.

---

## Model 3: Hybrid Governance (Recommended)

### Description

The platform team owns **schema conventions** (naming, documentation, deprecation policy, security patterns). These conventions are enforced **automatically** in CI via linting and OPA policies — not by human reviewers. Domain teams own their **schema content** (what types and fields exist in their domain). Non-breaking, policy-compliant changes merge without human review. Human review is required only for:

1. Breaking changes (regardless of approval, must have an RFC)
2. Changes that violate automated policy (require platform team exception approval)
3. New entity types that cross subgraph boundaries (require cross-team review)
4. Changes to the API surface visible to external clients (require API Platform sign-off)

### Org Chart

```
┌─────────────────────────────────────────────────────────────────┐
│                     API Platform Team                            │
│  Owns: conventions · policies · tooling · lint config · OPA    │
│  Does NOT own: domain schema content                            │
└───────────────────────────┬─────────────────────────────────────┘
                            │ Policies enforced via CI
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│   Team A     │   │   Team B     │   │   Team C     │
│  Users       │   │  Orders      │   │  Search      │
│              │   │              │   │              │
│ Owns domain  │   │ Owns domain  │   │ Owns domain  │
│ schema       │   │ schema       │   │ schema       │
└──────────────┘   └──────────────┘   └──────────────┘
   Self-approve       Self-approve       Self-approve
   if CI passes       if CI passes       if CI passes
   Human review only for exceptions
```

### Approval Workflow

```
Additive change (new field, new type):
  1. Domain team opens PR
  2. CI: graphql-eslint → must pass (naming, docs, deprecation format)
  3. CI: rover subgraph check → must pass (composition, no breaking changes)
  4. CI: OPA policy check → must pass (security, data classification)
  5. All green → auto-merge eligible (team lead approval only, same-day)
  6. No platform team review required

Breaking change (rename, remove, type change):
  1. Domain team writes RFC (template: 02-change-management.md)
  2. RFC posted in #schema-changes Slack channel
  3. 5-business-day comment period
  4. API Platform team member approves RFC
  5. PR opened with `breaking-change-approved` label
  6. Same CI gates as above
  7. Merges after quorum approval (platform team + affected subgraph owners)

Policy exception (e.g., naming convention deviation for legacy compatibility):
  1. PR opens with `policy-exception-request` label
  2. Platform team reviews and approves/denies within 48h
  3. Exception documented in schema comment: # policy-exception: <reason>
```

### Required Tooling

| Layer | Tool | Owned By |
|---|---|---|
| Lint rules | `graphql-eslint` with shared config npm package | Platform team publishes, domain teams consume |
| Breaking change detection | `rover subgraph check` or `graphql-inspector` | CI pipeline (platform team owns CI template) |
| Policy enforcement | OPA + Conftest for schema SDL validation | Platform team |
| Schema registry | Apollo GraphOS / Hive / Cosmo | Platform team |
| Exception tracking | GitHub label + RFC document | Domain team initiates, platform team approves |
| Field usage analytics | GraphOS Studio / Hive dashboard | Available to all teams |

**OPA policy example — auto-block undocumented public types:**
```rego
package graphql.schema

deny[msg] {
  type := input.types[_]
  type.kind == "OBJECT"
  not startswith(type.name, "_")
  not type.description
  msg := sprintf("Type '%v' is missing a description. All public object types require documentation.", [type.name])
}

deny[msg] {
  type := input.types[_]
  field := type.fields[_]
  not field.description
  not field.isDeprecated
  msg := sprintf("Field '%v.%v' is missing a description.", [type.name, field.name])
}
```

### Scaling Ceiling

The hybrid model scales effectively from ~5 subgraphs to 100+ subgraphs. The key properties that enable this:

- **No human bottleneck for normal changes** — 90%+ of changes are additive and policy-compliant; they merge the same day with zero platform team involvement
- **Automated policy enforcement** — convention consistency is maintained by machines, not by reviewer knowledge
- **Human review reserved for high-stakes decisions** — platform engineers spend time on RFCs and exception reviews, not rubber-stamping compliant changes
- **Shared tooling ownership** — the platform team's value is in the lint config and CI templates, not in being the approval gate

**Signs the hybrid model is working:**
- Schema PR cycle time: under 4 hours for additive changes
- Platform team schema reviews: fewer than 5 per week across all teams
- Lint violations blocked in CI: schema violations never reach production
- Breaking change RFCs: formal process followed >95% of the time

### Real-World Examples

**Airbnb (supergraph platform):** Airbnb's platform engineering team maintains shared GraphQL conventions enforced via CI, while product teams own their domain schemas. Breaking changes go through a formal deprecation workflow tracked in the schema registry. This is the hybrid model at scale.

**Expedia Group (Apollo Federation case study):** Expedia runs 50+ subgraphs across multiple brands. The platform team owns the federation infrastructure and shared lint config; individual brand teams own their subgraph schemas and self-approve routine changes. Breaking changes require a cross-team review process.

**Stripe (API governance model):** While Stripe uses REST for its public API, its internal GraphQL supergraph follows a platform-owns-conventions, teams-own-content model. The API design guide is enforced via automated tooling rather than human review for routine changes.

---

## Governance Model Comparison

| Dimension | Centralized | Federated | Hybrid |
|---|---|---|---|
| **Human review required** | All changes | None | Exceptions + breaking changes |
| **Convention consistency** | High | Variable | High (automated) |
| **Time to merge (additive)** | 24–72h | Same day | Same day |
| **Time to merge (breaking)** | 3–7 days | Same day (risky) | 3–7 days (safe) |
| **Platform team headcount** | High | Low | Medium |
| **Scales to 50+ subgraphs** | No | Conditionally | Yes |
| **SOC 2 change management** | Straightforward | Requires supplemental controls | Requires supplemental controls |
| **Best for** | Public APIs, regulated industries | Small teams, internal APIs | Large orgs, mixed consumer types |

---

## Choosing Your Model

Use this decision tree:

```
Do you have external clients (mobile, partner) that cannot redeploy quickly?
├── Yes → Centralized or Hybrid (breaking changes must be human-reviewed)
└── No ↓

Do you have > 10 subgraphs or > 30 engineers touching schema?
├── Yes → Hybrid (centralized doesn't scale)
└── No ↓

Do you have SOC 2 Type II, HIPAA, or PCI compliance requirements?
├── Yes → Hybrid with audit trail (centralized is simpler but doesn't scale)
└── No → Federated with shared lint config is acceptable
```

Most enterprise organizations with any external API surface and more than 3 subgraph teams should implement the hybrid model. The automation investment (shared lint config + OPA policies + CI templates) pays back in review cycle time within 3 months.

---

## See Also

- [02 — Change Management](./02-change-management.md) — RFC process, breaking change policy, deprecation lifecycle
- [04 — Multi-Team Coordination](./04-multi-team-coordination.md) — Schema working group, cross-subgraph dependency tracking
- [09 — Schema Governance](../09-schema-governance/) — Technical tooling: graphql-eslint, rover CLI, graphql-inspector
- [13 — Policy as Code](../13-policy-as-code/) — OPA policies for schema validation
