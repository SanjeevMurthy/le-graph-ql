# Security and Operations Best Practices

> **Purpose:** Twenty-plus security and operational rules for production GraphQL deployments. These rules address the attack surface unique to GraphQL (introspection, complexity abuse, batching) and the operational practices required to run a GraphQL API at enterprise scale (SLOs, chaos engineering, secret rotation). Each rule includes the failure mode it prevents and concrete implementation guidance.

---

## BP-SO-01: Require `operationName` on All Production Clients — Reject Anonymous Operations at the Router

**Rule:** The Apollo Router must be configured to reject any GraphQL request that does not include an `operationName` in the request body. All production client applications must send named operations.

**Rationale:** Anonymous operations cannot be traced by name in distributed tracing systems, cannot be rate-limited by operation, cannot be audited in access logs, and cannot be targeted by persisted query policies. Requiring named operations is a prerequisite for every other operational and security practice in this list. An anonymous operation in production is a gap in observability.

**Router configuration:**

```yaml
# router.yaml
preview_operation_limits:
  max_depth: 15
  max_height: 200
  max_aliases: 30
  max_root_fields: 20

# Reject unnamed operations via a Rhai plugin
plugins:
  experimental.rhai:
    scripts: ./rhai
    main: enforce_operation_name.rhai
```

```rust
// rhai/enforce_operation_name.rhai
fn supergraph_service(service) {
    let request_callback = |request| {
        let body = request.body;
        let operation_name = body["operationName"];

        if operation_name == () || operation_name == "" || operation_name == null {
            return {
                "control": "break",
                "response": {
                    "status": 400,
                    "body": {
                        "errors": [{
                            "message": "operationName is required for all production requests",
                            "extensions": {
                                "code": "OPERATION_NAME_REQUIRED"
                            }
                        }]
                    }
                }
            };
        }
        request
    };

    service.map_request(request_callback);
}
```

**Monitoring:** Alert when the rejection rate for unnamed operations exceeds 0.1%. This indicates a client is not following the contract and may be sending ad-hoc queries in production.

---

## BP-SO-02: Enable Persisted Queries in Allowlist Mode for Internal and Partner APIs

**Rule:** In production, the router must be configured to accept only pre-registered persisted query documents. Arbitrary GraphQL document strings are rejected. This is "trusted documents" mode (Apollo Router terminology) or "persisted query allowlist" mode.

**Rationale:** Allowlist mode eliminates the arbitrary query attack surface. An attacker cannot craft a complexity bomb, a field enumeration query, or a data exfiltration query because the server only executes pre-approved documents. This also enables significant performance optimization: pre-registered queries can be parsed and validated at registration time, not at request time.

**Router configuration (Apollo Persisted Queries):**

```yaml
# router.yaml
persisted_queries:
  enabled: true
  safelist:
    enabled: true
    require_id: true  # Reject any request that sends a query document; only IDs accepted
    log_unknown: true # Log unknown operation IDs for investigation
```

**Client request format (allowlist mode):**

```json
{
  "extensions": {
    "persistedQuery": {
      "version": 1,
      "sha256Hash": "ecf4edb46db40b5132295c0291d62fb65d6759a9eedfa4d5d612dd5ec54a6b38"
    }
  },
  "operationName": "GetOrderDetails",
  "variables": { "orderId": "order-123" }
}
```

**Registration in CI:**

```bash
# Register the operation manifest after each build
rover persisted-queries publish my-graph@production \
  --manifest ./generated/persisted-query-manifest.json
```

---

## BP-SO-03: Set Query Complexity and Depth Limits Tuned to Your SLA

**Rule:** The router must enforce query complexity limits (a numeric score based on field weights) and depth limits (maximum nesting depth). These limits must be measured against your actual query corpus before deployment — not set to arbitrary defaults.

**Rationale:** An unconstrained GraphQL query can be crafted to request exponentially more data than a typical query. A depth-10 query requesting a list of users, each with a list of orders, each with a list of line items, each with a product, can return millions of rows. Complexity and depth limits prevent this at the query analysis layer, before any resolver executes.

**Measuring limits from your actual query corpus:**

```bash
# 1. Export your operation signatures from Apollo Studio
rover graph fetch my-graph@production --format operations > operations.json

# 2. Calculate complexity distribution
jq '[.[] | .complexity] | sort | {
  p50: .[length * 0.50 | floor],
  p95: .[length * 0.95 | floor],
  p99: .[length * 0.99 | floor],
  max: .[-1]
}' operations.json

# Set complexity limit at 2x p99, depth limit at p99 + 2
```

**Router configuration:**

```yaml
# router.yaml
preview_operation_limits:
  # Reject queries with complexity score > 1500
  max_complexity: 1500
  # Reject queries nested more than 12 levels deep
  max_depth: 12
  # Reject queries with more than 50 distinct field selections
  max_height: 50
  # Reject queries with more than 15 aliases
  max_aliases: 15
  # Reject queries with more than 5 root fields
  max_root_fields: 5
```

---

## BP-SO-04: Never Log Raw Query Documents or Variable Values — Log Document Hash

**Rule:** Production logging must never include the raw GraphQL query document string or variable values. Log the operation name, the SHA-256 hash of the document, the trace ID, and the error code. Variable values often contain PII (email addresses, phone numbers, credit card tokens).

**Rationale:** Logging raw query documents exposes the full schema surface to anyone with log access. Logging variable values creates a PII data store in your logging infrastructure, creating GDPR/CCPA compliance exposure and a data breach risk. The document hash provides the ability to correlate logs to a specific operation without exposing the query.

**Counter-example:**

```json
// BAD: Raw query and variables in the log
{
  "level": "info",
  "message": "GraphQL request",
  "query": "query GetUser($email: Email!) { user(email: $email) { id name creditCardLast4 } }",
  "variables": { "email": "user@example.com" }
}
```

**Correct:**

```json
{
  "level": "info",
  "message": "GraphQL request",
  "operationName": "GetUser",
  "documentHash": "sha256:4bf92f3577b34da6a3ce929d0e0e4736a2f4da3aaecbe7f3b49f5e8b4aa6c7d1",
  "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
  "clientId": "web-app-v4.2.1",
  "durationMs": 145,
  "statusCode": 200
}
```

**Router configuration:**

```yaml
# router.yaml — sanitize logs at the router level
telemetry:
  exporters:
    tracing:
      common:
        attributes:
          # Include document hash, not document body
          document_hash: true
          document: false
          variables: false  # NEVER log variables in production
```

---

## BP-SO-05: Use Field-Level Authorization (OPA) — Not Just Operation-Level JWT Claims

**Rule:** Authorization must be enforced at the field level using a policy engine (OPA, Cerbos, or custom resolver-level checks). JWT claim validation at the router entry point proves identity. It does not prove authorization to access a specific field on a specific entity.

**Rationale:** JWT-only authorization means: any authenticated user can query any field. A support agent authenticated with a valid JWT should not be able to query the `paymentDetails` field on a customer's order. Field-level authorization policies enforce the principle of least privilege at the GraphQL layer. See [Security Chapter 04: OPA and Policy](../05-security/04-opa-and-policy.md) for full OPA integration patterns.

**OPA policy for field-level authorization:**

```rego
# policies/graphql/field_auth.rego
package graphql.field_auth

default allow = false

# Allow users to read their own User fields
allow {
    input.field_name == "User"
    input.object_id == input.user.id
}

# Allow FINANCE_ADMIN to read paymentDetails on any order
allow {
    input.field_name == "paymentDetails"
    input.user.roles[_] == "FINANCE_ADMIN"
}

# Allow order owners to read their own paymentDetails
allow {
    input.field_name == "paymentDetails"
    input.object.customer_id == input.user.id
}

# Allow HR_ADMIN to read compensation on any user
allow {
    input.field_name == "compensation"
    input.user.roles[_] == "HR_ADMIN"
}
```

```typescript
// Resolver-level OPA integration
async function checkFieldAccess(
  field: string,
  objectId: string,
  context: GraphQLContext
): Promise<boolean> {
  const result = await opaClient.evaluate('graphql/field_auth', {
    field_name: field,
    object_id: objectId,
    user: context.user,
  });
  return result.allow === true;
}
```

---

## BP-SO-06: Rate Limit by `client_id` + `operationName` — Not Just IP Address

**Rule:** Rate limiting must be applied per client application identifier and operation name combination, not just per IP address. A client that sends 1,000 `SearchProducts` operations per minute should be throttled independently from a client sending 1,000 `GetOrderDetails` operations.

**Rationale:** IP-based rate limiting is trivially bypassed by distributing requests across IP addresses or by using cloud egress IPs that change. More importantly, IP-based limits cannot distinguish between a legitimate client fetching many records and a bot enumerating the schema. Client ID + operation name rate limits enforce quotas per use case.

**Router rate limiting configuration:**

```yaml
# router.yaml
traffic_shaping:
  router:
    global_rate_limit:
      capacity: 10000  # Requests per second across all clients
      interval: 1s

plugins:
  experimental.rhai:
    scripts: ./rhai
    main: rate_limit.rhai
```

```rust
// rhai/rate_limit.rhai — per client_id + operationName rate limiting
fn supergraph_service(service) {
    let request_callback = |request| {
        let client_id = request.headers["x-client-id"] ?? "unknown";
        let operation = request.body["operationName"] ?? "anonymous";
        let rate_limit_key = `${client_id}:${operation}`;

        // Check Redis rate limit counter
        // (Actual Redis call handled by a custom native plugin)
        request.context["rate_limit_key"] = rate_limit_key;
        request
    };
    service.map_request(request_callback);
}
```

**Rate limit tiers by client type:**

```yaml
# Custom rate limit configuration (enforced via coprocessor)
rate_limits:
  mobile_app:
    SearchProducts: 60/min
    GetOrderDetails: 120/min
    Mutation: 30/min
  web_app:
    SearchProducts: 120/min
    GetOrderDetails: 300/min
    Mutation: 60/min
  partner_api:
    "*": 1000/min  # Partners get a bulk allowance
  internal_tooling:
    "*": unlimited
```

---

## BP-SO-07: Deploy Router With HPA and PDB — No Single Points of Failure

**Rule:** The Apollo Router must be deployed with a Kubernetes HorizontalPodAutoscaler (HPA) targeting 60–70% CPU utilization, a minimum of 3 replicas across 3 availability zones, and a PodDisruptionBudget (PDB) that ensures at least 2 replicas remain available during voluntary disruptions.

**Rationale:** The Apollo Router is the single entry point for all GraphQL traffic. A single router pod is a single point of failure. A router deployment without HPA cannot scale under load spikes. Without a PDB, a `kubectl drain` during node maintenance can remove all router pods simultaneously, causing a complete API outage.

**Kubernetes manifests:**

```yaml
# hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: apollo-router
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
          averageUtilization: 65
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 70
```

```yaml
# pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: apollo-router-pdb
spec:
  selector:
    matchLabels:
      app: apollo-router
  minAvailable: 2  # Never fewer than 2 router pods during disruptions
```

```yaml
# deployment.yaml (topology spread constraints)
spec:
  template:
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: apollo-router
```

---

## BP-SO-08: Define SLOs Before Deploying to Production

**Rule:** Before the first production deployment, define Service Level Objectives (SLOs) for the GraphQL API: availability (%), error rate (%), and latency (p50, p95, p99). Burn rate alerts must be configured before launch, not after the first incident.

**Rationale:** Without defined SLOs, incidents cannot be declared (what does "the API is degraded" mean without a threshold?), error budgets cannot be tracked, and teams cannot make data-driven decisions about reliability investments vs. feature work. SLOs are a prerequisite for a mature operations practice.

**SLO definition:**

```yaml
# slos/graphql-api.yml
slos:
  graphql_api_availability:
    description: "GraphQL API availability — proportion of requests returning non-5xx"
    target: 99.9%  # 43.8 minutes downtime budget per month
    window: 30d
    indicator:
      metric: 'rate(apollo_router_requests_total{status!~"5.."}[5m]) / rate(apollo_router_requests_total[5m])'

  graphql_api_latency_p99:
    description: "99th percentile response time < 1 second"
    target: 99%  # 99% of requests under 1s
    window: 30d
    indicator:
      metric: 'histogram_quantile(0.99, rate(apollo_router_request_duration_seconds_bucket[5m])) < 1.0'

  graphql_mutation_error_rate:
    description: "Mutation error rate < 0.5%"
    target: 99.5%  # Less than 0.5% of mutations return errors
    window: 7d
    indicator:
      metric: 'rate(apollo_router_requests_total{operation_type="mutation",status=~"4.."}[5m]) / rate(apollo_router_requests_total{operation_type="mutation"}[5m]) < 0.005'
```

**Burn rate alerts:**

```yaml
# prometheus/alerts/slo-burn.yml
groups:
  - name: slo-burn-rate
    rules:
      - alert: GraphQLAPIErrorBudgetBurnRateHigh
        expr: |
          (
            rate(apollo_router_requests_total{status=~"5.."}[1h]) /
            rate(apollo_router_requests_total[1h])
          ) > 14.4 * 0.001  # 14.4x burn rate = 1 hour window depletes monthly budget
        for: 2m
        labels:
          severity: critical
          slo: graphql_api_availability
        annotations:
          summary: "High error budget burn rate: GraphQL API"
          description: "Current burn rate will exhaust the monthly error budget in < 2 hours"
```

---

## BP-SO-09: Run Chaos Experiments Against Subgraph Failures to Verify Partial Data Behavior

**Rule:** Before production launch and quarterly thereafter, run controlled chaos experiments that simulate subgraph failures (timeout, error response, HTTP 503) and verify that the router returns correct partial data with structured errors — not a complete API failure.

**Rationale:** Partial data behavior (the router returns data from healthy subgraphs and errors for fields owned by the failed subgraph) is a core federation feature. But it requires that fields are nullable, that error handling is correct in resolvers, and that the router is configured to continue after subgraph failures. These behaviors only appear correct under failure conditions. Chaos experiments verify them before an incident does.

**Chaos experiment using Chaos Mesh:**

```yaml
# chaos/subgraph-timeout.yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: recommendations-subgraph-timeout
  namespace: graphql-staging
spec:
  action: delay
  mode: all
  selector:
    namespaces:
      - graphql-staging
    labelSelectors:
      app: recommendations-subgraph
  delay:
    latency: "10s"     # 10 second delay — exceeds the 500ms router timeout
    correlation: "100"
  duration: "5m"
```

**Verification checklist for each experiment:**

```
□ Router returns HTTP 200 (not 503) when a non-critical subgraph times out
□ Response body contains data from healthy subgraphs
□ Response errors array contains a structured error for the failed subgraph
□ Error message does not expose internal details (subgraph URL, internal errors)
□ Alerts fire within 2 minutes of the failure starting
□ Router timeout metric increments (not a silent drop)
□ P99 latency stays within SLO during the partial failure (fast timeout, not slow)
```

---

## BP-SO-10: Disable Introspection in Production — Enable Only for Internal Tooling With Auth

**Rule:** Introspection must be disabled in production for all external clients. Enable introspection only for authenticated internal requests (Apollo Studio, developer portals) using a separate authenticated endpoint or an introspection allow-header policy.

**Rationale:** Introspection returns the complete schema — every type, field, argument, and deprecation message. This is a reconnaissance gift for attackers: they can map the entire API surface, identify deprecated fields that may have weaker security posture, and target specific fields for injection or enumeration. Disabling introspection eliminates this attack vector.

**Router configuration:**

```yaml
# router.yaml
sandbox:
  enabled: false  # Disable the Apollo Sandbox (introspection UI) in production

plugins:
  experimental.rhai:
    scripts: ./rhai
    main: introspection_guard.rhai
```

```rust
// rhai/introspection_guard.rhai
fn supergraph_service(service) {
    let request_callback = |request| {
        let body = request.body;
        let query = body["query"] ?? "";

        // Detect introspection queries
        if query.contains("__schema") || query.contains("__type") {
            let api_key = request.headers["x-internal-api-key"] ?? "";
            let valid_key = env::get("INTERNAL_INTROSPECTION_KEY");

            if api_key != valid_key {
                return {
                    "control": "break",
                    "response": {
                        "status": 403,
                        "body": {
                            "errors": [{
                                "message": "Introspection disabled in production",
                                "extensions": { "code": "INTROSPECTION_DISABLED" }
                            }]
                        }
                    }
                };
            }
        }
        request
    };
    service.map_request(request_callback);
}
```

---

## BP-SO-11: Use HTTPS/mTLS Between Router and Subgraphs — Never Plain HTTP

**Rule:** All communication between the Apollo Router and subgraphs must use mTLS (mutual TLS). Client-facing communication must use TLS 1.3 minimum. Plain HTTP is never acceptable in production, even in "internal" network segments.

**Rationale:** "Internal" network segments are not isolated. Lateral movement attacks that compromise one pod in a Kubernetes cluster can intercept traffic on other pods unless communication is encrypted and mutually authenticated. mTLS ensures that only legitimate subgraph services (those with a valid certificate signed by the internal CA) can receive router traffic, and the router can verify it is talking to the real subgraph.

**Istio mTLS configuration (used with service mesh):**

```yaml
# istio/peer-authentication.yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: graphql-mtls-strict
  namespace: graphql-production
spec:
  mtls:
    mode: STRICT  # Reject all non-mTLS traffic within the namespace
```

**Router TLS configuration (without service mesh):**

```yaml
# router.yaml
tls:
  supergraph:
    certificate: /etc/certs/router-cert.pem
    certificate_key: /etc/certs/router-key.pem
    client_authentication:
      # Require client certificates on the subgraph-facing connections
      required: true
      certificate_authorities: /etc/certs/internal-ca.pem
```

---

## BP-SO-12: Rotate Secrets and API Keys on a Schedule — Maximum 90-Day Rotation

**Rule:** All secrets used by the GraphQL system (Apollo GraphOS API keys, JWT signing keys, subgraph authentication tokens, database passwords, OPA policy server tokens) must be rotated on a maximum 90-day schedule. Rotation must be automated. Manual rotation is not acceptable at scale.

**Rationale:** Secrets that never rotate accumulate risk. A leaked API key that is never rotated remains valid indefinitely. 90 days is the maximum acceptable rotation period for high-privilege secrets. For JWT signing keys, shorter rotation (7–30 days) limits the validity window of any compromised tokens.

**Vault secret rotation with Kubernetes integration:**

```hcl
# vault/policies/graphql-secrets.hcl
path "secret/data/graphql/+/+" {
  capabilities = ["read"]
}

path "graphql/creds/router" {
  capabilities = ["read"]
}
```

```yaml
# vault-secret-rotation.yaml — External Secrets Operator
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: apollo-router-secrets
spec:
  refreshInterval: 1h  # Check for rotation every hour
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: apollo-router-secrets
    creationPolicy: Owner
    template:
      engineVersion: v2
  data:
    - secretKey: APOLLO_KEY
      remoteRef:
        key: secret/graphql/router/apollo-key
        property: value
    - secretKey: JWT_SIGNING_KEY
      remoteRef:
        key: secret/graphql/router/jwt-key
        property: value
```

---

## BP-SO-13: Maintain a Schema Breaking Change Policy With Enforcement

**Rule:** Define and enforce a formal schema breaking change policy: breaking changes require a minimum deprecation period (30 days for internal, 90 days for external), usage tracking confirmation that no clients are using the deprecated field, and explicit approval from the platform team before removal.

**Rationale:** Without a formal policy, breaking changes are made ad-hoc. Client teams discover the breakage in production, not in advance. A written policy with tooling enforcement (rover schema check failing on unapproved breaking changes) makes the contract explicit and enforceable.

**Policy document (excerpt):**

```markdown
# GraphQL Schema Breaking Change Policy

## Definition of Breaking Change
A breaking change is any schema modification that may prevent existing clients
from successfully executing their current queries without modification:
- Removing a type, field, argument, or enum value
- Changing a field type to an incompatible type (String → Int)
- Making a nullable field non-null
- Adding a required argument to an existing field
- Changing @key fields on a federated entity

## Deprecation Requirements
| Client Type | Minimum Deprecation Period | Usage Verification Required |
|---|---|---|
| Internal clients | 30 days | Yes — zero usage in production for 7+ days |
| External partners | 90 days | Yes — direct confirmation from partner teams |
| Public API | 180 days | Yes — public announcement + deprecation notice |

## Enforcement
rover schema check will fail on any breaking change not listed in the
approved-changes allowlist in schema-governance/approved-removals.yaml.
```

---

## BP-SO-14: Implement Circuit Breakers on Subgraph Connections

**Rule:** The router must be configured with circuit breakers for each subgraph. When a subgraph's error rate or response time exceeds the threshold, the circuit opens and requests to that subgraph fail immediately (returning a structured error) without waiting for a timeout.

**Rationale:** Without circuit breakers, a slow subgraph accumulates pending requests. Connection pools fill. The router spends all its connections waiting for the degraded subgraph instead of serving requests to healthy subgraphs. A circuit breaker fails fast, releases resources, and allows partial responses from healthy subgraphs during the degraded period.

**Router circuit breaker configuration:**

```yaml
# router.yaml
traffic_shaping:
  subgraph:
    all:
      experimental_retry:
        min_per_sec: 10
        retry_fraction: 0.2
        predicate: request_not_mutating  # Only retry idempotent operations

    # Per-subgraph overrides
    recommendations:
      timeout: 500ms
      experimental_retry:
        min_per_sec: 5
        retry_fraction: 0.1
```

Custom circuit breaker via coprocessor:

```typescript
// coprocessor/circuit-breaker.ts
const circuitBreakers = new Map<string, CircuitBreaker>();

async function checkCircuit(subgraphName: string): Promise<'open' | 'closed'> {
  const breaker = circuitBreakers.get(subgraphName);
  if (!breaker) return 'closed';

  const errorRate = await redis.get(`circuit:${subgraphName}:error_rate`);
  if (parseFloat(errorRate ?? '0') > 0.5) {
    return 'open'; // >50% error rate — circuit open
  }
  return 'closed';
}
```

---

## BP-SO-15: Validate All Environment Variables at Startup — Fail Fast on Misconfiguration

**Rule:** The router and all subgraphs must validate required environment variables and configuration at process startup. If required configuration is missing or invalid, the process must exit immediately with a clear error message. Never start with an unknown or default configuration.

**Rationale:** Silent misconfiguration is worse than a startup failure. A router that starts without a valid JWT secret will accept all requests unauthenticated. A router that starts with a wrong Apollo API key will silently fail to push usage metrics. Fail-fast startup validation prevents silent misconfiguration.

**Correct:**

```typescript
// config/validate.ts
import { z } from 'zod';

const ConfigSchema = z.object({
  NODE_ENV: z.enum(['development', 'staging', 'production']),
  PORT: z.coerce.number().min(1).max(65535),
  DATABASE_URL: z.string().url(),
  APOLLO_KEY: z.string().min(1),
  JWT_PUBLIC_KEY: z.string().min(1),
  OPA_URL: z.string().url(),
  REDIS_URL: z.string().url(),
});

export function validateConfig() {
  const result = ConfigSchema.safeParse(process.env);
  if (!result.success) {
    console.error('FATAL: Invalid configuration at startup:');
    console.error(result.error.format());
    process.exit(1); // Hard fail — do not start with invalid config
  }
  return result.data;
}

// Called before any server initialization
const config = validateConfig();
```

---

## BP-SO-16: Implement Structured Audit Logging for All Mutations

**Rule:** Every mutation execution must produce a structured audit log entry capturing: the mutation name, the actor (user ID + client ID), the operation inputs (sanitized — no PII or secrets), the outcome (success/failure), and the trace ID.

**Rationale:** Audit logs are required for compliance (SOC 2, GDPR), incident investigation, and abuse detection. Without structured mutation logs, it is impossible to answer "who deleted this customer record and when?" Audit logs are separate from application logs — they must be immutable, retained for a minimum period (typically 1–7 years depending on compliance requirements), and accessible to compliance officers without system access.

**Correct:**

```typescript
// middleware/audit-logger.ts
export const auditLoggerMiddleware = {
  Mutation: {
    '*': async (resolve, parent, args, context, info) => {
      const startTime = Date.now();
      let outcome: 'success' | 'failure' = 'failure';
      let resultType: string | undefined;

      try {
        const result = await resolve(parent, args, context, info);
        outcome = 'success';
        resultType = result?.__typename;
        return result;
      } catch (error) {
        outcome = 'failure';
        throw error;
      } finally {
        // Write audit log — async, non-blocking
        context.auditLogger.log({
          timestamp: new Date().toISOString(),
          traceId: context.traceId,
          mutationName: info.fieldName,
          actorId: context.user?.id ?? 'unauthenticated',
          clientId: context.clientId,
          outcome,
          resultType,
          durationMs: Date.now() - startTime,
          // Sanitized inputs — exclude sensitive fields
          inputs: sanitizeForAudit(args, AUDIT_EXCLUDED_FIELDS),
        });
      }
    },
  },
};

const AUDIT_EXCLUDED_FIELDS = new Set([
  'password', 'token', 'secret', 'cvv', 'cardNumber', 'ssn'
]);
```

---

## BP-SO-17: Use Canary Deployments for Router Updates

**Rule:** Apollo Router version upgrades must go through canary deployment: 5% of production traffic for 1 hour, then 50% for 30 minutes, then 100%. Never do a direct 100% router upgrade.

**Rationale:** The Apollo Router is a critical path component. A regression in a new router version (query plan correctness, auth middleware behavior, schema validation changes) immediately affects all traffic if deployed directly. A canary deployment limits blast radius: a regression affecting 5% of traffic is detectable in minutes without a full outage.

**Argo Rollouts configuration:**

```yaml
# rollouts/apollo-router.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: apollo-router
spec:
  replicas: 6
  strategy:
    canary:
      steps:
        - setWeight: 5    # 5% canary
        - pause:
            duration: 1h  # Monitor for 1 hour
        - setWeight: 50   # 50% canary
        - pause:
            duration: 30m
        - setWeight: 100  # Full rollout
      analysis:
        templates:
          - templateName: router-success-rate
        args:
          - name: service-name
            value: apollo-router
```

---

## BP-SO-18: Implement a Schema Security Review Process for External APIs

**Rule:** Any schema change that adds a new root field, a new mutation, or a new entity type to the external (partner-facing) contract graph must go through a security review before being merged. This review must include: data classification of new fields, authorization requirements, rate limit requirements, and abuse potential assessment.

**Rationale:** New fields and mutations expand the attack surface. A field that returns user PII added without an authorization policy immediately becomes a data exposure risk. A mutation that modifies sensitive data added without rate limiting becomes a brute-force vector. Security review before merge is cheaper than remediation after exposure.

**Security review checklist (PR template):**

```markdown
## Schema Security Review

### Required for: any new root field, mutation, or entity type in the external API

- [ ] **Data Classification**: What data does this field expose? (Public / Internal / Confidential / PII)
- [ ] **Authorization**: Which roles/permissions are required to access this field? Where is authorization enforced?
- [ ] **Rate Limiting**: What rate limit applies to operations that use this field?
- [ ] **Input Validation**: What validation is applied to arguments? What is the maximum size/complexity?
- [ ] **Audit Logging**: Is this mutation covered by audit logging? Are sensitive inputs excluded?
- [ ] **Abuse Potential**: Could this field/mutation be used for enumeration, DoS, or data exfiltration?
- [ ] **PII Review**: Does this field return PII? Is it necessary? Is it encrypted at rest?

Security reviewer sign-off: @security-team
```

---

## BP-SO-19: Test Failure Scenarios in Staging Before Every Production Deployment

**Rule:** Every production deployment must include a pre-deployment staging validation run that tests: authentication failure (invalid JWT), authorization failure (forbidden field), query complexity rejection, and subgraph timeout handling. These tests must pass before the deployment proceeds.

**Correct:**

```typescript
// e2e/pre-deployment-validation.ts
describe('Pre-deployment security validation', () => {
  test('rejects requests with no Authorization header', async () => {
    const response = await client.query({ query: GET_ORDER, variables: { id: 'test-1' } });
    expect(response.errors?.[0].extensions?.code).toBe('UNAUTHENTICATED');
  });

  test('rejects requests with expired JWT', async () => {
    const expiredToken = generateExpiredJWT();
    const response = await client.query({ query: GET_ORDER }, {
      headers: { Authorization: `Bearer ${expiredToken}` }
    });
    expect(response.errors?.[0].extensions?.code).toBe('UNAUTHENTICATED');
  });

  test('rejects queries exceeding complexity limit', async () => {
    const deepQuery = buildQueryWithComplexity(2000); // Over the 1500 limit
    const response = await client.query({ query: deepQuery });
    expect(response.errors?.[0].extensions?.code).toBe('COMPLEXITY_LIMIT_EXCEEDED');
  });

  test('rejects introspection queries without internal key', async () => {
    const response = await client.query({ query: INTROSPECTION_QUERY });
    expect(response.status).toBe(403);
  });

  test('returns partial data when recommendations subgraph is unavailable', async () => {
    // Temporarily disable recommendations subgraph in staging
    await stagingTools.disableSubgraph('recommendations');
    const response = await client.query({ query: GET_PRODUCT_WITH_RECOMMENDATIONS });
    expect(response.data?.product?.name).toBeDefined(); // Product data present
    expect(response.errors?.some(e => e.path?.includes('relatedProducts'))).toBe(true); // Error for failed field
    await stagingTools.enableSubgraph('recommendations');
  });
});
```

---

## BP-SO-20: Maintain a Dependency Inventory and Run Automated Vulnerability Scans

**Rule:** Maintain an automated inventory of all dependencies in the GraphQL system (router binary, subgraph npm/Go/Python packages, Docker base images). Run vulnerability scans on every CI build and block deployments when critical CVEs are detected.

**CI vulnerability scanning:**

```yaml
# .github/workflows/security-scan.yml
name: Security Vulnerability Scan

on: [push, pull_request]

jobs:
  scan-dependencies:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Scan Node.js dependencies
        run: |
          npm audit --audit-level=high
          npx better-npm-audit audit --level high

      - name: Scan Docker images
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${{ env.DOCKER_IMAGE }}
          format: 'sarif'
          exit-code: '1'
          severity: 'CRITICAL,HIGH'

      - name: Upload SARIF to GitHub Security
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: 'trivy-results.sarif'
```

---

## References and Related Topics

- [OWASP GraphQL Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/GraphQL_Cheat_Sheet.html) — comprehensive GraphQL security guidance
- [Apollo Router Security](https://www.apollographql.com/docs/router/configuration/overview/) — router security configuration options
- [Apollo Persisted Queries](https://www.apollographql.com/docs/apollo-server/performance/apq/) — persisted query implementation
- [OPA (Open Policy Agent)](https://www.openpolicyagent.org/) — policy engine for field-level authorization
- [Chapter 05: Security](../05-security/README.md) — authentication and authorization depth
- [Chapter 13: Policy as Code](../13-policy-as-code/README.md) — OPA/Rego at CI/CD level
- [Chapter 14: Observability](../14-observability/README.md) — metrics and alerting for SLO compliance
- [Chapter 15: Kubernetes Deployment](../15-kubernetes-deployment/README.md) — HPA, PDB, Argo Rollouts
- [Production Runbooks](../32-production-runbooks/README.md) — operational procedures dependent on these practices
- [Incident Management](../33-incident-management/README.md) — incident response using audit logs and SLO metrics
- [Anti-Patterns](../29-anti-patterns/README.md) — documented security failures and their post-mortems
