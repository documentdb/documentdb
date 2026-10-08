# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Discover bounded PyMongo releases, retain AI context, and dispatch reviewed profiles."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlencode

from packaging.specifiers import SpecifierSet
from packaging.tags import compatible_tags, cpython_tags
from packaging.utils import parse_wheel_filename
from packaging.version import Version

from compatibility.contracts import (
    PYTHON_PLATFORMS,
    ROOT,
    read_registry,
    suite_digest,
    timestamp,
    validate_schema,
)
from compatibility.watcher_state import (
    GitHub,
    GitLedger,
    RequestError,
    json_digest,
    request_json,
)

UPSTREAM = "mongodb/mongo-python-driver"
WORKFLOW = "compatibility.yml"
MAX_DISPATCHES = 3
MAX_ATTEMPTS = 3
PROMPT = ROOT / ".github/workflows/compatibility-watcher.md"
IDENTITY_FIELDS = (
    "integration",
    "version",
    "documentdb_version",
    "documentdb_image",
    "profile",
    "suite_digest",
    "artifacts",
)


def now() -> datetime:
    return datetime.now(timezone.utc)


def read_json_file(path: Path) -> Any:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise ValueError("Watcher input must be a bounded regular JSON file")
    return json.loads(path.read_text())


@dataclass(frozen=True)
class Context:
    repository: str
    branch: str
    source_sha: str
    run_url: str
    model: str

    @classmethod
    def environment(cls) -> Context:
        if os.environ.get("COMPATIBILITY_WATCHER_ENABLED") != "true":
            raise ValueError("The compatibility watcher requires explicit maintainer opt-in")
        event = read_json_file(Path(os.environ["GITHUB_EVENT_PATH"]))
        repository = os.environ["GITHUB_REPOSITORY"]
        branch = event["repository"]["default_branch"]
        model = os.environ.get("COMPATIBILITY_WATCHER_MODEL", "")
        revision = os.environ["GITHUB_SHA"]
        run_id = os.environ["GITHUB_RUN_ID"]
        attempt = os.environ["GITHUB_RUN_ATTEMPT"]
        if (
            os.environ.get("GITHUB_SERVER_URL") != "https://github.com"
            or os.environ.get("GITHUB_EVENT_NAME") not in {"schedule", "workflow_dispatch"}
            or event["repository"]["full_name"] != repository
            or not isinstance(branch, str)
            or os.environ.get("GITHUB_REF") != f"refs/heads/{branch}"
            or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
            or not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", model)
            or not re.fullmatch(r"[a-f0-9]{40}", revision)
            or not re.fullmatch(r"[1-9][0-9]*", run_id)
            or not re.fullmatch(r"[1-9][0-9]*", attempt)
        ):
            raise ValueError(
                "Watcher execution requires a configured model and trusted default-branch context"
            )
        return cls(
            repository,
            branch,
            revision,
            f"https://github.com/{repository}/actions/runs/{run_id}/attempts/{attempt}",
            model,
        )


def detection_key(entry: dict[str, Any]) -> str:
    return json_digest({key: entry[key] for key in IDENTITY_FIELDS})


def watched_spec(registry: dict[str, Any]) -> dict[str, Any] | None:
    spec = registry["integrations"].get("pymongo")
    if spec is None or not spec["enabled"]:
        return None
    if (
        spec["package"] != "pymongo"
        or spec["runtime"] != "python"
        or spec["repository"] != f"https://github.com/{UPSTREAM}"
    ):
        raise ValueError("The initial watcher supports only the reviewed official PyMongo profile")
    return dict(spec)


def release_version(release: dict[str, Any], spec: dict[str, Any]) -> str | None:
    tag = release["tag_name"]
    if (
        not isinstance(tag, str)
        or len(tag) > 100
        or release["draft"] is not False
        or release["prerelease"] is not False
        or not re.fullmatch(r"v?[0-9]+\.[0-9]+(?:\.[0-9]+)?", tag)
    ):
        return None
    parsed = Version(tag.removeprefix("v"))
    version = f"{parsed.major}.{parsed.minor}.{parsed.micro}"
    if not re.fullmatch(spec["version_pattern"], version) or parsed < Version(
        spec["default_version"]
    ):
        return None
    if (
        type(release["id"]) is not int
        or release["id"] < 1
        or release["html_url"] != f"https://github.com/{UPSTREAM}/releases/tag/{tag}"
        or timestamp(release["published_at"]) > now() + timedelta(minutes=5)
    ):
        raise ValueError("Release identity or publication time does not match the official source")
    return version


def eligible_artifacts(metadata: dict[str, Any], version: str) -> list[dict[str, str]]:
    if metadata["info"]["name"] != "pymongo" or Version(metadata["info"]["version"]) != Version(
        version
    ):
        raise ValueError("PyPI metadata does not describe the selected PyMongo release")
    if not SpecifierSet(metadata["info"].get("requires_python") or "").contains("3.12.0"):
        return []
    supported = set(cpython_tags((3, 12), abis=["cp312"], platforms=list(PYTHON_PLATFORMS)))
    supported.update(
        compatible_tags((3, 12), interpreter="cp312", platforms=list(PYTHON_PLATFORMS))
    )
    artifacts = []
    for asset in metadata["urls"]:
        if asset["packagetype"] != "bdist_wheel" or asset["yanked"]:
            continue
        name, published, _, tags = parse_wheel_filename(asset["filename"])
        if name != "pymongo" or published != Version(version):
            raise ValueError("Published wheel identity disagrees with PyPI release metadata")
        if not tags.intersection(supported):
            continue
        if not SpecifierSet(asset.get("requires_python") or "").contains("3.12.0"):
            continue
        digest = asset["digests"]["sha256"]
        if not isinstance(digest, str) or not re.fullmatch(r"[a-f0-9]{64}", digest):
            raise ValueError("Published wheel is missing a SHA-256 identity")
        artifacts.append({"filename": asset["filename"], "sha256": digest})
    if len(artifacts) > 10 or len({a["filename"] for a in artifacts}) != len(artifacts):
        raise ValueError("Published wheel selection is ambiguous or exceeds its limit")
    return sorted(artifacts, key=lambda asset: asset["filename"])


def package_metadata(version: str) -> dict[str, Any]:
    value = request_json(f"https://pypi.org/pypi/pymongo/{quote(version, safe='')}/json")
    if not isinstance(value, dict):
        raise ValueError("PyPI did not return a release object")
    return value


def candidate(
    release: dict[str, Any],
    metadata: dict[str, Any],
    version: str,
    database_version: str,
    registry: dict[str, Any],
    context: Context,
) -> dict[str, Any] | None:
    spec = watched_spec(registry)
    if spec is None:
        return None
    artifacts = eligible_artifacts(metadata, version)
    if not artifacts:
        return None
    notes = release.get("body") or ""
    if not isinstance(notes, str):
        raise ValueError("Release notes must be text")
    return {
        "integration": "pymongo",
        "version": version,
        "documentdb_version": database_version,
        "documentdb_image": registry["documentdb"][database_version]["image"],
        "profile": spec["profile"],
        "suite_digest": suite_digest("pymongo", spec),
        "artifacts": artifacts,
        "release": {
            "id": release["id"],
            "tag": release["tag_name"],
            "url": release["html_url"],
            "published_at": release["published_at"],
            "notes": notes[:2000],
            "notes_sha256": hashlib.sha256(notes.encode()).hexdigest(),
        },
        "metadata_sha256": json_digest(metadata),
        "detected_at": now().isoformat(),
        "source_sha": context.source_sha,
        "detected_by": context.run_url,
        "status": "pending",
        "attempts": [],
        "review_run_url": context.run_url,
        "analysis": None,
        "error": None,
    }


def discover(ledger: GitLedger, registry: dict[str, Any], context: Context) -> list[dict[str, Any]]:
    spec = watched_spec(registry)
    observations: list[dict[str, str]] = []
    ledger.state["last_scan"] = {
        "run_url": context.run_url,
        "at": now().isoformat(),
        "observations": observations,
        "error": None,
    }
    try:
        if spec is not None:
            releases = ledger.api.request("GET", f"/repos/{UPSTREAM}/releases?per_page=30")
            if not isinstance(releases, list) or len(releases) > 30:
                raise ValueError("Upstream release feed exceeded its reviewed bound")
            added = 0
            for release in releases:
                version = release_version(release, spec)
                observation = {"tag": str(release["tag_name"])[:100], "decision": "outside policy"}
                observations.append(observation)
                if version is None:
                    continue
                try:
                    metadata = package_metadata(version)
                except RequestError as error:
                    if error.status != 404:
                        raise
                    observation["decision"] = "awaiting published PyPI metadata"
                    continue
                observation["decision"] = "no eligible, non-yanked Python 3.12 baseline wheel"
                for database in sorted(registry["documentdb"], key=Version, reverse=True):
                    entry = candidate(release, metadata, version, database, registry, context)
                    if entry is None:
                        continue
                    identifier = detection_key(entry)
                    observation["decision"] = "eligible"
                    if identifier not in ledger.state["entries"]:
                        ledger.state["entries"][identifier] = entry
                        added += 1
                    if added >= MAX_DISPATCHES:
                        break
                if added >= MAX_DISPATCHES:
                    break
    except (RequestError, ValueError, KeyError, TypeError) as error:
        ledger.state["last_scan"]["error"] = str(error)[:500]
        ledger.save()
        raise
    selected = []
    for identifier, entry in sorted(ledger.state["entries"].items()):
        if (
            entry["status"] == "pending"
            and entry["analysis"] is None
            and spec is not None
            and current_identity(entry, registry)
        ):
            entry["review_run_url"] = context.run_url
            selected.append(
                {
                    "detection_id": identifier,
                    "version": entry["version"],
                    "release": entry["release"],
                    "scenario_ids": spec["expected_tests"],
                }
            )
            if len(selected) == MAX_DISPATCHES:
                break
    ledger.save()
    return selected


def analysis_record(
    context: Context, summary: str, scenarios: list[str], status: str
) -> dict[str, Any]:
    return {
        "status": status,
        "model": context.model,
        "run_url": context.run_url,
        "prompt_sha256": hashlib.sha256(PROMPT.read_bytes()).hexdigest(),
        "summary": summary,
        "scenario_ids": scenarios,
    }


def assess(ledger: GitLedger, registry: dict[str, Any], context: Context, output: Any) -> None:
    if (
        not isinstance(output, dict)
        or not isinstance(output.get("items"), list)
        or len(output["items"]) > 10
        or any(not isinstance(item, dict) for item in output["items"])
    ):
        raise ValueError("AI output is not a safe-output envelope")
    requests = [item for item in output["items"] if item.get("type") == "assess_releases"]
    if len(requests) != 1 or not isinstance(requests[0].get("assessments"), str):
        raise ValueError("Exactly one structured release-assessment request is required")
    assessments = json.loads(requests[0]["assessments"])
    if not isinstance(assessments, list) or not 1 <= len(assessments) <= MAX_DISPATCHES:
        raise ValueError("AI assessment count is outside the reviewed limit")
    seen = set()
    prepared = {}
    for item in assessments:
        if not isinstance(item, dict) or set(item) != {"detection_id", "summary", "scenario_ids"}:
            raise ValueError(
                "AI assessments may contain only identities, summaries, and scenario IDs"
            )
        identifier = item["detection_id"]
        if not isinstance(identifier, str) or identifier in seen:
            raise ValueError("AI assessment contains a duplicate or malformed detection ID")
        seen.add(identifier)
        entry = ledger.state["entries"].get(identifier)
        if (
            entry is None
            or entry["status"] != "pending"
            or entry["review_run_url"] != context.run_url
        ):
            raise ValueError("AI assessment does not belong to this discovery run")
        summary = item["summary"]
        scenarios = item["scenario_ids"]
        if (
            not isinstance(summary, str)
            or not 1 <= len(summary) <= 1000
            or re.search(r"[\x00-\x08\x0b-\x1f]", summary)
            or not isinstance(scenarios, list)
            or any(not isinstance(name, str) for name in scenarios)
            or len(scenarios) != len(set(scenarios))
            or not set(scenarios).issubset(
                registry["integrations"][entry["integration"]]["expected_tests"]
            )
        ):
            raise ValueError("AI assessment has invalid text or invents unreviewed scenarios")
        prepared[identifier] = analysis_record(context, summary, scenarios, "complete")
    for identifier, analysis in prepared.items():
        ledger.state["entries"][identifier]["analysis"] = analysis
    ledger.save()


def current_identity(entry: dict[str, Any], registry: dict[str, Any]) -> bool:
    spec = watched_spec(registry)
    database = registry["documentdb"].get(entry["documentdb_version"])
    return bool(
        spec is not None
        and database is not None
        and re.fullmatch(spec["version_pattern"], entry["version"])
        and Version(entry["version"]) >= Version(spec["default_version"])
        and entry["documentdb_image"] == database["image"]
        and entry["profile"] == spec["profile"]
        and entry["suite_digest"] == suite_digest("pymongo", spec)
    )


def dispatch_title(identifier: str, attempt: str) -> str:
    return f"Ecosystem compatibility [watch:{identifier}:{attempt}]"


def verify_run(
    run: dict[str, Any], repository: str, branch: str, identifier: str, attempt: str
) -> None:
    if (
        type(run.get("id")) is not int
        or run["id"] < 1
        or run.get("event") != "workflow_dispatch"
        or run.get("head_branch") != branch
        or run.get("path")
        not in {f".github/workflows/{WORKFLOW}", f".github/workflows/{WORKFLOW}@{branch}"}
        or run.get("display_title") != dispatch_title(identifier, attempt)
        or run.get("html_url") != f"https://github.com/{repository}/actions/runs/{run['id']}"
    ):
        raise ValueError("Workflow receipt does not match the recorded dispatch identity")


def find_run(
    api: GitHub, branch: str, identifier: str, attempt: dict[str, Any]
) -> dict[str, Any] | None:
    if attempt["run_id"] is not None:
        run = api.local("GET", f"/actions/runs/{attempt['run_id']}")
        verify_run(run, api.repository, branch, identifier, attempt["id"])
        return dict(run)
    earliest = max(
        timestamp(attempt["started_at"]) - timedelta(minutes=5), now() - timedelta(days=7)
    )
    found = []
    visited: set[int] = set()
    for page in range(1, 11):
        query = urlencode(
            {
                "event": "workflow_dispatch",
                "created": ">=" + earliest.isoformat(),
                "per_page": 100,
                "page": page,
            }
        )
        response = api.local("GET", f"/actions/workflows/{WORKFLOW}/runs?{query}")
        runs = response["workflow_runs"]
        total = response["total_count"]
        if (
            not isinstance(runs, list)
            or len(runs) > 100
            or type(total) is not int
            or not 0 <= total <= 1000
        ):
            raise ValueError("Dispatch reconciliation exceeded its complete pagination bound")
        for run in runs:
            run_id = run.get("id")
            if type(run_id) is not int or run_id in visited:
                raise ValueError("Dispatch reconciliation returned invalid or repeated run IDs")
            visited.add(run_id)
            if run.get("display_title") == dispatch_title(identifier, attempt["id"]):
                verify_run(run, api.repository, branch, identifier, attempt["id"])
                found.append(run)
        if len(visited) == total:
            if len(found) > 1:
                raise ValueError(
                    "Multiple workflow runs share a dispatch nonce; inspect them before retrying"
                )
            return dict(found[0]) if found else None
        if len(runs) < 100 or len(visited) > total:
            raise ValueError("Dispatch reconciliation returned incomplete pagination")
    raise ValueError("Dispatch reconciliation could not exhaust the run list")


def reconcile(ledger: GitLedger, context: Context) -> None:
    for identifier, entry in ledger.state["entries"].items():
        if entry["status"] not in {"dispatching", "dispatched", "blocked"} or not entry["attempts"]:
            continue
        attempt = entry["attempts"][-1]
        run = find_run(ledger.api, context.branch, identifier, attempt)
        if run is not None:
            attempt.update(
                state="reconciled",
                run_id=run["id"],
                run_url=run["html_url"],
                conclusion=run["conclusion"],
                error=None,
            )
            entry["status"] = "completed" if run["status"] == "completed" else "dispatched"
            entry["error"] = None
        elif entry["status"] in {"dispatching", "dispatched"}:
            entry["status"] = "blocked"
            entry["error"] = (
                "Dispatch outcome is unknown; inspect or manually resume this nonce "
                "instead of resending"
            )
            attempt["state"] = "unknown"
            attempt["error"] = entry["error"]
        ledger.save()


def dispatch(ledger: GitLedger, registry: dict[str, Any], context: Context) -> bool:
    reconcile(ledger, context)
    used = sum(
        attempt["watcher_run_url"] == context.run_url
        for entry in ledger.state["entries"].values()
        for attempt in entry["attempts"]
    )
    entries = sorted(
        ledger.state["entries"].items(), key=lambda item: (item[1]["detected_at"], item[0])
    )
    for identifier, entry in entries:
        if entry["status"] != "pending":
            continue
        if not current_identity(entry, registry):
            entry.update(
                status="superseded", error="Reviewed execution inputs or release policy changed"
            )
            ledger.save()
            continue
        if used >= MAX_DISPATCHES:
            break
        release = ledger.api.request("GET", f"/repos/{UPSTREAM}/releases/{entry['release']['id']}")
        spec = watched_spec(registry)
        if spec is None:
            raise ValueError("The watched integration is no longer enabled")
        if (
            release_version(release, spec) != entry["version"]
            or eligible_artifacts(package_metadata(entry["version"]), entry["version"])
            != entry["artifacts"]
        ):
            entry.update(
                status="superseded", error="The upstream release or eligible artifacts changed"
            )
            ledger.save()
            continue
        if len(entry["attempts"]) >= MAX_ATTEMPTS:
            entry.update(status="blocked", error="Automatic dispatch retry limit reached")
            ledger.save()
            continue
        if entry["analysis"] is None:
            entry["analysis"] = analysis_record(
                context,
                "AI assessment unavailable; deterministic release eligibility "
                "selected the complete profile",
                [],
                "unavailable",
            )
            print(f"::warning::AI assessment unavailable for detection {identifier}")
        attempt: dict[str, Any] = {
            "id": uuid.uuid4().hex,
            "watcher_run_url": context.run_url,
            "started_at": now().isoformat(),
            "state": "dispatching",
            "run_id": None,
            "run_url": None,
            "conclusion": None,
            "error": None,
        }
        entry["attempts"].append(attempt)
        entry.update(status="dispatching", error=None)
        ledger.save()
        used += 1
        try:
            receipt = ledger.api.local(
                "POST",
                f"/actions/workflows/{WORKFLOW}/dispatches",
                {
                    "ref": context.branch,
                    "inputs": {
                        "integration": entry["integration"],
                        "version": entry["version"],
                        "documentdb_version": entry["documentdb_version"],
                        "demonstration": False,
                        "detection_id": identifier,
                        "dispatch_id": attempt["id"],
                    },
                },
            )
            run_id = receipt.get("workflow_run_id") if isinstance(receipt, dict) else None
            if (
                type(run_id) is not int
                or run_id < 1
                or receipt.get("html_url")
                != f"https://github.com/{context.repository}/actions/runs/{run_id}"
                or receipt.get("run_url")
                != f"https://api.github.com/repos/{context.repository}/actions/runs/{run_id}"
            ):
                raise RequestError("Dispatch returned no verifiable workflow receipt")
            attempt.update(state="dispatched", run_id=run_id, run_url=receipt["html_url"])
            entry["status"] = "dispatched"
        except RequestError as error:
            attempt["error"] = entry["error"] = str(error)[:500]
            if error.status is not None and 400 <= error.status < 500:
                attempt["state"] = "rejected"
                entry["status"] = (
                    "pending"
                    if error.retryable and len(entry["attempts"]) < MAX_ATTEMPTS
                    else "blocked"
                )
            else:
                attempt["state"] = "unknown"
            print(
                f"::error::Dispatch {identifier} requires attention: {entry['error']}",
                file=sys.stderr,
            )
        ledger.save()
    attention = [
        identifier
        for identifier, entry in ledger.state["entries"].items()
        if entry["status"] in {"dispatching", "blocked"}
        or (entry["status"] == "pending" and entry["error"] is not None)
    ]
    if attention:
        print("::error::Unresolved dispatches: " + ", ".join(attention), file=sys.stderr)
    return not attention


def validate_dispatch(
    registry: dict[str, Any],
    runs: list[dict[str, Any]],
    identifier: str,
    dispatch_id: str,
) -> list[str]:
    if (
        not re.fullmatch(r"[a-f0-9]{64}", identifier)
        or not re.fullmatch(r"[a-f0-9]{32}", dispatch_id)
        or len(runs) != 1
        or runs[0]["demonstration"]
    ):
        raise ValueError(
            "An upstream dispatch requires one normal profile and valid ledger identities"
        )
    context = Context.environment()
    ledger = GitLedger(GitHub(context.repository, os.environ["GITHUB_TOKEN"]))
    ledger.load()
    entry = ledger.state["entries"].get(identifier)
    if (
        entry is None
        or detection_key(entry) != identifier
        or not entry["attempts"]
        or entry["attempts"][-1]["id"] != dispatch_id
        or entry["status"] not in {"dispatching", "dispatched", "completed", "blocked"}
        or not current_identity(entry, registry)
        or any(
            runs[0][key] != entry[key] for key in ("integration", "version", "documentdb_version")
        )
    ):
        raise ValueError(
            "Dispatch does not match durable pending work and current reviewed execution inputs"
        )
    return sorted({asset["sha256"] for asset in entry["artifacts"]})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("discover", "assess", "dispatch"))
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--agent-output", type=Path)
    args = parser.parse_args()
    try:
        context = Context.environment()
        registry = read_registry()
        ledger = GitLedger(GitHub(context.repository, os.environ["GITHUB_TOKEN"]))
        ledger.load()
        if any(detection_key(entry) != key for key, entry in ledger.state["entries"].items()):
            raise ValueError(
                "Watcher ledger identities do not match their recorded execution inputs"
            )
        if args.command == "discover":
            selected = discover(ledger, registry, context)
            if args.github_output is not None:
                with args.github_output.open("a") as output:
                    output.write("candidates=" + json.dumps(selected, separators=(",", ":")) + "\n")
                    output.write(f"has_candidates={str(bool(selected)).lower()}\n")
            print(f"Persisted discovery; {len(selected)} releases require AI context")
        elif args.command == "assess":
            if args.agent_output is None:
                raise ValueError("The safe-output artifact is required for AI assessments")
            assess(ledger, registry, context, read_json_file(args.agent_output))
            print("Validated AI assessments were retained in the watcher ledger")
        elif not dispatch(ledger, registry, context):
            return 1
        validate_schema(ledger.state, "watcher")
    except (OSError, ValueError, KeyError, TypeError, RequestError) as error:
        print(f"Compatibility watcher failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
