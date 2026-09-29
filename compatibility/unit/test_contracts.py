# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Contract validation and fail-closed compatibility classification."""

from copy import deepcopy
from datetime import datetime, timedelta, timezone

import pytest

from compatibility.contracts import (
    artifact_sha256,
    compatibility_state,
    result_runtime,
    suite_digest,
    validate_client_report,
    validate_result,
    validate_schema,
)

pytestmark = pytest.mark.unit


def test_complete_execution_is_working(record):
    validate_result(record)
    assert compatibility_state(record) == "Working"


@pytest.mark.parametrize(
    ("requested", "installed"),
    [("4.9.0", "4.9"), ("4.11.0", "4.11"), ("4.9.1", "4.9.1")],
)
def test_equivalent_installed_versions_are_working(record, requested, installed):
    upstream = record["upstream"]
    upstream["version"] = requested
    upstream["actual_version"] = installed
    upstream["dependencies"][0]["version"] = installed
    validate_client_report(
        {
            "version": installed,
            "runtime": upstream["runtime"],
            "artifact_sha256": upstream["artifact_sha256"],
            "exit_code": 0,
            "tests": record["tests"],
            "junit": "",
            "dependencies": upstream["dependencies"],
        }
    )
    validate_result(record)
    assert compatibility_state(record) == "Working"


def test_missing_installed_version_cannot_pass(record):
    record["upstream"]["actual_version"] = None
    assert compatibility_state(record) == "Not tested"


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


def test_wrong_installed_version_cannot_pass(record, other_version):
    record["upstream"]["actual_version"] = other_version
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
        validate_result(record, registry["integrations"][record["integration"]])


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("id", "../../outside"),
        ("run_url", "javascript:alert(1)"),
        ("run_url", "https://example.test/actions/runs/1"),
        ("started_at", "2026-01-01T00:00:00"),
        ("schema_version", 3),
    ],
)
def test_unsafe_or_malformed_fields_rejected(record, field, value):
    record[field] = value
    with pytest.raises(ValueError):
        validate_result(record)


@pytest.mark.parametrize("suffix", ["", "/attempts/1", "/attempts/23"])
def test_pipeline_links_can_identify_a_specific_attempt(record, suffix):
    record["run_url"] = "https://github.com/example/project/actions/runs/42" + suffix
    validate_result(record)


@pytest.mark.parametrize(
    "suffix", ["/attempts/0", "/attempts/01", "/attempts/x", "/attempts/1/extra"]
)
def test_malformed_attempt_links_are_rejected(record, suffix):
    record["run_url"] = "https://github.com/example/project/actions/runs/42" + suffix
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


def test_owner_required(registry, selection):
    del registry["integrations"][selection["integration"]]["owner"]
    with pytest.raises(ValueError):
        validate_schema(registry, "registry")


def test_mutable_database_image_rejected(registry, selection):
    database = registry["documentdb"][selection["documentdb_version"]]
    database["image"] = database["image"].split("@", 1)[0] + ":latest"
    with pytest.raises(ValueError):
        validate_schema(registry, "registry")


def test_invalid_client_envelope_rejected():
    with pytest.raises(ValueError, match="client report"):
        validate_client_report({"tests": "passed"})


def test_legacy_python_records_remain_unchanged_and_readable(record, registry):
    record["schema_version"] = 1
    upstream = record["upstream"]
    upstream["wheel_sha256"] = upstream.pop("artifact_sha256")
    upstream["python_version"] = upstream.pop("runtime")["version"]
    original = deepcopy(record)
    validate_result(record, registry["integrations"][record["integration"]])
    assert compatibility_state(record) == "Working"
    assert artifact_sha256(record) == upstream["wheel_sha256"]
    assert result_runtime(record) == {"name": "python", "version": upstream["python_version"]}
    assert record == original


def test_node_result_and_scoped_dependency_names_are_valid(record, registry):
    spec = registry["integrations"]["nodejs"]
    record.update(
        integration="nodejs", **{key: spec[key] for key in ("repository", "owner", "profile")}
    )
    record["expected_tests"] = list(spec["expected_tests"])
    record["tests"] = [
        {"id": name, "outcome": "passed", "message": ""} for name in spec["expected_tests"]
    ]
    record["upstream"].update(
        version=spec["default_version"],
        actual_version=spec["default_version"],
        runtime={"name": "nodejs", "version": "24.0.0"},
    )
    record["upstream"]["dependencies"].append(
        {"name": "@example/dependency", "version": "1.0.0", "sha256": "d" * 64}
    )
    validate_result(record, spec)
    assert compatibility_state(record) == "Working"


@pytest.mark.parametrize("version", ["20.0.0", "3.12.0"])
def test_node_result_requires_the_reviewed_runtime(record, version):
    record["upstream"]["runtime"] = {"name": "nodejs", "version": version}
    with pytest.raises(ValueError, match="runtime"):
        validate_result(record)


def test_python_profile_cannot_accept_node_results(record, registry):
    record["upstream"]["runtime"] = {"name": "nodejs", "version": "24.0.0"}
    with pytest.raises(ValueError, match="runtime"):
        validate_result(record, registry["integrations"][record["integration"]])


def test_result_versions_cannot_mix_legacy_and_current_provenance(record):
    record["upstream"]["wheel_sha256"] = "b" * 64
    with pytest.raises(ValueError):
        validate_result(record)


def test_prepared_build_context_preserves_the_reviewed_suite(prepared_context, registry, selection):
    integration = selection["integration"]
    spec = registry["integrations"][integration]
    assert suite_digest(integration, spec, prepared_context) == suite_digest(integration, spec)


@pytest.mark.parametrize(
    "filename",
    [
        "compatibility/requirements.txt",
        "compatibility/pyproject.toml",
        "compatibility/schemas/result.json",
        "compatibility/runner.py",
        "compatibility/npm.py",
        "compatibility/integrations/pymongo/Dockerfile",
        "compatibility/integrations/pymongo/requirements.txt",
    ],
)
def test_runtime_or_configuration_changes_invalidate_results(
    prepared_context, registry, selection, filename
):
    integration = selection["integration"]
    spec = registry["integrations"][integration]
    original = suite_digest(integration, spec, prepared_context)
    path = prepared_context / filename
    path.write_text(path.read_text() + "\n")
    assert suite_digest(integration, spec, prepared_context) != original


def test_adapter_selection_is_part_of_the_suite_identity(registry, selection):
    integration = selection["integration"]
    spec = registry["integrations"][integration]
    original = suite_digest(integration, spec)
    spec["test_file"] = spec["demonstration_file"]
    assert suite_digest(integration, spec) != original
