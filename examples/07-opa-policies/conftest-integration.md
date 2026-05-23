# conftest Integration for GraphQL Schema Governance

Companion documentation: `../../docs/13-policy-as-code/` and `../../docs/11-ci-cd-automation/`

This document covers using [conftest](https://www.conftest.dev/) as a CI-friendly
alternative to raw `opa eval` for running GraphQL schema governance policies. conftest
wraps OPA with conventions for test output formatting, input file discovery, and policy
bundling that map well onto pull request workflows.

---

## Why conftest Instead of Raw opa eval

`opa eval` is the OPA evaluation primitive. It is flexible but requires shell scripting
to collect violations, format PR comments, and map exit codes to CI status. conftest adds:

- Structured PASS/FAIL/WARN output out of the box
- Multi-file input support (evaluate multiple schema diffs in one run)
- OCI bundle fetching (`conftest pull`) for centrally-managed shared policies
- `conftest verify` runs the policy unit tests, keeping test execution consistent with
  policy evaluation in the same tool

For teams with multiple repos sharing the same GraphQL governance policies, conftest OCI
bundles eliminate the need to copy policy files across repositories.

---

## conftest Setup

### conftest.toml

Place `conftest.toml` at the root of the repository (or in the CI working directory).
This file tells conftest where to find policy files and which namespace to evaluate.

```toml
# conftest.toml
#
# namespace maps to the OPA package name declared in the policy file.
# Our policies use: package graphql.schema
# conftest uses dot-separated namespace, which maps directly to the package path.

[[policies]]
# path to the directory containing .rego policy files
path = "examples/07-opa-policies"

# namespace matches `package graphql.schema` in the policy file
namespace = "graphql.schema"

# output format: "stdout" for human-readable, "json" for machine-readable parsing
# In CI we typically use "json" to extract annotation data
output = "stdout"

[[policies]]
# Additional local policy overrides — teams can add custom rules here without
# touching the shared policy directory. Same namespace means rules merge.
path = "policies/local"
namespace = "graphql.schema"
```

---

## Schema Diff Input Format

### How the Input Document is Generated

The OPA policies expect a `schema-diff.json` document as input. This document captures
both the old and new schema state in a single JSON structure. The generation pipeline
uses `graphql-inspector` to compute the diff and `jq` to transform the output into the
exact shape the policies expect.

**Step 1: Install graphql-inspector**

```bash
npm install --save-dev @graphql-inspector/cli
# or globally:
npm install -g @graphql-inspector/cli
```

**Step 2: Export both schema SDL files**

In a pull request context, the old schema is the SDL from the base branch and the new
schema is the SDL from the head branch.

```bash
# Check out base branch SDL (usually from the schema registry)
# In Apollo GraphOS, you can pull the SDL with:
rover graph fetch my-graph@production --output old-schema.graphql

# The new schema is the SDL file modified in this PR
cp src/schema.graphql new-schema.graphql
```

**Step 3: Generate the schema diff JSON**

graphql-inspector's `diff` command outputs a list of changes. We use a custom jq
transformation to produce the OPA input format, which requires both the full old and
new type lists (not just the diff delta).

```bash
# Introspect both schemas to get full type metadata
npx graphql-inspector introspect old-schema.graphql --format json > old-introspection.json
npx graphql-inspector introspect new-schema.graphql --format json > new-introspection.json
```

**Step 4: Extract PR labels from GitHub API**

```bash
# Using GitHub CLI to get PR labels as a JSON array of strings
PR_LABELS=$(gh pr view --json labels --jq '[.labels[].name]')
```

**Step 5: Compose the final schema-diff.json**

```bash
jq -n \
  --argjson old "$(cat old-introspection.json)" \
  --argjson new "$(cat new-introspection.json)" \
  --argjson labels "$PR_LABELS" \
  '{
    old_schema: {
      types: ($old.__schema.types | map(select(.name | startswith("__") | not)))
    },
    new_schema: {
      types: ($new.__schema.types | map(select(.name | startswith("__") | not)))
    },
    labels: $labels,
    approved_removals: []
  }' > schema-diff.json
```

This produces the exact input shape expected by the OPA policies:

```json
{
  "old_schema": {
    "types": [...]
  },
  "new_schema": {
    "types": [...]
  },
  "labels": ["breaking-change-approved"],
  "approved_removals": []
}
```

---

## Running conftest in CI

### Complete GitHub Actions Step

The following is a complete bash script suitable for a GitHub Actions `run:` block.
It generates the schema diff, runs conftest, and posts results as PR annotations.

```bash
#!/usr/bin/env bash
# ci-schema-governance.sh
# Run GraphQL schema governance policies via conftest.
# Exit code 1 if any deny rules fire; exit code 0 if only warnings.

set -euo pipefail

POLICY_DIR="${POLICY_DIR:-examples/07-opa-policies}"
OLD_SCHEMA="${OLD_SCHEMA:-old-schema.graphql}"
NEW_SCHEMA="${NEW_SCHEMA:-new-schema.graphql}"

echo "==> Generating schema introspection JSON..."

# Introspect both schemas. The --force flag allows introspection even if the
# schema has validation errors (useful when checking malformed schemas).
npx graphql-inspector introspect "$OLD_SCHEMA" --format json > /tmp/old-introspection.json
npx graphql-inspector introspect "$NEW_SCHEMA" --format json > /tmp/new-introspection.json

echo "==> Fetching PR labels..."
PR_LABELS=$(gh pr view --json labels --jq '[.labels[].name]' 2>/dev/null || echo "[]")

echo "==> Composing schema-diff.json..."
jq -n \
  --argjson old "$(cat /tmp/old-introspection.json)" \
  --argjson new "$(cat /tmp/new-introspection.json)" \
  --argjson labels "$PR_LABELS" \
  '{
    old_schema: {
      types: ($old.__schema.types | map(select(.name | startswith("__") | not)))
    },
    new_schema: {
      types: ($new.__schema.types | map(select(.name | startswith("__") | not)))
    },
    labels: $labels,
    approved_removals: []
  }' > /tmp/schema-diff.json

echo "==> Running conftest policy evaluation..."

# --output json produces machine-readable output for annotation extraction.
# --namespace must match the OPA package name in the policy files.
# --policy points to the directory containing .rego files.
# conftest exits non-zero if any FAIL results exist.
conftest test /tmp/schema-diff.json \
  --policy "$POLICY_DIR" \
  --namespace "graphql.schema" \
  --output json 2>&1 | tee /tmp/conftest-results.json

CONFTEST_EXIT=$?

echo "==> Parsing results for GitHub annotations..."

# Extract FAIL messages and emit as GitHub Actions error annotations.
# These appear inline in the PR diff view.
jq -r '
  .[] |
  select(.failures != null) |
  .failures[] |
  "::error file=schema.graphql,title=Schema Policy Violation::" + .msg
' /tmp/conftest-results.json || true

# Extract WARN messages and emit as GitHub Actions notice annotations.
jq -r '
  .[] |
  select(.warnings != null) |
  .warnings[] |
  "::warning file=schema.graphql,title=Schema Policy Advisory::" + .msg
' /tmp/conftest-results.json || true

# Summary output to GitHub step summary
echo "## Schema Governance Policy Results" >> "$GITHUB_STEP_SUMMARY"
echo "" >> "$GITHUB_STEP_SUMMARY"

FAIL_COUNT=$(jq '[.[] | .failures // [] | length] | add // 0' /tmp/conftest-results.json)
WARN_COUNT=$(jq '[.[] | .warnings // [] | length] | add // 0' /tmp/conftest-results.json)

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "**FAILED** — $FAIL_COUNT policy violation(s)" >> "$GITHUB_STEP_SUMMARY"
    echo "" >> "$GITHUB_STEP_SUMMARY"
    echo "### Violations" >> "$GITHUB_STEP_SUMMARY"
    jq -r '.[] | .failures // [] | .[] | "- " + .msg' /tmp/conftest-results.json >> "$GITHUB_STEP_SUMMARY"
else
    echo "**PASSED** — No policy violations" >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$WARN_COUNT" -gt 0 ]; then
    echo "" >> "$GITHUB_STEP_SUMMARY"
    echo "### Advisories ($WARN_COUNT)" >> "$GITHUB_STEP_SUMMARY"
    jq -r '.[] | .warnings // [] | .[] | "- " + .msg' /tmp/conftest-results.json >> "$GITHUB_STEP_SUMMARY"
fi

# Exit non-zero only for actual failures, not for warnings.
# This allows PRs with only advisory warnings to still merge.
exit "$CONFTEST_EXIT"
```

### GitHub Actions Workflow Snippet

```yaml
# .github/workflows/schema-governance.yml

name: Schema Governance

on:
  pull_request:
    paths:
      - "**/*.graphql"
      - "**/*.graphqls"
      - "**/schema.ts"

jobs:
  schema-policies:
    name: OPA Schema Policies
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write   # needed to post PR comments

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # needed to access base branch SDL

      - name: Install tools
        run: |
          # Install OPA
          curl -L -o opa https://openpolicyagent.org/downloads/v0.57.0/opa_linux_amd64_static
          chmod +x opa && sudo mv opa /usr/local/bin/

          # Install conftest
          CONFTEST_VERSION=0.47.0
          curl -L -o conftest.tar.gz \
            "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_x86_64.tar.gz"
          tar -xzf conftest.tar.gz && sudo mv conftest /usr/local/bin/

          # Install graphql-inspector
          npm install -g @graphql-inspector/cli

      - name: Fetch base branch SDL
        env:
          APOLLO_KEY: ${{ secrets.APOLLO_KEY }}
        run: |
          # Fetch the current production schema from Apollo GraphOS as the "old" schema.
          # This is the authoritative before-state for the diff.
          rover graph fetch my-graph@production > old-schema.graphql

      - name: Run schema governance policies
        env:
          GH_TOKEN: ${{ github.token }}
        run: bash ci-schema-governance.sh
```

---

## conftest Output Formats

### Human-Readable (stdout)

```
FAIL - /tmp/schema-diff.json - graphql.schema - Type "UserProfile" is missing a description.
FAIL - /tmp/schema-diff.json - graphql.schema - Field "legacyId" on type "User" has @deprecated but no reason.
WARN - /tmp/schema-diff.json - graphql.schema - Advisory: Query field "internalUsers" is missing an @tag directive.

2 tests, 0 passed, 1 warning, 2 failures, 0 exceptions
```

### Machine-Readable (json output)

```json
[
  {
    "filename": "/tmp/schema-diff.json",
    "namespace": "graphql.schema",
    "successes": 0,
    "failures": [
      {
        "msg": "Type \"UserProfile\" is missing a description. All OBJECT, INTERFACE, INPUT_OBJECT, and ENUM types must have a non-empty description string.",
        "metadata": {}
      },
      {
        "msg": "Field \"legacyId\" on type \"User\" has @deprecated but no reason. Add reason: \"Use someOtherField instead.\"",
        "metadata": {}
      }
    ],
    "warnings": [
      {
        "msg": "Advisory: Query field \"internalUsers\" is missing an @tag directive. Consider adding @tag(name: \"public\") or @tag(name: \"internal\").",
        "metadata": {}
      }
    ],
    "exceptions": []
  }
]
```

The JSON output is what the CI script parses to produce GitHub PR annotations and
the step summary. The `msg` field from each failure maps directly to the string produced
by `sprintf(...)` in the Rego deny rules.

---

## Local Development

### Running Policy Tests with conftest verify

`conftest verify` runs the OPA unit tests defined in `policy-tests.rego`. This is the
preferred way to run tests locally because it uses the same conftest binary as CI.

```bash
# Run all policy tests
conftest verify --policy examples/07-opa-policies/

# Run with verbose output showing each test name and result
conftest verify --policy examples/07-opa-policies/ --trace

# Expected output:
# data.graphql.schema.test_description_required_type_fails: PASS (1.2ms)
# data.graphql.schema.test_description_required_passes: PASS (0.8ms)
# data.graphql.schema.test_introspection_types_excluded: PASS (0.6ms)
# ...
# 18 tests, 18 passed, 0 failures
```

### Testing Against a Local Schema Diff

To evaluate policies against a local `schema-diff.json` without going through CI:

```bash
# Quick evaluation — show all violations
conftest test schema-diff.json \
  --policy examples/07-opa-policies/ \
  --namespace graphql.schema

# With raw OPA for interactive REPL-style debugging
opa run --watch \
  examples/07-opa-policies/schema-governance-policies.rego \
  schema-diff.json

# Inside the OPA REPL, evaluate specific rules:
# > data.graphql.schema.deny
# > data.graphql.schema.warn
# > data.graphql.schema.is_breaking_removal("UserProfile")
```

### Adding a New Policy Rule Locally

1. Add the Rego rule to `schema-governance-policies.rego`
2. Add corresponding `test_*` functions to `policy-tests.rego`
3. Run `conftest verify --policy examples/07-opa-policies/` — all tests must pass
4. Run `conftest test examples/07-opa-policies/fixtures/` against sample fixtures
5. Open a PR — CI will execute both the test suite and the policy evaluation

---

## Policy Bundle Publishing

For organizations with multiple repositories that share the same GraphQL governance
policies, publishing the policies as an OCI bundle eliminates the need to copy `.rego`
files across repos. Teams pull the bundle in CI without vendoring policy code.

### Building and Publishing the Bundle

```bash
# Build an OPA bundle from the policy directory.
# The --bundle flag creates an OCI-compatible bundle tarball.
opa build \
  --bundle examples/07-opa-policies/ \
  --output graphql-governance-bundle.tar.gz \
  --target rego

# Publish the bundle to an OCI registry (using ORAS or docker).
# The OCI artifact type for OPA bundles is application/vnd.oci.image.layer.v1.tar+gzip.
# ORAS CLI:
oras push \
  ghcr.io/my-org/graphql-governance-policies:latest \
  --media-type application/vnd.oci.image.layer.v1.tar+gzip \
  graphql-governance-bundle.tar.gz

# Tag with a version for reproducible CI:
oras push \
  ghcr.io/my-org/graphql-governance-policies:v1.2.0 \
  --media-type application/vnd.oci.image.layer.v1.tar+gzip \
  graphql-governance-bundle.tar.gz
```

### Consuming the Bundle in conftest

```toml
# conftest.toml in the consuming repository

[[policies]]
# Pull policy bundle from OCI registry at CI startup.
# Pin to an immutable digest for reproducibility:
#   ghcr.io/my-org/graphql-governance-policies@sha256:abc123...
# Or use a mutable tag for rolling updates:
#   ghcr.io/my-org/graphql-governance-policies:latest
url = "ghcr.io/my-org/graphql-governance-policies:v1.2.0"
namespace = "graphql.schema"
```

```bash
# In CI, pull the bundle before running conftest test:
conftest pull ghcr.io/my-org/graphql-governance-policies:v1.2.0

# conftest stores bundles in .conftest/ by default.
# Then run as normal:
conftest test schema-diff.json --namespace graphql.schema
```

### Bundle Versioning Strategy

| Version Type | Use Case |
|---|---|
| `v1.2.0` (semver tag) | Production CI — pin for reproducibility and auditability |
| `latest` | Local development — always use newest policies |
| `@sha256:digest` | Compliance-sensitive environments requiring immutable references |
| `v1-staging` | Pre-release policy changes being validated across test repos |

Align bundle version bumps with policy changes using semantic versioning:
- Patch bump: bug fix to existing rule (tighter evaluation without new restrictions)
- Minor bump: new warn rule added (non-blocking, backward-compatible)
- Major bump: new deny rule added (blocking — requires adoption coordination across teams)

---

## Key Design Decisions

**conftest over raw opa eval for CI.** `opa eval` outputs JSON that requires additional
shell parsing to extract violation messages and map them to CI annotations. conftest
standardizes the output format and provides `--output json` for machine-readable results
out of the box, reducing the amount of shell glue code in CI pipelines.

**Generating schema-diff.json at CI time rather than committing it.** The input document
is derived from the live schema state in the registry and the PR's SDL changes. Committing
it to the repo would create stale snapshots. Generating it fresh in each CI run ensures
the policy always evaluates against the current state of the supergraph.

**Separating deny exit codes from warn exit codes.** conftest exits non-zero if any
failures exist. Warnings do not affect the exit code. This maps cleanly to CI behavior:
violations block the merge, advisories appear as comments but allow merge. Teams that
want to graduate a warning to a failure can move the rule from `warn[msg]` to `deny[msg]`
in the policy file.

**OCI bundle publishing for multi-repo governance.** Copy-paste of policy files across
repos leads to drift — different teams running different versions of the same rules.
OCI bundles with semantic versioning allow the platform team to publish policy updates
and consuming teams to opt into new versions on their own schedule via a single version
bump in `conftest.toml`.

---

## Related Documentation

- `../../docs/13-policy-as-code/` — Policy as code principles, OPA architecture, Rego
  language reference, bundle management
- `../../docs/09-schema-governance/` — Schema governance strategy, breaking change
  classification, deprecation windows
- `../../docs/11-ci-cd-automation/` — Full CI/CD pipeline patterns including schema
  validation and deployment automation
- `../../examples/04-github-actions/` — Complete GitHub Actions workflows that call these
  conftest evaluation scripts
- `../../examples/03-schema-validation/` — graphql-inspector validation (runs before OPA
  policies in the pipeline)
