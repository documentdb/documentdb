# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Keep the small public-driver profile aligned with its advertised coverage."""

import ast

import pytest

from compatibility.contracts import DEMONSTRATION_TEST, ROOT

pytestmark = pytest.mark.unit


def test_registry_contains_only_the_pymongo_pilot(registry):
    assert list(registry["integrations"]) == ["pymongo"]
    assert registry["integrations"]["pymongo"]["enabled"]


def test_declared_scenarios_match_real_test_functions(registry):
    spec = registry["integrations"]["pymongo"]
    tree = ast.parse((ROOT / spec["test_file"]).read_text())
    names = [
        node.name
        for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name.startswith("test_")
    ]
    assert names == spec["expected_tests"]
    demonstration = ast.parse((ROOT / spec["demonstration_file"]).read_text())
    assert [node.name for node in demonstration.body if isinstance(node, ast.FunctionDef)] == [
        DEMONSTRATION_TEST
    ]


def test_profile_uses_driver_methods_not_a_raw_command_adapter(registry):
    tree = ast.parse((ROOT / registry["integrations"]["pymongo"]["test_file"]).read_text())
    methods = {
        node.func.attr
        for node in ast.walk(tree)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
    }
    assert {
        "insert_one",
        "insert_many",
        "find_one",
        "find",
        "sort",
        "limit",
        "batch_size",
        "count_documents",
        "update_one",
        "find_one_and_update",
        "delete_one",
        "delete_many",
        "aggregate",
        "create_indexes",
        "create_index",
        "list_indexes",
        "drop_index",
    }.issubset(methods)
    raw_commands = [
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "command"
    ]
    assert len(raw_commands) == 1
    assert ast.literal_eval(raw_commands[0].args[0]) == "ping"
