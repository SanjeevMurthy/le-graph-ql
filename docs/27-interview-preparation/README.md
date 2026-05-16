# Chapter 27: Interview Preparation

> **Purpose:** This chapter is the authoritative interview preparation guide for engineers pursuing senior, staff, and principal GraphQL roles. It covers every question category that appears in technical interviews at companies operating GraphQL at scale — from schema design whiteboard sessions to system design deep dives to behavioral leadership scenarios. Every question includes a model answer, common mistakes candidates make, and follow-up questions the interviewer will ask.

---

## Who This Chapter Is For

| Role | Primary Use |
|---|---|
| **Senior Engineer (L4/L5)** | Schema design questions, debugging scenarios, N+1 / DataLoader deep dives, testing strategy |
| **Staff Engineer (L6)** | Federation architecture, system design scenarios, observability strategy, schema governance |
| **Principal Architect (L7+)** | Banking/compliance system design, migration strategy, behavioral leadership, 90-day turnaround plans |

This chapter assumes you have completed — or are comfortable with — the core technical content in this handbook. If you encounter a question that references DataLoader, federation entities, or persisted queries and those concepts are unfamiliar, read the prerequisite chapters first. Interview performance correlates directly with depth of conceptual understanding, not memorized answers.

---

## How Technical GraphQL Interviews Are Structured

Most senior+ GraphQL interviews follow a consistent pattern:

**Round 1 — Schema Design (45–60 min)**
You are given a product domain (e-commerce, social feed, banking) and asked to design the GraphQL schema from scratch. The interviewer evaluates your type hierarchy decisions, nullability choices, pagination strategy, error modeling, and ability to evolve the schema without breaking clients.

**Round 2 — System Design (45–60 min)**
You are given a system requirements brief (e.g., "design a real-time collaborative document editor as a GraphQL API") and expected to walk through requirements, schema, architecture decisions, trade-offs, and failure modes. At principal level, compliance and multi-region requirements are common.

**Round 3 — Debugging and Performance (30–45 min)**
Scenario-based questions: production latency spike, N+1 resolver, malicious query attack, CI composition failure. The interviewer evaluates your mental model of the execution engine, tooling knowledge, and methodical debugging approach.

**Round 4 — Behavioral and Leadership (45–60 min)**
STAR-format questions about governance, adoption, incident leadership, and technical decision-making. At staff/principal level, these questions carry as much weight as technical rounds — interviewers are evaluating whether you can drive technical change across teams.

---

## How to Use This Chapter

**For a scheduled interview in 2 weeks:**
1. Read every question in all five files once, noting which areas feel weakest.
2. Spend days 1–5 on schema design and federation architecture (the highest-frequency topics).
3. Spend days 6–8 on system design — practice talking through requirements before touching schema.
4. Spend days 9–11 on debugging scenarios — trace through the execution mentally, not just the answer.
5. Spend days 12–14 on behavioral questions — write down your actual stories with specific company/project names.

**For ongoing preparation:**
Return to individual question files as reference when you encounter real production scenarios. The best interview preparation happens in production.

---

## Chapter Contents

| File | Topic | Target Audience | Est. Read |
|---|---|---|---|
| [01-schema-design-questions.md](./01-schema-design-questions.md) | E-commerce schema design, breaking changes, nullability contracts, error unions, polymorphism, N+1 / DataLoader | Senior, Staff | 35 min |
| [02-federation-and-architecture-questions.md](./02-federation-and-architecture-questions.md) | Schema decomposition, entity resolution, subgraph debugging, auth in federation, schema-first vs code-first, observability | Staff, Principal | 35 min |
| [03-system-design-questions.md](./03-system-design-questions.md) | Real-time collab editor, multi-tenant SaaS, REST migration, banking compliance — full 45-min format | Staff, Principal | 50 min |
| [04-debugging-and-performance-questions.md](./04-debugging-and-performance-questions.md) | p99 latency spike, query complexity attacks, N+1 diagnosis, schema composition CI failure, testing strategy | Senior, Staff | 30 min |
| [05-behavioral-and-leadership-questions.md](./05-behavioral-and-leadership-questions.md) | Governance enforcement, cross-team adoption, production incidents, GraphQL vs REST decisions, 90-day plans | Staff, Principal | 25 min |

---

## Cross-Chapter Prerequisites

Before interview day, ensure you can explain these concepts without notes:

- **DataLoader batch function** — how it works, when it flushes, why it caches within a request. See [Chapter 02: GraphQL Internals](../02-graphql-internals/).
- **Apollo Federation `@key` and `_entities` query** — what happens under the hood when the router resolves an entity across subgraphs. See [Chapter 07: Federation](../07-federation/).
- **Query planning** — how the router builds a Fetch/Sequence/Parallel tree from a client query. See [Chapter 07](../07-federation/04-query-planning.md).
- **Cursor-based pagination** — why offset pagination breaks under concurrent writes, how cursors encode position. See [Chapter 03: Schema Design](../03-schema-design/).
- **Persisted queries** — why they matter for security and performance, how allowlist mode works. See [Chapter 05: Security](../05-security/).
- **Schema composition validation** — what `rover subgraph check` catches, what it misses. See [Chapter 10: Schema Validation](../10-schema-validation/).

---

## Related Chapters

- [Chapter 03: Schema Design](../03-schema-design/) — prerequisite depth for schema design questions
- [Chapter 07: Federation](../07-federation/) — prerequisite depth for federation architecture questions
- [Chapter 14: Observability](../14-observability/) — prerequisite depth for observability design questions
- [Chapter 05: Security](../05-security/) — prerequisite depth for security and abuse prevention
- [Chapter 28: Best Practices](../28-best-practices/) — the opinionated practice list that forms the foundation of strong interview answers
- [Chapter 24: System Design Scenarios](../24-system-design-scenarios/) — extended system design walkthroughs with architecture diagrams
