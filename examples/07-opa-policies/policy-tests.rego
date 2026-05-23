# Policy Tests — OPA Unit Tests for schema-governance-policies.rego
#
# Companion documentation: ../../docs/13-policy-as-code/
#
# Run these tests with:
#   opa test schema-governance-policies.rego policy-tests.rego -v
#
# Each test function begins with "test_" per OPA convention. Tests use the
# "with input as" clause to supply controlled input documents, allowing
# deterministic assertions on rule behavior without external files.
#
# Test naming convention: test_<rule_name>_<scenario>
#   _fails  — expects the deny/warn set to be non-empty
#   _passes — expects the deny/warn set to be empty

package graphql.schema

import future.keywords.if
import future.keywords.in

# ---------------------------------------------------------------------------
# Tests for Rule 1: deny_missing_descriptions
# ---------------------------------------------------------------------------

# test_description_required_fails
# Verifies that an OBJECT type with no description produces exactly one deny
# message. The type has one field which is also undescribed, so we expect two
# denies: one for the type and one for the field.
test_description_required_type_fails if {
    violations := deny with input as {
        "old_schema": {"types": []},
        "new_schema": {"types": [
            {
                "name": "UserProfile",
                "kind": "OBJECT",
                "description": "",        # empty — should trigger deny
                "fields": [
                    {
                        "name": "id",
                        "description": "The unique identifier.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "ID"}},
                        "directives": []
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    # Exactly one violation: the type-level description is missing
    count(violations) == 1
    some v in violations
    contains(v, "UserProfile")
    contains(v, "missing a description")
}

# test_description_required_field_fails
# Verifies that a field with no description produces a deny, even when its
# parent type has a valid description.
test_description_required_field_fails if {
    violations := deny with input as {
        "old_schema": {"types": []},
        "new_schema": {"types": [
            {
                "name": "Product",
                "kind": "OBJECT",
                "description": "A catalog product.",
                "fields": [
                    {
                        "name": "sku",
                        "description": "",   # empty — should trigger deny
                        "type": {"kind": "NON_NULL", "ofType": {"name": "String"}},
                        "directives": []
                    },
                    {
                        "name": "name",
                        "description": "The product display name.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "String"}},
                        "directives": []
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    count(violations) == 1
    some v in violations
    contains(v, "sku")
    contains(v, "Product")
}

# test_description_required_passes
# A fully described type and all its fields — expect zero deny violations.
test_description_required_passes if {
    violations := deny with input as {
        "old_schema": {"types": []},
        "new_schema": {"types": [
            {
                "name": "Order",
                "kind": "OBJECT",
                "description": "A customer order record.",
                "fields": [
                    {
                        "name": "id",
                        "description": "The unique order identifier.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "ID"}},
                        "directives": []
                    },
                    {
                        "name": "total",
                        "description": "The total order amount in cents.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "Int"}},
                        "directives": []
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    count(violations) == 0
}

# test_introspection_types_excluded
# The __Schema introspection type with no description must NOT trigger a deny.
# Introspection types are built-in and schema authors cannot add descriptions.
test_introspection_types_excluded if {
    violations := deny with input as {
        "old_schema": {"types": []},
        "new_schema": {"types": [
            {
                "name": "__Schema",
                "kind": "OBJECT",
                "description": "",   # empty, but should be excluded
                "fields": [
                    {
                        "name": "types",
                        "description": "",
                        "type": {"kind": "LIST", "ofType": {"name": "__Type"}},
                        "directives": []
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    # Introspection type should be completely excluded from description checks
    count(violations) == 0
}

# test_enum_value_description_fails
# Enum values without descriptions must also trigger denies.
test_enum_value_description_fails if {
    violations := deny with input as {
        "old_schema": {"types": []},
        "new_schema": {"types": [
            {
                "name": "OrderStatus",
                "kind": "ENUM",
                "description": "The current status of an order.",
                "fields": [],
                "enumValues": [
                    {
                        "name": "PENDING",
                        "description": "",   # missing
                        "directives": []
                    },
                    {
                        "name": "CONFIRMED",
                        "description": "Order has been confirmed by the merchant.",
                        "directives": []
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    count(violations) == 1
    some v in violations
    contains(v, "PENDING")
}

# ---------------------------------------------------------------------------
# Tests for Rule 2: deny_breaking_type_removal
# ---------------------------------------------------------------------------

# test_breaking_type_removal_fails
# A type present in old_schema that is absent from new_schema should produce
# a deny. No approval label or approved_removals entry is present.
test_breaking_type_removal_fails if {
    violations := deny with input as {
        "old_schema": {"types": [
            {
                "name": "LegacyOrder",
                "kind": "OBJECT",
                "description": "The legacy order type.",
                "fields": [],
                "directives": []
            }
        ]},
        "new_schema": {"types": []},   # LegacyOrder removed without approval
        "labels": [],
        "approved_removals": []
    }
    count(violations) == 1
    some v in violations
    contains(v, "LegacyOrder")
    contains(v, "Breaking removal")
}

# test_breaking_type_removal_passes
# Same type in both old and new schema — no removal, no violation.
test_breaking_type_removal_passes if {
    same_types := [
        {
            "name": "User",
            "kind": "OBJECT",
            "description": "A user account.",
            "fields": [],
            "directives": []
        }
    ]
    violations := deny with input as {
        "old_schema": {"types": same_types},
        "new_schema": {"types": same_types},
        "labels": [],
        "approved_removals": []
    }
    # Filter to only breaking-removal violations to isolate this rule
    removal_violations := {v | v := violations[_]; contains(v, "Breaking removal")}
    count(removal_violations) == 0
}

# test_breaking_type_removal_approved_by_label
# Type removed but the PR carries the "breaking-change-approved" label.
# Should produce zero breaking-removal denies.
test_breaking_type_removal_approved_by_label if {
    violations := deny with input as {
        "old_schema": {"types": [
            {
                "name": "DeprecatedPaymentMethod",
                "kind": "OBJECT",
                "description": "An old payment method type.",
                "fields": [],
                "directives": []
            }
        ]},
        "new_schema": {"types": []},
        "labels": ["breaking-change-approved"],   # explicit approval
        "approved_removals": []
    }
    removal_violations := {v | v := violations[_]; contains(v, "Breaking removal")}
    count(removal_violations) == 0
}

# test_breaking_type_removal_approved_per_type
# Type is in approved_removals — the per-type approval mechanism.
test_breaking_type_removal_approved_per_type if {
    violations := deny with input as {
        "old_schema": {"types": [
            {
                "name": "V1Product",
                "kind": "OBJECT",
                "description": "Version 1 product.",
                "fields": [],
                "directives": []
            }
        ]},
        "new_schema": {"types": []},
        "labels": [],
        "approved_removals": ["V1Product"]   # per-type approval
    }
    removal_violations := {v | v := violations[_]; contains(v, "Breaking removal")}
    count(removal_violations) == 0
}

# ---------------------------------------------------------------------------
# Tests for Rule 3: deny_field_nullability_widening
# ---------------------------------------------------------------------------

# test_nullability_widening_fails
# A field that was NON_NULL in the old schema is nullable in the new schema.
test_nullability_widening_fails if {
    violations := deny with input as {
        "old_schema": {"types": [
            {
                "name": "User",
                "kind": "OBJECT",
                "description": "A user.",
                "fields": [
                    {
                        "name": "email",
                        "description": "The user email.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "String"}},   # was non-null
                        "directives": []
                    }
                ],
                "directives": []
            }
        ]},
        "new_schema": {"types": [
            {
                "name": "User",
                "kind": "OBJECT",
                "description": "A user.",
                "fields": [
                    {
                        "name": "email",
                        "description": "The user email.",
                        "type": {"kind": "SCALAR", "name": "String"},   # now nullable — breaking
                        "directives": []
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    nullability_violations := {v | v := violations[_]; contains(v, "NON_NULL")}
    count(nullability_violations) == 1
    some v in nullability_violations
    contains(v, "email")
    contains(v, "User")
}

# test_nullability_widening_passes_nullable_to_nonnull
# Making a nullable field non-null is a non-breaking change for clients
# (they receive stronger guarantees). This should not trigger a deny.
test_nullability_widening_passes_nullable_to_nonnull if {
    violations := deny with input as {
        "old_schema": {"types": [
            {
                "name": "Product",
                "kind": "OBJECT",
                "description": "A product.",
                "fields": [
                    {
                        "name": "price",
                        "description": "The price in cents.",
                        "type": {"kind": "SCALAR", "name": "Int"},   # was nullable
                        "directives": []
                    }
                ],
                "directives": []
            }
        ]},
        "new_schema": {"types": [
            {
                "name": "Product",
                "kind": "OBJECT",
                "description": "A product.",
                "fields": [
                    {
                        "name": "price",
                        "description": "The price in cents.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "Int"}},   # now non-null
                        "directives": []
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    nullability_violations := {v | v := violations[_]; contains(v, "NON_NULL")}
    count(nullability_violations) == 0
}

# ---------------------------------------------------------------------------
# Tests for Rule 4: deny_missing_deprecation_reason
# ---------------------------------------------------------------------------

# test_deprecation_without_reason_fails
# A field with @deprecated but no reason argument should trigger a deny.
test_deprecation_without_reason_fails if {
    violations := deny with input as {
        "old_schema": {"types": []},
        "new_schema": {"types": [
            {
                "name": "User",
                "kind": "OBJECT",
                "description": "A user account.",
                "fields": [
                    {
                        "name": "legacyId",
                        "description": "Deprecated legacy identifier.",
                        "type": {"kind": "SCALAR", "name": "String"},
                        "directives": [
                            {
                                "name": "deprecated",
                                "arguments": [
                                    {"name": "reason", "value": ""}   # empty reason
                                ]
                            }
                        ]
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    deprecation_violations := {v | v := violations[_]; contains(v, "deprecated")}
    count(deprecation_violations) >= 1
    some v in deprecation_violations
    contains(v, "legacyId")
}

# test_deprecation_with_reason_passes
# @deprecated with a non-empty reason should not produce a deny.
test_deprecation_with_reason_passes if {
    violations := deny with input as {
        "old_schema": {"types": []},
        "new_schema": {"types": [
            {
                "name": "User",
                "kind": "OBJECT",
                "description": "A user account.",
                "fields": [
                    {
                        "name": "legacyId",
                        "description": "Deprecated legacy identifier.",
                        "type": {"kind": "SCALAR", "name": "String"},
                        "directives": [
                            {
                                "name": "deprecated",
                                "arguments": [
                                    {"name": "reason", "value": "Use User.id instead."}
                                ]
                            }
                        ]
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    deprecation_violations := {v | v := violations[_]; contains(v, "deprecated")}
    count(deprecation_violations) == 0
}

# ---------------------------------------------------------------------------
# Tests for Rule 5: deny_input_type_without_suffix
# ---------------------------------------------------------------------------

# test_input_suffix_required
# An INPUT_OBJECT named "UserData" (no valid suffix) should trigger a deny.
test_input_suffix_required if {
    violations := deny with input as {
        "old_schema": {"types": []},
        "new_schema": {"types": [
            {
                "name": "UserData",       # missing Input/Filter/Args suffix
                "kind": "INPUT_OBJECT",
                "description": "Input data for creating a user.",
                "fields": [
                    {
                        "name": "name",
                        "description": "The user name.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "String"}},
                        "directives": []
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    suffix_violations := {v | v := violations[_]; contains(v, "suffix")}
    count(suffix_violations) == 1
    some v in suffix_violations
    contains(v, "UserData")
}

# test_input_suffix_passes
# "UserDataInput" ends with "Input" — should pass with no suffix deny.
test_input_suffix_passes if {
    violations := deny with input as {
        "old_schema": {"types": []},
        "new_schema": {"types": [
            {
                "name": "UserDataInput",
                "kind": "INPUT_OBJECT",
                "description": "Input data for creating a user.",
                "fields": [
                    {
                        "name": "name",
                        "description": "The user name.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "String"}},
                        "directives": []
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    suffix_violations := {v | v := violations[_]; contains(v, "suffix")}
    count(suffix_violations) == 0
}

# test_input_filter_suffix_passes
# "ProductFilter" ends with "Filter" — should also pass.
test_input_filter_suffix_passes if {
    violations := deny with input as {
        "old_schema": {"types": []},
        "new_schema": {"types": [
            {
                "name": "ProductFilter",
                "kind": "INPUT_OBJECT",
                "description": "Filter criteria for product queries.",
                "fields": [
                    {
                        "name": "categoryId",
                        "description": "Filter by category.",
                        "type": {"kind": "SCALAR", "name": "ID"},
                        "directives": []
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    suffix_violations := {v | v := violations[_]; contains(v, "suffix")}
    count(suffix_violations) == 0
}

# ---------------------------------------------------------------------------
# Tests for Rule 8: deny_mutation_without_input_type
# ---------------------------------------------------------------------------

# test_mutation_input_arg_required
# A mutation with a direct scalar argument (not an input type) should be denied.
test_mutation_input_arg_required if {
    violations := deny with input as {
        "old_schema": {"types": []},
        "new_schema": {"types": [
            {
                "name": "Mutation",
                "kind": "OBJECT",
                "description": "Root mutation type.",
                "fields": [
                    {
                        "name": "createUser",
                        "description": "Create a new user account.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "User"}},
                        "args": [
                            {
                                "name": "name",          # scalar arg, not "input"
                                "description": "The user name.",
                                "type": {"kind": "NON_NULL", "ofType": {"name": "String"}},
                                "directives": []
                            }
                        ],
                        "directives": []
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    mutation_violations := {v | v := violations[_]; contains(v, "createUser")}
    count(mutation_violations) >= 1
    some v in mutation_violations
    contains(v, "input")
}

# test_mutation_input_arg_passes
# A mutation with a single "input: CreateUserInput!" argument should pass.
test_mutation_input_arg_passes if {
    violations := deny with input as {
        "old_schema": {"types": []},
        "new_schema": {"types": [
            {
                "name": "Mutation",
                "kind": "OBJECT",
                "description": "Root mutation type.",
                "fields": [
                    {
                        "name": "createUser",
                        "description": "Create a new user account.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "User"}},
                        "args": [
                            {
                                "name": "input",
                                "description": "The user creation input.",
                                "type": {
                                    "kind": "NON_NULL",
                                    "ofType": {"name": "CreateUserInput", "kind": "INPUT_OBJECT"}
                                },
                                "directives": []
                            }
                        ],
                        "directives": []
                    }
                ],
                "directives": []
            },
            {
                "name": "CreateUserInput",
                "kind": "INPUT_OBJECT",
                "description": "Input for the createUser mutation.",
                "fields": [
                    {
                        "name": "name",
                        "description": "The user name.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "String"}},
                        "directives": []
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    mutation_violations := {v | v := violations[_]; contains(v, "createUser")}
    count(mutation_violations) == 0
}

# test_mutation_multiple_args_fails
# A mutation with two arguments — even if one is "input" — should be denied.
test_mutation_multiple_args_fails if {
    violations := deny with input as {
        "old_schema": {"types": []},
        "new_schema": {"types": [
            {
                "name": "Mutation",
                "kind": "OBJECT",
                "description": "Root mutation type.",
                "fields": [
                    {
                        "name": "updateProduct",
                        "description": "Update a product.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "Product"}},
                        "args": [
                            {
                                "name": "id",
                                "description": "The product ID.",
                                "type": {"kind": "NON_NULL", "ofType": {"name": "ID"}},
                                "directives": []
                            },
                            {
                                "name": "input",
                                "description": "The update data.",
                                "type": {
                                    "kind": "NON_NULL",
                                    "ofType": {"name": "UpdateProductInput", "kind": "INPUT_OBJECT"}
                                },
                                "directives": []
                            }
                        ],
                        "directives": []
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    mutation_violations := {v | v := violations[_]; contains(v, "updateProduct")}
    count(mutation_violations) == 1
    some v in mutation_violations
    contains(v, "2")  # error message mentions the count
}

# ---------------------------------------------------------------------------
# Tests for Rule 7: warn_field_without_tag (warn set, not deny set)
# ---------------------------------------------------------------------------

# test_warn_missing_tag_query_field
# A Query field without @tag should produce a warning.
test_warn_missing_tag_query_field if {
    advisories := warn with input as {
        "old_schema": {"types": []},
        "new_schema": {"types": [
            {
                "name": "Query",
                "kind": "OBJECT",
                "description": "Root query type.",
                "fields": [
                    {
                        "name": "users",
                        "description": "List all users.",
                        "type": {"kind": "LIST", "ofType": {"name": "UserConnection"}},
                        "args": [],
                        "directives": []   # no @tag
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    count(advisories) >= 1
    some a in advisories
    contains(a, "users")
    contains(a, "tag")
}

# test_warn_tag_present_no_warning
# A Query field with @tag should not produce a warning.
test_warn_tag_present_no_warning if {
    advisories := warn with input as {
        "old_schema": {"types": []},
        "new_schema": {"types": [
            {
                "name": "Query",
                "kind": "OBJECT",
                "description": "Root query type.",
                "fields": [
                    {
                        "name": "users",
                        "description": "List all users.",
                        "type": {"kind": "LIST", "ofType": {"name": "UserConnection"}},
                        "args": [],
                        "directives": [
                            {
                                "name": "tag",
                                "arguments": [{"name": "name", "value": "internal"}]
                            }
                        ]
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    tag_warnings := {a | a := advisories[_]; contains(a, "users")}
    count(tag_warnings) == 0
}

# ---------------------------------------------------------------------------
# Integration test: clean schema with all rules satisfied
#
# A complete minimal schema that passes every deny rule should produce zero
# deny violations. This test acts as a regression guard — if any rule is
# accidentally too broad, this will catch it.
# ---------------------------------------------------------------------------

test_clean_schema_no_violations if {
    violations := deny with input as {
        "old_schema": {"types": [
            {
                "name": "User",
                "kind": "OBJECT",
                "description": "A platform user account.",
                "fields": [
                    {
                        "name": "id",
                        "description": "The unique identifier.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "ID"}},
                        "directives": []
                    },
                    {
                        "name": "email",
                        "description": "The user email address.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "String"}},
                        "directives": []
                    }
                ],
                "directives": []
            }
        ]},
        "new_schema": {"types": [
            {
                "name": "User",
                "kind": "OBJECT",
                "description": "A platform user account.",
                "fields": [
                    {
                        "name": "id",
                        "description": "The unique identifier.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "ID"}},
                        "directives": []
                    },
                    {
                        "name": "email",
                        "description": "The user email address.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "String"}},
                        "directives": []
                    }
                ],
                "directives": []
            },
            {
                "name": "CreateUserInput",
                "kind": "INPUT_OBJECT",
                "description": "Input for creating a new user.",
                "fields": [
                    {
                        "name": "email",
                        "description": "The email address for the new user.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "String"}},
                        "directives": []
                    }
                ],
                "directives": []
            },
            {
                "name": "Mutation",
                "kind": "OBJECT",
                "description": "Root mutation type.",
                "fields": [
                    {
                        "name": "createUser",
                        "description": "Create a new user account.",
                        "type": {"kind": "NON_NULL", "ofType": {"name": "User"}},
                        "args": [
                            {
                                "name": "input",
                                "description": "The user creation data.",
                                "type": {
                                    "kind": "NON_NULL",
                                    "ofType": {"name": "CreateUserInput", "kind": "INPUT_OBJECT"}
                                },
                                "directives": []
                            }
                        ],
                        "directives": [
                            {
                                "name": "tag",
                                "arguments": [{"name": "name", "value": "internal"}]
                            }
                        ]
                    }
                ],
                "directives": []
            }
        ]},
        "labels": [],
        "approved_removals": []
    }
    count(violations) == 0
}
