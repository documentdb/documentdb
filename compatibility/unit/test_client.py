# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Report real pytest outcomes, including non-call failures and invalid collection."""

import pytest

pytestmark = pytest.mark.unit


@pytest.mark.parametrize(
    ("source", "code", "outcome"),
    [
        pytest.param("def test_profile(): pass", 0, "passed", id="passed"),
        pytest.param("def test_profile(): assert False", 1, "failed", id="assertion"),
        pytest.param(
            "import pytest\ndef test_profile(): pytest.fail('Explicit mismatch')",
            1,
            "failed",
            id="explicit-test-failure",
        ),
        pytest.param(
            "import pytest\nfrom pymongo.errors import DuplicateKeyError\n"
            "def test_profile():\n    with pytest.raises(DuplicateKeyError): pass",
            1,
            "failed",
            id="required-exception-was-not-raised",
        ),
        pytest.param(
            "def test_profile(): raise RuntimeError('Execution failed')", 1, "error", id="runtime"
        ),
        pytest.param(
            "import pytest\n@pytest.mark.skip(reason='Unavailable')\ndef test_profile(): pass",
            0,
            "skipped",
            id="skipped",
        ),
        pytest.param(
            "import pytest\n@pytest.mark.xfail(reason='Unavailable')\n"
            "def test_profile(): assert False",
            0,
            "skipped",
            id="expected-failure-is-not-working",
        ),
        pytest.param(
            "import pytest\ndef test_profile(): pytest.xfail('Unavailable')",
            0,
            "skipped",
            id="explicit-expected-failure-is-not-working",
        ),
        pytest.param(
            "import pytest\n@pytest.fixture\ndef fixture(): raise RuntimeError('Setup failed')\n"
            "def test_profile(fixture): pass",
            1,
            "error",
            id="setup",
        ),
        pytest.param(
            "import pytest\n@pytest.fixture\ndef fixture():\n"
            "    yield\n    raise RuntimeError('Cleanup failed')\n"
            "def test_profile(fixture): pass",
            1,
            "error",
            id="teardown",
        ),
        pytest.param(
            "import pytest\n@pytest.fixture\ndef fixture():\n"
            "    yield\n    raise RuntimeError('Cleanup failed')\n"
            "def test_profile(fixture): assert False",
            1,
            "failed",
            id="assertion-survives-teardown",
        ),
    ],
)
def test_report_classifies_all_test_phases(collect_report, source, code, outcome):
    report = collect_report(source)
    assert report["exit_code"] == code and [
        (test["id"], test["outcome"]) for test in report["tests"]
    ] == [("test_profile", outcome)]


def test_duplicate_parameterized_names_rejected_before_execution(collect_report):
    report = collect_report(
        "import pytest\n@pytest.mark.parametrize('value', [1, 2])\n" "def test_profile(value): pass"
    )
    assert report == {"exit_code": 4, "tests": []}


def test_collection_error_cannot_be_reported_as_passed(collect_report):
    report = collect_report("raise RuntimeError('Collection failed')")
    assert report == {"exit_code": 2, "tests": []}


@pytest.mark.parametrize(
    ("exception", "outcome"),
    [
        ("OperationFailure('Unsupported operation', 115)", "failed"),
        ("DuplicateKeyError('Unexpected duplicate', 11000)", "failed"),
        ("BulkWriteError({'writeErrors': [{'code': 11000}], 'writeConcernErrors': []})", "failed"),
        ("ProtocolError('Invalid response')", "failed"),
        ("OperationFailure('Server time limit exceeded', 50)", "error"),
        ("ExecutionTimeout('Server time limit exceeded', 50)", "error"),
        ("NetworkTimeout('Socket timeout')", "error"),
        ("ConnectionFailure('Endpoint unavailable')", "error"),
        ("ConfigurationError('Invalid runtime configuration')", "error"),
    ],
)
def test_driver_operation_failures_are_distinct_from_execution_errors(
    collect_report, exception, outcome
):
    report = collect_report(
        "from pymongo.errors import (BulkWriteError, ConfigurationError, ConnectionFailure, "
        "DuplicateKeyError, ExecutionTimeout, NetworkTimeout, OperationFailure, ProtocolError)\n"
        f"def test_profile(): raise {exception}\n"
    )
    assert report["exit_code"] == 1
    assert report["tests"][0]["outcome"] == outcome


def test_driver_failure_survives_teardown_connection_failure(collect_report):
    report = collect_report(
        "import pytest\nfrom pymongo.errors import ConnectionFailure, OperationFailure\n"
        "@pytest.fixture\ndef fixture():\n"
        "    yield\n    raise ConnectionFailure('Cleanup unavailable')\n"
        "def test_profile(fixture): raise OperationFailure('Unsupported operation', 115)\n"
    )
    assert report["tests"][0]["outcome"] == "failed"


def test_fixture_operation_failure_is_not_an_executed_scenario(collect_report):
    report = collect_report(
        "import pytest\nfrom pymongo.errors import OperationFailure\n"
        "@pytest.fixture\ndef fixture(): raise OperationFailure('Setup failed', 115)\n"
        "def test_profile(fixture): pass\n"
    )
    assert report["tests"][0]["outcome"] == "error"
