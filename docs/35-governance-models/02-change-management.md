# 02 — Schema Change Management

> **Purpose:** Define the end-to-end process for managing schema changes in a production supergraph — from RFC submission through deprecation to field removal — with specific process templates, SLAs, approval quorums, and emergency procedures.

---

## Overview

Schema change management is the set of processes that ensure changes to the supergraph schema are communicated, reviewed, and executed without breaking consumers. It consists of five sub-processes:

1. **RFC process** — how supergraph-wide changes are proposed and approved
2. **Breaking change policy** — the lifecycle every breaking change must follow
3. **Schema review checklist** — the criteria a change must satisfy before merge
4. **Schema changelog** — how changes are recorded and communicated
5. **Emergency change procedure** — how to ship a critical breaking change quickly and safely

---

## 1. RFC Process

An RFC (Request for Comments) is required for any change that:

- Removes a field, type, or argument from the schema
- Renames a field or type (even with a deprecation transition)
- Changes the type of a field in a breaking way (e.g., `String` → `ID`, non-null → nullable)
- Adds a cross-subgraph entity key that requires coordination with other subgraph teams
- Changes the semantics of a field without changing its type (behavior breaking change)
- Affects the public API surface exposed to external clients

Non-breaking additive changes (new fields, new types, new optional arguments) do not require an RFC.

### RFC Template

```markdown
# RFC: [Short title of the change]

**RFC ID:** RFC-YYYY-NNN (assigned by schema registry or sequential counter)
**Status:** Draft | In Review | Approved | Rejected | Implemented
**Author:** [GitHub username]
**Subgraph(s) affected:** [e.g., users-subgraph, orders-subgraph]
**Proposed date:** YYYY-MM-DD
**Target implementation date:** YYYY-MM-DD

---

## Summary

One paragraph. What is changing and why.

## Motivation

Why is this change necessary? What problem does it solve?
Include customer impact, technical debt, or correctness issues.

## Proposed Schema Change

```graphql
# Before
type User {
  address: String  # removing — unstructured, replaced by structured type
}

# After
type User {
  address: Address  # structured type, migration required
}

type Address {
  street: String!
  city: String!
  state: String!
  postalCode: String!
  countryCode: String!
}
```

## Breaking Change Analysis

- Fields being removed: `User.address` (String)
- Clients affected: [link to field usage report from GraphOS/Hive]
- Migration path: clients must update queries to use `User.address.street`, etc.
- Estimated migration effort: [low / medium / high]

## Deprecation Plan

- Deprecation notice added: YYYY-MM-DD
- Migration guide published: YYYY-MM-DD
- Deprecated field removal target: YYYY-MM-DD (minimum 90 days from notice for external clients)
- Removal PR: [link when available]

## Alternatives Considered

What other approaches were evaluated? Why were they rejected?

## Open Questions

List any unresolved questions or decisions that require feedback.

---

## Review Sign-offs

- [ ] API Platform team: @username
- [ ] Affected subgraph owners: @username, @username
- [ ] Client team representative (if external clients affected): @username
```

### RFC Review SLA

| Change Type | Comment Period | Approval Quorum | Maximum Review Time |
|---|---|---|---|
| Breaking change, internal clients only | 3 business days | 1 platform + 1 affected team | 5 business days |
| Breaking change, external clients | 5 business days | 1 platform + 2 affected teams + 1 client rep | 10 business days |
| New cross-subgraph entity key | 3 business days | 1 platform + all affected subgraph owners | 7 business days |
| Semantic breaking change | 5 business days | 1 platform + affected team lead | 7 business days |

**Quorum definition:** All required approvers must explicitly approve (GitHub review approval or Slack thread with :white_check_mark:). Silence does not constitute approval.

### RFC Tracking

RFCs are tracked in the schema governance repository:
- GitHub Issues with label `rfc` and `schema-change` in the platform team's governance repo
- RFC ID format: `RFC-YYYY-NNN` (e.g., `RFC-2025-047`)
- RFC status is updated by the platform team as the process advances
- Closed RFCs (approved + implemented) are archived but not deleted — they form the change rationale history

---

## 2. Breaking Change Policy

### Defining Breaking Changes

A breaking change is any schema modification that causes a currently valid client query to fail or return different data. This includes:

**Hard breaking changes** (immediately cause client errors):
- Removing a field, type, argument, or directive
- Changing a field type to an incompatible type
- Making an optional argument required
- Changing a nullable field to non-null when resolvers can return null

**Soft breaking changes** (may cause client errors depending on assumptions):
- Renaming a type (clients using `__typename` checks break)
- Removing an enum value
- Changing the semantics of a field's return value
- Adding a new required field to an input type

**Non-breaking changes** (safe to merge without RFC):
- Adding a new optional field to an object type
- Adding a new type
- Adding a new optional argument
- Deprecating a field (marking `@deprecated` does not break queries)
- Adding a new enum value (though clients should handle unknown values)

### The Deprecation → Migration → Removal Lifecycle

Every breaking change must follow this lifecycle. No exceptions in production.

```
Phase 1: Deprecate (Day 0)
  ├── Add @deprecated directive with reason and migration path
  ├── Add migration guide to schema changelog
  ├── Notify consumers via Slack + email digest
  └── Start monitoring field usage in registry

Phase 2: Migration Period
  ├── Support engineers available for migration questions
  ├── Usage reported weekly in schema-changes Slack channel
  ├── Automated reminders at 30, 60, and 90 days (GitHub bot)
  └── Blockers escalated to affected team leads

Phase 3: Removal (after minimum deprecation period)
  ├── Usage must be at 0 (verified in registry) OR
  │   all remaining usage accounted for (known + intentional)
  ├── RFC approved, removal PR opened
  ├── 24h notice in #schema-changes before merge
  └── Field removed, changelog updated
```

### Minimum Deprecation Periods

| Client Type | Minimum Period | Rationale |
|---|---|---|
| Internal web clients | 30 days | Continuous deployment, fast migration |
| Internal mobile clients (auto-update) | 45 days | Update rates vary by user |
| External mobile clients (app store) | 90 days | App store review + user update lag |
| Partner API integrations | 180 days | Contract terms, change management process |
| Embedded / IoT clients | 365 days | No auto-update mechanism |

**Determining client type:** Use field usage analytics (GraphOS Studio, Hive) to identify which client IDs are calling the deprecated field. Client type is determined by the client's `apollographql-client-name` and `apollographql-client-version` headers.

### Deprecation Directive Requirements

Every deprecation must include a structured reason string:

```graphql
type User {
  # Correct — includes migration path
  legacyAddress: String @deprecated(
    reason: "Use `address { street city state postalCode }` instead. Scheduled removal: 2026-03-01. Migration guide: https://platform.internal/schema/migrations/user-address"
  )

  # Incorrect — no migration path
  legacyId: String @deprecated(reason: "Use id instead")
}
```

The `graphql-eslint` rule `@graphql-eslint/deprecation-reason` enforces that deprecation reasons are non-empty. Custom rules can enforce the structured format.

---

## 3. Schema Review Checklist

Every schema PR (even non-breaking, non-RFC changes) should satisfy this checklist before merge. In the hybrid governance model, CI enforces the automated items; the human items apply only to PRs requiring human review.

### Automated (CI-enforced)

- [ ] All new types and fields have description strings
- [ ] Field names use `camelCase`, type names use `PascalCase`, enum values use `UPPER_CASE`
- [ ] `@deprecated` fields include a structured reason with migration path and removal date
- [ ] No scalar types used where a structured type would be appropriate (e.g., `String` for `email` fields should use a custom scalar or validated type)
- [ ] `rover subgraph check` passes — no composition errors, no unintentional breaking changes
- [ ] New mutations follow the input object pattern: `mutation { createUser(input: CreateUserInput!) }` not `mutation { createUser(name: String!, email: String!) }`
- [ ] New subscriptions document the event source and delivery guarantee

### Human Review (when applicable)

- [ ] Nullability is intentional — fields that can logically be absent are nullable; fields that are always present are non-null
- [ ] No sensitive data fields (PII, PHI, CHD) added without `@tag(name: "sensitive")` annotation and security review
- [ ] Breaking change has approved RFC linked in PR description
- [ ] Cross-subgraph `@requires` dependencies reviewed with the required subgraph's owners
- [ ] New entity `@key` fields reviewed — keys should be stable, globally unique identifiers
- [ ] Input types do not accept overly broad inputs (e.g., `JSON` scalar for structured data)
- [ ] Pagination follows Connection pattern (Relay spec) for all list fields that could grow unbounded

### Naming Conventions Quick Reference

| Element | Convention | Example |
|---|---|---|
| Object type | PascalCase | `OrderLineItem` |
| Query field | camelCase verb | `userById`, `searchProducts` |
| Mutation field | camelCase verb-noun | `createUser`, `updateOrderStatus` |
| Subscription field | camelCase event noun | `orderUpdated`, `inventoryChanged` |
| Input type | PascalCase + `Input` suffix | `CreateUserInput`, `UpdateOrderInput` |
| Enum type | PascalCase | `OrderStatus` |
| Enum value | UPPER_SNAKE_CASE | `PENDING_PAYMENT`, `SHIPPED` |
| Interface | PascalCase, no `I` prefix | `Node`, `Timestamped` |
| Custom scalar | PascalCase | `DateTime`, `EmailAddress`, `UUID` |

---

## 4. Schema Changelog

### Auto-Generated Changelog

The schema changelog is generated automatically from git diff and deprecation notes on every publish to the schema registry. It is consumed by consumers to track changes over time.

**Changelog generation workflow:**

```yaml
# .github/workflows/schema-changelog.yml
name: Generate Schema Changelog

on:
  push:
    branches: [main]
    paths:
      - '**/*.graphql'

jobs:
  changelog:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2  # need previous commit for diff

      - name: Generate schema diff
        run: |
          npx graphql-inspector diff \
            "git:HEAD^:./schema.graphql" \
            "./schema.graphql" \
            --format json > diff.json

      - name: Append to CHANGELOG.md
        run: node scripts/append-changelog.js diff.json

      - name: Commit changelog
        uses: stefanzweifel/git-auto-commit-action@v5
        with:
          commit_message: "docs: update schema changelog [skip ci]"
          file_pattern: CHANGELOG.md
```

**Changelog entry format:**

```markdown
## [2025-10-15] — Orders Subgraph

### Added
- `Order.estimatedDeliveryWindow: DeliveryWindow` — Returns structured delivery window with
  earliest and latest timestamps. Previously only available as unstructured string in `estimatedDelivery`.

### Deprecated
- `Order.estimatedDelivery: String` — Use `estimatedDeliveryWindow` instead.
  Removal date: 2026-01-15. Migration guide: https://platform.internal/migrations/delivery-window

### Removed
- `Order.legacyShipDate: String` — Deprecated 2025-07-01. Field usage reached 0 on 2025-09-28.
  RFC: RFC-2025-031
```

### Deprecation Notes

Engineers add deprecation notes to the PR description using a structured format that the changelog script parses:

```markdown
<!-- DEPRECATION-NOTE
field: Order.estimatedDelivery
type: String
removal_date: 2026-01-15
migration: https://platform.internal/migrations/delivery-window
affected_clients: web-app, ios-app
-->
```

---

## 5. Communicating Changes to Consumers

### Slack Webhook on Schema Publish

Every publish to the production schema registry triggers a Slack notification to `#schema-changes`. The notification includes:

```
📋 Schema updated: orders-subgraph v1.47.0

✅ Added (2):
  • Order.estimatedDeliveryWindow: DeliveryWindow
  • DeliveryWindow type (new)

⚠️  Deprecated (1):
  • Order.estimatedDelivery — removal 2026-01-15

🔗 Full diff: https://graphos.apollo.com/...
🔗 Migration guide: https://platform.internal/...
```

**Apollo Router plugin for Slack notification:**

```javascript
// router-plugin/schema-change-notifier.js
// Triggered by GraphOS webhook on schema publish
export default async function notifySchemaChange(event) {
  const { changes, subgraph, version } = event;
  const breaking = changes.filter(c => c.criticality === 'BREAKING');
  const deprecated = changes.filter(c => c.type === 'FIELD_DEPRECATION_ADDED');

  await fetch(process.env.SLACK_WEBHOOK_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      text: formatSchemaChangeMessage(subgraph, version, changes, breaking, deprecated)
    })
  });
}
```

### Email Digest for Deprecations

A weekly email digest summarizes all active deprecations and their removal timelines. This targets engineering managers and client team leads who may not monitor `#schema-changes` daily.

**Digest content:**
- New deprecations added this week (with migration guide links)
- Deprecations reaching their 30-day reminder (alert for teams to start migration)
- Deprecations reaching their 60-day reminder (escalation to team leads)
- Deprecations reaching their 90-day reminder (final notice, removal imminent)
- Fields removed this week

The digest is generated by a scheduled job that queries the schema registry's deprecation database and sends via SendGrid or internal email infrastructure.

### Consumer Notification Matrix

| Change Type | Slack #schema-changes | Email Digest | GitHub Issue | Direct Team Ping |
|---|---|---|---|---|
| New field added | Yes | No | No | No |
| Field deprecated | Yes | Yes (weekly) | Optional | If high-traffic field |
| Breaking change approved | Yes | Yes | Yes | Yes — all affected teams |
| Field removed | Yes | Yes | Close existing issue | Yes |
| Composition error | Yes (immediate) | No | No | Yes — subgraph owner |

---

## 6. Emergency Change Procedure

### When to Use

An emergency change procedure applies when:

- A field is exposing sensitive data that was never intended to be accessible
- A field is causing cascading failures in production (resolver throws, causing supergraph errors)
- A security vulnerability requires immediate removal of a field or type
- Legal/compliance requires immediate data removal (GDPR erasure, court order)

Emergency changes skip the normal RFC comment period and deprecation period, but they must follow a post-incident review process.

### Emergency Change Steps

```
Step 1: Declare the emergency (< 15 minutes)
  ├── Post in #incidents: "Emergency schema change in progress for [reason]"
  ├── Page the on-call platform engineer
  └── Open a GitHub Issue with label: emergency-schema-change

Step 2: Assess impact (< 30 minutes)
  ├── Check field usage in GraphOS/Hive (how many clients are calling this field?)
  ├── Identify all clients that will break when the field is removed
  └── Document in the GitHub Issue

Step 3: Communicate to affected teams (before making the change)
  ├── Direct Slack DM to affected team leads
  ├── Post in #schema-changes: "Emergency removal of [field] in [X] minutes"
  └── If external clients: notify partner relations team

Step 4: Execute the change (< 1 hour from declaration)
  ├── Open PR with [emergency] prefix in title
  ├── CI must still pass (graphql-eslint, composition check)
  ├── PR requires: 1 platform team approval + 1 subgraph owner approval
  └── Merge and publish to production

Step 5: Post-incident review (within 48 hours)
  ├── Document: why was emergency procedure required?
  ├── Document: what was the impact on clients?
  ├── Document: what would have prevented this?
  └── Publish retrospective to #postmortems
```

### Emergency Change SLA

- Time from declaration to production change: target < 2 hours, maximum 4 hours for security-critical changes
- Post-incident review: within 48 hours
- Retrospective published: within 5 business days

### Post-Incident Review Template

```markdown
# Emergency Schema Change Retrospective

**Date:** YYYY-MM-DD
**Field(s) removed:** [list]
**Declared by:** @username
**Resolved by:** @username

## Timeline
- HH:MM — [event]
- HH:MM — [event]

## Root Cause
Why was emergency removal required?

## Impact
- Clients affected: [count and names]
- Downtime / errors caused: [duration, error count]

## What Went Well

## What Could Be Improved

## Action Items
- [ ] [Specific action, owner, due date]
```

---

## See Also

- [01 — Schema Governance Models](./01-schema-governance-models.md) — Which model determines who follows this process
- [03 — Compliance and Audit](./03-compliance-and-audit.md) — How change management maps to SOC 2 controls
- [04 — Multi-Team Coordination](./04-multi-team-coordination.md) — Deprecation coordination across 50+ teams
- [09 — Schema Governance](../09-schema-governance/) — Technical tooling for breaking change detection
