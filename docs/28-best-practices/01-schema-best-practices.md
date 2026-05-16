# Schema Best Practices

> **Purpose:** Twenty-plus schema design rules for production GraphQL APIs. Each rule is stated as a directive, backed by rationale, and followed by a counter-example that shows the failure mode the rule prevents. SDL snippets are provided throughout. Apply these rules at schema design time — retrofitting them later is expensive.

---

## BP-S-01: Nullable by Default; Non-Null is a Contract Guarantee

**Rule:** Make fields nullable (`String`) unless you can guarantee the value will always be present at runtime, in every version of every resolver, forever. Non-null (`String!`) is a strong contract: if the resolver returns `null`, the GraphQL execution engine nulls out the entire parent object and propagates up the tree.

**Rationale:** Runtime `null` on a non-null field does not just fail that field — it destroys the parent. In a deeply nested schema, one bad non-null field can null out the entire response. Nullable fields degrade gracefully; non-null fields cascade failures.

Non-null is appropriate when the value is structurally guaranteed by the system — an entity's `id`, a type discriminant, or an enum with no absent state. It is not appropriate for fields that might be absent because of business logic, missing data, or future schema evolution.

**Counter-example:**

```graphql
# BAD: Non-null used as default, with no runtime guarantee
type Order {
  id: ID!
  customer: Customer!       # What if the customer was deleted (soft delete)?
  shippingAddress: Address! # What if the order was placed before addresses were required?
  completedAt: DateTime!    # Pending orders have no completion time — this WILL null out
}
```

When `completedAt` is `null` for a pending order, the runtime null propagates: `customer` is destroyed even if it was present. The entire `Order` object becomes `null`.

**Correct:**

```graphql
type Order {
  id: ID!                    # ID is always present — non-null is correct
  customer: Customer         # May be null if the customer account was deleted
  shippingAddress: Address   # Nullable until order reaches 'shipped' state
  completedAt: DateTime      # Null until order completes — semantically correct
}
```

---

## BP-S-02: PascalCase Types, camelCase Fields, SCREAMING_SNAKE_CASE Enums

**Rule:** Follow GraphQL community conventions without exception. Type names use PascalCase (`OrderLineItem`). Field names use camelCase (`createdAt`, `lineItems`). Enum values use SCREAMING_SNAKE_CASE (`PENDING_PAYMENT`). Mutation names use verb-object form with camelCase (`createOrder`, `cancelOrder`, `updateShippingAddress`).

**Rationale:** Inconsistent naming creates cognitive load for every engineer reading the schema. Codegen tools (GraphQL Code Generator, Relay, Apollo Client) assume these conventions. Violating them produces generated code that requires manual transformation layers.

**Counter-example:**

```graphql
# BAD: Mixed conventions, no coherent style
type order_line_item {   # snake_case type
  Created_At: DateTime   # Mixed case field
  LineItemId: ID!        # PascalCase field
}

enum orderStatus {       # camelCase enum
  pending_payment        # snake_case value
  Shipped                # Mixed case value
}

type Mutation {
  OrderCreate(input: OrderInput!): Order  # object-verb, not verb-object
}
```

**Correct:**

```graphql
type OrderLineItem {
  id: ID!
  createdAt: DateTime!
  quantity: Int!
  unitPrice: Money!
}

enum OrderStatus {
  PENDING_PAYMENT
  CONFIRMED
  SHIPPED
  DELIVERED
  CANCELLED
}

type Mutation {
  createOrder(input: CreateOrderInput!): CreateOrderResult!
  cancelOrder(input: CancelOrderInput!): CancelOrderResult!
}
```

---

## BP-S-03: Always Use Cursor-Based Pagination for Lists That Can Grow

**Rule:** Any list that can contain more than 10 items in production must use Relay-style cursor pagination (`first`, `after`, `last`, `before` arguments; `Connection`, `Edge`, `PageInfo` types). Never use offset-based pagination (`limit` + `offset`) for lists that grow over time.

**Rationale:** Offset pagination requires the database to scan and discard `offset` rows before returning `limit` rows. At offset 10,000, this is a full-table scan of 10,000 rows per page. It also breaks under concurrent inserts: if a new row is inserted between page 1 and page 2 fetches, a row is duplicated across pages, and a row falls through the gap. Cursor-based pagination is O(1) per page and stable under concurrent writes.

**Counter-example:**

```graphql
# BAD: Offset pagination — will not scale
type Query {
  orders(limit: Int, offset: Int): [Order!]!
}
```

```sql
-- What this generates at page 500 with limit 20:
SELECT * FROM orders ORDER BY created_at DESC LIMIT 20 OFFSET 10000;
-- Full scan of 10,020 rows to return 20
```

**Correct:**

```graphql
type Query {
  orders(first: Int, after: String, last: Int, before: String): OrderConnection!
}

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
```

The `cursor` is an opaque base64-encoded value encoding the sort key and id, enabling keyset queries:

```sql
SELECT * FROM orders
WHERE (created_at, id) < (decode_cursor(after))
ORDER BY created_at DESC, id DESC
LIMIT 20;
```

---

## BP-S-04: Every Public Type and Field Must Have a Description

**Rule:** All types, fields, arguments, enums, and enum values that are part of the public schema must have a `"""triple-quoted description"""`. Description-less schemas are incomplete and unmaintainable.

**Rationale:** Descriptions are consumed by: client portals (GraphOS Explorer, Apollo Studio), developer documentation generators, LLM-based code assistants, and GraphQL Code Generator (which can emit JSDoc from descriptions). A schema without descriptions is a schema that requires engineers to read source code to understand intent. At 50+ subgraphs, this is operationally impossible.

**Counter-example:**

```graphql
# BAD: No descriptions anywhere
type Order {
  id: ID!
  status: OrderStatus!
  total: Money!
  customer: Customer
}

enum OrderStatus {
  PENDING_PAYMENT
  CONFIRMED
  SHIPPED
}
```

**Correct:**

```graphql
"""
A purchase placed by a customer. An Order moves through a lifecycle defined by
OrderStatus. Orders in PENDING_PAYMENT status are not committed until payment
is captured. Orders are immutable after reaching DELIVERED or CANCELLED status.
"""
type Order {
  """The globally unique identifier for this order. Stable and immutable."""
  id: ID!

  """
  The current lifecycle status of this order. See OrderStatus for valid
  transitions. Status changes are reflected within 5 seconds of the event.
  """
  status: OrderStatus!

  """
  The total amount charged to the customer including tax and shipping.
  Does not include refunds. See refundTotal for the refunded amount.
  """
  total: Money!

  """
  The customer who placed this order. Null if the customer account has been
  deleted since the order was placed (orders are retained for 7 years).
  """
  customer: Customer
}
```

---

## BP-S-05: Never Reuse Output Types as Input Types

**Rule:** Define separate input types for mutations. Never use a type defined as an output type as a mutation argument. Output types (`type`) and input types (`input`) serve different contracts.

**Rationale:** Output types may contain fields that are server-computed (`createdAt`, `updatedAt`, `id`, `version`). Using an output type as input requires clients to supply those fields, or requires the server to silently ignore them — neither is correct. Input types also enable distinct validation rules per mutation (a `CreateProductInput` requires different fields than an `UpdateProductInput`). Sharing types couples the read and write contracts permanently.

**Counter-example:**

```graphql
# BAD: Output type used directly as input argument
type Product {
  id: ID!
  name: String!
  price: Money!
  createdAt: DateTime!
  updatedAt: DateTime!
  publishedBy: User!
}

type Mutation {
  # Client must provide id, createdAt, updatedAt, publishedBy — nonsense
  createProduct(product: Product): Product
}
```

**Correct:**

```graphql
type Product {
  id: ID!
  name: String!
  price: Money!
  createdAt: DateTime!
  updatedAt: DateTime!
  publishedBy: User!
}

"""Input for creating a new product. Server assigns id, createdAt, updatedAt."""
input CreateProductInput {
  name: String!
  price: MoneyInput!
  categoryId: ID!
  description: String
}

"""Input for updating an existing product. All fields are optional."""
input UpdateProductInput {
  name: String
  price: MoneyInput
  description: String
}

type Mutation {
  createProduct(input: CreateProductInput!): CreateProductResult!
  updateProduct(id: ID!, input: UpdateProductInput!): UpdateProductResult!
}
```

---

## BP-S-06: Use Error Unions on Mutations Instead of Throwing

**Rule:** Mutation return types should be union types that enumerate all expected error states. Do not use `throw` for expected business errors (validation failures, insufficient inventory, conflict states). Reserve exceptions for unexpected infrastructure failures.

**Rationale:** When a mutation throws, the error surfaces in the top-level `errors` array with an opaque message. The type system cannot model this — clients cannot statically handle `InsufficientInventoryError` differently from `ValidationError`. Error unions make the error contract explicit, typed, and discoverable. Clients can write exhaustive switch statements. Codegen produces typed error handling code.

**Counter-example:**

```graphql
# BAD: Mutation throws for expected business errors
type Mutation {
  createOrder(input: CreateOrderInput!): Order!
  # If inventory is insufficient, this throws — errors array gets an opaque message
  # Clients cannot distinguish inventory errors from auth errors from validation errors
}
```

**Correct:**

```graphql
type Mutation {
  createOrder(input: CreateOrderInput!): CreateOrderResult!
}

union CreateOrderResult =
  | CreateOrderSuccess
  | ValidationError
  | InsufficientInventoryError
  | PaymentDeclinedError

type CreateOrderSuccess {
  order: Order!
  estimatedDeliveryDate: Date!
}

type ValidationError {
  """Human-readable message safe to display in UI."""
  message: String!
  """Field-level validation failures."""
  fieldErrors: [FieldError!]!
}

type FieldError {
  field: String!
  message: String!
}

type InsufficientInventoryError {
  message: String!
  """Line items that could not be fulfilled, with available quantities."""
  unavailableItems: [UnavailableItem!]!
}

type PaymentDeclinedError {
  message: String!
  """Decline reason code from the payment processor."""
  declineCode: String!
}
```

---

## BP-S-07: Deprecate Before Remove; Always Provide a Replacement in the Reason

**Rule:** Mark fields and types `@deprecated` at least one full release cycle (minimum 30 days for internal clients, 90 days for external clients) before removal. The `reason` argument must name the replacement.

**Rationale:** Field removal is a breaking change. Clients that query a removed field receive a runtime error — even if the field was unused in their UI, their query is still sent. Deprecation gives clients time to migrate and is visible in introspection, IDEs, and analytics (GraphOS can show deprecated field usage by client).

**Counter-example:**

```graphql
# BAD: Field removed without deprecation. Clients break immediately.
type User {
  id: ID!
  # name field deleted from the schema in this PR
  email: String!
}
```

```graphql
# ALSO BAD: Deprecated without a replacement — clients cannot migrate
type User {
  id: ID!
  name: String! @deprecated(reason: "Do not use")
  email: String!
}
```

**Correct:**

```graphql
type User {
  id: ID!

  """
  The user's full name as a single string.
  @deprecated Use firstName and lastName for localization-safe name handling.
  """
  name: String! @deprecated(reason: "Use firstName and lastName instead. name will be removed in schema version 2025-Q3.")

  """The user's given name (first name). Replaces the deprecated name field."""
  firstName: String!

  """The user's family name (last name). Replaces the deprecated name field."""
  lastName: String!

  email: String!
}
```

---

## BP-S-08: Use Custom Scalars for Constrained String Types

**Rule:** Define custom scalars for string values with a well-defined format or constraint: `Email`, `UUID`, `PhoneNumber`, `URL`, `ISO8601Date`, `CurrencyCode`, `CountryCode`. Do not use raw `String` for values with a format contract.

**Rationale:** `String` provides no information about format to clients or codegen tools. A field typed `Email` self-documents its format, can be validated by scalar coercion, and generates a distinct type in TypeScript code. Schema validators (graphql-scalars library) can enforce the format server-side without custom validation logic in every resolver.

**Counter-example:**

```graphql
# BAD: All strings — no format information, no validation
type Customer {
  id: String!         # Is this a UUID? An opaque string? An integer ID?
  email: String!      # No validation of email format
  phone: String!      # Which phone number format? E.164? Local?
  website: String     # No URL validation
  countryCode: String # ISO 3166-1 alpha-2? alpha-3? No way to know
}
```

**Correct:**

```graphql
scalar UUID
scalar Email
scalar PhoneNumber
scalar URL
scalar CountryCode  @specifiedBy(url: "https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2")
scalar CurrencyCode @specifiedBy(url: "https://en.wikipedia.org/wiki/ISO_4217")

type Customer {
  id: UUID!
  email: Email!
  phone: PhoneNumber
  website: URL
  countryCode: CountryCode
  preferredCurrency: CurrencyCode!
}
```

Server-side scalar implementation (using `graphql-scalars`):

```typescript
import { EmailAddressResolver, UUIDResolver, PhoneNumberResolver, URLResolver } from 'graphql-scalars';

const resolvers = {
  UUID: UUIDResolver,
  Email: EmailAddressResolver,
  PhoneNumber: PhoneNumberResolver,
  URL: URLResolver,
};
```

---

## BP-S-09: Prefer Enums Over Strings for Bounded Sets

**Rule:** Any field whose valid values form a closed, known set must be an enum type, not a `String`. This applies to status fields, type discriminants, lifecycle states, and category codes.

**Rationale:** `String` typed status fields allow invalid values to pass schema validation (`status: "shiped"` is a valid `String`). Enums enforce valid values at the schema layer, appear in client codegen as TypeScript enums or union types, and make exhaustive switch statements possible. When a new status is added, the schema change forces clients to handle the new case.

**Counter-example:**

```graphql
# BAD: String used for a bounded set
type Order {
  status: String!  # "pending"? "PENDING"? "Pending"? "pending_payment"?
}
```

**Correct:**

```graphql
"""
The lifecycle status of an order. Status transitions follow:
PENDING_PAYMENT → PAYMENT_CAPTURED → PROCESSING → SHIPPED → DELIVERED
Any status can transition to CANCELLED before SHIPPED.
"""
enum OrderStatus {
  """Order created; payment not yet captured."""
  PENDING_PAYMENT

  """Payment successfully captured; order queued for fulfillment."""
  PAYMENT_CAPTURED

  """Order is being picked and packed."""
  PROCESSING

  """Order handed to carrier. trackingNumber is now available."""
  SHIPPED

  """Order confirmed delivered by carrier."""
  DELIVERED

  """Order cancelled. If payment was captured, a refund has been initiated."""
  CANCELLED
}
```

---

## BP-S-10: Never Use Version Suffixes — Use Deprecation and Aliasing

**Rule:** Field names must never include version suffixes (`getUserV2`, `productV3`, `order_new`). Use deprecation with a replacement reference to evolve fields. Use field aliasing at the client for backward-compatible field access during migration windows.

**Rationale:** Version suffixes accumulate until the schema is littered with `getUserV2`, `getUserV3`, `getUserV4`. Clients cannot know which version is current. The schema becomes a history of design decisions rather than a model of the domain. GraphQL's built-in deprecation mechanism handles field evolution correctly.

**Counter-example:**

```graphql
# BAD: Version suffixes replacing deprecation
type Query {
  getUser(id: ID!): User
  getUserV2(id: ID!): UserV2       # What changed in V2?
  getUserV3(id: ID!): UserV3       # And V3?
  product(id: ID!): Product
  product_new(id: ID!): ProductNew # "new" is not a version
}
```

**Correct:**

```graphql
type Query {
  """
  Fetch a user by their globally unique ID.
  """
  user(id: ID!): User

  """
  @deprecated Use user(id) instead. getUser will be removed in 2025-Q3.
  """
  getUser(id: ID!): User @deprecated(reason: "Use user(id: ID!) instead. Removal: 2025-Q3")
}
```

---

## BP-S-11: Flatten Mutations — Avoid Nested Mutation Paths

**Rule:** All mutations must be at the top level of the `Mutation` type. Do not nest mutations under namespace objects. Nested mutations create ambiguity about execution order and bypass standard tooling assumptions.

**Rationale:** GraphQL mutation fields execute sequentially (unlike query fields which may execute in parallel). Nesting mutations under namespace types breaks this guarantee: when you return a namespace object from a field, its child resolvers execute as object fields (potentially in parallel), not as sequential mutation steps. Apollo Client, Relay, and code generators also assume mutations are top-level.

**Counter-example:**

```graphql
# BAD: Nested mutations under namespace objects
type Mutation {
  orders: OrderMutations!
  catalog: CatalogMutations!
}

type OrderMutations {
  create(input: CreateOrderInput!): CreateOrderResult!
  cancel(id: ID!): CancelOrderResult!
}

type CatalogMutations {
  createProduct(input: CreateProductInput!): CreateProductResult!
}
```

**Correct:**

```graphql
# GOOD: All mutations at the top level with clear naming
type Mutation {
  # Order mutations
  createOrder(input: CreateOrderInput!): CreateOrderResult!
  cancelOrder(input: CancelOrderInput!): CancelOrderResult!
  updateOrderShippingAddress(input: UpdateOrderShippingAddressInput!): UpdateOrderShippingAddressResult!

  # Catalog mutations
  createProduct(input: CreateProductInput!): CreateProductResult!
  updateProduct(input: UpdateProductInput!): UpdateProductResult!
  archiveProduct(input: ArchiveProductInput!): ArchiveProductResult!
}
```

---

## BP-S-12: Use `@specifiedBy` for Custom Scalars

**Rule:** Every custom scalar must include a `@specifiedBy(url: "...")` directive pointing to the canonical specification for its format. This is required for schema portability and correct codegen behavior.

**Rationale:** Without `@specifiedBy`, a custom scalar is an opaque type — clients and tools cannot determine its format from the schema alone. Schema registries, documentation generators, and clients rely on `@specifiedBy` to produce correct serialization and validation code. The GraphQL spec requires `@specifiedBy` for scalars that have a defined format.

**Correct:**

```graphql
"""
An RFC 3339 compliant date-time string (e.g., "2024-01-15T09:00:00Z").
Always returned in UTC. Clients should convert to local time for display.
"""
scalar DateTime @specifiedBy(url: "https://scalars.graphql.org/andimarek/date-time")

"""
An RFC 5321 compliant email address.
"""
scalar Email @specifiedBy(url: "https://html.spec.whatwg.org/multipage/input.html#valid-e-mail-address")

"""
An RFC 4122 v4 UUID in canonical string form: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
"""
scalar UUID @specifiedBy(url: "https://tools.ietf.org/html/rfc4122")

"""
An E.164 formatted phone number (e.g., "+15555550100").
"""
scalar PhoneNumber @specifiedBy(url: "https://www.itu.int/rec/T-REC-E.164/en")
```

---

## BP-S-13: Model Money with a Structured Type, Not Float

**Rule:** Never represent monetary values as `Float`. Define a `Money` type with `amount` (integer cents or smallest denomination) and `currency` (ISO 4217 code). Never represent money as a floating-point number.

**Rationale:** Floating-point arithmetic is lossy. `0.1 + 0.2 !== 0.3` in IEEE 754. Financial calculations using floats accumulate rounding errors that become real money at scale. Integer arithmetic in the smallest currency denomination is exact. The `Money` type also makes currency explicit — a scalar `Float` price field has no currency information.

**Counter-example:**

```graphql
# BAD: Float price with no currency information
type Product {
  id: ID!
  price: Float!  # Floating-point? What currency? No guarantees.
}
```

**Correct:**

```graphql
"""
A monetary value with currency. amount is in the smallest denomination
of the currency (cents for USD, pence for GBP, yen for JPY which has
no minor denomination). Always display using currency-aware formatting.
"""
type Money {
  """Amount in the smallest denomination (integer). 1000 = $10.00 USD."""
  amount: Int!

  """ISO 4217 currency code (e.g., "USD", "EUR", "GBP", "JPY")."""
  currency: CurrencyCode!
}

input MoneyInput {
  amount: Int!
  currency: CurrencyCode!
}

type Product {
  id: ID!
  name: String!
  price: Money!
  compareAtPrice: Money
}
```

---

## BP-S-14: Design for Forward Compatibility — No Structural Assumptions in Field Names

**Rule:** Do not bake structural assumptions into field names. Names like `primaryEmail`, `secondaryEmail`, `email3` signal that the schema was designed around current data structure rather than the domain model.

**Rationale:** When business requirements change (users get multiple emails), the names become misleading and migration is a breaking change. Instead, model the domain concept and let the type system carry the structure.

**Counter-example:**

```graphql
# BAD: Structural assumptions baked into field names
type User {
  primaryEmail: String!
  secondaryEmail: String
  primaryPhone: String
  secondaryPhone: String
  homeAddress: Address
  workAddress: Address
  billingAddress: Address
}
```

**Correct:**

```graphql
type User {
  id: ID!
  """All verified email addresses for this user. First entry is the primary."""
  emails: [UserEmail!]!
  """All phone numbers for this user."""
  phoneNumbers: [UserPhoneNumber!]!
  """All addresses on file. Filter by type for specific address purposes."""
  addresses: [UserAddress!]!
}

type UserEmail {
  address: Email!
  isPrimary: Boolean!
  isVerified: Boolean!
  verifiedAt: DateTime
}

enum UserAddressType {
  HOME
  WORK
  BILLING
  SHIPPING
}

type UserAddress {
  id: UUID!
  type: UserAddressType!
  address: Address!
  isDefault: Boolean!
}
```

---

## BP-S-15: Use Interfaces for Polymorphic Types With Shared Fields

**Rule:** When multiple types share a common set of fields and semantics, define an interface. Use union types only when the member types share no fields.

**Rationale:** Interfaces allow clients to query shared fields without inline fragments, making queries shorter and codegen output leaner. Unions require inline fragments for every field access, which is verbose. If two types both have `id`, `createdAt`, and `status`, those fields belong in an interface.

**Correct:**

```graphql
"""Common fields for all timeline events."""
interface TimelineEvent {
  id: UUID!
  occurredAt: DateTime!
  actor: Actor!
}

"""An order status changed."""
type OrderStatusChangedEvent implements TimelineEvent {
  id: UUID!
  occurredAt: DateTime!
  actor: Actor!
  previousStatus: OrderStatus!
  newStatus: OrderStatus!
}

"""A note was added to the order."""
type OrderNoteAddedEvent implements TimelineEvent {
  id: UUID!
  occurredAt: DateTime!
  actor: Actor!
  note: String!
  isInternal: Boolean!
}

type Order {
  id: ID!
  timeline: [TimelineEvent!]!
}
```

---

## BP-S-16: Never Expose Internal IDs Directly — Use Opaque Global IDs

**Rule:** All `id` fields must be opaque, globally unique identifiers. Use Relay global IDs (base64 of `TypeName:databaseId`) or UUID v4. Never expose raw database sequence integers as `ID` fields.

**Rationale:** Raw database integer IDs enable enumeration attacks (fetch record 1, 2, 3, ...). They also expose your database implementation and prevent future migration to a different ID scheme. Opaque global IDs convey no information about the underlying storage and are safe to expose publicly.

**Counter-example:**

```graphql
# BAD: Database integer IDs exposed
type Order {
  id: Int!  # "Give me orders 1 through 10000" is now trivial for an attacker
}
```

**Correct:**

```graphql
type Order {
  """
  Globally unique, opaque identifier. Format: base64("Order:<uuid>").
  Use this ID to reference this order in mutations and other queries.
  Do not attempt to parse or construct this value.
  """
  id: ID!
}
```

Server-side Relay global ID implementation:

```typescript
import { toGlobalId, fromGlobalId } from 'graphql-relay';

// Encoding: "Order" + UUID → base64
const orderId = toGlobalId('Order', order.uuid);

// Decoding in a resolver argument
const { type, id: uuid } = fromGlobalId(args.id);
if (type !== 'Order') throw new UserInputError('Invalid order ID');
```

---

## BP-S-17: Separate Query and Subscription Schemas for Real-Time Data

**Rule:** Define subscription types only for events that are genuinely real-time requirements (live order status, live auction prices, collaborative editing). Do not add subscriptions to fields that can be polled without UX degradation.

**Rationale:** Subscriptions hold open WebSocket connections, consuming server resources proportional to the number of connected clients. Each subscription topic requires a pub/sub infrastructure component (Redis Pub/Sub, Kafka, or native cluster subscriptions). Over-using subscriptions creates capacity planning complexity without proportional user value.

**Correct:**

```graphql
type Subscription {
  """
  Real-time order status updates. Subscribe while the user is on the order
  tracking page. Closes automatically when the order reaches DELIVERED
  or CANCELLED status. Use orders query for historical data.
  """
  orderStatusUpdated(orderId: ID!): OrderStatusUpdatedEvent!

  """
  Live inventory level for a product. Subscribe during high-demand periods
  (flash sales). Poll using product query for non-time-critical inventory.
  """
  productInventoryChanged(productId: ID!): ProductInventoryChangedEvent!
}

type OrderStatusUpdatedEvent {
  order: Order!
  previousStatus: OrderStatus!
  newStatus: OrderStatus!
  updatedAt: DateTime!
}
```

---

## BP-S-18: Use Input Validation Constraints in Descriptions — Never Silently Coerce

**Rule:** Document all constraints on input fields in their description. If an input value will be rejected (too long, out of range, invalid format), the schema must document this explicitly. Never silently coerce invalid input to a valid value.

**Rationale:** Silent coercion (truncating a string, clamping a number) produces surprising behavior that is invisible to clients and impossible to debug. Explicit validation with documented constraints lets clients build correct UIs. When validation fails, return a `ValidationError` union member (see BP-S-06) with field-level error detail.

**Correct:**

```graphql
input CreateProductInput {
  """
  Product name. Required. 1–200 characters. Must be unique within the
  catalog. Returns ValidationError.DUPLICATE_NAME if name is already taken.
  """
  name: String!

  """
  Product description. Optional. Maximum 10,000 characters.
  Supports Markdown. HTML is stripped server-side.
  """
  description: String

  """
  Price in smallest currency denomination (cents for USD).
  Must be greater than 0. Maximum: 99,999,999 (≈$1M USD).
  """
  price: MoneyInput!

  """
  Quantity available for purchase. Must be 0 or greater.
  """
  initialInventory: Int!

  """
  ISO 3166-1 alpha-2 country code for the product's country of origin.
  Required for customs declarations on international shipments.
  """
  countryOfOrigin: CountryCode!
}
```

---

## BP-S-19: Group Related Mutations With a Common Prefix

**Rule:** When a domain has multiple mutations, prefix them consistently with the domain object name: `createOrder`, `cancelOrder`, `updateOrderStatus` — not `createOrder`, `cancelPurchase`, `changeOrderState`. Consistency makes the schema self-documenting.

**Rationale:** Inconsistent mutation naming forces engineers to search the schema to find the mutation they need. Consistent prefixes make the mutation surface predictable. IDE autocomplete surfaces all order mutations when the engineer types `order`.

**Correct:**

```graphql
type Mutation {
  # Order lifecycle
  createOrder(input: CreateOrderInput!): CreateOrderResult!
  confirmOrder(input: ConfirmOrderInput!): ConfirmOrderResult!
  cancelOrder(input: CancelOrderInput!): CancelOrderResult!
  updateOrderShippingAddress(input: UpdateOrderShippingAddressInput!): UpdateOrderShippingAddressResult!

  # Payment
  capturePayment(input: CapturePaymentInput!): CapturePaymentResult!
  refundPayment(input: RefundPaymentInput!): RefundPaymentResult!
  voidPayment(input: VoidPaymentInput!): VoidPaymentResult!

  # Catalog
  createProduct(input: CreateProductInput!): CreateProductResult!
  updateProduct(input: UpdateProductInput!): UpdateProductResult!
  archiveProduct(input: ArchiveProductInput!): ArchiveProductResult!
  restoreProduct(input: RestoreProductInput!): RestoreProductResult!
}
```

---

## BP-S-20: Always Include a `node` Root Field for Entity Lookup

**Rule:** Implement the Relay Node interface and a top-level `node(id: ID!): Node` query. Every entity type in your schema should implement `Node`.

**Rationale:** The Relay `node` interface provides a universal, predictable way to fetch any entity by its global ID. This enables client-side cache normalization (Apollo Client, Relay), deep-link refetching, and efficient cache invalidation after mutations. Without `node`, every entity type requires its own root field, cluttering the `Query` type.

**Correct:**

```graphql
"""Relay Node interface. All entity types implement this."""
interface Node {
  """Globally unique, opaque entity identifier."""
  id: ID!
}

type Query {
  """Fetch any entity by its globally unique Node ID."""
  node(id: ID!): Node

  # Domain-specific root fields for common access patterns
  order(id: ID!): Order
  product(id: ID!): Product
  user(id: ID!): User
}

type Order implements Node {
  id: ID!
  status: OrderStatus!
  total: Money!
}

type Product implements Node {
  id: ID!
  name: String!
  price: Money!
}
```

---

## BP-S-21: Avoid Input Types With More Than 10 Fields — Decompose Into Nested Inputs

**Rule:** If an input type has more than 10 fields, decompose it into logical sub-inputs. A `CreateOrderInput` with 20 fields should be split into `CreateOrderInput` (core order fields) + `ShippingDetailsInput` + `PaymentDetailsInput`.

**Rationale:** Large input types are difficult to construct correctly on the client and difficult to validate server-side. They also tend to accumulate optional fields over time, making it unclear which combinations are valid. Nested input types model the domain structure and make validation logic composable.

**Counter-example:**

```graphql
# BAD: 20-field flat input — unclear which fields are required together
input CreateOrderInput {
  customerId: ID!
  lineItems: [LineItemInput!]!
  shippingStreet: String!
  shippingCity: String!
  shippingState: String!
  shippingZip: String!
  shippingCountry: CountryCode!
  billingStreet: String!
  billingCity: String!
  billingState: String!
  billingZip: String!
  billingCountry: CountryCode!
  cardNumber: String!
  cardExpiry: String!
  cardCvv: String!
  giftMessage: String
  promoCode: String
  deliveryInstructions: String
  preferredDeliveryDate: Date
}
```

**Correct:**

```graphql
input CreateOrderInput {
  customerId: ID!
  lineItems: [LineItemInput!]!
  shippingAddress: AddressInput!
  billingAddress: AddressInput
  payment: PaymentMethodInput!
  preferences: OrderPreferencesInput
}

input AddressInput {
  street: String!
  city: String!
  state: String!
  postalCode: String!
  country: CountryCode!
}

input PaymentMethodInput {
  token: String!  # Tokenized by payment provider SDK client-side
  billingName: String!
}

input OrderPreferencesInput {
  giftMessage: String
  promoCode: String
  deliveryInstructions: String
  preferredDeliveryDate: Date
}
```

---

## References and Related Topics

- [GraphQL Specification](https://spec.graphql.org/) — the authoritative reference for all SDL constructs
- [Relay Cursor Connections Specification](https://relay.dev/graphql/connections.htm) — cursor pagination specification
- [Relay Global Object Identification](https://relay.dev/graphql/objectidentification.htm) — Node interface and global IDs
- [graphql-scalars](https://the-guild.dev/graphql/scalars) — community scalar implementations (Email, UUID, PhoneNumber, etc.)
- [Chapter 03: Schema Design](../03-schema-design/README.md) — extended schema design reference
- [Chapter 09: Schema Governance](../09-schema-governance/README.md) — enforcing these rules via linting and CI
- [Chapter 10: Schema Validation](../10-schema-validation/README.md) — automated validation tooling
- [02-resolver-best-practices.md](./02-resolver-best-practices.md) — resolver-level rules
- [Anti-Patterns](../29-anti-patterns/README.md) — documented failures for each practice violated
