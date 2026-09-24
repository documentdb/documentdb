# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Exercise history publication against real disposable Git repositories."""

import json
import os
import shlex
import subprocess
from copy import deepcopy

import pytest

from compatibility.contracts import ROOT

pytestmark = pytest.mark.unit
SCRIPT = ROOT / "compatibility/persist.sh"
RUN_URL = "https://github.com/example/project/actions/runs/42/attempts/1"


def git(directory, *arguments, check=True):
    return subprocess.run(
        ["git", "-C", str(directory), *arguments],
        capture_output=True,
        text=True,
        check=check,
        timeout=30,
    )


@pytest.fixture
def history_repo(tmp_path, monkeypatch):
    monkeypatch.setenv("PYTHONPATH", str(ROOT))
    monkeypatch.setenv("RUNNER_TEMP", str(tmp_path))
    origin = tmp_path / "origin.git"
    source = tmp_path / "source"
    git(tmp_path, "init", "--bare", "--quiet", "--initial-branch=main", str(origin))
    git(tmp_path, "clone", "--quiet", str(origin), str(source))
    (source / "source-only").write_text("Must not be published with result data\n")
    git(source, "add", "source-only")
    git(
        source,
        "-c",
        "user.name=Test Fixture",
        "-c",
        "user.email=fixture@example.test",
        "commit",
        "--quiet",
        "-s",
        "-m",
        "Create a test source revision",
    )
    git(source, "push", "--quiet", "origin", "main")
    return source, origin


def persist(source, path, *, run_url=RUN_URL, environment=None):
    return subprocess.run(
        ["bash", str(SCRIPT), str(path), run_url],
        cwd=source,
        env=environment or os.environ,
        capture_output=True,
        text=True,
        timeout=60,
    )


def write_record(directory, record):
    record["run_url"] = RUN_URL
    path = directory / f"{record['id']}.json"
    path.write_text(json.dumps(record))
    return path


def test_first_publication_creates_only_result_data_and_cleans_its_worktree(
    history_repo, tmp_path, record
):
    source, origin = history_repo
    source_revision = git(source, "rev-parse", "HEAD").stdout
    result = persist(source, write_record(tmp_path, record))
    assert result.returncode == 0, result.stderr
    assert git(origin, "ls-tree", "-r", "--name-only", "compatibility-data").stdout.split() == [
        f"results/{record['id']}.json"
    ]
    assert (
        json.loads(git(origin, "show", f"compatibility-data:results/{record['id']}.json").stdout)
        == record
    )
    assert git(source, "status", "--porcelain").stdout == ""
    assert git(source, "rev-parse", "HEAD").stdout == source_revision
    assert len(git(source, "worktree", "list", "--porcelain").stdout.split("worktree ")) == 2
    assert not list(tmp_path.glob("compat-history.*"))


def test_identical_replay_does_not_create_another_commit(history_repo, tmp_path, record):
    source, origin = history_repo
    path = write_record(tmp_path, record)
    first = persist(source, path)
    assert first.returncode == 0, first.stderr
    revision = git(origin, "rev-parse", "compatibility-data").stdout
    second = persist(source, path)
    assert second.returncode == 0, second.stderr
    assert "already persisted" in second.stdout
    assert git(origin, "rev-parse", "compatibility-data").stdout == revision


def test_different_record_with_existing_id_cannot_rewrite_history(history_repo, tmp_path, record):
    source, origin = history_repo
    path = write_record(tmp_path, record)
    result = persist(source, path)
    assert result.returncode == 0, result.stderr
    revision = git(origin, "rev-parse", "compatibility-data").stdout
    record["tests"][0]["outcome"] = "failed"
    result = persist(source, write_record(tmp_path, record))
    assert result.returncode != 0 and "overwrite" in result.stderr
    assert git(origin, "rev-parse", "compatibility-data").stdout == revision
    assert not list(tmp_path.glob("compat-history.*"))


@pytest.mark.parametrize("invalid", ["run", "suite", "coverage", "symlink"])
def test_untrusted_result_is_rejected_before_a_history_push(
    history_repo, tmp_path, record, invalid
):
    source, origin = history_repo
    if invalid == "suite":
        record["suite_digest"] = "0" * 64
    elif invalid == "coverage":
        record["expected_tests"].pop()
        record["tests"].pop()
    path = write_record(tmp_path, record)
    if invalid == "symlink":
        link = tmp_path / "linked.json"
        link.symlink_to(path)
        path = link
    result = persist(source, path, run_url=RUN_URL + "0" if invalid == "run" else RUN_URL)
    assert result.returncode != 0
    assert (
        git(origin, "show-ref", "--verify", "refs/heads/compatibility-data", check=False).returncode
        != 0
    )
    assert not list(tmp_path.glob("compat-history.*"))


@pytest.mark.parametrize("initial_history", [False, True])
def test_concurrent_writer_is_preserved_when_a_push_retries(
    history_repo, tmp_path, record, initial_history
):
    source, origin = history_repo
    expected_ids = {record["id"], "c" * 32}
    if initial_history:
        prior = deepcopy(record)
        prior["id"] = "b" * 32
        result = persist(source, write_record(tmp_path, prior))
        assert result.returncode == 0, result.stderr
        expected_ids.add(prior["id"])
    competitor = tmp_path / "competitor"
    git(tmp_path, "clone", "--quiet", str(origin), str(competitor))
    competing_record = deepcopy(record)
    competing_record["id"] = "c" * 32
    competing_path = write_record(tmp_path, competing_record)
    marker = tmp_path / "competing-push"
    injected = tmp_path / "concurrent-writer.sh"
    injected.write_text(
        "git() {\n"
        f'  if [[ "$1" == push && ! -e {shlex.quote(str(marker))} ]]; then\n'
        f"    touch {shlex.quote(str(marker))}\n"
        f"    (cd {shlex.quote(str(competitor))} && bash {shlex.quote(str(SCRIPT))} "
        f"{shlex.quote(str(competing_path))} {shlex.quote(RUN_URL)}) || return\n"
        "  fi\n"
        '  command git "$@"\n'
        "}\n"
    )
    result = persist(
        source,
        write_record(tmp_path, record),
        environment={**os.environ, "BASH_ENV": str(injected)},
    )
    assert result.returncode == 0, result.stderr
    assert "retrying from the current remote history" in result.stderr
    assert set(
        git(origin, "ls-tree", "-r", "--name-only", "compatibility-data").stdout.split()
    ) == {f"results/{identifier}.json" for identifier in expected_ids}
    for original in (record, competing_record):
        assert (
            json.loads(
                git(origin, "show", f"compatibility-data:results/{original['id']}.json").stdout
            )
            == original
        )
    assert not list(tmp_path.glob("compat-history.*"))


def test_remote_lookup_failure_is_not_treated_as_an_empty_history(history_repo, tmp_path, record):
    source, _ = history_repo
    git(source, "remote", "set-url", "origin", str(tmp_path / "missing.git"))
    result = persist(source, write_record(tmp_path, record))
    assert result.returncode != 0
    assert "Could not look up" in result.stderr
    assert not list(tmp_path.glob("compat-history.*"))
