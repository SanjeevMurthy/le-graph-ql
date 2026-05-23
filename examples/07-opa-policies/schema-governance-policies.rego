# Schema Governance Policies — OPA Rego
#
# Companion documentation: ../../docs/13-policy-as-code/ and ../../docs/09-schema-governance/
#
# This file defines production-ready OPA Rego policies for GraphQL schema governance.
# Policies are evaluated against a schema-diff.json document produced by graphql-inspector.
#
# Input document shape:
#   input.old_schema.types  — array of type definitions before this change
#   input.new_schema.types  — array of type definitions after this change
#   input.labels            — array of PR label strings (used for approval overrides)
#   input.approved_removals — array of type names explicitly approved for removal
#
# Rule forms used:
#   deny[msg]  — collects ALL violations; CI treats any non-empty set as a failure
#   warn[msg]  — collects advisory notices; CI posts these but does not block
#
# Usage:
#   opa eval -d schema-governance-policies.rego -i schema-diff.json 'data.graphql.schema.deny'
#   opa eval -d schema-governance-policies.rego -i schema-diff.json 'data.graphql.schema.warn'
#   opa test schema-governance-policies.rego policy-tests.rego -v

package graphql.schema

import future.keywords.if
import future.keywords.in
import future.keywords.every

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

# is_introspection_type returns true if the type name begins with "__".
# Introspection types (__Schema, __Type, __Field, etc.) are built-in and
# cannot carry custom descriptions, so all description rules must exclude them.
is_introspection_type(type_name) if {
    startswith(type_name, "__")
}

# has_description returns true if the given object has a non-empty description.
# We check both that the field exists and that it is not the empty string.
# Some schema serializers omit the description key entirely on undescribed elements;
# others set it to "". Both cases are treated as missing.
has_description(obj) if {
    obj.description != ""
    obj.description != null
}

# is_breaking_removal returns true when a type existed in the old schema but
# does not appear in the new schema, AND no explicit approval override is in place.
# Approval is granted either by the "breaking-change-approved" PR label or by the
# type name appearing in input.approved_removals.
is_breaking_removal(type_name) if {
    old_type_names := {t.name | t := input.old_schema.types[_]}
    new_type_names := {t.name | t := input.new_schema.types[_]}

    # Type existed before and is gone now
    type_name in old_type_names
    not type_name in new_type_names

    # No label-based approval
    not "breaking-change-approved" in input.labels

    # No explicit per-type removal approval
    not type_name in input.approved_removals
}

# non_null_field returns true when a field's type wrapper is NON_NULL.
# The GraphQL SDL type system wraps nullable/non-null using nested kind objects:
#   NON_NULL -> { kind: "NON_NULL", ofType: { name: "String" } }
#   nullable -> { kind: "SCALAR", name: "String" }
non_null_field(field) if {
    field.type.kind == "NON_NULL"
}

# get_old_field returns a field object from the old schema matching the given
# type name and field name. Used for before/after comparisons.
get_old_field(type_name, field_name) := field if {
    old_type := input.old_schema.types[_]
    old_type.name == type_name
    field := old_type.fields[_]
    field.name == field_name
}

# has_directive returns true when the given object's directives array contains
# a directive with the specified name.
has_directive(obj, directive_name) if {
    obj.directives[_].name == directive_name
}

# directive_arg returns the value of a named argument on the first matching
# directive. Used to inspect @deprecated(reason: "...") and @tag(name: "...").
directive_arg(obj, directive_name, arg_name) := value if {
    directive := obj.directives[_]
    directive.name == directive_name
    arg := directive.arguments[_]
    arg.name == arg_name
    value := arg.value
}

# input_type_kinds is the set of GraphQL type kinds that map to input types.
# We care about INPUT_OBJECT for the suffix and mutation argument rules.
input_type_kinds := {"INPUT_OBJECT"}

# list_return_type returns true when a field's return type (possibly wrapped
# in NON_NULL) is a LIST. GraphQL lists appear as:
#   { kind: "LIST", ofType: ... }                    (nullable list)
#   { kind: "NON_NULL", ofType: { kind: "LIST" } }   (non-null list)
list_return_type(field) if {
    field.type.kind == "LIST"
}

list_return_type(field) if {
    field.type.kind == "NON_NULL"
    field.type.ofType.kind == "LIST"
}

# is_connection_type returns true when a type name follows the Relay connection
# pattern — i.e., it ends in "Connection". Additionally, the named type must
# actually appear in the new schema with at minimum an "edges" and "pageInfo" field.
# We check both naming and structural presence to avoid false positives from types
# that happen to end in "Connection" without the correct shape.
is_connection_type(type_name) if {
    endswith(type_name, "Connection")
    conn_type := input.new_schema.types[_]
    conn_type.name == type_name
    field_names := {f.name | f := conn_type.fields[_]}
    "edges" in field_names
    "pageInfo" in field_names
}

# field_return_type_name extracts the named type from a field, unwrapping
# NON_NULL and LIST wrappers. This is used to check if the list element type
# is a Connection type.
field_return_type_name(field) := name if {
    field.type.kind == "NON_NULL"
    field.type.ofType.kind == "LIST"
    field.type.ofType.ofType.kind == "NON_NULL"
    name := field.type.ofType.ofType.ofType.name
}

field_return_type_name(field) := name if {
    field.type.kind == "NON_NULL"
    field.type.ofType.kind == "LIST"
    field.type.ofType.ofType.kind != "NON_NULL"
    name := field.type.ofType.ofType.name
}

field_return_type_name(field) := name if {
    field.type.kind == "LIST"
    field.type.ofType.kind == "NON_NULL"
    name := field.type.ofType.ofType.name
}

field_return_type_name(field) := name if {
    field.type.kind == "LIST"
    field.type.ofType.kind != "NON_NULL"
    name := field.type.ofType.name
}

# ---------------------------------------------------------------------------
# Rule 1: deny_missing_descriptions
#
# Every type definition (OBJECT, INTERFACE, INPUT_OBJECT, ENUM) and every field
# within those types must carry a non-empty description string.
#
# Rationale: Descriptions are the primary documentation surface in GraphQL.
# Schema introspection tools, GraphQL IDEs, and generated API docs rely entirely
# on description fields. Allowing undescribed types and fields degrades developer
# experience for all consumers.
#
# Excludes: introspection types (__Schema, __Type, etc.) which are built-in and
# cannot be described by schema authors.
#
# Applies to: input.new_schema.types — we only check the schema as it will exist
# after this PR, not the old schema. Authors must fix descriptions in the same PR
# that introduces or modifies a type.
# ---------------------------------------------------------------------------

# Deny any type definition that lacks a description.
deny[msg] if {
    type_def := input.new_schema.types[_]
    type_def.kind in {"OBJECT", "INTERFACE", "INPUT_OBJECT", "ENUM"}
    not is_introspection_type(type_def.name)
    not has_description(type_def)
    msg := sprintf("Type %q is missing a description. All OBJECT, INTERFACE, INPUT_OBJECT, and ENUM types must have a non-empty description string.", [type_def.name])
}

# Deny any field within a non-introspection type that lacks a description.
# We check fields on all types regardless of kind, since OBJECT, INTERFACE,
# and INPUT_OBJECT all have field arrays.
deny[msg] if {
    type_def := input.new_schema.types[_]
    not is_introspection_type(type_def.name)
    field := type_def.fields[_]
    not has_description(field)
    msg := sprintf("Field %q on type %q is missing a description. Every field must have a non-empty description string.", [field.name, type_def.name])
}

# Deny any enum value that lacks a description.
# Enum values are distinct from fields but carry the same documentation importance.
deny[msg] if {
    type_def := input.new_schema.types[_]
    type_def.kind == "ENUM"
    not is_introspection_type(type_def.name)
    enum_value := type_def.enumValues[_]
    not has_description(enum_value)
    msg := sprintf("Enum value %q on type %q is missing a description.", [enum_value.name, type_def.name])
}

# ---------------------------------------------------------------------------
# Rule 2: deny_breaking_type_removal
#
# If a type that existed in the old schema is absent from the new schema,
# this is a breaking change. The only exemptions are:
#   1. The PR carries the label "breaking-change-approved"
#   2. The type name appears in input.approved_removals (explicit per-type override)
#
# Rationale: Removing a type breaks all client queries that reference it, all
# federation subgraphs that extend it, and all codegen outputs. Removals must
# go through a formal deprecation window (at minimum one release cycle).
#
# The is_breaking_removal helper handles the approval override logic.
# ---------------------------------------------------------------------------

deny[msg] if {
    old_type := input.old_schema.types[_]
    not is_introspection_type(old_type.name)
    is_breaking_removal(old_type.name)
    msg := sprintf(
        "Breaking removal of type %q is not approved. Either add the 'breaking-change-approved' label to this PR or add the type name to the approved_removals list. Types must go through a deprecation window before removal.",
        [old_type.name]
    )
}

# ---------------------------------------------------------------------------
# Rule 3: deny_field_nullability_widening
#
# If a field was NON_NULL in the old schema and is nullable in the new schema,
# deny the change. This is a breaking change for clients that rely on the
# non-null guarantee to skip null checks.
#
# Rationale: In GraphQL, changing a field from NON_NULL to nullable is a
# breaking change for strongly-typed clients (TypeScript codegen, Swift codegen,
# etc.) because generated types change from `T` to `T | null`. Additionally,
# clients that write resolvers assuming non-null input may now receive nulls at
# runtime and crash.
#
# This rule compares old_schema fields against new_schema fields for the same
# type and field name.
# ---------------------------------------------------------------------------

deny[msg] if {
    new_type := input.new_schema.types[_]
    not is_introspection_type(new_type.name)
    new_field := new_type.fields[_]

    # Look up the corresponding field in the old schema
    old_field := get_old_field(new_type.name, new_field.name)

    # Old field was NON_NULL
    non_null_field(old_field)

    # New field is NOT NON_NULL (nullability was widened)
    not non_null_field(new_field)

    msg := sprintf(
        "Breaking change: field %q on type %q was NON_NULL and has been made nullable. This breaks clients relying on the non-null guarantee. Use a different field name or add 'breaking-change-approved' label.",
        [new_field.name, new_type.name]
    )
}

# ---------------------------------------------------------------------------
# Rule 4: deny_missing_deprecation_reason
#
# Any field or enum value annotated with @deprecated must include a non-empty
# reason argument: @deprecated(reason: "Use newField instead.")
#
# Rationale: @deprecated without a reason string leaves consumers with no
# migration path. The reason argument is the primary channel for communicating
# what to use instead. GraphQL clients, IDE plugins, and generated changelogs
# all surface the reason string.
#
# The SDL form @deprecated is shorthand for @deprecated(reason: "No longer supported.")
# which technically has a reason, but many serializers set reason to "" for
# bare @deprecated. We deny the empty-reason form as well.
# ---------------------------------------------------------------------------

deny[msg] if {
    type_def := input.new_schema.types[_]
    not is_introspection_type(type_def.name)
    field := type_def.fields[_]

    # Field carries @deprecated directive
    has_directive(field, "deprecated")

    # But the reason argument is missing or empty
    reason := directive_arg(field, "deprecated", "reason")
    reason == ""

    msg := sprintf(
        "Field %q on type %q has @deprecated but no reason. Use @deprecated(reason: \"Use someOtherField instead.\") to guide consumers to a migration path.",
        [field.name, type_def.name]
    )
}

deny[msg] if {
    type_def := input.new_schema.types[_]
    not is_introspection_type(type_def.name)
    field := type_def.fields[_]
    has_directive(field, "deprecated")

    # Reason argument is completely absent from the directive
    not directive_arg(field, "deprecated", "reason")

    msg := sprintf(
        "Field %q on type %q has @deprecated with no reason argument. Add reason: \"Use someOtherField instead.\"",
        [field.name, type_def.name]
    )
}

# ---------------------------------------------------------------------------
# Rule 5: deny_input_type_without_suffix
#
# All INPUT_OBJECT types must have names ending in "Input", "Filter", or "Args".
#
# Rationale: In a large federated schema with dozens of subgraphs, distinguishing
# input types from output types by name is critical for readability and for
# preventing confusion in codegen outputs. The suffix convention is the most
# widely adopted standard in production GraphQL schemas.
#
# Allowed suffixes: "Input" (mutations), "Filter" (query filtering), "Args" (custom)
# Example passing: CreateUserInput, ProductFilter, SearchArgs
# Example failing: UserData, UpdateUserPayload (Payload suffix should be for outputs)
# ---------------------------------------------------------------------------

# valid_input_suffixes defines the allowed suffixes for input type names.
# This is a set so that the check scales as we add more approved suffixes.
valid_input_suffixes := {"Input", "Filter", "Args"}

deny[msg] if {
    type_def := input.new_schema.types[_]
    type_def.kind == "INPUT_OBJECT"
    not is_introspection_type(type_def.name)

    # None of the valid suffixes match the type name
    valid_suffix_matches := {suffix | suffix := valid_input_suffixes[_]; endswith(type_def.name, suffix)}
    count(valid_suffix_matches) == 0

    msg := sprintf(
        "Input type %q does not end with an approved suffix. Input types must end with 'Input', 'Filter', or 'Args'. Example: %sInput.",
        [type_def.name, type_def.name]
    )
}

# ---------------------------------------------------------------------------
# Rule 6: deny_query_without_pagination
#
# Any top-level Query field whose return type is a list must use a Connection
# type (a type whose name ends in "Connection" and that has "edges" and
# "pageInfo" fields), OR the field must carry @tag(name: "no-pagination") to
# explicitly opt out.
#
# Rationale: Returning raw lists from top-level queries is a common antipattern
# that blocks future pagination rollout. Clients that bind to a [User] return
# type cannot be migrated to UserConnection without a breaking change. Requiring
# connections from the start, with an explicit opt-out escape hatch, forces
# intentional decisions about pagination at design time.
#
# The opt-out tag @tag(name: "no-pagination") must be justified in the PR
# description. Examples of legitimate opt-outs: intrinsic enumerations like
# `supportedCurrencies` that genuinely will never require pagination.
# ---------------------------------------------------------------------------

deny[msg] if {
    # Find the Query type in the new schema
    query_type := input.new_schema.types[_]
    query_type.name == "Query"

    field := query_type.fields[_]

    # Field has a list return type
    list_return_type(field)

    # Get the element type name to check if it is a connection
    element_type_name := field_return_type_name(field)

    # The element type is NOT a connection type
    not is_connection_type(element_type_name)

    # The field does not carry the explicit opt-out tag
    not has_directive(field, "tag")

    msg := sprintf(
        "Query field %q returns a list of %q but does not use a Connection type. Return a %sConnection type to support pagination, or add @tag(name: \"no-pagination\") to explicitly opt out.",
        [field.name, element_type_name, element_type_name]
    )
}

deny[msg] if {
    query_type := input.new_schema.types[_]
    query_type.name == "Query"
    field := query_type.fields[_]
    list_return_type(field)
    element_type_name := field_return_type_name(field)
    not is_connection_type(element_type_name)

    # Field has @tag but not with name: "no-pagination"
    has_directive(field, "tag")
    tag_name := directive_arg(field, "tag", "name")
    tag_name != "no-pagination"

    msg := sprintf(
        "Query field %q returns a list of %q without a Connection type. The @tag directive present is not the 'no-pagination' opt-out. Use @tag(name: \"no-pagination\") to opt out.",
        [field.name, element_type_name]
    )
}

# ---------------------------------------------------------------------------
# Rule 7: warn_field_without_tag (advisory only — does not block)
#
# Top-level Query and Mutation fields that are missing an @tag directive
# generate a warning. Tags are used in Apollo Federation to control schema
# exposure per variant (e.g., @tag(name: "internal") hides a field from the
# public variant).
#
# This is a warn rather than deny because not all organizations use tag-based
# variant filtering, and adding it as a hard requirement would block adoption.
# The warning encourages teams to consciously decide tag assignments.
# ---------------------------------------------------------------------------

warn[msg] if {
    root_type := input.new_schema.types[_]
    root_type.name in {"Query", "Mutation"}
    field := root_type.fields[_]
    not has_directive(field, "tag")
    msg := sprintf(
        "Advisory: %s field %q is missing an @tag directive. Consider adding @tag(name: \"public\") or @tag(name: \"internal\") to control schema variant exposure.",
        [root_type.name, field.name]
    )
}

# ---------------------------------------------------------------------------
# Rule 8: deny_mutation_without_input_type
#
# All mutation fields must accept exactly one argument named "input" whose
# type is a NON_NULL INPUT_OBJECT (ending in "Input", "Filter", or "Args").
#
# Rationale: The single-input-argument mutation pattern is the industry standard
# (adopted by GitHub, Shopify, and most large-scale GraphQL APIs) because:
#   1. Adding optional arguments to the input type is non-breaking
#   2. Clients get consistent codegen output (always a single `input` variable)
#   3. Input validation is centralized on the input type, not scattered across args
#
# Mutations with multiple arguments or with non-Input-type arguments violate
# this convention and cause long-term maintenance problems.
#
# A mutation PASSES this rule if:
#   - It has exactly one argument
#   - That argument is named "input"
#   - That argument's type is NON_NULL
#   - The NON_NULL wraps an INPUT_OBJECT type (we check suffix as a proxy for kind
#     since the input document may not always include full kind metadata)
# ---------------------------------------------------------------------------

deny[msg] if {
    mutation_type := input.new_schema.types[_]
    mutation_type.name == "Mutation"
    field := mutation_type.fields[_]

    # Mutation has arguments (if no arguments, this rule does not apply — some
    # mutations like triggerBuild may take no inputs)
    count(field.args) > 0

    # Check if there is a valid single "input" argument
    input_args := [a | a := field.args[_]; a.name == "input"]
    count(input_args) == 0

    msg := sprintf(
        "Mutation %q does not have an argument named 'input'. Mutations must accept a single 'input: SomethingInput!' argument. Found args: %v",
        [field.name, [a.name | a := field.args[_]]]
    )
}

deny[msg] if {
    mutation_type := input.new_schema.types[_]
    mutation_type.name == "Mutation"
    field := mutation_type.fields[_]
    count(field.args) > 1

    # Multiple arguments — even if one is named "input", this violates the pattern
    msg := sprintf(
        "Mutation %q has %d arguments. Mutations must accept a single 'input: SomethingInput!' argument.",
        [field.name, count(field.args)]
    )
}

deny[msg] if {
    mutation_type := input.new_schema.types[_]
    mutation_type.name == "Mutation"
    field := mutation_type.fields[_]
    count(field.args) == 1

    # Single argument exists
    the_arg := field.args[0]
    the_arg.name == "input"

    # But the argument type is not NON_NULL (input should always be required)
    not non_null_field(the_arg)

    msg := sprintf(
        "Mutation %q has 'input' argument that is nullable. The input argument must be NON_NULL: input: SomethingInput!",
        [field.name]
    )
}

deny[msg] if {
    mutation_type := input.new_schema.types[_]
    mutation_type.name == "Mutation"
    field := mutation_type.fields[_]
    count(field.args) == 1
    the_arg := field.args[0]
    the_arg.name == "input"
    non_null_field(the_arg)

    # The NON_NULL wraps a type — check that the type name ends with a valid input suffix
    inner_type_name := the_arg.type.ofType.name
    valid_suffix_matches := {suffix | suffix := valid_input_suffixes[_]; endswith(inner_type_name, suffix)}
    count(valid_suffix_matches) == 0

    msg := sprintf(
        "Mutation %q has 'input: %s!' but %s does not end with an approved suffix (Input, Filter, Args). Rename the input type accordingly.",
        [field.name, inner_type_name, inner_type_name]
    )
}
