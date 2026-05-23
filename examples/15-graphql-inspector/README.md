# graphql-inspector — Schema Management Tooling — Example 15

Companion docs: `../../docs/10-schema-validation/`

---

## What graphql-inspector Does

`graphql-inspector` is a CLI and library for offline, local-first GraphQL schema management. It provides five main capabilities:

**diff** — Compare two schema versions and classify every change as BREAKING, DANGEROUS, or NON_BREAKING. Used in CI to catch schema changes that would break existing clients before they reach production.

**validate** — Check a set of operation documents (queries, mutations, subscriptions) against a schema. Identifies operations that use removed fields, wrong argument types, or deprecated fields. Catches "you broke a client you forgot about" before deployment.

**coverage** — Analyze which schema fields are actually referenced by a set of known operation documents. Fields with zero coverage are candidates for deprecation. High-coverage fields are priority targets for performance optimization and caching.

**similar** — Find types in the schema that look structurally similar to each other. Surfaces potential duplicates created by schema sprawl — the GraphQL equivalent of dead code from multiple teams independently modeling the same concept.

**audit** — Security and quality audit: fields without descriptions, nullable IDs (a common schema design mistake), deprecated fields still in use by known operations.

---

## When to Use graphql-inspector vs Rover check

These tools are complementary, not competing. Use them together.

| Capability | graphql-inspector | rover subgraph check |
|---|---|---|
| Schema diff | Yes — offline, local schemas | Yes — against GraphOS registry |
| Operation validation | Yes — against local operation files | Yes — against GraphOS operation registry |
| Coverage analysis | Yes — against local operation corpus | Yes — using Apollo Studio field usage data |
| Works offline | Yes | No — requires GraphOS connectivity |
| Integrates with GraphOS | No (standalone) | Yes — native integration |
| Breaking change classification | Yes | Yes |
| Operation registry integration | No | Yes — finds registered client operations |
| Custom diff rules | Yes — `--rule` flag | No |
| Pre-commit hook use | Yes — fast, no network | No — requires network |

**Rule of thumb:** Use `graphql-inspector` for local development feedback and custom offline workflows. Use `rover subgraph check` in CI for authoritative schema validation against the GraphOS registry and the full registered operation corpus.

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Node.js | >= 18 | Required for CLI execution |
| @graphql-inspector/cli | >= 4.0 | Main CLI package |

```bash
# Install globally for CLI use
npm install -g @graphql-inspector/cli

# Or install as a dev dependency (recommended for CI consistency)
npm install --save-dev @graphql-inspector/cli
```

---

## Files in This Example

| File | Description |
|---|---|
| `README.md` | This file. Overview of graphql-inspector capabilities, when to use inspector vs Rover, prerequisites, and quick start. |
| `schema-diff-workflows.md` | Using `graphql-inspector diff` in development and CI: change classification taxonomy, custom rules, diffing against live endpoints, GitHub Actions integration, pre-commit hooks, and JSON output for programmatic use. |
| `operations-validation.md` | Using `graphql-inspector validate` and `coverage` to check all client operations against the schema: what validation catches, finding operations across a codebase, CI integration, coverage reports, `similar` for deduplication, and `audit` for security and quality checks. |
| `schema-coverage-analysis.md` | Deep dive into schema coverage analysis: correlating schema fields with operation usage to find dead fields, generating coverage from Apollo Studio and from local operations, CI coverage thresholds, dead field deprecation workflow, hot field identification, and a complete Node.js reporting script. |

---

## Quick Start

```bash
# 1. Compare two schema files (diff)
graphql-inspector diff old-schema.graphql new-schema.graphql

# 2. Diff the local schema against a live GraphQL endpoint
graphql-inspector diff http://localhost:4000/graphql new-schema.graphql

# 3. Validate all operations in the src/ directory against the schema
graphql-inspector validate 'src/**/*.graphql' schema.graphql

# 4. Generate a coverage report
graphql-inspector coverage 'src/**/*.graphql' schema.graphql

# 5. Find similar types
graphql-inspector similar schema.graphql
```

---

## Related Documentation

- `../../docs/10-schema-validation/` — Full schema validation pipeline documentation including Rover check integration, OPA policies, and custom lint rules
- `../../docs/09-schema-governance/` — Schema governance processes where diff outputs feed the RFC approval workflow
- `../../docs/11-ci-cd-automation/` — CI/CD pipeline integration patterns for schema checking tools
- `../../docs/05-security/` — Security audit workflows that complement the `graphql-inspector audit` capability
