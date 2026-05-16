# System Design Interview Questions

> **Purpose:** Full 45-minute format walkthroughs for the four most common GraphQL system design scenarios at staff and principal engineer level. Each scenario follows the same structure the interviewer expects: requirements gathering, schema design, architecture decisions, trade-off discussion, and common follow-up questions. These scenarios test whether you can translate business requirements into a coherent technical design under time pressure.

---

## How to Use This File

In a live interview, the system design round follows this cadence:
1. **Clarify requirements (5–8 min)** — ask about scale, consistency, access patterns, clients, and constraints before touching any design artifact. Interviewers penalize candidates who jump to solution before understanding the problem.
2. **Sketch high-level architecture (5 min)** — subgraphs, router, key backing services.
3. **Design the schema (15 min)** — types, queries, mutations, subscriptions, error handling.
4. **Deep dive on one area (10 min)** — the interviewer will pick the most technically interesting part of your design to probe deeply.
5. **Trade-off discussion (5–8 min)** — alternatives you considered and why you made your choices.

Practice each scenario out loud. The verbal reasoning is what interviewers score.

---

## Scenario 1: Design a Real-Time Collaborative Document Editor API

### Requirements Gathering — Questions to Ask

- How many concurrent editors per document? (10, 100, 10,000?)
- Is this Google Docs-style (character-level collaboration) or Notion-style (block-level collaboration)?
- Do we need offline support with eventual sync, or real-time only?
- What consistency model is required for conflict resolution? Last-write-wins, OT, or CRDTs?
- Who are the clients? Web only, or also mobile and third-party integrations?
- Is there a document version history requirement?
- What's the expected document size? (Character limit? Asset embeds?)

**Assumed answers for this walkthrough:** Block-level Notion-style collaboration, 50 concurrent users per document, real-time only (no offline), OT-based conflict resolution, web + mobile clients, full version history, documents up to 500 blocks.

### Schema Design

```graphql
# ─── Document Types ──────────────────────────────────────────────────────────

type Document @key(fields: "id") {
  id: ID!
  title: String!
  owner: User!
  collaborators(first: Int = 20, after: String): CollaboratorConnection!
  blocks(first: Int = 100, after: String): BlockConnection!
  version: Int!
  isPublic: Boolean!
  permissions: DocumentPermissions!
  createdAt: DateTime!
  updatedAt: DateTime!
}

"""
Content block — the atomic unit of a document. One paragraph, one heading,
one image, one table, etc. Using a polymorphic type over a flat document string
enables per-block locking and conflict resolution.
"""
interface Block {
  id: ID!
  document: Document!
  position: Float!    # Fractional indexing for O(1) reorder without renumbering
  createdBy: User!
  createdAt: DateTime!
  updatedAt: DateTime!
  version: Int!
}

type ParagraphBlock implements Block {
  id: ID!
  document: Document!
  position: Float!
  createdBy: User!
  createdAt: DateTime!
  updatedAt: DateTime!
  version: Int!
  content: String!
  formatting: [TextFormat!]!
}

type HeadingBlock implements Block {
  id: ID!
  document: Document!
  position: Float!
  createdBy: User!
  createdAt: DateTime!
  updatedAt: DateTime!
  version: Int!
  content: String!
  level: HeadingLevel!
}

type ImageBlock implements Block {
  id: ID!
  document: Document!
  position: Float!
  createdBy: User!
  createdAt: DateTime!
  updatedAt: DateTime!
  version: Int!
  url: String!
  altText: String
  caption: String
  width: Int
  height: Int
}

type CodeBlock implements Block {
  id: ID!
  document: Document!
  position: Float!
  createdBy: User!
  createdAt: DateTime!
  updatedAt: DateTime!
  version: Int!
  content: String!
  language: String
  isEditable: Boolean!
}

enum HeadingLevel { H1, H2, H3, H4, H5, H6 }

# ─── Presence / Cursor ──────────────────────────────────────────────────────

"""
Where a collaborator's cursor is currently positioned within the document.
Used to render colored cursor indicators.
"""
type CollaboratorPresence {
  user: User!
  documentId: ID!
  blockId: ID
  cursorOffset: Int
  selection: TextSelection
  lastSeenAt: DateTime!
}

type TextSelection {
  startOffset: Int!
  endOffset: Int!
}

# ─── Queries ────────────────────────────────────────────────────────────────

type Query {
  document(id: ID!): Document
  myDocuments(first: Int = 20, after: String): DocumentConnection!
  documentPresence(documentId: ID!): [CollaboratorPresence!]!
}

# ─── Mutations ──────────────────────────────────────────────────────────────

type Mutation {
  createDocument(input: CreateDocumentInput!): CreateDocumentResult!
  updateDocumentTitle(input: UpdateDocumentTitleInput!): UpdateDocumentTitleResult!
  applyBlockOperation(input: ApplyBlockOperationInput!): ApplyBlockOperationResult!
  addCollaborator(input: AddCollaboratorInput!): AddCollaboratorResult!
  updatePresence(input: UpdatePresenceInput!): UpdatePresenceResult!
}

input ApplyBlockOperationInput {
  documentId: ID!
  """
  The operation to apply. The server uses OT to transform against
  concurrent operations before applying.
  """
  operation: BlockOperationInput!
  """
  The document version the client had when it generated this operation.
  Used for OT transformation.
  """
  baseVersion: Int!
}

input BlockOperationInput {
  type: BlockOperationType!
  blockId: ID
  blockType: BlockType
  position: Float
  content: String
  attributes: JSON
}

enum BlockOperationType {
  INSERT_BLOCK
  UPDATE_BLOCK
  DELETE_BLOCK
  MOVE_BLOCK
}

union ApplyBlockOperationResult =
  | ApplyBlockOperationSuccess
  | ConflictError
  | PermissionError

type ApplyBlockOperationSuccess {
  """
  The transformed operation as applied by the server.
  Client uses this to reconcile its local state.
  """
  appliedOperation: BlockOperation!
  newVersion: Int!
  document: Document!
}

type ConflictError {
  message: String!
  code: String!
  """
  Operations the client needs to replay on top of to converge with server state.
  """
  serverOperationsSince: [BlockOperation!]!
  currentVersion: Int!
}

# ─── Subscriptions ──────────────────────────────────────────────────────────

type Subscription {
  """
  Streams all operations applied to a document in order.
  Clients that fall behind receive a batch of missed operations.
  """
  documentOperations(documentId: ID!): DocumentOperationEvent!

  """
  Streams presence updates — cursor movements, user join/leave.
  Higher frequency than document operations; separate subscription allows
  different client sampling rates.
  """
  documentPresence(documentId: ID!): PresenceEvent!
}

type DocumentOperationEvent {
  operation: BlockOperation!
  appliedBy: User!
  version: Int!
  timestamp: DateTime!
}

type PresenceEvent {
  type: PresenceEventType!
  presence: CollaboratorPresence!
}

enum PresenceEventType {
  CURSOR_MOVED
  SELECTION_CHANGED
  USER_JOINED
  USER_LEFT
  USER_IDLE
}
```

### Architecture Decisions

**WebSocket at scale:**

GraphQL subscriptions require a persistent connection. At 50 concurrent users per document and 10,000 simultaneous documents, that's 500,000 concurrent WebSocket connections. Key choices:
- Use a dedicated subscription router tier separate from the query/mutation router — subscriptions have different scaling characteristics.
- Pub/sub backend: Redis Streams or Kafka per document — when the mutation service writes an operation, it publishes to the document's channel; subscription servers fan out to connected clients.
- Sticky sessions for WebSocket routing, or a broker pattern where any subscription server can receive publishes.

**Conflict resolution:**

Store a per-document operation log (append-only). When `applyBlockOperation` arrives with `baseVersion: N` but the server is at version `N+3`, transform the incoming operation against the 3 operations applied since version N using OT, then apply. Return the transformed operation and new version to the client so it can reconcile.

**Fractional indexing for block positions:**

Using floating-point positions (e.g., 1.0, 2.0, 3.0) allows inserting a block between two others without renumbering: insert between 1.0 and 2.0 at position 1.5. This is an O(1) insert. The tradeoff is precision exhaustion after many inserts between the same two positions — regenerate positions when gap becomes too small (< 0.0001).

### Trade-Off Discussion

- **OT vs. CRDT:** OT is simpler to implement and well-understood; CRDTs are eventually-consistent by construction but operationally more complex (larger data structures, merge computation). For block-level (not character-level) collaboration, OT is the right choice.
- **Subscriptions vs. polling:** Polling at 1s intervals would work for small teams but creates unnecessary load for large documents with many collaborators. Subscriptions scale better operationally.
- **Block granularity:** Per-character collaboration (Google Docs style) requires a much more complex OT implementation. Block-level is a deliberate product choice that simplifies both the API and conflict resolution.

### Common Follow-Up Questions

- "How do you handle a client that is offline for 2 hours and comes back?"
- "How would you add real-time commenting on specific blocks?"
- "What's your strategy for document versioning/snapshots to avoid replaying millions of operations?"

---

## Scenario 2: Design the GraphQL Layer for a Multi-Tenant SaaS Platform

### Requirements Gathering — Questions to Ask

- Is this a soft-tenancy model (shared DB with tenant_id columns) or hard-tenancy (separate DB per tenant)?
- Can tenants customize the schema — add custom fields to standard types?
- Is there a self-service tier and enterprise tier with different features?
- What are the scale requirements per tenant? (Small: 100 users; large: 100,000 users?)
- Are there data residency requirements (EU data must stay in EU)?
- What's the rate limiting model — per tenant, per user, per operation?

**Assumed answers:** Soft-tenancy shared DB, enterprise tenants can add custom fields, both self-service and enterprise tiers, rate limiting per tenant + operation, EU data residency required for enterprise.

### Schema Design

```graphql
# ─── Tenant Context ──────────────────────────────────────────────────────────

"""
All queries and mutations are implicitly scoped to the authenticated tenant.
The tenant context is extracted from the JWT by the router — clients do not
pass tenantId explicitly (this would allow IDOR attacks).
"""
type Tenant @key(fields: "id") {
  id: ID!
  name: String!
  tier: TenantTier!
  settings: TenantSettings!
  customFields: [CustomFieldDefinition!]!
  dataResidencyRegion: DataRegion!
  rateLimits: TenantRateLimits!
}

enum TenantTier {
  FREE
  STARTER
  PROFESSIONAL
  ENTERPRISE
}

enum DataRegion {
  US_EAST
  EU_WEST
  AP_SOUTHEAST
}

# ─── Custom Fields ───────────────────────────────────────────────────────────

"""
Custom fields allow enterprise tenants to extend standard types with
tenant-specific attributes. The schema does not change — custom fields
are surfaced through a typed key-value pattern.
"""
type CustomFieldDefinition {
  id: ID!
  name: String!
  entityType: CustomFieldEntityType!
  fieldType: CustomFieldType!
  isRequired: Boolean!
  defaultValue: String
  validationRegex: String
}

type CustomFieldValue {
  definition: CustomFieldDefinition!
  value: String
}

enum CustomFieldEntityType { CONTACT, DEAL, COMPANY, TICKET }
enum CustomFieldType { TEXT, NUMBER, DATE, BOOLEAN, ENUM, URL }

# ─── Core SaaS Entity (e.g., CRM contact) ───────────────────────────────────

type Contact @key(fields: "id") {
  id: ID!
  tenant: Tenant!
  email: String!
  firstName: String!
  lastName: String!
  company: Company
  customFields: [CustomFieldValue!]!

  """
  Activity stream — scoped to tenant, cursor-paginated.
  """
  activities(
    first: Int = 20
    after: String
    filter: ActivityFilter
  ): ActivityConnection!
}

# ─── Rate Limit Surfacing ────────────────────────────────────────────────────

"""
Expose rate limit state to clients so they can implement backoff.
"""
type TenantRateLimits {
  requestsPerMinute: RateLimitBucket!
  requestsPerDay: RateLimitBucket!
  computeUnitsPerMonth: RateLimitBucket!
}

type RateLimitBucket {
  limit: Int!
  remaining: Int!
  resetsAt: DateTime!
}

# ─── Mutations ───────────────────────────────────────────────────────────────

type Mutation {
  createContact(input: CreateContactInput!): CreateContactResult!
  updateContact(input: UpdateContactInput!): UpdateContactResult!

  """
  Enterprise only: define custom fields for a tenant's contacts.
  """
  defineCustomField(input: DefineCustomFieldInput!): DefineCustomFieldResult!
}

union CreateContactResult =
  | CreateContactSuccess
  | ValidationError
  | RateLimitExceededError
  | FeatureNotAvailableError

type RateLimitExceededError {
  message: String!
  code: String!
  bucket: RateLimitBucket!
  retryAfter: DateTime!
}

type FeatureNotAvailableError {
  message: String!
  code: String!
  requiredTier: TenantTier!
  upgradeUrl: String!
}
```

### Architecture Decisions

**Tenant isolation in resolvers:**

Every resolver extracts `tenantId` from the request context (forwarded from router JWT claims) and applies it as a mandatory filter:

```typescript
// All queries are automatically scoped — tenant can never see another tenant's data
async contacts(_root, args, context) {
  // context.tenantId is set by router from JWT — not from client args
  return db.query(
    'SELECT * FROM contacts WHERE tenant_id = $1',
    [context.tenantId]
  );
}
```

**Schema customization via custom fields (not schema-per-tenant):**

A separate schema per tenant is operationally untenable — you cannot compose 10,000 schemas. Use the typed key-value `CustomFieldValue` pattern instead. Enterprise clients can define fields in the schema registry and surface them through the custom fields collection on each entity.

**Rate limiting at the router:**

```yaml
# router.yaml — per-tenant rate limiting via Rhai script or coprocessor
limits:
  experimental_http_max_request_bytes: 2000000  # 2MB max query

# Custom rate limiting via coprocessor
coprocessor:
  url: http://rate-limiter:4001
  router:
    request:
      headers: true
      # Rate limiter extracts tenant_id from JWT, checks Redis,
      # returns 429 with Retry-After header if exceeded
```

**Data residency:**

Deploy a separate router + subgraph stack per region (US, EU, AP). Route clients to their tenancy region based on the JWT `data_region` claim. No cross-region data reads.

### Trade-Off Discussion

- **Custom fields vs. per-tenant schema:** Per-tenant schemas are technically cleaner but operationally catastrophic at scale. Custom fields sacrifice some type safety for operational feasibility.
- **Soft vs. hard tenancy:** Hard tenancy (database per tenant) is more secure and easier to delete (GDPR) but 10x the operational cost. Soft tenancy with strong row-level security (PostgreSQL RLS) is the right trade-off for most SaaS.
- **Rate limiting at router vs. resolver:** Router-level rate limiting is coarser but cheaper; resolver-level allows per-operation granularity but requires every resolver to participate.

### Common Follow-Up Questions

- "How do you handle a tenant requesting a GDPR data deletion?"
- "An enterprise tenant wants to add a custom field with a complex computed value. How do you handle that?"
- "How do you enforce that resolver queries always include `tenant_id` in the WHERE clause? (Answer: RLS, integration tests, linting.)"

---

## Scenario 3: How Would You Migrate a REST API to GraphQL Without Breaking Clients?

### Requirements Gathering — Questions to Ask

- How many REST endpoints are there? (10, 100, 1,000?)
- Are there external clients (third-party developers) or only internal clients?
- Are the REST clients all under your control? Can you migrate them?
- Is there a requirement for backward compatibility during transition?
- What's the timeline for full migration?
- Are there REST clients that may never migrate (legacy partners)?

**Assumed answers:** 80 REST endpoints, mix of internal and external clients, indefinite backward compatibility for external clients, 12-month migration window.

### Architecture — Strangler Fig with a GraphQL Proxy Layer

**Phase 1 — GraphQL wrapping REST (months 1–3):**

```
External REST Clients ──────────────────────────────────────┐
                                                             │ (unchanged)
Internal Clients ─────── Apollo Router ─── GraphQL Layer ───┘
                                                ↓
                               REST API (existing, untouched)
```

The GraphQL layer initially wraps the REST API. Resolvers call the existing REST endpoints:

```typescript
const resolvers = {
  Query: {
    async product(_root, { id }, { restClient }) {
      // Initially, the GraphQL resolver delegates to the existing REST endpoint
      const response = await restClient.get(`/products/${id}`);
      return mapRestProductToGraphQL(response.data);
    }
  }
};
```

This lets you:
- Stand up the GraphQL endpoint and validate the schema with clients
- Migrate internal clients to GraphQL while external clients stay on REST
- Validate the GraphQL schema design against real production data

**Phase 2 — Move resolvers to direct service calls (months 4–9):**

Incrementally replace REST proxy resolvers with direct database/service calls:

```typescript
// Before (REST proxy)
async product(_root, { id }, { restClient }) {
  return restClient.get(`/products/${id}`);
}

// After (direct service call)
async product(_root, { id }, { productService }) {
  return productService.findById(id);
  // productService is the same code the REST endpoint called
}
```

This eliminates the REST hop and reduces latency. The REST API remains running — external clients are unaffected.

**Phase 3 — Parallel GraphQL endpoint for external clients (months 6–12):**

Stand up `api.company.com/graphql` as an external endpoint. Publish a GraphQL SDK for external developers. Run REST and GraphQL in parallel indefinitely for external clients.

```yaml
# router.yaml — separate external/internal schema surfaces
schema:
  contracts:
    - id: external-partners
      tags: ["public"]     # Only fields tagged @tag(name: "public") are exposed
    - id: internal-platform
      tags: ["public", "internal"]   # Internal clients see the full schema
```

**Schema design principles for migration:**

- Map REST resources to GraphQL types, not endpoints
- Consolidate redundant REST endpoints: `/products/{id}`, `/products/{id}/variants`, `/products/{id}/reviews` → one `Product` type with nested resolvers
- Improve the API design during migration — don't cargo-cult bad REST patterns into GraphQL

**GraphQL → REST field mapping example:**

```
REST endpoints unified under Product type:
  GET /products/:id           → Query.product(id)
  GET /products/:id/variants  → Product.variants(first, after)
  GET /products/:id/reviews   → Product.reviews(first, after, orderBy)
  GET /products/:id/inventory → Product.variants[].inventory (nullable)
  GET /products/:id/related   → Product.relatedProducts(first)

REST endpoints that become mutations:
  POST /cart/items            → Mutation.addToCart(input)
  DELETE /cart/items/:id      → Mutation.removeFromCart(input)
  POST /checkout              → Mutation.checkout(input)
```

### Trade-Off Discussion

- **Wrap REST vs. direct service calls:** Wrapping REST is safer (no application code changes) but adds latency. Direct calls are more efficient but require the migration team to understand each service's internal API.
- **Client migration timeline:** Internal clients should migrate within 6 months; external clients may never migrate. Plan for perpetual REST maintenance for external clients.
- **Schema design fidelity:** Should the GraphQL schema mirror the REST API exactly (easy migration) or be redesigned for GraphQL (better long-term)? Redesign wins — you won't get this opportunity again, and a cargo-culted REST schema is painful.

### Common Follow-Up Questions

- "How do you handle REST APIs that use session cookies vs. Bearer tokens?"
- "How do you migrate clients who use webhooks for async REST responses?"
- "What happens to REST clients using `fields` query parameters (sparse fieldsets) — how does that map to GraphQL?"

---

## Scenario 4: Design a GraphQL Federation for a Large Bank

### Requirements Gathering — Questions to Ask

- What regulatory framework? (PCI-DSS for payments, SOX for financial reporting, GDPR for EU clients?)
- Are there data residency constraints?
- Who are the clients? Internal banking apps, customer-facing mobile, third-party fintech partners?
- What are the latency SLA requirements per operation type?
- Is there a requirement for field-level encryption?
- What audit logging granularity is required?
- Is there a break-glass procedure for emergency access?

**Assumed answers:** PCI-DSS + SOX + GDPR, US + EU data residency, all three client types, <2s p99 for queries, field-level encryption for PII/PCI data, operation-level audit log for SOX, break-glass access with out-of-band approval.

### Architecture Overview

```
Internet clients ──── WAF ──── API Gateway ──── Apollo Router (public surface)
                                                        │
Internal clients ────────────── Apollo Router (internal surface, wider schema)
                                        │
                          Composition Config (schema contracts)
                          /            |            \
             accounts-subgraph  payments-subgraph  compliance-subgraph
                    │                  │                   │
              Accounts DB        Payments Processor    Audit DB (append-only)
              (US + EU)          (PCI zone)            (immutable ledger)
```

### Schema Design (Selected Critical Types)

```graphql
# ─── Compliance-Aware Account Type ──────────────────────────────────────────

type BankAccount @key(fields: "id") {
  id: ID!
  accountNumber: MaskedAccountNumber!
  accountType: BankAccountType!
  owner: Customer!
  balance: AccountBalance!

  """
  Full account number. PCI-sensitive — only accessible to authenticated
  customer owners and authorized bank employees. Field-level auth enforced
  via OPA policy. Audit logged on every access.
  """
  fullAccountNumber: String @tag(name: "pci-sensitive")

  transactions(
    first: Int = 20
    after: String
    filter: TransactionFilter
  ): TransactionConnection!

  statements(year: Int!, month: Int): [AccountStatement!]!
}

scalar MaskedAccountNumber   # Always returns last 4 digits only: "****1234"

type AccountBalance {
  available: Money!
  pending: Money!
  current: Money!
  asOf: DateTime!
}

# ─── Payment Mutation ────────────────────────────────────────────────────────

type Mutation {
  initiateTransfer(input: InitiateTransferInput!): InitiateTransferResult!
}

input InitiateTransferInput {
  fromAccountId: ID!
  toAccountId: ID!
  amount: MoneyInput!
  memo: String

  """
  Idempotency key — client generates a UUID for each attempt.
  If the same key is received twice, the server returns the original result
  without processing a second transfer. Critical for payment safety.
  """
  idempotencyKey: String!
}

union InitiateTransferResult =
  | TransferInitiated
  | InsufficientFundsError
  | TransferLimitExceededError
  | AccountFrozenError
  | FraudHoldError
  | ComplianceReviewRequiredError

type TransferInitiated {
  transfer: Transfer!
  confirmationNumber: String!
  """
  Estimated settlement time. Wire vs. ACH vs. internal have different SLAs.
  """
  estimatedSettlement: DateTime!
}

type ComplianceReviewRequiredError {
  message: String!
  code: String!
  """
  Reference number for the compliance review. Customer uses this to
  follow up with compliance team.
  """
  reviewReferenceNumber: String!
  estimatedReviewTime: String!   # "1-3 business days"
}

# ─── Audit Trail ────────────────────────────────────────────────────────────

"""
Every field access on PCI/PII-tagged fields generates an audit event.
This type is only accessible to compliance and security teams.
"""
type AuditEvent {
  id: ID!
  timestamp: DateTime!
  actorId: String!        # User or service that accessed the data
  actorType: ActorType!
  operation: String!      # "Query.BankAccount.fullAccountNumber"
  resourceId: String!     # Account ID accessed
  ipAddress: String!
  sessionId: String!
  result: AuditEventResult!
}

enum AuditEventResult { SUCCESS, DENIED, ERROR }
enum ActorType { CUSTOMER, EMPLOYEE, SERVICE_ACCOUNT, BREAK_GLASS }
```

### Architecture Decisions

**PCI zone isolation:**

The payments subgraph runs in a dedicated network zone with no internet ingress. The router can reach it, but no external service can. Card numbers and payment credentials never leave the PCI zone — only masked values or tokenized references are returned to the router.

**Field-level encryption for PII at rest:**

Fields tagged `@tag(name: "pci-sensitive")` or `@tag(name: "pii")` are encrypted at rest using envelope encryption (KMS-managed data keys). Resolvers transparently decrypt before returning — the client sees plaintext, but the database stores ciphertext.

**Audit logging architecture:**

Every resolver that accesses a sensitive field calls the audit subgraph as a side effect:

```typescript
// audit-aware resolver wrapper
async function auditedResolver(resolverFn, auditContext) {
  const result = await resolverFn();
  // Fire-and-forget audit event to append-only audit store
  // Never block the resolver on audit write success
  auditService.record({
    field: auditContext.field,
    actor: auditContext.claims.userId,
    resource: auditContext.resourceId,
    result: result != null ? 'SUCCESS' : 'NOT_FOUND'
  }).catch(err => logger.error({ event: 'audit_write_failed', err }));
  return result;
}
```

**SOX compliance — operation-level logging:**

Every mutation is logged with: actor, timestamp, operation, input hash (not raw input — it may contain PCI data), result status, and approval chain if applicable.

**Break-glass access:**

For emergency bank employee access to customer accounts, a separate `break-glass` auth flow issues a time-limited JWT with a `break_glass: true` claim and a unique approval ID. All field accesses using this token are tagged `ActorType.BREAK_GLASS` in the audit log and trigger real-time alerts to the security team.

### Trade-Off Discussion

- **Field-level encryption vs. database encryption at rest:** Database encryption protects against storage-layer attacks; field-level encryption additionally protects against internal SQL access and compromised DBA credentials. PCI-DSS and SOX typically require field-level for cardholder data.
- **Persisted queries vs. dynamic queries:** For a banking API, persisted queries in allowlist mode are mandatory for internal mobile clients. Dynamic queries increase the attack surface unnecessarily.
- **Synchronous vs. asynchronous audit writes:** Synchronous writes would add latency to every resolver. Asynchronous fire-and-forget writes are fine for audit purposes — the rare dropped event is handled by reconciliation against the transaction log.

### Common Follow-Up Questions

- "How do you handle a multi-currency bank account — a customer with USD and EUR balances?"
- "GDPR requires the ability to delete a customer's data. How does that interact with the append-only audit log?"
- "How do you ensure the idempotency key check is atomic under concurrent transfer requests?"
- "How do you test the compliance audit trail? (Answer: integration tests that verify every field access generates an audit record.)"

---

## Related Topics

- [Chapter 07: Federation](../07-federation/) — federation mechanics underpinning all four scenarios
- [Chapter 05: Security](../05-security/) — auth, PCI compliance, field-level encryption
- [Chapter 14: Observability](../14-observability/) — observability strategy referenced in Scenario 1 and 4
- [Chapter 24: System Design Scenarios](../24-system-design-scenarios/) — extended walkthroughs with more detailed architecture diagrams
- [02-federation-and-architecture-questions.md](./02-federation-and-architecture-questions.md) — prerequisite architecture questions
- [04-debugging-and-performance-questions.md](./04-debugging-and-performance-questions.md) — operational follow-ups to system design rounds
