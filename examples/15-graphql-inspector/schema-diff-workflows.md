# Schema Diff Workflows with graphql-inspector

Companion docs: `../../docs/10-schema-validation/`, `../../docs/09-schema-governance/`

---

## 1. Basic Diff — Understanding the Output

```bash
# Compare two local schema files
graphql-inspector diff old-schema.graphql new-schema.graphql

# Example output:
# Detected the following changes (4) between schemas:
#
# [breaking] Field 'Product.price' changed type from 'Float' to 'Money'
# [breaking] Field 'User.email' was removed from object type 'User'
# [dangerous] Enum value 'PENDING' was added to enum 'OrderStatus'
# [non-breaking] Field 'Product.description' was added to object type 'Product'
```

### Change Severity Definitions

**BREAKING** — Changes that will cause existing clients to fail or receive incorrect data. Any deployed client that relies on the changed field will experience an error after the schema is updated. Breaking changes require a migration path and typically need the RFC process.

**DANGEROUS** — Changes that are technically schema-valid but may cause unexpected behavior in clients. Clients will not get errors, but behavior may change in ways that are not immediately obvious. Require careful testing and communication.

**NON_BREAKING** — Changes that are fully backward compatible. Existing clients are unaffected. Can be deployed without coordination.

---

## 2. All Change Types — Comprehensive Reference

### BREAKING Changes

| Change | Example | Why It Breaks |
|---|---|---|
| Type removed | `type Order {}` deleted | Clients querying `Order` fields get a type error |
| Field removed from type | `Product.price` deleted | Clients selecting `price` get a validation error |
| Argument removed from field | `products(first)` loses `first` | Clients passing `first` get an unknown argument error |
| Field type changed (incompatible) | `price: Float` → `price: Money` | Return type mismatch; clients expecting a scalar get an object |
| Non-null added to field | `email: String` → `email: String!` | Existing null values will fail the non-null constraint |
| Non-null added to argument | `id: ID` → `id: ID!` | Clients that omit the argument get a validation error |
| Input field removed | `CreateProductInput.sku` deleted | Clients sending `sku` get an unknown field error |
| Enum value removed | `OrderStatus.ARCHIVED` deleted | Clients that check for `ARCHIVED` may behave incorrectly |
| Directive argument removed | `@cache(maxAge)` loses `maxAge` | Operations using the removed argument fail validation |
| Interface field removed | Field removed from interface | All implementing types lose the field; clients break |
| Union member removed | `SearchResult = Product \| Order` → `Product` only | Clients using fragments on `Order` get no data |

### DANGEROUS Changes

| Change | Example | Why It's Dangerous |
|---|---|---|
| Enum value added | `OrderStatus.ARCHIVED` added | Clients with exhaustive enum handling may hit an unexpected case |
| Required argument added | `product(id: ID!)` gets new required arg | Clients that call `product` without the new arg will fail |
| Default value changed | `products(first: 10)` → `products(first: 20)` | Clients that omit `first` get more data than expected |
| Type added to union | `SearchResult` adds `Category` | Clients with inline fragments may get unexpected types |
| Field argument default changed | Any default value modification | Behavioral change without type error |

### NON_BREAKING Changes

| Change | Example | Why It's Safe |
|---|---|---|
| Type added | New `type Recommendation {}` | No existing client knows about it |
| Field added to type | `Product.videoUrl` added | Clients that don't request it are unaffected |
| Optional argument added | `products(filter: ProductFilter)` added | Clients that don't use it are unaffected |
| Description changed | `"A product"` → `"A catalog product"` | Descriptions are not part of the query contract |
| Deprecation added | `@deprecated(reason: "Use X")` | Clients continue working; they receive a deprecation warning |
| Non-null removed from field | `email: String!` → `email: String` | Relaxing a constraint is always safe |
| Non-null removed from argument | `id: ID!` → `id: ID` | Accepting null where previously non-null was required |

---

## 3. Custom Rules

The `--rule` flag allows customizing which changes are considered breaking. This is useful for organizations that have policies that differ from the default classification.

```bash
# Treat description changes as non-breaking (default is to flag them)
graphql-inspector diff old.graphql new.graphql \
  --rule ignoreDescriptionChanges

# Treat adding a required argument as non-breaking
# (use this carefully — only when you are certain all clients pass all arguments)
graphql-inspector diff old.graphql new.graphql \
  --rule ignoreReasonableChanges

# Use a custom rule file
graphql-inspector diff old.graphql new.graphql \
  --rule ./ci/graphql-rules.js
```

### Writing a Custom Rule

Custom rules are JavaScript (or TypeScript, transpiled) files that export a function receiving the list of changes and returning a filtered/modified list.

```javascript
// ci/graphql-rules.js
// Custom rule: treat description changes as non-breaking (many teams
// update descriptions frequently and do not want them flagged)

module.exports = (changes) => {
  return changes.map((change) => {
    // If the change is purely a description change, reclassify as non-breaking
    if (
      change.message.toLowerCase().includes('description') &&
      change.criticality.level === 'DANGEROUS'
    ) {
      return {
        ...change,
        criticality: {
          level: 'NON_BREAKING',
          reason: 'Description changes are classified as non-breaking per org policy',
        },
      };
    }
    return change;
  });
};
```

---

## 4. Diff Against a Running Endpoint

```bash
# Introspect the live production schema and compare to the local new version
# This answers: "what would change if I deployed this new schema to production?"
graphql-inspector diff \
  "http://api.example.com/graphql" \
  "new-schema.graphql"

# With authentication headers (most production APIs require auth)
graphql-inspector diff \
  "http://api.example.com/graphql" \
  "new-schema.graphql" \
  --header "Authorization: Bearer $GRAPHQL_INTROSPECTION_TOKEN"

# Against the Apollo Router endpoint (which introspects the supergraph)
graphql-inspector diff \
  "http://router.internal/graphql" \
  "proposed-supergraph.graphql" \
  --header "X-Internal: true"
```

**Limitation:** Introspecting a live endpoint captures the currently deployed schema. If multiple teams are deploying changes simultaneously, the introspected schema may not reflect the true current state of the registry. For definitive checks in CI, use the schema file from the registry (fetched via `rover graph fetch`) rather than live introspection.

```bash
# Better practice: fetch from registry, then diff against local
rover graph fetch my-graph@main --output current-schema.graphql
graphql-inspector diff current-schema.graphql new-schema.graphql
```

---

## 5. GitHub Actions Integration

### Automated PR Diff Comment

```yaml
# .github/workflows/schema-diff.yml
name: Schema Diff

on:
  pull_request:
    paths:
      - '**.graphql'
      - 'subgraphs/**'

jobs:
  diff:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write  # Required to post PR comments
    steps:
      - uses: actions/checkout@v4
        with:
          # Fetch the base branch so we can compare against it
          fetch-depth: 0

      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - run: npm ci

      - name: Fetch base schema
        run: |
          # Check out the base branch version of the schema
          git show origin/${{ github.base_ref }}:schema/schema.graphql > /tmp/base-schema.graphql

      - name: Run schema diff
        id: diff
        run: |
          # Run diff and capture output; don't fail on breaking changes yet
          # (the next step will handle failure logic)
          set +e
          DIFF_OUTPUT=$(npx graphql-inspector diff \
            /tmp/base-schema.graphql \
            schema/schema.graphql \
            --format json 2>&1)
          DIFF_EXIT_CODE=$?
          set -e

          # Save output for the PR comment step
          echo "$DIFF_OUTPUT" > /tmp/diff-output.json
          echo "exit_code=$DIFF_EXIT_CODE" >> $GITHUB_OUTPUT

          # Parse breaking changes count for the summary
          BREAKING_COUNT=$(echo "$DIFF_OUTPUT" | \
            jq '[.[] | select(.criticality.level == "BREAKING")] | length' 2>/dev/null || echo "0")
          DANGEROUS_COUNT=$(echo "$DIFF_OUTPUT" | \
            jq '[.[] | select(.criticality.level == "DANGEROUS")] | length' 2>/dev/null || echo "0")
          echo "breaking_count=$BREAKING_COUNT" >> $GITHUB_OUTPUT
          echo "dangerous_count=$DANGEROUS_COUNT" >> $GITHUB_OUTPUT

      - name: Post diff as PR comment
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const diffJson = JSON.parse(fs.readFileSync('/tmp/diff-output.json', 'utf-8'));
            const breaking = diffJson.filter(c => c.criticality.level === 'BREAKING');
            const dangerous = diffJson.filter(c => c.criticality.level === 'DANGEROUS');
            const nonBreaking = diffJson.filter(c => c.criticality.level === 'NON_BREAKING');

            let body = '## GraphQL Schema Diff\n\n';

            if (breaking.length > 0) {
              body += `### Breaking Changes (${breaking.length})\n\n`;
              body += '> These changes will break existing clients.\n\n';
              breaking.forEach(c => {
                body += `- **BREAKING** ${c.message}\n`;
              });
              body += '\n';
            }

            if (dangerous.length > 0) {
              body += `### Dangerous Changes (${dangerous.length})\n\n`;
              body += '> These changes may cause unexpected behavior in clients.\n\n';
              dangerous.forEach(c => {
                body += `- **DANGEROUS** ${c.message}\n`;
              });
              body += '\n';
            }

            if (nonBreaking.length > 0) {
              body += `### Non-Breaking Changes (${nonBreaking.length})\n\n`;
              nonBreaking.forEach(c => {
                body += `- ${c.message}\n`;
              });
              body += '\n';
            }

            if (diffJson.length === 0) {
              body += 'No schema changes detected.\n';
            }

            // Find and update existing comment, or create a new one
            const { data: comments } = await github.rest.issues.listComments({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
            });

            const botComment = comments.find(c =>
              c.user.type === 'Bot' && c.body.includes('GraphQL Schema Diff')
            );

            if (botComment) {
              await github.rest.issues.updateComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                comment_id: botComment.id,
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

      - name: Fail on breaking changes
        # Block the PR if there are breaking changes.
        # Teams can override this by adding the 'approved-breaking-change' label
        # to the PR after getting explicit approval from the platform team.
        if: >
          steps.diff.outputs.breaking_count > 0 &&
          !contains(github.event.pull_request.labels.*.name, 'approved-breaking-change')
        run: |
          echo "PR contains ${{ steps.diff.outputs.breaking_count }} breaking schema changes."
          echo "Add the 'approved-breaking-change' label after getting platform team approval."
          exit 1
```

---

## 6. Pre-Commit Hook with Husky

For fast local feedback before CI runs:

```bash
# Install husky
npm install --save-dev husky
npx husky init
```

```bash
# .husky/pre-commit
#!/usr/bin/env sh
. "$(dirname -- "$0")/_/husky.sh"

# Only run if GraphQL schema files changed
CHANGED_SCHEMAS=$(git diff --cached --name-only | grep '\.graphql$')

if [ -z "$CHANGED_SCHEMAS" ]; then
  exit 0  # No schema changes, skip
fi

echo "GraphQL schema files changed. Running diff check..."

# Get the last committed version of the schema to compare against
git show HEAD:schema/schema.graphql > /tmp/committed-schema.graphql 2>/dev/null || {
  echo "No previous schema version found (first commit?). Skipping diff."
  exit 0
}

# Run diff — warn on DANGEROUS, block on BREAKING
DIFF_OUTPUT=$(npx graphql-inspector diff \
  /tmp/committed-schema.graphql \
  schema/schema.graphql \
  --format json 2>/dev/null)

BREAKING_COUNT=$(echo "$DIFF_OUTPUT" | \
  jq '[.[] | select(.criticality.level == "BREAKING")] | length' 2>/dev/null || echo "0")

DANGEROUS_COUNT=$(echo "$DIFF_OUTPUT" | \
  jq '[.[] | select(.criticality.level == "DANGEROUS")] | length' 2>/dev/null || echo "0")

if [ "$DANGEROUS_COUNT" -gt "0" ]; then
  echo ""
  echo "WARNING: This commit contains $DANGEROUS_COUNT dangerous schema change(s)."
  echo "Dangerous changes are allowed but require careful testing and client coordination."
  echo "$DIFF_OUTPUT" | jq -r '.[] | select(.criticality.level == "DANGEROUS") | "  - " + .message'
  echo ""
fi

if [ "$BREAKING_COUNT" -gt "0" ]; then
  echo ""
  echo "ERROR: This commit contains $BREAKING_COUNT breaking schema change(s)."
  echo "Breaking changes are blocked at the pre-commit stage."
  echo "To proceed:"
  echo "  1. Get approval from the GraphQL Platform Team"
  echo "  2. Open a schema RFC: https://github.com/org/repo/discussions/new"
  echo "  3. Use 'git commit --no-verify' ONLY with explicit written approval on file"
  echo ""
  echo "Breaking changes:"
  echo "$DIFF_OUTPUT" | jq -r '.[] | select(.criticality.level == "BREAKING") | "  - " + .message'
  exit 1
fi

echo "Schema diff: $DANGEROUS_COUNT dangerous, 0 breaking changes. Proceeding."
```

---

## 7. Output Formats — JSON for Programmatic Use

```bash
# Output as JSON for downstream processing
graphql-inspector diff old.graphql new.graphql --format json

# Example JSON output structure:
# [
#   {
#     "message": "Field 'Product.price' changed type from 'Float' to 'Money'",
#     "path": "Product.price",
#     "criticality": {
#       "level": "BREAKING",
#       "reason": "Changing the type of a field is a breaking change"
#     },
#     "type": "FIELD_TYPE_CHANGED",
#     "meta": {
#       "typeName": "Product",
#       "fieldName": "price",
#       "oldFieldType": "Float",
#       "newFieldType": "Money"
#     }
#   },
#   ...
# ]
```

### Using jq to Extract Breaking Changes

```bash
# Extract only breaking changes
graphql-inspector diff old.graphql new.graphql --format json | \
  jq '[.[] | select(.criticality.level == "BREAKING")]'

# Count by severity
graphql-inspector diff old.graphql new.graphql --format json | \
  jq 'group_by(.criticality.level) | map({level: .[0].criticality.level, count: length})'

# Extract all affected type names
graphql-inspector diff old.graphql new.graphql --format json | \
  jq -r '.[].meta.typeName // empty' | sort -u

# Output as Markdown table (useful for piping into Confluence or Slack)
graphql-inspector diff old.graphql new.graphql --format json | \
  jq -r '"| Severity | Change |",
         "| --- | --- |",
         (.[] | "| \(.criticality.level) | \(.message) |")'
```

### Integrating JSON Output into Custom Tooling

```typescript
// scripts/schema-change-reporter.ts
// Parses graphql-inspector diff JSON output and sends a Slack notification
// for any breaking or dangerous changes detected in CI.

import { execSync } from 'child_process';

interface SchemaChange {
  message: string;
  path: string;
  criticality: {
    level: 'BREAKING' | 'DANGEROUS' | 'NON_BREAKING';
    reason: string;
  };
  type: string;
}

const diffOutput = execSync(
  'npx graphql-inspector diff old.graphql new.graphql --format json',
  { encoding: 'utf-8' }
);

const changes: SchemaChange[] = JSON.parse(diffOutput);
const breaking = changes.filter((c) => c.criticality.level === 'BREAKING');
const dangerous = changes.filter((c) => c.criticality.level === 'DANGEROUS');

if (breaking.length > 0 || dangerous.length > 0) {
  const payload = {
    text: `GraphQL Schema Changes Detected in PR #${process.env.PR_NUMBER}`,
    blocks: [
      {
        type: 'section',
        text: {
          type: 'mrkdwn',
          text: `*Schema Diff for PR #${process.env.PR_NUMBER}*\n` +
            `Breaking: ${breaking.length} | Dangerous: ${dangerous.length}`,
        },
      },
      ...breaking.map((c) => ({
        type: 'section',
        text: {
          type: 'mrkdwn',
          text: `:red_circle: *BREAKING* ${c.message}`,
        },
      })),
      ...dangerous.map((c) => ({
        type: 'section',
        text: {
          type: 'mrkdwn',
          text: `:warning: *DANGEROUS* ${c.message}`,
        },
      })),
    ],
  };

  await fetch(process.env.SLACK_WEBHOOK_URL!, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
}
```

---

## Key Design Decisions

**Why use `--format json` rather than parsing text output:** Text output format is not versioned and may change between graphql-inspector releases. JSON output is structured data with a stable schema (per major version). Always use JSON format for any programmatic processing in scripts or CI pipelines.

**Why the pre-commit hook warns on DANGEROUS rather than blocking:** DANGEROUS changes (like adding an enum value) are sometimes intentional and unambiguously safe in the specific context. Blocking on dangerous changes would require frequent `--no-verify` overrides, which trains engineers to skip hooks. Warning prompts the engineer to think about the change without creating friction for the common case.

**Why post a PR comment rather than just failing the CI check:** A CI failure tells engineers "something is wrong." A PR comment tells engineers "here are the specific schema changes and their severity." The comment is actionable immediately without navigating to CI logs. Both the failure and the comment serve different purposes: the failure gates the merge, the comment provides information.

**Why block breaking changes at the pre-commit hook AND in CI:** Defense in depth. The pre-commit hook catches issues locally in seconds, before the code is pushed. The CI check catches issues that bypass the pre-commit hook (e.g., when using `--no-verify` or when the hook is not installed). Both layers are needed.

---

## Related Documentation

- `../../docs/10-schema-validation/` — Full schema validation pipeline combining graphql-inspector, Rover check, and custom lint rules
- `../../docs/09-schema-governance/` — Schema RFC process triggered by breaking change detection
- `../../docs/11-ci-cd-automation/` — Full CI/CD pipeline where the schema diff job fits into the broader deployment pipeline
