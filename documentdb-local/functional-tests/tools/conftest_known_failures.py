"""
Pytest plugin that marks known-failing tests as xfail(strict=True)
and flaky tests as xfail(strict=False).

Known failures (ci_failing_tests.txt):
  - If a known-failing test still fails: reported as xfail (OK)
  - If a known-failing test now passes: XPASS(strict) -> BUILD FAILS

Flaky tests (ci_flaky_tests.txt):
  - If a flaky test fails: reported as xfail (OK)
  - If a flaky test passes: XPASS (OK, not strict — does not fail the build)
"""

import os
import pytest

_KNOWN_FAILURES = set()
_FLAKY_TESTS = set()
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
    """Load known failing and flaky test node IDs."""
    global _KNOWN_FAILURES, _FLAKY_TESTS, _LOADED
    if _LOADED:
        return
    _LOADED = True

    script_dir = os.path.dirname(os.path.abspath(__file__))
    _KNOWN_FAILURES.update(_load_test_list(os.path.join(script_dir, "ci_failing_tests.txt")))
    _FLAKY_TESTS.update(_load_test_list(os.path.join(script_dir, "ci_flaky_tests.txt")))

    overlap = _KNOWN_FAILURES & _FLAKY_TESTS
    if overlap:
        raise ValueError(
            "Tests must not appear in both ci_failing_tests.txt and ci_flaky_tests.txt. "
            f"Found in both: {sorted(overlap)}"
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


def pytest_collection_modifyitems(config, items):
    """Mark known-failing tests as xfail(strict=True) and flaky tests as xfail(strict=False)."""
    _load_known_failures()
    if not _KNOWN_FAILURES and not _FLAKY_TESTS:
        return

    rootdir = str(config.rootdir)
    failure_set = _build_suffix_set(_KNOWN_FAILURES, rootdir)
    flaky_set = _build_suffix_set(_FLAKY_TESTS, rootdir)

    xfail_strict = pytest.mark.xfail(
        reason="Known failure (ci_failing_tests.txt)",
        strict=True,
    )
    xfail_flaky = pytest.mark.xfail(
        reason="Flaky test (ci_flaky_tests.txt)",
        strict=False,
    )

    for item in items:
        if item.nodeid in failure_set:
            item.add_marker(xfail_strict)
        elif item.nodeid in flaky_set:
            item.add_marker(xfail_flaky)
