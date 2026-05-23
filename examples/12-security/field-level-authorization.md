# Field-Level Authorization in GraphQL Subgraphs

Companion docs: `../../docs/05-security/`

Field-level authorization is the mechanism for restricting access to specific schema fields based on the authenticated user's identity, roles, or OAuth scopes. In Apollo Federation, this lives in the subgraph layer — the Router handles authentication, but the subgraph owns the authorization policy for its data.

This document covers the built-in Federation directives (`@requiresScopes`, `@authenticated`), custom directive implementations, resolver-level checks, multi-tenant data isolation, audit logging, and testing patterns.

---

## `@requiresScopes` Directive (Apollo Router Built-In)

`@requiresScopes` is a Federation 2.4+ directive that declares which OAuth scopes a client must present to access a field or type. The Router evaluates scopes before the resolver runs — unauthorized requests are rejected without touching the subgraph.

### Enabling `@requiresScopes` in `router.yaml`

```yaml
# router.yaml
authorization:
  # Enable the @requiresScopes and @authenticated directive enforcement.
  # These are preview features in Router 1.40 and stable in 1.45+.
  preview_directives:
    enabled: true
```

### Declaring scope requirements in SDL

```graphql
# users subgraph — schema.graphql
extend schema
  @link(
    url: "https://specs.apollo.dev/federation/v2.4"
    import: ["@key", "@authenticated", "@requiresScopes"]
  )

type User @key(fields: "id") {
  id: ID!
  # Public fields — no scope or auth required
  displayName: String!
  avatarUrl: String

  # Requires the 'read:profile' scope. OAuth clients without this scope
  # cannot access this field, even if they have a valid JWT.
  email: String @requiresScopes(scopes: [["read:profile"]])

  # Requires EITHER 'admin:users' OR 'billing:read' scope.
  # The nested array syntax means: each inner array is an AND condition,
  # outer array items are OR conditions.
  # [["admin:users"], ["billing:read"]] = admin:users OR billing:read
  billingInfo: BillingInfo @requiresScopes(scopes: [["admin:users"], ["billing:read"]])

  # Requires BOTH 'read:profile' AND 'read:sensitive' (AND condition).
  # [["read:profile", "read:sensitive"]] = read:profile AND read:sensitive
  socialSecurityNumber: String @requiresScopes(scopes: [["read:profile", "read:sensitive"]])
}

type Query {
  # Requires authentication (any valid JWT) to list users
  users: [User!]! @authenticated

  # Requires the admin scope to list ALL users
  allUsers(page: Int, pageSize: Int): UserPage @requiresScopes(scopes: [["admin:users"]])
}

type Mutation {
  # Requires write:profile scope to update user data
  updateProfile(input: UpdateProfileInput!): User @requiresScopes(scopes: [["write:profile"]])

  # Requires admin scope to delete users
  deleteUser(id: ID!): Boolean @requiresScopes(scopes: [["admin:users"]])
}
```

### Scope claim format in JWT

The Router extracts scopes from the JWT `scope` claim (space-delimited string, per RFC 8693):

```json
{
  "sub": "user-42",
  "iss": "https://myapp.auth0.com/",
  "aud": "https://api.myapp.com",
  "scope": "read:profile write:profile read:orders",
  "exp": 1716000000
}
```

The Router parses the `scope` string into an array and evaluates it against the `@requiresScopes` requirements. If the token's scope set satisfies the directive's requirements, the request proceeds. Otherwise, the Router returns:

```json
{
  "errors": [{
    "message": "Unauthorized field or type",
    "extensions": { "code": "UNAUTHORIZED" }
  }]
}
```

---

## `@authenticated` Directive

`@authenticated` is the coarser-grained companion to `@requiresScopes`. It requires any valid authenticated JWT without checking specific scopes. Use it for fields that should be accessible to all authenticated users regardless of granted scopes.

```graphql
type Query {
  # Any authenticated user can see their own profile
  me: User @authenticated

  # Public — no directive needed
  publicAnnouncements: [Announcement!]!
}

type User @key(fields: "id") {
  id: ID!
  displayName: String!    # Public

  # Only authenticated users see this (e.g., contact info for logged-in users)
  email: String @authenticated

  # More restrictive — requires specific scope
  billingInfo: BillingInfo @requiresScopes(scopes: [["billing:read"]])
}
```

---

## Custom `@authorize` Directive

For authorization rules that cannot be expressed as OAuth scope checks — such as ownership checks, role hierarchy, or resource-based access control — implement a custom `@authorize` directive with a schema directive visitor.

### SDL definition

```graphql
# users subgraph schema
directive @authorize(
  # Required roles — user must have at least one of these roles.
  roles: [String!]
  # Allow owner — if true, a user can access their own resource even without the required roles.
  # "Ownership" is defined as: context.userId === the resource's userId field.
  allowOwner: Boolean
) on FIELD_DEFINITION | OBJECT
```

### Implementation with `@graphql-tools/schema`

```typescript
// src/directives/authorize.ts
import { MapperKind, mapSchema, getDirective } from '@graphql-tools/utils';
import { GraphQLSchema, defaultFieldResolver, GraphQLError } from 'graphql';

export function authorizeDirectiveTransformer(schema: GraphQLSchema): GraphQLSchema {
  return mapSchema(schema, {
    [MapperKind.OBJECT_FIELD]: (fieldConfig) => {
      // Check if this field has the @authorize directive
      const authorizeDirective = getDirective(schema, fieldConfig, 'authorize')?.[0];
      if (!authorizeDirective) {
        // No @authorize directive — leave the field unchanged
        return fieldConfig;
      }

      const { roles: requiredRoles, allowOwner } = authorizeDirective as {
        roles?: string[];
        allowOwner?: boolean;
      };

      const { resolve = defaultFieldResolver } = fieldConfig;

      // Wrap the original resolver with authorization logic
      fieldConfig.resolve = async function (source, args, context, info) {
        const { userId, userRoles } = context as {
          userId: string | null;
          userRoles: string[];
        };

        // Check 1: Must be authenticated
        if (!userId) {
          throw new GraphQLError('Authentication required', {
            extensions: { code: 'UNAUTHENTICATED' },
          });
        }

        // Check 2: Role-based authorization
        const hasRequiredRole =
          !requiredRoles ||
          requiredRoles.length === 0 ||
          userRoles.some((role) => requiredRoles.includes(role));

        // Check 3: Owner bypass — if allowOwner is true and the resource belongs
        // to the requesting user, grant access regardless of roles.
        // The 'source' object is the parent entity being resolved; compare its userId
        // field to the current user's ID.
        const isOwner = allowOwner === true && source?.userId === userId;

        if (!hasRequiredRole && !isOwner) {
          throw new GraphQLError(
            `Insufficient permissions. Required roles: ${requiredRoles?.join(', ')}`,
            {
              extensions: { code: 'FORBIDDEN' },
            }
          );
        }

        // Authorization passed — call the original resolver
        return resolve(source, args, context, info);
      };

      return fieldConfig;
    },
  });
}
```

### Applying the transformer in Apollo Server setup

```typescript
// src/server.ts
import { makeExecutableSchema } from '@graphql-tools/schema';
import { authorizeDirectiveTransformer } from './directives/authorize';

let schema = makeExecutableSchema({ typeDefs, resolvers });
// Apply directive transformers — order matters if multiple transformers exist
schema = authorizeDirectiveTransformer(schema);

const server = new ApolloServer({ schema });
```

### Usage in SDL

```graphql
type User @key(fields: "id") {
  id: ID!
  displayName: String!

  # Only admins can view internal notes, OR the user can view their own notes
  internalNotes: String @authorize(roles: ["admin"], allowOwner: true)

  # Only managers and admins can view performance reviews
  performanceReviews: [Review] @authorize(roles: ["admin", "manager"])
}
```

---

## Authorization in Resolvers

Directive-based authorization covers static rules. Dynamic rules (e.g., "can this user access this specific document?") require authorization logic inside the resolver.

### TypeScript resolver with role check

```typescript
// src/resolvers/user.ts

const resolvers = {
  Query: {
    userById: async (_, { id }, context: SubgraphContext) => {
      // Step 1: Must be authenticated
      if (!context.userId) {
        throw new GraphQLError('Authentication required', {
          extensions: { code: 'UNAUTHENTICATED' },
        });
      }

      // Step 2: Users can view their own profile; admins can view any profile
      const isOwnProfile = context.userId === id;
      const isAdmin = context.userRoles.includes('admin');

      if (!isOwnProfile && !isAdmin) {
        // Return null instead of throwing an error for ownership violations.
        // Throwing an error reveals that the resource exists, which is an
        // information disclosure risk. Returning null is equivalent to "not found."
        return null;
      }

      // Step 3: Fetch with org scoping (see multi-tenant section below)
      return userRepository.findById(id, context.orgId);
    },
  },
};
```

---

## DataLoader and Authorization

DataLoader batches multiple entity loads into a single database query. A subtle correctness issue arises when DataLoader is used in multi-user patterns: authorization must be applied AFTER the batch resolves, not as a pre-filter.

### The problem: batch loads span entity IDs, not users

In Apollo Federation, the `_entities` resolver receives a batch of entity representations from the Router. All representations in a single batch are for the SAME request (same user context). This is safe. However, if you build a custom batching system that aggregates across multiple user requests, you must apply authorization per item after the batch resolves.

```typescript
// SAFE: DataLoader for a single user's request context
// Each request gets its own DataLoader instance (created in the context factory)
const userLoader = new DataLoader(async (ids: readonly string[]) => {
  // All IDs in this batch belong to the current request's context
  const users = await db.query('SELECT * FROM users WHERE id = ANY($1)', [ids]);
  return ids.map((id) => users.find((u) => u.id === id) ?? null);
});

// In resolver — DataLoader batches multiple calls within the same request
User: {
  manager: async (user, _, context) => {
    if (!user.managerId) return null;
    const manager = await context.loaders.user.load(user.managerId);

    // Apply authorization AFTER load — check ownership or role
    if (!context.userRoles.includes('admin') && manager?.orgId !== context.orgId) {
      return null;  // Cross-org data not accessible
    }

    return manager;
  },
},
```

### The danger: module-level DataLoader (do not do this)

```typescript
// WRONG — singleton DataLoader caches responses across requests
// If request 1 loads User:42 and request 2 also loads User:42,
// request 2 gets the cached value WITHOUT its authorization context being checked.
const globalUserLoader = new DataLoader((ids) => loadUsers(ids));

// CORRECT — DataLoader in the per-request context function
context: async ({ req }) => ({
  loaders: {
    // New instance per request — in-memory cache is scoped to this request only
    user: new DataLoader((ids: readonly string[]) => loadUsers(ids)),
  },
})
```

---

## Organization-Scoped Data Isolation (Multi-Tenant)

Every resolver in a multi-tenant system must scope queries by `orgId`. The `orgId` is injected by the Router from the JWT claim `x-user-org-id`. Resolvers must never return data from a different organization, regardless of what ID is provided in query arguments.

### The invariant

```typescript
// The golden rule of multi-tenant resolver design:
// ALWAYS add orgId as a filter condition in addition to the primary key.
// Do not rely on the client to "not ask for data from other orgs."
```

### PostgreSQL query pattern

```typescript
// src/repositories/user.ts

export class UserRepository {
  async findById(userId: string, orgId: string): Promise<User | null> {
    // The WHERE clause includes BOTH id AND org_id.
    // If an attacker passes userId for a user in a different org,
    // org_id mismatch causes the query to return null — not an error, not the
    // other org's data. Zero data leakage without revealing the ID exists.
    const result = await pool.query(
      `SELECT id, display_name, email, billing_info
       FROM users
       WHERE id = $1
         AND org_id = $2    -- org scoping: never remove this condition`,
      [userId, orgId]
    );
    return result.rows[0] ?? null;
  }

  async findAll(orgId: string, page: number, pageSize: number): Promise<User[]> {
    // Listing all users: scoped entirely to the org. No possibility of
    // listing users from another organization.
    return pool.query(
      `SELECT id, display_name, email
       FROM users
       WHERE org_id = $1   -- must always be present
       ORDER BY display_name
       LIMIT $2 OFFSET $3`,
      [orgId, pageSize, (page - 1) * pageSize]
    ).then((r) => r.rows);
  }
}
```

### Prisma pattern

```typescript
// src/repositories/user.prisma.ts

export class UserRepository {
  constructor(private prisma: PrismaClient) {}

  async findById(userId: string, orgId: string): Promise<User | null> {
    return this.prisma.user.findFirst({
      where: {
        id: userId,
        orgId: orgId,   // Always scope to orgId — even with findFirst not findUnique
        // Using findFirst (not findUnique) because the compound condition
        // (id + orgId) is a unique constraint, but the application-level intent
        // is to scope by org, not just find by ID.
      },
    });
  }

  // Alternative: use a base Prisma extension that automatically adds orgId to all queries
  // This prevents accidentally missing the orgId filter in any new repository method.
}
```

### Prisma middleware for automatic org scoping

```typescript
// src/db/prisma-org-middleware.ts
// This middleware automatically adds orgId to every Prisma query, eliminating
// the risk of a developer forgetting to add the orgId filter in a new method.

prisma.$use(async (params, next) => {
  // List of models that support org scoping
  const orgScopedModels = ['User', 'Order', 'Product', 'Invoice'];

  if (orgScopedModels.includes(params.model ?? '') && params.action !== 'create') {
    // Inject orgId into the where clause of all read operations
    if (params.args.where) {
      params.args.where.orgId = currentOrgId;  // currentOrgId from async context
    } else {
      params.args.where = { orgId: currentOrgId };
    }
  }

  return next(params);
});
```

---

## Audit Logging for Sensitive Field Access

Every access to personally identifiable information (PII), financial data, or health records must be logged to an audit trail. Implement this as a `graphql-middleware` field middleware to avoid duplicating logging logic in every resolver.

### Installing dependencies

```bash
npm install graphql-middleware
```

### Implementing the audit log middleware

```typescript
// src/middleware/audit-log.ts
import { IMiddleware } from 'graphql-middleware';
import { GraphQLResolveInfo } from 'graphql';

// Fields that require audit logging — define by type.field pattern
const AUDITED_FIELDS = new Set([
  'User.email',
  'User.billingInfo',
  'User.socialSecurityNumber',
  'User.healthRecords',
  'Order.paymentDetails',
]);

export const auditLogMiddleware: IMiddleware = async (
  resolve,
  root,
  args,
  context,
  info: GraphQLResolveInfo
) => {
  const fieldPath = `${info.parentType.name}.${info.fieldName}`;
  const isAudited = AUDITED_FIELDS.has(fieldPath);

  if (isAudited) {
    // Log BEFORE the resolver runs — captures access attempts, not just successful reads.
    // If the resolver throws (auth failure), we still have a record of the access attempt.
    const auditEntry = {
      timestamp: new Date().toISOString(),
      event: 'field_access',
      field: fieldPath,
      userId: context.userId,
      orgId: context.orgId,
      resourceId: root?.id ?? args?.id ?? 'unknown',
      // Request correlation ID for tracing the full request chain
      correlationId: context.req?.headers['x-correlation-id'] ?? 'unknown',
    };

    // Write to structured audit log — use a dedicated logger, not console.log
    // In production, ship audit logs to an immutable destination (S3, CloudWatch, Splunk)
    auditLogger.info(auditEntry);
  }

  // Run the resolver and return the result
  return resolve(root, args, context, info);
};
```

### Applying middleware to the Apollo Server schema

```typescript
// src/server.ts
import { applyMiddleware } from 'graphql-middleware';

const schema = makeExecutableSchema({ typeDefs, resolvers });
const schemaWithMiddleware = applyMiddleware(
  schema,
  auditLogMiddleware      // Audit logging on sensitive fields
  // Add other middleware here: rateLimitMiddleware, metricMiddleware, etc.
);
const server = new ApolloServer({ schema: schemaWithMiddleware });
```

---

## Testing Authorization

### Unit tests for pure authorization functions

```typescript
// test/unit/authorization.test.ts
import { describe, it, expect } from 'vitest';
import { checkRoleAccess, checkOwnership } from '../../src/auth/authorization';

describe('checkRoleAccess', () => {
  it('returns true when user has a required role', () => {
    expect(checkRoleAccess(['admin', 'user'], ['admin'])).toBe(true);
  });

  it('returns false when user lacks all required roles', () => {
    expect(checkRoleAccess(['user'], ['admin', 'billing'])).toBe(false);
  });

  it('returns true for empty required roles (no restriction)', () => {
    expect(checkRoleAccess(['user'], [])).toBe(true);
  });
});

describe('checkOwnership', () => {
  it('returns true when userId matches resource owner', () => {
    const resource = { userId: 'user-42', orgId: 'org-1' };
    expect(checkOwnership('user-42', resource)).toBe(true);
  });

  it('returns false for a different user', () => {
    const resource = { userId: 'user-42', orgId: 'org-1' };
    expect(checkOwnership('user-99', resource)).toBe(false);
  });
});
```

### Integration tests with different user roles

```typescript
// test/integration/field-auth.test.ts
import { describe, it, expect } from 'vitest';
import { createTestJWT } from '../helpers/jwt';

async function graphqlRequest(query: string, token?: string) {
  return fetch('http://localhost:4001/graphql', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify({ query }),
  }).then((r) => r.json());
}

describe('field-level authorization', () => {
  it('allows user to read their own email with read:profile scope', async () => {
    const token = await createTestJWT({
      sub: 'user-42',
      scopes: ['read:profile'],
    });
    const result = await graphqlRequest('{ me { email } }', token);
    expect(result.errors).toBeUndefined();
    expect(result.data.me.email).toBeDefined();
  });

  it('denies access to billingInfo without billing:read scope', async () => {
    const token = await createTestJWT({
      sub: 'user-42',
      scopes: ['read:profile'],  // No billing:read scope
    });
    const result = await graphqlRequest('{ me { billingInfo { cardLastFour } } }', token);
    expect(result.errors).toBeDefined();
    expect(result.errors[0].extensions.code).toBe('UNAUTHORIZED');
  });

  it('allows admin to access any user profile', async () => {
    const token = await createTestJWT({
      sub: 'admin-1',
      roles: ['admin'],
      scopes: ['read:profile', 'admin:users'],
    });
    const result = await graphqlRequest('{ userById(id: "user-42") { displayName } }', token);
    expect(result.errors).toBeUndefined();
    expect(result.data.userById).toBeDefined();
  });

  it('prevents cross-org data access', async () => {
    const token = await createTestJWT({
      sub: 'user-org1',
      orgId: 'org-1',   // User belongs to org-1
      scopes: ['read:profile'],
    });
    // Try to access a user in org-2
    const result = await graphqlRequest('{ userById(id: "user-org2-99") { displayName } }', token);
    // Should return null (not found), not an error that reveals the resource exists
    expect(result.data.userById).toBeNull();
    expect(result.errors).toBeUndefined();
  });
});
```

---

## Key Design Decisions

1. **`@requiresScopes` for OAuth-native scope-based access, custom `@authorize` for role/ownership rules.** They solve different problems. `@requiresScopes` is evaluated by the Router before the request reaches the subgraph. The custom directive runs in the subgraph where resolver context (ownership, org membership) is available.

2. **Return `null` instead of throwing errors for ownership failures.** Throwing a `FORBIDDEN` error for a resource that belongs to another user reveals that the resource ID exists — this is an enumeration vulnerability. Returning `null` is equivalent to "not found" from the client's perspective and reveals nothing about other users' data.

3. **DataLoader instances must be per-request.** The DataLoader in-memory cache is an optimization for deduplicating loads within a single request execution. Sharing a DataLoader across requests creates a cache that cannot differentiate authorization contexts. Create DataLoaders in the context factory.

4. **Org scoping at the database layer, not just the API layer.** API-level checks can be bypassed by bugs, refactors, or missing middleware. Database-level filtering (WHERE org_id = $1) provides a hard invariant — a query without the org filter cannot return out-of-org data, regardless of how it was constructed.

5. **Audit logging before the resolver runs, not after.** Logging after a successful read means failed authorization attempts (where the resolver throws) are not logged. Pre-logging captures all access attempts, including those that fail due to missing permissions or network errors.

---

## Related Documentation

- `../../docs/05-security/` — full security guide
- `../../examples/12-security/jwt-authentication.md` — JWT auth and claim injection
- `../../examples/12-security/query-security.md` — query depth/complexity limits
- `../../examples/07-opa-policies/` — OPA for centralized policy-as-code authorization
- `../../docs/01-federation-overview/` — Federation entity model and `@key` directive
