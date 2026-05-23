# Schema Validation Example

> Companion documentation: `../../docs/10-schema-validation/`

This example set demonstrates a production-grade GraphQL schema validation pipeline that
catches breaking changes, enforces style conventions, and gates promotion before any schema
reaches a live router. The pipeline is designed to be layered: each tool operates at a
different scope and catches a different class of problem.

---

## What This Example Demonstrates

| File | Purpose |
|------|---------|
| `graphql-eslint-config.md` | Static lint rules enforced at the file level — naming conventions, required descriptions, Relay pagination patterns. Runs in IDE and in CI on every changed `.graphql` file. |
| `rover-schema-check.md` | Apollo Rover CLI integration for checking subgraph schemas against the GraphOS schema registry. The authoritative breaking-change detector because it knows your real operation traffic. |
| `graphql-inspector-diff.md` | Offline, registry-independent diff tool for local development and PR reviews. Complements Rover when GraphOS is unavailable or for monorepo pre-commit gates. |

The three tools are complementary, not redundant:

- `graphql-eslint` enforces *style* and *documentation completeness*. It knows nothing about
  clients or traffic — it only reads the SDL.
- `graphql-inspector` enforces *structural correctness* and *compatibility* against a baseline
  SDL. It is deterministic and works offline; a good fit for pre-commit and local development.
- `rover subgraph check` enforces *operational safety* by correlating the structural diff
  against real operation usage from Apollo Studio. Only Rover knows whether a removed field
  is actually queried by a production client.

---

## Schema Validation Pipeline

The following diagram shows the flow of a pull request through the full validation pipeline.
Each stage is a required status check; a failure at any stage blocks merging.

```
Pull Request opened / updated
         |
         v
+------------------+
|  graphql-eslint  |   <-- runs first: fast, no network, catches 90% of style issues
|  (lint)          |       fails immediately on naming violations, missing descriptions
+--------+---------+
         |
         | pass
         v
+------------------+
|  graphql-        |   <-- diff-based check against main branch baseline SDL
|  inspector diff  |       catches structural breaks without requiring GraphOS credentials
+--------+---------+
         |
         | no breaking changes (or all acknowledged)
         v
+------------------+
|  rover subgraph  |   <-- checks against GraphOS registry, correlates with real traffic
|  check           |       BREAKING = hard fail, DANGEROUS = warn, NON_BREAKING = info
+--------+---------+
         |
         | check passes (no unacknowledged breaking changes)
         v
+------------------+
|  supergraph      |   <-- composes the full supergraph locally to verify federation
|  compose (local) |       catches cross-subgraph type conflicts before publish
+--------+---------+
         |
         | composition succeeds
         v
+------------------+
| PR gate: PASSED  |   <-- all checks green; merge is unblocked
+------------------+
```

---

## Prerequisites

| Dependency | Minimum Version | Install Command | Notes |
|------------|----------------|-----------------|-------|
| Node.js | 18.x | `nvm install 18` | Required for graphql-eslint and inspector |
| npm | 9.x | Bundled with Node 18 | |
| Rover CLI | 0.24.0 | `curl -sSL https://rover.apollo.dev/nix/latest \| sh` | Handles GraphOS registry auth |
| `@graphql-eslint/eslint-plugin` | 3.20.x | `npm install --save-dev @graphql-eslint/eslint-plugin` | Schema lint rules |
| `eslint` | 8.x | `npm install --save-dev eslint` | Required peer dep |
| `@graphql-inspector/cli` | 5.x | `npm install --save-dev @graphql-inspector/cli` | Offline diff and validate |
| `graphql` | 16.x | `npm install graphql` | Required peer dep for all tools |
| Apollo GraphOS account | n/a | https://studio.apollographql.com | Required for rover subgraph check |

---

## Quick Start

Run the full local validation pipeline against the `users` subgraph:

```bash
# 1. Install dependencies
npm install

# 2. Lint all GraphQL schema files
npx eslint --ext .graphql subgraphs/

# 3. Diff the current schema against the main branch baseline
npx graphql-inspector diff \
  <(git show origin/main:subgraphs/users/schema.graphql) \
  subgraphs/users/schema.graphql

# 4. Check against GraphOS registry (requires APOLLO_KEY env var)
rover subgraph check my-graph@main \
  --name users \
  --schema subgraphs/users/schema.graphql
```

To compose the full supergraph locally and verify federation compatibility:

```bash
rover supergraph compose --config supergraph.yaml
```

---

## File Navigation

| File | When to Read It |
|------|----------------|
| `graphql-eslint-config.md` | Setting up lint rules for the first time; understanding why a lint rule fired; configuring IDE integration |
| `rover-schema-check.md` | Integrating rover into CI; debugging a breaking change report from GraphOS; running async checks for large schemas |
| `graphql-inspector-diff.md` | Setting up pre-commit hooks; running offline diff in restricted environments; writing custom breaking-change rules |

---

## Environment Variables

| Variable | Required By | Description |
|----------|-------------|-------------|
| `APOLLO_KEY` | Rover | API key from Apollo Studio. Format: `service:graph-name:hash`. Store in CI secrets, never commit. |
| `APOLLO_GRAPH_REF` | Rover | Graph ref in `graph-name@variant` format. Override per-environment. |
| `GRAPHQL_INSPECTOR_SCHEMA` | graphql-inspector | Optional: path to baseline schema for `validate` command |

---

## Related Documentation

- `../../docs/10-schema-validation/` — Full theory and design rationale for the validation pipeline
- `../../docs/11-schema-registry/` — Apollo GraphOS schema registry concepts
- `../../docs/12-schema-evolution/` — Safe schema evolution patterns and deprecation policy
- `../../docs/13-federation-composition/` — Federation composition rules that underpin the compose gate
- `../../examples/04-github-actions/schema-check-workflow.md` — CI workflow that orchestrates all three tools
