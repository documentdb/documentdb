"""Tests for functional_gate.py reconcile — folding a gate run's outcomes back
into a known-failures list (the source_sha-bump maintenance operation)."""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))

from functional_gate import _normalize_node_id, reconcile_failing_list  # noqa: E402

PREFIX = "docdb_functional_tests/documentdb_tests/"


def _write_report(tmp_path, tests):
    path = tmp_path / "report.json"
    payload = {"tests": [
        {"nodeid": nid, "outcome": outcome,
         "call": {"longrepr": detail}}
        for nid, outcome, detail in tests
    ]}
    path.write_text(json.dumps(payload))
    return str(path)


def _write_list(tmp_path, name, lines):
    path = tmp_path / name
    path.write_text("\n".join(lines) + "\n")
    return str(path)


class TestNormalizeNodeId:
    def test_prefixed_entry_normalizes_to_rootdir_relative(self):
        assert _normalize_node_id(PREFIX + "compatibility/tests/a.py::t") == \
            "compatibility/tests/a.py::t"

    def test_bare_entry_unchanged(self):
        assert _normalize_node_id("compatibility/tests/a.py::t") == \
            "compatibility/tests/a.py::t"


class TestReconcile:
    def test_new_failure_is_added(self, tmp_path):
        report = _write_report(tmp_path, [
            ("compatibility/tests/new.py::t_new", "failed", "AssertionError"),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            "# header comment",
            "compatibility/tests/old.py::t_old",
        ])
        result = reconcile_failing_list(report, failing)
        assert result["added"] == ["compatibility/tests/new.py::t_new"]
        assert result["removed"] == []
        assert "compatibility/tests/new.py::t_new" in result["lines"]
        assert "# header comment" in result["lines"]

    def test_xpass_strict_entry_is_removed(self, tmp_path):
        # A listed test that now passes is reported by pytest as 'failed'
        # with an XPASS(strict) repr under the strict-xfail plugin.
        report = _write_report(tmp_path, [
            ("compatibility/tests/fixed.py::t_fixed", "failed", "[XPASS(strict)] Known failure"),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            "compatibility/tests/fixed.py::t_fixed",
        ])
        result = reconcile_failing_list(report, failing)
        assert result["removed"] == ["compatibility/tests/fixed.py::t_fixed"]
        assert "compatibility/tests/fixed.py::t_fixed" not in result["lines"]

    def test_still_failing_listed_entry_is_kept(self, tmp_path):
        # Still-failing listed tests come back as 'xfailed' — untouched.
        report = _write_report(tmp_path, [
            ("compatibility/tests/known.py::t_known", "xfailed", ""),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            "compatibility/tests/known.py::t_known",
        ])
        result = reconcile_failing_list(report, failing)
        assert result["added"] == [] and result["removed"] == []
        assert "compatibility/tests/known.py::t_known" in result["lines"]

    def test_prefixed_list_matches_bare_report_ids(self, tmp_path):
        # Backend-gate style lists carry the repo prefix; report node IDs are
        # rootdir-relative. They must compare equal.
        report = _write_report(tmp_path, [
            ("compatibility/tests/fixed.py::t", "failed", "[XPASS(strict)]"),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            PREFIX + "compatibility/tests/fixed.py::t",
        ])
        result = reconcile_failing_list(report, failing)
        assert result["removed"] == ["compatibility/tests/fixed.py::t"]
        assert all("fixed.py" not in l for l in result["lines"])

    def test_additions_follow_dominant_prefixed_style(self, tmp_path):
        report = _write_report(tmp_path, [
            ("compatibility/tests/new.py::t_new", "failed", "boom"),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            PREFIX + "compatibility/tests/a.py::t1",
            PREFIX + "compatibility/tests/b.py::t2",
        ])
        result = reconcile_failing_list(report, failing)
        assert PREFIX + "compatibility/tests/new.py::t_new" in result["lines"]

    def test_flaky_listed_failure_is_skipped_not_added(self, tmp_path):
        # Adding it would trip the plugin's failing/flaky overlap ValueError.
        report = _write_report(tmp_path, [
            ("compatibility/tests/f.py::t_flaky", "failed", "boom"),
        ])
        failing = _write_list(tmp_path, "failing.txt", ["# empty"])
        flaky = _write_list(tmp_path, "flaky.txt", [
            "compatibility/tests/f.py::t_flaky",
        ])
        result = reconcile_failing_list(report, failing, flaky)
        assert result["added"] == []
        assert result["skipped_flaky"] == ["compatibility/tests/f.py::t_flaky"]

    def test_listed_setup_error_is_kept_for_inspection(self, tmp_path):
        # xfail does not cover setup errors: a listed test that ERRORS is not
        # an XPASS and must not be dropped from the list silently.
        report = _write_report(tmp_path, [
            ("compatibility/tests/e.py::t_err", "error", "fixture blew up"),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            "compatibility/tests/e.py::t_err",
        ])
        result = reconcile_failing_list(report, failing)
        assert result["removed"] == []
        assert result["kept_errored"] == ["compatibility/tests/e.py::t_err"]
        assert "compatibility/tests/e.py::t_err" in result["lines"]

    def test_uncollected_entry_reported_but_kept_by_default(self, tmp_path):
        report = _write_report(tmp_path, [
            ("compatibility/tests/present.py::t", "passed", ""),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            "compatibility/tests/gone.py::t_gone",
        ])
        result = reconcile_failing_list(report, failing)
        assert result["uncollected"] == ["compatibility/tests/gone.py::t_gone"]
        assert result["pruned"] == []
        assert "compatibility/tests/gone.py::t_gone" in result["lines"]

    def test_uncollected_entry_pruned_when_requested(self, tmp_path):
        report = _write_report(tmp_path, [
            ("compatibility/tests/present.py::t", "passed", ""),
        ])
        failing = _write_list(tmp_path, "failing.txt", [
            "compatibility/tests/gone.py::t_gone",
        ])
        result = reconcile_failing_list(report, failing, prune_uncollected=True)
        assert result["pruned"] == ["compatibility/tests/gone.py::t_gone"]
        assert "compatibility/tests/gone.py::t_gone" not in result["lines"]

    def test_flaky_pass_is_reported_as_pruning_candidate(self, tmp_path):
        report = _write_report(tmp_path, [
            ("compatibility/tests/f.py::t_flaky", "xpassed", ""),
        ])
        failing = _write_list(tmp_path, "failing.txt", ["# empty"])
        flaky = _write_list(tmp_path, "flaky.txt", [
            "compatibility/tests/f.py::t_flaky",
        ])
        result = reconcile_failing_list(report, failing, flaky)
        assert result["flaky_passes"] == ["compatibility/tests/f.py::t_flaky"]
