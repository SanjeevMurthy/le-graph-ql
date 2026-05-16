# 04 — Open Federation Standards

> **Purpose:** Analyze the move toward open, vendor-neutral federation standards — the GraphQL Composite Schemas Working Group, the competitive landscape among federation implementations, vendor lock-in risk, and the practical question of whether teams can switch routers or registries without rewriting their schemas. Based on public WG activity, GitHub data, and community adoption signals.

---

## The Status Quo: Apollo Federation's Dominance

Apollo Federation v1 (2019) and v2 (2022) are the dominant specifications for federated GraphQL. Apollo created the supergraph pattern, defined the entity system (`@key`, `@external`, `@requires`, `@provides`), and built the most widely-deployed router (Apollo Router, written in Rust). Apollo GraphOS provides the schema registry, composition tooling, observability, and contract schemas.

This dominance creates a genuine lock-in risk. Teams that built on Apollo Federation v1 in 2019–2021 have discovered that migrating to v2 requires significant schema annotation work. Teams that relied on Apollo Gateway (deprecated) are mid-migration to Apollo Router. Each Apollo product upgrade has required schema changes — which means every client that generated types from the schema also required changes.

The open-source community's response: multiple independent router implementations, schema registries, and now a Working Group effort to standardize federation at the specification level.

---

## GraphQL Composite Schemas Working Group

### Structure and Participants

The Composite Schemas WG is a sub-working-group of the GraphQL Foundation's main Working Group. It was formed in 2022 with the explicit goal of standardizing what Apollo Federation pioneered — producing a vendor-neutral specification for:

1. **Subgraph specification** — how subgraphs declare types, entities, and inter-subgraph relationships
2. **Composition specification** — how multiple subgraph schemas are merged into a supergraph
3. **Router specification** — how the router plans and executes federated queries

Current participants include engineers from:
- **Apollo** — the primary author of Federation v2; participating to influence alignment
- **The Guild** — authors of Hive, graphql-yoga, and the graphql-tools ecosystem
- **WunderGraph** — authors of Cosmo Router
- **Grafbase** — edge-native GraphQL platform
- **Netflix** — large-scale Apollo Federation user
- **Microsoft** — contributor to tooling ecosystem

The broad participation is a positive signal. Unlike some standards processes that are dominated by a single vendor, the Composite Schemas WG has genuine multi-stakeholder representation.

### Deliverables and Progress (Mid-2025)

| Deliverable | Status | Notes |
|------------|--------|-------|
| Subgraph SDL specification | Initial draft | Covers `@key`, entity types, built-in scalars |
| Composition algorithm specification | Active draft | Most complex piece — composition is hard to specify |
| Router behavior specification | Early draft | Covers query planning principles, not implementation |
| Reference composition implementation | In progress | Open-source tool, vendor-neutral |
| Test suite | Planning | Cross-implementation compatibility tests |

The WG publishes meeting notes and RFC documents at [github.com/graphql/composite-schemas-wg](https://github.com/graphql/composite-schemas-wg).

### What Standardization Means in Practice

**What will be standardized:**
- The SDL directives used in subgraph schemas (`@key`, `@external`, `@requires`, `@provides`, `@shareable`, `@inaccessible`, `@override`, `@tag`)
- The semantics of entity resolution (what `_entities` query must return)
- The composition rules (what constitutes a composition error, what types of sharing are allowed)
- The `_service` introspection endpoint (how routers discover a subgraph's SDL)

**What will NOT be standardized:**
- Router configuration syntax and format
- Router plugin and coprocessor APIs
- Schema registry APIs and webhook formats
- Observability and tracing formats (covered by OpenTelemetry separately)
- Performance characteristics and query planning heuristics

**The practical implication:** Once standardized, you will be able to write subgraph schemas that compose correctly across multiple router implementations. You will NOT be able to take a Cloudflare Workers-based Cosmo router configuration and run it unchanged on Apollo Router — router configuration portability is not in scope for the WG.

---

## Competitive Landscape: Feature Matrix

### The Four Major Federation Implementations

| Feature | Apollo Federation (GraphOS) | Hive (The Guild) | Cosmo (WunderGraph) | Grafbase |
|---------|---------------------------|------------------|--------------------|-|
| **Router implementation** | Apollo Router (Rust) | Hive Gateway (TS) | Cosmo Router (Go) | Grafbase Gateway (Rust) |
| **Schema registry** | GraphOS (SaaS/self-host) | Hive (open-source SaaS) | Cosmo Control Plane | Grafbase Cloud |
| **Federation v2 support** | Full | Full | Full | Full |
| **Composite Schemas WG alignment** | Actively participating | Actively participating | Actively participating | Participating |
| **Open source router** | Yes (Apache 2.0) | Yes (MIT) | Yes (Apache 2.0) | Yes |
| **Open source registry** | Partial (Rover CLI open) | Yes (fully open) | Yes (fully open) | No |
| **Subscription support** | Yes (WebSocket + SSE) | Yes | Yes | Yes |
| **@defer / @stream** | Yes (Apollo Router) | In progress | Yes (Cosmo Router) | In progress |
| **Native Rhai scripting** | Yes | No | No | No |
| **Coprocessor support** | Yes | Via plugins | Via middleware | Via plugins |
| **Managed federation** | Yes (GraphOS cloud) | Yes (Hive cloud) | Yes (Cosmo cloud) | Yes |
| **Self-hosted control plane** | Enterprise tier only | Yes (open source) | Yes (open source) | No |
| **Contract schemas** | Yes (GraphOS feature) | Partial | In development | No |
| **Field-level usage analytics** | Yes (GraphOS) | Yes (Hive) | Yes (Cosmo) | Limited |
| **Persisted queries / safelisting** | Yes | Yes | Yes | Yes |
| **Multi-graph / multi-variant** | Yes (graph variants) | Yes (targets) | Yes (federated graphs) | Yes |
| **Edge deployment** | Cloudflare Workers (beta) | Not native | Kubernetes-native | Cloudflare Workers |
| **Native ARM64 support** | Yes | Yes | Yes | Yes |

### Hive — The Open-Source Alternative

Hive is the most mature fully open-source alternative to Apollo GraphOS. Built and maintained by The Guild (a consultancy that maintains graphql-tools, graphql-yoga, Envelop, and dozens of other widely-used packages), Hive offers:

- **Schema registry** with push-based and passive schema reporting
- **Breaking change detection** with field-level usage data from operation reports
- **Composition** using the same algorithm as Apollo Federation v2
- **Hive Gateway** — a TypeScript-based router compatible with Apollo Federation v2 subgraphs
- **Self-hosted** — the entire stack runs on your infrastructure via Docker Compose or Helm charts

**When to choose Hive:**
- You need a fully open-source schema registry (Apollo's registry is SaaS-only except at Enterprise tier)
- Your organization has a policy against SaaS data products for schema governance
- You are a small team without an enterprise GraphQL budget
- You want to run Hive Gateway alongside Apollo Router (they are compatible subgraph consumers)

**When to choose Apollo GraphOS:**
- You need deep integration with Apollo Studio's trace visualization
- You require contract schemas (a commercial-only Apollo feature)
- Your team is already invested in Apollo's toolchain and the migration cost exceeds the lock-in cost

### Cosmo (WunderGraph) — The Kubernetes-Native Challenger

Cosmo Router is written in Go (not Rust like Apollo Router), optimized for Kubernetes-native deployment with native gRPC subgraph support. The Cosmo Control Plane is fully open-source, making it the most operationally transparent option for teams running their own infrastructure.

**Differentiators:**
- **Go-based router** — lower memory footprint than Rust in some configurations; familiar tooling for Go shops
- **gRPC subgraph support** — first-class support for subgraphs that expose gRPC interfaces (with proto-to-schema generation)
- **Fully open control plane** — schema registry, composition, and analytics all run on your infrastructure
- **WebAssembly plugin system** — extend the router using WASM modules (language-agnostic)

**When to choose Cosmo:**
- You have Go infrastructure expertise and prefer a Go-based router
- You want to run a fully open-source control plane without an Apollo enterprise contract
- You have existing gRPC services you want to expose as subgraphs without a REST translation layer

### Grafbase — Edge-First Federation

Grafbase is positioned as an edge-native federation platform, with first-class support for Cloudflare Workers deployment and a schema registry integrated with CI/CD. It is the least mature of the four options and currently lacks some features (contract schemas, field-level analytics) that are standard in Apollo and Hive.

**Best suited for:** Small teams building on Cloudflare Workers infrastructure who want a managed edge GraphQL platform without self-hosting a control plane.

---

## Vendor Lock-In Risk Assessment

### The Three Layers of Lock-In

Lock-in in federated GraphQL exists at three distinct layers with different exit costs:

**Layer 1: Subgraph Schema Directives (Low Lock-In)**

The directives you write in subgraph schemas (`@key`, `@external`, `@requires`, `@provides`, `@shareable`, `@inaccessible`, `@tag`) are implemented by all major federation routers. Switching from Apollo Router to Cosmo Router or Hive Gateway does NOT require changing your subgraph schemas.

Exit cost: Low. Subgraph schemas are portable across Apollo-compatible routers today.

**Layer 2: Router Configuration (Medium Lock-In)**

Each router has its own configuration format:
- Apollo Router: YAML with Rhai scripting support and coprocessor hooks
- Cosmo Router: YAML with WASM plugin support
- Hive Gateway: TypeScript/JavaScript plugin system

Moving from one router to another requires rewriting your router configuration, coprocessors, and custom plugins. The logic is often port-able, but the syntax and APIs are not.

Exit cost: Medium. Plan for 2–8 weeks of platform engineering work per router migration, depending on the complexity of your coprocessors and plugins.

**Layer 3: Schema Registry and Control Plane (High Lock-In)**

Schema registry features vary significantly:
- Apollo's contract schemas (schema subsets by `@tag`) have no direct equivalent in Hive or Cosmo
- Apollo GraphOS Studio's trace waterfall visualization is proprietary
- Rover CLI schema operations are Apollo-specific
- The webhook and notification format for schema check results differs across registries

If you rely on Apollo-specific contract schemas, migrating your registry requires redesigning your schema segmentation strategy — not just porting configuration.

Exit cost: High for teams using Apollo-specific registry features. Medium for teams using only core functionality (push, check, diff).

### Reducing Lock-In Today

Regardless of which vendor you choose, these practices reduce your lock-in surface:

1. **Use only Federation v2 standard directives.** Avoid Apollo-specific extensions that are not in the Composite Schemas WG draft (e.g., `@authenticated`, `@requiresScopes` are Apollo Router-specific policy directives with no equivalent in other routers).

2. **Keep coprocessors stateless and protocol-based.** If your coprocessor communicates via a standard HTTP request/response protocol (not Apollo's proprietary SDK), it can work with any router that supports coprocessors.

3. **Own your operation analytics pipeline.** Apollo's field-level usage data is stored in GraphOS — you cannot export it. Instead, implement OpenTelemetry-based tracing that ships to your own Tempo/Jaeger/Grafana stack. This is router-agnostic.

4. **Avoid Apollo-specific contract schema features if you anticipate switching.** Contract schemas can be approximated by maintaining separate schema variants with `@inaccessible` applied differently — this is portable.

5. **Pin your federation version explicitly.** Use `@link(url: "https://specs.apollo.dev/federation/v2.6")` with a specific version. Floating `latest` causes silent schema changes when Apollo releases new spec versions.

---

## The Future of Apollo GraphOS vs Open-Source Alternatives

### Apollo's Commercial Position

Apollo's commercial model depends on GraphOS — the cloud-hosted schema registry, observability, and governance platform. Apollo Router is open-source (Apache 2.0), but the control plane (GraphOS) is SaaS. This is a standard open-core model.

Apollo's competitive advantages that will persist despite standardization:
- **Deepest feature set** — contract schemas, field-level usage attribution, Studio trace visualization
- **Best developer experience** — Rover CLI, Studio, and GraphiQL are the benchmark for DX in the ecosystem
- **Largest mindshare** — most new GraphQL engineers learn federation via Apollo's documentation

Apollo's risks:
- If the Composite Schemas WG standardizes composition, the router layer commoditizes and Apollo's differentiation shifts entirely to GraphOS features
- Hive and Cosmo are closing the feature gap annually

### Open-Source Alternatives' Trajectory

Hive and Cosmo are both growing. Key signals:

| Signal | Apollo Router | Hive | Cosmo |
|--------|--------------|------|-------|
| GitHub Stars (router/registry) | ~5,700 | ~3,100 | ~2,400 |
| npm weekly downloads (gateway pkg) | ~350,000 | ~45,000 | ~8,000 |
| Major production users (public) | Meta, Netflix, Shopify | Multiple EU enterprises | Several mid-market companies |
| Full-time maintainers | 20+ (Apollo) | 8–10 (The Guild) | 5–8 (WunderGraph) |
| Enterprise support contracts | Yes | Yes | Yes |

The download gap between Apollo and the alternatives reflects the installed base advantage. New project starts are more evenly split in 2025 than they were in 2022.

---

## Schema Registry Interoperability

### Can You Switch Registries Without Rewriting Schemas?

**Short answer: Yes, if you use only standard Federation v2 directives and core registry features.**

**Detailed answer:**

The subgraph SDL you push to a registry is just a `.graphql` file. All registries accept subgraph SDL and perform composition. The push mechanism differs (Rover CLI for Apollo, `hive schema:publish` for Hive, `wgc subgraph publish` for Cosmo), but the artifact (the SDL) is the same.

Where interoperability breaks:
- **Contract schemas** — Apollo-specific; Hive has no direct equivalent
- **Schema check configuration** — Apollo's `rover graph check` has different flags and semantics than `hive schema:check`
- **Webhook payload format** — CI/CD pipelines that consume schema check webhooks must be updated when switching registries

A practical migration path:

```
Phase 1: Run both registries in parallel (1–2 weeks)
  - Push schema to both Apollo and Hive/Cosmo simultaneously
  - Compare composition results
  - Verify breaking change detection parity
  - Test webhook integration with new registry

Phase 2: Migrate CI/CD to new registry (1 week)
  - Update schema check commands in GitHub Actions
  - Redirect webhooks to new registry

Phase 3: Migrate router to new router (2–4 weeks)
  - Deploy new router in shadow mode (receives traffic, doesn't serve it)
  - Compare responses between old and new router
  - Gradual traffic shift with rollback plan

Phase 4: Decommission old stack
```

---

## Community Momentum Indicators

### Leading Indicators of Ecosystem Health

Teams evaluating which federation stack to invest in should watch these signals:

**GitHub activity** (stars are a lagging indicator; commit velocity and issue resolution rate are leading):
- Apollo Router: High commit velocity; large team; fast issue resolution
- Hive: Consistent commit velocity; community PRs accepted rapidly
- Cosmo: High commit velocity for a small team; aggressive feature development

**Job postings** (search LinkedIn, Lever, Greenhouse for "GraphQL Federation"):
- "Apollo Federation" appears in ~85% of federated GraphQL job postings (2025)
- "Hive" or "WunderGraph" appear in ~10% — growing from ~2% in 2022
- Implication: hiring GraphQL engineers will be easier if you are on Apollo Federation

**Conference talks and adoption reports:**
- Apollo Summit and GraphQL Conf are the primary venues — watch for case studies from companies not using Apollo for their registry

**npm download trends** (`@apollo/gateway`, `@apollo/server`, `@graphql-hive/client`, `wundergraph-cosmo`):
- Apollo packages dominate total downloads but the year-over-year growth rate for alternatives is higher
- Apollo's gateway deprecation (in favor of Apollo Router) has caused some churn that alternatives have captured

### The Pragmatic Position

Given the current ecosystem state, the pragmatic choice for most enterprises is:

- **Use Apollo Federation v2 directives in your subgraph schemas** — they are the most widely supported, they will align with the Composite Schemas WG standard, and your schemas will remain portable.
- **Choose your router based on your platform team's technology stack** — Apollo Router (Rust-based, best DX), Cosmo (Go-based, fully open control plane), or Hive Gateway (TypeScript, easiest for JS shops).
- **Choose your registry based on your control plane requirements** — Apollo GraphOS (best features, SaaS), Hive (fully open, self-hostable), or Cosmo (fully open, self-hostable).
- **Invest in OpenTelemetry-based observability** — this is registry and router agnostic, and protects your analytics investment across any future migration.

---

## Related Sections

- [07-federation](../07-federation/) — Apollo Federation v2 in depth — the baseline all alternatives implement
- [08-supergraph-architecture](../08-supergraph-architecture/) — Router configuration and composition
- [09-schema-governance](../09-schema-governance/) — Schema registry operation in the context of governance
- [35-governance-models](../35-governance-models/) — Organizational models for governing a federated graph
- [36-future-trends/01-graphql-spec-evolution.md](./01-graphql-spec-evolution.md) — Composite Schemas WG progress in detail
- [38-glossary/02-federation-terms.md](../38-glossary/02-federation-terms.md) — All federation terms defined
