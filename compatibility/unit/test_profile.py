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
