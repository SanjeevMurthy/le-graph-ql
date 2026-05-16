# 24 — System Design Scenarios

> **Purpose:** Worked system design problems for GraphQL at enterprise scale. Each scenario
> follows a consistent structure: requirements elicitation → back-of-the-envelope math →
> schema design → architecture → trade-off analysis. The scenarios are self-contained
> documents with concrete numbers, schema SDL, and Mermaid architecture diagrams.
> They are useful for architecture reviews, team design exercises, and evaluating design
> proposals before committing to an implementation.

---

## How to Use These Scenarios

These are not reference architectures — they are **worked problems**. Each scenario
starts from requirements, reasons through constraints, makes explicit trade-offs, and
arrives at a design that is defensible given the stated constraints. The same
requirements under different constraints would produce a different design.

When using a scenario as a template for a real system design:

1. **Verify the scale estimates.** The back-of-the-envelope numbers are derived from
   stated requirements. Your requirements are different. Run the math for your actual
   scale before adopting an architecture.

2. **Challenge the trade-offs.** Every scenario accepts specific trade-offs (latency for
   simplicity, consistency for availability, operational complexity for cost). These are
   explicit. If your constraints do not match the stated constraints, the trade-off
   analysis may not apply.

3. **Schema SDL is starting points.** The SDL in each scenario is illustrative of the
   design pattern, not a production-ready schema. Real implementations require additional
   fields, error types, input validation types, and documentation.

---

## Scenario Index

| Scenario | Domain | Scale | Primary Design Challenge |
|---|---|---|---|
| [01 — Social Graph API](./01-design-social-graph-api.md) | Social Platform | 500M users, 100M DAU | Follow graph, feed generation, fan-out, real-time notifications |
| [02 — E-Commerce Search](./02-design-ecommerce-search.md) | Retail Platform | 100M products, 50ms p99 | Faceted search, real-time inventory overlay, personalized ranking |
| [03 — Real-Time Dashboard](./03-design-realtime-dashboard.md) | Analytics Platform | 1,000 concurrent users, 10s refresh | Subscription vs polling, aggregation strategy, query complexity budgets |
| [04 — Headless CMS API](./04-design-content-management-api.md) | Media Publishing | 50 editorial teams, CDN-cached | Draft/published schema, CDN invalidation, editorial permissions |
| [05 — IoT Data Platform](./05-design-iot-data-platform.md) | Industrial IoT | 10M devices, 1B events/day | Time-series queries, hot/cold data tiering, subscription for live telemetry |

---

## Cross-Cutting Patterns

Reading across all five scenarios, four design patterns appear repeatedly. Understanding
them in isolation — before seeing them applied in a specific scenario — makes each
scenario easier to follow.

### Cursor-Based Pagination Is Non-Negotiable at Scale

Every scenario that involves list queries at scale uses cursor-based (keyset) pagination.
Offset pagination (`LIMIT 100 OFFSET 50000`) degrades badly at large offsets because the
database must scan and discard 50,000 rows. At 100M products, offset 50,000 requires
scanning half a million rows. Cursor-based pagination uses an indexed key (timestamp,
ID, or composite) to jump directly to the next page position.

The `Connection` pattern (from the Relay specification) is used in every scenario for
paginated list types: `ProductConnection`, `FeedConnection`, `PostConnection`. This
pattern provides consistent pagination semantics across the entire schema.

### DataLoader Is Required for Any Resolver That Fetches by ID

Any resolver that accepts an ID and fetches a single record will produce N+1 queries when
called in a list context without DataLoader. This is the most common performance defect in
GraphQL resolvers. Every scenario notes the DataLoader requirement explicitly, including
the batching key.

### CDN Cacheability Requires GET + APQ

Queries sent via HTTP POST cannot be cached by a CDN. Queries sent via HTTP GET (with the
query in the URL) can be cached, but the query string in the URL makes them long and
potentially privacy-leaking. Automatic Persisted Queries (APQ) solve this: the client
sends a hash of the query, and the CDN caches responses by hash. This pattern appears
in every scenario that involves public or semi-public content (social profiles, product
pages, CMS content).

### Read Replicas Belong in Separate Subgraphs

When a domain has both real-time write operations and expensive analytical read operations,
splitting the read path into a separate subgraph (connected to a read replica) prevents
analytical queries from competing with the write path on the primary database. This
pattern appears in the financial services case study (Case Study 02) and in three of the
five system design scenarios.

---

## Back-of-the-Envelope Reference

These estimates are starting points for capacity planning. They are order-of-magnitude
estimates, not precise measurements.

| Component | Estimate | Notes |
|---|---|---|
| HTTP request processing (router) | ~1ms overhead | Query plan cache warm, simple operation |
| Entity resolution (subgraph hop) | ~5–20ms per hop | Network RTT within same data center |
| PostgreSQL point query (indexed) | ~1–5ms | Indexed lookup, single row |
| PostgreSQL aggregation (1M rows) | ~100–500ms | No pre-aggregation |
| Redis GET | ~0.2–0.5ms | Same region |
| Elasticsearch query | ~10–50ms | Simple query, warm shard |
| DataLoader batch (100 IDs) | ~1 database RTT | vs 100 RTTs without DataLoader |
| WebSocket connection overhead | ~40KB memory | Server-side, at scale |
| SSE connection overhead | ~20KB memory | vs WebSocket — lighter transport |
| Apollo Router memory per 1K connections | ~50MB | Baseline; varies with subscription state |

---

## Navigation Map

| File | Purpose |
|---|---|
| [README.md](./README.md) | This file. Overview, cross-cutting patterns, usage guide. |
| [01-design-social-graph-api.md](./01-design-social-graph-api.md) | Social graph, feed generation, real-time notifications at 500M users |
| [02-design-ecommerce-search.md](./02-design-ecommerce-search.md) | Product search API with real-time inventory at 100M products |
| [03-design-realtime-dashboard.md](./03-design-realtime-dashboard.md) | Analytics dashboard with subscriptions at 1,000 concurrent users |
| [04-design-content-management-api.md](./04-design-content-management-api.md) | Headless CMS with CDN caching and editorial permissions |
| [05-design-iot-data-platform.md](./05-design-iot-data-platform.md) | IoT telemetry API with time-series queries at 10M devices |

---

## Related Topics

- [Production Case Studies](../23-production-case-studies/README.md)
- [Federation](../07-federation/README.md)
- [Supergraph Architecture](../08-supergraph-architecture/README.md)
- [Performance and Scaling](../06-performance-and-scaling/README.md)
- [Caching Strategies](../17-caching-strategies/README.md)
- [Security](../05-security/README.md)
- [Observability](../14-observability/README.md)
