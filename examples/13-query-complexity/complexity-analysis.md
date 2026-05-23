# Query Complexity Analysis with graphql-query-complexity

Companion docs: `../../docs/06-performance-and-scaling/`, `../../docs/05-security/`

---

## 1. Installation and Basic Setup

`graphql-query-complexity` integrates with Apollo Server 4's `validationRules` mechanism. Validation rules run synchronously during the validation phase — after the query is parsed but before any resolver executes. If a complexity rule rejects the query, no resolver runs at all and the server returns a 400-class error. This is the correct place to enforce limits: cheap to evaluate, no partial execution, deterministic behavior.

```bash
npm install graphql-query-complexity
# Peer dependency — should already be installed
npm install graphql
```

```typescript
// src/server.ts
import { ApolloServer } from '@apollo/server';
import { expressMiddleware } from '@apollo/server/express4';
import {
  createComplexityLimitRule,
  fieldExtensionsEstimator,
  simpleEstimator,
} from 'graphql-query-complexity';
import { schema } from './schema';

// Maximum query complexity score allowed before the server rejects the query.
// 1000 is a reasonable starting threshold for most APIs. Tune this based on
// your P99 complexity scores observed in production over 2-4 weeks of traffic.
const MAX_QUERY_COMPLEXITY = 1000;

// Complexity score at which we emit a warning log but still allow execution.
// Useful for identifying queries that are approaching the hard limit.
const WARN_QUERY_COMPLEXITY = 500;

const complexityLimitRule = createComplexityLimitRule(MAX_QUERY_COMPLEXITY, {
  // Called when the complexity exceeds the hard limit.
  // The query is rejected — this is invoked before any error is returned.
  onCost: (cost: number) => {
    console.warn({ event: 'query_complexity_rejected', cost });
  },

  // Called for every query that passes validation with its computed cost.
  // Use this to emit metrics to your observability platform.
  createError: (max: number, actual: number) => {
    return new Error(
      `Query complexity ${actual} exceeds the maximum allowed complexity of ${max}. ` +
        `Simplify your query by reducing the number of nested fields or requesting fewer records per page.`
    );
  },

  estimators: [
    // fieldExtensionsEstimator reads cost from the field's extensions object
    // in the schema definition. This is the primary mechanism — it reads
    // complexity weights that you annotate directly on resolver configs.
    fieldExtensionsEstimator(),

    // simpleEstimator is the fallback. Any field that does not have explicit
    // cost annotation in extensions gets this default cost.
    // Default cost of 1 means scalar fields, enums, and simple object reads
    // are essentially free relative to expensive list/computed fields.
    simpleEstimator({ defaultComplexity: 1 }),
  ],
});

const server = new ApolloServer({
  schema,
  // validationRules run in order; add complexityLimitRule after any auth-related
  // rules so that unauthenticated requests are rejected before we spend cycles
  // computing complexity.
  validationRules: [complexityLimitRule],
});
```

---

## 2. Field Cost Definitions

Costs are attached to resolver configurations via the `extensions.complexity` property. This keeps the cost metadata co-located with the resolver it describes rather than in a separate configuration file that can drift out of sync.

```typescript
// src/resolvers/product.resolvers.ts

export const productResolvers = {
  Query: {
    // Simple ID lookup — hits primary key index, returns one row.
    // Cost 1 is appropriate: fast, predictable, low resource usage.
    product: {
      resolve: async (_: unknown, { id }: { id: string }, ctx: Context) => {
        return ctx.loaders.product.load(id);
      },
      extensions: {
        complexity: 1,
      },
    },

    // List query with pagination. The cost scales with how many records
    // the client requests. See Section 3 for the dynamic argument multiplier.
    // Base cost is 2 because even an empty list requires a DB round-trip.
    products: {
      resolve: async (_: unknown, args: ProductsArgs, ctx: Context) => {
        return ctx.loaders.products.loadMany(args);
      },
      extensions: {
        complexity: ({ args, childComplexity }: ComplexityEstimatorArgs) => {
          // childComplexity is the sum of the complexity of all fields the
          // client is requesting on each product. Multiply by the number of
          // items requested to get the total cost of this list.
          const pageSize = args.first ?? args.limit ?? 10;
          return 2 + pageSize * childComplexity;
        },
      },
    },

    // Search query runs a full-text search index query plus a JOIN.
    // More expensive than a simple lookup but bounded by pageSize.
    searchProducts: {
      resolve: async (_: unknown, args: SearchArgs, ctx: Context) => {
        return ctx.services.search.query(args.query, args);
      },
      extensions: {
        complexity: ({ args, childComplexity }: ComplexityEstimatorArgs) => {
          const pageSize = args.first ?? 20;
          // Full-text search base cost is 5 (more expensive than a keyed lookup)
          return 5 + pageSize * childComplexity;
        },
      },
    },
  },

  Product: {
    // Simple scalar fields — the fieldExtensionsEstimator will fall through to
    // simpleEstimator(1) for these since no complexity is defined. Listed here
    // for documentation clarity, not because they need explicit annotation.
    id: { resolve: (p: Product) => p.id },
    name: { resolve: (p: Product) => p.name },
    price: { resolve: (p: Product) => p.price },

    // Relationship field that resolves to a single object type.
    // Cost 2: one DataLoader call, resolves in the same batch as siblings.
    category: {
      resolve: async (product: Product, _: unknown, ctx: Context) => {
        return ctx.loaders.category.load(product.categoryId);
      },
      extensions: {
        complexity: 2,
      },
    },

    // Reviews is a list field. Each review has nested fields (author, etc.)
    // so we apply the page-size multiplier.
    reviews: {
      resolve: async (product: Product, args: ReviewsArgs, ctx: Context) => {
        return ctx.loaders.reviewsByProduct.load({
          productId: product.id,
          ...args,
        });
      },
      extensions: {
        complexity: ({ args, childComplexity }: ComplexityEstimatorArgs) => {
          const pageSize = args.first ?? 10;
          return 1 + pageSize * childComplexity;
        },
      },
    },

    // AI-powered recommendations call an external ML service.
    // This is expensive: external HTTP call, typically 200-500ms latency.
    // High fixed cost (15) communicates to clients that this field is not
    // cheap even before considering the list multiplier.
    recommendations: {
      resolve: async (product: Product, args: RecommendationsArgs, ctx: Context) => {
        return ctx.services.recommendations.fetch(product.id, args.first ?? 5);
      },
      extensions: {
        complexity: ({ args, childComplexity }: ComplexityEstimatorArgs) => {
          const count = args.first ?? 5;
          return 15 + count * childComplexity;
        },
      },
    },

    // N+1 prone field: no DataLoader available because the vendor SDK does not
    // support batch loading. Each product requires a separate HTTP call.
    // High base cost (10) penalizes requesting this field on many products.
    // Consider adding a DataLoader and reducing this cost once implemented.
    inventoryStatus: {
      resolve: async (product: Product, _: unknown, ctx: Context) => {
        return ctx.services.inventory.getStatus(product.id);
      },
      extensions: {
        // TODO: implement DataLoader for inventory batch API and reduce cost to 2
        complexity: 10,
      },
    },
  },
};
```

---

## 3. ComplexityEstimatorArgs — Dynamic Cost from Arguments

The `ComplexityEstimatorArgs` type gives you access to the field arguments, the parent type, the field definition, and the sum of child field complexities. This allows computing costs that scale with query parameters rather than using fixed weights.

```typescript
// src/complexity/estimators.ts
import type { ComplexityEstimatorArgs } from 'graphql-query-complexity';
import type { GraphQLField } from 'graphql';

/**
 * A reusable pagination estimator for any list field that uses
 * the relay-style `first`/`last` cursor pagination pattern.
 *
 * Usage:
 *   extensions: { complexity: paginatedListEstimator(2) }
 *
 * @param baseCost - Fixed cost charged for the query itself (DB round-trip).
 */
export function paginatedListEstimator(baseCost: number) {
  return ({ args, childComplexity }: ComplexityEstimatorArgs): number => {
    // Prefer `first` (forward pagination) over `last` (backward pagination).
    // Default to 10 if no argument is provided — this matches our default
    // page size in the API, so unspecified pages are costed accurately.
    const pageSize = typeof args.first === 'number'
      ? args.first
      : typeof args.last === 'number'
      ? args.last
      : 10;

    // Cap at our maximum allowed page size so complexity scores don't blow up
    // even if a client specifies an unreasonably large page size (those requests
    // will also fail on the input validation layer, but defense in depth).
    const clampedSize = Math.min(pageSize, 100);

    return baseCost + clampedSize * childComplexity;
  };
}

/**
 * A reusable estimator for search/filter list fields that also apply
 * a full-text search or vector search query.
 */
export function searchListEstimator(baseCost: number) {
  return ({ args, childComplexity }: ComplexityEstimatorArgs): number => {
    const pageSize = Math.min(args.first ?? 20, 100);
    // Add extra cost for faceted search (multiple facets = multiple index queries)
    const facetCost = Array.isArray(args.facets) ? args.facets.length * 2 : 0;
    return baseCost + facetCost + pageSize * childComplexity;
  };
}

/**
 * Estimator for time-range queries (e.g., order history, audit logs).
 * Wide time ranges are more expensive — we add a penalty for ranges > 30 days.
 */
export function timeRangeEstimator(baseCost: number) {
  return ({ args, childComplexity }: ComplexityEstimatorArgs): number => {
    const pageSize = Math.min(args.first ?? 20, 100);
    let rangePenalty = 0;
    if (args.startDate && args.endDate) {
      const days = (new Date(args.endDate).getTime() - new Date(args.startDate).getTime())
        / (1000 * 60 * 60 * 24);
      // Ranges over 30 days get a penalty proportional to the extra width
      if (days > 30) {
        rangePenalty = Math.floor((days - 30) / 10) * 2;
      }
    }
    return baseCost + rangePenalty + pageSize * childComplexity;
  };
}
```

---

## 4. createComplexityLimitRule — Wiring Everything Together

The complete integration including per-operation-name logging and threshold behavior:

```typescript
// src/complexity/complexity-rule.ts
import {
  createComplexityLimitRule,
  fieldExtensionsEstimator,
  simpleEstimator,
} from 'graphql-query-complexity';
import type { ValidationContext } from 'graphql';
import { logger } from '../observability/logger';
import { metrics } from '../observability/metrics';

const MAX_COMPLEXITY = parseInt(process.env.GRAPHQL_MAX_COMPLEXITY ?? '1000', 10);
const WARN_COMPLEXITY = parseInt(process.env.GRAPHQL_WARN_COMPLEXITY ?? '500', 10);

export function buildComplexityLimitRule() {
  return createComplexityLimitRule(MAX_COMPLEXITY, {
    estimators: [
      fieldExtensionsEstimator(),
      simpleEstimator({ defaultComplexity: 1 }),
    ],

    onCost: (cost: number, context: ValidationContext) => {
      // Extract operation name for structured logging.
      // This makes it easy to find which operations are expensive.
      const operationDef = context.getDocument().definitions.find(
        (d) => d.kind === 'OperationDefinition'
      );
      const operationName =
        operationDef && 'name' in operationDef && operationDef.name
          ? operationDef.name.value
          : 'anonymous';

      if (cost >= MAX_COMPLEXITY) {
        // Hard rejection — query will not execute.
        logger.warn({
          event: 'query_complexity_rejected',
          operationName,
          cost,
          limit: MAX_COMPLEXITY,
        });
        metrics.increment('graphql.complexity.rejected', { operationName });
      } else if (cost >= WARN_COMPLEXITY) {
        // Soft warning — query executes but engineers should know about it.
        logger.info({
          event: 'query_complexity_high',
          operationName,
          cost,
          warnThreshold: WARN_COMPLEXITY,
          limit: MAX_COMPLEXITY,
        });
        metrics.increment('graphql.complexity.high', { operationName });
      } else {
        // Normal range — record for histogram.
        metrics.histogram('graphql.complexity.score', cost, { operationName });
      }
    },

    createError: (max: number, actual: number) => {
      // Error message is client-visible. Be specific about what to do
      // rather than just saying "too complex." Clients get actionable guidance.
      return new Error(
        `Query complexity ${actual} exceeds the maximum allowed complexity of ${max}. ` +
          `Reduce complexity by: (1) requesting fewer fields per object, ` +
          `(2) using smaller page sizes (e.g., first: 10 instead of first: 100), ` +
          `(3) removing deeply nested relationships from a single query and ` +
          `fetching them in separate queries, or (4) using persisted queries ` +
          `which bypass complexity limits if pre-approved.`
      );
    },
  });
}
```

---

## 5. Persisted Query Complexity Pre-Computation

For production APIs using Apollo Persisted Queries (APQ), complexity can be computed at query publish time and stored in the manifest. Queries within their pre-approved budget execute without the per-request complexity calculation overhead. Queries that are not in the manifest are rejected entirely in production.

```typescript
// scripts/compute-manifest-complexity.ts
// Run this during CI/CD when publishing a new set of persisted queries.

import * as fs from 'fs';
import { parse, buildASTSchema } from 'graphql';
import {
  getComplexity,
  fieldExtensionsEstimator,
  simpleEstimator,
} from 'graphql-query-complexity';
import { schema } from '../src/schema';

interface PersistedQueryManifest {
  format: 'apollo-persisted-query-manifest';
  version: number;
  operations: Array<{
    id: string;
    name: string;
    body: string;
    type: 'query' | 'mutation' | 'subscription';
    // Added by this script:
    complexity?: number;
    complexityApprovedAt?: string;
    complexityApprovedBy?: string;
  }>;
}

const MANIFEST_PATH = './persisted-query-manifest.json';
const MAX_APPROVED_COMPLEXITY = 800; // Slightly lower than runtime limit
const manifest: PersistedQueryManifest = JSON.parse(
  fs.readFileSync(MANIFEST_PATH, 'utf-8')
);

const results: Array<{ name: string; complexity: number; status: string }> = [];

for (const op of manifest.operations) {
  const document = parse(op.body);
  const complexity = getComplexity({
    schema,
    query: document,
    estimators: [
      fieldExtensionsEstimator(),
      simpleEstimator({ defaultComplexity: 1 }),
    ],
  });

  op.complexity = complexity;
  op.complexityApprovedAt = new Date().toISOString();
  op.complexityApprovedBy = process.env.CI_ACTOR ?? 'ci';

  results.push({
    name: op.name,
    complexity,
    status: complexity > MAX_APPROVED_COMPLEXITY ? 'REJECTED' : 'APPROVED',
  });
}

// Write back the manifest with complexity annotations
fs.writeFileSync(MANIFEST_PATH, JSON.stringify(manifest, null, 2));

// Print a summary table for CI logs
console.log('\nComplexity Pre-Computation Results:');
console.table(results);

const rejected = results.filter((r) => r.status === 'REJECTED');
if (rejected.length > 0) {
  console.error(`\n${rejected.length} operations exceed the complexity budget:`);
  rejected.forEach((r) => console.error(`  ${r.name}: ${r.complexity}`));
  process.exit(1); // Fail the CI pipeline
}

console.log('\nAll operations within complexity budget. Manifest updated.');
```

---

## 6. Exposing Complexity in Response Headers

Returning the computed complexity score in a response extension or header gives client teams visibility into how expensive their queries are. This is the fastest way to encourage clients to optimize: show them the number and let them compare it to the limit.

```typescript
// src/plugins/complexity-header-plugin.ts
import type { ApolloServerPlugin } from '@apollo/server';
import {
  getComplexity,
  fieldExtensionsEstimator,
  simpleEstimator,
} from 'graphql-query-complexity';
import { schema } from '../schema';

/**
 * Apollo Server plugin that computes query complexity and adds it to
 * the response as both an HTTP header and a GraphQL extension.
 *
 * HTTP header: X-Query-Complexity: 47
 * GraphQL extension: { "queryComplexity": 47 }
 *
 * Client teams can log this value alongside their query performance data
 * and use it to identify queries that should be split or optimized.
 */
export const complexityHeaderPlugin: ApolloServerPlugin = {
  async requestDidStart() {
    return {
      async willSendResponse({ response, document, operationName }) {
        if (!document) return;

        try {
          const complexity = getComplexity({
            schema,
            query: document,
            estimators: [
              fieldExtensionsEstimator(),
              simpleEstimator({ defaultComplexity: 1 }),
            ],
          });

          // Add to HTTP response headers so it's visible in browser DevTools
          // and in API testing tools like Insomnia and Postman.
          if (response.http) {
            response.http.headers.set('X-Query-Complexity', String(complexity));
            response.http.headers.set(
              'X-Query-Complexity-Limit',
              String(process.env.GRAPHQL_MAX_COMPLEXITY ?? '1000')
            );
          }

          // Add to GraphQL extensions for clients that parse the full
          // response body (mobile apps, non-browser clients).
          if (response.body.kind === 'single') {
            response.body.singleResult.extensions = {
              ...response.body.singleResult.extensions,
              queryComplexity: complexity,
            };
          }
        } catch {
          // Complexity computation errors should never break the response.
          // Log and continue silently.
        }
      },
    };
  },
};
```

---

## 7. Testing Complexity Rules

Unit tests for complexity estimation catch regressions when resolver costs are changed and provide a reference for what different query shapes actually cost.

```typescript
// src/complexity/__tests__/complexity.test.ts
import { parse } from 'graphql';
import {
  getComplexity,
  fieldExtensionsEstimator,
  simpleEstimator,
} from 'graphql-query-complexity';
import { schema } from '../../schema';

function computeComplexity(query: string): number {
  return getComplexity({
    schema,
    query: parse(query),
    estimators: [
      fieldExtensionsEstimator(),
      simpleEstimator({ defaultComplexity: 1 }),
    ],
  });
}

describe('Query complexity estimator', () => {
  test('simple scalar lookup is cheap', () => {
    const complexity = computeComplexity(`
      query { product(id: "1") { id name price } }
    `);
    expect(complexity).toBe(4); // 1 (product) + 3 scalars at 1 each
  });

  test('paginated list scales with page size', () => {
    const small = computeComplexity(`
      query { products(first: 10) { id name } }
    `);
    const large = computeComplexity(`
      query { products(first: 100) { id name } }
    `);
    // large should be 10x the cost of small (same fields, 10x items)
    expect(large).toBeGreaterThan(small * 5);
  });

  test('nested relationships multiply costs', () => {
    const flat = computeComplexity(`
      query { products(first: 10) { id name } }
    `);
    const nested = computeComplexity(`
      query { products(first: 10) { id name reviews(first: 5) { id } } }
    `);
    expect(nested).toBeGreaterThan(flat);
  });

  test('AI recommendations field is expensive', () => {
    const withRecs = computeComplexity(`
      query { product(id: "1") { recommendations(first: 5) { id name } } }
    `);
    const withoutRecs = computeComplexity(`
      query { product(id: "1") { id name } }
    `);
    // Recommendations should add substantially to the cost
    expect(withRecs - withoutRecs).toBeGreaterThanOrEqual(15);
  });

  test('N+1 field has high penalty', () => {
    const complexity = computeComplexity(`
      query { products(first: 10) { inventoryStatus } }
    `);
    // 10 products * 10 (inventoryStatus cost) = 100 minimum
    expect(complexity).toBeGreaterThanOrEqual(100);
  });
});
```

### Reference Complexity Table

The following table shows expected complexity scores for representative queries. Use this as acceptance criteria when making schema changes.

| Query Description | Page Size | Expected Complexity | Notes |
|---|---|---|---|
| `product(id)` — id, name, price | N/A | ~4 | Cached by DataLoader |
| `products` — id, name only | first: 10 | ~22 | 2 + 10 * (id+name) |
| `products` — id, name only | first: 100 | ~202 | 10x the above |
| `products` with `category` | first: 20 | ~100 | Each category = cost 2 |
| `products` with `reviews` | first: 20, reviews first: 10 | ~400 | Nested list multiplication |
| `products` with `recommendations` | first: 10, recs first: 5 | ~750 | Near the warn threshold |
| Deeply nested (5 levels) | first: 10 at each level | >1000 | Should be rejected |

---

## Key Design Decisions

**Why `fieldExtensionsEstimator` before `simpleEstimator`:** The estimators array is evaluated in order; the first estimator to return a defined (non-undefined) value wins. By placing `fieldExtensionsEstimator` first, fields with explicit cost annotations use those values, and only fields without annotations fall through to the `simpleEstimator` default. This means unannotated scalar fields cheaply default to cost 1 without requiring explicit annotation on every field in the schema.

**Why separate warn and reject thresholds:** The warn threshold (500) gives the team visibility into queries that are trending toward the limit. Operations approaching the threshold get surfaced in monitoring without being rejected, giving client teams time to optimize before they hit the hard limit. A single reject-only threshold creates a binary situation where clients are surprised by rejections.

**Why the complexity header plugin is a separate concern from the validation rule:** The validation rule rejects queries that exceed the limit. The header plugin reports the complexity of every query that executes. If combined, a rejected query would not get a complexity header, which means clients whose queries are rejected cannot see their score to understand how far over the limit they are. Keeping them separate ensures the header is always returned.

**Why environment variables for thresholds:** `GRAPHQL_MAX_COMPLEXITY` and `GRAPHQL_WARN_COMPLEXITY` allow per-environment tuning without code changes. Development environments may use much higher limits to avoid interfering with development queries. Staging mirrors production limits. This is preferable to hardcoding values.

---

## Related Documentation

- `../../docs/06-performance-and-scaling/` — DataLoader patterns that reduce actual execution cost, directly affecting how complexity scores translate to real performance
- `../../docs/05-security/` — Threat model for GraphQL denial-of-service attacks and the full defense-in-depth strategy
- `../../docs/09-schema-governance/` — Schema review process where complexity costs should be evaluated for new fields
- `../../docs/14-observability/` — Setting up the metrics infrastructure to collect complexity histogram data from production
