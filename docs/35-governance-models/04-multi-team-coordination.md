# 04 — Multi-Team Coordination

> **Purpose:** Define the coordination mechanisms, processes, and tooling that make a GraphQL supergraph governable across 50+ teams — schema working group structure, deprecation coordination, cross-subgraph dependency tracking, breaking change impact analysis, and schema style enforcement at scale.

---

## The Coordination Problem at Scale

At 5 subgraph teams, coordination is largely informal — a Slack message before making a cross-subgraph change, a shared Notion doc for naming conventions, a weekly team sync. At 50+ teams, informal coordination breaks down in predictable ways:

- **Schema drift**: Team A calls it `userId`, Team B calls it `user_id`, Team C calls it `authorId` for the same concept
- **Silent dependencies**: Team A adds `@requires(fields: "inventory { stockLevel }")` from Team B's subgraph without notifying them; Team B's schema refactor breaks Team A's subgraph
- **Deprecation abandonment**: Fields are deprecated but never removed because no one has visibility into which clients are still using them
- **Design duplication**: Three teams independently design pagination patterns for their list fields, producing three incompatible implementations
- **RFC bottleneck**: When coordination happens only through the platform team, 50+ teams create more RFCs than the platform team can review

This document defines the mechanisms that replace informal coordination with engineered coordination — systems that scale with team count rather than platform team headcount.

---

## 1. Schema Working Group

### Structure

The Schema Working Group (SWG) is a standing forum for cross-team schema decisions. It does not replace the platform team but extends the governance capacity of the organization.

**Membership:**
- **Rotating domain representatives**: one engineer from each domain team cluster (e.g., commerce domain = Orders + Inventory + Catalog teams; a single rep covers all three). Representatives rotate quarterly to spread schema knowledge across teams.
- **Platform team facilitator**: owns the agenda, records decisions, maintains the SWG charter. Does not cast deciding votes on domain schema questions.
- **Client team liaison**: optional but recommended when mobile or partner teams are consumers of the supergraph.

**SWG size target:** 8–15 members. Smaller: insufficient coverage. Larger: decision-making becomes unwieldy.

**Meeting cadence:**
- **Weekly**: 30 minutes, async-first (decisions made in Slack/GitHub before the meeting; meeting is for unresolved discussions only)
- **Monthly**: 60 minutes, schema roadmap review, convention updates, retrospective

### Responsibilities

| Responsibility | Frequency | Owner |
|---|---|---|
| Review and approve RFC documents above threshold | Per RFC | SWG quorum |
| Update shared schema style guide | As needed | Platform facilitator + proposing rep |
| Review and resolve cross-subgraph entity key conflicts | As needed | Affected team reps + platform |
| Monthly schema health report | Monthly | Platform facilitator |
| Onboard new subgraph teams to schema conventions | As needed | Rotating rep from similar domain |
| Resolve naming convention disputes | As needed | SWG vote |

### Decision-Making Protocol

**Lazy consensus**: If a proposal is posted in `#schema-working-group` and no objections are raised within 3 business days, it is considered approved.

**Active vote**: Any SWG member can call for an active vote by posting `@swg-vote`. Requires majority of attending representatives (>50%) within 5 business days.

**Platform team veto**: The platform team can veto any SWG decision that violates an established technical constraint (e.g., composition incompatibility, security policy). Vetoes must be accompanied by a specific technical justification and a proposed alternative.

### SWG Charter Template

```markdown
# Schema Working Group Charter

**Version:** 1.0
**Effective date:** YYYY-MM-DD
**Next review:** YYYY-MM-DD

## Purpose
The Schema Working Group ensures consistent, consumer-friendly schema evolution
across all subgraphs in the [Company] supergraph.

## Scope
All subgraphs in production. New subgraphs must be presented to the SWG before
their first production deployment.

## Membership
[List of current representatives and their domains]
[Rotation schedule]

## Meeting Schedule
- Weekly sync: [Day, Time, Video link]
- Monthly roadmap: [Day, Time, Video link]
- Emergency session: called by any SWG member via #schema-working-group

## Decision Process
[Lazy consensus, active vote, veto procedures — as described above]

## Escalation
Unresolved SWG disputes escalate to [VP Engineering / CTO / specific named role].
```

---

## 2. Deprecation Coordination at Scale

### 30-60-90 Day Timeline with Automated Reminders

Every deprecated field triggers an automated lifecycle managed by a GitHub bot (or similar automation). The lifecycle runs from the day `@deprecated` is merged to the registry.

```
Day 0: @deprecated merged → GitHub Issue created automatically
       Issue title: "[DEPRECATION] User.legacyAddress → removal target 2026-01-15"
       Issue body: auto-generated from schema change diff
       Labels: deprecation, schema-change, affected:web-app, affected:ios-app
       Assigned to: field-owning team + affected client teams

Day 1: Slack notification to #schema-changes + affected team channels

Day 30: GitHub bot comments on issue with usage report
        "30-day check: User.legacyAddress still used by 3 clients (312 req/day)
         Migration guide: [link]. Please start migration."

Day 60: GitHub bot comments + @mentions team leads
        "60-day check: User.legacyAddress still used by 2 clients (180 req/day)
         Migration at 33% completion. Removal target in 30 days.
         Escalating to: @team-lead-web, @team-lead-ios"

Day 90: GitHub bot comments + creates child issues per affected team
        "90-day check: User.legacyAddress still used by 1 client (45 req/day)
         Removal is blocked. Creating tracking issues in affected team repos."

Day 90+: Removal blocked until field usage reaches 0
         Weekly reminder until cleared
         Removal date slips + new target date set if usage persists
```

**GitHub bot implementation sketch:**

```javascript
// scripts/deprecation-bot.js
// Runs as a GitHub Actions scheduled job (daily)

async function checkDeprecationTimelines() {
  const deprecations = await schemaRegistry.getActiveDeprecations();

  for (const dep of deprecations) {
    const daysSinceDeprecation = daysSince(dep.deprecatedAt);
    const usage = await fieldUsageService.getDailyUsage(dep.fieldPath, 7); // 7-day avg

    if (daysSinceDeprecation >= 90 && usage > 0) {
      await createBlockingIssue(dep, usage);
      await notifyTeamLeads(dep, usage);
    } else if (daysSinceDeprecation >= 60 && usage > 0) {
      await postReminderComment(dep, usage, '60-day');
      await mentionTeamLeads(dep);
    } else if (daysSinceDeprecation >= 30 && usage > 0) {
      await postReminderComment(dep, usage, '30-day');
    } else if (usage === 0) {
      await markReadyForRemoval(dep);
    }
  }
}
```

### Deprecation Dashboard

The deprecation dashboard provides a real-time view of all active deprecations, their age, current usage, and blocking status. It is a required tool for the SWG monthly review.

**Dashboard columns:**

| Field | Subgraph | Deprecated | Current Usage | Target Removal | Status |
|---|---|---|---|---|---|
| `User.legacyAddress` | users | 2025-07-01 | 45 req/day | 2025-10-01 | Blocked |
| `Order.estimatedDelivery` | orders | 2025-09-01 | 0 req/day | 2026-01-01 | Ready to remove |
| `Product.legacyCategory` | catalog | 2025-10-15 | 1,200 req/day | 2026-01-15 | On track |

---

## 3. Cross-Subgraph Dependency Tracking

### Why Cross-Subgraph Dependencies Are High Risk

In a federated supergraph, subgraph A can declare `@requires` fields from subgraph B's entity. This creates a runtime dependency: if subgraph B changes or removes the field that A `@requires`, subgraph A's queries will fail — even though subgraph B's composition may succeed independently.

Composition validation catches direct schema incompatibilities. It does not catch semantic changes to `@requires` fields that break the resolver logic in the depending subgraph.

**Example dependency:**

```graphql
# orders-subgraph
type Product @key(fields: "id") {
  id: ID! @external
  inventory: ProductInventory @external  # from catalog-subgraph

  # orders-subgraph @requires catalog-subgraph's inventory field
  availableForBackorder: Boolean! @requires(fields: "inventory { stockLevel backorderAllowed }")
}

# catalog-subgraph
type Product @key(fields: "id") {
  id: ID!
  inventory: ProductInventory!
}

type ProductInventory {
  stockLevel: Int!
  backorderAllowed: Boolean!
  # If catalog team removes backorderAllowed, orders-subgraph breaks silently at runtime
}
```

### Automated Dependency Graph

A tooling script analyzes all subgraph schemas and builds a dependency graph of `@requires` and `@external` relationships. The graph is:

1. Generated on every schema change
2. Published to the platform team's governance dashboard
3. Consulted during any RFC that modifies `@key` or `@external` fields

**Dependency graph generation:**

```typescript
// scripts/cross-subgraph-deps.ts

interface SubgraphDependency {
  dependentSubgraph: string;
  requiredSubgraph: string;
  fieldPath: string;     // e.g., "Product.inventory.stockLevel"
  via: '@requires' | '@external' | 'entity-extension';
  addedAt: string;
}

async function buildDependencyGraph(subgraphs: SubgraphSchema[]): Promise<DependencyGraph> {
  const deps: SubgraphDependency[] = [];

  for (const subgraph of subgraphs) {
    const requires = extractRequiresDirectives(subgraph.schema);
    for (const req of requires) {
      const owningSubgraph = findFieldOwner(req.fieldPath, subgraphs);
      deps.push({
        dependentSubgraph: subgraph.name,
        requiredSubgraph: owningSubgraph,
        fieldPath: req.fieldPath,
        via: '@requires',
        addedAt: req.addedAt,
      });
    }
  }

  return buildGraph(deps);
}

// Output example:
// orders-subgraph → catalog-subgraph (via @requires: Product.inventory.stockLevel, Product.inventory.backorderAllowed)
// recommendations-subgraph → users-subgraph (via @requires: User.purchaseHistory.categoryIds)
// pricing-subgraph → catalog-subgraph (via @requires: Product.cost)
```

### Dependency Notification on Schema Change

When a schema change modifies a field that other subgraphs `@require`, the CI pipeline automatically identifies and notifies the dependent subgraph teams:

```yaml
# .github/workflows/check-cross-subgraph-impact.yml
- name: Check cross-subgraph impact
  run: |
    CHANGED_FIELDS=$(npx graphql-inspector diff \
      "git:HEAD^:./schema.graphql" \
      "./schema.graphql" \
      --format json | jq -r '.changes[].path')

    DEPENDENT_TEAMS=$(node scripts/find-dependents.js "$CHANGED_FIELDS")

    if [ -n "$DEPENDENT_TEAMS" ]; then
      echo "::warning::This change affects fields @required by: $DEPENDENT_TEAMS"
      echo "DEPENDENT_TEAMS=$DEPENDENT_TEAMS" >> $GITHUB_ENV
    fi

- name: Notify dependent teams
  if: env.DEPENDENT_TEAMS != ''
  uses: slackapi/slack-github-action@v1
  with:
    payload: |
      {
        "text": "Schema change in ${{ github.repository }} affects dependent subgraphs: ${{ env.DEPENDENT_TEAMS }}. Review required before merge."
      }
```

---

## 4. Breaking Change Impact Analysis

### GraphOS Field Usage for Pre-Removal Verification

Before removing any deprecated field, the owning team must run a field usage analysis to confirm that all clients have migrated. Apollo GraphOS and Hive both provide field-level usage analytics with client-level breakdowns.

**Pre-removal checklist:**

```markdown
## Pre-Removal Field Usage Report

**Field:** User.legacyAddress
**Subgraph:** users-subgraph
**Deprecated:** 2025-07-01
**Proposed removal:** 2025-10-01

### Usage Report (last 30 days)
- Total requests: 0
- Unique clients: 0
- Last request: 2025-09-18 (12 days ago)

### Client Migration Status
- [x] web-app v4.2.0 — migrated 2025-09-10
- [x] ios-app v6.1.0 — migrated 2025-09-15
- [x] legacy-admin v1.3.0 — migrated 2025-09-18

### Sign-off
- [ ] Subgraph owner: @username
- [ ] Platform team: @username
```

**GraphOS CLI command to generate usage report:**

```bash
# Get field usage for the last 30 days
rover graph introspect my-graph@production \
  --field-usage "User.legacyAddress" \
  --from "2025-09-01" \
  --to "2025-10-01"
```

### Client Impact Matrix

For planned breaking changes with an approved RFC, create a client impact matrix before any migration work begins:

```markdown
## Client Impact Matrix: Order.estimatedDelivery → estimatedDeliveryWindow

| Client | Usage (req/day) | Team Lead | Migration Target | Status |
|---|---|---|---|---|
| web-storefront | 8,400 | @frontend-lead | 2025-12-01 | Not started |
| ios-app | 3,200 | @mobile-ios-lead | 2025-12-15 | In progress |
| android-app | 2,800 | @mobile-android-lead | 2025-12-15 | Not started |
| partner-api-acme | 450 | @partner-integrations | 2026-01-01 | Notified |
| internal-reporting | 180 | @analytics-lead | 2025-11-15 | Complete |
```

---

## 5. Schema Office Hours

### Structure

Schema office hours is a weekly open forum where any engineer can ask questions about GraphQL API design, get feedback on schema proposals, or request guidance on cross-subgraph patterns. It is not a decision-making body — it is a knowledge distribution mechanism.

**Format:**
- **Frequency:** Weekly, 45 minutes
- **Facilitator:** Rotating platform team engineer
- **Format:** Open queue — engineers bring specific questions or draft schemas for review
- **Recording:** Sessions are recorded and linked in `#schema-office-hours` for async consumption
- **Notes:** Brief notes posted in Slack after each session (top 3 topics + decisions/guidance given)

**Standing agenda items (if no specific questions):**
1. Recent schema changes worth discussing (5 min)
2. Upcoming breaking changes affecting multiple teams (10 min)
3. Open discussion / schema review (30 min)

**Sample office hours questions:**
- "I need to paginate a large list of inventory items — should I use Relay-style connections or a simpler offset approach?"
- "We want to add a `User.settings` field — I see another team already has `User.preferences`. How do we resolve this?"
- "Our team is adding a third-party payments subgraph. What entity patterns should we use for `PaymentMethod`?"

### Office Hours vs RFC

| Question Type | Use Office Hours | Use RFC |
|---|---|---|
| "What's the right pattern for X?" | Yes | No |
| "Feedback on my draft schema?" | Yes | No |
| "Removing a field that 3 teams use" | No | Yes |
| "Adding a new entity key" | First, then RFC | After getting design input |
| "Naming convention question" | Yes | No (follow convention or propose update) |

---

## 6. Schema Style Guide Enforcement at Scale

### Automated Enforcement via graphql-eslint in CI

The schema style guide is enforced by `graphql-eslint` configured with the platform team's shared rule set. All subgraph repositories inherit the same configuration via a shared npm package.

```json
// packages/graphql-lint-config/package.json
{
  "name": "@your-org/graphql-lint-config",
  "version": "2.1.0",
  "description": "Shared graphql-eslint configuration for all supergraph subgraphs",
  "main": "index.js",
  "peerDependencies": {
    "@graphql-eslint/eslint-plugin": "^3.0.0"
  }
}
```

```javascript
// packages/graphql-lint-config/index.js
module.exports = {
  rules: {
    // Naming conventions
    "@graphql-eslint/naming-convention": ["error", {
      "FieldDefinition": { "style": "camelCase" },
      "TypeDefinition": { "style": "PascalCase" },
      "EnumValueDefinition": { "style": "UPPER_CASE" },
      "ArgumentDefinition": { "style": "camelCase" },
      "InputValueDefinition": { "style": "camelCase" }
    }],

    // Documentation requirements
    "@graphql-eslint/require-description": ["error", {
      "types": true,
      "FieldDefinition": true,
      "DirectiveDefinition": true
    }],

    // Deprecation quality
    "@graphql-eslint/deprecation-reason": "error",

    // Input type patterns
    "@graphql-eslint/input-name": ["error", {
      "checkInputType": true,
      "caseSensitiveInputType": true
    }],

    // Relay pagination pattern enforcement
    "@graphql-eslint/relay-connection-types": "warn",

    // Avoid catch-all types
    "@graphql-eslint/no-scalar-result-type-on-mutation": "warn",

    // Security: no introspection in production schema
    "@graphql-eslint/no-typename-prefix": "error"
  }
};
```

**Subgraph `.eslintrc.js`:**

```javascript
// In each subgraph repository
module.exports = {
  overrides: [
    {
      files: ["**/*.graphql"],
      parser: "@graphql-eslint/eslint-plugin",
      plugins: ["@graphql-eslint"],
      extends: ["plugin:@graphql-eslint/schema-recommended"],
      rules: {
        ...require("@your-org/graphql-lint-config").rules,
        // Subgraph-specific overrides allowed for documented exceptions
        // "@graphql-eslint/require-description": ["warn"] // only if subgraph has exemption
      }
    }
  ]
};
```

### Style Guide Version Management

The shared lint config is versioned. Breaking changes to lint rules (new error-level rules) require:

1. RFC to the SWG (treated as a supergraph-wide convention change)
2. One-month migration period where new rule is `warn` before becoming `error`
3. Platform team support available during migration (office hours + #schema-help)

Version bumps are announced in `#schema-changes` and `#engineering-announcements`.

---

## Coordination Mechanisms at a Glance

| Mechanism | Purpose | Frequency | Scale |
|---|---|---|---|
| Schema Working Group | Cross-team decisions, RFC review | Weekly | Required at 10+ subgraphs |
| Deprecation automation | Enforce deprecation timeline | Daily bot | Required at 5+ subgraphs |
| Dependency graph | Visibility into @requires chains | Per schema change | Required at 10+ subgraphs |
| Impact analysis | Pre-removal client verification | Per removal RFC | Required always |
| Office hours | Design guidance, knowledge distribution | Weekly | Valuable at 5+ subgraphs |
| Style guide automation | Naming/quality consistency | Per PR | Required at 3+ subgraphs |

---

## See Also

- [01 — Schema Governance Models](./01-schema-governance-models.md) — Working group fits into the hybrid governance model
- [02 — Change Management](./02-change-management.md) — RFC process that the SWG reviews
- [09 — Schema Governance](../09-schema-governance/) — Technical tooling for schema registry and field usage
- [19 — Platform Engineering](../19-platform-engineering/) — Golden path templates include lint config setup for new subgraphs
