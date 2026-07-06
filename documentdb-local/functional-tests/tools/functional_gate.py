#!/usr/bin/env python3
"""
DocumentDB Functional Test Gate Tooling.

Provides config validation, PR gate result summarization, and daily delta
reporting for the allowlist PR gate framework (RFC-0007).
"""

from __future__ import annotations

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


SUPPORTED_ALLOWLIST_SCHEMA_VERSIONS = (1, 2)
_ALLOWED_ENTRY_KEYS = {"id", "engines"}


def parse_allowlist_entries(data: dict) -> tuple[list[tuple[str, frozenset[str] | None]], list[ConfigError]]:
    """Parse an allowlist mapping and return (entries, errors).

    Each entry is normalized to ``(test_id, engines_or_None)`` where ``None``
    means "applies to all engines". Schema v1 produces only ``(id, None)``
    tuples. Schema v2 supports both bare strings (= all engines) and
    ``{id, engines: [...]}`` dicts.
    """
    errors: list[ConfigError] = []
    entries: list[tuple[str, frozenset[str] | None]] = []

    if not isinstance(data, dict):
        errors.append(ConfigError(
            "INVALID_SCHEMA",
            f"Allowlist must be a YAML mapping, got {type(data).__name__}"))
        return entries, errors

    schema_version = data.get("schema_version")
    if schema_version not in SUPPORTED_ALLOWLIST_SCHEMA_VERSIONS:
        supported = ", ".join(str(v) for v in SUPPORTED_ALLOWLIST_SCHEMA_VERSIONS)
        errors.append(ConfigError(
            "INVALID_SCHEMA",
            f"Unsupported schema_version: {schema_version} (expected one of: {supported})"))
        return entries, errors

    tests = data.get("tests")
    if tests is None:
        errors.append(ConfigError("INVALID_SCHEMA", "Missing required field 'tests'"))
        return entries, errors

    if not isinstance(tests, list):
        errors.append(ConfigError("INVALID_SCHEMA",
                                  f"'tests' must be a list, got {type(tests).__name__}"))
        return entries, errors

    seen_ids: set[str] = set()
    for entry in tests:
        if isinstance(entry, str):
            test_id = entry
            engines: frozenset[str] | None = None
        elif isinstance(entry, dict):
            if schema_version < 2:
                errors.append(ConfigError(
                    "INVALID_SCHEMA",
                    f"Dict entries require schema_version >= 2, got: {entry}"))
                continue

            unknown_keys = set(entry.keys()) - _ALLOWED_ENTRY_KEYS
            if unknown_keys:
                errors.append(ConfigError(
                    "INVALID_SCHEMA",
                    f"Unknown keys in entry {entry}: {sorted(unknown_keys)} "
                    f"(allowed: {sorted(_ALLOWED_ENTRY_KEYS)})"))
                continue

            test_id = entry.get("id")
            if not isinstance(test_id, str) or not test_id:
                errors.append(ConfigError(
                    "INVALID_SCHEMA",
                    f"Entry 'id' must be a non-empty string, got: {entry}"))
                continue

            if "engines" in entry:
                engines_raw = entry["engines"]
                if not isinstance(engines_raw, list):
                    errors.append(ConfigError(
                        "INVALID_SCHEMA",
                        f"Entry 'engines' must be a list, got {type(engines_raw).__name__} for {test_id}"))
                    continue
                if len(engines_raw) == 0:
                    errors.append(ConfigError(
                        "INVALID_SCHEMA",
                        f"Entry 'engines' must be a non-empty list for {test_id} "
                        f"(omit the field to apply to all engines)"))
                    continue
                bad_engines = [e for e in engines_raw if not isinstance(e, str) or not e]
                if bad_engines:
                    errors.append(ConfigError(
                        "INVALID_SCHEMA",
                        f"Entry 'engines' for {test_id} must contain non-empty strings, got: {bad_engines}"))
                    continue
                engines = frozenset(engines_raw)
            else:
                engines = None
        else:
            errors.append(ConfigError(
                "INVALID_SCHEMA",
                f"Test entry must be a string or mapping, got {type(entry).__name__}: {entry}"))
            continue

        if test_id in seen_ids:
            errors.append(ConfigError("DUPLICATE_TEST_ID", f"Duplicate test ID: {test_id}"))
            continue
        seen_ids.add(test_id)
        entries.append((test_id, engines))

    return entries, errors


def load_allowlist_entries(path: str) -> list[tuple[str, frozenset[str] | None]]:
    """Load and parse an allowlist file. Raises ValueError on any schema error."""
    data = load_yaml(path)
    entries, errors = parse_allowlist_entries(data)
    if errors:
        joined = "; ".join(f"[{e.subtype}] {e.message}" for e in errors)
        raise ValueError(f"Invalid allowlist {path}: {joined}")
    return entries


def load_allowlist_ids(path: str, engine_name: str) -> set[str]:
    """Return the set of allowlisted test IDs that apply to ``engine_name``.

    An entry with ``engines = None`` (bare string in v1/v2, or v2 dict with no
    ``engines`` field) applies to every engine. An entry with an explicit
    ``engines`` list is in-scope only when ``engine_name`` is in that list.
    """
    in_scope: set[str] = set()
    for test_id, engines in load_allowlist_entries(path):
        if engines is None or engine_name in engines:
            in_scope.add(test_id)
    return in_scope


def shard_allowlist_ids(allowlist_path: str, engine_name: str,
                        num_shards: int, shard_id: int, prefix: str = "") -> list[str]:
    """Return the allowlisted test IDs assigned to one shard.

    IDs are sorted for determinism, then distributed round-robin (stride
    slicing ``ids[shard_id::num_shards]``) so every shard gets a roughly equal,
    interleaved slice across all test areas — this keeps per-shard runtime even
    rather than clustering a slow directory onto one shard. The union of all
    shards is exactly the full allowlist with no overlap.

    ``prefix`` (e.g. ``documentdb_tests/``) is prepended to each rootdir-relative
    node ID so the result can be passed straight to pytest in the container.
    """
    if num_shards < 1:
        raise ValueError(f"num_shards must be >= 1, got {num_shards}")
    if not (0 <= shard_id < num_shards):
        raise ValueError(f"shard_id must be in [0, {num_shards}), got {shard_id}")
    ids = sorted(load_allowlist_ids(allowlist_path, engine_name))
    return [prefix + tid for tid in ids[shard_id::num_shards]]


def cmd_shard_allowlist(args):
    ids = shard_allowlist_ids(args.allowlist, args.engine_name,
                              args.num_shards, args.shard_id, args.prefix)
    text = "\n".join(ids)
    if args.output:
        with open(args.output, "w") as f:
            f.write(text + ("\n" if text else ""))
    else:
        if text:
            print(text)
    return 0


def validate_allowlist_config(path: str) -> list[ConfigError]:
    """Validate allowlist.yml and return a list of errors (empty = valid)."""
    try:
        data = load_yaml(path)
    except Exception as e:
        return [ConfigError("INVALID_SCHEMA", f"Cannot parse {path}: {e}")]

    _, errors = parse_allowlist_entries(data)
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


def summarize_gate(allowlist_path: str, report_path: str, image_path: str = "",
                   engine_name: str = "documentdb",
                   image_override: str = "") -> GateResult:
    """Analyze pytest JSON report against the allowlist and produce a gate result.

    Only entries that apply to ``engine_name`` (per the v2 schema) are
    considered in scope. v1 files are read as if every entry applies to all
    engines. ``image_override`` (if non-empty) is reported as the image used
    in place of whatever is pinned in ``image_path`` — used when a CI run
    is parameterized with a one-off image instead of the on-disk pinned one.
    """
    result = GateResult()

    # Load image info
    if image_override:
        result.image = image_override
    elif image_path and os.path.exists(image_path):
        image_data = load_yaml(image_path)
        result.image = image_data.get("image", "")

    # Load allowlist filtered by engine
    allowed_ids = load_allowlist_ids(allowlist_path, engine_name)
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
        elif outcome in ("xfailed", "xfail"):
            result.non_pass += 1
            result.errors.append({
                "subtype": "NON_PASS_OUTCOME",
                "test_id": test_id,
                "outcome": outcome,
                "message": f"Allowlisted test has non-pass outcome: {outcome}",
            })
        elif outcome in ("xpassed", "xpass"):
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

def summarize_daily(allowlist_path: str, report_path: str, image_path: str = "",
                    engine_name: str = "documentdb",
                    image_override: str = "") -> dict:
    """Analyze a full-suite pytest JSON report against the allowlist for daily delta.

    Only entries that apply to ``engine_name`` (per the v2 schema) are
    considered in scope. v1 files are read as if every entry applies to all
    engines. ``image_override`` (if non-empty) is reported as the image used
    in place of whatever is pinned in ``image_path``.
    """
    allowed_ids = load_allowlist_ids(allowlist_path, engine_name)

    # All node IDs present in the allowlist, regardless of engine scoping.
    # Used to separate "truly outside the file" from "in the file but scoped
    # to a different engine" so the promotion snippet never recommends a
    # bare-string addition that would collide with an existing scoped entry.
    all_listed_ids = {tid for tid, _ in load_allowlist_entries(allowlist_path)}
    scoped_other_engine_ids = all_listed_ids - allowed_ids

    with open(report_path) as f:
        report = json.load(f)

    if image_override:
        image = image_override
    elif image_path and os.path.exists(image_path):
        image_data = load_yaml(image_path)
        image = image_data.get("image", "")
    else:
        image = ""

    tests_in_report = report.get("tests", [])

    allowlisted_passed = []
    allowlisted_failed = []
    scoped_other_engine_passed = []
    scoped_other_engine_not_passing = []
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
        elif nodeid in scoped_other_engine_ids:
            if outcome == "passed":
                scoped_other_engine_passed.append(nodeid)
            else:
                scoped_other_engine_not_passing.append(nodeid)
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

    # Generate promotion YAML snippet.
    # IMPORTANT: only emit truly outside-the-file IDs. IDs already present
    # under a different engine scope are handled separately so a maintainer
    # never copy-pastes a bare-string line that would duplicate an existing
    # scoped entry.
    promotion_snippet_lines = [
        "# Promotion candidates from one daily run; rerun/bootstrap before promoting.",
        "# These are bare-string (all-engines) entries. If a candidate should only",
        "# run on one engine, change it to: { id: ..., engines: [<engine>] }",
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
        "scoped_other_engine_passed": sorted(scoped_other_engine_passed),
        "scoped_other_engine_not_passing": len(scoped_other_engine_not_passing),
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

    scoped_passed = delta.get("scoped_other_engine_passed") or []
    scoped_not_passing = delta.get("scoped_other_engine_not_passing", 0)
    if scoped_passed or scoped_not_passing:
        lines.append("**Allowlisted but scoped to a different engine on this run:**")
        lines.append(
            "These tests are in the allowlist but with `engines:` excluding the engine "
            "this daily ran. They are NOT enforced here and not promotion candidates. "
            "To require any of them on this engine, widen the existing entry's `engines:` "
            "list instead of adding a new bare-string line (a duplicate `id` is rejected)."
        )
        lines.append(f"- passed: {len(scoped_passed)}")
        lines.append(f"- not passing: {scoped_not_passing}")
        if scoped_passed:
            for nodeid in scoped_passed[:10]:
                lines.append(f"  - `{nodeid}`")
            if len(scoped_passed) > 10:
                lines.append(f"  - ... and {len(scoped_passed) - 10} more")
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
# Engine comparison
# ---------------------------------------------------------------------------

def compare_engines(report_a_path: str, report_b_path: str,
                    engine_a: str, engine_b: str,
                    image_path: str = "") -> dict:
    """Compare pytest JSON reports from two engines and classify differences."""
    image = ""
    if image_path and os.path.exists(image_path):
        image_data = load_yaml(image_path)
        image = image_data.get("image", "")

    with open(report_a_path) as f:
        report_a = json.load(f)
    with open(report_b_path) as f:
        report_b = json.load(f)

    # Build outcome maps
    def build_outcome_map(report):
        m = {}
        for test in report.get("tests", []):
            m[test.get("nodeid", "")] = test.get("outcome", "unknown")
        return m

    map_a = build_outcome_map(report_a)
    map_b = build_outcome_map(report_b)
    all_ids = sorted(set(map_a.keys()) | set(map_b.keys()))

    both_pass = []
    both_fail = []
    a_only_pass = []  # a pass, b fail/error
    b_only_pass = []  # b pass, a fail/error — compatibility gaps
    both_skip = []
    other = []

    pass_outcomes = {"passed"}
    fail_outcomes = {"failed", "error"}
    skip_outcomes = {"skipped", "xfailed", "xpassed"}

    for test_id in all_ids:
        outcome_a = map_a.get(test_id, "missing")
        outcome_b = map_b.get(test_id, "missing")
        area = derive_area(test_id)
        entry = {"test_id": test_id, "area": area,
                 engine_a: outcome_a, engine_b: outcome_b}

        if outcome_a in pass_outcomes and outcome_b in pass_outcomes:
            both_pass.append(entry)
        elif outcome_a in fail_outcomes and outcome_b in fail_outcomes:
            both_fail.append(entry)
        elif outcome_a in pass_outcomes and outcome_b in fail_outcomes:
            a_only_pass.append(entry)
        elif outcome_b in pass_outcomes and outcome_a in fail_outcomes:
            b_only_pass.append(entry)
        elif outcome_a in skip_outcomes and outcome_b in skip_outcomes:
            both_skip.append(entry)
        else:
            other.append(entry)

    return {
        "image": image,
        "engine_a": engine_a,
        "engine_b": engine_b,
        "total_compared": len(all_ids),
        "summary": {
            engine_a: {"passed": sum(1 for t in all_ids if map_a.get(t) in pass_outcomes),
                        "failed": sum(1 for t in all_ids if map_a.get(t) in fail_outcomes),
                        "skipped": sum(1 for t in all_ids if map_a.get(t) in skip_outcomes),
                        "missing": sum(1 for t in all_ids if map_a.get(t, "missing") == "missing")},
            engine_b: {"passed": sum(1 for t in all_ids if map_b.get(t) in pass_outcomes),
                        "failed": sum(1 for t in all_ids if map_b.get(t) in fail_outcomes),
                        "skipped": sum(1 for t in all_ids if map_b.get(t) in skip_outcomes),
                        "missing": sum(1 for t in all_ids if map_b.get(t, "missing") == "missing")},
        },
        "both_pass": both_pass,
        "both_fail": both_fail,
        "a_only_pass": a_only_pass,
        "b_only_pass": b_only_pass,
        "both_skip": both_skip,
        "other": other,
    }


def render_comparison_markdown(result: dict) -> str:
    """Render a Markdown comparison report between two engines."""
    engine_a = result["engine_a"]
    engine_b = result["engine_b"]
    summary = result["summary"]
    lines = []

    lines.append(f"## Engine Comparison: {engine_a} vs {engine_b}")
    lines.append("")
    if result.get("image"):
        lines.append(f"**Image:** `{result['image']}`")
        lines.append("")

    lines.append("### Summary")
    lines.append("")
    lines.append(f"| | {engine_a} | {engine_b} |")
    lines.append("|---|---|---|")
    lines.append(f"| Passed | {summary[engine_a]['passed']} | {summary[engine_b]['passed']} |")
    lines.append(f"| Failed | {summary[engine_a]['failed']} | {summary[engine_b]['failed']} |")
    lines.append(f"| Skipped | {summary[engine_a]['skipped']} | {summary[engine_b]['skipped']} |")
    lines.append(f"| Missing | {summary[engine_a]['missing']} | {summary[engine_b]['missing']} |")
    lines.append(f"| **Total** | **{result['total_compared']}** | **{result['total_compared']}** |")
    lines.append("")

    # Compatibility gaps: engine_b passes but engine_a fails
    b_only = result["b_only_pass"]
    if b_only:
        lines.append(f"### Compatibility Gaps ({engine_a} fail, {engine_b} pass): {len(b_only)}")
        lines.append("")
        lines.append(f"| Test | Area | {engine_a} | {engine_b} |")
        lines.append("|---|---|---|---|")
        for t in b_only:
            lines.append(f"| `{t['test_id']}` | {t['area']} | {t[engine_a]} | {t[engine_b]} |")
        lines.append("")
    else:
        lines.append(f"### Compatibility Gaps ({engine_a} fail, {engine_b} pass): 0")
        lines.append("")

    # engine_a advantages: engine_a passes but engine_b fails
    a_only = result["a_only_pass"]
    if a_only:
        lines.append(f"### {engine_a} Advantages ({engine_a} pass, {engine_b} fail): {len(a_only)}")
        lines.append("")
        lines.append(f"| Test | Area | {engine_a} | {engine_b} |")
        lines.append("|---|---|---|---|")
        for t in a_only:
            lines.append(f"| `{t['test_id']}` | {t['area']} | {t[engine_a]} | {t[engine_b]} |")
        lines.append("")

    # Both failed
    both_fail = result["both_fail"]
    if both_fail:
        lines.append(f"### Both Failed: {len(both_fail)}")
        lines.append("")
        lines.append(f"| Test | Area | {engine_a} | {engine_b} |")
        lines.append("|---|---|---|---|")
        for t in both_fail[:20]:
            lines.append(f"| `{t['test_id']}` | {t['area']} | {t[engine_a]} | {t[engine_b]} |")
        if len(both_fail) > 20:
            lines.append(f"| ... and {len(both_fail) - 20} more | | | |")
        lines.append("")

    # Other (mixed skip/xfail/missing)
    other = result["other"]
    if other:
        lines.append(f"### Other Differences: {len(other)}")
        lines.append("")
        lines.append(f"| Test | Area | {engine_a} | {engine_b} |")
        lines.append("|---|---|---|---|")
        for t in other[:20]:
            lines.append(f"| `{t['test_id']}` | {t['area']} | {t[engine_a]} | {t[engine_b]} |")
        if len(other) > 20:
            lines.append(f"| ... and {len(other) - 20} more | | | |")
        lines.append("")

    # Both passed and both skipped (counts only)
    lines.append(f"### Both Passed: {len(result['both_pass'])} tests")
    lines.append("")
    if result["both_skip"]:
        lines.append(f"### Both Skipped/XFail: {len(result['both_skip'])} tests")
        lines.append("")

    return "\n".join(lines)


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
    result = summarize_gate(args.allowlist, args.report, args.image, args.engine_name,
                            image_override=getattr(args, "image_override", "") or "")
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
    delta = summarize_daily(args.allowlist, args.report, args.image, args.engine_name,
                            image_override=getattr(args, "image_override", "") or "")
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


def cmd_compare_engines(args):
    result = compare_engines(args.report_a, args.report_b,
                             args.engine_a, args.engine_b, args.image)
    md = render_comparison_markdown(result)

    print(md)

    if args.output_dir:
        os.makedirs(args.output_dir, exist_ok=True)
        with open(os.path.join(args.output_dir, "comparison-summary.md"), "w") as f:
            f.write(md)
        with open(os.path.join(args.output_dir, "comparison-summary.json"), "w") as f:
            json.dump(result, f, indent=2)

    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        with open(summary_file, "a") as f:
            f.write(md + "\n")

    # Comparison is informational; always succeed so the pipeline stays green
    return 0


def gate_failure_ids(allowlist_path: str, report_path: str, engine_name: str) -> list[str]:
    """Return allowlisted test IDs that ran but did NOT pass (failed/skipped/
    xfailed/xpassed/errored).

    These are the candidates for a sequential re-run: the parallel full-suite
    pass can intermittently crash the engine (a known RUM dynamic-cursor race
    under -n4), and the backend's brief recovery window cascades into spurious
    failures of unrelated, otherwise-passing allowlisted tests. Re-running just
    these IDs sequentially (no parallel race) lets genuine passers recover while
    genuinely-broken tests stay failed.

    Missing (never-collected) allowlisted IDs are intentionally excluded — a
    re-run cannot resurrect a test that was never collected, and that condition
    indicates a real allowlist/image drift that must fail the gate.
    """
    result = summarize_gate(allowlist_path, report_path, engine_name=engine_name)
    ids = [f["test_id"] for f in result.failed_tests]
    ids += [e["test_id"] for e in result.errors
            if e.get("subtype") in ("NON_PASS_OUTCOME", "ALLOWLISTED_XPASS")]
    # De-duplicate while preserving order
    seen = set()
    unique = []
    for tid in ids:
        if tid not in seen:
            seen.add(tid)
            unique.append(tid)
    return unique


def cmd_gate_failures(args):
    ids = gate_failure_ids(args.allowlist, args.report, args.engine_name)
    text = "\n".join(ids)
    if args.output:
        with open(args.output, "w") as f:
            f.write(text + ("\n" if text else ""))
    else:
        if text:
            print(text)
    return 0


def merge_reports(base_path: str, overlay_paths: list[str],
                  sum_collected: bool = False) -> dict:
    """Merge one or more overlay pytest JSON reports into a base report.

    For every test present in an overlay, the overlay's record (outcome and
    detail) replaces the base record for that node ID. Overlays are applied in
    order, so the last overlay wins. This is used to fold a sequential re-run of
    failed allowlisted tests back into the full parallel report: a re-run that
    passes overrides the original transient failure, while a re-run that fails
    keeps the test failed.

    ``summary.collected`` handling depends on the merge mode:

    * ``sum_collected=False`` (default, **re-run merge**): the base report holds
      the full collected population and each overlay is a subset re-run of it, so
      the base's ``collected`` is preserved.
    * ``sum_collected=True`` (**shard-combine merge**): the base and overlays are
      *disjoint* shard reports, so ``collected`` is summed across all inputs so
      the coverage-boundary math in summarize-gate reflects the whole set rather
      than just shard 0's slice.
    """
    with open(base_path) as f:
        base = json.load(f)

    tests = base.get("tests", [])
    index = {t.get("nodeid", ""): i for i, t in enumerate(tests)}
    collected_total = (base.get("summary", {}) or {}).get("collected", 0) or 0

    for overlay_path in overlay_paths:
        with open(overlay_path) as f:
            overlay = json.load(f)
        if sum_collected:
            collected_total += (overlay.get("summary", {}) or {}).get("collected", 0) or 0
        for t in overlay.get("tests", []):
            nid = t.get("nodeid", "")
            if not nid:
                continue
            if nid in index:
                tests[index[nid]] = t
            else:
                index[nid] = len(tests)
                tests.append(t)

    base["tests"] = tests

    # Refresh the outcome tallies in summary so downstream readers see merged
    # numbers. 'collected' is preserved (re-run) or summed (shard-combine).
    summary = base.get("summary", {})
    tally: dict[str, int] = {}
    for t in tests:
        tally[t.get("outcome", "unknown")] = tally.get(t.get("outcome", "unknown"), 0) + 1
    for key in ("passed", "failed", "skipped", "error", "xfailed", "xpassed"):
        if key in tally:
            summary[key] = tally[key]
        elif key in summary:
            summary[key] = 0
    summary["total"] = len(tests)
    if sum_collected:
        summary["collected"] = collected_total
    base["summary"] = summary
    return base


def cmd_merge_reports(args):
    merged = merge_reports(args.base, args.overlay,
                           sum_collected=getattr(args, "sum_collected", False))
    with open(args.out, "w") as f:
        json.dump(merged, f)
    print(f"Merged {len(args.overlay)} overlay report(s) into {args.out} "
          f"({len(merged.get('tests', []))} tests)")
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="DocumentDB Functional Test Gate Tooling (RFC-0007)")
    parser.add_argument("--image", default="documentdb-local/functional-tests/config/image.yml",
                        help="Path to image.yml")
    parser.add_argument("--allowlist", default="documentdb-local/functional-tests/config/allowlist.yml",
                        help="Path to allowlist.yml")
    parser.add_argument("--engine-name", default="documentdb",
                        help="Engine name for filtering schema_version=2 allowlist entries "
                             "with explicit 'engines:' scoping (default: documentdb). "
                             "Ignored by validate-config since schema validation is engine-agnostic.")

    subparsers = parser.add_subparsers(dest="command", required=True)

    # validate-config
    subparsers.add_parser("validate-config", help="Validate image.yml and allowlist.yml")

    # summarize-gate
    gate_parser = subparsers.add_parser("summarize-gate", help="Summarize PR gate results")
    gate_parser.add_argument("--report", required=True, help="Path to pytest JSON report")
    gate_parser.add_argument("--output-dir", default="", help="Directory for output artifacts")
    gate_parser.add_argument("--image-override", default="",
                             help="Docker ref of the image actually used (overrides image.yml "
                                  "in the report only; used when CI is parameterized with a one-off image)")

    # summarize-daily
    daily_parser = subparsers.add_parser("summarize-daily", help="Summarize daily delta")
    daily_parser.add_argument("--report", required=True, help="Path to pytest JSON report")
    daily_parser.add_argument("--output-dir", default="", help="Directory for output artifacts")
    daily_parser.add_argument("--image-override", default="",
                              help="Docker ref of the image actually used (overrides image.yml "
                                   "in the report only; used when CI is parameterized with a one-off image)")

    # compare-engines
    compare_parser = subparsers.add_parser("compare-engines",
                                           help="Compare test results from two engines")
    compare_parser.add_argument("--report-a", required=True,
                                help="Path to pytest JSON report for engine A")
    compare_parser.add_argument("--report-b", required=True,
                                help="Path to pytest JSON report for engine B")
    compare_parser.add_argument("--engine-a", default="documentdb",
                                help="Name of engine A (default: documentdb)")
    compare_parser.add_argument("--engine-b", default="reference",
                                help="Name of engine B (default: reference)")
    compare_parser.add_argument("--output-dir", default="",
                                help="Directory for output artifacts")

    # gate-failures: list allowlisted tests that ran but did not pass (rerun set)
    failures_parser = subparsers.add_parser(
        "gate-failures",
        help="Print allowlisted tests that ran but did not pass (for sequential re-run)")
    failures_parser.add_argument("--report", required=True, help="Path to pytest JSON report")
    failures_parser.add_argument("--output", default="",
                                 help="Write node IDs (one per line) to this file instead of stdout")

    # merge-reports: fold re-run outcomes back into the base report
    merge_parser = subparsers.add_parser(
        "merge-reports",
        help="Merge overlay (re-run) pytest JSON reports into a base report")
    merge_parser.add_argument("--base", required=True, help="Path to the base pytest JSON report")
    merge_parser.add_argument("--overlay", required=True, nargs="+",
                              help="Path(s) to overlay report(s); later overlays win")
    merge_parser.add_argument("--out", required=True, help="Path to write the merged report")
    merge_parser.add_argument("--sum-collected", action="store_true",
                              help="Sum summary.collected across base+overlays (disjoint "
                                   "shard-combine merge) instead of preserving the base's "
                                   "(default: preserve, for re-run merges)")

    # shard-allowlist: print the allowlisted node IDs assigned to one shard
    shard_parser = subparsers.add_parser(
        "shard-allowlist",
        help="Print the allowlisted test node IDs for one shard (round-robin split)")
    shard_parser.add_argument("--num-shards", type=int, required=True, help="Total number of shards")
    shard_parser.add_argument("--shard-id", type=int, required=True, help="This shard's index [0, num-shards)")
    shard_parser.add_argument("--prefix", default="",
                              help="String prepended to each node ID (e.g. 'documentdb_tests/')")
    shard_parser.add_argument("--output", default="",
                              help="Write node IDs (one per line) to this file instead of stdout")

    args = parser.parse_args()

    if args.command == "validate-config":
        return cmd_validate_config(args)
    elif args.command == "summarize-gate":
        return cmd_summarize_gate(args)
    elif args.command == "summarize-daily":
        return cmd_summarize_daily(args)
    elif args.command == "compare-engines":
        return cmd_compare_engines(args)
    elif args.command == "gate-failures":
        return cmd_gate_failures(args)
    elif args.command == "merge-reports":
        return cmd_merge_reports(args)
    elif args.command == "shard-allowlist":
        return cmd_shard_allowlist(args)


if __name__ == "__main__":
    sys.exit(main())
