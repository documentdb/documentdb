# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Isolated pytest entry point; stdout is a single machine-readable report."""

from __future__ import annotations

import contextlib
import importlib.metadata
import json
import os
import platform
import sys
from pathlib import Path

import pytest
from pymongo.errors import OperationFailure, ProtocolError, PyMongoError


class Reports:
    """Preserve setup/call/teardown failures instead of counting only passing calls."""

    def __init__(self) -> None:
        self.tests: dict[str, dict[str, str]] = {}

    def pytest_collection_modifyitems(self, items):
        identifiers = [item.originalname or item.name for item in items]
        if len(identifiers) != len(set(identifiers)):
            raise pytest.UsageError(
                "Each registered scenario must have a unique test function name"
            )

    @pytest.hookimpl(hookwrapper=True)
    def pytest_runtest_makereport(self, item, call):
        report = (yield).get_result()
        identifier = item.originalname or item.name
        outcome = "passed"
        if report.failed:
            error = call.excinfo.value if call.excinfo is not None else None
            incompatible = isinstance(
                error, (AssertionError, pytest.fail.Exception, OperationFailure, ProtocolError)
            )
            timed_out = isinstance(error, PyMongoError) and error.timeout
            outcome = (
                "failed" if report.when == "call" and incompatible and not timed_out else "error"
            )
        elif report.skipped:
            outcome = "skipped"
        elif report.when != "call":
            return
        severity = {"passed": 0, "skipped": 1, "error": 2, "failed": 3}
        previous = self.tests.get(identifier)
        if previous is None or severity[outcome] > severity[previous["outcome"]]:
            self.tests[identifier] = {
                "id": identifier,
                "outcome": outcome,
                "message": str(report.longrepr)[:2000] if outcome != "passed" else "",
            }


def main() -> int:
    """Execute only the selected adapter file, never the entire engine corpus."""
    package = os.environ["COMPATIBILITY_PACKAGE"]
    report = json.loads(Path("/install-report.json").read_text())
    installed = next(
        entry
        for entry in report["install"]
        if entry["metadata"]["name"].lower().replace("-", "_") == package.replace("-", "_")
    )
    collector = Reports()
    paths = [os.environ["COMPATIBILITY_TEST_FILE"]]
    if os.environ.get("COMPATIBILITY_DEMONSTRATION") == "1":
        paths.append(os.environ["COMPATIBILITY_DEMONSTRATION_FILE"])
    with contextlib.redirect_stdout(sys.stderr):
        exit_code = pytest.main(
            [
                "-c",
                "compatibility/pyproject.toml",
                "-q",
                "--tb=short",
                "-p",
                "no:cacheprovider",
                "--junitxml=/tmp/tests.xml",
                *paths,
            ],
            plugins=[collector],
        )
    payload = {
        "version": importlib.metadata.version(package),
        "python": platform.python_version(),
        "wheel_sha256": installed["download_info"]["archive_info"]["hashes"]["sha256"],
        "dependencies": [
            {
                "name": entry["metadata"]["name"],
                "version": entry["metadata"]["version"],
                "sha256": entry["download_info"]["archive_info"]["hashes"]["sha256"],
            }
            for entry in report["install"]
        ],
        "exit_code": int(exit_code),
        "tests": list(collector.tests.values()),
        "junit": Path("/tmp/tests.xml").read_text(),
    }
    print(json.dumps(payload, allow_nan=False))
    return int(exit_code)


if __name__ == "__main__":
    raise SystemExit(main())
