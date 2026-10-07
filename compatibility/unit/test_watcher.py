# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Exercise release discovery and interrupted dispatches without inference or GitHub writes."""

import hashlib
import json
from copy import deepcopy
from dataclasses import replace
from datetime import datetime, timezone

import pytest

from compatibility import watcher
from compatibility.contracts import validate_schema
from compatibility.watcher_state import GitHub, RequestError

pytestmark = pytest.mark.unit


def metadata(version):
    return {
        "info": {"name": "pymongo", "version": version, "requires_python": ">=3.9"},
        "urls": [
            {
                "filename": f"pymongo-{version}-cp312-cp312-manylinux_2_17_x86_64.whl",
                "packagetype": "bdist_wheel",
                "yanked": False,
                "requires_python": ">=3.9",
                "digests": {"sha256": hashlib.sha256(version.encode()).hexdigest()},
            }
        ],
    }


def release(version, identifier=100):
    return {
        "id": identifier,
        "tag_name": version,
        "draft": False,
        "prerelease": False,
        "html_url": f"https://github.com/{watcher.UPSTREAM}/releases/tag/{version}",
        "published_at": "2026-10-01T00:00:00Z",
        "body": "Stable upstream release notes.",
    }


class FakeAPI(GitHub):
    def __init__(self, releases):
        super().__init__("example/project", "unit-token")
        self.releases = releases
        self.dispatches = []
        self.runs = []
        self.mode = "success"
        self.persisted = None

    def request(self, method, path, payload=None):
        assert method == "GET", (method, path)
        if path == f"/repos/{watcher.UPSTREAM}/releases?per_page=30":
            return deepcopy(self.releases)
        prefix = f"/repos/{watcher.UPSTREAM}/releases/"
        if path.startswith(prefix):
            return deepcopy(next(r for r in self.releases if str(r["id"]) == path[len(prefix) :]))
        raise AssertionError(f"Unexpected API request: {method} {path}")

    def local(self, method, path, payload=None):
        if method == "POST" and path == "/actions/workflows/compatibility.yml/dispatches":
            identifier = payload["inputs"]["detection_id"]
            nonce = payload["inputs"]["dispatch_id"]
            persisted = self.persisted["entries"][identifier]
            assert persisted["status"] == "dispatching"
            assert persisted["attempts"][-1]["id"] == nonce
            self.dispatches.append(deepcopy(payload))
            if self.mode == "rate-limit":
                raise RequestError("Rate limited", 429, True)
            if self.mode == "denied":
                raise RequestError("Permission denied", 403)
            if self.mode == "ambiguous-missing":
                raise RequestError("Connection failed")
            run_id = 500 + len(self.runs)
            run = {
                "id": run_id,
                "head_branch": "main",
                "event": "workflow_dispatch",
                "path": ".github/workflows/compatibility.yml",
                "display_title": watcher.dispatch_title(identifier, nonce),
                "html_url": f"https://github.com/{self.repository}/actions/runs/{run_id}",
                "status": "completed",
                "conclusion": "success",
            }
            self.runs.append(run)
            if self.mode == "ambiguous-accepted":
                raise RequestError("Connection failed after acceptance")
            if self.mode == "malformed":
                return {"workflow_run_id": run_id, "html_url": "https://unreviewed.example/run"}
            return {
                "workflow_run_id": run_id,
                "html_url": run["html_url"],
                "run_url": f"https://api.github.com/repos/{self.repository}/actions/runs/{run_id}",
            }
        if method == "GET" and path.startswith("/actions/workflows/compatibility.yml/runs?"):
            return {"total_count": len(self.runs), "workflow_runs": deepcopy(self.runs)}
        if method == "GET" and path.startswith("/actions/runs/"):
            return deepcopy(
                next(run for run in self.runs if str(run["id"]) == path.rsplit("/", 1)[1])
            )
        raise AssertionError(f"Unexpected local API request: {method} {path}")


class MemoryLedger:
    def __init__(self, api):
        self.api = api
        self.state = {"schema_version": 1, "entries": {}, "last_scan": None}
        self.snapshots = []
        self.reject_save = False

    def load(self):
        if self.api.persisted is not None:
            self.state = deepcopy(self.api.persisted)

    def save(self):
        if self.reject_save:
            raise RequestError("Concurrent state writer", 422)
        validate_schema(self.state, "watcher")
        self.api.persisted = deepcopy(self.state)
        self.snapshots.append(deepcopy(self.state))


@pytest.fixture
def context(monkeypatch):
    monkeypatch.setattr(watcher, "now", lambda: datetime(2026, 10, 7, tzinfo=timezone.utc))
    return watcher.Context(
        "example/project",
        "main",
        "a" * 40,
        "https://github.com/example/project/actions/runs/42/attempts/1",
        "unit-model",
    )


@pytest.fixture
def ledger(registry, monkeypatch):
    version = registry["integrations"]["pymongo"]["default_version"]
    monkeypatch.setattr(watcher, "package_metadata", lambda selected: metadata(selected))
    return MemoryLedger(FakeAPI([release(version)]))


def detect(ledger, registry, context):
    selected = watcher.discover(ledger, registry, context)
    assert len(selected) == 1
    identifier = selected[0]["detection_id"]
    return identifier, ledger.state["entries"][identifier]


def assessment(identifier, **changes):
    item = {"detection_id": identifier, "summary": "Upstream describes fixes.", "scenario_ids": []}
    item.update(changes)
    return {"items": [{"type": "assess_releases", "assessments": json.dumps([item])}]}


@pytest.mark.parametrize("mutation", ["yanked", "runtime", "python", "source-only"])
def test_ineligible_packages_cannot_become_dispatches(
    registry, ledger, context, monkeypatch, mutation
):
    version = registry["integrations"]["pymongo"]["default_version"]
    value = metadata(version)
    if mutation == "yanked":
        value["urls"][0]["yanked"] = True
    elif mutation == "runtime":
        value["urls"][0]["filename"] = f"pymongo-{version}-cp313-cp313-win_amd64.whl"
    elif mutation == "python":
        value["info"]["requires_python"] = ">=3.13"
    else:
        value["urls"][0]["packagetype"] = "sdist"
    monkeypatch.setattr(watcher, "package_metadata", lambda selected: value)
    assert watcher.discover(ledger, registry, context) == []
    assert not ledger.state["entries"]
    assert "no eligible" in ledger.api.persisted["last_scan"]["observations"][0]["decision"]
    assert watcher.dispatch(ledger, registry, context)
    assert not ledger.api.dispatches


@pytest.mark.parametrize("mutation", ["draft", "prerelease", "old", "major", "tag", "foreign"])
def test_release_policy_precedes_package_access(ledger, registry, context, monkeypatch, mutation):
    item = ledger.api.releases[0]
    if mutation in {"draft", "prerelease"}:
        item[mutation] = True
    elif mutation == "old":
        item["tag_name"] = "4.9.0"
    elif mutation == "major":
        item["tag_name"] = "5.0.0"
    elif mutation == "tag":
        item["tag_name"] += "; echo unreviewed"
    else:
        item["html_url"] = "https://unreviewed.example/release"
    monkeypatch.setattr(
        watcher,
        "package_metadata",
        lambda *args: pytest.fail("Ineligible release fetched packages"),
    )
    if mutation == "foreign":
        with pytest.raises(ValueError, match="official source"):
            watcher.discover(ledger, registry, context)
        assert ledger.api.persisted["last_scan"]["error"]
    else:
        assert watcher.discover(ledger, registry, context) == []
    assert not ledger.api.dispatches


def test_missing_package_is_audited_and_reconsidered(ledger, registry, context, monkeypatch):
    def missing(version):
        raise RequestError("Not published yet", 404)

    monkeypatch.setattr(watcher, "package_metadata", missing)
    assert watcher.discover(ledger, registry, context) == []
    assert "awaiting" in ledger.api.persisted["last_scan"]["observations"][0]["decision"]
    monkeypatch.setattr(watcher, "package_metadata", metadata)
    assert len(watcher.discover(ledger, registry, context)) == 1


def test_discovery_is_durable_idempotent_and_scoped_to_execution_identity(
    ledger, registry, context
):
    identifier, entry = detect(ledger, registry, context)
    assert entry == ledger.api.persisted["entries"][identifier]
    assert not ledger.api.dispatches
    assert (
        entry["release"]["notes_sha256"]
        == hashlib.sha256(b"Stable upstream release notes.").hexdigest()
    )
    watcher.discover(ledger, registry, context)
    assert list(ledger.state["entries"]) == [identifier]
    registry["integrations"]["pymongo"]["timeout_seconds"] += 1
    watcher.discover(ledger, registry, context)
    assert len(ledger.state["entries"]) == 2
    assert ledger.state["entries"][identifier] == entry


def test_ai_context_is_bounded_and_cannot_choose_commands(ledger, registry, context):
    identifier, _ = detect(ledger, registry, context)
    scenarios = [registry["integrations"]["pymongo"]["expected_tests"][0]]
    watcher.assess(ledger, registry, context, assessment(identifier, scenario_ids=scenarios))
    saved = ledger.api.persisted["entries"][identifier]["analysis"]
    assert saved["status"] == "complete" and saved["scenario_ids"] == scenarios
    assert saved["model"] == context.model and saved["run_url"] == context.run_url
    assert not ledger.api.dispatches


@pytest.mark.parametrize(
    "mutation", ["command", "unknown-id", "scenario", "text", "duplicate", "items"]
)
def test_untrusted_ai_output_cannot_change_pending_work(ledger, registry, context, mutation):
    identifier, _ = detect(ledger, registry, context)
    request = assessment(identifier)
    item = json.loads(request["items"][0]["assessments"])[0]
    if mutation == "command":
        item["command"] = "echo unreviewed"
    elif mutation == "unknown-id":
        item["detection_id"] = "f" * 64
    elif mutation == "scenario":
        item["scenario_ids"] = ["test_undeclared_profile"]
    elif mutation == "text":
        item["summary"] = "\x00"
    items = [item, item] if mutation == "duplicate" else [item]
    request["items"][0]["assessments"] = json.dumps(items)
    if mutation == "items":
        request["items"] = [None]
    prior = deepcopy(ledger.api.persisted)
    with pytest.raises(ValueError):
        watcher.assess(ledger, registry, context, request)
    assert ledger.api.persisted == prior
    assert not ledger.api.dispatches


def test_ai_omission_does_not_discard_an_unambiguous_release(ledger, registry, context):
    identifier, _ = detect(ledger, registry, context)
    assert watcher.dispatch(ledger, registry, context)
    saved = ledger.api.persisted["entries"][identifier]
    assert saved["analysis"]["status"] == "unavailable"
    assert saved["status"] == "dispatched"
    assert ledger.api.dispatches[0]["inputs"] == {
        "integration": "pymongo",
        "version": saved["version"],
        "documentdb_version": saved["documentdb_version"],
        "demonstration": False,
        "detection_id": identifier,
        "dispatch_id": saved["attempts"][0]["id"],
    }
    assert watcher.dispatch(ledger, registry, context)
    assert len(ledger.api.dispatches) == 1
    assert ledger.api.persisted["entries"][identifier]["status"] == "completed"


def test_dispatch_is_bounded_across_reentry_of_the_same_invocation(ledger, registry, context):
    major, minor, patch = registry["integrations"]["pymongo"]["default_version"].split(".")
    ledger.api.releases = [release(f"{major}.{minor}.{int(patch) + n}", 100 + n) for n in range(4)]
    assert len(watcher.discover(ledger, registry, context)) == 3
    watcher.discover(ledger, registry, context)
    assert len(ledger.state["entries"]) == 4
    assert watcher.dispatch(ledger, registry, context)
    assert len(ledger.api.dispatches) == 3
    assert watcher.dispatch(ledger, registry, context)
    assert len(ledger.api.dispatches) == 3
    another = replace(context, run_url=context.run_url.removesuffix("/1") + "/2")
    assert watcher.dispatch(ledger, registry, another)
    assert len(ledger.api.dispatches) == 4


def test_failed_reservation_cannot_send_a_dispatch(ledger, registry, context):
    detect(ledger, registry, context)
    ledger.reject_save = True
    with pytest.raises(RequestError, match="Concurrent"):
        watcher.dispatch(ledger, registry, context)
    assert not ledger.api.dispatches
    assert next(iter(ledger.api.persisted["entries"].values()))["status"] == "pending"


@pytest.mark.parametrize("mode", ["ambiguous-accepted", "malformed"])
def test_ambiguous_acceptance_is_reconciled_without_resending(ledger, registry, context, mode):
    identifier, _ = detect(ledger, registry, context)
    ledger.api.mode = mode
    assert not watcher.dispatch(ledger, registry, context)
    assert ledger.api.persisted["entries"][identifier]["status"] == "dispatching"
    ledger.load()
    assert watcher.dispatch(ledger, registry, context)
    assert ledger.api.persisted["entries"][identifier]["status"] == "completed"
    assert len(ledger.api.dispatches) == 1


def test_unresolved_acceptance_never_blindly_retries(ledger, registry, context):
    identifier, _ = detect(ledger, registry, context)
    ledger.api.mode = "ambiguous-missing"
    assert not watcher.dispatch(ledger, registry, context)
    assert not watcher.dispatch(ledger, registry, context)
    assert ledger.api.persisted["entries"][identifier]["status"] == "blocked"
    assert len(ledger.api.dispatches) == 1


def test_definitive_rate_limits_retry_with_a_durable_ceiling(ledger, registry, context):
    identifier, _ = detect(ledger, registry, context)
    ledger.api.mode = "rate-limit"
    for attempt in range(1, 4):
        invocation = replace(context, run_url=context.run_url.removesuffix("/1") + f"/{attempt}")
        assert not watcher.dispatch(ledger, registry, invocation)
        assert len(ledger.api.dispatches) == attempt
    assert ledger.api.persisted["entries"][identifier]["status"] == "blocked"
    assert not watcher.dispatch(ledger, registry, context)
    assert len(ledger.api.dispatches) == 3


@pytest.mark.parametrize("mutation", ["inputs", "artifacts", "withdrawn"])
def test_changed_policy_or_artifacts_cannot_use_old_authorization(
    ledger, registry, context, monkeypatch, mutation
):
    identifier, _ = detect(ledger, registry, context)
    if mutation == "inputs":
        registry["integrations"]["pymongo"]["timeout_seconds"] += 1
    elif mutation == "withdrawn":
        ledger.api.releases[0]["draft"] = True
    else:
        value = metadata(registry["integrations"]["pymongo"]["default_version"])
        value["urls"][0]["digests"]["sha256"] = "e" * 64
        monkeypatch.setattr(watcher, "package_metadata", lambda version: value)
    assert watcher.dispatch(ledger, registry, context)
    assert ledger.api.persisted["entries"][identifier]["status"] == "superseded"
    assert not ledger.api.dispatches


def test_duplicate_dispatch_runs_require_attention(ledger, registry, context):
    detect(ledger, registry, context)
    ledger.api.mode = "ambiguous-accepted"
    assert not watcher.dispatch(ledger, registry, context)
    other = deepcopy(ledger.api.runs[0])
    other.update(id=999, html_url="https://github.com/example/project/actions/runs/999")
    ledger.api.runs.append(other)
    with pytest.raises(ValueError, match="Multiple"):
        watcher.dispatch(ledger, registry, context)
    assert len(ledger.api.dispatches) == 1


def test_pagination_failure_does_not_authorize_a_retry(ledger, registry, context, monkeypatch):
    detect(ledger, registry, context)
    ledger.api.mode = "ambiguous-missing"
    assert not watcher.dispatch(ledger, registry, context)
    monkeypatch.setattr(
        ledger.api, "local", lambda *args: {"workflow_runs": [], "total_count": 1001}
    )
    with pytest.raises(ValueError, match="pagination"):
        watcher.dispatch(ledger, registry, context)
    assert len(ledger.api.dispatches) == 1


@pytest.mark.parametrize("invalid", [None, "nonce", "version", "source", "demonstration"])
def test_execution_guard_binds_the_exact_pending_profile(
    ledger, registry, context, monkeypatch, invalid
):
    identifier, _ = detect(ledger, registry, context)
    assert watcher.dispatch(ledger, registry, context)
    entry = ledger.api.persisted["entries"][identifier]
    run = {key: entry[key] for key in ("integration", "version", "documentdb_version")}
    run["demonstration"] = False
    nonce = entry["attempts"][-1]["id"]
    monkeypatch.setattr(watcher.Context, "environment", lambda: context)
    monkeypatch.setattr(watcher, "GitHub", lambda *args: ledger.api)
    monkeypatch.setattr(watcher, "GitLedger", lambda *args: ledger)
    monkeypatch.setenv("GITHUB_TOKEN", "unit-token")
    if invalid == "nonce":
        nonce = "f" * 32
    elif invalid == "version":
        run["version"] = "4.99.99"
    elif invalid == "source":
        registry["integrations"]["pymongo"]["timeout_seconds"] += 1
    elif invalid == "demonstration":
        run["demonstration"] = True
    if invalid:
        with pytest.raises(ValueError):
            watcher.validate_dispatch(registry, [run], identifier, nonce)
    else:
        assert watcher.validate_dispatch(registry, [run], identifier, nonce) == [
            entry["artifacts"][0]["sha256"]
        ]


@pytest.mark.parametrize(
    ("variable", "value"),
    [
        (None, None),
        ("COMPATIBILITY_WATCHER_ENABLED", "false"),
        ("COMPATIBILITY_WATCHER_MODEL", ""),
        ("GITHUB_REF", "refs/heads/unreviewed"),
        ("GITHUB_EVENT_NAME", "pull_request"),
        ("GITHUB_REPOSITORY", "example/other"),
        ("GITHUB_SERVER_URL", "https://unreviewed.example"),
    ],
)
def test_execution_context_requires_explicit_trusted_activation(
    tmp_path, monkeypatch, variable, value
):
    event = tmp_path / "event.json"
    event.write_text(
        json.dumps({"repository": {"full_name": "example/project", "default_branch": "main"}})
    )
    environment = {
        "COMPATIBILITY_WATCHER_ENABLED": "true",
        "COMPATIBILITY_WATCHER_MODEL": "unit-model",
        "GITHUB_EVENT_PATH": str(event),
        "GITHUB_REPOSITORY": "example/project",
        "GITHUB_REF": "refs/heads/main",
        "GITHUB_EVENT_NAME": "workflow_dispatch",
        "GITHUB_SERVER_URL": "https://github.com",
        "GITHUB_SHA": "a" * 40,
        "GITHUB_RUN_ID": "42",
        "GITHUB_RUN_ATTEMPT": "1",
    }
    if variable is not None:
        environment[variable] = value
    for key, configured in environment.items():
        monkeypatch.setenv(key, configured)
    if variable is None:
        assert watcher.Context.environment().run_url.endswith("/42/attempts/1")
    else:
        with pytest.raises(ValueError):
            watcher.Context.environment()


def test_a_stale_agent_run_cannot_replace_current_analysis(ledger, registry, context):
    identifier, _ = detect(ledger, registry, context)
    stale = replace(context, run_url=context.run_url.removesuffix("/1") + "/2")
    with pytest.raises(ValueError, match="discovery run"):
        watcher.assess(ledger, registry, stale, assessment(identifier))
    assert ledger.api.persisted["entries"][identifier]["analysis"] is None


def test_a_manually_resumed_unknown_dispatch_is_associated_without_another_request(
    ledger, registry, context
):
    identifier, _ = detect(ledger, registry, context)
    ledger.api.mode = "ambiguous-missing"
    assert not watcher.dispatch(ledger, registry, context)
    assert not watcher.dispatch(ledger, registry, context)
    entry = ledger.api.persisted["entries"][identifier]
    ledger.api.runs.append(
        {
            "id": 999,
            "head_branch": "main",
            "path": ".github/workflows/compatibility.yml",
            "event": "workflow_dispatch",
            "display_title": watcher.dispatch_title(identifier, entry["attempts"][-1]["id"]),
            "html_url": "https://github.com/example/project/actions/runs/999",
            "status": "completed",
            "conclusion": "failure",
        }
    )
    assert watcher.dispatch(ledger, registry, context)
    resumed = ledger.api.persisted["entries"][identifier]
    assert resumed["status"] == "completed"
    assert resumed["attempts"][-1]["conclusion"] == "failure"
    assert resumed["attempts"][-1]["run_id"] == 999
    assert len(ledger.api.dispatches) == 1


@pytest.mark.parametrize("total", [101, 1000])
def test_reconciliation_exhausts_complete_pages_before_accepting_a_run(
    ledger, registry, context, monkeypatch, total
):
    identifier, _ = detect(ledger, registry, context)
    ledger.api.mode = "ambiguous-accepted"
    assert not watcher.dispatch(ledger, registry, context)
    matching = ledger.api.runs[0]
    pages = [{"id": 1000 + number, "display_title": "Unrelated run"} for number in range(total - 1)]
    pages.append(matching)
    called = []

    def listing(method, path):
        from urllib.parse import parse_qs, urlsplit

        assert method == "GET"
        page = int(parse_qs(urlsplit(path).query)["page"][0])
        called.append(page)
        return {"total_count": total, "workflow_runs": pages[(page - 1) * 100 : page * 100]}

    monkeypatch.setattr(ledger.api, "local", listing)
    assert watcher.dispatch(ledger, registry, context)
    assert called == list(range(1, (total + 99) // 100 + 1))
    assert ledger.api.persisted["entries"][identifier]["status"] == "completed"
    assert len(ledger.api.dispatches) == 1


def test_an_incomplete_page_cannot_claim_reconciliation_exhausted_the_feed(
    ledger, registry, context, monkeypatch
):
    detect(ledger, registry, context)
    ledger.api.mode = "ambiguous-missing"
    assert not watcher.dispatch(ledger, registry, context)
    monkeypatch.setattr(ledger.api, "local", lambda *args: {"workflow_runs": [], "total_count": 1})
    with pytest.raises(ValueError, match="incomplete pagination"):
        watcher.dispatch(ledger, registry, context)
    assert len(ledger.api.dispatches) == 1
