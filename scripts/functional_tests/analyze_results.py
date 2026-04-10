#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from update_deselect import parse_deselect_list


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Analyze functional test results for workflow summaries and daily-baseline "
            "comparison."
        )
    )
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--deselect-list", required=True, type=Path)
    parser.add_argument("--analysis-json", required=True, type=Path)
    parser.add_argument("--summary-markdown", required=True, type=Path)
    parser.add_argument("--scope", required=True)
    parser.add_argument(
        "--deselect-mode",
        required=True,
        choices=("applied", "excluded"),
        help="'applied' for PR/main runs, 'excluded' for the daily all-tests run.",
    )
    parser.add_argument("--documentdb-image", required=True)
    parser.add_argument("--test-image", required=True)
    parser.add_argument("--run-url")
    parser.add_argument("--baseline-input", type=Path)
    parser.add_argument("--baseline-output", type=Path)
    return parser.parse_args()


def parse_report(path: Path) -> tuple[dict[str, int], list[str]]:
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise SystemExit(f"Missing report file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Could not parse JSON report {path}: {exc}") from exc

    summary = report.get("summary", {})
    passed = int(summary.get("passed", 0))
    failed = int(summary.get("failed", 0))
    skipped = int(summary.get("skipped", 0))

    failed_tests: list[str] = []
    seen = set()
    for test in report.get("tests", []):
        if not isinstance(test, dict):
            continue
        if test.get("outcome") != "failed":
            continue
        nodeid = test.get("nodeid")
        if isinstance(nodeid, str) and nodeid and nodeid not in seen:
            seen.add(nodeid)
            failed_tests.append(nodeid)

    return (
        {
            "passed": passed,
            "failed": failed,
            "skipped": skipped,
            "total": passed + failed + skipped,
        },
        failed_tests,
    )


def load_baseline(path: Path | None) -> dict | None:
    if path is None:
        return None

    try:
        baseline = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Could not parse baseline JSON {path}: {exc}") from exc

    if not isinstance(baseline.get("failed_tests"), list):
        raise SystemExit(f"Baseline JSON missing failed_tests list: {path}")
    return baseline


def render_failed_tests(title: str, tests: list[str], empty_message: str) -> list[str]:
    lines = ["", f"### {title}"]
    if not tests:
        lines.append(empty_message)
        return lines

    for name in tests[:20]:
        lines.append(f"- `{name}`")
    if len(tests) > 20:
        lines.append(f"- ... and {len(tests) - 20} more")
    return lines


def render_summary_markdown(analysis: dict) -> str:
    lines = [
        "## Functional Tests",
        "",
        f"Scope: `{analysis['scope']}`",
        (
            "Deselect list: `excluded (running all tests)`"
            if analysis["deselect_mode"] == "excluded"
            else "Deselect list: `applied`"
        ),
        f"System under test: `{analysis['documentdb_image']}`",
        f"Test image: `{analysis['test_image']}`",
        "",
        "| Total | Passed | Failed | Skipped |",
        "| --- | --- | --- | --- |",
        (
            f"| {analysis['counts']['total']} | {analysis['counts']['passed']} | "
            f"{analysis['counts']['failed']} | {analysis['counts']['skipped']} |"
        ),
    ]

    lines.extend(
        render_failed_tests(
            "Failed tests",
            analysis["failed_tests"],
            "No failed tests were reported.",
        )
    )

    if analysis["deselect_mode"] == "excluded":
        category_counts = analysis["categories"]
        lines.extend(
            [
                "",
                "### Daily failure categories",
                "",
                "| Unsupported feature | Known product bug | Needs triage | New failures |",
                "| --- | --- | --- | --- |",
                (
                    f"| {len(category_counts['unsupported_feature'])} | "
                    f"{len(category_counts['known_product_bug'])} | "
                    f"{len(category_counts['needs_triage'])} | "
                    f"{len(category_counts['new_failures'])} |"
                ),
                "",
                "This daily run excludes `deselect.list` on purpose so maintainers can see the"
                " full failure picture on `main`.",
            ]
        )
        lines.extend(
            render_failed_tests(
                "New failures not in deselect.list",
                category_counts["new_failures"],
                "No new failures were found outside deselect.list.",
            )
        )
    else:
        comparison = analysis["comparison"]
        lines.extend(["", "### Daily baseline comparison"])
        if not comparison["baseline_available"]:
            lines.append("No daily baseline artifact was available for comparison.")
        else:
            if comparison["baseline_run_url"]:
                lines.append(
                    f"Latest daily baseline: {comparison['baseline_run_url']}"
                )
            lines.extend(
                [
                    "",
                    "| Potential regressions | Also in latest daily baseline |",
                    "| --- | --- |",
                    (
                        f"| {len(comparison['potential_regressions'])} | "
                        f"{len(comparison['also_in_daily_baseline'])} |"
                    ),
                ]
            )
            lines.extend(
                render_failed_tests(
                    "Potential regressions",
                    comparison["potential_regressions"],
                    "No failures were unique to this run.",
                )
            )
            lines.extend(
                render_failed_tests(
                    "Also failing in latest daily baseline",
                    comparison["also_in_daily_baseline"],
                    "No failures overlapped with the latest daily baseline.",
                )
            )

    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()

    counts, failed_tests = parse_report(args.report)
    sections = parse_deselect_list(args.deselect_list)
    deselected = {
        nodeid for values in sections.values() for nodeid in values
    }

    categories = {
        "unsupported_feature": [
            nodeid for nodeid in failed_tests if nodeid in set(sections["unsupported_feature"])
        ],
        "known_product_bug": [
            nodeid for nodeid in failed_tests if nodeid in set(sections["known_product_bug"])
        ],
        "needs_triage": [
            nodeid for nodeid in failed_tests if nodeid in set(sections["needs_triage"])
        ],
        "new_failures": [
            nodeid for nodeid in failed_tests if nodeid not in deselected
        ],
    }

    baseline = load_baseline(args.baseline_input)
    if baseline is None:
        comparison = {
            "baseline_available": False,
            "baseline_run_url": None,
            "also_in_daily_baseline": [],
            "potential_regressions": [],
        }
    else:
        baseline_failed = set(
            nodeid
            for nodeid in baseline.get("failed_tests", [])
            if isinstance(nodeid, str) and nodeid
        )
        comparison = {
            "baseline_available": True,
            "baseline_run_url": baseline.get("run_url"),
            "also_in_daily_baseline": [
                nodeid for nodeid in failed_tests if nodeid in baseline_failed
            ],
            "potential_regressions": [
                nodeid for nodeid in failed_tests if nodeid not in baseline_failed
            ],
        }

    analysis = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "scope": args.scope,
        "deselect_mode": args.deselect_mode,
        "documentdb_image": args.documentdb_image,
        "test_image": args.test_image,
        "run_url": args.run_url,
        "counts": counts,
        "failed_tests": failed_tests,
        "categories": categories,
        "comparison": comparison,
    }

    args.analysis_json.write_text(
        json.dumps(analysis, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    args.summary_markdown.write_text(
        render_summary_markdown(analysis),
        encoding="utf-8",
    )

    if args.baseline_output is not None:
        baseline_payload = {
            "generated_at_utc": analysis["generated_at_utc"],
            "run_url": args.run_url,
            "test_image": args.test_image,
            "failed_tests": failed_tests,
        }
        args.baseline_output.write_text(
            json.dumps(baseline_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
