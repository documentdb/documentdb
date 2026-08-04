"""
Pytest plugin that marks known-failing tests as xfail(strict=True)
and flaky tests as xfail(strict=False).

Known failures (ci_failing_tests.txt):
  - If a known-failing test still fails: reported as xfail (OK)
  - If a known-failing test now passes: XPASS(strict) -> BUILD FAILS

Flaky tests (ci_flaky_tests.txt):
  - If a flaky test fails: reported as xfail (OK)
  - If a flaky test passes: XPASS (OK, not strict — does not fail the build)

Engine-crasher tests (ci_crash_tests.txt):
  - Marked skip: NEVER EXECUTED. xfail is not enough for these — an xfailed test
    still runs, and these tests crash the backend (SIGSEGV/SIGABRT), restarting
    the whole cluster and cascading connection errors onto every concurrent
    test. Worse, a crasher can itself score GREEN (pymongo retryable reads
    re-send the command after the crash and the retry succeeds, or the xfail
    mark absorbs its own connection error), so the only visible damage is other
    tests failing "randomly". Skip is the only mark that prevents the crash.
    Entries carry the engine bug context in ci_crash_tests.txt comments and
    must come back out when the engine bug is fixed.
  - Entry forms: an exact node ID; a file path (ends in '.py'); or a directory
    prefix (ends in '/'). Prefix forms exist so the list survives suite pin
    bumps — a renamed or newly added case under a crashing feature's directory
    is auto-covered instead of silently running and crashing. Prefixes are
    crash-list-only ON PURPOSE: a prefix xfail would fail OPEN (absorbing any
    new failure under the whole directory), while a prefix skip fails CLOSED.
  - A failing/flaky entry shadowed by a crash prefix stays in its list: it is
    simply never consulted while the skip exists, and removing the prefix after
    the engine fix restores the exact xfail baseline with no regeneration.
"""

import os
import pytest

_KNOWN_FAILURES = set()
_FLAKY_TESTS = set()
_CRASH_TESTS = set()
_LOADED = False


def _load_test_list(filepath):
    """Load test node IDs from a file (one per line, # comments allowed)."""
    entries = set()
    if not os.path.exists(filepath):
        return entries
    with open(filepath, "r") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                entries.add(line)
    return entries


def _load_known_failures():
    """Load known failing, flaky, and engine-crasher test node IDs."""
    global _KNOWN_FAILURES, _FLAKY_TESTS, _CRASH_TESTS, _LOADED
    if _LOADED:
        return
    _LOADED = True

    script_dir = os.path.dirname(os.path.abspath(__file__))
    _KNOWN_FAILURES.update(_load_test_list(os.path.join(script_dir, "ci_failing_tests.txt")))
    _FLAKY_TESTS.update(_load_test_list(os.path.join(script_dir, "ci_flaky_tests.txt")))
    _CRASH_TESTS.update(_load_test_list(os.path.join(script_dir, "ci_crash_tests.txt")))

    overlap = _KNOWN_FAILURES & _FLAKY_TESTS
    if overlap:
        raise ValueError(
            "Tests must not appear in both ci_failing_tests.txt and ci_flaky_tests.txt. "
            f"Found in both: {sorted(overlap)}"
        )
    # An EXACT crasher node ID must be MOVED into ci_crash_tests.txt, not
    # duplicated. (Entries merely *covered by* a crash prefix are fine and stay
    # in their lists — see module docstring — so this checks string equality,
    # not prefix coverage.)
    crash_overlap = _CRASH_TESTS & (_KNOWN_FAILURES | _FLAKY_TESTS)
    if crash_overlap:
        raise ValueError(
            "Tests in ci_crash_tests.txt must not also appear in "
            "ci_failing_tests.txt or ci_flaky_tests.txt. "
            f"Found in both: {sorted(crash_overlap)}"
        )


def _build_suffix_set(entries, rootdir):
    """Build a lookup set with both full and rootdir-relative forms."""
    suffix_set = set()
    rootdir_name = os.path.basename(rootdir)
    for entry in entries:
        suffix_set.add(entry)
        parts = entry.split("/")
        if rootdir_name in parts:
            idx = len(parts) - 1 - parts[::-1].index(rootdir_name)
            suffix_set.add("/".join(parts[idx + 1:]))
    return suffix_set


def _build_prefix_tuple(entries, rootdir):
    """Build a startswith() tuple for path-prefix entries (crash list only).

    Directory entries (ending '/') match as-is; file entries (ending '.py')
    match '<file>::' so 'a/test_x.py' cannot match 'a/test_xy.py' node IDs.
    Like _build_suffix_set, each prefix is added in both its full and
    rootdir-relative form so the same list works whether pytest reports node
    IDs bare ('compatibility/tests/...') or repo-prefixed.
    """
    prefixes = set()
    rootdir_name = os.path.basename(rootdir)
    for entry in entries:
        if entry.endswith(".py"):
            entry = entry + "::"
        prefixes.add(entry)
        parts = entry.split("/")
        if rootdir_name in parts:
            idx = len(parts) - 1 - parts[::-1].index(rootdir_name)
            prefixes.add("/".join(parts[idx + 1:]))
    return tuple(sorted(prefixes))


def pytest_collection_modifyitems(config, items):
    """Mark known-failing tests as xfail(strict=True), flaky tests as
    xfail(strict=False), and engine-crasher tests as skip (never run)."""
    _load_known_failures()
    if not _KNOWN_FAILURES and not _FLAKY_TESTS and not _CRASH_TESTS:
        return

    rootdir = str(config.rootdir)
    failure_set = _build_suffix_set(_KNOWN_FAILURES, rootdir)
    flaky_set = _build_suffix_set(_FLAKY_TESTS, rootdir)
    crash_prefix_entries = {e for e in _CRASH_TESTS
                            if e.endswith("/") or e.endswith(".py")}
    crash_set = _build_suffix_set(_CRASH_TESTS - crash_prefix_entries, rootdir)
    crash_prefixes = _build_prefix_tuple(crash_prefix_entries, rootdir)

    xfail_strict = pytest.mark.xfail(
        reason="Known failure (ci_failing_tests.txt)",
        strict=True,
    )
    xfail_flaky = pytest.mark.xfail(
        reason="Flaky test (ci_flaky_tests.txt)",
        strict=False,
    )
    skip_crash = pytest.mark.skip(
        reason="Known engine-crasher (ci_crash_tests.txt): crashes the backend "
               "and cascades onto concurrent tests; suppressed until the engine "
               "bug is fixed",
    )

    for item in items:
        # Crash skip wins: running the test at all is what must be prevented.
        # (str.startswith on an empty tuple is False, so no prefixes = no-op.)
        if item.nodeid in crash_set or item.nodeid.startswith(crash_prefixes):
            item.add_marker(skip_crash)
        elif item.nodeid in failure_set:
            item.add_marker(xfail_strict)
        elif item.nodeid in flaky_set:
            item.add_marker(xfail_flaky)
