# Chapter 25: Enterprise GraphQL Patterns

> **Purpose:** This chapter catalogs design patterns that recur across enterprise GraphQL deployments. Each pattern is documented with the problem it solves, the solution it prescribes, its trade-offs, and explicit guidance on when to apply it and when to avoid it. Patterns are grouped into four families: schema patterns, resolver patterns, federation patterns, and integration patterns. Engineers building or reviewing a GraphQL system at scale should treat this chapter as a decision record reference — use it to evaluate options, justify choices in ADRs, and align across teams.

---

## Why Patterns Matter at Enterprise Scale

A pattern is a named, repeatable solution to a recurring problem in a specific context. In enterprise GraphQL, the context is always the same: multiple teams, multiple clients, millions of requests per day, and an evolving schema that must not break existing consumers.

Without shared vocabulary and agreed solutions, every team reinvents the wheel — often in incompatible directions. Teams that adopted Relay connections independently produce different cursor formats. Teams that added error handling to mutations produce different shapes. Teams that needed to call a REST API from a resolver built six variations of the same wrapper.

This chapter gives teams a common library of solutions they can cite, adopt, and compose.

---

## Pattern Families

### Schema Patterns

Decisions made in the schema SDL are the hardest to undo. They are the public contract with every client. Schema patterns in this chapter address the most consequential schema decisions: how to paginate, how to evolve safely, how to model errors, how to handle nullability, and how to express polymorphism.

| Pattern | Problem Solved |
|---|---|
| [Relay Specification](#relay) | Consistent pagination across all list fields |
| [Command/Query Segregation](#cqs) | Mutation inputs that evolve without breaking queries |
| [Schema Versioning via Deprecation](#deprecation) | Safe field removal without breaking clients |
| [Nullable by Default for Partial Data](#nullable) | Prevent single-field errors from nullifying entire responses |
| [Error Union Pattern](#error-union) | Typed, structured mutation errors instead of generic error extensions |
| [Phantom Types for Scalar Validation](#phantom-types) | Encode domain constraints in the type system |
| [Polymorphism via Interface vs Union](#polymorphism) | Choose the right abstraction for type hierarchies |

### Resolver Patterns

Resolvers are where schema contracts meet data access. Resolver patterns address correctness (N+1), testability (repository pattern), efficiency (memoization), security (cursor encryption), and resilience (field-level error isolation).

| Pattern | Problem Solved |
|---|---|
| [DataLoader Batch-by-Foreign-Key](#dataloader) | Eliminate N+1 database queries |
| [Resolver Chain Memoization](#memoization) | Avoid redundant parent fetches within a single request |
| [Optimistic DataLoader](#optimistic) | Pre-warm entity caches before child resolvers fire |
| [Repository Pattern for Resolvers](#repository) | Decouple data access from resolver logic |
| [Context Factory](#context-factory) | Build request-scoped services once, share across resolvers |
| [Field-Level Error Isolation](#error-isolation) | Contain resolver failures to their own field |
| [Cursor Encryption](#cursor-encryption) | Prevent cursor-based ID exposure |

### Federation Patterns

Federation distributes a schema across teams. Federation patterns address entity ownership, cross-subgraph data composition, schema exposure to different consumer audiences, and safe migration paths.

| Pattern | Problem Solved |
|---|---|
| [Entity Extension Pattern](#entity-extension) | Add fields to another team's entity |
| [Computed Field Pattern](#computed-field) | Derive values from data in multiple subgraphs |
| [Interface Object Pattern](#interface-object) | Share interface implementations across subgraph boundaries |
| [Stub Subgraph Pattern](#stub-subgraph) | Claim entity ownership during migrations |
| [Fan-out Entity Resolution](#fan-out) | Manage performance of multi-subgraph entity resolution |
| [Schema Contract Pattern](#schema-contract) | Expose different schema surfaces to different consumers |
| [Subgraph Namespacing](#namespacing) | Prevent mutation name collisions across teams |

### Integration Patterns

GraphQL rarely lives in isolation. It sits in a larger architecture that includes event buses, CQRS read/write paths, REST legacy systems, and distributed transactions. Integration patterns address how GraphQL fits into these systems.

| Pattern | Problem Solved |
|---|---|
| [Event Sourcing + GraphQL](#event-sourcing) | Expose event-sourced read models via GraphQL |
| [CQRS with GraphQL](#cqrs) | Route reads and writes to purpose-built services |
| [BFF Pattern](#bff) | Tailor schema shape to specific client needs |
| [GraphQL as API Gateway](#api-gateway) | Replace REST gateway with a typed GraphQL surface |
| [Strangler Fig for REST Migration](#strangler-fig) | Incrementally replace REST endpoints with native resolvers |
| [Saga Pattern for Distributed Mutations](#saga) | Coordinate multi-step mutations with compensating actions |
| [Circuit Breaker in Resolvers](#circuit-breaker) | Degrade gracefully when a downstream service is unavailable |

---

## How to Read This Chapter

Each pattern document follows the same structure:

1. **Pattern Name** — the canonical name used in ADRs and code reviews
2. **Problem** — the recurring situation this pattern addresses
3. **Solution** — the specific, actionable prescription
4. **Implementation** — code examples in TypeScript/SDL
5. **Trade-offs** — what you gain and what you give up
6. **When to Use** — preconditions under which this pattern is appropriate
7. **When Not to Use** — counter-indications and cheaper alternatives
8. **Related Patterns** — patterns that compose with or oppose this one

Read the patterns in sequence if you are architecting a new system. Reference individual patterns when evaluating a specific decision.

---

## Chapter Contents

| File | Topic | Reading Time |
|---|---|---|
| [01-schema-patterns.md](./01-schema-patterns.md) | Relay spec, CQRS naming, deprecation, nullability, error unions, phantom types, polymorphism | 60 min |
| [02-resolver-patterns.md](./02-resolver-patterns.md) | DataLoader, memoization, optimistic loading, repository, context factory, error isolation, cursor encryption | 55 min |
| [03-federation-patterns.md](./03-federation-patterns.md) | Entity extension, computed fields, interface objects, stub subgraphs, fan-out, contracts, namespacing | 50 min |
| [04-integration-patterns.md](./04-integration-patterns.md) | Event sourcing, CQRS, BFF, API gateway, strangler fig, saga, circuit breaker | 60 min |

---

## Related Chapters

- [Chapter 03: Schema Design](../03-schema-design/README.md) — foundational schema design principles these patterns build on
- [Chapter 04: Resolvers and Execution](../04-resolvers-and-execution/README.md) — resolver mechanics prerequisite for resolver patterns
- [Chapter 07: Apollo Federation v2](../07-federation/README.md) — federation mechanics prerequisite for federation patterns
- [Chapter 09: Schema Governance](../09-schema-governance/README.md) — governance processes that enforce pattern adoption
- [Chapter 26: Production Failure Scenarios](../26-production-failure-scenarios/README.md) — what happens when these patterns are not followed
- [Chapter 29: Anti-Patterns](../29-anti-patterns/README.md) — the inverse: what not to do and why
