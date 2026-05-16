# 03 — Senior Engineer and Architect Learning Roadmap

> **Purpose:** A structured 9-week learning path for senior engineers and architects who make technology choices, review schemas for scalability, advise teams on federation boundaries, and are responsible for the long-term architecture of a GraphQL platform. Each phase ends with a milestone that tests conceptual depth and design judgment — not implementation skill.

---

## Who This Roadmap Is For

This roadmap is for engineers who:

- Make or heavily influence technology choices for their organization
- Review other engineers' schemas and architecture designs
- Advise teams on federation boundaries, subgraph ownership, and API design
- Are responsible for the correctness and scalability of the platform as a whole
- May have implemented GraphQL before but lack depth in federation, governance, or production operations at scale

You should have:
- System design experience (designing distributed systems, data models, API contracts)
- Experience with at least one prior distributed systems technology (microservices, Kafka, gRPC)
- Familiarity with the tradeoffs between consistency, availability, and performance

**What you will be able to do after completing this roadmap:**

- Design a subgraph boundary that reflects team ownership and domain semantics
- Produce a schema design document that survives peer review from senior GraphQL engineers
- Architect the full production stack for a new subgraph from scratch
- Write a platform charter for a GraphQL platform team
- Evaluate trade-offs between Apollo, Hive, Cosmo, and other federation implementations
- Present a reference architecture for complex system design scenarios

---

## How Architects Use This Documentation Differently

Backend engineers read this documentation to learn how to implement. Architects read it to develop judgment about design decisions. For each section, ask:

- What is the full range of design choices available here?
- What are the trade-offs between the options?
- Under what circumstances would I choose option A vs option B?
- What mistakes do teams make at scale with this technology?
- How would I communicate this decision to a team that disagrees?

The milestones in this roadmap emphasize design documentation and communication — not code. The output is design docs, architecture diagrams, and technical arguments, not working code.

---

## Phase 1 — Mental Model (1 Week)

**Sections:** [01-graphql-fundamentals](../01-graphql-fundamentals/), [02-graphql-internals](../02-graphql-internals/), [07-federation](../07-federation/)

### Goal

Develop a clear mental model of GraphQL from specification to execution — well enough to explain federation to an engineer who has never seen it, and to identify where a design decision has downstream consequences.

### What You Will Learn

- The full type system: how nullability, interfaces, unions, and input types interact at scale
- The execution model: parse → validate → plan → execute; where errors enter and propagate
- Federation: entities, `@key`, `@requires`, `@provides`, query planning, the `_entities` query
- Why federation boundaries matter architecturally: coupling, ownership, change velocity

### Recommended Reading Sequence

1. `01-graphql-fundamentals/` — all files, focusing on type system and schema evolution (2.5 hours)
2. `02-graphql-internals/` — all files, focusing on the execution pipeline (1.5 hours)
3. `07-federation/` — all files (3 hours)

### Key Concepts to Internalize

**Null propagation as an architectural concern.** The decision to mark a field `String` (nullable) vs `String!` (non-null) propagates up the type chain. A non-null field whose resolver throws an error causes the nearest nullable ancestor to become null — which may null out an entire section of a UI. This is not a schema syntax detail; it is an error handling contract between schema owner and client.

**Entities as the unit of federation boundary.** The `@key` directive identifies which types can be owned by one subgraph and referenced by another. The design question is not "which fields belong together" but "which team owns this type and what does 'ownership' mean for change control?"

**`@requires` creates sequential query planning.** When a resolver in Subgraph B `@requires` a field from Subgraph A, the router cannot parallelize those subgraph calls — it must first call A, then call B with A's result. This is a latency tax. Architects who approve `@requires` usage without understanding the query plan impact are building in latency that accumulates.

### Phase 1 Milestone

**Explain federation to a non-GraphQL engineer.**

Without notes, explain to a colleague with distributed systems background but no GraphQL experience:

1. What the "supergraph" concept is and why it exists (the organizational motivation, not just the technical mechanism)
2. How entity resolution works when a query spans two subgraphs (walk through a specific example with the `_entities` query)
3. Why `@requires` creates a latency dependency and how to decide when that trade-off is acceptable
4. How composition errors differ from runtime errors — and why the distinction matters for deployment safety

If your colleague asks "why not just use REST?" and you can give a nuanced answer that respects both approaches, you pass this milestone.

---

## Phase 2 — Design (2 Weeks)

**Sections:** [03-schema-design](../03-schema-design/), [08-supergraph-architecture](../08-supergraph-architecture/), [09-schema-governance](../09-schema-governance/), [25-enterprise-patterns](../25-enterprise-patterns/)

### Goal

Develop the judgment to design schemas and federation boundaries that scale with team growth, remain evolvable, and are coherent from a domain perspective — not just technically valid.

### What You Will Learn

- Schema design principles: consumer-first design, nullable vs non-null intent, pagination patterns
- Federation boundary design: domain boundaries vs team boundaries vs service boundaries
- Supergraph architecture patterns: monorepo vs polyrepo subgraphs, shared entity models
- Schema governance: breaking change policy, deprecation workflow, schema check in CI
- Enterprise patterns: schema registries, federated governance models, multi-tenant schemas
- `@tag` and contract schemas: how to expose different schema subsets to different consumers

### Recommended Reading Sequence

1. `03-schema-design/` — all files (2.5–3 hours)
2. `08-supergraph-architecture/` — all files (2.5 hours)
3. `09-schema-governance/` — all files (2 hours)
4. `25-enterprise-patterns/` — all files (2 hours)

### Key Design Questions to Develop Opinions On

**When should two related types be in the same subgraph vs different subgraphs?**

The Conway's Law answer: put types in the same subgraph when they are owned by the same team. But team boundaries are fluid. The technical answer: co-locate types when they are always accessed together (query planning will keep them sequential anyway), and separate them when they have different change velocity, different scaling characteristics, or different ownership.

**When should you use `@shareable` vs entity references?**

`@shareable` marks a type that can be resolved by multiple subgraphs simultaneously (not via entity resolution, but by each subgraph resolving the full object). Use it for value types (a `Money` type that stores currency and amount) that do not represent a domain entity with identity. Avoid it for domain entities — `@shareable` on a `User` type creates implicit coupling between subgraphs that both need to return consistent User data.

**What is the right deprecation window for a federated graph?**

Longer than you think. A field used in a mobile app requires: schema deprecation → mobile app update → app store review → user update. This cycle is 6–8 weeks minimum. Your deprecation window should be at least 90 days, and you should use schema registry usage analytics to verify zero active usage before removing any field.

### Hands-On Exercises

**Exercise 2.1 — Evaluate a schema for scalability**

Review an existing schema (from your codebase or a public API like GitHub's GraphQL API) and produce a written evaluation covering:
- Nullability decisions: are they intentional or accidental? What are the client implications?
- Pagination strategy: consistent or ad-hoc? Does it follow the Relay Connections spec?
- Mutation patterns: do mutations return enough information for client-side error handling?
- Schema evolution readiness: can fields be removed safely? Is there a deprecation signal?

**Exercise 2.2 — Design a federation boundary**

Given a monolithic GraphQL schema (create one from a domain you know, or use a public example), propose how to split it into 3–4 subgraphs. Produce:
- A diagram showing subgraph boundaries and shared entity types
- A written justification for each boundary decision (domain ownership, change velocity, team structure)
- The entity types with their `@key` fields
- Any `@requires` dependencies and their query planning implications

### Phase 2 Milestone

**Produce a schema design document for a new domain.**

Write a schema design document for a new GraphQL subgraph in a domain you know. The document must include:

1. **Domain model** — the types, their relationships, and the business concepts they represent
2. **Schema SDL** — the complete schema in SDL format with field descriptions on every type and field
3. **Nullability rationale** — for every nullable field, explain why it is nullable (not just "it might not be present")
4. **Pagination decisions** — which list fields use cursor-based pagination and why
5. **Mutation design** — the mutations, their input types, and the response pattern
6. **Federation boundary decision** — if this is a subgraph, which types are entities, which teams own them, and what are the `@key` fields
7. **Evolution plan** — which fields are likely to change in the next 6 months, and how you would evolve the schema without breaking clients

Have the document reviewed by at least one other engineer. Revise based on feedback. The ability to produce and defend a design document is the core architect skill.

---

## Phase 3 — Production Systems (3 Weeks)

**Sections:** [05-security](../05-security/), [06-performance-and-scaling](../06-performance-and-scaling/), [14-observability](../14-observability/), [15-kubernetes-deployment](../15-kubernetes-deployment/), [16-service-mesh-integration](../16-service-mesh-integration/), [17-caching-strategies](../17-caching-strategies/), [18-api-gateway-vs-federation](../18-api-gateway-vs-federation/)

### Goal

Understand the full production stack for a GraphQL subgraph — security, performance, observability, infrastructure, and deployment — well enough to architect it from scratch and evaluate other engineers' implementations.

### What You Will Learn

**Security:**
- Authentication: JWT validation at the router vs subgraph level
- Authorization: field-level auth patterns, directive-based auth, `@requiresScopes`
- Query depth and complexity limiting as attack surface management
- Persisted query allowlisting for production APIs
- Disabling introspection in production

**Performance:**
- Query complexity and the N+1 problem at federation scale
- DataLoader patterns: per-request initialization, batching, cache invalidation
- APQ and CDN caching for public GraphQL APIs
- Response caching: in-memory vs Redis vs CDN, cache key design for GraphQL
- Schema-level performance patterns: denormalization, pagination limits, field cost

**Observability:**
- Distributed tracing: trace propagation from router through subgraphs
- Operation name as the primary observability dimension
- SLO definition for GraphQL: what percentile, what operations, what error budget

**Infrastructure:**
- Router deployment patterns: Kubernetes HPA, PDB, resource limits
- Subgraph health checks and readiness probes for schema-aware routing
- Service mesh integration: mTLS between router and subgraphs

**Caching and gateways:**
- When to use an API gateway in front of a GraphQL router
- GraphQL vs REST trade-offs for caching at the CDN layer
- Persisted query integration with edge caching

### Recommended Reading Sequence

1. `05-security/` — all files (2 hours)
2. `06-performance-and-scaling/` — all files (2 hours)
3. `17-caching-strategies/` — all files (1.5 hours)
4. `18-api-gateway-vs-federation/` — all files (1.5 hours)
5. `15-kubernetes-deployment/` — all files (2 hours)
6. `16-service-mesh-integration/` — all files (2 hours)
7. `14-observability/` — all files (2 hours)

### Key Trade-Off Frameworks to Develop

**Authorization at the router vs at the subgraph:**

Router-level authorization (via coprocessors or Rhai scripts) is centralized and consistent, but the router becomes a business logic dependency — harder to test subgraphs in isolation. Subgraph-level authorization is decentralized and testable in isolation, but inconsistency between subgraphs is a real risk. The pragmatic architecture: authenticate at the router (verify JWT, extract claims, forward as trusted headers), authorize at the subgraph (each subgraph applies its own field-level access control using the forwarded claims).

**Caching for GraphQL:**

GraphQL's POST-by-default semantics prevent naive CDN caching. APQ + GET enables CDN caching, but only for queries without user-specific data. The architect's decision: which queries are public-safe (cacheable) and which are user-specific (not cacheable)? Public catalog queries, pricing, and content can use APQ + CDN. Authenticated profile, order, and personalization queries cannot. Design your schema so these two categories are in separate queries (not mixed into one query with both public and private fields).

### Phase 3 Milestone

**Architect the full stack for a new subgraph from scratch.**

Produce a technical design document for deploying a new subgraph to production. The document must cover:

1. **Schema design** — entity types, key fields, dependencies on other subgraphs
2. **Authentication model** — how JWT is validated and claims are forwarded
3. **Authorization model** — which fields require which claims; how authorization is implemented and tested
4. **Performance design** — DataLoader strategy; which queries need caching; complexity limits
5. **Deployment architecture** — Kubernetes manifests (Deployment, Service, HPA, PDB); resource sizing
6. **Observability plan** — which metrics, traces, and logs; SLO definition; alert thresholds
7. **Schema check integration** — CI/CD pipeline for schema check + deployment
8. **Rollback plan** — how to roll back a schema change that causes a regression after deployment

Present this document to your team as a design review. Revise based on feedback.

---

## Phase 4 — Platform + Governance (1 Week)

**Sections:** [19-platform-engineering](../19-platform-engineering/), [20-internal-developer-platforms](../20-internal-developer-platforms/), [35-governance-models](../35-governance-models/)

### Goal

Understand what it means to run GraphQL as a platform product — a shared, governed, opinionated service that enables multiple application teams to move fast without coordination overhead.

### What You Will Learn

- Platform maturity model: the five stages from ad-hoc to self-optimizing
- Golden paths: what they are, how to build them for subgraph onboarding
- Internal developer platform design: self-service schema onboarding, automated composition checks
- Schema governance models: centralized vs federated governance
- Platform team charter: mission, responsibilities, SLOs, and customer model
- Schema registry as platform infrastructure: uptime requirements, disaster recovery

### Recommended Reading Sequence

1. `19-platform-engineering/` — all files (2.5 hours)
2. `20-internal-developer-platforms/` — all files (2 hours)
3. `35-governance-models/` — all files (1.5 hours)

### Phase 4 Milestone

**Write a platform charter for a GraphQL platform team.**

A platform charter is a 2–3 page document that defines the team's mission and operating model. Your charter must include:

1. **Mission statement** — one sentence: what the platform team exists to do
2. **Customers** — who the platform serves (application teams, their engineers, their consumers)
3. **Services offered** — what the platform provides (schema registry, router infrastructure, observability, golden path templates, schema governance)
4. **SLOs** — the platform's reliability commitments to its customers (router uptime, schema check turnaround time, composition error detection rate)
5. **Governance model** — how schema changes are approved; who can break the supergraph; what the escalation path is for governance disputes
6. **On-call model** — who responds to router incidents; what is in scope for the platform team vs the application team
7. **Platform maturity target** — where your organization currently sits on the maturity model (from section 19), and where you plan to be in 12 months

Present the charter to stakeholders and engineering managers. Revise based on feedback. A charter that survives a review with skeptical engineering managers is a genuinely useful artifact.

---

## Phase 5 — Advanced Topics (2 Weeks)

**Sections:** [21-ai-native-graphql](../21-ai-native-graphql/), [22-rag-and-vector-search](../22-rag-and-vector-search/), [23-production-case-studies](../23-production-case-studies/), [24-system-design-scenarios](../24-system-design-scenarios/), [31-real-world-enterprise-designs](../31-real-world-enterprise-designs/)

### Goal

Develop architectural judgment on frontier topics and complex system design scenarios. Understand how leading organizations have applied GraphQL at scale and where the technology is heading.

### What You Will Learn

- AI-native GraphQL design: schema as AI context, agent interfaces, NL2GraphQL
- Vector search integration: vector subgraphs, RAG architecture on GraphQL
- Case studies: what worked, what failed, and why at organizations running large-scale GraphQL
- System design: architectural trade-offs for specific complex scenarios
- Real-world enterprise designs: reference architectures from production deployments

### Recommended Reading Sequence

1. `21-ai-native-graphql/` — all files (2 hours)
2. `22-rag-and-vector-search/` — all files (1.5 hours)
3. `23-production-case-studies/` — all files (2 hours)
4. `24-system-design-scenarios/` — all files (2.5 hours)
5. `31-real-world-enterprise-designs/` — all files (2 hours)

### Key Architectural Patterns to Evaluate

**AI agents as first-class API consumers:**

AI agents are becoming consumers of your GraphQL API. Unlike browser clients, agents: generate queries at runtime (not compile time), may not be updated when the schema changes, and can generate queries with unusual complexity or shape. The architecture implication: treat AI agents as a separate client class with dedicated rate limits, observability labels, and potentially a dedicated schema variant that is stable and optimized for agent consumption.

**The "schema as product" mindset:**

The GraphQL schema is a product with customers (the teams consuming it), a product owner (the platform team or schema council), and a roadmap (the schema evolution plan). Architects who treat the schema as an implementation detail produce schemas that break clients. Architects who treat the schema as a product produce schemas that are evolvable, well-documented, and governed.

**Case study extraction:**

When reading case studies, extract these patterns:
- What was the trigger for GraphQL adoption? (Pain point, not enthusiasm)
- What was the failure mode they encountered? (N+1, composition errors, ownership ambiguity)
- What organizational change accompanied the technical change?
- What would they do differently with hindsight?

### Phase 5 Milestone

**Present a reference architecture for a new system design.**

Take a system design scenario from [24-system-design-scenarios](../24-system-design-scenarios/) and produce:

1. **Architecture diagram** — showing all components, their relationships, and data flows
2. **Federation boundary decisions** — which subgraphs, which entities, which team owns each
3. **Schema design** — key types, relationships, and the rationale for design decisions
4. **Production stack** — security, caching, observability, deployment model
5. **Trade-off analysis** — what you chose not to do, and why the trade-offs favor your approach
6. **Risk register** — the 3–5 highest risks in your architecture and your mitigation for each

Present to a panel of engineers (your team, or a design review group) and defend your decisions. Update the document based on the most substantive challenges you received. The revised document is your milestone artifact.

---

## Continuing Beyond This Roadmap

| Interest | Next Sections |
|----------|---------------|
| Future trends and spec evolution | [36-future-trends](../36-future-trends/) |
| Interview preparation | [27-interview-preparation](../27-interview-preparation/) — for staff/principal interview prep |
| Cost optimization at scale | [34-cost-optimization](../34-cost-optimization/) |
| Anti-patterns library | [29-anti-patterns](../29-anti-patterns/) |
| Runbooks and incident management | [32-production-runbooks](../32-production-runbooks/), [33-incident-management](../33-incident-management/) |

---

## External Resources

- [Apollo Federation documentation](https://www.apollographql.com/docs/federation/) — authoritative federation reference
- [Google SRE Book](https://sre.google/sre-book/table-of-contents/) — reliability engineering principles applicable to GraphQL platform
- [Team Topologies](https://teamtopologies.com/) — team structure patterns for platform teams and stream-aligned teams
- [Designing Data-Intensive Applications](https://dataintensive.net/) — Kleppmann's text on distributed system design (foundational for understanding federation trade-offs)
- [Production GraphQL — Apollo Blog](https://www.apollographql.com/blog/tag/case-studies) — case studies from production Apollo deployments

---

## Related Sections

- [38-glossary](../38-glossary/) — definitions for all terms used in this roadmap
- [28-best-practices](../28-best-practices/) — consolidated best practices reference
- [30-reference-architectures](../30-reference-architectures/) — reference architectures to study and adapt
