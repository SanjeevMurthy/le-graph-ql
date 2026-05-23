# Real-World GraphQL Platform Architectures — Example 14

Companion docs: `../../docs/23-production-case-studies/`, `../../docs/25-enterprise-patterns/`

---

## Why Case Studies Matter

Documentation written for tutorials optimizes for clarity of the individual concept. Production GraphQL platforms require understanding dozens of concepts simultaneously and making architectural trade-offs that depend on your specific organizational constraints: team size, budget, existing infrastructure, regulatory requirements, and where the business is in its growth curve.

The gap between "I understand GraphQL Federation" and "I can design a production federation platform for my organization" is a collection of decisions that tutorials rarely address: How many subgraphs is too many for a team of ten? When does Apollo GraphOS become worth the cost? How do you manage schema governance when ten teams are pushing changes? What happens to your federation setup during a database incident?

The three platform archetypes in this example are drawn from common patterns observed across many production GraphQL deployments. They are not case studies of specific companies but rather composite reference architectures that reflect the real trade-offs at each scale.

---

## Three Platform Archetypes

| Archetype | Team Size | Subgraph Count | Platform Team | Primary Constraint |
|---|---|---|---|---|
| Startup | ~50 engineers | 5-10 | 0 (distributed ownership) | Move fast, minimize operational overhead |
| Mid-size | ~150 engineers | 15-30 | 1-3 platform engineers | Balance autonomy and consistency |
| Large Enterprise | 500+ engineers | 50+ | 6-10 platform engineers | Governance, compliance, multi-region |

This example covers the startup and enterprise ends of the spectrum, plus a cross-cutting topic — migrating from REST — that applies at every scale.

---

## Files in This Example

| File | Description |
|---|---|
| `README.md` | This file. Overview, archetypes, and orientation. |
| `startup-platform.md` | Reference architecture for a startup GraphQL platform: 50 engineers, 5-10 subgraphs, no dedicated platform team. Covers team topology, technology stack, monorepo structure, schema governance, CI/CD, observability, and the most common startup GraphQL mistakes. |
| `enterprise-platform.md` | Reference architecture for a large enterprise: 500+ engineers, 50+ subgraphs, dedicated platform team of 8. Covers RACI ownership, multi-environment promotion, formal schema governance (RFC process), Backstage integration, security posture (persisted queries, OPA, mTLS), multi-region deployment, incident playbooks, and cost optimization. |
| `migration-from-rest.md` | How to migrate a REST API portfolio to GraphQL Federation incrementally using the strangler fig pattern. Covers wrapping REST in subgraphs, running REST and GraphQL in parallel, client migration strategy, REST deprecation mechanics, and common migration mistakes. |

---

## Related Documentation

- `../../docs/23-production-case-studies/` — Detailed analysis of production GraphQL patterns at various organizational scales, including failure post-mortems
- `../../docs/25-enterprise-patterns/` — Enterprise-specific patterns: multi-tenancy, compliance requirements, regulated industry considerations, and global deployment
- `../../docs/08-supergraph-architecture/` — Technical deep dive into Apollo Federation v2 supergraph architecture
- `../../docs/09-schema-governance/` — Schema RFC process, breaking change management, and deprecation workflows
- `../../docs/11-ci-cd-automation/` — Complete CI/CD pipeline patterns for GraphQL including Rover integration
