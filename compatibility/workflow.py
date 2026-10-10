# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Select registry-backed jobs and combine their evidence without fabricating missing runs."""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
from pathlib import Path
from typing import Any

from compatibility.contracts import read_registry
from compatibility.publish import (
    RunKey,
    append_result,
    read_result,
    render,
    result_key,
    validate_incoming_result,
)


def select_runs(
    registry: dict[str, Any],
    integration: str,
    version: str | None,
    documentdb_version: str,
    demonstration: bool = False,
) -> list[dict[str, Any]]:
    """Resolve each enabled integration's own default before expanding the matrix."""
    if documentdb_version not in registry["documentdb"]:
        raise ValueError("Unknown DocumentDB release")
    if integration == "all":
        if version:
            raise ValueError("A version override requires a single integration, not all")
        names = [name for name, spec in registry["integrations"].items() if spec["enabled"]]
    else:
        spec = registry["integrations"].get(integration)
        if spec is None or not spec["enabled"]:
            raise ValueError("Unknown or disabled integration")
        names = [integration]
    if not names:
        raise ValueError("No enabled integrations were selected")
    runs = []
    for name in sorted(names):
        spec = registry["integrations"][name]
        selected = version or spec["default_version"]
        if len(selected) > 40 or not re.fullmatch(spec["version_pattern"], selected):
            raise ValueError(f"Requested version is outside the policy for {name}")
        runs.append(
            {
                "integration": name,
                "version": selected,
                "documentdb_version": documentdb_version,
                "demonstration": demonstration,
            }
        )
    return runs


def markdown_cell(value: str) -> str:
    """Keep diagnostics as table text rather than executable HTML or Markdown."""
    escaped = html.escape(value).replace("\r", " ").replace("\n", " ")
    return re.sub(r"([\\`*_{}\[\]()|])", r"\\\1", escaped)


def collect_report(
    incoming: Path,
    output: Path,
    registry: dict[str, Any],
    runs: list[dict[str, Any]],
    *,
    expected_run_url: str | None = None,
    summary: Path | None = None,
) -> bool:
    """Retain valid envelopes and expose rejected or absent evidence for every selected job."""
    if output.exists() or output.is_symlink():
        raise ValueError("Refusing to overwrite an existing combined report")
    if incoming.is_symlink():
        raise ValueError("The incoming artifact directory must not be a symbolic link")
    store = output / "results"
    expected: dict[RunKey, str | None] = {}
    errors = []
    selected = {run["integration"] for run in runs}
    if incoming.exists() and any(path.name not in selected for path in incoming.iterdir()):
        errors.append("Unexpected files or integrations were found in the downloaded artifacts")
    output.mkdir(parents=True)
    for run in runs:
        integration = run["integration"]
        spec = registry["integrations"][integration]
        key = (
            integration,
            run["documentdb_version"],
            run["version"],
            spec["profile"],
            run["demonstration"],
        )
        expected[key] = None
        directory = incoming / integration
        path = directory / "result.json"
        try:
            if directory.is_symlink():
                raise ValueError("Integration artifacts must not use a directory symbolic link")
            if not path.exists() and not path.is_symlink():
                raise ValueError("Missing result artifact for this integration and attempt")
            result = read_result(path)
            if result_key(result) != key or result["trigger"] != "manual":
                raise ValueError("Result does not match the selected integration run")
            validate_incoming_result(result, registry, expected_run_url)
            append_result(store, result)
        except (OSError, ValueError, KeyError) as error:
            expected[key] = f"Result unavailable: {error}"
    rows = render(store, output / "site", registry, preview=True, expected_runs=expected)
    success = not errors and all(row["state"] == "Working" for row in rows)
    report = {
        "schema_version": 1,
        "success": success,
        "errors": errors,
        "integrations": [
            {key: value for key, value in row.items() if key != "history"} for row in rows
        ],
    }
    (output / "summary.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    lines = [
        "## Ecosystem compatibility",
        "",
        (
            "All selected profiles passed."
            if success
            else "One or more profiles or artifacts need attention."
        ),
        "",
        "| Integration | DocumentDB | Upstream | Profile | Mode | Result | Passed | Diagnostic |",
        "| --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for row in rows:
        cells = [
            row["integration"],
            row["documentdb_version"],
            row["upstream_version"],
            row["profile"],
            "Demonstration" if row["demonstration"] else "Compatibility",
            row["state"],
            f"{row['passed']}/{row['expected']}",
            row["error"] or "",
        ]
        lines.append("| " + " | ".join(markdown_cell(cell) for cell in cells) + " |")
    if errors:
        lines.extend(["", "### Reporting errors", ""])
        lines.extend(f"- {markdown_cell(error)}" for error in errors)
    contents = "\n".join(lines) + "\n"
    (output / "summary.md").write_text(contents)
    if summary is not None:
        with summary.open("a") as file:
            file.write(contents)
    return success


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("matrix", "report"):
        command = commands.add_parser(name)
        command.add_argument("--integration", default="all")
        command.add_argument("--version")
        command.add_argument("--documentdb-version", default="0.117.0")
        command.add_argument("--demonstration", action="store_true")
        if name == "report":
            command.add_argument("--input", type=Path, required=True)
            command.add_argument("--output", type=Path, required=True)
            command.add_argument("--expected-run-url")
            command.add_argument("--summary", type=Path)
    args = parser.parse_args()
    try:
        registry = read_registry()
        runs = select_runs(
            registry, args.integration, args.version, args.documentdb_version, args.demonstration
        )
        if args.command == "matrix":
            print(json.dumps({"include": runs}, separators=(",", ":")))
            return 0
        success = collect_report(
            args.input,
            args.output,
            registry,
            runs,
            expected_run_url=args.expected_run_url,
            summary=args.summary,
        )
    except (OSError, ValueError) as error:
        print(f"Invalid compatibility workflow request: {error}", file=sys.stderr)
        return 2
    print(f"Combined report: {args.output / 'summary.md'}")
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
