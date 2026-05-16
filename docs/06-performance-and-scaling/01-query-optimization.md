# 01 — Query Optimization

> GraphQL's flexible query model is its greatest feature and its most common performance liability. A single under-optimized resolver can generate hundreds of redundant database queries per request. This chapter covers the analytical and implementation techniques required to prevent query explosion: complexity analysis, DataLoader batching, look-ahead query planning, and persisted query performance.

---

## Learning Objectives

- [ ] Understand why GraphQL resolvers produce the N+1 database query problem by default
- [ ] Implement DataLoader with correct key-ordering semantics to batch and deduplicate database calls
- [ ] Configure `graphql-query-complexity` to assign cost budgets and reject over-budget queries before execution
- [ ] Apply look-ahead optimization with `graphql-parse-resolve-info` to select optimal JOIN strategies
- [ ] Interpret Apollo Router query plan output to identify cross-subgraph fetch patterns
- [ ] Measure the performance benefit of persisted queries relative to ad-hoc query transmission

---

## Overview

GraphQL execution is a tree walk. The executor starts at the root query type, calls each field's resolver, and then — for each resolved object — calls the resolvers for that object's fields, recursively. This model makes the schema composable and easy to reason about, but it creates a structural problem when lists are involved: each element in a list independently triggers its own child resolver calls.

The canonical example is a blog platform. A query for the 100 most recent posts will invoke the `Post` type resolver 100 times. If each `Post` resolver also fetches its `Author` from the database, that is 100 separate `SELECT * FROM users WHERE id = ?` statements — one per post — plus the original query for posts. This is the **N+1 problem**: 1 query to fetch N posts, then N queries to fetch their authors. At 100 posts and 10ms per database round-trip, that is 1 full second of sequential database I/O for a single GraphQL request.

DataLoader is the standard solution. It works by batching all calls that occur within a single JavaScript event-loop tick into a single database call. Rather than making 100 individual lookups, DataLoader accumulates the 100 user IDs and issues one `SELECT * FROM users WHERE id = ANY(array_of_ids)`. The combination of batching and per-request deduplication (two posts by the same author trigger only one database lookup) makes DataLoader essential for any production GraphQL server.

Look-ahead optimization goes further: instead of relying on DataLoader to repair the N+1 problem after the fact, the resolver inspects the parsed query AST before making any database call. If the client requested `User.posts`, the resolver can detect that at resolution time and issue a single JOIN query that returns users and their posts in one round-trip, rather than loading users first and then batching post lookups.

```mermaid
sequenceDiagram
    participant Client
    participant Router as Apollo Router
    participant Subgraph as Users Subgraph
    participant DL as DataLoader
    participant DB as PostgreSQL

    Client->>Router: query { posts { id title author { name email } } }
    Router->>Subgraph: fetch posts with author IDs
    Subgraph->>DB: SELECT * FROM posts LIMIT 100

    Note over Subgraph,DL: WITHOUT DataLoader (N+1)
    loop For each of 100 posts
        Subgraph->>DB: SELECT * FROM users WHERE id = ?
    end

    Note over Subgraph,DL: WITH DataLoader (batched)
    Subgraph->>DL: load(userId) × 100 calls (tick accumulation)
    DL->>DB: SELECT * FROM users WHERE id = ANY([id1,id2,...,id100])
    DB-->>DL: 100 user rows
    DL-->>Subgraph: resolved User objects

    Subgraph-->>Router: resolved posts array
    Router-->>Client: JSON response

    classDef clientNode fill:#dbeafe,stroke:#3B82F6,color:#1e3a8a
    classDef routerNode fill:#e8f4f8,stroke:#0ea5e9,color:#0c4a6e
    classDef subgraphNode fill:#f0fdf4,stroke:#22c55e,color:#14532d
    classDef dbNode fill:#fef9c3,stroke:#eab308,color:#713f12
    class Client clientNode
    class Router routerNode
    class Subgraph subgraphNode
    class DL subgraphNode
    class DB dbNode
```

---

## Core Concepts

### 1. The N+1 Problem in Detail

Consider the following GraphQL schema and a realistic blog query:

```graphql
type Query {
  recentPosts(limit: Int!): [Post!]!
}

type Post {
  id: ID!
  title: String!
  content: String!
  author: User!
  comments: [Comment!]!
  tags: [Tag!]!
}

type User {
  id: ID!
  name: String!
  email: String!
  avatarUrl: String
}

type Comment {
  id: ID!
  body: String!
  author: User!
  createdAt: DateTime!
}
```

A client sends:

```graphql
query RecentPostsPage {
  recentPosts(limit: 50) {
    id
    title
    author {
      id
      name
      avatarUrl
    }
    comments {
      id
      body
      author {
        id
        name
      }
    }
  }
}
```

Without batching, execution generates:

| Step | Query | Count |
|------|-------|-------|
| Fetch posts | `SELECT * FROM posts ORDER BY created_at DESC LIMIT 50` | 1 |
| Fetch post authors | `SELECT * FROM users WHERE id = ?` | 50 |
| Fetch comments per post | `SELECT * FROM comments WHERE post_id = ?` | 50 |
| Fetch comment authors | `SELECT * FROM users WHERE id = ?` | Up to 500 |

**Total: up to 601 database queries** for a single GraphQL request. With DataLoader, this collapses to 4 queries regardless of data volume.

### 2. DataLoader: Batching Mechanics

DataLoader accumulates `.load(key)` calls that happen within the same JavaScript microtask queue flush, then invokes a batch function once per tick. The batch function receives an array of keys and must return a Promise resolving to an array of values in the **same order** as the input keys. This ordering requirement is critical — if the database returns rows in arbitrary order, the resolver will receive mis-matched data.

```typescript
import DataLoader from 'dataloader';
import type { Pool } from 'pg';

// Correct: preserves key ordering
function createUserLoader(db: Pool) {
  return new DataLoader<string, User | null>(async (ids: readonly string[]) => {
    const { rows } = await db.query<User>(
      'SELECT * FROM users WHERE id = ANY($1::uuid[])',
      [ids as string[]]
    );

    // Build a map so we can return in the same order as the input ids
    const userMap = new Map<string, User>(rows.map((u) => [u.id, u]));

    // Return null for any ID that was not found (DataLoader requires
    // the return array to be the same length as the input array)
    return ids.map((id) => userMap.get(id) ?? null);
  });
}
```

DataLoaders are **per-request** objects. They must be created fresh for each incoming GraphQL request and attached to the context object. If a DataLoader instance is shared across requests, it will serve stale data and cause data leakage between users.

```typescript
// Apollo Server context factory — runs once per request
async function createContext({ req }: { req: Request }): Promise<GraphQLContext> {
  const db = await getPooledConnection();
  return {
    db,
    currentUser: await authenticateRequest(req),
    loaders: {
      user: createUserLoader(db),
      post: createPostLoader(db),
      commentsByPostId: createCommentsByPostIdLoader(db),
      tagsByPostId: createTagsByPostIdLoader(db),
    },
  };
}
```

### 3. DataLoader with Caching and Deduplication

DataLoader has a per-request in-memory cache enabled by default. If `user.load('user-123')` is called twice in the same request, the second call returns the cached value immediately without adding `user-123` to the batch. This is safe because the cache is scoped to a single request lifetime.

```typescript
// Deduplication example: author is the same person on 3 posts
const [post1, post2, post3] = await Promise.all([
  context.loaders.post.load('post-1'),
  context.loaders.post.load('post-2'),
  context.loaders.post.load('post-3'),
]);

// All three posts have the same author (id: 'user-42')
// DataLoader will batch ALL THREE into one DB call and return the
// same object reference for all three from cache after the first batch
const [author1, author2, author3] = await Promise.all([
  context.loaders.user.load('user-42'),
  context.loaders.user.load('user-42'), // deduplicated
  context.loaders.user.load('user-42'), // deduplicated
]);
// result: one DB query, not three
```

### 4. Query Complexity Analysis

Complexity analysis assigns a numeric cost to every field in a query and rejects the query before execution if the total cost exceeds a configurable budget. This prevents clients from crafting deeply nested or multiply-paginated queries that would exhaust server resources.

The `graphql-query-complexity` library provides a `fieldExtensionsEstimator` and `simpleEstimator` that can be combined. Connection fields (pagination) require special handling because they multiply the child cost by the `first` or `limit` argument.

```typescript
import {
  getComplexity,
  simpleEstimator,
  fieldExtensionsEstimator,
} from 'graphql-query-complexity';
import type { ApolloServerPlugin } from '@apollo/server';

const QUERY_COMPLEXITY_LIMIT = 1000;

export const complexityPlugin: ApolloServerPlugin = {
  async requestDidStart() {
    return {
      async didResolveOperation({ request, document, schema }) {
        const complexity = getComplexity({
          schema,
          operationName: request.operationName,
          query: document,
          variables: request.variables,
          estimators: [
            // Use field-level complexity annotations from schema extensions first
            fieldExtensionsEstimator(),
            // Fall back to: 1 point per scalar field, multiply by pagination limit
            simpleEstimator({ defaultComplexity: 1 }),
          ],
        });

        if (complexity > QUERY_COMPLEXITY_LIMIT) {
          throw new GraphQLError(
            `Query complexity ${complexity} exceeds the maximum allowed complexity of ${QUERY_COMPLEXITY_LIMIT}. ` +
            `Please reduce the number of requested fields or pagination limits.`,
            { extensions: { code: 'QUERY_TOO_COMPLEX', complexity, limit: QUERY_COMPLEXITY_LIMIT } }
          );
        }

        // Attach complexity to extensions for observability
        request.extensions = { ...request.extensions, queryComplexity: complexity };
      },
    };
  },
};
```

Field-specific complexity annotations in the schema type definitions allow fine-grained control. Connection fields that hit the database with a variable `first` argument are significantly more expensive than scalar fields:

```typescript
// In your GraphQL type definitions (using makeExecutableSchema or SDL)
const typeDefs = gql`
  type Query {
    # This field costs 10 points regardless of its children
    currentUser: User @complexity(value: 10)

    # This connection field costs: first × child_complexity (default 1 per child)
    # So "posts(first: 20)" with 5 child fields = 20 × 5 = 100 points
    posts(first: Int = 10, after: String): PostConnection @complexity(
      value: 5,
      multipliers: ["first"]
    )
  }

  type PostConnection {
    edges: [PostEdge!]!
    pageInfo: PageInfo!
    totalCount: Int! @complexity(value: 5)  # requires COUNT(*) query
  }
`;

// Alternatively, use field extensions directly on the resolver map
const resolvers = {
  Query: {
    posts: {
      resolve: postsResolver,
      extensions: {
        complexity: ({ args, childComplexity }) =>
          (args.first ?? 10) * childComplexity + 5,
      },
    },
  },
};
```

### 5. Depth Limiting

Query depth is a simpler guard that limits how deeply nested a query can be. It prevents clients from crafting queries like `{ user { friends { friends { friends { ... } } } } }` that would recurse through the graph.

```typescript
import depthLimit from 'graphql-depth-limit';

const server = new ApolloServer({
  schema,
  validationRules: [
    depthLimit(10, { ignore: ['IntrospectionQuery'] }),
  ],
});
```

A depth of 10 is a reasonable default for most APIs. Introspection queries are excluded because they are deeply nested by nature and issued only by developer tooling.

---

## Real-World Implementation

### Complete DataLoader Setup for a Blog Platform

```typescript
// src/context/loaders.ts
import DataLoader from 'dataloader';
import type { Pool } from 'pg';

export interface AppLoaders {
  user: DataLoader<string, User | null>;
  postsByUserId: DataLoader<string, Post[]>;
  commentsByPostId: DataLoader<string, Comment[]>;
  tagsByPostId: DataLoader<string, Tag[]>;
  reactionCountByPostId: DataLoader<string, number>;
}

export function createLoaders(db: Pool): AppLoaders {
  return {
    // Simple single-object loader: one ID → one User
    user: new DataLoader<string, User | null>(async (ids) => {
      const { rows } = await db.query<User>(
        `SELECT id, name, email, avatar_url, created_at
         FROM users
         WHERE id = ANY($1::uuid[])`,
        [ids as string[]]
      );
      const map = new Map(rows.map((u) => [u.id, u]));
      return ids.map((id) => map.get(id) ?? null);
    }),

    // One-to-many loader: one user ID → array of Posts
    postsByUserId: new DataLoader<string, Post[]>(async (userIds) => {
      const { rows } = await db.query<Post & { user_id: string }>(
        `SELECT p.*, p.user_id
         FROM posts p
         WHERE p.user_id = ANY($1::uuid[])
         ORDER BY p.created_at DESC`,
        [userIds as string[]]
      );

      // Group rows by user_id
      const grouped = new Map<string, Post[]>();
      for (const row of rows) {
        const existing = grouped.get(row.user_id) ?? [];
        existing.push(row);
        grouped.set(row.user_id, existing);
      }

      // Return an empty array (not null) for any userId with no posts
      return userIds.map((id) => grouped.get(id) ?? []);
    }),

    // One-to-many loader: one post ID → array of Comments
    commentsByPostId: new DataLoader<string, Comment[]>(async (postIds) => {
      const { rows } = await db.query<Comment & { post_id: string }>(
        `SELECT c.*, c.post_id
         FROM comments c
         WHERE c.post_id = ANY($1::uuid[])
         ORDER BY c.created_at ASC`,
        [postIds as string[]]
      );

      const grouped = new Map<string, Comment[]>();
      for (const row of rows) {
        const existing = grouped.get(row.post_id) ?? [];
        existing.push(row);
        grouped.set(row.post_id, existing);
      }
      return postIds.map((id) => grouped.get(id) ?? []);
    }),

    // One-to-many loader: one post ID → array of Tags
    tagsByPostId: new DataLoader<string, Tag[]>(async (postIds) => {
      const { rows } = await db.query<{ post_id: string } & Tag>(
        `SELECT pt.post_id, t.id, t.name, t.slug
         FROM post_tags pt
         JOIN tags t ON t.id = pt.tag_id
         WHERE pt.post_id = ANY($1::uuid[])`,
        [postIds as string[]]
      );

      const grouped = new Map<string, Tag[]>();
      for (const row of rows) {
        const existing = grouped.get(row.post_id) ?? [];
        existing.push({ id: row.id, name: row.name, slug: row.slug });
        grouped.set(row.post_id, existing);
      }
      return postIds.map((id) => grouped.get(id) ?? []);
    }),

    // Aggregation loader: one post ID → reaction count (integer)
    reactionCountByPostId: new DataLoader<string, number>(async (postIds) => {
      const { rows } = await db.query<{ post_id: string; count: string }>(
        `SELECT post_id, COUNT(*)::text AS count
         FROM reactions
         WHERE post_id = ANY($1::uuid[])
         GROUP BY post_id`,
        [postIds as string[]]
      );
      const map = new Map(rows.map((r) => [r.post_id, parseInt(r.count, 10)]));
      return postIds.map((id) => map.get(id) ?? 0);
    }),
  };
}
```

### Look-Ahead Optimization

```typescript
// src/resolvers/query/user.ts
import { parseResolveInfo, ResolveTree } from 'graphql-parse-resolve-info';
import type { GraphQLResolveInfo } from 'graphql';
import type { GraphQLContext } from '../context';

interface UserArgs {
  id: string;
}

export async function userResolver(
  _parent: unknown,
  args: UserArgs,
  context: GraphQLContext,
  info: GraphQLResolveInfo
): Promise<User | null> {
  // Parse the query AST to discover what fields the client actually requested
  const resolveInfo = parseResolveInfo(info) as ResolveTree;
  const requestedUserFields = Object.keys(
    resolveInfo.fieldsByTypeName['User'] ?? {}
  );

  const wantsPosts = requestedUserFields.includes('posts');
  const wantsStats = requestedUserFields.includes('stats');

  if (wantsPosts && wantsStats) {
    // Most expensive path: JOIN posts and compute stats in one query
    const { rows } = await context.db.query(
      `SELECT
         u.*,
         COALESCE(json_agg(p.* ORDER BY p.created_at DESC) FILTER (WHERE p.id IS NOT NULL), '[]') AS posts,
         json_build_object(
           'totalPosts', COUNT(p.id),
           'totalReactions', COALESCE(SUM(r.reaction_count), 0)
         ) AS stats
       FROM users u
       LEFT JOIN posts p ON p.user_id = u.id
       LEFT JOIN (
         SELECT post_id, COUNT(*) AS reaction_count FROM reactions GROUP BY post_id
       ) r ON r.post_id = p.id
       WHERE u.id = $1
       GROUP BY u.id`,
      [args.id]
    );
    return rows[0] ?? null;
  }

  if (wantsPosts) {
    // Medium path: JOIN posts only
    const { rows } = await context.db.query(
      `SELECT
         u.*,
         COALESCE(json_agg(p.* ORDER BY p.created_at DESC) FILTER (WHERE p.id IS NOT NULL), '[]') AS posts
       FROM users u
       LEFT JOIN posts p ON p.user_id = u.id
       WHERE u.id = $1
       GROUP BY u.id`,
      [args.id]
    );
    return rows[0] ?? null;
  }

  // Cheapest path: just fetch the user row (no JOIN)
  const { rows } = await context.db.query(
    'SELECT * FROM users WHERE id = $1',
    [args.id]
  );
  return rows[0] ?? null;
}
```

### Persisted Queries Configuration

```typescript
// Apollo Server persisted query setup
import { ApolloServer } from '@apollo/server';
import { createPersistedQueryLink } from '@apollo/client/link/persisted-queries';
import { sha256 } from 'crypto-hash';
import { KeyvAdapter } from '@apollo/utils.keyvadapter';
import Keyv from 'keyv';
import KeyvRedis from '@keyv/redis';
import Redis from 'ioredis';

const redis = new Redis(process.env.REDIS_URL!);

// Server-side: store and retrieve persisted query documents
const server = new ApolloServer({
  schema,
  persistedQueries: {
    cache: new KeyvAdapter(new Keyv({ store: new KeyvRedis(redis), ttl: 86400000 })),
    // Reject documents not found in the cache (APQ strict mode)
    // Uncomment in production once all clients are sending hashes
    // forbidMultipleExecutions: true,
  },
});

// Client-side: generate SHA-256 hash and send it instead of the full query
const apolloClient = new ApolloClient({
  link: createPersistedQueryLink({ sha256 }).concat(httpLink),
  cache: new InMemoryCache(),
});
```

### Apollo Router Query Plan Analysis

Apollo Router prints query plans in debug mode. The following plan shows a parallel fetch (two subgraphs fetched simultaneously) and a sequential fetch (one subgraph depends on results from the first):

```
QueryPlan {
  Parallel {
    Fetch(service: "posts") {
      {
        recentPosts(limit: 50) {
          id
          title
          __typename
          authorId
        }
      }
    },
    Fetch(service: "tags") {
      {
        popularTags {
          id
          name
        }
      }
    }
  },
  Flatten(path: "recentPosts.@") {
    Fetch(service: "users") {
      {
        ... on Post {
          __typename
          authorId
        }
      } =>
      {
        _entities(representations: $representations) {
          ... on User {
            id
            name
            avatarUrl
          }
        }
      }
    }
  }
}
```

Key observations from this plan:
- `Parallel` means the `posts` and `tags` fetches happen concurrently — no extra latency
- `Flatten` + `Fetch(service: "users")` is a batched entity resolution — the router collects all `authorId` values from all 50 posts and sends them in a single `_entities` query to the users subgraph
- The `=>` arrow shows the representation being sent to the users subgraph — this is the `@key` field

---

## Production Considerations

### Performance

- **Tune DataLoader batch size.** By default DataLoader has no maximum batch size. For very large lists, add `maxBatchSize: 100` to avoid over-sized PostgreSQL `ANY()` arrays. Split into multiple batches automatically.
- **DataLoader with priming.** If a resolver loads a list of entities anyway (e.g., `SELECT * FROM users WHERE org_id = ?`), prime the loader cache with those results so subsequent `.load(id)` calls hit the cache rather than the database.
- **Connection pool sizing.** Each DataLoader batch is one database query. With high concurrency, multiple DataLoader batches can hit the database simultaneously. Ensure the pg pool size matches your expected concurrency level (typical: 10–20 connections per subgraph pod).

```typescript
// Priming the loader cache after a list query
const orgUsers = await db.query('SELECT * FROM users WHERE org_id = $1', [orgId]);
// Prime each user into the loader so sibling resolvers don't re-fetch
for (const user of orgUsers.rows) {
  context.loaders.user.prime(user.id, user);
}
return orgUsers.rows;
```

### Security

- **Enforce complexity limits in all environments.** Do not disable complexity limits in staging or development. Developers need to discover complexity violations early.
- **Log rejected queries.** When a query is rejected for exceeding the complexity limit, log the full operation document, the client IP, and the computed complexity. This helps identify whether the client is a legitimate user who needs an exemption, or a scanner probing for resource exhaustion.
- **Separate complexity limits by client tier.** Internal tooling (admin dashboards) can be granted higher complexity budgets than public API consumers. Use a custom plugin that reads the client's API key tier from context.

### Scaling

- **DataLoader is not a distributed cache.** DataLoader's per-request cache exists only in memory for the lifetime of a single request. It does not share data between concurrent requests or between pods. For shared caching across requests, use Redis with the response cache plugin (see [02-caching-strategies.md](./02-caching-strategies.md)).
- **Persisted queries reduce network overhead.** A typical query document for a complex dashboard page can be 2–5KB. Replacing it with a 64-byte SHA-256 hash reduces request size by ~99% and enables GET-based CDN caching.

### Observability

- Attach `queryComplexity` to every Apollo trace via `request.extensions`. This allows Apollo Studio to filter operations by complexity and identify which clients send the most expensive queries.
- Record DataLoader batch sizes as a histogram metric: `dataloader_batch_size_histogram{loader="user"}`. Consistently large batches may indicate a missing index on the batched column.
- Set a slow-resolver threshold (e.g., 100ms) and log the resolver path, arguments, and elapsed time when exceeded.

---

## Best Practices

1. **Create DataLoaders per request, never as singletons.** A singleton DataLoader accumulates stale data across requests and can serve user A's data to user B. Always instantiate loaders in the context factory.

2. **Always handle the null case in DataLoader batch functions.** If a requested ID does not exist in the database, the batch function must return `null` (not `undefined`) at the corresponding index position. Returning `undefined` causes DataLoader to throw a confusing internal error.

3. **Use look-ahead for high-traffic resolvers.** Identify your top 5 most frequently called resolvers (via Apollo Studio field usage). Apply look-ahead optimization to those first; the impact is highest where traffic is heaviest.

4. **Set complexity limits before going to production.** It is significantly harder to add complexity limits retroactively because legitimate clients may already depend on high-complexity queries. Introduce limits in staged rollout: warn mode first (log but don't reject), then enforce.

5. **Cache the parsed AST for persisted queries.** Apollo Router and Apollo Server both parse the query document on every request. With persisted queries, the parsed AST can be cached by the document hash. Parsing is CPU-bound and typically accounts for 5–15% of total request processing time.

6. **Avoid overly fine-grained DataLoaders.** If two fields always appear together (e.g., `User.posts` and `User.postCount`), load them in a single DataLoader batch function rather than two separate ones. Each separate batch invocation is a separate database round-trip.

7. **Test DataLoader behavior with mocked database calls.** DataLoader batching depends on Promise scheduling. Use `jest.useFakeTimers()` or `flushPromises()` in tests to verify that multiple concurrent `.load()` calls are coalesced into a single batch function invocation.

---

## Anti-Patterns

### Anti-Pattern 1: Calling the Database Inside a DataLoader Batch Function Loop

```typescript
// WRONG: This defeats the entire purpose of DataLoader
const userLoader = new DataLoader(async (ids) => {
  // This makes one DB call per ID — no better than not using DataLoader at all
  return Promise.all(ids.map((id) => db.query('SELECT * FROM users WHERE id = $1', [id])));
});

// CORRECT: One query for all IDs
const userLoader = new DataLoader(async (ids) => {
  const { rows } = await db.query('SELECT * FROM users WHERE id = ANY($1)', [ids]);
  const map = new Map(rows.map((u) => [u.id, u]));
  return ids.map((id) => map.get(id) ?? null);
});
```

**Failure scenario:** A team implements DataLoader to "fix N+1" but uses `Promise.all` over individual queries. Apollo Studio traces show per-field latency is unchanged. The error is invisible until someone inspects the batch function implementation.

### Anti-Pattern 2: Sharing a DataLoader Instance Across Requests

```typescript
// WRONG: module-level DataLoader — shared across ALL requests
const globalUserLoader = new DataLoader(async (ids) => {
  return fetchUsers(ids);
});

const resolvers = {
  Post: {
    author: (post) => globalUserLoader.load(post.authorId), // Data leak risk
  },
};
```

**Failure scenario:** Request A loads user 42 (admin). DataLoader caches the result. Request B from a different user calls `globalUserLoader.load('42')` and gets the cached admin user object — potentially with sensitive fields — from Request A's context. This is a security vulnerability, not just a performance bug.

### Anti-Pattern 3: Unbounded Pagination Arguments in Complexity Calculation

```typescript
// WRONG: no limit on 'first' argument — complexity is unbounded
const typeDefs = gql`
  type Query {
    posts(first: Int): [Post!]!
  }
`;

// A client can send first: 10000 and the complexity estimator won't catch it
// because the estimator multiplies by the argument value
```

**Failure scenario:** A client sends `posts(first: 10000)` with 20 child fields. The complexity is 200,000 — far above any budget — but the schema does not enforce an argument maximum. The fix is to add `@constraint(max: 100)` to the `first` argument, or validate it in the resolver.

### Anti-Pattern 4: Using Look-Ahead for Every Field

```typescript
// WRONG: over-engineering — parseResolveInfo on every single resolver
const resolvers = {
  Post: {
    title: (_parent, _args, _context, info) => {
      const resolveInfo = parseResolveInfo(info); // Unnecessary — title is a scalar
      return _parent.title;
    },
  },
};
```

**Failure scenario:** `parseResolveInfo` traverses and copies the query AST on every call. Calling it on scalar fields (which have no children) wastes CPU and adds latency. Apply look-ahead only in resolvers that make a branching database decision based on child fields.

---

## Operational Notes

- **DataLoader batch timing.** DataLoader batches calls that occur within the same microtask queue flush. If your resolver has an `await` before calling `loader.load()`, the call may land in a different tick and form a separate batch. Minimize async operations before calling `.load()`.
- **Complexity limits and subscriptions.** Apply complexity analysis to subscription operations as well. A subscription that re-runs a complex query on every event can generate sustained high database load.
- **Apollo Router enforces depth limits natively.** Configure `limits.max_depth` in `router.yaml` to add depth limiting at the router level without requiring changes to subgraphs.
- **Introspection in production.** Disable introspection in production (`introspection: false`) to prevent clients from mapping the schema for targeted complexity attacks. Tooling teams can access schema via the Apollo Studio registry instead.

```yaml
# router.yaml — depth and height limits
limits:
  max_depth: 15
  max_height: 200
  max_aliases: 30
  max_root_fields: 20
  warn_only: false
```

---

## References

- [DataLoader GitHub Repository (graphql/dataloader)](https://github.com/graphql/dataloader) — Official DataLoader implementation, API reference, and advanced usage patterns
- [graphql-query-complexity](https://github.com/slicknode/graphql-query-complexity) — Query complexity estimation library with field extensions and multiplier support
- [Apollo Router Query Planning](https://www.apollographql.com/docs/router/executing-operations/query-planning/) — Official documentation on how Apollo Router builds and executes query plans across subgraphs

---

## Related Topics

- [02-caching-strategies.md](./02-caching-strategies.md) — Cache optimized queries to avoid re-executing them entirely
- [04-performance-monitoring.md](./04-performance-monitoring.md) — Measure the impact of DataLoader and look-ahead optimizations with field-level tracing
- [../04-resolvers-and-execution/](../04-resolvers-and-execution/) — Deep dive into the GraphQL execution model and resolver lifecycle
- [../05-security/](../05-security/) — Rate limiting and query depth limits from a security perspective
- [../07-federation/](../07-federation/) — How query plans are generated in a federated supergraph
