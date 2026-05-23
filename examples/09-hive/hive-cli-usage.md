# Hive CLI Usage — Federation v2 Workflow Reference

<!-- Companion docs: ../../docs/09-schema-governance/, ../../docs/11-ci-cd-automation/ -->

This document is the complete reference for using the `@graphql-hive/cli` in a Federation v2
monorepo. It covers installation, authentication, schema publishing, schema checking, usage
reporting, service deletion, project-level configuration, and a full GitHub Actions CI/CD workflow.

---

## 1. Installation

Install the Hive CLI as a global tool or as a project devDependency. Using a pinned devDependency
is preferred in CI/CD to ensure reproducible builds and avoid surprise breakage from a major CLI
version upgrade.

```bash
# Option A: global install (developer workstations)
npm install -g @graphql-hive/cli

# Option B: project devDependency (preferred for CI/CD)
npm install --save-dev @graphql-hive/cli

# Verify installation
npx hive --version
```

After installing, verify the CLI can reach the Hive API:

```bash
npx hive whoami
# Output: Organization: my-org | Project: my-federation-project | Target: production
```

---

## 2. Authentication

Hive uses access tokens for all CLI operations. Tokens are scoped to a specific target
(e.g., "production", "staging") and granted one of three permission levels:

| Token Type | Permission | CLI Operations |
|------------|-----------|----------------|
| Registry Write | Read + write schema | `schema:publish`, `schema:check`, `schema:delete` |
| Registry Read | Read schema only | `schema:check` (read-only checks) |
| CDN Access | Fetch composed supergraph SDL | Router schema delivery only, not CLI |

**Creating a token via the Hive dashboard:**
1. Navigate to your project at app.graphql-hive.com.
2. Select the target (e.g., "production").
3. Go to Settings > Tokens > Create new token.
4. Select "Registry Write" permission.
5. Copy the token — it will not be shown again.

**Setting the token in CI/CD:**

The CLI reads the token from the `HIVE_TOKEN` environment variable. Always pass this as a
CI/CD secret, never hardcode it in config files or scripts.

```bash
# Local development: set in shell profile or .env (gitignored)
export HIVE_TOKEN="hvo1/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# GitHub Actions: set as a repository secret named HIVE_TOKEN
# Then reference in workflow: ${{ secrets.HIVE_TOKEN }}
```

**Creating a token with the CLI (for automation):**

```bash
# Authenticate with an existing token and create a scoped token for a specific target
hive auth:create-token \
  --name "ci-production-write" \
  --registry-write \
  --target production
```

---

## 3. Schema Publishing

The `hive schema:publish` command registers a subgraph schema version in the Hive registry. In
a Federation v2 setup, you run this once per subgraph on every merge to the main branch.

**Basic publish:**

```bash
hive schema:publish \
  --service users \
  --url https://users-service.internal/graphql \
  subgraphs/users/schema.graphql
```

**Full publish with all recommended flags:**

```bash
hive schema:publish \
  # The logical name of this subgraph — must match the name used in all previous publishes
  # and in the Apollo Router supergraph composition config.
  --service users \
  \
  # The URL at which the router can reach this subgraph at runtime.
  # This is embedded in the composed supergraph SDL so the router knows where to send requests.
  # For Kubernetes: use the internal cluster DNS name, not the public URL.
  --url https://users-service.prod.svc.cluster.local/graphql \
  \
  # The author field associates this schema version with the engineer or system that published it.
  # In CI, use the git committer name for traceability.
  --author "$(git log -1 --format='%an <%ae>')" \
  \
  # The commit SHA links this schema version to the exact git commit.
  # This allows the Hive dashboard to show a "View commit" link and correlates schema
  # changes with code changes in post-incident reviews.
  --commit "$(git rev-parse HEAD)" \
  \
  # The path to the subgraph schema file. This is the raw SDL file, not an introspection JSON.
  subgraphs/users/schema.graphql
```

**GitHub Actions auto-detection:**

When running inside a GitHub Actions workflow, the Hive CLI automatically reads commit and author
information from the standard GitHub Actions environment variables, so you can omit `--author`
and `--commit`:

```bash
# Inside GitHub Actions, GITHUB_SHA and GITHUB_ACTOR are set automatically.
# Hive CLI reads these if --commit and --author are not explicitly provided.
hive schema:publish \
  --service users \
  --url https://users-service.prod.svc.cluster.local/graphql \
  subgraphs/users/schema.graphql
```

The environment variables the CLI reads automatically in GitHub Actions:

| Env Var | Used As |
|---------|---------|
| `GITHUB_SHA` | Commit SHA (equivalent to `--commit`) |
| `GITHUB_ACTOR` | Author name (equivalent to `--author`) |
| `GITHUB_REPOSITORY` | Linked in the Hive dashboard for "View on GitHub" |
| `GITHUB_RUN_ID` | Linked to the Actions run for traceability |

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Schema published successfully. |
| 1 | Publication failed (network error, auth error, or composition failure). |

If composition fails after publishing (e.g., your new subgraph schema is incompatible with other
registered subgraphs), Hive will still store the schema version but mark the target as having a
composition error. The previous valid supergraph SDL remains on the CDN until a valid composition
is published.

---

## 4. Schema Checking

The `hive schema:check` command validates a proposed schema change against the current registry
state without writing anything to the registry. Run this on every pull request.

**Basic check:**

```bash
hive schema:check \
  --service users \
  subgraphs/users/schema.graphql
```

**Full check with GitHub PR annotation:**

```bash
hive schema:check \
  # Which subgraph this schema belongs to. Required for Federation projects.
  --service users \
  \
  # Optional: a human-readable name for this check run. Shown in the Hive dashboard.
  # Using the PR number + branch name creates a unique, traceable identifier.
  --target production \
  \
  # Path to the modified schema file.
  subgraphs/users/schema.graphql
```

**Understanding check output:**

A passing check with no changes:
```
v No schema changes detected.
  Composition: Successful
  Breaking changes: 0
  Dangerous changes: 0
  Safe changes: 0
```

A check with breaking changes when usage reporting is disabled:
```
x Breaking changes detected!
  FIELD_REMOVED: User.legacyId was removed.
  Composition: Successful
  Breaking changes: 1
  Dangerous changes: 0
  Safe changes: 2
```

The same check when usage reporting is enabled and the field has zero recent usage:
```
v Schema check passed (with suppressed breaking changes).
  FIELD_REMOVED: User.legacyId was removed.
    -> Suppressed: 0 operations used this field in the last 30 days.
  Composition: Successful
  Breaking changes: 1 (0 affecting active clients)
  Safe changes: 2
```

**Change severity reference:**

| Severity | Examples | Action |
|----------|---------|--------|
| Breaking | Remove field, change non-null to null, remove type, change argument type | Blocked by default; requires approval or suppression |
| Dangerous | Add required argument, change default value, change enum value | Warning; review required |
| Safe | Add field, add optional argument, add type | No action required |

**Approving a breaking change:**

When a breaking change is intentional (field removal after client migration), approve it in the
Hive dashboard under Schema Checks. The approval is tied to the specific change and allows the
next `schema:check` with that change to pass without blocking.

---

## 5. Usage Reporting

Usage reporting sends aggregated operation data from your GraphQL server to Hive. This data powers:
- Field usage counts in the schema explorer.
- Client-based suppression of breaking changes.
- Operation count and error rate dashboards.

**Server-side setup with Apollo Server:**

Install the Hive client plugin for Apollo Server:

```bash
npm install @graphql-hive/client
```

Configure the plugin in your Apollo Server setup:

```typescript
// subgraphs/users/src/server.ts
import { ApolloServer } from "@apollo/server";
import { useHive } from "@graphql-hive/client";

const server = new ApolloServer({
  // ... schema, resolvers
  plugins: [
    useHive({
      // The registry write token for this target.
      // Use a separate token per environment (production vs staging).
      token: process.env.HIVE_TOKEN!,

      // Usage reporting configuration.
      usage: {
        // Enable usage collection. When false, the plugin is a no-op for usage.
        enabled: true,

        // Sample rate: 1.0 = report 100% of operations, 0.1 = report 10%.
        // For high-traffic subgraphs, reduce this to limit Hive ingestion volume.
        // The Hive usage service extrapolates counts from the sample.
        sampleRate: 1.0,

        // Exclude specific operation names from usage reporting.
        // Useful for health check queries and internal tooling operations.
        exclude: ["HealthCheck", "IntrospectionQuery"],

        // Map client identifiers from request headers for per-client usage breakdown.
        // The Hive dashboard shows which clients use which fields.
        clientInfo(context) {
          return {
            name: context.req?.headers?.["x-client-name"] as string ?? "unknown",
            version: context.req?.headers?.["x-client-version"] as string ?? "0.0.0",
          };
        },
      },

      // Schema reporting: automatically publish the schema from the running server.
      // Useful for non-Federation setups. In Federation, prefer hive schema:publish in CI.
      reporting: {
        enabled: false, // Disabled for Federation subgraphs — use CLI publishing instead
      },
    }),
  ],
});
```

**Reporting from Apollo Router (preferred for Federation):**

For Federation v2, usage reporting should be done from Apollo Router rather than individual
subgraphs. This avoids double-counting operations and provides a unified view of the full
supergraph request. See `hive-router-config.md` for the router-level usage reporting configuration.

---

## 6. Deleting a Subgraph Service

When decommissioning a subgraph, remove it from the Hive registry to allow Hive to recompose
the supergraph without the deleted service:

```bash
hive schema:delete \
  # The service name to remove from the registry.
  # The composition will be re-run without this service after deletion.
  --service decommissioned-subgraph \
  \
  # Confirm the deletion without interactive prompt (required for CI/CD).
  --confirm
```

Before deleting, verify that:
1. No field in the remaining subgraphs references a type defined only in the deleted subgraph.
2. The router has been updated to not route any queries to the deleted subgraph.
3. All client queries have been migrated away from any types or fields unique to that subgraph.

---

## 7. The hive.json Configuration File

The `hive.json` file at the project root provides default values for CLI flags, reducing the
amount of repetition in CI scripts. The CLI merges these defaults with any explicitly passed flags
(explicit flags take precedence).

```json
{
  "$schema": "https://graphql-hive.com/config.json",

  "token": "${HIVE_TOKEN}",

  "access": {
    "endpoint": "https://app.graphql-hive.com/graphql"
  },

  "schema": {
    "sdl": "subgraphs/users/schema.graphql",

    "author": "${GITHUB_ACTOR}",

    "commit": "${GITHUB_SHA}",

    "service": "users",

    "url": "https://users-service.prod.svc.cluster.local/graphql",

    "force": false
  },

  "cdn": {
    "endpoint": "${HIVE_CDN_ENDPOINT}",

    "accessToken": "${HIVE_CDN_TOKEN}"
  }
}
```

Environment variable substitution (`${VAR_NAME}` syntax) is supported natively in `hive.json`.
Never hardcode tokens in this file — always use environment variable references.

For a monorepo with multiple subgraphs, keep the `hive.json` at the individual subgraph level
(e.g., `subgraphs/users/hive.json`) and override the `service`, `sdl`, and `url` fields per
subgraph.

---

## 8. CI/CD Workflow — GitHub Actions

The following workflow runs schema checks on pull requests and publishes schemas on merges to main.
It is designed for a Federation v2 monorepo where each subgraph lives in its own directory under
`subgraphs/`.

```yaml
# .github/workflows/hive-schema.yml
# Purpose: Validate GraphQL subgraph schemas on PRs and publish them on merge to main.
# This workflow runs for every subgraph. To add a new subgraph, add a job to the matrix.

name: GraphQL Schema — Hive

on:
  push:
    branches:
      - main
    paths:
      # Only run when subgraph schema files change.
      # Avoids unnecessary Hive API calls on documentation-only PRs.
      - "subgraphs/**/schema.graphql"
  pull_request:
    branches:
      - main
    paths:
      - "subgraphs/**/schema.graphql"

# Limit concurrency to one workflow run per branch/PR.
# cancel-in-progress prevents a slow schema check on an outdated commit from blocking
# a newer check on the same branch.
concurrency:
  group: hive-schema-${{ github.ref }}
  cancel-in-progress: true

env:
  # The Hive registry write token, stored as a GitHub Actions secret.
  # This token has read+write access to the production target.
  HIVE_TOKEN: ${{ secrets.HIVE_TOKEN }}

  # Pin the Hive CLI version to avoid surprise breakage from upstream releases.
  # Update this pin deliberately after reviewing the Hive changelog.
  HIVE_CLI_VERSION: "0.34.0"

jobs:
  # -----------------------------------------------------------------------
  # Schema Check: runs on every pull request
  # -----------------------------------------------------------------------
  schema-check:
    name: Schema Check — ${{ matrix.subgraph }}
    runs-on: ubuntu-latest

    # Only run the check job on pull requests, not on pushes to main.
    if: github.event_name == 'pull_request'

    strategy:
      # Run checks for all subgraphs in parallel.
      # fail-fast: false ensures that a failure in one subgraph check does not
      # cancel checks for other subgraphs — you want to see all failures at once.
      fail-fast: false
      matrix:
        subgraph:
          - users
          - products
          - orders
          - inventory
          - notifications

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          # Use the LTS version. Hive CLI requires Node 18+.
          node-version: "20"

      - name: Install Hive CLI
        # Install a pinned version of the Hive CLI. Using npx with @version ensures
        # the exact version is used without relying on a global install.
        run: npm install -g @graphql-hive/cli@${{ env.HIVE_CLI_VERSION }}

      - name: Check schema — ${{ matrix.subgraph }}
        # hive schema:check compares the proposed schema against the current registry state.
        # It exits non-zero if there are unresolved breaking changes, which fails the CI job
        # and blocks the PR from merging.
        run: |
          hive schema:check \
            --service ${{ matrix.subgraph }} \
            --target production \
            subgraphs/${{ matrix.subgraph }}/schema.graphql
        env:
          # Pass the Hive token explicitly (also available globally via env: above,
          # but explicit passing makes the token scope obvious).
          HIVE_TOKEN: ${{ secrets.HIVE_TOKEN }}

      - name: Annotate PR with check results
        # The Hive CLI outputs schema check results in a format that GitHub Actions
        # can parse as workflow commands to annotate the PR diff view.
        # This step only runs if the check step fails, providing inline annotations.
        if: failure()
        run: |
          echo "::error file=subgraphs/${{ matrix.subgraph }}/schema.graphql::Hive schema check failed. See the Hive dashboard for details."

  # -----------------------------------------------------------------------
  # Schema Publish: runs on every merge to main
  # -----------------------------------------------------------------------
  schema-publish:
    name: Schema Publish — ${{ matrix.subgraph.name }}
    runs-on: ubuntu-latest

    # Only run the publish job on pushes to main (i.e., after a PR is merged).
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'

    strategy:
      # fail-fast: false here is important — if the users subgraph publish fails,
      # we still want to publish other subgraphs that changed in the same merge.
      fail-fast: false
      matrix:
        subgraph:
          - name: users
            url: https://users-service.prod.svc.cluster.local/graphql
            schema: subgraphs/users/schema.graphql
          - name: products
            url: https://products-service.prod.svc.cluster.local/graphql
            schema: subgraphs/products/schema.graphql
          - name: orders
            url: https://orders-service.prod.svc.cluster.local/graphql
            schema: subgraphs/orders/schema.graphql
          - name: inventory
            url: https://inventory-service.prod.svc.cluster.local/graphql
            schema: subgraphs/inventory/schema.graphql
          - name: notifications
            url: https://notifications-service.prod.svc.cluster.local/graphql
            schema: subgraphs/notifications/schema.graphql

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          # Fetch the full git history so --author and --commit can be resolved correctly.
          # Shallow clones (the default) only fetch the tip commit and will have missing
          # author information for commits that are not the HEAD.
          fetch-depth: 0

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: "20"

      - name: Install Hive CLI
        run: npm install -g @graphql-hive/cli@${{ env.HIVE_CLI_VERSION }}

      - name: Publish schema — ${{ matrix.subgraph.name }}
        # hive schema:publish registers this schema version with the Hive registry.
        # After a successful publish, Hive recomposes the supergraph and updates the CDN.
        # The router will pick up the new supergraph SDL on its next poll interval.
        run: |
          hive schema:publish \
            --service ${{ matrix.subgraph.name }} \
            --url ${{ matrix.subgraph.url }} \
            ${{ matrix.subgraph.schema }}
        env:
          HIVE_TOKEN: ${{ secrets.HIVE_TOKEN }}
          # GitHub Actions sets these automatically; Hive CLI reads them for --author and --commit.
          GITHUB_SHA: ${{ github.sha }}
          GITHUB_ACTOR: ${{ github.actor }}
          GITHUB_REPOSITORY: ${{ github.repository }}
          GITHUB_RUN_ID: ${{ github.run_id }}

      - name: Notify on failure
        # Post a Slack notification if the schema publish fails.
        # A failed publish does not break the running system (the old schema stays on the CDN)
        # but it means the new schema version is not live — which is a P2 incident.
        if: failure()
        uses: 8398a7/action-slack@v3
        with:
          status: failure
          fields: repo,message,commit,author,action
          text: "Schema publish failed for subgraph `${{ matrix.subgraph.name }}`. The previous schema version is still active."
        env:
          SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
```

**Path filtering for monorepos:**

In a large monorepo, schema changes may only affect one or two subgraphs per PR. To avoid running
all subgraph checks on every PR (slow and noisy), use the `dorny/paths-filter` action to determine
which subgraphs changed and pass that as a dynamic matrix:

```yaml
- name: Detect changed subgraphs
  id: changes
  uses: dorny/paths-filter@v3
  with:
    filters: |
      users:
        - 'subgraphs/users/**'
      products:
        - 'subgraphs/products/**'
      orders:
        - 'subgraphs/orders/**'

- name: Check changed schemas
  if: steps.changes.outputs.users == 'true'
  run: |
    hive schema:check --service users subgraphs/users/schema.graphql
```

---

## Related Documentation

- `../../docs/09-schema-governance/` — Schema governance policies, including rules for when
  breaking changes require an approval process vs. automated suppression.
- `../../docs/11-ci-cd-automation/` — General CI/CD pipeline patterns for GraphQL, beyond just
  schema checking.
- `../../docs/12-github-actions/` — Reusable GitHub Actions workflows for the full GraphQL
  platform CI/CD pipeline.
- `hive-router-config.md` — Configuring Apollo Router to consume the Hive CDN after schemas
  are published by this workflow.

---

## Key Design Decisions

**Pinning the CLI version in CI**
The `@graphql-hive/cli` package receives frequent updates. Pinning the version in CI with
`HIVE_CLI_VERSION` ensures that a new CLI release does not silently change check behavior mid-sprint.
The pin should be updated deliberately as part of a dependency maintenance rotation, not
automatically via Dependabot (to avoid unexpected breakage in schema check behavior).

**Separating check and publish jobs**
The check job (PRs) and publish job (main branch pushes) are separate GitHub Actions jobs rather
than a single job with conditional steps. This makes the failure surface explicit: a failed check
fails the PR check run, and a failed publish fires an alert to the on-call engineer. Conflating
them into a single job would make the failure mode ambiguous.

**fail-fast: false in the matrix strategy**
Setting `fail-fast: false` for both check and publish matrices means a failure in the `users`
subgraph does not cancel in-flight checks or publishes for `products` or `orders`. This is
important because a PR might modify multiple subgraph schemas simultaneously, and you need to see
all check results at once rather than iterating through them one at a time.

**Reporting from the router, not subgraphs**
Usage reporting is configured at the Apollo Router level (see `hive-router-config.md`) rather than
in each subgraph's Apollo Server instance. Router-level reporting provides a unified view of every
operation executed against the supergraph, including operations that are resolved entirely from the
router cache and never reach subgraphs. Per-subgraph reporting would double-count federated fields
and miss cached responses.
