# 01 — GraphQL Language and Runtime Terms

> **Purpose:** Alphabetical definitions for GraphQL language, type system, and execution model terms used across this documentation. Each entry defines the term, explains why it matters in production contexts, and links to the section where it is covered in depth.

---

**Abstract Type** — A type in the GraphQL type system that cannot be used as the concrete type of a field — it must be implemented or resolved to a concrete Object Type. The two abstract types are Interface and Union. Abstract types enable polymorphic query patterns, but resolvers must correctly return a `__typename` hint so the execution engine can select the right fields. In federation, abstract types that span subgraphs require careful design to avoid composition errors. *See also:* Interface, Union, Object Type. *Covered in depth:* Section 01.

---

**Alias (Field Alias)** — A syntax feature that lets a client rename a field in the response by prefixing it with `alias: fieldName`. For example, `cheapPrice: price(currency: USD)` returns the result under the key `cheapPrice` in the response `data` object. Aliases allow a single query to request the same field multiple times with different arguments. They affect query complexity scoring (each alias counts as a separate field) and are sometimes abused in complexity-bomb queries. *See also:* Selection Set, Query Complexity. *Covered in depth:* Section 01.

---

**Argument** — A named input value attached to a field or directive in a GraphQL document. Arguments allow clients to parameterize field resolution — for example, `user(id: "123")` passes `id` as an argument to the `user` field. Arguments are type-checked at the validation phase against the schema's declared argument types. Arguments that accept complex input are typed as Input Types. *See also:* Input Type, Validation Phase. *Covered in depth:* Section 01.

---

**APQ (Automatic Persisted Queries)** — A protocol that allows clients to send a hash of a query document instead of the full query text on repeat requests. The server caches the query by hash; if the hash is unknown, the server returns an error and the client retries with the full query, which is then cached for future requests. APQ reduces network payload size significantly for large queries and is a prerequisite for GET-based GraphQL requests that CDNs can cache. *See also:* Persisted Query, Query (operation type). *Covered in depth:* Section 17.

---

**@deprecated directive** — A built-in GraphQL directive that marks a field, enum value, or argument as deprecated, with an optional `reason` string. Clients that introspect the schema will see the deprecation notice. Schema registries use `@deprecated` alongside usage analytics to enforce deprecation workflows: a field cannot be removed until usage drops to zero. In federation, deprecating a field that is referenced by another subgraph via `@requires` requires coordinating the deprecation across subgraph boundaries. *See also:* @requires, Introspection, Schema. *Covered in depth:* Section 09.

---

**Default Resolver** — The implicit field resolver that GraphQL uses when no explicit resolver function is defined for a field. The default resolver returns the property of the parent object whose name matches the field name. For example, if a resolver returns `{ id: "1", name: "Alice" }` for a `User` type, the `name` field resolves to `"Alice"` via the default resolver without any explicit code. Understanding the default resolver is important for understanding when explicit resolvers are necessary — particularly for fields that require data fetching, authorization checks, or DataLoader batch coordination. *See also:* Resolver, Root Field. *Covered in depth:* Section 04.

---

**Depth Limit** — A query complexity control that rejects queries whose field selection nesting exceeds a configured maximum. A depth limit of 10 means a query cannot have more than 10 levels of nested field selection. Depth limits are simpler to compute than full complexity scoring but less expressive — a shallow but wide query can have high cost without triggering a depth limit. Both depth limits and complexity limits should be configured in production. *See also:* Query Complexity, Validation Phase. *Covered in depth:* Section 05.

---

**Document (GraphQL Document)** — The complete text submitted in a GraphQL request, consisting of one or more Operation and Fragment definitions. A document is parsed by the server into an Abstract Syntax Tree (AST), validated against the schema, and then executed. The term "document" distinguishes the full text (which may include fragments and multiple named operations) from a single operation. Persisted queries and APQ store and retrieve documents by hash. *See also:* Operation, Fragment (named), APQ. *Covered in depth:* Section 02.

---

**DataLoader** — A utility (originally by Facebook, language-agnostic pattern) that batches and caches data fetching within a single request lifecycle. A DataLoader for users accumulates all `user(id: X)` calls made during a single query execution, then sends one batched query to the data source for all requested IDs at once. This eliminates the N+1 problem that arises when nested resolvers each fetch their parent entity separately. DataLoaders are request-scoped — a new DataLoader instance is created per request to prevent data leaking between requests. *See also:* DataLoader Batch Function, DataLoader Cache, N+1 Problem. *Covered in depth:* Section 04.

---

**DataLoader Batch Function** — The function provided to a DataLoader that receives an array of keys (e.g., user IDs) and returns a corresponding array of values (or Promises). The batch function is the integration point between the DataLoader abstraction and the actual data source (database query, REST API call, cache lookup). A well-implemented batch function preserves key order in its response array and handles partial failures by returning Error instances for individual failed keys rather than rejecting the entire batch. *See also:* DataLoader, N+1 Problem. *Covered in depth:* Section 04.

---

**DataLoader Cache (request-scoped)** — The in-memory cache maintained by a DataLoader for the duration of a single request. If the same key is requested twice in one query execution (e.g., two fragments both resolve the same user ID), the DataLoader returns the cached result from the first load rather than issuing a second batch call. This cache is intentionally scoped to a single request: it is created fresh per request and discarded after the response is sent. Using a global or cross-request DataLoader cache is a common anti-pattern that causes data consistency bugs. *See also:* DataLoader, N+1 Problem. *Covered in depth:* Section 04.

---

**Edge (Relay Pattern)** — A wrapper type in the Relay Connections pagination spec that wraps a single node with a cursor. A `PostEdge` type typically has `node: Post` and `cursor: String` fields. The edge abstraction allows the cursor to be associated with a specific position in the result set, enabling stable forward and backward pagination. Edges also provide a location to add per-connection metadata (e.g., relationship attributes between the parent and the node). *See also:* Connection (Relay pattern), Cursor, Node (Relay pattern), PageInfo. *Covered in depth:* Section 03.

---

**Connection (Relay Pattern)** — A standardized pagination container type from the Relay pagination specification. A `PostConnection` type typically has `edges: [PostEdge]` and `pageInfo: PageInfo` fields. The Connection pattern provides consistent pagination across all list fields in a schema, enabling client-side pagination libraries to work without per-field customization. In federation, Connection types that span subgraphs require careful entity design because the cursor must remain valid across subgraph calls. *See also:* Edge, Cursor, PageInfo, Node (Relay pattern). *Covered in depth:* Section 03.

---

**Cursor (Pagination)** — An opaque string that identifies a specific position in a paginated list. Clients pass the cursor back in a subsequent request (via `after` or `before` arguments) to retrieve the next or previous page of results. Cursors are opaque by convention — clients should not attempt to parse or construct them. Server implementations commonly encode the cursor as a base64-encoded row ID or offset, but the encoding is an implementation detail. *See also:* Connection (Relay pattern), Edge, PageInfo. *Covered in depth:* Section 03.

---

**Enum** — A GraphQL scalar type that restricts a field's value to a specific named set of strings. For example, `enum Status { ACTIVE INACTIVE ARCHIVED }`. Enums are serialized as strings in the JSON response. Adding a new enum value is considered a non-breaking change for most clients, but removing an enum value or renaming one is breaking. Enums used as input arguments require clients to know the valid values at build time. *See also:* Scalar, Input Type. *Covered in depth:* Section 01.

---

**Execution Engine** — The runtime component of a GraphQL server that takes a validated query AST and resolves it against the schema by invoking resolver functions. The execution engine walks the query selection set, calls the appropriate resolver for each field, and assembles the results into the response `data` object. In a federated architecture, the router's query planner decomposes a query into subgraph-specific sub-queries, each of which is executed by a separate subgraph execution engine. *See also:* Resolver, Query Plan, Parsing Phase, Validation Phase. *Covered in depth:* Section 02.

---

**Field** — The basic unit of data in a GraphQL schema and query. A field has a name, an optional list of arguments, and a type. In a query, selecting a field requests that the server resolve it. In a schema, a field declaration defines what can be selected, its argument types, and its return type. Every field in a schema has an associated resolver (explicit or default). Field-level authorization, deprecation, and cost annotations all attach to the field definition. *See also:* Resolver, Selection Set, Argument. *Covered in depth:* Section 01.

---

**Fragment (named)** — A reusable piece of field selection in a GraphQL document, defined with the `fragment` keyword and referenced with the spread operator (`...FragmentName`). Named fragments are defined once and can be used in multiple operations within the same document. They reduce query duplication and are the building block of client-side component-driven query composition patterns (e.g., Relay fragments). Servers execute fragment spreads inline — fragments do not change the semantics of the query, only the syntax. *See also:* Fragment (inline), Selection Set, Document. *Covered in depth:* Section 01.

---

**Fragment (inline)** — An anonymous fragment embedded directly in a selection set, defined with `... on TypeName { fields }`. Inline fragments are used primarily for type-conditional field selection on abstract types: `... on AdminUser { permissions }` selects `permissions` only when the concrete type is `AdminUser`. Unlike named fragments, inline fragments cannot be reused across operations. *See also:* Fragment (named), Abstract Type, Union. *Covered in depth:* Section 01.

---

**@include directive** — A built-in execution directive that conditionally includes a field or fragment in the query based on a boolean variable: `@include(if: $showDetails)`. When `$showDetails` is false, the field is excluded from execution entirely — the resolver is not called and the field does not appear in the response. This differs from returning `null` from a resolver: with `@include`, the field is absent from the response rather than null. *See also:* @skip directive, Variable. *Covered in depth:* Section 01.

---

**Input Type** — A special GraphQL type (declared with `input`) used exclusively as argument values — Input Types cannot be used as field return types. Unlike Object Types, Input Types have no resolvers; they are pure data containers for client-provided values. Input Types support nesting (input types can have fields of other input types). They are commonly used for mutation inputs, filter arguments, and pagination arguments. *See also:* Mutation, Argument. *Covered in depth:* Section 01.

---

**Interface** — An abstract type that defines a set of fields that implementing Object Types must include. A field typed as an Interface can return any Object Type that implements it. Interfaces enable polymorphic queries — a `search` field that returns `SearchResult` (interface) can return `Product`, `Article`, and `User` objects in the same list. In federation, interfaces can span subgraphs via `@interfaceObject`, which allows one subgraph to add fields to an interface implemented in another subgraph. *See also:* Abstract Type, Union, @interfaceObject. *Covered in depth:* Section 01.

---

**Introspection** — A built-in GraphQL feature that allows clients to query the schema itself: what types exist, what fields each type has, what directives are defined, and what deprecations are present. Introspection is used by GraphQL development tools, schema explorers, and code generators. In production, introspection should be disabled or restricted to authenticated clients, because it exposes the full API surface to potential attackers who can use it to enumerate fields and plan targeted queries. *See also:* @deprecated directive, Schema. *Covered in depth:* Section 05.

---

**List type** — A type modifier that wraps another type to indicate the field returns an array: `[Post]` means a list of Post objects. Lists can be combined with Non-Null: `[Post!]!` means a non-null list of non-null Post objects. Each element in a list is resolved independently by the execution engine, which is why list fields with nested resolvers are the primary source of N+1 problems. In federation, list fields that reference entities in other subgraphs trigger `_entities` batch calls proportional to the list length. *See also:* Non-Null type, N+1 Problem. *Covered in depth:* Section 01.

---

**Mutation** — One of the three root operation types in GraphQL (alongside Query and Subscription). Mutations are intended for operations that change state on the server. Unlike Query fields, Mutation root fields execute serially (not in parallel) to provide predictable ordering of state changes. A well-designed mutation returns enough information for the client to update its local state without a follow-up query — typically the modified resource plus error information. *See also:* Query (operation type), Subscription (operation type), Input Type. *Covered in depth:* Section 01.

---

**N+1 Problem** — A performance anti-pattern that occurs when a list field resolver fetches N items and then each item's nested resolver makes an additional database query — resulting in 1 + N total queries for a list of N items. For example, resolving `posts { author { name } }` for 100 posts without DataLoader results in 1 query for posts plus 100 queries for authors. The N+1 problem is the most common GraphQL performance failure mode and the primary motivation for the DataLoader pattern. *See also:* DataLoader, DataLoader Batch Function, List type. *Covered in depth:* Section 04.

---

**Named Operation** — A GraphQL operation that includes a name after the operation keyword: `query GetUser { ... }` or `mutation CreatePost { ... }`. Named operations are strongly preferred in production because: (1) the operation name appears in server logs and traces, making debugging feasible; (2) persisted query systems use the operation name as a key; (3) analytics systems group requests by operation name. Anonymous operations (bare `{ user { name } }`) are indistinguishable from each other in observability tooling. *See also:* Operation, operationName, Persisted Query. *Covered in depth:* Section 01.

---

**Node (Relay Pattern)** — In the Relay pagination specification, Node refers to a single item in a paginated list, wrapped by an Edge. `node` is also a special interface in the Relay Global Object Identification specification: any type that implements `Node` must have a globally unique `id` field and a root field `node(id: ID!): Node` that can fetch any entity by its global ID. This interface is used by Relay's normalized cache to identify and update entities. *See also:* Edge, Connection (Relay pattern), Interface. *Covered in depth:* Section 03.

---

**Non-Null type (!)** — A type modifier that declares a field or argument cannot be null: `String!` means the field will always return a string, never null. Non-null is a contract between the server and client. If a non-null field's resolver throws an error, GraphQL cannot honor the contract — the error propagates up to the nearest nullable ancestor field, which becomes null. This propagation can null out large sections of a response. Nullability decisions are architectural choices with significant error handling implications, not mere syntax preferences. *See also:* Scalar, Field, Execution Engine. *Covered in depth:* Section 01.

---

**Object Type** — The core building block of a GraphQL schema. An Object Type has a name and a set of fields, each with a type. Every GraphQL query ultimately resolves to scalar values through a tree of Object Type fields. Root types (`Query`, `Mutation`, `Subscription`) are Object Types. In federation, Object Types can be entities (with `@key` directives that identify them as cross-subgraph references) or value types (plain objects with no cross-subgraph identity). *See also:* Field, Scalar, Abstract Type, @key. *Covered in depth:* Section 01.

---

**Operation** — A single executable unit in a GraphQL document: a query, mutation, or subscription. An operation has an optional name, an optional list of variable definitions, optional directives, and a selection set. A document can contain multiple operations, but a request must specify which operation to execute via the `operationName` field in the HTTP body. *See also:* Document, Named Operation, operationName. *Covered in depth:* Section 01.

---

**Operation Name** — The identifier given to a named GraphQL operation. See *Named Operation*. *Covered in depth:* Section 01.

---

**operationName (field in HTTP body)** — The JSON field in a GraphQL HTTP request body that specifies which operation to execute when the document contains multiple operations. The `operationName` value must exactly match a named operation in the submitted document. It is also the primary dimension for GraphQL observability — metrics, traces, and logs group by `operationName` to provide per-operation performance visibility. *See also:* Named Operation, Document. *Covered in depth:* Section 02.

---

**PageInfo** — A standard type in the Relay Connections pagination spec that provides pagination metadata: `hasNextPage`, `hasPreviousPage`, `startCursor`, and `endCursor`. Clients use `hasNextPage` and `endCursor` to determine whether to fetch the next page and what cursor to use. `PageInfo` is always a non-null field on Connection types. *See also:* Connection (Relay pattern), Edge, Cursor. *Covered in depth:* Section 03.

---

**Parsing Phase** — The first phase of GraphQL request processing, in which the query document text is tokenized and converted into an Abstract Syntax Tree (AST). Syntax errors (malformed queries, unclosed brackets, invalid tokens) are detected in the parsing phase and returned as errors before validation or execution. The parsing phase is fast and has low cost; query complexity attacks that bypass parsing are detected in the validation phase. *See also:* Validation Phase, Execution Engine, Document. *Covered in depth:* Section 02.

---

**Persisted Query** — A query document that is stored on the server side and referenced by a client using a hash or identifier. Unlike APQ (which uses a client-initiated caching protocol), traditional persisted queries involve a static allow-list of pre-approved operations. Only operations in the allow-list can execute in production, which eliminates the possibility of arbitrary query execution and is the strongest form of GraphQL security hardening. *See also:* APQ, Query Complexity, Introspection. *Covered in depth:* Section 05.

---

**Query (operation type)** — The root operation type for read-only data fetching. Query fields execute in parallel (unlike Mutation fields, which execute serially). Most GraphQL traffic is Query operations. In a federated supergraph, a Query operation is decomposed by the query planner into subgraph-specific sub-queries, executed in parallel where possible, and assembled into a single response. *See also:* Mutation, Subscription (operation type), Query Plan. *Covered in depth:* Section 01.

---

**Query Complexity** — A numeric score assigned to a query that estimates the computational cost of executing it. Each field in the query selection set contributes a base cost, with multipliers applied for list fields (cost × expected list size). A complexity limit rejects queries whose total score exceeds the configured threshold before execution begins. Complexity scoring is more expressive than depth limits: it accounts for wide shallow queries that a depth limit would allow but that are expensive to resolve. *See also:* Depth Limit, Alias, @specifiedBy directive. *Covered in depth:* Section 05.

---

**Resolver** — A function associated with a specific field in the GraphQL schema that the execution engine calls to compute that field's value. Resolvers receive four arguments: `parent` (the result of the parent field's resolver), `args` (the field's arguments), `context` (a per-request object for shared resources like database connections and DataLoaders), and `info` (metadata about the field and query). Resolvers can be synchronous or asynchronous. The resolver tree defines the execution behavior of the entire API. *See also:* Default Resolver, DataLoader, Execution Engine. *Covered in depth:* Section 04.

---

**Root Field** — A field on one of the three root types (`Query`, `Mutation`, `Subscription`). Root fields are the entry points for all GraphQL operations — every operation begins by selecting one or more root fields. Root field resolvers typically perform authentication, authorization, and the first data fetch. In federation, root fields are owned by specific subgraphs, and the query planner routes the root field request to the owning subgraph. *See also:* Root Types, Resolver. *Covered in depth:* Section 01.

---

**Root Types** — The three special Object Types that define the entry points to a GraphQL schema: `Query` (read operations), `Mutation` (write operations), and `Subscription` (real-time event streams). Every GraphQL operation begins from one of these root types. Custom names for root types are allowed by the spec (`schema { query: MyQuery }`) but are unusual in practice and not recommended. *See also:* Root Field, Query (operation type), Mutation, Subscription. *Covered in depth:* Section 01.

---

**Scalar (built-in: Int / Float / String / Boolean / ID)** — The leaf types in a GraphQL type system. Scalar fields resolve to concrete values rather than to nested objects. The five built-in scalars are: `Int` (32-bit signed integer), `Float` (double-precision floating point), `String` (UTF-8 string), `Boolean` (`true` or `false`), and `ID` (a serialized unique identifier, serialized as a string). Custom scalars extend the type system for domain-specific types like `Date`, `URL`, or `JSON`. *See also:* @specifiedBy directive, Enum, Object Type. *Covered in depth:* Section 01.

---

**Schema** — The complete type system definition for a GraphQL API: all types, fields, arguments, directives, and root types. The schema defines what clients can query and what contracts the server must honor. In a federated supergraph, the supergraph schema is composed from multiple subgraph schemas by the composition process. The schema is the primary API contract and governance artifact — changes to it affect all clients. *See also:* Schema Definition Language, Schema-First, Code-First. *Covered in depth:* Section 01.

---

**Schema Definition Language (SDL)** — The human-readable text format for expressing a GraphQL schema. SDL uses keywords like `type`, `interface`, `enum`, `union`, `input`, `directive`, and `scalar` to define types and their fields. SDL is the standard way to version and review GraphQL schemas in source control, write schema checks in CI, and publish schemas to a schema registry. *See also:* Schema, Code-First, Schema-First. *Covered in depth:* Section 01.

---

**Schema-First (approach)** — A development workflow in which the schema SDL is written first and the resolver implementations are written to match it. Schema-first enables parallel frontend and backend development (frontend teams can build against mock resolvers), makes the API contract explicit before implementation begins, and is well-suited to federation (where subgraph schemas must be composed and reviewed before implementation). *See also:* Code-First, Schema Definition Language. *Covered in depth:* Section 03.

---

**Code-First (approach)** — A development workflow in which the schema is generated from the server-side code (types, decorators, annotations) rather than written in SDL explicitly. Code-first reduces the risk of schema and implementation diverging but makes schema review and composition harder because the SDL is a build artifact. In federated architectures, the subgraph SDL must be available to the schema registry — code-first projects must generate and publish their SDL as part of CI. *See also:* Schema-First, Schema Definition Language. *Covered in depth:* Section 03.

---

**Selection Set** — The set of fields (and nested selection sets) selected in a GraphQL operation or fragment. In `{ user(id: "1") { name email } }`, `{ name email }` is the selection set for the `user` field. Selection sets are hierarchical — nested types have nested selection sets. The execution engine traverses selection sets to determine which resolvers to call and in what order. *See also:* Field, Fragment (named), Operation. *Covered in depth:* Section 01.

---

**@skip directive** — A built-in execution directive that conditionally excludes a field or fragment from the query based on a boolean variable: `@skip(if: $hideDetails)`. When `$hideDetails` is true, the field is excluded from execution — the resolver is not called. Semantically the inverse of `@include`. *See also:* @include directive, Variable. *Covered in depth:* Section 01.

---

**@specifiedBy directive** — A built-in schema directive used to annotate custom scalar types with a URL pointing to the specification that defines the scalar's serialization format: `scalar Date @specifiedBy(url: "https://scalars.graphql.org/andimarek/date")`. This is a documentation directive; it does not affect runtime behavior but improves schema legibility for tooling and consumers. *See also:* Scalar. *Covered in depth:* Section 01.

---

**Subscription (operation type)** — The root operation type for real-time event streams. A Subscription establishes a persistent connection (typically via WebSocket or SSE) between client and server; the server pushes data events to the client over this connection as they occur. In a federated supergraph, subscriptions require special router configuration because the persistent connection model is different from the request/response model used by queries and mutations. *See also:* Query (operation type), Mutation. *Covered in depth:* Section 01.

---

**Type System** — The complete set of types, type modifiers (Non-Null, List), abstract types, scalars, and directives that form a GraphQL schema. The type system defines what shapes of data are valid in queries, responses, and arguments. GraphQL's type system is strongly and statically typed — the schema is fully defined at server startup, and all queries are validated against it before execution. *See also:* Schema, Object Type, Abstract Type, Scalar. *Covered in depth:* Section 01.

---

**Union** — An abstract type that can resolve to one of several named concrete Object Types without requiring those types to share any fields. `union SearchResult = Product | Article | User` means a `search` field can return any of these three types. Unlike Interface, Union types share no common fields — clients must use inline fragments with type conditions to select fields on the concrete type. Unions are useful for heterogeneous result sets where the types have no meaningful shared interface. *See also:* Abstract Type, Interface, Fragment (inline). *Covered in depth:* Section 01.

---

**Validation Phase** — The second phase of GraphQL request processing (after parsing), in which the query AST is validated against the schema: field selections must exist on the type, argument types must match, required variables must be provided, fragment spreads must not form cycles, and query depth or complexity limits are applied. Validation errors are returned before execution begins — no resolvers are called for an invalid query. This is where complexity-bomb queries are rejected. *See also:* Parsing Phase, Query Complexity, Depth Limit, Execution Engine. *Covered in depth:* Section 02.

---

**Variable** — A named, typed input value declared in an operation definition and passed via a separate `variables` JSON object in the HTTP request body. Variables allow query documents to be parameterized and reused across requests with different input values without string interpolation. They are required for persisted queries and APQ, which rely on the query document text being identical across requests. Variables also prevent injection attacks by keeping user-supplied values separate from the query structure. *See also:* Persisted Query, APQ, Argument. *Covered in depth:* Section 01.

---

## Related Topics

- [38-glossary/02-federation-terms.md](./02-federation-terms.md) — federation and supergraph terminology
- [38-glossary/03-infrastructure-terms.md](./03-infrastructure-terms.md) — infrastructure and observability terminology
- [01-graphql-fundamentals](../01-graphql-fundamentals/) — foundational GraphQL concepts
- [02-graphql-internals](../02-graphql-internals/) — execution engine and parsing internals
- [04-resolvers-and-execution](../04-resolvers-and-execution/) — resolver patterns and DataLoader
