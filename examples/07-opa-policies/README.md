# OPA Policies for GraphQL Schema Governance

Companion documentation: `../../docs/13-policy-as-code/` and `../../docs/09-schema-governance/`

This example demonstrates using Open Policy Agent (OPA) to enforce schema governance rules
as code — testable, versionable, and executable in CI pipelines. Policies run against a
schema diff input document before any pull request is merged, giving teams fast, automated
feedback about breaking changes and style violations.

---

## Why OPA for GraphQL Schema Governance

GraphQL schema governance is a coordination problem. Multiple teams publish subgraph
schemas to a federated supergraph. Without automated enforcement, the following issues
emerge over time:

- Types lose descriptions, making schema introspection useless for consumers
- Fields silently become nullable, breaking clients that rely on non-null guarantees
- Types are removed without a deprecation window, causing runtime failures
- Mutations accumulate ad-hoc argument signatures instead of following input-type conventions
- Queries return raw lists instead of paginated connections, blocking future pagination rollout

OPA Rego policies address these with:

- **Policy as code** — rules live in version control alongside the schema, subject to the
  same review process
- **Testability** — every policy ships with OPA unit tests (`opa test`)
- **Portability** — policies can run in CI via `opa eval`, via `conftest`, or embedded in a
  custom schema registry
- **Auditability** — policy evaluations produce structured JSON output that can be stored
  as CI artifacts

---

## Architecture

The following diagram describes how schema governance policies integrate into the pull
request lifecycle:

```
Pull Request (SDL change)
        |
        v
  GitHub Actions
        |
        |-- graphql-inspector (generate schema diff JSON)
        |         |
        |         v
        |    schema-diff.json
        |         |
        v         v
  opa eval -d policies/ -i schema-diff.json 'data.graphql.schema.deny'
        |
        +-- violations? --> Post PR comment with violation list --> Block merge
        |
        +-- no violations? --> Policy check passes --> Allow merge
        |
        v
  opa eval -d policies/ -i schema-diff.json 'data.graphql.schema.warn'
        |
        +-- warnings? --> Post PR comment as advisory (non-blocking)
```

The CI step consumes a single `schema-diff.json` document. This document captures both
the previous schema state (types, fields, directives) and the proposed new schema state.
See `conftest-integration.md` for the exact input format and how to generate it.

---

## File Navigation

| File | Purpose |
|---|---|
| `README.md` | This file. Architecture, prerequisites, quick start. |
| `schema-governance-policies.rego` | Production OPA Rego policies for schema governance. |
| `policy-tests.rego` | OPA unit tests for each policy rule. |
| `conftest-integration.md` | Using conftest as an alternative runner, CI integration, bundle publishing. |

---

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| OPA CLI | >= 0.57.0 | Evaluate policies, run tests |
| Rego | Built into OPA | Policy language |
| conftest | >= 0.47.0 | CI-friendly wrapper around OPA |
| graphql-inspector | >= 5.0.0 | Generate schema diff JSON from two SDL files |
| jq | >= 1.6 | Transform schema diff output into OPA input shape |

Install OPA:

```bash
# macOS
brew install opa

# Linux (amd64)
curl -L -o opa https://openpolicyagent.org/downloads/latest/opa_linux_amd64_static
chmod +x opa
sudo mv opa /usr/local/bin/
```

Install conftest:

```bash
# macOS
brew install conftest

# Linux
curl -L -o conftest.tar.gz \
  https://github.com/open-policy-agent/conftest/releases/latest/download/conftest_Linux_x86_64.tar.gz
tar -xzf conftest.tar.gz
sudo mv conftest /usr/local/bin/
```

Verify versions:

```bash
opa version
conftest --version
```

---

## Input Document Shape

OPA policies in this directory expect the following `schema-diff.json` shape as input.
This document represents a single schema change event:

```json
{
  "old_schema": {
    "types": [
      {
        "name": "User",
        "kind": "OBJECT",
        "description": "A platform user account.",
        "fields": [
          {
            "name": "id",
            "description": "The unique identifier.",
            "type": { "kind": "NON_NULL", "ofType": { "name": "ID" } },
            "directives": []
          }
        ],
        "directives": []
      }
    ]
  },
  "new_schema": {
    "types": [
      {
        "name": "User",
        "kind": "OBJECT",
        "description": "A platform user account.",
        "fields": [
          {
            "name": "id",
            "description": "The unique identifier.",
            "type": { "kind": "NON_NULL", "ofType": { "name": "ID" } },
            "directives": []
          }
        ],
        "directives": []
      }
    ]
  },
  "labels": [],
  "approved_removals": []
}
```

The `labels` array holds PR labels (e.g., `"breaking-change-approved"`) that can unlock
otherwise-denied operations. The `approved_removals` array lists type names explicitly
approved for removal in this PR.

---

## Quick Start

**Run all deny rules and print violations:**

```bash
opa eval \
  -d examples/07-opa-policies/schema-governance-policies.rego \
  -i schema-diff.json \
  'data.graphql.schema.deny'
```

**Run all warn rules and print advisories:**

```bash
opa eval \
  -d examples/07-opa-policies/schema-governance-policies.rego \
  -i schema-diff.json \
  'data.graphql.schema.warn'
```

**Run the policy unit test suite:**

```bash
opa test \
  examples/07-opa-policies/schema-governance-policies.rego \
  examples/07-opa-policies/policy-tests.rego \
  -v
```

**Run with conftest (recommended for CI):**

```bash
conftest test schema-diff.json \
  --policy examples/07-opa-policies/ \
  --namespace graphql.schema
```

**Expected output (violations present):**

```
FAIL - schema-diff.json - graphql.schema - Type "UserProfile" is missing a description
FAIL - schema-diff.json - graphql.schema - Breaking removal of type "LegacyOrder" is not approved
WARN - schema-diff.json - graphql.schema - Query field "products" is missing @tag directive
```

**Expected output (clean schema):**

```
1 test, 0 passed, 0 warnings, 0 failures, 0 exceptions
```

---

## Interpreting Policy Output

OPA returns a set of denial strings. Each string identifies the rule that fired and the
offending schema element. CI scripts should:

1. Count the number of entries in the `deny` set.
2. If count > 0, post the violation strings as a PR comment and fail the check.
3. Count the number of entries in the `warn` set.
4. If count > 0, post advisory strings as a PR comment but do not fail the check.

The GitHub Actions workflow in `../../examples/04-github-actions/` includes a complete
step that performs this evaluation and posts annotations.

---

## Policy Customization

Each team can extend these policies for their own conventions:

- Add custom naming rules in a separate `local-policies.rego` file under the same package
- Override default behavior using OPA's partial rules (same rule name in multiple files
  merges the sets)
- Use `data.graphql.schema.exceptions` to define team-specific exceptions without modifying
  the shared policy file

---

## Key Design Decisions

**Using `deny[msg]` set rules instead of boolean rules.** Set-based deny rules accumulate
all violations in a single evaluation, unlike short-circuiting boolean rules. This means
every violation in a PR is reported at once rather than requiring iterative fix-and-rerun
cycles.

**Separating `deny` from `warn`.** Some policy violations are advisory (e.g., missing
`@tag` directives) but should not block merges. Using separate `deny` and `warn` rule sets
allows CI to treat them differently without duplicating evaluation logic.

**Approvals via PR labels.** Requiring an explicit `"breaking-change-approved"` label
rather than a comment or file-based override creates a traceable, auditable record in the
PR history that a human consciously approved a breaking change.

**Schema diff as the policy input, not raw SDL.** Policies that compare old and new schema
state cannot be expressed against a single SDL document. The diff document structure allows
rules like `deny_breaking_type_removal` to compare before/after state within a single
evaluation.

---

## Related Documentation

- `../../docs/13-policy-as-code/` — Policy as code principles, OPA architecture, Rego
  language reference
- `../../docs/09-schema-governance/` — Schema governance strategies, breaking change
  classification, deprecation workflows
- `../../docs/11-ci-cd-automation/` — CI/CD pipeline patterns for schema validation
- `../../examples/03-schema-validation/` — graphql-inspector schema validation (complement
  to OPA policies)
- `../../examples/04-github-actions/` — GitHub Actions workflows that invoke these policies
