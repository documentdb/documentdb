# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Validated test records for compatibility infrastructure."""

import hashlib
import io
import json
import os
import subprocess
import sys
from copy import deepcopy
from datetime import datetime, timedelta, timezone

import pytest

from compatibility import runner
from compatibility.contracts import read_registry, suite_digest


@pytest.fixture
def collect_report(tmp_path):
    """Exercise the production reporting plugin in a fresh, isolated pytest process."""

    def collect(source):
        (tmp_path / "test_profile.py").write_text(source)
        output = tmp_path / "report.json"
        program = """
import json
import os
import sys
from pathlib import Path
import pytest
from compatibility.client import Reports
collector = Reports()
code = pytest.main(
    ["-q", "-c", os.devnull, "--rootdir", sys.argv[1], "--confcutdir", sys.argv[1],
     "-p", "no:cacheprovider", sys.argv[1]], plugins=[collector]
)
Path(sys.argv[2]).write_text(json.dumps(
    {"exit_code": int(code), "tests": list(collector.tests.values())}
))
"""
        subprocess.run(
            [sys.executable, "-c", program, str(tmp_path), str(output)],
            env={**os.environ, "PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1"},
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        return json.loads(output.read_text())

    return collect


@pytest.fixture
def registry():
    return read_registry()


@pytest.fixture
def prepared_context(tmp_path, registry, monkeypatch):
    """Prepare the real build context while replacing only external wheel metadata."""
    context = tmp_path / "context"
    context.mkdir()
    wheelhouse = tmp_path / "wheelhouse"
    wheelhouse.mkdir()
    wheel = wheelhouse / "pymongo-4.18.0-cp312-cp312-manylinux2014_x86_64.whl"
    wheel.write_bytes(b"unit fixture; not an executable wheel")
    metadata = json.dumps(
        {
            "urls": [
                {
                    "filename": wheel.name,
                    "yanked": False,
                    "digests": {"sha256": hashlib.sha256(wheel.read_bytes()).hexdigest()},
                }
            ]
        }
    ).encode()
    monkeypatch.setattr(
        runner.urllib.request, "urlopen", lambda *args, **kwargs: io.BytesIO(metadata)
    )
    runner.prepare_client(context, registry["integrations"]["pymongo"], "4.18.0", wheelhouse)
    return context


@pytest.fixture
def record(registry):
    spec = registry["integrations"]["pymongo"]
    now = datetime.now(timezone.utc) - timedelta(minutes=1)
    return {
        "schema_version": 1,
        "id": "a" * 32,
        "integration": "pymongo",
        "repository": spec["repository"],
        "owner": spec["owner"],
        "profile": spec["profile"],
        "suite_digest": suite_digest("pymongo", spec),
        "documentdb": {
            "version": "0.117.0",
            "image": registry["documentdb"]["0.117.0"]["image"],
            "actual_extension_version": "0.117-0",
            "actual_postgres_version": "17.11",
        },
        "upstream": {
            "version": "4.18.0",
            "actual_version": "4.18.0",
            "wheel_sha256": "b" * 64,
            "client_image": "sha256:" + "c" * 64,
            "python_version": "3.12.14",
            "dependencies": [{"name": "pymongo", "version": "4.18.0", "sha256": "b" * 64}],
        },
        "expected_tests": deepcopy(spec["expected_tests"]),
        "tests": [
            {"id": name, "outcome": "passed", "message": ""} for name in spec["expected_tests"]
        ],
        "started_at": (now - timedelta(seconds=5)).isoformat(),
        "finished_at": now.isoformat(),
        "trigger": "manual",
        "run_url": None,
        "demonstration": False,
        "execution_error": None,
    }
