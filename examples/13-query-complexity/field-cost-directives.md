# Field Cost Directives — Schema-Level Complexity Annotations

Companion docs: `../../docs/06-performance-and-scaling/`, `../../docs/05-security/`, `../../docs/09-schema-governance/`

---

## 1. The @cost Directive — Proposed GraphQL Cost Spec

The GraphQL Cost Specification is a community draft (not yet ratified) that proposes standardized `@cost` and `@listSize` directives for expressing query cost in the schema itself. The advantage over code-level complexity estimators is that the cost information lives in the schema SDL where all tooling — validators, IDEs, documentation generators — can read it without executing any code.

The current draft is available at https://ibm.github.io/graphql-cost-spec/ (draft). The directive shapes below track the draft as of late 2024. Because this is a draft specification, treat the directive definitions as subject to change; pin the version of any implementation library you use.

### Defining the Directives in SDL

```graphql
# cost-directives.graphql
# Add these to your schema definition. Both directives must be declared
# in the schema before they can be used on field definitions.

"""
@cost assigns a static complexity weight to a field.
The weight is added to the query complexity score regardless of
how many items the field returns (for that, use @listSize).

weight: A positive integer representing the relative cost of this field.
        The unit is arbitrary — choose a scale and apply it consistently.
        Common convention: 1 = cheap scalar, 10 = external API call.
"""
directive @cost(weight: Int!) on FIELD_DEFINITION

"""
@listSize provides hints to complexity analyzers about how large
a list field's response is expected to be.

assumedSize: The default assumed item count when no slicing argument
             is provided. Used as the multiplier in cost calculations.

slicingArguments: Names of arguments that control the number of items
                  returned (e.g., ["first", "limit", "pageSize"]).
                  The complexity analyzer reads the actual argument value
                  from the query to compute the real multiplier.

sizedFields: For connection-pattern types (edges/nodes), names the
             subfields that contain the actual list. Complexity is
             multiplied for these subfields, not the connection wrapper.

requireOneSlicingArgument: If true, the query is invalid if none of the
                            slicingArguments are provided. Enforces that
                            clients must specify a page size.
"""
directive @listSize(
  assumedSize: Int
  slicingArguments: [String!]
  sizedFields: [String!]
  requireOneSlicingArgument: Boolean = false
) on FIELD_DEFINITION
```

---

## 2. @listSize Directive — List Size Hints

`@listSize` is the more important of the two directives because it controls how multipliers are applied in complexity calculations. Without size hints, a complexity analyzer must either assume a fixed multiplier (often 10 by convention) or refuse to compute list complexity at all.

```graphql
type Query {
  # No slicing argument — the list always returns all items.
  # assumedSize: 50 tells the analyzer to multiply child complexity by 50.
  # This field intentionally has no first/limit arg; it's a bounded list
  # (system configuration items, not user-generated content).
  supportedCurrencies: [Currency!]!
    @listSize(assumedSize: 50)
    @cost(weight: 2)

  # Paginated list with relay-style cursor pagination.
  # slicingArguments: ["first", "last"] means the analyzer reads the actual
  # value of the `first` or `last` argument in the query to compute the multiplier.
  # requireOneSlicingArgument: true means the query is invalid if neither
  # first nor last is provided — prevents unbounded list requests.
  products(
    first: Int
    last: Int
    after: String
    before: String
    filter: ProductFilter
  ): ProductConnection!
    @listSize(
      slicingArguments: ["first", "last"]
      sizedFields: ["edges"]
      requireOneSlicingArgument: true
    )
    @cost(weight: 3)

  # Search with both a page size and a facet count argument.
  # The primary slicing argument is `first`. The analyzer uses the first
  # recognized slicing argument it finds in the query.
  searchProducts(
    query: String!
    first: Int = 20
    facets: [String!]
  ): SearchResult!
    @listSize(
      slicingArguments: ["first"]
      assumedSize: 20   # default when first is not specified
      sizedFields: ["items"]
    )
    @cost(weight: 5)
}
```

---

## 3. Implementation — Custom Directive Visitor

The following TypeScript implementation reads `@cost` and `@listSize` metadata from the schema and feeds it into `graphql-query-complexity`'s estimator system.

```typescript
// src/complexity/directive-cost-visitor.ts
import {
  GraphQLSchema,
  GraphQLObjectType,
  GraphQLInterfaceType,
  GraphQLUnionType,
  GraphQLField,
  isObjectType,
  isInterfaceType,
  GraphQLDirective,
  DirectiveNode,
  getNamedType,
  isListType,
  isNonNullType,
} from 'graphql';
import type { ComplexityEstimatorArgs } from 'graphql-query-complexity';

interface CostMetadata {
  weight: number;
  listSize?: {
    assumedSize?: number;
    slicingArguments?: string[];
    sizedFields?: string[];
    requireOneSlicingArgument?: boolean;
  };
}

/**
 * Extracts cost metadata from @cost and @listSize directives on a field.
 * Returns null if neither directive is present (caller should fall through
 * to a default estimator).
 */
function extractCostMetadata(
  field: GraphQLField<unknown, unknown>
): CostMetadata | null {
  const directives = field.astNode?.directives ?? [];

  let weight: number | null = null;
  let listSize: CostMetadata['listSize'] | null = null;

  for (const directive of directives) {
    if (directive.name.value === 'cost') {
      const weightArg = directive.arguments?.find(
        (a) => a.name.value === 'weight'
      );
      if (weightArg && weightArg.value.kind === 'IntValue') {
        weight = parseInt(weightArg.value.value, 10);
      }
    }

    if (directive.name.value === 'listSize') {
      listSize = {};

      const assumedSizeArg = directive.arguments?.find(
        (a) => a.name.value === 'assumedSize'
      );
      if (assumedSizeArg && assumedSizeArg.value.kind === 'IntValue') {
        listSize.assumedSize = parseInt(assumedSizeArg.value.value, 10);
      }

      const slicingArgs = directive.arguments?.find(
        (a) => a.name.value === 'slicingArguments'
      );
      if (slicingArgs && slicingArgs.value.kind === 'ListValue') {
        listSize.slicingArguments = slicingArgs.value.values
          .filter((v) => v.kind === 'StringValue')
          .map((v) => (v as any).value as string);
      }

      const sizedFields = directive.arguments?.find(
        (a) => a.name.value === 'sizedFields'
      );
      if (sizedFields && sizedFields.value.kind === 'ListValue') {
        listSize.sizedFields = sizedFields.value.values
          .filter((v) => v.kind === 'StringValue')
          .map((v) => (v as any).value as string);
      }

      const requireOne = directive.arguments?.find(
        (a) => a.name.value === 'requireOneSlicingArgument'
      );
      if (requireOne) {
        listSize.requireOneSlicingArgument =
          requireOne.value.kind === 'BooleanValue'
            ? requireOne.value.value
            : false;
      }
    }
  }

  if (weight === null && listSize === null) return null;

  return { weight: weight ?? 1, listSize: listSize ?? undefined };
}

/**
 * Builds a graphql-query-complexity estimator function that reads from
 * @cost and @listSize directives on the schema fields.
 *
 * Usage:
 *   estimators: [
 *     directiveCostEstimator(schema),
 *     simpleEstimator({ defaultComplexity: 1 }),
 *   ]
 */
export function directiveCostEstimator(schema: GraphQLSchema) {
  return ({
    field,
    args,
    childComplexity,
  }: ComplexityEstimatorArgs): number | undefined => {
    const metadata = extractCostMetadata(field);
    if (metadata === null) return undefined; // fall through to next estimator

    const { weight, listSize } = metadata;

    if (!listSize) {
      // Simple scalar or object field — just the weight
      return weight;
    }

    // List field: weight + (pageSize * childComplexity)
    let pageSize = listSize.assumedSize ?? 10;

    // If slicingArguments are defined, check the actual query arguments
    if (listSize.slicingArguments) {
      for (const slicingArg of listSize.slicingArguments) {
        const argValue = args[slicingArg];
        if (typeof argValue === 'number') {
          pageSize = argValue;
          break; // Use the first matching slicing argument
        }
      }
    }

    return weight + pageSize * childComplexity;
  };
}
```

---

## 4. Annotated E-Commerce Schema with Cost Directives

This is a realistic e-commerce subgraph schema with cost directives applied to every non-trivial field. The annotations document the cost model for anyone reading the schema.

```graphql
# schema/products.graphql

type Query {
  # Fast primary key lookup — single DB row, always cached by DataLoader
  product(id: ID!): Product
    @cost(weight: 1)

  # Category lookup — cached aggressively (categories change rarely)
  category(slug: String!): Category
    @cost(weight: 1)

  # Paginated product list — requires first or last to be specified
  products(
    first: Int
    last: Int
    after: String
    before: String
    categoryId: ID
    filter: ProductFilter
    sortBy: ProductSortField
    sortDirection: SortDirection
  ): ProductConnection!
    @cost(weight: 3)
    @listSize(
      slicingArguments: ["first", "last"]
      sizedFields: ["edges"]
      assumedSize: 20
      requireOneSlicingArgument: true
    )

  # Full-text product search — hits Elasticsearch, not the primary DB
  searchProducts(
    query: String!
    first: Int = 20
    categoryIds: [ID!]
    priceRange: PriceRangeInput
    inStock: Boolean
  ): SearchProductsResult!
    @cost(weight: 8)
    @listSize(
      slicingArguments: ["first"]
      sizedFields: ["items"]
      assumedSize: 20
    )

  # Featured products — cached at CDN level, 5-minute TTL
  # Low weight despite being a list because it's almost always a cache hit
  featuredProducts(placement: FeaturedPlacement!): [Product!]!
    @cost(weight: 2)
    @listSize(assumedSize: 12)
}

type Product {
  id: ID!          # cost 1 (scalar, default)
  sku: String!     # cost 1
  name: String!    # cost 1
  slug: String!    # cost 1
  description: String  # cost 1
  price: Money!    # cost 1
  compareAtPrice: Money  # cost 1

  # Relationship to a bounded list (variants per product rarely exceed 20)
  variants: [ProductVariant!]!
    @cost(weight: 1)
    @listSize(assumedSize: 10)

  # Category — DataLoader batched, single round-trip for all products
  category: Category!
    @cost(weight: 2)

  # Tags — a bounded list, rarely more than 10
  tags: [String!]!
    @cost(weight: 1)
    @listSize(assumedSize: 10)

  # Reviews — a paginated list of user-generated content
  # Higher base cost because reviews require a separate DB query per product
  # (no join-based batch loading available with the current data model)
  reviews(first: Int = 10, after: String): ReviewConnection!
    @cost(weight: 4)
    @listSize(
      slicingArguments: ["first"]
      sizedFields: ["edges"]
      assumedSize: 10
    )

  # Average rating — precomputed and stored, not calculated at query time
  averageRating: Float
    @cost(weight: 1)

  # Review count — precomputed, single column read
  reviewCount: Int!
    @cost(weight: 1)

  # AI-powered recommendations — calls external ML inference service
  # High fixed weight (15) captures the external HTTP call overhead
  # even before the list multiplier is applied
  recommendations(first: Int = 5): [Product!]!
    @cost(weight: 15)
    @listSize(
      slicingArguments: ["first"]
      assumedSize: 5
    )

  # Real-time inventory status — calls inventory microservice via gRPC
  # No DataLoader available; every product requires a separate call
  # TODO: Implement batch inventory API and reduce weight to 2
  inventoryStatus: InventoryStatus!
    @cost(weight: 10)

  # Images — stored in CDN, fast to resolve, bounded list
  images(first: Int = 5): [ProductImage!]!
    @cost(weight: 1)
    @listSize(
      slicingArguments: ["first"]
      assumedSize: 5
    )

  # SEO metadata — single row join, DataLoader compatible
  seo: SeoMetadata
    @cost(weight: 1)

  # Related products via merchandising rules — DB join query
  relatedProducts(first: Int = 10): ProductConnection!
    @cost(weight: 4)
    @listSize(
      slicingArguments: ["first"]
      sizedFields: ["edges"]
      assumedSize: 10
    )
}

# The schema continues for Order, Customer, etc. with similar annotations
```

---

## 5. Federation Compatibility

In a federated schema, subgraphs define their own types and the router composes them into a supergraph. Cost directives must be defined and respected at both levels.

### Option A: Define @cost in Each Subgraph

Each subgraph includes the `@cost` and `@listSize` directive definitions in its own SDL. The subgraph's own validation rules read these directives during composition.

```graphql
# In each subgraph's schema (e.g., products-subgraph.graphql)
# The directive must be declared with @composeDirective to propagate through composition

directive @cost(weight: Int!) on FIELD_DEFINITION
directive @listSize(
  assumedSize: Int
  slicingArguments: [String!]
  sizedFields: [String!]
  requireOneSlicingArgument: Boolean = false
) on FIELD_DEFINITION

# Declare these as composition-time directives so they survive into the supergraph
extend schema
  @link(url: "https://specs.apollo.dev/federation/v2.3", import: ["@key", "@external"])
  @link(url: "https://ibm.github.io/graphql-cost-spec/cost/v0.1", import: ["@cost", "@listSize"])
  @composeDirective(name: "@cost")
  @composeDirective(name: "@listSize")
```

When using `@composeDirective`, Apollo Federation composition preserves the directives in the supergraph SDL. The router's complexity analyzer reads the supergraph SDL and finds the cost annotations exactly as if they were defined at the supergraph level.

### Option B: Apply Cost Annotations at the Supergraph Level

Alternatively, define costs centrally in a supergraph configuration rather than in each subgraph. This is useful when subgraph teams do not want to own the cost model, or when the cost of a field depends on cross-subgraph entity resolution (e.g., a field that triggers fetches from three subgraphs).

```yaml
# supergraph-overrides.yaml — managed by the platform team
# Overrides cost annotations for specific fields where the subgraph
# author's annotation does not account for cross-subgraph fan-out
fieldCostOverrides:
  "Product.recommendations":
    weight: 20    # Higher than the 15 in the subgraph SDL because this field
                  # triggers both the products subgraph AND the ML subgraph
  "Order.lineItems":
    weight: 5
    listSize:
      slicingArguments: ["first"]
      assumedSize: 20
```

### Caveats for Federation

When an entity is resolved through `@key`-based entity fetching (the `_entities` query), the complexity of fetching that entity is not automatically included in the parent field's complexity score. A field annotated `@cost(weight: 2)` that resolves a federated entity actually costs 2 (for the reference resolution in the requesting subgraph) plus the cost of the `_entities` call in the owning subgraph. This cross-subgraph cost is difficult to capture in static annotations.

The practical recommendation is to add an overhead factor to any field that crosses a subgraph boundary. If the entity resolution in the owning subgraph would normally cost 3, add at least 3 to the requesting field's weight to account for the network hop and entity resolution.

---

## 6. Client Tooling — VS Code GraphQL LSP Integration

The GraphQL Language Server Protocol (LSP) extension for VS Code (the official `GraphQL: Language Feature Support` extension, ID: `GraphQL.vscode-graphql`) can expose complexity information inline using the schema's cost directive annotations.

### Inline Complexity Hints

The LSP extension supports custom extension points. When a schema with `@cost` and `@listSize` is loaded, a TypeScript LSP plugin can compute complexity for the query in the currently open file and display it as a code lens or hover tooltip.

```typescript
// .graphqlrc.ts — VS Code GraphQL extension configuration
import type { IGraphQLProject } from 'graphql-config';

const config: IGraphQLProject = {
  schema: './schema/**/*.graphql',
  documents: './src/**/*.{ts,tsx,graphql}',
  extensions: {
    // Enable complexity analysis plugin
    complexity: {
      // Maximum complexity shown as a warning in the editor
      warnAtComplexity: 500,
      // Maximum complexity shown as an error in the editor
      errorAtComplexity: 1000,
      // Show complexity as a code lens above each operation
      showCodeLens: true,
    },
  },
};

export default config;
```

When the plugin is active, developers see inline feedback like:

```
[Complexity: 47] query ProductDetail($id: ID!) {
  product(id: $id) {
    name
    price
    recommendations(first: 5) {   # adds 40 to complexity
      name
    }
  }
}
```

This early-feedback loop is the most effective mechanism for keeping query complexity under control: engineers see the cost while writing the query, long before CI runs.

### CI/CD Complexity Gate

For teams without the LSP plugin, a complexity check in the pre-commit hook or CI pipeline provides the same safety net:

```yaml
# .github/workflows/graphql-complexity.yml
name: GraphQL Complexity Check

on:
  pull_request:
    paths:
      - 'src/**/*.graphql'
      - 'src/**/*.tsx'   # gql`` tagged templates
      - 'src/**/*.ts'

jobs:
  complexity:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
      - run: npm ci
      - name: Check query complexity
        run: |
          npx ts-node scripts/check-complexity.ts \
            --schema ./schema/supergraph.graphql \
            --operations './src/**/*.graphql' \
            --max-complexity 800 \
            --warn-complexity 500
        env:
          CI: true
```

---

## Key Design Decisions

**Why put cost annotations in the schema SDL rather than in resolver code:** Schema SDL is the contract between the server and its clients. Cost information belongs in the contract because it affects how clients should structure their queries. Keeping cost in resolver extensions (see `complexity-analysis.md`) means the cost model is not visible to tooling that reads the SDL — documentation generators, IDEs, and static analysis tools cannot see it. The SDL approach makes the cost model part of the public API contract.

**Why the IBM GraphQL Cost Spec rather than a custom directive:** Using a draft spec rather than a fully custom directive means there is a reasonable chance that future tooling support will be built around this directive definition. Even if the spec never becomes a standard, the directive names and semantics are widely understood in the GraphQL community. A bespoke directive would require custom documentation.

**Why sizedFields matters for connection patterns:** The relay connection pattern wraps list items in an intermediate `edges` type: `products { edges { node { ... } } }`. Without `sizedFields: ["edges"]`, the complexity multiplier would be applied to all fields of the `ProductConnection` type, including `pageInfo` and `totalCount`, which are cheap scalar fields. `sizedFields` ensures the multiplier applies only to the actual list content.

**Why requireOneSlicingArgument: true is a governance feature:** Making the slicing argument required at the schema level prevents clients from omitting page size limits entirely. Without this, a client that forgets to include `first: N` gets all matching records — potentially millions of rows. Requiring the argument shifts the default from unbounded to explicit, which is the correct default for any API exposed to clients.

---

## Related Documentation

- `../../docs/09-schema-governance/` — RFC and review process for adding cost annotations to new fields
- `../../docs/06-performance-and-scaling/` — Runtime performance data that informs what cost weights to assign
- `../../docs/10-schema-validation/` — Schema linting and validation pipelines where cost directive presence can be enforced
- `../../docs/05-security/` — How cost directives contribute to the overall defense-in-depth strategy against abusive queries
