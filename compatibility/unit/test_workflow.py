# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Keep branch-demo and manual runs read-only without turning failures into green jobs."""

import os
import re
import subprocess

import pytest
import yaml

from compatibility.contracts import ROOT

pytestmark = pytest.mark.unit
WORKFLOW = ROOT / ".github/workflows/compatibility.yml"


@pytest.fixture
def workflow():
    return yaml.safe_load(WORKFLOW.read_text())


def test_pilot_has_only_the_scoped_demo_trigger_and_manual_dispatch(workflow):
    # PyYAML's YAML 1.1 loader interprets the Actions "on" key as true.
    assert set(workflow[True]) == {"push", "workflow_dispatch"}
    assert workflow[True]["push"] == {"branches": ["users/urismiley/pymongo-compatibility"]}
    assert set(workflow[True]["workflow_dispatch"]["inputs"]) == {
        "version",
        "documentdb_version",
        "demonstration",
    }
    assert workflow["permissions"] == {"contents": "read"}
    assert set(workflow["jobs"]) == {"test"}
    assert "permissions" not in workflow["jobs"]["test"]
    assert "secrets." not in WORKFLOW.read_text()


def test_actions_are_pinned_and_checkout_does_not_retain_credentials(workflow):
    actions = [step for step in workflow["jobs"]["test"]["steps"] if "uses" in step]
    assert all(re.fullmatch(r"actions/[a-z-]+@[a-f0-9]{40}", step["uses"]) for step in actions)
    checkout = next(step for step in actions if step["uses"].startswith("actions/checkout@"))
    assert checkout["with"]["persist-credentials"] is False


def test_user_inputs_are_passed_as_quoted_arguments(workflow):
    suite = next(step for step in workflow["jobs"]["test"]["steps"] if step.get("id") == "suite")
    assert "${{" not in suite["run"]
    assert '"$VERSION"' in suite["run"]
    assert '"$DOCUMENTDB_VERSION"' in suite["run"]
    assert '"${args[@]}"' in suite["run"]


@pytest.mark.parametrize(
    ("event", "version", "database", "demonstration", "extra", "exit_code"),
    [
        ("push", "", "", "", ["--trigger", "push"], 0),
        (
            "workflow_dispatch",
            "",
            "0.117.0",
            "false",
            ["--documentdb-version", "0.117.0"],
            0,
        ),
        (
            "workflow_dispatch",
            "4.18.1",
            "0.117.0",
            "true",
            ["--documentdb-version", "0.117.0", "--version", "4.18.1", "--demonstration"],
            1,
        ),
        (
            "workflow_dispatch",
            "4.18.0; echo unsafe",
            "0.117.0",
            "false",
            ["--documentdb-version", "0.117.0", "--version", "4.18.0; echo unsafe"],
            0,
        ),
    ],
)
def test_actual_workflow_script_handles_push_defaults_and_dispatch_inputs(
    workflow, tmp_path, event, version, database, demonstration, extra, exit_code
):
    suite = next(step for step in workflow["jobs"]["test"]["steps"] if step.get("id") == "suite")
    capture = (
        'python() { printf "%s\\0" "$@" > "$CAPTURED_ARGUMENTS"; return "$TEST_EXIT_CODE"; }\n'
    )
    captured = tmp_path / "arguments"
    process = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", capture + suite["run"]],
        cwd=tmp_path,
        env={
            **os.environ,
            "VERSION": version,
            "DOCUMENTDB_VERSION": database,
            "DEMONSTRATION": demonstration,
            "GITHUB_EVENT_NAME": event,
            "GITHUB_SERVER_URL": "https://github.com",
            "GITHUB_REPOSITORY": "documentdb/documentdb",
            "GITHUB_RUN_ID": "42",
            "CAPTURED_ARGUMENTS": str(captured),
            "TEST_EXIT_CODE": str(exit_code),
        },
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert process.returncode == exit_code, process.stderr
    assert captured.read_bytes().decode().split("\0")[:-1] == [
        "-m",
        "compatibility.runner",
        "--output",
        "results/result.json",
        "--run-url",
        "https://github.com/documentdb/documentdb/actions/runs/42",
        *extra,
    ]


def test_failed_runs_keep_their_evidence_and_fail_the_job(workflow):
    steps = workflow["jobs"]["test"]["steps"]
    suite = next(step for step in steps if step.get("id") == "suite")
    upload = next(
        step for step in steps if step.get("uses", "").startswith("actions/upload-artifact@")
    )
    preview = next(step for step in steps if "compatibility.publish" in step.get("run", ""))
    assert suite["continue-on-error"] is True
    assert upload["if"] == "always()"
    assert preview["if"].startswith("always()")
    assert upload["with"]["if-no-files-found"] == "error"
    assert "results/" in upload["with"]["path"]
    assert steps[-1]["if"] == "always() && steps.suite.outcome != 'success'"
    assert steps[-1]["run"] == "exit 1"


def test_infrastructure_is_checked_without_starting_an_integration():
    workflow = yaml.safe_load((ROOT / ".github/workflows/documentdb_local_tests.yml").read_text())
    job = workflow["jobs"]["pymongo-compatibility-unit-tests"]
    commands = "\n".join(step.get("run", "") for step in job["steps"])
    assert "compatibility/requirements-dev.txt" in commands
    assert "compatibility/unit" in commands
    assert "test_freshness.cjs" in commands
    assert "compatibility.runner" not in commands
