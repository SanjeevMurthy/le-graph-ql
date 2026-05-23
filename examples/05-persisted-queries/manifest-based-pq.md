# Manifest-Based Persisted Queries — Build-Time Security for Production

> Companion docs: [../../docs/05-security/](../../docs/05-security/) and
> [../../docs/17-caching-strategies/](../../docs/17-caching-strategies/)

Manifest-based persisted queries are the production-grade approach for any API that is
customer-facing or operates under compliance requirements. The difference from APQ is
fundamental: instead of registering queries at runtime (which still accepts unknown queries
on first execution), the manifest approach registers all permitted operations during CI at
build time. The production router receives the manifest before any client traffic arrives
and rejects operations that were never in the manifest.

The result is a hard allowlist: only operations that existed in your codebase at the last
successful build can ever execute in production. Schema reconnaissance through introspection,
novel query injection, and unexpected batching attacks become structurally impossible.

---

## 1. Generating a PQ Manifest

The `@apollo/generate-persisted-query-manifest` package scans your client source code for
GraphQL operation definitions and produces a JSON manifest with a stable hash per operation.

### Install

```bash
# Add to client project devDependencies — this is a build-time tool only
npm install --save-dev @apollo/generate-persisted-query-manifest
```

### Configuration file

```javascript
// persisted-query-manifest.config.js (project root)
/** @type {import('@apollo/generate-persisted-query-manifest').PersistedQueryManifestConfig} */
module.exports = {
  // Documents: glob patterns pointing to every .graphql file or .ts/.tsx file
  // containing gql-tagged template literals in your project.
  // The generator extracts gql`...` and graphql`...` tagged templates as well
  // as standalone .graphql files.
  documents: [
    "src/**/*.{ts,tsx}",
    "src/**/*.graphql",
    // Exclude test files — test operations should not be registered in production.
    // Using a separate allowlist for test environments is safer than including them.
    "!src/**/*.test.{ts,tsx}",
    "!src/**/*.spec.{ts,tsx}",
  ],

  // output: path where the manifest JSON file will be written.
  // Commit this file to version control so you can diff it in PR reviews.
  // A manifest diff in a PR immediately shows reviewers which operations were
  // added, removed, or changed — before they reach production.
  output: "persisted-query-manifest.json",
};
```

### Generate the manifest

```bash
# Run as part of your build step, before bundling the client application
npx generate-persisted-query-manifest

# Output:
# Found 47 operations across 31 files
# Written to persisted-query-manifest.json
```

### What to do with the manifest file

```bash
# Always commit the manifest to version control
git add persisted-query-manifest.json
git commit -m "chore: regenerate persisted query manifest"

# If you see unexpected operations added or removed in the diff, investigate
# before merging. Operations disappear when components are deleted; they appear
# when new features are added. Both are expected on feature branches.
```

---

## 2. The Manifest Format

The manifest is a JSON file. Understanding its structure helps when debugging hash mismatches
or verifying that a specific operation is registered.

```json
{
  "format": "apollo-persisted-query-manifest",
  "version": 1,
  "operations": [
    {
      "id": "a9b0d89f3c2e1f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8",
      "name": "GetProduct",
      "type": "query",
      "body": "query GetProduct($id: ID!) {\n  product(id: $id) {\n    id\n    name\n    price\n    category {\n      id\n      name\n    }\n  }\n}"
    },
    {
      "id": "b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2",
      "name": "CreateOrder",
      "type": "mutation",
      "body": "mutation CreateOrder($input: CreateOrderInput!) {\n  createOrder(input: $input) {\n    id\n    status\n    total\n  }\n}"
    },
    {
      "id": "c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4",
      "name": "ProductUpdated",
      "type": "subscription",
      "body": "subscription ProductUpdated($productId: ID!) {\n  productUpdated(productId: $productId) {\n    id\n    price\n    stockCount\n  }\n}"
    }
  ]
}
```

Key fields:

| Field | Type | Description |
|---|---|---|
| `format` | string | Always `"apollo-persisted-query-manifest"` — router validates this |
| `version` | number | Always `1` — future schema evolution uses this field |
| `operations[].id` | string | SHA-256 of the normalized operation body — this is what clients send |
| `operations[].name` | string | Operation name — used for Studio reporting and error messages |
| `operations[].type` | string | `"query"`, `"mutation"`, or `"subscription"` |
| `operations[].body` | string | The normalized operation text — router executes this on cache hit |

---

## 3. Extracting Operations from Different Client Setups

### React / TypeScript with gql tagged templates

The manifest generator handles `gql` and `graphql` tagged templates natively. No
additional configuration is needed for standard Apollo Client or urql usage.

```typescript
// src/features/products/queries.ts
// The generator finds this automatically via the documents glob
import { gql } from "@apollo/client";

export const GET_PRODUCT = gql`
  query GetProduct($id: ID!) {
    product(id: $id) {
      id
      name
      price
    }
  }
`;
```

### Fragment collocation

If your project uses fragment collocation (fragments defined alongside components), the
generator must be able to resolve fragment references. Ensure fragments are included in
the documents glob and that the generator can statically analyze the spread.

```typescript
// ProductCard.tsx
export const PRODUCT_CARD_FRAGMENT = gql`
  fragment ProductCard on Product {
    id
    name
    imageUrl
  }
`;

// ProductList.tsx — references the fragment
export const GET_PRODUCT_LIST = gql`
  ${PRODUCT_CARD_FRAGMENT}
  query GetProductList {
    products {
      ...ProductCard
    }
  }
`;
```

### Standalone .graphql files (code-gen workflow)

If your project uses `graphql-codegen` and stores operations in `.graphql` files, the
manifest generator reads those files directly. The documents configuration in
`persisted-query-manifest.config.js` handles this:

```javascript
documents: [
  "src/**/*.graphql",
  // graphql-codegen generated files contain fragment and operation definitions
  // that you do NOT want to re-register as persisted queries — exclude them
  "!src/**/__generated__/**",
],
```

---

## 4. Publishing the Manifest to Apollo GraphOS

```bash
# Authenticate first (one-time setup — credentials cached in ~/.config/rover/)
rover auth login --profile production

# Publish the manifest to a specific graph variant.
# graph_ref format: <graph-id>@<variant>
# Example: acme-ecommerce@production
rover persisted-queries publish acme-ecommerce@production \
  --manifest persisted-query-manifest.json

# Output:
# Publishing 47 operations to acme-ecommerce@production...
# Successfully published persisted query manifest.
# Manifest ID: pq-manifest-20241215-abc123
# Operations registered: 47
# New: 3, Updated: 0, Unchanged: 44
```

### Integrating publication into CI/CD

```yaml
# .github/workflows/publish-pq-manifest.yml
name: Publish Persisted Query Manifest

on:
  push:
    branches: [main]
    paths:
      # Only run when client source or manifest config changes
      - "src/**"
      - "persisted-query-manifest.config.js"

jobs:
  publish-manifest:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: "npm"

      - name: Install dependencies
        run: npm ci

      - name: Generate manifest
        run: npx generate-persisted-query-manifest

      - name: Install Rover CLI
        run: |
          curl -sSL https://rover.apollo.dev/nix/latest | sh
          echo "$HOME/.rover/bin" >> $GITHUB_PATH

      - name: Publish manifest to GraphOS
        env:
          APOLLO_KEY: ${{ secrets.APOLLO_KEY }}
        run: |
          rover persisted-queries publish ${{ vars.APOLLO_GRAPH_REF }} \
            --manifest persisted-query-manifest.json

      - name: Commit updated manifest
        uses: stefanzweifel/git-auto-commit-action@v5
        with:
          commit_message: "chore: update persisted query manifest [skip ci]"
          file_pattern: persisted-query-manifest.json
```

---

## 5. Router Configuration to Enforce PQ-Only Mode

```yaml
# router.yaml

# persisted_queries block enables manifest enforcement.
# This is separate from the apq block (runtime cache).
# Both can coexist: APQ handles the warm cache, manifest handles enforcement.
persisted_queries:
  # Master switch for manifest-based PQ
  enabled: true

  safelist:
    # enabled: true means the router checks incoming hashes against the GraphOS manifest.
    # The router fetches the manifest from GraphOS uplink on startup and refreshes it
    # periodically (every 30s by default).
    enabled: true

    # require_id: true is the key lockdown setting.
    # When true, the router rejects ANY request that does not carry a hash matching
    # a registered operation. Requests with only a query body and no hash are rejected.
    # Requests with a hash that is not in the manifest are rejected.
    # This is the primary security control — without this flag, PQ is advisory only.
    require_id: true

# APQ cache still useful alongside manifest-based PQ:
# it caches the compiled query plan in memory, avoiding re-planning on every request.
apq:
  enabled: true
  router:
    cache:
      redis:
        urls:
          - "redis://${REDIS_HOST}:${REDIS_PORT}"
        ttl: 86400

# GraphOS connectivity — required for manifest sync
telemetry:
  apollo:
    key: "${APOLLO_KEY}"
    graph_ref: "${APOLLO_GRAPH_REF}"
```

---

## 6. Handling the Client Side: Sending Only the Hash

Once the manifest is published and the router is in `require_id: true` mode, clients must
send only the hash with no query body. Apollo Client and urql handle this automatically when
`enforcePersistedQueries: true` is configured (or when `createPersistedQueryLink` is used
with a custom `disable` function that never returns true).

### Apollo Client — enforce mode

```typescript
import { createPersistedQueryLink } from "@apollo/client/link/persisted-queries";
import { sha256 } from "crypto-hash";

const persistedQueryLink = createPersistedQueryLink({
  sha256,
  // disable: () => false means "never fall back to full query".
  // In manifest PQ mode the server always has the operation registered,
  // so PersistedQueryNotFound should never occur in production.
  // If it does, that is a bug (hash mismatch, client-server version skew)
  // that you want to surface as an error, not silently retry with full query.
  disable: () => false,
  useGETForHashedQueries: true,
});
```

### urql — enforce mode

```typescript
import { persistedExchange } from "@urql/exchange-persisted";

persistedExchange({
  preferGetForPersistedQueries: true,
  // enforcePersistedQueries: true disables the fallback retry.
  // Same reasoning as Apollo Client disable: () => false above.
  enforcePersistedQueries: true,
})
```

---

## 7. Freeform Operations Allowlist (Development / Staging)

In development you want to be able to run ad-hoc queries from GraphQL Playground, Apollo
Sandbox, or curl without regenerating the manifest. Use a separate router config per
environment.

```yaml
# router.staging.yaml — staging permits freeform queries for developer productivity
persisted_queries:
  enabled: true
  safelist:
    enabled: true
    # require_id: false in staging — unknown operations are allowed through.
    # The manifest is still checked; known hashes still resolve correctly.
    # This matches production behavior for registered operations while
    # permitting exploratory queries.
    require_id: false

# router.production.yaml — production enforces the manifest strictly
persisted_queries:
  enabled: true
  safelist:
    enabled: true
    require_id: true
```

### Environment-specific router startup

```bash
# Staging
router --config router.staging.yaml --supergraph supergraph.graphql

# Production
router --config router.production.yaml --supergraph supergraph.graphql
```

In Kubernetes, this is handled with ConfigMap per environment and a Helm values override.
See [../06-kubernetes/router-deployment.md](../06-kubernetes/router-deployment.md) for the
ConfigMap pattern.

---

## 8. Manifest Versioning Strategy

### The problem with flag-day upgrades

If you change the body of an existing operation (e.g., add a field to `GetProduct`), the
SHA-256 hash changes. Old clients that cached the old hash will send a hash the server no
longer recognizes. New clients send the new hash which the server accepts. The window between
the manifest being published and all clients being updated is a gap where old clients fail.

### Rolling upgrade strategy

```
Step 1: Operation changes are backward-compatible (add fields, not remove)
  - Principle: GraphQL schema evolution should be additive. Removing fields from an
    operation is a client breaking change regardless of PQ.
  - If you must change an operation body, add a new operation with a new name and
    deprecate the old one rather than modifying it in place.

Step 2: Publish a manifest that includes BOTH old and new operation versions
  - Old clients continue sending old hash -> still works
  - New clients send new hash -> also works
  - The manifest now has two entries for conceptually the same operation

Step 3: Deploy new client
  - New client sends new hash; old hash entries still in manifest for rollback safety

Step 4: After old clients are drained (no traffic to old hash for N days)
  - Remove old operation from manifest
  - Re-publish
  - Old hash is now rejected; since no client is sending it, no impact
```

### Using operation names as a versioning signal

```typescript
// Instead of modifying GetProduct, add GetProductV2 with the new fields.
// Both exist in the manifest simultaneously.
export const GET_PRODUCT_V2 = gql`
  query GetProductV2($id: ID!) {
    product(id: $id) {
      id
      name
      price
      # New field added in V2
      averageRating
      reviewCount
    }
  }
`;
```

### Monitoring manifest coverage

```bash
# Check which operations in the manifest have received zero traffic in the last 30 days
# (indicates they can be safely removed from the manifest)
rover persisted-queries list acme-ecommerce@production \
  --format json | jq '.operations[] | select(.lastUsed < "2024-11-15")'
```

---

## Key Design Decisions

**Why commit the manifest to version control?**
The manifest is the source of truth for what operations the production API accepts. Keeping
it in version control gives you a PR-reviewable audit trail: every time an operation is
added, changed, or removed, it appears as a diff. Security teams can mandate that manifest
changes require review from a designated approver group via CODEOWNERS.

**Why publish the manifest before deploying the client?**
The deployment order is: (1) publish manifest to GraphOS, (2) deploy new router config if
needed, (3) deploy new client build. If you deploy the client before publishing the manifest,
new operation hashes arrive at the router before the router knows about them, causing
PersistedQueryNotFound errors. Publishing first ensures the router is ready before clients
begin sending new hashes.

**Why use `rover persisted-queries publish` rather than a direct GraphOS API call?**
Rover handles manifest validation (format version, hash integrity), authentication via the
Apollo key, retry logic, and provides a stable CLI interface that does not change with
GraphOS API version updates. Calling the GraphOS Management API directly is possible but
requires maintaining your own client code against a versioned API.

**Why keep APQ enabled alongside manifest-based PQ?**
Even in manifest mode, the APQ in-memory/Redis cache still serves a valuable purpose: it
stores compiled query plans keyed by hash. Without APQ cache, the router re-plans every
request from the manifest body. With APQ cache, plans are retrieved in microseconds.
The manifest provides security (allowlisting); APQ cache provides performance (plan caching).
They complement rather than replace each other.

---

## Related Documentation

- [apq-setup.md](./apq-setup.md) — runtime APQ approach and Redis cache configuration
- [client-integration.md](./client-integration.md) — complete client setup for all stacks
- [Chapter 05 — Security](../../docs/05-security/README.md)
- [Chapter 17 — Caching Strategies](../../docs/17-caching-strategies/README.md)
- [examples/02-apollo-router](../02-apollo-router/) — full router.yaml reference
- [examples/04-github-actions](../04-github-actions/) — CI/CD integration patterns
