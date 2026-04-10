#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

HEADER_LINES = [
    "# One pytest node id per line. Blank lines and comments are ignored.",
    "",
    "# Use node IDs relative to the functional-tests pytest rootdir (`documentdb_tests`).",
    "",
]

UNSUPPORTED_FEATURE_HEADER = "# Unsupported feature in documentdb-local today."
KNOWN_PRODUCT_BUG_HEADER = "# Known product bug in documentdb-local today."
NEEDS_TRIAGE_PLACEHOLDER_HEADER = (
    "# Needs triage -- added by update-test-image workflow when a newly pinned image introduces failures."
)
NEEDS_TRIAGE_DATED_HEADER = (
    "# Needs triage -- added by update-test-image workflow on {date}."
)
NEEDS_TRIAGE_NOTE = (
    '# Categorize these as "Unsupported feature" or "Known product bug" before merging.'
)

SECTION_ORDER = (
    "unsupported_feature",
    "known_product_bug",
    "needs_triage",
)

SECTION_HEADERS = {
    "unsupported_feature": UNSUPPORTED_FEATURE_HEADER,
    "known_product_bug": KNOWN_PRODUCT_BUG_HEADER,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Update scripts/functional_tests/deselect.list from a pytest JSON report "
            "while preserving existing categories."
        )
    )
    parser.add_argument(
        "--report",
        required=True,
        type=Path,
        help="Path to functional-report.json produced by the no-deselect full-suite run.",
    )
    parser.add_argument(
        "--deselect-list",
        required=True,
        type=Path,
        help="Path to the current deselect.list file.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Output path for the updated deselect list. Defaults to --deselect-list.",
    )
    parser.add_argument(
        "--summary-json",
        required=True,
        type=Path,
        help="Path to write a JSON summary of new, removed, and retained deselections.",
    )
    parser.add_argument(
        "--date",
        default=datetime.now(timezone.utc).date().isoformat(),
        help="UTC date to stamp onto the Needs triage header (default: today).",
    )
    return parser.parse_args()


def parse_report(path: Path) -> set[str]:
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise SystemExit(f"Missing report file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Could not parse JSON report {path}: {exc}") from exc

    tests = report.get("tests")
    if not isinstance(tests, list):
        raise SystemExit(f"Expected 'tests' list in JSON report: {path}")

    failed = set()
    for test in tests:
        if not isinstance(test, dict):
            continue
        if test.get("outcome") != "failed":
            continue
        nodeid = test.get("nodeid")
        if isinstance(nodeid, str) and nodeid:
            failed.add(nodeid)
    return failed


def parse_deselect_list(path: Path) -> dict[str, list[str]]:
    try:
        contents = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError as exc:
        raise SystemExit(f"Missing deselect list: {path}") from exc

    sections = {section: [] for section in SECTION_ORDER}
    seen_entries: dict[str, str] = {}
    current_section: str | None = None

    for line_number, raw_line in enumerate(contents, start=1):
        line = raw_line.strip()

        if not line:
            continue

        if line.startswith("#"):
            if line == UNSUPPORTED_FEATURE_HEADER:
                current_section = "unsupported_feature"
            elif line == KNOWN_PRODUCT_BUG_HEADER:
                current_section = "known_product_bug"
            elif line.startswith("# Needs triage"):
                current_section = "needs_triage"
            continue

        if current_section is None:
            raise SystemExit(
                f"{path}:{line_number}: deselect entry is missing a category header: {line}"
            )

        previous_section = seen_entries.get(line)
        if previous_section is not None:
            raise SystemExit(
                f"{path}:{line_number}: duplicate deselect entry {line!r} "
                f"already listed under {previous_section}"
            )

        seen_entries[line] = current_section
        sections[current_section].append(line)

    return sections


def render_deselect_list(sections: dict[str, list[str]], date: str) -> str:
    lines = list(HEADER_LINES)

    for section_name in ("unsupported_feature", "known_product_bug"):
        lines.append(SECTION_HEADERS[section_name])
        lines.extend(sections[section_name])
        lines.append("")

    if sections["needs_triage"]:
        lines.append(NEEDS_TRIAGE_DATED_HEADER.format(date=date))
    else:
        lines.append(NEEDS_TRIAGE_PLACEHOLDER_HEADER)
    lines.append(NEEDS_TRIAGE_NOTE)
    lines.extend(sections["needs_triage"])

    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    output_path = args.output or args.deselect_list

    failed_in_report = parse_report(args.report)
    current_sections = parse_deselect_list(args.deselect_list)

    retained_sections = {
        section: [
            nodeid for nodeid in current_sections[section] if nodeid in failed_in_report
        ]
        for section in SECTION_ORDER
    }

    existing_entries = {
        nodeid
        for section in SECTION_ORDER
        for nodeid in current_sections[section]
    }

    removed = [
        nodeid
        for section in SECTION_ORDER
        for nodeid in current_sections[section]
        if nodeid not in failed_in_report
    ]
    unchanged = [
        nodeid
        for section in SECTION_ORDER
        for nodeid in current_sections[section]
        if nodeid in failed_in_report
    ]
    new_failures = sorted(failed_in_report - existing_entries)

    retained_sections["needs_triage"].extend(new_failures)

    output_path.write_text(
        render_deselect_list(retained_sections, args.date),
        encoding="utf-8",
    )

    summary = {
        "date": args.date,
        "counts": {
            "failed_in_report": len(failed_in_report),
            "new_failures": len(new_failures),
            "removed": len(removed),
            "unchanged": len(unchanged),
            "unsupported_feature": len(retained_sections["unsupported_feature"]),
            "known_product_bug": len(retained_sections["known_product_bug"]),
            "needs_triage": len(retained_sections["needs_triage"]),
        },
        "new_failures": new_failures,
        "removed": removed,
        "unchanged": unchanged,
        "sections": retained_sections,
    }
    args.summary_json.write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
