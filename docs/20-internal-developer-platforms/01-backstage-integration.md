# 01 — Backstage Integration

> **Purpose:** Backstage is the de facto open-source developer portal framework. For a GraphQL
> platform, it serves as the catalog layer of the IDP — the single place where every subgraph,
> its schema, its owner, its health status, and its documentation live. This document defines
> the catalog entity model for subgraphs, the custom Backstage plugins that surface
> GraphQL-specific capabilities (schema visualization powered by Rover CLI, interactive
> exploration, TechDocs auto-generation), the Software Templates that provision new subgraphs
> through the Scaffolder, and the entity autodiscovery configuration that keeps the catalog
> synchronized with GitHub without manual registration.

---

## Catalog Entity Model for GraphQL Subgraphs

Backstage's Software Catalog uses YAML entity descriptors committed to source repositories.
A GraphQL subgraph registration requires two entities: a `Component` that represents the
running service and an `API` that represents the GraphQL contract it publishes. These two
entity kinds serve different purposes and appear in different Backstage views.

### Component Entity — `spec.type: graphql-subgraph`

The `Component` entity describes the deployable service. The critical field is
`spec.type: graphql-subgraph` — a custom type value that Backstage renders with a
GraphQL-specific UI card (via the custom plugin described below) rather than the default
generic component view.

```yaml
# catalog-info.yaml — committed to the subgraph repository root
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: products-subgraph
  title: Products Subgraph
  description: |
    Product catalog domain — exposes Product, Category, and Money types.
    Owned by the Catalog team. Handles product search, detail pages, and
    pricing data. Backed by the PostgreSQL products database and the
    ElasticSearch search index.
  annotations:
    # Standard Backstage annotations
    backstage.io/source-location: url:https://github.com/myorg/products-subgraph
    backstage.io/techdocs-ref: dir:.
    github.com/project-slug: myorg/products-subgraph

    # CI integration — links to the most recent schema check run
    github.com/project-slug: myorg/products-subgraph

    # Prometheus rule for the "Subgraph Health" card
    prometheus.io/rule: |
      sum(rate(graphql_subgraph_requests_total{subgraph="products"}[5m]))

    # Platform-specific annotations consumed by the GraphQL Backstage plugin
    graphql-platform.myorg.com/subgraph-name: products
    graphql-platform.myorg.com/registry-url: https://api.apollographql.com
    graphql-platform.myorg.com/graph-ref: myorg-supergraph@current
    graphql-platform.myorg.com/template-version: "1.8.0"
    graphql-platform.myorg.com/golden-path-status: current  # current | drift | unknown

  tags:
    - graphql
    - subgraph
    - catalog-domain
    - typescript

  links:
    - url: https://studio.apollographql.com/graph/myorg-supergraph/subgraph/products
      title: Schema in GraphOS Studio
      icon: catalog
    - url: https://grafana.internal.myorg.com/d/subgraph-health?var-subgraph=products
      title: Health Dashboard
      icon: dashboard
    - url: https://myorg.atlassian.net/wiki/spaces/CATALOG/pages/graphql-products
      title: Architecture Decision Record
      icon: docs

spec:
  type: graphql-subgraph           # Custom type — triggers GraphQL plugin UI
  lifecycle: production
  owner: group:catalog-team
  system: graphql-supergraph

  # What APIs does this component provide? Points to the API entity below.
  providesApis:
    - products-graphql-api

  # Dependencies on other platform resources
  dependsOn:
    - resource:products-postgres-db
    - resource:elasticsearch-products-index
    - component:product-enrichment-service
```

### API Entity — GraphQL SDL as the Spec

The `API` entity stores the actual GraphQL SDL. Backstage renders SDL with syntax
highlighting by default when `spec.type: graphql` is set. The platform's custom plugin
extends this rendering to add interactive exploration and diff capabilities.

```yaml
---
apiVersion: backstage.io/v1alpha1
kind: API
metadata:
  name: products-graphql-api
  title: Products GraphQL API
  description: |
    Products subgraph schema. Provides the Product type, Category type,
    and root Query fields for product lookup and search. Part of the
    myorg-supergraph federated schema.
  annotations:
    backstage.io/source-location: url:https://github.com/myorg/products-subgraph/blob/main/src/schema.graphql
    graphql-platform.myorg.com/subgraph-name: products
  tags:
    - graphql
    - federated

spec:
  type: graphql
  lifecycle: production
  owner: group:catalog-team
  system: graphql-supergraph
  definition: |
    """
    A product in the catalog. This type is the @key entity for the
    products subgraph — other subgraphs can extend it with additional fields.
    """
    type Product @key(fields: "id") {
      id: ID!
      name: String!
      description: String
      price: Money!
      category: Category!
      tags: [String!]!
      "Whether this product is currently in stock and available for purchase."
      inStock: Boolean!
      """
      @deprecated(reason: "Use `price { amount }` instead. Removal: 2025-09-01.")
      """
      priceInCents: Int @deprecated(reason: "Use `price { amount }` instead")
    }

    type Category @key(fields: "id") {
      id: ID!
      name: String!
      slug: String!
      parent: Category
    }

    type Money {
      amount: Float!
      currency: String!
    }

    input ProductFilter {
      categoryId: ID
      inStockOnly: Boolean
      minPrice: Float
      maxPrice: Float
      tags: [String!]
    }

    type ProductEdge {
      node: Product!
      cursor: String!
    }

    type ProductConnection {
      edges: [ProductEdge!]!
      pageInfo: PageInfo!
      totalCount: Int!
    }

    type PageInfo {
      hasNextPage: Boolean!
      hasPreviousPage: Boolean!
      startCursor: String
      endCursor: String
    }

    extend type Query {
      "Look up a single product by ID."
      product(id: ID!): Product
      "Paginated product list with optional filtering."
      products(filter: ProductFilter, first: Int = 20, after: String): ProductConnection!
      "Full-text product search powered by ElasticSearch."
      searchProducts(query: String!, first: Int = 10): ProductConnection!
    }
```

### System Entity — The Supergraph

The platform team owns a single `System` entity that all subgraph components reference as
`spec.system`. This entity appears in Backstage as the parent system that groups all
subgraph components together.

```yaml
# Owned by platform team — committed to platform catalog repo, not subgraph repos
apiVersion: backstage.io/v1alpha1
kind: System
metadata:
  name: graphql-supergraph
  title: GraphQL Supergraph
  description: |
    The enterprise federated GraphQL API. Composed from all registered subgraphs
    and served by the Apollo Router cluster. All client applications query this
    supergraph endpoint — never individual subgraph endpoints directly.
  annotations:
    graphql-platform.myorg.com/router-url: https://api.internal.myorg.com/graphql
    graphql-platform.myorg.com/studio-url: https://studio.apollographql.com/graph/myorg-supergraph
  tags:
    - graphql
    - federation
    - platform
  links:
    - url: https://api.internal.myorg.com/graphql
      title: Supergraph Endpoint
    - url: https://studio.apollographql.com/graph/myorg-supergraph/explorer
      title: Apollo Studio Explorer
spec:
  owner: group:graphql-platform-team
  domain: platform
```

---

## Custom Backstage Plugin — GraphQL Subgraph Card

The default Backstage API entity view renders SDL as a code block. A dedicated plugin
provides the schema visualization, health metrics card, and golden-path status indicator
that make subgraph entities first-class citizens in the catalog.

### Plugin Architecture

```
packages/
  graphql-subgraph-plugin/
    src/
      index.ts                   # Plugin entrypoint, exports all components
      plugin.ts                  # createPlugin() call, route registration
      components/
        SubgraphHealthCard.tsx   # Request rate, error rate, p99 latency
        SchemaVisualizerCard.tsx # SDL with type graph — calls Rover in backend plugin
        GoldenPathStatusCard.tsx # Template version drift indicator
        DeprecationSummaryCard.tsx # Fields with active @deprecated directives
      api/
        graphqlPlatformApi.ts    # API client for the platform API (section 03)
        types.ts                 # TypeScript types generated from platform API SDL
    package.json
  graphql-subgraph-plugin-backend/
    src/
      index.ts
      router.ts                  # Express router for Rover CLI invocations
      roverService.ts            # Runs Rover CLI as a subprocess, caches SDL
```

### Backend Plugin — Rover CLI Integration

The Rover CLI runs server-side (in the Backstage backend plugin) because it requires the
`APOLLO_KEY` secret and makes outbound calls to the GraphOS API. It would be a security
violation to expose `APOLLO_KEY` to a browser plugin.

```typescript
// packages/graphql-subgraph-plugin-backend/src/roverService.ts
import { spawn } from 'child_process';
import { Logger } from 'winston';
import NodeCache from 'node-cache';

interface SubgraphSdl {
  sdl: string;
  fetchedAt: string;
  subgraphName: string;
  graphRef: string;
}

export class RoverService {
  private readonly cache: NodeCache;
  private readonly apolloKey: string;
  private readonly logger: Logger;

  constructor(apolloKey: string, logger: Logger) {
    this.apolloKey = apolloKey;
    this.logger = logger;
    // Cache SDL for 5 minutes — avoid hammering GraphOS API on every page load
    this.cache = new NodeCache({ stdTTL: 300, checkperiod: 60 });
  }

  async fetchSubgraphSdl(graphRef: string, subgraphName: string): Promise<SubgraphSdl> {
    const cacheKey = `${graphRef}:${subgraphName}`;
    const cached = this.cache.get<SubgraphSdl>(cacheKey);
    if (cached) return cached;

    const sdl = await this.runRover([
      'subgraph', 'fetch',
      graphRef,
      '--name', subgraphName,
      '--output', 'json',
    ]);

    const parsed = JSON.parse(sdl);
    const result: SubgraphSdl = {
      sdl: parsed.data.sdl,
      fetchedAt: new Date().toISOString(),
      subgraphName,
      graphRef,
    };

    this.cache.set(cacheKey, result);
    return result;
  }

  async fetchSupergraphSdl(graphRef: string): Promise<string> {
    const cacheKey = `supergraph:${graphRef}`;
    const cached = this.cache.get<string>(cacheKey);
    if (cached) return cached;

    const output = await this.runRover(['supergraph', 'fetch', graphRef, '--output', 'json']);
    const parsed = JSON.parse(output);
    const sdl = parsed.data.sdl as string;
    this.cache.set(cacheKey, sdl);
    return sdl;
  }

  private runRover(args: string[]): Promise<string> {
    return new Promise((resolve, reject) => {
      const chunks: Buffer[] = [];
      const errChunks: Buffer[] = [];

      const proc = spawn('rover', args, {
        env: { ...process.env, APOLLO_KEY: this.apolloKey },
      });

      proc.stdout.on('data', (chunk: Buffer) => chunks.push(chunk));
      proc.stderr.on('data', (chunk: Buffer) => errChunks.push(chunk));

      proc.on('close', code => {
        if (code !== 0) {
          const stderr = Buffer.concat(errChunks).toString();
          this.logger.error('Rover CLI failed', { args, code, stderr });
          reject(new Error(`rover ${args[0]} ${args[1]} exited ${code}: ${stderr}`));
        } else {
          resolve(Buffer.concat(chunks).toString());
        }
      });
    });
  }
}
```

### Backend Router

```typescript
// packages/graphql-subgraph-plugin-backend/src/router.ts
import { Router, Request, Response } from 'express';
import { RoverService } from './roverService';

export function createRouter(roverService: RoverService): Router {
  const router = Router();

  // GET /api/graphql-subgraph/sdl?graphRef=myorg@current&subgraph=products
  router.get('/sdl', async (req: Request, res: Response) => {
    const { graphRef, subgraph } = req.query as Record<string, string>;
    if (!graphRef || !subgraph) {
      return res.status(400).json({ error: 'graphRef and subgraph are required' });
    }

    try {
      const result = await roverService.fetchSubgraphSdl(graphRef, subgraph);
      return res.json(result);
    } catch (err) {
      return res.status(502).json({ error: (err as Error).message });
    }
  });

  // GET /api/graphql-subgraph/supergraph?graphRef=myorg@current
  router.get('/supergraph', async (req: Request, res: Response) => {
    const { graphRef } = req.query as Record<string, string>;
    if (!graphRef) {
      return res.status(400).json({ error: 'graphRef is required' });
    }

    try {
      const sdl = await roverService.fetchSupergraphSdl(graphRef);
      return res.json({ sdl, fetchedAt: new Date().toISOString() });
    } catch (err) {
      return res.status(502).json({ error: (err as Error).message });
    }
  });

  return router;
}
```

---

## TechDocs Auto-Generation from Subgraph README

Every scaffolded subgraph repository includes a `docs/` directory and `mkdocs.yml` that
Backstage's TechDocs pipeline renders into searchable, versioned documentation. The scaffold
generates the structure; subgraph teams fill in the content.

```yaml
# mkdocs.yml — generated by scaffold, committed to subgraph repository
site_name: Products Subgraph
site_description: Product catalog subgraph — schema, resolvers, runbooks
docs_dir: docs/

nav:
  - Overview: index.md
  - Schema Reference: schema.md
  - Resolver Guide: resolvers.md
  - DataLoader Patterns: dataloaders.md
  - Runbooks:
      - Deployment: runbooks/deployment.md
      - Incident Response: runbooks/incident.md
  - Changelog: CHANGELOG.md

plugins:
  - techdocs-core

extra:
  graphql_platform:
    subgraph_name: products
    graph_ref: myorg-supergraph@current
```

The `schema.md` file is auto-generated during CI using a custom script that renders the SDL
into Markdown tables:

```bash
# scripts/generate-schema-docs.sh
#!/usr/bin/env bash
set -euo pipefail

# Use graphql-markdown or a custom script to render SDL to Markdown
npx @graphql-markdown/docusaurus \
  ./src/schema.graphql \
  --output ./docs/schema.md \
  --homepage ./docs/schema-intro.md

echo "Schema docs generated at docs/schema.md"
```

---

## Scaffolder Templates for New Subgraph Provisioning

The Backstage Scaffolder provides a form-driven UI for creating new subgraphs. The template
validates inputs, runs pre-provisioning checks, creates the GitHub repository, registers the
catalog entity, and triggers the Terraform provisioning — all without CLI access.

```yaml
# backstage/templates/graphql-subgraph/template.yaml
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: graphql-subgraph-template
  title: GraphQL Subgraph
  description: Provision a new federated GraphQL subgraph with full golden-path setup
  tags:
    - graphql
    - subgraph
    - recommended
spec:
  owner: group:graphql-platform-team
  type: service

  parameters:
    - title: Subgraph Details
      required:
        - subgraphName
        - teamName
        - description
      properties:
        subgraphName:
          title: Subgraph Name
          type: string
          description: Lowercase, hyphenated. Example — products, order-history, user-accounts
          pattern: "^[a-z][a-z0-9-]{2,30}$"
          ui:autofocus: true
        teamName:
          title: Owning Team
          type: string
          description: Must match an existing Backstage Group entity
          ui:field: OwnerPicker
          ui:options:
            catalogFilter:
              kind: Group
        description:
          title: Description
          type: string
          description: What domain does this subgraph cover? Used in the catalog.
          ui:widget: textarea
          ui:options:
            rows: 3

    - title: Configuration
      properties:
        language:
          title: Implementation Language
          type: string
          enum:
            - typescript
            - kotlin
            - go
            - python
          default: typescript
        resourceTier:
          title: Resource Tier
          type: string
          enum:
            - small
            - medium
            - large
          default: small
          description: "small: 100m CPU/256Mi RAM. medium: 500m/1Gi. large: 1000m/2Gi"
        includeExamples:
          title: Include Example Resolvers
          type: boolean
          default: true
          description: Scaffold includes a working example query resolver and test

    - title: Review
      description: |
        Review the settings before provisioning. The scaffold will:
        - Create a GitHub repository in the myorg org
        - Provision Kubernetes namespace, ServiceAccount, and RBAC
        - Register the subgraph in GraphOS (staging slot)
        - Register the catalog entity in Backstage
        - Open an initial PR with the scaffold code

  steps:
    - id: validate-subgraph-name
      name: Validate Subgraph Name
      action: http:backstage:request
      input:
        method: GET
        path: /api/graphql-platform/validate?subgraphName={{ parameters.subgraphName }}

    - id: fetch-template
      name: Fetch Template
      action: fetch:template
      input:
        url: ./skeleton
        values:
          subgraphName: ${{ parameters.subgraphName }}
          teamName: ${{ parameters.teamName }}
          description: ${{ parameters.description }}
          language: ${{ parameters.language }}
          resourceTier: ${{ parameters.resourceTier }}
          includeExamples: ${{ parameters.includeExamples }}
          templateVersion: "1.8.0"

    - id: create-github-repo
      name: Create GitHub Repository
      action: publish:github
      input:
        allowedHosts: ['github.com']
        description: ${{ parameters.description }}
        repoUrl: github.com?owner=myorg&repo=${{ parameters.subgraphName }}-subgraph
        defaultBranch: main
        repoVisibility: internal
        topics:
          - graphql
          - subgraph
          - ${{ parameters.language }}
        gitCommitMessage: "chore: initial scaffold from graphql-subgraph-template@1.8.0"

    - id: register-catalog-entity
      name: Register in Backstage Catalog
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps['create-github-repo'].output.repoContentsUrl }}
        catalogInfoPath: '/catalog-info.yaml'

    - id: provision-infrastructure
      name: Provision Infrastructure
      action: http:backstage:request
      input:
        method: POST
        path: /api/graphql-platform/provision
        body:
          subgraphName: ${{ parameters.subgraphName }}
          teamName: ${{ parameters.teamName }}
          resourceTier: ${{ parameters.resourceTier }}
          githubRepo: myorg/${{ parameters.subgraphName }}-subgraph

  output:
    links:
      - title: GitHub Repository
        url: ${{ steps['create-github-repo'].output.remoteUrl }}
      - title: Catalog Entity
        icon: catalog
        entityRef: ${{ steps['register-catalog-entity'].output.entityRef }}
      - title: Schema in GraphOS (after first push)
        url: https://studio.apollographql.com/graph/myorg-supergraph/subgraph/${{ parameters.subgraphName }}
```

### Dry-Run Mode

The Scaffolder template supports a dry-run execution path. When `dryRun: true` is passed,
the template validates all parameters and prints what would be created — without calling
GitHub, Terraform, or the platform API.

```typescript
// The platform's provisioning API endpoint handles dry-run server-side
// POST /api/graphql-platform/provision
{
  "subgraphName": "inventory",
  "teamName": "warehouse",
  "resourceTier": "small",
  "githubRepo": "myorg/inventory-subgraph",
  "dryRun": true   // returns plan without applying
}

// Response:
{
  "dryRun": true,
  "plan": {
    "githubRepo": { "action": "create", "name": "myorg/inventory-subgraph" },
    "k8sNamespace": { "action": "reuse", "name": "team-warehouse", "reason": "namespace exists" },
    "serviceAccount": { "action": "create", "name": "inventory-subgraph" },
    "graphOsSlot": { "action": "reserve", "subgraph": "inventory", "variant": "staging" },
    "backstageCatalog": { "action": "register", "entityRef": "component:default/inventory-subgraph" }
  },
  "estimatedDurationSeconds": 240
}
```

---

## Entity Autodiscovery from GitHub

Manually committing `catalog-info.yaml` is a one-time action, but keeping the catalog
synchronized with the actual state of GitHub repositories requires autodiscovery. Backstage's
GitHub integration supports org-wide entity discovery via the `GithubEntityProvider`.

```typescript
// packages/backend/src/plugins/catalog.ts
import { CatalogBuilder } from '@backstage/plugin-catalog-backend';
import { GithubEntityProvider } from '@backstage/plugin-catalog-backend-module-github';
import { ScaffolderEntitiesProcessor } from '@backstage/plugin-scaffolder-backend';
import { Router } from 'express';
import { PluginEnvironment } from '../types';

export default async function createPlugin(env: PluginEnvironment): Promise<Router> {
  const builder = await CatalogBuilder.create(env);

  builder.addEntityProvider(
    GithubEntityProvider.fromConfig(env.config, {
      logger: env.logger,
      scheduler: env.scheduler,
    }),
  );

  builder.addProcessor(new ScaffolderEntitiesProcessor());

  const { processingEngine, router } = await builder.build();
  await processingEngine.start();
  return router;
}
```

```yaml
# app-config.yaml — Backstage configuration for GitHub autodiscovery
catalog:
  providers:
    github:
      myorg:
        organization: myorg
        catalogPath: '/catalog-info.yaml'   # Look for this file in every repo
        filters:
          branch: main
          repository: '.*-subgraph$'         # Only repositories ending in -subgraph
        schedule:
          frequency: { minutes: 30 }         # Re-scan every 30 minutes
          timeout: { minutes: 3 }
```

This configuration scans every repository in the `myorg` GitHub organization that matches
`.*-subgraph$` every 30 minutes, ingesting or updating any `catalog-info.yaml` found on the
`main` branch. New subgraph repositories created by the Scaffolder appear in the catalog
within 30 minutes of their first commit to `main`, without any manual registration step.

---

## Related Topics

- [Developer Portal Design](./02-developer-portal-design.md)
- [Platform APIs](./03-platform-apis.md)
- [Self-Service Infrastructure](../19-platform-engineering/03-self-service-infrastructure.md)
- [Golden Paths](../19-platform-engineering/02-golden-paths.md)
- [CI/CD Automation](../11-ci-cd-automation/README.md)

## References

- [Backstage Software Catalog](https://backstage.io/docs/features/software-catalog/)
- [Backstage Scaffolder Templates](https://backstage.io/docs/features/software-templates/)
- [Backstage TechDocs](https://backstage.io/docs/features/techdocs/)
- [GithubEntityProvider](https://backstage.io/docs/integrations/github/discovery)
- [Rover CLI — Subgraph Fetch](https://www.apollographql.com/docs/rover/commands/subgraphs/)
- [graphql-markdown](https://github.com/graphql-markdown/graphql-markdown)
