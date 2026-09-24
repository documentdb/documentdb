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
    assert set(workflow["jobs"]) == {"test", "persist", "deploy"}
    assert "permissions" not in workflow["jobs"]["test"]
    assert "secrets." not in WORKFLOW.read_text()


def test_actions_are_pinned_and_checkout_does_not_retain_credentials(workflow):
    actions = [step for job in workflow["jobs"].values() for step in job["steps"] if "uses" in step]
    assert all(re.fullmatch(r"actions/[a-z-]+@[a-f0-9]{40}", step["uses"]) for step in actions)
    assert all(
        step["with"]["persist-credentials"] is False
        for step in actions
        if step["uses"].startswith("actions/checkout@")
    )


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
            "GITHUB_RUN_ATTEMPT": "3",
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
        "https://github.com/documentdb/documentdb/actions/runs/42/attempts/3",
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


def test_publication_requires_opt_in_and_the_exact_fork_branch(workflow):
    for name in ("persist", "deploy"):
        gate = workflow["jobs"][name]["if"]
        assert "always() && !cancelled()" in gate
        assert "github.repository == 'udsmicrosoft/documentdb'" in gate
        assert "github.ref == 'refs/heads/users/urismiley/pymongo-compatibility'" in gate
        assert "vars.COMPATIBILITY_PUBLISH_ENABLED == 'true'" in gate
    persist = workflow["jobs"]["persist"]
    deploy = workflow["jobs"]["deploy"]
    assert persist["needs"] == "test"
    assert "needs.test.outputs.result_available == 'true'" in persist["if"]
    assert "needs.test.result == 'success'" not in persist["if"]
    assert deploy["needs"] == "persist"
    assert "needs.persist.result == 'success'" in deploy["if"]
    assert workflow["jobs"]["test"]["outputs"]["result_available"] == (
        "${{ steps.result.outputs.available }}"
    )


def test_publication_permissions_are_separate_from_execution(workflow):
    persist = workflow["jobs"]["persist"]
    deploy = workflow["jobs"]["deploy"]
    assert persist["permissions"] == {"contents": "write"}
    assert persist["environment"] == "compatibility-publishing"
    assert deploy["permissions"] == {
        "contents": "read",
        "pages": "write",
        "id-token": "write",
    }
    assert deploy["environment"]["name"] == "github-pages"
    assert all("github.token" not in str(step) for step in workflow["jobs"]["test"]["steps"])
    credential_steps = [step for step in persist["steps"] if step.get("env", {}).get("GH_TOKEN")]
    assert len(credential_steps) == 1
    assert "bash compatibility/persist.sh" in credential_steps[0]["run"]
    assert "pip install" not in credential_steps[0]["run"]


def test_deployment_reads_current_history_inside_its_own_queue(workflow):
    assert "concurrency" not in workflow
    assert "concurrency" not in workflow["jobs"]["test"]
    assert "concurrency" not in workflow["jobs"]["persist"]
    deploy = workflow["jobs"]["deploy"]
    assert deploy["concurrency"] == {
        "group": "compatibility-pages",
        "cancel-in-progress": False,
    }
    checkouts = [
        step for step in deploy["steps"] if step.get("uses", "").startswith("actions/checkout@")
    ]
    assert checkouts[0]["with"]["ref"] == "${{ github.ref }}"
    assert checkouts[1]["with"]["ref"] == "compatibility-data"
    assert any("--preview" in step.get("run", "") for step in deploy["steps"])


def test_reruns_do_not_collide_on_artifact_names(workflow):
    for job in ("test", "deploy"):
        for step in workflow["jobs"][job]["steps"]:
            if any(
                name in step.get("uses", "")
                for name in (
                    "upload-artifact@",
                    "upload-pages-artifact@",
                    "deploy-pages@",
                )
            ):
                settings = step["with"]
                name = settings.get("artifact_name", settings.get("name"))
                assert "${{ github.run_attempt }}" in name


def test_retrying_only_publication_uses_the_original_test_attempt(workflow):
    outputs = workflow["jobs"]["test"]["outputs"]
    assert outputs["artifact_name"] == "${{ steps.result.outputs.artifact_name }}"
    assert outputs["run_url"] == "${{ steps.result.outputs.run_url }}"
    persist = workflow["jobs"]["persist"]
    download = next(
        step
        for step in persist["steps"]
        if step.get("uses", "").startswith("actions/download-artifact@")
    )
    assert download["with"]["name"] == "${{ needs.test.outputs.artifact_name }}"
    publisher = next(step for step in persist["steps"] if "persist.sh" in step.get("run", ""))
    assert publisher["env"]["EXPECTED_RUN_URL"] == "${{ needs.test.outputs.run_url }}"
    assert '"$EXPECTED_RUN_URL"' in publisher["run"]


@pytest.mark.parametrize("available", [False, True])
def test_test_job_exports_the_attempt_and_presence_of_evidence(workflow, tmp_path, available):
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
            "GITHUB_RUN_ATTEMPT": "3",
            "GITHUB_RUN_ID": "42",
            "GITHUB_SERVER_URL": "https://github.com",
            "GITHUB_REPOSITORY": "example/project",
        },
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert process.returncode == 0, process.stderr
    assert dict(line.split("=", 1) for line in output.read_text().splitlines()) == {
        "available": str(available).lower(),
        "artifact_name": "pymongo-compatibility-3",
        "run_url": "https://github.com/example/project/actions/runs/42/attempts/3",
    }


def test_failure_demo_override_is_fork_only_and_explicit(workflow):
    suite = next(step for step in workflow["jobs"]["test"]["steps"] if step.get("id") == "suite")
    setting = suite["env"]["DEMONSTRATION"]
    assert "inputs.demonstration" in setting
    assert "github.event_name == 'push'" in setting
    assert "github.repository == 'udsmicrosoft/documentdb'" in setting
    assert "vars.COMPATIBILITY_FAILURE_DEMONSTRATION == 'true'" in setting


def test_infrastructure_is_checked_without_starting_an_integration():
    workflow = yaml.safe_load((ROOT / ".github/workflows/documentdb_local_tests.yml").read_text())
    job = workflow["jobs"]["pymongo-compatibility-unit-tests"]
    commands = "\n".join(step.get("run", "") for step in job["steps"])
    assert "compatibility/requirements-dev.txt" in commands
    assert "compatibility/unit" in commands
    assert "test_freshness.cjs" in commands
    assert "compatibility.runner" not in commands
