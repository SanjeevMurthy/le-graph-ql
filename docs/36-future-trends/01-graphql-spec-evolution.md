# 01 — GraphQL Specification Evolution

> **Purpose:** Track active RFCs in the GraphQL specification, their current status, implementation availability across major servers and routers, and what each feature means for schema design and client development. This document is updated as RFC stages advance — check the GraphQL Working Group GitHub for real-time status.

---

## The GraphQL Working Group Process

The GraphQL specification is governed by the GraphQL Foundation under the Linux Foundation. Changes to the spec go through a staged RFC process modeled loosely on TC39 (the JavaScript standards body):

| Stage | Name | Meaning |
|-------|------|---------|
| 0 | Strawman | Idea proposed; no formal proposal document |
| 1 | Proposal | Champion identified; problem statement accepted by WG |
| 2 | Draft | Formal spec text written; implementations encouraged |
| 3 | Accepted | At least two independent implementations; ready for ratification |
| Final | Released | Merged into the official specification |

The Working Group meets monthly. RFC discussions happen asynchronously on GitHub at `graphql/graphql-spec`. Major server implementations (graphql-js, graphql-java, Strawberry, Hot Chocolate, graphql-go) are expected to implement Stage 3 RFCs. Router implementations (Apollo Router, Cosmo) implement features that affect query planning independently of the spec.

---

## @defer and @stream — Incremental Delivery

### What It Solves

A persistent pain point in GraphQL: queries that include slow fields block the entire response. If a UI page needs user profile data (fast, from cache) and personalized recommendations (slow, from ML service), the client waits for the slowest field before rendering anything.

`@defer` lets a client mark a fragment as deferrable — the server streams the non-deferred fields immediately and sends the deferred fragment as a follow-up chunk when it is ready. `@stream` does the same for list fields, streaming each item as it becomes available rather than waiting for the full list.

### Current RFC Status

As of mid-2025, `@defer` and `@stream` are **merged into the spec draft** — the most advanced non-Final stage. The spec text is stable enough that major implementations have been built against it. The GraphQL Foundation's process for moving this to Final involves resolving a small number of open editorial issues, not design questions.

This is the most production-ready RFC in the Working Group pipeline.

### Directive Syntax

```graphql
# @defer on a named fragment — profile loads immediately, recommendations stream in
query ProductPage($id: ID!) {
  product(id: $id) {
    id
    name
    price
    
    ...RecommendedProducts @defer(label: "recommendations")
  }
}

fragment RecommendedProducts on Product {
  recommendations {
    id
    name
    score
  }
}
```

```graphql
# @stream on a list field — items arrive as they are resolved
query ReviewFeed($productId: ID!) {
  product(id: $productId) {
    reviews @stream(initialCount: 3, label: "more-reviews") {
      id
      author
      rating
      body
    }
  }
}
```

The `label` argument on both directives is optional but strongly recommended in production — it identifies which chunk corresponds to which deferred fragment in multi-deferred responses, and it maps to span labels in distributed traces.

### Transport Layer Requirements

Incremental delivery requires a transport that supports multiple response chunks from a single request. The spec defines this as **multipart HTTP** (using `Content-Type: multipart/mixed` with `Transfer-Encoding: chunked`) or **Server-Sent Events (SSE)**. WebSocket transports also support it naturally.

The client declares support by setting `Accept: multipart/mixed`:

```http
POST /graphql HTTP/1.1
Content-Type: application/json
Accept: multipart/mixed

{ "query": "..." }
```

The server responds with a stream:

```
HTTP/1.1 200 OK
Content-Type: multipart/mixed; boundary="-"

---
Content-Type: application/json

{"data":{"product":{"id":"1","name":"Widget","price":9.99}},"hasNext":true}
---
Content-Type: application/json

{"incremental":[{"label":"recommendations","path":["product"],"data":{"recommendations":[...]}}],"hasNext":false}
-----
```

### Implementation Status

| Implementation | Status | Notes |
|----------------|--------|-------|
| **Apollo Router** | Production-ready | Available since Router 1.25; multipart and SSE both supported |
| **Apollo Server 4** | Production-ready | `@defer` support with graphql-js 17+ |
| **graphql-yoga** | Production-ready | Full implementation with SSE transport |
| **graphql-java** | Implemented | Available in graphql-java 21+ |
| **Strawberry (Python)** | Implemented | Available in Strawberry 0.220+ |
| **Hot Chocolate (.NET)** | Implemented | Available in HC 13+ |
| **Apollo Client** | Implemented | Requires React 18 for Suspense integration |

### React Suspense Integration

`@defer` integrates naturally with React 18's Suspense model. Apollo Client 3.8+ exposes deferred fragments as separate Suspense boundaries:

```tsx
import { useSuspenseQuery } from '@apollo/client';

function ProductPage({ id }: { id: string }) {
  const { data } = useSuspenseQuery(PRODUCT_PAGE_QUERY, {
    variables: { id },
  });

  return (
    <div>
      {/* Renders immediately when non-deferred data arrives */}
      <ProductHeader product={data.product} />
      
      {/* Suspends until the deferred fragment resolves */}
      <Suspense fallback={<RecommendationSkeleton />}>
        <RecommendationPanel product={data.product} />
      </Suspense>
    </div>
  );
}
```

The pattern eliminates the need for separate loading states for slow fields — the Suspense boundary handles it declaratively. This is a significant DX improvement over the previous pattern of separate queries with manual loading coordination.

### Schema Design Implications

`@defer` changes how you think about query shape:

- **Stop splitting queries to avoid slow fields.** The common workaround of making two separate network requests — one for fast data and one for slow data — is no longer necessary. A single query with `@defer` achieves the same result with better cache coherence.
- **Label all deferred fragments.** Labels become observability identifiers. Apollo Router emits spans per deferred chunk; without labels, tracing is opaque.
- **Resolver timeout discipline matters more.** When slow fields are deferred, they are still resolved. If a deferred resolver has no timeout and hangs indefinitely, the client connection stays open. Implement resolver timeouts regardless of deferral.

---

## Fragment Arguments — Parameterized Fragments

### What It Solves

Fragments are reusable selection sets, but they are statically defined — they cannot accept parameters. The common workaround is to define multiple nearly-identical fragments, or to push variables to the operation level where they are accessible to all fragments (which breaks encapsulation and pollutes the variable namespace).

Fragment Arguments lets fragments declare typed arguments, and callers pass values when using the fragment:

### Current RFC Status

**Stage 2 (Draft)** as of mid-2025. The RFC champion is Matt Mahoney (Meta). Implementations are underway in graphql-js. The feature is commonly expected to reach Stage 3 in 2025 with Final in 2026.

### Before and After

**Without Fragment Arguments — repeated fragment definitions:**

```graphql
# Before: three nearly-identical fragments for different image sizes
fragment UserAvatarSmall on User {
  avatar(size: 32) { url }
  name
}

fragment UserAvatarMedium on User {
  avatar(size: 64) { url }
  name
}

fragment UserAvatarLarge on User {
  avatar(size: 128) { url }
  name
}

query TeamPage {
  team {
    lead { ...UserAvatarLarge }
    members { ...UserAvatarSmall }
  }
}
```

**With Fragment Arguments — single parameterized fragment:**

```graphql
# After: one fragment, parameterized at the call site
fragment UserAvatar($size: Int!) on User {
  avatar(size: $size) { url }
  name
}

query TeamPage {
  team {
    lead { ...UserAvatar(size: 128) }
    members { ...UserAvatar(size: 32) }
  }
}
```

### Production Impact

For large codebases with design systems built on fragments, this eliminates entire categories of fragment duplication. Shopify's Storefront API documentation has noted that Fragment Arguments would reduce their public fragment count by approximately 40%. The DX impact for frontend engineers maintaining design system components is significant — a `<Button>` fragment no longer needs four size variants.

Fragment Arguments also improve persisted query hit rates: instead of permuting query documents per fragment variant, a single parameterized document covers all cases.

### Schema Design Implications

Fragment Arguments are a **client-side** language feature — they do not change how you design schemas. However, they do change how you think about field arguments on schema types:

- **Keep arguments on fields, not on types.** Fragment Arguments encourages passing arguments through to field resolvers. This reinforces the GraphQL principle that fields carry their own arguments — not a workaround where you create multiple types for different sizes.
- **Field argument documentation matters more.** When fragments become parameterized components, field arguments become the fragment's API contract. Document them thoroughly.

---

## Input Unions — Union Types for Input

### What It Solves

GraphQL's Union type allows a field to return one of several Object types. But on the input side, there is no equivalent — Input types cannot form a union. This forces workarounds: one large Input type with all optional fields and application-level validation, or separate mutations for each input variant.

```graphql
# Current workaround: one fat input type with manual validation
input CreateNotificationInput {
  type: NotificationType!
  
  # Email fields — required when type = EMAIL, ignored otherwise
  emailAddress: String
  emailSubject: String
  
  # Push fields — required when type = PUSH, ignored otherwise
  deviceToken: String
  pushTitle: String
  pushBody: String
  
  # SMS fields
  phoneNumber: String
  smsBody: String
}
```

Input Unions would allow:

```graphql
# Target state: discriminated union for inputs
input EmailNotificationInput {
  emailAddress: String!
  subject: String!
  body: String!
}

input PushNotificationInput {
  deviceToken: String!
  title: String!
  body: String!
}

# Input union (proposed syntax — not finalized)
inputUnion CreateNotificationInput = 
  EmailNotificationInput | 
  PushNotificationInput | 
  SmsNotificationInput

mutation SendNotification($input: CreateNotificationInput!) {
  sendNotification(input: $input) { id }
}
```

### Current RFC Status

**Stage 1 (Proposal)** — and this is the most contentious long-running RFC in the Working Group. It has been discussed since 2018. The core problem is that GraphQL's type system uses structural typing, and adding a discriminated union for inputs requires a disambiguation mechanism. Multiple competing proposals exist:

| Proposal | Mechanism | Status |
|----------|-----------|--------|
| **Tagged** | Wrapper object with exactly one field (acts as the tag) | Current frontrunner as of 2024 |
| **@oneOf** directive | Directive on an Input type marking exactly one field required | Stage 2 (separate RFC, more likely to merge first) |
| **inputUnion keyword** | New keyword in SDL | Rejected — too large a spec change |

**`@oneOf` is the pragmatic near-term path.** It is simpler than full Input Unions and solves the majority of use cases:

```graphql
input CreateNotificationInput @oneOf {
  email: EmailNotificationInput
  push: PushNotificationInput
  sms: SmsNotificationInput
}
```

With `@oneOf`, exactly one of the fields must be provided and non-null. The server validates this at the GraphQL layer, before resolvers run. The `@oneOf` RFC is Stage 2 and has implementations in graphql-java and Hot Chocolate.

### Schema Design Implications

If you are designing schemas today that need input unions, two strategies:

1. **Use `@oneOf` now if your server supports it.** graphql-java and Hot Chocolate implement it. If you are on graphql-js, you can implement `@oneOf` as a custom directive with a validation rule.
2. **Design for future migration.** Use the "one large input with optional fields" pattern but document which field combinations are valid. When Input Unions land, migration to the canonical form requires only a schema change — not a resolver rewrite.

---

## Composite Schemas — Spec-Level Federation

### What It Solves

Apollo Federation v1 introduced the supergraph model in 2019: multiple subgraph services compose into a unified graph that clients query through a router. This was a significant architectural innovation, but it remained a proprietary Apollo specification. Teams adopting federation were implicitly adopting Apollo's interpretation of how federation works.

The **GraphQL Composite Schemas Working Group** (a sub-WG of the main GraphQL WG) is formalizing federation concepts at the specification level. The goal is a vendor-neutral specification that any router can implement — so a team could compose subgraphs written for Apollo Federation, serve them through a WunderGraph Cosmo router, and switch to a Hive router without changing their subgraph schemas.

### WG Progress

The Composite Schemas WG began publishing deliverables in 2024. As of mid-2025:

- The **Subgraph Specification** (how individual subgraphs declare their types and entities) has an initial draft
- The **Composition Specification** (how multiple subgraph schemas merge into a supergraph) is in active draft
- The **Router Specification** (how the router plans and executes queries across subgraphs) is in early draft

The WG includes engineers from Apollo, The Guild (Hive), WunderGraph (Cosmo), Grafbase, and Netflix. This broad participation is a positive signal for convergence.

### Relationship to Apollo Federation v2

Apollo Federation v2 directives (`@key`, `@external`, `@requires`, `@provides`, `@shareable`, `@inaccessible`, `@override`, `@tag`) are the current de-facto standard. The Composite Schemas specification is expected to:

- **Ratify most of Apollo Federation v2's directive vocabulary** with minor semantic adjustments
- **Add vendor-neutral alternatives** for features that were Apollo-specific (like `@interfaceObject`)
- **Leave room** for implementation-specific extensions behind `@link` import mechanisms

### Impact on Vendor Lock-In

Today's federation lock-in is primarily at the **schema registry** and **router** layers:

- Subgraph schemas using `@key`, `@external`, etc. are portable between routers that implement them (Apollo Router, Cosmo, and Hive's router all implement Federation v2)
- Schema composition tooling (Rover for Apollo, the WG's reference implementation) is less portable
- Router configuration (coprocessors, custom plugins, Rhai scripts for Apollo Router) is not portable at all

When Composite Schemas reaches ratification:

- Subgraph schemas will be fully portable by spec
- Router configuration portability will remain a competitive differentiator
- Schema composition interoperability will improve but not be guaranteed (composition is hard to standardize completely)

### Timeline

The WG has not committed to a specific ratification date. Given the complexity of the composition algorithm and the need for multiple independent router implementations, a realistic estimate is 2026–2027 for a stable specification. Implementation vendors will track the draft — teams building today can use Apollo Federation v2 directives with confidence that they will align closely with the eventual standard.

---

## Client-Controlled Nullability — Client Marks Fields as Required

### What It Solves

GraphQL's type system uses nullable-by-default semantics. A field typed `String` (nullable) can return `null`, and the resolver failure propagation rules mean a `null` from a nested nullable field only nulls out that field — the rest of the response is intact. But `String!` (non-null) means a resolver failure propagates up to the nearest nullable ancestor, potentially nulling out large portions of the response.

Schema designers face a dilemma: mark fields non-null (strict, breaks clients harder on errors) or nullable (lenient, requires defensive null-checking everywhere in clients). There is no schema-level answer that satisfies all clients — some clients can tolerate partial data, others cannot.

Client-Controlled Nullability lets clients override the schema's nullability at query time:

```graphql
# Client marks fields as required with ! syntax in the selection set
query UserProfile($id: ID!) {
  user(id: $id) {
    id!          # Client requires this — null causes a client-level error
    name!
    email        # Client tolerates null here
    avatar {
      url!       # Client requires the avatar URL if avatar is present
    }
  }
}
```

### Current RFC Status

**Stage 2 (Draft)** — RFC champion is Alex Reilly (Yelp). The RFC has generated significant debate because it changes the error-handling contract:

- When a client-marked-required field returns null, should the error propagate (like non-null in schema) or should it be surfaced as an error without propagation?
- Should `!` in the selection set always be an error, or should clients be able to opt into alternative behaviors?

The current direction is that client-required nullability errors are collected in the `errors` array without propagation — giving clients a stricter signal without blowing up the entire response.

### Debate on Adoption

The community is divided. Arguments for:

- **Eliminates defensive null-checking in clients.** Clients that know they need a field can declare it, and the server will surface an error rather than silently returning null and causing a downstream crash.
- **Enables better code generation.** Type generators (GraphQL Code Generator, Relay compiler) can emit non-optional TypeScript types for client-required fields.

Arguments against:

- **Complexity.** Adding a second nullability layer confuses engineers who already struggle with the nullable-by-default schema design decision.
- **Schema-first principle.** If a field is logically required, it should be `String!` in the schema — not overridden at query time by each client.
- **Interaction with @defer.** The semantics of client-required nullability combined with deferred fields are complex and not fully specified.

**Practical guidance:** Design your schemas with clear nullability intent. If Client-Controlled Nullability merges, it will be most useful for client teams consuming third-party schemas they do not control — not as a workaround for poor schema design decisions in schemas you own.

---

## Schema Coordinates — Standard Field References

### What It Solves

GraphQL tooling, directives, error messages, and documentation all need a standard way to refer to a specific field within a type. Currently each tool invents its own syntax: `User.email`, `User::email`, `User/email`, or just "the email field on the User type."

Schema Coordinates defines a canonical syntax: `Type.field` for fields, `Type.field(argument:)` for arguments, `@directive` for directives, `@directive(argument:)` for directive arguments.

### Current RFC Status

**Stage 3 (Accepted)** — this is the furthest-along RFC outside of `@defer`/`@stream`. The syntax is finalized. Multiple tooling implementations exist. It is expected to merge into the stable specification in the next release.

```
# Schema Coordinate syntax examples
User                    # Object type
User.email              # Field on a type
User.email(format:)     # Argument on a field
Query.user              # Root field
Mutation.createUser     # Mutation field
@deprecated             # Directive
@deprecated(reason:)    # Directive argument
```

### Production Impact

Schema Coordinates will be adopted everywhere tooling references schema elements:

- **Rover CLI** will use coordinates in schema check output: `User.email is deprecated — referenced in 14 operations`
- **Schema Registry** breaking change reports will use coordinates: `Breaking: User.phone removed (14 active operations reference User.phone)`
- **Custom directives** can reference coordinates as arguments: `@auth(requires: "User.sensitiveField")`
- **Error messages** will standardize on coordinates: `Cannot query field "User.deletedAt" — deprecated since v2.1, use User.archivedAt`

This is low-drama but high-leverage — it eliminates an entire category of tooling inconsistency and makes error messages actionable across the entire ecosystem.

---

## Adoption Timeline Summary

| RFC | Stage | Stable Spec | Implementation Now | Recommendation |
|-----|-------|-------------|-------------------|----------------|
| @defer / @stream | Draft (pre-Final) | 2025 | Apollo Router, graphql-yoga, Apollo Server 4 | Use in production for slow field isolation |
| Schema Coordinates | Stage 3 | 2025 | Rover CLI, tooling ecosystem | Adopt in tooling references immediately |
| Fragment Arguments | Stage 2 | 2026 | Limited (in progress) | Plan for adoption; watch graphql-js releases |
| @oneOf (Input Unions shortcut) | Stage 2 | 2026 | graphql-java, Hot Chocolate | Use if your server supports it |
| Input Unions (full) | Stage 1 | 2027+ | None yet | Design for migration; use @oneOf interim |
| Composite Schemas | Draft | 2026–2027 | Router vendors tracking draft | Use Apollo Federation v2 directives — they will align |
| Client-Controlled Nullability | Stage 2 | 2026–2027 | Limited | Monitor; design schemas with clear nullability intent |

---

## Schema Design Implications for Today

These RFCs have concrete implications for teams designing schemas now:

1. **Add labels to your @defer and @stream directives.** When @defer is in your stack today (Apollo Router 1.25+), `label` arguments are not optional — they become observability identifiers.

2. **Document every field description thoroughly.** Fragment Arguments and AI integration (see [02-ai-and-graphql-convergence.md](./02-ai-and-graphql-convergence.md)) both increase the importance of field-level descriptions. A schema without descriptions is a liability.

3. **Adopt Apollo Federation v2 directives.** The Composite Schemas WG is converging on this vocabulary. Using v1 directives (`@provides`, `@requires` with v1 semantics) requires a migration that will be more painful later.

4. **Design clear nullability intent.** Do not rely on Client-Controlled Nullability as a future escape hatch. Decide whether fields are logically nullable or not and express that in the schema.

5. **Use Schema Coordinates in your custom directives and tooling.** Even before the spec finalizes, adopt the `Type.field` syntax convention in your tooling, schema registry queries, and error messages. Migration cost when the spec lands will be minimal.

---

## Working Group Resources

- **GraphQL WG GitHub**: [github.com/graphql/graphql-wg](https://github.com/graphql/graphql-wg) — meeting notes, RFC discussions
- **GraphQL Spec**: [spec.graphql.org](https://spec.graphql.org) — the canonical specification
- **RFC Tracker**: [github.com/graphql/graphql-spec/projects](https://github.com/graphql/graphql-spec/projects)
- **Composite Schemas WG**: [github.com/graphql/composite-schemas-wg](https://github.com/graphql/composite-schemas-wg)
- **graphql-js releases**: [github.com/graphql/graphql-js/releases](https://github.com/graphql/graphql-js/releases) — reference implementation

---

## Related Sections

- [01-graphql-fundamentals](../01-graphql-fundamentals/) — the type system and SDL these RFCs extend
- [07-federation](../07-federation/) — Apollo Federation v2 directives that Composite Schemas will standardize
- [10-schema-validation](../10-schema-validation/) — how Schema Coordinates improve breaking change detection
- [36-future-trends/02-ai-and-graphql-convergence.md](./02-ai-and-graphql-convergence.md) — how AI integration accelerates RFC adoption
- [38-glossary/01-graphql-terms.md](../38-glossary/01-graphql-terms.md) — definitions for all terms used in this document
