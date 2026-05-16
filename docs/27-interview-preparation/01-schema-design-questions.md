# Schema Design Interview Questions

> **Purpose:** Model answers for the six most common schema design interview questions in senior+ GraphQL roles. Each answer walks through the decision process an interviewer expects to observe — not just the final schema, but the reasoning behind every structural choice. Questions are ordered from foundational (e-commerce type hierarchy) through advanced (N+1 / DataLoader internals).

---

## How to Read This File

Each question section contains:
- **The question** as an interviewer typically phrases it
- **What the interviewer is evaluating** — the signal they are looking for
- **Model answer** — the answer a strong candidate gives, structured as a verbal walkthrough with SDL
- **Common mistakes** — what weak candidates say or do
- **Follow-up questions** — what the interviewer asks next to probe depth

Work through each question by covering the model answer, formulating your own answer out loud, then comparing. The SDL is the artifact, but the spoken reasoning is what interviewers score.

---

## Question 1: Design the GraphQL Schema for an E-Commerce Product Page

### What the interviewer is evaluating

Your ability to model a real product domain with appropriate type hierarchy, handle collection pagination, represent variants and pricing without over-nesting, and recognize that inventory is operationally sensitive data that may be served from a different system.

### Model Answer

**Start by clarifying requirements (always do this before touching SDL):**

"Before I start writing types, let me clarify a few things: Does this need to support digital products alongside physical products? Should pricing handle multi-currency? Is inventory real-time or eventually consistent? And are we designing this for a single monolith or a federated graph?"

Assuming a federated graph with physical products, multi-currency pricing, and real-time inventory:

```graphql
# ─── Core Product Types ─────────────────────────────────────────────────────

"""
A product listed in the catalog. Represents the canonical item
regardless of variant (size, color, etc.).
"""
type Product {
  id: ID!
  slug: String!
  name: String!
  description: String
  brand: Brand
  categories: [Category!]!

  """
  Variants are the purchasable SKUs — a product with sizes Small/Medium/Large
  has three variants. Always at least one variant exists.
  """
  variants(first: Int = 10, after: String): ProductVariantConnection!

  """
  The primary media item. Clients rendering a thumbnail use this field;
  clients rendering a gallery use the media connection.
  """
  primaryImage: MediaItem

  media(first: Int = 20, after: String): MediaItemConnection!

  """
  Aggregate rating from reviews. Nullable because new products have no reviews.
  """
  rating: ProductRating

  reviews(
    first: Int = 10
    after: String
    orderBy: ReviewOrderByInput
  ): ReviewConnection!

  """
  SEO metadata owned by the content team subgraph.
  """
  seo: ProductSEO

  createdAt: DateTime!
  updatedAt: DateTime!
}

"""
A purchasable variant of a product. Each variant has its own SKU,
pricing, and inventory position.
"""
type ProductVariant {
  id: ID!
  sku: String!
  product: Product!

  """
  Attributes that distinguish this variant: size, color, material.
  Using a key-value pair rather than typed fields keeps the schema
  flexible across product categories.
  """
  attributes: [VariantAttribute!]!

  """
  Pricing is variant-scoped, not product-scoped. A large shirt
  may cost more than a small shirt; a sale may affect only one color.
  """
  pricing: VariantPricing!

  """
  Inventory is deliberately nullable — it may be served by a separate
  warehouse subgraph that is occasionally unavailable. Partial data
  (product renders without inventory) is better than a null product.
  """
  inventory: VariantInventory

  isAvailable: Boolean!
}

type VariantAttribute {
  name: String!    # "size", "color", "material"
  value: String!   # "Large", "Navy Blue", "Cotton"
}

# ─── Pricing ────────────────────────────────────────────────────────────────

type VariantPricing {
  """
  List price before any promotions or discounts.
  """
  listPrice: Money!

  """
  Effective price the customer pays today, after promotions.
  Nullable — if the pricing engine is unavailable, we return listPrice
  and surface a non-critical error in errors[].
  """
  effectivePrice: Money

  """
  Discount applied, if any. Null when no promotion is active.
  """
  discount: PriceDiscount

  currency: CurrencyCode!
}

type Money {
  """
  Amount in the smallest currency unit (cents for USD, pence for GBP).
  Using Int avoids floating-point precision errors.
  """
  amount: Int!
  currency: CurrencyCode!

  """
  Pre-formatted string for display: "$29.99". Saves clients from
  implementing currency formatting. Nullable because formatting rules
  may not exist for all currency/locale combinations.
  """
  formatted: String
}

type PriceDiscount {
  amount: Money!
  percentage: Float!
  label: String      # "20% off", "SUMMER2024"
  expiresAt: DateTime
}

# ─── Inventory ──────────────────────────────────────────────────────────────

type VariantInventory {
  """
  Quantity on hand across all warehouses. Intentionally coarse —
  exact stock counts are business-sensitive and can become stale.
  Clients should use isAvailable for purchase gating.
  """
  quantityAvailable: Int

  """
  Threshold below which we show "only N left" messaging.
  """
  lowStockThreshold: Int

  isInStock: Boolean!
  isBackorderable: Boolean!

  """
  Estimated restock date when isInStock is false. Nullable.
  """
  expectedRestockDate: Date
}

# ─── Connections (Relay-spec pagination) ────────────────────────────────────

type ProductVariantConnection {
  edges: [ProductVariantEdge!]!
  pageInfo: PageInfo!
  totalCount: Int!
}

type ProductVariantEdge {
  node: ProductVariant!
  cursor: String!
}

type PageInfo {
  hasNextPage: Boolean!
  hasPreviousPage: Boolean!
  startCursor: String
  endCursor: String
}

# ─── Supporting Types ────────────────────────────────────────────────────────

type Brand {
  id: ID!
  name: String!
  logoUrl: String
}

type Category {
  id: ID!
  name: String!
  slug: String!
  parent: Category
}

type ProductRating {
  average: Float!
  count: Int!
}

type MediaItem {
  id: ID!
  url: String!
  altText: String
  width: Int
  height: Int
}

type ProductSEO {
  title: String
  description: String
  canonicalUrl: String
}

enum CurrencyCode {
  USD
  EUR
  GBP
  JPY
  CAD
}
```

**Key decisions to verbalize:**

1. **Product vs. Variant separation** — a product is a concept (blue Nike shoe); a variant is a purchasable SKU (blue Nike shoe, size 10). Conflating them makes pricing and inventory impossible to model correctly.

2. **`inventory` is nullable on `ProductVariant`** — inventory data often lives in a warehouse management system with different SLA guarantees than the catalog. Making it nullable means a warehouse outage returns partial data rather than nulling out the entire product.

3. **`Money.amount` as `Int` not `Float`** — floating-point arithmetic on currency values introduces rounding errors. Store in smallest denomination (cents). This is a non-negotiable.

4. **Relay Connection on `variants`** — even if today there are only 3 variants, some products (apparel with size + color matrix) can have 50+. Design for the extreme case from day one.

5. **`VariantAttribute` as key-value pair** — using typed fields (has`color: String`, `size: String`) would work for apparel but break for electronics where attributes are completely different. Key-value preserves schema flexibility.

### Common Mistakes

- Putting pricing at the product level, not variant level. "The product costs $29.99" breaks the moment you have a sale that affects only one color.
- Using `Float` for monetary amounts.
- Returning `inventory: VariantInventory!` (non-null) — this ties your product page availability to warehouse system uptime.
- Forgetting pagination on `variants` — this will break the moment a client requests a product with 50 color/size combinations.
- Not clarifying requirements before writing SDL. Interviewers notice immediately when candidates jump to types without asking questions.

### Follow-Up Questions

- "How would you add support for bundle products (product composed of multiple SKUs)?"
- "How would you handle a product that exists in the catalog but is region-restricted?"
- "How would you expose personalized pricing for B2B customers with negotiated rates?"

---

## Question 2: How Do You Handle Breaking Changes in a Public GraphQL API?

### What the interviewer is evaluating

Your understanding of the deprecation lifecycle, why URL versioning doesn't work for GraphQL, the tooling used to enforce safe evolution, and your ability to balance technical correctness with organizational realities.

### Model Answer

"Breaking changes in GraphQL are a spectrum. Let me distinguish between the different classes before talking about process."

**Non-breaking (additive) changes — safe to ship anytime:**
- Adding a new field to a type
- Adding a new optional argument to a field
- Adding a new type, enum value, union member, or interface implementation
- Making a non-null field nullable (clients already handle the null case)

**Breaking changes — require deprecation process:**
- Removing a field
- Renaming a field
- Changing a field's type (e.g., `String` to `Int`)
- Making a nullable field non-null
- Removing an enum value a client may be sending
- Removing an argument

**The deprecation workflow:**

```graphql
type User {
  id: ID!

  # Step 1: Add the new field
  displayName: String!

  # Step 2: Deprecate the old field with a replacement instruction
  # Always include where the replacement lives in the reason string
  username: String! @deprecated(reason: "Use displayName instead. Will be removed 2025-Q1.")

  # Do not remove until usage reaches zero
}
```

**Process for a breaking change:**

1. **Add the replacement field.** Never rename in place — add alongside.
2. **Deprecate the old field** with `@deprecated(reason: "Use X instead. Removal date: YYYY-QN.")`. The reason string must include the replacement and a concrete timeline.
3. **Instrument field usage.** Apollo Studio field usage metrics, or a custom resolver wrapper that logs `client_name + field_path` when deprecated fields are accessed.
4. **Notify clients.** Email/Slack blast to all registered client teams with the deprecation notice and migration guide.
5. **Monitor usage graphs.** Do not remove until the 30-day trailing usage drops to zero.
6. **Remove the field** only after zero usage is confirmed. Run `rover subgraph check` in CI to catch any schema composition issues.

**Why not URL versioning (`/graphql/v2`)?**

URL versioning creates a complete schema fork. Every bug fix, security patch, and new feature must be applied to both `/v1` and `/v2`. In a federated graph with 30 subgraphs, this becomes 60 deployments for every change. More critically, clients that query across types owned by different subgraphs lose the ability to do so in a versioned fork — the router cannot merge v1 users with v2 orders. GraphQL's additive evolution model is incompatible with URL versioning by design.

**What about operation-level versioning?**

Some teams use `@skip`/`@include` directives with feature flags to let clients opt into new behavior before the old fields are removed. This is a valid migration pattern for high-traffic clients that need careful cutover.

### Common Mistakes

- Saying "you can't make breaking changes in GraphQL" — you can, you just need a deprecation process.
- Not mentioning usage monitoring — deprecating without tracking usage means you never know when it's safe to remove.
- Proposing URL versioning without explaining why it fails for GraphQL specifically.
- Forgetting that making a nullable field non-null is a breaking change (it will break any client that handles the null case differently, and it expands the error blast radius).

### Follow-Up Questions

- "How do you handle a breaking change that is security-critical and can't wait for a deprecation cycle?"
- "A client team says they can't migrate off a deprecated field for 6 months. How do you handle that?"
- "How does schema composition validation (`rover subgraph check`) help enforce this process?"

---

## Question 3: When Should a Field Be Nullable vs. Non-Null?

### What the interviewer is evaluating

Your understanding of how GraphQL propagates null values up the response tree, how non-null is a contract guarantee (not just a type annotation), and the design trade-off between strictness and resilience.

### Model Answer

"Nullability in GraphQL is not just a type annotation — it's a contract about error propagation behavior. Let me explain the mechanics first, then the design rule."

**How null propagation works:**

When a non-null field's resolver throws or returns null, GraphQL does not return a partial response. Instead, it walks up the parent chain until it finds a nullable field, sets that field to null, and appends the error to `errors[]`. If every field up the chain is non-null, the entire response data becomes null.

```graphql
# Dangerous: if inventory resolver throws, the entire order query returns null
type Order {
  id: ID!
  customer: Customer!
  items: [OrderItem!]!
  shippingAddress: Address!
  inventory: InventoryStatus!  # NON-NULL — blast radius: entire order
}

# Safe: inventory resolver failure returns partial data
type Order {
  id: ID!
  customer: Customer!
  items: [OrderItem!]!
  shippingAddress: Address!
  inventory: InventoryStatus  # NULLABLE — blast radius: this field only
}
```

**The design rule:**

Use non-null (`!`) as a **contract guarantee** — only when you can guarantee the resolver will never fail. Use nullable as the default for resilience.

**Make a field non-null when:**
- The field is an identifier or key (`id: ID!`) — a type without an ID is not a valid entity
- The field is computed entirely from the parent object with no I/O
- The field represents a structural guarantee of the type (`createdAt: DateTime!` on any auditable entity)
- The connection/list wrapper, not the items themselves: `orders: OrderConnection!` (the connection always exists, but the edges may be empty `[]`)

**Keep a field nullable when:**
- The resolver makes an external service call (payment processor, warehouse API, third-party enrichment)
- The data may not exist for all entities (e.g., `bio` on a User who never filled it in — but note this is different from a structural guarantee)
- The field is expensive to compute and may be elided at runtime
- The subgraph that owns the data has lower SLA guarantees than the parent type's subgraph

**The "nullable by default" argument:**

The strongest argument for nullable-by-default is resilience: a nullable field failure stays isolated. A non-null field failure can propagate to null an entire query. In a federated graph where subgraphs are deployed independently and can fail independently, the safest default is nullable.

The strongest argument against nullable-by-default is client complexity: clients must write null-checks everywhere, and type generation produces `string | null | undefined` in TypeScript rather than `string`. Non-null fields produce cleaner client code.

The resolution: be non-null where you have a strong guarantee, nullable everywhere you depend on external data or optional information. Do not make non-null just because you expect the data to exist — the expectation fails in production.

### Common Mistakes

- Saying "use non-null whenever the data should exist." This ignores the error propagation mechanism entirely.
- Not knowing that null propagation walks up the parent chain.
- Not mentioning partial data patterns — the value of nullable is that you return useful partial responses rather than complete failures.
- Confusing list nullability: `[Item!]!` vs `[Item]!` vs `[Item!]` vs `[Item]` are four distinct things. The outer `!` controls whether the list itself is null; the inner `!` controls whether list elements can be null.

### Follow-Up Questions

- "You have a `User` type with a `paymentMethod` field that calls a payment processor. Should it be nullable?"
- "When would you use `[Item!]!` vs `[Item!]`?"
- "How does your nullability choice affect Apollo Client's cache normalization behavior?"

---

## Question 4: Design the Error Handling Strategy for a Checkout Mutation

### What the interviewer is evaluating

Your ability to distinguish between user-facing expected errors (out of stock, card declined) and system errors (resolver throws), and your understanding of error modeling patterns — specifically why error unions on mutations produce better client code than throwing for expected errors.

### Model Answer

"Checkout has two categories of failure that need completely different treatment. Let me separate them before designing the schema."

**Category 1 — Expected domain errors (user-facing, recoverable):**
- Item out of stock
- Card declined
- Address validation failed
- Coupon expired
- Age verification failed for restricted items

These are not exceptional — they happen in the normal flow of business. Modeling them as exceptions (`throw new GraphQLError(...)`) is semantically wrong and creates operational noise (these errors appear in error tracking dashboards as "failures" when they are normal business events).

**Category 2 — System errors (unexpected, non-recoverable by user):**
- Payment processor timeout
- Inventory service unavailable
- Database write failure

These are exceptional and should propagate through `errors[]` as system errors.

**The error union pattern for mutations:**

```graphql
# ─── Mutation definition ─────────────────────────────────────────────────────

type Mutation {
  checkout(input: CheckoutInput!): CheckoutResult!
}

input CheckoutInput {
  cartId: ID!
  paymentMethodId: ID!
  shippingAddressId: ID!
  couponCode: String
}

# ─── Result union ────────────────────────────────────────────────────────────

"""
All possible outcomes of a checkout attempt. Clients switch on __typename
to handle each case.
"""
union CheckoutResult =
  | CheckoutSuccess
  | OutOfStockError
  | PaymentDeclinedError
  | AddressValidationError
  | CouponExpiredError

# ─── Success case ────────────────────────────────────────────────────────────

type CheckoutSuccess {
  order: Order!
  """
  Confirmation number for display and customer service reference.
  """
  confirmationNumber: String!
  estimatedDelivery: DateRange
}

# ─── Domain error types ──────────────────────────────────────────────────────

"""
Base interface for all user-facing checkout errors.
Clients can query message on any error type without knowing the specific type.
"""
interface CheckoutError {
  message: String!
  """
  Machine-readable code for client-side handling logic.
  """
  code: CheckoutErrorCode!
}

type OutOfStockError implements CheckoutError {
  message: String!
  code: CheckoutErrorCode!
  """
  The specific items that are out of stock, so the client can highlight them.
  """
  affectedItems: [CartItem!]!
  """
  Back in stock date, if known.
  """
  expectedRestockDate: Date
}

type PaymentDeclinedError implements CheckoutError {
  message: String!
  code: CheckoutErrorCode!
  """
  Decline reason from the payment processor, safe to show to the user.
  Do not surface raw processor codes — map them to user-facing strings.
  """
  declineReason: PaymentDeclineReason!
  """
  Whether the user should retry with the same card or use a different one.
  """
  retryable: Boolean!
}

type AddressValidationError implements CheckoutError {
  message: String!
  code: CheckoutErrorCode!
  """
  Field-level validation failures for inline form error display.
  """
  fieldErrors: [AddressFieldError!]!
  suggestedAddress: ShippingAddress
}

type CouponExpiredError implements CheckoutError {
  message: String!
  code: CheckoutErrorCode!
  expiredAt: DateTime!
}

enum CheckoutErrorCode {
  OUT_OF_STOCK
  PAYMENT_DECLINED
  ADDRESS_VALIDATION_FAILED
  COUPON_EXPIRED
  COUPON_INVALID
  AGE_VERIFICATION_REQUIRED
}

enum PaymentDeclineReason {
  INSUFFICIENT_FUNDS
  CARD_EXPIRED
  CVV_MISMATCH
  ADDRESS_MISMATCH
  SUSPECTED_FRAUD
  CARD_NOT_SUPPORTED
}
```

**Client usage:**

```typescript
const result = await checkout({ variables: { input } });

switch (result.data.checkout.__typename) {
  case 'CheckoutSuccess':
    router.push(`/confirmation/${result.data.checkout.confirmationNumber}`);
    break;
  case 'OutOfStockError':
    highlightOutOfStockItems(result.data.checkout.affectedItems);
    break;
  case 'PaymentDeclinedError':
    showPaymentError(result.data.checkout.declineReason);
    break;
  // TypeScript's exhaustiveness checking will catch unhandled cases
}
```

**Why not `errors[]`?**

The `errors[]` array in the GraphQL response spec is designed for unexpected errors — resolver crashes, auth failures, network issues. Using it for expected domain errors has two problems: (1) clients must parse the `extensions.code` on every error to determine if it's domain or system, (2) a domain error like "card declined" will fire alerts in Datadog/PagerDuty if engineers are monitoring `errors[]` for system health.

### Common Mistakes

- Putting domain errors in `errors[]` and saying "clients can check the error code." This conflates expected and unexpected errors.
- Not using an interface on error types — making clients write `... on OutOfStockError { message }` on every type instead of `... on CheckoutError { message }`.
- Making `CheckoutResult` a type (not a union) with optional fields for each error case. This requires clients to check multiple nullable fields to understand what happened.
- Forgetting to map raw payment processor error codes to user-safe strings.

### Follow-Up Questions

- "How does this error pattern interact with optimistic updates on the client?"
- "Should `message` on domain error types be localized, or should clients handle localization?"
- "How do you add a new error case to this union without breaking existing clients?"

---

## Question 5: How Would You Model a Polymorphic Content Type?

### What the interviewer is evaluating

Your understanding of when to use Interface vs. Union, the discriminated union pattern with `__typename`, and the downstream implications for client code generation (TypeScript discriminated unions, fragment spreading).

### Model Answer

"Polymorphism in GraphQL is handled by two constructs: Interface and Union. They solve different problems, and the choice has downstream effects on client code. Let me walk through the distinction and then design a content type."

**Interface — use when all types share common fields:**

```graphql
"""
All content items that can appear in a user's feed share these fields.
Interface enforces that every implementing type provides them.
"""
interface FeedItem {
  id: ID!
  publishedAt: DateTime!
  author: User!
  engagementStats: EngagementStats!
}

type ArticlePost implements FeedItem {
  id: ID!
  publishedAt: DateTime!
  author: User!
  engagementStats: EngagementStats!
  # Article-specific fields
  title: String!
  body: String!
  readingTimeMinutes: Int!
  coverImage: MediaItem
  tags: [Tag!]!
}

type VideoPost implements FeedItem {
  id: ID!
  publishedAt: DateTime!
  author: User!
  engagementStats: EngagementStats!
  # Video-specific fields
  title: String!
  videoUrl: String!
  thumbnailUrl: String!
  durationSeconds: Int!
  captions: [Caption!]
}

type PollPost implements FeedItem {
  id: ID!
  publishedAt: DateTime!
  author: User!
  engagementStats: EngagementStats!
  # Poll-specific fields
  question: String!
  options: [PollOption!]!
  endsAt: DateTime
  hasVoted: Boolean!
}

type Query {
  feed(first: Int = 20, after: String): FeedItemConnection!
  feedItem(id: ID!): FeedItem
}
```

**Union — use when types share no common fields:**

```graphql
"""
Search results can be entirely different entity types with nothing in common.
A union is correct here — there is no interface to enforce.
"""
union SearchResult =
  | Product
  | User
  | Article
  | Collection

type Query {
  search(query: String!, first: Int = 10): SearchResultConnection!
}
```

**The `__typename` discriminator pattern on the client:**

```graphql
# Query using fragments for each concrete type
query GetFeed($first: Int!, $after: String) {
  feed(first: $first, after: $after) {
    edges {
      node {
        __typename  # Always request __typename on polymorphic fields
        id
        publishedAt
        author { name avatarUrl }
        ... on ArticlePost {
          title
          readingTimeMinutes
          coverImage { url }
        }
        ... on VideoPost {
          title
          durationSeconds
          thumbnailUrl
        }
        ... on PollPost {
          question
          options { id text voteCount }
          hasVoted
        }
      }
    }
  }
}
```

**Decision criteria:**

| Scenario | Use |
|---|---|
| Multiple types share a set of required common fields | Interface |
| Types share some but not all fields (partial overlap) | Interface for shared contract, optional additional fields |
| Types have completely different structures | Union |
| You need to query shared fields without fragment spreading | Interface (avoids `... on X` for common fields) |
| You want TypeScript discriminated union code generation | Either — both produce discriminated unions via `__typename` |

**Adding a new type to a union without breaking clients:**

When you add a new member to a union (e.g., `LiveStreamPost`), existing clients that do exhaustive matching may render nothing for the new type. This is by design — clients should handle unknown `__typename` values gracefully with a fallback case. Document this as a pattern in your schema governance guide.

### Common Mistakes

- Using Union when types share common fields — forces every client query to repeat shared fields in every fragment.
- Using Interface when types genuinely have no common structure — creates a fake shared interface with only `id: ID!` that adds no value.
- Not requesting `__typename` in the query — Apollo Client includes it automatically, but other clients may not.
- Not handling unknown `__typename` values in client switch statements — new union members will break exhaustive matches silently.

### Follow-Up Questions

- "How does Apollo Client normalize an interface type in its cache?"
- "What happens when you add a new implementing type to an interface — is that a breaking change?"
- "How would you handle a case where a search result type needs to appear in multiple different contexts with different fields selected?"

---

## Question 6: Explain the N+1 Problem and How DataLoader Solves It

### What the interviewer is evaluating

Your depth of understanding of how GraphQL executes resolvers — specifically the sequential-per-field execution model — and how DataLoader's batching mechanism works under the hood. This is the highest-frequency technical deep-dive question at senior level.

### Model Answer

"The N+1 problem is a consequence of how GraphQL resolves fields in a tree. Let me trace through an execution to show exactly where it appears, then explain how DataLoader fixes it mechanically."

**The N+1 execution trace:**

Consider this query:
```graphql
query {
  orders(first: 10) {
    edges {
      node {
        id
        status
        customer {    # <-- This field causes the problem
          name
          email
        }
      }
    }
  }
}
```

GraphQL executes resolvers parent-first, depth-first. The execution sequence is:

```
1. Query.orders resolver → SELECT * FROM orders LIMIT 10  (1 query)
2. For each of the 10 orders, Order.customer resolver fires:
   3.  Order.customer(order={id: 1}) → SELECT * FROM users WHERE id = 1
   4.  Order.customer(order={id: 2}) → SELECT * FROM users WHERE id = 2
   5.  Order.customer(order={id: 3}) → SELECT * FROM users WHERE id = 3
   ...
   12. Order.customer(order={id: 10}) → SELECT * FROM users WHERE id = 10
```

Total database queries: **1 + 10 = 11** (hence "N+1" — 1 initial query + N sub-queries).

For 100 orders: 101 queries. For a complex query with 3 levels of nesting, it compounds multiplicatively.

**How DataLoader solves it:**

DataLoader is a batching and caching utility by Facebook. It works in two phases that map to the JavaScript event loop:

**Phase 1 — Collect:** DataLoader defers all load calls scheduled in the current tick. Instead of executing immediately, `loader.load(id)` adds the ID to a batch queue and returns a Promise.

**Phase 2 — Batch:** At the end of the current tick (via `process.nextTick`), DataLoader calls the batch function once with all collected IDs.

```typescript
// DataLoader batch function — called once per tick with all queued IDs
const userLoader = new DataLoader<string, User>(async (userIds: string[]) => {
  // ONE query for all IDs
  const users = await db.query(
    'SELECT * FROM users WHERE id = ANY($1)',
    [userIds]
  );

  // CRITICAL: Return results in the SAME ORDER as the input IDs
  // DataLoader maps results back to individual load() calls by position
  const userMap = new Map(users.map(u => [u.id, u]));
  return userIds.map(id => userMap.get(id) ?? new Error(`User ${id} not found`));
});

// Resolver — looks identical to a naive implementation
const resolvers = {
  Order: {
    customer: (order, _args, context) => {
      return context.loaders.user.load(order.customerId);
      // .load() returns a Promise — execution defers, batching happens automatically
    }
  }
};
```

**Execution trace with DataLoader:**

```
Tick 1:
  1. Query.orders resolver → SELECT * FROM orders LIMIT 10
  2. 10 Order.customer resolvers fire, each calling loader.load(customerId)
     → loader queues [id1, id2, ..., id10], returns 10 Promises

process.nextTick fires:
  3. DataLoader calls batch function with [id1, id2, ..., id10]
     → SELECT * FROM users WHERE id = ANY([id1...id10])  (1 query)
  4. DataLoader resolves the 10 individual Promises with their respective users
```

Total database queries: **1 + 1 = 2** regardless of how many orders are returned.

**DataLoader caching:**

DataLoader also caches by key within a request. If two different resolvers in the same query both load `user:42`, the second call returns the cached Promise from the first — no duplicate query. This cache is request-scoped (built fresh per request in the context factory), not global.

**Where to build DataLoaders:**

```typescript
// CORRECT: Build in the context factory, one DataLoader instance per request
function buildContext(req: Request): GraphQLContext {
  return {
    db,
    loaders: {
      user: new DataLoader(userBatchFn),
      product: new DataLoader(productBatchFn),
      order: new DataLoader(orderBatchFn),
    }
  };
}

// WRONG: Building DataLoader inside the resolver creates a new loader
// per resolver call, which defeats batching entirely
const resolvers = {
  Order: {
    customer: (order) => {
      const loader = new DataLoader(userBatchFn); // New instance — no batching
      return loader.load(order.customerId);
    }
  }
};
```

### Common Mistakes

- Describing the N+1 problem without tracing through actual query counts — interviewers want to see you know it's not just "too many queries" but specifically 1 + N.
- Not knowing the DataLoader batch function signature — interviewers often ask you to write it.
- Forgetting the ordering contract: the batch function must return results in the exact same order as the input keys.
- Not mentioning where DataLoaders should be instantiated (context factory, not inside resolvers).
- Confusing DataLoader's request-scoped cache with a global cache.

### Follow-Up Questions

- "What happens if the DataLoader batch function returns results out of order?"
- "How does DataLoader interact with federation entity resolution? Does the router do its own batching?"
- "When would you disable DataLoader's cache? (Answer: when doing mutations that invalidate the cached data mid-request.)"
- "How would you use DataLoader for a query that fetches by something other than ID — say, by `userId + status`?"

---

## Related Topics

- [Chapter 02: GraphQL Internals](../02-graphql-internals/) — resolver execution model, DataLoader internals
- [Chapter 03: Schema Design](../03-schema-design/) — nullability, pagination, error modeling patterns
- [Chapter 28: Best Practices — Schema](../28-best-practices/01-schema-best-practices.md) — opinionated rules distilled from these questions
- [02-federation-and-architecture-questions.md](./02-federation-and-architecture-questions.md) — continuation for Staff/Principal level
