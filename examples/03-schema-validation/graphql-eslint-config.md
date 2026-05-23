# GraphQL ESLint Configuration

> Companion documentation: `../../docs/10-schema-validation/`
> Related example: `rover-schema-check.md` (registry-level checks that complement these lint rules)

This document covers the complete ESLint + graphql-eslint setup for linting GraphQL SDL files.
The configuration targets three goals:

1. Consistent naming across all subgraph schemas so client developers have a predictable API.
2. Mandatory descriptions on all public types and fields so generated API docs are complete.
3. Structural patterns (Relay pagination, non-null mutations) that prevent whole classes of
   client-side bugs.

---

## Installation

```bash
# graphql-eslint v3 requires eslint v8 and graphql v16
npm install --save-dev \
  eslint@8 \
  @graphql-eslint/eslint-plugin@3 \
  graphql@16
```

Do not install `graphql-eslint` directly — the package has been renamed to
`@graphql-eslint/eslint-plugin`. The old package name is a stub that prints a deprecation
warning.

---

## Project Layout Assumed by This Config

```
project-root/
  subgraphs/
    users/
      schema.graphql
    products/
      schema.graphql
    orders/
      schema.graphql
  .graphqlrc.yml          <-- tells graphql-eslint which schema files to load
  .eslintrc.js            <-- ESLint rule configuration
  .eslintignore           <-- files to skip
  generated/              <-- auto-generated files, excluded from lint
```

---

## .graphqlrc.yml

The `.graphqlrc.yml` file is read by graphql-eslint to build the in-memory schema that rules
operate on. It is also read by IDE plugins (GraphQL Language Feature Support for VS Code).

```yaml
# .graphqlrc.yml
#
# This file configures the GraphQL Language Service and graphql-eslint.
# It tells both tools where to find schema files and where to find
# operation documents (queries, mutations, subscriptions).

projects:
  # ---- Subgraph: users -------------------------------------------------------
  # Each subgraph is its own project so it can have its own schema entry point.
  # graphql-eslint will validate each project independently, which means
  # cross-subgraph type references will intentionally show as "unknown type"
  # — that is expected in federated schemas.
  users:
    schema:
      # Primary SDL file for the users subgraph.
      # Add additional files here if the schema is split across multiple files.
      - "subgraphs/users/schema.graphql"
    documents:
      # If this subgraph has co-located operation documents (e.g., for testing),
      # include them here. This enables operation-level rules.
      - "subgraphs/users/**/*.graphql"
      - "!subgraphs/users/schema.graphql"  # exclude the schema itself
    extensions:
      # Tell graphql-eslint to load the ESLint plugin for this project.
      # Without this, only the schema rules in .eslintrc.js will apply.
      codegen:
        generates:
          generated/users-types.ts:
            plugins:
              - typescript

  products:
    schema:
      - "subgraphs/products/schema.graphql"
    documents:
      - "subgraphs/products/**/*.graphql"
      - "!subgraphs/products/schema.graphql"

  orders:
    schema:
      - "subgraphs/orders/schema.graphql"
    documents:
      - "subgraphs/orders/**/*.graphql"
      - "!subgraphs/orders/schema.graphql"
```

---

## .eslintrc.js

The ESLint config is split into two override blocks:

- **Schema files** (`*.graphql` files that are SDL) — apply SDL-specific rules.
- **Operation documents** (`*.graphql` files that are queries/mutations) — apply operation rules.

ESLint cannot distinguish SDL from operations by extension alone, so we use the `documents`
and `schema` keys from `.graphqlrc.yml` to create two logical sets.

```js
// .eslintrc.js
'use strict';

module.exports = {
  // Root config — applies to all files including JS/TS.
  // GraphQL-specific rules are scoped to overrides below.
  root: true,

  overrides: [
    // =========================================================================
    // BLOCK 1: GraphQL Schema Definition Language (SDL) files
    // These are the source-of-truth schema files in subgraphs/*/schema.graphql.
    // Rules here enforce style, documentation, and structural conventions.
    // =========================================================================
    {
      files: ['subgraphs/**/schema.graphql'],
      parser: '@graphql-eslint/eslint-plugin',
      plugins: ['@graphql-eslint'],
      rules: {
        // -----------------------------------------------------------------
        // NAMING CONVENTIONS
        // Consistent naming makes the API self-documenting and avoids
        // surprises for client developers coming from any language.
        // -----------------------------------------------------------------
        '@graphql-eslint/naming-convention': [
          'error',
          {
            // GraphQL types (Object, Interface, Union, Enum, Scalar, Input)
            // must use PascalCase. This matches the convention in every major
            // GraphQL spec example and all reference implementations.
            types: 'PascalCase',

            // Field names must use camelCase. This maps naturally to
            // JavaScript/TypeScript property access without transformation.
            FieldDefinition: 'camelCase',

            // Input field names follow the same rule as regular fields.
            InputValueDefinition: 'camelCase',

            // Enum values are SCREAMING_SNAKE_CASE. This signals that they are
            // constants, not data, and prevents collision with field names.
            EnumValueDefinition: 'UPPER_CASE',

            // Directive names use camelCase. This is the convention used by
            // the federation spec (@key, @external, @shareable, etc.).
            DirectiveDefinition: 'camelCase',

            // Fragments in co-located operation files use PascalCase + suffix.
            // e.g., UserFragment, ProductDetailsFragment
            FragmentDefinition: { style: 'PascalCase', suffix: 'Fragment' },
          },
        ],

        // -----------------------------------------------------------------
        // REQUIRED DESCRIPTIONS
        // Every public type and field must have a docstring description.
        // This is the single biggest driver of API documentation quality.
        // Descriptions appear in Studio's schema explorer and in generated
        // client SDKs (Apollo Kotlin, Apollo iOS, Apollo Client React).
        // -----------------------------------------------------------------
        '@graphql-eslint/require-description': [
          'error',
          {
            // Object types must be described. "What does this type represent?"
            types: true,

            // Every field on an object or interface must be described.
            // This is often the hardest rule to maintain but the most
            // valuable for client developers.
            FieldDefinition: true,

            // Input object fields must be described so form-building clients
            // (e.g., GraphiQL Explorer, Postman) can show helpful tooltips.
            InputValueDefinition: true,

            // Enum values must be described because their meaning is often
            // domain-specific and not obvious from the name alone.
            EnumValueDefinition: true,

            // Directives must be described because they appear in the
            // introspection schema and in generated code.
            DirectiveDefinition: true,

            // Interface definitions must be described.
            interfaces: true,

            // Union definitions must be described.
            unions: true,

            // Enum type definitions (not values) must also be described.
            // This is in addition to EnumValueDefinition above.
            enumValues: true,

            // Input object type definitions must be described.
            // This describes the overall purpose of the input, not just its fields.
            inputObjectTypes: true,
          },
        ],

        // -----------------------------------------------------------------
        // DEPRECATION POLICY
        // @deprecated fields must always include a reason string explaining
        // what to use instead. A bare @deprecated with no reason is useless
        // to client developers and is blocked.
        // -----------------------------------------------------------------
        '@graphql-eslint/require-deprecation-reason': 'error',

        // -----------------------------------------------------------------
        // NO DEPRECATED USAGE (warn)
        // Fields marked @deprecated should not be referenced by other fields
        // in the schema itself (e.g., a resolver should not call a deprecated
        // helper type). Set to warn so we can audit existing violations without
        // hard-blocking CI while cleaning up.
        // Upgrade to 'error' once existing deprecated fields are removed.
        // -----------------------------------------------------------------
        '@graphql-eslint/no-deprecated': 'warn',

        // -----------------------------------------------------------------
        // UNIQUE TYPE NAMES
        // No two types in the same schema file can share a name. Federation
        // allows type merging across subgraphs, but within a single subgraph
        // SDL this must be strictly unique. Catches copy-paste errors.
        // -----------------------------------------------------------------
        '@graphql-eslint/unique-type-names': 'error',

        // -----------------------------------------------------------------
        // INPUT TYPE NAME SUFFIX
        // All Input Object Types must end with "Input" (e.g., CreateUserInput,
        // UpdateOrderStatusInput). This makes it immediately clear in a query
        // or mutation signature which arguments are complex input objects.
        // Without this rule, "CreateUser" could refer to either a type or
        // an input, causing confusion.
        // -----------------------------------------------------------------
        '@graphql-eslint/input-name': [
          'error',
          {
            // Require the "Input" suffix on all Input Object Type definitions.
            checkInputType: true,

            // The expected suffix string.
            // Change to "Args" if your team prefers that convention, but pick one
            // and enforce it consistently.
            caseSensitiveInputType: true,
          },
        ],

        // -----------------------------------------------------------------
        // RELAY EDGE / CONNECTION PATTERN
        // Enforce the Relay Connection spec for paginated fields.
        // This is a hard requirement for clients using Apollo Client's
        // built-in pagination helpers (fetchMore, relayStylePagination).
        // Without enforcement, teams create bespoke pagination shapes that
        // cannot be handled by the standard InMemoryCache field policies.
        //
        // The spec requires:
        //   - A "Connection" type with `edges: [XEdge]` and `pageInfo: PageInfo`
        //   - An "Edge" type with `node: X` and `cursor: String!`
        //   - PageInfo with hasNextPage, hasPreviousPage, startCursor, endCursor
        // -----------------------------------------------------------------
        '@graphql-eslint/relay-edge-types': [
          'error',
          {
            // Require that Connection types have the "Connection" suffix.
            withEdgeSuffix: true,

            // Require that Edge types have the "Edge" suffix.
            shouldImplementNode: false, // Don't require Node interface on edge targets.
                                        // Teams without global node IDs can set false.

            // The cursor field on Edge types must be non-null.
            // A nullable cursor breaks cursor-based pagination logic.
            listTypeCanWrapOnlyEdgeType: true,
          },
        ],

        // -----------------------------------------------------------------
        // MUTATIONS MUST RETURN NON-NULL RESULTS
        // Mutation fields should never return null on success. A nullable
        // mutation return type means clients cannot distinguish "the mutation
        // succeeded but returned nothing" from "the mutation failed". Use a
        // dedicated payload type with a non-null userErrors field instead.
        //
        // Correct pattern:
        //   createUser(input: CreateUserInput!): CreateUserPayload!
        //
        // Where CreateUserPayload is:
        //   type CreateUserPayload {
        //     user: User          # nullable: null when mutation had errors
        //     userErrors: [UserError!]!  # non-null, empty on success
        //   }
        // -----------------------------------------------------------------
        '@graphql-eslint/require-nullable-result-in-mutation': 'error',

        // -----------------------------------------------------------------
        // ALPHABETIZE (optional consistency rule)
        // Alphabetizing fields and type definitions reduces diff noise in
        // code review — a field added in the middle of a non-alphabetized
        // list causes all subsequent lines to shift. With alphabetical order,
        // a new field is always an addition, never a modification.
        //
        // This rule is set to warn rather than error because alphabetizing
        // existing schemas is a large refactor best done deliberately,
        // not enforced incrementally on each PR.
        // -----------------------------------------------------------------
        '@graphql-eslint/alphabetize': [
          'warn',
          {
            // Require type fields to be alphabetized.
            fields: ['ObjectTypeDefinition', 'InterfaceTypeDefinition', 'InputObjectTypeDefinition'],

            // Require enum values to be alphabetized.
            values: true,

            // Require type definitions within the document to be alphabetized.
            // This keeps the schema file easy to navigate without Ctrl+F.
            definitions: true,

            // Require arguments to be alphabetized.
            // Note: this can conflict with semantic ordering (e.g., putting
            // "id" first). Disable if your team prefers semantic argument order.
            arguments: ['FieldDefinition', 'DirectiveDefinition'],
          },
        ],
      },
    },

    // =========================================================================
    // BLOCK 2: GraphQL Operation Documents (queries, mutations, subscriptions)
    // These rules apply to .graphql files that contain operations, not SDL.
    // This block is primarily relevant if operation documents live in the repo
    // alongside the schema (e.g., integration tests, persisted queries).
    // =========================================================================
    {
      files: ['subgraphs/**/operations/**/*.graphql', 'tests/**/*.graphql'],
      parser: '@graphql-eslint/eslint-plugin',
      plugins: ['@graphql-eslint'],
      rules: {
        // Operations must always be named. Anonymous operations (e.g., query { ... })
        // are not allowed because they cannot be persisted, tracked in APM, or
        // correlated with errors. A name like "GetUserProfile" makes tracing trivial.
        '@graphql-eslint/no-anonymous-operations': 'error',

        // Operation names must be unique within the document set.
        // Duplicate names cause non-deterministic behavior in persisted query stores.
        '@graphql-eslint/unique-operation-name': 'error',

        // Fragments must be used. Unused fragments are dead code that increase
        // document parse time and confuse developers.
        '@graphql-eslint/no-unused-fragments': 'error',

        // Fields must be selected when they are available.
        // This prevents over-fetching suppressors — if you select a type,
        // you should select its fields, not rely on the server to send everything.
        '@graphql-eslint/selection-set-depth': [
          'warn',
          {
            // Warn if a selection set is deeper than 6 levels. Deep queries
            // are a performance and complexity risk. Review and flatten if possible.
            maxDepth: 6,
          },
        ],
      },
    },
  ],
};
```

---

## .eslintignore

```
# .eslintignore
#
# Files that should never be linted. These are either generated by tooling
# (and would generate spurious errors) or are third-party schemas that
# we do not own.

# Code generation output — linting generated files is pointless and slow.
generated/

# Introspection schema JSON/SDL exported from a running server.
# These files are generated by `rover subgraph introspect` and should
# not be edited or linted.
introspection/
*.introspection.json
*.introspection.graphql

# node_modules is excluded by default in ESLint 8, but listed here
# for clarity in case tooling configuration changes.
node_modules/

# Vendor or pinned copies of third-party schemas (Apollo Federation spec, etc.)
vendor/
```

---

## VS Code Integration

Install the "GraphQL: Language Feature Support" extension (ID: `GraphQL.vscode-graphql`)
and the "ESLint" extension (ID: `dbaeumer.vscode-eslint`).

Add the following to `.vscode/settings.json` in the repository root:

```json
{
  // Tell the GraphQL extension where to find the .graphqlrc.yml config.
  // Without this, the extension falls back to file-system discovery which
  // can be slow in large monorepos.
  "graphql-config.filepath": "${workspaceFolder}/.graphqlrc.yml",

  // Enable ESLint validation for GraphQL files.
  // By default ESLint only runs on JS/TS files in VS Code.
  "eslint.validate": [
    "javascript",
    "javascriptreact",
    "typescript",
    "typescriptreact",
    "graphql"   // <-- this enables real-time GraphQL lint feedback
  ],

  // Show ESLint errors inline in the editor, not just in the Problems panel.
  "editor.codeActionsOnSave": {
    "source.fixAll.eslint": true  // auto-fix fixable rules on save
  },

  // Associate .graphql files with the GraphQL language mode so syntax
  // highlighting and hover-to-schema work correctly.
  "files.associations": {
    "*.graphql": "graphql",
    "*.gql": "graphql"
  }
}
```

---

## Running the Linter

```bash
# Lint all GraphQL schema files and print results to stdout.
npx eslint --ext .graphql subgraphs/

# Lint with JSON output (for CI parsers that need structured results).
npx eslint --ext .graphql --format json subgraphs/ > eslint-results.json

# Lint only changed files (useful in large monorepos).
# $CHANGED_FILES is set by the CI workflow using `git diff --name-only`.
npx eslint --ext .graphql $CHANGED_FILES

# Auto-fix all fixable violations (e.g., alphabetize rule auto-sorts fields).
# Review the diff before committing — auto-fix modifies your schema files.
npx eslint --ext .graphql --fix subgraphs/
```

---

## Integrating graphql-inspector for Diff-Based Linting

graphql-eslint alone cannot detect breaking changes — it only sees one version of a file at a
time. To catch changes like "removed a required field" or "changed a type from non-null to
null", combine it with graphql-inspector as a second lint pass:

```bash
# Step 1: Export the baseline schema from the main branch.
git show origin/main:subgraphs/users/schema.graphql > /tmp/users-schema-baseline.graphql

# Step 2: Run graphql-eslint on the new schema file (style + structure).
npx eslint --ext .graphql subgraphs/users/schema.graphql

# Step 3: Run graphql-inspector diff against the baseline (breaking changes).
npx graphql-inspector diff \
  /tmp/users-schema-baseline.graphql \
  subgraphs/users/schema.graphql

# If both pass, the schema change is safe to review.
```

This two-pass approach is what the CI workflow in `../../examples/04-github-actions/` runs
on every pull request.

---

## Common Lint Failures and Fixes

| Rule | Typical Failure | Fix |
|------|----------------|-----|
| `naming-convention` | `type user_profile` | Rename to `UserProfile` |
| `naming-convention` | `field UserName` | Rename to `userName` |
| `naming-convention` | `enum Status { active }` | Rename to `ACTIVE` |
| `require-description` | `type User { id: ID! }` | Add `"""..."""` docstring above the type and each field |
| `require-deprecation-reason` | `oldField: String @deprecated` | Add `reason` arg: `@deprecated(reason: "Use newField instead")` |
| `input-name` | `input CreateUser { ... }` | Rename to `CreateUserInput` |
| `relay-edge-types` | `type UserConnection { users: [User!]! }` | Restructure to `edges: [UserEdge]` + `pageInfo: PageInfo!` |
| `require-nullable-result-in-mutation` | `createUser: User!` | Return a payload type: `createUser: CreateUserPayload!` |

---

## Key Design Decisions

**Why `require-description` is an error, not a warning.** Warnings are ignored over time.
Once the rule is a warning, it accumulates hundreds of violations that become technical debt.
By making it an error from day one, every new type and field is documented at the time it is
written — when the author best understands its purpose.

**Why `no-deprecated` is a warning, not an error.** Existing schemas often have many
deprecated fields that are still referenced internally (e.g., in resolver delegation or
utility types). Enforcing this as an error on an existing schema would require a large
refactor before any other work can proceed. Use the warning to build an audit list, then
migrate systematically.

**Why `alphabetize` is a warning, not an error.** Alphabetizing an existing schema
is a pure rename diff that makes it harder to review the substantive changes on the same PR.
The warning encourages new types to be alphabetized from the start without blocking work
on existing schemas.

**Why separate ESLint overrides for SDL vs operations.** The graphql-eslint plugin has
distinct rule sets for SDL (schema definition) files and operation (query) files. Applying
SDL rules to operations (or vice versa) produces parser errors. The two override blocks
in `.eslintrc.js` ensure each rule set is applied only to the correct file class.

---

## Related Documentation

- `../../docs/10-schema-validation/` — Validation pipeline design rationale
- `../../docs/12-schema-evolution/` — Deprecation policy and field lifecycle
- `rover-schema-check.md` — Registry-based breaking change detection (run after this lint step)
- `graphql-inspector-diff.md` — Offline diff tool for pre-commit and local development
- `../../examples/04-github-actions/schema-check-workflow.md` — CI workflow that orchestrates all validation steps
