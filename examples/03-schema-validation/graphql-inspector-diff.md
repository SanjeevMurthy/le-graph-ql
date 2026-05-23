# GraphQL Inspector Diff

> Companion documentation: `../../docs/10-schema-validation/`
> Related example: `rover-schema-check.md` (use after inspector for registry-correlated checks)

`graphql-inspector` is an offline, registry-independent tool for GraphQL schema diffing,
validation, and similarity analysis. It operates purely on SDL files and does not require a
connection to Apollo GraphOS or any running server. This makes it ideal for pre-commit hooks,
local development feedback, and CI environments with restricted network access.

---

## graphql-inspector vs Rover: Complementary, Not Competing

| Dimension | graphql-inspector | rover subgraph check |
|-----------|------------------|---------------------|
| Network required | No — reads SDL files from disk | Yes — calls Apollo GraphOS |
| Correlates with client traffic | No — structural diff only | Yes — uses operation usage reports |
| False positive rate | Higher (all structural breaks are flagged) | Lower (filters out unused fields) |
| Speed | Very fast (< 2s) | Slower (10-120s depending on graph size) |
| Pre-commit suitable | Yes | No (too slow and requires CI secrets) |
| Custom break rules | Yes — via --rule files | No |
| Multi-subgraph federation | Partial (no composition awareness) | Full (uses the registry supergraph) |
| Offline / air-gapped | Yes | No |

The recommended pipeline is: `graphql-inspector` in pre-commit and as a fast CI gate, then
`rover subgraph check` as the authoritative gate that correlates with real client usage.

---

## Installation

```bash
# Install as a project dev dependency (recommended for consistent versions in CI).
npm install --save-dev @graphql-inspector/cli graphql

# Alternatively, install globally for developer workstations.
npm install -g @graphql-inspector/cli
```

Verify the installation:

```bash
npx graphql-inspector --version
# Expected output: @graphql-inspector/cli/5.x.x
```

---

## Basic Diff Command

```bash
# Compare two SDL files and print a human-readable change list.
# old-schema is the baseline (e.g., from main branch).
# new-schema is the proposed change (e.g., from the feature branch).
npx graphql-inspector diff old-schema.graphql new-schema.graphql
```

### Example: Non-Breaking Changes

```bash
# Scenario: added a new field to User and an optional argument to Query.users.

npx graphql-inspector diff \
  baseline/users-schema.graphql \
  subgraphs/users/schema.graphql
```

Output:
```
Detected the following changes (2) between schemas:

  NON_BREAKING   Field displayName was added to object type User
  NON_BREAKING   Argument cursor was added to field users in type Query
```

Exit code: 0 (success — no breaking changes)

### Example: Breaking Changes

```bash
npx graphql-inspector diff \
  baseline/users-schema.graphql \
  subgraphs/users/schema.graphql
```

Output:
```
Detected the following changes (3) between schemas:

  BREAKING    Field legacyId was removed from object type User
  BREAKING    Type of field age on type User changed from Int to String
  DANGEROUS   Default value of argument limit on field Query.users changed from 10 to 20
```

Exit code: 1 (failure — breaking changes detected)

---

## Using --rule Flags to Customize Breaking Change Classification

Some structural changes are technically breaking by spec but acceptable in your specific
deployment context. Use `--rule` flags to reclassify them.

```bash
# Treat DANGEROUS changes as BREAKING (stricter than the default).
# Use this on public APIs where any behavioral change is unacceptable.
npx graphql-inspector diff \
  baseline/schema.graphql \
  subgraphs/users/schema.graphql \
  --rule dangerousBreaking

# Ignore deprecation-related changes (e.g., adding @deprecated to a field).
# Deprecations are always safe; ignoring them reduces noise in the diff output.
npx graphql-inspector diff \
  baseline/schema.graphql \
  subgraphs/users/schema.graphql \
  --rule ignoreDescriptionChanges  # description-only changes are never breaking

# Use a custom rule file (see "Custom Rules" section below).
npx graphql-inspector diff \
  baseline/schema.graphql \
  subgraphs/users/schema.graphql \
  --rule ./policies/inspector-rules.js
```

Available built-in rule names:

| Rule Name | Effect |
|-----------|--------|
| `dangerousBreaking` | Promote DANGEROUS changes to BREAKING |
| `ignoreDescriptionChanges` | Ignore changes to type/field descriptions |
| `ignoreParameterDefaultValue` | Ignore changes to argument default values |
| `suppressRemovalOfDeprecatedField` | Do not flag removal of a @deprecated field as BREAKING |

---

## graphql-inspector validate (Schema + Operations)

The `validate` command checks that a set of operation documents are compatible with a schema.
This is useful for validating that client-side queries still work after a schema change.

```bash
# Validate all operation documents in the operations/ directory against the schema.
npx graphql-inspector validate \
  'operations/**/*.graphql' \
  subgraphs/users/schema.graphql

# Validate operations from multiple subgraph schemas simultaneously.
# Inspector will report which operation violates which type in which schema.
npx graphql-inspector validate \
  'operations/**/*.graphql' \
  '{subgraphs/*/schema.graphql}'  # glob for all subgraph SDL files
```

### Example Output

```
Validating 7 documents against subgraphs/users/schema.graphql

  INVALID   operations/GetLegacyUserProfile.graphql
            - Unknown field "legacyId" on type "User". [line 5]

  INVALID   operations/ListUsersWithOffset.graphql
            - Unknown argument "offset" on field "Query.users". [line 3]

  VALID     operations/GetUserProfile.graphql
  VALID     operations/CreateUser.graphql
  VALID     operations/UpdateUserEmail.graphql
  VALID     operations/DeleteUser.graphql
  VALID     operations/GetUsersByTeam.graphql

2 invalid document(s) detected
```

---

## Finding Affected Operations with graphql-inspector similar

When a breaking change is unavoidable (e.g., renaming a field after a deprecation period),
use `similar` to find all operation documents that reference the changed field. This gives
you a migration checklist.

```bash
# Find all operations that use the field "legacyId" on the "User" type.
# Pass the OLD schema so the field is still resolvable.
npx graphql-inspector similar \
  baseline/users-schema.graphql \
  --match 'User.legacyId'

# Find all operations that use a specific type.
npx graphql-inspector similar \
  baseline/schema.graphql \
  --match 'LegacyOrderFormat'
```

Output:
```
Similar documents for User.legacyId:

  HIGH_SIMILARITY   operations/GetLegacyUserProfile.graphql  (uses User.legacyId directly)
  HIGH_SIMILARITY   operations/AdminUserExport.graphql       (uses User.legacyId in fragment)
  MEDIUM_SIMILARITY operations/GetUserProfile.graphql        (uses User type but not legacyId)
```

---

## Pre-Commit Hook

Install a pre-commit hook that runs `graphql-inspector diff` before every commit. This
prevents breaking changes from ever entering the repository, even on feature branches.

### Setup with Husky

```bash
# Install husky for managing Git hooks.
npm install --save-dev husky lint-staged

# Initialize husky.
npx husky init
```

Create `.husky/pre-commit`:

```bash
#!/usr/bin/env bash
# .husky/pre-commit
#
# Run graphql-inspector diff on every changed schema file before committing.
# If any breaking changes are detected, the commit is aborted and the developer
# must either fix the schema or explicitly acknowledge the break.

set -euo pipefail

# Find GraphQL schema files staged for commit.
# We only check files that are actually being committed, not all files in the repo.
STAGED_SCHEMA_FILES=$(git diff --cached --name-only --diff-filter=ACM \
  | grep -E 'subgraphs/.*/schema\.graphql$' || true)

if [ -z "$STAGED_SCHEMA_FILES" ]; then
  # No schema files in this commit — skip the check.
  exit 0
fi

FAILED=0

for schema_file in $STAGED_SCHEMA_FILES; do
  subgraph=$(dirname "$schema_file" | xargs basename)
  echo "Checking subgraph: $subgraph ($schema_file)"

  # Get the baseline version of this file from HEAD (the last committed version).
  # If the file is new (no HEAD version), skip the diff check.
  if ! git show HEAD:"$schema_file" > /tmp/baseline-schema.graphql 2>/dev/null; then
    echo "  New file — no diff check needed."
    continue
  fi

  # Run the diff. Exit code 1 means breaking changes were detected.
  if ! npx graphql-inspector diff \
    /tmp/baseline-schema.graphql \
    "$schema_file" 2>&1; then
    echo ""
    echo "  BLOCKED: Breaking changes detected in $schema_file."
    echo "  Fix the breaking changes or follow the deprecation process."
    echo "  If this break is intentional, use 'git commit --no-verify' to bypass."
    echo "  (Bypassing requires a Jira ticket number in the commit message.)"
    FAILED=1
  fi
done

if [ "$FAILED" -eq 1 ]; then
  echo ""
  echo "Pre-commit check failed. Commit aborted."
  exit 1
fi

echo "All schema checks passed."
```

```bash
# Make the hook executable.
chmod +x .husky/pre-commit
```

---

## Custom Rules via --rule File

For teams with specific breaking-change policies, custom rule files allow fine-grained
control over how changes are classified.

```js
// policies/inspector-rules.js
//
// Custom graphql-inspector rule that modifies how certain changes are classified.
// Export a function that receives the change object and returns a modified
// (or unchanged) change object, or null to suppress the change entirely.
//
// The change object has the properties:
//   - type: string (e.g., "FIELD_REMOVED", "TYPE_REMOVED", "ARG_DEFAULT_VALUE_CHANGE")
//   - criticality: { level: "BREAKING" | "DANGEROUS" | "NON_BREAKING", reason: string }
//   - message: string
//   - path: string (e.g., "User.legacyId")

module.exports = function customRule(change) {
  // Rule 1: Removing a field that ends with "Legacy" is intentional and not breaking.
  // Teams use a naming convention to mark fields for removal: "legacyFieldName".
  // Once the field has been deprecated and clients migrated, removal is safe.
  if (
    change.type === 'FIELD_REMOVED' &&
    change.path &&
    /Legacy[A-Z]?/.test(change.path.split('.').pop())
  ) {
    // Downgrade to NON_BREAKING with an explanatory reason.
    return {
      ...change,
      criticality: {
        level: 'NON_BREAKING',
        reason: 'Fields with "Legacy" naming convention are pre-approved for removal.',
      },
    };
  }

  // Rule 2: Description-only changes are never breaking.
  // This is also available as a built-in rule (ignoreDescriptionChanges),
  // but shown here as an example of the custom rule pattern.
  if (change.type === 'TYPE_DESCRIPTION_CHANGED' || change.type === 'FIELD_DESCRIPTION_CHANGED') {
    return null; // null suppresses the change entirely from the report
  }

  // Rule 3: Input type changes on internal-only inputs (prefixed with "_Internal")
  // are not breaking because they are not exposed to external clients.
  if (
    change.path &&
    change.path.startsWith('_Internal')
  ) {
    return {
      ...change,
      criticality: {
        level: 'NON_BREAKING',
        reason: 'Internal types (prefixed _Internal) are not part of the public API contract.',
      },
    };
  }

  // Return the change unmodified for all other cases.
  return change;
};
```

Use the rule file:

```bash
npx graphql-inspector diff \
  baseline/schema.graphql \
  subgraphs/users/schema.graphql \
  --rule ./policies/inspector-rules.js
```

---

## Generating Baseline Schemas for CI

In CI, the baseline schema must be the version on the target branch (usually `main`), not the
last commit on the feature branch.

```bash
# Method 1: git show — extract the schema from the git object store.
# This is the most reliable method in CI because it does not require a working copy.
git show origin/main:subgraphs/users/schema.graphql > /tmp/users-baseline.graphql

# Method 2: git stash — temporarily unstage changes to read the baseline.
# Fragile in CI because it modifies the working tree. Prefer Method 1.
git stash
cp subgraphs/users/schema.graphql /tmp/users-baseline.graphql
git stash pop

# Method 3: rover subgraph fetch — fetch the current registry SDL as baseline.
# Use this when you want to diff against the published schema, not the main branch file.
# Useful when the main branch has unreleased changes.
rover subgraph fetch my-graph@main \
  --name users \
  > /tmp/users-registry-baseline.graphql
```

---

## JSON Output for CI Parsing

```bash
# Output the diff as JSON for structured CI processing.
npx graphql-inspector diff \
  baseline/schema.graphql \
  subgraphs/users/schema.graphql \
  --format json

# Example JSON output structure:
# [
#   {
#     "message": "Field 'legacyId' was removed from object type 'User'",
#     "path": "User.legacyId",
#     "type": "FIELD_REMOVED",
#     "criticality": {
#       "level": "BREAKING",
#       "reason": "Removing a field is a breaking change"
#     }
#   }
# ]

# Count breaking changes from JSON output.
BREAKING=$(npx graphql-inspector diff \
  baseline/schema.graphql \
  subgraphs/users/schema.graphql \
  --format json 2>/dev/null \
  | jq '[.[] | select(.criticality.level == "BREAKING")] | length')

echo "Breaking changes: $BREAKING"
```

---

## Key Design Decisions

**Why use graphql-inspector instead of relying solely on rover check.** Rover check requires
a network call to GraphOS and typically takes 30-120 seconds. For developer experience, fast
feedback is critical. graphql-inspector runs in under 2 seconds and requires no credentials.
The pre-commit hook using inspector means a developer knows about a breaking change before
they even push — not after waiting for a CI job.

**Why the pre-commit hook uses `--no-verify` as the documented escape hatch.** Completely
blocking all breaking changes in pre-commit is counterproductive — sometimes a breaking
change is intentional (scheduled removal of a deprecated field). By documenting `--no-verify`
as the escape hatch (with the policy requirement of a Jira ticket in the commit message),
the policy remains enforceable through the commit history audit trail without creating
friction that causes developers to disable the hook permanently.

**Why custom rules are a JavaScript file rather than a YAML allow-list.** A YAML allow-list
of "approved breaking changes" would need constant maintenance as fields are added and
removed. A rule function that matches patterns (e.g., "Legacy" suffix, "_Internal" prefix)
encodes the policy once and applies it automatically to all future changes that match the
pattern. This is more maintainable and less prone to stale allow-list entries.

**Why use `rover subgraph fetch` as the baseline in some scenarios.** The main branch SDL
file and the published registry SDL can diverge if the main branch has merged changes that
have not yet been published. Using `rover subgraph fetch` as the baseline ensures you are
comparing against what the router is actually serving, not what is in the repository.

---

## Related Documentation

- `../../docs/10-schema-validation/` — Full validation pipeline theory and design
- `../../docs/12-schema-evolution/` — Deprecation policy and safe removal process
- `graphql-eslint-config.md` — Style lint that runs before this diff step
- `rover-schema-check.md` — Registry-correlated check that runs after this diff step
- `../../examples/04-github-actions/schema-check-workflow.md` — CI workflow wiring all tools together
