# 01 — Backend Engineer Learning Roadmap

> **Purpose:** A structured 9-week learning path for backend engineers who are new to GraphQL or want to develop production-grade depth. Each phase has a concrete milestone that must be completable before advancing. Time estimates assume 5–8 hours of active learning per week alongside normal work.

---

## Who This Roadmap Is For

This roadmap is for engineers who:

- Write server-side application code (Node.js, Python, Go, Java, or similar)
- Are comfortable with REST API design and HTTP fundamentals
- Have some experience with relational databases and SQL
- Are new to GraphQL, or know the basics but lack production depth

You do not need prior GraphQL experience. You do need comfort with your backend language of choice — the examples in this documentation use TypeScript/Node.js, but the concepts apply to any server-side language.

**What you will be able to do after completing this roadmap:**

- Design type-safe GraphQL schemas for complex domains
- Implement performant resolvers with DataLoader — eliminating N+1 queries
- Write field-level authorization middleware
- Deploy a subgraph into a federated supergraph
- Implement query complexity limiting, depth limits, and persisted queries
- Set up field-level tracing and structured logging for production observability
- Automate schema validation in a CI/CD pipeline

---

## Environment Setup

Before starting Phase 1, set up a local development environment:

```bash
# Required tools
node --version      # v20+ recommended
npm --version       # v9+
docker --version    # For running local Postgres

# Core packages you will use throughout the roadmap
npm install -g @apollo/rover   # Apollo Rover CLI for federation tools

# Verify Rover works
rover --version
```

You do not need a cloud account or Kubernetes cluster to complete Phases 1–4. Phase 5 requires a Kubernetes environment — use a local cluster (kind or k3d) if you do not have cloud access.

---

## Phase 1 — Foundation (2 Weeks)

**Sections:** [00-introduction](../00-introduction/), [01-graphql-fundamentals](../01-graphql-fundamentals/), [02-graphql-internals](../02-graphql-internals/)

### What You Will Learn

- Why GraphQL exists and what problems it solves vs REST
- The three operation types: query, mutation, subscription
- The type system: scalars, objects, interfaces, unions, enums, input types
- Null semantics and what `String` vs `String!` means for error propagation
- How `graphql-js` parses, validates, and executes operations (the execution model)
- What the execution context is and how resolvers access it
- How introspection works and why you should disable it in production

### Recommended Reading Sequence

1. `00-introduction/README.md` — orientation, GraphQL vs REST at a glance (20 min)
2. `00-introduction/01-why-graphql.md` — the root problems (25 min)
3. `01-graphql-fundamentals/01-queries-and-mutations.md` — the core operations (45 min)
4. `01-graphql-fundamentals/02-subscriptions.md` — real-time operations (40 min)
5. `01-graphql-fundamentals/03-type-system.md` — the type system in detail (40 min)
6. `01-graphql-fundamentals/04-schema-definition-language.md` — SDL syntax (35 min)
7. `01-graphql-fundamentals/05-schema-evolution.md` — additive evolution, `@deprecated` (35 min)
8. `02-graphql-internals/` — parse, validate, execute pipeline (60 min)

### Hands-On Exercises

**Exercise 1.1 — Stand up a GraphQL server**

Using Apollo Server 4 and `graphql-js`, stand up a local GraphQL server with:
- A `User` type with id, name, email, and createdAt fields
- A `Query.user(id: ID!): User` root query
- A `Mutation.createUser(name: String!, email: String!): User` mutation
- A hardcoded in-memory data store (a simple JavaScript Map)

Run it locally and use GraphiQL or Apollo Studio Explorer to execute queries.

**Exercise 1.2 — Explore introspection**

Using your running server, run these introspection queries in the explorer:
- `query { __schema { types { name kind } } }` — list all types
- `query { __type(name: "User") { fields { name type { name kind } } } }` — inspect a type
- Disable introspection in your server config and verify it no longer works

**Exercise 1.3 — Trace the execution**

Add `console.log` statements to your resolvers to observe the execution order for a nested query. Then remove them and use Apollo Server's built-in plugin system to add execution logging without modifying resolver code.

### Common Mistakes in Phase 1

- **Returning wrong types from resolvers.** If your schema says `String!` and your resolver returns `null`, the error propagates unexpectedly. Start by understanding the nullability rules before designing your schema.
- **Anonymous operations.** Never write queries without an operation name in development — it builds bad habits. Anonymous operations make APM metrics useless in production.
- **Conflating the resolver function signature with REST handler patterns.** GraphQL resolvers are called per-field, not per-request. A single request may call dozens of resolvers.

### External Resources

- [GraphQL official documentation](https://graphql.org/learn/) — the canonical reference for language fundamentals
- [Apollo Server 4 documentation](https://www.apollographql.com/docs/apollo-server/) — server setup, middleware, plugins
- [How to GraphQL — Backend tutorial](https://www.howtographql.com/graphql-js/0-introduction/) — hands-on tutorial for graphql-js
- [GraphQL spec](https://spec.graphql.org/) — for understanding null propagation rules precisely (reference, not tutorial)

### Phase 1 Milestone

**Write a basic resolver with DataLoader.**

Extend your server to:
1. Connect to a local PostgreSQL database (use `pg` or `Prisma`)
2. Fetch users from the database in your root resolver
3. Add an `orders: [Order!]!` field on `User` that fetches each user's orders
4. Without DataLoader: run the server and observe the N+1 query problem in your logs
5. Add DataLoader: implement a batch function that fetches orders for all user IDs in a single SQL query
6. Verify (via your database query logs) that a query for 10 users with their orders makes exactly 2 SQL queries, not 11

You pass this milestone when: a query for `{ users { id name orders { id total } } }` consistently makes 2 database queries regardless of how many users are returned.

---

## Phase 2 — Schema Design + Resolvers (2 Weeks)

**Sections:** [03-schema-design](../03-schema-design/), [04-resolvers-and-execution](../04-resolvers-and-execution/)

### What You Will Learn

- Designing schemas around the consumer's needs (not the database structure)
- Cursor-based pagination (the Connections spec)
- Mutation response patterns (Shopify-style `userErrors` vs throwing errors)
- Nested resolver execution and field-level resolver chaining
- Context object design — what belongs in context and what does not
- DataLoader caching semantics (request-scoped — do not share across requests)
- Abstract type resolution (`__resolveType` for interfaces and unions)

### Recommended Reading Sequence

1. `03-schema-design/` — all files in section order (2–3 hours total)
2. `04-resolvers-and-execution/` — all files in section order (2–3 hours total)

### Hands-On Exercises

**Exercise 2.1 — Design a schema for a familiar domain**

Pick a domain you know from past work (e-commerce, project management, social media, healthcare). Without looking at your database schema, design a GraphQL schema from the perspective of a consumer. Answer:
- What are the natural entry points (root queries)?
- What types relate to each other, and how?
- Which fields should be nullable, and why?
- Which mutations do consumers need?

Then compare your schema design to your database schema. They will be different — that is expected. The schema should reflect consumer needs, not table structure.

**Exercise 2.2 — Implement connection-style pagination**

Add pagination to your users query:
```graphql
type Query {
  users(first: Int, after: String, last: Int, before: String): UserConnection!
}

type UserConnection {
  edges: [UserEdge!]!
  pageInfo: PageInfo!
  totalCount: Int!
}

type UserEdge {
  node: User!
  cursor: String!
}

type PageInfo {
  hasNextPage: Boolean!
  hasPreviousPage: Boolean!
  startCursor: String
  endCursor: String
}
```

Implement cursor encoding (base64 encode the row ID or offset) and verify that pagination works correctly with your DataLoader setup.

**Exercise 2.3 — Implement mutation response patterns**

Implement a `createUser` mutation with proper error handling:
```graphql
type Mutation {
  createUser(input: CreateUserInput!): CreateUserPayload!
}

type CreateUserPayload {
  user: User          # null if there were errors
  userErrors: [UserError!]!
}

type UserError {
  field: [String!]!   # e.g., ["email"]
  message: String!
  code: UserErrorCode!
}

enum UserErrorCode {
  DUPLICATE_EMAIL
  INVALID_EMAIL_FORMAT
  REQUIRED_FIELD_MISSING
}
```

### Common Mistakes in Phase 2

- **Schema mirrors the database.** A `UserTable` type with `user_id`, `created_at`, `is_deleted` fields is a database table exposed as GraphQL — it is not a schema. Consumers need `id`, `createdAt`, and status fields that reflect business concepts.
- **DataLoader shared across requests.** DataLoader caches results for the request cycle. If you initialize a DataLoader outside of the request context (at module scope), it will return stale cached values across requests. Always create DataLoader instances inside your context factory function.
- **Mutations that throw instead of returning `userErrors`.** `throw new Error("email already exists")` surfaces as an unstructured error in the `errors` array. The `userErrors` pattern keeps validation errors in the data payload where clients can handle them gracefully.

### External Resources

- [Shopify GraphQL design principles](https://shopify.dev/docs/api/design-principles) — the industry benchmark for mutation response patterns
- [Relay Cursor Connections specification](https://relay.dev/graphql/connections.htm) — the canonical pagination spec
- [DataLoader documentation](https://github.com/graphql/dataloader) — implementation reference for batching and caching
- [graphql-scalars](https://the-guild.dev/graphql/scalars) — custom scalar implementations (DateTime, UUID, etc.)

### Phase 2 Milestone

**Design a schema for a domain you know.**

Produce a GraphQL schema (SDL) for a domain from your professional experience. The schema must:
1. Have at least 5 object types with meaningful relationships between them
2. Implement cursor-based pagination on at least 2 list fields
3. Use interfaces or unions for at least one type hierarchy
4. Have at least 3 mutations with proper `userErrors` response patterns
5. Include field descriptions on every type and field (no empty descriptions)
6. Be validated with `rover graph check` or `graphql-inspector` — zero validation errors

Present the schema to a colleague and walk through: why you chose to make certain fields nullable, how pagination works, and what the mutation response pattern achieves.

---

## Phase 3 — Federation (2 Weeks)

**Sections:** [07-federation](../07-federation/), [08-supergraph-architecture](../08-supergraph-architecture/)

### What You Will Learn

- The supergraph architecture: subgraphs, routers, and the unified graph
- Entity types: what they are, how `@key` works, how entity resolution happens
- The `_entities` query: what the router sends to your subgraph when resolving entities
- `@external`, `@requires`, and `@provides`: cross-subgraph field dependencies
- Query planning: how the router determines which subgraphs to query in what order
- `@shareable` and `@inaccessible`: multi-subgraph field sharing and schema segmentation
- `@override`: migrating fields between subgraphs safely

### Recommended Reading Sequence

1. `07-federation/` — all files in section order (2.5–3 hours)
2. `08-supergraph-architecture/` — all files in section order (2.5–3 hours)

### Hands-On Exercises

**Exercise 3.1 — Run a local federated graph**

Set up a local supergraph with two subgraphs using Docker Compose:
- **Users subgraph**: owns `User` entity with `@key(fields: "id")`
- **Orders subgraph**: owns `Order`, references `User` entity with `@extends`

Use `rover dev` for local federation development. Verify that a query for `{ orders { id user { name email } } }` routes correctly through the router.

**Exercise 3.2 — Implement `@requires`**

In your Orders subgraph, add a field that depends on a field from the Users subgraph:
```graphql
# Orders subgraph
type Order {
  id: ID!
  # This field requires User.preferredCurrency from the Users subgraph
  totalInPreferredCurrency: Float @requires(fields: "user { preferredCurrency }")
  user: User!
}

extend type User @key(fields: "id") {
  id: ID! @external
  preferredCurrency: String @external  # owned by Users subgraph
}
```

Implement the `referenceResolver` in the Orders subgraph and verify that the query planner fetches `preferredCurrency` from the Users subgraph before calling your resolver.

**Exercise 3.3 — Trace a query plan**

Enable Apollo Router's query plan debugging output and trace a complex federated query:
1. Write a query that requires data from both subgraphs
2. Inspect the query plan in the router output
3. Identify which subgraph calls are sequential (due to `@requires`) vs parallel
4. Optimize the schema to minimize sequential subgraph calls

### Common Mistakes in Phase 3

- **Making every type an entity.** Not every type needs `@key`. Use entities only for types that are meaningful across subgraph boundaries. Internal types (e.g., `OrderLineItem`) owned by a single subgraph should not be entities.
- **`@external` on the wrong subgraph.** `@external` marks a field that is owned by another subgraph. If you put `@external` on a field that your subgraph actually resolves, composition will reject it.
- **Forgetting the `_service` endpoint.** Apollo Router discovers your subgraph's SDL via the `_service { sdl }` query. If your subgraph does not implement this (Apollo Server does it automatically), the router cannot compose it.

### External Resources

- [Apollo Federation v2 documentation](https://www.apollographql.com/docs/federation/) — the authoritative reference
- [Federation specification](https://www.apollographql.com/docs/federation/subgraph-spec/) — the complete subgraph spec including `_entities` and `_service`
- [Rover CLI documentation](https://www.apollographql.com/docs/rover/) — `rover dev` for local development
- [Apollo Federation examples](https://github.com/apollographql/supergraph-demo-fed2) — reference implementations

### Phase 3 Milestone

**Split a monolith into 2 federated subgraphs.**

Take your schema from Phase 2 (or a domain of similar complexity) and split it into two subgraphs:

1. Identify which types belong to each subgraph (draw the boundary based on team/domain ownership, not just technical convenience)
2. Implement `@key` on entity types that cross the boundary
3. Implement reference resolvers in both subgraphs
4. Configure a local Apollo Router to compose and serve the federated graph
5. Verify that a query spanning both subgraphs returns correct results
6. Verify that a failing resolver in one subgraph does not affect fields from the other subgraph

Write a one-page document explaining why you drew the subgraph boundary where you did. This forces you to articulate the domain ownership model — the real work of federation design.

---

## Phase 4 — Security + Performance (1 Week)

**Sections:** [05-security](../05-security/), [06-performance-and-scaling](../06-performance-and-scaling/)

### What You Will Learn

- Field-level authorization patterns: resolver-level, directive-based, and middleware-based
- The difference between authentication (who are you?) and authorization (what can you access?)
- Query complexity analysis and depth limiting
- Persisted queries and query allowlisting
- APQ (Automatic Persisted Queries) and how they enable CDN caching
- Response caching patterns (in-memory, Redis, CDN)
- Rate limiting by operation name

### Recommended Reading Sequence

1. `05-security/` — all files (2–2.5 hours)
2. `06-performance-and-scaling/` — all files (2–2.5 hours)

### Hands-On Exercises

**Exercise 4.1 — Implement field-level authorization**

Add an `isAdmin: Boolean!` field to your User type (stored in the JWT claims). Implement authorization for sensitive fields:

```typescript
// In your resolver file
const resolvers = {
  User: {
    email: (parent, args, context) => {
      // Users can always see their own email
      // Admins can see any user's email
      if (context.currentUser.id === parent.id || context.currentUser.isAdmin) {
        return parent.email;
      }
      return null; // or throw new ForbiddenError(...)
    },
    
    // Alternative: directive-based approach using @auth
  },
};
```

Verify that:
- Unauthenticated requests cannot access any user data
- Authenticated users can see their own data
- Admin users can see all data
- Your authorization logic is testable in isolation from the resolver

**Exercise 4.2 — Add complexity limits**

Using `graphql-query-complexity` or Apollo Server's built-in complexity limiting:

```typescript
import { createComplexityLimitRule } from 'graphql-query-complexity';

const server = new ApolloServer({
  schema,
  validationRules: [
    createComplexityLimitRule(1000, {
      // Assign complexity costs to fields
      fieldExtensions: {
        complexity: ({ args, childComplexity }) => {
          // Paginated list fields cost more
          if (args.first) return args.first * childComplexity;
          return childComplexity + 1;
        },
      },
    }),
  ],
});
```

Write a query that exceeds your complexity limit and verify it is rejected with a clear error message.

**Exercise 4.3 — Enable APQ**

Enable Automatic Persisted Queries in your Apollo Server and client:
- Server: configure the APQ cache (in-memory or Redis)
- Client: configure Apollo Client to send APQ hash extensions
- Verify in server logs that the second request for the same query uses the hash-only request (smaller payload)

### Common Mistakes in Phase 4

- **Authorization in the root resolver only.** If you check auth in `Query.user` but not in `User.email`, a direct entity query or a federated query can bypass the root-level check. Authorization must be at the field level.
- **Complexity calculation that ignores pagination arguments.** A `users(first: 1000)` query should have 1000x the complexity of `users(first: 1)`. Complexity rules that ignore arguments create an exploitable bypass.
- **Rate limiting by IP.** A single IP can represent thousands of mobile users behind NAT. Rate limit by authenticated user identity (JWT sub claim) or by operation name.

### External Resources

- [Apollo Router security documentation](https://www.apollographql.com/docs/router/security/) — allowlisting, CORS, JWT authentication
- [graphql-query-complexity](https://github.com/slicknode/graphql-query-complexity) — complexity limiting library
- [OWASP GraphQL Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/GraphQL_Cheat_Sheet.html) — comprehensive security checklist
- [APQ documentation](https://www.apollographql.com/docs/apollo-server/performance/apq/) — setup and configuration

### Phase 4 Milestone

**Implement field-level auth + complexity limiting.**

On your federated graph from Phase 3:

1. Implement JWT authentication in the Router (extract JWT, forward user identity headers to subgraphs)
2. Implement field-level authorization in at least one subgraph (3+ fields with different auth requirements)
3. Implement query complexity limiting (reject queries above a threshold)
4. Implement query depth limiting (reject queries nested deeper than your threshold)
5. Enable APQ with a Redis cache
6. Write integration tests that verify:
   - Unauthenticated requests are rejected
   - Users cannot access other users' private fields
   - Overly complex queries are rejected with a descriptive error
   - Overly deep queries are rejected

---

## Phase 5 — CI/CD + Operations (2 Weeks)

**Sections:** [10-schema-validation](../10-schema-validation/), [11-ci-cd-automation](../11-ci-cd-automation/), [12-github-actions](../12-github-actions/), [13-policy-as-code](../13-policy-as-code/), [14-observability](../14-observability/)

### What You Will Learn

- Schema validation and breaking change detection
- Automated schema checks in CI pipelines (GitHub Actions)
- Deployment pipelines for subgraphs (build, test, publish schema, deploy)
- Policy-as-code for schema rules (OPA, custom linting)
- Distributed tracing with OpenTelemetry
- Structured logging for GraphQL (operation name as the primary dimension)
- Prometheus metrics for GraphQL (request rate, error rate, latency by operation)

### Recommended Reading Sequence

1. `10-schema-validation/` — breaking change detection (1 hour)
2. `11-ci-cd-automation/` — deployment pipeline patterns (1.5 hours)
3. `12-github-actions/` — concrete GitHub Actions workflows (1 hour)
4. `13-policy-as-code/` — schema linting and OPA policies (1 hour)
5. `14-observability/` — tracing, logging, and metrics (2 hours)

### Hands-On Exercises

**Exercise 5.1 — GitHub Actions schema check pipeline**

Create a GitHub Actions workflow for your subgraph repository:
```yaml
name: Schema Check
on: [pull_request]

jobs:
  schema-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Rover
        run: |
          curl -sSL https://rover.apollo.dev/nix/latest | sh
          echo "$HOME/.rover/bin" >> $GITHUB_PATH
      - name: Schema Check
        run: |
          rover subgraph check my-graph@production \
            --name users \
            --schema ./schema.graphql
        env:
          APOLLO_KEY: ${{ secrets.APOLLO_KEY }}
```

Test it by introducing a breaking change (remove a field) and verify the CI check fails with a descriptive error.

**Exercise 5.2 — OpenTelemetry tracing**

Instrument your Apollo Server with OpenTelemetry:
- Add spans for resolver execution
- Include operation name as a span attribute
- Export traces to a local Jaeger instance (via Docker)
- Trace a federated query and verify you can see the full trace (router + both subgraphs) in a single trace waterfall

**Exercise 5.3 — Prometheus metrics**

Configure Apollo Server's metrics plugin and Prometheus export:
- Request rate by operation name
- Error rate by operation name and error type
- Resolver execution duration (p50, p95, p99)
- DataLoader batch size distribution

Set up a local Prometheus + Grafana stack (Docker Compose) and build a dashboard showing the four GraphQL golden signals: request rate, error rate, latency, and saturation.

### Common Mistakes in Phase 5

- **Not naming operations in CI test queries.** Integration tests that use anonymous operations inflate your APM error rates because you cannot distinguish test traffic from production traffic. Always name operations, including in tests.
- **Schema check only on the production graph.** Run schema checks against the staging graph during development and the production graph in the final deployment step. A change that is safe on staging may have operations running on production that would be affected.
- **Traces without operation names.** Operation names are the primary grouping dimension for GraphQL traces. Without them, traces from all operations appear as the single `/graphql` endpoint.

### External Resources

- [Apollo Router observability documentation](https://www.apollographql.com/docs/router/configuration/telemetry/instrumentation/) — OpenTelemetry setup
- [OpenTelemetry JavaScript SDK](https://opentelemetry.io/docs/languages/js/) — instrumentation reference
- [Prometheus GraphQL metrics patterns](https://prometheus.io/docs/practices/naming/) — metric naming conventions
- [GitHub Actions documentation](https://docs.github.com/en/actions) — workflow syntax reference

### Phase 5 Milestone

**Deploy a subgraph to Kubernetes with full observability.**

Set up a complete deployment pipeline for one of your Phase 3 subgraphs:

1. Create a Dockerfile for the subgraph (multi-stage build)
2. Create a Kubernetes Deployment, Service, and HPA manifest
3. Set up a GitHub Actions pipeline that:
   - Runs schema checks on PR
   - Builds and pushes Docker image on merge to main
   - Publishes the schema to the registry on successful deployment
   - Runs a post-deployment smoke test
4. Configure OpenTelemetry tracing with export to a local Jaeger
5. Configure Prometheus metrics with a Grafana dashboard showing the four golden signals
6. Verify end-to-end: push a code change, watch the pipeline run, see traces and metrics in your dashboards

---

## Continuing Beyond This Roadmap

After completing Phase 5, you have the foundation for production GraphQL engineering. The next depth areas, depending on your interests:

| Interest | Next Sections |
|----------|---------------|
| Advanced federation patterns | [25-enterprise-patterns](../25-enterprise-patterns/), [30-reference-architectures](../30-reference-architectures/) |
| Production incident response | [26-production-failure-scenarios](../26-production-failure-scenarios/), [32-production-runbooks](../32-production-runbooks/) |
| AI integration | [21-ai-native-graphql](../21-ai-native-graphql/), [22-rag-and-vector-search](../22-rag-and-vector-search/) |
| Interview preparation | [27-interview-preparation](../27-interview-preparation/) |
| Platform engineering | [02-platform-engineer-roadmap.md](./02-platform-engineer-roadmap.md) |
| Architecture | [03-architect-roadmap.md](./03-architect-roadmap.md) |

---

## Related Sections

- [38-glossary/01-graphql-terms.md](../38-glossary/01-graphql-terms.md) — definitions for all terms in this roadmap
- [28-best-practices](../28-best-practices/) — consolidated best practices reference
- [29-anti-patterns](../29-anti-patterns/) — common mistakes to avoid
