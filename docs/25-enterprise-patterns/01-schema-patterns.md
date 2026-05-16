# Schema Patterns

> **Purpose:** This document covers seven schema-level design patterns for enterprise GraphQL. Schema decisions are permanent in the sense that they form a public contract with clients. These patterns address the most consequential choices: how to paginate, how to version safely, how to model errors, and how to express type hierarchies. Each pattern is documented with a working SDL example, trade-offs, and explicit guidance on when to apply it.

---

## Pattern 1: Relay Specification

### Problem

Every team that builds a paginated list field invents their own pagination contract. One team returns `items: [Product!]!` with a `nextPage: Int`. Another uses `data: [Order!]!` with `cursor: String`. A third uses `results: [User!]!` with `hasMore: Boolean`. Clients must implement different pagination logic for every list field. Generic tooling (Apollo Client's `InMemoryCache`, Relay client) cannot automatically normalize paginated results without a predictable shape.

### Solution

Adopt the [Relay Cursor Connections Specification](https://relay.dev/graphql/connections.htm) for all paginated list fields:

```graphql
# Every paginated list follows the Connection/Edge/Node shape
type Query {
  products(first: Int, after: String, last: Int, before: String): ProductConnection!
  orders(first: Int, after: String): OrderConnection!
}

type ProductConnection {
  edges: [ProductEdge!]!
  pageInfo: PageInfo!
  totalCount: Int!
}

type ProductEdge {
  node: Product!
  cursor: String!
}

type PageInfo {
  hasNextPage: Boolean!
  hasPreviousPage: Boolean!
  startCursor: String
  endCursor: String
}
```

**Global IDs** are mandatory for the Node interface. Every entity that can be fetched by ID must implement `Node`:

```graphql
interface Node {
  id: ID!
}

type Product implements Node {
  id: ID!          # globally unique, opaque, base64-encoded type:dbId
  name: String!
  price: Money!
}

type Query {
  node(id: ID!): Node
  nodes(ids: [ID!]!): [Node]!
}
```

Global IDs encode the type name and the database-local ID:

```typescript
// utilities/globalId.ts
import { Buffer } from 'buffer';

export function toGlobalId(type: string, id: string | number): string {
  return Buffer.from(`${type}:${id}`).toString('base64');
}

export function fromGlobalId(globalId: string): { type: string; id: string } {
  const decoded = Buffer.from(globalId, 'base64').toString('utf-8');
  const colonIndex = decoded.indexOf(':');
  return {
    type: decoded.slice(0, colonIndex),
    id: decoded.slice(colonIndex + 1),
  };
}
```

### Trade-offs

| Gain | Cost |
|---|---|
| Uniform pagination across all list fields | Verbosity — Connection/Edge wrappers add SDL noise |
| Apollo Client cache normalization works out of the box | `totalCount` requires a `COUNT(*)` query — expensive at scale |
| Relay client and custom tooling can be written once | `last`/`before` backward pagination is complex to implement correctly |
| Cursor-based pagination is correct for mutable datasets | More types to maintain in the schema |

### When to Use

- Any list field that consumers will paginate
- Systems using Apollo Client with normalized cache
- APIs that will be consumed by the Relay client
- Lists with more than 100 items at typical query sizes
- Lists from mutable datasets where offset pagination produces inconsistent results (items inserted between pages)

### When Not to Use

- Internal admin tools where you control all clients and offset pagination is acceptable
- Lists that are always returned in full (e.g., `categories: [Category!]!` with 12 items max)
- Read-only reference data that is fetched once and cached indefinitely

### Related Patterns

- **Cursor Encryption** (see [02-resolver-patterns.md](./02-resolver-patterns.md)) — cursors must be opaque; never expose raw offsets or row IDs
- **Nullable by Default** — `edges` should be `[ProductEdge!]!` but `node` inside an edge can be nullable when the referenced entity may have been deleted

---

## Pattern 2: Command/Query Segregation in Schema Design

### Problem

Mutation input types are reused for query filter types, or mutation return types mirror query types directly. When the mutation needs a new required field (e.g., `idempotencyKey`), adding it is a breaking change for every client that constructs the input. When a mutation grows to cover update semantics, its input type diverges from the query type it was originally mirroring, creating confusing partial-update semantics.

### Solution

Separate mutation input types from query types completely. Use **verb-noun naming** for mutations. Never share an input type between a query filter and a mutation payload.

```graphql
# WRONG: shared input type between query and mutation
input ProductInput {
  name: String!
  price: Float!
  categoryId: ID!
}

type Query {
  searchProducts(filter: ProductInput): [Product!]!  # reusing mutation input
}

type Mutation {
  createProduct(input: ProductInput!): Product!
}

# RIGHT: dedicated input types per mutation, separate filter types
input CreateProductInput {
  name: String!
  price: Float!
  categoryId: ID!
  idempotencyKey: String!   # only relevant to the mutation
}

input UpdateProductInput {
  name: String            # all fields optional for partial update
  price: Float
  categoryId: ID
}

input ProductFilterInput {
  nameContains: String
  categoryId: ID
  priceRange: PriceRangeInput
}

type Mutation {
  # verb-noun: CreateProduct, UpdateProduct, DeleteProduct, PublishProduct
  createProduct(input: CreateProductInput!): CreateProductResult!
  updateProduct(id: ID!, input: UpdateProductInput!): UpdateProductResult!
  deleteProduct(id: ID!): DeleteProductResult!
}

type Query {
  products(filter: ProductFilterInput, first: Int, after: String): ProductConnection!
}
```

Verb-noun convention for mutations makes the schema self-documenting and avoids name collisions in federation:

```graphql
# Mutations read as actions on domain objects
type Mutation {
  # Orders domain
  createOrder(input: CreateOrderInput!): CreateOrderResult!
  cancelOrder(id: ID!, reason: CancelOrderReason!): CancelOrderResult!
  fulfillOrder(id: ID!): FulfillOrderResult!

  # Inventory domain
  reserveInventory(input: ReserveInventoryInput!): ReserveInventoryResult!
  releaseInventory(reservationId: ID!): ReleaseInventoryResult!
}
```

### Trade-offs

| Gain | Cost |
|---|---|
| Input types evolve independently without breaking unrelated consumers | More types in the schema |
| Mutation inputs can have mutation-specific required fields | Teams must be disciplined about not reusing inputs |
| Verb-noun naming makes mutations self-documenting | Naming requires team agreement upfront |

### When to Use

- Always. This pattern has no meaningful trade-off against the alternative.

### When Not to Use

- Prototypes and internal tooling where schema longevity is not a concern and rapid iteration matters more.

---

## Pattern 3: Schema Versioning via Deprecation

### Problem

A field name was chosen poorly. A type needs to be restructured. A mutation parameter was a string but should be an enum. The instinct is to version the API (`/graphql/v2`) or add a `version` argument. Both approaches create permanent API fragmentation: two schemas to maintain, two sets of resolvers, two documentation sets. Clients remain on old versions indefinitely because migration is never urgent enough to prioritize.

### Solution

Never version by URL. Version within the schema using `@deprecated`. Field aliases bridge breaking renames. The process is:

1. Add the new field alongside the old field
2. Mark the old field `@deprecated(reason: "Use displayName")`
3. Implement the old field as an alias for the new field in resolvers
4. Track client usage via field-level metrics in Apollo Studio or the observability stack
5. Remove the old field only when client usage drops to zero and has been zero for N weeks (typically 8 weeks)

```graphql
type User {
  # Step 1: New field added
  displayName: String!

  # Step 2: Old field deprecated with migration path in reason string
  fullName: String! @deprecated(reason: "Use displayName. fullName will be removed after 2026-Q1.")

  # Deeper restructuring example: scalar -> object
  address: String! @deprecated(reason: "Use structuredAddress for parsed address fields.")
  structuredAddress: Address!
}

type Address {
  street: String!
  city: String!
  state: String!
  postalCode: String!
  country: String!
}
```

Resolver aliasing so the deprecated field never has stale data:

```typescript
// resolvers/User.ts
export const UserResolvers = {
  User: {
    // New canonical field
    displayName: (user: UserModel) => user.display_name,

    // Deprecated alias — always returns the same data as displayName
    fullName: (user: UserModel) => user.display_name,

    // Deprecated scalar returns first line of structured address
    address: (user: UserModel) =>
      `${user.address_street}, ${user.address_city}, ${user.address_state} ${user.address_postal_code}`,

    structuredAddress: (user: UserModel): Address => ({
      street: user.address_street,
      city: user.address_city,
      state: user.address_state,
      postalCode: user.address_postal_code,
      country: user.address_country,
    }),
  },
};
```

Track field usage to determine safe removal timing:

```yaml
# Apollo Studio field insights — query in GraphOS
# Or use field-level metrics in the observability stack:
# graphql_field_executions_total{field_name="fullName"} < 1 for 8 weeks
```

### Trade-offs

| Gain | Cost |
|---|---|
| Clients migrate at their own pace without hard cutoffs | Old fields remain in the schema, increasing SDL size |
| Single schema to maintain | Requires field usage tracking to know when it's safe to remove |
| Breaking changes become non-breaking through aliases | Teams must enforce the deprecation process — culture dependency |
| No URL versioning debt | Requires discipline: removal deadlines must be enforced |

### When to Use

- Any schema change that would break existing clients: field removal, rename, type change, required argument change
- Production APIs with multiple client teams or public API consumers

### When Not to Use

- Breaking changes in the same sprint as the initial field addition (before any clients have consumed the field)
- Internal-only schemas with a single client team that can coordinate synchronized migration

---

## Pattern 4: Nullable by Default for Partial Data

### Problem

A schema declares most fields as non-nullable (`field: Type!`). A downstream service call within one of those resolvers fails. GraphQL propagates the null upward: the parent field becomes null, then its parent, until it hits a nullable ancestor — or the entire response becomes `{ "data": null }`. A single transient error in a minor field destroys the entire response.

### Solution

Treat non-nullability as an explicit commitment, not the default. Fields should be nullable unless there is a specific, documented reason they cannot be null in production. A field is non-nullable only when:

- Its resolver has no upstream dependencies that can independently fail
- Its absence would make the parent object semantically meaningless
- You are willing to null the entire parent object on failure

```graphql
# WRONG: aggressive non-nullability
type Order {
  id: ID!
  status: OrderStatus!
  total: Money!
  customer: User!         # if user service is down, entire Order is nulled
  shippingAddress: Address! # if address service is down, entire Order is nulled
  lineItems: [LineItem!]!
  trackingInfo: TrackingInfo! # if shipping service is down, entire Order is nulled
}

# RIGHT: defensive nullability — fields fail independently
type Order {
  id: ID!                   # non-null: without an ID, this object is meaningless
  status: OrderStatus!      # non-null: status is always set at creation
  total: Money!             # non-null: total is always computed at order creation
  customer: User            # nullable: user service call may fail; order still renderable
  shippingAddress: Address  # nullable: may not yet be set, or address service may fail
  lineItems: [LineItem!]!   # non-null list, but items inside are always complete
  trackingInfo: TrackingInfo # nullable: not available until shipped
}
```

The rule of thumb: **a field is non-nullable only when its absence would make the entire parent object unusable to any client.**

Pair with the `errors` array and partial data:

```json
{
  "data": {
    "order": {
      "id": "T3JkZXI6MTIz",
      "status": "PENDING",
      "total": { "amount": 4999, "currency": "USD" },
      "customer": null,
      "trackingInfo": null
    }
  },
  "errors": [
    {
      "message": "User service unavailable",
      "path": ["order", "customer"],
      "extensions": { "code": "SERVICE_UNAVAILABLE" }
    }
  ]
}
```

Clients that cannot render without `customer` show an error state. Clients that can render an order summary without customer details do so. The partial data is genuinely useful.

### Trade-offs

| Gain | Cost |
|---|---|
| Single-field failures do not cascade to null entire responses | Clients must handle nullable fields explicitly |
| Partial data is genuinely useful to clients | TypeScript codegen produces more optional types |
| Resilient to downstream service degradation | Requires deliberate documentation of which fields are always present |
| Mirrors real-world availability characteristics | Can feel like "everything is optional" without discipline |

### When to Use

- Any field resolved by a call to an external service, database, or downstream subgraph
- Any field not present at object creation time (e.g., `completedAt`, `trackingNumber`)
- Any field with complex business logic in its resolver

### When Not to Use

- Fields that are identifiers (IDs, keys) — these should always be non-null
- Fields guaranteed by the database schema (e.g., `createdAt NOT NULL`)
- Leaf scalars computed from non-null parent data (e.g., `user.initials` computed from `user.firstName`)

---

## Pattern 5: Error Union Pattern

### Problem

Mutations return `MutationPayload!` with an `errors: [UserError!]` field. Clients receive a `200 OK` with a `data.createOrder` object, and must check for the presence of `errors` to know if the mutation succeeded. Every mutation has a different set of possible errors, but they're all expressed as the same generic `UserError` type with `message: String` and `code: String`. Clients cannot model domain-specific error states in their type systems — they must parse error codes as strings.

### Solution

Each mutation returns a **result union** where every branch is a named, typed success or failure state:

```graphql
# Each possible outcome is a distinct named type
union CreateOrderResult =
  | CreateOrderSuccess
  | ValidationError
  | InsufficientInventoryError
  | PaymentDeclinedError
  | CustomerNotFoundError

type CreateOrderSuccess {
  order: Order!
  estimatedDelivery: Date!
}

type ValidationError {
  fields: [FieldValidationError!]!
  message: String!
}

type FieldValidationError {
  field: String!
  message: String!
  code: ValidationErrorCode!
}

enum ValidationErrorCode {
  REQUIRED
  INVALID_FORMAT
  OUT_OF_RANGE
  DUPLICATE_VALUE
}

type InsufficientInventoryError {
  productId: ID!
  requestedQuantity: Int!
  availableQuantity: Int!
  expectedRestockDate: Date
}

type PaymentDeclinedError {
  declineCode: String!
  userFacingMessage: String!
  retryable: Boolean!
}

type Mutation {
  createOrder(input: CreateOrderInput!): CreateOrderResult!
}
```

Resolver implementation with typed discriminated union:

```typescript
// resolvers/mutations/createOrder.ts
import type { MutationResolvers } from '../generated/types';

export const createOrderResolver: MutationResolvers['createOrder'] = async (
  _,
  { input },
  context
) => {
  // Validation phase
  const validationErrors = validateCreateOrderInput(input);
  if (validationErrors.length > 0) {
    return {
      __typename: 'ValidationError',
      fields: validationErrors,
      message: 'Order input validation failed',
    };
  }

  // Customer lookup
  const customer = await context.dataloaders.customer.load(input.customerId);
  if (!customer) {
    return {
      __typename: 'CustomerNotFoundError',
      customerId: input.customerId,
      message: `Customer ${input.customerId} not found`,
    };
  }

  // Inventory check
  const inventory = await context.inventoryService.checkInventory(input.lineItems);
  if (!inventory.sufficient) {
    return {
      __typename: 'InsufficientInventoryError',
      productId: inventory.insufficientProductId,
      requestedQuantity: inventory.requestedQuantity,
      availableQuantity: inventory.availableQuantity,
      expectedRestockDate: inventory.expectedRestockDate ?? null,
    };
  }

  // Create the order
  const order = await context.orderService.create(input);
  return {
    __typename: 'CreateOrderSuccess',
    order,
    estimatedDelivery: order.estimatedDelivery,
  };
};
```

Client query using inline fragments to handle each case:

```graphql
mutation CreateOrder($input: CreateOrderInput!) {
  createOrder(input: $input) {
    ... on CreateOrderSuccess {
      order {
        id
        status
        total { amount currency }
      }
      estimatedDelivery
    }
    ... on ValidationError {
      fields {
        field
        message
        code
      }
    }
    ... on InsufficientInventoryError {
      productId
      availableQuantity
      expectedRestockDate
    }
    ... on PaymentDeclinedError {
      userFacingMessage
      retryable
    }
  }
}
```

### Trade-offs

| Gain | Cost |
|---|---|
| Each error type is a first-class schema type with domain-specific fields | More types per mutation — schema grows faster |
| Clients get full type safety for error handling | New error cases require schema changes (planned releases) |
| Eliminates `errors[0].extensions.code` string parsing | Teams must agree on error taxonomy upfront |
| Error payloads are as discoverable as success payloads via introspection | Union members cannot share fields without an interface |

### When to Use

- Any mutation that has more than one meaningful failure mode
- Mutations in systems where clients are built by different teams
- APIs that generate client SDKs (TypeScript, Swift, Kotlin) — the generated types are far more useful with error unions

### When Not to Use

- Simple CRUD mutations with only one failure mode (`NotFoundError`)
- Internal tooling where error messages are sufficient for the single client team

### Related Patterns

- **Nullable by Default** — the error union covers mutation failures; nullable fields cover query-time partial failures
- **Command/Query Segregation** — each mutation's result type is its own named type, following the same naming discipline

---

## Pattern 6: Phantom Types for Scalar Validation

### Problem

A `User` type has `email: String!` and `phone: String!`. Nothing in the type system prevents a resolver from accidentally swapping them, assigning an unvalidated string to `email`, or accepting a malformed phone number. Input types accept `String` for email addresses without format validation, generating confusing downstream errors.

### Solution

Define **custom scalars** that encode domain validation. The scalar name communicates the domain constraint; the scalar's `serialize`/`parseValue`/`parseLiteral` methods enforce it at the GraphQL layer.

```graphql
# schema.graphql
scalar Email
scalar PhoneNumber
scalar UUID
scalar URL
scalar NonNegativeInt
scalar PositiveFloat
scalar ISO8601Date
scalar ISO8601DateTime
scalar JSON

type User {
  id: UUID!
  email: Email!
  phone: PhoneNumber
  createdAt: ISO8601DateTime!
}

input CreateUserInput {
  email: Email!
  phone: PhoneNumber
}
```

Scalar implementation using the `graphql-scalars` library (preferred for standard scalars):

```typescript
// scalars/index.ts
import {
  EmailAddressResolver,
  PhoneNumberResolver,
  UUIDResolver,
  URLResolver,
  NonNegativeIntResolver,
  PositiveFloatResolver,
  DateTimeResolver,
  JSONResolver,
} from 'graphql-scalars';

export const scalarResolvers = {
  Email: EmailAddressResolver,
  PhoneNumber: PhoneNumberResolver,
  UUID: UUIDResolver,
  URL: URLResolver,
  NonNegativeInt: NonNegativeIntResolver,
  PositiveFloat: PositiveFloatResolver,
  ISO8601DateTime: DateTimeResolver,
  JSON: JSONResolver,
};
```

Domain-specific scalar with custom validation:

```typescript
// scalars/Money.ts
import { GraphQLScalarType, GraphQLError } from 'graphql';

interface MoneyValue {
  amount: number;  // integer cents
  currency: string; // ISO 4217 currency code
}

export const MoneyScalar = new GraphQLScalarType<MoneyValue, MoneyValue>({
  name: 'Money',
  description: 'Monetary value as { amount: Int (cents), currency: String (ISO 4217) }',

  serialize(value: unknown): MoneyValue {
    if (typeof value !== 'object' || value === null) {
      throw new GraphQLError('Money must be an object');
    }
    const { amount, currency } = value as Record<string, unknown>;
    if (typeof amount !== 'number' || !Number.isInteger(amount) || amount < 0) {
      throw new GraphQLError('Money.amount must be a non-negative integer (cents)');
    }
    if (typeof currency !== 'string' || !/^[A-Z]{3}$/.test(currency)) {
      throw new GraphQLError('Money.currency must be an ISO 4217 currency code');
    }
    return { amount, currency };
  },

  parseValue(value: unknown): MoneyValue {
    return MoneyScalar.serialize!(value) as MoneyValue;
  },

  parseLiteral(ast) {
    throw new GraphQLError('Money scalar does not support literal values');
  },
});
```

### Trade-offs

| Gain | Cost |
|---|---|
| Validation occurs at the GraphQL boundary — before resolver execution | Custom scalars require implementation and maintenance |
| Type system communicates domain constraints to clients and developers | Some clients (older codegen) treat custom scalars as `any` |
| Prevents classes of bugs: wrong string in wrong field | Schema introspection shows the scalar name but not the validation rules — must be documented |
| `graphql-scalars` covers 80% of common cases with zero implementation | Validation errors appear as input coercion errors, not the Error Union pattern |

### When to Use

- Any field where the string value has domain constraints (email, phone, URL, UUID, currency code)
- Public APIs where clients should know the expected format from the type system
- Systems generating typed client SDKs

### When Not to Use

- Internal admin tools where developer experience is secondary to speed of iteration
- Fields where validation is context-dependent (e.g., an enum whose valid values depend on another field)

---

## Pattern 7: Polymorphism via Interface vs Union

### Problem

A `SearchResult` type needs to return `Product`, `Article`, `User`, and `Category` objects. An `Event` type needs to handle `PageView`, `Purchase`, `Refund`, and `Subscription` each with some shared fields and some unique fields. Teams default to one of the two GraphQL abstractions (interface or union) without understanding when each is appropriate.

### Solution

Use **interface** when types share fields that have the same name and semantics across all members. Use **union** when types are unrelated and sharing field names would be coincidental or misleading.

```graphql
# Interface: types share real semantic meaning for the shared fields
interface Node {
  id: ID!
}

interface Timestamped {
  createdAt: ISO8601DateTime!
  updatedAt: ISO8601DateTime!
}

interface SearchResult {
  id: ID!
  title: String!
  url: URL!
  relevanceScore: Float!
}

# All SearchResult types genuinely have a title and URL
type ProductSearchResult implements SearchResult & Node & Timestamped {
  id: ID!
  title: String!       # product name is a title
  url: URL!            # product page URL
  relevanceScore: Float!
  price: Money!
  createdAt: ISO8601DateTime!
  updatedAt: ISO8601DateTime!
}

type ArticleSearchResult implements SearchResult & Node & Timestamped {
  id: ID!
  title: String!       # article headline is a title
  url: URL!            # article URL
  relevanceScore: Float!
  author: String!
  publishedAt: ISO8601DateTime!
  createdAt: ISO8601DateTime!
  updatedAt: ISO8601DateTime!
}
```

```graphql
# Union: types are unrelated — no shared fields with real semantic equivalence
union PaymentMethod =
  | CreditCard
  | BankTransfer
  | Cryptocurrency
  | GiftCard
  | BuyNowPayLaterPlan

# These types have no meaningful shared fields — a CreditCard's "number" and
# a BankTransfer's "routingNumber" are not the same concept even if both are strings

type CreditCard {
  last4: String!
  network: CardNetwork!
  expiresAt: String!
  holderName: String!
}

type BankTransfer {
  bankName: String!
  accountLast4: String!
  routingNumber: String!
  accountType: BankAccountType!
}

type Cryptocurrency {
  network: CryptoNetwork!
  walletAddress: String!
  confirmations: Int!
}
```

Decision matrix:

| Question | Interface | Union |
|---|---|---|
| Do all types share fields with the same semantics? | Yes | No |
| Should clients be able to query shared fields without inline fragments? | Yes | No |
| Are types from completely different domains? | No | Yes |
| Can types implement multiple abstractions? | Yes (multiple interfaces) | No (only in one union per usage) |
| Is the relationship "is-a" with shared behavior? | Yes | No |

### Trade-offs — Interface

| Gain | Cost |
|---|---|
| Shared fields are queryable without `... on` spreads | All members must implement all interface fields |
| Clients can write generic code against the interface | Adding a field to the interface is a breaking change for all implementing types |
| Expresses "is-a" relationships clearly | Over-abstraction: forcing unrelated types into a shared interface creates fake shared semantics |

### Trade-offs — Union

| Gain | Cost |
|---|---|
| Types are fully independent | Every field access requires an `... on TypeName` inline fragment |
| Types can evolve independently | No shared querying across members |
| Correct model for truly unrelated types | Clients must handle every member explicitly |

### When to Use Interface

- Types that genuinely share behavior: `Node` (all entities), `Timestamped` (all auditable types), `SearchResult` (all searchable types), `PricedItem` (all purchasable items)
- When clients need to write generic queries against the shared fields

### When to Use Union

- Mutation result types (Error Union pattern) — success and error types share no fields
- Payment methods, authentication methods, notification channels — unrelated domain types that happen to be alternatives
- `SearchResult` unions where the types are truly heterogeneous and a forced `title` field would be misleading

### Related Patterns

- **Error Union Pattern** — always union, never interface, for mutation result types
- **Relay Specification** — `Node` is the canonical interface all entities implement
