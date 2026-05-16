# 02 — GraphQL On-Call Handbook

> **Purpose**
> This document is the operational handbook for engineers on call for the GraphQL platform. It covers the first-5-minute response procedure, the GraphQL-specific diagnostic sequence, required dashboard bookmarks, communication templates, escalation triggers, and the on-call handoff checklist. Written to be read in-context during an actual incident — concise, action-oriented, concrete.

---

## First 5 Minutes

The goal of the first 5 minutes is not to diagnose the root cause. The goal is to understand the blast radius, open the incident channel, and make sure the right people are looped in. Diagnosis follows.

### Minute 1: Acknowledge

1. Acknowledge the PagerDuty alert. This stops the escalation clock.
2. Open the alert notification and read the `summary` and `description` fields.
3. Note the `runbook_url` in the alert — open it in a separate tab.

**Key fields to extract from the alert:**
```
- alertname:      What fired (e.g., GraphQLErrorRateCritical)
- severity:       critical / high / warning
- slo:            Which SLO is breaching
- burn_rate:      Current budget consumption rate
- runbook_url:    Direct link to this specific playbook
- dashboard_url:  Grafana SLO dashboard
```

### Minute 2: Assess Scope

Open the Grafana SLO dashboard (bookmark required — see Dashboard Bookmarks section). Answer three questions in under 60 seconds:

1. **Is the error rate rising, stable, or recovering?** Check the 5-minute error rate panel.
2. **Is this all operations or a subset?** Check the per-subgraph error rate panel.
3. **What is the current SLO burn rate?** Check the burn rate panel — is it above 14.4x (SEV1) or 6x (SEV2)?

**Classification:**
- All operations affected + burn rate > 14.4x → SEV1
- One subgraph affected + burn rate > 6x → SEV2
- Latency only, no complete errors → SEV3
- Narrow scope, burn rate < 3x → SEV4 (consider downgrading)

### Minute 3: Open Incident Channel

Open a Slack channel using the naming convention `#inc-YYYYMMDD-{description}`. Post the first status message using the template below. Pin it immediately.

```
:fire: INCIDENT OPENED — SEV{N}
Time:       2026-05-16 14:23 UTC
Severity:   SEV2
Summary:    orders subgraph returning complete errors — ~15% of operations affected
Commander:  @your-name
Scribe:     (assign someone if others join)
Dashboard:  https://grafana.internal.example.com/d/graphql-slo
Runbook:    https://runbooks.internal.example.com/graphql/subgraph-down
Status:     INVESTIGATING
```

### Minute 4: Notify Stakeholders

Based on severity:
- **SEV1:** Post in `#graphql-platform-oncall` and `#engineering-incidents` immediately. Tag the engineering lead.
- **SEV2:** Post in `#graphql-platform-oncall`. Tag the subgraph team owner if already identified.
- **SEV3/4:** Post in `#graphql-platform-oncall` — no tags, no urgent escalation.

### Minute 5: Start the Diagnostic Sequence

Open the incident channel and post: `Starting diagnostic sequence`. Then follow the section below.

---

## GraphQL Diagnostic Sequence

This sequence is designed specifically for GraphQL federated platforms. Follow it in order — each question narrows the scope and points to a specific playbook.

```
Step 1: Is it one operation or all operations?
        ↓
Step 2: Is it one subgraph or all subgraphs?
        ↓
Step 3: Is it latency or complete errors?
        ↓
Step 4: Correlate with recent deployments
        ↓
Step 5: Open a representative trace
```

### Step 1 — One Operation or All Operations?

**Query to run (bookmark this):**
```promql
# Count of operation names with non-zero error rate in last 5 minutes
count(
  sum by (operation_name) (
    rate(apollo_router_graphql_error_total[5m])
  ) > 0
)
```

**Interpretation:**
- Count = 1–5 operation names: Narrow blast radius. Likely one subgraph or one resolver path.
- Count = dozens to hundreds: Wide blast radius. Likely router, auth, or schema composition issue.
- Count = 0 but alerts are firing: Check if the alert is for latency (not error rate). Proceed to step 3.

**If one operation:** identify which operation name and which field path appears in `errors[].path`. This directly maps to a subgraph.

### Step 2 — One Subgraph or All Subgraphs?

**Query to run:**
```promql
# Per-subgraph error rate, sorted descending
topk(10,
  sum by (subgraph_name) (
    rate(apollo_router_subgraph_request_error_total[5m])
  )
)
```

**Interpretation:**
- One subgraph_name has non-zero rate, others are zero: Subgraph incident. Go to the relevant playbook in `03-incident-response-playbooks.md`. Notify that subgraph team owner.
- Multiple subgraph_names have non-zero rates: Possible router issue or a shared dependency (database, auth service). Escalate to platform team.
- No subgraph has non-zero rate but router error rate is high: Router-level issue. Not reaching subgraphs. Check router logs.

**If one subgraph — check subgraph health directly:**
```bash
# Check pod status for the affected subgraph
kubectl get pods -n graphql -l app=orders-subgraph

# Check recent pod events
kubectl describe pod -n graphql -l app=orders-subgraph | tail -40

# Stream recent logs
kubectl logs -n graphql -l app=orders-subgraph --since=10m --tail=100
```

### Step 3 — Latency or Complete Errors?

**Latency check:**
```promql
# p99 latency by operation category over last 10 minutes
histogram_quantile(0.99,
  sum by (le, operation_type) (
    rate(apollo_router_graphql_request_duration_seconds_bucket[10m])
  )
) * 1000  # convert to ms
```

**Baseline for comparison:**
- Interactive queries (GET /graphql?query=...): p99 baseline ~150ms. Alert at 300ms.
- Mutations: p99 baseline ~200ms. Alert at 400ms.
- Background queries: p99 baseline ~2000ms. Alert at 4000ms.

**If latency elevated but no complete errors:** This is SEV3. Check for:
1. DataLoader N+1 regression (batch size drop)
2. Slow database query introduced by recent schema change
3. Cold query plan cache after a router deployment (resolves within 5 minutes naturally)

### Step 4 — Correlate with Recent Deployments

**Check deployment history:**
```bash
# Recent deployments in the graphql namespace
kubectl rollout history deployment -n graphql

# Check specific deployment rollout time
kubectl rollout history deployment/apollo-router -n graphql
kubectl rollout history deployment/orders-subgraph -n graphql

# When did the incident start vs. when did the deployment complete?
```

**Check deployment annotation in Grafana:**
The SLO dashboard has a deployment annotation overlay. Look for a vertical line at the time the error rate began rising. If a deployment correlates with the incident start, rollback is likely the fastest mitigation.

**Rollback command:**
```bash
# Rollback a subgraph deployment
kubectl rollout undo deployment/orders-subgraph -n graphql

# Rollback the router
kubectl rollout undo deployment/apollo-router -n graphql
```

### Step 5 — Open a Representative Trace

Use Grafana Tempo or the Grafana Explore tab with the Tempo data source.

**Tempo query for error traces:**
```
{resource.service.name="apollo-router"} | json | graphql_error_type = "complete"
```

**What to look for in the trace:**
1. Which span is the slowest or erroring?
2. Is the error originating from a subgraph HTTP call (look for `http.url` with subgraph hostname)?
3. Is the error originating from query planning (look for `graphql.operation.plan_ms` being abnormally high)?
4. Are there timeout spans (look for spans with `otel.status_code = ERROR` and `timeout` in the description)?

**Share the trace ID in the incident channel** so other responders can follow along without repeating the same investigation steps.

---

## Required Dashboard Bookmarks

All on-call engineers must have these dashboards bookmarked before going on call. Check them during incident on-call onboarding.

### 1. GraphQL SLO Dashboard

```
URL:     https://grafana.internal.example.com/d/graphql-slo
Purpose: Error budget remaining, burn rate over time, SLO status table
Key panels:
  - Error Budget Remaining (gauge — goal: > 75%)
  - Error Budget Burn Rate 1h/6h (time series — page threshold: 14.4x)
  - Complete Error Rate by Operation Type
  - p99 Latency by Operation Category
  - Deployment annotations
```

### 2. Router Metrics Dashboard

```
URL:     https://grafana.internal.example.com/d/apollo-router
Purpose: Router health — CPU, memory, request rate, query plan cache
Key panels:
  - Router CPU usage (alert threshold: 80%)
  - Router memory usage (alert threshold: 2GB)
  - Query plan cache hit rate (healthy: > 90%)
  - Concurrent connections
  - Request rate by operation type
```

### 3. Subgraph Health Dashboard

```
URL:     https://grafana.internal.example.com/d/subgraph-health
Purpose: Per-subgraph error rate, latency, DataLoader batch size
Key panels:
  - Error rate by subgraph (heatmap)
  - p99 latency by subgraph
  - DataLoader batch size p5 (N+1 detector — healthy: > 5)
  - Pod restart count per subgraph
```

### 4. Tempo Trace Search

```
URL:     https://grafana.internal.example.com/explore?datasource=tempo
Purpose: Search for error traces by operation name, time range, subgraph
Example search:
  {resource.service.name="apollo-router"} | json | graphql_error_type="complete"
  | select trace_id, graphql_operation_name, duration, subgraph_error_source
```

### 5. Loki Log Query for Errors

```
URL:     https://grafana.internal.example.com/explore?datasource=loki
Purpose: Structured logs from router and subgraphs during incident window
Example query (Loki LogQL):
  {app="apollo-router"} |= "error" | json
  | line_format "{{.timestamp}} [{{.level}}] {{.message}} operation={{.graphql_operation_name}}"

Subgraph-specific:
  {app="orders-subgraph"} | json | level="error" | line_format "{{.timestamp}} {{.message}} {{.error}}"
```

---

## Communication Templates

Use these templates verbatim during incidents. Do not improvise when under pressure.

### Internal Slack — Incident Open

```
:fire: *INCIDENT OPENED*
*Severity:* SEV{N} — {one-line description}
*Time:* {ISO timestamp UTC}
*Affected:* {operations or subgraphs affected}
*Current error rate:* {X}% complete errors / p99 latency {X}ms
*SLO burn rate:* {X}x ({Y} days to budget exhaustion)
*Commander:* @{name}
*Dashboard:* {url}
*Runbook:* {url}
*Status:* INVESTIGATING
```

### Internal Slack — Status Update (every 10-20 min)

```
:information_source: *INCIDENT UPDATE* [{timestamp}]
*Status:* INVESTIGATING / MITIGATING / MONITORING
*Current error rate:* {X}% (was {Y}% at incident open)
*What we know:* {1-2 sentences on root cause hypothesis}
*What we're doing:* {current action}
*Next update:* {timestamp}
```

### Internal Slack — Mitigation Applied

```
:white_check_mark: *MITIGATION APPLIED* [{timestamp}]
*Action taken:* {description — e.g., "rolled back orders-subgraph to v1.4.2"}
*Error rate now:* {X}% (target: < 0.1%)
*Monitoring:* We will confirm stability over the next 15 minutes.
*Next update:* {timestamp or "at resolution"}
```

### Internal Slack — Incident Resolved

```
:tada: *INCIDENT RESOLVED* [{timestamp}]
*Duration:* {X} minutes
*Root cause (preliminary):* {1-2 sentences}
*Mitigation:* {what was done}
*SLO budget consumed:* approximately {X}% of monthly budget
*Post-mortem:* {"required by {date}" or "lightweight retrospective in this channel"}
*Action items:* {0–3 immediate follow-up items}
```

### Status Page Update (external — SEV1 only)

```
Title: GraphQL API — Elevated Error Rate

{Time}: We are investigating elevated error rates affecting the GraphQL API.
Some users may experience failures when loading [affected features].
Our team is actively working to resolve this. We will provide updates every 15 minutes.

{Time}: We have identified the root cause: [one sentence, no internal jargon].
We are implementing a fix. The estimated time to resolution is [X] minutes.

{Time}: This incident is resolved. Normal service has been restored.
The GraphQL API is returning [metric: error rate, latency] at expected levels.
A full post-mortem will be published at [URL] within 5 business days.
```

### Customer Notification Email (SEV1, external impact confirmed)

```
Subject: Service Disruption — GraphQL API [Date]

We are writing to inform you of a service disruption affecting the [Product Name] API
between [start time] and [end time] UTC.

Impact: [One sentence describing what was broken and how customers were affected.]

Root cause: [One sentence, non-technical where possible.]

Resolution: [One sentence describing what was fixed.]

We apologize for the disruption and are taking the following steps to prevent recurrence:
1. [Action item]
2. [Action item]

If you have questions, contact [support email].

[Name], [Team]
```

---

## Escalation Triggers

These are the conditions under which you must escalate, even if you believe you are making progress.

### Escalate to Engineering Lead

Escalate immediately if **any** of these are true:
- Incident has been open for > 30 minutes with no mitigation applied
- Error rate is not improving 15 minutes after mitigation attempt
- Root cause is a data corruption issue (any concern about data integrity)
- External customers have confirmed impact and are waiting for communication
- The incident requires a cross-team decision (e.g., should we disable a critical feature?)

**How to escalate:**
1. Post in the incident channel: `@engineering-lead escalating — [one-sentence reason]`
2. Page via PagerDuty manually if no response in 5 minutes
3. If still no response: call the secondary escalation contact

### Escalate to Subgraph Team Owner

Escalate to a subgraph team owner when:
- The affected subgraph has been identified via the diagnostic sequence
- The subgraph error rate is non-zero and not recovering
- You need to make a change to the subgraph code or configuration
- A rollback requires the subgraph team's explicit approval

**Subgraph team owner contact list:**

| Subgraph | Team | Primary Contact | Slack Handle |
|----------|------|-----------------|--------------|
| `products` | Catalog Team | On-call rotation | `#catalog-oncall` |
| `orders` | Commerce Team | On-call rotation | `#commerce-oncall` |
| `identity` | Auth Team | On-call rotation | `#auth-oncall` |
| `inventory` | Warehouse Team | On-call rotation | `#warehouse-oncall` |
| `pricing` | Revenue Team | On-call rotation | `#revenue-oncall` |
| `reviews` | Community Team | On-call rotation | `#community-oncall` |

### Escalate to Engineering Leadership

Escalate to VP Engineering if:
- SEV1 has been open > 45 minutes with no mitigation
- External customer impact is confirmed and growing
- A production database rollback is required
- The incident involves a potential security breach

---

## On-Call Handoff Checklist

At the end of each on-call shift (typically weekly), complete this handoff before handing off to the next engineer.

### State Transfer

```
[ ] All open incidents are documented in the incident channel with current status
[ ] Any ongoing investigations have a written summary of findings so far
[ ] Any changes made to production during the shift are documented
    (config changes, scaling events, manual interventions)
[ ] Grafana dashboards are in the expected state (no leftover incidents)
[ ] Alert silence rules: any silences are reviewed and extended or expired
```

### Handoff Communication

Post in `#graphql-platform-oncall`:

```
:handshake: *ON-CALL HANDOFF*
*Outgoing:* @{name} (shift: {start date} – {end date})
*Incoming:* @{name}

*Shift summary:*
  - Incidents this week: {N}
  - SEV1: {N}, SEV2: {N}, SEV3: {N}, SEV4: {N}
  - SLO error budget consumed this week: ~{X}% of monthly budget
  - Post-mortems due: {list or "none"}

*Active investigations:*
  {list or "none"}

*Production changes made during shift:*
  {list — date, change, who made it}

*Known fragile areas to watch:*
  {list or "none"}

*Handoff complete:* {timestamp}
```

### Pre-On-Call Readiness Check

Run this checklist before *starting* an on-call shift:

```
[ ] PagerDuty account configured with correct phone number
[ ] Grafana dashboards load correctly (test each bookmark)
[ ] kubectl access to the graphql namespace working
    (kubectl get pods -n graphql)
[ ] Slack notifications enabled for #graphql-platform-oncall and #graphql-incidents
[ ] Subgraph team owner contact list reviewed and up to date
[ ] Read the post-mortems from the last 30 days
[ ] Reviewed the backlog for any in-progress reliability work that may affect this week
[ ] Engineering lead contact information confirmed
```

---

## Common Gotchas for New On-Call Engineers

**GraphQL HTTP 200 does not mean success.** Always check the `error_type="complete"` metric, not just HTTP 5xx.

**Query plan cache cold start is expected.** After any router deployment, the plan cache hit rate will drop to 0% for 2–5 minutes. p99 latency will spike briefly. This is normal and will self-resolve. Do not page anyone for this.

**Schema composition failures do not affect live traffic immediately.** A failing CI check for schema composition means new subgraph versions cannot be deployed. The current schema in production continues serving. Classify as SEV2 (blocking deployments) but no immediate customer impact.

**DataLoader N+1 regressions are subtle.** A subgraph that had DataLoader batching disabled by a code change will start making individual database queries per field instead of batched queries. The error rate stays zero. Latency rises gradually. p99 spikes. Look for DataLoader batch size dropping in the subgraph health dashboard.

**Router OOM is almost always a query complexity problem.** When the router pods are OOM-killed in a loop, the cause is almost always a client sending an unbounded query that allocates a large response object. Check the complexity score histogram for outliers before scaling up memory.

---

## Related Topics

- [01-incident-classification.md](./01-incident-classification.md) — Severity levels and decision matrix
- [03-incident-response-playbooks.md](./03-incident-response-playbooks.md) — Step-by-step playbooks for specific incident types
- [14-observability/02-distributed-tracing.md](../14-observability/02-distributed-tracing.md) — How to use traces during diagnosis
- [14-observability/03-metrics.md](../14-observability/03-metrics.md) — Full metric reference

## References

- [Google SRE Book — Emergency Response](https://sre.google/sre-book/emergency-response/)
- [PagerDuty On-Call Fundamentals](https://response.pagerduty.com/oncall/being_oncall/)
- [Apollo Router Troubleshooting](https://www.apollographql.com/docs/router/configuration/overview/)
- [Grafana Tempo Query Language](https://grafana.com/docs/tempo/latest/traceql/)
- [Loki LogQL Reference](https://grafana.com/docs/loki/latest/query/)
