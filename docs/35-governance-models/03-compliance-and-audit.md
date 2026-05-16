# 03 — Compliance and Audit

> **Purpose:** Map enterprise compliance frameworks — SOC 2 Type II, GDPR, HIPAA, and PCI DSS — to specific GraphQL schema design patterns, resolver implementations, and operational controls. This section is reference material for security engineers, compliance officers, and architects preparing for audits or designing data-sensitive GraphQL APIs.

---

## Overview

GraphQL compliance is frequently misunderstood. Auditors familiar with REST ask for endpoint-level access logs; GraphQL requires field-level access logs. They ask for data classification by table; GraphQL requires data classification by schema field. The patterns in this section translate standard compliance controls into GraphQL-specific implementations that satisfy auditors who understand the underlying framework.

This section covers four compliance frameworks:

1. **SOC 2 Type II** — operational controls evidence for trust service criteria
2. **GDPR** — field-level data classification, erasure implementation, retention enforcement
3. **HIPAA** — PHI field handling, access log retention, BAA vendor requirements
4. **PCI DSS** — cardholder data isolation, tokenization, never-expose patterns

---

## SOC 2 Type II Controls for GraphQL APIs

SOC 2 Type II requires evidence that controls are operating continuously over the audit period (typically 6–12 months), not just that controls exist. The following maps SOC 2 trust service criteria to GraphQL-specific evidence.

### CC6: Logical and Physical Access Controls

**Control requirement:** Access to the GraphQL API is restricted to authorized users and systems.

**GraphQL implementation:**

```graphql
# Schema-level access control via field directives
# @requiresScope is a custom directive enforced in resolver middleware
type Query {
  # Public — no auth required
  products(filter: ProductFilter): ProductConnection!

  # Requires authenticated session
  me: User @requiresScope(scope: "user:read")

  # Requires admin role
  allUsers(filter: UserFilter): UserConnection! @requiresScope(scope: "admin:users:read")

  # Requires specific data classification clearance
  financialReport(period: ReportPeriod!): FinancialReport! @requiresScope(scope: "finance:reports:read")
}
```

**Evidence artifacts for SOC 2 auditors:**

| Artifact | How Collected | Retention |
|---|---|---|
| Authentication decision logs | Apollo Router request log + auth service logs | 1 year |
| Authorization policy definitions | OPA policy files in git (immutable history) | Git history |
| Access denied events | Router logs filtered by 401/403 | 1 year |
| Privileged access usage | Admin-scoped operation logs | 2 years |
| Access review records | Quarterly SCIM group membership review | 2 years |

**Continuous monitoring evidence:** A daily job queries the access log datastore and generates a report of operations by scope for the audit period. This report is the "continuous operation" evidence SOC 2 Type II requires.

### CC7: System Operations

**Control requirement:** The GraphQL API is monitored for unauthorized activity and performance degradation.

**GraphQL-specific monitoring controls:**

```yaml
# Alerting rules mapped to SOC 2 CC7 controls
groups:
  - name: soc2-cc7-graphql
    rules:
      # CC7.2 — Detect potential intrusion
      - alert: GraphQLUnusualFieldAccessRate
        expr: |
          rate(graphql_field_resolve_total{field=~".*password.*|.*token.*|.*secret.*"}[5m]) > 10
        for: 2m
        annotations:
          soc2_control: "CC7.2"
          description: "Unusual access rate to sensitive fields — potential enumeration attack"

      # CC7.3 — Detect performance degradation
      - alert: GraphQLP99LatencyHigh
        expr: |
          histogram_quantile(0.99, graphql_operation_duration_seconds_bucket) > 5
        for: 5m
        annotations:
          soc2_control: "CC7.3"
          description: "GraphQL P99 latency exceeds 5s — availability SLA at risk"
```

### CC8: Change Management

**Control requirement:** Schema changes follow an authorized change management process.

**Evidence artifacts:**

- **Change request:** RFC document in GitHub (linked RFC ID)
- **Approval evidence:** GitHub PR approval timestamps and approver identities
- **Testing evidence:** CI pipeline run logs with test results
- **Deployment evidence:** Schema registry publish audit log (GraphOS/Hive maintains immutable publish history with timestamp, subgraph, version, and publisher identity)
- **Post-deployment verification:** Smoke test results from staging and production

**Schema registry as change management evidence:** Apollo GraphOS and Hive maintain an immutable audit log of every schema publish. This log includes: who published, when, from which CI job, what schema version, and whether the composition succeeded. Export this log for the SOC 2 audit period.

```bash
# Export GraphOS schema publish history for audit period
rover graph fetch my-graph@production --log-start 2025-01-01 --log-end 2025-12-31 > audit-schema-changes.json
```

### A1: Availability

**Control requirement:** The GraphQL API meets its SLA commitments.

**SLO evidence for SOC 2:**

```yaml
# Prometheus recording rules that generate SLO evidence
- record: soc2:graphql_availability:ratio_rate30d
  expr: |
    1 - (
      sum(rate(graphql_requests_total{status="error"}[30d]))
      / sum(rate(graphql_requests_total[30d]))
    )
```

Report monthly: availability ratio, incident count, mean time to recovery (MTTR), and whether each incident was within SLA bounds.

---

## GDPR Compliance

### Field-Level Data Classification

GDPR requires knowing which fields contain personal data, where it flows, and how long it is retained. GraphQL's typed schema makes field-level classification tractable in a way that untyped REST APIs cannot match.

**Classification directive:**

```graphql
directive @dataClass(
  classification: DataClassification!
  piiCategory: PIICategory
  retentionDays: Int
  erasable: Boolean
) on FIELD_DEFINITION

enum DataClassification {
  PUBLIC
  INTERNAL
  CONFIDENTIAL
  RESTRICTED       # PII, PHI, CHD
}

enum PIICategory {
  CONTACT_INFO     # name, email, phone, address
  IDENTITY         # government IDs, SSN, passport
  FINANCIAL        # payment methods, bank accounts
  BEHAVIORAL       # browsing history, purchase history
  BIOMETRIC        # fingerprints, face ID
  HEALTH           # medical conditions, prescriptions
}
```

**Schema with data classification:**

```graphql
type User {
  id: ID!
  createdAt: DateTime! @dataClass(classification: INTERNAL)

  # GDPR Article 4(1) personal data
  email: EmailAddress! @dataClass(
    classification: RESTRICTED
    piiCategory: CONTACT_INFO
    retentionDays: 2555  # 7 years for contractual records
    erasable: true
  )

  fullName: String! @dataClass(
    classification: RESTRICTED
    piiCategory: CONTACT_INFO
    retentionDays: 2555
    erasable: true
  )

  # Not GDPR personal data in isolation
  locale: String! @dataClass(classification: INTERNAL)
  plan: SubscriptionPlan! @dataClass(classification: INTERNAL)
}
```

**Automated data map generation:** A tooling script reads all schema definitions, extracts `@dataClass` annotations, and generates a GDPR Article 30 Record of Processing Activities (ROPA) entry for each classified field. This gives compliance teams an always-current data map.

### Right to Erasure (Article 17)

GDPR Article 17 requires the ability to erase all personal data about a user upon request. In GraphQL, this maps to a mutation with a robust audit trail.

```graphql
type Mutation {
  """
  Initiate deletion of all personal data associated with the requesting user.
  Queues an asynchronous erasure job. Returns a token for status tracking.
  Complies with GDPR Article 17 (Right to Erasure).
  """
  deleteMyData(
    input: DeleteMyDataInput!
  ): DeleteMyDataResponse!

  """
  Admin-only: process a GDPR erasure request for a specific user.
  Requires erasure:execute scope. All invocations are audit-logged.
  """
  processErasureRequest(
    input: ProcessErasureRequestInput!
  ): ErasureRequestResult! @requiresScope(scope: "gdpr:erasure:execute")
}

input DeleteMyDataInput {
  """Confirmation string: must equal 'DELETE MY DATA' to prevent accidental erasure."""
  confirmation: String!
  """Optional reason for audit log."""
  reason: String
}

type DeleteMyDataResponse {
  """Opaque token for tracking erasure job status."""
  erasureToken: ID!
  """Estimated completion time."""
  estimatedCompletionAt: DateTime!
  """Fields that will be erased."""
  fieldsToErase: [String!]!
  """Systems that will be notified for cascading erasure."""
  downstreamSystems: [String!]!
}
```

**Erasure resolver with audit trail:**

```typescript
// resolvers/mutation/deleteMyData.ts
export async function deleteMyData(
  _parent: unknown,
  { input }: { input: DeleteMyDataInput },
  context: GraphQLContext
): Promise<DeleteMyDataResponse> {
  const { userId, requestId, userAgent, ip } = context;

  if (input.confirmation !== 'DELETE MY DATA') {
    throw new UserInputError('Confirmation string does not match required value');
  }

  // Audit log entry — immutable, append-only
  await auditLog.record({
    eventType: 'GDPR_ERASURE_INITIATED',
    userId,
    requestId,
    timestamp: new Date().toISOString(),
    initiatedBy: userId,
    userAgent,
    ip,
    reason: input.reason ?? 'user-initiated',
    regulatoryBasis: 'GDPR-Article-17',
  });

  const erasureJob = await erasureQueue.enqueue({
    userId,
    requestId,
    fieldsToErase: await dataClassificationService.getErasableFields(userId),
    downstreamSystems: await dataMapService.getDownstreamSystems(userId),
  });

  return {
    erasureToken: erasureJob.id,
    estimatedCompletionAt: erasureJob.estimatedCompletionAt,
    fieldsToErase: erasureJob.fieldsToErase,
    downstreamSystems: erasureJob.downstreamSystems,
  };
}
```

### Data Retention Policy Enforcement

GraphQL resolvers should not return data past its retention period. A middleware layer enforces this:

```typescript
// middleware/retentionEnforcement.ts
// Applied to all resolver executions for @dataClass(erasable: true) fields

export function retentionMiddleware(resolve, parent, args, context, info) {
  const fieldDef = info.parentType.getFields()[info.fieldName];
  const dataClass = getDirective(schema, fieldDef, 'dataClass')?.[0];

  if (dataClass?.retentionDays && parent.createdAt) {
    const ageInDays = daysSince(parent.createdAt);
    if (ageInDays > dataClass.retentionDays) {
      // Field is past retention period — return null rather than data
      return null;
    }
  }

  return resolve(parent, args, context, info);
}
```

---

## HIPAA Compliance

### PHI Field Tagging

HIPAA's Safe Harbor standard defines 18 categories of Protected Health Information (PHI). Any GraphQL field that stores or returns PHI must be tagged, access-controlled, and audit-logged.

**PHI directive:**

```graphql
directive @phi(
  safeHarborCategory: PHISafeHarborCategory!
  minimumNecessary: Boolean
) on FIELD_DEFINITION

enum PHISafeHarborCategory {
  NAME
  GEOGRAPHIC          # smaller than state
  DATES               # except year, if related to individual
  PHONE
  FAX
  EMAIL
  SSN
  MRN                 # medical record number
  HEALTH_PLAN_ID
  ACCOUNT_NUMBER
  CERTIFICATE_NUMBER
  VIN
  DEVICE_ID
  URL
  IP_ADDRESS
  BIOMETRIC
  PHOTO
  ANY_UNIQUE_ID
}

type Patient {
  id: ID!

  # PHI — Safe Harbor: NAME
  firstName: String! @phi(safeHarborCategory: NAME, minimumNecessary: true)
  lastName: String! @phi(safeHarborCategory: NAME, minimumNecessary: true)

  # PHI — Safe Harbor: DATES (date of birth)
  dateOfBirth: Date! @phi(safeHarborCategory: DATES, minimumNecessary: true)

  # PHI — Safe Harbor: MRN
  medicalRecordNumber: String! @phi(safeHarborCategory: MRN, minimumNecessary: true)

  # PHI — Safe Harbor: EMAIL
  contactEmail: EmailAddress @phi(safeHarborCategory: EMAIL)

  # Non-PHI
  enrolledProgramIds: [ID!]!
}
```

**Minimum Necessary access enforcement:** HIPAA's Minimum Necessary standard (45 CFR §164.502(b)) requires that access to PHI be limited to the minimum necessary to accomplish the intended purpose. In GraphQL, this is enforced by requiring a stated purpose scope for each PHI field:

```typescript
// middleware/minimumNecessary.ts
export function minimumNecessaryMiddleware(resolve, parent, args, context, info) {
  const fieldDef = info.parentType.getFields()[info.fieldName];
  const phiDirective = getDirective(schema, fieldDef, 'phi')?.[0];

  if (phiDirective?.minimumNecessary) {
    const purposeScope = context.operationPurpose; // from request header or JWT claim
    if (!purposeScope) {
      // Log access attempt without stated purpose
      phiAccessLog.record({
        userId: context.userId,
        field: `${info.parentType.name}.${info.fieldName}`,
        patientId: parent.id,
        purpose: null,
        decision: 'DENIED — no purpose stated',
        timestamp: new Date().toISOString(),
      });
      throw new ForbiddenError('PHI access requires a stated purpose (x-operation-purpose header)');
    }

    phiAccessLog.record({
      userId: context.userId,
      field: `${info.parentType.name}.${info.fieldName}`,
      patientId: parent.id,
      purpose: purposeScope,
      decision: 'ALLOWED',
      timestamp: new Date().toISOString(),
    });
  }

  return resolve(parent, args, context, info);
}
```

### Access Log Retention (HIPAA §164.312(b))

HIPAA requires audit logs of PHI access to be retained for 6 years. GraphQL-specific implementation:

- Every resolver execution touching a `@phi` field writes to an append-only audit log
- Audit log schema captures: user identity, patient identity, field accessed, operation name, purpose scope, timestamp, IP address, user agent
- Logs shipped to immutable object storage (S3 with Object Lock / GCS with retention policy) with 6-year retention
- Log integrity verified via hash chain (each entry includes hash of previous entry)

### BAA Vendor Requirements

Any vendor that processes PHI on behalf of the covered entity must have a Business Associate Agreement (BAA). For GraphQL infrastructure:

| Vendor | PHI Exposure | BAA Required |
|---|---|---|
| Apollo GraphOS | Schema + field usage metadata (field names, not values) | Depends on whether field names are considered PHI — get legal review |
| Hive (self-hosted) | No external PHI exposure | No |
| Datadog | PHI may appear in traces if not scrubbed | Yes — Datadog offers BAA for Enterprise |
| Sentry | Error payloads may contain PHI | Yes — scrub PHI from error context before sending |
| Cloudflare (Router on edge) | Request/response in flight | Yes — Cloudflare offers BAA |

---

## PCI DSS Compliance

### Cardholder Data in GraphQL: Never Expose Directly

PCI DSS Requirement 3 prohibits storing, processing, or transmitting cardholder data (CHD) except as strictly necessary. The GraphQL schema must be designed so that primary account numbers (PAN), CVVs, and track data never appear as schema fields.

**Explicit prohibition in schema:**

```graphql
# NEVER define these fields in a GraphQL schema
# This is an example of what NOT to do:
#
# type PaymentMethod {
#   cardNumber: String!    # PAN — PCI DSS violation
#   cvv: String            # CVV — PCI DSS violation (must never be stored)
#   trackData: String      # Track data — PCI DSS violation
# }

# CORRECT: Only expose tokenized, truncated representations
type PaymentMethod {
  """Opaque token from the payment vault. Never contains card data."""
  id: ID!

  """Display-safe card description: last 4 digits and card type only."""
  displaySummary: String!          # e.g., "Visa •••• 4242"

  """Card network. Does not identify the card."""
  network: CardNetwork!            # VISA, MASTERCARD, AMEX, DISCOVER

  """Card expiry month (display only — not usable for transactions)."""
  expiryMonth: Int!

  """Card expiry year (display only — not usable for transactions)."""
  expiryYear: Int!

  """Whether this is the default payment method."""
  isDefault: Boolean!

  """Billing address associated with this card."""
  billingAddress: Address
}

enum CardNetwork {
  VISA
  MASTERCARD
  AMEX
  DISCOVER
  JCB
  UNIONPAY
  OTHER
}
```

### Tokenization via External Vault

All payment processing flows through an external PCI-compliant vault (Stripe, Braintree, Adyen). The GraphQL API only handles vault tokens.

```graphql
type Mutation {
  """
  Attach a tokenized payment method to the user's account.
  The `vaultToken` is obtained directly from the payment provider's
  client-side SDK and is never transmitted through your GraphQL API.
  """
  attachPaymentMethod(input: AttachPaymentMethodInput!): AttachPaymentMethodResult!

  """
  Remove a tokenized payment method.
  """
  removePaymentMethod(paymentMethodId: ID!): RemovePaymentMethodResult!

  """
  Process a payment using an existing tokenized payment method.
  Returns a transaction token, not transaction details containing card data.
  """
  processPayment(input: ProcessPaymentInput!): ProcessPaymentResult!
}

input AttachPaymentMethodInput {
  """Token from Stripe.js / Braintree JS SDK. Never the raw card number."""
  vaultToken: String!
  """Set as default payment method."""
  setAsDefault: Boolean
}
```

**OPA policy to block CHD fields:**

```rego
package graphql.pci

# Block any field definition containing card number patterns
deny[msg] {
  field := input.fields[_]
  field_name_lower := lower(field.name)
  card_number_patterns := {"cardnumber", "pan", "primaryaccountnumber", "cvv", "cvc", "trackdata"}
  card_number_patterns[_] == field_name_lower
  msg := sprintf(
    "PCI DSS violation: Field '%v' appears to store cardholder data. Use vault tokenization instead.",
    [field.name]
  )
}
```

---

## Audit Log Schema

Every GraphQL operation against a field-level access-controlled API should produce a structured audit log entry. The following schema covers all compliance frameworks:

```typescript
// types/audit-log.ts
interface GraphQLAuditLogEntry {
  // Request identity
  requestId: string;           // trace ID, correlates with distributed trace
  sessionId: string;
  userId: string;              // authenticated user
  serviceAccountId?: string;  // for service-to-service calls

  // Operation
  operationType: 'query' | 'mutation' | 'subscription';
  operationName: string | null;
  operationHash: string;       // SHA-256 of normalized query document

  // Fields accessed (for field-level audit)
  fieldsAccessed: FieldAccessRecord[];

  // Context
  clientName: string;          // apollographql-client-name header
  clientVersion: string;       // apollographql-client-version header
  userAgent: string;
  sourceIp: string;
  timestamp: string;           // ISO 8601

  // Compliance metadata
  operationPurpose?: string;   // x-operation-purpose header (HIPAA minimum necessary)
  dataClassifications: DataClassification[];  // from @dataClass directives of accessed fields
  complianceFrameworks: ComplianceFramework[];  // derived from data classifications

  // Decision
  authorized: boolean;
  authorizationDenialReason?: string;

  // Performance (for availability evidence)
  durationMs: number;
  errorCount: number;
  cacheHit: boolean;
}

interface FieldAccessRecord {
  typeName: string;         // e.g., "User"
  fieldName: string;        // e.g., "email"
  classification: string;   // from @dataClass directive
  phiCategory?: string;     // from @phi directive
  entityId?: string;        // e.g., the user ID whose data was accessed
}
```

**Audit log storage requirements by framework:**

| Framework | Retention | Immutability | Access Control |
|---|---|---|---|
| SOC 2 | 1 year minimum | Preferred | Restricted to auditors |
| GDPR | Erasure logs: indefinite; access logs: 1 year | Required for erasure logs | DPO + legal |
| HIPAA | 6 years | Required | HIPAA security officer |
| PCI DSS | 1 year online, 3 years total | Required | QSA + security team |

---

## See Also

- [01 — Schema Governance Models](./01-schema-governance-models.md) — Governance model selection affects compliance evidence approach
- [02 — Change Management](./02-change-management.md) — Change management records are primary SOC 2 CC8 evidence
- [05 — Security](../05-security/) — Authentication, authorization, and rate limiting implementation
- [13 — Policy as Code](../13-policy-as-code/) — OPA policies for schema-level compliance checks
- [14 — Observability](../14-observability/) — Field-level tracing for audit log generation
