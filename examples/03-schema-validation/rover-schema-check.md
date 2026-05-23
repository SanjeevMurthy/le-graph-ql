# Rover Schema Check

> Companion documentation: `../../docs/10-schema-validation/`
> Related example: `graphql-eslint-config.md` (style lint that runs before this step)

`rover subgraph check` is the authoritative breaking-change gate in the schema validation
pipeline. Unlike `graphql-inspector` which compares two SDL files structurally, Rover checks
the proposed schema against the GraphOS schema registry and correlates the diff with real
operation traffic. A field removal that is never queried by any registered client is classified
as NON_BREAKING, not BREAKING — this dramatically reduces false positives.

---

## How Rover Schema Check Works

1. Rover sends the proposed SDL to the GraphOS check service alongside the current registry SDL.
2. GraphOS computes the structural diff (same algorithm as graphql-inspector).
3. GraphOS correlates each changed field against the operation usage window (default: last 7 days
   of operation reports from connected clients).
4. GraphOS returns a structured list of changes, each tagged BREAKING, DANGEROUS, or NON_BREAKING.
5. If any BREAKING change exists, Rover exits with a non-zero status code.

The operation usage correlation is the key differentiator. An unused deprecated field that is
structurally removed is a BREAKING change structurally but NON_BREAKING operationally if no
client has queried it in the past 7 days.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| Rover CLI >= 0.24.0 | Install: `curl -sSL https://rover.apollo.dev/nix/latest \| sh` |
| `APOLLO_KEY` environment variable | API key from Apollo Studio. Format: `service:graph-name:hash` |
| Graph registered in Apollo GraphOS | At least one published SDL must exist for the check to compare against |
| Subgraph name matches the registry | The `--name` flag must exactly match the subgraph name in the supergraph |

---

## Basic rover subgraph check Invocation

```bash
# Minimal invocation — check the users subgraph against the @main variant.
# Rover reads APOLLO_KEY from the environment.
rover subgraph check my-graph@main \
  --name users \
  --schema subgraphs/users/schema.graphql

# Full invocation with all relevant flags.
rover subgraph check my-graph@main \
  --name users \
  --schema subgraphs/users/schema.graphql \
  --format json \                    # machine-readable output for CI parsing
  --validation-period 7d \           # compare against 7 days of operation traffic
                                     # (default is 7d; reduce to 1d for faster but noisier results)
  --query-count-threshold 1 \        # treat a field as "used" if queried >= 1 time
                                     # in the validation period; increase to ignore rare usage
  --query-count-threshold-percentage 1 # alternative: treat as used if >= 1% of total operations
                                     # use one of the two threshold flags, not both
```

Rover uses the `APOLLO_KEY` environment variable for authentication. Never pass the key via
`--api-key` on the command line — it will appear in process listings.

```bash
# Set the key for the current shell session only.
# In CI, use the secrets manager to inject this into the environment.
export APOLLO_KEY="service:my-graph:abc123xyz"
```

---

## Understanding the Check Output

### Text Output (default)

```
Checking the proposed schema for subgraph 'users' against my-graph@main ...

BREAKDOWN
---------
4 schema changes detected:

  BREAKING
  --------
  [1] FIELD_REMOVED: `User.legacyId` was removed.
      (removed field that may still be in use by existing clients)

  DANGEROUS
  ---------
  [2] ARG_DEFAULT_VALUE_CHANGE: `Query.users(limit:)` default value changed from `10` to `20`.
      (changing a default value may affect existing operations that rely on the old default)

  NON_BREAKING
  ------------
  [3] FIELD_ADDED: `User.displayName` was added.
  [4] OPTIONAL_ARG_ADDED: `Query.users(cursor:)` was added as an optional argument.


1 breaking change detected. The check failed.
```

### JSON Output (for CI parsing)

Passing `--format json` returns a structure like the following. The exact schema has evolved
across Rover versions — always pin to a specific Rover version in CI to avoid parse breakage.

```json
{
  "data": {
    "graph": {
      "variant": {
        "graphSchemaCheckStatus": {
          "status": "FAILED",
          "id": "chk_1234567890abcdef",
          "diffToBuild": {
            "changes": [
              {
                "severity": "BREAKING",
                "code": "FIELD_REMOVED",
                "description": "`User.legacyId` was removed.",
                "affectedClients": [
                  {
                    "name": "ios-app",
                    "operationCount": 1247
                  }
                ]
              },
              {
                "severity": "DANGEROUS",
                "code": "ARG_DEFAULT_VALUE_CHANGE",
                "description": "`Query.users(limit:)` default value changed from `10` to `20`.",
                "affectedClients": []
              },
              {
                "severity": "NON_BREAKING",
                "code": "FIELD_ADDED",
                "description": "`User.displayName` was added.",
                "affectedClients": []
              },
              {
                "severity": "NON_BREAKING",
                "code": "OPTIONAL_ARG_ADDED",
                "description": "`Query.users(cursor:)` was added as an optional argument.",
                "affectedClients": []
              }
            ]
          }
        }
      }
    }
  }
}
```

### Parsing the JSON Output with jq

```bash
# Save JSON output to a file for parsing.
rover subgraph check my-graph@main \
  --name users \
  --schema subgraphs/users/schema.graphql \
  --format json > rover-check-result.json 2>&1

# Count changes by severity.
BREAKING=$(jq '[.data.graph.variant.graphSchemaCheckStatus.diffToBuild.changes[]
  | select(.severity == "BREAKING")] | length' rover-check-result.json)

DANGEROUS=$(jq '[.data.graph.variant.graphSchemaCheckStatus.diffToBuild.changes[]
  | select(.severity == "DANGEROUS")] | length' rover-check-result.json)

NON_BREAKING=$(jq '[.data.graph.variant.graphSchemaCheckStatus.diffToBuild.changes[]
  | select(.severity == "NON_BREAKING")] | length' rover-check-result.json)

echo "Breaking: $BREAKING | Dangerous: $DANGEROUS | Non-Breaking: $NON_BREAKING"

# Extract just the descriptions of breaking changes (useful for PR comments).
jq -r '[.data.graph.variant.graphSchemaCheckStatus.diffToBuild.changes[]
  | select(.severity == "BREAKING")
  | .description] | .[]' rover-check-result.json

# Check the overall status string (PASSED or FAILED).
STATUS=$(jq -r '.data.graph.variant.graphSchemaCheckStatus.status' rover-check-result.json)
if [ "$STATUS" = "FAILED" ]; then
  echo "Schema check failed — $BREAKING breaking change(s) detected."
  exit 1
fi
```

---

## Async Mode with --background

For large schemas or high-traffic graphs, the GraphOS check service may take 60-120 seconds
to process operation usage data. Use `--background` mode to submit the check and poll for
results rather than blocking the CI job.

```bash
#!/usr/bin/env bash
# async-rover-check.sh
#
# Submits a rover subgraph check in background mode and polls until complete.
# Exits 0 on pass, 1 on fail or timeout.

set -euo pipefail

GRAPH_REF="${1:-my-graph@main}"
SUBGRAPH_NAME="${2:-users}"
SCHEMA_FILE="${3:-subgraphs/users/schema.graphql}"
POLL_INTERVAL_SECONDS=10
TIMEOUT_SECONDS=180    # fail after 3 minutes of waiting

# Submit the check and capture the check ID.
# --background causes rover to print the check ID and exit immediately
# rather than waiting for completion.
SUBMIT_OUTPUT=$(rover subgraph check "$GRAPH_REF" \
  --name "$SUBGRAPH_NAME" \
  --schema "$SCHEMA_FILE" \
  --background \
  --format json 2>&1)

CHECK_ID=$(echo "$SUBMIT_OUTPUT" | jq -r '.data.check_id // empty')

if [ -z "$CHECK_ID" ]; then
  echo "ERROR: Failed to parse check_id from rover output."
  echo "$SUBMIT_OUTPUT"
  exit 1
fi

echo "Check submitted. ID: $CHECK_ID"
echo "Polling every ${POLL_INTERVAL_SECONDS}s (timeout: ${TIMEOUT_SECONDS}s)..."

ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT_SECONDS" ]; do
  # Poll the check status using rover subgraph check-status.
  # (Available from rover 0.20.0+)
  POLL_OUTPUT=$(rover subgraph check-status "$GRAPH_REF" \
    --check-id "$CHECK_ID" \
    --format json 2>&1)

  STATUS=$(echo "$POLL_OUTPUT" | jq -r '.data.status // "PENDING"')

  echo "[${ELAPSED}s] Status: $STATUS"

  if [ "$STATUS" = "PASSED" ]; then
    echo "Check passed."
    exit 0
  elif [ "$STATUS" = "FAILED" ]; then
    echo "Check failed."
    # Print the breaking change descriptions for the CI log.
    echo "$POLL_OUTPUT" | jq -r \
      '[.data.changes[] | select(.severity == "BREAKING") | "  - " + .description] | .[]'
    exit 1
  fi

  # Status is still PENDING or RUNNING — wait and poll again.
  sleep "$POLL_INTERVAL_SECONDS"
  ELAPSED=$((ELAPSED + POLL_INTERVAL_SECONDS))
done

echo "ERROR: Timed out after ${TIMEOUT_SECONDS}s waiting for check to complete."
exit 1
```

---

## Multi-Subgraph Matrix Check

In a federated graph with many subgraphs, checks can be parallelized. The following pattern
runs one check per subgraph concurrently and waits for all of them to finish.

```bash
#!/usr/bin/env bash
# matrix-check.sh
#
# Runs rover subgraph check for all subgraphs in parallel.
# Reports per-subgraph pass/fail and exits 1 if any check fails.

set -uo pipefail

GRAPH_REF="${APOLLO_GRAPH_REF:-my-graph@main}"
SUBGRAPHS_DIR="subgraphs"
PIDS=()     # array of background process IDs
RESULTS=()  # array of result file paths

# Discover subgraphs by finding schema.graphql files.
# Each subgraph is named by its parent directory.
for schema_file in "${SUBGRAPHS_DIR}"/*/schema.graphql; do
  subgraph_name=$(basename "$(dirname "$schema_file")")
  result_file="/tmp/rover-check-${subgraph_name}.json"
  RESULTS+=("$result_file:$subgraph_name")

  # Run the check in the background; redirect all output to the result file.
  rover subgraph check "$GRAPH_REF" \
    --name "$subgraph_name" \
    --schema "$schema_file" \
    --format json \
    > "$result_file" 2>&1 &

  PIDS+=("$!")
  echo "Started check for subgraph '${subgraph_name}' (PID: $!)"
done

# Wait for all background processes to complete.
FAILED=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || FAILED=$((FAILED + 1))
done

echo ""
echo "--- Check Results ---"

# Print a summary line per subgraph.
for entry in "${RESULTS[@]}"; do
  result_file="${entry%%:*}"
  subgraph_name="${entry##*:}"

  if [ -f "$result_file" ]; then
    status=$(jq -r '.data.graph.variant.graphSchemaCheckStatus.status // "UNKNOWN"' \
      "$result_file" 2>/dev/null || echo "PARSE_ERROR")
    breaking=$(jq '[.data.graph.variant.graphSchemaCheckStatus.diffToBuild.changes[]
      | select(.severity == "BREAKING")] | length' "$result_file" 2>/dev/null || echo "?")
    echo "  ${subgraph_name}: ${status} (${breaking} breaking)"
  else
    echo "  ${subgraph_name}: NO RESULT FILE"
    FAILED=$((FAILED + 1))
  fi
done

if [ "$FAILED" -gt 0 ]; then
  echo ""
  echo "FAILURE: ${FAILED} subgraph check(s) failed."
  exit 1
fi

echo ""
echo "All subgraph checks passed."
exit 0
```

---

## Local Composition Check with rover supergraph compose

Before publishing any subgraph, verify that the full supergraph composes without errors.
Composition errors are caught here before they ever reach the GraphOS registry.

```yaml
# supergraph.yaml
# Configuration file for rover supergraph compose.
# Each entry lists a subgraph by name, its routing URL, and its local SDL file.
# The routing URL is used in the composed supergraph's router configuration —
# it must match the actual service URL reachable from the router.

federation_version: =2.5.0  # pin the federation version to avoid silent behavior changes

subgraphs:
  users:
    routing_url: https://users-service.internal/graphql
    schema:
      file: subgraphs/users/schema.graphql

  products:
    routing_url: https://products-service.internal/graphql
    schema:
      file: subgraphs/products/schema.graphql

  orders:
    routing_url: https://orders-service.internal/graphql
    schema:
      file: subgraphs/orders/schema.graphql
```

```bash
# Compose the supergraph locally and write the composed SDL to stdout.
rover supergraph compose --config supergraph.yaml

# Write the composed SDL to a file (useful as a CI artifact).
rover supergraph compose --config supergraph.yaml > supergraph-composed.graphql

# Compose and immediately check if the output is a valid GraphQL document.
# This catches federation directive errors that are not caught by subgraph check alone.
rover supergraph compose --config supergraph.yaml \
  | npx graphql-inspector validate --schema -  # read composed SDL from stdin
```

---

## rover subgraph introspect (for Running Servers)

In environments where you want to check the live schema from a running server rather than
a file, use `rover subgraph introspect` to fetch the SDL.

```bash
# Introspect a running Apollo Federation subgraph.
# The endpoint must expose the Apollo Federation service SDL at __ApolloGetServiceDefinition__.
# This is true for any server using @apollo/subgraph or apollo-server with federation.
rover subgraph introspect https://users-service-staging.internal/graphql

# Pipe directly into a check without writing a file.
rover subgraph introspect https://users-service-staging.internal/graphql \
  | rover subgraph check my-graph@staging \
    --name users \
    --schema -   # read from stdin

# With a custom header (e.g., internal auth).
rover subgraph introspect https://users-service-staging.internal/graphql \
  --header "X-Internal-Service-Token: $INTERNAL_TOKEN"
```

---

## rover.yaml — Custom Check Configuration

Create a `rover.yaml` file in the repository root to configure Rover behavior and set
graph-level defaults.

```yaml
# rover.yaml
#
# Per-project Rover configuration.
# This file is read automatically by rover CLI when run from the repo root.
# Reference: https://www.apollographql.com/docs/rover/configuring/

# Default graph ref used when --graph-ref is not passed.
# This prevents accidentally running checks against the wrong variant.
# Override per-environment in CI using the APOLLO_GRAPH_REF env var.
graph: my-graph@main

# Check configuration controlling which changes are flagged and how.
checks:
  # Number of past days of operation traffic to analyze.
  # 7 days is the default and a good balance between recency and coverage.
  # Increase for graphs with weekly usage patterns (e.g., business-hours-only tools).
  # Decrease (to 1-2 days) only if you have very high operation volume and are
  # confident that all clients query every field at least daily.
  validationPeriod: 7d

  # Minimum number of times a field must have been queried in the validation
  # period to be considered "in use". A value of 1 means any single query counts.
  # Increase (to 10 or 50) if you want to ignore very-low-usage fields as noise.
  queryCountThreshold: 1

  # Alternatively, specify a percentage threshold instead of an absolute count.
  # A field must account for at least this percentage of total operation count
  # to be considered "in use". Uncomment and set queryCountThreshold to 0 to use.
  # queryCountThresholdPercentage: 0.1  # 0.1% of all operations

  # List of operation IDs to exclude from the breaking change analysis.
  # Use this to exclude known-broken or intentionally-deprecated operations that
  # you are migrating clients away from. Get the operation ID from Apollo Studio.
  # excludeOperations:
  #   - "abc123def456"  # "GetLegacyUserProfile" operation from deprecated iOS 1.x

# Telemetry opt-out (optional).
# Set to true to disable anonymous usage data sent to Apollo.
telemetry:
  enabled: false
```

---

## Handling Breaking Changes in CI

When a check fails with breaking changes, the workflow should:

1. Post the list of breaking changes as a PR comment (see `../../examples/04-github-actions/`).
2. Block the merge via a required status check.
3. Provide an escape hatch: the change author can mark a breaking change as intentional in
   Apollo Studio, which will cause the next check run to pass for that specific change.

The "acknowledge breaking change" flow:
1. Go to Apollo Studio > Checks > [the failed check].
2. Click the breaking change.
3. Click "Override: Approve this change".
4. Re-run the CI check — Rover will see the approval and downgrade the change to NON_BREAKING.

Do not delete and re-create the check to bypass failures. The approval audit trail in Studio
is the evidence that a human consciously decided a breaking change was acceptable.

---

## Key Design Decisions

**Why Rover is the final gate, not the first.** Running graphql-eslint first is faster (no
network call) and catches a higher volume of issues (style, naming, descriptions). By the time
Rover runs, the schema is already structurally clean. This reduces Rover check time because
there are fewer diff items to analyze.

**Why use --format json in CI.** Text output is human-readable but fragile to parse with grep
or awk across Rover version changes. JSON output has a stable structure that can be extracted
with jq regardless of display formatting changes in future versions.

**Why pin the federation version in supergraph.yaml.** Federation 2.x has had multiple minor
versions with different composition behavior. Unpinned composition means a Rover upgrade
can change composition results silently. Pin explicitly and upgrade deliberately with a
changelog review.

**Why not use rover subgraph check with --watch.** The --watch flag re-runs the check every
time the schema file changes on disk. This is designed for local development feedback loops,
not CI. In CI, run a single check per commit for reproducibility.

---

## Related Documentation

- `../../docs/10-schema-validation/` — Full validation pipeline theory and design
- `../../docs/11-schema-registry/` — Apollo GraphOS registry concepts
- `graphql-eslint-config.md` — Lint step that runs before rover check
- `graphql-inspector-diff.md` — Offline diff alternative for pre-commit gates
- `../../examples/04-github-actions/schema-check-workflow.md` — CI workflow that wires all these commands together
