# JWT Authentication — Apollo Router and Subgraph Trust Model

Companion docs: `../../docs/05-security/`

JWT authentication in Apollo Federation is implemented entirely at the Router layer. Subgraphs do not validate JWTs — they trust the Router's claim injection via request headers. This document covers the complete Router JWT plugin configuration, the subgraph trust model, multi-IdP setup, service-to-service authentication, and testing patterns.

---

## Router JWT Plugin Configuration

The Apollo Router has a built-in JWT authentication plugin that handles JWKS fetching, token validation, and claim extraction. It does not require any custom code — the entire configuration lives in `router.yaml`.

### Complete `router.yaml` authentication section

```yaml
# router.yaml
# Apollo Router JWT authentication configuration.
# Reference: https://www.apollographql.com/docs/router/configuration/authn-jwt

authentication:
  router:
    jwt:
      jwks:
        # The JWKS endpoint URL. This must be the HTTPS endpoint exposed by
        # your identity provider (Auth0, Okta, Cognito, etc.).
        # Inject via environment variable — never hardcode a production IdP URL.
        url: "${JWKS_URL}"
        # Examples:
        # Auth0:    https://<tenant>.auth0.com/.well-known/jwks.json
        # Okta:     https://<tenant>.okta.com/oauth2/default/v1/keys
        # Cognito:  https://cognito-idp.<region>.amazonaws.com/<pool-id>/.well-known/jwks.json

        # How often to re-fetch the JWKS from the IdP endpoint.
        # 5 minutes (300 seconds) is the standard interval for key rotation polling.
        # Too short: excessive HTTP traffic to IdP.
        # Too long: if the IdP rotates keys (emergency or scheduled), the Router will
        # reject valid tokens signed with the new key until the next poll.
        poll_interval: 5m

        # Optional: cache the JWKS response even past its HTTP cache-control headers.
        # Useful if the IdP sends short Cache-Control headers (some Cognito configs do).
        # Units: seconds.
        # cache_duration: 300

      # How the Router extracts the JWT from incoming HTTP requests.
      token_extraction:
        # Extract from the Authorization header using the Bearer scheme.
        # This is the standard for OAuth2/OIDC tokens.
        from:
          header:
            name: "Authorization"
            value_prefix: "Bearer "
            # The Router strips the "Bearer " prefix and validates the remainder as a JWT.

      # JWT claims to validate in addition to signature verification.
      claims:
        # iss (issuer) validation. Tokens from unexpected issuers are rejected.
        # Must match exactly; wildcards are not supported.
        iss: "${JWT_ISSUER}"
        # Example: "https://myapp.auth0.com/"

        # aud (audience) validation. Prevents token reuse across services.
        # A JWT issued with aud: "api.myapp.com" cannot be used against a different service.
        aud: "${JWT_AUDIENCE}"
        # Example: "https://api.myapp.com"

      # Token forwarding: controls whether the raw JWT is forwarded to subgraphs.
      # IMPORTANT: Do not forward the raw JWT to subgraphs.
      # Reasons:
      # 1. Subgraphs cannot validate the JWT without their own JWKS setup (operational overhead).
      # 2. If a subgraph validates the token independently, it must also poll JWKS — doubling the
      #    key rotation polling load on the IdP.
      # 3. Leaking the JWT to subgraph logs increases the blast radius of a log compromise.
      # Instead, extract specific claims and inject them as headers (see below).
      token_forwarding: false
```

---

## Claim Extraction and Header Injection

After the Router validates the JWT, it extracts claims from the token payload and injects them as HTTP headers on requests to subgraphs. Subgraphs read these headers from the request context instead of decoding a JWT.

### Complete `headers` config for claim injection

```yaml
# router.yaml (continued)
headers:
  all:
    # These header operations apply to requests forwarded to ALL subgraphs.
    request:
      # Inject the user ID claim from the JWT as a header.
      # The 'sub' (subject) claim is the standard OIDC claim for user identity.
      # Subgraphs use x-user-id to identify the current user in resolvers.
      - propagate:
          named: "sub"
          rename: "x-user-id"
          # rename: changes the header name from the JWT claim name to a
          # subgraph-readable convention. This decouples subgraph code from
          # JWT claim naming conventions.

      # Inject the roles claim — a custom claim in the JWT payload.
      # The claim name ("https://myapp.com/roles") uses a URI namespace to
      # prevent collision with standard OIDC claims. The subgraph reads
      # x-user-roles as a comma-separated string.
      - propagate:
          named: "https://myapp.com/roles"
          rename: "x-user-roles"

      # Inject the organization ID for multi-tenant authorization.
      # Every resolver that queries tenant-specific data uses x-user-org-id
      # to scope database queries.
      - propagate:
          named: "https://myapp.com/org_id"
          rename: "x-user-org-id"

      # Inject the email for audit logging. Do not use this for authorization —
      # use the stable user ID (x-user-id) instead. Emails can change.
      - propagate:
          named: "email"
          rename: "x-user-email"

      # Remove the Authorization header before forwarding to subgraphs.
      # The subgraph does not need the raw JWT — claims are already injected above.
      # Removing it prevents accidental JWT logging in subgraph access logs.
      - remove:
          named: "Authorization"
```

### Accessing injected headers in Apollo Server subgraph context

```typescript
// src/context.ts (in any subgraph)

export interface SubgraphContext {
  userId: string | null;
  userRoles: string[];
  orgId: string | null;
  userEmail: string | null;
}

export function buildContext(req: IncomingMessage): SubgraphContext {
  // The Router has already validated the JWT. These headers are injected by the Router
  // and are trustworthy because the subgraph is only reachable from within the cluster
  // (see NetworkPolicy below). Direct external access is blocked at the network level.
  return {
    userId: (req.headers['x-user-id'] as string) ?? null,
    userRoles: ((req.headers['x-user-roles'] as string) ?? '').split(',').filter(Boolean),
    orgId: (req.headers['x-user-org-id'] as string) ?? null,
    userEmail: (req.headers['x-user-email'] as string) ?? null,
  };
}
```

---

## Subgraph Trust Model

The security of the entire architecture rests on one invariant: **subgraphs are only reachable from the Router**. If an attacker can send a request directly to a subgraph with crafted `x-user-id: admin` headers, authentication is bypassed entirely.

### Kubernetes NetworkPolicy to enforce subgraph isolation

```yaml
# k8s/network-policy-subgraph.yaml
# Apply this to each subgraph namespace/deployment.
# This policy denies all ingress to subgraph pods EXCEPT from Router pods.

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-router-only
  namespace: subgraphs   # Apply in the namespace where subgraph pods run
spec:
  # Apply this policy to pods labeled app=users-subgraph (or products-subgraph, etc.)
  podSelector:
    matchLabels:
      component: subgraph  # Label all subgraph pods with this label

  policyTypes:
    - Ingress

  ingress:
    # Allow traffic ONLY from pods labeled component=apollo-router
    - from:
        - podSelector:
            matchLabels:
              component: apollo-router
      ports:
        - protocol: TCP
          port: 4001  # Subgraph HTTP port — adjust if subgraphs use different ports
```

This NetworkPolicy means:
- The Router (labeled `component: apollo-router`) can reach subgraph port 4001
- All other traffic to port 4001 is dropped, including direct external connections
- Subgraph-to-subgraph communication (if needed) must be explicitly permitted with additional rules

### Why subgraphs don't validate JWTs

In addition to the network controls, there are operational reasons to keep JWT validation in the Router only:

| Concern | Impact without Router-only validation |
|---------|--------------------------------------|
| JWKS polling | Every subgraph instance polls the IdP JWKS endpoint — 10 subgraphs × 3 replicas = 30 pollers |
| Key rotation latency | Each poller has its own TTL/cache — key rotation propagates at different times per subgraph |
| Operational consistency | Each team must configure JWKS URL, issuer, audience, claim names — inconsistencies introduce bugs |
| Library overhead | JWT validation library added to every subgraph bundle |
| Test complexity | Every subgraph integration test needs a valid JWT |

---

## Handling Unauthenticated Requests

Some operations (public product catalog, landing page content, public blog posts) should work without authentication. Others require a valid JWT. The Router supports both modes.

### Schema-level authentication directives (Federation 2.4+)

```graphql
# supergraph schema (or individual subgraph schemas federated together)
# Import the @authenticated directive from the federation spec
extend schema
  @link(url: "https://specs.apollo.dev/federation/v2.4", import: ["@key", "@authenticated", "@requiresScopes"])

type Query {
  # Public — no authentication required
  products: [Product!]!
  product(id: ID!): Product

  # Requires authentication — @authenticated causes the Router to reject
  # requests without a valid JWT before the resolver runs
  myOrders: [Order!]! @authenticated
  me: User @authenticated
}

type Mutation {
  # All mutations require authentication
  createOrder(input: OrderInput!): Order @authenticated
  updateProfile(input: ProfileInput!): User @authenticated
}
```

### Router configuration for optional authentication

```yaml
# router.yaml
authentication:
  router:
    jwt:
      # ... JWKS config as above ...

      # Allow unauthenticated requests to pass through (for public endpoints).
      # If this is false (the default), ALL requests must have a valid JWT.
      # If this is true, unauthenticated requests are allowed but the JWT claims
      # are not available in context. The @authenticated directive on individual
      # fields/types enforces auth at the schema level for protected operations.
      require_authentication: false
```

With `require_authentication: false`, unauthenticated requests proceed to the Router but have no claim headers. The `@authenticated` directive on specific types and fields acts as the enforcement gate. Resolvers for unauthenticated operations receive `context.userId = null`.

---

## Multiple Identity Providers

Production platforms often have multiple IdPs: one for end users (Auth0, Okta) and another for service-to-service (internal PKI, Vault JWT, AWS STS). Configure multiple JWKS endpoints as an array.

```yaml
# router.yaml
authentication:
  router:
    jwt:
      jwks:
        # Array of JWKS endpoints. The Router validates a JWT against each endpoint
        # in order until one succeeds or all fail. The first endpoint to successfully
        # validate the token determines the claims.
        - url: "${AUTH0_JWKS_URL}"
          # End user tokens from Auth0. These tokens carry user identity claims.
          # iss: "https://myapp.auth0.com/"
          # aud: "https://api.myapp.com"

        - url: "${INTERNAL_JWKS_URL}"
          # Service-to-service tokens from the internal PKI.
          # iss: "https://internal-auth.myapp.internal"
          # aud: "https://api.myapp.com"
          # These tokens carry service identity claims: sub = "service:checkout"

      claims:
        # Audience is the same for all token types — the API must be the intended audience.
        aud: "${JWT_AUDIENCE}"
        # Issuer is NOT validated globally when using multiple JWKS — each endpoint
        # has a different issuer. Validate issuer per-endpoint using the claims section
        # inside each jwks entry (supported in Router 1.45+):
        # - url: "${AUTH0_JWKS_URL}"
        #   claims:
        #     iss: "https://myapp.auth0.com/"
```

### Distinguishing token types in resolvers

```typescript
// In subgraph context builder
const userId = req.headers['x-user-id'] as string | null;
const isServiceToken = userId?.startsWith('service:') ?? false;

// context.isServiceToken can be used in resolvers to apply different
// authorization rules for service-to-service calls
```

---

## Service-to-Service Authentication (M2M)

Internal services (e.g., the billing service calling the GraphQL API directly) use the OAuth2 Client Credentials flow to obtain a JWT:

```typescript
// src/auth/service-token.ts
// Internal service authenticating to the GraphQL API

import { createJWT } from 'jose';
import { createPrivateKey } from 'crypto';

export async function getServiceToken(): Promise<string> {
  // Use client credentials flow with Auth0 (or any OAuth2 IdP)
  const response = await fetch(`${process.env.AUTH0_DOMAIN}/oauth/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      client_id: process.env.SERVICE_CLIENT_ID,
      client_secret: process.env.SERVICE_CLIENT_SECRET,
      audience: process.env.JWT_AUDIENCE,
      grant_type: 'client_credentials',
      // Custom claims for service identity — resolved by Auth0 Actions/Rules
      // The resulting JWT will contain sub: "service:billing"
    }),
  });

  const { access_token } = await response.json();
  return access_token;
}
```

### Restricting internal-only fields via `@tag`

```graphql
# In a subgraph schema — mark admin/internal fields with @tag
type Query {
  # This field is accessible only to internal services, not end users.
  # The Router policy blocks external tokens from accessing @tag(name: "internal") fields.
  adminUserList: [User!]! @tag(name: "internal") @authenticated
}
```

```yaml
# router.yaml — enforce internal tag restriction
authorization:
  require_authentication: false
  preview_directives:
    enabled: true
  # Requests using an end-user token (iss: Auth0) cannot access fields tagged "internal".
  # Requests using a service token (iss: internal PKI, sub starts with "service:") can.
```

---

## Testing JWT Authentication

### Generating test JWTs

```typescript
// test/helpers/jwt.ts
import { SignJWT, generateKeyPair } from 'jose';

// Generate a key pair for tests — do not use RSA keys from production
export const testKeys = await generateKeyPair('RS256');

export async function createTestJWT(claims: {
  sub: string;
  roles?: string[];
  orgId?: string;
  expiresIn?: string;
}): Promise<string> {
  const jwt = await new SignJWT({
    'https://myapp.com/roles': claims.roles ?? ['user'],
    'https://myapp.com/org_id': claims.orgId ?? 'org-test',
    email: `${claims.sub}@test.example`,
  })
    .setProtectedHeader({ alg: 'RS256', kid: 'test-key-1' })
    .setIssuer('https://test.auth.myapp.com/')
    .setAudience('https://api.myapp.com')
    .setSubject(claims.sub)
    .setIssuedAt()
    .setExpirationTime(claims.expiresIn ?? '1h')
    .sign(testKeys.privateKey);

  return jwt;
}
```

### Curl examples for manual testing

```bash
# Authenticated request
TOKEN=$(node -e "
const { SignJWT, generateKeyPair } = require('jose');
// ... (use the createTestJWT helper above) ...
")

curl -s http://localhost:4000/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{"query": "{ me { id email } }"}'

# Unauthenticated request (should work for public queries)
curl -s http://localhost:4000/graphql \
  -H "Content-Type: application/json" \
  -d '{"query": "{ products { id name } }"}'

# Expired token — Router should return 401
EXPIRED_TOKEN="eyJhbGciOiJSUzI1NiJ9..."  # A token with exp in the past
curl -s http://localhost:4000/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${EXPIRED_TOKEN}" \
  -d '{"query": "{ me { id } }"}'
# Expected: {"errors":[{"message":"Unauthorized","extensions":{"code":"UNAUTHENTICATED"}}]}

# Wrong audience — Router should return 401
curl -s http://localhost:4000/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${WRONG_AUD_TOKEN}" \
  -d '{"query": "{ me { id } }"}'
```

### Integration test: JWKS validation

```typescript
// test/integration/auth.test.ts
import { describe, it, expect, beforeAll } from 'vitest';
import { createTestJWT, testKeys } from '../helpers/jwt';
import { exportJWK } from 'jose';
import nock from 'nock';

describe('JWT authentication integration', () => {
  beforeAll(async () => {
    // Mock the JWKS endpoint with the test public key
    const publicJWK = await exportJWK(testKeys.publicKey);
    nock('https://test.auth.myapp.com')
      .get('/.well-known/jwks.json')
      .reply(200, {
        keys: [{ ...publicJWK, kid: 'test-key-1', use: 'sig', alg: 'RS256' }],
      });
  });

  it('should resolve authenticated fields with a valid JWT', async () => {
    const token = await createTestJWT({ sub: 'user-42', roles: ['user'] });
    const response = await fetch('http://localhost:4000/graphql', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ query: '{ me { id } }' }),
    });
    const body = await response.json();
    expect(body.errors).toBeUndefined();
    expect(body.data.me.id).toBe('user-42');
  });

  it('should reject @authenticated fields without a JWT', async () => {
    const response = await fetch('http://localhost:4000/graphql', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: '{ me { id } }' }),
    });
    const body = await response.json();
    expect(body.errors[0].extensions.code).toBe('UNAUTHENTICATED');
  });

  it('should reject an expired JWT', async () => {
    const expiredToken = await createTestJWT({ sub: 'user-42', expiresIn: '-1m' });
    const response = await fetch('http://localhost:4000/graphql', {
      method: 'POST',
      headers: { Authorization: `Bearer ${expiredToken}` },
      body: JSON.stringify({ query: '{ me { id } }' }),
    });
    const body = await response.json();
    expect(body.errors[0].extensions.code).toBe('UNAUTHENTICATED');
  });
});
```

---

## Key Design Decisions

1. **Authentication in the Router only, not in subgraphs.** Centralizing JWT validation reduces operational complexity, ensures consistent enforcement, and avoids the polling overhead of 10+ subgraph instances each polling JWKS. The network controls (NetworkPolicy) enforce this architectural decision at the infrastructure level.

2. **Claims injected as headers, raw JWT stripped.** Injecting individual claims decouples subgraph code from JWT structure. If the IdP changes a claim name (e.g., `roles` to `permissions`), only the Router header injection config changes — subgraph code remains unchanged.

3. **`aud` claim validation is mandatory.** Without audience validation, a JWT issued for another service (e.g., a third-party API that also trusts your IdP) can be replayed against the GraphQL API. The `aud` claim scopes tokens to their intended recipient.

4. **`require_authentication: false` with `@authenticated` directives.** This approach provides the most flexibility — public APIs work without a JWT, protected operations are gated at the schema level. The alternative (require auth globally and use exemptions) is more complex and error-prone.

5. **Service-to-service tokens have a different issuer from user tokens.** This allows the Router to distinguish M2M requests from user requests and apply different authorization rules (e.g., allow access to internal-only fields for service tokens only).

---

## Related Documentation

- `../../docs/05-security/` — full security guide
- `../../examples/12-security/field-level-authorization.md` — using JWT claims for field authorization
- `../../examples/12-security/query-security.md` — preventing abuse at the query layer
- `../../examples/07-opa-policies/` — OPA for complex authorization rules
- `../../examples/06-kubernetes/` — NetworkPolicy configuration
