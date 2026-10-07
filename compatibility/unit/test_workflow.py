# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Keep manual runs read-only without turning failures into green jobs."""

import os
import re
import subprocess
from fnmatch import fnmatchcase

import pytest
import yaml

from compatibility.contracts import ROOT, read_registry

pytestmark = pytest.mark.unit
WORKFLOW = ROOT / ".github/workflows/compatibility.yml"


@pytest.fixture
def workflow():
    return yaml.safe_load(WORKFLOW.read_text())


def test_workflow_is_manual_and_read_only(workflow):
    # PyYAML's YAML 1.1 loader interprets the Actions "on" key as true.
    assert set(workflow[True]) == {"workflow_dispatch"}
    assert {
        "integration",
        "version",
        "documentdb_version",
        "demonstration",
    } <= set(workflow[True]["workflow_dispatch"]["inputs"])
    assert workflow["permissions"] == {"contents": "read"}
    assert all(
        job.get("permissions", workflow["permissions"]) == {"contents": "read"}
        for job in workflow["jobs"].values()
    )
    assert "secrets." not in WORKFLOW.read_text()
    assert "github.token" not in WORKFLOW.read_text()
    assert workflow["name"] == "Ecosystem compatibility"
    selector = workflow[True]["workflow_dispatch"]["inputs"]["integration"]
    assert selector["default"] == "all"
    assert {"all", *read_registry()["integrations"]} <= set(selector["options"])


def test_actions_are_pinned_and_checkout_does_not_retain_credentials(workflow):
    actions = [step for job in workflow["jobs"].values() for step in job["steps"] if "uses" in step]
    assert all(re.fullmatch(r"actions/[a-z-]+@[a-f0-9]{40}", step["uses"]) for step in actions)
    assert all(
        step["with"]["persist-credentials"] is False
        for step in actions
        if step["uses"].startswith("actions/checkout@")
    )


# These synthetic values exercise argument transport, not the reviewed release policy.
@pytest.mark.parametrize(
    ("version", "database", "demonstration", "extra", "exit_code"),
    [
        ("", "", "", [], 0),
        (
            "",
            "0.999.0",
            "false",
            ["--documentdb-version", "0.999.0"],
            0,
        ),
        (
            "4.99.1",
            "0.999.0",
            "true",
            ["--documentdb-version", "0.999.0", "--version", "4.99.1", "--demonstration"],
            1,
        ),
        (
            "4.99.0; echo unsafe",
            "0.999.0",
            "false",
            ["--documentdb-version", "0.999.0", "--version", "4.99.0; echo unsafe"],
            0,
        ),
        (
            "",
            "0.999.0; echo unsafe",
            "false",
            ["--documentdb-version", "0.999.0; echo unsafe"],
            0,
        ),
    ],
)
@pytest.mark.parametrize(
    "integration", ["", *read_registry()["integrations"], "pymongo; echo unsafe"]
)
@pytest.mark.parametrize("job", ["plan", "test", "report"])
def test_actual_workflow_script_handles_defaults_and_dispatch_inputs(
    workflow, tmp_path, version, database, demonstration, extra, exit_code, integration, job
):
    step = next(
        step
        for step in workflow["jobs"][job]["steps"]
        if "compatibility.runner" in step.get("run", "")
        or "compatibility.workflow" in step.get("run", "")
    )
    capture = (
        'python() { printf "%s\\0" "$@" > "$CAPTURED_ARGUMENTS"; '
        """if [ "$3" = "matrix" ]; then printf '%s\\n' '{"include":[]}'; fi; """
        'return "$TEST_EXIT_CODE"; }\n'
    )
    captured = tmp_path / "arguments"
    output = tmp_path / "job-output"
    summary = tmp_path / "summary"
    process = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", capture + step["run"]],
        cwd=tmp_path,
        env={
            **os.environ,
            "VERSION": version,
            "INTEGRATION": integration,
            "DOCUMENTDB_VERSION": database,
            "DEMONSTRATION": demonstration,
            "GITHUB_SERVER_URL": "https://github.com",
            "GITHUB_REPOSITORY": "example/project",
            "GITHUB_RUN_ID": "42",
            "GITHUB_RUN_ATTEMPT": "3",
            "GITHUB_OUTPUT": str(output),
            "GITHUB_STEP_SUMMARY": str(summary),
            "CAPTURED_ARGUMENTS": str(captured),
            "TEST_EXIT_CODE": str(exit_code),
        },
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert process.returncode == exit_code, process.stderr
    assert process.stdout == ""
    run_url = "https://github.com/example/project/actions/runs/42/attempts/3"
    if job == "test":
        expected = [
            "-m",
            "compatibility.runner",
            "--integration",
            integration,
            "--version",
            version,
            "--documentdb-version",
            database,
            "--output",
            f"results/{integration}/result.json",
            "--run-url",
            run_url,
            *(["--demonstration"] if demonstration == "true" else []),
        ]
    else:
        expected = ["-m", "compatibility.workflow", "matrix" if job == "plan" else "report"]
        if job == "report":
            expected += [
                "--input",
                "incoming",
                "--output",
                "report",
                "--summary",
                str(summary),
                "--expected-run-url",
                run_url,
            ]
        expected += [*(["--integration", integration] if integration else []), *extra]
    assert captured.read_bytes().decode().split("\0")[:-1] == expected
    if job == "plan":
        if exit_code:
            assert not output.exists()
        else:
            assert output.read_text() == 'matrix={"include":[]}\n'


def test_failed_runs_keep_their_evidence_and_fail_the_job(workflow):
    job = workflow["jobs"]["test"]
    steps = job["steps"]
    suite = next(step for step in steps if step.get("id") == "suite")
    upload = next(
        step for step in steps if step.get("uses", "").startswith("actions/upload-artifact@")
    )
    assert job.get("continue-on-error", False) is False
    assert suite.get("continue-on-error", False) is False
    assert job["strategy"]["fail-fast"] is False
    assert job["strategy"]["matrix"] == "${{ fromJSON(needs.plan.outputs.matrix) }}"
    assert job["needs"] == "plan"
    assert workflow["jobs"]["plan"]["outputs"]["matrix"] == "${{ steps.select.outputs.matrix }}"
    assert upload["if"] == "always()"
    assert upload["with"]["if-no-files-found"] == "error"
    assert upload["with"]["path"] == "results/"
    for variable in ("integration", "version", "documentdb_version", "demonstration"):
        assert suite["env"][variable.upper()] == "${{ matrix." + variable + " }}"


def test_combined_reporting_runs_after_test_and_download_failures(workflow):
    job = workflow["jobs"]["report"]
    assert set(job["needs"]) == {"plan", "test"}
    assert job["if"] == "always() && needs.plan.result == 'success'"
    download = next(
        step
        for step in job["steps"]
        if step.get("uses", "").startswith("actions/download-artifact@")
    )
    report = next(
        step for step in job["steps"] if "compatibility.workflow report" in step.get("run", "")
    )
    upload = next(
        step for step in job["steps"] if step.get("uses", "").startswith("actions/upload-artifact@")
    )
    assert report["if"] == upload["if"] == "always()"
    assert job["steps"].index(download) < job["steps"].index(report) < job["steps"].index(upload)
    assert all(step.get("continue-on-error", False) is False for step in job["steps"])
    assert job.get("continue-on-error", False) is False
    assert download["with"]["merge-multiple"] is True
    assert download["with"]["path"] == "incoming"
    assert upload["with"]["path"] == "report/"
    assert upload["with"]["if-no-files-found"] == "error"


def test_artifacts_are_distinct_per_integration_and_attempt(workflow, registry):
    uploads = {
        name: next(
            step["with"]
            for step in workflow["jobs"][name]["steps"]
            if step.get("uses", "").startswith("actions/upload-artifact@")
        )
        for name in ("test", "report")
    }
    pattern = next(
        step["with"]["pattern"]
        for step in workflow["jobs"]["report"]["steps"]
        if step.get("uses", "").startswith("actions/download-artifact@")
    )
    names = set()
    for attempt in (1, 2):
        current_pattern = pattern.replace("${{ github.run_attempt }}", str(attempt))
        for integration in registry["integrations"]:
            name = (
                uploads["test"]["name"]
                .replace("${{ matrix.integration }}", integration)
                .replace("${{ github.run_attempt }}", str(attempt))
            )
            assert name not in names
            assert fnmatchcase(name, current_pattern)
            assert not fnmatchcase(
                name, pattern.replace("${{ github.run_attempt }}", str(attempt + 1))
            )
            names.add(name)
        combined = uploads["report"]["name"].replace("${{ github.run_attempt }}", str(attempt))
        assert combined not in names and not fnmatchcase(combined, current_pattern)
        names.add(combined)
    assert all(settings["retention-days"] == 30 for settings in uploads.values())


def test_infrastructure_is_checked_without_starting_an_integration():
    workflow = yaml.safe_load((ROOT / ".github/workflows/documentdb_local_tests.yml").read_text())
    job = workflow["jobs"]["compatibility-unit-tests"]
    assert job["name"] == "Ecosystem compatibility infrastructure"
    commands = "\n".join(step.get("run", "") for step in job["steps"])
    assert "compatibility/requirements-dev.txt" in commands
    assert "compatibility/unit" in commands
    assert "test_freshness.cjs" in commands
    assert "compatibility.runner" not in commands
