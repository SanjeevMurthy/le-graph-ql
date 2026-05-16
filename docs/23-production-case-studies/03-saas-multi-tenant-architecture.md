# Case Study 03 — SaaS Multi-Tenant Schema Customization

> **Industry:** B2B SaaS (CRM / Customer Data Platform)
> **Scale:** 500 enterprise customers, single codebase, each tenant with custom fields and data models
> **Core challenge:** Expose per-tenant schema customizations without separate deployments or API versions
> **Migration duration:** 11 months
> **Outcome summary:** Single codebase serves 500 distinct tenant schemas, 40% reduction in API surface area for free-tier tenants, zero schema deployment incidents in 6 months post-migration

---

## Context

A B2B SaaS company operated a CRM and customer data platform serving 500 enterprise customers.
The product had a shared data model (contacts, companies, deals, activities, notes, segments)
extended by per-tenant customizations. Tenants could define custom fields on any entity. An
enterprise financial services customer might add `aum`, `relationship_tier`, and
`compliance_status` to the Contact object. A healthcare customer might add `npi_number`,
`specialty`, and `payer_network`. A retail customer might add `lifetime_value_bucket`,
`preferred_channel`, and `last_purchase_date`.

At migration start, the platform had:
- **500 enterprise tenants**, each with between 0 and 340 custom fields
- **2.3 million total custom field definitions** across all tenants
- **A single codebase** deployed as one application (shared infrastructure, partitioned data)
- **A feature tiering model**: free tier, professional tier, enterprise tier — each tier had
  access to different sets of base schema fields

The platform also supported **app marketplace integrations**: third-party apps built on
the platform's API could add their own fields to tenant objects, scoped to tenants that
had installed the app.

---

## Problem

### REST APIs Returning Irrelevant Fields for Most Tenants

The REST API for a Contact returned every field that any tenant had ever defined, for every
tenant. A GET `/contacts/123` response on a free-tier account returned 180 fields — of which
that account could actually use 23 (the base schema minus the enterprise-only fields). The
remaining 157 fields were present but empty, or present and populated with data from other
tenants if the field isolation was not implemented correctly (this was the root cause of two
data incidents in the 12 months before the migration).

Mobile clients on free-tier accounts were downloading and parsing responses seven times
larger than necessary. On low-bandwidth connections, contact list queries were the leading
cause of mobile app ANRs (Application Not Responding).

### Custom Field Proliferation Causing Schema Drift

The REST API had no concept of a typed custom field. Custom fields were returned in a
`customFields` map: `{"customFields": {"aum": "5000000", "tier": "gold", ...}}`. All values
were strings. Clients were responsible for knowing which custom fields existed for their
tenant and what type each field had.

This meant client applications maintained a local schema registry in application code.
The React SPA had a `customFieldRegistry.js` file that was manually updated by a developer
when a customer support ticket requested a custom field addition. The registry was
frequently out of date. Support tickets for "my custom field isn't showing up correctly"
were the top category in the customer support queue.

### No Tenant-Specific Schema Without Separate Deployments

Larger customers increasingly wanted first-class GraphQL APIs with proper typed schemas
for their custom fields — not a string map. Two enterprise customers had requested GraphQL
APIs as a procurement requirement. The platform had no way to expose a typed GraphQL schema
for custom fields without generating a separate GraphQL deployment per tenant, which was
operationally infeasible at 500 tenants and would require a separate deployment pipeline
for every custom field addition.

---

## Constraints

**No separate deployment per tenant.** The business model was shared infrastructure. A
deployment-per-tenant model would require 500x the operational overhead and was cost-
prohibitive.

**No schema breaking changes for existing tenants.** 500 tenants had existing API
integrations. Breaking changes to the base schema were not acceptable without a 90-day
deprecation notice period enforced contractually.

**Feature tier enforcement must be in the API layer.** Free-tier tenants must not be able
to access enterprise-tier fields, even if they know the field name. This cannot rely on
the client not sending the field — it must be enforced server-side.

**App marketplace integrations have independent release cycles.** Third-party app
developers deploy their field definitions independently of the platform. The schema must
be updatable without restarting the router.

**DataLoader isolation.** Custom fields often came from separate storage systems (a
custom field store, separate from the CRM store). DataLoader batching must not mix custom
field loads across tenant boundaries, even if two tenants happen to define a field with
the same name.

---

## Solution

The architecture uses Apollo Federation with schema contracts for feature tiering,
per-tenant schema extensions via the `@tag` directive and contract schemas, and a custom
scalar type for tenant-specific field values.

### Architecture Diagram

```mermaid
graph TD
    subgraph "Client Tier"
        freeTenant["Free-Tier Tenant\n(SPA + mobile)"]
        proTenant["Pro-Tier Tenant\n(SPA + API integration)"]
        entTenant["Enterprise Tenant\n(SPA + API + custom fields)"]
        appDev["Marketplace App Developer\n(third-party API)"]
    end

    subgraph "Contract Routing"
        contractRouter["Contract Router\n(per-tier contract schema)"]
    end

    subgraph "Supergraph Layer"
        coreRouter["Core Router\n(full supergraph)"]
        tenantContext["Tenant Context Middleware\n(inject tenant + tier from JWT)"]
    end

    subgraph "Subgraphs"
        contacts["Contacts Subgraph"]
        deals["Deals Subgraph"]
        activities["Activities Subgraph"]
        customFields["Custom Fields Subgraph\n(per-tenant field store)"]
        marketplace["Marketplace Subgraph\n(app field extensions)"]
        identity["Identity Subgraph"]
    end

    subgraph "Schema Infrastructure"
        graphos["Apollo GraphOS\n(schema registry + contracts)"]
        pqStore["Persisted Query Store\n(per-tenant operation registry)"]
        tenantSchemaCache["Tenant Schema Cache\n(Redis — tenant field definitions)"]
    end

    freeTenant --> contractRouter
    proTenant --> contractRouter
    entTenant --> contractRouter
    appDev --> contractRouter

    contractRouter --> tenantContext
    tenantContext --> coreRouter

    coreRouter --> contacts
    coreRouter --> deals
    coreRouter --> activities
    coreRouter --> customFields
    coreRouter --> marketplace
    coreRouter --> identity

    graphos --> coreRouter
    customFields --> tenantSchemaCache
    marketplace --> tenantSchemaCache
    pqStore --> contractRouter

    classDef client fill:#dbeafe,stroke:#3B82F6,color:#1e3a8a
    classDef router fill:#e8f4f8,stroke:#0ea5e9,color:#0c4a6e
    classDef subgraph fill:#f0fdf4,stroke:#22c55e,color:#14532d
    classDef infra fill:#fdf4ff,stroke:#a855f7,color:#581c87

    class freeTenant,proTenant,entTenant,appDev client
    class contractRouter,tenantContext,coreRouter router
    class contacts,deals,activities,customFields,marketplace,identity subgraph
    class graphos,pqStore,tenantSchemaCache infra
```

### Schema Contracts for Feature Tiers

Apollo Federation `@tag` directives mark fields by feature tier. Contract schemas are
generated for each tier, exposing only the fields that tier is allowed to access.

```graphql
# contacts subgraph — full schema with tags
type Contact @key(fields: "id") {
  # Base fields — all tiers
  id: ID!
  email: String! @tag(name: "free") @tag(name: "professional") @tag(name: "enterprise")
  firstName: String @tag(name: "free") @tag(name: "professional") @tag(name: "enterprise")
  lastName: String @tag(name: "free") @tag(name: "professional") @tag(name: "enterprise")
  phone: String @tag(name: "free") @tag(name: "professional") @tag(name: "enterprise")
  createdAt: DateTime! @tag(name: "free") @tag(name: "professional") @tag(name: "enterprise")

  # Professional-tier fields
  segments: [Segment!]! @tag(name: "professional") @tag(name: "enterprise")
  enrichmentData: EnrichmentData @tag(name: "professional") @tag(name: "enterprise")
  score: Int @tag(name: "professional") @tag(name: "enterprise")

  # Enterprise-tier fields
  customFields: [CustomFieldValue!]! @tag(name: "enterprise")
  dataGovernanceLabel: DataLabel @tag(name: "enterprise")
  auditHistory: [AuditEntry!]! @tag(name: "enterprise")
}
```

Apollo GraphOS generates three contract schemas from this base schema — one per `@tag`
value. The `free` contract schema contains only the fields tagged `free`. The router for
each tier serves only the corresponding contract schema.

A free-tier tenant cannot introspect the professional or enterprise fields, cannot request
them in a query (the schema does not include them), and receives a `FIELD_NOT_FOUND` error
if somehow the request arrives with those fields.

### Per-Tenant Custom Fields via Dynamic Schema Extensions

Custom fields are the hardest part. A tenant defines a custom field (name, type, validation
rules) through the admin UI. That field must immediately be queryable via GraphQL with the
correct type. The schema cannot require a recompose + redeploy for each field addition.

The solution uses a **custom scalar type** for tenant-specific field values combined with
a **field introspection resolver** that returns the tenant's field schema:

```graphql
# custom fields subgraph
scalar TenantFieldValue  # Can be String, Int, Float, Boolean, or a JSON object

type CustomFieldDefinition {
  key: String!
  label: String!
  fieldType: CustomFieldType!
  isRequired: Boolean!
  options: [String!]     # For SELECT and MULTI_SELECT field types
  validationRules: CustomFieldValidation
}

enum CustomFieldType {
  TEXT
  NUMBER
  BOOLEAN
  DATE
  SELECT
  MULTI_SELECT
  RELATION
}

type CustomFieldValue {
  definition: CustomFieldDefinition!
  value: TenantFieldValue
}

type Contact @key(fields: "id") {
  id: ID! @external
  customFields(keys: [String!]): [CustomFieldValue!]!
  customFieldSchema: [CustomFieldDefinition!]!  # Introspection: what fields exist for this tenant?
}
```

The `customFields` resolver loads only the fields requested (via the `keys` argument or
all fields if no argument). It uses a DataLoader keyed by `(tenantId, contactId)` to batch
loads across multiple contacts in a list query, while ensuring strict tenant isolation:
the DataLoader key includes the tenantId, so two tenants with identically named custom
fields are never batched together.

The `customFieldSchema` resolver returns the tenant's field definitions from the tenant
schema cache (Redis), allowing clients to build dynamic forms without maintaining a
local field registry. This eliminated the `customFieldRegistry.js` maintenance burden.

### DataLoader with Tenant Isolation Key

The DataLoader pattern for custom fields is critical to correctness:

```typescript
// custom-fields.dataloader.ts
interface CustomFieldBatchKey {
  tenantId: string;
  contactId: string;
}

// Serialized key for DataLoader deduplication
function keyFn(key: CustomFieldBatchKey): string {
  return `${key.tenantId}:${key.contactId}`;
}

// Batch function — only called with keys from a single request context
// The request context always contains exactly one tenantId (from JWT)
async function batchLoadCustomFields(
  keys: readonly CustomFieldBatchKey[]
): Promise<CustomFieldValue[][]> {
  // Safety check: all keys must belong to the same tenant
  const tenantIds = new Set(keys.map(k => k.tenantId));
  if (tenantIds.size > 1) {
    throw new Error(
      `CustomFieldDataLoader received keys from multiple tenants: ${[...tenantIds].join(', ')}`
    );
  }

  const tenantId = keys[0].tenantId;
  const contactIds = keys.map(k => k.contactId);

  // Batch query: SELECT * FROM custom_field_values
  //   WHERE tenant_id = $1 AND entity_id = ANY($2)
  const rows = await db.query(
    `SELECT entity_id, field_key, field_value
     FROM custom_field_values
     WHERE tenant_id = $1 AND entity_id = ANY($2)`,
    [tenantId, contactIds]
  );

  // Map results back to input order
  return contactIds.map(id =>
    rows.filter(r => r.entity_id === id).map(toCustomFieldValue)
  );
}

// DataLoader is instantiated per-request (never shared across requests)
export function createCustomFieldLoader() {
  return new DataLoader(batchLoadCustomFields, { cacheKeyFn: keyFn });
}
```

The DataLoader is instantiated per-request, not as a module-level singleton. This ensures
that even if a process handles two concurrent requests from different tenants, their
DataLoader instances are isolated. The safety check (panic if keys from multiple tenants
appear) is a defense-in-depth measure that would catch a DataLoader lifecycle bug before
it could cause a data incident.

### Persisted Operations Scoped Per Tenant

Enterprise tenants building API integrations register persisted operations through the
admin UI. These operations are scoped to their tenant: a persisted operation registered
by tenant A cannot be executed by tenant B, even if the operation ID is somehow obtained.

```yaml
# router.yaml — per-tenant persisted query enforcement
persisted_queries:
  enabled: true
  safelist:
    enabled: true
    require_id: true

# The persisted query list is fetched from GraphOS per tenant,
# resolved at request time using the tenant_id from JWT
```

Marketplace app developers register their operations through a separate developer portal,
scoped to the app. When a tenant installs the app, the app's registered operations are
added to that tenant's allowed operation list.

---

## Multi-Tenancy Patterns

### Request-Scoped Tenant Context via Baggage

The tenant context (tenant ID, feature tier, installed apps) is injected by the
authentication middleware and propagated across all subgraph calls via OpenTelemetry
baggage headers. No subgraph needs to re-fetch tenant context from a database — it is
available in the incoming request headers.

```yaml
# router.yaml — propagate tenant context as headers to all subgraphs
headers:
  all:
    request:
      - propagate:
          named: "x-tenant-id"
      - propagate:
          named: "x-tenant-tier"
      - propagate:
          named: "x-installed-apps"
```

### Per-Tenant Rate Limits

Rate limits are enforced per tenant with tier-based default limits and
per-tenant overrides:

```yaml
# router.yaml
traffic_shaping:
  router:
    rate_limiting:
      enabled: true
      storage:
        type: redis
        url: "redis://rate-limit-redis:6379"
      levels:
        - header: "x-tenant-id"
          limits:
            - capacity: 100    # free tier default (ops/sec)
              interval: 1s
              condition: "request.header('x-tenant-tier') == 'free'"
            - capacity: 500
              interval: 1s
              condition: "request.header('x-tenant-tier') == 'professional'"
            - capacity: 2000
              interval: 1s
              condition: "request.header('x-tenant-tier') == 'enterprise'"
```

Enterprise tenants with negotiated higher limits have their tenant ID in a Redis set
that maps to a custom limit. The rate limiter checks the custom set before applying
the tier default.

### Per-Tenant Complexity Budgets

Enterprise tenants building complex integrations are allocated a higher query complexity
budget than free-tier tenants. The complexity limit is checked at the router level before
any subgraph call:

```yaml
limits:
  # Per-tier complexity budgets (enforced in router coprocessor via tenant-tier header)
  # Free:           200  — basic queries only
  # Professional:   500  — list queries with nested relations
  # Enterprise:    1500  — complex cross-object queries
  max_query_complexity: 1500  # Absolute cap; per-tier is enforced in coprocessor
```

---

## Trade-offs Accepted

**The `TenantFieldValue` custom scalar degrades static type safety.** Clients that want
full type safety for custom fields must call `customFieldSchema` first to learn field
types, then interpret `TenantFieldValue` accordingly. This is worse than having typed
fields, but generating typed SDL per-tenant (the alternative) requires per-tenant schema
composition — which requires per-tenant router or a very complex schema routing layer.
The team accepted the scalar trade-off as the lesser evil.

**Schema contracts require tags on every field.** The `@tag` approach requires every new
field in every subgraph to be tagged with the appropriate tier. This is a discipline
requirement enforced by a schema lint rule in CI. When a field is added without a tag,
the lint check fails. But it is still a process overhead that did not exist before.

**Tenant schema cache is eventually consistent.** When a tenant adds a custom field
through the admin UI, the custom fields subgraph's cache is invalidated. There is a brief
window (under 5 seconds, typically under 500ms) where the field exists in the database
but is not yet returned by `customFieldSchema`. The team accepted this because the
alternative (synchronous cache invalidation blocking the admin UI action) would add
latency to a user-facing write operation.

---

## Outcome

Measured 90 days post-migration:

| Metric | Before | After |
|---|---|---|
| Number of active tenant schemas served | 1 (monolithic) | 500 (per-tenant contract) |
| Contact API response size for free-tier tenants | 180 fields average | 23 fields (free contract only) |
| Mobile ANR rate attributed to contact list queries | 3.2/1000 sessions | 0.4/1000 sessions |
| Custom field support tickets per month | 340 average | 41 average |
| Schema deployment incidents in 6 months post | N/A | 0 |
| API surface reduction for free-tier tenants | Baseline | 40% reduction in exposed fields |

The reduction in custom field support tickets was the outcome the customer success team
found most significant. The `customFieldSchema` introspection resolver eliminated the
need for the manual `customFieldRegistry.js` maintenance process entirely. Customers now
use the API to introspect their own schema rather than filing tickets.

---

## What We Would Do Differently

**Start with the `@tag` discipline enforced in CI from day one.** Several early subgraphs
were added without comprehensive tagging, and auditing them retroactively required reading
every field and making a tiering decision under time pressure. The schema lint rule should
have been in place before the first subgraph was merged.

**Build the marketplace app field extension model before general availability.** The
marketplace integration model was bolted on after the core migration was complete. It
required a second pass of schema redesign for the marketplace subgraph. Having a clear
model for third-party field extensions from the beginning would have avoided this.

---

## References and Related Topics

- [Schema Governance](../09-schema-governance/README.md) — `@tag`, contract schemas, breaking change policy
- [Federation](../07-federation/README.md) — entity resolution, subgraph patterns
- [Security](../05-security/README.md) — multi-tenant authorization patterns
- [Policy as Code](../13-policy-as-code/README.md) — per-tenant rate limiting via OPA
- [Performance and Scaling](../06-performance-and-scaling/README.md) — DataLoader isolation, per-tenant batching
- [Migration Playbook](./05-platform-migration-playbook.md) — incremental migration, rollback criteria
