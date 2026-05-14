# Diagram Catalogue

> Index of all key Mermaid diagrams across the Enterprise GraphQL Engineering Handbook. When adding a significant diagram to a doc file, add an entry here.

For diagram style conventions and working examples, see [docs/assets/mermaid-style-guide.md](../assets/mermaid-style-guide.md).

---

## Convention

Each entry lists:
- **Diagram Name** — descriptive title
- **File** — relative path to the `.md` file containing the diagram
- **Type** — Mermaid diagram type
- **Description** — one sentence on what it shows

---

## Catalogue

| Diagram Name | File | Type | Description |
|---|---|---|---|
| Production GraphQL Platform | [ARCHITECTURE_OVERVIEW.md](../../ARCHITECTURE_OVERVIEW.md) | `flowchart LR` | Full platform: clients → CDN → router → subgraphs → data sources, with schema registry and observability stacks |
| Federated Query Execution | [ARCHITECTURE_OVERVIEW.md](../../ARCHITECTURE_OVERVIEW.md) | `sequenceDiagram` | Step-by-step sequence of how a federated query traverses the router and multiple subgraphs |
| Should I Use GraphQL? | [ARCHITECTURE_OVERVIEW.md](../../ARCHITECTURE_OVERVIEW.md) | `flowchart TD` | Decision tree for evaluating GraphQL adoption |
| Should I Use Federation? | [ARCHITECTURE_OVERVIEW.md](../../ARCHITECTURE_OVERVIEW.md) | `flowchart TD` | Decision tree for evaluating federation vs monolith GraphQL |
| Learning Track Overview | [LEARNING_ROADMAP.md](../../LEARNING_ROADMAP.md) | `flowchart TD` | How the 5 learning tracks relate and where they converge |
| Simple Federation Architecture | [docs/assets/mermaid-style-guide.md](../assets/mermaid-style-guide.md) | `flowchart LR` | Reference example: clients → router → subgraphs → databases |
| Query Execution Sequence | [docs/assets/mermaid-style-guide.md](../assets/mermaid-style-guide.md) | `sequenceDiagram` | Reference example: client → router → two subgraphs → assembled response |
| Schema Lifecycle State Machine | [docs/assets/mermaid-style-guide.md](../assets/mermaid-style-guide.md) | `stateDiagram-v2` | Reference example: schema change from Draft through Published to Removed |
| CI/CD Pipeline | [docs/assets/mermaid-style-guide.md](../assets/mermaid-style-guide.md) | `flowchart TD` | Reference example: PR → lint → compose → check → policy gate → publish |

---

## Adding a New Diagram

When you add a significant diagram to any doc file:

1. Test it at [mermaid.live](https://mermaid.live) to confirm it renders
2. Add a row to the table above: name, file path (relative from this file), type, description
3. Use the style conventions from [mermaid-style-guide.md](../assets/mermaid-style-guide.md) — especially the `classDef` color blocks
