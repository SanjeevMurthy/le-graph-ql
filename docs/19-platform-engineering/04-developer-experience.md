# 04 — Developer Experience

> **Purpose:** Developer experience is the platform team's primary deliverable, not an
> afterthought. A platform that is technically excellent but painful to use will be bypassed.
> This document covers every touchpoint a subgraph engineer has with the GraphQL platform:
> local development setup, IDE integration, schema exploration, pre-commit validation, and the
> onboarding checklist that takes a team from idea to production. It closes with the metrics
> the platform team uses to measure whether DX is improving or degrading.

---

## Local Development Setup

Local development for a federated GraphQL subgraph has two requirements that traditional
REST APIs do not: the subgraph must compose with other subgraphs at development time, and
the local router must reflect production routing logic so that cross-subgraph queries work
correctly before code is merged.

### `rover dev` — Local Supergraph Composition

Apollo Rover's `rover dev` command composes a local supergraph from running subgraph processes
and starts a local router. It is the primary local development tool for subgraph engineers.

```bash
# Start your subgraph
npm run dev   # Starts products-subgraph on http://localhost:4001

# In a separate terminal — start rover dev pointing at your subgraph
# and polling the registry for other subgraphs' current schemas
rover dev \
  --name products \
  --url http://localhost:4001 \
  --supergraph-config supergraph.yaml
```

The `supergraph.yaml` in each scaffold repository points at the local subgraph and at
the staging registry schemas for all other subgraphs:

```yaml
# supergraph.yaml — committed to each subgraph repository
federation_version: =2.6.0

subgraphs:
  products:
    routing_url: http://localhost:4001
    schema:
      subgraph_url: http://localhost:4001

  # Other subgraphs come from the staging registry — no local setup needed
  orders:
    routing_url: https://orders-subgraph.staging.internal.myorg.com
    schema:
      graphref: myorg-supergraph@staging
      subgraph: orders

  users:
    routing_url: https://users-subgraph.staging.internal.myorg.com
    schema:
      graphref: myorg-supergraph@staging
      subgraph: users
```

With this setup, cross-subgraph queries that span `products` (local) and `users` (staging)
work during local development. The developer only runs their subgraph locally; everything
else comes from staging.

### Docker Compose — Full Local Supergraph

For teams that need full offline development or want to run integration tests without
connecting to staging, the scaffold generates a `docker-compose.local.yml` that runs
the router and a minimal set of dependent subgraphs as mocked services:

```yaml
# docker-compose.local.yml
version: '3.9'

services:
  router:
    image: ghcr.io/apollographql/router:v1.45.0
    ports:
      - "4000:4000"
    environment:
      APOLLO_KEY: ${APOLLO_KEY}
      APOLLO_GRAPH_REF: myorg-supergraph@staging
      # Override subgraph URL to point at local instance
      APOLLO_ROUTER_SUPERGRAPH_URL: http://supergraph-config-sidecar:8080
    volumes:
      - ./router.yaml:/dist/config/router.yaml
    depends_on:
      - products-subgraph
      - users-mock
      - orders-mock

  products-subgraph:
    build: .
    ports:
      - "4001:4001"
    environment:
      NODE_ENV: development
      DATABASE_URL: postgresql://dev:dev@postgres:5432/products_dev
      OTEL_SDK_DISABLED: "true"   # Disable OTel in local dev
    depends_on:
      - postgres

  # Mocked subgraphs for cross-service queries
  users-mock:
    image: registry.internal.myorg.com/graphql-platform/subgraph-mock:latest
    environment:
      SUBGRAPH_NAME: users
      GRAPHOS_REF: myorg-supergraph@staging
    ports:
      - "4002:4001"

  orders-mock:
    image: registry.internal.myorg.com/graphql-platform/subgraph-mock:latest
    environment:
      SUBGRAPH_NAME: orders
      GRAPHOS_REF: myorg-supergraph@staging
    ports:
      - "4003:4001"

  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: products_dev
      POSTGRES_USER: dev
      POSTGRES_PASSWORD: dev
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./db/migrations:/docker-entrypoint-initdb.d

volumes:
  postgres_data:
```

The `subgraph-mock` image (maintained by the platform team) introspects a subgraph's
schema from GraphOS and serves a mock implementation using `@graphql-tools/mock`.
This lets teams run cross-subgraph queries locally without setting up every dependent
subgraph from source.

### Schema Mocking with `@graphql-tools/mock`

For unit and integration tests that do not require a real database:

```typescript
// src/__tests__/setup.ts
import { addMocksToSchema } from '@graphql-tools/mock';
import { makeExecutableSchema } from '@graphql-tools/schema';
import { typeDefs } from '../schema';

export function buildMockSchema() {
  return addMocksToSchema({
    schema: makeExecutableSchema({ typeDefs }),
    mocks: {
      // Override specific scalars with realistic test data
      ID: () => `test-id-${Math.random().toString(36).slice(2, 9)}`,
      String: () => 'Mock String',
      Float: () => 9.99,
      Boolean: () => true,

      // Override specific types with domain-realistic data
      Product: () => ({
        id: `prod-${Math.random().toString(36).slice(2, 9)}`,
        name: 'Test Product',
        price: { amount: 29.99, currency: 'USD' },
        inStock: true,
        tags: ['electronics', 'sale'],
      }),

      Money: () => ({
        amount: 9.99,
        currency: 'USD',
      }),
    },
    preserveResolvers: false,
  });
}
```

---

## IDE Integration

### GraphQL Language Server Protocol

The GraphQL LSP (`graphql-language-service`) provides IDE features for `.graphql` files:
autocomplete, go-to-definition, inline error highlighting, and hover documentation. The
scaffold configures it via `.graphqlrc.yml`:

```yaml
# .graphqlrc.yml
schema:
  # Point at the local subgraph's introspection endpoint for type checking
  - http://localhost:4001
  # Also include schema SDL files for offline type checking
  - src/schema.graphql

documents:
  - src/**/*.graphql
  - src/**/*.ts   # Finds graphql-tag template literals in TS files

extensions:
  endpoints:
    local:
      url: http://localhost:4001
      headers:
        Content-Type: application/json
    staging:
      url: https://api.staging.internal.myorg.com/graphql
      headers:
        Content-Type: application/json
        Authorization: Bearer ${STAGING_TOKEN}
```

### VS Code Configuration

```json
// .vscode/settings.json (generated by scaffold)
{
  "graphql-config.load.rootDir": ".",
  "graphql-config.load.configName": ".graphqlrc",

  // ESLint — apply graphql-eslint rules to .graphql and .ts files
  "eslint.validate": [
    "typescript",
    "typescriptreact",
    "graphql"
  ],

  // Format .graphql files with prettier on save
  "[graphql]": {
    "editor.formatOnSave": true,
    "editor.defaultFormatter": "esbenp.prettier-vscode"
  },

  // Show inline type information from the schema
  "editor.inlayHints.enabled": "on",

  // File nesting — show schema.graphql under schema.ts in explorer
  "explorer.fileNesting.patterns": {
    "schema.ts": "schema.graphql",
    "resolvers.ts": "resolvers/**/*.ts"
  }
}
```

```json
// .vscode/extensions.json (generated by scaffold)
{
  "recommendations": [
    "GraphQL.vscode-graphql",            // GraphQL LSP
    "GraphQL.vscode-graphql-syntax",     // Syntax highlighting
    "dbaeumer.vscode-eslint",            // graphql-eslint integration
    "esbenp.prettier-vscode",            // SDL formatting
    "ms-vscode.vscode-typescript-next",  // TypeScript support
    "eamodio.gitlens",                   // Git blame in editor
    "humao.rest-client"                  // Test GraphQL over HTTP
  ]
}
```

### JetBrains (IntelliJ / WebStorm) Configuration

```xml
<!-- .idea/graphql.xml (generated by scaffold for JetBrains IDEs) -->
<?xml version="1.0" encoding="UTF-8"?>
<project version="4">
  <component name="GraphQLProjectConfig">
    <config>
      <endpoints>
        <endpoint name="Local" url="http://localhost:4001" />
        <endpoint name="Staging" url="https://api.staging.internal.myorg.com/graphql" />
      </endpoints>
    </config>
  </component>
</project>
```

The JetBrains GraphQL plugin (JS GraphQL) reads `.graphqlrc.yml` for schema configuration.
In IntelliJ Ultimate and WebStorm, the plugin provides autocomplete for `gql` template
literals in TypeScript files and inline schema validation.

---

## Schema Exploration in Production

### GraphOS Studio Explorer

Apollo GraphOS Studio includes an in-browser GraphQL explorer with full schema
introspection, operation history, and variable management. Platform team configuration
for Explorer access:

```yaml
# Router configuration for Studio Explorer integration
# router.yaml
cors:
  origins:
    - https://studio.apollographql.com
  allow_headers:
    - Content-Type
    - Authorization
    - x-apollo-operation-name

# Enable introspection only for authenticated internal users
# (handled by the router's authorization plugin)
supergraph:
  introspection: true   # Controlled per-environment by authorization plugin
```

Restrict Explorer to internal users by requiring an internal authentication header:

```yaml
# router.yaml — authorization plugin configuration
authorization:
  require_authentication: false  # Public traffic is allowed

coprocessor:
  url: http://auth-sidecar:8080
  router:
    request:
      headers: true
      body: false
  # Studio Explorer sends a special header — allow it through without auth
  # Internal traffic validation happens in the coprocessor
```

### Hive Schema Viewer

For organizations using The Guild's Hive as the schema registry:

```bash
# View schema history for a subgraph
hive schema:check --service products --sdl src/schema.graphql

# View the current supergraph schema
hive schema:fetch --target myorg/supergraph@production > supergraph.graphql

# Check field usage before deprecation
hive operations:check --service products --field "Product.priceInCents"
```

### Postman GraphQL Support

Postman supports GraphQL natively with schema introspection and variable management.
The platform team maintains a shared Postman workspace with:

- Pre-configured environment variables for staging and production
- A collection of example queries organized by domain
- An introspection sync workflow that updates the schema in the collection when
  the supergraph schema changes

```bash
# Export the current supergraph schema for import into Postman
rover graph introspect https://api.staging.internal.myorg.com/graphql \
  --header "Authorization: Bearer $STAGING_TOKEN" \
  > postman-schema.graphql
```

---

## Local Schema Check Before Push

A pre-commit hook runs a fast local schema check before any push reaches CI. This catches
naming violations, documentation gaps, and local composition errors in under five seconds —
before a developer even opens a PR.

### Pre-commit Hook Setup

The scaffold generates a `.husky` configuration that installs the pre-commit hook:

```bash
# Installed by scaffold — runs automatically on npm install
# package.json
{
  "scripts": {
    "prepare": "husky install"
  },
  "devDependencies": {
    "husky": "^9.0.0",
    "lint-staged": "^15.0.0"
  },
  "lint-staged": {
    "*.{graphql,graphqls}": [
      "graphql-eslint --fix",
      "graphql-platform validate-local"
    ],
    "*.{ts,tsx}": [
      "eslint --fix",
      "tsc --noEmit"
    ]
  }
}
```

```bash
# .husky/pre-commit
#!/usr/bin/env sh
. "$(dirname "$0")/_/husky.sh"

# Run lint-staged for schema and TypeScript files
npx lint-staged

# Run local composition check — fails fast if the subgraph
# cannot compose with the staging supergraph
if git diff --cached --name-only | grep -qE '\.(graphql|graphqls)$'; then
  echo "Schema changes detected — running local composition check..."
  rover subgraph check myorg-supergraph@staging \
    --name products \
    --schema src/schema.graphql \
    --background   # Non-blocking — result posted as GitHub check
fi
```

### `graphql-inspector` for Local Diff

```bash
# Check what changed in the schema before committing
npx graphql-inspector diff \
  git:main:src/schema.graphql \
  src/schema.graphql

# Output example:
# ✔ No changes detected
# — OR —
# ✖ Breaking change: Field 'Product.priceInCents' removed
# ⚠ Dangerous change: Field 'Product.name' changed type from 'String' to 'String!'
# ✔ Non-breaking: Field 'Product.sku' added
```

---

## Onboarding Checklist: From Idea to Production

This checklist represents the full onboarding path for a new subgraph team. Each step
has an owner (the developer, the platform team, or an automated system) and a target
time to completion.

```
Phase 1: Setup (Target: Day 1, < 2 hours)
─────────────────────────────────────────
[ ] Developer — Install graphql-platform CLI
    brew install myorg/tap/graphql-platform
    graphql-platform version  # Should print current version

[ ] Developer — Authenticate with platform
    graphql-platform auth login
    graphql-platform auth status  # Should show authenticated user

[ ] Developer — Run new subgraph scaffold
    graphql-platform new-subgraph \
      --name <your-subgraph-name> \
      --team <your-team-name>

[ ] Automated — Infrastructure provisioned (Terraform)
    Kubernetes namespace, ServiceAccount, IAM role, secrets, ArgoCD App
    Expected: < 5 minutes after scaffold command

[ ] Developer — Clone the generated repository
    git clone git@github.com:myorg/<subgraph-name>-subgraph.git

[ ] Developer — Install dependencies and verify local start
    cd <subgraph-name>-subgraph && npm install
    npm run dev
    # Subgraph should be reachable at http://localhost:4001
    curl http://localhost:4001 -d '{"query":"{__typename}"}' -H "Content-Type: application/json"

Phase 2: First Schema (Target: Day 1–2)
────────────────────────────────────────
[ ] Developer — Write initial schema in src/schema.graphql
    Follow naming guidelines: docs/03-schema-design/
    All types must have descriptions

[ ] Developer — Verify schema composes locally
    rover dev --name <subgraph> --url http://localhost:4001

[ ] Developer — Run lint check
    npm run lint:schema
    # All rules must pass

[ ] Developer — Open first PR
    git checkout -b feat/initial-schema
    git add src/schema.graphql
    git commit -m "feat: add initial schema"
    git push origin feat/initial-schema

[ ] Automated — Schema check CI runs (< 30 seconds target)
    Check status at: github.com/myorg/<subgraph>-subgraph/actions

Phase 3: Staging Deployment (Target: Day 2–3)
──────────────────────────────────────────────
[ ] Developer — Merge initial PR after schema check passes
[ ] Automated — ArgoCD deploys to staging namespace (< 10 minutes)
[ ] Developer — Verify staging deployment
    rover subgraph introspect https://<subgraph>.staging.internal.myorg.com

[ ] Developer — Publish schema to registry staging
    APOLLO_KEY=$APOLLO_KEY rover subgraph publish myorg-supergraph@staging \
      --name <subgraph> \
      --schema src/schema.graphql \
      --routing-url https://<subgraph>.staging.internal.myorg.com

[ ] Developer — Verify subgraph appears in GraphOS Studio staging graph

Phase 4: Observability Verification (Target: Day 3)
────────────────────────────────────────────────────
[ ] Developer — Verify traces appear in Grafana
    grafana.internal.myorg.com/explore?orgId=1&left=...

[ ] Developer — Verify metrics are scraped
    Check Prometheus targets: prometheus.internal.myorg.com/targets
    Filter by job="<subgraph>-subgraph"

[ ] Developer — Verify logs are structured JSON
    kubectl logs -n team-<team> deploy/<subgraph>-subgraph | head -5
    # Must be valid JSON with level, msg, traceId fields

Phase 5: Production (Target: Week 2)
──────────────────────────────────────
[ ] Developer — Complete at least one integration test
    npm run test:integration

[ ] Platform team — Review schema for production readiness
    Schedule 30-minute platform review (book via #graphql-platform)

[ ] Developer — Promote to production
    Update ArgoCD Application to target main branch tag

[ ] Automated — Production schema published to GraphOS
[ ] Developer — Verify Grafana SLO dashboard shows green
```

---

## Measuring Developer Experience

The platform team cannot improve what it does not measure. The following metrics provide
an objective signal on whether the developer experience is getting better or worse.

### Time-Based Metrics

| Metric | Definition | Target | Measurement Method |
|---|---|---|---|
| Time-to-first-schema-check | Scaffold command → first schema check result in CI | ≤ 10 minutes | CLI telemetry + GitHub Actions duration |
| Time-to-staging | Scaffold command → first deployment in staging | ≤ 30 minutes | ArgoCD sync timestamps |
| Time-to-production | First PR → first production deployment | ≤ 2 weeks | GitHub tag timestamp vs scaffold timestamp |
| Schema check duration | PR opened → schema check CI job complete | ≤ 30 seconds | GitHub Actions duration |
| Pre-commit hook duration | `git commit` → hook complete | ≤ 5 seconds | Git hook timing logs |
| Onboarding escalations | Number of #graphql-platform Slack threads per new team | ≤ 2 per onboarding | Slack channel analytics |

### Quality Metrics

| Metric | Definition | Target | Measurement Method |
|---|---|---|---|
| Schema breaking change incident rate | Production incidents caused by schema breaking changes / month | < 1 per quarter | Incident post-mortems tagged "schema-breaking" |
| Policy violation rate at merge | % of PRs that had policy violations before final merge | ≤ 5% | conftest output in CI + GitHub API |
| Documentation coverage | % of schema fields with non-empty descriptions | ≥ 90% | graphql-inspector stat + custom CI check |
| Golden path coverage | % of subgraphs on the current golden path template version | ≥ 80% | registry.yaml template_version comparison |
| Pre-commit bypass rate | % of commits that skipped pre-commit hooks | < 2% | Git log analysis (commits without hook metadata) |

### Platform Health Dashboard

The platform team maintains a Grafana dashboard that aggregates these metrics across all
subgraph teams. The dashboard is publicly accessible to all engineering staff.

```yaml
# grafana/dashboards/platform-dx.json (abbreviated structure)
# Full dashboard JSON is committed to the platform repository

panels:
  - title: "Time to First Schema Check (p50)"
    type: stat
    targets:
      - expr: histogram_quantile(0.5, sum(rate(platform_scaffold_to_check_seconds_bucket[7d])) by (le))
    thresholds:
      - value: 600     # 10 minutes — green
      - value: 1800    # 30 minutes — yellow
      - value: null    # > 30 minutes — red

  - title: "Schema Check Duration (p99)"
    type: timeseries
    targets:
      - expr: histogram_quantile(0.99, sum(rate(github_actions_job_duration_seconds_bucket{job_name="schema-check"}[5m])) by (le))

  - title: "Breaking Change Incidents (Quarter)"
    type: stat
    targets:
      - datasource: prometheus
        expr: sum(incidents_total{label="schema-breaking"})

  - title: "Golden Path Coverage (%)"
    type: gauge
    targets:
      - expr: |
          100 * (
            count(subgraph_template_version == "1.7.2")
            /
            count(subgraph_template_version)
          )
```

---

## Related Topics

- [Golden Paths](./02-golden-paths.md)
- [Self-Service Infrastructure](./03-self-service-infrastructure.md)
- [Platform Team Model](./01-platform-team-model.md)
- [Platform Maturity Model](./05-platform-maturity-model.md)
- [Observability](../14-observability/README.md)

## References

- [Apollo Rover `dev` Command](https://www.apollographql.com/docs/rover/commands/dev/)
- [GraphQL Language Service](https://github.com/graphql/graphql-language-service)
- [VS Code GraphQL Extension](https://marketplace.visualstudio.com/items?itemName=GraphQL.vscode-graphql)
- [graphql-inspector Documentation](https://the-guild.dev/graphql/inspector)
- [Husky Pre-commit Hooks](https://typicode.github.io/husky/)
- [`@graphql-tools/mock`](https://the-guild.dev/graphql/tools/docs/mocking)
- [Hive Schema Registry](https://the-guild.dev/graphql/hive)
- [Developer Experience Engineering — Gartner (2023)](https://www.gartner.com/en/information-technology/insights/developer-experience)
