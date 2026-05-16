# 35 — Governance Models

> **Purpose:** Define the organizational models, processes, and compliance frameworks that govern a GraphQL supergraph at enterprise scale. This section moves from the technical governance tooling in section 09 to the human systems — who approves changes, how teams coordinate across organizational boundaries, and how compliance requirements map to GraphQL-specific controls.

---

## Why Governance Models Matter

Technical governance tooling (linters, schema registries, breaking change detectors) is necessary but not sufficient. The tools enforce policy — they do not define who owns policy, how policy exceptions are handled, or what happens when two teams disagree about a schema design. At scale, those human coordination failures cause more outages than technical failures.

The four documents in this section address governance as a sociotechnical system: the org structure, the processes, the compliance mappings, and the multi-team coordination mechanisms that make a supergraph governable across 50+ teams.

---

## When to Use This Section

| Situation | Start Here |
|---|---|
| Defining who reviews schema changes | [01-schema-governance-models.md](./01-schema-governance-models.md) |
| Building an RFC and change management process | [02-change-management.md](./02-change-management.md) |
| SOC 2, GDPR, HIPAA, or PCI DSS audit preparation | [03-compliance-and-audit.md](./03-compliance-and-audit.md) |
| Scaling governance beyond 10 teams | [04-multi-team-coordination.md](./04-multi-team-coordination.md) |

---

## Contents

| File | Topic | Estimated Read |
|---|---|---|
| `README.md` (this file) | Orientation and navigation | 5 min |
| [01-schema-governance-models.md](./01-schema-governance-models.md) | Centralized, federated, and hybrid org models — org charts, approval workflows, tooling, scaling ceilings | 25 min |
| [02-change-management.md](./02-change-management.md) | RFC process, breaking change policy, deprecation lifecycle, schema changelog, emergency procedures | 25 min |
| [03-compliance-and-audit.md](./03-compliance-and-audit.md) | SOC 2 Type II, GDPR, HIPAA, PCI DSS controls mapped to GraphQL — audit log schema, field classification | 30 min |
| [04-multi-team-coordination.md](./04-multi-team-coordination.md) | Schema working group, 30-60-90 deprecation timeline, cross-subgraph dependency tracking, office hours | 25 min |

---

## Governance Stack Overview

The governance models in this section operate on top of the technical tooling from sections 09–13. The relationship:

```
┌─────────────────────────────────────────────────────────────────┐
│                  Organizational Governance (Section 35)          │
│   Who approves · RFC process · Compliance controls · WG        │
├─────────────────────────────────────────────────────────────────┤
│               Policy Enforcement (Sections 10–13)               │
│   graphql-eslint · rover check · OPA · GitHub Actions          │
├─────────────────────────────────────────────────────────────────┤
│               Schema Registry (Sections 07–09)                  │
│   GraphOS / Hive / Cosmo · Composition · Field usage analytics │
├─────────────────────────────────────────────────────────────────┤
│                  Supergraph Infrastructure (Section 08)          │
│   Apollo Router · Subgraph services · Kubernetes               │
└─────────────────────────────────────────────────────────────────┘
```

Human governance sits at the top of this stack. It sets the policies that the technical layers enforce. A well-designed governance model makes the technical enforcement nearly invisible to teams following the rules, while creating clear signals for the rare cases that require human judgment.

---

## Prerequisites

- **[07 — Federation](../07-federation/)** — Federation concepts, subgraphs, and supergraph composition are assumed knowledge throughout this section.
- **[08 — Supergraph Architecture](../08-supergraph-architecture/)** — Schema registry, query planning, and router architecture provide the infrastructure context.
- **[09 — Schema Governance](../09-schema-governance/)** — The technical governance framework (graphql-eslint, rover CLI, graphql-inspector) this section extends with organizational models.
- **[13 — Policy as Code](../13-policy-as-code/)** — OPA policies for schema validation are referenced in the hybrid governance model.

---

## Key Principles

**Governance should be invisible for compliant changes.** An engineer making an additive, well-named, documented change should never interact with a human reviewer. Automated CI passes; the change merges. Human review gates exist only for policy exceptions.

**Policy lives in code, not in documents.** Every governance rule in this section has a corresponding enforcement implementation. A rule that lives only in a wiki is a suggestion.

**Compliance is not a separate workstream.** SOC 2, GDPR, and HIPAA requirements are mapped to specific schema design patterns and resolver implementations — they are part of the build, not an audit activity performed after the fact.

**Coordination costs compound at scale.** The multi-team coordination mechanisms in section 04 are not optional at 50+ teams. Without them, teams duplicate schema concepts, create conflicting naming patterns, and break each other's subgraphs without knowing it.
