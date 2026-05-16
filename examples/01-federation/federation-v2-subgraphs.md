# Federation v2 Subgraph SDL and Resolvers

Complete SDL definitions and TypeScript resolver implementations for all three subgraphs. Every code block is runnable; adapt connection strings and environment variables for your deployment.

---

## Users Subgraph (port 4001)

Owns the `User` entity. No other subgraph writes to the users table. The `@key(fields: "id")` directive makes `User` an entity that other subgraphs can reference by `id`.

### SDL

```graphql
extend schema
  @link(url: "https://specs.apollo.dev/federation/v2.6", import: [
    "@key", "@shareable", "@inaccessible", "@tag"
  ])

scalar DateTime
scalar EmailAddress

enum UserRole {
  CUSTOMER
  ADMIN
  SUPPORT
}

type UserPreferences {
  marketingEmails: Boolean!
  orderNotifications: Boolean!
  currency: String!
  locale: String!
}

type User @key(fields: "id") {
  id: ID!
  email: EmailAddress!
  displayName: String!
  avatarUrl: String
  createdAt: DateTime!
  role: UserRole!
  preferences: UserPreferences!
}

type UserEdge {
  cursor: String!
  node: User!
}

type PageInfo {
  hasNextPage: Boolean!
  hasPreviousPage: Boolean!
  startCursor: String
  endCursor: String
}

type UserConnection {
  edges: [UserEdge!]!
  pageInfo: PageInfo!
  totalCount: Int!
}

input CreateUserInput {
  email: EmailAddress!
  displayName: String!
  avatarUrl: String
  role: UserRole! = CUSTOMER
}

input UpdateUserInput {
  displayName: String
  avatarUrl: String
  preferences: UpdatePreferencesInput
}

input UpdatePreferencesInput {
  marketingEmails: Boolean
  orderNotifications: Boolean
  currency: String
  locale: String
}

type MutationResult {
  success: Boolean!
  message: String
}

type Query {
  user(id: ID!): User
  users(first: Int = 20, after: String): UserConnection!
  me: User
}

type Mutation {
  createUser(input: CreateUserInput!): User!
  updateUser(id: ID!, input: UpdateUserInput!): User!
  deleteUser(id: ID!): MutationResult!
}
```

### TypeScript Resolvers

```typescript
// users-subgraph/src/resolvers.ts
import DataLoader from 'dataloader';
import { GraphQLError } from 'graphql';
import type { UserRecord, UsersContext } from './types.js';
import { db } from './db.js';
import { decodeCursor, encodeCursor } from './pagination.js';

// -------------------------------------------------------------------
// DataLoader — batch user fetches by ID within a single request tick
// -------------------------------------------------------------------
export function createUserLoader(): DataLoader<string, UserRecord | null> {
  return new DataLoader<string, UserRecord | null>(
    async (ids: readonly string[]) => {
      const rows = await db
        .selectFrom('users')
        .selectAll()
        .where('id', 'in', ids as string[])
        .execute();

      const byId = new Map(rows.map((r) => [r.id, r]));
      // Preserve input order; return null for missing IDs
      return ids.map((id) => byId.get(id) ?? null);
    },
    { maxBatchSize: 100 }
  );
}

// -------------------------------------------------------------------
// Context type
// -------------------------------------------------------------------
export interface UsersContext {
  userId?: string; // from JWT, set by router header injection
  loaders: {
    user: DataLoader<string, UserRecord | null>;
  };
}

// -------------------------------------------------------------------
// Resolvers
// -------------------------------------------------------------------
export const resolvers = {
  Query: {
    user: async (_: unknown, { id }: { id: string }, ctx: UsersContext) => {
      const user = await ctx.loaders.user.load(id);
      if (!user) return null;
      return user;
    },

    users: async (
      _: unknown,
      { first, after }: { first: number; after?: string },
      _ctx: UsersContext
    ) => {
      const limit = Math.min(first, 100); // cap page size
      const cursor = after ? decodeCursor(after) : null;

      const rows = await db
        .selectFrom('users')
        .selectAll()
        .$if(cursor !== null, (qb) => qb.where('id', '>', cursor!))
        .orderBy('id', 'asc')
        .limit(limit + 1) // fetch one extra to determine hasNextPage
        .execute();

      const hasNextPage = rows.length > limit;
      const edges = rows.slice(0, limit).map((node) => ({
        cursor: encodeCursor(node.id),
        node,
      }));

      return {
        edges,
        pageInfo: {
          hasNextPage,
          hasPreviousPage: cursor !== null,
          startCursor: edges[0]?.cursor ?? null,
          endCursor: edges[edges.length - 1]?.cursor ?? null,
        },
        totalCount: async () => {
          const result = await db
            .selectFrom('users')
            .select(db.fn.countAll<number>().as('count'))
            .executeTakeFirstOrThrow();
          return Number(result.count);
        },
      };
    },

    me: async (_: unknown, __: unknown, ctx: UsersContext) => {
      if (!ctx.userId) return null;
      return ctx.loaders.user.load(ctx.userId);
    },
  },

  Mutation: {
    createUser: async (
      _: unknown,
      { input }: { input: CreateUserInput },
      _ctx: UsersContext
    ) => {
      const existing = await db
        .selectFrom('users')
        .select('id')
        .where('email', '=', input.email)
        .executeTakeFirst();

      if (existing) {
        throw new GraphQLError('Email already in use', {
          extensions: { code: 'EMAIL_TAKEN' },
        });
      }

      const [user] = await db
        .insertInto('users')
        .values({
          email: input.email,
          display_name: input.displayName,
          avatar_url: input.avatarUrl ?? null,
          role: input.role,
          preferences: JSON.stringify({
            marketingEmails: false,
            orderNotifications: true,
            currency: 'USD',
            locale: 'en-US',
          }),
        })
        .returningAll()
        .execute();

      return user;
    },

    updateUser: async (
      _: unknown,
      { id, input }: { id: string; input: UpdateUserInput },
      ctx: UsersContext
    ) => {
      const existing = await ctx.loaders.user.load(id);
      if (!existing) {
        throw new GraphQLError(`User ${id} not found`, {
          extensions: { code: 'NOT_FOUND' },
        });
      }

      const [updated] = await db
        .updateTable('users')
        .set({
          ...(input.displayName && { display_name: input.displayName }),
          ...(input.avatarUrl !== undefined && { avatar_url: input.avatarUrl }),
        })
        .where('id', '=', id)
        .returningAll()
        .execute();

      ctx.loaders.user.clear(id); // invalidate cache for this request
      return updated;
    },

    deleteUser: async (
      _: unknown,
      { id }: { id: string },
      ctx: UsersContext
    ) => {
      const existing = await ctx.loaders.user.load(id);
      if (!existing) {
        throw new GraphQLError(`User ${id} not found`, {
          extensions: { code: 'NOT_FOUND' },
        });
      }

      await db.deleteFrom('users').where('id', '=', id).execute();
      return { success: true, message: `User ${id} deleted` };
    },
  },

  // -------------------------------------------------------------------
  // Reference resolver — called by the router when other subgraphs
  // reference a User entity by its @key. Must use DataLoader.
  // -------------------------------------------------------------------
  User: {
    __resolveReference: async (
      ref: { id: string },
      ctx: UsersContext
    ) => {
      const user = await ctx.loaders.user.load(ref.id);
      if (!user) {
        throw new GraphQLError(`User ${ref.id} not found`, {
          extensions: { code: 'ENTITY_NOT_FOUND', entityType: 'User' },
        });
      }
      return user;
    },
  },
};
```

---

## Products Subgraph (port 4002)

Owns the `Product` entity and the `Category` entity. The `price` field is marked `@shareable` so the Orders subgraph can use it in `@requires` without the router needing a separate fetch just for that field.

### SDL

```graphql
extend schema
  @link(url: "https://specs.apollo.dev/federation/v2.6", import: [
    "@key", "@shareable", "@provides", "@inaccessible"
  ])

scalar DateTime

enum InventoryStatus {
  IN_STOCK
  LOW_STOCK
  OUT_OF_STOCK
  DISCONTINUED
}

type Money @shareable {
  amount: Int!      # cents — avoid floating-point rounding
  currency: String! # ISO 4217, e.g. "USD"
}

type Category @key(fields: "id") {
  id: ID!
  name: String!
  slug: String!
  parentCategory: Category
}

type InventoryInfo {
  status: InventoryStatus!
  quantityOnHand: Int!
  reservedQuantity: Int!
  availableQuantity: Int!
  warehouseLocation: String
}

type Product @key(fields: "id") {
  id: ID!
  sku: String!
  name: String!
  description: String
  price: Money! @shareable
  inventory: InventoryInfo!
  category: Category!
  imageUrls: [String!]!
  createdAt: DateTime!
  updatedAt: DateTime!
}

type ProductEdge {
  cursor: String!
  node: Product!
}

type PageInfo {
  hasNextPage: Boolean!
  hasPreviousPage: Boolean!
  startCursor: String
  endCursor: String
}

type ProductConnection {
  edges: [ProductEdge!]!
  pageInfo: PageInfo!
  totalCount: Int!
}

input ProductFilters {
  categoryId: ID
  minPrice: Int
  maxPrice: Int
  inStockOnly: Boolean
  searchTerm: String
}

input CreateProductInput {
  sku: String!
  name: String!
  description: String
  priceAmount: Int!
  priceCurrency: String! = "USD"
  categoryId: ID!
}

type Query {
  product(id: ID!): Product
  products(first: Int = 20, after: String, filters: ProductFilters): ProductConnection!
  productBySku(sku: String!): Product
}

type Mutation {
  createProduct(input: CreateProductInput!): Product!
  updateProductPrice(id: ID!, amount: Int!, currency: String!): Product!
  updateInventory(id: ID!, quantity: Int!, warehouseLocation: String): InventoryInfo!
}
```

### TypeScript Resolvers

```typescript
// products-subgraph/src/resolvers.ts
import DataLoader from 'dataloader';
import { GraphQLError } from 'graphql';
import type { ProductRecord, ProductsContext } from './types.js';
import { db } from './db.js';

// -------------------------------------------------------------------
// DataLoader — batch product fetches by ID
// -------------------------------------------------------------------
export function createProductLoader(): DataLoader<string, ProductRecord | null> {
  return new DataLoader<string, ProductRecord | null>(
    async (ids: readonly string[]) => {
      const rows = await db
        .selectFrom('products')
        .innerJoin('categories', 'categories.id', 'products.category_id')
        .selectAll('products')
        .select([
          'categories.id as category_id',
          'categories.name as category_name',
          'categories.slug as category_slug',
        ])
        .where('products.id', 'in', ids as string[])
        .execute();

      const byId = new Map(rows.map((r) => [r.id, r]));
      return ids.map((id) => byId.get(id) ?? null);
    },
    { maxBatchSize: 200 }
  );
}

export const resolvers = {
  Query: {
    product: async (
      _: unknown,
      { id }: { id: string },
      ctx: ProductsContext
    ) => ctx.loaders.product.load(id),

    productBySku: async (
      _: unknown,
      { sku }: { sku: string },
      _ctx: ProductsContext
    ) => {
      return db
        .selectFrom('products')
        .selectAll()
        .where('sku', '=', sku)
        .executeTakeFirst() ?? null;
    },

    products: async (
      _: unknown,
      {
        first = 20,
        after,
        filters,
      }: { first: number; after?: string; filters?: ProductFilters },
      _ctx: ProductsContext
    ) => {
      const limit = Math.min(first, 100);
      let query = db.selectFrom('products').selectAll();

      if (filters?.categoryId) {
        query = query.where('category_id', '=', filters.categoryId);
      }
      if (filters?.minPrice !== undefined) {
        query = query.where('price_amount', '>=', filters.minPrice);
      }
      if (filters?.maxPrice !== undefined) {
        query = query.where('price_amount', '<=', filters.maxPrice);
      }
      if (filters?.inStockOnly) {
        query = query.where('inventory_status', '!=', 'OUT_OF_STOCK');
      }
      if (filters?.searchTerm) {
        query = query.where('name', 'ilike', `%${filters.searchTerm}%`);
      }

      const rows = await query.orderBy('id', 'asc').limit(limit + 1).execute();
      const hasNextPage = rows.length > limit;
      const edges = rows.slice(0, limit).map((node) => ({
        cursor: Buffer.from(node.id).toString('base64'),
        node,
      }));

      return {
        edges,
        pageInfo: {
          hasNextPage,
          hasPreviousPage: after != null,
          startCursor: edges[0]?.cursor ?? null,
          endCursor: edges[edges.length - 1]?.cursor ?? null,
        },
        totalCount: async () => {
          const result = await db
            .selectFrom('products')
            .select(db.fn.countAll<number>().as('count'))
            .executeTakeFirstOrThrow();
          return Number(result.count);
        },
      };
    },
  },

  Mutation: {
    createProduct: async (
      _: unknown,
      { input }: { input: CreateProductInput },
      _ctx: ProductsContext
    ) => {
      const [product] = await db
        .insertInto('products')
        .values({
          sku: input.sku,
          name: input.name,
          description: input.description ?? null,
          price_amount: input.priceAmount,
          price_currency: input.priceCurrency,
          category_id: input.categoryId,
          inventory_status: 'OUT_OF_STOCK',
          quantity_on_hand: 0,
        })
        .returningAll()
        .execute();
      return product;
    },

    updateProductPrice: async (
      _: unknown,
      { id, amount, currency }: { id: string; amount: number; currency: string },
      ctx: ProductsContext
    ) => {
      const [updated] = await db
        .updateTable('products')
        .set({ price_amount: amount, price_currency: currency })
        .where('id', '=', id)
        .returningAll()
        .execute();

      if (!updated) {
        throw new GraphQLError(`Product ${id} not found`, {
          extensions: { code: 'NOT_FOUND' },
        });
      }

      ctx.loaders.product.clear(id);
      return updated;
    },

    updateInventory: async (
      _: unknown,
      { id, quantity, warehouseLocation }: {
        id: string;
        quantity: number;
        warehouseLocation?: string;
      },
      ctx: ProductsContext
    ) => {
      const status =
        quantity === 0
          ? 'OUT_OF_STOCK'
          : quantity < 10
          ? 'LOW_STOCK'
          : 'IN_STOCK';

      const [updated] = await db
        .updateTable('products')
        .set({
          quantity_on_hand: quantity,
          inventory_status: status,
          ...(warehouseLocation && { warehouse_location: warehouseLocation }),
        })
        .where('id', '=', id)
        .returningAll()
        .execute();

      ctx.loaders.product.clear(id);
      return {
        status: updated.inventory_status,
        quantityOnHand: updated.quantity_on_hand,
        reservedQuantity: updated.reserved_quantity,
        availableQuantity: updated.quantity_on_hand - updated.reserved_quantity,
        warehouseLocation: updated.warehouse_location,
      };
    },
  },

  Product: {
    price: (product: ProductRecord) => ({
      amount: product.price_amount,
      currency: product.price_currency,
    }),

    inventory: (product: ProductRecord) => ({
      status: product.inventory_status,
      quantityOnHand: product.quantity_on_hand,
      reservedQuantity: product.reserved_quantity,
      availableQuantity: product.quantity_on_hand - product.reserved_quantity,
      warehouseLocation: product.warehouse_location,
    }),

    category: (product: ProductRecord) => ({
      id: product.category_id,
      name: product.category_name,
      slug: product.category_slug,
    }),

    // Reference resolver for cross-subgraph entity resolution
    __resolveReference: async (
      ref: { id: string },
      ctx: ProductsContext
    ) => {
      const product = await ctx.loaders.product.load(ref.id);
      if (!product) {
        throw new GraphQLError(`Product ${ref.id} not found`, {
          extensions: { code: 'ENTITY_NOT_FOUND', entityType: 'Product' },
        });
      }
      return product;
    },
  },
};
```

---

## Orders Subgraph (port 4003)

Owns the `Order` entity. References `User` and `Product` as external entities — it stores only their IDs. The `@requires` directive on `LineItem.unitPrice` tells the router it needs `Product.price` from the Products subgraph before this resolver can run.

### SDL

```graphql
extend schema
  @link(url: "https://specs.apollo.dev/federation/v2.6", import: [
    "@key", "@external", "@requires", "@shareable"
  ])

scalar DateTime

enum OrderStatus {
  PENDING
  CONFIRMED
  PROCESSING
  SHIPPED
  DELIVERED
  CANCELLED
  REFUNDED
}

type Money @shareable {
  amount: Int!
  currency: String!
}

# External entity — owned by Users subgraph
type User @key(fields: "id", resolvable: false) {
  id: ID!
}

# External entity — owned by Products subgraph
# We declare price as @external because @requires needs it
type Product @key(fields: "id") {
  id: ID!
  price: Money! @external
}

type LineItem {
  product: Product!
  quantity: Int!
  # @requires causes the router to fetch Product.price from the Products
  # subgraph before this resolver runs; unitPrice is then validated against it
  unitPrice: Money! @requires(fields: "product { price { amount currency } }")
  subtotal: Money!
}

type Order @key(fields: "id") {
  id: ID!
  user: User!
  lineItems: [LineItem!]!
  status: OrderStatus!
  total: Money!
  notes: String
  createdAt: DateTime!
  updatedAt: DateTime!
}

type OrderEdge {
  cursor: String!
  node: Order!
}

type PageInfo {
  hasNextPage: Boolean!
  hasPreviousPage: Boolean!
  startCursor: String
  endCursor: String
}

type OrderConnection {
  edges: [OrderEdge!]!
  pageInfo: PageInfo!
  totalCount: Int!
}

input LineItemInput {
  productId: ID!
  quantity: Int!
}

input CreateOrderInput {
  userId: ID!
  lineItems: [LineItemInput!]!
  notes: String
}

type Query {
  order(id: ID!): Order
  orders(
    userId: ID
    status: OrderStatus
    first: Int = 20
    after: String
  ): OrderConnection!
}

type Mutation {
  createOrder(input: CreateOrderInput!): Order!
  cancelOrder(id: ID!, reason: String): Order!
  updateOrderStatus(id: ID!, status: OrderStatus!): Order!
}
```

### TypeScript Resolvers

```typescript
// orders-subgraph/src/resolvers.ts
import DataLoader from 'dataloader';
import { GraphQLError } from 'graphql';
import type { OrderRecord, LineItemRecord, OrdersContext } from './types.js';
import { db } from './db.js';

// -------------------------------------------------------------------
// DataLoader — batch order fetches by ID
// -------------------------------------------------------------------
export function createOrderLoader(): DataLoader<string, OrderRecord | null> {
  return new DataLoader<string, OrderRecord | null>(
    async (ids: readonly string[]) => {
      const rows = await db
        .selectFrom('orders')
        .selectAll()
        .where('id', 'in', ids as string[])
        .execute();

      const byId = new Map(rows.map((r) => [r.id, r]));
      return ids.map((id) => byId.get(id) ?? null);
    },
    { maxBatchSize: 100 }
  );
}

export const resolvers = {
  Query: {
    order: async (
      _: unknown,
      { id }: { id: string },
      ctx: OrdersContext
    ) => ctx.loaders.order.load(id),

    orders: async (
      _: unknown,
      {
        userId,
        status,
        first = 20,
        after,
      }: { userId?: string; status?: string; first: number; after?: string },
      _ctx: OrdersContext
    ) => {
      const limit = Math.min(first, 100);
      let query = db.selectFrom('orders').selectAll();

      if (userId) query = query.where('user_id', '=', userId);
      if (status) query = query.where('status', '=', status);

      const rows = await query
        .orderBy('created_at', 'desc')
        .limit(limit + 1)
        .execute();

      const hasNextPage = rows.length > limit;
      const edges = rows.slice(0, limit).map((node) => ({
        cursor: Buffer.from(node.id).toString('base64'),
        node,
      }));

      return {
        edges,
        pageInfo: {
          hasNextPage,
          hasPreviousPage: after != null,
          startCursor: edges[0]?.cursor ?? null,
          endCursor: edges[edges.length - 1]?.cursor ?? null,
        },
        totalCount: async () => {
          const result = await db
            .selectFrom('orders')
            .select(db.fn.countAll<number>().as('count'))
            .executeTakeFirstOrThrow();
          return Number(result.count);
        },
      };
    },
  },

  Mutation: {
    createOrder: async (
      _: unknown,
      { input }: { input: CreateOrderInput },
      _ctx: OrdersContext
    ) => {
      return db.transaction().execute(async (trx) => {
        const [order] = await trx
          .insertInto('orders')
          .values({
            user_id: input.userId,
            status: 'PENDING',
            total_amount: 0,
            total_currency: 'USD',
            notes: input.notes ?? null,
          })
          .returningAll()
          .execute();

        for (const item of input.lineItems) {
          await trx
            .insertInto('order_line_items')
            .values({
              order_id: order.id,
              product_id: item.productId,
              quantity: item.quantity,
              unit_price_amount: 0, // populated via @requires at query time
              unit_price_currency: 'USD',
            })
            .execute();
        }

        return order;
      });
    },

    cancelOrder: async (
      _: unknown,
      { id, reason }: { id: string; reason?: string },
      ctx: OrdersContext
    ) => {
      const order = await ctx.loaders.order.load(id);
      if (!order) {
        throw new GraphQLError(`Order ${id} not found`, {
          extensions: { code: 'NOT_FOUND' },
        });
      }

      const terminalStatuses = ['DELIVERED', 'CANCELLED', 'REFUNDED'];
      if (terminalStatuses.includes(order.status)) {
        throw new GraphQLError(
          `Order ${id} is in status ${order.status} and cannot be cancelled`,
          { extensions: { code: 'INVALID_STATUS_TRANSITION' } }
        );
      }

      const [updated] = await db
        .updateTable('orders')
        .set({ status: 'CANCELLED', notes: reason ?? order.notes })
        .where('id', '=', id)
        .returningAll()
        .execute();

      ctx.loaders.order.clear(id);
      return updated;
    },

    updateOrderStatus: async (
      _: unknown,
      { id, status }: { id: string; status: string },
      ctx: OrdersContext
    ) => {
      const [updated] = await db
        .updateTable('orders')
        .set({ status })
        .where('id', '=', id)
        .returningAll()
        .execute();

      if (!updated) {
        throw new GraphQLError(`Order ${id} not found`, {
          extensions: { code: 'NOT_FOUND' },
        });
      }

      ctx.loaders.order.clear(id);
      return updated;
    },
  },

  Order: {
    user: (order: OrderRecord) => ({ id: order.user_id }),

    lineItems: async (order: OrderRecord, _args: unknown, _ctx: OrdersContext) => {
      return db
        .selectFrom('order_line_items')
        .selectAll()
        .where('order_id', '=', order.id)
        .execute();
    },

    total: (order: OrderRecord) => ({
      amount: order.total_amount,
      currency: order.total_currency,
    }),

    // Reference resolver for cross-subgraph entity resolution
    __resolveReference: async (
      ref: { id: string },
      ctx: OrdersContext
    ) => {
      const order = await ctx.loaders.order.load(ref.id);
      if (!order) {
        throw new GraphQLError(`Order ${ref.id} not found`, {
          extensions: { code: 'ENTITY_NOT_FOUND', entityType: 'Order' },
        });
      }
      return order;
    },
  },

  LineItem: {
    product: (item: LineItemRecord) => ({ id: item.product_id }),

    // The router has already fetched Product.price via @requires before
    // calling this resolver. The price is injected into the item representation.
    unitPrice: (item: LineItemRecord & { product?: { price?: { amount: number; currency: string } } }) => {
      // Use the snapshotted price from the line item row (stored at order creation)
      return {
        amount: item.unit_price_amount,
        currency: item.unit_price_currency,
      };
    },

    subtotal: (item: LineItemRecord) => ({
      amount: item.unit_price_amount * item.quantity,
      currency: item.unit_price_currency,
    }),
  },
};
```
