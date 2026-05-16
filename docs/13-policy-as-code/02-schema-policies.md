# 02 — Schema Policies in Rego

> **Purpose:** This document provides production-ready Rego policy implementations for every
> common GraphQL schema design policy — naming conventions, required documentation, deprecation
> lifecycle, field complexity budgets, schema size limits, and forbidden field name patterns.
> Each policy is written for evaluation by conftest in CI, with full unit test suites and
> a complete GitHub Actions workflow that runs them on every schema-affecting pull request.
> Adapt these policies to your organization's conventions; do not copy them blindly without
> reviewing the thresholds and regex patterns for your context.

---

## Learning Objectives

After completing this document you will be able to:

- Write Rego policies that enforce camelCase field names and PascalCase type names on GraphQL SDL
- Implement a required documentation policy that blocks undocumented types and fields from CI
- Enforce deprecation lifecycle policies that track deprecation age and require removal timelines
- Define and evaluate field complexity budgets that prevent expensive schema patterns from shipping
- Set schema size limits that prevent unbounded type system growth
- Detect and block forbidden field name patterns that expose security or compliance risks
- Run all policies in GitHub Actions CI with annotations, PR comments, and structured reporting
- Write complete unit tests for every policy rule using `opa test`

---

## Policy Architecture Overview

All policies in this document follow a consistent Rego structure:

```
package graphql.<policy_name>

# --- Configuration ---
# Constants, thresholds, and regex patterns

# --- Helper rules ---
# Reusable intermediate computations

# --- deny set ---
# Blocking violations that fail CI

# --- warn set ---
# Advisory violations that post warnings but do not fail CI
```

Each policy package is evaluated by conftest using the `--namespace graphql` flag, which
collects `deny` and `warn` sets from all packages under the `graphql.*` hierarchy.

---

## Policy 1 — Naming Conventions

GraphQL naming conventions enforce consistency across a distributed schema. Without automated
enforcement, different teams write `userId`, `user_id`, `UserID`, and `user_id` for the same
concept across subgraphs, breaking client expectations and composability.

### Rules

| Target | Convention | Example |
|---|---|---|
| Object / interface / union types | PascalCase | `UserProfile`, `OrderLineItem` |
| Input types | PascalCase, `Input` suffix | `CreateUserInput`, `UpdateOrderInput` |
| Enum types | PascalCase | `UserRole`, `PaymentStatus` |
| Enum values | SCREAMING_SNAKE_CASE | `ACTIVE_USER`, `PAYMENT_PENDING` |
| Field names | camelCase, no leading underscore | `firstName`, `createdAt` |
| Query fields | verb + noun (camelCase) | `getUser`, `listOrders`, `searchProducts` |
| Mutation fields | imperative verb + noun | `createUser`, `deleteOrder`, `publishPost` |
| Subscription fields | noun or noun phrase | `orderStatusChanged`, `newMessage` |
| Argument names | camelCase | `userId`, `pageSize`, `filterBy` |

```rego
# policy/rego/graphql/naming.rego
package graphql.naming

import future.keywords.in
import future.keywords.if
import future.keywords.contains
import future.keywords.every

# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────

# GraphQL built-in scalars and introspection types — never check these
builtin_types := {
    "String", "Int", "Float", "Boolean", "ID",
    "__Schema", "__Type", "__Field", "__InputValue",
    "__EnumValue", "__Directive", "__DirectiveLocation"
}

# Regex for naming conventions
pascal_case_regex  := `^[A-Z][a-zA-Z0-9]+$`
camel_case_regex   := `^[a-z][a-zA-Z0-9]+$`
screaming_snake_regex := `^[A-Z][A-Z0-9]*(_[A-Z0-9]+)*$`

# Input type suffix requirement
input_type_suffix  := "Input"

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

object_types contains t if {
    some t in input.Types
    t.Kind == "OBJECT"
    not t.Name in builtin_types
}

input_types contains t if {
    some t in input.Types
    t.Kind == "INPUT_OBJECT"
    not t.Name in builtin_types
}

enum_types contains t if {
    some t in input.Types
    t.Kind == "ENUM"
    not t.Name in builtin_types
}

interface_types contains t if {
    some t in input.Types
    t.Kind == "INTERFACE"
    not t.Name in builtin_types
}

union_types contains t if {
    some t in input.Types
    t.Kind == "UNION"
    not t.Name in builtin_types
}

# ──────────────────────────────────────────────────────────────────────────────
# Type naming violations
# ──────────────────────────────────────────────────────────────────────────────

# Object types must be PascalCase
deny contains msg if {
    some t in object_types
    not regex.match(pascal_case_regex, t.Name)
    msg := sprintf(
        "NAMING-001: Object type '%s' is not PascalCase. Rename to e.g. '%s'. Policy §3.1.",
        [t.Name, to_pascal_case_hint(t.Name)]
    )
}

# Input types must be PascalCase and end with 'Input'
deny contains msg if {
    some t in input_types
    not regex.match(pascal_case_regex, t.Name)
    msg := sprintf(
        "NAMING-002: Input type '%s' is not PascalCase. Input types must be PascalCase and end with 'Input' (e.g. 'CreateUserInput'). Policy §3.2.",
        [t.Name]
    )
}

deny contains msg if {
    some t in input_types
    not endswith(t.Name, input_type_suffix)
    msg := sprintf(
        "NAMING-003: Input type '%s' must end with 'Input' (e.g. 'Create%sInput'). Policy §3.2.",
        [t.Name, t.Name]
    )
}

# Enum types must be PascalCase
deny contains msg if {
    some t in enum_types
    not regex.match(pascal_case_regex, t.Name)
    msg := sprintf(
        "NAMING-004: Enum type '%s' is not PascalCase. Policy §3.3.",
        [t.Name]
    )
}

# Enum values must be SCREAMING_SNAKE_CASE
deny contains msg if {
    some t in enum_types
    some v in t.EnumValues
    not regex.match(screaming_snake_regex, v.Name)
    msg := sprintf(
        "NAMING-005: Enum value '%s.%s' must be SCREAMING_SNAKE_CASE (e.g. '%s'). Policy §3.3.",
        [t.Name, v.Name, upper(v.Name)]
    )
}

# Interface types must be PascalCase
deny contains msg if {
    some t in interface_types
    not regex.match(pascal_case_regex, t.Name)
    msg := sprintf(
        "NAMING-006: Interface type '%s' is not PascalCase. Policy §3.1.",
        [t.Name]
    )
}

# Union types must be PascalCase
deny contains msg if {
    some t in union_types
    not regex.match(pascal_case_regex, t.Name)
    msg := sprintf(
        "NAMING-007: Union type '%s' is not PascalCase. Policy §3.1.",
        [t.Name]
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# Field naming violations
# ──────────────────────────────────────────────────────────────────────────────

deny contains msg if {
    some t in object_types
    some f in t.Fields
    not regex.match(camel_case_regex, f.Name)
    msg := sprintf(
        "NAMING-008: Field '%s.%s' is not camelCase. Rename to e.g. '%s'. Policy §3.4.",
        [t.Name, f.Name, to_camel_case_hint(f.Name)]
    )
}

deny contains msg if {
    some t in input_types
    some f in t.InputFields
    not regex.match(camel_case_regex, f.Name)
    msg := sprintf(
        "NAMING-009: Input field '%s.%s' is not camelCase. Policy §3.4.",
        [t.Name, f.Name]
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# Argument naming violations
# ──────────────────────────────────────────────────────────────────────────────

deny contains msg if {
    some t in object_types
    some f in t.Fields
    some arg in f.Args
    not regex.match(camel_case_regex, arg.Name)
    msg := sprintf(
        "NAMING-010: Argument '%s.%s(%s:)' is not camelCase. Policy §3.5.",
        [t.Name, f.Name, arg.Name]
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# Hint helpers (best-effort suggestions, not authoritative)
# ──────────────────────────────────────────────────────────────────────────────

to_pascal_case_hint(name) := result if {
    # Replace underscores and capitalize following character
    parts := split(lower(name), "_")
    result := concat("", [upper(substring(p, 0, 1)), substring(p, 1, -1) | some p in parts])
}

to_camel_case_hint(name) := result if {
    pascal := to_pascal_case_hint(name)
    result := concat("", [lower(substring(pascal, 0, 1)), substring(pascal, 1, -1)])
}
```

### Naming Policy Tests

```rego
# policy/rego/graphql/naming_test.rego
package graphql.naming

import future.keywords.if
import future.keywords.in

# ── Object type tests ─────────────────────────────────────────────────────────

test_valid_object_type_passes if {
    count(deny) == 0 with input as {"Types": [
        {"Name": "UserProfile", "Kind": "OBJECT", "Fields": []}
    ]}
}

test_snake_case_object_type_fails if {
    some msg in deny
    contains(msg, "NAMING-001")
    with input as {"Types": [
        {"Name": "user_profile", "Kind": "OBJECT", "Fields": []}
    ]}
}

test_lowercase_object_type_fails if {
    some msg in deny
    contains(msg, "NAMING-001")
    with input as {"Types": [
        {"Name": "userProfile", "Kind": "OBJECT", "Fields": []}
    ]}
}

# ── Input type tests ──────────────────────────────────────────────────────────

test_valid_input_type_passes if {
    count(deny) == 0 with input as {"Types": [
        {"Name": "CreateUserInput", "Kind": "INPUT_OBJECT", "InputFields": []}
    ]}
}

test_input_type_without_suffix_fails if {
    some msg in deny
    contains(msg, "NAMING-003")
    with input as {"Types": [
        {"Name": "CreateUser", "Kind": "INPUT_OBJECT", "InputFields": []}
    ]}
}

# ── Enum tests ────────────────────────────────────────────────────────────────

test_valid_enum_passes if {
    count(deny) == 0 with input as {"Types": [
        {"Name": "UserRole", "Kind": "ENUM", "EnumValues": [
            {"Name": "ADMIN"},
            {"Name": "VIEWER"},
            {"Name": "SUPER_ADMIN"}
        ]}
    ]}
}

test_lowercase_enum_value_fails if {
    some msg in deny
    contains(msg, "NAMING-005")
    with input as {"Types": [
        {"Name": "UserRole", "Kind": "ENUM", "EnumValues": [
            {"Name": "admin"}
        ]}
    ]}
}

test_camel_case_enum_value_fails if {
    some msg in deny
    contains(msg, "NAMING-005")
    with input as {"Types": [
        {"Name": "PaymentStatus", "Kind": "ENUM", "EnumValues": [
            {"Name": "paymentPending"}
        ]}
    ]}
}

# ── Field naming tests ────────────────────────────────────────────────────────

test_camel_case_field_passes if {
    count(deny) == 0 with input as {"Types": [
        {"Name": "User", "Kind": "OBJECT", "Fields": [
            {"Name": "firstName", "Args": [], "Type": {"Name": "String"}}
        ]}
    ]}
}

test_snake_case_field_fails if {
    some msg in deny
    contains(msg, "NAMING-008")
    with input as {"Types": [
        {"Name": "User", "Kind": "OBJECT", "Fields": [
            {"Name": "first_name", "Args": [], "Type": {"Name": "String"}}
        ]}
    ]}
}

test_builtin_types_skipped if {
    count(deny) == 0 with input as {"Types": [
        {"Name": "__Schema", "Kind": "OBJECT", "Fields": []}
    ]}
}
```

---

## Policy 2 — Required Field Documentation

Undocumented GraphQL fields create integration friction. Clients cannot distinguish between
`status: String` meaning HTTP status, order status, or account status without a description.
Documentation requirements prevent this ambiguity from accumulating.

```rego
# policy/rego/graphql/documentation.rego
package graphql.documentation

import future.keywords.in
import future.keywords.if
import future.keywords.contains

# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────

# Minimum description length in characters
min_description_length := 10

# Types excluded from documentation requirements (legacy types)
# Override per-repository via data document: data.doc_exceptions.excluded_types
excluded_types := object.get(data, ["doc_exceptions", "excluded_types"], set())

# Kinds requiring type-level documentation
documented_kinds := {"OBJECT", "INTERFACE", "UNION", "ENUM", "INPUT_OBJECT"}

# Fields excluded from documentation (e.g. standard ID fields)
always_documented_exceptions := {"id", "createdAt", "updatedAt"}

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

requires_documentation(kind) if {
    kind in documented_kinds
}

has_description(s) if {
    s != null
    count(trim_space(s)) >= min_description_length
}

is_user_defined(name) if {
    not startswith(name, "__")
}

# ──────────────────────────────────────────────────────────────────────────────
# Type documentation violations
# ──────────────────────────────────────────────────────────────────────────────

deny contains msg if {
    some t in input.Types
    is_user_defined(t.Name)
    requires_documentation(t.Kind)
    not t.Name in excluded_types
    not has_description(t.Description)
    msg := sprintf(
        "DOCS-001: Type '%s' (%s) has no description or description is too short (minimum %d characters). Add a description that explains what this type represents and when it is used. Policy §4.1.",
        [t.Name, t.Kind, min_description_length]
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# Field documentation violations
# ──────────────────────────────────────────────────────────────────────────────

# All fields on documented object types must have descriptions
deny contains msg if {
    some t in input.Types
    is_user_defined(t.Name)
    t.Kind == "OBJECT"
    not t.Name in excluded_types
    some f in t.Fields
    not f.Name in always_documented_exceptions
    not has_description(f.Description)
    msg := sprintf(
        "DOCS-002: Field '%s.%s' has no description or description is too short (minimum %d characters). Describe what this field returns, any nullable semantics, and any units or format constraints. Policy §4.2.",
        [t.Name, f.Name, min_description_length]
    )
}

# All input fields must have descriptions
deny contains msg if {
    some t in input.Types
    is_user_defined(t.Name)
    t.Kind == "INPUT_OBJECT"
    not t.Name in excluded_types
    some f in t.InputFields
    not has_description(f.Description)
    msg := sprintf(
        "DOCS-003: Input field '%s.%s' has no description. Input fields must be documented because clients use them to construct mutations. Policy §4.3.",
        [t.Name, f.Name]
    )
}

# All enum values must have descriptions
deny contains msg if {
    some t in input.Types
    is_user_defined(t.Name)
    t.Kind == "ENUM"
    not t.Name in excluded_types
    some v in t.EnumValues
    not has_description(v.Description)
    msg := sprintf(
        "DOCS-004: Enum value '%s.%s' has no description. Document the meaning and usage context of each enum value. Policy §4.4.",
        [t.Name, v.Name]
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# Argument documentation violations (warn — not all args require docs)
# ──────────────────────────────────────────────────────────────────────────────

warn contains msg if {
    some t in input.Types
    t.Kind == "OBJECT"
    not t.Name in excluded_types
    some f in t.Fields
    count(f.Args) > 0
    some arg in f.Args
    not has_description(arg.Description)
    msg := sprintf(
        "DOCS-005 (warn): Argument '%s.%s(%s:)' has no description. Arguments on public-facing fields should explain their purpose and valid values. Policy §4.5.",
        [t.Name, f.Name, arg.Name]
    )
}
```

### Documentation Policy Tests

```rego
# policy/rego/graphql/documentation_test.rego
package graphql.documentation

import future.keywords.if
import future.keywords.in

test_documented_type_passes if {
    count(deny) == 0 with input as {"Types": [
        {
            "Name": "Order",
            "Kind": "OBJECT",
            "Description": "Represents a customer purchase order in the system.",
            "Fields": [
                {
                    "Name": "id",
                    "Description": "",
                    "Args": [],
                    "Type": {"Name": "ID"}
                }
            ]
        }
    ]}
}

test_undocumented_type_fails if {
    some msg in deny
    contains(msg, "DOCS-001")
    with input as {"Types": [
        {
            "Name": "Order",
            "Kind": "OBJECT",
            "Description": "",
            "Fields": []
        }
    ]}
}

test_short_description_fails if {
    some msg in deny
    contains(msg, "DOCS-001")
    with input as {"Types": [
        {
            "Name": "Order",
            "Kind": "OBJECT",
            "Description": "An order",
            "Fields": []
        }
    ]}
}

test_undocumented_non_id_field_fails if {
    some msg in deny
    contains(msg, "DOCS-002")
    with input as {"Types": [
        {
            "Name": "Order",
            "Kind": "OBJECT",
            "Description": "Represents a customer purchase order.",
            "Fields": [
                {
                    "Name": "status",
                    "Description": null,
                    "Args": [],
                    "Type": {"Name": "String"}
                }
            ]
        }
    ]}
}

test_id_field_skipped if {
    # 'id', 'createdAt', 'updatedAt' are always-documented exceptions
    count(deny) == 0 with input as {"Types": [
        {
            "Name": "Order",
            "Kind": "OBJECT",
            "Description": "Represents a customer purchase order.",
            "Fields": [
                {
                    "Name": "id",
                    "Description": "",
                    "Args": [],
                    "Type": {"Name": "ID"}
                }
            ]
        }
    ]}
}

test_excluded_type_skipped if {
    count(deny) == 0 with input as {
        "Types": [{"Name": "LegacyPayment", "Kind": "OBJECT", "Description": "", "Fields": []}]
    } with data.doc_exceptions.excluded_types as {"LegacyPayment"}
}

test_undocumented_input_field_fails if {
    some msg in deny
    contains(msg, "DOCS-003")
    with input as {"Types": [
        {
            "Name": "CreateOrderInput",
            "Kind": "INPUT_OBJECT",
            "Description": "Input for creating a new order in the system.",
            "InputFields": [
                {"Name": "customerId", "Description": null, "Type": {"Name": "ID"}}
            ]
        }
    ]}
}
```

---

## Policy 3 — Deprecation Age Policy

Deprecated fields accumulate without automated enforcement. This policy enforces that
deprecation reasons include a date, that the date is machine-parseable, and that fields
older than the maximum allowed age block CI until removed.

```rego
# policy/rego/graphql/deprecation.rego
package graphql.deprecation

import future.keywords.in
import future.keywords.if
import future.keywords.contains

# ──────────────────────────────────────────────────────────────────────────────
# Configuration (override via data document in bundle)
# ──────────────────────────────────────────────────────────────────────────────

max_age_days     := object.get(data, ["deprecation_config", "max_age_days"], 180)
warning_days     := object.get(data, ["deprecation_config", "warning_days"], 30)

# Required phrase pattern in deprecation reason to indicate a migration target
migration_pattern := `[Uu]se\s+\w+`

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

deprecated_fields contains entry if {
    some t in input.Types
    some f in t.Fields
    f.IsDeprecated
    entry := {"type": t.Name, "field": f.Name, "reason": f.DeprecationReason}
}

extract_date(reason) := date if {
    matches := regex.find_all_string_submatch_n(`(\d{4}-\d{2}-\d{2})`, reason, 1)
    count(matches) > 0
    date := matches[0][1]
}

extract_date(reason) := "" if {
    not regex.match(`\d{4}-\d{2}-\d{2}`, reason)
}

days_since_iso(date_str) := days if {
    parts  := split(date_str, "-")
    year   := to_number(parts[0])
    month  := to_number(parts[1])
    day    := to_number(parts[2])
    ts_ns  := time.date([year, month, day, 0, 0, 0, "UTC"])
    now_ns := time.now_ns()
    days   := round((now_ns - ts_ns) / (24 * 60 * 60 * 1000000000))
}

# ──────────────────────────────────────────────────────────────────────────────
# Deny rules
# ──────────────────────────────────────────────────────────────────────────────

# Deprecation reason must not be empty
deny contains msg if {
    some entry in deprecated_fields
    entry.reason == null
    msg := sprintf(
        "DEPR-001: Field '%s.%s' is deprecated but has no deprecation reason. Deprecation reasons must explain why the field is deprecated, provide a migration target, and include a deprecation date (YYYY-MM-DD). Policy §5.1.",
        [entry.type, entry.field]
    )
}

deny contains msg if {
    some entry in deprecated_fields
    entry.reason != null
    trim_space(entry.reason) == ""
    msg := sprintf(
        "DEPR-001: Field '%s.%s' is deprecated but has an empty deprecation reason. Policy §5.1.",
        [entry.type, entry.field]
    )
}

# Deprecation reason must contain a date
deny contains msg if {
    some entry in deprecated_fields
    entry.reason != null
    trim_space(entry.reason) != ""
    not regex.match(`\d{4}-\d{2}-\d{2}`, entry.reason)
    msg := sprintf(
        "DEPR-002: Field '%s.%s' deprecation reason does not include a date (YYYY-MM-DD format required). Example: '@deprecated(reason: \"Use orderStatus instead. Deprecated: 2025-06-01.\")'. Policy §5.2.",
        [entry.type, entry.field]
    )
}

# Deprecation reason should include a migration alternative
deny contains msg if {
    some entry in deprecated_fields
    entry.reason != null
    not regex.match(migration_pattern, entry.reason)
    msg := sprintf(
        "DEPR-003: Field '%s.%s' deprecation reason does not specify a migration target. Include 'Use <alternative>' in the reason. Policy §5.3.",
        [entry.type, entry.field]
    )
}

# Fields deprecated longer than max_age_days must be removed
deny contains msg if {
    some entry in deprecated_fields
    entry.reason != null
    date := extract_date(entry.reason)
    date != ""
    age  := days_since_iso(date)
    age > max_age_days
    msg := sprintf(
        "DEPR-004: Field '%s.%s' has been deprecated for %d days (since %s), exceeding the maximum of %d days. This field must be removed. Submit a removal PR or request an exception via PLAT-XXXX. Policy §5.4.",
        [entry.type, entry.field, age, date, max_age_days]
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# Warn rules — approaching max age
# ──────────────────────────────────────────────────────────────────────────────

warn contains msg if {
    some entry in deprecated_fields
    entry.reason != null
    date := extract_date(entry.reason)
    date != ""
    age  := days_since_iso(date)
    age > (max_age_days - warning_days)
    age <= max_age_days
    remaining := max_age_days - age
    msg := sprintf(
        "DEPR-005 (warn): Field '%s.%s' has been deprecated for %d days and will exceed the maximum in %d days. Plan removal now. Policy §5.4.",
        [entry.type, entry.field, age, remaining]
    )
}
```

---

## Policy 4 — Field Complexity Budget

Fields that return lists of objects, or that are nested inside other list fields, have
multiplicative cost. This policy enforces that no single field has an estimated complexity
score above a configurable budget when combined with its parent type's list multiplier.

```rego
# policy/rego/graphql/complexity.rego
package graphql.complexity

import future.keywords.in
import future.keywords.if
import future.keywords.contains

# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────

# Per-field complexity cost (default 1; listed types cost more)
default_field_cost := 1
list_field_cost    := 10
connection_cost    := 20   # Relay-style Connection types

# Maximum cost for a single field (not total query cost)
max_field_cost := 100

# Warn when a single field exceeds this threshold
warn_field_cost := 50

# List of type-name suffixes that indicate a connection (Relay pagination)
connection_suffixes := {"Connection", "Edge", "PageInfo"}

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

is_list_type(type_def) if {
    type_def.Kind == "LIST"
}

is_list_type(type_def) if {
    type_def.OfType != null
    is_list_type(type_def.OfType)
}

is_connection_type(type_name) if {
    some suffix in connection_suffixes
    endswith(type_name, suffix)
}

field_cost(f) := connection_cost if {
    is_connection_type(f.Type.Name)
}

field_cost(f) := list_field_cost if {
    not is_connection_type(f.Type.Name)
    is_list_type(f.Type)
}

field_cost(f) := default_field_cost if {
    not is_list_type(f.Type)
    not is_connection_type(f.Type.Name)
}

# ──────────────────────────────────────────────────────────────────────────────
# Deny rules
# ──────────────────────────────────────────────────────────────────────────────

deny contains msg if {
    some t in input.Types
    t.Kind == "OBJECT"
    not startswith(t.Name, "__")
    some f in t.Fields
    cost := field_cost(f)
    cost > max_field_cost
    msg := sprintf(
        "CMPLX-001: Field '%s.%s' has an estimated complexity cost of %d, exceeding the maximum of %d. Consider paginating this field, adding depth limits, or breaking it into a separate lazy-loaded query. Policy §6.1.",
        [t.Name, f.Name, cost, max_field_cost]
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# Warn rules
# ──────────────────────────────────────────────────────────────────────────────

warn contains msg if {
    some t in input.Types
    t.Kind == "OBJECT"
    not startswith(t.Name, "__")
    some f in t.Fields
    cost := field_cost(f)
    cost > warn_field_cost
    cost <= max_field_cost
    msg := sprintf(
        "CMPLX-002 (warn): Field '%s.%s' has an estimated complexity cost of %d (warning threshold: %d). Ensure this field is paginated or has appropriate depth limits. Policy §6.2.",
        [t.Name, f.Name, cost, warn_field_cost]
    )
}
```

---

## Policy 5 — Schema Size Limits

Unbounded schema growth slows introspection, increases composition check time, and indicates
that domain boundaries need review. Size limits enforce architectural discipline.

```rego
# policy/rego/graphql/schema_size.rego
package graphql.schema_size

import future.keywords.in
import future.keywords.if
import future.keywords.contains

# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────

# Per-subgraph limits (override via data.schema_size_config)
max_types_per_subgraph  := object.get(data, ["schema_size_config", "max_types"], 200)
max_fields_per_type     := object.get(data, ["schema_size_config", "max_fields_per_type"], 50)
max_args_per_field      := object.get(data, ["schema_size_config", "max_args_per_field"], 10)
max_enum_values         := object.get(data, ["schema_size_config", "max_enum_values"], 100)

warn_types_threshold    := round(max_types_per_subgraph * 0.8)
warn_fields_threshold   := round(max_fields_per_type * 0.8)

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

user_defined_types contains t if {
    some t in input.Types
    not startswith(t.Name, "__")
    t.Kind in {"OBJECT", "INTERFACE", "UNION", "ENUM", "INPUT_OBJECT"}
}

# ──────────────────────────────────────────────────────────────────────────────
# Deny rules
# ──────────────────────────────────────────────────────────────────────────────

# Total type count
deny contains msg if {
    total := count(user_defined_types)
    total > max_types_per_subgraph
    msg := sprintf(
        "SIZE-001: Schema contains %d user-defined types, exceeding the maximum of %d per subgraph. Review domain boundaries — this subgraph may own too many concerns. Policy §7.1.",
        [total, max_types_per_subgraph]
    )
}

# Fields per type
deny contains msg if {
    some t in user_defined_types
    t.Kind == "OBJECT"
    count(t.Fields) > max_fields_per_type
    msg := sprintf(
        "SIZE-002: Type '%s' has %d fields, exceeding the maximum of %d. Consider splitting this type into multiple focused types or using composition. Policy §7.2.",
        [t.Name, count(t.Fields), max_fields_per_type]
    )
}

# Arguments per field
deny contains msg if {
    some t in user_defined_types
    t.Kind == "OBJECT"
    some f in t.Fields
    count(f.Args) > max_args_per_field
    msg := sprintf(
        "SIZE-003: Field '%s.%s' has %d arguments, exceeding the maximum of %d. Consolidate arguments into an input type. Policy §7.3.",
        [t.Name, f.Name, count(f.Args), max_args_per_field]
    )
}

# Enum values per enum
deny contains msg if {
    some t in user_defined_types
    t.Kind == "ENUM"
    count(t.EnumValues) > max_enum_values
    msg := sprintf(
        "SIZE-004: Enum type '%s' has %d values, exceeding the maximum of %d. Large enums are a signal that this concept should be modeled as a type with a lookup query. Policy §7.4.",
        [t.Name, count(t.EnumValues), max_enum_values]
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# Warn rules
# ──────────────────────────────────────────────────────────────────────────────

warn contains msg if {
    total := count(user_defined_types)
    total > warn_types_threshold
    total <= max_types_per_subgraph
    msg := sprintf(
        "SIZE-005 (warn): Schema has %d types (%d%% of the %d-type limit). Plan for subgraph decomposition. Policy §7.1.",
        [total, round(total * 100 / max_types_per_subgraph), max_types_per_subgraph]
    )
}

warn contains msg if {
    some t in user_defined_types
    t.Kind == "OBJECT"
    count(t.Fields) > warn_fields_threshold
    count(t.Fields) <= max_fields_per_type
    msg := sprintf(
        "SIZE-006 (warn): Type '%s' has %d fields (%d%% of the %d-field limit). Consider whether this type is taking on too many responsibilities. Policy §7.2.",
        [t.Name, count(t.Fields), round(count(t.Fields) * 100 / max_fields_per_type), max_fields_per_type]
    )
}
```

---

## Policy 6 — Forbidden Field Name Patterns

Certain field names expose security risks (leaking internal IDs), create compliance problems
(exposing PII field names in introspection), or indicate poor schema design (generic names
that will need disambiguation later).

```rego
# policy/rego/graphql/security.rego
package graphql.security

import future.keywords.in
import future.keywords.if
import future.keywords.contains

# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────

# Field name patterns that are explicitly forbidden
# Each entry: {pattern, code, reason, severity}
forbidden_field_patterns := [
    {
        "pattern": `(?i)^password$`,
        "code": "SEC-001",
        "reason": "Field named 'password' must not appear in a GraphQL type. Passwords must never be returned from the API. If this is an input field for authentication, name it 'credential' and use a dedicated auth mutation.",
        "severity": "deny"
    },
    {
        "pattern": `(?i)^(secret|apiKey|api_key|accessToken|access_token|privateKey|private_key)$`,
        "code": "SEC-002",
        "reason": "Field name indicates a sensitive credential. Credentials must not be exposed through the GraphQL schema. If an API key must be returned (e.g. after creation), mark the field @deprecated immediately after first use and rotate on exposure.",
        "severity": "deny"
    },
    {
        "pattern": `(?i)internal`,
        "code": "SEC-003",
        "reason": "Field name contains 'internal', suggesting it is not intended for external consumers. Remove the field or rename it to reflect its actual public semantics.",
        "severity": "deny"
    },
    {
        "pattern": `(?i)^(ssn|socialSecurityNumber|taxId|tax_id|passport)$`,
        "code": "SEC-004",
        "reason": "Field name indicates government-issued identifier. These fields require PII classification, encryption at rest, field-level access control, and audit logging before being exposed in the API. Consult the security team before adding this field.",
        "severity": "deny"
    },
    {
        "pattern": `(?i)^(data|info|details|metadata|misc|stuff|temp|tmp)$`,
        "code": "DESIGN-001",
        "reason": "Generic field name provides no semantic information to API consumers. Rename to describe the specific data contained (e.g. 'orderMetadata', 'paymentDetails').",
        "severity": "deny"
    },
    {
        "pattern": `(?i)^(deprecated|old|legacy|v[0-9]+)$`,
        "code": "DESIGN-002",
        "reason": "Field name suggests it is a versioning artifact. Use the @deprecated directive with a migration reason instead of embedding version markers in field names.",
        "severity": "warn"
    },
    {
        "pattern": `(?i)^(test|debug|dev|mock|stub|fake)$`,
        "code": "DESIGN-003",
        "reason": "Field name suggests test or development-only data. Test utilities must not appear in the production schema.",
        "severity": "deny"
    }
]

# Types excluded from security pattern checks (approved legacy types)
excluded_types := object.get(data, ["security_exceptions", "excluded_types"], set())

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

user_defined_object_types contains t if {
    some t in input.Types
    t.Kind in {"OBJECT", "INPUT_OBJECT"}
    not startswith(t.Name, "__")
    not t.Name in excluded_types
}

fields_for_type(t) := t.Fields if {
    t.Kind == "OBJECT"
}

fields_for_type(t) := t.InputFields if {
    t.Kind == "INPUT_OBJECT"
}

# ──────────────────────────────────────────────────────────────────────────────
# Deny rules — forbidden field patterns with severity "deny"
# ──────────────────────────────────────────────────────────────────────────────

deny contains msg if {
    some t in user_defined_object_types
    some f in fields_for_type(t)
    some rule in forbidden_field_patterns
    rule.severity == "deny"
    regex.match(rule.pattern, f.Name)
    msg := sprintf(
        "%s: Field '%s.%s' matches forbidden pattern. %s",
        [rule.code, t.Name, f.Name, rule.reason]
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# Warn rules — forbidden field patterns with severity "warn"
# ──────────────────────────────────────────────────────────────────────────────

warn contains msg if {
    some t in user_defined_object_types
    some f in fields_for_type(t)
    some rule in forbidden_field_patterns
    rule.severity == "warn"
    regex.match(rule.pattern, f.Name)
    msg := sprintf(
        "%s (warn): Field '%s.%s' matches an advisory pattern. %s",
        [rule.code, t.Name, f.Name, rule.reason]
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# Type-level checks
# ──────────────────────────────────────────────────────────────────────────────

# Types must not contain the word 'Internal' in their name
deny contains msg if {
    some t in input.Types
    t.Kind in {"OBJECT", "INTERFACE"}
    not startswith(t.Name, "__")
    regex.match(`(?i)internal`, t.Name)
    msg := sprintf(
        "SEC-005: Type name '%s' contains 'internal', suggesting it is not intended for external consumers. Remove from the schema or rename to reflect its public role. Policy §8.1.",
        [t.Name]
    )
}
```

### Security Policy Tests

```rego
# policy/rego/graphql/security_test.rego
package graphql.security

import future.keywords.if
import future.keywords.in

test_password_field_denied if {
    some msg in deny
    contains(msg, "SEC-001")
    with input as {"Types": [
        {
            "Name": "User",
            "Kind": "OBJECT",
            "Fields": [{"Name": "password", "Type": {"Name": "String"}}]
        }
    ]}
}

test_api_key_field_denied if {
    some msg in deny
    contains(msg, "SEC-002")
    with input as {"Types": [
        {
            "Name": "ServiceAccount",
            "Kind": "OBJECT",
            "Fields": [{"Name": "apiKey", "Type": {"Name": "String"}}]
        }
    ]}
}

test_generic_data_field_denied if {
    some msg in deny
    contains(msg, "DESIGN-001")
    with input as {"Types": [
        {
            "Name": "Order",
            "Kind": "OBJECT",
            "Fields": [{"Name": "data", "Type": {"Name": "String"}}]
        }
    ]}
}

test_test_field_denied if {
    some msg in deny
    contains(msg, "DESIGN-003")
    with input as {"Types": [
        {
            "Name": "Product",
            "Kind": "OBJECT",
            "Fields": [{"Name": "testPrice", "Type": {"Name": "Float"}}]
        }
    ]}
}

test_safe_field_passes if {
    count(deny) == 0 with input as {"Types": [
        {
            "Name": "User",
            "Kind": "OBJECT",
            "Fields": [
                {"Name": "id", "Type": {"Name": "ID"}},
                {"Name": "email", "Type": {"Name": "String"}},
                {"Name": "firstName", "Type": {"Name": "String"}}
            ]
        }
    ]}
}

test_excluded_type_skipped if {
    count(deny) == 0 with input as {
        "Types": [
            {
                "Name": "LegacyUser",
                "Kind": "OBJECT",
                "Fields": [{"Name": "password", "Type": {"Name": "String"}}]
            }
        ]
    } with data.security_exceptions.excluded_types as {"LegacyUser"}
}

test_internal_type_name_denied if {
    some msg in deny
    contains(msg, "SEC-005")
    with input as {"Types": [
        {"Name": "InternalOrderCache", "Kind": "OBJECT", "Fields": []}
    ]}
}
```

---

## Running Policies in GitHub Actions CI

### Complete Schema Policy Workflow

```yaml
# .github/workflows/graphql-schema-policies.yml
name: GraphQL Schema Policies

on:
  pull_request:
    paths:
      - "**/*.graphql"
      - "**/*.graphqls"
      - "policy/rego/graphql/**"
    types: [opened, synchronize, reopened]
  push:
    branches: [main]
    paths:
      - "**/*.graphql"
      - "**/*.graphqls"

permissions:
  contents: read
  pull-requests: write
  checks: write
  statuses: write

env:
  OPA_VERSION: "0.65.0"
  CONFTEST_VERSION: "0.51.0"
  POLICY_BUNDLE_VERSION: "v1.2.0"

jobs:
  opa-unit-tests:
    name: Policy Unit Tests
    runs-on: ubuntu-24.04
    timeout-minutes: 5

    steps:
      - uses: actions/checkout@v4

      - name: Cache OPA binary
        uses: actions/cache@v4
        with:
          path: ~/.local/bin/opa
          key: opa-${{ env.OPA_VERSION }}

      - name: Install OPA
        run: |
          if [ ! -f ~/.local/bin/opa ]; then
            mkdir -p ~/.local/bin
            curl -Lo ~/.local/bin/opa \
              "https://github.com/open-policy-agent/opa/releases/download/v${OPA_VERSION}/opa_linux_amd64_static"
            chmod +x ~/.local/bin/opa
          fi
          echo "$HOME/.local/bin" >> "$GITHUB_PATH"
          opa version

      - name: Run policy unit tests
        run: |
          opa test policy/rego/ \
            --verbose \
            --coverage \
            --format json \
            | tee opa-test-output.json

      - name: Enforce coverage threshold
        run: |
          python3 - <<'EOF'
          import json, sys

          with open("opa-test-output.json") as f:
              data = json.load(f)

          # Collect test results
          failures = [t for t in data.get("results", []) if t.get("fail")]
          errors   = [t for t in data.get("results", []) if t.get("error")]
          coverage = data.get("coverage", 0)

          print(f"Tests run:   {len(data.get('results', []))}")
          print(f"Failures:    {len(failures)}")
          print(f"Errors:      {len(errors)}")
          print(f"Coverage:    {coverage:.1f}%")

          if failures or errors:
              print("\nFailed tests:")
              for t in failures + errors:
                  print(f"  - {t.get('location', {})}: {t.get('fail') or t.get('error')}")
              sys.exit(1)

          if coverage < 95:
              print(f"\nERROR: Coverage {coverage:.1f}% is below the required 95% threshold.")
              sys.exit(1)
          EOF

      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: opa-test-results
          path: opa-test-output.json
          retention-days: 14

  schema-policy-check:
    name: Schema Policy Evaluation
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    needs: opa-unit-tests

    steps:
      - uses: actions/checkout@v4

      - name: Cache conftest binary
        uses: actions/cache@v4
        with:
          path: ~/.local/bin/conftest
          key: conftest-${{ env.CONFTEST_VERSION }}

      - name: Install conftest
        run: |
          if [ ! -f ~/.local/bin/conftest ]; then
            mkdir -p ~/.local/bin
            curl -Lo /tmp/conftest.tar.gz \
              "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_x86_64.tar.gz"
            tar xzf /tmp/conftest.tar.gz -C /tmp conftest
            mv /tmp/conftest ~/.local/bin/conftest
            chmod +x ~/.local/bin/conftest
          fi
          echo "$HOME/.local/bin" >> "$GITHUB_PATH"
          conftest --version

      - name: Find changed schema files
        id: changed-files
        run: |
          if [ "${{ github.event_name }}" = "pull_request" ]; then
            BASE="${{ github.event.pull_request.base.sha }}"
            HEAD="${{ github.event.pull_request.head.sha }}"
            CHANGED=$(git diff --name-only "$BASE" "$HEAD" -- '*.graphql' '*.graphqls' | tr '\n' ' ')
          else
            CHANGED=$(find . -name "*.graphql" -o -name "*.graphqls" | grep -v node_modules | tr '\n' ' ')
          fi
          echo "files=${CHANGED}" >> "$GITHUB_OUTPUT"
          echo "Changed schema files: ${CHANGED}"

      - name: Evaluate schema policies
        id: policy-eval
        if: steps.changed-files.outputs.files != ''
        run: |
          set +e
          conftest test \
            --policy policy/rego/graphql \
            --namespace graphql \
            --output github \
            --no-color \
            --data policy/data/ \
            ${{ steps.changed-files.outputs.files }} \
            2>&1 | tee conftest-output.txt
          EXIT_CODE=${PIPESTATUS[0]}
          echo "exit_code=${EXIT_CODE}" >> "$GITHUB_OUTPUT"
          set -e

      - name: Parse violation counts
        if: always() && steps.changed-files.outputs.files != ''
        id: violation-counts
        run: |
          DENIES=$(grep -c "^FAIL" conftest-output.txt 2>/dev/null || echo 0)
          WARNS=$(grep -c "^WARN" conftest-output.txt 2>/dev/null || echo 0)
          echo "denies=${DENIES}" >> "$GITHUB_OUTPUT"
          echo "warns=${WARNS}"   >> "$GITHUB_OUTPUT"

      - name: Post PR comment with violations
        if: |
          github.event_name == 'pull_request' &&
          steps.changed-files.outputs.files != '' &&
          (steps.policy-eval.outputs.exit_code != '0' || steps.violation-counts.outputs.warns != '0')
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const output = fs.readFileSync('conftest-output.txt', 'utf8');
            const denies = '${{ steps.violation-counts.outputs.denies }}';
            const warns  = '${{ steps.violation-counts.outputs.warns }}';
            const status = denies > 0 ? '❌ Failed' : '⚠️ Warnings';

            const body = [
              `## Schema Policy Check — ${status}`,
              '',
              `| Metric | Count |`,
              `|---|---|`,
              `| Blocking violations (deny) | ${denies} |`,
              `| Advisory warnings (warn) | ${warns} |`,
              '',
              '<details><summary>Full output</summary>',
              '',
              '```',
              output.substring(0, 65000),
              '```',
              '</details>',
              '',
              '### Remediation',
              '- Review the [Schema Policy Reference](docs/13-policy-as-code/02-schema-policies.md)',
              '- For exceptions, open a request using the [Policy Exception template](https://jira.example.com/PLAT-exception)',
              '- Policy codes (e.g. NAMING-001) map to specific rules in the documentation',
            ].join('\n');

            // Update existing comment if present, otherwise create new
            const { data: comments } = await github.rest.issues.listComments({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
            });

            const existing = comments.find(c =>
              c.user.login === 'github-actions[bot]' &&
              c.body.includes('Schema Policy Check')
            );

            if (existing) {
              await github.rest.issues.updateComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                comment_id: existing.id,
                body,
              });
            } else {
              await github.rest.issues.createComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                issue_number: context.issue.number,
                body,
              });
            }

      - name: Upload policy evaluation results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: conftest-results-${{ github.run_id }}
          path: conftest-output.txt
          retention-days: 30

      - name: Fail if blocking violations found
        if: steps.policy-eval.outputs.exit_code != '0'
        run: |
          echo "::error::Schema policy check failed. Review violations in the PR comment and conftest-output.txt artifact."
          exit 1

  policy-metrics:
    name: Record Policy Metrics
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    needs: schema-policy-check
    if: always() && github.ref == 'refs/heads/main'

    steps:
      - uses: actions/checkout@v4

      - name: Download conftest results
        uses: actions/download-artifact@v4
        with:
          name: conftest-results-${{ github.run_id }}
          path: /tmp/results/

      - name: Emit policy violation metrics
        env:
          PUSHGATEWAY_URL: ${{ secrets.PROMETHEUS_PUSHGATEWAY_URL }}
          PUSHGATEWAY_TOKEN: ${{ secrets.PROMETHEUS_PUSHGATEWAY_TOKEN }}
        run: |
          DENIES=$(grep -c "^FAIL" /tmp/results/conftest-output.txt 2>/dev/null || echo 0)
          WARNS=$(grep -c  "^WARN" /tmp/results/conftest-output.txt 2>/dev/null || echo 0)

          # Push metrics to Prometheus pushgateway
          cat <<EOF | curl --silent --fail \
            -H "Authorization: Bearer ${PUSHGATEWAY_TOKEN}" \
            --data-binary @- \
            "${PUSHGATEWAY_URL}/metrics/job/graphql-schema-policies/repo/${{ github.repository }}"
          # HELP graphql_schema_policy_violations_total Total schema policy violations in CI
          # TYPE graphql_schema_policy_violations_total gauge
          graphql_schema_policy_violations_total{severity="deny",repo="${{ github.repository }}"} ${DENIES}
          graphql_schema_policy_violations_total{severity="warn",repo="${{ github.repository }}"} ${WARNS}
          EOF
```

---

## Production Considerations

### Performance

conftest evaluates compiled Rego bundles. For schemas with 200+ types, pre-compile the bundle
with `opa build --optimize 1` and reference the compiled bundle from conftest. Compilation
reduces the per-evaluation time by 30–60% and eliminates the Rego parser overhead.

On large monorepos, scope conftest evaluation to changed files only (as shown in the workflow
above) rather than evaluating the entire schema on every push. The `git diff` approach keeps
CI times proportional to change size.

### Security

The security policy (Policy 6) is the most critical from a compliance perspective. Test its
unit tests with full branch coverage. Consider requiring two-reviewer approval for any change
to `security.rego` or its test file, enforced via CODEOWNERS:

```
# CODEOWNERS
policy/rego/graphql/security.rego          @security-team @platform-team
policy/rego/graphql/security_test.rego     @security-team @platform-team
policy/rego/runtime/authz.rego             @security-team
policy/data/                               @platform-team
```

### Scaling

As the number of subgraphs grows, the number of schema files evaluated in CI grows
proportionally. Shard the conftest evaluation by subgraph directory if evaluation time
exceeds 60 seconds. GitHub Actions matrix builds distribute evaluation across parallel jobs:

```yaml
strategy:
  matrix:
    subgraph: [users, orders, payments, products, notifications]
steps:
  - run: |
      conftest test \
        --policy policy/rego/graphql \
        --namespace graphql \
        --output github \
        subgraphs/${{ matrix.subgraph }}/**/*.graphql
```

---

## Best Practices

1. Start with naming and documentation policies. These are low-controversy, high-value,
   and have clear, automatable fixes. Ship these first to demonstrate policy-as-code value
   before introducing more opinionated policies.

2. Use `warn` mode for new policies for two sprint cycles. Collect real violation counts.
   If the violation rate is high, the policy threshold may need adjustment before going
   blocking.

3. Keep error codes stable. Policy codes like `NAMING-001` are referenced in documentation,
   Jira tickets, exception records, and team wikis. Changing codes retroactively breaks
   search and audit trails.

4. Make every policy configurable via data documents. Teams should be able to override
   thresholds (max field count, deprecation age) without modifying Rego. Configuration
   lives in the bundle data layer; policy logic lives in Rego.

5. Document exceptions in code, not in spreadsheets. The `data.security_exceptions` and
   `data.doc_exceptions` patterns let exception records live in the bundle where they are
   version-controlled and auditable.

---

## Anti-Patterns

**Writing policies that rely on field order.** GraphQL SDL files do not guarantee field order.
Rego policies that depend on the first or last element of a field array will produce
non-deterministic results as SDL tools reorder fields. Always iterate with comprehensions.

**Embedding thresholds as literals.** If `max_fields_per_type := 50` appears as a literal
in Rego, changing the threshold requires a policy code change and bundle publish. Move
thresholds to the data layer so they can be updated without a Rego change.

**Skipping warn rules in tests.** `deny` tests are obvious. `warn` tests are equally
important — a false-positive warn floods CI with noise and trains teams to ignore warnings.
Test both `deny` and `warn` sets in every policy.

**Not testing the empty-input case.** Policies must handle schemas with no types, no fields,
and empty strings without panicking. OPA's undefined semantics can cause silent failures
when comprehensions are applied to null inputs. Test with empty `input.Types := []`.

---

## References

- [OPA Rego Language Reference](https://www.openpolicyagent.org/docs/latest/policy-language/)
- [conftest GraphQL Support](https://www.conftest.dev/parsers/)
- [graphql-eslint Naming Rules](https://the-guild.dev/graphql/eslint/rules/naming-convention)
- [GraphQL Specification — Type System](https://spec.graphql.org/October2021/#sec-Type-System)
- [Relay Cursor Connections Specification](https://relay.dev/graphql/connections.htm)
- [OPA Policy Testing](https://www.openpolicyagent.org/docs/latest/policy-testing/)
- [OWASP GraphQL Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/GraphQL_Cheat_Sheet.html)

---

## Related Topics

- [Policy as Code Overview](./README.md)
- [OPA Integration](./01-opa-integration.md)
- [Schema Governance](../../09-schema-governance/README.md)
- [Schema Validation](../../10-schema-validation/README.md)
- [GitHub Actions](../../12-github-actions/README.md)
- [Security](../../05-security/README.md)
- [Breaking Change Policies](../../09-schema-governance/03-breaking-change-policies.md)
