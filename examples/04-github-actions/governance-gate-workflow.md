# Governance Gate Workflow

> Companion documentation: `../../docs/10-schema-validation/`
> Related example: `schema-check-workflow.md` (structural checks), `schema-publish-workflow.md` (post-merge publish)

This document describes the schema governance enforcement workflow that runs as a required
status check on every pull request that modifies a GraphQL schema file. Governance checks
enforce organization-wide policies that are not captured by structural validation:

- **OPA policies** enforce custom rules written in Rego (naming conventions specific to your
  org, forbidden patterns, required directive usage).
- **Description audits** ensure every public type and field is documented before it merges.
- **Deprecation lifecycle** enforces that deprecated fields are removed after the agreed
  window (90 days by default).
- **Ownership checks** ensure every subgraph has a registered owner in CODEOWNERS, preventing
  orphaned schemas that have no team responsible for them.

---

## Workflow Overview

```
Pull Request opened / updated (schema files changed)
           |
           v
+---------------------+  +----------------------+  +---------------------+  +-------------------+
| Job 1:              |  | Job 2:               |  | Job 3:              |  | Job 4:            |
| opa-policy          |  | description-audit    |  | deprecation-check   |  | ownership-check   |
|                     |  |                      |  |                     |  |                   |
| OPA eval on SDL     |  | AST walk: count      |  | git log: find       |  | CODEOWNERS check  |
| diff using Rego     |  | undescribed types    |  | @deprecated > 90d   |  | for each changed  |
| policy file. Emit   |  | and fields. Fail if  |  | old. Fail if any    |  | subgraph. Fail if |
| GitHub annotations. |  | any are missing.     |  | past window.        |  | no owner entry.   |
+-----+---------------+  +----------+-----------+  +---------+-----------+  +--------+----------+
      |                             |                         |                       |
      +------- all run in parallel --------------------------------------------------------+
                                                                                     |
                                                                             all results collected
                                                                                     |
                                                                                     v
                                                              +------------------------------+
                                                              | Job 5: governance-summary    |
                                                              | (always: runs)               |
                                                              | Posts a single comment to PR |
                                                              | with consolidated results.   |
                                                              +------------------------------+
```

---

## Full Workflow YAML

```yaml
# .github/workflows/graphql-governance-gate.yml
#
# Required status check on all pull requests that modify GraphQL schema files.
# This workflow enforces governance policies that cannot be expressed as
# structural schema validation (naming conventions, documentation completeness,
# deprecation lifecycle, and ownership).

name: GraphQL Governance Gate

on:
  pull_request:
    types: [opened, synchronize, reopened]
    paths:
      # Only run governance checks when schema SDL files change.
      # Skipping on documentation or test changes reduces CI noise.
      - 'subgraphs/**/schema.graphql'
      - 'policies/schema-governance.rego'  # re-run if the policy itself changes
      - '.github/CODEOWNERS'               # re-run if ownership changes

# Allow at most one governance run per PR, cancelling older runs when new commits arrive.
# This prevents a queue of stale check runs from blocking the merge queue.
concurrency:
  group: governance-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  # ===========================================================================
  # JOB 1: OPA Policy Check
  # Evaluates the SDL diff against a Rego policy using Open Policy Agent.
  # The policy file (policies/schema-governance.rego) encodes org-specific rules
  # that cannot be expressed as graphql-eslint rules:
  #   - Requiring @tag directives on all types for contract variants
  #   - Forbidding PII-related field names without a @privacy directive
  #   - Requiring @authenticated on all Mutation fields
  #   - Custom naming patterns (e.g., all query fields must start with a verb)
  #
  # OPA violations are emitted as GitHub annotations (inline PR comments on the
  # specific line in the schema file that violates the policy).
  # ===========================================================================
  opa-policy:
    name: OPA Policy Check
    runs-on: ubuntu-latest
    outputs:
      violations: ${{ steps.opa.outputs.violations }}
      violation_count: ${{ steps.opa.outputs.violation_count }}

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          # Fetch the full history so we can diff against the base branch.
          fetch-depth: 0

      - name: Install OPA
        run: |
          # Pin the OPA version to avoid policy evaluation differences between CI runs.
          # OPA releases are at: https://github.com/open-policy-agent/opa/releases
          OPA_VERSION="v0.65.0"
          curl -sL "https://github.com/open-policy-agent/opa/releases/download/${OPA_VERSION}/opa_linux_amd64_static" \
            -o /usr/local/bin/opa
          chmod +x /usr/local/bin/opa
          opa version

      - name: Install Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '18'
          cache: npm

      - name: Install dependencies
        run: npm ci

      - name: Extract SDL diff as structured input for OPA
        id: extract-diff
        run: |
          # OPA operates on JSON input. We generate a JSON document that contains:
          #   - The full new SDL for each changed subgraph
          #   - The diff summary (added/removed/changed types and fields)
          #   - The PR metadata (PR number, author, changed files)
          #
          # This script uses graphql-inspector to parse the SDL into a JSON AST
          # that OPA can traverse with Rego rules.
          node scripts/generate-opa-input.js \
            --base-ref "${{ github.event.pull_request.base.sha }}" \
            --head-ref "${{ github.event.pull_request.head.sha }}" \
            --output /tmp/opa-input.json

          echo "OPA input generated:"
          cat /tmp/opa-input.json | jq 'keys'

      - name: Run OPA evaluation
        id: opa
        run: |
          # Evaluate the governance policy against the SDL input.
          # The policy returns a set of violation objects.
          # We use --format json to get structured output for parsing.
          opa eval \
            --input /tmp/opa-input.json \
            --data policies/schema-governance.rego \
            --format json \
            "data.graphql.governance.violations" \
            > /tmp/opa-result.json 2>&1

          OPA_EXIT=$?
          if [ $OPA_EXIT -ne 0 ]; then
            echo "ERROR: OPA evaluation failed (exit $OPA_EXIT)."
            cat /tmp/opa-result.json
            exit 1
          fi

          # Extract the violations array from the OPA result.
          # OPA result format: {"result": [{"expressions": [{"value": [...violations...]}]}]}
          VIOLATIONS=$(jq '.result[0].expressions[0].value // []' /tmp/opa-result.json)
          VIOLATION_COUNT=$(echo "$VIOLATIONS" | jq 'length')

          echo "violations=$(echo "$VIOLATIONS" | jq -c .)" >> "$GITHUB_OUTPUT"
          echo "violation_count=$VIOLATION_COUNT" >> "$GITHUB_OUTPUT"

          echo "OPA found $VIOLATION_COUNT violation(s)."

      - name: Emit GitHub annotations for OPA violations
        if: steps.opa.outputs.violation_count != '0'
        run: |
          # Emit each violation as a GitHub annotation.
          # Annotations appear as inline comments on the specific file and line
          # in the Files Changed tab of the pull request.
          #
          # GitHub annotation format:
          # ::error file={file},line={line},col={col}::{message}
          # ::warning file={file},line={line},col={col}::{message}
          VIOLATIONS='${{ steps.opa.outputs.violations }}'

          echo "$VIOLATIONS" | jq -c '.[]' | while read -r violation; do
            file=$(echo "$violation" | jq -r '.file // "unknown"')
            line=$(echo "$violation" | jq -r '.line // 1')
            severity=$(echo "$violation" | jq -r '.severity // "error"')
            message=$(echo "$violation" | jq -r '.message')
            rule=$(echo "$violation" | jq -r '.rule // "governance"')

            # Emit the annotation using the GitHub Actions workflow command syntax.
            echo "::${severity} file=${file},line=${line},title=Governance [${rule}]::${message}"
          done

          # Exit with failure if any error-level violations exist.
          ERROR_COUNT=$(echo "$VIOLATIONS" | jq '[.[] | select(.severity == "error")] | length')
          if [ "$ERROR_COUNT" -gt 0 ]; then
            echo "$ERROR_COUNT error-level governance violation(s) detected. Failing check."
            exit 1
          fi

  # ===========================================================================
  # JOB 2: Description Audit
  # Parses the GraphQL SDL using a Node.js AST walker and verifies that every
  # public (non-@inaccessible) type and field has a non-empty description.
  #
  # The Node.js script is inlined below as a heredoc and executed directly.
  # This avoids adding a file to the repository just for the CI check.
  # ===========================================================================
  description-audit:
    name: Description Audit
    runs-on: ubuntu-latest
    outputs:
      undescribed_count: ${{ steps.audit.outputs.undescribed_count }}
      undescribed_items: ${{ steps.audit.outputs.undescribed_items }}

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Install Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '18'
          cache: npm

      - name: Install dependencies
        run: npm ci

      - name: Run description audit
        id: audit
        run: |
          # Write the description audit script to a temp file and execute it.
          # This script uses the graphql package to parse the SDL and walk the AST.
          cat > /tmp/description-audit.js << 'EOF'
          #!/usr/bin/env node
          /**
           * description-audit.js
           *
           * Parses one or more GraphQL SDL files and reports any type definitions
           * or field definitions that are missing a description.
           *
           * A "description" in GraphQL SDL is the triple-quoted docstring that
           * appears above a type or field definition:
           *
           *   """
           *   This is the description.
           *   """
           *   type User { ... }
           *
           * The @inaccessible directive marks types/fields that are not exposed
           * to external clients (they are internal to the federation graph).
           * We skip those because they are implementation details and do not need
           * to appear in the public API documentation.
           */

          const fs = require('fs');
          const path = require('path');
          const { parse, visit } = require('graphql');

          // Read schema files from command-line arguments.
          const schemaFiles = process.argv.slice(2);

          if (schemaFiles.length === 0) {
            console.error('Usage: node description-audit.js <schema.graphql> [...]');
            process.exit(1);
          }

          const violations = [];

          for (const schemaFile of schemaFiles) {
            const sdl = fs.readFileSync(schemaFile, 'utf8');
            let document;

            try {
              document = parse(sdl);
            } catch (err) {
              console.error(`ERROR: Failed to parse ${schemaFile}: ${err.message}`);
              process.exit(1);
            }

            // Walk every node in the AST and check for missing descriptions.
            visit(document, {
              // Object type definitions (e.g., type User { ... })
              ObjectTypeDefinition(node) {
                // Skip @inaccessible types — they are not part of the public API.
                const isInaccessible = (node.directives || [])
                  .some(d => d.name.value === 'inaccessible');
                if (isInaccessible) return;

                // Skip built-in federation types (prefixed with "__" or starting
                // with "_Entity", "_Any", etc.).
                const typeName = node.name.value;
                if (typeName.startsWith('__') || typeName.startsWith('_')) return;

                // Check the type-level description.
                if (!node.description || !node.description.value.trim()) {
                  violations.push({
                    file: schemaFile,
                    line: node.loc ? node.loc.startToken.line : 0,
                    path: typeName,
                    kind: 'ObjectTypeDefinition',
                    message: `Type "${typeName}" is missing a description.`,
                  });
                }

                // Check each field on the type.
                for (const field of node.fields || []) {
                  // Skip @inaccessible fields.
                  const fieldIsInaccessible = (field.directives || [])
                    .some(d => d.name.value === 'inaccessible');
                  if (fieldIsInaccessible) continue;

                  if (!field.description || !field.description.value.trim()) {
                    violations.push({
                      file: schemaFile,
                      line: field.loc ? field.loc.startToken.line : 0,
                      path: `${typeName}.${field.name.value}`,
                      kind: 'FieldDefinition',
                      message: `Field "${typeName}.${field.name.value}" is missing a description.`,
                    });
                  }
                }
              },

              // Interface type definitions
              InterfaceTypeDefinition(node) {
                const typeName = node.name.value;
                if (!node.description || !node.description.value.trim()) {
                  violations.push({
                    file: schemaFile,
                    line: node.loc ? node.loc.startToken.line : 0,
                    path: typeName,
                    kind: 'InterfaceTypeDefinition',
                    message: `Interface "${typeName}" is missing a description.`,
                  });
                }

                for (const field of node.fields || []) {
                  if (!field.description || !field.description.value.trim()) {
                    violations.push({
                      file: schemaFile,
                      line: field.loc ? field.loc.startToken.line : 0,
                      path: `${typeName}.${field.name.value}`,
                      kind: 'FieldDefinition',
                      message: `Interface field "${typeName}.${field.name.value}" is missing a description.`,
                    });
                  }
                }
              },

              // Enum type definitions
              EnumTypeDefinition(node) {
                const typeName = node.name.value;
                // Skip built-in enums.
                if (typeName.startsWith('__')) return;

                if (!node.description || !node.description.value.trim()) {
                  violations.push({
                    file: schemaFile,
                    line: node.loc ? node.loc.startToken.line : 0,
                    path: typeName,
                    kind: 'EnumTypeDefinition',
                    message: `Enum "${typeName}" is missing a description.`,
                  });
                }

                for (const value of node.values || []) {
                  if (!value.description || !value.description.value.trim()) {
                    violations.push({
                      file: schemaFile,
                      line: value.loc ? value.loc.startToken.line : 0,
                      path: `${typeName}.${value.name.value}`,
                      kind: 'EnumValueDefinition',
                      message: `Enum value "${typeName}.${value.name.value}" is missing a description.`,
                    });
                  }
                }
              },

              // Input object type definitions
              InputObjectTypeDefinition(node) {
                const typeName = node.name.value;
                if (!node.description || !node.description.value.trim()) {
                  violations.push({
                    file: schemaFile,
                    line: node.loc ? node.loc.startToken.line : 0,
                    path: typeName,
                    kind: 'InputObjectTypeDefinition',
                    message: `Input type "${typeName}" is missing a description.`,
                  });
                }

                for (const field of node.fields || []) {
                  if (!field.description || !field.description.value.trim()) {
                    violations.push({
                      file: schemaFile,
                      line: field.loc ? field.loc.startToken.line : 0,
                      path: `${typeName}.${field.name.value}`,
                      kind: 'InputValueDefinition',
                      message: `Input field "${typeName}.${field.name.value}" is missing a description.`,
                    });
                  }
                }
              },
            });
          }

          // Output results.
          if (violations.length === 0) {
            console.log('Description audit passed. All public types and fields have descriptions.');
            process.exit(0);
          }

          console.error(`Description audit found ${violations.length} undescribed item(s):\n`);
          for (const v of violations) {
            // Emit GitHub annotation for each violation.
            console.log(`::error file=${v.file},line=${v.line}::${v.message}`);
          }

          // Output the violations as JSON for the summary job.
          fs.writeFileSync('/tmp/description-violations.json', JSON.stringify(violations, null, 2));

          process.exit(1);
          EOF

          # Find all changed schema files in this PR.
          CHANGED_SCHEMAS=$(git diff --name-only origin/${{ github.base_ref }}...HEAD \
            | grep -E 'subgraphs/.*/schema\.graphql$' || true)

          if [ -z "$CHANGED_SCHEMAS" ]; then
            echo "No changed schema files found."
            echo "undescribed_count=0" >> "$GITHUB_OUTPUT"
            echo "undescribed_items=[]" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          echo "Auditing: $CHANGED_SCHEMAS"

          # Run the audit script. node exits 1 if violations exist.
          if ! node /tmp/description-audit.js $CHANGED_SCHEMAS; then
            VIOLATIONS=$(cat /tmp/description-violations.json 2>/dev/null || echo '[]')
            COUNT=$(echo "$VIOLATIONS" | jq 'length')
            echo "undescribed_count=$COUNT" >> "$GITHUB_OUTPUT"
            echo "undescribed_items=$(echo "$VIOLATIONS" | jq -c .)" >> "$GITHUB_OUTPUT"
            exit 1
          fi

          echo "undescribed_count=0" >> "$GITHUB_OUTPUT"
          echo "undescribed_items=[]" >> "$GITHUB_OUTPUT"

  # ===========================================================================
  # JOB 3: Deprecation Lifecycle Check
  # Uses git log to find fields that were marked @deprecated more than 90 days
  # ago and verifies that they have been removed by now. If a deprecated field
  # has outlived its deprecation window, the PR cannot merge until the field
  # is removed (or the window is extended with documented justification).
  #
  # The 90-day window is configurable via the DEPRECATION_WINDOW_DAYS variable.
  # ===========================================================================
  deprecation-check:
    name: Deprecation Lifecycle Check
    runs-on: ubuntu-latest
    outputs:
      expired_count: ${{ steps.deprecation.outputs.expired_count }}
      expired_fields: ${{ steps.deprecation.outputs.expired_fields }}

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          # Fetch full history to enable git log date queries.
          fetch-depth: 0

      - name: Check for expired deprecations
        id: deprecation
        run: |
          #!/usr/bin/env bash
          # Find all @deprecated fields in the current schema and determine when
          # they were first deprecated by searching git history.

          DEPRECATION_WINDOW_DAYS=90
          CUTOFF_DATE=$(date -d "-${DEPRECATION_WINDOW_DAYS} days" +%Y-%m-%d 2>/dev/null \
            || date -v "-${DEPRECATION_WINDOW_DAYS}d" +%Y-%m-%d)  # macOS fallback

          echo "Deprecation window: ${DEPRECATION_WINDOW_DAYS} days"
          echo "Checking for @deprecated fields added before: $CUTOFF_DATE"

          EXPIRED_FIELDS=()

          # Find all schema files (not just changed ones — expired deprecations
          # in any subgraph should block the PR to force a cleanup conversation).
          for schema_file in subgraphs/*/schema.graphql; do
            subgraph=$(dirname "$schema_file" | xargs basename)

            # Extract all @deprecated field names from the current schema.
            # The grep pattern matches lines like:
            #   fieldName: SomeType @deprecated(reason: "...")
            #   fieldName: SomeType! @deprecated
            DEPRECATED_FIELDS=$(grep -n '@deprecated' "$schema_file" \
              | grep -oE '^[0-9]+:[ ]+([a-zA-Z_][a-zA-Z0-9_]*)' \
              | sed 's/^[0-9]*:[ ]*//' \
              || true)

            for field_name in $DEPRECATED_FIELDS; do
              # Find the first commit that added @deprecated to this field.
              # git log --all --diff-filter=A: only commits that added lines.
              # -S"${field_name}.*@deprecated": search for the specific field+directive.
              # --format="%ai": output ISO 8601 date of the commit.
              FIRST_DEPRECATION_DATE=$(git log \
                --all \
                --diff-filter=M \
                --format="%ai" \
                -S "${field_name}.*@deprecated" \
                -- "$schema_file" \
                | tail -1 \
                | cut -d' ' -f1)

              if [ -z "$FIRST_DEPRECATION_DATE" ]; then
                # Could not find when the deprecation was added.
                # This can happen for fields deprecated before this repo's git history.
                # Skip with a warning — do not fail, as we cannot be certain.
                echo "Warning: could not determine deprecation date for ${subgraph}.${field_name}"
                continue
              fi

              # Compare the deprecation date to the cutoff.
              # If the field was deprecated before the cutoff date, it has expired.
              if [[ "$FIRST_DEPRECATION_DATE" < "$CUTOFF_DATE" ]]; then
                echo "EXPIRED: ${subgraph}.${field_name} deprecated on ${FIRST_DEPRECATION_DATE} (>${DEPRECATION_WINDOW_DAYS} days ago)"
                EXPIRED_FIELDS+=("${subgraph}.${field_name} (deprecated: ${FIRST_DEPRECATION_DATE})")
              else
                echo "OK: ${subgraph}.${field_name} deprecated on ${FIRST_DEPRECATION_DATE}"
              fi
            done
          done

          EXPIRED_COUNT=${#EXPIRED_FIELDS[@]}
          echo "expired_count=$EXPIRED_COUNT" >> "$GITHUB_OUTPUT"

          # Serialize the expired fields list as a JSON array for the summary job.
          EXPIRED_JSON=$(printf '%s\n' "${EXPIRED_FIELDS[@]}" | jq -R . | jq -sc .)
          echo "expired_fields=$EXPIRED_JSON" >> "$GITHUB_OUTPUT"

          if [ "$EXPIRED_COUNT" -gt 0 ]; then
            echo ""
            echo "FAILURE: $EXPIRED_COUNT deprecated field(s) have exceeded the ${DEPRECATION_WINDOW_DAYS}-day removal window:"
            for field in "${EXPIRED_FIELDS[@]}"; do
              echo "  - $field"
            done
            echo ""
            echo "Remove these fields in this PR or open a dedicated cleanup PR before merging."
            exit 1
          fi

          echo "All deprecations are within the ${DEPRECATION_WINDOW_DAYS}-day window."

  # ===========================================================================
  # JOB 4: Ownership Check
  # Verifies that every subgraph that has a changed schema.graphql also has a
  # corresponding entry in .github/CODEOWNERS.
  #
  # Rationale: Without CODEOWNERS entries, schema changes have no required
  # reviewer — any contributor can merge schema changes to a subgraph they
  # do not own. This prevents unilateral API changes without team review.
  #
  # CODEOWNERS entry format expected:
  #   subgraphs/users/  @my-org/users-team
  # ===========================================================================
  ownership-check:
    name: Ownership Check
    runs-on: ubuntu-latest
    outputs:
      unowned_count: ${{ steps.ownership.outputs.unowned_count }}
      unowned_subgraphs: ${{ steps.ownership.outputs.unowned_subgraphs }}

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Check CODEOWNERS coverage
        id: ownership
        run: |
          #!/usr/bin/env bash
          # Find changed subgraphs and verify each has a CODEOWNERS entry.

          CODEOWNERS_FILE=".github/CODEOWNERS"
          UNOWNED=()

          if [ ! -f "$CODEOWNERS_FILE" ]; then
            echo "ERROR: $CODEOWNERS_FILE does not exist."
            echo "All subgraphs must have ownership entries in CODEOWNERS."
            exit 1
          fi

          # Find subgraphs with changed schema files in this PR.
          CHANGED_SUBGRAPHS=$(git diff --name-only origin/${{ github.base_ref }}...HEAD \
            | grep -E '^subgraphs/[^/]+/schema\.graphql$' \
            | sed 's|subgraphs/\([^/]*\)/schema\.graphql|\1|' \
            | sort -u || true)

          if [ -z "$CHANGED_SUBGRAPHS" ]; then
            echo "No changed subgraphs found."
            echo "unowned_count=0" >> "$GITHUB_OUTPUT"
            echo "unowned_subgraphs=[]" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          for subgraph in $CHANGED_SUBGRAPHS; do
            # Check if there is a CODEOWNERS entry that covers subgraphs/<name>/.
            # Accepted patterns:
            #   subgraphs/users/  @team         (trailing slash, covers all files)
            #   subgraphs/users/schema.graphql  @team  (specific file)
            #   subgraphs/users/**  @team        (glob pattern)
            #   subgraphs/*  @team               (wildcard for all subgraphs — acceptable)
            if grep -qE "^subgraphs/${subgraph}[/ ]|^subgraphs/\*|^subgraphs/\*\*" \
                "$CODEOWNERS_FILE"; then
              # Found a matching entry. Extract the owner for display.
              OWNER=$(grep -E "^subgraphs/${subgraph}[/ ]" "$CODEOWNERS_FILE" \
                | awk '{print $2}' | head -1)
              echo "OK: subgraphs/${subgraph} owned by ${OWNER:-<wildcard match>}"
            else
              echo "MISSING: subgraphs/${subgraph} has no CODEOWNERS entry."
              UNOWNED+=("$subgraph")
            fi
          done

          UNOWNED_COUNT=${#UNOWNED[@]}
          echo "unowned_count=$UNOWNED_COUNT" >> "$GITHUB_OUTPUT"

          UNOWNED_JSON=$(printf '%s\n' "${UNOWNED[@]}" | jq -R . | jq -sc .)
          echo "unowned_subgraphs=$UNOWNED_JSON" >> "$GITHUB_OUTPUT"

          if [ "$UNOWNED_COUNT" -gt 0 ]; then
            echo ""
            echo "FAILURE: The following subgraphs have no CODEOWNERS entry:"
            for sub in "${UNOWNED[@]}"; do
              echo "  - subgraphs/${sub}/"
              echo "    Add to .github/CODEOWNERS: subgraphs/${sub}/  @your-org/your-team"
            done
            exit 1
          fi

          echo "All changed subgraphs have CODEOWNERS entries."

  # ===========================================================================
  # JOB 5: Governance Summary
  # Always runs (even if upstream jobs fail) and posts a single consolidated
  # comment to the PR with results from all four governance checks.
  #
  # This replaces four separate status check comments with one structured
  # summary, reducing PR comment noise while still providing actionable detail.
  #
  # The comment is upserted: if a previous governance comment exists (from a
  # prior commit push), it is updated in place rather than posting a new one.
  # ===========================================================================
  governance-summary:
    name: Governance Summary
    needs: [opa-policy, description-audit, deprecation-check, ownership-check]
    # always() ensures this job runs even if upstream jobs fail.
    # Without always(), a failed upstream job would skip this job, meaning
    # no summary comment would be posted when checks fail.
    if: always()
    runs-on: ubuntu-latest

    steps:
      - name: Post governance summary comment
        uses: actions/github-script@v7
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            // Collect results from upstream jobs.
            // needs.*.result is 'success', 'failure', 'skipped', or 'cancelled'.
            const results = {
              opa: {
                result: '${{ needs.opa-policy.result }}',
                violationCount: parseInt('${{ needs.opa-policy.outputs.violation_count }}' || '0'),
              },
              descriptions: {
                result: '${{ needs.description-audit.result }}',
                undescribedCount: parseInt('${{ needs.description-audit.outputs.undescribed_count }}' || '0'),
                items: JSON.parse('${{ needs.description-audit.outputs.undescribed_items }}' || '[]'),
              },
              deprecation: {
                result: '${{ needs.deprecation-check.result }}',
                expiredCount: parseInt('${{ needs.deprecation-check.outputs.expired_count }}' || '0'),
                fields: JSON.parse('${{ needs.deprecation-check.outputs.expired_fields }}' || '[]'),
              },
              ownership: {
                result: '${{ needs.ownership-check.result }}',
                unownedCount: parseInt('${{ needs.ownership-check.outputs.unowned_count }}' || '0'),
                subgraphs: JSON.parse('${{ needs.ownership-check.outputs.unowned_subgraphs }}' || '[]'),
              },
            };

            const allPassed = Object.values(results).every(r => r.result === 'success');
            const statusEmoji = allPassed ? 'PASSED' : 'FAILED';

            // Build the markdown comment body.
            let body = `## GraphQL Governance Gate: ${statusEmoji}\n\n`;
            body += `| Check | Status | Detail |\n`;
            body += `|-------|--------|--------|\n`;

            // OPA Policy row
            const opaIcon = results.opa.result === 'success' ? 'pass' : 'FAIL';
            body += `| OPA Policy | ${opaIcon} | ${results.opa.violationCount} violation(s) |\n`;

            // Description Audit row
            const descIcon = results.descriptions.result === 'success' ? 'pass' : 'FAIL';
            body += `| Description Audit | ${descIcon} | ${results.descriptions.undescribedCount} undescribed item(s) |\n`;

            // Deprecation Check row
            const deprIcon = results.deprecation.result === 'success' ? 'pass' : 'FAIL';
            body += `| Deprecation Lifecycle | ${deprIcon} | ${results.deprecation.expiredCount} expired deprecation(s) |\n`;

            // Ownership Check row
            const ownIcon = results.ownership.result === 'success' ? 'pass' : 'FAIL';
            body += `| Ownership | ${ownIcon} | ${results.ownership.unownedCount} unowned subgraph(s) |\n`;

            body += `\n`;

            // Add detail sections for failures.
            if (results.descriptions.undescribedCount > 0) {
              body += `### Description Audit Failures\n\n`;
              body += `The following types/fields are missing descriptions. Add a triple-quoted docstring above each.\n\n`;
              for (const item of results.descriptions.items.slice(0, 20)) {
                body += `- \`${item.path}\` in \`${item.file}\` (line ${item.line})\n`;
              }
              if (results.descriptions.items.length > 20) {
                body += `\n...and ${results.descriptions.items.length - 20} more. See the job log for the full list.\n`;
              }
              body += `\n`;
            }

            if (results.deprecation.expiredCount > 0) {
              body += `### Expired Deprecations\n\n`;
              body += `The following fields were deprecated more than 90 days ago and must be removed:\n\n`;
              for (const field of results.deprecation.fields) {
                body += `- \`${field}\`\n`;
              }
              body += `\nTo resolve: remove these fields in this PR or open a dedicated cleanup PR.\n\n`;
            }

            if (results.ownership.unownedCount > 0) {
              body += `### Missing CODEOWNERS Entries\n\n`;
              body += `Add the following entries to \`.github/CODEOWNERS\`:\n\n\`\`\`\n`;
              for (const sub of results.ownership.subgraphs) {
                body += `subgraphs/${sub}/  @your-org/your-team\n`;
              }
              body += `\`\`\`\n\n`;
            }

            body += `---\n`;
            body += `*Governance Gate run: [View full logs](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }})*`;

            // Find existing governance comment on this PR (from previous commits).
            const { data: comments } = await github.rest.issues.listComments({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
            });

            const existingComment = comments.find(c =>
              c.user.login === 'github-actions[bot]' &&
              c.body.includes('GraphQL Governance Gate:')
            );

            if (existingComment) {
              // Update the existing comment instead of posting a new one.
              // This keeps the PR timeline clean when multiple commits are pushed.
              await github.rest.issues.updateComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                comment_id: existingComment.id,
                body: body,
              });
              console.log(`Updated existing governance comment (ID: ${existingComment.id})`);
            } else {
              // Post a new comment.
              await github.rest.issues.createComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                issue_number: context.issue.number,
                body: body,
              });
              console.log('Posted new governance comment.');
            }
```

---

## OPA Policy File Reference

The Rego policy at `policies/schema-governance.rego` is evaluated in Job 1. Below is a
representative policy showing the patterns used. Extend this file for your organization's
specific rules.

```rego
# policies/schema-governance.rego
#
# GraphQL schema governance policy for OPA.
# Input: JSON document generated by scripts/generate-opa-input.js
# Output: data.graphql.governance.violations — an array of violation objects.

package graphql.governance

import future.keywords.in

# The violations set collects all policy violations found in the input.
# OPA evaluates all rules and unions the results into a single set.
violations[violation] {
  # Rule: All Mutation fields must have @authenticated directive.
  # Mutations without @authenticated are accessible to unauthenticated clients,
  # which is almost never intentional.
  mutation_field := input.schema.mutations[_]
  not has_directive(mutation_field, "authenticated")
  violation := {
    "rule": "require-authenticated-on-mutations",
    "severity": "error",
    "file": mutation_field.file,
    "line": mutation_field.line,
    "message": sprintf(
      "Mutation field '%v' is missing @authenticated directive. All mutations require authentication.",
      [mutation_field.name]
    ),
  }
}

violations[violation] {
  # Rule: Field names must not contain PII indicators without a @privacy directive.
  # Fields named "ssn", "creditCardNumber", "password", etc. must be tagged with
  # @privacy(level: "sensitive") to ensure they are handled appropriately in
  # logging, caching, and persisted query stores.
  pii_patterns := ["ssn", "socialSecurity", "creditCard", "password", "secret", "token", "privateKey"]
  field := input.schema.fields[_]
  some pii_pattern in pii_patterns
  contains(lower(field.name), lower(pii_pattern))
  not has_directive(field, "privacy")
  violation := {
    "rule": "pii-requires-privacy-directive",
    "severity": "error",
    "file": field.file,
    "line": field.line,
    "message": sprintf(
      "Field '%v.%v' appears to contain PII (matches pattern '%v') but has no @privacy directive.",
      [field.parent_type, field.name, pii_pattern]
    ),
  }
}

violations[violation] {
  # Rule: Query fields must start with a verb (get, list, search, find, count).
  # This is a naming convention that makes the query API self-describing.
  # "user" as a query field is ambiguous; "getUser" or "listUsers" is clear.
  valid_prefixes := ["get", "list", "search", "find", "count", "fetch"]
  query_field := input.schema.queries[_]
  not any_prefix(query_field.name, valid_prefixes)
  violation := {
    "rule": "query-field-verb-prefix",
    "severity": "warning",  # warning not error — existing fields are grandfathered
    "file": query_field.file,
    "line": query_field.line,
    "message": sprintf(
      "Query field '%v' should start with a verb (get, list, search, find, count, fetch).",
      [query_field.name]
    ),
  }
}

# Helper: check if a node has a specific directive.
has_directive(node, directive_name) {
  node.directives[_].name == directive_name
}

# Helper: check if a string starts with any of the given prefixes.
any_prefix(s, prefixes) {
  some prefix in prefixes
  startswith(s, prefix)
}
```

---

## Required Status Check Configuration

To make the governance gate a required status check, add the following to the repository's
branch protection rules for `main`:

1. Go to Settings > Branches > Branch protection rules > Edit (or Add rule for `main`).
2. Enable "Require status checks to pass before merging".
3. Add the following check names (these match the `name:` fields in the workflow jobs):
   - `OPA Policy Check`
   - `Description Audit`
   - `Deprecation Lifecycle Check`
   - `Ownership Check`
   - `Governance Summary`
4. Enable "Require branches to be up to date before merging".

Note: `Governance Summary` must be in the required checks list even though it `always()` runs,
because GitHub requires the check to be green (not just present). The summary job exits
0 (success) even when individual checks fail — it is an informational aggregator, not a gate
itself. The individual job checks are the actual gates.

---

## Key Design Decisions

**Why OPA for policy enforcement rather than more graphql-eslint rules.** graphql-eslint rules
are designed for structural GraphQL concerns. Org-specific policies (e.g., "all mutations need
@authenticated", "PII fields need @privacy") involve cross-cutting concerns and custom
directives that are cumbersome to express as ESLint rules. OPA Rego is a purpose-built policy
language that can express these rules as data-driven queries over a JSON representation of the
SDL. The policy file can be updated by a governance team without touching the CI configuration.

**Why the Node.js description audit script runs at PR time rather than as a lint rule.** The
graphql-eslint `require-description` rule is already configured (see
`../03-schema-validation/graphql-eslint-config.md`) and catches missing descriptions at lint
time. The description audit in this workflow provides a second check specifically on the diff
— it counts undescribed items in changed files and fails if any exist, even if the ESLint
config was accidentally bypassed. Defense in depth.

**Why the deprecation check scans all subgraphs, not just changed ones.** A PR that modifies
one subgraph provides an opportunity to catch expired deprecations in other subgraphs that
have been overlooked. This "scan all on any change" approach creates a forcing function to
clean up technical debt regularly rather than letting it accumulate indefinitely.

**Why the governance summary uses comment upsert rather than always posting new comments.**
A PR that has many commits (common in rebased feature branches) would accumulate many
governance check comments over its lifetime, making the PR timeline noisy and difficult to
review. Upsert (update-or-create) ensures there is always exactly one governance comment
on the PR, reflecting the current state of the latest commit.

---

## Related Documentation

- `../../docs/10-schema-validation/` — Validation pipeline design and governance rationale
- `../../docs/12-schema-evolution/` — Deprecation policy, field lifecycle, removal process
- `schema-check-workflow.md` — Structural check workflow (runs in parallel with governance)
- `schema-publish-workflow.md` — Post-merge publish workflow (runs after governance passes)
- `../../examples/03-schema-validation/graphql-eslint-config.md` — Lint rules (pre-commit complement to governance gate)
- `../../examples/07-opa-policies/` — Extended OPA policy examples and testing patterns
