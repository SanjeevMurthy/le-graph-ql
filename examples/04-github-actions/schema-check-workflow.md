# Schema Check Workflow — Production Example

Complete, production-ready GitHub Actions workflow for GraphQL schema checking on pull requests.
Covers four jobs in sequence: lint → Rover subgraph check → local composition verify →
breaking-change gate with approval-label bypass.

Companion doc: [docs/12-github-actions/02-schema-check-workflow.md](../../docs/12-github-actions/02-schema-check-workflow.md)

---

## Workflow File

```yaml
# .github/workflows/graphql-schema-check.yml
#
# Schema Check — runs on every PR that touches schema or resolver files.
# Four sequential jobs gate the merge:
#   1. schema-lint      — graphql-eslint naming/description/nullability rules
#   2. schema-check     — rover subgraph check against @staging (async, polled)
#   3. composition-check — rover compose locally to verify supergraph composes
#   4. breaking-change-gate — fail if BREAKING changes found and no approval label
#
# Required secrets:
#   APOLLO_KEY — Apollo service API key (graph-scoped, not org-scoped)
#
# Required variables:
#   APOLLO_GRAPH_REF — e.g. my-supergraph@staging
#   APOLLO_GRAPH_ID  — e.g. my-supergraph (for Studio links)

name: GraphQL Schema Check

on:
  pull_request:
    branches:
      - main
    paths:
      - 'schema/**'
      - 'subgraphs/**/schema.graphql'
      - 'src/**/*.graphql'
      - 'src/**/*.ts'

# Cancel superseded runs when a new commit lands on the same PR branch.
# Use the PR number so distinct PRs don't cancel each other.
concurrency:
  group: schema-check-${{ github.event.pull_request.number }}
  cancel-in-progress: true

env:
  ROVER_VERSION: "0.27.0"
  # APOLLO_KEY is injected per-job from secrets to minimize exposure surface.
  APOLLO_GRAPH_REF: ${{ vars.APOLLO_GRAPH_REF }}
  APOLLO_GRAPH_ID: ${{ vars.APOLLO_GRAPH_ID }}

# ─────────────────────────────────────────────────────────────────────────────
# JOB 1: Lint all changed .graphql and .ts files with graphql-eslint
# ─────────────────────────────────────────────────────────────────────────────
jobs:
  schema-lint:
    name: Schema Lint
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
      pull-requests: write   # post lint violation comment

    steps:
      - name: Checkout PR branch
        uses: actions/checkout@v4
        with:
          fetch-depth: 2     # need HEAD and HEAD~1 for diff

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install lint dependencies
        run: |
          npm install --save-dev \
            @graphql-eslint/eslint-plugin@3 \
            eslint@8 \
            graphql@16
        env:
          NPM_CONFIG_FUND: "false"
          NPM_CONFIG_AUDIT: "false"

      - name: Run graphql-eslint
        id: lint
        run: |
          set +e
          npx eslint \
            --ext .graphql \
            --format json \
            --output-file lint-results.json \
            subgraphs/ schema/ 2>&1
          LINT_EXIT=$?
          set -e

          # Emit workflow annotations for each violation
          if [[ -f lint-results.json ]]; then
            node - <<'EOF'
          const results = require('./lint-results.json');
          for (const file of results) {
            for (const msg of file.messages) {
              const level = msg.severity === 2 ? 'error' : 'warning';
              // Trim repo root from path so annotation links correctly in Files Changed tab
              const relPath = file.filePath.replace(process.cwd() + '/', '');
              process.stdout.write(
                `::${level} file=${relPath},line=${msg.line},col=${msg.column}::${msg.message}\n`
              );
            }
          }
          EOF
          fi

          exit $LINT_EXIT

      - name: Upload lint results artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: lint-results
          path: lint-results.json
          retention-days: 7

  # ─────────────────────────────────────────────────────────────────────────────
  # JOB 2: rover subgraph check — async with polling for completion
  # ─────────────────────────────────────────────────────────────────────────────
  schema-check:
    name: Rover Subgraph Check
    needs: schema-lint
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
      pull-requests: write
      checks: write

    # Dynamic matrix: discover all subgraph directories automatically
    strategy:
      fail-fast: false   # check all subgraphs even if one fails
      matrix:
        subgraph: ${{ fromJSON(needs.schema-lint.outputs.subgraph_matrix || '["users","products","orders"]') }}

    outputs:
      has_breaking: ${{ steps.check.outputs.has_breaking }}
      check_url: ${{ steps.check.outputs.check_url }}

    steps:
      - name: Checkout PR branch
        uses: actions/checkout@v4

      - name: Cache Rover binary
        id: rover-cache
        uses: actions/cache@v4
        with:
          path: ~/.rover/bin
          key: rover-linux-${{ env.ROVER_VERSION }}
          restore-keys: |
            rover-linux-

      - name: Install Rover
        if: steps.rover-cache.outputs.cache-hit != 'true'
        run: |
          curl -sSL "https://rover.apollo.dev/nix/v${{ env.ROVER_VERSION }}" | sh
        env:
          ROVER_ELIXIR_SKIP_INSTALL: "true"

      - name: Add Rover to PATH
        run: echo "$HOME/.rover/bin" >> "$GITHUB_PATH"

      - name: Discover subgraph directories (populate matrix on first run)
        id: discover
        run: |
          # Emit the list of subgraph directories as JSON for subsequent matrix runs.
          # Only subgraphs whose schema.graphql changed in this PR are included.
          CHANGED=$(git diff --name-only origin/main...HEAD \
            -- 'subgraphs/**/schema.graphql' | \
            grep -oP 'subgraphs/\K[^/]+' | sort -u | \
            jq -R . | jq -sc . || echo '[]')

          echo "changed_subgraphs=${CHANGED}" >> "$GITHUB_OUTPUT"

          # Fall back to the matrix value if discovery produces nothing
          # (happens when the matrix is pre-populated via workflow input)
          echo "subgraph=${{ matrix.subgraph }}" >> "$GITHUB_OUTPUT"

      - name: Run rover subgraph check (async background mode)
        id: check-async
        env:
          APOLLO_KEY: ${{ secrets.APOLLO_KEY }}
        run: |
          set -euo pipefail

          SUBGRAPH="${{ matrix.subgraph }}"
          SCHEMA_PATH="subgraphs/${SUBGRAPH}/schema.graphql"

          if [[ ! -f "${SCHEMA_PATH}" ]]; then
            echo "schema not found at ${SCHEMA_PATH} — skipping"
            echo "skipped=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          echo "Running rover subgraph check for: ${SUBGRAPH}"

          # --background flag submits the check asynchronously and returns
          # immediately with a check ID. We poll for the result below.
          # This prevents the job from blocking on Apollo GraphOS processing time.
          CHECK_OUTPUT=$(rover subgraph check "${APOLLO_GRAPH_REF}" \
            --name "${SUBGRAPH}" \
            --schema "${SCHEMA_PATH}" \
            --background \
            --output json 2>&1) || CHECK_EXIT=$?

          echo "Rover output:"
          echo "${CHECK_OUTPUT}" | jq . 2>/dev/null || echo "${CHECK_OUTPUT}"

          # Extract the check workflow task ID for polling
          TASK_ID=$(echo "${CHECK_OUTPUT}" | \
            jq -r '.data.graph.checkPartialSchema.launched.id // empty' 2>/dev/null || echo "")

          if [[ -z "${TASK_ID}" ]]; then
            # Background mode not available or check failed immediately
            echo "task_id=" >> "$GITHUB_OUTPUT"
            echo "immediate_result=true" >> "$GITHUB_OUTPUT"
            echo "${CHECK_OUTPUT}" > rover-check-result.json
          else
            echo "task_id=${TASK_ID}" >> "$GITHUB_OUTPUT"
            echo "immediate_result=false" >> "$GITHUB_OUTPUT"
          fi

          echo "subgraph=${SUBGRAPH}" >> "$GITHUB_OUTPUT"

      - name: Poll for async check completion
        id: poll
        if: steps.check-async.outputs.immediate_result == 'false'
        env:
          APOLLO_KEY: ${{ secrets.APOLLO_KEY }}
        run: |
          set -euo pipefail

          TASK_ID="${{ steps.check-async.outputs.task_id }}"
          MAX_WAIT=600   # 10 minutes maximum
          ELAPSED=0
          POLL_INTERVAL=10

          echo "Polling for check task ${TASK_ID} (max ${MAX_WAIT}s)..."

          while [[ $ELAPSED -lt $MAX_WAIT ]]; do
            STATUS_OUTPUT=$(rover subgraph check "${APOLLO_GRAPH_REF}" \
              --check-timeout "$((MAX_WAIT - ELAPSED))" \
              --output json 2>&1) || true

            STATUS=$(echo "${STATUS_OUTPUT}" | jq -r '.data.graph.checkWorkflow.status // "PENDING"' 2>/dev/null || echo "PENDING")

            echo "[${ELAPSED}s] Check status: ${STATUS}"

            if [[ "${STATUS}" == "PASSED" || "${STATUS}" == "FAILED" ]]; then
              echo "${STATUS_OUTPUT}" > rover-check-result.json
              echo "status=${STATUS}" >> "$GITHUB_OUTPUT"
              break
            fi

            sleep $POLL_INTERVAL
            ELAPSED=$((ELAPSED + POLL_INTERVAL))
          done

          if [[ $ELAPSED -ge $MAX_WAIT ]]; then
            echo "::error::Schema check timed out after ${MAX_WAIT}s"
            exit 1
          fi

      - name: Parse check results and set outputs
        id: check
        run: |
          set -euo pipefail

          if [[ ! -f rover-check-result.json ]]; then
            echo "No check result file found"
            echo "has_breaking=false" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          # Extract counts from rover JSON output
          BREAKING=$(jq '[.data.diff.changes[]? | select(.severity == "BREAKING")] | length' \
            rover-check-result.json 2>/dev/null || echo "0")
          DANGEROUS=$(jq '[.data.diff.changes[]? | select(.severity == "DANGEROUS")] | length' \
            rover-check-result.json 2>/dev/null || echo "0")
          SAFE=$(jq '[.data.diff.changes[]? | select(.severity == "NON_BREAKING")] | length' \
            rover-check-result.json 2>/dev/null || echo "0")

          CHECK_ID=$(jq -r '.data.graph.checkWorkflow.id // "unknown"' \
            rover-check-result.json 2>/dev/null || echo "unknown")

          echo "breaking_count=${BREAKING}" >> "$GITHUB_OUTPUT"
          echo "dangerous_count=${DANGEROUS}" >> "$GITHUB_OUTPUT"
          echo "safe_count=${SAFE}" >> "$GITHUB_OUTPUT"
          echo "check_id=${CHECK_ID}" >> "$GITHUB_OUTPUT"
          echo "check_url=https://studio.apollographql.com/graph/${{ env.APOLLO_GRAPH_ID }}/checks/${CHECK_ID}" >> "$GITHUB_OUTPUT"
          echo "has_breaking=$([[ ${BREAKING} -gt 0 ]] && echo 'true' || echo 'false')" >> "$GITHUB_OUTPUT"

          echo "Results: ${BREAKING} BREAKING, ${DANGEROUS} DANGEROUS, ${SAFE} SAFE"

      - name: Post schema diff comment on PR
        if: always()
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const subgraph = '${{ matrix.subgraph }}';
            const breakingCount = parseInt('${{ steps.check.outputs.breaking_count }}' || '0');
            const dangerousCount = parseInt('${{ steps.check.outputs.dangerous_count }}' || '0');
            const safeCount = parseInt('${{ steps.check.outputs.safe_count }}' || '0');
            const checkUrl = '${{ steps.check.outputs.check_url }}';

            let changes = [];
            try {
              const raw = fs.readFileSync('rover-check-result.json', 'utf8');
              changes = JSON.parse(raw)?.data?.diff?.changes || [];
            } catch { /* result file may not exist on skip */ }

            const icon = breakingCount > 0 ? '🔴' : dangerousCount > 0 ? '🟡' : '🟢';
            const marker = `<!-- schema-check-${subgraph} -->`;

            const severityIcon = (s) =>
              s === 'BREAKING' ? '🔴' : s === 'DANGEROUS' ? '🟡' : '🟢';

            const tableRows = changes
              .sort((a, b) => {
                const order = { BREAKING: 0, DANGEROUS: 1, NON_BREAKING: 2 };
                return (order[a.severity] ?? 3) - (order[b.severity] ?? 3);
              })
              .slice(0, 40)   // cap table to 40 rows to stay within comment size limits
              .map(c =>
                `| ${severityIcon(c.severity)} \`${c.severity}\` | \`${c.path || ''}\` | ${(c.description || '').replace(/\|/g, '\\|')} |`
              )
              .join('\n');

            const body = [
              marker,
              `## Schema Check — \`${subgraph}\` ${icon}`,
              '',
              `| Severity | Count |`,
              `|---|---|`,
              `| 🔴 BREAKING | ${breakingCount} |`,
              `| 🟡 DANGEROUS | ${dangerousCount} |`,
              `| 🟢 NON_BREAKING | ${safeCount} |`,
              '',
              tableRows
                ? `| Severity | Path | Description |\n|---|---|---|\n${tableRows}`
                : '_No schema changes detected._',
              '',
              checkUrl ? `[View full results in Apollo Studio](${checkUrl})` : '',
              breakingCount > 0
                ? '\n> **To override**: apply the `approved-breaking-change` label to this PR.'
                : '',
            ].join('\n');

            const { data: comments } = await github.rest.issues.listComments({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
            });

            const existing = comments.find(c => c.body.includes(marker));
            const params = {
              owner: context.repo.owner,
              repo: context.repo.repo,
              body,
            };

            if (existing) {
              await github.rest.issues.updateComment({ ...params, comment_id: existing.id });
            } else {
              await github.rest.issues.createComment({ ...params, issue_number: context.issue.number });
            }

      - name: Upload schema diff artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: schema-diff-${{ matrix.subgraph }}
          path: rover-check-result.json
          retention-days: 30

  # ─────────────────────────────────────────────────────────────────────────────
  # JOB 3: Local composition check — verify the supergraph still composes
  # Runs rover compose against a local supergraph.yaml so we catch composition
  # errors before publishing. Does not require APOLLO_KEY.
  # ─────────────────────────────────────────────────────────────────────────────
  composition-check:
    name: Composition Check
    needs: schema-lint
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
      pull-requests: write

    steps:
      - name: Checkout PR branch
        uses: actions/checkout@v4

      - name: Cache Rover binary
        id: rover-cache
        uses: actions/cache@v4
        with:
          path: ~/.rover/bin
          key: rover-linux-${{ env.ROVER_VERSION }}
          restore-keys: |
            rover-linux-

      - name: Install Rover
        if: steps.rover-cache.outputs.cache-hit != 'true'
        run: |
          curl -sSL "https://rover.apollo.dev/nix/v${{ env.ROVER_VERSION }}" | sh

      - name: Add Rover to PATH
        run: echo "$HOME/.rover/bin" >> "$GITHUB_PATH"

      - name: Compose supergraph locally
        id: compose
        run: |
          set -euo pipefail

          if [[ ! -f schema/supergraph.yaml ]]; then
            echo "::warning::schema/supergraph.yaml not found — skipping local composition check"
            exit 0
          fi

          echo "Composing supergraph from schema/supergraph.yaml..."

          COMPOSE_OUTPUT=$(rover supergraph compose \
            --config schema/supergraph.yaml \
            --output json 2>&1) || COMPOSE_EXIT=$?

          if [[ "${COMPOSE_EXIT:-0}" -ne 0 ]]; then
            echo "::error::Supergraph composition failed"
            echo "${COMPOSE_OUTPUT}" | jq -r '.error.message // .' 2>/dev/null || echo "${COMPOSE_OUTPUT}"
            exit 1
          fi

          echo "${COMPOSE_OUTPUT}" | jq -r '.data' > /tmp/supergraph.graphql
          TYPE_COUNT=$(grep -c '^type ' /tmp/supergraph.graphql || true)
          echo "Composition succeeded. Type count: ${TYPE_COUNT}"
          echo "type_count=${TYPE_COUNT}" >> "$GITHUB_OUTPUT"

      - name: Post composition result comment
        if: failure()
        uses: actions/github-script@v7
        with:
          script: |
            const marker = '<!-- composition-check-result -->';
            const body = `${marker}
            ## Composition Check Failed

            The supergraph did not compose with the proposed schema change. This means the
            subgraph SDL you are adding is incompatible with one or more other subgraphs.

            **Next steps:**
            1. Check the workflow log for the full composition error message.
            2. Identify which subgraph's \`@key\`, \`@external\`, or \`@requires\` directive
               is incompatible with your change.
            3. Coordinate with the owning team to update the federation directives consistently.

            > This check validates federation composition locally without calling Apollo GraphOS.`;

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

  # ─────────────────────────────────────────────────────────────────────────────
  # JOB 4: Breaking change gate
  # Fails the PR if any schema-check job found BREAKING changes AND the PR does
  # not carry the `approved-breaking-change` label.
  # ─────────────────────────────────────────────────────────────────────────────
  breaking-change-gate:
    name: Breaking Change Gate
    needs:
      - schema-check
      - composition-check
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
      pull-requests: write

    steps:
      - name: Evaluate breaking change status
        uses: actions/github-script@v7
        with:
          script: |
            const hasBreaking = '${{ needs.schema-check.outputs.has_breaking }}' === 'true';
            const labels = context.payload.pull_request.labels.map(l => l.name);
            const approved = labels.includes('approved-breaking-change');

            if (!hasBreaking) {
              core.info('No BREAKING changes detected — gate passes.');
              return;
            }

            if (approved) {
              core.warning(
                'BREAKING changes detected but overridden by the `approved-breaking-change` label.\n' +
                'Ensure all affected client teams have been notified and queries have been migrated.'
              );
              // Allow the workflow to succeed
              return;
            }

            // BREAKING changes found and no override label — request review from platform team
            try {
              await github.rest.pulls.requestReviewers({
                owner: context.repo.owner,
                repo: context.repo.repo,
                pull_number: context.issue.number,
                team_reviewers: ['graphql-platform-team'],
              });
            } catch (err) {
              core.warning(`Could not request reviewers: ${err.message}`);
            }

            core.setFailed(
              'BREAKING schema changes detected. This PR cannot merge until either:\n' +
              '  1. The breaking changes are removed or reverted, OR\n' +
              "  2. The `approved-breaking-change` label is applied by @graphql-platform-team\n" +
              '     after confirming all affected clients have been migrated.'
            );
```

---

## Supporting Configuration Files

### `.graphqlrc.yml` — graphql-eslint Rule Configuration

```yaml
# .graphqlrc.yml
# graphql-eslint configuration. Committed to the repo root.
# See docs/10-schema-validation/04-linting.md for rule rationale.

overrides:
  - files: '**/*.graphql'
    parser: '@graphql-eslint/eslint-plugin'
    parserOptions:
      # Provide all subgraph schemas so cross-subgraph references resolve
      schema: './subgraphs/**/schema.graphql'
    plugins:
      - '@graphql-eslint'
    rules:
      # Naming conventions
      '@graphql-eslint/naming-convention':
        - error
        - types: PascalCase
          FieldDefinition: camelCase
          InputValueDefinition: camelCase
          EnumValueDefinition: UPPER_CASE
          DirectiveDefinition: camelCase

      # Every public type and field must have a description docstring
      '@graphql-eslint/require-description':
        - error
        - types: true
          FieldDefinition: true
          InputObjectTypeDefinition: true
          EnumTypeDefinition: true
          DirectiveDefinition: true

      # No @deprecated without a migration reason
      '@graphql-eslint/require-deprecation-reason':
        - error

      # Unique type and directive names within the schema
      '@graphql-eslint/unique-type-names':
        - error

      # No anonymous operations in schema files
      '@graphql-eslint/no-anonymous-operations':
        - error

      # Enforce input type suffix convention
      '@graphql-eslint/input-name':
        - error
        - checkInputType: true
          caseSensitiveInputType: true
```

### `schema/supergraph.yaml` — Rover Compose Config

```yaml
# schema/supergraph.yaml
# Used by composition-check job for local composition verification.
# Subgraph routing URLs here are only used for the SDL source; the actual
# routing URLs for the router come from rover subgraph publish --routing-url.
federation_version: =2.6.0

subgraphs:
  users:
    routing_url: http://users-service/graphql
    schema:
      file: ../subgraphs/users/schema.graphql

  products:
    routing_url: http://products-service/graphql
    schema:
      file: ../subgraphs/products/schema.graphql

  orders:
    routing_url: http://orders-service/graphql
    schema:
      file: ../subgraphs/orders/schema.graphql
```

---

## Labels Required

Create these labels in the repository before the workflows run:

```bash
# The override label — only graphql-platform-team should be able to apply this
gh label create "approved-breaking-change" \
  --color "FF4500" \
  --description "Approved breaking schema change — clients have been migrated"

# Label to track schema-rfc issues (used by governance-gate-workflow)
gh label create "schema-rfc" \
  --color "7B68EE" \
  --description "Schema RFC — required before a breaking change can merge"
```
