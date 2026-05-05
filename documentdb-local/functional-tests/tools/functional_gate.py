#!/usr/bin/env python3
"""
DocumentDB Functional Test Gate Tooling.

Provides config validation, PR gate result summarization, and daily delta
reporting for the allowlist PR gate framework (RFC-0007).
"""

import argparse
import json
import os
import sys

import yaml


# ---------------------------------------------------------------------------
# Config loading and validation
# ---------------------------------------------------------------------------

class ConfigError:
    """Represents a single config validation error."""

    def __init__(self, subtype: str, message: str):
        self.subtype = subtype
        self.message = message

    def __repr__(self):
        return f"ConfigError({self.subtype}: {self.message})"


def load_yaml(path: str) -> dict:
    with open(path) as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        raise ValueError(f"Expected YAML mapping, got {type(data).__name__}")
    return data


def validate_image_config(path: str) -> list[ConfigError]:
    """Validate image.yml and return a list of errors (empty = valid)."""
    errors = []
    try:
        data = load_yaml(path)
    except Exception as e:
        errors.append(ConfigError("INVALID_SCHEMA", f"Cannot parse {path}: {e}"))
        return errors

    for field in ("image", "source_ref", "source_sha"):
        if field not in data:
            errors.append(ConfigError("INVALID_SCHEMA", f"Missing required field '{field}' in {path}"))

    image = data.get("image", "")
    if image and "@sha256:" not in image:
        errors.append(ConfigError("INVALID_SCHEMA", f"Image must use a pinned sha256 digest, got: {image}"))

    return errors


def validate_allowlist_config(path: str) -> list[ConfigError]:
    """Validate allowlist.yml and return a list of errors (empty = valid)."""
    errors = []
    try:
        data = load_yaml(path)
    except Exception as e:
        errors.append(ConfigError("INVALID_SCHEMA", f"Cannot parse {path}: {e}"))
        return errors

    schema_version = data.get("schema_version")
    if schema_version != 1:
        errors.append(ConfigError("INVALID_SCHEMA",
                                  f"Unsupported schema_version: {schema_version} (expected 1)"))
        return errors

    tests = data.get("tests")
    if tests is None:
        errors.append(ConfigError("INVALID_SCHEMA", "Missing required field 'tests'"))
        return errors

    if not isinstance(tests, list):
        errors.append(ConfigError("INVALID_SCHEMA",
                                  f"'tests' must be a list, got {type(tests).__name__}"))
        return errors

    seen = set()
    for entry in tests:
        if not isinstance(entry, str):
            errors.append(ConfigError("INVALID_SCHEMA",
                                      f"Test ID must be a string, got {type(entry).__name__}: {entry}"))
            continue
        if entry in seen:
            errors.append(ConfigError("DUPLICATE_TEST_ID", f"Duplicate test ID: {entry}"))
        seen.add(entry)

    return errors


def validate_config(image_path: str, allowlist_path: str) -> list[ConfigError]:
    """Validate both config files and return combined errors."""
    errors = []
    errors.extend(validate_image_config(image_path))
    errors.extend(validate_allowlist_config(allowlist_path))
    return errors


# ---------------------------------------------------------------------------
# Gate result summarization
# ---------------------------------------------------------------------------

class GateResult:
    """Represents a PR gate result."""

    def __init__(self):
        self.outcome = "PASS"
        self.selected = 0
        self.passed = 0
        self.failed = 0
        self.missing = 0
        self.non_pass = 0
        self.total_discovered = 0
        self.outside_allowlist = 0
        self.image = ""
        self.errors: list[dict] = []
        self.failed_tests: list[dict] = []

    def to_dict(self) -> dict:
        return {
            "outcome": self.outcome,
            "selected": self.selected,
            "passed": self.passed,
            "failed": self.failed,
            "missing": self.missing,
            "non_pass": self.non_pass,
            "total_discovered": self.total_discovered,
            "outside_allowlist": self.outside_allowlist,
            "image": self.image,
            "errors": self.errors,
            "failed_tests": self.failed_tests,
        }


def summarize_gate(allowlist_path: str, report_path: str, image_path: str = "") -> GateResult:
    """Analyze pytest JSON report against the allowlist and produce a gate result."""
    result = GateResult()

    # Load image info
    if image_path and os.path.exists(image_path):
        image_data = load_yaml(image_path)
        result.image = image_data.get("image", "")

    # Load allowlist
    al_data = load_yaml(allowlist_path)
    allowed_ids = set(al_data.get("tests", []))
    result.selected = len(allowed_ids)

    # Load pytest JSON report
    with open(report_path) as f:
        report = json.load(f)

    tests_in_report = report.get("tests", [])
    summary = report.get("summary", {})
    # summary.collected includes all tests pytest discovered before deselection
    result.total_discovered = summary.get("collected", 0)
    if result.total_discovered == 0:
        # Fallback: total + deselected, or just total
        result.total_discovered = summary.get("total", 0) + summary.get("deselected", 0)

    # Build outcome map from report
    outcome_map: dict[str, dict] = {}
    for test in tests_in_report:
        nodeid = test.get("nodeid", "")
        outcome = test.get("outcome", "unknown")
        outcome_map[nodeid] = {"outcome": outcome, "test": test}

    # Check every allowlisted test
    for test_id in sorted(allowed_ids):
        if test_id not in outcome_map:
            result.missing += 1
            result.errors.append({
                "subtype": "UNKNOWN_TEST_ID",
                "test_id": test_id,
                "message": f"Allowlisted test not found in report: {test_id}",
            })
            continue

        entry = outcome_map[test_id]
        outcome = entry["outcome"]

        if outcome == "passed":
            result.passed += 1
        elif outcome == "failed":
            result.failed += 1
            result.failed_tests.append({
                "test_id": test_id,
                "outcome": outcome,
                "short_name": test_id.rsplit("/", 1)[-1] if "/" in test_id else test_id,
            })
        elif outcome == "xfail":
            result.non_pass += 1
            result.errors.append({
                "subtype": "NON_PASS_OUTCOME",
                "test_id": test_id,
                "outcome": outcome,
                "message": f"Allowlisted test has non-pass outcome: {outcome}",
            })
        elif outcome == "xpass":
            result.non_pass += 1
            result.errors.append({
                "subtype": "ALLOWLISTED_XPASS",
                "test_id": test_id,
                "outcome": outcome,
                "message": "Test was expected to fail but passed (XPASS under strict xfail)",
            })
        elif outcome == "skipped":
            result.non_pass += 1
            result.errors.append({
                "subtype": "NON_PASS_OUTCOME",
                "test_id": test_id,
                "outcome": outcome,
                "message": f"Allowlisted test was skipped",
            })
        elif outcome == "error":
            result.non_pass += 1
            result.errors.append({
                "subtype": "NON_PASS_OUTCOME",
                "test_id": test_id,
                "outcome": outcome,
                "message": f"Allowlisted test had an error",
            })
        else:
            result.non_pass += 1
            result.errors.append({
                "subtype": "NON_PASS_OUTCOME",
                "test_id": test_id,
                "outcome": outcome,
                "message": f"Allowlisted test has unexpected outcome: {outcome}",
            })

    result.outside_allowlist = max(0, result.total_discovered - result.selected)

    # Determine gate outcome
    if result.missing > 0:
        result.outcome = "ALLOWLIST_ERROR"
    elif result.failed > 0:
        result.outcome = "ALLOWED_TEST_FAILED"
    elif result.non_pass > 0:
        result.outcome = "ALLOWLIST_ERROR"
    else:
        result.outcome = "PASS"

    return result


def render_gate_markdown(result: GateResult) -> str:
    """Render a Markdown summary for the PR gate."""
    lines = []
    if result.outcome == "PASS":
        lines.append("## Functional gate: PASS")
    else:
        lines.append(f"## Functional gate: FAIL ({result.outcome})")

    lines.append("")
    if result.image:
        lines.append(f"**Image:** `{result.image}`")
        lines.append("")

    lines.append("**Allowlist:**")
    lines.append(f"- selected: {result.selected}")
    lines.append(f"- passed: {result.passed}")
    lines.append(f"- failed: {result.failed}")
    lines.append(f"- missing: {result.missing}")
    lines.append(f"- non-pass: {result.non_pass}")
    lines.append("")

    lines.append("**Coverage boundary:**")
    lines.append(f"- upstream tests discovered in pinned image: {result.total_discovered}")
    lines.append(f"- outside allowlist and not run in PR gate: {result.outside_allowlist}")
    lines.append("")

    if result.outcome != "PASS":
        lines.append("**What this means:**")
        lines.append("- Every allowlisted test must be collected, executed, and pass.")
        lines.append("- A failed, skipped, xfail/xpass, errored, or missing allowlisted test is a gate failure.")
        lines.append("- Start with the repro command below, then inspect `report.json`, `results.xml`, and `documentdb.log` in the uploaded artifact or local results directory.")
        lines.append("")

    if result.failed_tests:
        lines.append("**Failed tests:**")
        for ft in result.failed_tests:
            lines.append(f"- `{ft['test_id']}`")
        lines.append("")

    if result.errors:
        lines.append("**Errors:**")
        for err in result.errors[:10]:
            lines.append(f"- [{err['subtype']}] {err['message']}")
        if len(result.errors) > 10:
            lines.append(f"- ... and {len(result.errors) - 10} more")
        lines.append("")

    if result.outcome != "PASS":
        lines.append("**Reproduce:**")
        lines.append(f"```")
        if result.failed_tests:
            first_failed = result.failed_tests[0]["test_id"]
            lines.append(f"./documentdb-local/functional-tests/scripts/run-functional-tests.sh single {first_failed}")
        else:
            lines.append("./documentdb-local/functional-tests/scripts/run-functional-tests.sh allowlist")
        lines.append(f"```")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Daily delta summarization
# ---------------------------------------------------------------------------

def summarize_daily(allowlist_path: str, report_path: str, image_path: str = "") -> dict:
    """Analyze a full-suite pytest JSON report against the allowlist for daily delta."""
    al_data = load_yaml(allowlist_path)
    allowed_ids = set(al_data.get("tests", []))

    with open(report_path) as f:
        report = json.load(f)

    image = ""
    if image_path and os.path.exists(image_path):
        image_data = load_yaml(image_path)
        image = image_data.get("image", "")

    tests_in_report = report.get("tests", [])

    allowlisted_passed = []
    allowlisted_failed = []
    outside_passed = []
    outside_not_passing = []

    for test in tests_in_report:
        nodeid = test.get("nodeid", "")
        outcome = test.get("outcome", "unknown")

        if nodeid in allowed_ids:
            if outcome == "passed":
                allowlisted_passed.append(nodeid)
            else:
                allowlisted_failed.append({"test_id": nodeid, "outcome": outcome})
        else:
            if outcome == "passed":
                outside_passed.append(nodeid)
            else:
                outside_not_passing.append(nodeid)

    # Check for allowlisted tests missing from report entirely
    reported_ids = {t.get("nodeid", "") for t in tests_in_report}
    missing_from_report = sorted(allowed_ids - reported_ids)

    # Derive areas for promotion candidates
    area_counts: dict[str, int] = {}
    for nodeid in outside_passed:
        area = derive_area(nodeid)
        area_counts[area] = area_counts.get(area, 0) + 1

    # Generate promotion YAML snippet
    promotion_snippet_lines = [
        "# Promotion candidates from one daily run; rerun/bootstrap before promoting.",
        "tests:",
    ]
    for nodeid in sorted(outside_passed):
        promotion_snippet_lines.append(f"  - {nodeid}")

    result = {
        "image": image,
        "allowlist_total": len(allowed_ids),
        "allowlisted_passed": len(allowlisted_passed),
        "allowlisted_failed": allowlisted_failed,
        "allowlisted_missing": missing_from_report,
        "outside_passed": len(outside_passed),
        "outside_not_passing": len(outside_not_passing),
        "promotion_areas": area_counts,
        "promotion_snippet": "\n".join(promotion_snippet_lines) if outside_passed else "",
    }
    return result


def render_daily_markdown(delta: dict) -> str:
    """Render a Markdown summary for the daily delta report."""
    lines = []
    lines.append("## Daily functional-test delta")
    lines.append("")
    if delta.get("image"):
        lines.append(f"**Image:** `{delta['image']}`")
        lines.append("")

    lines.append("**Required allowlist:**")
    lines.append(f"- total: {delta['allowlist_total']}")
    lines.append(f"- passed: {delta['allowlisted_passed']}")
    lines.append(f"- failed/non-pass: {len(delta['allowlisted_failed'])}")
    if delta["allowlisted_missing"]:
        lines.append(f"- missing from report: {len(delta['allowlisted_missing'])}")
    lines.append("")

    lines.append("**Outside allowlist:**")
    lines.append(f"- passed: {delta['outside_passed']}")
    lines.append(f"- not passing: {delta['outside_not_passing']}")
    lines.append("")

    if delta.get("promotion_areas"):
        lines.append("**Manual promotion candidates by area:**")
        lines.append("")
        lines.append(
            "These are single-run candidates from the scheduled daily job. "
            "Re-run or use `bootstrap --runs <n>` before promoting them into `allowlist.yml`."
        )
        lines.append("")
        for area, count in sorted(delta["promotion_areas"].items()):
            lines.append(f"- {area}: {count}")
        lines.append("")

    if delta.get("allowlisted_failed"):
        lines.append("**Allowlisted tests that failed:**")
        for entry in delta["allowlisted_failed"][:20]:
            lines.append(f"- `{entry['test_id']}` ({entry['outcome']})")
        if len(delta["allowlisted_failed"]) > 20:
            lines.append(f"- ... and {len(delta['allowlisted_failed']) - 20} more")
        lines.append("")

    if delta.get("allowlisted_missing"):
        lines.append("**Allowlisted tests missing from the report:**")
        for test_id in delta["allowlisted_missing"][:20]:
            lines.append(f"- `{test_id}`")
        if len(delta["allowlisted_missing"]) > 20:
            lines.append(f"- ... and {len(delta['allowlisted_missing']) - 20} more")
        lines.append("")

    if delta.get("allowlisted_failed") or delta.get("allowlisted_missing"):
        lines.append("**Debug next:**")
        lines.append("- Missing or non-passing allowlisted tests violate the Phase 1 support-boundary contract.")
        lines.append("- Inspect `daily-summary.json`, `report.json`, `results.xml`, and `documentdb.log` in the daily artifact.")
        lines.append("- Reproduce locally with `./documentdb-local/functional-tests/scripts/run-functional-tests.sh allowlist` or run a single failed node ID.")
        lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Area derivation
# ---------------------------------------------------------------------------

AREA_PATTERNS = [
    ("commands/find/", "find"),
    ("commands/insert/", "insert"),
    ("commands/update/", "update"),
    ("commands/delete/", "delete"),
    ("operator/expressions/", "expressions"),
    ("operator/query/", "query"),
    ("operator/stages/", "aggregate"),
    ("operator/accumulators/", "aggregate"),
    ("operator/window/", "aggregate"),
    ("operator/projection/", "projection"),
    ("operator/system-stages/", "aggregate"),
    ("operator/aggregation/", "aggregate"),
    ("operator/", "operator"),
    ("aggregate/", "aggregate"),
    ("collections/", "collection_mgmt"),
    ("sessions/", "sessions"),
    ("indexes/", "index"),
    ("administration/", "admin"),
    ("diagnostic/", "diagnostic"),
    ("security/", "security"),
    ("transactions/", "transactions"),
    ("geospatial/", "geospatial"),
    ("text_search/", "text_search"),
    ("validation/", "validation"),
    ("bson_types/", "bson_types"),
    ("data-types/", "data_types"),
    ("changeStreams/", "change_streams"),
    ("cursors/", "cursors"),
    ("collation/", "collation"),
    ("query-planning/", "query_planning"),
    ("query-and-write/", "query_and_write"),
    ("auditing/", "auditing"),
]


def derive_area(nodeid: str) -> str:
    """Derive a reporting area from a pytest node ID path."""
    for pattern, area in AREA_PATTERNS:
        if pattern in nodeid:
            return area
    return "unknown"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_validate_config(args):
    errors = validate_config(args.image, args.allowlist)
    if errors:
        print("Functional test config validation failed:\n")
        for err in errors:
            print(f"  [{err.subtype}] {err.message}")
        return 1
    print("Functional test config validation passed.")
    return 0


def cmd_summarize_gate(args):
    result = summarize_gate(args.allowlist, args.report, args.image)
    md = render_gate_markdown(result)

    # Write summary to stdout
    print(md)

    # Write artifacts
    if args.output_dir:
        os.makedirs(args.output_dir, exist_ok=True)
        with open(os.path.join(args.output_dir, "gate-summary.md"), "w") as f:
            f.write(md)
        with open(os.path.join(args.output_dir, "gate-summary.json"), "w") as f:
            json.dump(result.to_dict(), f, indent=2)

    # Write to GITHUB_STEP_SUMMARY if available
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        with open(summary_file, "a") as f:
            f.write(md + "\n")

    return 0 if result.outcome == "PASS" else 1


def cmd_summarize_daily(args):
    delta = summarize_daily(args.allowlist, args.report, args.image)
    md = render_daily_markdown(delta)

    print(md)

    if args.output_dir:
        os.makedirs(args.output_dir, exist_ok=True)
        with open(os.path.join(args.output_dir, "daily-summary.md"), "w") as f:
            f.write(md)
        with open(os.path.join(args.output_dir, "daily-summary.json"), "w") as f:
            json.dump(delta, f, indent=2)
        if delta.get("promotion_snippet"):
            with open(os.path.join(args.output_dir, "promotion-candidates.yml"), "w") as f:
                f.write(delta["promotion_snippet"] + "\n")

    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        with open(summary_file, "a") as f:
            f.write(md + "\n")

    has_allowlisted_contract_violations = (
        len(delta.get("allowlisted_failed", [])) > 0
        or len(delta.get("allowlisted_missing", [])) > 0
    )
    return 1 if has_allowlisted_contract_violations else 0


def main():
    parser = argparse.ArgumentParser(
        description="DocumentDB Functional Test Gate Tooling (RFC-0007)")
    parser.add_argument("--image", default="documentdb-local/functional-tests/config/image.yml",
                        help="Path to image.yml")
    parser.add_argument("--allowlist", default="documentdb-local/functional-tests/config/allowlist.yml",
                        help="Path to allowlist.yml")

    subparsers = parser.add_subparsers(dest="command", required=True)

    # validate-config
    subparsers.add_parser("validate-config", help="Validate image.yml and allowlist.yml")

    # summarize-gate
    gate_parser = subparsers.add_parser("summarize-gate", help="Summarize PR gate results")
    gate_parser.add_argument("--report", required=True, help="Path to pytest JSON report")
    gate_parser.add_argument("--output-dir", default="", help="Directory for output artifacts")

    # summarize-daily
    daily_parser = subparsers.add_parser("summarize-daily", help="Summarize daily delta")
    daily_parser.add_argument("--report", required=True, help="Path to pytest JSON report")
    daily_parser.add_argument("--output-dir", default="", help="Directory for output artifacts")

    args = parser.parse_args()

    if args.command == "validate-config":
        return cmd_validate_config(args)
    elif args.command == "summarize-gate":
        return cmd_summarize_gate(args)
    elif args.command == "summarize-daily":
        return cmd_summarize_daily(args)


if __name__ == "__main__":
    sys.exit(main())
