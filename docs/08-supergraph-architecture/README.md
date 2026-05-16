# 08 — Supergraph Architecture

> A supergraph is the composed, federated schema plus the runtime infrastructure that serves it. The schema
> is built from many independently-deployed subgraphs; Apollo Router (or a compatible gateway) executes
> queries against that schema at runtime. This chapter documents every layer: the router itself, its
> configuration surface, multi-variant schema management, and the operational practices required to run
> the supergraph reliably at enterprise scale.

---

## What Is the Supergraph?

The term **supergraph** has two distinct meanings that are often conflated and must be understood separately.

**The supergraph schema** is the unified, composed GraphQL schema produced by the Apollo Federation
composition engine. It is not served directly — clients never receive the raw supergraph SDL. Instead the
composition output (a supergraph SDL or a build artifact stored in Apollo GraphOS) is consumed by the
router at startup. The registry (Apollo GraphOS, WunderGraph Cosmo, or GraphQL Hive) is the source of
truth for this schema. Subgraph teams publish their partial schemas to the registry; the registry runs
composition and validates the result; the router fetches the composed schema on a polling interval or
webhook push.

**The supergraph runtime** is Apollo Router — a Rust binary that accepts client requests, runs the query
planner to determine which subgraphs to call, fans out the subgraph requests in parallel (or serially when
data dependencies require it), merges the responses, and streams the result back to the client. Apollo
Router also enforces authentication, applies rate limits, injects headers, emits OpenTelemetry traces and
Prometheus metrics, and can be extended via Rhai scripts or compiled Rust plugins.

The distinction matters operationally: the schema and the router are deployed independently. A subgraph
can publish a new schema version without restarting the router (hot reload). The router can be scaled
horizontally without touching any subgraph.

---

## Architecture Overview

```mermaid
graph TD
    subgraph Clients
        web["Web App<br/>(browser)"]
        mobile["Mobile App<br/>(iOS / Android)"]
        partner["Partner API<br/>(server-to-server)"]
    end

    cdn["CDN / WAF<br/>(Cloudflare / CloudFront)"]

    subgraph Router Layer
        router1["Apollo Router<br/>replica-1"]
        router2["Apollo Router<br/>replica-2"]
        router3["Apollo Router<br/>replica-3"]
    end

    subgraph Subgraph Cluster
        usersGql["Users Subgraph<br/>:4001"]
        productsGql["Products Subgraph<br/>:4002"]
        ordersGql["Orders Subgraph<br/>:4003"]
        paymentsGql["Payments Subgraph<br/>:4004"]
        inventoryGql["Inventory Subgraph<br/>:4005"]
    end

    subgraph Registries & Observability
        graphos["Apollo GraphOS<br/>(Schema Registry)"]
        otel["OpenTelemetry<br/>Collector"]
        prometheus["Prometheus<br/>+ Grafana"]
        jaeger["Jaeger / Tempo<br/>(Distributed Traces)"]
    end

    subgraph Backing Stores
        usersDb[("Users DB<br/>PostgreSQL")]
        productsDb[("Products DB<br/>PostgreSQL")]
        ordersDb[("Orders DB<br/>PostgreSQL")]
        cache[("Redis<br/>Cache")]
    end

    web --> cdn
    mobile --> cdn
    partner --> cdn
    cdn --> router1
    cdn --> router2
    cdn --> router3

    router1 --> usersGql
    router1 --> productsGql
    router1 --> ordersGql
    router1 --> paymentsGql
    router1 --> inventoryGql

    router2 --> usersGql
    router2 --> productsGql
    router2 --> ordersGql

    router3 --> usersGql
    router3 --> productsGql

    graphos --> router1
    graphos --> router2
    graphos --> router3

    router1 --> otel
    router2 --> otel
    router3 --> otel
    otel --> prometheus
    otel --> jaeger

    usersGql --> usersDb
    productsGql --> productsDb
    ordersGql --> ordersDb
    ordersGql --> cache
    productsGql --> cache

    classDef clientNode fill:#dbeafe,stroke:#3B82F6,color:#1e3a8a
    classDef routerNode fill:#e8f4f8,stroke:#0ea5e9,color:#0c4a6e
    classDef subgraphNode fill:#f0fdf4,stroke:#22c55e,color:#14532d
    classDef dbNode fill:#fef9c3,stroke:#eab308,color:#713f12
    classDef registryNode fill:#fdf4ff,stroke:#a855f7,color:#581c87
    classDef obsNode fill:#fdf2f8,stroke:#ec4899,color:#831843

    class web,mobile,partner clientNode
    class cdn,router1,router2,router3 routerNode
    class usersGql,productsGql,ordersGql,paymentsGql,inventoryGql subgraphNode
    class usersDb,productsDb,ordersDb,cache dbNode
    class graphos registryNode
    class otel,prometheus,jaeger obsNode
```

---

## Prerequisites

Before working through this chapter, you should be comfortable with the concepts covered in
**Chapter 07 — Federation**:

- Apollo Federation v2 directives (`@key`, `@external`, `@provides`, `@requires`, `@shareable`, `@override`)
- Subgraph schema authoring and the `_entities` query
- The query planning algorithm and how entity resolution works
- The difference between a gateway (JavaScript, `@apollo/gateway`) and Apollo Router (Rust)
- Rover CLI basics: `rover subgraph publish`, `rover graph fetch`

If those concepts are unfamiliar, complete Chapter 07 first.

---

## Files in This Chapter

| File | Topic |
|------|-------|
| [01-apollo-router.md](./01-apollo-router.md) | Apollo Router architecture, `router.yaml` reference, WASM plugins, Rhai scripting |
| [02-router-configuration.md](./02-router-configuration.md) | Traffic shaping, entity caching, coprocessors, per-subgraph overrides, mTLS |
| [03-graph-variants.md](./03-graph-variants.md) | Apollo GraphOS variants, contract graphs, GitOps promotion, schema checks |
| [04-router-at-scale.md](./04-router-at-scale.md) | High availability, multi-region, cost analysis, disaster recovery, canary deploys |

---

## Key Tooling Referenced

- **Apollo Router** — the Rust-based supergraph runtime (open source, Apache 2.0)
- **Apollo GraphOS** — managed schema registry, launch checks, analytics, contract graphs
- **rover CLI** — the official CLI for interacting with Apollo GraphOS (publish, check, fetch, contract)
- **WunderGraph Cosmo** — open-source alternative schema registry and router (self-hosted)
- **GraphQL Hive** — open-source schema registry with schema checks and analytics (CDN delivery)

---

## Related Chapters

- Chapter 07 — Federation (subgraph authoring, `@key`, entity resolution)
- Chapter 09 — Schema Governance (breaking change policies, ownership, review workflow)
- Chapter 11 — CI/CD Automation (rover in pipelines, automated schema checks)
- Chapter 14 — Observability (OpenTelemetry integration, distributed tracing)
- Chapter 15 — Kubernetes Deployment (router Helm chart, HPA, resource tuning)
