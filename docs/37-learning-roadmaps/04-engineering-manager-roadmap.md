# 04 — Engineering Manager Learning Roadmap

> **Purpose:** For engineering managers and technical leads who need to understand GraphQL platform strategy, governance, and team models — without necessarily implementing resolvers themselves. This roadmap builds sufficient technical depth to evaluate platform maturity, make informed investment decisions, assess engineer competency, and communicate GraphQL platform value to leadership. Each phase ends with a concrete deliverable, not a hands-on implementation exercise.

---

## Who This Roadmap Is For

This roadmap is for:

- Engineering managers leading teams that build on or operate a GraphQL platform
- Technical leads who influence technology decisions but are not the primary implementers
- Engineering directors who need to evaluate GraphQL platform investment proposals
- Product managers embedded with GraphQL platform teams who want technical context

**You do not need to:**

- Write a resolver, a mutation, or a schema directive
- Deploy a Kubernetes manifest
- Run a PromQL query (though you will be able to read them)

**You will be able to:**

- Explain what a supergraph is and why it matters to non-technical stakeholders
- Identify where your organization sits on a 5-level platform maturity model
- Identify the top 3 governance gaps in your current platform setup
- Draft a 6-month platform roadmap with measurable success criteria
- Run a post-mortem culture assessment for your team
- Evaluate GraphQL engineer candidates with well-formed interview questions
- Make the business case for platform investment to engineering leadership

**Time investment:** Approximately 3 weeks at 5–8 hours per week. Total: 15–24 hours of active reading plus deliverable time.

---

## How Managers Use This Documentation Differently

Backend engineers read this documentation to learn *how to implement*. Managers read it to understand *what is being built, what it costs to run, what can go wrong, and whether the team is doing it well*.

For each section, ask:

- What decisions does my team make about this topic? Are they making the right decisions?
- What does success look like here? How would I know if we were failing?
- What would a governance gap in this area cost us? (Developer time, incidents, customer impact?)
- What should I look for in a code review or architecture review of this area?
- What questions should I ask in a hiring interview to assess competence here?

The milestones in this roadmap produce management artifacts — roadmaps, maturity assessments, post-mortem culture audits, and business cases. These are immediately usable in your role.

---

## What a Supergraph Is (Read This First)

Before starting Phase 1, establish a baseline mental model.

A **supergraph** is a unified GraphQL API assembled from multiple independently deployed services called **subgraphs**. Each subgraph is owned by a specific team and exposes a schema covering its domain (e.g., `orders`, `inventory`, `users`). The **Apollo Router** (or equivalent) receives client requests, plans which subgraphs to call, executes those calls in parallel where possible, and assembles the result.

**Why this matters for managers:**

- Subgraph ownership maps directly to team ownership. A schema boundary *is* a team boundary. When you change how teams are organized, you may need to change schema boundaries too.
- A schema change in one subgraph can break the *supergraph*. This is a governance risk, not just a technical risk — multiple teams are coupled through the schema.
- The router is shared platform infrastructure. Its availability is everyone's SLO. A dedicated platform team owns it; application teams own their subgraphs.
- Developer velocity depends on how well the platform makes subgraph development self-service. Slow schema check pipelines, manual approval gates, and undocumented onboarding processes are manager problems, not engineering problems.

---

## Phase 1 — Platform Mental Model (Week 1)

**Sections to read:** [01-graphql-fundamentals](../01-graphql-fundamentals/), [07-federation](../07-federation/), [08-supergraph-architecture](../08-supergraph-architecture/)

### Goal

Be able to explain what a supergraph is and why it matters to stakeholders — technical and non-technical. Understand the vocabulary your engineers use so you can participate in architecture reviews without needing a translator.

### What You Will Learn

**From section 01 (GraphQL Fundamentals):**
- The type system: what a schema is, what types and fields are, why nullability matters
- Operations: queries, mutations, subscriptions — and what each is used for
- The error model: why GraphQL returns `HTTP 200` even when something fails, and what `errors[]` means
- Why GraphQL is different from REST at the organizational level: a single endpoint, a single schema contract, shared ownership

**From section 07 (Federation):**
- What a subgraph is and how teams own them
- How entity resolution works when a query spans multiple subgraphs (conceptual understanding only — not the implementation details)
- What `@key`, `@requires`, `@provides` mean at an architectural level
- Composition: what happens when two subgraphs' schemas are combined into a supergraph, and what a composition error means for deployments

**From section 08 (Supergraph Architecture):**
- The components of a production supergraph: router, schema registry, subgraphs, observability
- Deployment models: monorepo vs polyrepo subgraph ownership
- The schema registry as platform infrastructure: why its uptime matters as much as the router's uptime

### What to Skip in Phase 1

In sections 01, 07, and 08, skip code implementation details and focus on:
- Conceptual explanations of how things work
- Architecture diagrams
- "Why this matters" sections
- Trade-off discussions

Do not spend time on: resolver implementation, DataLoader code, Kubernetes manifests, or SDL syntax details. Those are your engineers' domain.

### Phase 1 Milestone

**Explain the supergraph to a non-technical stakeholder.**

Schedule a 15-minute informal conversation with a product manager, a business analyst, or an executive sponsor who is not technical. Without slides or notes, explain:

1. What the GraphQL API is and who uses it (the clients and their relationship to the teams)
2. What a subgraph is and which teams own which ones in your organization
3. What a schema change is and why it requires coordination between teams
4. What a composition error is and why it can block all subgraph deployments

If your stakeholder asks "why don't we just use REST?" and you can give an answer that is honest about trade-offs rather than promotional, you have internalized the mental model.

---

## Phase 2 — Governance and Teams (Week 2)

**Sections to read:** [09-schema-governance](../09-schema-governance/), [19-platform-engineering](../19-platform-engineering/), [35-governance-models](../35-governance-models/)

### Goal

Understand what good GraphQL governance looks like. Locate your organization on the platform maturity model. Identify the top 3 governance gaps in your current setup.

### What You Will Learn

**From section 09 (Schema Governance):**
- What schema governance means: who can change the schema, how changes are reviewed, how breaking changes are detected and prevented
- The schema check: an automated step in CI that detects whether a proposed schema change would break any active client operations
- Deprecation workflows: how fields are marked deprecated, how usage is measured, and when fields can be safely removed
- Schema ownership: who approves schema changes, who is notified, and what happens when teams disagree

**From section 19 (Platform Engineering):**
- The platform team model: who is on the platform team, what they own, and what their SLOs are
- The 5-level platform maturity model (from ad-hoc GraphQL to self-optimizing supergraph) — this is the primary framework for the Phase 2 milestone
- The golden path concept: standardized, supported ways for application teams to onboard new subgraphs
- What it costs to run a GraphQL platform: engineer headcount, infrastructure, tooling licenses

**From section 35 (Governance Models):**
- Centralized governance: a schema council or platform team approves all schema changes. High consistency, low velocity.
- Federated governance: each subgraph team self-governs. High velocity, inconsistency risk.
- Hybrid governance: automated gates for breaking changes + team autonomy for additive changes. The most common production model.
- How to choose a governance model based on organization size, team maturity, and risk tolerance

### The 5-Level Platform Maturity Model

This model from section 19 is the diagnostic framework for Phase 2. Read the full model in section 19; use this summary as a reference:

| Level | Description | Characteristics |
|-------|-------------|-----------------|
| 1 — Ad-Hoc | GraphQL exists but is not governed | No schema registry, breaking changes in production regularly, no dedicated platform team |
| 2 — Repeatable | Basic tooling in place | Schema registry deployed, schema checks in CI, on-call rotation exists |
| 3 — Defined | Standard processes documented | Golden path templates, governance policy documented, SLOs defined and measured |
| 4 — Managed | Platform is measured and optimized | Developer experience score tracked, error budget management, self-service onboarding |
| 5 — Self-Optimizing | Continuous improvement loop | Automated schema suggestions, usage-driven field deprecation, platform-as-product |

Most organizations starting a governance improvement program are between Level 1 and Level 2. Reaching Level 3 is the realistic goal for a 6-month roadmap.

### Phase 2 Milestone

**Produce a governance gap assessment.**

Using the maturity model and what you learned from sections 09, 19, and 35, produce a 1-page written assessment:

1. **Current maturity level** — which level your organization currently sits at, with specific evidence (e.g., "we have a schema registry but no schema check in CI — Level 2 partial")
2. **Top 3 governance gaps** — the three highest-priority gaps between your current state and Level 3. Be specific: not "we need better governance" but "we have no automated breaking change detection in CI, which means breaking changes reach production weekly"
3. **Gap → risk mapping** — for each gap, describe the incident or developer experience cost if the gap is not closed (e.g., "without schema checks, a breaking field removal would cause a P2 incident affecting all clients that use that field")
4. **Recommended governance model** — centralized, federated, or hybrid — for your organization's current team structure and risk tolerance

This assessment becomes the input for the Phase 3 platform roadmap.

---

## Phase 3 — Platform Investment (Week 3)

**Sections to read:** [20-internal-developer-platforms](../20-internal-developer-platforms/), [34-cost-optimization](../34-cost-optimization/), [23-production-case-studies](../23-production-case-studies/)

### Goal

Produce a draft 6-month platform roadmap with a cost model and measurable success criteria. Understand what platform investment has returned for peer organizations.

### What You Will Learn

**From section 20 (Internal Developer Platforms):**
- What an Internal Developer Platform (IDP) is in the GraphQL context: self-service schema onboarding, automated composition checks, developer portal integration (Backstage)
- The developer portal as a force multiplier: a Backstage integration that shows every team which subgraphs they own, their current SLOs, recent schema changes, and open incidents
- Self-service golden path onboarding: how the platform team enables new subgraphs to go from idea to production without hand-holding
- What the platform team builds vs what application teams consume

**From section 34 (Cost Optimization):**
- Router infrastructure cost: what drives it (request volume, query complexity, caching hit rate)
- Subgraph sprawl: how having too many small subgraphs increases operational overhead without adding value
- Caching as a cost lever: APQ + CDN caching can reduce compute cost by 40–70% for public read-heavy APIs
- The cost of N+1 queries: a single undetected N+1 can multiply database cost by 10–50x
- Build vs buy: the cost of operating your own schema registry (e.g., open-source Hive) vs a managed service (Apollo GraphOS)
- Headcount model: how many platform engineers per number of subgraph teams (industry benchmark: 1 platform engineer per 8–10 subgraph teams, with high maturity tooling)

**From section 23 (Production Case Studies):**
- How other organizations have structured their GraphQL platform investment
- Common failure patterns: teams that adopted GraphQL without a governance model, the resulting incidents, and the cost of remediation
- ROI evidence: specific metrics from production deployments (developer velocity improvement, incident rate reduction, time-to-production for new features)
- What went wrong: organizations that over-invested in tooling before establishing governance, or under-invested in the platform team and created tech debt

### Reading the Case Studies as a Manager

When reading section 23, extract these patterns for each case study:

- **What was the organizational trigger?** (What pain point led to GraphQL adoption? Was it a technical decision or a business decision?)
- **What organizational change accompanied the technical change?** (Did they form a platform team? Did they change schema ownership models?)
- **What was the first failure?** (The first significant incident or governance failure after adoption — what did it reveal?)
- **What would they do differently?** (Hindsight recommendations from the teams that went through it)

These patterns feed directly into your roadmap's risk register.

### Phase 3 Milestone

**Produce a 6-month platform roadmap.**

Building on the governance gap assessment from Phase 2, produce a platform roadmap document:

**Section 1 — Current State**
- Current maturity level (from Phase 2 assessment)
- Top 3 governance gaps with their associated risks
- Current platform cost model (infrastructure + headcount + tooling)

**Section 2 — Target State (6 months)**
- Target maturity level (be specific: which criteria from the maturity model will be met?)
- Which governance gaps will be closed and how
- Developer experience metrics that will improve (time to onboard a new subgraph, schema check pass rate, breaking change incident rate)

**Section 3 — Investment Required**
- Engineering headcount: platform team size needed for the target state
- Infrastructure: router, schema registry, observability stack
- Tooling: managed service vs self-hosted decision with cost comparison
- Timeline: quarterly milestones with measurable success criteria

**Section 4 — Risk Register**
- Top 3 risks to the roadmap (team capacity, organizational resistance, technical dependencies)
- Mitigation strategy for each risk
- Success metrics: how you will know the roadmap is working (not just "we shipped X" but "error rate dropped Y%", "time-to-production for new features went from Z weeks to W weeks")

Present this roadmap to engineering leadership as a proposal. The ability to defend it with cost and risk evidence — not just technical enthusiasm — is the milestone.

---

## Supplemental Reading (Ongoing)

These sections do not require a dedicated week. Read them as incidents or questions arise in your management work.

### Section 26 — Production Failure Scenarios

[26-production-failure-scenarios](../26-production-failure-scenarios/)

**Why managers should read this:** Understand what incidents look like before they happen. Section 26 describes the most common GraphQL platform failure patterns — N+1 query cascades, schema composition failures, DataLoader memory leaks, auth outages — with realistic timelines and impact descriptions. Reading this helps you set appropriate SLOs and have informed conversations during incident retrospectives.

**What to focus on:** The "impact" and "timeline" sections of each failure scenario. Skip the technical root cause analysis unless you want the detail.

### Section 32 — Production Runbooks

[32-production-runbooks](../32-production-runbooks/)

**Why managers should read this:** Understand what your on-call team does at 2am. Section 32 contains the runbooks your engineers execute during incidents. Reading the runbooks — not to memorize them, but to understand their structure — helps you assess whether your team has adequate runbook coverage and whether the runbooks are maintained (a key indicator of operational maturity).

**What to focus on:** The README and the structure of 2–3 specific runbooks. Ask: does every failure scenario in section 26 have a corresponding runbook? If not, that is a governance gap.

### Section 33 — Incident Management

[33-incident-management](../33-incident-management/)

**Why managers should read this:** Understand the full incident lifecycle and own the post-mortem culture. Section 33 covers incident classification, on-call procedures, and post-mortem processes. As an engineering manager, you are responsible for the post-mortem culture — ensuring post-mortems are blameless, action items are tracked, and the same incident does not recur.

**What to focus on:** The classification framework (so you can assess severity correctly when incidents are reported to you), the post-mortem template, and the blameless principles. The chaos engineering document (05-chaos-engineering.md) is valuable if you want to understand how your team proactively validates the system's failure behavior.

### Section 27 — Interview Preparation

[27-interview-preparation](../27-interview-preparation/)

**Why managers should read this:** Evaluate GraphQL engineer candidates with well-formed questions. Section 27 contains interview question sets at multiple levels (backend engineer, platform engineer, senior/staff, architect). Use these to assess whether a candidate's claimed GraphQL experience is substantive.

**What to focus on:** The conceptual and design questions at each level. Questions like "explain how entity resolution works in a federated supergraph" or "when would you choose `@requires` and what is the query planning cost?" have right answers — if a candidate cannot answer them at the claimed level, their experience is shallower than stated.

---

## Platform Maturity Self-Assessment

Answer these 10 questions to locate your organization on the maturity model. Honest answers are more valuable than optimistic ones.

**Governance:**

1. Does every subgraph have an identified team owner who is responsible for its schema and runtime behavior?
2. Is there an automated schema check in CI that detects breaking changes before they reach production?
3. Is there a documented deprecation workflow that your teams follow consistently?

**Operations:**

4. Does your organization have defined SLOs for the GraphQL API (availability, latency, error rate)?
5. Is there a dedicated on-call rotation that covers the router and platform infrastructure?
6. Does every SEV1 and SEV2 incident result in a published, blameless post-mortem?

**Developer Experience:**

7. Can a new team onboard a new subgraph without requiring help from the platform team?
8. Is there a self-service developer portal where teams can see their subgraph's schema, SLOs, and recent changes?
9. Is the time from "schema change approved" to "schema change in production" less than 2 hours?

**Cost Awareness:**

10. Do you know the fully loaded cost of operating the GraphQL platform (compute, schema registry, observability, on-call overhead)?

**Scoring:**

| Yes answers | Maturity Level |
|-------------|----------------|
| 0–2 | Level 1 — Ad-Hoc |
| 3–5 | Level 2 — Repeatable |
| 6–7 | Level 3 — Defined |
| 8–9 | Level 4 — Managed |
| 10 | Level 5 — Self-Optimizing |

Most organizations with active but ungoverned GraphQL platforms score between 3 and 5. If you scored below 3, the governance gap assessment in Phase 2 is your highest-priority deliverable.

---

## Making the Case for Platform Investment

Use these metrics when presenting a platform investment proposal to engineering leadership. Each metric has a before/after framing that makes the business case concrete.

### Developer Velocity Metrics

**Time to onboard a new subgraph:** The time from "team decides to create a new subgraph" to "subgraph is in production with monitoring and CI." At Level 1–2 maturity, this is often 4–8 weeks due to manual coordination. At Level 3–4 maturity with a golden path, it should be 2–5 days. The delta represents weeks of developer time per new subgraph per year.

**Schema change cycle time:** The time from "schema change committed" to "schema change validated and deployed." At Level 1 maturity, this involves manual review and coordination. At Level 3, automated schema checks and CI/CD pipelines reduce this to under 2 hours. With 10+ subgraphs and 5–10 schema changes per week per subgraph, this compounds.

**Breaking change incident rate:** How often does a breaking schema change reach production and cause a client-visible incident? At Level 1–2 maturity, this happens weekly or more. At Level 3, automated schema checks should reduce this to near zero. Each incident costs: on-call engineer time + post-mortem time + customer support escalations + trust erosion.

### Reliability Metrics

**Error budget consumption rate:** What percentage of the GraphQL API's monthly error budget is consumed by avoidable incidents (incidents that a chaos experiment, a schema check, or a runbook could have prevented)? At Level 2, this is often 40–60%. At Level 3–4, it should be under 20%.

**Mean time to resolution (MTTR) for SEV2 incidents:** With documented runbooks, instrumenting observability, and trained on-call engineers, MTTR should be under 60 minutes. Without these, MTTR is often 2–4 hours. For a team with a monthly SEV2 incident, this is 1–3 additional hours of engineering time at an incident-response opportunity cost.

**Post-mortem action item close rate:** What percentage of post-mortem action items are closed within 90 days? Below 50% indicates that post-mortems are a compliance exercise, not a reliability improvement tool. The same incidents recur.

### Platform Cost Metrics

**Platform engineering ratio:** How many platform engineers support how many subgraph development teams? Industry benchmark for a Level 3–4 platform is 1 platform engineer per 8–10 subgraph teams. If your ratio is worse (more platform engineers per team), the platform is under-automated. If it is better (fewer platform engineers per team), the platform team is likely overloaded and toil is accumulating.

**Infrastructure cost per request:** Router compute + schema registry + observability stack, divided by monthly request count. Caching improvements (APQ, CDN, response caching) typically reduce this by 30–60% for read-heavy APIs. This is a lever that platform investment directly controls.

---

## Red Flags to Watch For

These are signals that your GraphQL platform governance is failing. Each one has an associated management action.

**Teams skipping schema checks.** If engineers are merging schema changes with `--skip-checks` or bypassing the CI gate because "it's urgent," the schema check is either too slow, too noisy, or not enforced. This is a process failure, not an engineer failure. Action: investigate why checks are being skipped (false positive rate, turnaround time, policy gaps) and fix the root cause.

**No one owns the platform.** "Everyone owns it" means no one owns it. If incidents involving the router or schema registry do not have a clear owner with an on-call rotation and SLOs, the platform team is not functioning as a team. Action: designate a platform team (even if it is 1–2 engineers to start), define their charter, and establish SLOs.

**Breaking changes in production weekly.** More than one breaking change incident per month is a strong signal that schema governance automation (schema check in CI) is not in place or is not enforced. Action: prioritize schema check deployment as the highest-ROI governance investment.

**No defined SLOs.** If your team cannot tell you the current error rate, p99 latency, or error budget burn rate for the GraphQL API, SLOs are not defined. Without SLOs, reliability work is invisible and deprioritized. Action: work with the platform team to define at minimum one availability SLO and one latency SLO, instrument them, and make them visible on a shared dashboard.

**On-call engineers who have never read the runbooks.** If your on-call engineers learn the runbooks during an incident rather than before, incidents will take longer to resolve and will cause unnecessary escalations. Action: require runbook review as part of on-call onboarding, and track runbook staleness (runbooks older than 90 days without review are likely stale).

**Post-mortems with no action items.** A post-mortem that concludes "the engineer should be more careful" has failed. Blameless post-mortems always produce system-level action items. If your post-mortems consistently produce no actionable items, the process is broken. Action: review recent post-mortems with the team, identify whether system-level changes were proposed, and track action item close rates.

---

## Continuing Beyond This Roadmap

| Question | Where to look |
|----------|---------------|
| How do I evaluate a GraphQL engineer candidate? | [27-interview-preparation](../27-interview-preparation/) |
| What should my team's incident response look like? | [33-incident-management](../33-incident-management/) |
| What does a world-class platform team look like? | [19-platform-engineering](../19-platform-engineering/) |
| What are the biggest risks in our architecture? | [26-production-failure-scenarios](../26-production-failure-scenarios/) |
| What are the GraphQL anti-patterns I should watch for in code reviews? | [29-anti-patterns](../29-anti-patterns/) |
| What is the industry direction for GraphQL? | [36-future-trends](../36-future-trends/) |

---

## External Resources

- [Team Topologies](https://teamtopologies.com/) — Skelton and Pais on platform teams and stream-aligned teams; the organizational model that maps most cleanly to the platform + subgraph team structure
- [Accelerate: Building and Scaling High-Performing Technology Organizations](https://itrevolution.com/accelerate-book/) — Forsgren, Humble, and Kim on the four DORA metrics; the deployment frequency and MTTR metrics are the highest-signal reliability measures for a GraphQL platform
- [The Platform Engineering Book](https://platformengineering.org/blog/what-is-platform-engineering) — practitioner-focused overview of the platform team model
- [Google SRE Book — Eliminating Toil](https://sre.google/sre-book/eliminating-toil/) — framework for identifying and reducing toil in platform operations; applicable directly to schema registry operations and on-call rotation design
- [Apollo GraphOS Product Documentation](https://www.apollographql.com/docs/graphos/) — the managed schema registry and governance tooling; read the feature overview to understand what Level 3–4 tooling looks like in practice

---

## Related Sections

- [38-glossary](../38-glossary/) — definitions for all terms used in this roadmap; use as a reference when encountering unfamiliar vocabulary in architecture reviews
- [19-platform-engineering](../19-platform-engineering/) — the full platform maturity model with detailed criteria for each level
- [09-schema-governance](../09-schema-governance/) — the governance framework your platform team should be implementing
- [33-incident-management](../33-incident-management/) — the incident lifecycle and post-mortem process you are responsible for as a manager
