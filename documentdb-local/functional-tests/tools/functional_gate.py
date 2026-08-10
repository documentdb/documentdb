#!/usr/bin/env python3
"""
DocumentDB Functional Test Gate Tooling — known-failures xfail model.

The functional gate runs the full suite under conftest_known_failures.py against
a per-gateway failing/flaky pair and gates with these commands:

* split-collection       — slice the collection manifest for one parallel leg
* report-failures        — node IDs that failed/errored (re-run set + gate verdict)
* recover-and-gate       — serial re-run of transient victims, gate on the merge
* merge-reports          — fold sequential re-run outcomes into the base report
* verify-split-universes — assert every parallel leg collected the same universe
* reconcile              — fold a gate run back into a list (source_sha bump / drift)
* compare-engines        — reference-engine (mongo:8.0) comparison lane

The gate path has zero third-party dependencies; PyYAML is imported lazily in
load_yaml() (used only by compare-engines) so a lane without pyyaml cannot crash
the gate.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

# Error annotations. GitHub Actions renders a line prefixed with "::error::" as
# an annotation on the run; a CI system with different syntax can set
# CI_ERROR_PREFIX instead of forking this file. Either way the gate's verdict is
# the exit code, so the prefix only affects presentation.
_CI_ERROR_PREFIX = os.environ.get("CI_ERROR_PREFIX", "::error::")


def ci_error(message: str, *, flush: bool = False) -> None:
    """Emit ``message`` as a CI error annotation."""
    print(f"{_CI_ERROR_PREFIX}{message}", flush=flush)


def load_yaml(path: str) -> dict:
    import yaml  # lazy: keeps the gate path free of the PyYAML dependency
    with open(path) as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        raise ValueError(f"Expected YAML mapping, got {type(data).__name__}")
    return data


def _read_manifest_ids(manifest_path: str) -> list[str]:
    """Extract pytest node IDs from a collection manifest, dropping noise.

    Accepts the raw output of ``pytest --collect-only -q``: one node ID per
    line, followed by a trailing ``"<N> tests collected in <t>s"`` summary line
    and possibly blank or warning lines. Only lines containing ``::`` (the
    node-ID separator) are kept. Duplicates are removed, first-seen order kept.
    """
    ids: list[str] = []
    seen: set[str] = set()
    with open(manifest_path) as f:
        for line in f:
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or "::" not in stripped:
                continue
            if stripped not in seen:
                seen.add(stripped)
                ids.append(stripped)
    return ids


def split_collection_ids(manifest_path: str, num_splits: int, split_id: int,
                         prefix: str = "", strip_prefix: str = "") -> list[str]:
    """Return the collected test node IDs assigned to one test-split.

    This is TEST SPLITTING (dividing a test suite across parallel CI jobs), not
    data sharding — nothing here relates to sharded collections.

    Deterministic round-robin (stride-slice ``ids[split_id::num_splits]`` over a
    sorted universe) where the universe is a pytest collection manifest (the full
    non-quarantined suite), so each parallel runner runs a disjoint, interleaved
    slice of the whole collected suite under the xfail plugin.

    ``strip_prefix`` is removed from each manifest node ID *before* splitting and
    ``prefix`` is prepended *after*, so passing the same value for both makes
    the output prefix idempotent regardless of the collector's node-ID form.
    """
    if num_splits < 1:
        raise ValueError(f"num_splits must be >= 1, got {num_splits}")
    if not (0 <= split_id < num_splits):
        raise ValueError(f"split_id must be in [0, {num_splits}), got {split_id}")
    ids = _read_manifest_ids(manifest_path)
    if strip_prefix:
        ids = [tid[len(strip_prefix):] if tid.startswith(strip_prefix) else tid
               for tid in ids]
    ids = sorted(set(ids))
    return [prefix + tid for tid in ids[split_id::num_splits]]


def parse_universe_record(path: str) -> dict:
    """Parse one leg's ``universe.txt`` (``<tag> <mode> <hash> <count>``)."""
    with open(path, encoding="utf-8") as f:
        line = f.read().strip()
    parts = line.split()
    if len(parts) != 4:
        raise ValueError(
            f"{path}: expected '<tag> <mode> <hash> <count>', got {line!r}")
    tag, mode, uhash, count = parts
    if mode not in ("parallel", "noparallel"):
        raise ValueError(f"{path}: unknown mode {mode!r}")
    if not count.isdigit():
        raise ValueError(f"{path}: count {count!r} is not a number")
    return {"tag": tag, "mode": mode, "hash": uhash,
            "count": int(count), "path": path}


def verify_split_universes(universe_files: list[str],
                           expected_splits: int) -> list[str]:
    """Check that every parallel test-split collected an IDENTICAL universe.

    Returns a list of human-readable problems; empty means the splits agree.

    Why this has to be enforced rather than merely logged: each parallel leg
    collects the suite independently and then takes the stride slice
    ``ids[split_id::num_splits]``. That slice is a partition of the suite ONLY
    if every leg sliced the same sorted universe. If one leg's collection
    silently omits a node -- a clean rc=0 partial, which ``guard_collection``
    does not catch because the exit code is 0 -- then every position after the
    omission shifts by one. That leg starts running the NEXT leg's tests, and
    its own share is left to nobody: roughly ``1/num_splits`` of the suite after
    the omission point runs on no leg at all. Every leg still clears
    MIN_MANIFEST, every leg still reports its own slice as passing, and the gate
    scores green over a suite it never fully ran.

    The per-leg ``universe-hash`` log line makes that *detectable* after the
    fact; this makes it *fail*.

    ``noparallel`` legs are excluded on purpose: that leg collects a different
    marker set (``-m no_parallel``) by design, so its hash legitimately differs.
    """
    problems: list[str] = []
    records = []
    for path in sorted(universe_files):
        try:
            records.append(parse_universe_record(path))
        except (OSError, ValueError) as exc:
            problems.append(f"unreadable universe record: {exc}")

    # Collapse byte-identical records BEFORE counting. A stage retry republishes
    # every leg under a new artifact name (the name carries System.PhaseAttempt),
    # so this job legitimately sees one record per leg PER ATTEMPT. Those repeats
    # are one leg reporting the same universe twice, not two legs claiming the
    # same id, and must not be read as a fault. A tag that survives this dedupe
    # more than once genuinely disagreed with itself, which IS worth failing on.
    uniq = {}
    for r in records:
        uniq[(r["tag"], r["mode"], r["hash"], r["count"])] = r
    records = list(uniq.values())

    parallel = [r for r in records if r["mode"] == "parallel"]

    tags = [r["tag"] for r in parallel]
    dupes = sorted({t for t in tags if tags.count(t) > 1})
    if dupes:
        problems.append(
            f"split tag(s) {dupes} reported CONFLICTING universes -- the same "
            f"split id claimed more than one collected universe, so its stride "
            f"cannot be trusted")

    if len(parallel) != expected_splits:
        problems.append(
            f"expected {expected_splits} parallel split(s) to report a universe, "
            f"got {len(parallel)} ({sorted(tags)}) -- a leg that never reported "
            f"leaves its stride unrun, which no per-leg gate can detect")

    hashes = {r["hash"] for r in parallel}
    if len(hashes) > 1:
        detail = ", ".join(f"{r['tag']}={r['hash']}({r['count']} ids)"
                           for r in parallel)
        problems.append(
            f"parallel splits collected DIFFERENT universes: {detail} -- the "
            f"stride slices are computed against mismatched manifests, so part "
            f"of the suite was assigned to no split. Refusing to accept these "
            f"results.")

    return problems


def cmd_verify_split_universes(args):
    files = list(args.universe or [])
    scanned = []
    prefix = getattr(args, "artifact_prefix", "") or ""
    for root in (args.dir or []):
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in filenames:
                if name != "universe.txt":
                    continue
                path = os.path.join(dirpath, name)
                scanned.append(path)
                # Scope to THIS stage's artifacts. Downloads land under
                # <workspace>/<artifactName>/, so the containing directory
                # carries the artifact name. Without this, a second instance of
                # this stage template in the same run (e.g. a rust-gateway
                # variant) would contribute its own splits' records here and
                # trip the count/duplicate checks for no real reason.
                if prefix and not os.path.basename(
                        os.path.dirname(path)).startswith(prefix):
                    continue
                files.append(path)
    if not files:
        # Self-diagnosing on purpose. The likeliest cause is a download pattern
        # that matched nothing, and "no records" alone does not distinguish that
        # from a genuinely empty run -- so say what WAS on disk.
        print("ERROR: no universe.txt found -- cannot verify that the test "
              "splits agreed on a universe; refusing to pass.", file=sys.stderr)
        if scanned:
            print(f"  {len(scanned)} universe.txt file(s) were present but none "
                  f"sat under a directory starting with {prefix!r}:",
                  file=sys.stderr)
            for p in sorted(scanned)[:20]:
                print(f"    {p}", file=sys.stderr)
        else:
            for root in (args.dir or []):
                try:
                    entries = sorted(os.listdir(root))
                except OSError as exc:
                    print(f"  search root {root} unreadable: {exc}", file=sys.stderr)
                    continue
                print(f"  search root {root} holds {len(entries)} entry(ies); "
                      f"first 20: {entries[:20]}", file=sys.stderr)
        return 1
    problems = verify_split_universes(files, args.expected_splits)
    for r in sorted(files):
        print(f"  found {r}")
    if problems:
        for p in problems:
            ci_error(f"split-universe check: {p}")
            print(f"ERROR: {p}", file=sys.stderr)
        return 1
    print(f"split-universe check PASS: {args.expected_splits} parallel split(s) "
          f"reported an identical collected universe.")
    return 0


def cmd_split_collection(args):
    ids = split_collection_ids(args.manifest, args.num_splits, args.split_id,
                               args.prefix, args.strip_prefix)
    text = "\n".join(ids)
    if args.output:
        with open(args.output, "w") as f:
            f.write(text + ("\n" if text else ""))
    else:
        if text:
            print(text)
    return 0


def report_failure_ids(report_path: str, strip_prefix: str = "") -> list[str]:
    """Return node IDs whose outcome is ``failed``/``error`` in a JSON report.

    With the ``conftest_known_failures`` xfail plugin applied in-process, known
    failures are reported as ``xfailed`` and flaky/upstream passes as
    ``xpassed``/``xfailed`` — so a ``failed``/``error`` outcome is a genuine
    regression or an XPASS(strict) of a known failure. Used both to pick the
    sequential re-run set (engine-crash victims) and, in the combine job, to
    decide the gate: any residual ``failed``/``error`` fails the build.

    ``strip_prefix`` (e.g. ``docdb_functional_tests/documentdb_tests/``) is
    removed from each node ID so the caller can re-prefix idempotently.
    """
    with open(report_path) as f:
        report = json.load(f)
    seen: set[str] = set()
    out: list[str] = []
    for test in report.get("tests", []):
        if test.get("outcome", "") in ("failed", "error"):
            nid = test.get("nodeid", "")
            if strip_prefix and nid.startswith(strip_prefix):
                nid = nid[len(strip_prefix):]
            if nid and nid not in seen:
                seen.add(nid)
                out.append(nid)
    return out


def report_recorded_ids(report_path: str, strip_prefix: str = "") -> set[str]:
    """Return every node ID with ANY recorded outcome in a pytest JSON report.

    Used by recover-and-gate to detect assigned-but-unrecorded tests: when an
    xdist worker dies (OOM kill, interpreter crash), the in-flight test gets a
    crash error but part of the worker's queue can end the session with no
    outcome at all — the report is simply shorter, which no outcome-based check
    can see. Comparing against the assigned set is the only way to notice.
    """
    with open(report_path) as f:
        report = json.load(f)
    ids: set[str] = set()
    for test in report.get("tests", []):
        nid = test.get("nodeid", "")
        if strip_prefix and nid.startswith(strip_prefix):
            nid = nid[len(strip_prefix):]
        if nid:
            ids.add(nid)
    return ids


def cmd_report_failures(args):
    ids = report_failure_ids(args.report, args.strip_prefix)
    text = "\n".join(ids)
    if args.output:
        with open(args.output, "w") as f:
            f.write(text + ("\n" if text else ""))
    else:
        if text:
            print(text)
    return 0


_ROOTDIR_NAME = "documentdb_tests"


def _normalize_node_id(node_id: str, rootdir_name: str = _ROOTDIR_NAME) -> str:
    """Normalize a node ID to its rootdir-relative form.

    Mirrors ``conftest_known_failures._build_suffix_set``: if the path part of
    the ID contains the rootdir directory name (``documentdb_tests``), return
    the suffix after its last occurrence; otherwise return the ID unchanged.
    This lets prefixed list entries (``docdb_functional_tests/documentdb_tests/
    compatibility/...``) and bare report node IDs (``compatibility/...``)
    compare equal.
    """
    parts = node_id.split("/")
    if rootdir_name in parts:
        idx = len(parts) - 1 - parts[::-1].index(rootdir_name)
        return "/".join(parts[idx + 1:])
    return node_id


def reconcile_failing_list(report_path: str, failing_path: str,
                           flaky_path: str = "",
                           prune_uncollected: bool = False) -> dict:
    """Reconcile a known-failures list against a (merged) pytest JSON report.

    The classification mirrors the gate's strict-xfail semantics under
    ``conftest_known_failures``:

    * ``failed``/``error`` test NOT on the list  -> new failure -> **add**
      (unless it is on the flaky list, which would make the plugin's
      failing/flaky overlap check throw — those are skipped with a warning).
    * ``failed`` test ON the list -> XPASS(strict) (a listed expected failure
      now passes) -> **remove**. As a safety net, if the failure detail is
      available and does not look like an XPASS (e.g. a setup ``error`` on a
      listed test), the entry is kept and reported instead.
    * List entry whose test was not collected at all (renamed/deleted
      upstream) -> **pruned** when ``prune_uncollected`` is set, otherwise
      only reported. Keep the default when reconciling from a partial run.

    Returns a dict with the updated list ``lines`` (comments and entry order
    preserved, additions appended under a marker comment in the file's
    dominant prefix style) plus the classification buckets.
    """
    with open(report_path) as f:
        report = json.load(f)

    outcomes = {}
    details = {}
    for test in report.get("tests", []):
        nid = test.get("nodeid", "")
        if not nid:
            continue
        norm = _normalize_node_id(nid)
        outcomes[norm] = test.get("outcome", "unknown")
        call = test.get("call", {}) or {}
        details[norm] = str(call.get("longrepr", "") or "")

    raw_lines = []
    with open(failing_path) as f:
        for line in f:
            raw_lines.append(line.rstrip("\n"))
    entries = [l.strip() for l in raw_lines if l.strip() and not l.strip().startswith("#")]
    entry_by_norm = {_normalize_node_id(e): e for e in entries}

    flaky_norm = set()
    if flaky_path and os.path.exists(flaky_path):
        with open(flaky_path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    flaky_norm.add(_normalize_node_id(line))

    added, removed, kept_errored, skipped_flaky = [], [], [], []
    for norm, outcome in sorted(outcomes.items()):
        if outcome not in ("failed", "error"):
            continue
        if norm in entry_by_norm:
            # Listed + failed = XPASS(strict) in the gate. A listed test can
            # also 'error' outside the call phase (xfail does not cover setup
            # errors) — keep those and let a human look.
            detail = details.get(norm, "")
            if outcome == "error" and "XPASS" not in detail:
                kept_errored.append(norm)
            else:
                removed.append(norm)
        elif norm in flaky_norm:
            skipped_flaky.append(norm)
        else:
            added.append(norm)

    uncollected = [norm for norm in entry_by_norm if norm not in outcomes]
    pruned = uncollected if prune_uncollected else []

    drop = {entry_by_norm[n] for n in removed}
    drop.update(entry_by_norm[n] for n in pruned)
    new_lines = [l for l in raw_lines if l.strip() not in drop]

    if added:
        # Preserve the file's dominant entry style: prefixed (backend-gate
        # style) vs bare rootdir-relative (report style).
        prefixed = sum(1 for e in entries if _normalize_node_id(e) != e)
        style_prefix = ""
        if entries and prefixed > len(entries) / 2:
            sample = next(e for e in entries if _normalize_node_id(e) != e)
            style_prefix = sample[: len(sample) - len(_normalize_node_id(sample))]
        while new_lines and not new_lines[-1].strip():
            new_lines.pop()
        new_lines.append("")
        new_lines.append("# --- added by functional_gate.py reconcile ---")
        new_lines.extend(style_prefix + n for n in added)

    return {
        "lines": new_lines,
        "added": added,
        "removed": removed,
        "uncollected": uncollected,
        "pruned": pruned,
        "kept_errored": kept_errored,
        "skipped_flaky": skipped_flaky,
        "flaky_passes": sorted(n for n, o in outcomes.items()
                               if o == "xpassed" and n in flaky_norm),
    }


def cmd_reconcile(args):
    result = reconcile_failing_list(args.report, args.failing, args.flaky,
                                    prune_uncollected=args.prune_uncollected)
    out_path = args.out or args.failing
    with open(out_path, "w", newline="\n") as f:
        f.write("\n".join(result["lines"]) + "\n")

    print(f"Reconciled {args.failing} from {args.report} -> {out_path}")
    print(f"  added (new failures):          {len(result['added'])}")
    print(f"  removed (XPASS strict):        {len(result['removed'])}")
    print(f"  uncollected list entries:      {len(result['uncollected'])}"
          + ("  [pruned]" if args.prune_uncollected else "  [kept — use --prune-uncollected]"))
    if result["kept_errored"]:
        print(f"  KEPT listed-but-errored (inspect manually): {len(result['kept_errored'])}")
        for n in result["kept_errored"]:
            print(f"    {n}")
    if result["skipped_flaky"]:
        print(f"  SKIPPED failures already on the flaky list (would overlap): {len(result['skipped_flaky'])}")
        for n in result["skipped_flaky"]:
            print(f"    {n}")
    if result["flaky_passes"]:
        print(f"  flaky-list entries that passed this run (pruning candidates): {len(result['flaky_passes'])}")

    if getattr(args, "summary_json", ""):
        # Machine-readable classification for the auto-reconcile bot. "clean" is
        # true when the reconcile is safe to auto-apply: it ONLY drops
        # XPASS(strict) entries. Uncollected entries (a listed test the run did
        # not collect — deleted/renamed upstream, or a run that did not cover the
        # list) make it false whether or not they were pruned, since dropping them
        # is a suite-composition change a human should confirm.
        clean = (not result["added"] and not result["kept_errored"]
                 and not result["skipped_flaky"] and not result["uncollected"])
        summary = {
            "added": result["added"],
            "removed": result["removed"],
            "kept_errored": result["kept_errored"],
            "skipped_flaky": result["skipped_flaky"],
            "uncollected": result["uncollected"],
            "pruned": result["pruned"],
            "flaky_passes": result["flaky_passes"],
            "changed": bool(result["added"] or result["removed"] or result["pruned"]),
            "clean": clean,
        }
        with open(args.summary_json, "w") as f:
            json.dump(summary, f, indent=2)
    return 0


# ---------------------------------------------------------------------------
# Gate result summarization
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Daily delta summarization
# ---------------------------------------------------------------------------


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


def merge_reports(base_path: str, overlay_paths: list[str],
                  sum_collected: bool = False) -> dict:
    """Merge one or more overlay pytest JSON reports into a base report.

    For every test present in an overlay, the overlay's record (outcome and
    detail) replaces the base record for that node ID. Overlays are applied in
    order, so the last overlay wins. This is used to fold a sequential re-run of
    failed tests back into the full parallel report: a re-run that passes
    overrides the original transient failure, while a re-run that fails keeps
    the test failed.

    ``summary.collected`` handling depends on the merge mode:

    * ``sum_collected=False`` (default, **re-run merge**): the base report holds
      the full collected population and each overlay is a subset re-run of it, so
      the base's ``collected`` is preserved.
    * ``sum_collected=True`` (**split-combine merge**): the base and overlays are
      *disjoint* test-split reports, so ``collected`` is summed across all inputs
      to reflect the whole set rather than just split 0's slice.
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
    # numbers. 'collected' is preserved (re-run) or summed (split-combine).
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


def _rerun_isolated(rerun_cmd: list[str], ids: list[str], prefix: str,
                    workdir: str) -> list[str]:
    """Re-run each node ID in its own pytest process; return the reports written.

    Fallback for when the batched re-run dies without producing a report (see the
    caller). One process per test bounds the blast radius of a fatal hang to the
    single test that hung: every other test still gets its recovery attempt. A
    test whose own process dies writes no report and simply stays failed, which is
    the correct outcome -- a test that reliably hangs is not a transient victim.
    """
    import subprocess

    reports = []
    for i, test_id in enumerate(ids):
        out = os.path.join(workdir, f"recover_rerun_{i}.json")
        try:
            os.remove(out)
        except OSError:
            pass
        subprocess.call(rerun_cmd + ["--json-report",
                                     f"--json-report-file={out}",
                                     prefix + test_id])
        if os.path.exists(out):
            reports.append(out)
        else:
            print(f"  no report for {test_id} (hung or crashed) — left failed.",
                  flush=True)
    print(f"isolated re-run produced {len(reports)}/{len(ids)} report(s).",
          flush=True)
    return reports


def cmd_recover_and_gate(args):
    """Sequential re-run recovery of transient crash victims + gate on the merged
    report. The single canonical implementation shared by the single-job lane and
    the split matrix lane (scripts/run_pytest_split.sh).

    The parallel (-n auto) pass is stochastic: a backend crash (e.g. the
    $meta:textScore dynamic-cursor UAF) restarts the cluster and cascades a batch
    of concurrent tests with connection errors. Each pass re-runs ONLY the
    still-failing set sequentially via the caller-supplied pytest command (given
    after ``--``; this function appends ``--json-report`` and the ``@argfile`` of
    node IDs) so, with no contention, transient victims pass and are merged back;
    a genuine failure survives every pass. Bounded to --max-passes; above
    --transient-limit failures the run is treated as a real breakage and left for
    the gate. Fails CLOSED (exit 1) on a missing/unreadable report so a collapse
    never scores green, and exit 1 on any residual failed/error (real regression
    or XPASS(strict)) after recovery.

    With ``--expected-ids`` (the caller's assigned-slice/manifest file), each
    pass ALSO re-runs assigned tests that have no recorded outcome at all. That
    is the xdist worker-death hole: a killed worker's in-flight test gets a
    crash error, but tests still in its queue can vanish from the report
    entirely — observed in a full-suite run where 20 worker deaths left
    1,175 of 12,094 assigned tests unrecorded and the leg scored green (the
    RAN >= EXPECTED/2 floor is far too lax to see it). Above --missing-limit
    unrecorded tests the loss is systemic (a leg-wide collapse must red, not
    grind through a serial re-run of half the slice), and any test still
    unrecorded after recovery is a gate failure.
    """
    import subprocess
    import time

    rerun_cmd = list(args.rerun_cmd or [])
    if rerun_cmd and rerun_cmd[0] == "--":
        rerun_cmd = rerun_cmd[1:]
    if not rerun_cmd:
        ci_error("recover-and-gate: no pytest re-run "
                 "command was given after '--'.", flush=True)
        return 1
    if not os.path.exists(args.report):
        ci_error(f"recover-and-gate: report {args.report} "
                 f"does not exist — refusing to score green on a missing run.",
                 flush=True)
        return 1

    expected_ids: list[str] = []
    if getattr(args, "expected_ids", ""):
        try:
            expected_ids = _read_manifest_ids(args.expected_ids)
        except OSError as exc:
            ci_error(f"recover-and-gate: cannot read "
                     f"--expected-ids {args.expected_ids} ({exc}) — refusing to gate "
                     f"without the assigned set.", flush=True)
            return 1
        if args.strip_prefix:
            expected_ids = [i[len(args.strip_prefix):] if i.startswith(args.strip_prefix)
                            else i for i in expected_ids]
        expected_ids = sorted(set(expected_ids))
        if not expected_ids:
            ci_error(f"recover-and-gate: --expected-ids "
                     f"{args.expected_ids} holds no node IDs — refusing to gate against "
                     f"an empty assigned set.", flush=True)
            return 1

    # getattr defaults keep direct callers (tests build a bare Namespace) and
    # older invocations working without the new flags.
    missing_limit = getattr(args, "missing_limit", 1500)

    def _unrecorded():
        if not expected_ids:
            return []
        recorded = report_recorded_ids(args.report, args.strip_prefix)
        return [i for i in expected_ids if i not in recorded]

    workdir = args.workdir or (os.path.dirname(os.path.abspath(args.report)) or ".")
    os.makedirs(workdir, exist_ok=True)
    # The final os.replace onto args.report is atomic only within one filesystem;
    # across devices it raises OSError(EXDEV, "Invalid cross-device link"). When
    # --workdir is a runner temp dir on a different mount from the artifact-staging
    # directory the report lives in, the merged file MUST be staged in the report's
    # own directory, not in workdir. Re-run scratch (which is never renamed across
    # dirs) can stay in workdir.
    report_dir = os.path.dirname(os.path.abspath(args.report)) or "."
    rerun_json = os.path.join(workdir, "recover_rerun.json")
    merged_json = os.path.join(report_dir, ".recover_merged.json")
    rerun_args = os.path.join(workdir, "recover_rerun_args.txt")

    for p in range(1, args.max_passes + 1):
        failing = report_failure_ids(args.report, args.strip_prefix)
        missing = _unrecorded()
        n = len(failing)
        print(f"re-run pass {p}: {n} failing, {len(missing)} unrecorded "
              f"before this pass", flush=True)
        if n == 0 and not missing:
            break
        if n > args.transient_limit:
            print(f"too many failures ({n} > {args.transient_limit}) to treat as "
                  f"transient; leaving them for the gate.", flush=True)
            break
        if len(missing) > missing_limit:
            print(f"too many unrecorded tests ({len(missing)} > {missing_limit}) "
                  f"to treat as a recoverable worker-loss tail; leaving them for "
                  f"the gate.", flush=True)
            break
        ids = sorted(set(failing) | set(missing))
        n = len(ids)
        with open(rerun_args, "w", encoding="utf-8") as f:
            f.write("\n".join(args.prefix + i for i in ids) + "\n")
        print(f"re-running {n} test(s) sequentially after letting the engine settle...",
              flush=True)
        time.sleep(args.settle_seconds)
        try:
            os.remove(rerun_json)
        except OSError:
            pass
        subprocess.call(rerun_cmd + ["--json-report",
                                     f"--json-report-file={rerun_json}",
                                     "@" + rerun_args])
        rerun_reports = [rerun_json] if os.path.exists(rerun_json) else []
        if not rerun_reports:
            # The batch died without writing a report — usually a --timeout kill,
            # since pytest-timeout's `thread` method takes the interpreter down
            # with os._exit before json-report writes. Batched, one hang costs
            # EVERY test in the set its recovery (a full-suite run scored 21 crash
            # victims as residual after a single test hung for 600s). Re-run one
            # process per test so a hang costs only the test that hung; callers
            # also pass --timeout-method=signal to make the common case
            # recoverable in-process.
            print("re-run produced no report (batch aborted); "
                  "falling back to one process per test.", flush=True)
            rerun_reports = _rerun_isolated(rerun_cmd, ids, args.prefix, workdir)
        if not rerun_reports:
            print("re-run produced no report; stopping.", flush=True)
            break
        try:
            merged = merge_reports(args.report, rerun_reports)
            with open(merged_json, "w") as f:
                json.dump(merged, f)
            os.replace(merged_json, args.report)
            print(f"merged re-run pass {p}.", flush=True)
        except Exception as e:  # defensive: a bad merge stops recovery, gate on what we have
            print(f"merge failed ({e}); stopping re-run recovery.", flush=True)
            break

    # Gate on the merged report; fail CLOSED if it is unreadable. A test still
    # unrecorded after recovery is a gate failure too: green must mean "every
    # assigned test has an outcome", not "nothing recorded failed".
    try:
        residual = report_failure_ids(args.report, args.strip_prefix)
        still_missing = _unrecorded()
    except Exception as e:
        ci_error(f"recover-and-gate could not evaluate "
                 f"the merged report ({e}) — failing the gate.", flush=True)
        return 1
    residual_all = residual + [i for i in still_missing if i not in set(residual)]
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write("\n".join(residual_all) + ("\n" if residual_all else ""))
    print(f"gate failures after re-run recovery: {len(residual)} failed/error, "
          f"{len(still_missing)} unrecorded", flush=True)
    if residual_all:
        ci_error(f"{len(residual)} residual "
                 f"failure(s)/XPASS(strict) and {len(still_missing)} assigned "
                 f"test(s) with no recorded outcome. First 50:", flush=True)
        for r in residual_all[:50]:
            print(r, flush=True)
        return 1
    print("gate PASS: no unexpected failures after re-run recovery.", flush=True)
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="DocumentDB Functional Test Gate Tooling (known-failures xfail model)")
    parser.add_argument("--image", default="documentdb-local/functional-tests/config/image.yml",
                        help="Path to image.yml (used by compare-engines)")

    subparsers = parser.add_subparsers(dest="command", required=True)

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
                                   "split-combine merge) instead of preserving the base's "
                                   "(default: preserve, for re-run merges)")

    # verify-split-universes: cross-leg guard for split-collection. Each leg
    # writes a universe.txt beside its results; this asserts they agree.
    verify_uni_parser = subparsers.add_parser(
        "verify-split-universes",
        help="Fail unless every parallel test-split collected an identical "
             "universe (guards the stride slice against cross-leg manifest skew)")
    verify_uni_parser.add_argument("--dir", action="append", default=[],
                                   help="Directory tree to search for universe.txt (repeatable)")
    verify_uni_parser.add_argument("--universe", action="append", default=[],
                                   help="Explicit path to a universe.txt (repeatable)")
    verify_uni_parser.add_argument("--expected-splits", type=int, required=True,
                                   help="How many parallel splits must have reported")
    verify_uni_parser.add_argument("--artifact-prefix", default="",
                                   help="Only accept records whose containing directory (the "
                                        "downloaded artifact name) starts with this, so a second "
                                        "instance of the stage cannot contribute its own records")

    # split-collection: splits a pytest collection manifest (the full suite)
    # across parallel CI jobs.
    split_coll_parser = subparsers.add_parser(
        "split-collection",
        help="Print the collected test node IDs for one test-split (round-robin split of a "
             "collection manifest across parallel CI jobs)")
    split_coll_parser.add_argument("--manifest", required=True,
                                   help="Path to a collection manifest (pytest --collect-only -q output)")
    split_coll_parser.add_argument("--num-splits", type=int, required=True, help="Total number of test-splits")
    split_coll_parser.add_argument("--split-id", type=int, required=True,
                                   help="This split's index [0, num-splits)")
    split_coll_parser.add_argument("--prefix", default="",
                                   help="String prepended to each node ID (e.g. 'docdb_functional_tests/documentdb_tests/')")
    split_coll_parser.add_argument("--strip-prefix", default="",
                                   help="Prefix stripped from each manifest node ID before splitting "
                                        "(pass the same value as --prefix to make prefixing idempotent)")
    split_coll_parser.add_argument("--output", default="",
                                   help="Write node IDs (one per line) to this file instead of stdout")

    # report-failures: node IDs with a failed/error outcome (re-run + gate set)
    report_fail_parser = subparsers.add_parser(
        "report-failures",
        help="Print node IDs that failed/errored in a JSON report (re-run set; any residual = gate fail)")
    report_fail_parser.add_argument("--report", required=True, help="Path to pytest JSON report")
    report_fail_parser.add_argument("--strip-prefix", default="",
                                    help="Prefix stripped from each node ID before output")
    report_fail_parser.add_argument("--output", default="",
                                    help="Write node IDs (one per line) to this file instead of stdout")

    # reconcile: fold a gate run's outcomes back into a known-failures list
    reconcile_parser = subparsers.add_parser(
        "reconcile",
        help="Update a known-failures list from a (merged) JSON report: add new "
             "failures, drop XPASS(strict) entries (used after a source_sha bump)")
    reconcile_parser.add_argument("--report", required=True,
                                  help="Path to the merged pytest JSON report of a gate run")
    reconcile_parser.add_argument("--failing", required=True,
                                  help="Path to the known-failures list to reconcile")
    reconcile_parser.add_argument("--flaky", default="",
                                  help="Path to the flaky list (new failures already on it are "
                                       "skipped so the plugin's overlap check cannot throw)")
    reconcile_parser.add_argument("--out", default="",
                                  help="Write the updated list here (default: rewrite --failing in place)")
    reconcile_parser.add_argument("--prune-uncollected", action="store_true",
                                  help="Also drop list entries whose test no longer exists in the "
                                       "report (only safe when reconciling from a FULL-suite run)")
    reconcile_parser.add_argument("--summary-json", default="",
                                  help="Also write a machine-readable classification (added/removed/"
                                       "kept_errored/skipped_flaky/changed/clean) here for the "
                                       "auto-reconcile bot")

    # recover-and-gate: sequential re-run recovery of transient crash victims,
    # then gate on the merged report. Shared by the single-job lane and the
    # split matrix lane. The pytest re-run command follows '--'.
    recover_parser = subparsers.add_parser(
        "recover-and-gate",
        help="Sequentially re-run the still-failing set (transient crash victims) "
             "and gate on the merged report; exit 1 on any residual. Pass the "
             "pytest re-run command after '--'.")
    recover_parser.add_argument("--report", required=True,
                                help="Path to the base pytest JSON report (merged in place)")
    recover_parser.add_argument("--strip-prefix", default="",
                                help="Prefix stripped from node IDs when reading failures")
    recover_parser.add_argument("--prefix", default="",
                                help="Prefix re-added to failing node IDs for the re-run args")
    recover_parser.add_argument("--max-passes", type=int, default=3,
                                help="Max sequential re-run passes (default 3)")
    recover_parser.add_argument("--transient-limit", type=int, default=400,
                                help="Above this many failures, treat as a real breakage and stop (default 400)")
    recover_parser.add_argument("--expected-ids", default="",
                                help="File of node IDs assigned to this run (slice file or "
                                     "collection manifest; noise lines are ignored). When given, "
                                     "assigned tests with NO recorded outcome (an xdist worker "
                                     "death loses part of its queue) are also re-run, and any "
                                     "still-unrecorded test fails the gate.")
    recover_parser.add_argument("--missing-limit", type=int, default=1500,
                                help="Above this many unrecorded tests, treat as a systemic "
                                     "collapse and leave them for the gate instead of grinding "
                                     "through a serial re-run (default 1500; worst observed "
                                     "worker-death loss was 1,175 of 12,094 on one leg)")
    recover_parser.add_argument("--settle-seconds", type=int, default=20,
                                help="Sleep before each re-run to let the engine settle (default 20)")
    recover_parser.add_argument("--workdir", default="",
                                help="Directory for temp re-run/merged reports (default: the report's dir)")
    recover_parser.add_argument("--output", default="",
                                help="Write residual node IDs (one per line) to this file")
    recover_parser.add_argument("rerun_cmd", nargs=argparse.REMAINDER,
                                help="After '--': the pytest command to re-run the failing set")

    args = parser.parse_args()

    if args.command == "compare-engines":
        return cmd_compare_engines(args)
    elif args.command == "merge-reports":
        return cmd_merge_reports(args)
    elif args.command == "verify-split-universes":
        return cmd_verify_split_universes(args)
    elif args.command == "split-collection":
        return cmd_split_collection(args)
    elif args.command == "report-failures":
        return cmd_report_failures(args)
    elif args.command == "reconcile":
        return cmd_reconcile(args)
    elif args.command == "recover-and-gate":
        return cmd_recover_and_gate(args)
    # Fail LOUD on an unrecognized command. Without this the chain falls through,
    # main() returns None, and sys.exit(None) exits 0 — so a subcommand renamed in
    # add_parser() but not here would silently no-op and score the caller green.
    parser.error(f"unhandled command {args.command!r} (dispatch and subparser are "
                 f"out of sync — this is a bug in functional_gate.py)")


if __name__ == "__main__":
    sys.exit(main())
