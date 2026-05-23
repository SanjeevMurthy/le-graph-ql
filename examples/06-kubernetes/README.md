# examples/06-kubernetes — Production Kubernetes Manifests for Apollo Federation

Complete, production-ready Kubernetes manifests for deploying Apollo Router and a GraphQL
subgraph in a real enterprise environment. Every resource in this directory is annotated
with intent — not just what each field does, but why it is set to its specific value for
a GraphQL workload.

---

## What is Covered

| File | Contents |
|------|----------|
| [router-deployment.md](./router-deployment.md) | All Kubernetes resources for Apollo Router: Namespace, ServiceAccount, ConfigMap, ExternalSecret, Deployment, Service, HPA, PDB, NetworkPolicy, ServiceMonitor |
| [hpa-config.md](./hpa-config.md) | Custom metrics HPA setup, Prometheus Adapter rules, KEDA ScaledObject alternative, subgraph VPA+HPA, scale behavior tuning |
| [subgraph-deployment.md](./subgraph-deployment.md) | Complete manifests for a Products subgraph with DataLoader-aware resource sizing, init containers, and drain-aware lifecycle hooks |

---

## Deployment Architecture

```
Internet
  └─ NGINX Ingress Controller (namespace: ingress)
       └─ Service: apollo-router (ClusterIP :4000)
            └─ Deployment: apollo-router (3–20 replicas)
                 ├─ Subgraph: products   (namespace: team-products, port 4001)
                 ├─ Subgraph: users      (namespace: team-users,    port 4001)
                 └─ Subgraph: orders     (namespace: team-orders,   port 4001)

Sidecars / infrastructure
  ├─ OPA sidecar (localhost:8181) — per router pod
  ├─ OpenTelemetry Collector (namespace: observability, port 4317)
  ├─ Prometheus (scrapes /metrics via ServiceMonitor)
  └─ Redis (namespace: redis, port 6379) — query plan cache
```

---

## Namespace Strategy

These manifests use the **shared platform + per-team subgraph** namespace strategy:

```
graphql-platform/   ← Apollo Router, shared config, ExternalSecrets
team-products/      ← Products subgraph (Catalog team)
team-users/         ← Users subgraph (Identity team)
team-orders/        ← Orders subgraph (Commerce team)
```

NetworkPolicy enforces that subgraph namespaces accept traffic only from
`graphql-platform`. Subgraph namespaces cannot communicate with each other.

---

## Applying Manifests

### kubectl (imperative, for review/debugging)

```bash
# Apply all router resources in dependency order
kubectl apply -f router-namespace.yaml
kubectl apply -f router-serviceaccount.yaml
kubectl apply -f router-configmap.yaml
kubectl apply -f router-externalsecret.yaml

# Wait for ExternalSecret to sync (creates the Kubernetes Secret)
kubectl wait externalsecret apollo-router-secrets \
  --namespace graphql-platform \
  --for=condition=Ready \
  --timeout=60s

# Apply the rest
kubectl apply -f router-deployment.yaml
kubectl apply -f router-service.yaml
kubectl apply -f router-hpa.yaml
kubectl apply -f router-pdb.yaml
kubectl apply -f router-networkpolicy.yaml
kubectl apply -f router-servicemonitor.yaml
```

### Helm (recommended for production)

The Helm chart in `examples/08-terraform/` wraps these manifests. Values are
environment-specific; the chart is promoted through environments with Helmfile.

```bash
# Install with production values
helm upgrade --install apollo-router ./charts/apollo-router \
  --namespace graphql-platform \
  --create-namespace \
  --values ./values/production.yaml \
  --set image.tag=v1.40.0 \
  --wait \
  --timeout 5m

# Rollback if health probes fail
helm rollback apollo-router --namespace graphql-platform
```

### ArgoCD (GitOps)

```yaml
# argocd-application.yaml (illustrative)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: apollo-router
  namespace: argocd
spec:
  project: graphql-platform
  source:
    repoURL: https://github.com/myorg/infra-platform
    targetRevision: main
    path: k8s/graphql-platform/router
  destination:
    server: https://kubernetes.default.svc
    namespace: graphql-platform
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## Prerequisites

- Kubernetes 1.28+ (stable HPA v2, Gateway API CRDs)
- [external-secrets operator](https://external-secrets.io/) installed cluster-wide
- [Prometheus Operator](https://github.com/prometheus-operator/prometheus-operator) for ServiceMonitor CRD
- AWS Secrets Manager (or substitute Vault / GCP Secret Manager — ExternalSecret `spec.provider` changes)
- AWS IAM OIDC provider configured for IRSA (or GCP Workload Identity equivalent)
- Prometheus Adapter (for custom metrics HPA) — see `hpa-config.md`

---

## Related Documentation

- [Chapter 15 — Kubernetes Deployment](../../docs/15-kubernetes-deployment/README.md)
- [Chapter 14 — Observability](../../docs/14-observability/README.md)
- [Chapter 08 — Supergraph Architecture](../../docs/08-supergraph-architecture/README.md)
- [examples/02-apollo-router](../02-apollo-router/) — full `router.yaml` configuration
- [examples/07-opa-policies](../07-opa-policies/) — OPA runtime authorization policies
