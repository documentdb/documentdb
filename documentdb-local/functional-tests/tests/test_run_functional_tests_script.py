"""Tests for run-functional-tests.sh behavior."""

import json
import os
import subprocess
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPO_ROOT / "documentdb-local/functional-tests/scripts/run-functional-tests.sh"
ALLOWLIST = REPO_ROOT / "documentdb-local/functional-tests/config/allowlist.yml"


def write_fake_docker(tmp_path: Path) -> Path:
    docker = tmp_path / "docker"
    docker.write_text(
        """#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

import yaml


def find_volume_source(args, container_path):
    for index, arg in enumerate(args):
        if arg != "-v" or index + 1 >= len(args):
            continue
        source, target, *_ = args[index + 1].split(":")
        if target == container_path:
            return Path(source)
    raise SystemExit(f"missing volume for {container_path}")


if len(sys.argv) > 1 and sys.argv[1] == "run":
    results_dir = find_volume_source(sys.argv, "/results")
    allowlist_path = find_volume_source(sys.argv, "/allowlist.yml")
    results_dir.mkdir(parents=True, exist_ok=True)

    raw_tests = yaml.safe_load(allowlist_path.read_text())["tests"]
    tests = [t["id"] if isinstance(t, dict) else t for t in raw_tests]
    if os.environ.get("FAKE_DOCKER_REPORT") == "missing_one":
        tests = tests[:-1]

    report = {
        "summary": {"total": len(tests), "deselected": 0, "collected": len(tests)},
        "tests": [{"nodeid": test_id, "outcome": "passed"} for test_id in tests],
    }
    (results_dir / "report.json").write_text(json.dumps(report))
    sys.exit(int(os.environ.get("FAKE_DOCKER_EXIT", "0")))

raise SystemExit(f"unexpected docker invocation: {sys.argv}")
"""
    )
    docker.chmod(0o755)
    return docker


def run_allowlist(
    tmp_path: Path,
    *,
    docker_exit: int = 0,
    report: str = "all_pass",
    extra_args: list[str] | None = None,
):
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_fake_docker(fake_bin)

    results_dir = tmp_path / "results"
    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["FAKE_DOCKER_EXIT"] = str(docker_exit)
    env["FAKE_DOCKER_REPORT"] = report

    return subprocess.run(
        [str(SCRIPT), "allowlist", "--results-dir", str(results_dir), *(extra_args or [])],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
    )


def test_allowlist_mode_succeeds_when_pytest_and_summary_succeed(tmp_path):
    result = run_allowlist(tmp_path)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "Test run complete (exit: 0)" in result.stdout


def test_allowlist_mode_fails_when_pytest_fails_even_if_summary_passes(tmp_path):
    result = run_allowlist(tmp_path, docker_exit=7)

    assert result.returncode == 1, result.stdout + result.stderr
    assert "Test run complete (exit: 1)" in result.stdout


def test_allowlist_mode_fails_when_summary_fails_even_if_pytest_succeeds(tmp_path):
    result = run_allowlist(tmp_path, report="missing_one")

    assert result.returncode == 1, result.stdout + result.stderr
    assert "Test run complete (exit: 1)" in result.stdout


def test_allowlist_mode_redacts_logged_connection_string(tmp_path):
    password = "redacted-value"
    query_token = "abc"
    connection_string = (
        "mongodb://"
        + "user"
        + ":"
        + password
        + "@example.com:10260/?tls=true&token="
        + query_token
    )

    result = run_allowlist(
        tmp_path,
        extra_args=["--connection-string", connection_string],
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "Connection:  mongodb://example.com:10260" in result.stdout
    assert password not in result.stdout
    assert f"token={query_token}" not in result.stdout


def test_fake_docker_tolerates_v2_dict_entries(tmp_path):
    """The fake docker reads tests directly from allowlist.yml; it must accept
    the v2 dict form so a future allowlist with engine-scoped entries doesn't
    silently break this test harness."""
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_fake_docker(fake_bin)

    fake_allowlist = tmp_path / "allowlist.yml"
    fake_allowlist.write_text(yaml.dump({
        "schema_version": 2,
        "tests": [
            "bare::test_id",
            {"id": "scoped_one::test", "engines": ["documentdb"]},
            {"id": "scoped_two::test", "engines": ["pgmongo", "documentdb"]},
        ],
    }))

    results_dir = tmp_path / "results"
    results_dir.mkdir()

    proc = subprocess.run(
        [
            str(fake_bin / "docker"),
            "run",
            "-v", f"{results_dir}:/results",
            "-v", f"{fake_allowlist}:/allowlist.yml",
        ],
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr

    report = json.loads((results_dir / "report.json").read_text())
    nodeids = [t["nodeid"] for t in report["tests"]]
    assert "bare::test_id" in nodeids
    assert "scoped_one::test" in nodeids
    assert "scoped_two::test" in nodeids
