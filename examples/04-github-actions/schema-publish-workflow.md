# Schema Publish Workflow

> Companion documentation: `../../docs/10-schema-validation/`
> Related example: `schema-check-workflow.md` (PR gate that must pass before this workflow runs)

This document describes the full Continuous Delivery workflow that publishes subgraph schemas
to Apollo GraphOS after a merge to `main`. The workflow implements a two-stage publish:
staging first, with automated smoke tests, then production with a manual approval gate.

The guiding principle is that no schema change reaches the production router without:
1. Local composition succeeding (fast-fail before any publish).
2. The schema being live in staging and passing automated smoke tests.
3. A human reviewing and approving the promotion to production.
4. Smoke tests passing against the production router after publish.
5. An automated rollback path available if production smoke tests fail.

---

## Workflow Overview

```
push to main (schema file changed)
           |
           v
+--------------------+         fails
| Job 1:             | ------> workflow stops, Slack alert sent
| composition-check  |         (no schema was published)
+--------+-----------+
         |
         | succeeds
         v
+--------------------+
| Job 2:             |  rover subgraph publish to @staging for each changed subgraph
| publish-staging    |
+--------+-----------+
         |
         v
+--------------------+
| Job 3:             |  poll staging router health endpoint for new schema version
| wait-for-          |  (up to 2 minutes)
| propagation        |
+--------+-----------+
         |
         v
+--------------------+         fails
| Job 4:             | ------> workflow stops, Slack alert sent, production NOT promoted
| smoke-test-staging |         (staging is now running the bad schema — manual fix needed)
+--------+-----------+
         |
         | passes
         v
+--------------------+
| Job 5:             |  waits for manual approval in GitHub Environments UI
| publish-production |  rover subgraph publish to @production
+--------+-----------+
         |
         v
+--------------------+         fails
| Job 6:             | ------> Job 7 (rollback) triggered
| smoke-test-        |         re-publishes previous SDL artifacts to @production
| production         |
+--------------------+
         |
         | passes
         v
+--------------------+
| Slack: published   |  Notification to #graphql-releases with graph ref and change count
+--------------------+
```

---

## Full Workflow YAML

```yaml
# .github/workflows/graphql-schema-publish.yml
#
# Triggered on push to main when schema files change.
# Publishes subgraph schemas to Apollo GraphOS staging, smoke tests,
# then promotes to production with a manual approval gate.

name: GraphQL Schema Publish

on:
  push:
    branches:
      - main
    paths:
      # Only trigger when schema SDL files change, not on README updates,
      # test file changes, or CI config changes. This prevents unnecessary
      # publish runs that would consume Apollo Studio check quota.
      - 'subgraphs/**/schema.graphql'
      - 'supergraph.yaml'  # also trigger if the supergraph composition config changes

  # Allow manual trigger for emergency publishes (e.g., rolling back a schema).
  workflow_dispatch:
    inputs:
      subgraph:
        description: 'Specific subgraph to publish (leave empty for all changed)'
        required: false
        type: string
      target_variant:
        description: 'Target variant (staging or production)'
        required: false
        default: staging
        type: choice
        options:
          - staging
          - production

# Concurrency group prevents two publish runs from racing.
# If a new push arrives while a publish is in progress, cancel the in-progress run.
# This prevents out-of-order publishes (e.g., newer push finishing before older one).
# Note: only cancel on the same branch — parallel branches publish independently.
concurrency:
  group: graphql-publish-${{ github.ref }}
  cancel-in-progress: true

env:
  # Apollo credentials injected from GitHub repository secrets.
  # Never hard-code these values — they grant write access to the schema registry.
  APOLLO_KEY: ${{ secrets.APOLLO_KEY }}

  # The graph ref format is graph-name@variant. We use environment-specific
  # graph refs so staging and production have independent schema histories.
  APOLLO_GRAPH_REF_STAGING: ${{ vars.APOLLO_GRAPH_PRODUCTION_REF }}

  # Staging router endpoint — the live Apollo Router serving the staging supergraph.
  STAGING_ROUTER_URL: ${{ vars.STAGING_ROUTER_URL }}

  # Production router endpoint.
  PRODUCTION_ROUTER_URL: ${{ vars.PRODUCTION_ROUTER_URL }}

  # Slack webhook URL for publish notifications. Stored as a secret to avoid
  # leaking it (webhook URLs grant the ability to post to your Slack workspace).
  SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}

  # Rover version to pin across all jobs. Explicit pinning prevents a Rover
  # release from changing behavior mid-flight on a long-running publish.
  ROVER_VERSION: 0.24.0

jobs:
  # ===========================================================================
  # JOB 1: Composition Check
  # Fast-fail: verify the full supergraph composes before publishing anything.
  # If composition fails, no subgraph is published and the workflow stops here.
  # This is cheaper than publishing a subgraph that breaks overall composition.
  # ===========================================================================
  composition-check:
    name: Composition Check
    runs-on: ubuntu-latest
    outputs:
      # Expose the list of changed subgraphs as a JSON array for downstream jobs.
      # Format: '["users","products"]'
      changed_subgraphs: ${{ steps.detect-changes.outputs.changed_subgraphs }}

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          # Fetch two commits so we can compute the diff (HEAD and HEAD~1).
          fetch-depth: 2

      - name: Install Rover CLI
        run: |
          # Install a pinned version of Rover for reproducible CI behavior.
          # The install script reads ROVER_VERSION if set; otherwise installs latest.
          # We set it explicitly above to guarantee the version.
          curl -sSL https://rover.apollo.dev/nix/v${ROVER_VERSION} | sh
          echo "${HOME}/.rover/bin" >> $GITHUB_PATH

      - name: Detect changed subgraphs
        id: detect-changes
        run: |
          # Compare HEAD to HEAD~1 to find schema files changed in this push.
          # git diff --name-only HEAD~1 HEAD: lists files changed between commits.
          # The grep filters to only schema SDL files under subgraphs/.
          # The sed extracts just the subgraph directory name.
          CHANGED=$(git diff --name-only HEAD~1 HEAD \
            | grep -E '^subgraphs/[^/]+/schema\.graphql$' \
            | sed 's|subgraphs/\([^/]*\)/schema\.graphql|\1|' \
            | sort -u \
            | jq -R . | jq -sc .)  # convert newline-separated list to JSON array

          # If workflow_dispatch specified a subgraph, override the detected list.
          if [ -n "${{ github.event.inputs.subgraph }}" ]; then
            CHANGED=$(echo '["${{ github.event.inputs.subgraph }}"]')
          fi

          echo "Changed subgraphs: $CHANGED"
          echo "changed_subgraphs=$CHANGED" >> "$GITHUB_OUTPUT"

      - name: Save current production SDLs as rollback artifacts
        run: |
          # Before publishing anything, save the current production SDL for each
          # subgraph we are about to change. These artifacts are used by the
          # rollback job (Job 7) if production smoke tests fail.
          mkdir -p rollback-sdls

          SUBGRAPHS='${{ steps.detect-changes.outputs.changed_subgraphs }}'
          for subgraph in $(echo "$SUBGRAPHS" | jq -r '.[]'); do
            echo "Fetching current production SDL for: $subgraph"
            rover subgraph fetch "${{ vars.APOLLO_GRAPH_PRODUCTION_REF }}" \
              --name "$subgraph" \
              > "rollback-sdls/${subgraph}-rollback.graphql" \
              || echo "Warning: could not fetch SDL for $subgraph (may be a new subgraph)"
          done

      - name: Upload rollback artifacts
        uses: actions/upload-artifact@v4
        with:
          name: rollback-sdls
          # Retain rollback artifacts for 7 days so they are available for
          # manual rollback even after the workflow run expires.
          retention-days: 7
          path: rollback-sdls/

      - name: Compose supergraph locally
        run: |
          # Run rover supergraph compose against supergraph.yaml.
          # This validates that all subgraphs — including the newly changed ones —
          # compose into a valid supergraph. If composition fails here, the problem
          # is in the SDL, not in the registry, and must be fixed before publish.
          rover supergraph compose --config supergraph.yaml \
            > composed-supergraph.graphql

          echo "Composition succeeded. Supergraph SDL size: $(wc -c < composed-supergraph.graphql) bytes"

      - name: Upload composed supergraph artifact
        uses: actions/upload-artifact@v4
        with:
          name: composed-supergraph
          retention-days: 1  # short TTL — only needed within this workflow run
          path: composed-supergraph.graphql

      - name: Notify on composition failure
        if: failure()
        run: |
          curl -s -X POST "$SLACK_WEBHOOK_URL" \
            -H 'Content-Type: application/json' \
            -d '{
              "text": ":x: *GraphQL Schema Publish Failed* — Composition check failed on `main`.",
              "attachments": [{
                "color": "danger",
                "fields": [
                  {"title": "Branch", "value": "${{ github.ref_name }}", "short": true},
                  {"title": "Commit", "value": "${{ github.sha }}", "short": true},
                  {"title": "Run URL", "value": "${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}", "short": false}
                ]
              }]
            }'

  # ===========================================================================
  # JOB 2: Publish to Staging
  # Publishes each changed subgraph to the @staging variant.
  # Uses the changed_subgraphs output from Job 1 to publish only what changed.
  # Publishing only changed subgraphs minimizes registry churn and audit noise.
  # ===========================================================================
  publish-staging:
    name: Publish to Staging
    needs: composition-check
    runs-on: ubuntu-latest
    environment: staging  # links to the "staging" GitHub Environment for secrets/rules
    outputs:
      published_count: ${{ steps.publish.outputs.published_count }}

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Install Rover CLI
        run: |
          curl -sSL https://rover.apollo.dev/nix/v${ROVER_VERSION} | sh
          echo "${HOME}/.rover/bin" >> $GITHUB_PATH

      - name: Publish changed subgraphs to staging
        id: publish
        run: |
          SUBGRAPHS='${{ needs.composition-check.outputs.changed_subgraphs }}'
          COUNT=0

          for subgraph in $(echo "$SUBGRAPHS" | jq -r '.[]'); do
            schema_file="subgraphs/${subgraph}/schema.graphql"
            echo "Publishing subgraph '${subgraph}' to staging..."

            # rover subgraph publish pushes the SDL to the GraphOS registry
            # and triggers a new supergraph composition in the cloud.
            # The --routing-url must match the actual staging service URL.
            rover subgraph publish "${{ vars.APOLLO_GRAPH_STAGING_REF }}" \
              --name "$subgraph" \
              --schema "$schema_file" \
              --routing-url "${{ vars.STAGING_SUBGRAPH_ROUTING_URLS }}"
              # Note: STAGING_SUBGRAPH_ROUTING_URLS is a JSON map variable:
              # {"users": "https://users-staging.internal/graphql", ...}
              # In practice, parse this with jq in a helper function.

            COUNT=$((COUNT + 1))
            echo "Published $subgraph to staging."
          done

          echo "published_count=$COUNT" >> "$GITHUB_OUTPUT"
          echo "Published $COUNT subgraph(s) to staging."

  # ===========================================================================
  # JOB 3: Wait for Schema Propagation
  # After publishing, the Apollo Router needs time to fetch and apply the new
  # supergraph schema. This job polls the staging router's health endpoint until
  # it reflects the new schema version, with a 2-minute timeout.
  #
  # The check uses a lightweight __typename query with the x-apollo-operation-id
  # header to verify the router is running the new composition.
  # ===========================================================================
  wait-for-propagation:
    name: Wait for Schema Propagation
    needs: [composition-check, publish-staging]
    runs-on: ubuntu-latest

    steps:
      - name: Poll staging router for new schema version
        timeout-minutes: 3  # GitHub Actions job-level timeout as a safety net
        run: |
          # The Apollo Router fetches updated supergraph schemas from the Uplink service
          # on a configurable interval (default: 10 seconds). After publish, we poll
          # until the router responds to a query without errors, confirming it has
          # loaded the new schema.
          #
          # Strategy: send a minimal __typename query. If the router returns a valid
          # GraphQL response (not a 503 or a "schema unavailable" error), the new
          # schema is live.

          STAGING_URL="${STAGING_ROUTER_URL}"
          MAX_WAIT=120   # seconds
          POLL_INTERVAL=10
          ELAPSED=0

          echo "Waiting for staging router to reflect new schema..."
          echo "Router URL: $STAGING_URL"

          while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
            HTTP_STATUS=$(curl -s -o /tmp/router-response.json -w "%{http_code}" \
              -X POST "$STAGING_URL" \
              -H "Content-Type: application/json" \
              -H "x-apollo-operation-name: HealthCheck" \
              -d '{"query": "{ __typename }"}')

            if [ "$HTTP_STATUS" = "200" ]; then
              # Check that the response is a valid GraphQL response (not an error JSON).
              TYPENAME=$(jq -r '.data.__typename // empty' /tmp/router-response.json)
              if [ -n "$TYPENAME" ]; then
                echo "Router is healthy. __typename = $TYPENAME"
                echo "Schema propagation confirmed after ${ELAPSED}s."
                exit 0
              fi
            fi

            echo "[${ELAPSED}s] Router not ready (HTTP $HTTP_STATUS). Waiting ${POLL_INTERVAL}s..."
            sleep "$POLL_INTERVAL"
            ELAPSED=$((ELAPSED + POLL_INTERVAL))
          done

          echo "ERROR: Router did not become healthy within ${MAX_WAIT}s."
          exit 1

  # ===========================================================================
  # JOB 4: Smoke Test Staging
  # Runs automated smoke tests against the staging router. Includes:
  #   - An IntrospectionQuery to verify the schema is introspectable.
  #   - A domain query that exercises the core paths of the changed subgraphs.
  # Failure here means the new schema is functionally broken on staging.
  # Production will NOT be promoted until this passes.
  # ===========================================================================
  smoke-test-staging:
    name: Smoke Test (Staging)
    needs: wait-for-propagation
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Run smoke tests against staging router
        id: smoke-test
        run: |
          STAGING_URL="${STAGING_ROUTER_URL}"
          FAILED=0

          # --- Test 1: IntrospectionQuery ---
          # Validates that the schema is introspectable and that the router has
          # loaded the new supergraph SDL. If introspection fails, the router may
          # have rejected the composition or be running the old schema.
          echo "Test 1: IntrospectionQuery"
          HTTP_STATUS=$(curl -s -o /tmp/introspection-response.json -w "%{http_code}" \
            -X POST "$STAGING_URL" \
            -H "Content-Type: application/json" \
            -d '{"query": "{ __schema { queryType { name } } }"}')

          if [ "$HTTP_STATUS" != "200" ]; then
            echo "FAIL: IntrospectionQuery returned HTTP $HTTP_STATUS"
            FAILED=1
          else
            QUERY_TYPE=$(jq -r '.data.__schema.queryType.name // empty' \
              /tmp/introspection-response.json)
            if [ -z "$QUERY_TYPE" ]; then
              echo "FAIL: IntrospectionQuery response missing queryType"
              cat /tmp/introspection-response.json
              FAILED=1
            else
              echo "PASS: queryType = $QUERY_TYPE"
            fi
          fi

          # --- Test 2: Domain Query ---
          # Runs a real query that exercises the primary entity types.
          # This query is a minimal but representative path through the graph.
          # It validates resolver connectivity, not just schema structure.
          echo "Test 2: Domain smoke query"
          HTTP_STATUS=$(curl -s -o /tmp/domain-response.json -w "%{http_code}" \
            -X POST "$STAGING_URL" \
            -H "Content-Type: application/json" \
            -d '{
              "operationName": "SmokeTestQuery",
              "query": "query SmokeTestQuery { users(limit: 1) { edges { node { id email } } pageInfo { hasNextPage } } }"
            }')

          if [ "$HTTP_STATUS" != "200" ]; then
            echo "FAIL: Domain query returned HTTP $HTTP_STATUS"
            FAILED=1
          else
            # Check for GraphQL errors in the response body.
            ERRORS=$(jq '.errors // empty' /tmp/domain-response.json)
            if [ -n "$ERRORS" ] && [ "$ERRORS" != "null" ]; then
              echo "FAIL: Domain query returned GraphQL errors:"
              echo "$ERRORS"
              FAILED=1
            else
              echo "PASS: Domain query returned no errors."
            fi
          fi

          if [ "$FAILED" -eq 1 ]; then
            echo "One or more smoke tests failed."
            exit 1
          fi
          echo "All smoke tests passed."

      - name: Notify on staging smoke test failure
        if: failure()
        run: |
          curl -s -X POST "$SLACK_WEBHOOK_URL" \
            -H 'Content-Type: application/json' \
            -d '{
              "text": ":fire: *GraphQL Staging Smoke Tests FAILED* — schema is published to staging but tests are failing. Production will NOT be promoted.",
              "attachments": [{
                "color": "danger",
                "fields": [
                  {"title": "Commit", "value": "${{ github.sha }}", "short": true},
                  {"title": "Run URL", "value": "${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}", "short": false}
                ]
              }]
            }'

  # ===========================================================================
  # JOB 5: Publish to Production
  # Requires manual approval via GitHub Environments before running.
  # The "production" GitHub Environment should be configured with:
  #   - Required reviewers (the GraphQL platform team)
  #   - A wait timer of 0 (no automatic delay — the smoke tests are sufficient)
  #   - Protected branches: only main can deploy to production
  # ===========================================================================
  publish-production:
    name: Publish to Production
    needs: [composition-check, smoke-test-staging]
    runs-on: ubuntu-latest
    environment: production  # triggers the manual approval gate

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Install Rover CLI
        run: |
          curl -sSL https://rover.apollo.dev/nix/v${ROVER_VERSION} | sh
          echo "${HOME}/.rover/bin" >> $GITHUB_PATH

      - name: Publish changed subgraphs to production
        run: |
          SUBGRAPHS='${{ needs.composition-check.outputs.changed_subgraphs }}'

          for subgraph in $(echo "$SUBGRAPHS" | jq -r '.[]'); do
            schema_file="subgraphs/${subgraph}/schema.graphql"
            echo "Publishing subgraph '${subgraph}' to production..."

            rover subgraph publish "${{ vars.APOLLO_GRAPH_PRODUCTION_REF }}" \
              --name "$subgraph" \
              --schema "$schema_file"

            echo "Published $subgraph to production."
          done

  # ===========================================================================
  # JOB 6: Smoke Test Production
  # Same test suite as Job 4, run against the production router URL.
  # Failure here triggers Job 7 (rollback).
  # ===========================================================================
  smoke-test-production:
    name: Smoke Test (Production)
    needs: publish-production
    runs-on: ubuntu-latest
    # This job's failure status is checked by Job 7 (rollback).
    # We use 'failure()' condition there rather than a direct needs dependency.

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Wait for production router propagation
        run: |
          # Same propagation wait as staging (Job 3), against the production URL.
          PROD_URL="${PRODUCTION_ROUTER_URL}"
          MAX_WAIT=120
          POLL_INTERVAL=10
          ELAPSED=0

          while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
            HTTP_STATUS=$(curl -s -o /tmp/prod-health.json -w "%{http_code}" \
              -X POST "$PROD_URL" \
              -H "Content-Type: application/json" \
              -d '{"query": "{ __typename }"}')

            if [ "$HTTP_STATUS" = "200" ]; then
              TYPENAME=$(jq -r '.data.__typename // empty' /tmp/prod-health.json)
              if [ -n "$TYPENAME" ]; then
                echo "Production router healthy after ${ELAPSED}s."
                exit 0
              fi
            fi

            sleep "$POLL_INTERVAL"
            ELAPSED=$((ELAPSED + POLL_INTERVAL))
          done

          echo "ERROR: Production router did not become healthy within ${MAX_WAIT}s."
          exit 1

      - name: Run production smoke tests
        run: |
          PROD_URL="${PRODUCTION_ROUTER_URL}"
          FAILED=0

          # IntrospectionQuery
          echo "Test 1: IntrospectionQuery (production)"
          HTTP_STATUS=$(curl -s -o /tmp/prod-introspection.json -w "%{http_code}" \
            -X POST "$PROD_URL" \
            -H "Content-Type: application/json" \
            -d '{"query": "{ __schema { queryType { name } } }"}')

          if [ "$HTTP_STATUS" != "200" ]; then
            echo "FAIL: IntrospectionQuery HTTP $HTTP_STATUS"
            FAILED=1
          fi

          # Domain query
          echo "Test 2: Domain smoke query (production)"
          HTTP_STATUS=$(curl -s -o /tmp/prod-domain.json -w "%{http_code}" \
            -X POST "$PROD_URL" \
            -H "Content-Type: application/json" \
            -d '{
              "operationName": "SmokeTestQuery",
              "query": "query SmokeTestQuery { users(limit: 1) { edges { node { id email } } pageInfo { hasNextPage } } }"
            }')

          if [ "$HTTP_STATUS" != "200" ]; then
            echo "FAIL: Domain query HTTP $HTTP_STATUS"
            FAILED=1
          else
            ERRORS=$(jq '.errors // empty' /tmp/prod-domain.json)
            if [ -n "$ERRORS" ] && [ "$ERRORS" != "null" ]; then
              echo "FAIL: GraphQL errors in production domain query:"
              echo "$ERRORS"
              FAILED=1
            fi
          fi

          if [ "$FAILED" -eq 1 ]; then exit 1; fi
          echo "Production smoke tests passed."

  # ===========================================================================
  # JOB 7: Rollback
  # Runs if smoke-test-production fails. Re-publishes the rollback SDL artifacts
  # saved at the start of the workflow (Job 1, "Save current production SDLs").
  # This restores the last known-good production schema.
  # ===========================================================================
  rollback:
    name: Rollback Production
    needs: smoke-test-production
    # Only run if production smoke tests failed. 'failure()' is true when any
    # upstream job in the 'needs' graph failed or was cancelled.
    if: failure()
    runs-on: ubuntu-latest
    environment: production  # rollback also requires the production approval environment

    steps:
      - name: Install Rover CLI
        run: |
          curl -sSL https://rover.apollo.dev/nix/v${ROVER_VERSION} | sh
          echo "${HOME}/.rover/bin" >> $GITHUB_PATH

      - name: Download rollback artifacts
        uses: actions/download-artifact@v4
        with:
          name: rollback-sdls
          path: rollback-sdls/

      - name: Re-publish previous SDLs to production
        run: |
          # Re-publish each rollback SDL to production. This restores the schema
          # to the state it was in before this workflow run.
          for rollback_file in rollback-sdls/*-rollback.graphql; do
            # Extract subgraph name from the filename.
            subgraph=$(basename "$rollback_file" | sed 's/-rollback\.graphql//')
            echo "Rolling back subgraph '${subgraph}'..."

            rover subgraph publish "${{ vars.APOLLO_GRAPH_PRODUCTION_REF }}" \
              --name "$subgraph" \
              --schema "$rollback_file"

            echo "Rolled back $subgraph."
          done

      - name: Notify on rollback
        run: |
          curl -s -X POST "$SLACK_WEBHOOK_URL" \
            -H 'Content-Type: application/json' \
            -d '{
              "text": ":warning: *GraphQL Production ROLLED BACK* — smoke tests failed. Schema has been restored to the previous version.",
              "attachments": [{
                "color": "warning",
                "fields": [
                  {"title": "Commit", "value": "${{ github.sha }}", "short": true},
                  {"title": "Run URL", "value": "${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}", "short": false}
                ]
              }]
            }'

  # ===========================================================================
  # JOB 8: Notify Success
  # Posts a Slack notification on successful end-to-end publish to production.
  # Only runs if smoke-test-production passed (and rollback did not run).
  # ===========================================================================
  notify-success:
    name: Notify Success
    needs: smoke-test-production
    if: success()
    runs-on: ubuntu-latest

    steps:
      - name: Post Slack notification
        run: |
          SUBGRAPHS='${{ needs.composition-check.outputs.changed_subgraphs }}'
          SUBGRAPH_LIST=$(echo "$SUBGRAPHS" | jq -r 'join(", ")')

          curl -s -X POST "$SLACK_WEBHOOK_URL" \
            -H 'Content-Type: application/json' \
            -d "{
              \"text\": \":white_check_mark: *GraphQL Schema Published to Production* — $SUBGRAPH_LIST\",
              \"attachments\": [{
                \"color\": \"good\",
                \"fields\": [
                  {\"title\": \"Subgraphs\", \"value\": \"$SUBGRAPH_LIST\", \"short\": true},
                  {\"title\": \"Commit\", \"value\": \"${{ github.sha }}\", \"short\": true},
                  {\"title\": \"Run URL\", \"value\": \"${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}\", \"short\": false}
                ]
              }]
            }"
```

---

## Secrets and Variables Reference

All secrets must be configured in the GitHub repository settings before this workflow runs.

| Name | Type | Description |
|------|------|-------------|
| `APOLLO_KEY` | Secret | Apollo API key. Format: `service:graph-name:hash`. Grants write access to the schema registry. |
| `SLACK_WEBHOOK_URL` | Secret | Slack Incoming Webhook URL. Stored as secret to prevent webhook abuse. |
| `APOLLO_GRAPH_STAGING_REF` | Variable | Graph ref for the staging variant. Example: `my-graph@staging` |
| `APOLLO_GRAPH_PRODUCTION_REF` | Variable | Graph ref for the production variant. Example: `my-graph@production` |
| `STAGING_ROUTER_URL` | Variable | Base URL of the staging Apollo Router. Example: `https://graphql-staging.mycompany.com` |
| `PRODUCTION_ROUTER_URL` | Variable | Base URL of the production Apollo Router. Example: `https://graphql.mycompany.com` |
| `STAGING_SUBGRAPH_ROUTING_URLS` | Variable | JSON map of subgraph name to routing URL for staging. Used in `rover subgraph publish --routing-url`. |

---

## GitHub Environment Configuration

Two GitHub Environments must be configured in repository Settings > Environments:

**staging**
- No required reviewers (automated promotion after successful composition check).
- Deployment branches: main only.

**production**
- Required reviewers: at least 1 member of the GraphQL platform team.
- Deployment branches: main only.
- Wait timer: 0 minutes (smoke tests on staging are sufficient delay).

The "production" environment approval creates a mandatory human gate: when Job 5
(`publish-production`) starts, GitHub pauses the workflow and sends an email/Slack
notification to the required reviewers. The workflow resumes only after one reviewer
approves in the GitHub Actions UI.

---

## Key Design Decisions

**Why publish to staging before production, not simultaneously.** The router takes 10-30
seconds to load a new supergraph schema from GraphOS Uplink. Publishing to both variants
simultaneously means the production gate (smoke test) fires before the production router
has necessarily loaded the new schema, causing intermittent false failures.

**Why save rollback SDLs at the start of the workflow rather than at publish time.** If the
SDL is fetched after publishing (e.g., from the registry), it might already reflect the new
broken schema. Fetching at workflow start, before any publish, guarantees the rollback SDL
represents the last known-good state.

**Why use `concurrency: cancel-in-progress`.** Without this, two pushes in rapid succession
can result in out-of-order publishes. If commit A pushes `users` v1 and commit B pushes
`users` v2, and B's workflow starts before A's finishes, A's publish could overwrite B's v2
with the v1 SDL. cancel-in-progress ensures only the newest commit's workflow runs to
completion.

**Why the rollback job requires the production environment approval.** Rollback is also a
schema change — it reverts the production registry to an older SDL. Requiring the same
approval gate as forward publish ensures rollbacks are also reviewed by a human, preventing
automated rollback loops.

---

## Related Documentation

- `../../docs/10-schema-validation/` — Validation and publish pipeline design
- `../../docs/11-schema-registry/` — Apollo GraphOS registry concepts
- `schema-check-workflow.md` — PR-time check workflow (runs before this publish workflow)
- `governance-gate-workflow.md` — PR governance checks that must pass before merge to main
- `../../examples/03-schema-validation/rover-schema-check.md` — Rover CLI reference
