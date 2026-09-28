# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Keep the small public-driver profile aligned with its advertised coverage."""

import ast

import pytest

from compatibility.contracts import DEMONSTRATION_TEST, ROOT, read_registry

pytestmark = pytest.mark.unit


@pytest.mark.parametrize("integration", read_registry()["integrations"])
def test_declared_scenarios_match_real_test_functions(registry, integration):
    spec = registry["integrations"][integration]
    tree = ast.parse((ROOT / spec["test_file"]).read_text())
    names = [
        node.name
        for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name.startswith("test_")
    ]
    assert sorted(names) == sorted(spec["expected_tests"])
    demonstration = ast.parse((ROOT / spec["demonstration_file"]).read_text())
    assert [
        node.name
        for node in demonstration.body
        if isinstance(node, ast.FunctionDef) and node.name.startswith("test_")
    ] == [DEMONSTRATION_TEST]
