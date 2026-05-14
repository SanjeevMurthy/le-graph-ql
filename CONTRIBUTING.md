# Contributing to the Enterprise GraphQL Engineering Handbook

---

## Standard Document Template

Every `.md` file in this repository (except READMEs and overview files) **must** include the following 12 sections. Missing sections are grounds for requesting revisions.

```markdown
# [Title — specific, not generic]

> **Purpose:** [1–2 sentences: what does this doc cover and why does it matter in production?]

## Learning Objectives
- [ ] [What the reader can do or explain after reading — use active verbs]
- [ ] [...]

## Overview / Architecture
[2–3 paragraphs of narrative. Explain WHY this topic exists — the problem it solves before the solution.]

[MERMAID DIAGRAM REQUIRED for any architecture or flow topic]

## Core Concepts
[Technical deep-dive from first principles. Assume the reader is competent but has not seen this specific topic.]

## Real-World Implementation
[Complete, production-realistic examples. Name the actual tools: Apollo Router, not "your router". Include real SDL, YAML, Rego, or command-line examples.]

## Production Considerations

### Performance
[Specific performance characteristics, benchmarks where possible, what to measure]

### Security
[Threat model, specific mitigations, what NOT to do]

### Scaling
[Horizontal scaling story, stateless vs stateful considerations, limits]

### Observability
[What to instrument, what metrics/spans to emit, what to alert on]

## Best Practices
[Numbered or bulleted list. Each item must have a brief rationale — not just "do X" but "do X because..."]

## Anti-Patterns
[Common mistakes with explanation of why they fail in production. Include real failure scenarios where possible.]

## Operational Notes
[Runbook hints, debugging steps, common errors and their meaning]

## References
- [Official documentation URL with title]
- [GitHub repository URL]
- [Architecture blog post URL]
- [GraphQL Foundation / CNCF resource]

## Related Topics
- [Relative path link to related file]
- [...]
```

---

## Mermaid Diagram Guidelines

Diagrams are required in every file that explains an architecture, flow, or lifecycle. Use the appropriate diagram type:

### `flowchart LR` — for architecture and component relationships

```
flowchart LR
    Client --> Router --> SubgraphA & SubgraphB
    SubgraphA --> DB[(PostgreSQL)]
    SubgraphB --> Cache[(Redis)]
```

### `sequenceDiagram` — for request/response flows

```
sequenceDiagram
    participant C as Client
    participant R as Router
    participant S as Subgraph
    C->>R: GraphQL Query
    R->>S: Fetch entity
    S-->>R: Data
    R-->>C: Response
```

### `stateDiagram-v2` — for lifecycle and state machines

```
stateDiagram-v2
    [*] --> Draft
    Draft --> InReview: submit RFC
    InReview --> Approved: review passed
    Approved --> Published: rover publish
    Published --> Deprecated: deprecate
    Deprecated --> [*]: field removed
```

### `flowchart TD` — for decision trees

```
flowchart TD
    A{Multiple teams?} -->|Yes| B[Use Federation]
    A -->|No| C[Single server]
```

**Color conventions** — use `classDef` blocks for consistent styling:

```
classDef router fill:#e8f4f8,stroke:#2196F3
classDef subgraph fill:#f3f4f6,stroke:#9CA3AF
classDef database fill:#fef3c7,stroke:#F59E0B
classDef external fill:#fce7f3,stroke:#EC4899
```

For the full style guide see [docs/assets/mermaid-style-guide.md](docs/assets/mermaid-style-guide.md).

---

## Writing Standards

**Explain WHY before HOW.** Every concept must begin with the problem it solves. "DataLoader is a batching utility" is less useful than "Without DataLoader, a query for 100 users each with their posts triggers 100 separate database queries — the N+1 problem. DataLoader solves this by..."

**Use real tool names.** Not "your caching layer" — write "Redis" or "Memcached". Not "a registry" — write "Apollo GraphOS" or "GraphQL Hive". Be specific.

**No toy schemas.** `type Foo { bar: String }` teaches nothing. Use domain-realistic schemas:
```graphql
type Product {
  id: ID!
  sku: String!
  title: String!
  price: Money!
  inventory: InventoryStatus!
  variants(first: Int, after: String): ProductVariantConnection!
}
```

**Explain tradeoffs.** Good documentation says "Option A is faster but sacrifices consistency, Option B is safer but adds latency." Don't recommend a solution without acknowledging what you're giving up.

**Reference real incidents.** When describing anti-patterns or failure modes, use real (or realistic) incident narratives: "In Q3 2023, a major e-commerce platform experienced a 40-minute outage when a recursive query bypassed complexity limits..."

**First principles before patterns.** Don't cite patterns without explaining the underlying mechanism. Explain why DataLoader works (JavaScript tick-based batching), not just "use DataLoader for N+1."

---

## File Naming Conventions

- **Numbered prefix:** `01-topic-name.md`, `02-another-topic.md` — the number reflects reading order within the folder
- **Folder index:** Every folder has `README.md` as the entry point — overview, prerequisites, links to files within
- **Kebab-case only:** `schema-governance.md`, not `SchemaGovernance.md` or `schema_governance.md`
- **No generic names:** `patterns.md` is bad. `federation-query-planning-patterns.md` is good.

---

## Cross-linking

Use **relative paths only** — no absolute URLs to this repository.

```markdown
<!-- Good -->
See [Federation Directives](../../07-federation/02-federation-directives.md) for @key usage.

<!-- Bad -->
See https://github.com/user/le-graph-ql/blob/main/docs/07-federation/02-federation-directives.md
```

Link from `## Related Topics` at the bottom of every file to 3–5 closely related documents.

---

## Quality Checklist

Before submitting a PR, confirm:

- [ ] All 12 template sections are present (adapt headings but don't skip sections)
- [ ] At least one Mermaid diagram in every architecture or flow topic
- [ ] No placeholder content ("TODO", "coming soon", "TBD")
- [ ] Minimum 400 lines per topic file (READMEs can be shorter)
- [ ] Code blocks use syntax highlighting (` ```graphql `, ` ```yaml `, ` ```bash ` etc.)
- [ ] All cross-links use relative paths and point to files that exist
- [ ] References section has at least 3 external links (official docs, GitHub repos, blog posts)
- [ ] Mermaid syntax tested at [mermaid.live](https://mermaid.live)

---

## Submitting Changes

1. Fork the repository
2. Create a branch: `docs/add-federation-patterns` or `docs/fix-security-typos`
3. Follow the template and quality checklist
4. Open a PR with a description explaining: what you added/changed and why
5. Link related issues or doc gaps

Reviewers will check: template compliance, technical accuracy, Mermaid syntax validity, and cross-link correctness.
