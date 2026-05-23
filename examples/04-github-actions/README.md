# GitHub Actions — Production GraphQL Federation CI/CD

This example set provides production-ready GitHub Actions workflows for a GraphQL Federation
platform. The three workflows here cover the full schema lifecycle: validation on every PR,
schema publishing to Apollo GraphOS after merge, and a governance gate that enforces
organizational policy on every schema change.

These examples are the companion implementation for
[docs/12-github-actions/](../../docs/12-github-actions/). Read that section for the
conceptual architecture before working through these examples.

---

## What This Example Demonstrates

| File | Workflow | Trigger |
|---|---|---|
| [schema-check-workflow.md](./schema-check-workflow.md) | PR schema validation — lint, Rover check, composition, breaking-change gate | `pull_request` on schema/resolver paths |
| [schema-publish-workflow.md](./schema-publish-workflow.md) | CD promotion pipeline — staging publish, smoke test, prod promote, rollback | `push` to `main` on schema paths |
| [governance-gate-workflow.md](./governance-gate-workflow.md) | Governance enforcement — OPA policies, description audit, deprecation check, ownership | `pull_request` on schema paths |

---

## Pipeline Architecture

```
Developer opens PR
       │
       ▼
 path filter: schema/**  src/**/*.graphql  src/**/*.ts
       │
       ├─── schema-check-workflow.yml ──────────────────────────────────────────┐
       │    schema-lint (graphql-eslint)                                        │
       │         │                                                               │
       │         ▼                                                               │
       │    schema-check (rover subgraph check @staging)                        │
       │         │                                                               │
       │         ├── BREAKING + no approval label? → FAIL                       │
       │         ├── BREAKING + approved-breaking-change label → WARN + pass    │
       │         └── no issues → pass                                           │
       │              │                                                          │
       │              ▼                                                          │
       │    composition-check (rover compose local)                             │
       │         │                                                               │
       │         ▼                                                               │
       │    breaking-change-gate                                                │
       │                                                                        │
       ├─── governance-gate-workflow.yml ──────────────────────────────────────┤
       │    OPA policy check                                                    │
       │    description audit (AST parse)                                       │
       │    deprecation window check (git log)                                  │
       │    team ownership check (CODEOWNERS)                                   │
       │                                                                        │
       └─────────────────────────────────────────────────────────────────────── ┘
                        │ PR approved + status checks pass
                        ▼
                   Merge to main
                        │
                        ▼
       schema-publish-workflow.yml
            composition-check (pre-publish fast fail)
                        │
                        ▼
            rover subgraph publish → @staging
                        │
                        ▼
            poll GraphOS for schema propagation (up to 2 min)
                        │
                        ▼
            smoke test query against staging router
                        ├── FAIL → rollback to previous SDL artifact
                        └── PASS ──────────────────────────────────────────────┐
                                                                               │
                                          rover subgraph publish → @production │
                                                     │                         │
                                                     ▼                         │
                                          smoke test against production ◄───── ┘
                                                     ├── FAIL → rollback
                                                     └── PASS → Slack notify
```

---

## Required Secrets and Variables

Configure these before the workflows will run. Secrets are set under
**Settings → Secrets and variables → Actions → Secrets**. Variables are set under
**Settings → Secrets and variables → Actions → Variables**.

### Secrets (sensitive — use the Secrets tab)

| Secret | Description |
|---|---|
| `APOLLO_KEY` | Apollo service API key with subgraph publish and check permissions. Create under **Apollo Studio → Graph Settings → API Keys**. Scope to the specific graph, not the org root. Rotate quarterly. |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook URL for publish notifications. Create under **Slack App → Incoming Webhooks**. Scope to the `#schema-changes` channel. |

### Variables (non-sensitive — use the Variables tab)

| Variable | Example value | Description |
|---|---|---|
| `APOLLO_GRAPH_REF` | `my-supergraph@main` | The graph ref used for schema checks and the production publish. Format: `{graph-id}@{variant}`. |
| `APOLLO_GRAPH_REF_STAGING` | `my-supergraph@staging` | The staging variant ref. Publish goes here first. |
| `APOLLO_GRAPH_ID` | `my-supergraph` | The graph ID without variant. Used to construct Studio links. |
| `STAGING_ROUTER_URL` | `https://staging-router.internal/graphql` | URL used for smoke test queries against the staging router. |
| `PRODUCTION_ROUTER_URL` | `https://router.api.example.com/graphql` | URL used for smoke test queries against the production router. |

### GitHub Environment Configuration

The `schema-publish-workflow.yml` uses **GitHub Environments** to gate the production publish
step. Create two environments:

**`staging`**
- No required reviewers (automated publish)
- Add environment secret `ROUTER_URL` = staging router URL

**`production`**
- Required reviewers: at least one member of `@graphql-platform-team`
- Deployment protection rule: require approval for `workflow_dispatch` runs
- Add environment secret `ROUTER_URL` = production router URL

---

## Branch Protection Configuration

Run once to configure required status checks. Replace `my-org` and `my-repo`:

```bash
# Require schema-check and governance-gate as status checks before merge
gh api repos/my-org/my-repo/branches/main/protection \
  --method PUT \
  --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "Schema Check / schema-lint",
      "Schema Check / schema-check",
      "Schema Check / composition-check",
      "Schema Check / breaking-change-gate",
      "Governance Gate / opa-policy",
      "Governance Gate / description-audit",
      "Governance Gate / deprecation-check",
      "Governance Gate / ownership-check"
    ]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "require_code_owner_reviews": true,
    "dismiss_stale_reviews": true
  },
  "restrictions": null
}
EOF
```

---

## Monorepo Subgraph Layout Assumed by These Workflows

```
repo-root/
├── .github/
│   ├── CODEOWNERS
│   └── workflows/
│       ├── graphql-schema-check.yml
│       ├── graphql-schema-publish.yml
│       └── graphql-governance-gate.yml
├── schema/
│   └── supergraph.yaml          # rover supergraph compose config
├── subgraphs/
│   ├── users/
│   │   ├── schema.graphql
│   │   ├── subgraph.yaml        # routing_url, variant overrides
│   │   └── src/
│   ├── products/
│   │   ├── schema.graphql
│   │   └── subgraph.yaml
│   └── orders/
│       ├── schema.graphql
│       └── subgraph.yaml
├── policies/
│   └── schema-governance.rego
└── scripts/
    └── smoke-test.sh
```

---

## Related Docs

- [docs/12-github-actions/](../../docs/12-github-actions/) — conceptual architecture for all workflows
- [docs/10-schema-validation/](../../docs/10-schema-validation/) — schema validation rules the CI enforces
- [docs/09-schema-governance/](../../docs/09-schema-governance/) — CODEOWNERS strategy and review processes
- [docs/13-policy-as-code/](../../docs/13-policy-as-code/) — OPA policy design and testing
- [examples/07-opa-policies/](../07-opa-policies/) — full OPA policy reference implementation
