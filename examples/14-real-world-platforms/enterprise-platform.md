# Enterprise GraphQL Platform Reference Architecture

Companion docs: `../../docs/25-enterprise-patterns/`, `../../docs/23-production-case-studies/`

---

## Context

This reference architecture is designed for a large enterprise with the following characteristics:

- 300-1,000+ engineers across 30-60 product and platform teams
- 50-150 subgraphs covering multiple product lines, integrations, and internal domains
- A dedicated GraphQL Platform Team with 6-10 engineers
- Compliance requirements: SOC 2 Type II, and possibly HIPAA, PCI-DSS, or ISO 27001
- Multi-region production deployment serving global customers
- Investment horizon: 3-5 years. Architectural decisions are made for durability, not speed.

At enterprise scale, the primary challenges shift from "how do we build this" to "how do we govern this." Schema drift, breaking change propagation, security posture, and organizational coordination dominate the roadmap. This architecture addresses each of those challenges explicitly.

---

## 1. Team Topology — RACI Matrix

The GraphQL Platform Team owns the infrastructure and tooling; product teams own the content. This separation is critical for scaling governance without creating a centralized bottleneck.

### Platform Team Responsibilities

| Responsibility | Role | Notes |
|---|---|---|
| Apollo Router configuration and deployment | Platform Team | Owns the router fleet: capacity, tuning, upgrades |
| Apollo GraphOS account and variants | Platform Team | Controls registry access, schema approval settings |
| Schema governance tooling | Platform Team | Reviews tooling, lint rules, enforcement automation |
| Breaking change escalation process | Platform Team | Defines the process; product teams execute it |
| Developer tooling (codegen, VSCode extensions) | Platform Team | Publishes and maintains internal npm packages |
| Security posture (persisted queries, mTLS, OPA) | Platform Team | Designs and enforces; security team audits |
| On-call for the router fleet | Platform Team | Subgraphs are owned by product teams |
| GraphQL SDK and library maintenance | Platform Team | Wraps Apollo dependencies for internal consistency |

### Product Team Responsibilities

| Responsibility | Role | Notes |
|---|---|---|
| Subgraph schema design | Product Team | Platform Team reviews, does not approve unilaterally |
| Resolver implementation | Product Team | Full ownership |
| DataLoader implementation | Product Team | Platform Team provides helper libraries |
| Subgraph deployment | Product Team | Using platform-provided Helm chart or Terraform module |
| Subgraph on-call | Product Team | Router issues escalate to Platform Team |
| Schema RFC submission | Product Team | For breaking or large changes |
| Operation registration (client teams) | Product Team (client) | All client operations registered in GraphOS |

### RACI Summary

| Decision | Platform Team | Product Team | Security Team | Architecture Review |
|---|---|---|---|---|
| New subgraph creation | A/R | R | I | C |
| Breaking schema change | A | R | I | C |
| Router version upgrade | R/A | I | I | I |
| New auth mechanism | A | C | A/R | C |
| New custom directive | A/R | C | I | C |
| Subgraph service account | C | R | A | I |

R = Responsible, A = Accountable, C = Consulted, I = Informed

---

## 2. Multi-Environment Strategy

Enterprise platforms require a validated promotion pipeline where changes move through environments in order. No change goes directly to production.

```
dev (variant: dev)
  -> staging (variant: staging)
  -> canary (variant: canary, receives 5% of traffic)
  -> production (variant: main)
```

### Environment Characteristics

| Environment | Purpose | Schema Checks | Traffic | Data |
|---|---|---|---|---|
| `dev` | Development and integration testing | None | Synthetic only | Sanitized copy of prod, refreshed weekly |
| `staging` | Pre-production validation, QA | Against `staging` variant | Synthetic + QA team | Sanitized production snapshot |
| `canary` | Gradual rollout, early production signal | Against `main` variant | 5% real production traffic | Live production data |
| `production` | Full traffic | N/A (schema already deployed) | 100% real traffic | Live production data |

### Promotion Pipeline

```yaml
# .github/workflows/promote.yml
# Triggered when a schema change passes checks in the lower environment
# and a human approves the promotion via GitHub Environments protection rules.

name: Schema Promotion Pipeline

on:
  workflow_dispatch:
    inputs:
      subgraph:
        description: 'Subgraph name to promote'
        required: true
      from_variant:
        description: 'Source variant (staging or canary)'
        required: true
        type: choice
        options: [staging, canary]
      to_variant:
        description: 'Target variant (canary or main)'
        required: true
        type: choice
        options: [canary, main]

jobs:
  validate-promotion:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Schema compatibility check
        run: |
          rover subgraph check $GRAPH_ID@${{ inputs.to_variant }} \
            --name ${{ inputs.subgraph }} \
            --schema subgraphs/${{ inputs.subgraph }}/src/schema.graphql

      - name: Run smoke tests against target environment
        run: |
          npm run test:smoke -- \
            --env ${{ inputs.to_variant }} \
            --subgraph ${{ inputs.subgraph }}

  promote:
    needs: validate-promotion
    runs-on: ubuntu-latest
    # GitHub Environments protection rule requires approval from
    # the Platform Team before this job runs for canary->main promotions.
    environment:
      name: ${{ inputs.to_variant == 'main' && 'production' || 'canary' }}
    steps:
      - name: Publish schema to target variant
        run: |
          rover subgraph publish $GRAPH_ID@${{ inputs.to_variant }} \
            --name ${{ inputs.subgraph }} \
            --schema subgraphs/${{ inputs.subgraph }}/src/schema.graphql \
            --routing-url https://${{ inputs.subgraph }}.${{ inputs.to_variant }}.internal.example.com/graphql
```

---

## 3. Supergraph Composition Governance — Schema RFC Process

At enterprise scale, breaking schema changes require a formal review process. Uncoordinated breaking changes are the most common source of production incidents in federated GraphQL platforms.

### Change Classification

| Change Type | Review Required | Lead Time Required | Example |
|---|---|---|---|
| Non-breaking addition | Champion review | Same sprint | Adding a new optional field |
| Deprecation | Champion + Platform | 2 weeks | Marking a field `@deprecated` |
| Breaking change | RFC + Platform + Architecture | 8 weeks minimum | Removing a field |
| New subgraph | RFC + Platform | 4 weeks | New domain integration |
| Custom directive | RFC + Platform + Tooling | 4 weeks | New schema annotation |

### RFC Template

```markdown
# Schema RFC: [Title]

## Status
Draft | Under Review | Approved | Implemented | Withdrawn

## Summary
One paragraph describing the proposed schema change.

## Motivation
Why is this change needed? What problem does it solve?
Link to any relevant product requirements or engineering issues.

## Proposed Schema Change

\`\`\`graphql
# Before
type Product {
  price: Float!  # Current field
}

# After
type Product {
  price: Money!  # New type — breaking change
}
\`\`\`

## Impact Analysis
- Affected subgraphs: [list]
- Affected client operations: [list from Apollo Studio or graphql-inspector]
- Breaking: Yes/No — if yes, explain migration path

## Migration Plan
How will existing clients migrate? What is the timeline?
How will we communicate the change?

## Deprecation Timeline
If deprecating: what is the remove-by date? (minimum 90 days from deprecation)
Who is tracking compliance?

## Alternatives Considered
What other approaches were considered and why were they rejected?
```

### Deprecation Tracking Automation

```typescript
// scripts/deprecation-tracker.ts
// Scans the supergraph SDL for deprecated fields and checks if any
// have exceeded the 90-day deprecation window without being removed.
// Run in CI on every schema publish.

import { buildSchema, parse, visit } from 'graphql';
import * as fs from 'fs';

const DEPRECATION_SLA_DAYS = 90;

interface DeprecatedField {
  type: string;
  field: string;
  reason: string;
  deprecatedSince?: Date;
  removeBy?: Date;
  overdue: boolean;
}

// Parses the removal date from the deprecation reason string.
// Convention: @deprecated(reason: "Use X instead. Remove by 2025-03-01")
function parseRemoveByDate(reason: string): Date | undefined {
  const match = reason.match(/[Rr]emove by (\d{4}-\d{2}-\d{2})/);
  return match ? new Date(match[1]) : undefined;
}

const schemaSDL = fs.readFileSync('./supergraph.graphql', 'utf-8');
const schema = buildSchema(schemaSDL);
const overdueFields: DeprecatedField[] = [];

const typeMap = schema.getTypeMap();
for (const [typeName, type] of Object.entries(typeMap)) {
  if (typeName.startsWith('__')) continue; // Skip introspection types
  if (!('getFields' in type)) continue;    // Skip non-object types

  const fields = (type as any).getFields();
  for (const [fieldName, field] of Object.entries(fields as any)) {
    const deprecationReason = (field as any).deprecationReason;
    if (!deprecationReason) continue;

    const removeBy = parseRemoveByDate(deprecationReason);
    const overdue = removeBy ? removeBy < new Date() : false;

    if (overdue) {
      overdueFields.push({
        type: typeName,
        field: fieldName,
        reason: deprecationReason,
        removeBy,
        overdue: true,
      });
    }
  }
}

if (overdueFields.length > 0) {
  console.error('\nDeprecation SLA violations:');
  console.table(overdueFields);
  console.error(
    '\nThe above fields have passed their scheduled removal date. ' +
    'Open schema RFCs to remove them or extend the deadline with justification.'
  );
  process.exit(1);
}

console.log('No deprecation SLA violations found.');
```

---

## 4. Internal Developer Portal — Backstage Integration

At enterprise scale, discoverability of subgraphs and their schemas becomes a significant problem. Engineers spend time asking "which subgraph owns the `Order` type?" or "what fields are available on `Customer`?" A developer portal solves this.

Backstage (backstage.io) is the most widely adopted internal developer portal framework. The GraphQL plugin for Backstage (community-maintained) can display schema documentation, field-level descriptions, and ownership metadata.

```yaml
# catalog/components/products-subgraph.yaml
# Backstage catalog entry for a subgraph component.
# Commit this file alongside the subgraph code.

apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: products-subgraph
  description: Product catalog subgraph — manages product data, variants, reviews, and recommendations
  annotations:
    # Links Backstage to Apollo GraphOS for schema introspection
    apollographql.com/graph-ref: my-graph@main
    apollographql.com/subgraph-name: products
    # Links to the GitHub team that owns this subgraph
    github.com/team-slug: core-product
    # Links to runbook for on-call
    pagerduty.com/service-id: P12345
  tags:
    - graphql
    - subgraph
    - products
spec:
  type: graphql-subgraph
  lifecycle: production
  owner: team:core-product
  system: supergraph
  dependsOn:
    - resource:products-db
    - resource:recommendations-service
    - resource:inventory-service
```

When the Backstage GraphQL plugin is installed, it:

1. Reads the `apollographql.com/graph-ref` annotation and calls `rover graph introspect` to fetch the current schema
2. Renders the schema as browsable documentation in Backstage (types, fields, descriptions, deprecations)
3. Shows the owning team (from `owner:`) for each component, enabling engineers to find the right team for questions

---

## 5. Security Posture

Enterprise platforms require a layered security model. Each layer handles a different threat class.

### Persisted Queries in Production

In production, the Apollo Router is configured to reject all ad-hoc queries and only execute operations from the approved manifest:

```yaml
# router.yaml
persisted_queries:
  enabled: true
  safelist:
    enabled: true
    # Block all requests that are not in the manifest.
    # In development and staging, set this to false to allow ad-hoc queries.
    require_id: true
  log_unknown: true  # Log rejected queries for security monitoring
```

The persisted query manifest is built during CI/CD by extracting all `gql` tagged templates from client code and hashing them. Only queries in the manifest execute in production. This eliminates injection attacks, query fuzzing, and most DoS vectors targeting query complexity.

### JWT Authentication at the Router

```yaml
# router.yaml
authentication:
  router:
    jwt:
      jwks:
        - url: https://auth.example.com/.well-known/jwks.json
          poll_interval: 60s  # Refresh signing keys every 60 seconds
      # Extract claims from the token and forward them to subgraphs
      # as request headers. Subgraphs trust these headers because
      # traffic reaches them only through the router (mTLS enforced).
      header_value_prefix: "Bearer"
      # Reject requests with expired tokens
      clock_skew: "30s"
```

### OPA Policy Gate in CI

Open Policy Agent policies run in CI before any schema change reaches the registry:

```rego
# policies/schema-governance.rego
package graphql.schema

# Deny schema changes that add fields to PII types without a @pii directive
deny[msg] {
  input.change.type == "FIELD_ADDED"
  pii_types[input.change.parentType]
  not has_pii_directive(input.change.field)
  msg := sprintf(
    "Field %s.%s added to a PII type without @pii directive. Add @pii to enable field-level audit logging.",
    [input.change.parentType, input.change.field]
  )
}

pii_types := {"User", "Customer", "Employee", "PaymentMethod"}

has_pii_directive(field) {
  field.directives[_].name == "pii"
}
```

### mTLS Between Router and Subgraphs

In Kubernetes deployments, mTLS is enforced between the router and all subgraphs using a service mesh (Istio or Linkerd). Subgraphs verify that incoming requests have a valid certificate from the router's service account and reject all other traffic. This prevents direct subgraph access from within the cluster.

```yaml
# istio/peer-authentication.yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: subgraph-strict-mtls
  namespace: graphql
spec:
  # All pods in the graphql namespace must use mTLS
  mtls:
    mode: STRICT
```

### Field-Level Audit Logging for PII

```typescript
// src/plugins/pii-audit-plugin.ts
import type { ApolloServerPlugin } from '@apollo/server';
import { auditLogger } from '../observability/audit-logger';

// Fields annotated with @pii in the schema are logged when accessed.
// The @pii directive triggers this plugin to record who accessed the field,
// from what operation, and at what time.
//
// Audit logs go to a separate, append-only log stream that feeds into the
// SIEM. They are not mixed with application logs to prevent accidental
// modification or deletion.

export const piiAuditPlugin: ApolloServerPlugin = {
  async requestDidStart({ request, contextValue }) {
    return {
      async executionDidStart() {
        return {
          willResolveField({ info, source }) {
            // Check if this field has the @pii directive
            const fieldDef = info.parentType.getFields()[info.fieldName];
            const hasPii = fieldDef?.astNode?.directives?.some(
              (d) => d.name.value === 'pii'
            );

            if (hasPii) {
              auditLogger.log({
                event: 'pii_field_accessed',
                field: `${info.parentType.name}.${info.fieldName}`,
                operationName: request.operationName ?? 'anonymous',
                userId: (contextValue as any).user?.id,
                requestId: request.http?.headers.get('x-request-id'),
                timestamp: new Date().toISOString(),
              });
            }
          },
        };
      },
    };
  },
};
```

---

## 6. Multi-Cluster Deployment

Enterprise platforms serve global customers and require geographic distribution for latency and availability. The same supergraph is deployed across multiple regions.

### Cluster Architecture

```
us-east-1 (primary)
  - Apollo Router fleet (3-10 replicas)
  - Subgraph services (each in their own deployment)
  - Regional PostgreSQL primary
  - Redis cluster for entity cache

eu-west-1 (secondary)
  - Apollo Router fleet (2-5 replicas)
  - Subgraph services (read-optimized)
  - PostgreSQL read replica (writes route to us-east-1)
  - Redis cluster for entity cache

ap-southeast-1 (secondary)
  - Same as eu-west-1
```

### Schema Change Atomicity Across Clusters

When a schema change is deployed, all clusters must apply it simultaneously or in rapid succession to prevent routing inconsistencies where a client hits the us-east-1 router (new schema) and then the eu-west-1 router (old schema) for the same session.

The deployment pipeline enforces this:

1. Schema is published to Apollo GraphOS (single source of truth)
2. All Router fleets poll GraphOS for schema updates on a 10-second interval
3. Schema changes propagate to all clusters within 30 seconds of publication
4. Application code changes deploy using a phased rollout: us-east-1 first (canary), then all regions simultaneously after 15 minutes if no errors

### Global Traffic Manager Configuration

```yaml
# cloudflare-load-balancer.yaml (conceptual)
# Route clients to the nearest healthy cluster.
# Apollo Router's /health endpoint is used for health checks.
load_balancer:
  pools:
    - name: us-east-1
      origins:
        - address: router-us-east-1.example.com
      health_check:
        path: /health
        interval: 10s
        threshold: 2  # Mark unhealthy after 2 failures
    - name: eu-west-1
      origins:
        - address: router-eu-west-1.example.com
      health_check:
        path: /health
        interval: 10s
        threshold: 2
    - name: ap-southeast-1
      origins:
        - address: router-ap-southeast-1.example.com
      health_check:
        path: /health
        interval: 10s
        threshold: 2

  routing:
    strategy: nearest  # Route to geographically nearest healthy pool
    fallback: us-east-1  # All traffic routes here if all others are down
```

---

## 7. Incident Playbooks

### Subgraph Degradation

**Symptoms:** Increased error rate on fields owned by one subgraph. Other fields continue resolving normally. Apollo Studio shows errors isolated to one subgraph.

**Immediate Response:**

1. Confirm the affected subgraph via Apollo Studio's field error breakdown
2. Check the subgraph's health endpoint: `curl https://<subgraph>.internal.example.com/health`
3. Check the subgraph's Kubernetes pod status: `kubectl get pods -n graphql -l subgraph=<name>`
4. If the subgraph is down, Apollo Router falls back to partial query execution: fields owned by the degraded subgraph return errors with code `DOWNSTREAM_SERVICE_ERROR`; fields owned by healthy subgraphs continue resolving
5. Notify the owning product team via the on-call pager
6. Consider applying a temporary schema override to hide the degraded subgraph's fields from the router while the subgraph recovers (prevents error noise for clients)

**Router Configuration for Graceful Degradation:**

```yaml
# router.yaml
traffic_shaping:
  all:
    # Allow the router to continue serving partial responses when
    # a subgraph is timing out or returning errors.
    # Without this, a subgraph timeout would fail the entire query.
    deduplicate_variables: true

  subgraphs:
    inventory:
      # Inventory service is known to be slower — give it more time
      # before the router marks the request as failed.
      timeout: 5s
    recommendations:
      # Recommendations is non-critical — fail fast so it doesn't
      # degrade the overall query latency.
      timeout: 2s
```

### Schema Hotfix Process

When a schema bug reaches production (a field that throws errors, a type mismatch, a resolver panic), the hotfix process is:

1. Reproduce in staging — confirm the bug and the fix in staging before touching production
2. Tag the fix as a "hotfix" in the commit message and PR title
3. Skip the canary stage if the bug is already in production and the fix is low risk (documented exception to the promotion pipeline)
4. Platform Team approval bypasses the standard 24-hour canary soak for hotfixes
5. Post-mortem within 5 business days per the standard incident process

---

## 8. Cost Optimization

At enterprise scale, GraphQL infrastructure costs are significant. The main cost levers:

### Entity Cache Hit Rate

The Apollo Router entity cache stores the results of `_entities` queries from subgraphs. A high hit rate means fewer subgraph calls, lower database load, and lower router CPU usage.

Track the entity cache hit rate per entity type. Types with < 50% hit rate need investigation:
- Is the cache TTL too short?
- Is the cache key too granular (including user-specific data that should not be cached)?
- Is the entity invalidation pattern too aggressive?

Target: entity cache hit rate > 80% for read-heavy entity types.

### N+1 Pattern Elimination

Each unresolved N+1 pattern multiplies database load by the page size of any list that contains the offending field. At enterprise scale, eliminating one N+1 pattern on a high-traffic field can reduce database load by 10-100x.

Use Apollo Studio's field-level tracing to identify the highest-cost resolvers. For each resolver in the top 20 by total execution time, verify it uses DataLoader.

### Query Complexity Budget Per Team

Assign each product team a "complexity budget" for their subgraph — the sum of all complexity costs that their subgraph contributes to the P99 query complexity score. Teams that want to add expensive fields must offset the cost by optimizing existing fields (adding caching, switching to DataLoader, improving database query patterns).

This creates an organizational incentive for teams to keep their subgraphs efficient rather than assuming that the platform's overall capacity will absorb any cost.

---

## Key Design Decisions

**Why the platform team does not own product subgraphs:** A central team that owns all subgraphs is a bottleneck that blocks product teams. The platform team's value is in the infrastructure, tooling, and governance framework — not in writing product resolvers. Product teams need full ownership and autonomy to ship fast. The RACI matrix makes this boundary explicit and prevents scope creep in both directions.

**Why 5% canary rather than blue/green:** Blue/green deployments double the infrastructure cost and require instant cutover. Canary allows gradual validation of schema changes against real production traffic with the ability to halt the rollout at any point. For schema changes (which are not compute-intensive to apply), canary is strictly better than blue/green.

**Why OPA in CI rather than at the router:** An OPA gate at the router checks authorization on every request — appropriate for dynamic access control. An OPA gate in CI checks schema governance policies at schema design time — appropriate for structural and compliance policies like "PII fields must have the @pii directive." Running governance policies in CI means they catch issues before they reach production, not after. Both are needed; they solve different problems.

---

## Related Documentation

- `../../docs/25-enterprise-patterns/` — Multi-tenancy, compliance, regulated industry considerations
- `../../docs/09-schema-governance/` — Detailed RFC process and breaking change management
- `../../docs/13-policy-as-code/` — OPA policy implementation for GraphQL schema governance
- `../../docs/15-kubernetes-deployment/` — Kubernetes deployment patterns for Apollo Router and subgraphs
- `../../docs/16-service-mesh-integration/` — Istio and Linkerd integration for mTLS and traffic shaping
