# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Keep the small public-driver profile aligned with its advertised coverage."""

import ast
import re

import pytest

from compatibility.contracts import DEMONSTRATION_TEST, ROOT, read_registry

pytestmark = pytest.mark.unit


def scenario_names(path):
    if path.suffix == ".cjs":
        return re.findall(r"^async function (test_[a-z0-9_]+)\(", path.read_text(), re.M)
    tree = ast.parse(path.read_text())
    return [
        node.name
        for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name.startswith("test_")
    ]


@pytest.mark.parametrize("integration", read_registry()["integrations"])
def test_declared_scenarios_match_real_test_functions(registry, integration):
    spec = registry["integrations"][integration]
    assert sorted(scenario_names(ROOT / spec["test_file"])) == sorted(spec["expected_tests"])
    assert scenario_names(ROOT / spec["demonstration_file"]) == [DEMONSTRATION_TEST]
