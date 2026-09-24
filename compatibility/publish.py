# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Append immutable results and render a credential-free static compatibility dashboard."""

from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

from jinja2 import Environment, FileSystemLoader, StrictUndefined

from compatibility.contracts import (
    ROOT,
    compatibility_state,
    read_registry,
    suite_digest,
    timestamp,
    validate_result,
)


def read_result(path: Path) -> dict[str, Any]:
    """Read bounded regular JSON files, never symlinks from an artifact or data branch."""
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise ValueError("Result must be a regular JSON file smaller than one MiB")
    value = json.loads(path.read_text())
    validate_result(value)
    return dict(value)


def append_result(store: Path, result: dict[str, Any]) -> Path:
    """Publish a complete file atomically without ever replacing an existing run."""
    validate_result(result)
    if store.is_symlink():
        raise ValueError("The result store must not be a symbolic link")
    store.mkdir(parents=True, exist_ok=True)
    destination = store / f"{result['id']}.json"
    contents = json.dumps(result, indent=2, allow_nan=False) + "\n"
    with tempfile.NamedTemporaryFile(mode="w", dir=store, suffix=".tmp", delete=False) as temporary:
        temporary.write(contents)
        temporary.flush()
        os.fsync(temporary.fileno())
    try:
        try:
            os.link(temporary.name, destination)
        except FileExistsError:
            if read_result(destination) != result:
                raise ValueError("Refusing to overwrite a different result with the same run ID")
    finally:
        Path(temporary.name).unlink()
    return destination


def reporting_link(repository: str, row: dict[str, Any]) -> str:
    """Use the issue form's stable field IDs and encode every prefilled value."""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*", repository):
        raise ValueError("Invalid issue repository")
    query = urlencode(
        {
            "template": "compatibility-report.yml",
            "title": f"[Compatibility] {row['integration']} {row['upstream_version']}",
            "integration": row["integration"],
            "documentdb_version": row["documentdb_version"],
            "upstream_version": row["upstream_version"],
            "environment": row["profile"],
            "dashboard_run": row["run_url"] or "No published run; include your dashboard/run link",
        }
    )
    return f"https://github.com/{repository}/issues/new?{query}"


def dashboard_rows(
    results: list[dict[str, Any]],
    registry: dict[str, Any],
    now: datetime,
    issue_repository: str,
) -> list[dict[str, Any]]:
    """Keep version pairs and demonstrations separate; retain the last conclusive result."""
    groups: dict[tuple, list[dict[str, Any]]] = defaultdict(list)
    for result in results:
        validate_result(result)
        key = (
            result["integration"],
            result["documentdb"]["version"],
            result["upstream"]["version"],
            result["profile"],
            result["demonstration"],
        )
        groups[key].append(result)
    for integration, spec in registry["integrations"].items():
        if spec["enabled"]:
            for version in registry["documentdb"]:
                groups.setdefault(
                    (integration, version, spec["default_version"], spec["profile"], False), []
                )
    rows = []
    for key, history in sorted(groups.items()):
        integration, database_version, upstream_version, profile, demonstration = key
        spec = registry["integrations"].get(integration)
        if spec is None:
            raise ValueError("History references an integration absent from the registry")
        history.sort(
            key=lambda record: (timestamp(record["started_at"]), record["id"]), reverse=True
        )
        latest = history[0] if history else None
        conclusive = [r for r in history if compatibility_state(r) in ("Working", "Failing")]
        current = conclusive[0] if conclusive else None
        successful = [r for r in history if compatibility_state(r) == "Working"]
        state = compatibility_state(current) if current else "Not tested"
        previous_state = state
        active_database = registry["documentdb"].get(database_version)
        if current and (
            now - timestamp(current["finished_at"]) > timedelta(days=spec["freshness_days"])
            or current["suite_digest"] != suite_digest(integration, spec)
            or (active_database and current["documentdb"]["image"] != active_database["image"])
            or (
                latest is not None
                and latest["upstream"]["wheel_sha256"]
                and latest["upstream"]["wheel_sha256"] != current["upstream"]["wheel_sha256"]
            )
        ):
            state = "Stale"
        coverage_source = current or latest
        tests = coverage_source["tests"] if coverage_source else []
        error = None
        if latest:
            error = latest["execution_error"] or next(
                (test["message"] for test in latest["tests"] if test["outcome"] != "passed"), None
            )
        row = {
            "integration": integration,
            "repository": spec["repository"],
            "owner": spec["owner"],
            "documentdb_version": database_version,
            "upstream_version": upstream_version,
            "profile": profile,
            "demonstration": demonstration,
            "state": state,
            "previous_state": previous_state,
            "freshness_days": spec["freshness_days"],
            "conclusive_at": current["finished_at"] if current else None,
            "last_success": successful[0]["finished_at"] if successful else None,
            "last_attempt": latest["finished_at"] if latest else None,
            "latest_attempt_state": compatibility_state(latest) if latest else "Not tested",
            "trigger": latest["trigger"] if latest else None,
            "run_url": latest["run_url"] if latest else None,
            "error": error,
            "passed": sum(test["outcome"] == "passed" for test in tests),
            "expected": len(
                coverage_source["expected_tests"] if coverage_source else spec["expected_tests"]
            ),
            "scenarios": (
                coverage_source["expected_tests"] if coverage_source else spec["expected_tests"]
            ),
            "history": history,
        }
        row["issue_url"] = reporting_link(issue_repository, row)
        rows.append(row)
    return rows


def render(
    store: Path,
    site: Path,
    registry: dict[str, Any],
    *,
    issue_repository: str = "documentdb/documentdb",
    preview: bool = False,
    now: datetime | None = None,
) -> list[dict[str, Any]]:
    """Publish static HTML and JSON from the same validated history."""
    now = now or datetime.now(timezone.utc)
    if store.is_symlink():
        raise ValueError("The result store must not be a symbolic link")
    results = [read_result(path) for path in sorted(store.glob("*.json"))]
    rows = dashboard_rows(results, registry, now, issue_repository)
    if preview:
        for row in rows:
            row["issue_url"] = None
    site.mkdir(parents=True, exist_ok=True)
    environment = Environment(
        loader=FileSystemLoader(ROOT / "compatibility" / "dashboard"),
        autoescape=True,
        undefined=StrictUndefined,
    )
    generated = now.isoformat()
    page = environment.get_template("index.html").render(
        rows=rows, generated_at=generated, preview=preview
    )
    (site / "index.html").write_text(page)
    (site / "freshness.js").write_text(
        (ROOT / "compatibility" / "dashboard" / "freshness.js").read_text()
    )
    (site / "history.json").write_text(json.dumps(results, indent=2, allow_nan=False) + "\n")
    current = [{key: value for key, value in row.items() if key != "history"} for row in rows]
    (site / "current.json").write_text(
        json.dumps({"generated_at": generated, "integrations": current}, indent=2, allow_nan=False)
        + "\n"
    )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", type=Path)
    parser.add_argument("--store", type=Path, required=True)
    parser.add_argument("--site", type=Path)
    parser.add_argument("--issue-repository", default="documentdb/documentdb")
    parser.add_argument("--expected-run-url")
    parser.add_argument(
        "--preview", action="store_true", help="Label a demo site; hide issue links"
    )
    args = parser.parse_args()
    if args.result is None and args.site is None:
        parser.error("Provide a result to append or a site to render")
    registry = read_registry()
    if args.result:
        result = read_result(args.result)
        if args.expected_run_url and result["run_url"] != args.expected_run_url:
            raise ValueError("Result does not belong to the publishing workflow run")
        spec = registry["integrations"][result["integration"]]
        validate_result(result, spec)
        database = registry["documentdb"][result["documentdb"]["version"]]
        if result["documentdb"]["image"] != database["image"]:
            raise ValueError("Incoming result does not reference the reviewed database artifact")
        actual = result["documentdb"]["actual_extension_version"]
        if actual is not None and actual != database["extension_version"]:
            raise ValueError("Incoming result has an unexpected installed extension version")
        if result["suite_digest"] != suite_digest(result["integration"], spec):
            raise ValueError("Incoming result was generated by a different suite revision")
        append_result(args.store, result)
    if args.site:
        render(
            args.store,
            args.site,
            registry,
            issue_repository=args.issue_repository,
            preview=args.preview,
        )
        print(f"Dashboard rendered at {args.site / 'index.html'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
