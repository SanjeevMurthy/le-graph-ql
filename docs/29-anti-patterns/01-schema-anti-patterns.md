# Schema Anti-Patterns

> Schema design decisions are the hardest to reverse. A poorly designed type committed to a public API will live in client codebases for years. This document covers the ten most common schema-level anti-patterns, why engineers fall into them, and what the correct design looks like.

---

## Table of Contents

1. [The Generic Response Wrapper](#1-the-generic-response-wrapper)
2. [God Schema](#2-god-schema)
3. [REST-Shaped GraphQL](#3-rest-shaped-graphql)
4. [Non-Nullable Everything](#4-non-nullable-everything)
5. [Opaque JSON Scalars](#5-opaque-json-scalars)
6. [Deeply Nested Mutations](#6-deeply-nested-mutations)
7. [Magic String Enums](#7-magic-string-enums)
8. [Pagination Anti-patterns](#8-pagination-anti-patterns)
9. [Version Suffixes](#9-version-suffixes)
10. [Missing Descriptions](#10-missing-descriptions)

---

## 1. The Generic Response Wrapper

**Severity**: High  
**Layer**: Schema Design

### What It Looks Like

```graphql
# Anti-pattern: every mutation returns the same envelope
type Response {
  success: Boolean
  data: JSON
  error: String
  code: Int
}

type Mutation {
  createUser(input: CreateUserInput!): Response
  updateOrder(input: UpdateOrderInput!): Response
  cancelSubscription(id: ID!): Response
}
```

### Why It Happens

Teams migrating from REST carry over the HTTP response envelope (`{ success: true, data: {...} }`) because it's familiar. It feels "safe" — one return type means fewer types to manage. In dynamic languages, it also sidesteps the need to think carefully about what each operation actually returns.

### What Goes Wrong

- **Type safety is destroyed**. The `data: JSON` field is untyped. Codegen tools (graphql-codegen, Apollo Client) generate `any` or `unknown` for this field. Every consumer does runtime casting.
- **Error handling becomes inconsistent**. Clients must check both the GraphQL `errors` array and the `success` field and the `error` string. Three parallel error channels.
- **Tooling breaks**. GraphQL IDEs cannot autocomplete inside a `JSON` field. Documentation portals cannot render the shape of `data`.
- **Partial success is impossible to represent**. If three out of five items in a batch succeed, the `success: Boolean` collapses that to a single bit.

### The Correct Alternative

Use **mutation error unions** — a dedicated success type and dedicated error types per mutation, unified in a union:

```graphql
type CreateUserSuccess {
  user: User!
}

type EmailAlreadyTaken {
  message: String!
  suggestedEmails: [String!]!
}

type InvalidInput {
  fields: [FieldError!]!
}

type FieldError {
  field: String!
  message: String!
}

union CreateUserResult = CreateUserSuccess | EmailAlreadyTaken | InvalidInput

type Mutation {
  createUser(input: CreateUserInput!): CreateUserResult!
}
```

Clients use `__typename` to branch:

```graphql
mutation CreateUser($input: CreateUserInput!) {
  createUser(input: $input) {
    __typename
    ... on CreateUserSuccess {
      user { id email }
    }
    ... on EmailAlreadyTaken {
      message
      suggestedEmails
    }
    ... on InvalidInput {
      fields { field message }
    }
  }
}
```

This pattern is called the **Payload pattern** (used by Shopify's public API). Each mutation has a unique return type. Expected business errors are part of the schema, not the error transport.

---

## 2. God Schema

**Severity**: Medium  
**Layer**: Schema Maintainability

### What It Looks Like

```
schema/
  schema.graphql   # 8,400 lines, 500+ types, owned by nobody
```

```graphql
# Everything in one file: users, orders, products, payments,
# notifications, analytics, admin, internal tooling...
type User { ... }
type Order { ... }
type Product { ... }
type Payment { ... }
type AdminUser { ... }
type InternalAuditLog { ... }
# ... 494 more types
```

### Why It Happens

Schema starts small. The first engineer adds a few types. Nobody establishes file structure or ownership rules. Six months later, 40 engineers are appending to the same file. In monorepo setups, the path of least resistance is always the existing file.

### What Goes Wrong

- **No ownership**: every change touches the same file. PR conflicts on `schema.graphql` become a daily occurrence.
- **No domain isolation**: a change to the `Payment` type can accidentally affect `User` resolution if field names collide.
- **Merge conflicts at scale**: on a team of 40+ engineers, simultaneous schema changes create constant rebase friction.
- **Documentation becomes impossible**: no one can explain what the schema does end-to-end. Onboarding new engineers takes weeks.
- **Test coverage gaps**: it is impossible to test 500 types comprehensively, so nothing is tested.

### The Correct Alternative

**Split the schema by domain** and enforce ownership via CODEOWNERS:

```
schema/
  users/
    user.graphql
    user-mutations.graphql
    user-queries.graphql
  orders/
    order.graphql
    order-mutations.graphql
  products/
    product.graphql
  shared/
    scalars.graphql
    pagination.graphql
    errors.graphql

.github/CODEOWNERS:
  schema/users/     @team-identity
  schema/orders/    @team-commerce
  schema/products/  @team-catalog
```

In a federated architecture, the God Schema anti-pattern naturally resolves — each subgraph owns its slice. For monolithic GraphQL servers, enforce the domain split manually.

---

## 3. REST-Shaped GraphQL

**Severity**: High  
**Layer**: API Design

### What It Looks Like

```graphql
type Query {
  getUser(id: ID!): UserResponse
  getUsers(page: Int, limit: Int): UsersResponse
  getUserByEmail(email: String!): UserResponse
}

type Mutation {
  createUser(input: CreateUserInput!): UserResponse
  updateUser(id: ID!, input: UpdateUserInput!): UserResponse
  deleteUser(id: ID!): DeleteResponse
}

type UserResponse {
  data: User
  status: Int
  message: String
}
```

### Why It Happens

Teams with a REST background map their existing REST routes directly to GraphQL operations. The verbs (`get`, `create`, `update`, `delete`) come from HTTP method conventions. The `UserResponse` envelope mirrors an HTTP response body. This is the path of least resistance when GraphQL is adopted as a "transport replacement" rather than a "schema-first API."

### What Goes Wrong

- **Client fetching defeats the purpose**. Clients must make multiple queries to compose data that GraphQL's traversal model would give them in one operation.
- **No graph traversal**. `getUser` returns a `User` but not their `orders` or `posts` — clients must issue separate `getOrders(userId:)` calls, reproducing REST's N+1 at the client layer.
- **Verb-based names pollute the schema**. GraphQL queries are already verbs in disguise — naming them `getUser` is redundant (`query { getUser }` vs `query { user }`).
- **Envelope types destroy codegen**. The `UserResponse.data` field is typed as `User` but wrapped in a response object — codegen generates deeply nested access patterns.

### The Correct Alternative

Design the schema as a **graph of types**, not a list of endpoints:

```graphql
type Query {
  user(id: ID!): User
  users(filter: UserFilter, first: Int, after: String): UserConnection!
}

type User {
  id: ID!
  email: String!
  orders(first: Int, after: String): OrderConnection!
  posts(first: Int, after: String): PostConnection!
  profile: UserProfile
}

type Mutation {
  createUser(input: CreateUserInput!): CreateUserResult!
  updateUser(id: ID!, input: UpdateUserInput!): UpdateUserResult!
}
```

One query fetches the user and their orders in a single network round-trip. No envelope. Mutations return proper result unions.

---

## 4. Non-Nullable Everything

**Severity**: High  
**Layer**: Schema Resilience

### What It Looks Like

```graphql
type User {
  id: ID!
  email: String!
  firstName: String!
  lastName: String!
  phoneNumber: String!    # not every user has a phone
  avatarUrl: String!      # not every user has an avatar
  address: Address!       # not every user has an address on file
  createdAt: String!
  lastLoginAt: String!    # null if never logged in
}
```

### Why It Happens

Engineers think non-null (`!`) means "required" or "validated." It feels like defensive programming. The reasoning is: "if the field should always exist, mark it non-null to enforce that." In strongly typed languages, non-null feels like compile-time safety.

### What Goes Wrong

In GraphQL, a non-null field that resolves to `null` at runtime causes the **null propagation** mechanism to bubble the error upward. If `phoneNumber` is `String!` but returns `null`:

1. The `phoneNumber` field errors
2. Because its parent `User` is non-null, `User` becomes `null`
3. Because `user` in `Query.user` might be non-null, the entire query returns `null` data
4. The client receives `data: null` with an error — **even though the rest of the user data was perfectly valid**

```json
{
  "data": null,
  "errors": [{ "message": "Cannot return null for non-nullable field User.phoneNumber" }]
}
```

A single missing optional field destroys the entire response.

### The Correct Alternative

Apply the **principle of nullable by default for optional data**:

```graphql
type User {
  id: ID!                  # truly always present — entity identifier
  email: String!           # required for account creation — truly non-null
  firstName: String        # optional — user may not have provided
  lastName: String         # optional
  phoneNumber: String      # optional — not required at signup
  avatarUrl: String        # optional — user may not have set one
  address: Address         # optional — shipping address is optional
  createdAt: String!       # always set by the system
  lastLoginAt: String      # null for accounts that have never logged in
}
```

Reserve `!` for fields that are **contractually guaranteed by the system** — primary keys, system timestamps, fields set at creation time.

---

## 5. Opaque JSON Scalars

**Severity**: High  
**Layer**: Type Safety

### What It Looks Like

```graphql
scalar JSON

type Product {
  id: ID!
  name: String!
  metadata: JSON          # "flexible" — can be anything
  attributes: JSON        # product attributes vary by category
  pricingRules: JSON      # complex nested pricing logic
  customFields: JSON      # per-tenant custom fields
}
```

### Why It Happens

Product data often has genuinely variable shapes — a laptop has `processorSpeed` and `ramGB`, a t-shirt has `sizes` and `colors`. It is tempting to reach for `JSON` to avoid defining a union of product types. Custom fields per tenant are another common driver — the field set is not known at schema design time.

### What Goes Wrong

- **Codegen generates `unknown`**. Every consumer does runtime casting and loses IDE autocomplete.
- **Breaking changes are invisible**. If `metadata` changes its shape, no schema check catches it. Clients break silently at runtime.
- **No documentation**. The schema cannot describe what `metadata` contains. Developers read source code or ask Slack.
- **Security surface**. Untyped data often bypasses input validation — clients can inject arbitrary keys.
- **Query planning is impossible**. The query planner cannot determine which fields inside `JSON` to fetch — it must always fetch the whole blob.

### The Correct Alternative

For variable product types, use **interface + type unions**:

```graphql
interface ProductAttributes {
  category: ProductCategory!
}

type LaptopAttributes implements ProductAttributes {
  category: ProductCategory!
  processorSpeed: Float!
  ramGb: Int!
  storageGb: Int!
}

type ApparelAttributes implements ProductAttributes {
  category: ProductCategory!
  sizes: [String!]!
  colors: [String!]!
  material: String
}

type Product {
  id: ID!
  name: String!
  attributes: ProductAttributes
}
```

For genuinely dynamic custom fields (per-tenant), use a **key-value pair type**:

```graphql
type CustomField {
  key: String!
  value: String!         # serialize complex values; parse on client
  type: CustomFieldType! # STRING, NUMBER, BOOLEAN, DATE
}

type Product {
  id: ID!
  customFields: [CustomField!]!
}
```

---

## 6. Deeply Nested Mutations

**Severity**: Medium  
**Layer**: Mutation Design

### What It Looks Like

```graphql
type Mutation {
  user: UserMutations!
}

type UserMutations {
  profile: ProfileMutations!
}

type ProfileMutations {
  settings: SettingsMutations!
}

type SettingsMutations {
  update(input: SettingsInput!): SettingsResult!
  reset: SettingsResult!
}
```

Used as: `mutation { user { profile { settings { update(input: {...}) { ... } } } } }`

### Why It Happens

Engineers familiar with object-oriented design apply namespace patterns to mutation design. Grouping mutations under `user.profile.settings` feels like a clean object hierarchy. It is also used to avoid top-level mutation namespace pollution.

### What Goes Wrong

- **Mutation execution order is undefined for nested types**. The GraphQL spec guarantees serial execution for **top-level** mutations. Nested mutations execute in field resolution order, which is implementation-defined.
- **Error propagation is confusing**. If `UserMutations` resolver returns null (e.g., user not found), all nested mutations silently return null without a useful error.
- **Query planning is complicated**. Routers and query planners expect mutations at the top level.
- **The nesting is fake namespacing**. There is no semantic benefit to the hierarchy — it is cosmetic.

### The Correct Alternative

Flat mutations with descriptive names:

```graphql
type Mutation {
  updateUserSettings(userId: ID!, input: SettingsInput!): UpdateUserSettingsResult!
  resetUserSettings(userId: ID!): ResetUserSettingsResult!
  updateUserProfile(userId: ID!, input: ProfileInput!): UpdateUserProfileResult!
}
```

If namespace pollution is a concern at scale, federation handles it naturally — each subgraph owns its mutation namespace, and the supergraph merges them.

---

## 7. Magic String Enums

**Severity**: Medium  
**Layer**: Type Safety

### What It Looks Like

```graphql
type Order {
  id: ID!
  status: String!       # "pending" | "processing" | "shipped" | "delivered" | "cancelled"
  priority: String!     # "LOW" | "MEDIUM" | "HIGH" | "URGENT"
  paymentMethod: String # "credit_card" | "paypal" | "bank_transfer" | "crypto"
}

type Query {
  orders(status: String): [Order!]!
}
```

### Why It Happens

The set of valid values is "obvious" to the team at the time of design. Defining an enum feels like unnecessary ceremony. In dynamic languages, enum types add a step to the development workflow. When the values come from a database column or a legacy REST API, it is easier to pass the string through unchanged.

### What Goes Wrong

- **Invalid values at runtime**. Clients can pass `status: "SHIPPPED"` (typo) — the schema accepts it, the resolver breaks at runtime.
- **No introspection value**. Tools and portals cannot show valid values without reading source code or documentation.
- **Refactoring is silent**. Renaming `"pending"` to `"PENDING"` is a breaking change the schema check cannot catch because the field is `String`.
- **Codegen generates `string`**. No compile-time safety in TypeScript/Swift/Kotlin clients.

### The Correct Alternative

```graphql
enum OrderStatus {
  PENDING
  PROCESSING
  SHIPPED
  DELIVERED
  CANCELLED
}

enum OrderPriority {
  LOW
  MEDIUM
  HIGH
  URGENT
}

enum PaymentMethod {
  CREDIT_CARD
  PAYPAL
  BANK_TRANSFER
  CRYPTO
}

type Order {
  id: ID!
  status: OrderStatus!
  priority: OrderPriority!
  paymentMethod: PaymentMethod
}
```

Codegen tools generate exhaustive switch/when/match statements from enum types in TypeScript, Kotlin, and Swift, giving clients compile-time exhaustiveness checks.

---

## 8. Pagination Anti-patterns

**Severity**: High  
**Layer**: API Design

### What It Looks Like

```graphql
# Anti-pattern A: flat list with no pagination
type Query {
  orders: [Order!]!        # returns all orders, always
}

# Anti-pattern B: offset/limit
type Query {
  orders(limit: Int, offset: Int): [Order!]!
}

# Anti-pattern C: inconsistent pagination across types
type Query {
  orders(page: Int, pageSize: Int): OrdersPage
  products(limit: Int, cursor: String): ProductConnection
  users: [User!]!
}
```

### Why It Happens

For small datasets, `[Order!]!` works fine in development. Offset/limit is familiar from SQL and REST. Inconsistency accumulates as different engineers add types at different times without a shared standard.

### What Goes Wrong

- **`[T!]!` with no pagination returns every row**. At 10 million orders, this query kills the database.
- **Offset/limit is unstable under concurrent writes**. If a new order is inserted between page 1 and page 2 fetches, offset 10 skips a record. Clients see duplicate or missing data.
- **Inconsistent pagination prevents generic client utilities**. A React hook that handles pagination must be implemented differently for every collection type.

### The Correct Alternative

Adopt the **Relay Cursor Connection Specification** for all paginated collections:

```graphql
type OrderConnection {
  edges: [OrderEdge!]!
  pageInfo: PageInfo!
  totalCount: Int!
}

type OrderEdge {
  node: Order!
  cursor: String!
}

type PageInfo {
  hasNextPage: Boolean!
  hasPreviousPage: Boolean!
  startCursor: String
  endCursor: String
}

type Query {
  orders(
    first: Int
    after: String
    last: Int
    before: String
    filter: OrderFilter
  ): OrderConnection!
}
```

Cursor-based pagination is stable under inserts and deletes. The `PageInfo` contract is consistent across all collections, enabling generic client utilities. Enforce this pattern via a schema linting rule (`graphql-schema-linter` or custom `graphql-inspector` rules).

---

## 9. Version Suffixes

**Severity**: Medium  
**Layer**: API Evolution

### What It Looks Like

```graphql
type Query {
  user(id: ID!): User
  userV2(id: ID!): UserV2
  userV3(id: ID!): UserV3       # added when V2 was insufficient

  getOrders: [Order!]!
  getOrdersV2(filter: OrderFilter): OrderConnection
}

type User { ... }      # original, 47 fields
type UserV2 { ... }    # same fields + 3 new ones
type UserV3 { ... }    # V2 + 2 more new ones, 1 field renamed
```

### Why It Happens

A field needs to change in a breaking way — a field is renamed, an argument is added, the return type changes. Rather than deprecating and migrating, adding a `V2` variant feels safer because it does not break existing clients.

### What Goes Wrong

- **Schema explodes**. At year 3, the schema has 40 `*V2` and `*V3` variants. No one knows which version is current.
- **Resolver duplication**. Each version has its own resolver, often copy-pasted. Bugs get fixed in `userV3` but not `user` or `userV2`.
- **Clients stay on old versions forever**. Because the old versions still work, clients have no incentive to migrate. The technical debt compounds.
- **Federation composition fails**. Multiple subgraphs returning different versions of `User` causes composition conflicts.

### The Correct Alternative

Use **GraphQL's built-in deprecation mechanism** with migration guides:

```graphql
type User {
  id: ID!
  email: String!

  # Deprecated in favor of displayName (2024-03-01)
  # Migration: use displayName instead
  name: String @deprecated(reason: "Use displayName. Will be removed 2025-01-01.")

  displayName: String!

  # Deprecated pagination style
  ordersList: [Order!]! @deprecated(reason: "Use orders(first:, after:). Will be removed 2025-01-01.")

  orders(first: Int, after: String): OrderConnection!
}
```

Set a **removal date** in the deprecation reason. Use `graphql-inspector` to track deprecated field usage in real queries. Remove fields after the removal date when usage drops to zero.

---

## 10. Missing Descriptions

**Severity**: Low (compounds over time to High)  
**Layer**: Developer Experience

### What It Looks Like

```graphql
type User {
  id: ID!
  email: String!
  status: UserStatus!
  tier: Int!
  flags: Int!
  meta: JSON
}

type Query {
  user(id: ID!): User
  users(filter: UserFilter, first: Int, after: String): UserConnection!
}
```

### Why It Happens

Descriptions feel like optional ceremony, especially early in a project. Engineers know what the fields mean because they wrote them. Under deadline pressure, documentation is the first thing cut.

### What Goes Wrong

- **Documentation portals are empty**. Apollo Studio, Stellate, and Backstage schema browsers display blank descriptions for every type and field. Teams cannot use them.
- **LLM tool use fails**. When an AI assistant is given the GraphQL schema as a tool spec, missing descriptions mean the model cannot determine which fields to query. LLM-powered GraphQL clients (increasingly common) degrade without descriptions.
- **Onboarding friction**. New engineers cannot understand the schema without asking a colleague. Knowledge is locked in people's heads, not the schema.
- **`tier: Int` and `flags: Int` are incomprehensible**. What does tier 3 mean? Is flags a bitmask? Nobody knows.

### The Correct Alternative

Treat schema descriptions as part of the API contract, enforced in CI:

```graphql
"""
A registered user account. Represents a human or service account
that has authenticated with the platform.
"""
type User {
  "Globally unique identifier. Stable for the lifetime of the account."
  id: ID!

  "Primary email address. Used for login and notifications. Unique across all accounts."
  email: String!

  """
  Account status. ACTIVE means the user can authenticate.
  SUSPENDED means login is blocked pending review.
  DELETED means the account has been soft-deleted; data is retained for 90 days.
  """
  status: UserStatus!

  """
  Subscription tier: 1 = Free, 2 = Pro, 3 = Enterprise.
  Controls rate limits, feature flags, and SLA guarantees.
  """
  tier: Int!

  """
  Unix timestamp of most recent successful authentication.
  Null if the account has never logged in (e.g., invited but not activated).
  """
  lastLoginAt: String
}
```

Enforce in CI with `graphql-schema-linter` rule `descriptions-are-required` or a custom `graphql-inspector` check. Fail the PR if any public type, field, or enum value is missing a description.

---

## Summary

| Anti-Pattern | Root Cause | Primary Risk | Fix Complexity |
|---|---|---|---|
| Generic Response Wrapper | REST migration habits | Type safety loss | High (client migration required) |
| God Schema | No ownership rules | Unmaintainable | Medium (file split + CODEOWNERS) |
| REST-Shaped GraphQL | Mental model carryover | Defeats GraphQL value | High (redesign required) |
| Non-Nullable Everything | Misunderstood type safety | Null propagation failures | Medium (nullability audit) |
| Opaque JSON Scalars | Flexibility over safety | Silent breaking changes | High (type modeling required) |
| Deeply Nested Mutations | OOP namespace habits | Undefined execution order | Medium (flatten mutations) |
| Magic String Enums | Laziness / legacy data | Runtime errors | Low (add enum types) |
| Pagination Anti-patterns | SQL habits / small data | Scale failures | Medium (adopt Relay spec) |
| Version Suffixes | Fear of breaking changes | Schema explosion | Medium (deprecation process) |
| Missing Descriptions | Documentation debt | Tooling failure | Low (progressive backfill) |

---

## References

- [GraphQL Specification — Non-Null Types](https://spec.graphql.org/October2021/#sec-Non-Null)
- [Relay Cursor Connection Specification](https://relay.dev/graphql/connections.htm)
- [Shopify Payload Pattern](https://shopify.engineering/graphql-mutation-design)
- [graphql-schema-linter](https://github.com/cjoudrey/graphql-schema-linter)
- [graphql-inspector](https://the-guild.dev/graphql/inspector)

## Related Topics

- [Schema Design](../03-schema-design/README.md)
- [Best Practices](../28-best-practices/README.md)
- [Schema Governance](../09-schema-governance/README.md)
- [CI/CD Automation](../11-ci-cd-automation/README.md)
