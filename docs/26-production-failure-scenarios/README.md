# Chapter 26: Production Failure Scenarios

> **Purpose:** This chapter documents common failure modes and incident patterns specific to GraphQL in production. Each scenario is written as an incident post-mortem: what happened, why it happened, how to detect it before it becomes an incident, how to mitigate it during an incident, and how to prevent recurrence through engineering changes. These are not hypothetical — each scenario is a composite of real incidents across enterprise GraphQL deployments. Engineers on-call for GraphQL services and architects designing new systems should read this chapter to build the institutional knowledge that typically only comes from surviving an incident firsthand.

---

## Why GraphQL Has Distinct Failure Modes

REST APIs fail in predictable ways: a 5xx on `/users/123` means the Users service is down. Metrics on that endpoint tell you exactly what broke. Rollback means reverting one endpoint.

GraphQL fails differently:

1. **A single query can touch dozens of services.** A schema failure in one resolver can null-propagate across the response in ways that are difficult to trace without distributed tracing.
2. **Query flexibility is also query attack surface.** Clients can construct queries that are orders of magnitude more expensive than the schema author anticipated.
3. **Schema changes break clients silently.** A renamed field returns null. The client renders blank. No HTTP error is generated.
4. **Connection-oriented protocols (WebSocket subscriptions) have connection storm characteristics** that HTTP/1.1 request floods do not.
5. **Federation composes multiple teams' schemas.** One team's breaking change can block all teams' deployments.

Each scenario in this chapter corresponds to one of these failure categories.

---

## Failure Scenario Index

| File | Scenario | Failure Category | Severity |
|---|---|---|---|
| [01-query-complexity-bomb.md](./01-query-complexity-bomb.md) | Deep nested query causes router OOM | Query attack surface | P1 |
| [02-n-plus-one-at-scale.md](./02-n-plus-one-at-scale.md) | Missing DataLoader causes DB pool exhaustion | Performance regression | P1 |
| [03-schema-breaking-change-incident.md](./03-schema-breaking-change-incident.md) | Field rename breaks mobile clients | Schema contract violation | P1 |
| [04-federation-composition-failure.md](./04-federation-composition-failure.md) | Subgraph change breaks supergraph composition | Federation governance failure | P2 |
| [05-subscription-storm.md](./05-subscription-storm.md) | Mobile reconnect bug causes WebSocket storm | Protocol-level attack surface | P1 |

---

## How to Read These Scenarios

Each document follows the same structure:

1. **Scenario Summary** — one paragraph, the incident in plain language
2. **System State Before the Incident** — what was in place (or not in place)
3. **Incident Timeline** — chronological sequence with timestamps
4. **Mermaid Sequence Diagram** — visual representation of the failure propagation
5. **Root Cause Analysis** — the technical explanation of why it happened
6. **Detection Signals** — the metrics and alerts that fired (or should have fired)
7. **PromQL Queries** — concrete alert rules for this failure class
8. **Immediate Mitigation** — what to do in the first 30 minutes
9. **Remediation** — the engineering fix applied after the incident
10. **Prevention** — the architectural and process changes that prevent recurrence
11. **References** — related documentation and tools

---

## Prerequisites

- [Chapter 05: Security](../05-security/README.md) — security mitigations relevant to query complexity and subscription flooding
- [Chapter 07: Apollo Federation v2](../07-federation/README.md) — federation mechanics for the composition failure scenario
- [Chapter 14: Observability](../14-observability/README.md) — the monitoring infrastructure assumed throughout
- [Chapter 25: Enterprise Patterns](../25-enterprise-patterns/README.md) — the patterns whose absence caused these incidents

---

## Related Chapters

- [Chapter 29: Anti-Patterns](../29-anti-patterns/README.md) — the anti-patterns that led to each failure
- [Chapter 32: Production Runbooks](../32-production-runbooks/README.md) — operational runbooks for common GraphQL incidents
- [Chapter 33: Incident Management](../33-incident-management/README.md) — incident management process for GraphQL service owners
