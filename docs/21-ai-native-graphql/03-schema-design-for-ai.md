# 03 — Schema Design for AI Consumers

> **Purpose:** This document covers the design principles specific to GraphQL schemas that will be consumed by AI agents, LLMs using tool use, and RAG retrieval pipelines. The fundamental shift from human-centric schema design is that LLMs read descriptions to make decisions. Every description is an instruction. Every naming choice is a disambiguation signal. Every nullability decision affects how an LLM-populated field behaves at the boundary of model uncertainty. Engineers who treat schema descriptions as optional metadata are building APIs that AI consumers will use incorrectly.

---

## Why Schema Design Differs for AI Consumers

A human engineer reading your schema has implicit knowledge: they understand domain context, they check related schemas, they ask colleagues, they look at UI mockups. An LLM consuming your schema operates on text alone — primarily the descriptions you write.

Consider two versions of the same field:

```graphql
# Version A — human-oriented, terse
type User {
  addr: String
}

# Version B — AI-oriented, descriptive
type User {
  """
  The user's primary mailing address, formatted as a single string.
  Use for shipping address selection. For structured address components
  (street, city, zip, country), use the `address` field which returns
  a structured `PostalAddress` type. This field returns null for users
  who have not added an address.
  """
  primaryAddressFormatted: String
}
```

An LLM using Version A will guess what `addr` contains. It may use it for purposes you did not intend, or miss it when it should be used, or confuse it with a different address field. Version B removes ambiguity and guides the LLM to make the correct choice.

This is not documentation for its own sake. Schema descriptions are executable guidance for AI consumers.

---

## Semantic Field Naming

Field names are the first disambiguation signal. Names should encode:

1. **The entity being described** — `productTitle` not `title` (when on a `Product` type)
2. **The representation** — `priceFormatted` (string like "$29.99") vs `priceAmount` (number like 29.99) vs `priceCents` (integer like 2999)
3. **The intended use** — `heroImageUrl` not `image`, `thumbnailImageUrl` not `imageSmall`

```graphql
# Bad: Ambiguous names that require context an LLM may not have
type Product {
  title: String           # Title of what?
  desc: String            # Description? Deprecated?
  img: String             # Image URL? Base64? Alt text?
  price: Float            # USD? Cents? The user's currency?
  status: String          # "active"? "in_stock"? An enum string?
  data: JSON              # Completely opaque to LLMs
}

# Good: Names that describe content, representation, and use
type Product {
  """The product's display title as shown in the catalog."""
  name: String!

  """
  Full product description in Markdown format, suitable for display
  and for including in LLM context for summarization or comparison.
  May be up to 5000 characters.
  """
  descriptionMarkdown: String

  """
  URL to the primary product image (JPEG/PNG, 800×800px).
  Use for display and image analysis. For thumbnail (200×200px), use thumbnailUrl.
  """
  primaryImageUrl: String

  """
  Price in the store's base currency (USD). Formatted for display as a
  decimal string (e.g., "29.99"). For numeric calculations, use priceAmountCents.
  """
  priceDisplay: String!

  """
  Price in USD cents as an integer (e.g., 2999 for $29.99).
  Use for arithmetic comparisons. Never display this directly to users.
  """
  priceAmountCents: Int!

  """
  Current inventory status. ACTIVE = available for purchase, OUT_OF_STOCK = temporarily unavailable,
  DISCONTINUED = no longer sold. Use to filter products for purchase recommendations.
  """
  inventoryStatus: ProductInventoryStatus!
}
```

---

## Schema Descriptions as Documentation for AI

Every type and field needs a description. This is non-negotiable for AI-consumed schemas.

Structure descriptions to answer the questions an LLM will have:

1. **What is this?** — One sentence defining the field/type
2. **When should I use this vs. similar fields?** — Disambiguation
3. **What are the valid values or constraints?** — For inputs and enums
4. **What does null mean?** — For nullable fields

```graphql
"""
A customer order representing a purchase transaction.

Use this type when:
- Retrieving order history for a user
- Checking order status for fulfillment queries
- Summarizing purchase activity for customer service

For product catalog queries (not order-related), use the `Product` type directly.
"""
type Order {
  """Globally unique order identifier. Use as a stable reference across systems."""
  id: ID!

  """
  ISO 8601 timestamp when the order was placed (e.g., "2025-05-16T14:30:00Z").
  Use for sorting orders by recency or filtering by date range.
  """
  placedAt: DateTime!

  """
  Current fulfillment status of the order.
  PENDING = payment not confirmed, CONFIRMED = processing,
  SHIPPED = in transit, DELIVERED = received by customer,
  CANCELLED = order cancelled before shipment,
  RETURNED = customer returned items.
  """
  status: OrderStatus!

  """
  The customer who placed this order. Always present — orders cannot exist without a customer.
  """
  customer: User!

  """
  All line items in this order. Empty array if order was fully cancelled before any items were added.
  Returns a maximum of 100 items; orders with more items are rare but possible for B2B accounts.
  """
  lineItems: [OrderLineItem!]!

  """
  Total amount charged to the customer in their selected currency.
  Includes taxes, shipping, and any applied discounts. Null only for orders
  that were cancelled before payment was collected.
  """
  totalAmount: Money

  """
  Shipping tracking number. Null until the order has been shipped (status = SHIPPED or DELIVERED).
  The carrier can be determined from the tracking number format or the `shippingCarrier` field.
  """
  trackingNumber: String

  """
  Reason the order was cancelled. Null for orders that were not cancelled.
  For cancelled orders, always present.
  """
  cancellationReason: String
}
```

---

## `@deprecated` with Meaningful Reason Strings

LLMs read `@deprecated` directives and their reason strings. A meaningful reason string tells the LLM what to use instead and explains the context.

```graphql
type Product {
  # Bad: Deprecation without guidance
  price: Float @deprecated

  # Still bad: Generic guidance
  priceUsd: Float @deprecated(reason: "Use priceDisplay instead")

  # Good: Complete migration guidance that an LLM can act on
  priceUsd: Float @deprecated(
    reason: "Deprecated 2025-03-01. Returns price in USD as a float, which loses precision for non-round amounts. Use priceDisplay (string, e.g. '29.99') for display or priceAmountCents (integer cents) for arithmetic. Both fields are always present."
  )

  """Price formatted for display, e.g. '29.99'. Currency is USD."""
  priceDisplay: String!

  """Price in USD cents. Use for comparisons and calculations."""
  priceAmountCents: Int!
}
```

LLMs generating queries that reference `priceUsd` will receive the deprecation notice in introspection results and can self-correct to use the preferred field without human intervention.

---

## Nullable vs Non-Null in AI Contexts

GraphQL nullability communicates guarantees. For AI-populated fields, the nullability contract must reflect the LLM's ability to produce a value — not a hypothetical ideal.

**Principle: AI-populated fields should be nullable unless you have a hard guarantee.**

```graphql
type Product {
  """
  AI-generated summary of the product suitable for use in recommendations.
  Null if the product description is too short to summarize (< 50 characters)
  or if AI summarization is temporarily unavailable.
  """
  aiSummary: String    # Nullable — AI can fail or be unavailable

  """
  Sentiment of aggregated customer reviews.
  Null for products with fewer than 5 reviews (insufficient data for reliable classification).
  """
  reviewSentiment: SentimentLabel    # Nullable — data may not exist

  """
  Extracted product category tags from description.
  Returns an empty array (never null) when no tags can be extracted.
  """
  aiGeneratedTags: [String!]!    # Non-null array, but elements always present

  """
  Product name — always present, never AI-generated.
  Guaranteed non-null because it is a required field in our data model.
  """
  name: String!    # Non-null — safe because source is structured data
}
```

**Non-null AI fields create operational problems.** If you mark `aiSummary: String!` and your LLM provider is down, every query that requests `aiSummary` will fail the entire query because GraphQL propagates nullability errors upward through non-null parents.

Reserve `!` for fields backed by database constraints or guaranteed system invariants.

---

## Input Validation for AI-Generated Variables

LLMs generate GraphQL variables. They will produce:
- Strings where IDs are expected
- Negative numbers where positive are required
- Invalid enum values (hallucinated)
- Strings that are too long
- Injection payloads

Use custom scalars and input object validation to catch these at the type system boundary:

```graphql
"""
A cursor for connection-based pagination. Opaque to clients — never construct manually.
Must be a value obtained from a previous query's `pageInfo.endCursor`.
"""
scalar Cursor

"""
A URL string. Must be a valid absolute URL (https:// or http://).
AI agents should use URLs from previous query results, not construct them.
"""
scalar URL

input ProductSearchInput {
  """
  Full-text search query. Maximum 200 characters. Do not include SQL or GraphQL syntax.
  """
  query: String!

  """
  Maximum number of results. Range: 1–50. Default: 10. AI agents should use 10 unless
  the user explicitly needs more results.
  """
  first: Int

  """
  Sort order for results. RELEVANCE = ranked by search score (default),
  PRICE_ASC = cheapest first, PRICE_DESC = most expensive first,
  NEWEST = recently added first.
  """
  sortBy: ProductSortOrder = RELEVANCE

  """
  Filter by price range in USD cents. Both minPriceCents and maxPriceCents are optional.
  Example: { minPriceCents: 1000, maxPriceCents: 5000 } for $10–$50 products.
  """
  priceRange: PriceRangeInput
}

input PriceRangeInput {
  """Minimum price in cents (integer, 0 or greater). Null means no lower bound."""
  minPriceCents: Int
  """Maximum price in cents (integer, greater than minPriceCents). Null means no upper bound."""
  maxPriceCents: Int
}
```

Implement server-side validation for custom scalars:

```typescript
// scalars/cursor-scalar.ts
import { GraphQLScalarType, GraphQLError } from 'graphql';

export const CursorScalar = new GraphQLScalarType({
  name: 'Cursor',
  description: 'An opaque pagination cursor. Must be a value from pageInfo.endCursor.',

  serialize(value) {
    if (typeof value !== 'string') throw new GraphQLError('Cursor must be a string');
    return Buffer.from(value).toString('base64');
  },

  parseValue(value) {
    if (typeof value !== 'string') {
      throw new GraphQLError('Cursor variable must be a string');
    }
    try {
      const decoded = Buffer.from(value, 'base64').toString('utf8');
      // Validate format: "typename:id"
      if (!decoded.includes(':')) {
        throw new Error('Invalid cursor format');
      }
      return decoded;
    } catch {
      throw new GraphQLError(
        `Invalid cursor value "${value}". Cursor must be obtained from pageInfo.endCursor in a previous query.`
      );
    }
  },

  parseLiteral(ast) {
    if (ast.kind !== 'StringValue') {
      throw new GraphQLError('Cursor must be a string literal');
    }
    return this.parseValue!(ast.value);
  },
});
```

---

## Pagination Design for AI Agents

AI agents paginate differently from human clients. A human client knows to stop when results are irrelevant. An AI agent in an agentic loop may keep paginating indefinitely.

**Cursor-based pagination is safer than offset-based for AI clients.**

Offset pagination is unsafe for AI agents because:
- `offset: 0, limit: 50` then `offset: 50, limit: 50` ... is trivially easy to loop
- No natural stopping condition visible to the agent
- High offset values create expensive database queries

Cursor pagination provides a natural stopping condition (`hasNextPage: false`) and the cursor value must come from a previous query result — an AI agent cannot fabricate cursors.

```graphql
"""
Pagination metadata for cursor-based connections.
AI agents: check hasNextPage before making additional paginated requests.
Fetching all pages in a loop is almost never the right approach — filter or summarize instead.
"""
type PageInfo {
  """True if there are more results after the current page."""
  hasNextPage: Boolean!
  """True if there are more results before the current page (for reverse pagination)."""
  hasPreviousPage: Boolean!
  """Cursor pointing to the last item on the current page. Use as `after` argument for next page."""
  endCursor: Cursor
  """Cursor pointing to the first item on the current page."""
  startCursor: Cursor
  """
  Total number of items matching the query. Use this to decide whether pagination is necessary
  before fetching subsequent pages. If totalCount is less than 50, a single page is sufficient.
  """
  totalCount: Int!
}
```

```graphql
type Query {
  """
  Returns paginated orders for the specified user.

  Pagination guidance for AI agents:
  - Default page size (first: 10) is appropriate for most queries
  - Use `filter` to narrow results before paginating
  - Check pageInfo.totalCount before paginating — if totalCount < 10, no pagination needed
  - Do not paginate all results to build a complete list; use aggregation queries instead
  """
  userOrders(
    userId: ID!
    first: Int = 10
    after: Cursor
    filter: OrderFilter
  ): OrderConnection!
}
```

---

## Schema Versioning and Stability Signals for AI

AI agents cache schema context. If you change a field's type or meaning, agents using a stale schema will generate invalid queries or misinterpret results.

Use descriptions to signal stability:

```graphql
type Product {
  """
  [STABLE since 2024-01] Product ID. This field name and type will not change.
  Safe to use in long-lived agent configurations.
  """
  id: ID!

  """
  [BETA since 2025-03] AI-generated semantic tags. Field name and return type may change
  before 2025-09. Use experimentalAiTags field name in persisted operations only.
  """
  experimentalAiTags: [String!]

  """
  [DEPRECATED 2025-01, REMOVED 2026-01] Use priceDisplay or priceAmountCents.
  """
  price: Float @deprecated(reason: "Use priceDisplay (string) or priceAmountCents (integer cents). Removed 2026-01.")
}
```

---

## Full Example: AI-Optimized Type Design

Before and after transformation of a typical schema type for AI consumption:

```graphql
# Before: human-readable but AI-hostile
type Product {
  id: ID!
  name: String!
  desc: String
  price: Float!
  cat: String
  img: String
  stock: Boolean!
  rating: Float
  reviews: [Review!]
}

# After: AI-optimized
"""
A product available for purchase in the catalog.

For product search, use the `productSearch` query.
For browsing by category, use `productsByCategory`.
For checking purchase eligibility, check inventoryStatus = ACTIVE.
"""
type Product {
  """Stable unique product identifier. Consistent across environments."""
  id: ID!

  """
  Product name as displayed in the catalog and cart.
  Use for display and when describing the product to users.
  """
  name: String!

  """
  Full product description in Markdown. May include feature lists, specifications,
  and usage instructions. Up to 5000 characters. Null for products with no description.
  Suitable for inclusion in LLM context for summarization or feature extraction.
  """
  descriptionMarkdown: String

  """
  Price in USD formatted for display (e.g., "29.99", "1,299.00").
  Use this for showing prices to users. For arithmetic, use priceAmountCents.
  """
  priceDisplay: String!

  """
  Price in USD cents as an integer (e.g., 2999 for $29.99).
  Use for price comparisons, range filters, and discount calculations.
  """
  priceAmountCents: Int!

  """
  Product category path, e.g. "Electronics > Phones > Accessories".
  Use for categorization and filtering. For structured category data, use the `category` field.
  """
  categoryPath: String

  """
  URL to the product's primary display image (JPEG/PNG, 800×800px).
  Null if no image is available. Do not construct image URLs from product IDs.
  """
  primaryImageUrl: String

  """
  Whether the product can currently be added to cart and purchased.
  ACTIVE = available, OUT_OF_STOCK = temporarily unavailable (restock expected),
  DISCONTINUED = permanently unavailable (suggest alternatives).
  Filter for ACTIVE status when making purchase recommendations.
  """
  inventoryStatus: ProductInventoryStatus!

  """
  Average customer review score from 1.0 to 5.0.
  Null for products with fewer than 3 reviews (insufficient data for reliable average).
  Use alongside reviewCount to assess reliability of the rating.
  """
  averageRating: Float

  """
  Total number of customer reviews.
  Use to weight the reliability of averageRating.
  """
  reviewCount: Int!

  """
  AI-generated summary of customer sentiment from reviews.
  Null if reviewCount < 5 or if AI summarization is temporarily unavailable.
  Do not display to users as a substitute for actual reviews.
  """
  reviewSentimentSummary: String

  """
  First 10 most helpful customer reviews. For all reviews, use the `reviews` query.
  Empty array for products with no reviews.
  """
  topReviews: [Review!]!
}
```

---

## References

- [GraphQL Schema Description Syntax](https://spec.graphql.org/October2021/#sec-Descriptions)
- [Relay Connection Specification](https://relay.dev/graphql/connections.htm)
- [OpenAI Function Calling Schema Best Practices](https://platform.openai.com/docs/guides/function-calling/best-practices)

## Related Topics

- [Chapter 03: Schema Design](../03-schema-design/README.md) — Core schema design principles
- [Chapter 21.01: GraphQL as AI Tool](./01-graphql-as-ai-tool.md) — Auto-generating tool definitions from schema
- [Chapter 21.04: AI Gateway Patterns](./04-ai-gateway-patterns.md) — Schema-aware prompt construction
- [Chapter 22: RAG and Vector Search](../22-rag-and-vector-search/README.md) — Using schema field selection to control context budget
