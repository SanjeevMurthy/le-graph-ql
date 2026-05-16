# 04 — Blameless Post-Mortem Process

> **Purpose**
> This document defines the blameless post-mortem process for GraphQL platform incidents. It covers the post-mortem template, the 5 Whys technique applied to a real GraphQL incident pattern, action item categories and ownership, the process for tracking action items in the platform backlog, and the cultural practices that make post-mortems valuable rather than performative. Written for incident commanders, platform leads, and engineering managers who own the reliability improvement cycle.

---

## What Is a Blameless Post-Mortem?

A blameless post-mortem assumes that engineers act in good faith with the information and tools available to them at the time. When a system fails, the question is not "who made the mistake?" but "what properties of the system made this failure possible, and what can we change to make it less likely or easier to detect?"

**The blameless principle in practice:**
- Describe actions taken during the incident without judgment ("the engineer rolled back the deployment" not "the engineer made the wrong call")
- Focus on system properties: alerting gaps, missing safeguards, inadequate testing, unclear runbooks
- Recognize that the same engineer, given the same information and the same system, would make the same decision again — the system must change, not the person

**What post-mortems are not:**
- A forum to assign fault or document who was "responsible"
- A compliance exercise to satisfy a process checkbox
- A retrospective on every decision made during the incident (only the system design decisions)

---

## When Is a Post-Mortem Required?

### Mandatory

- Any SEV1 incident
- Any SEV2 incident that consumed > 20% of the monthly SLO error budget
- Any incident involving data loss or data corruption
- Any incident that recurs for the third time within 90 days

### Recommended

- SEV2 incidents consuming 5–20% of error budget
- SEV3 incidents lasting > 4 hours
- Any incident that exposed a significant gap in monitoring, alerting, or runbooks

### Optional

- SEV4 incidents (lightweight retrospective in incident channel is sufficient)
- SEV3 incidents resolved in < 1 hour

---

## Post-Mortem Timeline

```
T+0           Incident resolved
T+24 hours    Incident commander drafts the post-mortem document
              Circulates to all participants for timeline review
T+48 hours    Post-mortem meeting — 30–60 minutes
              Attendees: incident responders + engineering lead + subgraph team leads
T+72 hours    Action items assigned and added to platform backlog
T+5 business  Post-mortem document finalized and published to team wiki
  days
T+30 days     First action item checkpoint — are the items making progress?
T+90 days     Second action item checkpoint — are the items closed?
```

---

## Post-Mortem Template

Use this template for every post-mortem document. Store documents in the team wiki at `wiki/post-mortems/YYYY-MM-DD-{title}.md`.

```markdown
# Post-Mortem: {Incident Title}

**Date:** {YYYY-MM-DD}
**Duration:** {start time UTC} – {end time UTC} ({N} minutes)
**Severity:** SEV{N}
**Incident Commander:** {Name}
**Scribe:** {Name}
**Participants:** {Comma-separated list}
**Document Author:** {Name}
**Review Status:** DRAFT / REVIEWED / FINAL

---

## Incident Summary

{2–4 sentences. What happened, what was the user impact, how was it resolved.
No jargon. Should be readable by an engineering manager without context.}

**Example:**
On 2026-05-16 at 14:23 UTC, the `orders` subgraph began returning timeout errors
for all requests. This caused the `CheckoutOrder` and `GetOrderHistory` GraphQL
operations to fail completely for all users. The incident lasted 47 minutes.
Root cause was an unindexed database query introduced in the 14:00 UTC deployment.
We mitigated by rolling back the subgraph to the previous version and adding the
missing database index in a follow-up deployment.

---

## Impact

- **Users affected:** {N} users (or: all authenticated users, or: users using the checkout flow)
- **Operations affected:** `{OperationName1}`, `{OperationName2}`
- **Error rate during incident:** {X}% complete errors (peak), {Y}% average during incident
- **SLO error budget consumed:** approximately {Z}% of monthly budget
  - Budget remaining after incident: {W}% of monthly budget
- **Revenue impact:** {estimated or "not quantified"}
- **External customer notification sent:** Yes / No

---

## Timeline

All times UTC.

| Time | Event | Who / What |
|------|-------|------------|
| 14:00 | `orders-subgraph` v2.3.4 deployed | Automated deployment pipeline |
| 14:00 | Deployment health check passed | Kubernetes readiness probe |
| 14:07 | First error alerts fire in Prometheus | PagerDuty pages on-call |
| 14:09 | On-call acknowledges alert | @oncall-engineer |
| 14:12 | Incident channel opened: #inc-20260516-orders-timeout | @oncall-engineer |
| 14:15 | Subgraph identified: orders p99 = 8,200ms | @oncall-engineer (via dashboard) |
| 14:18 | Deployment correlation identified | @oncall-engineer |
| 14:22 | Subgraph team lead notified | @oncall-engineer → @orders-team-lead |
| 14:30 | Rollback decision made and executed | @orders-team-lead, @oncall-engineer |
| 14:35 | Rollback complete; orders p99 returning to baseline | Kubernetes rollout status |
| 14:47 | Error rate confirmed below SLO threshold | Grafana SLO dashboard |
| 14:50 | Incident resolved; post-mortem scheduled | @oncall-engineer |

---

## Root Cause

{1–3 sentences. Be specific. Name the exact technical change that caused the failure.}

**Example:**
A new filter parameter `order.status` was added to the `GetOrderHistory` query in
`orders-subgraph` v2.3.4. The corresponding database query used a `WHERE status = ?`
clause against the `orders` table. The `orders` table had no index on the `status`
column. At the production load of 500 queries/second, each query performed a full
table scan against the 4.2M-row orders table, causing query times of 6–8 seconds
and exhausting the subgraph's database connection pool.

---

## Contributing Factors

List all factors that contributed to the incident occurring or to its impact. These
are the inputs to the 5 Whys analysis and action items.

1. **No query performance testing in CI** — The slow query was not detected before
   deployment because there is no automated query analysis step in the subgraph CI pipeline.

2. **No database index change review requirement** — The deployment process does not
   require engineers to document and review database schema changes (including index additions).

3. **Readiness probe did not test the slow endpoint** — The Kubernetes readiness probe
   only checked `/health`. The `GET /graphql?query=...` endpoint with a real query was
   not tested before traffic was routed to the new pods.

4. **No canary deployment** — The deployment went to 100% of pods simultaneously.
   A 10% canary would have surfaced the latency issue at 50 queries/second before
   full rollout.

5. **Subgraph timeout was 30s (default)** — The router waited 30 seconds for each
   slow subgraph response. A 2-second timeout would have reduced user-facing impact
   from 6–8 seconds per request to 2 seconds per request, while still producing errors.

---

## 5 Whys Analysis

The 5 Whys technique asks "why" repeatedly until the root systemic cause is identified.

**Symptom:** Users could not complete checkout or view order history for 47 minutes.

**Why 1:** Why were users unable to complete checkout?
- The `orders` subgraph was timing out, causing the `CheckoutOrder` mutation to fail completely.

**Why 2:** Why was the `orders` subgraph timing out?
- A new database query was performing full table scans against a 4.2M-row table under production load, exhausting the connection pool in < 10 seconds.

**Why 3:** Why did a slow query reach production?
- There is no automated query performance testing in the CI pipeline. The query was only tested on a developer's local machine with a small dataset (500 rows), where it completed in 8ms.

**Why 4:** Why is there no automated query performance testing in CI?
- The `orders` team added the feature quickly to meet a product deadline. The performance test infra (a staging database with production-scale data) exists but is not wired into CI as a mandatory step.

**Why 5:** Why is the performance test infrastructure not a mandatory CI gate?
- No explicit policy requires it. The platform team's CI/CD guidelines recommend performance testing but do not enforce it. There is no code ownership review that flags missing test coverage for new query parameters.

**Root systemic cause:** The absence of a mandatory CI performance test gate for new query patterns, combined with the absence of a canary deployment policy, allowed a slow query to reach full production load without early detection.

---

## Action Items

Action items are classified into three categories: immediate fix, detection improvement, and prevention mechanism. Each item has an owner and a due date.

### Immediate Fix

Items that address the specific root cause and should be completed within 1 week.

| Item | Owner | Due Date | Priority |
|------|-------|----------|----------|
| Add index `orders(status)` to production database | @orders-dba | 2026-05-17 | P0 — done |
| Reduce orders subgraph router timeout from 30s to 3s | @platform-engineer | 2026-05-18 | P1 |
| Add `/health/ready?full=true` endpoint that tests a representative query | @orders-engineer | 2026-05-23 | P1 |

### Detection Improvement

Items that would have shortened the detection or diagnosis time. Complete within 30 days.

| Item | Owner | Due Date | Priority |
|------|-------|----------|----------|
| Add DataLoader batch size drop alert (N+1 detector) to orders subgraph metrics | @platform-sre | 2026-06-01 | P2 |
| Add slow query log alert: log + alert when orders DB query > 500ms | @orders-dba | 2026-06-01 | P2 |
| Add deployment annotation to Grafana that overlays DB migration events | @platform-engineer | 2026-06-15 | P3 |

### Prevention Mechanism

Items that prevent this category of failure from occurring in the future. Complete within 90 days.

| Item | Owner | Due Date | Priority |
|------|-------|----------|----------|
| Make EXPLAIN ANALYZE in CI a required step for PRs that add new query parameters | @orders-lead | 2026-08-01 | P2 |
| Add canary deployment policy to `orders` subgraph CI — 10% canary for 10 min before full rollout | @platform-engineer | 2026-07-15 | P2 |
| Add query performance test to staging CI: run new operation against production-scale staging DB | @orders-engineer | 2026-08-01 | P2 |
| Document "adding a new filter parameter" procedure in `orders` subgraph contribution guide | @orders-lead | 2026-07-01 | P3 |

---

## What Went Well

Document practices that worked correctly during the incident, to reinforce them.

- The deployment correlation was identified within 9 minutes of incident open. The rollout history command was readily available and familiar to the on-call engineer.
- The subgraph team lead responded and joined the incident channel within 8 minutes of notification — faster than the 15-minute SLA.
- The rollback procedure was clean and completed in 5 minutes. The `kubectl rollout undo` command worked without issues.
- Communication cadence was maintained — updates were posted every 10 minutes as required.

---

## Lessons Learned

{2–4 sentences on the broader lesson, applicable beyond this specific incident.}

Database query performance is not visible to GraphQL schema reviewers or infrastructure engineers without an explicit testing step. Any schema change that adds a new filter or sort field introduces a new database query path that must be tested at scale. The rollback procedure worked well, which validates the investment in Kubernetes deployment strategies over in-place hot patches.

---

## Appendix: Metrics During Incident

```
Complete error rate (peak): 42%
Complete error rate (avg during incident): 28%
SLO burn rate (peak 1h window): 420x
SLO error budget consumed: approximately 29% of monthly budget
orders subgraph p99 (during incident): 8,200ms
orders subgraph p99 (baseline): 180ms
MTTD (alert to incident open): 9 minutes
MTTR (incident open to resolved): 47 minutes
Time from deployment to first error: 7 minutes
```
```

---

## Action Item Tracking

### In the Platform Backlog

All action items from post-mortems are tracked in the platform engineering backlog with:

```
Title:      [PM-YYYY-MM-DD] {action item description}
Label:      post-mortem-action
Priority:   P0 / P1 / P2 / P3
Owner:      Assigned engineer
Due date:   From post-mortem document
Status:     TODO / IN PROGRESS / DONE / DEFERRED
Notes:      Link to post-mortem document
```

**Tracking query (GitHub Issues / Linear / Jira):**
Filter by label `post-mortem-action` to see all outstanding post-mortem work. Review in the weekly platform sync.

### SLA by Action Item Category

| Category | SLA |
|----------|-----|
| Immediate fix (P0) | 24 hours |
| Immediate fix (P1) | 1 week |
| Detection improvement | 30 days |
| Prevention mechanism | 90 days |

Items that slip beyond their SLA must be explicitly triaged: deferred with documented reason, re-prioritized, or escalated to engineering lead.

### Accountability

The incident commander owns the post-mortem document through finalization. After finalization, the platform team lead owns the action item completion. Engineering lead reviews outstanding post-mortem action items monthly.

---

## Sharing Post-Mortems Across Teams

Post-mortems are valuable only if the lessons reach engineers who were not in the incident. The following practices build a learning culture:

### Publication

1. Publish every final post-mortem to the team wiki at `wiki/post-mortems/`
2. Post the link in `#engineering-all` (or the equivalent all-engineering channel) with a one-sentence summary: *"Post-mortem published: orders timeout incident — root cause: missing DB index. Key action: making query performance testing mandatory in CI."*

### Monthly Review

Schedule a 30-minute "incident review" monthly in the platform sync:
- Review all post-mortems from the previous 30 days
- Highlight any recurring patterns across incidents
- Review action item completion status

### Pattern Tracking

Track incidents across quarters for recurrence analysis:

| Pattern | Count Last Quarter | Count This Quarter | Trend |
|---------|-------------------|-------------------|-------|
| Missing database index | 2 | 1 | Improving |
| DataLoader singleton | 1 | 0 | Resolved |
| Subgraph timeout cascade | 2 | 2 | Flat — prevention needed |
| Schema composition failure | 3 | 1 | Improving |

If the same pattern recurs across two quarters, escalate to a dedicated platform reliability sprint.

---

## Platform Reliability Metrics to Track Over Time

Track these metrics quarterly to measure the effectiveness of the post-mortem program:

### MTTD — Mean Time to Detect

```
MTTD = average time from incident start to first alert
```

Target: < 5 minutes for SEV1, < 15 minutes for SEV2.
Improvement lever: better alerting thresholds, shorter evaluation periods, more granular metrics.

### MTTR — Mean Time to Resolve

```
MTTR = average time from incident open to incident resolved
```

Target: < 30 minutes for SEV1, < 60 minutes for SEV2.
Improvement lever: better runbooks, more practiced rollback procedures, faster mitigation tooling.

### Incident Recurrence Rate

```
Recurrence rate = incidents caused by a previously-seen pattern / total incidents
```

Target: < 10% recurrence rate.
Improvement lever: action item completion rate, deeper 5 Whys analysis, better prevention mechanisms.

### Error Budget Consumed Per Incident

```
Budget per incident = error budget consumed during incident / monthly error budget
```

Target: < 20% per incident.
Improvement lever: faster MTTR, better partial-failure handling (partial data vs. complete failure).

### Sample Quarterly Report

```
Q2 2026 — GraphQL Platform Reliability Report

Total incidents:      12
  SEV1:               2
  SEV2:               7
  SEV3:               3

MTTD (median):        4.2 minutes (Q1 baseline: 7.8 minutes) ↑ Improved
MTTR (median):        23 minutes  (Q1 baseline: 41 minutes)  ↑ Improved
Recurrence rate:      8%          (Q1 baseline: 22%)         ↑ Improved

Error budget consumed this quarter: 47% of quarterly budget
  Largest single incident: orders subgraph timeout — 29% of monthly budget
  Second largest: auth JWKS outage — 11% of monthly budget

Top recurring pattern: Subgraph timeout cascade (3 incidents)
  Action: Subgraph timeout limit enforcement — planned for Q3

Post-mortem action items:
  Total items created this quarter: 28
  Items closed:  19 (68%)
  Items pending: 7  (25%)
  Items deferred: 2 (7%)
```

---

## Anti-Patterns to Avoid

**Action items with no owner.** An unassigned action item will never be completed. Every item must have a named individual, not a team.

**Action items that are "monitor X."** Monitoring is not an action item — it is the absence of one. Replace with "add alert for X" or "add dashboard panel for X."

**Post-mortems written weeks after the incident.** Memory fades and details are lost. Draft the timeline within 24 hours while events are fresh.

**Blame language in the timeline.** Avoid: "the engineer failed to test this before deploying." Use: "the deployment process did not require this type of test."

**Action items closed without verification.** An item is not done until the fix is deployed and tested. "Created the PR" is not done. "PR merged and deployed to production" is done.

**Post-mortems published to a wiki no one reads.** Post the link in public engineering channels with a one-sentence summary. The act of sharing is as important as the act of writing.

---

## Related Topics

- [01-incident-classification.md](./01-incident-classification.md) — Severity definitions that trigger post-mortem requirements
- [02-on-call-procedures.md](./02-on-call-procedures.md) — Incident timeline documentation during the incident
- [03-incident-response-playbooks.md](./03-incident-response-playbooks.md) — Playbooks that improve MTTR
- [05-chaos-engineering.md](./05-chaos-engineering.md) — Proactive failure testing to reduce incident frequency
- [14-observability/05-slos-and-alerting.md](../14-observability/05-slos-and-alerting.md) — Error budget policy

## References

- [Google SRE Book — Postmortem Culture](https://sre.google/sre-book/postmortem-culture/)
- [Google SRE Workbook — Postmortem Examples](https://sre.google/workbook/postmortem-culture/)
- [PagerDuty Post-Mortem Guide](https://postmortems.pagerduty.com/)
- [The 5 Whys Technique](https://en.wikipedia.org/wiki/Five_whys)
- [Etsy — Blameless Post-Mortems](https://www.etsy.com/codeascraft/blameless-postmortems/)
