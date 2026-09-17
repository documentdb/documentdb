# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Contract validation and fail-closed compatibility classification."""

from copy import deepcopy
from datetime import datetime, timedelta, timezone

import pytest

from compatibility.contracts import (
    compatibility_state,
    suite_digest,
    validate_client_report,
    validate_result,
    validate_schema,
)

pytestmark = pytest.mark.unit


def test_complete_execution_is_working(record):
    validate_result(record)
    assert compatibility_state(record) == "Working"


@pytest.mark.parametrize("outcome", ["skipped", "error"])
def test_incomplete_execution_is_not_tested(record, outcome):
    record["tests"][0]["outcome"] = outcome
    assert compatibility_state(record) == "Not tested"


def test_zero_tests_cannot_pass(record):
    record["tests"] = []
    assert compatibility_state(record) == "Not tested"


def test_missing_required_test_cannot_pass(record):
    record["tests"].pop()
    assert compatibility_state(record) == "Not tested"


def test_wrong_installed_version_cannot_pass(record):
    record["upstream"]["actual_version"] = "4.17.0"
    assert compatibility_state(record) == "Not tested"


def test_unverified_database_cannot_pass(record):
    record["documentdb"]["actual_extension_version"] = None
    assert compatibility_state(record) == "Not tested"


def test_assertion_failure_survives_cleanup_error(record):
    record["tests"][0]["outcome"] = "failed"
    record["execution_error"] = "Cleanup failed"
    assert compatibility_state(record) == "Failing"


def test_duplicate_test_outcomes_rejected(record):
    record["tests"].append(deepcopy(record["tests"][0]))
    with pytest.raises(ValueError, match="Duplicate"):
        validate_result(record)


def test_undeclared_test_rejected(record):
    record["tests"][0]["id"] = "test_undeclared"
    with pytest.raises(ValueError, match="undeclared"):
        validate_result(record)


def test_coverage_cannot_be_reduced_by_a_report(record, registry):
    record["expected_tests"].pop()
    record["tests"].pop()
    with pytest.raises(ValueError, match="coverage"):
        validate_result(record, registry["integrations"]["pymongo"])


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("id", "../../outside"),
        ("run_url", "javascript:alert(1)"),
        ("run_url", "https://example.test/actions/runs/1"),
        ("started_at", "2026-01-01T00:00:00"),
        ("schema_version", 2),
    ],
)
def test_unsafe_or_malformed_fields_rejected(record, field, value):
    record[field] = value
    with pytest.raises(ValueError):
        validate_result(record)


def test_future_result_rejected(record):
    record["finished_at"] = (datetime.now(timezone.utc) + timedelta(days=1)).isoformat()
    with pytest.raises(ValueError, match="future"):
        validate_result(record)


def test_unknown_fields_rejected(record):
    record["credentials"] = "not-a-real-secret"
    with pytest.raises(ValueError, match="additionalProperties"):
        validate_result(record)


def test_owner_required(registry):
    del registry["integrations"]["pymongo"]["owner"]
    with pytest.raises(ValueError):
        validate_schema(registry, "registry")


def test_mutable_database_image_rejected(registry):
    registry["documentdb"]["0.117.0"][
        "image"
    ] = "ghcr.io/documentdb/documentdb/documentdb-local:latest"
    with pytest.raises(ValueError):
        validate_schema(registry, "registry")


def test_invalid_client_envelope_rejected():
    with pytest.raises(ValueError, match="client report"):
        validate_client_report({"tests": "passed"})


def test_prepared_build_context_preserves_the_reviewed_suite(prepared_context, registry):
    spec = registry["integrations"]["pymongo"]
    assert suite_digest("pymongo", spec, prepared_context) == suite_digest("pymongo", spec)


@pytest.mark.parametrize(
    "filename",
    [
        "compatibility/requirements.txt",
        "compatibility/pyproject.toml",
        "compatibility/schemas/result.json",
        "compatibility/runner.py",
        "compatibility/integrations/pymongo/Dockerfile",
        "compatibility/integrations/pymongo/requirements.txt",
    ],
)
def test_runtime_or_configuration_changes_invalidate_results(prepared_context, registry, filename):
    spec = registry["integrations"]["pymongo"]
    original = suite_digest("pymongo", spec, prepared_context)
    path = prepared_context / filename
    path.write_text(path.read_text() + "\n")
    assert suite_digest("pymongo", spec, prepared_context) != original


def test_adapter_selection_is_part_of_the_suite_identity(registry):
    spec = registry["integrations"]["pymongo"]
    original = suite_digest("pymongo", spec)
    spec["test_file"] = spec["demonstration_file"]
    assert suite_digest("pymongo", spec) != original
