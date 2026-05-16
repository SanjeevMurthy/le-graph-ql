# 37 — Learning Roadmaps

> **Purpose:** Provide structured, role-specific learning paths through this documentation. Each roadmap defines a starting point, a target level of proficiency, a recommended reading sequence, hands-on milestones, and external resources. These are not generic reading lists — they are sequenced so that each section builds on the last, with milestones that verify understanding before moving forward.

---

## How to Use These Roadmaps

Each roadmap is designed for a specific role. Read the role descriptions below to find yours. If your role spans two descriptions (e.g., you are a backend engineer moving into platform engineering), start with the more foundational roadmap and use the other as a supplement.

**The milestone system:** Each phase ends with a concrete hands-on milestone. Do not advance to the next phase until you can complete the milestone. The milestones are intentionally practical — they require applying the concepts, not just reading about them. They are also verifiable by a peer: if you can explain your milestone work to a colleague, you have internalized the material.

**External resources:** Each roadmap includes external resources for depth on topics where this documentation provides overview but not implementation detail. The external resources are curated for quality — they are official documentation, recognized reference texts, or high-signal technical blog posts. Generic "learn GraphQL" tutorials are not included.

**Time estimates:** Time estimates assume active reading (note-taking, running examples) rather than passive reading. Passive reading will be faster but retention will be lower. The estimates also assume engineers are doing this learning concurrently with their normal workload — allocate 5–8 hours per week per roadmap.

---

## Roadmaps Available

| File | Role | Duration | Entry Level |
|------|------|----------|-------------|
| [01-backend-engineer-roadmap.md](./01-backend-engineer-roadmap.md) | Backend engineers new to GraphQL | ~9 weeks | REST API experience required |
| [02-platform-engineer-roadmap.md](./02-platform-engineer-roadmap.md) | Platform / SRE engineers | ~8 weeks | Kubernetes experience required |
| [03-architect-roadmap.md](./03-architect-roadmap.md) | Senior engineers and architects | ~9 weeks | System design experience required |
| [04-engineering-manager-roadmap.md](./04-engineering-manager-roadmap.md) | Engineering managers and technical leads | ~3 weeks | No implementation experience required |

---

## Which Roadmap Is For Me?

### Backend Engineer

You write server-side code. You implement APIs, connect to databases, write resolvers, and are responsible for the correctness and performance of your service's data layer. You are comfortable with REST APIs and HTTP fundamentals, but GraphQL is new to you — or you know the basics but want structured depth.

Read: [01-backend-engineer-roadmap.md](./01-backend-engineer-roadmap.md)

### Platform Engineer / SRE

You run infrastructure. You manage Kubernetes clusters, design service meshes, build CI/CD pipelines, and own the reliability of shared platform services. You may not write application code, but you need to understand GraphQL deeply enough to operate, debug, and scale a federated supergraph. You have experience with Kubernetes, Prometheus, and Helm.

Read: [02-platform-engineer-roadmap.md](./02-platform-engineer-roadmap.md)

### Senior Engineer / Architect

You design systems. You make technology choices, review schemas for correctness and scalability, advise teams on federation boundaries, and are responsible for the long-term architecture of your GraphQL platform. You may have implemented GraphQL before but lack depth in federation, schema governance, or the full platform stack.

Read: [03-architect-roadmap.md](./03-architect-roadmap.md)

### Engineering Manager / Technical Lead

You lead teams. Your role is governance, strategy, and enabling engineers — not implementation. You need to understand GraphQL well enough to evaluate your platform's maturity, make informed investment decisions, assess engineer competency, and communicate platform value to stakeholders.

Read: [04-engineering-manager-roadmap.md](./04-engineering-manager-roadmap.md)

---

## Cross-Cutting Learning Advice

### On the Order of Sections

This documentation has 38 numbered sections. The numbers reflect a logical dependency order — later sections build on earlier ones. The roadmaps respect these dependencies by sequencing phases to cover foundational material before advanced topics. If you skip sections, you will encounter unexplained concepts.

### On Hands-On Practice

Reading documentation without hands-on practice produces shallow, short-lived knowledge. Every roadmap includes milestones that require you to build or configure something. Set up a local environment early (see [00-introduction](../00-introduction/) for tool recommendations) and complete milestones before advancing.

### On the Glossary

When you encounter an unfamiliar term, consult [38-glossary](../38-glossary/) before searching the web. Terms in this documentation have specific, precise meanings — a general web search may return conflicting definitions. The glossary cross-references the sections where terms are covered in depth.

### On External Resources

The roadmaps include links to external resources. These are selected for current relevance (as of 2025) and technical depth. Official documentation is always preferred over tutorials. For Apollo-specific topics, [apollographql.com/docs](https://www.apollographql.com/docs/) is the authoritative reference; for spec-level topics, [spec.graphql.org](https://spec.graphql.org) is authoritative.

---

## Documentation Coverage Map

This map shows which sections are covered in each roadmap:

```
Section Range    Backend  Platform  Architect  Manager
00–02            ●        ◐         ●          ○
03–04            ●        ◐         ●          ○
05–06            ●        ○         ●          ○
07–08            ●        ●         ●          ○
09               ◐        ●         ●          ●
10–13            ●        ◐         ○          ○
14               ◐        ●         ●          ○
15–16            ○        ●         ●          ○
17–18            ○        ◐         ●          ○
19–20            ○        ●         ●          ●
21–22            ○        ○         ●          ○
23               ○        ○         ◐          ●
24–25            ○        ○         ●          ○
26               ○        ●         ○          ○
27               ○        ○         ○          ●
28–29            ◐        ○         ●          ○
30–31            ○        ○         ●          ○
32–33            ○        ●         ○          ○
34               ○        ○         ○          ●
35               ○        ○         ◐          ●
36               ○        ○         ◐          ○
37               —        —         —          —

● = Primary coverage in this roadmap
◐ = Secondary coverage / referenced
○ = Not covered in this roadmap
```

---

## Related Sections

- [00-introduction](../00-introduction/) — entry point for engineers new to this documentation
- [38-glossary](../38-glossary/) — term definitions cross-referenced throughout roadmaps
- [27-interview-preparation](../27-interview-preparation/) — for engineers preparing for GraphQL roles (complements architect and backend roadmaps)
- [19-platform-engineering](../19-platform-engineering/) — platform maturity model referenced in manager roadmap
