# Production Runbooks for GraphQL Platform Operations

> **Purpose**
> This section provides step-by-step operational runbooks for the most common GraphQL platform tasks and incidents. Each runbook defines trigger conditions, pre-requisites, numbered execution steps, verification commands, and a rollback procedure. Runbooks are written to be executed under pressure — concrete commands, not prose. Written for platform engineers and SREs who own the Apollo Router and subgraph deployment pipeline.

---

## How to Use These Runbooks

Runbooks are referenced directly from PagerDuty and Grafana alert annotations. Every alert in `docs/14-observability/05-slos-and-alerting.md` includes a `runbook_url` pointing to the relevant entry in this section.

**Convention:** Steps are numbered. Commands are complete and copy-pasteable. Every runbook ends with a verification section confirming the action succeeded and a rollback section if it did not.

**Scope:** These runbooks cover platform-level operations. Subgraph-team-specific runbooks live in each subgraph repository. This directory covers the shared router and composition layer.

---

## Runbook Trigger Map

| Runbook | When to Execute | PagerDuty Alert |
|---------|----------------|-----------------|
| [01-router-deployment-runbook.md](./01-router-deployment-runbook.md) | Planned: upgrading Apollo Router version | — (planned task) |
| [02-subgraph-deployment-runbook.md](./02-subgraph-deployment-runbook.md) | Planned: deploying a subgraph with schema change | — (planned task) |
| [03-schema-incident-runbook.md](./03-schema-incident-runbook.md) | Unplanned: breaking schema change detected in production | `GraphQLErrorRateCritical`, `GraphQLSubgraphHighErrorRate` |
| [04-performance-degradation-runbook.md](./04-performance-degradation-runbook.md) | Unplanned: p99 latency > 2x baseline | `GraphQLInteractiveLatencyCritical`, `GraphQLInteractiveLatencyHigh` |
| [05-capacity-scaling-runbook.md](./05-capacity-scaling-runbook.md) | Planned or reactive: traffic event or sudden load spike | `GraphQLRouterHighCPU`, `GraphQLSubgraphDown` |

---

## Section Map

```
32-production-runbooks/
├── README.md                              ← You are here — purpose and navigation
├── 01-router-deployment-runbook.md        ← Deploying a new Apollo Router version
├── 02-subgraph-deployment-runbook.md      ← Deploying a subgraph with schema change
├── 03-schema-incident-runbook.md          ← Responding to a breaking schema change in production
├── 04-performance-degradation-runbook.md  ← Diagnosing and resolving latency degradation
└── 05-capacity-scaling-runbook.md         ← Scaling for traffic events and campaigns
```

---

## Common Environment Variables

All runbooks assume these environment variables are set in the operator's shell. Set them before starting any runbook.

```bash
# Kubernetes context — confirm before every runbook
export CLUSTER=prod-us-east-1
export NAMESPACE=graphql-platform
export STAGING_NAMESPACE=graphql-platform-staging

# Apollo Router Helm release names
export ROUTER_RELEASE=apollo-router
export ROUTER_CHART=oci://ghcr.io/apollographql/helm-charts/router

# Rover CLI — must be authenticated
# rover config auth --profile prod

# Verify cluster context
kubectl config current-context
# Expected output: prod-us-east-1
```

---

## Pre-Requisites for All Runbooks

Before executing any runbook in this section, confirm:

```
[ ] kubectl is configured for the correct cluster and namespace
[ ] rover CLI is installed and authenticated (rover config list)
[ ] Helm 3 is installed (helm version)
[ ] Access to Grafana dashboard: https://grafana.internal.example.com/d/graphql-platform
[ ] Access to Tempo traces: https://tempo.internal.example.com
[ ] Access to #graphql-incidents Slack channel
[ ] PagerDuty incident is open and acknowledged (for incident runbooks)
```

---

## Rollback Philosophy

Every deployment runbook includes a rollback procedure. The guiding principles are:

1. **Rollback first, diagnose second.** If an error rate spike begins within 15 minutes of a deployment, roll back before investigating root cause. The goal is to restore service, not to be right.
2. **Helm rollback is the primary mechanism.** `helm rollback` restores the previous Helm release revision atomically, including all values and chart version.
3. **Schema publishes require an additional step.** If a subgraph schema was published to the registry before rollback, publish the previous schema version after rolling back the Kubernetes deployment.
4. **Document every rollback.** Post a message in #graphql-incidents with: what was rolled back, when, who executed it, and what the error rate was before and after.

---

## Related Topics

- [14-observability/05-slos-and-alerting.md](../14-observability/05-slos-and-alerting.md) — SLO definitions and alert rules that trigger runbook execution
- [33-incident-management/README.md](../33-incident-management/README.md) — Incident lifecycle, severity levels, and on-call procedures
- [11-ci-cd-automation/README.md](../11-ci-cd-automation/README.md) — CI/CD pipeline that runs before runbooks are needed
- [13-policy-as-code/README.md](../13-policy-as-code/README.md) — Automated gates that prevent the incidents these runbooks address
