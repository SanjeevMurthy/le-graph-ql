# Schema Coverage Analysis

Companion doc: [Chapter 10 — Schema Validation](../../docs/10-schema-validation/README.md)

Schema coverage analysis correlates every field in the schema against actual client usage.
Fields with zero usage across all known operations are deprecation candidates. Fields with
high usage are hot paths that justify caching and performance investment.

---

## Coverage Concept

Coverage answers: "For each field in the schema, how many of our known operations use it?"

- **100% coverage** — every field is used. Rare. Usually means the schema is well-pruned.
- **Low coverage on a new type** — could mean a feature flag is keeping clients from using
  the type yet, or the type was added speculatively.
- **Zero coverage on an old type** — strong signal for deprecation. Verify against runtime
  data before removing.
- **Zero coverage on a field in a widely-used type** — the field was probably added for a
  use case that never materialized.

---

## Static Coverage with graphql-inspector

Static coverage is computed from the operation corpus in the source tree — no server
required. Fast, runnable in CI.

```bash
# Basic coverage against local schema
npx graphql-inspector coverage \
  'src/**/*.graphql' \
  schema.graphql

# Output to JSON for downstream processing
npx graphql-inspector coverage \
  'src/**/*.graphql' \
  schema.graphql \
  --format json \
  > coverage-report.json
```

### Reading the JSON output

```json
{
  "types": {
    "Query": {
      "hits": 45,
      "fields": {
        "user":          { "hits": 12, "children": { "id": 12, "email": 8, "role": 3 } },
        "product":       { "hits": 8,  "children": { "id": 8,  "name": 8, "price": 6 } },
        "adminReport":   { "hits": 0,  "children": {} }
      }
    },
    "Product": {
      "hits": 20,
      "fields": {
        "id":            { "hits": 20 },
        "name":          { "hits": 20 },
        "price":         { "hits": 15 },
        "description":   { "hits": 6  },
        "legacyCode":    { "hits": 0  }
      }
    }
  }
}
```

---

## Runtime Coverage from Apollo Studio

Static coverage covers the operation corpus in source. Runtime coverage covers what actually
executed in production — essential for validating that source coverage is representative.

### Exporting usage data from Apollo Studio

Apollo Studio tracks field-level usage. Export it using the Apollo Platform API:

```bash
# Fetch field usage stats for the past 30 days
curl -s \
  -H "x-api-key: ${APOLLO_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "query FieldUsage($id: ID!, $from: Timestamp!, $to: Timestamp!) { service(id: $id) { stats(from: $from, to: $to) { fieldStats { groupBy { parentType field } metrics { fieldHistogram { durationNs { p99 } } referenceCount } } } } }",
    "variables": {
      "id": "my-graph@production",
      "from": "-2592000",
      "to": "-0"
    }
  }' \
  https://graphql.api.apollographql.com/api/graphql \
  | jq '.data.service.stats[0].fieldStats' \
  > studio-field-usage.json
```

### Finding zero-runtime-usage fields

```bash
# Fields with 0 reference count across the 30-day window
jq '[.[] | select(.metrics.referenceCount == 0) | "\(.groupBy.parentType).\(.groupBy.field)"]' \
  studio-field-usage.json
```

---

## Combined Coverage Report

This Node.js script joins static (graphql-inspector) coverage with runtime (Studio) usage
data and produces a markdown report showing fields by risk level.

```javascript
// scripts/coverage-report.js
// Usage: node scripts/coverage-report.js > COVERAGE.md

const fs = require('fs');

const staticCoverage = JSON.parse(fs.readFileSync('coverage-report.json', 'utf8'));
const runtimeUsage = JSON.parse(fs.readFileSync('studio-field-usage.json', 'utf8'));

// Build runtime lookup: "TypeName.fieldName" -> referenceCount
const runtimeMap = {};
for (const entry of runtimeUsage) {
  const key = `${entry.groupBy.parentType}.${entry.groupBy.field}`;
  runtimeMap[key] = entry.metrics.referenceCount ?? 0;
}

const rows = [];

for (const [typeName, typeData] of Object.entries(staticCoverage.types)) {
  // Skip introspection types
  if (typeName.startsWith('__')) continue;

  for (const [fieldName, fieldData] of Object.entries(typeData.fields ?? {})) {
    const key = `${typeName}.${fieldName}`;
    const staticHits = fieldData.hits ?? 0;
    const runtimeHits = runtimeMap[key] ?? null;

    let risk;
    if (staticHits === 0 && (runtimeHits === null || runtimeHits === 0)) {
      risk = 'DEAD';          // safe to deprecate
    } else if (staticHits === 0 && runtimeHits > 0) {
      risk = 'UNTRACKED';     // runtime usage not reflected in source corpus
    } else if (staticHits > 0 && (runtimeHits === null || runtimeHits === 0)) {
      risk = 'UNRELEASED';    // in source but no runtime traffic yet
    } else {
      risk = 'ACTIVE';
    }

    rows.push({ key, staticHits, runtimeHits, risk });
  }
}

// Sort: DEAD first, then UNTRACKED, UNRELEASED, ACTIVE
const riskOrder = { DEAD: 0, UNTRACKED: 1, UNRELEASED: 2, ACTIVE: 3 };
rows.sort((a, b) => riskOrder[a.risk] - riskOrder[b.risk]);

// Emit markdown table
const lines = [
  '# Schema Coverage Report',
  '',
  `Generated: ${new Date().toISOString()}`,
  '',
  '| Field | Static Hits | Runtime Refs (30d) | Risk |',
  '|-------|-------------|-------------------|------|',
];

for (const row of rows) {
  const runtime = row.runtimeHits === null ? 'N/A' : row.runtimeHits.toLocaleString();
  lines.push(`| \`${row.key}\` | ${row.staticHits} | ${runtime} | **${row.risk}** |`);
}

const dead = rows.filter(r => r.risk === 'DEAD').length;
const untracked = rows.filter(r => r.risk === 'UNTRACKED').length;
const active = rows.filter(r => r.risk === 'ACTIVE').length;

lines.push('', '## Summary', '');
lines.push(`- Active fields: ${active}`);
lines.push(`- Dead fields (deprecation candidates): ${dead}`);
lines.push(`- Untracked fields (missing from operation corpus): ${untracked}`);

console.log(lines.join('\n'));
```

---

## Coverage Thresholds in CI

Fail the build if a newly added type or field has zero coverage in the operations corpus.
This prevents speculative schema additions that no client ever uses.

```bash
# scripts/check-new-field-coverage.sh
# Called in CI after operations extraction and coverage analysis.
# Fails if any field added in this PR has 0 static hits.

set -euo pipefail

# Get fields added in this PR
ADDED_FIELDS=$(git diff origin/main...HEAD -- '**/*.graphql' \
  | grep '^+' \
  | grep -v '^+++' \
  | grep -E '^\+\s+\w+' \
  | sed 's/^+//' \
  | grep -v '@deprecated' \
  || true)

if [[ -z "${ADDED_FIELDS}" ]]; then
  echo "No new fields detected — coverage check skipped."
  exit 0
fi

# Check coverage report for zero-hit new fields
UNCOVERED=$(jq -r '
  .types | to_entries[] |
  .key as $type |
  .value.fields | to_entries[] |
  select(.value.hits == 0) |
  "\($type).\(.key)"
' coverage-report.json)

FAILURES=0
while IFS= read -r field; do
  if echo "${UNCOVERED}" | grep -qF "${field}"; then
    echo "::error::New field ${field} has zero coverage in the operations corpus."
    echo "  Add at least one operation that uses this field before merging."
    FAILURES=$((FAILURES + 1))
  fi
done <<< "${ADDED_FIELDS}"

if [[ "${FAILURES}" -gt 0 ]]; then
  exit 1
fi

echo "All new fields have operations coverage."
```

---

## Dead Field Deprecation Workflow

A structured process for safely removing zero-coverage fields:

```
Step 1 — Identify (automated, weekly CI report)
  graphql-inspector coverage + Studio export → COVERAGE.md
  Fields with DEAD risk → deprecation candidates list

Step 2 — Annotate (manual, PR)
  Add @deprecated(reason: "No known usages. Planned removal: <date 90 days out>")
  to each candidate field.

Step 3 — Monitor (90-day window)
  Studio field usage dashboard continues tracking.
  If any runtime hits appear during the window, remove from candidates list.

Step 4 — Remove (PR, after 90 days)
  Delete the deprecated field from the subgraph SDL.
  Run: graphql-inspector validate to confirm no operations reference it.
  Rover check will flag as BREAKING — apply approved-breaking-change label.

Step 5 — Deploy
  Normal schema publish workflow.
```

---

## Hot Field Identification

Fields with the highest runtime usage are the most important to protect and optimize.

### PromQL for field execution count (requires OTel instrumentation)

```promql
# Top 10 most-executed fields in the last 24 hours
topk(10,
  sum by (graphql_field_parent_type, graphql_field_name) (
    increase(graphql_field_executions_total[24h])
  )
)
```

### What to do with hot fields

| Hit rate | Action |
|----------|--------|
| >10K req/min on a scalar | Candidate for entity caching (set short TTL) |
| >1K req/min on a resolver with DB query | Mandatory DataLoader batching review |
| >100 req/min on a computed field | Profile resolver, consider memoization |
| High variance in latency | Add `@cacheControl(maxAge: N)` hint |

---

## Key Design Decisions

**Why combine static and runtime coverage rather than using one or the other?**
Static coverage reflects the current source tree including unreleased features. Runtime
coverage reflects what's actually executing in production. A field can appear in both, only
one, or neither. The combination gives a complete picture: `DEAD` (absent from both) is the
only truly safe deprecation signal.

**Why use a 90-day deprecation window?** Mobile clients cannot update immediately — App
Store review and user upgrade rates mean an old version of the app can be in active use
for months. 90 days gives enough time for the P95 mobile client population to update.
The Studio field usage report will show exactly when the last request using the deprecated
field occurred.

**Why fail CI for new fields with zero coverage?** It prevents the schema from growing with
speculative additions. Every field added to a public schema has a cost: it must be
documented, governed, supported, and eventually deprecated. Making coverage a gate forces
engineers to think "which client will use this?" before adding to the schema.

---

## Related Documentation

- [Chapter 10 — Schema Validation](../../docs/10-schema-validation/README.md)
- [Chapter 34 — Cost Optimization](../../docs/34-cost-optimization/README.md)
- [Chapter 09 — Schema Governance](../../docs/09-schema-governance/README.md)
- [examples/03-schema-validation](../03-schema-validation/) — lint and Rover check setup
- [examples/04-github-actions](../04-github-actions/) — CI workflows that run coverage checks
