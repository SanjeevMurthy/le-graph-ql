# 02 — Federation, Supergraph, and Schema Registry Terms

> **Purpose:** Alphabetical definitions for federation, supergraph, schema registry, and composition terms used across this documentation. Each entry defines the term, explains why it matters in production contexts, and links to the section where it is covered in depth.

---

**@external** — A federation directive that marks a field in a subgraph as defined by another subgraph. A field annotated `@external` is not resolved by the subgraph that declares it; it is present only to satisfy the dependencies of `@requires` or `@provides` directives in the same subgraph. If the owning subgraph removes the external field from its schema, composition will detect a dangling `@external` reference. *See also:* @requires, @provides, Entity. *Covered in depth:* Section 07.

---

**@inaccessible** — A federation directive that marks a type or field as present in the supergraph schema but excluded from the API schema exposed to clients. `@inaccessible` is used to hide implementation details, internal fields used for entity resolution, and fields that are under development but not yet ready for clients. Unlike removing a field, `@inaccessible` keeps the field available for internal supergraph operations while preventing clients from selecting it. *See also:* @tag, Contract Schema, Supergraph Schema. *Covered in depth:* Section 07.

---

**@interfaceObject** — A federation v2 directive that allows a subgraph to contribute fields to an interface type without implementing the interface's concrete types. A subgraph that uses `@interfaceObject` declares the interface as an entity type with `@key` and adds fields — the router routes entity resolution for those fields to this subgraph regardless of which concrete type was actually returned. This enables cross-subgraph interface enrichment without requiring every implementing subgraph to be updated. *See also:* Interface (GraphQL Terms), @key, Entity Resolution Rate. *Covered in depth:* Section 07.

---

**@key** — The federation directive that designates a type as an entity and identifies the field or fields that uniquely identify instances of that type across subgraphs. `type Product @key(fields: "id") { id: ID! }` declares `Product` as an entity with `id` as its key. Any subgraph that references a `Product` can use its `id` to request the full `Product` from the owning subgraph via the `_entities` query. Compound keys (`@key(fields: "sku warehouse { id }")`) compose multiple fields into a single entity identity. *See also:* Entity, Entity Reference, Reference Resolver, _entities query. *Covered in depth:* Section 07.

---

**@override** — A federation v2 directive that allows one subgraph to declare that it is taking ownership of a field previously resolved by another subgraph. `@override(from: "legacy-subgraph")` migrates field resolution progressively — traffic can be split between the old and new resolver during migration using `@override(from: "...", label: "percent(50)")`. This enables zero-downtime field ownership migration without requiring both subgraphs to be updated simultaneously. *See also:* Subgraph, @shareable, Federated Schema. *Covered in depth:* Section 07.

---

**@provides** — A federation directive that allows a subgraph to declare that it can return certain fields of an entity it references, without requiring the router to make a separate call to the entity's owning subgraph. `reviews @provides(fields: "product { name }")` tells the query planner that the `reviews` subgraph can return `product.name` directly, eliminating a round-trip to the `products` subgraph for that field. This is an optimization hint — it changes the query plan to avoid a subgraph fan-out. *See also:* @requires, @external, Query Plan. *Covered in depth:* Section 07.

---

**@requires** — A federation directive that declares a resolver's dependency on fields from another subgraph. `price @requires(fields: "product { basePrice currency }")` tells the query planner that to resolve `price`, it must first fetch `product.basePrice` and `product.currency` from the `products` subgraph. `@requires` creates a sequential dependency in the query plan: the required fields must be fetched before the requiring resolver executes. This is a latency tax — use it deliberately and benchmark the query plan impact. *See also:* @external, @provides, Query Plan, Fan-out. *Covered in depth:* Section 07.

---

**@shareable** — A federation v2 directive that marks a type or field as resolvable by multiple subgraphs simultaneously. Unlike entity resolution (which routes to the owning subgraph), `@shareable` types can be resolved fully by any subgraph that includes them. This is appropriate for value types (a `Money` type, a `GeoCoordinate` type) that do not have cross-subgraph identity but are used by multiple domains. Avoid `@shareable` on domain entities — it creates implicit coupling between subgraphs that must return consistent data. *See also:* Entity, @key, @override. *Covered in depth:* Section 07.

---

**@tag** — A federation directive that annotates schema elements with named tags, which are then used to define Contract Schemas that include or exclude tagged elements. `@tag(name: "public")` on a field marks it for inclusion in a `public` contract schema variant. Teams use `@tag` to expose different schema subsets to internal consumers (full schema), partner APIs (partner contract), and public APIs (public contract) from the same supergraph without maintaining separate schemas. *See also:* Contract Schema, Graph Variant, @inaccessible. *Covered in depth:* Section 09.

---

**Apollo Gateway (legacy)** — The original JavaScript-based federation gateway from Apollo, now superseded by Apollo Router for most production deployments. Apollo Gateway implements Federation v1 and limited Federation v2 features. It is still supported but is no longer the recommended runtime for new federated supergraph deployments. Teams on Apollo Gateway should plan migration to Apollo Router for improved performance, Rust-based execution, and full Federation v2 support. *See also:* Apollo Router, Federation v1, Federation v2. *Covered in depth:* Section 07.

---

**Apollo GraphOS** — Apollo's cloud-hosted platform for GraphQL schema management, including schema registry, schema check, usage reporting, operation metrics, and client awareness. GraphOS is the managed-service counterpart to self-hosted schema registry solutions like Hive or WunderGraph Cosmo. It provides a web UI (Apollo Studio), CLI tooling (Rover), and schema check integrations for CI/CD pipelines. Teams that prefer not to operate their own schema registry infrastructure use GraphOS. *See also:* Apollo Studio, Rover CLI, Schema Registry, Hive (open-source). *Covered in depth:* Section 09.

---

**Apollo Router** — The production-ready, Rust-based supergraph router that replaces Apollo Gateway for Federation v2 deployments. Apollo Router receives client GraphQL requests, generates a query plan, executes subgraph calls in parallel where possible, and assembles the final response. It supports Rhai scripts and WASM-based coprocessors for custom logic (authentication, request modification, response shaping). Apollo Router is the performance-critical shared infrastructure of a federated supergraph — its availability is the platform SLO. *See also:* Apollo Gateway, Query Planner, Subgraph. *Covered in depth:* Section 07.

---

**Apollo Studio** — The web-based UI for Apollo GraphOS. Studio provides schema exploration (schema reference, query building), operation metrics (which operations are most used, which fields are accessed by which clients), schema check results, and graph variant management. Studio is the primary interface for schema registry operations for teams on Apollo GraphOS. *See also:* Apollo GraphOS, Schema Check, Usage Reporting. *Covered in depth:* Section 09.

---

**Composition** — The process of combining multiple subgraph schemas into a single unified supergraph schema. Composition validates that all subgraph schemas are mutually compatible: entity types are consistently defined across subgraphs, `@requires` fields exist in the subgraphs that provide them, and there are no conflicting type definitions. Composition errors block publication of a new supergraph schema. Successful composition produces the supergraph SDL that the router uses. *See also:* Composition Error, Subgraph Schema, Supergraph Schema, Schema Registry. *Covered in depth:* Section 07.

---

**Composition Error** — An error that occurs during the composition of subgraph schemas into a supergraph schema. Composition errors indicate that the subgraph schemas are mutually incompatible — for example, two subgraphs define the same entity type with different `@key` fields, or a `@requires` references a field that does not exist in the providing subgraph. Composition errors are detected in CI (via `rover supergraph compose` or schema check) and block deployment of the affected subgraph. *See also:* Composition, Schema Check, Rover CLI. *Covered in depth:* Section 10.

---

**Contract Schema** — A filtered view of the supergraph schema, derived by including or excluding types and fields based on `@tag` annotations. A `public` contract schema exposes only fields tagged `@tag(name: "public")`; an `internal` contract schema exposes all fields. Contract schemas allow one supergraph to serve multiple consumer segments with different API surface areas, without maintaining separate schemas or separate deployments. *See also:* @tag, @inaccessible, Graph Variant. *Covered in depth:* Section 09.

---

**Entity** — A GraphQL Object Type in a federated schema that is annotated with `@key` and can be referenced and resolved across subgraph boundaries. Entities are the federation primitive for cross-subgraph data relationships. An entity is "owned" by the subgraph that defines its resolvable `@key` — other subgraphs can reference the entity but must use entity resolution to fetch its fields from the owning subgraph. *See also:* @key, Entity Reference, Reference Resolver, Entity Resolution Rate. *Covered in depth:* Section 07.

---

**Entity Reference** — A stub representation of an entity in a subgraph that does not own that entity. A subgraph that references a `Product` entity includes the entity reference type (`type Product @key(fields: "id") { id: ID! }`) but does not resolve the `Product`'s other fields — those are fetched from the owning subgraph via entity resolution. Entity references are the mechanism by which subgraphs express cross-subgraph type relationships without importing the owning subgraph's full schema. *See also:* Entity, @key, Reference Resolver. *Covered in depth:* Section 07.

---

**Entity Resolution Rate** — An operational metric tracking how efficiently entities are resolved across subgraph boundaries. Entity resolution rate is expressed as the ratio of successful `_entities` query responses to total `_entities` calls. A high entity resolution error rate indicates that the owning subgraph is unavailable or returning errors for entity lookups, which propagates as partial failures in the supergraph response. *See also:* Entity, _entities query, Reference Resolver. *Covered in depth:* Section 14.

---

**Fan-out** — The number of subgraph calls required to resolve a single client query. A query that touches 5 subgraphs has a fan-out of 5. Fan-out is a key latency driver in federated supergraphs: the overall response latency is bounded by the slowest subgraph in the critical path. `@requires` directives increase fan-out by creating sequential dependencies; parallel subgraph calls reduce effective fan-out by overlapping latency. Minimizing unnecessary fan-out is a core supergraph design principle. *See also:* Query Plan, @requires, @provides. *Covered in depth:* Section 08.

---

**Federated Schema** — The combined schema produced by composing multiple subgraph schemas. The federated schema (also called the supergraph schema) is the router's view of the entire API, including all entity definitions, cross-subgraph references, and query planning metadata. Clients never see the full federated schema — they see the API schema, which may be filtered by contracts. *See also:* Composition, Supergraph Schema, Subgraph Schema. *Covered in depth:* Section 07.

---

**Federation v1** — The first version of the Apollo Federation specification, characterized by: `@key`, `@external`, `@requires`, `@provides`, and a `_service { sdl }` query on each subgraph. Federation v1 has known limitations around shared types, value types, and interface handling. New projects should use Federation v2. Existing v1 projects can migrate to v2 incrementally because v2 is backward compatible with v1 schemas. *See also:* Federation v2, Apollo Gateway, Composition. *Covered in depth:* Section 07.

---

**Federation v2** — The current version of the Apollo Federation specification. Federation v2 adds `@shareable`, `@inaccessible`, `@override`, `@interfaceObject`, and improved composition semantics. It fixes several v1 design limitations and enables more flexible subgraph ownership models. Apollo Router is required for full v2 feature support. The v2 spec is stewarded by the Apollo Federation working group and is available as an open specification. *See also:* Federation v1, Apollo Router, @shareable, @override. *Covered in depth:* Section 07.

---

**Graph Variant** — A named configuration of a supergraph schema in a schema registry. Graph variants allow teams to maintain separate schema configurations for different environments (production, staging, development) or different consumer segments (internal, partner, public contracts). Each variant has its own schema history, usage metrics, and schema check configuration. The router is configured with a specific variant's schema at startup. *See also:* Contract Schema, Schema Registry, Apollo GraphOS. *Covered in depth:* Section 09.

---

**Hive (open-source)** — An open-source schema registry and analytics platform developed by The Guild, designed as a self-hosted alternative to Apollo GraphOS. Hive provides schema registry, schema check (compatibility checking), usage reporting, client-aware analytics, and schema versioning. It supports both Apollo Federation and plain GraphQL schemas. Teams that prefer not to use a managed service, or that require data residency guarantees, use Hive. *See also:* Apollo GraphOS, Schema Registry, WunderGraph Cosmo. *Covered in depth:* Section 09.

---

**Interface Object** — See `@interfaceObject`. *Covered in depth:* Section 07.

---

**Managed Federation** — An operational model in which the supergraph schema composition and schema publication are managed by a cloud service (Apollo GraphOS) rather than by a locally executed CLI command. In managed federation, subgraphs publish their schemas to GraphOS via `rover subgraph publish`; GraphOS triggers composition and, if successful, delivers the new supergraph schema to the router via the Uplink protocol. This eliminates the need for teams to run their own composition pipeline. *See also:* Apollo GraphOS, Rover CLI, Schema Registry, Uplink. *Covered in depth:* Section 09.

---

**Query Plan** — The execution plan generated by the Apollo Router's query planner for a specific GraphQL operation. The query plan specifies: which subgraphs to call, in what order, with what sub-queries, and how to merge their responses into a single result. The query plan is the performance-critical output of the planning phase — an inefficient plan (unnecessary sequential calls, redundant entity fetches) causes latency that is invisible at the schema level but dominant in production. Query plans are cached by the router. *See also:* Query Planner, Fan-out, @requires, @provides. *Covered in depth:* Section 07.

---

**Query Planner** — The component of Apollo Router that analyzes a GraphQL operation and the supergraph schema to generate the optimal Query Plan for execution. The query planner determines which subgraphs must be called, which calls can be parallelized, and how entity resolution fits into the execution sequence. The query planner's output changes when the supergraph schema changes (new `@key`, new `@requires`, new subgraph) — schema changes can silently change the performance profile of existing operations. *See also:* Query Plan, Apollo Router, Fan-out. *Covered in depth:* Section 07.

---

**Reference Resolver** — The subgraph resolver function that handles the `_entities` query — given an array of entity representations (objects containing the `@key` fields), it resolves the full entity data for each. The reference resolver is the federation-specific extension to standard GraphQL resolvers: it enables entity resolution across subgraph boundaries. A well-implemented reference resolver uses DataLoader batching to avoid N+1 problems when resolving large arrays of entity representations. *See also:* Entity, @key, _entities query, DataLoader. *Covered in depth:* Section 07.

---

**Rover CLI** — The official command-line tool for interacting with the Apollo Federation ecosystem and schema registry. Rover provides commands for: composing supergraph schemas locally (`rover supergraph compose`), publishing subgraph schemas to the registry (`rover subgraph publish`), running schema checks (`rover subgraph check`), and fetching schema variants. Rover is the primary CI integration point for schema governance automation. *See also:* Apollo GraphOS, Schema Check, Composition. *Covered in depth:* Section 11.

---

**Schema Check** — An automated validation step that compares a proposed subgraph schema change against the current supergraph and against recorded client operation usage, to detect: (1) composition errors — the new schema cannot compose with peer subgraphs; (2) breaking changes — the new schema removes or modifies fields used by active client operations. Schema checks are the primary governance gate in CI/CD pipelines for federated GraphQL. *See also:* Composition Error, Schema Registry, Rover CLI, Usage Reporting. *Covered in depth:* Section 10.

---

**Schema Registry** — A versioned store for subgraph and supergraph schemas that tracks schema history, manages composition, runs schema checks, and exposes schema metadata to consumers. The schema registry is platform infrastructure — its availability is a prerequisite for all schema governance workflows and for the router's ability to load new schema versions. Self-hosted options include Hive and WunderGraph Cosmo; the managed service option is Apollo GraphOS. *See also:* Apollo GraphOS, Hive, WunderGraph Cosmo, Schema Check, Graph Variant. *Covered in depth:* Section 09.

---

**Schema Validation** — The process of verifying that a subgraph schema is internally consistent and valid according to the GraphQL specification and federation directives before it is published to the schema registry. Schema validation runs locally (via `rover subgraph lint` or framework-level checks) and in CI. Distinct from composition (which checks cross-subgraph compatibility) and from runtime validation (which checks individual client queries). *See also:* Schema Check, Composition Error, Rover CLI. *Covered in depth:* Section 10.

---

**Stub Subgraph** — A minimal subgraph implementation that exposes only the schema SDL and the `_service` query, without full resolver implementations. Stub subgraphs are used in testing and local development to mock the presence of a subgraph in the supergraph without running the full service. They allow other subgraph teams to test their cross-subgraph queries against a realistic schema surface without a running instance of the depended-on service. *See also:* Subgraph, Composition. *Covered in depth:* Section 07.

---

**Subgraph** — An independently deployed GraphQL service that is part of a federated supergraph. Each subgraph owns a domain (e.g., `orders`, `inventory`, `users`), publishes its schema to the schema registry, and is called by the Apollo Router during query execution. Subgraphs expose a standard `_service { sdl }` endpoint and, if they define entities, a `_entities` query. Team ownership of subgraphs is the organizational building block of federated GraphQL architecture. *See also:* Subgraph Schema, Entity, Apollo Router, Reference Resolver. *Covered in depth:* Section 07.

---

**Subgraph Schema** — The GraphQL schema for a single subgraph, written in federation-annotated SDL. The subgraph schema includes the types, fields, and directives that the subgraph owns or references. It is published to the schema registry on each deployment and composed with peer subgraph schemas to produce the supergraph schema. Subgraph schemas should be reviewed in CI via schema check before deployment. *See also:* Subgraph, Composition, Supergraph Schema, Schema Check. *Covered in depth:* Section 07.

---

**Supergraph** — The unified GraphQL API assembled from multiple subgraphs via federation. The supergraph presents a single schema and endpoint to clients while routing execution across multiple backend services. The supergraph is the primary artifact of a federated GraphQL platform — it represents the full API capability of the organization, composed from individually owned and deployed subgraphs. *See also:* Supergraph Schema, Apollo Router, Subgraph, Federated Schema. *Covered in depth:* Section 07.

---

**Supergraph Schema** — The composed schema artifact that results from combining all subgraph schemas via the composition process. The supergraph schema is used by the Apollo Router to validate incoming queries, generate query plans, and route subgraph calls. It is a superset of any individual subgraph schema. Clients do not receive the supergraph schema directly; they receive the API schema (which may be filtered by contract or by `@inaccessible`). *See also:* Supergraph, Composition, Federated Schema, @inaccessible. *Covered in depth:* Section 07.

---

**Usage Reporting** — The practice of collecting and reporting which GraphQL operations and fields are used by clients, to inform schema evolution decisions. Schema registries (GraphOS, Hive) ingest operation traces and aggregate field usage metrics. Usage reporting is the data source for: identifying safe fields to deprecate (zero usage), blocking removal of actively used fields (schema check), and understanding client migration progress during deprecation windows. *See also:* Schema Check, @deprecated directive, Apollo Studio. *Covered in depth:* Section 09.

---

**Uplink** — The Apollo protocol by which the Apollo Router fetches the current supergraph schema from Apollo GraphOS on startup and polls for schema updates. The router connects to the Uplink endpoint, authenticates with a graph API key, and receives the composed supergraph SDL. When a new schema version is published (after a `rover subgraph publish` triggers a successful composition), Uplink delivers the update to all router instances, which hot-reload the schema without restarting. *See also:* Apollo GraphOS, Managed Federation, Apollo Router. *Covered in depth:* Section 07.

---

**WunderGraph Cosmo** — An open-source, self-hosted federated supergraph platform developed by WunderGraph, providing router, schema registry, composition, schema check, and observability in a single deployable package. Cosmo is designed to be operated on Kubernetes and supports the Apollo Federation specification. It is a self-hosted alternative to Apollo GraphOS for teams that require full infrastructure control. *See also:* Hive, Apollo GraphOS, Schema Registry. *Covered in depth:* Section 09.

---

**Subgraph Introspection** — The ability to query a subgraph's schema directly via the standard GraphQL introspection query or via the `_service { sdl }` federation endpoint. Subgraph introspection is used by schema registry tooling to fetch the subgraph's current schema. In production, standard introspection on the supergraph (router-level) should be disabled for external clients; subgraph introspection may be restricted to internal network access only. *See also:* _service query, Introspection (GraphQL Terms), Apollo GraphOS. *Covered in depth:* Section 05.

---

**_entities query** — The special federation query implemented by every subgraph that defines entities. The router calls `_entities(representations: [_Any!]!)` with an array of entity representation objects (containing the entity's `@key` fields), and the subgraph returns the resolved entities in the same order. The `_entities` query is the protocol mechanism for entity resolution in federated supergraphs. It is not exposed in the public API schema — it is an internal federation protocol endpoint. *See also:* Entity, @key, Reference Resolver. *Covered in depth:* Section 07.

---

**_service query** — The special federation query implemented by every subgraph that returns the subgraph's SDL: `_service { sdl }`. The schema registry and composition tools use `_service` to fetch the current schema from a running subgraph. It is the introspection mechanism for federation. Like `_entities`, `_service` is not exposed in the public API schema. *See also:* Subgraph Schema, Schema Registry, Composition. *Covered in depth:* Section 07.

---

## Related Topics

- [38-glossary/01-graphql-terms.md](./01-graphql-terms.md) — GraphQL language and runtime terminology
- [38-glossary/03-infrastructure-terms.md](./03-infrastructure-terms.md) — infrastructure and observability terminology
- [07-federation](../07-federation/) — federation concepts and implementation
- [08-supergraph-architecture](../08-supergraph-architecture/) — supergraph design patterns
- [09-schema-governance](../09-schema-governance/) — schema registry, schema check, and governance workflows
