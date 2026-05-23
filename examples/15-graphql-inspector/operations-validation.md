# Operations Validation with graphql-inspector

Companion doc: [Chapter 10 — Schema Validation](../../docs/10-schema-validation/README.md)

Using `graphql-inspector validate` to verify that every known client operation is compatible
with the current schema. This catches the cases that Rover check misses: you changed a field
that no subgraph owns but that clients reference directly, or you composed successfully but
a client operation now references a removed argument.

---

## What Validation Catches

| Problem | Example | Caught by |
|---------|---------|-----------|
| Field removed from schema | `product { weight }` after `weight` is dropped | `validate` |
| Argument type changed | `user(id: Int!)` after type changed to `ID!` | `validate` |
| Required argument added | `search(query: String!, locale: String!)` | `validate` |
| Deprecated field in active use | `@deprecated` field still queried | `validate --deprecated` |
| Wrong return type used | Fragment on `Product` applied to `Item` result | `validate` |
| Missing `__typename` for union | Union result without discriminator | `validate` |

---

## Installation

```bash
npm install --save-dev @graphql-inspector/cli

# Verify
npx graphql-inspector --version
```

---

## Basic Validation

Validate all operation documents in the repository against the current schema:

```bash
# Validate all .graphql files under src/ against the local schema
npx graphql-inspector validate \
  'src/**/*.graphql' \
  schema.graphql

# Validate against a running endpoint (introspects the live schema)
npx graphql-inspector validate \
  'src/**/*.graphql' \
  http://localhost:4000/graphql
```

### Example Output — Passing

```
  ✔  src/features/catalog/queries/GetProduct.graphql
  ✔  src/features/catalog/queries/ListProducts.graphql
  ✔  src/features/cart/mutations/AddToCart.graphql
  ✔  src/features/user/queries/GetCurrentUser.graphql

  Documents: 4 valid, 0 invalid
```

### Example Output — Failing

```
  ✔  src/features/catalog/queries/ListProducts.graphql
  ✖  src/features/catalog/queries/GetProduct.graphql

    [GetProduct] Field "weight" does not exist on type "Product".
    [GetProduct] Argument "currency" is not defined on field "Product.price".

  Documents: 1 valid, 1 invalid
```

---

## Finding All Operations in a Codebase

Not all operations live in `.graphql` files — many projects embed them in TypeScript with
`gql` template literals. Extract them before validating.

### From `.graphql` files (simplest case)

```bash
# Glob covers subpackages in a monorepo
npx graphql-inspector validate \
  '{apps,packages}/**/*.graphql' \
  schema.graphql
```

### From TypeScript with `gql` tag extraction

```bash
# Install the extractor
npm install --save-dev @graphql-tools/load @graphql-tools/graphql-tag-pluck

# Write a one-off extractor script
node - <<'EOF'
const { loadDocuments } = require('@graphql-tools/load');
const { GraphQLFileLoader } = require('@graphql-tools/graphql-file-loader');
const { CodeFileLoader } = require('@graphql-tools/code-file-loader');
const { print } = require('graphql');
const fs = require('fs');

async function main() {
  const documents = await loadDocuments(
    [
      'src/**/*.graphql',
      'src/**/*.ts',
      'src/**/*.tsx',
    ],
    {
      loaders: [new GraphQLFileLoader(), new CodeFileLoader()],
    }
  );

  // Write a combined operations file for graphql-inspector
  const combined = documents
    .map(doc => print(doc.document))
    .join('\n\n');

  fs.writeFileSync('all-operations.graphql', combined);
  console.log(`Extracted ${documents.length} operations`);
}

main().catch(console.error);
EOF

# Now validate the extracted file
npx graphql-inspector validate all-operations.graphql schema.graphql
```

---

## Validation in CI

Run on every schema change to catch regressions against known client operations. The schema
changes; the operations corpus stays fixed (the client codebase at HEAD).

```yaml
# .github/workflows/validate-operations.yml
name: Validate Operations

on:
  pull_request:
    paths:
      - 'subgraphs/**/schema.graphql'
      - 'schema/supergraph.yaml'

jobs:
  validate:
    name: Validate Client Operations Against New Schema
    runs-on: ubuntu-latest
    timeout-minutes: 10

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Compose supergraph schema
        run: |
          curl -sSL https://rover.apollo.dev/nix/v0.27.0 | sh
          echo "$HOME/.rover/bin" >> "$GITHUB_PATH"
          rover supergraph compose \
            --config schema/supergraph.yaml \
            --output supergraph-composed.graphql

      - name: Extract operations from source
        run: node scripts/extract-operations.js

      - name: Validate operations against composed schema
        id: validate
        run: |
          npx graphql-inspector validate \
            all-operations.graphql \
            supergraph-composed.graphql \
            --deprecated   # treat use of deprecated fields as errors

      - name: Post validation failure comment
        if: failure()
        uses: actions/github-script@v7
        with:
          script: |
            const marker = '<!-- operations-validation-result -->';
            const body = [
              marker,
              '## Operations Validation Failed',
              '',
              'One or more client operations are incompatible with the proposed schema change.',
              '',
              '**Next steps:**',
              '1. Check the workflow log for the full list of invalid operations.',
              '2. Identify which client(s) own the failing operations.',
              '3. Either update the client operations to use the new schema OR',
              '   revise the schema change to maintain compatibility.',
              '',
              '> Operations validation checks all known operations in the source tree against',
              '> the composed supergraph. This catches breakages that `rover subgraph check`',
              '> does not detect (fields used by clients but not tracked in the operation registry).',
            ].join('\n');

            const { data: comments } = await github.rest.issues.listComments({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
            });

            const existing = comments.find(c => c.body.includes(marker));
            if (existing) {
              await github.rest.issues.updateComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                comment_id: existing.id,
                body,
              });
            } else {
              await github.rest.issues.createComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                issue_number: context.issue.number,
                body,
              });
            }
```

---

## Schema Coverage

`graphql-inspector coverage` shows which schema fields are actually referenced by known
operations. Fields with 0 hits are unused by any known client — deprecation candidates.

```bash
npx graphql-inspector coverage \
  'src/**/*.graphql' \
  schema.graphql

# Output (truncated)
  type Query
    ✔  user          (12 operations)
    ✔  product       (8 operations)
    ✘  adminReport   (0 operations)   ← never used by any known operation

  type Product
    ✔  id            (20 operations)
    ✔  name          (20 operations)
    ✔  price         (15 operations)
    ✘  legacyCode    (0 operations)   ← dead field
    ✔  description   (6 operations)
```

---

## Similar Type Detection

Find types that look alike — a symptom of schema sprawl where the same concept was
added twice under different names.

```bash
npx graphql-inspector similar schema.graphql

# Example output
  ProductItem is similar to Product (85% match)
    Shared fields: id, name, price, description
    Only in ProductItem: stockCode
    Only in Product: sku, category

  UserProfile is similar to User (91% match)
    Shared fields: id, email, displayName, createdAt
    Only in UserProfile: bio
    Only in User: role, preferences
```

When similarity is above 70%, investigate whether the two types should be merged or if the
difference is intentional (different security scope, different subgraph ownership).

---

## Schema Audit

`graphql-inspector audit` runs a set of schema health checks in a single pass:

```bash
npx graphql-inspector audit schema.graphql

# Output
  Missing descriptions (errors):
    Type "LegacyPaymentMethod" — no description
    Field "Order.internalNote" — no description

  Deprecated fields still used by operations:
    Field "User.username" (@deprecated) — used in 3 operations

  Nullable ID fields (warnings):
    Field "Product.legacyId: String" — consider ID scalar
    Field "Order.externalRef: String" — consider ID scalar

  Audit summary: 2 errors, 4 warnings
```

---

## Combining with Rover

graphql-inspector `validate` and `rover subgraph check` address different failure modes —
run both in CI for complete coverage:

| Check | Tool | What it catches |
|-------|------|-----------------|
| Breaking changes vs. GraphOS operation registry | `rover subgraph check` | Operations tracked in Apollo Studio (production traffic) |
| Breaking changes vs. source operations | `graphql-inspector validate` | Operations in the codebase (including pre-production features) |
| Schema composition | `rover supergraph compose` | Federation directive conflicts |
| Schema lint | `graphql-eslint` | Naming, descriptions, conventions |
| Policy gate | `opa eval` | Governance rules |

Run all five checks on every PR. Each catches a distinct class of problem; none is redundant.

---

## Key Design Decisions

**Why validate against the source corpus rather than the Studio registry?** The Studio
registry only tracks operations that have run in production. Pre-production features — new
app screens, unreleased mobile app versions — are absent from the registry. The source
corpus catches those too.

**Why validate the composed supergraph, not individual subgraphs?** Clients query the
supergraph schema, not subgraph schemas. A field might exist in a subgraph but not be
exposed through the supergraph due to `@inaccessible` or composition errors. Validating
against the composed schema is the accurate check.

**Why treat deprecated field usage as errors in CI?** Deprecation without removal creates
permanent technical debt. Elevating it to a CI error creates pressure to complete migrations
within the 90-day window rather than deferring indefinitely.

---

## Related Documentation

- [Chapter 10 — Schema Validation](../../docs/10-schema-validation/README.md)
- [Chapter 09 — Schema Governance](../../docs/09-schema-governance/README.md)
- [Chapter 12 — GitHub Actions](../../docs/12-github-actions/README.md)
- [examples/04-github-actions](../04-github-actions/) — full CI workflow including schema check
- [examples/03-schema-validation](../03-schema-validation/) — graphql-eslint and Rover check setup
