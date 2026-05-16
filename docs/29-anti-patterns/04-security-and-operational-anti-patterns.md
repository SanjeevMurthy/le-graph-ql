# Security and Operational Anti-Patterns

> Security anti-patterns create attack surface. Operational anti-patterns create 3 AM incidents. Neither shows up in unit tests. This document covers ten common anti-patterns at the intersection of security posture and operational readiness — where GraphQL deployments most often fail under real-world conditions.

---

## Table of Contents

1. [Introspection in Production](#1-introspection-in-production)
2. [No Complexity Limits](#2-no-complexity-limits)
3. [JWT Validation in Each Subgraph](#3-jwt-validation-in-each-subgraph)
4. [Logging Full Query Documents](#4-logging-full-query-documents)
5. [No operationName Requirement](#5-no-operationname-requirement)
6. [Single-Replica Router](#6-single-replica-router)
7. [Skipping Schema Checks](#7-skipping-schema-checks)
8. [Alert Fatigue from Partial Errors](#8-alert-fatigue-from-partial-errors)
9. [Cold Cache on Deploy](#9-cold-cache-on-deploy)
10. [Mutation Without Idempotency](#10-mutation-without-idempotency)

---

## 1. Introspection in Production

**Severity**: High (Security)  
**Layer**: Security

### What It Looks Like

```typescript
// Apollo Server — introspection enabled by default in all environments
const server = new ApolloServer({
  typeDefs,
  resolvers,
  // introspection: true is the default — never explicitly disabled
});
```

Or in Apollo Router:
```yaml
# router.yaml — no introspection configuration
# Default: introspection is enabled
```

### Why It Happens

Introspection is on by default in all major GraphQL implementations. Teams disable it in some environments but forget production. Developer experience tools (GraphQL Playground, Postman) require introspection, creating organizational pressure to leave it on everywhere.

### What Goes Wrong

Full schema introspection exposes:
- Every type name, field name, and argument in the schema
- Deprecated fields and their reasons (internal migration context)
- Internal operation names that hint at business logic
- Type relationships that reveal data model structure

This gives attackers a complete roadmap for constructing malicious queries. Tools like **graphql-cop** and **clairvoyance** automate schema extraction via introspection and field enumeration. A well-designed attack starts with introspection.

```bash
# Attacker's workflow:
$ graphql-cop -t https://api.example.com/graphql
# Output: full schema, authentication bypass hints, field suggestions
```

### The Correct Alternative

Disable introspection in production. Provide schema access through controlled channels:

```typescript
// Apollo Server
const server = new ApolloServer({
  typeDefs,
  resolvers,
  introspection: process.env.NODE_ENV !== 'production',
});
```

```yaml
# Apollo Router — router.yaml
sandbox:
  enabled: false  # disables the built-in sandbox (uses introspection)

supergraph:
  introspection: false
```

For internal developer tools, use **schema registry portals** (Apollo Studio, Hive) that require authentication — not public introspection. For trusted internal clients, provide the schema file directly or via a schema registry API that requires authentication.

---

## 2. No Complexity Limits

**Severity**: Critical (DoS)  
**Layer**: Security

### What It Looks Like

```typescript
// Apollo Server — no complexity plugin installed
const server = new ApolloServer({
  typeDefs,
  resolvers,
  // No query complexity or depth limits
});
```

An attacker sends:
```graphql
query ComplexityBomb {
  users(first: 100) {
    orders(first: 100) {
      items(first: 100) {
        product {
          relatedProducts(first: 100) {
            reviews(first: 100) {
              author {
                orders(first: 100) {
                  # ... 5 more levels
                }
              }
            }
          }
        }
      }
    }
  }
}
```

### Why It Happens

Complexity limits require installing and configuring an additional plugin. Teams defer it as "nice to have." In development with small datasets, deeply nested queries simply return quickly and the problem is invisible.

### What Goes Wrong

The nested query above generates `100^7 = 10^14` potential entity fetches. Even with DataLoaders, the resulting database load is catastrophic. A single malicious query can OOM the router process or exhaust the database connection pool for all other users.

For federated deployments, the query plan itself can become enormous — the router must allocate memory to plan the execution before any data is fetched.

### The Correct Alternative

Install query complexity analysis at the router layer:

```yaml
# Apollo Router — router.yaml
limits:
  max_depth: 10                    # maximum query nesting depth
  max_height: 200                  # maximum number of fields
  max_aliases: 30                  # maximum number of field aliases
  max_root_fields: 20              # maximum root-level fields per operation
  parser_max_tokens: 15000         # maximum tokens in the query document
```

For application-level complexity scoring (Apollo Server):

```typescript
import { createComplexityLimitRule } from 'graphql-query-complexity';

const server = new ApolloServer({
  typeDefs,
  resolvers,
  validationRules: [
    createComplexityLimitRule(1000, {
      scalarCost: 1,
      objectCost: 2,
      listFactor: 10,
      introspectionListFactor: 2,
    }),
  ],
});
```

Set limits based on profiling legitimate queries in production. P99 complexity for legitimate operations is typically under 200. Reject anything over 1,000.

---

## 3. JWT Validation in Each Subgraph

**Severity**: High (Security)  
**Layer**: Authentication Architecture

### What It Looks Like

```typescript
// users-subgraph/context.ts
function createContext({ req }) {
  const token = req.headers.authorization?.replace('Bearer ', '');
  const user = jwt.verify(token, process.env.JWT_SECRET); // each subgraph validates
  return { user };
}

// orders-subgraph/context.ts — same code, copy-pasted
function createContext({ req }) {
  const token = req.headers.authorization?.replace('Bearer ', '');
  const user = jwt.verify(token, process.env.JWT_SECRET); // duplicated
  return { user };
}
```

### Why It Happens

Each subgraph was developed independently. JWT validation is "obvious" — every HTTP service should validate its own auth. The pattern is copied from non-federated GraphQL services.

### What Goes Wrong

- **`JWT_SECRET` distributed to all subgraphs**: instead of one service holding the signing secret, every subgraph has it. Each is an independent attack surface for secret extraction.
- **Inconsistent validation logic**: subgraph A validates `iss` and `aud` claims; subgraph B only validates the signature. A token with a spoofed issuer is rejected by A but accepted by B.
- **Clock skew variations**: JWT expiry validation is time-dependent. Subgraphs on different pods may have different system times, causing identical tokens to be accepted by one subgraph and rejected by another.
- **Revocation is impossible**: if a JWT is compromised, each subgraph must be updated with revocation logic independently.

### The Correct Alternative

Validate JWT **once at the router layer**. Propagate claims to subgraphs as trusted headers:

```yaml
# Apollo Router — router.yaml
authentication:
  router:
    jwt:
      jwks:
        - url: https://auth.example.com/.well-known/jwks.json
          issuer: "https://auth.example.com"
          audiences:
            - "https://api.example.com"

headers:
  all:
    request:
      # Router propagates validated claims as trusted headers
      - propagate:
          named: x-user-id
      - propagate:
          named: x-user-roles
      - propagate:
          named: x-tenant-id
```

Subgraphs read pre-validated claims from headers — no JWT validation logic, no secret distribution:

```typescript
// users-subgraph/context.ts
function createContext({ req }) {
  // Trust headers set by the router — never trust raw Authorization header in subgraphs
  return {
    userId: req.headers['x-user-id'],
    roles: req.headers['x-user-roles']?.split(',') ?? [],
    tenantId: req.headers['x-tenant-id'],
  };
}
```

Subgraphs should **reject direct requests** that do not come from the router (use mTLS or a shared router secret header to validate request origin).

---

## 4. Logging Full Query Documents

**Severity**: High (Compliance)  
**Layer**: Observability

### What It Looks Like

```typescript
// Apollo Server plugin — logs the full query document
const loggingPlugin = {
  requestDidStart({ request }) {
    logger.info({
      query: request.query,          // FULL QUERY TEXT
      variables: request.variables,  // FULL VARIABLES (may contain passwords)
      operationName: request.operationName,
    });
  },
};
```

What gets logged:
```json
{
  "query": "query GetUser { user(id: \"u-123\") { email ssn dateOfBirth creditScore } }",
  "variables": { "password": "hunter2", "creditCard": "4111111111111111" }
}
```

### Why It Happens

Logging the full query is the easiest way to debug production issues. Engineers add it during incident response and it stays. The PII risk is not immediately obvious because the query is "just a string."

### What Goes Wrong

- **PII in logs**: field names like `ssn`, `dateOfBirth`, `creditScore` appear in log lines. Logs are often stored in systems (CloudWatch, Datadog, Splunk) with broader access than production databases.
- **Secrets in variables**: `login(email:, password:)` mutations log the password in `variables`.
- **GDPR/HIPAA compliance failure**: logs containing PII must be protected, retained for limited periods, and subject to right-to-erasure requests. Most logging infrastructure is not designed for this.
- **Audit trails expose sensitive access patterns**: `user(id: "u-123") { ssn }` in a log file reveals that a specific user's SSN was accessed at a specific time — a breach even without the value.

### The Correct Alternative

Log **operation metadata**, not the query document:

```typescript
const loggingPlugin = {
  requestDidStart({ request }) {
    // Log metadata, never the full document
    const operationId = hashQuery(request.query); // stable hash for correlation

    logger.info({
      operationName: request.operationName,      // "GetUser" — safe
      operationId,                                // "sha256:abc123" — for debugging
      // DO NOT log: request.query, request.variables
    });

    return {
      willSendResponse({ response }) {
        logger.info({
          operationName: request.operationName,
          hasErrors: (response.errors?.length ?? 0) > 0,
          errorCount: response.errors?.length ?? 0,
          // DO NOT log: error messages that may contain field values
        });
      },
    };
  },
};
```

For debugging, use **persisted queries** — store the operation text in a registry keyed by hash. Log the hash. Developers look up the operation by hash in the registry. The full operation text never appears in logs.

---

## 5. No operationName Requirement

**Severity**: Medium  
**Layer**: Observability / Security

### What It Looks Like

```graphql
# Anonymous operation — no operationName
query {
  user(id: "u-123") {
    email
    orders(first: 10) { id total }
  }
}
```

### Why It Happens

`operationName` is optional in the GraphQL spec. Development tools (GraphQL Playground, curl) do not require it. Operations written for quick testing are anonymous and get deployed as-is.

### What Goes Wrong

- **Metrics are useless**: Prometheus metric `graphql_operation_duration_seconds` has labels `{operation_name="__anonymous__"}` for 40% of operations. You cannot debug a latency spike for an anonymous operation.
- **Tracing is meaningless**: Jaeger traces labeled `anonymous` cannot be linked to product features.
- **Log correlation fails**: you cannot correlate error logs with the operation that caused them.
- **Persisted queries are impossible**: operation allowlists (trusted documents) require an operation name to register the operation. Anonymous operations cannot be persisted.
- **Security audit is incomplete**: "which client is querying sensitive fields?" cannot be answered without operation names.

### The Correct Alternative

Require `operationName` at the router layer:

```yaml
# Apollo Router — router.yaml
# Custom Rhai script to reject anonymous operations
traffic_shaping:
  all:
    experimental_retry:
      min_per_sec: 10
```

```rhai
// router_operation_check.rhai
fn supergraph_service(service) {
  let request_callback = |request| {
    if request.context["operation_name"] == () {
      return http::Response {
        status: 400,
        body: "operationName is required for all GraphQL operations",
      };
    }
  };
  service.map_request(request_callback);
}
```

Enforce in client SDKs and codegen configuration — generated hooks always include the operation name. Fail CI if any `.graphql` file contains an unnamed operation.

---

## 6. Single-Replica Router

**Severity**: Critical (Reliability)  
**Layer**: Reliability

### What It Looks Like

```yaml
# k8s/router-deployment.yaml — anti-pattern
apiVersion: apps/v1
kind: Deployment
metadata:
  name: apollo-router
spec:
  replicas: 1            # single point of failure
  # No HPA
  # No PodDisruptionBudget
  template:
    spec:
      containers:
        - name: router
          image: ghcr.io/apollographql/router:v1.45.0
          resources:
            requests:
              memory: "512Mi"
              cpu: "500m"
            # No limits defined
```

### Why It Happens

The router was deployed during a proof-of-concept with `replicas: 1`. It worked. Nobody updated it as traffic grew. "We'll add replicas when we need them" — but the need is discovered during the first production incident.

### What Goes Wrong

- **Pod restart = total outage**: a router crash, OOM kill, or node eviction causes 100% of GraphQL traffic to fail until the pod restarts (typically 30–60 seconds).
- **Zero-downtime deployments fail**: a rollout of `replicas: 1` causes a brief downtime window as the old pod terminates before the new one is ready.
- **No HPA = traffic spikes cause OOM**: without resource limits and HPA, a traffic spike can OOM the router pod, causing a restart loop during peak load.

### The Correct Alternative

```yaml
# k8s/router-deployment.yaml — production-ready
apiVersion: apps/v1
kind: Deployment
metadata:
  name: apollo-router
spec:
  replicas: 3                   # minimum 3 replicas across nodes
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0         # zero-downtime rollout
      maxSurge: 1
  template:
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: apollo-router
      containers:
        - name: router
          resources:
            requests:
              memory: "512Mi"
              cpu: "500m"
            limits:
              memory: "1Gi"
              cpu: "2000m"
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: apollo-router-pdb
spec:
  minAvailable: 2               # maintain at least 2 healthy pods during disruptions
  selector:
    matchLabels:
      app: apollo-router
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: apollo-router-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: apollo-router
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

---

## 7. Skipping Schema Checks

**Severity**: Critical (Breaking Changes)  
**Layer**: CI/CD

### What It Looks Like

```bash
# CI pipeline under deadline pressure
rover subgraph publish my-graph@production \
  --name users \
  --schema ./schema.graphql \
  --routing-url https://users.internal/graphql \
  --skip-update-check   # "just this once to unblock the release"

# Or bypassing checks entirely:
# (Comment out the schema check job in GitHub Actions workflow)
```

### Why It Happens

A deadline. A breaking change was made accidentally. The schema check fails and blocks the deploy. The engineer does not have time to investigate. The flag is used "just once" — and it accumulates. After enough incidents, `--skip-checks` (or commented-out schema check jobs) becomes the default for "urgent" releases.

### What Goes Wrong

Each skipped check accumulates a silent breaking change in the supergraph. Client operations that worked before the schema change now fail — but the failure happens at query time, not at deploy time.

Common post-skip failures:
- Field renamed without `@deprecated`: client queries for old field name return null
- Argument made required: existing operations missing the argument fail with a schema error
- Type changed: codegen-generated types no longer match the schema

These failures are discovered at runtime by end users, not in CI.

### The Correct Alternative

Never skip schema checks. Instead, use the tooling to **understand and manage** breaking changes:

```bash
# Identify what is breaking and why
rover subgraph check my-graph@production \
  --name users \
  --schema ./schema.graphql

# Output:
# ✕ BREAKING: Field `User.name` was removed
#   Affected operations: 14
#   Earliest operation: GetUserProfile (last seen 2 hours ago)
```

If a breaking change is intentional:
1. Mark the old field `@deprecated` with a removal date.
2. Wait for client usage to drop to zero (monitored via GraphOS field usage analytics).
3. Then remove the field.

If breaking the change is unavoidable (security incident, data compliance), use a **schema override** with explicit acknowledgment:

```bash
rover subgraph publish my-graph@production \
  --name users \
  --schema ./schema.graphql \
  --allow-invalid-routing-url  # only valid flag for routing issues, not for schema checks
# Schema check failures must not be bypassed — fix the schema instead
```

---

## 8. Alert Fatigue from Partial Errors

**Severity**: Medium  
**Layer**: Observability

### What It Looks Like

```yaml
# Prometheus alerting rule — anti-pattern
- alert: GraphQLErrors
  expr: rate(graphql_errors_total[5m]) > 0
  for: 1m
  labels:
    severity: page
  annotations:
    summary: "GraphQL errors detected"
```

This alert fires on **every** GraphQL error — including expected partial errors like:
- `User.phoneNumber` is null for users who didn't provide one (schema is non-null but resolver returns null)
- `Product.reviewSummary` is null for new products with no reviews
- `WeatherWidget.forecast` is null when the external API is rate-limited

### Why It Happens

"Alert on all errors" is a natural first instinct for monitoring. In REST, an error means a 4xx or 5xx HTTP status — always unexpected. Teams carry this mental model to GraphQL without accounting for the partial error model.

### What Goes Wrong

The on-call engineer is paged 50 times per day for expected partial errors. After a few weeks, engineers start ignoring the alerts. The alert for a real, critical error — `PaymentProcessor.charge` is failing for all users — is lost in the noise.

**Alert fatigue is a patient safety issue at scale**: the team is conditioned to dismiss alerts before reading them.

### The Correct Alternative

Distinguish between **expected partial errors** and **unexpected critical errors**:

```yaml
# Alert only on critical resolver failures — operations returning null for non-nullable fields
# due to infrastructure failures, not business logic

- alert: GraphQLCriticalErrors
  expr: |
    rate(graphql_errors_total{error_type="INTERNAL"}[5m]) > 0.01
  for: 2m
  labels:
    severity: page
  annotations:
    summary: "GraphQL internal errors — resolver infrastructure failure"

# Low-severity alert for elevated partial error rates
- alert: GraphQLPartialErrors
  expr: |
    rate(graphql_errors_total{error_type="PARTIAL"}[5m]) > 0.05
  for: 10m
  labels:
    severity: warning    # notify, don't page
  annotations:
    summary: "Elevated partial error rate — investigate resolver degradation"
```

Classify errors in the server:
```typescript
const resolvers = {
  Query: {
    forecast: async (_, { location }, context) => {
      try {
        return await weatherApi.getForecast(location);
      } catch (e) {
        context.metrics.increment('graphql_errors_total', { error_type: 'PARTIAL' });
        return null; // expected degradation — not an infrastructure failure
      }
    },
  },
};
```

---

## 9. Cold Cache on Deploy

**Severity**: Medium  
**Layer**: Reliability

### What It Looks Like

```
Deploy timeline:
14:00 — New router version deployed (replaces all 6 pods simultaneously or via rolling update)
14:01 — Cache miss rate: 98% (all 6 pods have empty caches)
14:01–14:05 — Every query hits the database/subgraphs at full rate
14:05 — Database CPU spikes to 95%
14:06 — P99 latency: 4200ms (normal: 120ms)
14:08 — Cache warm — P99 latency returns to 120ms
```

### Why It Happens

Caching is designed for steady-state operation. The deploy scenario — all cache cleared simultaneously — is a low-frequency event that is not considered in the cache design. In-process caching (Apollo's default response caching) is always cold after a pod restart.

### What Goes Wrong

The 4–8 minute window of cold cache after every deploy causes a noticeable latency spike for users. For deployments that happen multiple times per day (CD pipelines), this is a recurring quality-of-service degradation. For deployments during peak hours, it can cause partial outages.

### The Correct Alternative

**Strategy 1: Shared external cache** (survives pod restarts)
```yaml
# Apollo Router — router.yaml
supergraph:
  cache:
    in_memory:
      limit: 512
    redis:
      urls:
        - redis://redis-cluster.graphql-platform.svc.cluster.local:6379
      # Redis cache survives pod restarts — no cold start
      ttl: 300s
```

**Strategy 2: Cache warm-up job before traffic shift**
```yaml
# k8s/cache-warmup-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: router-cache-warmup
spec:
  template:
    spec:
      containers:
        - name: warmup
          image: your-cache-warmup-image
          command:
            - /bin/sh
            - -c
            - |
              # Execute the top-50 most frequent operations against the new deployment
              # before shifting traffic to it
              for op in $(cat /warmup/top-operations.json | jq -r '.[]'); do
                curl -s -X POST http://router-canary/graphql \
                  -H "Content-Type: application/json" \
                  -d "$op" > /dev/null
              done
```

**Strategy 3: Blue-green deployment with DNS cut-over** — warm the green environment fully before switching DNS, instead of rolling updates that clear individual pod caches one at a time.

---

## 10. Mutation Without Idempotency

**Severity**: High  
**Layer**: Reliability

### What It Looks Like

```graphql
type Mutation {
  chargePaymentMethod(
    paymentMethodId: ID!,
    amount: Float!,
    currency: String!
  ): ChargeResult!
  # No idempotency key — retry causes double charge
}
```

Client behavior:
```typescript
// Client times out at 5s but server processed the charge at 4.9s
const result = await apolloClient.mutate({
  mutation: CHARGE_MUTATION,
  variables: { paymentMethodId, amount: 99.99, currency: 'USD' },
  // On timeout → retry
});
// Retry: second charge of $99.99 is processed
// Customer is charged twice
```

### Why It Happens

Queries are naturally idempotent — reading data twice is fine. Mutations are designed thinking about the happy path. Network timeouts and retries are handled at the infrastructure layer (load balancer timeouts, client retry logic) without considering that the mutation may have already succeeded.

### What Goes Wrong

For financial, inventory, and email mutations:
- **Double charges**: payment mutation retried → customer charged twice
- **Double fulfillment**: order fulfillment mutation retried → two shipments sent
- **Duplicate emails**: welcome email mutation retried → two welcome emails sent

This is particularly dangerous in GraphQL subscriptions (reconnect-on-disconnect causes operation re-execution) and in mobile clients with aggressive retry policies over unreliable networks.

### The Correct Alternative

Add an **idempotency key** to all mutations with side effects:

```graphql
type Mutation {
  chargePaymentMethod(
    input: ChargePaymentMethodInput!
    """
    Client-generated UUID for idempotency. The server will return the same result
    for requests with the same idempotencyKey within 24 hours, without
    re-processing the charge. Generate once per user action; do not regenerate on retry.
    """
    idempotencyKey: String!
  ): ChargeResult!
}
```

Server implementation:
```typescript
const resolvers = {
  Mutation: {
    chargePaymentMethod: async (_parent, { input, idempotencyKey }, context) => {
      // Check for existing result
      const cached = await context.idempotencyStore.get(idempotencyKey);
      if (cached) return cached; // return cached result, no re-processing

      // Process the charge
      const result = await context.services.payment.charge(input);

      // Store result for 24 hours
      await context.idempotencyStore.set(idempotencyKey, result, { ttl: 86400 });
      return result;
    },
  },
};
```

The client generates the idempotency key once (UUID v4) before attempting the mutation and reuses it on retries:

```typescript
const idempotencyKey = crypto.randomUUID(); // generated once per user action
const result = await apolloClient.mutate({
  mutation: CHARGE_MUTATION,
  variables: { input: { paymentMethodId, amount }, idempotencyKey },
  // Safe to retry with the same idempotencyKey
});
```

---

## Summary

| Anti-Pattern | Severity | Root Cause | Mitigation |
|---|---|---|---|
| Introspection in Production | High | Default-on behavior | Explicit opt-out per environment |
| No Complexity Limits | Critical | Deferred "nice to have" | Router-level depth + complexity rules |
| JWT in Each Subgraph | High | Independent service habits | Validate once at router, propagate claims |
| Logging Full Queries | High | Debug convenience | Log operation metadata, not documents |
| No operationName | Medium | Optional spec field | Router enforcement + codegen convention |
| Single-Replica Router | Critical | POC configuration | 3 replicas + HPA + PDB |
| Skipping Schema Checks | Critical | Deadline pressure | No bypass flag; deprecation process |
| Alert Fatigue | Medium | REST alert mental model | Separate partial vs. critical error alerts |
| Cold Cache on Deploy | Medium | Happy-path caching design | External Redis cache or warm-up job |
| Mutation Without Idempotency | High | Happy-path mutation design | Idempotency key on all side-effect mutations |

---

## References

- [Apollo Router Security Configuration](https://www.apollographql.com/docs/router/configuration/overview)
- [OWASP GraphQL Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/GraphQL_Cheat_Sheet.html)
- [Apollo Router — Response Caching](https://www.apollographql.com/docs/router/performance/caching)
- [Stripe — Idempotency Keys](https://stripe.com/docs/api/idempotent_requests)
- [graphql-cop — Security Auditing Tool](https://github.com/nicholasess/graphql-cop)

## Related Topics

- [Security](../05-security/README.md)
- [Observability](../14-observability/README.md)
- [Kubernetes Deployment](../15-kubernetes-deployment/README.md)
- [Caching Strategies](../17-caching-strategies/README.md)
- [Production Failure Scenarios](../26-production-failure-scenarios/README.md)
