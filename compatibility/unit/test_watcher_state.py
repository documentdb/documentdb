# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Exercise metadata boundaries and the ledger's Git object protocol locally."""

import base64
import io
import os
import subprocess
import urllib.error
from copy import deepcopy

import pytest

from compatibility import watcher_state as state

pytestmark = pytest.mark.unit


class LocalGitAPI(state.GitHub):
    """Implement the used Git Data endpoints with a disposable real object store."""

    def __init__(self, path):
        super().__init__("example/project", "unit-token")
        self.path = path
        subprocess.run(["git", "init", "--bare", "--quiet", str(path)], check=True)

    def git(self, *arguments, data=None, check=True):
        return subprocess.run(
            ["git", "--git-dir", str(self.path), *arguments],
            input=data,
            capture_output=True,
            check=check,
            env={
                **os.environ,
                "GIT_AUTHOR_NAME": state.BOT["name"],
                "GIT_AUTHOR_EMAIL": state.BOT["email"],
                "GIT_COMMITTER_NAME": state.BOT["name"],
                "GIT_COMMITTER_EMAIL": state.BOT["email"],
            },
        )

    def local(self, method, path, payload=None):
        reference = f"refs/heads/{state.STATE_BRANCH}"
        if method == "GET" and path == f"/git/ref/heads/{state.STATE_BRANCH}":
            result = self.git("show-ref", "--hash", "--verify", reference, check=False)
            if result.returncode:
                raise state.RequestError("Reference missing", 404)
            return {"object": {"sha": result.stdout.decode().strip()}}
        if method == "GET" and path.startswith("/git/commits/"):
            revision = path.rsplit("/", 1)[1]
            tree = self.git("rev-parse", f"{revision}^{{tree}}").stdout.decode().strip()
            return {"tree": {"sha": tree}}
        if method == "GET" and path.startswith("/git/trees/"):
            contents = self.git("ls-tree", "--long", "-z", path.rsplit("/", 1)[1]).stdout.decode()
            files = []
            for line in contents.strip("\0").split("\0"):
                fields, name = line.split("\t")
                mode, kind, digest, size = fields.split()
                files.append(
                    {"mode": mode, "type": kind, "sha": digest, "size": int(size), "path": name}
                )
            return {"truncated": False, "tree": files}
        if method == "GET" and path.startswith("/git/blobs/"):
            contents = self.git("cat-file", "blob", path.rsplit("/", 1)[1]).stdout
            return {"encoding": "base64", "content": base64.b64encode(contents).decode()}
        if method == "POST" and path == "/git/trees":
            objects = []
            for item in payload["tree"]:
                digest = (
                    self.git("hash-object", "-w", "--stdin", data=item["content"].encode())
                    .stdout.decode()
                    .strip()
                )
                objects.append(f"{item['mode']} blob {digest}\t{item['path']}\n")
            digest = self.git("mktree", data="".join(objects).encode()).stdout.decode().strip()
            return {"sha": digest}
        if method == "POST" and path == "/git/commits":
            parents = [argument for parent in payload["parents"] for argument in ("-p", parent)]
            digest = (
                self.git("commit-tree", payload["tree"], *parents, data=payload["message"].encode())
                .stdout.decode()
                .strip()
            )
            return {"sha": digest}
        if method == "POST" and path == "/git/refs":
            assert payload["ref"] == reference
            result = self.git("update-ref", reference, payload["sha"], "0" * 40, check=False)
        elif method == "PATCH" and path == f"/git/refs/heads/{state.STATE_BRANCH}":
            assert payload["force"] is False
            current = self.git("rev-parse", reference).stdout.decode().strip()
            if self.git(
                "merge-base", "--is-ancestor", current, payload["sha"], check=False
            ).returncode:
                raise state.RequestError("Non-fast-forward update", 422)
            result = self.git("update-ref", reference, payload["sha"], current, check=False)
        else:
            raise AssertionError(f"Unexpected Git API operation: {method} {path}")
        if result.returncode:
            raise state.RequestError("Concurrent reference update", 422)
        return {"object": {"sha": payload["sha"]}}


def scanned(run):
    return {
        "run_url": f"https://github.com/example/project/actions/runs/{run}/attempts/1",
        "at": "2026-10-01T00:00:00Z",
        "observations": [],
        "error": None,
    }


def test_git_ledger_round_trips_an_orphan_data_branch(tmp_path):
    api = LocalGitAPI(tmp_path / "state.git")
    original = state.GitLedger(api)
    original.load()
    original.save()
    original.state["last_scan"] = scanned(1)
    original.save()
    reloaded = state.GitLedger(api)
    reloaded.load()
    assert reloaded.head == original.head and reloaded.state == original.state
    commits = api.git("rev-list", "--parents", state.STATE_BRANCH).stdout.decode().splitlines()
    assert len(commits) == 2 and len(commits[-1].split()) == 1
    assert api.git("ls-tree", "--name-only", original.head).stdout == b"ledger.json\n"
    assert (
        b"Signed-off-by: github-actions[bot]"
        in api.git("show", "-s", "--format=%B", original.head).stdout
    )


@pytest.mark.parametrize("existing", [False, True])
def test_git_state_conflicts_preserve_the_other_writers_evidence(tmp_path, existing):
    api = LocalGitAPI(tmp_path / "state.git")
    if existing:
        state.GitLedger(api).save()
    first, second = state.GitLedger(api), state.GitLedger(api)
    first.load()
    second.load()
    first.state["last_scan"] = scanned(1)
    second.state["last_scan"] = scanned(2)
    first.save()
    prior = second.head
    with pytest.raises(state.RequestError) as error:
        second.save()
    assert error.value.status == 422 and second.head == prior
    actual = state.GitLedger(api)
    actual.load()
    assert actual.state == first.state and actual.head == first.head


def test_state_load_rejects_a_symlink_instead_of_following_it(tmp_path):
    api = LocalGitAPI(tmp_path / "state.git")
    tree = api.local(
        "POST",
        "/git/trees",
        {
            "tree": [
                {
                    "path": "ledger.json",
                    "mode": "120000",
                    "content": "../outside.json",
                }
            ]
        },
    )
    commit = api.local(
        "POST",
        "/git/commits",
        {"tree": tree["sha"], "parents": [], "message": "Invalid unit fixture"},
    )
    api.local(
        "POST", "/git/refs", {"ref": f"refs/heads/{state.STATE_BRANCH}", "sha": commit["sha"]}
    )
    with pytest.raises(ValueError, match="regular ledger"):
        state.GitLedger(api).load()


def test_invalid_or_full_state_cannot_advance_the_branch(tmp_path, monkeypatch):
    api = LocalGitAPI(tmp_path / "state.git")
    ledger = state.GitLedger(api)
    ledger.save()
    head = ledger.head
    before = deepcopy(ledger.state)
    ledger.state["unreviewed_field"] = True
    with pytest.raises(ValueError):
        ledger.save()
    ledger.state = before
    monkeypatch.setattr(state, "MAX_STATE_BYTES", 1)
    with pytest.raises(ValueError, match="full"):
        ledger.save()
    assert api.git("rev-parse", state.STATE_BRANCH).stdout.decode().strip() == head


@pytest.mark.parametrize(
    ("url", "token"),
    [
        ("https://pypi.org/pypi/pymongo/4.18.0/json", "unit-token"),
        ("https://api.github.com.unreviewed.example/repos/example/project", None),
        ("https://pypi.org/pypi/unreviewed/1.0/json", None),
        ("http://api.github.com/repos/example/project", "unit-token"),
    ],
)
def test_unreviewed_sources_never_receive_requests(monkeypatch, url, token):
    monkeypatch.setattr(
        state.urllib.request,
        "build_opener",
        lambda *args: pytest.fail("Unreviewed source or credential boundary was crossed"),
    )
    with pytest.raises(ValueError, match="reviewed public sources"):
        state.request_json(url, token=token)


def test_metadata_transport_separates_credentials_and_disables_redirects(monkeypatch):
    requests = []

    class Transport:
        def open(self, request, timeout):
            requests.append(request)
            assert timeout == 30
            return io.BytesIO(b'{"ok":true}')

    def opener(handler):
        assert isinstance(handler, state.NoRedirect)
        assert (
            handler.redirect_request(None, None, 302, "", {}, "https://unreviewed.example") is None
        )
        return Transport()

    monkeypatch.setattr(state.urllib.request, "build_opener", opener)
    state.request_json("https://api.github.com/repos/example/project", token="unit-token")
    state.request_json("https://pypi.org/pypi/pymongo/4.18.0/json")
    assert requests[0].get_header("Authorization") == "Bearer unit-token"
    assert requests[0].get_header("X-github-api-version") == "2026-03-10"
    assert requests[1].get_header("Authorization") is None


@pytest.mark.parametrize(
    ("code", "headers", "retryable"),
    [
        (429, {}, True),
        (403, {"X-RateLimit-Remaining": "0"}, True),
        (403, {}, False),
        (302, {}, False),
    ],
)
def test_only_definite_rate_limits_are_retryable(monkeypatch, code, headers, retryable):
    class Transport:
        def open(self, request, timeout):
            raise urllib.error.HTTPError(request.full_url, code, "unit response", headers, None)

    monkeypatch.setattr(state.urllib.request, "build_opener", lambda *args: Transport())
    with pytest.raises(state.RequestError) as error:
        state.request_json("https://api.github.com/repos/example/project", token="unit-token")
    assert error.value.status == code and error.value.retryable is retryable


@pytest.mark.parametrize("contents", [b"{broken", b"x" * 33])
def test_invalid_or_oversized_responses_have_unknown_outcomes(monkeypatch, contents):
    class Transport:
        def open(self, request, timeout):
            return io.BytesIO(contents)

    monkeypatch.setattr(state, "MAX_RESPONSE_BYTES", 32)
    monkeypatch.setattr(state.urllib.request, "build_opener", lambda *args: Transport())
    with pytest.raises(state.RequestError) as error:
        state.request_json("https://api.github.com/repos/example/project", token="unit-token")
    assert error.value.status is None and not error.value.retryable
