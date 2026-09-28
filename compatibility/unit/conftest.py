# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Validated test records for compatibility infrastructure."""

import hashlib
import io
import json
import os
import re
import subprocess
import sys
from copy import deepcopy
from datetime import datetime, timedelta, timezone

import pytest

from compatibility import runner
from compatibility.contracts import ROOT, read_registry, suite_digest


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
def selection(registry):
    return {
        "integration": "pymongo",
        "version": registry["integrations"]["pymongo"]["default_version"],
        "documentdb_version": next(iter(registry["documentdb"])),
    }


@pytest.fixture
def other_version(selection):
    major, minor, patch = selection["version"].split(".")
    return f"{major}.{minor}.{int(patch) + 1}"


@pytest.fixture
def client_python(registry, selection):
    adapter = (ROOT / registry["integrations"][selection["integration"]]["test_file"]).parent
    version = re.search(r"^FROM python:(\d+\.\d+)", (adapter / "Dockerfile").read_text(), re.M)
    assert version is not None, "The client image must declare its Python version"
    return version.group(1)


@pytest.fixture
def prepared_context(tmp_path, registry, selection, monkeypatch):
    """Prepare the real build context while replacing only external wheel metadata."""
    spec = registry["integrations"][selection["integration"]]
    version = selection["version"]
    context = tmp_path / "context"
    context.mkdir()
    wheelhouse = tmp_path / "wheelhouse"
    wheelhouse.mkdir()
    wheel = wheelhouse / f"{spec['package'].replace('-', '_')}-{version}-py3-none-any.whl"
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
    runner.prepare_client(context, spec, version, wheelhouse)
    return context


@pytest.fixture
def record(registry, selection, client_python):
    """Use reviewed identities with synthetic runtime details, not live release snapshots."""
    integration = selection["integration"]
    spec = registry["integrations"][integration]
    database_version = selection["documentdb_version"]
    database = registry["documentdb"][database_version]
    version = selection["version"]
    now = datetime.now(timezone.utc) - timedelta(minutes=1)
    return {
        "schema_version": 1,
        "id": "a" * 32,
        "integration": integration,
        "repository": spec["repository"],
        "owner": spec["owner"],
        "profile": spec["profile"],
        "suite_digest": suite_digest(integration, spec),
        "documentdb": {
            "version": database_version,
            "image": database["image"],
            "actual_extension_version": database["extension_version"],
            "actual_postgres_version": f"{database['postgres_major']}.0",
        },
        "upstream": {
            "version": version,
            "actual_version": version,
            "wheel_sha256": "b" * 64,
            "client_image": "sha256:" + "c" * 64,
            "python_version": f"{client_python}.0",
            "dependencies": [{"name": spec["package"], "version": version, "sha256": "b" * 64}],
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
