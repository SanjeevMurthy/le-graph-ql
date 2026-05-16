# Debugging and Performance Interview Questions

> **Purpose:** Model answers for five high-frequency debugging and performance interview questions in senior+ GraphQL roles. These questions assess operational depth — can you diagnose a live production problem, not just design a clean system? Each answer is structured as a verbal walkthrough: the thought process the interviewer expects to observe, the specific tools and metrics you would consult, and the hypotheses you would form and test. Questions are ordered from observability-first diagnosis through schema composition debugging.

---

## How to Read This File

Each question section contains:
- **The question** as an interviewer typically phrases it
- **What the interviewer is evaluating** — the specific signal they want to see
- **Model answer** — a structured walkthrough of the diagnosis and resolution process, suitable for verbal delivery in an interview
- **Common candidate mistakes** — what weak answers look like
- **Follow-up questions** — what the interviewer asks next to probe depth

Deliver the model answers as if thinking aloud: "First I'd check X, because... then I'd look at Y, because... I'd form the hypothesis that..." Interviewers penalize candidates who jump to a conclusion without showing diagnostic reasoning.

---

## Question 1: Your GraphQL API's p99 Latency Doubled After a Deployment. Walk Me Through Your Debugging Process.

### What the interviewer is evaluating

Your ability to approach a production latency regression systematically. They want to see: (1) that you go to data before forming hypotheses, (2) that you understand which layers of the stack can cause latency regressions, (3) that you know how to use distributed tracing to isolate a problem to a specific operation or resolver, and (4) that you can reason about N+1 regressions, slow queries, and infrastructure changes as distinct root causes.

### Model Answer

"Before I suggest any cause, I need to understand the shape of the regression. Let me walk through how I'd approach this."

**Step 1: Confirm the scope on the operation-level latency dashboard**

"My first move is to pull up the GraphQL operation latency dashboard — I need to know whether p99 doubled for all operations or only a subset. If it's all operations, the problem is likely infrastructure (a router config change, a pod scheduling issue, a networking change). If it's specific operations, I'm looking for a regression in a particular resolver or a new code path."

```promql
# In Grafana, split by operation name to see which operations degraded
histogram_quantile(0.99,
  rate(apollo_router_http_request_duration_seconds_bucket[5m])
) by (operation_name)
```

"If I see that `GetOrderDetails` p99 went from 180ms to 360ms but `GetUserProfile` is unchanged, I've isolated it to a specific operation. That immediately tells me it's not infrastructure."

**Step 2: Correlate with the deployment timing**

"I need to confirm causation, not just correlation. I'd look at the latency timeline and overlay the deployment event. If latency doubled at exactly 14:23 and the deployment completed at 14:22, that's strong causation evidence. If latency started increasing at 14:15 while the deployment was still in progress (rolling deploy), that tells me the new pods were the cause."

```bash
# Check deployment time from Kubernetes
kubectl rollout history deployment/orders-subgraph
kubectl describe deployment/orders-subgraph | grep "last-applied"
```

**Step 3: Open a Tempo trace for the degraded operation**

"With distributed tracing (Tempo, Jaeger, or Honeycomb), I can see the exact breakdown of time within a single request. I'd filter traces for `GetOrderDetails` with duration > 300ms and look at the waterfall."

"The trace will show me the time spent in each subgraph and within each resolver. I'm looking for a span that grew disproportionately — maybe `OrderItem.product` went from 2ms to 45ms, or `Order.customer` has 200 database spans where it should have 1."

**Step 4: Check for N+1 regression via DataLoader batch size metric**

"If the slow span is a resolver that should be using a DataLoader, I'd check the DataLoader batch size metric. A working DataLoader batches dozens of IDs into one query. If the metric shows batch size dropped from 50 to 1, the DataLoader is no longer batching — probably because someone created a new DataLoader instance inside the resolver instead of using the context-level one."

```promql
# DataLoader batch size histogram — should show batches of 10–100 in normal operation
histogram_quantile(0.50,
  rate(dataloader_batch_size_bucket{loader="product"}[5m])
)
# If this shows 1.0, DataLoader batching is broken — N+1 regression
```

**Step 5: Check for slow database queries correlated with the deployment**

"If the trace shows a database span is slow — not many spans, just one slow span — I'd check the database slow query log and `pg_stat_statements` to see if a query plan changed. This can happen when a deployment changes query parameters enough to invalidate a cached query plan, or when a new index was dropped accidentally."

```sql
-- pg_stat_statements: queries that are slower than they were before the deployment
SELECT query, mean_exec_time, calls, total_exec_time
FROM pg_stat_statements
WHERE mean_exec_time > 100  -- ms threshold
ORDER BY mean_exec_time DESC
LIMIT 10;
```

**Step 6: Check for schema/resolver code changes in the deployment diff**

"If I've found that a specific resolver is slow and I've confirmed it wasn't slow before the deployment, I'd pull the git diff for that resolver file. I'm looking for: a new external service call added without a timeout, a DataLoader removed or instantiated inside the resolver, a new `await` that serializes what was previously parallel, or a new authorization check that makes a synchronous database call."

**Synthesis: how I'd communicate the finding**

"In a real incident, I'd be narrating findings to the team as I go. After 5–10 minutes, I'd expect to have either: (1) isolated the slow span to a specific resolver, with a hypothesis about the code change that caused it, or (2) determined it's infrastructure and escalated to SRE. In either case, I wouldn't wait 30 minutes before forming a hypothesis — I form hypotheses at each step and test them with data."

### Common Candidate Mistakes

- Starting with "I'd look at server CPU" — this is too vague and misses the GraphQL-specific tools available. p99 latency is an application-layer problem first.
- Not mentioning distributed tracing — without tracing, diagnosing which resolver is slow requires guessing. Tracing is the essential tool for this class of problem.
- Proposing "rollback" immediately without diagnosing — rolling back might be the right action, but it should follow, not precede, diagnosis. Without understanding the cause, a rollback might not even fix the problem.
- Not knowing about DataLoader batch size as a metric — this is the primary quantitative signal for N+1 regressions.
- Describing the diagnosis as purely sequential — a strong candidate mentions that you'd form and test hypotheses at each step rather than waiting for a complete picture.

### Follow-Up Questions

- "You open a trace and see 200 spans for `OrderItem.product` — the resolver is clearly making 200 individual calls. How do you fix it?"
- "The latency regression is only happening for authenticated users, not anonymous users. What does that tell you, and how does it change your investigation?"
- "How would you catch this regression before it reaches production?"

---

## Question 2: How Do You Prevent a Malicious User from Bringing Down Your GraphQL API with a Single Query?

### What the interviewer is evaluating

Your knowledge of the attack surface specific to GraphQL (query complexity, depth, aliases, introspection) and the layered defense strategy for each. A complete answer covers at least three distinct defense mechanisms and explains why each is necessary — no single mechanism is sufficient alone.

### Model Answer

"GraphQL's query flexibility is its greatest strength and its greatest attack surface. A malicious user can craft queries that are computationally expensive without being obviously large. Let me walk through the attack classes and the defenses for each."

**Attack Class 1: Query depth explosion**

```graphql
# A crafted query that traverses self-referential types to arbitrary depth
{
  category {
    parent {
      parent {
        parent {
          parent { name } # 20+ levels deep
        }
      }
    }
  }
}
```

**Defense:** Depth limit in the router. Reject any query that exceeds a maximum AST depth before execution begins.

```yaml
# router.yaml
limits:
  max_depth: 10  # Reject queries deeper than 10 levels
```

**Attack Class 2: Alias explosion**

```graphql
# Uses aliases to multiply query cost while reporting low complexity
{
  p1: product(id: "1") { reviews { author { name } } }
  p2: product(id: "1") { reviews { author { name } } }
  # Repeated 100 times
  p100: product(id: "1") { reviews { author { name } } }
}
```

**Defense:** Alias limit. The router counts each alias as a separate field in the complexity calculation and rejects queries with too many aliases.

```yaml
limits:
  max_aliases: 30  # Reject queries with more than 30 field aliases
```

**Attack Class 3: Field complexity explosion (calculated complexity)**

"Some fields are exponentially more expensive than others — a `search` field that hits Elasticsearch is orders of magnitude more expensive than an `id` field that's a database lookup. A query that calls `search` 10 times with complex inputs can exceed the cost of 1,000 simple queries."

**Defense:** Per-field cost weights with a global complexity budget:

```graphql
type Query {
  user(id: ID!): User       # cost: 1 (simple DB lookup)
  search(query: String!): [SearchResult!]!  @cost(weight: 50)  # expensive
  reports: [Report!]!       @cost(weight: 100)  # very expensive
}
```

```yaml
limits:
  max_complexity: 500  # Reject queries whose weighted field cost exceeds 500
```

**Attack Class 4: Introspection-based reconnaissance**

"A malicious actor can query `__schema` to map your entire schema, identify sensitive types and mutations, and craft targeted attacks. Introspection is disabled in production for this reason."

```yaml
# router.yaml
introspection: false  # Disable in production; enabled in dev/staging only
```

**Attack Class 5: Batch query flooding**

"Some GraphQL servers support query batching — sending an array of operations in a single HTTP request. A malicious user can send a batch of 1,000 expensive queries in a single request."

**Defense:** Limit the number of operations per batch, or disable batching entirely:

```yaml
limits:
  max_batch_size: 10  # Allow at most 10 operations per batched request
```

**The layered defense stack:**

"No single defense is sufficient. Complexity limits can be bypassed with aliases if aliases aren't counted. Depth limits don't prevent alias explosions. The correct approach is defense in depth:"

1. Depth limit — catches recursive type bombs
2. Alias limit — catches alias multiplication attacks
3. Per-field complexity weights + budget — catches expensive field abuse
4. Rate limiting per IP + per authenticated user — limits overall request volume
5. Persisted queries only in production — eliminates arbitrary query submission entirely
6. Query timeout — ensures any query that slips through still terminates

"Persisted queries is the most powerful defense: in production, only pre-registered operation hashes are accepted. An attacker cannot submit arbitrary queries — they can only use operations that were registered during the development and deployment process."

### Common Candidate Mistakes

- Mentioning only one defense (e.g., "set a complexity limit") — a senior engineer knows that a single defense has bypasses.
- Not knowing about alias multiplication as a complexity bypass.
- Not mentioning persisted queries as the architectural solution for eliminating the entire attack class.
- Saying "use authentication to prevent malicious queries" — authenticated users can also be malicious (or compromised), and complexity attacks do not require authentication bypass.

### Follow-Up Questions

- "What is the difference between a depth limit and a complexity limit? Can a query exceed one without exceeding the other?"
- "You've enabled persisted queries. How do you handle queries from a developer testing in a GraphQL playground?"
- "How do you test that your complexity limits actually catch malicious queries before you deploy them?"

---

## Question 3: A Resolver Is Causing 10x More Database Queries Than Expected. How Do You Find and Fix It?

### What the interviewer is evaluating

Your operational knowledge of the N+1 diagnosis and resolution workflow. A complete answer shows: (1) how to identify the specific resolver using metrics and tracing, (2) how to verify the expected vs. actual query count, (3) how DataLoader fixes it at the code level, and (4) how you verify the fix.

### Model Answer

"Ten times more queries than expected is the classic N+1 signature. Let me walk through the diagnosis."

**Step 1: Identify the resolver using distributed tracing**

"I'd open a trace for a request that's producing excessive queries. In the trace waterfall, I'm looking for a resolver span that has many child database spans. The span `Review.author` with 200 child `SELECT * FROM users WHERE id = ?` spans is the smoking gun."

"Without tracing, I can use database-level introspection:"

```sql
-- In PostgreSQL, check which queries are firing most frequently
-- A sudden appearance of a single-row SELECT by ID is the N+1 signature
SELECT query, calls, mean_exec_time, total_exec_time
FROM pg_stat_statements
WHERE query LIKE '%WHERE id = %'
  AND calls > 1000
ORDER BY calls DESC
LIMIT 10;
```

**Step 2: Confirm the expected vs. actual query count**

"I expect a DataLoader to batch N individual user lookups into one query. If I'm seeing 200 individual `SELECT * FROM users WHERE id = $1` queries instead of one `SELECT * FROM users WHERE id = ANY($1)`, DataLoader is not batching."

"The root causes for DataLoader not batching are almost always one of three things:"

```typescript
// Root cause A: DataLoader instantiated inside the resolver (no batching)
export const ReviewResolvers = {
  Review: {
    author: async (review, _args, context) => {
      // WRONG: new DataLoader() inside the resolver creates a fresh loader
      // per resolver call — it never accumulates a batch
      const loader = new DataLoader(userBatchFn);
      return loader.load(review.authorId);
    }
  }
};

// Root cause B: Using context.db directly instead of the DataLoader
export const ReviewResolvers = {
  Review: {
    author: async (review, _args, context) => {
      // WRONG: direct database call, N+1 pattern
      return context.db.users.findById(review.authorId);
    }
  }
};

// Root cause C: DataLoader cache disabled, but batch function makes individual queries
const loader = new DataLoader(async (ids) => {
  // WRONG: iterating instead of batching
  return Promise.all(ids.map(id => db.users.findById(id)));
});
```

**Step 3: Apply the fix**

```typescript
// CORRECT: DataLoader in the context factory — shared across all resolvers in the request
function buildContext(req: Request): GraphQLContext {
  return {
    db,
    loaders: {
      // One DataLoader instance per request — accumulates batch across all resolver calls
      user: new DataLoader<string, User>(async (userIds: readonly string[]) => {
        const users = await db.query(
          'SELECT * FROM users WHERE id = ANY($1)',
          [[...userIds]]
        );
        const userMap = new Map(users.map(u => [u.id, u]));
        // Return in the SAME ORDER as the input IDs — DataLoader requires this
        return [...userIds].map(id => userMap.get(id) ?? new Error(`User ${id} not found`));
      }),
    }
  };
}

// Resolver uses the context DataLoader
export const ReviewResolvers = {
  Review: {
    author: async (review, _args, context) => {
      return context.loaders.user.load(review.authorId);
    }
  }
};
```

**Step 4: Verify the fix**

"After deploying, I'd verify two things:"

```sql
-- 1. Database query pattern changed from individual to batch
-- Before fix: many single-row queries
-- After fix: one batch query with ANY($1)
SELECT query, calls
FROM pg_stat_statements
WHERE query LIKE '%users%ANY%'  -- DataLoader batch pattern
ORDER BY calls DESC LIMIT 5;
```

```promql
# 2. Resolver latency improved
histogram_quantile(0.99,
  rate(graphql_resolver_duration_seconds_bucket{resolver="Review.author"}[5m])
)
# Before: 200ms (200 serial DB queries)
# After: 15ms (1 batch DB query)
```

**Step 5: Add a regression test**

"The fix is not complete without a test that catches this regression in CI:"

```typescript
// tests/resolvers/Review.author.test.ts
describe('Review.author resolver', () => {
  it('batches multiple author lookups into a single query', async () => {
    const dbSpy = jest.spyOn(db, 'query');

    // Execute a query that fetches 50 reviews, each needing an author
    await executeOperation(REVIEWS_WITH_AUTHORS_QUERY, { reviewIds: generate50ReviewIds() });

    // Verify only ONE database query was made for all 50 authors
    const userQueries = dbSpy.mock.calls.filter(call => call[0].includes('users'));
    expect(userQueries).toHaveLength(1);  // NOT 50
    expect(userQueries[0][0]).toContain('ANY');  // Batch query pattern
  });
});
```

### Common Candidate Mistakes

- Saying "use DataLoader" without explaining how to diagnose which resolver is the culprit first.
- Not mentioning the ordering contract in the DataLoader batch function — forgetting to return results in the same order as input keys is the most common DataLoader implementation bug.
- Not knowing where DataLoaders should be instantiated (context factory, not inside resolvers).
- Not explaining how to verify the fix — proposing a solution without verification is incomplete.

### Follow-Up Questions

- "The DataLoader batch function must return results in the same order as the input keys. What happens if it doesn't?"
- "How does DataLoader handle an ID that doesn't exist in the database? What should the batch function return for a missing ID?"
- "You have a resolver that looks up data by a composite key (userId + tenantId), not just a single ID. How do you structure the DataLoader?"

---

## Question 4: Your Schema Composition Is Failing in CI. What Are the Most Common Causes and How Do You Fix Them?

### What the interviewer is evaluating

Your operational familiarity with federation composition failures — not just knowing they exist, but knowing how to read Rover error output, map an error code to a root cause, and know which teams to involve in resolution.

### Model Answer

"Schema composition failures in CI are among the most disruptive issues in a federated GraphQL organization — they block all subgraph teams from deploying, not just the team that introduced the problem. Let me walk through the most common error classes in order of frequency."

**Error Class 1: Removing a `@key` field or a field used in `@requires`**

"This is the most common cause. A team removes a field from their subgraph during cleanup, not realizing another subgraph uses it in a `@requires` directive."

```
COMPOSITION ERROR [E029]:
  Field `ProductVariant.warehouseRegion` cannot be found in subgraph `catalog`.
  This field is required by:
    - Subgraph `inventory`: @requires(fields: "warehouseRegion")
```

"Fix: Re-add the field to the owning subgraph. If the field should genuinely be removed, coordinate with the dependent subgraph team to migrate their `@requires` first."

**Error Class 2: `@key` field type mismatch across subgraphs**

"When two subgraphs both define the same entity with a `@key`, the `@key` fields must have identical types. If one subgraph says `id: ID!` and another says `id: String`, composition fails."

```
COMPOSITION ERROR [E030]:
  Key field `User.id` has type `ID!` in subgraph `identity`
  but type `String!` in subgraph `orders`.
  All subgraphs that define the same entity must agree on the @key field types.
```

"Fix: Align the type — in practice, make both `ID!`. This is usually introduced when a subgraph team copies an entity stub from the wrong codebase example."

**Error Class 3: Conflicting field definitions on a shared type**

"If two subgraphs define the same field on the same type with different return types, composition fails:"

```
COMPOSITION ERROR [E011]:
  Field `User.role` has return type `String` in subgraph `identity`
  and return type `UserRole` (enum) in subgraph `permissions`.
  Conflicting type definitions for the same field are not permitted.
```

"Fix: One team must change their definition. Use the canonical type from the owning subgraph."

**Error Class 4: Schema syntax errors**

"Less common but easy to miss: a malformed SDL file (missing closing brace, invalid directive syntax) causes the subgraph schema to be unparseable."

```
COMPOSITION ERROR [E001]:
  Subgraph `catalog` schema is not valid SDL:
  Syntax Error: Expected Name, found "}"
  Line 47: type Product @key(fields: "id") {
```

"Fix: Run `rover subgraph introspect` or validate the SDL locally before pushing."

**Diagnosis workflow:**

"When I see a composition failure in CI, my first step is always to read the error output carefully — Rover's error messages are specific about which subgraph introduced the problem and which other subgraph is affected. The error message tells me exactly which teams to involve."

```bash
# Get full composition error detail locally
rover subgraph check \
  --graph-id "$GRAPH_ID" \
  --name "$SUBGRAPH_NAME" \
  --schema schema.graphql \
  2>&1

# Find which subgraph published a breaking change recently
# (In Apollo Studio: Schema > History > Last 4 hours)

# Validate that the fix composes before pushing
rover subgraph check --name <fixed-subgraph> --schema fixed-schema.graphql
```

**Prevention:**

"The best prevention is running `rover subgraph check` in every subgraph's CI before `rover subgraph publish`. The check catches composition errors before they reach the registry. If the check is bypassed with `--skip-checks`, the problem lands in production and blocks all other teams."

### Common Candidate Mistakes

- Saying "restart the CI pipeline" — this doesn't fix a composition error; it just re-runs the same failure.
- Not knowing that composition failures in one subgraph's check block all other subgraphs from deploying.
- Not being able to read a Rover error message and identify which subgraphs are involved.
- Not mentioning the `--skip-checks` bypass as a root cause of composition failures reaching the registry.

### Follow-Up Questions

- "One team's schema check is passing but another team's is failing with the same composition error. How is that possible?"
- "You've identified the breaking change but the team that introduced it says their change was necessary — they genuinely need to remove that field. How do you resolve the situation?"
- "How do you prevent composition failures from blocking unrelated teams in a large federated organization?"

---

## Question 5: How Do You Test a GraphQL API?

### What the interviewer is evaluating

Your understanding of the testing pyramid applied to GraphQL: unit tests for resolver logic, integration tests for resolver + database interaction, contract tests for schema changes, and E2E tests for multi-operation flows. A complete answer discusses all four layers and gives concrete examples of what each layer catches.

### Model Answer

"Testing a GraphQL API requires a pyramid of test types, each catching different failure classes. Let me walk through the layers from bottom to top."

**Layer 1: Unit tests for resolver business logic**

"Resolver functions contain business logic that should be tested in isolation. At this layer, the database and all other dependencies are mocked — you're testing the logic of the resolver, not its integration with infrastructure."

```typescript
// tests/unit/resolvers/Order.test.ts
describe('Order.total resolver', () => {
  it('calculates total correctly with discounts applied', () => {
    const order = {
      items: [
        { price: 1000, quantity: 2, discountPercentage: 0.1 },  // $10 * 2, 10% off
        { price: 500, quantity: 1, discountPercentage: 0 },      // $5 * 1, no discount
      ]
    };

    // No database — pure function test
    const total = OrderResolvers.Order.total(order, {}, mockContext);

    expect(total).toEqual({ amount: 2300, currency: 'USD' });  // (900 + 900) + 500
  });

  it('returns null for orders with no items', () => {
    const order = { items: [] };
    expect(OrderResolvers.Order.total(order, {}, mockContext)).toBeNull();
  });
});
```

"Unit tests are fast (milliseconds), numerous, and catch logic errors early. They do not catch integration failures — a resolver that correctly computes a total but queries the wrong database table will pass unit tests."

**Layer 2: Integration tests against a real database**

"Integration tests execute the full resolver stack against a real (test) database, testing that the resolver produces correct results given actual data. These tests are slower (seconds) but catch the class of bug unit tests miss: wrong SQL, incorrect JOIN conditions, missing index causing timeout."

```typescript
// tests/integration/resolvers/orders.test.ts
describe('Order queries — integration', () => {
  let db: TestDatabase;

  beforeAll(async () => {
    db = await TestDatabase.create();  // Spin up a real PostgreSQL instance
    await db.migrate();
    await db.seed({ users: 5, orders: 20, items: 100 });
  });

  afterAll(() => db.destroy());

  it('returns correct order total for an order with discounts', async () => {
    const orderId = await db.createOrder({
      items: [{ productId: 'p1', price: 1000, quantity: 2 }],
      discountCode: 'SAVE10'
    });

    const result = await executeOperation(
      GET_ORDER_TOTAL_QUERY,
      { id: orderId },
      { db }  // Real database context
    );

    expect(result.data.order.total.amount).toBe(1800);  // 10% discount applied
    expect(result.errors).toBeUndefined();
  });

  it('returns null for an order that belongs to a different user', async () => {
    // Test that authorization works correctly in the resolver
    const result = await executeOperation(
      GET_ORDER_TOTAL_QUERY,
      { id: 'OTHER_USER_ORDER_ID' },
      { db, currentUser: { id: 'user-2' } }  // Different user
    );

    expect(result.data.order).toBeNull();
    // Should not be an error — null is the correct response for not-found/not-authorized
  });
});
```

**Layer 3: Schema contract tests**

"Contract tests verify that the schema fulfills its contract with clients. They test: (1) that deprecated fields still resolve correctly, (2) that client operations compile against the current schema, and (3) that schema changes don't break known client operation hashes."

```typescript
// tests/contract/client-operations.test.ts
describe('Client operation contract tests', () => {
  it('iOS app GetUserProfile operation is valid against current schema', () => {
    const schema = loadCurrentSchema();
    const operation = parseOperation(IOS_GET_USER_PROFILE_OPERATION);

    const errors = validate(schema, operation);
    expect(errors).toHaveLength(0);
  });

  it('deprecated User.fullName field resolves correctly', async () => {
    // Contract: fullName must continue to work while @deprecated
    const result = await executeOperation(
      '{ user(id: "user-1") { fullName } }',
      {},
      testContext
    );

    expect(result.data.user.fullName).toBeTruthy();
    expect(result.errors).toBeUndefined();
  });
});
```

"Contract tests are the layer that catches breaking changes before they reach production. Running `rover subgraph check` in CI is the automated version of this layer for composition-level contracts."

**Layer 4: End-to-end tests for critical user flows**

"E2E tests execute real operations against a running server (staging or a local stack), testing multi-step flows that cross multiple operations. They catch integration failures that no lower layer catches: the router can't compose the response from two subgraphs, an auth token from operation A is not accepted by operation B, a subscription fires incorrectly after a mutation."

```typescript
// tests/e2e/checkout-flow.test.ts
describe('Checkout flow E2E', () => {
  it('completes a checkout: add to cart → apply coupon → checkout → order visible', async () => {
    const client = new GraphQLClient(STAGING_URL, { headers: authHeaders });

    // Step 1: Add item to cart
    const { addToCart } = await client.request(ADD_TO_CART_MUTATION, {
      productId: 'product-123',
      quantity: 2
    });
    expect(addToCart.__typename).toBe('CartItem');
    const cartId = addToCart.cart.id;

    // Step 2: Apply coupon
    const { applyCoupon } = await client.request(APPLY_COUPON_MUTATION, {
      cartId,
      couponCode: 'SAVE20'
    });
    expect(applyCoupon.__typename).toBe('CartWithCoupon');
    expect(applyCoupon.discount.percentage).toBe(0.2);

    // Step 3: Checkout
    const { checkout } = await client.request(CHECKOUT_MUTATION, {
      cartId,
      paymentMethodId: TEST_PAYMENT_METHOD
    });
    expect(checkout.__typename).toBe('CheckoutSuccess');
    const orderId = checkout.order.id;

    // Step 4: Verify order is visible in order history
    const { me } = await client.request(GET_ORDER_HISTORY_QUERY);
    expect(me.orders.edges.map(e => e.node.id)).toContain(orderId);
  });
});
```

**What each layer catches:**

| Layer | Catches | Does Not Catch |
|---|---|---|
| Unit tests | Business logic errors, edge cases | DB queries, resolver integration, composition |
| Integration tests | DB query errors, resolver-DB integration | Cross-subgraph failures, auth E2E |
| Contract tests | Breaking schema changes, client operation validity | Runtime behavior |
| E2E tests | Cross-subgraph failures, full flow regressions | Performance regressions at scale |

### Common Candidate Mistakes

- Describing only one layer ("just write integration tests") — this misses the value of having fast unit tests for logic and the necessity of contract tests for schema governance.
- Not mentioning schema contract testing — this is the GraphQL-specific layer that prevents breaking changes from reaching clients.
- Not knowing how to execute a GraphQL operation in a test (the `executeOperation` pattern, or using `graphql-request` / `@apollo/client` in tests).
- Not mentioning subscription testing — subscriptions are often untested and break in production.

### Follow-Up Questions

- "How do you test a GraphQL subscription? What does an integration test for a subscription look like?"
- "How do you test authorization logic in a resolver — the rule that a user can only see their own orders?"
- "You're adding a new field to a type. What tests do you write before opening the PR?"

---

## References and Related Topics

- [Chapter 02: GraphQL Internals](../02-graphql-internals/) — resolver execution model for N+1 diagnosis
- [Chapter 14: Observability](../14-observability/README.md) — distributed tracing and metrics referenced throughout
- [Chapter 26: Production Failure Scenarios](../26-production-failure-scenarios/README.md) — full incident post-mortems for questions 1 and 3
- [Chapter 05: Security](../05-security/README.md) — query complexity and attack surface (question 2)
- [Chapter 10: Schema Validation](../10-schema-validation/README.md) — composition checks (question 4)
- [01-schema-design-questions.md](./01-schema-design-questions.md) — schema design foundations
- [02-federation-and-architecture-questions.md](./02-federation-and-architecture-questions.md) — composition and federation mechanics
- [DataLoader GitHub](https://github.com/graphql/dataloader) — canonical DataLoader implementation and documentation
