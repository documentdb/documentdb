# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Keep manual runs read-only without turning failures into green jobs."""

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


def test_workflow_is_manual_and_read_only(workflow):
    # PyYAML's YAML 1.1 loader interprets the Actions "on" key as true.
    assert set(workflow[True]) == {"workflow_dispatch"}
    assert set(workflow[True]["workflow_dispatch"]["inputs"]) == {
        "version",
        "documentdb_version",
        "demonstration",
    }
    assert workflow["permissions"] == {"contents": "read"}
    assert all(
        job.get("permissions", workflow["permissions"]) == {"contents": "read"}
        for job in workflow["jobs"].values()
    )
    assert "secrets." not in WORKFLOW.read_text()
    assert "github.token" not in WORKFLOW.read_text()


def test_actions_are_pinned_and_checkout_does_not_retain_credentials(workflow):
    actions = [step for job in workflow["jobs"].values() for step in job["steps"] if "uses" in step]
    assert all(re.fullmatch(r"actions/[a-z-]+@[a-f0-9]{40}", step["uses"]) for step in actions)
    assert all(
        step["with"]["persist-credentials"] is False
        for step in actions
        if step["uses"].startswith("actions/checkout@")
    )


@pytest.mark.parametrize(
    ("version", "database", "demonstration", "extra", "exit_code"),
    [
        ("", "", "", [], 0),
        (
            "",
            "0.117.0",
            "false",
            ["--documentdb-version", "0.117.0"],
            0,
        ),
        (
            "4.18.1",
            "0.117.0",
            "true",
            ["--documentdb-version", "0.117.0", "--version", "4.18.1", "--demonstration"],
            1,
        ),
        (
            "4.18.0; echo unsafe",
            "0.117.0",
            "false",
            ["--documentdb-version", "0.117.0", "--version", "4.18.0; echo unsafe"],
            0,
        ),
        (
            "",
            "0.117.0; echo unsafe",
            "false",
            ["--documentdb-version", "0.117.0; echo unsafe"],
            0,
        ),
    ],
)
def test_actual_workflow_script_handles_defaults_and_dispatch_inputs(
    workflow, tmp_path, version, database, demonstration, extra, exit_code
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
            "GITHUB_SERVER_URL": "https://github.com",
            "GITHUB_REPOSITORY": "documentdb/documentdb",
            "GITHUB_RUN_ID": "42",
            "GITHUB_RUN_ATTEMPT": "3",
            "CAPTURED_ARGUMENTS": str(captured),
            "TEST_EXIT_CODE": str(exit_code),
        },
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert process.returncode == exit_code, process.stderr
    assert process.stdout == ""
    assert captured.read_bytes().decode().split("\0")[:-1] == [
        "-m",
        "compatibility.runner",
        "--output",
        "results/result.json",
        "--run-url",
        "https://github.com/documentdb/documentdb/actions/runs/42/attempts/3",
        *extra,
    ]


def test_failed_runs_keep_their_evidence_and_fail_the_job(workflow):
    job = workflow["jobs"]["test"]
    steps = job["steps"]
    suite = next(step for step in steps if step.get("id") == "suite")
    result = next(step for step in steps if step.get("id") == "result")
    upload = next(
        step for step in steps if step.get("uses", "").startswith("actions/upload-artifact@")
    )
    preview = next(step for step in steps if "compatibility.publish" in step.get("run", ""))
    assert job.get("continue-on-error", False) is False
    assert suite.get("continue-on-error", False) is False
    assert result["if"] == "always()"
    assert upload["if"] == "always()"
    assert preview["if"].startswith("always()")
    assert upload["with"]["if-no-files-found"] == "error"
    assert "results/" in upload["with"]["path"]


def test_reruns_do_not_collide_on_artifact_names(workflow):
    for job in workflow["jobs"]:
        for step in workflow["jobs"][job]["steps"]:
            if step.get("uses", "").startswith("actions/upload-artifact@"):
                assert "${{ github.run_attempt }}" in step["with"]["name"]


@pytest.mark.parametrize("available", [False, True])
def test_result_presence_is_reported(workflow, tmp_path, available):
    if available:
        (tmp_path / "results").mkdir()
        (tmp_path / "results/result.json").write_text("{}")
    output = tmp_path / "job-output"
    step = next(step for step in workflow["jobs"]["test"]["steps"] if step.get("id") == "result")
    process = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", step["run"]],
        cwd=tmp_path,
        env={
            **os.environ,
            "GITHUB_OUTPUT": str(output),
        },
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert process.returncode == 0, process.stderr
    assert output.read_text() == f"available={str(available).lower()}\n"


def test_infrastructure_is_checked_without_starting_an_integration():
    workflow = yaml.safe_load((ROOT / ".github/workflows/documentdb_local_tests.yml").read_text())
    job = workflow["jobs"]["pymongo-compatibility-unit-tests"]
    commands = "\n".join(step.get("run", "") for step in job["steps"])
    assert "compatibility/requirements-dev.txt" in commands
    assert "compatibility/unit" in commands
    assert "test_freshness.cjs" in commands
    assert "compatibility.runner" not in commands
