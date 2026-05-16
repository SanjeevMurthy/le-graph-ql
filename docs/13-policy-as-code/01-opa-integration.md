# 01 — OPA Integration for GraphQL Policy Enforcement

> **Purpose:** This document covers the full integration of Open Policy Agent (OPA) into a
> GraphQL platform — from architecture decisions through production deployment. It covers
> GraphQL-specific Rego patterns, conftest-based CI evaluation, bundle distribution at scale,
> policy testing strategy, versioning, and the tradeoffs between sidecar and centralized
> OPA deployment models. Every code example here is production-grade and intended to be
> adapted directly, not used as a starting point for a toy setup.

---

## Learning Objectives

After completing this document you will be able to:

- Explain how OPA's evaluation model maps to GraphQL's schema and request lifecycle
- Write Rego policies that evaluate GraphQL SDL and request documents
- Integrate OPA-based schema policy evaluation into a GitHub Actions CI pipeline using conftest
- Design a bundle distribution system for policy delivery across many OPA instances
- Write unit tests for Rego policies using `opa test` with full branch coverage
- Choose between sidecar and centralized OPA deployment for runtime authorization
- Version policies independently of application code and manage policy rollouts safely

---

## OPA Architecture Recap

OPA (Open Policy Agent) is a general-purpose policy engine that decouples policy decisions
from policy enforcement. Applications ask OPA a question ("can this user execute this query?")
by sending structured JSON input to a policy endpoint. OPA evaluates the input against a Rego
policy and returns a structured decision. The application enforces whatever decision OPA returns.

OPA's data model has three components:

**Input:** the question being asked — the data the application provides for OPA to evaluate.
For GraphQL, input is typically the request context: query document, variables, operation name,
authenticated identity, and any metadata from the router.

**Data:** background context OPA uses during evaluation — permission tables, allowlists, rate
limit budgets, or any other reference data. Data is loaded into OPA separately from input,
either from files (bundle), from a remote API (bundle server), or pushed via the Data API.

**Policy (Rego):** the rules that evaluate input against data to produce a decision. Rego is
a declarative, logic-based language. Rules define sets or objects; OPA evaluates which
elements belong to those sets given the current input and data.

### OPA Evaluation Model

```
Input (JSON)     +     Data (JSON)      →     Rego Evaluation     →     Decision (JSON)
{                      {                        package graphql             {
  "query": "...",        "allowed_ops": [...]    allow {                     "allow": true,
  "user": {...},         "rate_limits": {...}      input.user.role == ...    "reasons": []
  "operation": "..."   }                        }                         }
}
```

OPA is **stateless per evaluation** — it does not maintain session state between requests.
All state that affects a policy decision must be in `input` or `data`. This makes OPA
horizontally scalable and predictable: the same input always produces the same decision
given the same policy and data.

---

## OPA Integration Architecture

```mermaid
flowchart TD
    subgraph CI["CI Pipeline"]
        A([Schema SDL files\n*.graphql]) --> B[conftest pull\nbundle from registry]
        B --> C[conftest test\n--policy policy/rego/graphql]
        C --> D{Violations?}
        D -- deny set non-empty --> E([Fail CI\nannotate violations])
        D -- warn set non-empty --> F([Warn + continue\npost PR comment])
        D -- clean --> G([Proceed to\nschema registry check])
    end

    subgraph BUNDLE["Bundle Distribution"]
        H[Policy source repo\npolicy/rego/**] --> I[opa build\n--bundle output.tar.gz]
        I --> J[Sign bundle\ncosign sign-blob]
        J --> K[Upload to S3\nopa-bundles-prod/v1.2.3.tar.gz]
        K --> L[CloudFront CDN\nbundles.policy.example.com]
        L --> M[OPA sidecar\npolling every 60–300s]
        L --> B
    end

    subgraph ROUTER["GraphQL Router"]
        N([Client query]) --> O[Router receives request\nwith JWT / API key]
        O --> P[OPA sidecar\nlocalhost:8181]
        P --> Q{authz.allow?}
        Q -- false --> R([Return 403\nForbidden])
        Q -- true --> S[Complexity check\nOPA sidecar]
        S --> T{complexity.allow?}
        T -- false --> U([Return 400\nQuery too complex])
        T -- true --> V[Execute query\nsubgraph calls])
        V --> W([Return response])
    end

    subgraph OBS["Observability"]
        P --> X[Decision log\nKafka topic: opa-decisions]
        S --> X
        X --> Y[Decision log\nconsumer service]
        Y --> Z[BigQuery\ncompliance warehouse]
        Y --> AA[Prometheus metrics\nOPA decision counters]
        AA --> AB[Grafana dashboards]
    end

    M --> P

    classDef ciNode fill:#fff7ed,stroke:#f97316,color:#7c2d12
    classDef bundleNode fill:#fdf4ff,stroke:#a855f7,color:#581c87
    classDef routerNode fill:#f0fdf4,stroke:#22c55e,color:#14532d
    classDef obsNode fill:#f8fafc,stroke:#64748b,color:#1e293b

    class A,B,C,D,E,F,G ciNode
    class H,I,J,K,L,M bundleNode
    class N,O,P,Q,R,S,T,U,V,W routerNode
    class X,Y,Z,AA,AB obsNode
```

---

## GraphQL-Specific Rego Patterns

### Pattern 1: Evaluating SDL Input

conftest parses GraphQL SDL files and passes them as structured JSON to Rego policies.
The parsed SDL input has the following shape (simplified):

```json
{
  "Types": [
    {
      "Name": "User",
      "Kind": "OBJECT",
      "Description": "Represents an authenticated user in the system.",
      "Fields": [
        {
          "Name": "id",
          "Type": {"Name": "ID", "NonNull": true},
          "Description": "Unique identifier for the user.",
          "IsDeprecated": false,
          "DeprecationReason": null,
          "Directives": []
        },
        {
          "Name": "email",
          "Type": {"Name": "String", "NonNull": true},
          "Description": "",
          "IsDeprecated": false,
          "DeprecationReason": null,
          "Directives": []
        }
      ]
    }
  ]
}
```

Rego iterates over this structure using comprehensions:

```rego
# policy/rego/graphql/naming.rego
package graphql.naming

import future.keywords.in
import future.keywords.if
import future.keywords.contains
import future.keywords.every

# Helper: all user-defined object types (excludes built-ins starting with __)
object_types contains t if {
    some t in input.Types
    t.Kind == "OBJECT"
    not startswith(t.Name, "__")
}

# Violation: type name is not PascalCase
# PascalCase: starts with uppercase, no underscores, no all-caps acronyms > 2 chars
deny contains msg if {
    some t in object_types
    not is_pascal_case(t.Name)
    msg := sprintf(
        "Type '%s' violates naming convention: type names must be PascalCase (e.g. 'UserProfile', not 'user_profile' or 'USER_PROFILE'). See schema governance policy §3.1.",
        [t.Name]
    )
}

# Helper: validates PascalCase — starts with uppercase letter, only letters and digits
is_pascal_case(name) if {
    regex.match(`^[A-Z][a-zA-Z0-9]+$`, name)
}
```

### Pattern 2: Field-Level Authorization in Rego

Runtime authorization policies receive the GraphQL request as OPA input. The router
must extract and forward relevant context: the authenticated identity, the operation,
and the requested fields.

```rego
# policy/rego/runtime/authz.rego
package graphql.authz

import future.keywords.in
import future.keywords.if
import future.keywords.contains

# Default deny — explicit permit required
default allow := false

allow if {
    # Operation must be explicitly registered
    input.operation_name in data.allowed_operations[input.user.role]
    # No requested field exceeds the user's clearance level
    count(denied_fields) == 0
}

# Fields denied for the requesting user
denied_fields contains field if {
    some field in input.requested_fields
    field_clearance := data.field_sensitivity[field]
    user_clearance := data.clearance_levels[input.user.clearance]
    field_clearance > user_clearance
}

# Reason set — returned to the application for logging
reasons contains msg if {
    some field in denied_fields
    msg := sprintf("Field '%s' requires clearance level %d; user has level %d",
        [field, data.field_sensitivity[field], data.clearance_levels[input.user.clearance]])
}

reasons contains msg if {
    not input.operation_name in data.allowed_operations[input.user.role]
    msg := sprintf("Operation '%s' is not permitted for role '%s'",
        [input.operation_name, input.user.role])
}
```

The companion data document loaded into OPA:

```json
{
  "allowed_operations": {
    "admin": ["GetUser", "ListUsers", "UpdateUser", "DeleteUser", "GetAuditLog"],
    "operator": ["GetUser", "ListUsers"],
    "viewer": ["GetUser"]
  },
  "field_sensitivity": {
    "User.ssn": 3,
    "User.salary": 3,
    "User.email": 2,
    "User.name": 1,
    "User.id": 1
  },
  "clearance_levels": {
    "public": 1,
    "internal": 2,
    "restricted": 3
  }
}
```

### Pattern 3: Query Complexity Evaluation

Cost-based rate limiting evaluates the estimated cost of an incoming query document before
execution. OPA receives the parsed query as a tree structure and walks it to compute cost.

```rego
# policy/rego/runtime/complexity.rego
package graphql.complexity

import future.keywords.in
import future.keywords.if

default allow := false

# Maximum complexity budget per operation type
budget := {
    "query": 1000,
    "mutation": 500,
    "subscription": 200,
}

allow if {
    total_cost <= budget[input.operation_type]
}

# Total cost is the sum of field costs across all selections
total_cost := cost if {
    cost := sum([field_cost |
        some selection in input.selections
        field_cost := selection_cost(selection)
    ])
}

# Recursive cost calculation
selection_cost(sel) := cost if {
    base := object.get(data.field_costs, [sel.type_name, sel.field_name], 1)
    multiplier := object.get(sel, "list_multiplier", 1)
    children_cost := sum([selection_cost(child) | some child in sel.selections])
    cost := (base + children_cost) * multiplier
}

deny_reason := sprintf(
    "Query complexity %d exceeds budget %d for %s operations",
    [total_cost, budget[input.operation_type], input.operation_type]
) if {
    not allow
}
```

### Pattern 4: Deprecation Age Policy

```rego
# policy/rego/graphql/deprecation.rego
package graphql.deprecation

import future.keywords.in
import future.keywords.if
import future.keywords.contains

# Maximum age (days) a deprecated field may remain before removal is mandatory
max_deprecated_age_days := 180

# Minimum notice period (days) before a deprecated field may be removed
min_notice_days := 90

deny contains msg if {
    some t in input.Types
    some f in t.Fields
    f.IsDeprecated
    # Deprecation reason must contain an ISO 8601 date in YYYY-MM-DD format
    not regex.match(`\d{4}-\d{2}-\d{2}`, f.DeprecationReason)
    msg := sprintf(
        "Field '%s.%s' is deprecated but its deprecation reason does not include a deprecation date (YYYY-MM-DD format required). Policy §5.2 requires a removal date in all deprecation messages.",
        [t.Name, f.Name]
    )
}

deny contains msg if {
    some t in input.Types
    some f in t.Fields
    f.IsDeprecated
    deprecation_date := extract_date(f.DeprecationReason)
    deprecation_date != ""
    age_days := days_since(deprecation_date)
    age_days > max_deprecated_age_days
    msg := sprintf(
        "Field '%s.%s' has been deprecated for %d days (since %s), exceeding the maximum allowed age of %d days. This field must be removed or its deprecation policy renewed. Policy §5.3.",
        [t.Name, f.Name, age_days, deprecation_date, max_deprecated_age_days]
    )
}

warn contains msg if {
    some t in input.Types
    some f in t.Fields
    f.IsDeprecated
    deprecation_date := extract_date(f.DeprecationReason)
    deprecation_date != ""
    age_days := days_since(deprecation_date)
    age_days > (max_deprecated_age_days - 30)
    age_days <= max_deprecated_age_days
    msg := sprintf(
        "Field '%s.%s' has been deprecated for %d days and will exceed the maximum age of %d days in %d days. Plan for removal.",
        [t.Name, f.Name, age_days, max_deprecated_age_days, max_deprecated_age_days - age_days]
    )
}

# Extract first YYYY-MM-DD date from a string
extract_date(s) := date if {
    matches := regex.find_all_string_submatch_n(`(\d{4}-\d{2}-\d{2})`, s, 1)
    count(matches) > 0
    date := matches[0][1]
}

extract_date(s) := "" if {
    not regex.match(`\d{4}-\d{2}-\d{2}`, s)
}

# Compute days between ISO date string and today (requires OPA >= 0.55 for time.now_ns)
days_since(date_str) := days if {
    parts := split(date_str, "-")
    year  := to_number(parts[0])
    month := to_number(parts[1])
    day   := to_number(parts[2])
    date_ns := time.date([year, month, day, 0, 0, 0, "UTC"])
    now_ns := time.now_ns()
    days := round((now_ns - date_ns) / (24 * 60 * 60 * 1000000000))
}
```

---

## Integrating OPA Checks in CI with conftest

### GitHub Actions — Schema Policy Job

```yaml
# .github/workflows/schema-policy.yml
name: Schema Policy Check

on:
  pull_request:
    paths:
      - "**/*.graphql"
      - "**/*.graphqls"
      - "policy/rego/**"

permissions:
  contents: read
  pull-requests: write
  checks: write

jobs:
  schema-policy:
    name: OPA Schema Policies
    runs-on: ubuntu-24.04
    timeout-minutes: 10

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0   # Full history for deprecation date comparisons

      - name: Install conftest
        run: |
          CONFTEST_VERSION="0.51.0"
          curl -Lo conftest.tar.gz \
            "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_x86_64.tar.gz"
          tar xzf conftest.tar.gz conftest
          chmod +x conftest
          sudo mv conftest /usr/local/bin/conftest
          conftest --version

      - name: Install OPA CLI
        run: |
          OPA_VERSION="0.65.0"
          curl -Lo opa \
            "https://github.com/open-policy-agent/opa/releases/download/v${OPA_VERSION}/opa_linux_amd64_static"
          chmod +x opa
          sudo mv opa /usr/local/bin/opa
          opa version

      - name: Run Rego policy unit tests
        run: |
          opa test policy/rego/ \
            --verbose \
            --coverage \
            --format json \
            > opa-test-results.json
          # Check coverage threshold (95%)
          python3 - <<'EOF'
          import json, sys
          with open("opa-test-results.json") as f:
              results = json.load(f)
          coverage = results.get("coverage", 0)
          print(f"Policy coverage: {coverage:.1f}%")
          if coverage < 95:
              print(f"ERROR: Coverage {coverage:.1f}% is below required threshold of 95%")
              sys.exit(1)
          EOF

      - name: Pull policy bundle (if using remote bundle)
        env:
          BUNDLE_TOKEN: ${{ secrets.OPA_BUNDLE_TOKEN }}
        run: |
          conftest pull \
            --policy policy/rego \
            oci://ghcr.io/${{ github.repository_owner }}/graphql-policies:stable
        # Fall back to local policies if bundle pull is unavailable
        continue-on-error: false

      - name: Evaluate schema policies with conftest
        id: conftest
        run: |
          conftest test \
            --policy policy/rego/graphql \
            --namespace graphql \
            --output github \
            --no-color \
            $(find . -name "*.graphql" -o -name "*.graphqls" | grep -v node_modules) \
            2>&1 | tee conftest-output.txt
          echo "exit_code=${PIPESTATUS[0]}" >> "$GITHUB_OUTPUT"

      - name: Post policy violations as PR comment
        if: failure() && github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const output = fs.readFileSync('conftest-output.txt', 'utf8');
            const body = [
              '## Schema Policy Violations',
              '',
              'The following policy violations were detected by OPA + conftest:',
              '',
              '```',
              output.slice(0, 60000),  // GitHub comment size limit
              '```',
              '',
              'See [Policy as Code docs](docs/13-policy-as-code/README.md) for remediation guidance.',
            ].join('\n');
            await github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
              body,
            });

      - name: Upload conftest results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: conftest-results
          path: |
            conftest-output.txt
            opa-test-results.json
          retention-days: 30
```

### Running conftest Locally

```bash
# Install conftest
brew install conftest   # macOS
# or
curl -Lo conftest.tar.gz \
  https://github.com/open-policy-agent/conftest/releases/download/v0.51.0/conftest_0.51.0_Darwin_arm64.tar.gz
tar xzf conftest.tar.gz && sudo mv conftest /usr/local/bin/

# Run policies against all schema files
conftest test \
  --policy policy/rego/graphql \
  --namespace graphql \
  --output table \
  schema/**/*.graphql

# Run with a specific policy namespace only
conftest test \
  --policy policy/rego/graphql \
  --namespace graphql.naming \
  --output table \
  schema/user/schema.graphql

# Pull a remote bundle and test
conftest pull oci://ghcr.io/myorg/graphql-policies:v1.2.3
conftest test --policy policy/rego/graphql --output github schema/**/*.graphql
```

---

## OPA Bundle Distribution

Bundles allow policy updates to be deployed independently of application code. The bundle
is a `.tar.gz` archive containing Rego files and data documents, signed and distributed
via an HTTP server or OCI registry.

### Building and Publishing Bundles

```bash
#!/usr/bin/env bash
# scripts/publish-policy-bundle.sh
set -euo pipefail

BUNDLE_VERSION="${1:-$(git describe --tags --abbrev=0)}"
BUNDLE_NAME="graphql-policies"
OUTPUT_DIR="dist/bundles"
OCI_REGISTRY="ghcr.io/myorg"

mkdir -p "${OUTPUT_DIR}"

echo "Building OPA bundle v${BUNDLE_VERSION}..."

# Build the bundle — compiles Rego for faster evaluation
opa build \
  --bundle policy/rego \
  --output "${OUTPUT_DIR}/${BUNDLE_NAME}-${BUNDLE_VERSION}.tar.gz" \
  --capabilities "$(opa capabilities --current)" \
  --optimize 1

echo "Running bundle self-test..."
opa test \
  "${OUTPUT_DIR}/${BUNDLE_NAME}-${BUNDLE_VERSION}.tar.gz" \
  --verbose

echo "Signing bundle..."
# Requires cosign installed and COSIGN_KEY env var set
cosign sign-blob \
  --key env://COSIGN_KEY \
  --output-signature "${OUTPUT_DIR}/${BUNDLE_NAME}-${BUNDLE_VERSION}.sig" \
  "${OUTPUT_DIR}/${BUNDLE_NAME}-${BUNDLE_VERSION}.tar.gz"

echo "Pushing bundle to OCI registry..."
# oras is the OCI artifact push tool
oras push \
  "${OCI_REGISTRY}/${BUNDLE_NAME}:${BUNDLE_VERSION}" \
  --manifest-config /dev/null:application/vnd.oci.image.config.v1+json \
  "${OUTPUT_DIR}/${BUNDLE_NAME}-${BUNDLE_VERSION}.tar.gz:application/vnd.openpolicyagent.bundle.v1+tar+gzip" \
  "${OUTPUT_DIR}/${BUNDLE_NAME}-${BUNDLE_VERSION}.sig:application/vnd.dev.cosign.simplesigning.v1+json"

# Update stable tag to point to this version
oras tag \
  "${OCI_REGISTRY}/${BUNDLE_NAME}:${BUNDLE_VERSION}" \
  "${OCI_REGISTRY}/${BUNDLE_NAME}:stable"

echo "Bundle v${BUNDLE_VERSION} published successfully."
```

### OPA Sidecar Kubernetes Deployment

```yaml
# k8s/opa-sidecar-patch.yaml
# Applied via Kustomize patch to add OPA sidecar to the router deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: graphql-router
spec:
  template:
    spec:
      initContainers:
        # Verify bundle signature before OPA starts
        - name: bundle-verify
          image: gcr.io/projectsigstore/cosign:v2.2.3
          command:
            - sh
            - -c
            - |
              cosign verify-blob \
                --key /etc/cosign/cosign.pub \
                --signature /bundle/graphql-policies.sig \
                /bundle/graphql-policies.tar.gz
          volumeMounts:
            - name: bundle-volume
              mountPath: /bundle
            - name: cosign-key
              mountPath: /etc/cosign
              readOnly: true

      containers:
        - name: opa
          image: openpolicyagent/opa:0.65.0-static
          args:
            - run
            - --server
            - --addr=localhost:8181
            - --config-file=/etc/opa/config.yaml
            - --log-format=json
            - --log-level=info
          ports:
            - containerPort: 8181
              name: opa-http
            - containerPort: 9090
              name: opa-metrics
          volumeMounts:
            - name: opa-config
              mountPath: /etc/opa
              readOnly: true
            - name: opa-bundle-token
              mountPath: /var/run/secrets/opa
              readOnly: true
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
          livenessProbe:
            httpGet:
              path: /health
              port: 8181
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /health?bundles=true
              port: 8181
            initialDelaySeconds: 5
            periodSeconds: 5

      volumes:
        - name: opa-config
          configMap:
            name: opa-config
        - name: opa-bundle-token
          secret:
            secretName: opa-bundle-credentials
        - name: bundle-volume
          emptyDir: {}
        - name: cosign-key
          secret:
            secretName: cosign-public-key
```

### OPA ConfigMap

```yaml
# k8s/opa-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: opa-config
  namespace: graphql-platform
data:
  config.yaml: |
    services:
      bundle-server:
        url: https://ghcr.io
        type: oci
        credentials:
          bearer:
            token_path: /var/run/secrets/opa/token

    bundles:
      graphql-policies:
        service: bundle-server
        resource: myorg/graphql-policies:stable
        polling:
          min_delay_seconds: 60
          max_delay_seconds: 300

    decision_logs:
      console: false
      plugin: kafka-sink

    plugins:
      kafka-sink:
        topic: opa-decisions-graphql
        brokers: kafka.internal.example.com:9092
        tls:
          ca_cert: /etc/ssl/certs/kafka-ca.crt

    status:
      console: false

    distributed_tracing:
      type: grpc
      address: otel-collector.observability.svc.cluster.local:4317
      service_name: opa-graphql-sidecar
```

---

## Policy Testing with opa test

Every Rego policy file must have a corresponding `_test.rego` file. OPA's built-in test
runner evaluates rules whose names begin with `test_`. Tests use the `with` keyword to
provide controlled input and data, and assert expected rule values.

### Naming Policy Tests

```rego
# policy/rego/graphql/naming_test.rego
package graphql.naming

import future.keywords.if

# --- Type naming tests ---

test_pascal_case_type_passes if {
    count(deny) == 0 with input as {
        "Types": [{
            "Name": "UserProfile",
            "Kind": "OBJECT",
            "Fields": []
        }]
    }
}

test_snake_case_type_fails if {
    count(deny) == 1 with input as {
        "Types": [{
            "Name": "user_profile",
            "Kind": "OBJECT",
            "Fields": []
        }]
    }
}

test_all_caps_type_fails if {
    count(deny) == 1 with input as {
        "Types": [{
            "Name": "USERPROFILE",
            "Kind": "OBJECT",
            "Fields": []
        }]
    }
}

test_internal_type_ignored if {
    # Types starting with __ are GraphQL introspection types; skip them
    count(deny) == 0 with input as {
        "Types": [{
            "Name": "__Schema",
            "Kind": "OBJECT",
            "Fields": []
        }]
    }
}

# --- Field naming tests ---

test_camel_case_field_passes if {
    count(deny) == 0 with input as {
        "Types": [{
            "Name": "User",
            "Kind": "OBJECT",
            "Fields": [{
                "Name": "firstName",
                "Type": {"Name": "String", "NonNull": false},
                "Description": "The user's given name.",
                "IsDeprecated": false,
                "DeprecationReason": null
            }]
        }]
    }
}

test_snake_case_field_fails if {
    some msg in deny
    contains(msg, "first_name") with input as {
        "Types": [{
            "Name": "User",
            "Kind": "OBJECT",
            "Fields": [{
                "Name": "first_name",
                "Type": {"Name": "String", "NonNull": false},
                "Description": "The user's given name.",
                "IsDeprecated": false,
                "DeprecationReason": null
            }]
        }]
    }
}

# --- Interface and enum naming ---

test_interface_pascal_case_passes if {
    count(deny) == 0 with input as {
        "Types": [{
            "Name": "Auditable",
            "Kind": "INTERFACE",
            "Fields": []
        }]
    }
}

test_enum_value_all_caps_passes if {
    count(deny) == 0 with input as {
        "Types": [{
            "Name": "UserRole",
            "Kind": "ENUM",
            "EnumValues": [
                {"Name": "ADMIN"},
                {"Name": "VIEWER"},
                {"Name": "OPERATOR"}
            ]
        }]
    }
}

test_enum_value_camel_case_fails if {
    count(deny) > 0 with input as {
        "Types": [{
            "Name": "UserRole",
            "Kind": "ENUM",
            "EnumValues": [
                {"Name": "admin"},
                {"Name": "viewer"}
            ]
        }]
    }
}
```

### Running Tests with Coverage

```bash
# Run all policy tests
opa test policy/rego/ --verbose

# Run with coverage report
opa test policy/rego/ --coverage --format pretty

# Run tests for a specific package
opa test policy/rego/graphql/naming.rego policy/rego/graphql/naming_test.rego --verbose

# Run and fail if coverage drops below threshold
opa test policy/rego/ --coverage --format json | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
cov = data.get('coverage', 0)
print(f'Coverage: {cov:.1f}%')
sys.exit(0 if cov >= 95 else 1)
"

# Benchmark a specific rule (useful for hot-path policies)
opa bench \
  --data policy/rego/runtime/authz.rego \
  --data policy/data/authz-data.json \
  --input policy/test/fixtures/authz-input.json \
  'data.graphql.authz.allow'
```

---

## Policy Versioning

Policies are versioned independently of the application. A policy change that causes
previously-passing schemas to fail is a breaking change — it requires a major version bump,
a communication plan, and a grace period.

### Versioning Strategy

```
v1.0.0  — Initial naming conventions, documentation requirements
v1.1.0  — Add deprecation age policy (warn only)
v1.2.0  — Graduate deprecation age to error; add complexity budget policy (warn only)
v2.0.0  — Breaking: stricter naming regex rejects single-letter type names
```

### Policy Changelog File

```markdown
# Policy Changelog

## v1.2.0 — 2025-11-01

### Added
- `graphql.complexity`: field complexity budget policy (warn only)
  - Default budget: query=1000, mutation=500, subscription=200
  - Customize via `data.complexity_overrides` in the bundle data document

### Changed
- `graphql.deprecation`: deprecation age policy graduated from `warn` to `deny`
  - Fields deprecated for > 180 days now block CI
  - Warning threshold: 150 days (30-day advance notice)

### Migration
Teams with fields deprecated > 180 days must either:
1. Remove the field (preferred)
2. Submit an exception request via PLAT-xxxx template (grants 60-day extension)

## v1.1.0 — 2025-08-15
...
```

### Bundle Pinning in CI

```yaml
# In subgraph team CI, pin to a specific policy bundle version
- name: Pull policy bundle
  run: |
    conftest pull oci://ghcr.io/myorg/graphql-policies:v1.2.0
    # Verify the pulled bundle matches expected digest
    conftest verify \
      --policy policy/rego \
      --certificate /etc/ssl/certs/policy-signing-cert.pem \
      oci://ghcr.io/myorg/graphql-policies:v1.2.0
```

---

## OPA Sidecar vs Centralized Deployment

### Sidecar Model

Each router or server pod runs an OPA process as a sidecar container. Policy requests
are made over `localhost` or a Unix socket — no network hop, minimal latency.

**Advantages:**
- Sub-millisecond evaluation latency for synchronous request authorization
- No single point of failure — each pod's OPA is independent
- Bundle polling provides eventual consistency; pods update policies independently
- Easy to correlate OPA logs with application logs (same pod, same trace ID)

**Disadvantages:**
- OPA resource consumption multiplies by pod count (memory for Rego AST + data)
- Bundle download happens N times in parallel on rollout (thundering herd at scale)
- Policy updates are not instantaneous — all pods converge within bundle polling interval

**Use when:** Latency is critical, the cluster has fewer than 500 router pods, and you
can accept eventual-consistency semantics for policy updates.

### Centralized Deployment

A dedicated OPA service (or cluster of replicas) handles all policy evaluation requests
over HTTP/gRPC. Router and server instances make outbound calls to the OPA service.

**Advantages:**
- Single place to update policies — all clients pick up changes immediately
- Easier to audit — all decisions flow through one service with one log stream
- Resource-efficient — one OPA cluster instead of N sidecars

**Disadvantages:**
- Network latency: 5–20ms per evaluation, added to every request path
- Single point of failure — requires high-availability deployment with load balancing
- Complex failure handling — what does the application do when OPA is unavailable?
  (fail-open vs. fail-closed decision required upfront)

**Use when:** Strong consistency is required (policy changes must take immediate effect),
the environment has strict resource budgets, or the platform team cannot manage sidecar
injection across all workloads.

### Hybrid: Sidecar for Hot Path, Centralized for Audit

```
Client request
  └─ Router
      ├─ OPA sidecar  ──→  authz.allow  (synchronous, <1ms)
      └─ OPA sidecar  ──→  complexity.allow  (synchronous, <1ms)
            │
            └─ Async decision log  ──→  Kafka  ──→  OPA Central  (audit, compliance reporting)
```

The sidecar handles synchronous authorization; an async pipeline ships decision logs to
a central OPA instance used exclusively for compliance queries and dashboards. This avoids
the latency cost of centralized evaluation in the hot path while maintaining a complete,
centralized audit record.

---

## Production Considerations

### Performance

- Profile all hot-path policies with `opa bench` before production deployment
- Pre-compile bundles with `opa build --optimize 1` — reduces evaluation time by 30–60%
- Load background data via the Data API, not as `import data.x` with HTTP calls in Rego
- Cache OPA decisions in the router for identical (operation, user role) pairs with a 5s TTL
  to reduce sidecar call rate under repeated identical requests

### Security

- Enforce bundle signature verification in OPA config — without it, a compromised CDN
  could serve malicious policy
- Restrict the OPA HTTP API in sidecar mode: bind to `localhost` only, not `0.0.0.0`
- Use mTLS for all communication between the application and a centralized OPA service
- Treat the `data` document as trusted but not secret — do not store credentials or keys
  in OPA data; use environment variables or secrets mounts

### Reliability

- Set `bundles.on_start_wait_until_ready: true` in OPA config when using the sidecar model
  — this prevents the router container from accepting traffic before the first bundle load
- Implement a circuit breaker between the router and the OPA sidecar — if OPA fails to
  respond within 5ms, the circuit opens and the router falls back to a fail-closed or
  fail-open default as defined by the security team
- Monitor `opa_bundle_last_successful_request` Prometheus metric — alert if this metric
  has not updated within `max_delay_seconds + 60` seconds

---

## Best Practices

1. Co-locate `_test.rego` files next to policy files — do not separate them into a test
   directory. OPA's test runner discovers them automatically and co-location enforces
   the discipline that every policy has tests.

2. Use `future.keywords` imports — `import future.keywords.in`, `import future.keywords.if`,
   `import future.keywords.contains` — for forward-compatible Rego syntax. OPA 1.0 makes
   these mandatory.

3. Define a `warn` set alongside every `deny` set. Policies start in warn mode, graduate
   to error mode. The set pattern works identically — only the CI pipeline changes whether
   it fails on `deny` or `warn`.

4. Keep Rego rules single-purpose. One rule per violation type. Multi-condition rules that
   check multiple properties simultaneously produce confusing violation messages and are
   harder to test exhaustively.

5. Use `sprintf` for all violation messages. Raw string concatenation produces inconsistent
   output that is harder to parse programmatically. Structured messages with field names
   and policy references are actionable.

---

## References

- [OPA Documentation](https://www.openpolicyagent.org/docs/latest/)
- [Rego Language Reference](https://www.openpolicyagent.org/docs/latest/policy-language/)
- [conftest Documentation](https://www.conftest.dev/)
- [OPA Bundle API](https://www.openpolicyagent.org/docs/latest/management-bundles/)
- [opa test Reference](https://www.openpolicyagent.org/docs/latest/cli/#opa-test)
- [OPA Performance Tuning](https://www.openpolicyagent.org/docs/latest/policy-performance/)
- [OPA Sidecar Deployment Pattern](https://www.openpolicyagent.org/docs/latest/deployments/)
- [cosign — Sigstore Signing](https://docs.sigstore.dev/cosign/overview/)
- [oras — OCI Registry AS Storage](https://oras.land/docs/)

---

## Related Topics

- [Policy as Code Overview](./README.md)
- [Schema Policies in Rego](./02-schema-policies.md)
- [Schema Governance](../../09-schema-governance/README.md)
- [Schema Validation](../../10-schema-validation/README.md)
- [GitHub Actions](../../12-github-actions/README.md)
- [Security](../../05-security/README.md)
