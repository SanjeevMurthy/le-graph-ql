# GraphQL Authorization

> **Purpose:** Authorization determines what authenticated users can do. GraphQL's fine-grained type system makes field-level authorization both possible and necessary — a REST endpoint either returns the resource or doesn't, but a GraphQL response can expose 50 fields, each with different access rules.

## Learning Objectives

- [ ] Distinguish RBAC from ABAC and choose the right model for a given use case
- [ ] Implement a custom `@auth` directive using `mapSchema` transformer
- [ ] Apply field-level authorization in resolvers without duplicating checks
- [ ] Configure PostgreSQL Row-Level Security (RLS) as a data-layer authorization backstop
- [ ] Design a multi-subgraph authorization model where each subgraph enforces its own rules

---

## Overview / Architecture

Authentication answers "who are you?" Authorization answers "what are you allowed to do?" In GraphQL, authorization is more complex than in REST because the same query path can traverse multiple types and fields, each with different rules.

The canonical failure mode: a developer adds authorization to the `Query.user` root field but forgets to protect `Query.userByEmail`. Both resolve to the same `User` type. An attacker enumerates users by email without permission, bypassing the `user(id:)` guard entirely.

The correct mental model: **authorize at the field level, not just the root.** Every field that exposes sensitive data needs its own authorization check. This is expensive to implement naively (N checks per query), which is why directive-based and context-aware patterns exist.

```mermaid
flowchart TD
    classDef clientNode fill:#dbeafe,stroke:#3B82F6,color:#1e3a8a
    classDef routerNode fill:#e8f4f8,stroke:#0ea5e9,color:#0c4a6e
    classDef subgraphNode fill:#f0fdf4,stroke:#22c55e,color:#14532d
    classDef secNode fill:#fdf4ff,stroke:#a855f7,color:#581c87
    classDef dbNode fill:#fef9c3,stroke:#eab308,color:#713f12

    Q[Query:\nuser {\n  salary\n  ssn\n  name\n}]:::clientNode
    ROUTER[Apollo Router\nx-user-id + x-roles forwarded]:::routerNode
    RESOLVER[User Resolver\ncontext.userId + context.roles]:::subgraphNode
    
    NAME_AUTH{role: any\nauthenticated user}:::secNode
    SALARY_AUTH{role: hr\nor self}:::secNode
    SSN_AUTH{role: hr_admin\nonly}:::secNode

    NAME[name: OK]:::subgraphNode
    SALARY[salary: OK for HR]:::subgraphNode
    SSN_BLOCK[ssn: null\nerror extension]:::routerNode
    DB[(PostgreSQL\nRLS: tenant_id match)]:::dbNode

    Q --> ROUTER --> RESOLVER
    RESOLVER --> NAME_AUTH --> NAME
    RESOLVER --> SALARY_AUTH --> SALARY
    RESOLVER --> SSN_AUTH --> SSN_BLOCK
    NAME & SALARY --> DB
```

---

## Core Concepts

### RBAC vs ABAC

**Role-Based Access Control (RBAC):** Access is granted based on the user's role. Simple and auditable. Fails when access rules depend on data attributes (e.g., "can access own orders but not others'").

```
user.roles = ['viewer', 'hr_admin']
IF role IN ['hr', 'hr_admin'] THEN allow salary access
```

**Attribute-Based Access Control (ABAC):** Access is granted based on attributes of the subject (user), resource (data), and environment (time, IP). Powerful and expressive. Complex to audit.

```
IF user.id == resource.owner_id OR user.role == 'admin' THEN allow
IF user.tenant_id == resource.tenant_id AND user.role != 'suspended' THEN allow
```

Most production systems use a hybrid: RBAC for coarse-grained access (can you access billing at all?) and ABAC for fine-grained access (can you see this specific invoice?).

### Defense in Depth

Authorization should happen at multiple layers:

1. **Router layer:** Coarse-grained — can this user access this operation type? (mutation requires authenticated, subscription requires premium plan)
2. **Resolver layer:** Fine-grained — can this user see this field on this specific object?
3. **Database layer:** PostgreSQL RLS — ensures data never leaks even if resolver logic has bugs

Never rely on a single layer. The database RLS is a safety net, not the primary mechanism.

### Null vs Error for Unauthorized Fields

Two patterns for unauthorized fields:

**Return null:** The field resolves to null. The client sees data with gaps. No error is surfaced. Used when field absence is not itself sensitive information.

**Return error with extensions:** The field resolves to null AND an error is added to the `errors` array with `extensions.code: "FORBIDDEN"`. The client can distinguish "this user has no salary" from "you're not authorized to see salary."

Both are valid. Pick one and apply it consistently.

---

## Real-World Implementation

### Custom @auth Directive

```typescript
import { makeExecutableSchema } from '@graphql-tools/schema';
import { mapSchema, getDirective, MapperKind } from '@graphql-tools/utils';
import { defaultFieldResolver, GraphQLSchema } from 'graphql';
import { GraphQLError } from 'graphql';

const typeDefs = `
  directive @auth(
    requires: [Role!]!
  ) on FIELD_DEFINITION | OBJECT

  enum Role {
    ADMIN
    HR
    HR_ADMIN
    VIEWER
  }

  type User {
    id: ID!
    name: String!
    email: String! @auth(requires: [ADMIN, HR])
    salary: Float @auth(requires: [HR, HR_ADMIN])
    ssn: String @auth(requires: [HR_ADMIN])
  }

  type Query {
    user(id: ID!): User
    users: [User!]! @auth(requires: [HR, ADMIN])
  }
`;

function authDirectiveTransformer(schema: GraphQLSchema): GraphQLSchema {
  return mapSchema(schema, {
    [MapperKind.OBJECT_FIELD]: (fieldConfig) => {
      const authDirective = getDirective(schema, fieldConfig, 'auth')?.[0];
      if (!authDirective) return fieldConfig;

      const { requires } = authDirective as { requires: string[] };
      const { resolve = defaultFieldResolver } = fieldConfig;

      return {
        ...fieldConfig,
        resolve: async function (source, args, context, info) {
          const userRoles: string[] = context.roles ?? [];
          const hasRole = requires.some((r) => userRoles.includes(r));

          if (!hasRole) {
            // Return null for the field and add an error — caller sees partial data
            context.errors?.push(
              new GraphQLError(`Not authorized to access field: ${info.fieldName}`, {
                extensions: {
                  code: 'FORBIDDEN',
                  field: info.fieldName,
                  requires,
                },
              })
            );
            return null;
          }

          return resolve(source, args, context, info);
        },
      };
    },
  });
}

const schema = authDirectiveTransformer(
  makeExecutableSchema({ typeDefs, resolvers })
);
```

### ABAC in Resolvers — Ownership Check

```typescript
const resolvers = {
  Query: {
    order: async (_, { id }, context) => {
      const order = await orderLoader.load(id);
      if (!order) return null;

      // ABAC: user can only see their own orders, unless admin
      if (order.userId !== context.userId && !context.roles.includes('ADMIN')) {
        throw new GraphQLError('Not authorized to access this order', {
          extensions: { code: 'FORBIDDEN' },
        });
      }

      return order;
    },
  },

  Order: {
    // Field-level: payment details visible only to account owners and billing admins
    paymentMethod: async (order, _, context) => {
      if (
        order.userId !== context.userId &&
        !context.roles.includes('BILLING_ADMIN')
      ) {
        return null; // Silent null — payment method absence isn't sensitive
      }
      return order.paymentMethod;
    },
  },
};
```

### Authorization Middleware Pattern

For cross-cutting authorization that shouldn't repeat in every resolver:

```typescript
import { GraphQLError } from 'graphql';

function requireAuth(resolver: Function) {
  return async (source: unknown, args: unknown, context: any, info: any) => {
    if (!context.userId) {
      throw new GraphQLError('Authentication required', {
        extensions: { code: 'UNAUTHENTICATED' },
      });
    }
    return resolver(source, args, context, info);
  };
}

function requireRole(roles: string[]) {
  return (resolver: Function) =>
    async (source: unknown, args: unknown, context: any, info: any) => {
      if (!roles.some((r) => context.roles?.includes(r))) {
        throw new GraphQLError(`Requires role: ${roles.join(' or ')}`, {
          extensions: { code: 'FORBIDDEN', requires: roles },
        });
      }
      return resolver(source, args, context, info);
    };
}

const resolvers = {
  Query: {
    user: requireAuth(async (_, { id }, context) => {
      return userLoader.load(id);
    }),
    
    adminStats: requireRole(['ADMIN'])(async (_, __, context) => {
      return adminStatsService.get(context.tenantId);
    }),
  },
};
```

### PostgreSQL Row-Level Security (RLS)

RLS enforces tenant isolation at the database level — even if a resolver bug returns the wrong `WHERE` clause, the database filters it:

```sql
-- Enable RLS on the orders table
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

-- Tenants only see their own orders
CREATE POLICY orders_tenant_isolation ON orders
  FOR ALL
  USING (tenant_id = current_setting('app.tenant_id')::uuid);

-- Users can only see their own orders (unless admin role)
CREATE POLICY orders_user_isolation ON orders
  FOR SELECT
  USING (
    user_id = current_setting('app.user_id')::uuid
    OR current_setting('app.user_role') = 'admin'
  );
```

```typescript
// Set PostgreSQL session variables before each query:
async function getDbConnection(context: UserContext) {
  const client = await pool.connect();
  await client.query(`
    SELECT
      set_config('app.tenant_id', $1, true),
      set_config('app.user_id', $2, true),
      set_config('app.user_role', $3, true)
  `, [context.tenantId, context.userId, context.roles[0] ?? 'viewer']);
  return client;
}
```

### Multi-Subgraph Authorization

In federation, each subgraph owns its authorization. The Users subgraph authorizes access to user data; the Orders subgraph authorizes access to order data. They do not share authorization state directly.

```typescript
// Users subgraph — context function
async function buildContext({ req }) {
  return {
    userId: req.headers['x-user-id'],
    roles: JSON.parse(req.headers['x-user-roles'] || '[]'),
    tenantId: req.headers['x-tenant-id'],
    // Cache of checked permissions for this request (avoid re-checking same permission):
    permissionCache: new Map(),
  };
}

// Orders subgraph — context function (identical structure)
async function buildContext({ req }) {
  return {
    userId: req.headers['x-user-id'],
    roles: JSON.parse(req.headers['x-user-roles'] || '[]'),
    tenantId: req.headers['x-tenant-id'],
    permissionCache: new Map(),
  };
}
```

Both subgraphs receive the same trusted headers from the router and independently authorize their own data.

---

## Production Considerations

### Performance

Authorization checks in hot paths (fields resolved thousands of times per second) must be fast. Options:
- **Precompute permissions in context** — load all permission grants for the user once per request, not per field
- **Permission cache in context** — memoize authorization decisions within a request: `if (permissionCache.has(cacheKey)) return permissionCache.get(cacheKey)`
- **ABAC policies in Redis** — cache complex permission calculations with short TTL (30–60 seconds)

### Security

Authorization failures should surface as `FORBIDDEN` errors, not `UNAUTHENTICATED`. The distinction matters:
- `UNAUTHENTICATED`: no valid token present — client should redirect to login
- `FORBIDDEN`: valid token, insufficient permissions — client should show "access denied"

Never return 404 for security-sensitive resources (order IDs, user IDs). Return 403/FORBIDDEN — otherwise existence of the resource is leaked.

### Scaling

Authorization logic in resolvers is stateless and scales horizontally with the subgraph service. OPA authorization (covered in [04-opa-and-policy.md](04-opa-and-policy.md)) can be deployed as a sidecar, which keeps authorization latency under 5ms at scale.

### Observability

```typescript
// Log authorization decisions for audit trail:
logger.info('authorization_decision', {
  userId: context.userId,
  tenantId: context.tenantId,
  field: info.fieldName,
  operation: info.operation.name?.value,
  decision: hasRole ? 'allow' : 'deny',
  roles: context.roles,
  requires,
});
```

---

## Best Practices

1. **Authorize at the field level, not just root queries.** A root-level auth check on `user` doesn't protect fields inside `User` accessed via other paths (e.g., `order.customer.email`).
2. **Use the `@auth` directive pattern** to co-locate authorization rules with the schema definition.
3. **Apply PostgreSQL RLS as a backstop** — it catches authorization bugs that make it past resolver-level checks.
4. **Prefer explicit FORBIDDEN errors** over silent nulls for clearly sensitive fields. Clients need to know the difference between "no data" and "no access."
5. **Cache permission decisions within a request** — a single mutation can invoke the same auth check dozens of times.
6. **Audit authorization denials** — log every FORBIDDEN decision with user ID, resource, and required roles.

---

## Anti-Patterns

**Checking `context.userId` but not `context.roles`:** Being authenticated doesn't mean being authorized. Check both.

**Authorization in the data layer only:** If your only authorization is a `WHERE user_id = $1` clause, a bug that omits the WHERE clause leaks all data. Defense in depth means resolver-level checks AND database-level constraints.

**Sharing a resolver's authorization logic via comments:** Comments don't enforce anything. Authorization code must execute, not be described.

**Using `null` for all authorization failures:** Clients cannot distinguish "this user has no salary data" (legitimate null) from "you're not authorized to see salary" (authorization failure). Use error extensions for the latter.

---

## Operational Notes

**Debugging FORBIDDEN errors:** When a field returns null and `errors` contains FORBIDDEN, check: (1) Was the JWT validated and claims extracted correctly? (2) Are the `x-user-roles` headers set by the router? (3) Does the `@auth` directive's `requires` list match the claim exactly (case-sensitive)?

**Testing authorization:** Write one test per role per field for sensitive fields. Authorization logic has a combinatorial explosion of cases — table-driven tests help.

---

## References

- [GraphQL Authorization Patterns — Apollo Blog](https://www.apollographql.com/blog/authorization-in-graphql)
- [graphql-tools mapSchema](https://the-guild.dev/graphql/tools/docs/schema-directives)
- [PostgreSQL Row-Level Security](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
- [OWASP Broken Access Control](https://owasp.org/www-project-top-ten/2021/A01_2021-Broken_Access_Control/)

## Related Topics

- [02-authentication.md](02-authentication.md) — JWT validation and context building
- [04-opa-and-policy.md](04-opa-and-policy.md) — OPA for externalized policy enforcement
- [../13-policy-as-code/](../13-policy-as-code/) — schema-level policy at CI/CD time
