"""Tests for functional_gate.py report-failures — the node IDs whose outcome is
failed/error in a (merged) JSON report, used for both the sequential re-run set
and the final gate verdict."""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))

from functional_gate import report_failure_ids  # noqa: E402

PREFIX = "docdb_functional_tests/documentdb_tests/"


def _write_report(tmp_path, tests):
    path = tmp_path / "report.json"
    payload = {"tests": [{"nodeid": nid, "outcome": outcome} for nid, outcome in tests]}
    path.write_text(json.dumps(payload))
    return str(path)


class TestReportFailureIds:
    def test_only_failed_and_error_reported(self, tmp_path):
        report = _write_report(tmp_path, [
            (PREFIX + "a.py::t_fail", "failed"),
            (PREFIX + "b.py::t_err", "error"),
            (PREFIX + "c.py::t_pass", "passed"),
            (PREFIX + "d.py::t_xfail", "xfailed"),
            (PREFIX + "e.py::t_xpass", "xpassed"),
        ])
        assert report_failure_ids(report, strip_prefix=PREFIX) == \
            ["a.py::t_fail", "b.py::t_err"]

    def test_strip_prefix_applied(self, tmp_path):
        report = _write_report(tmp_path, [(PREFIX + "a.py::t", "failed")])
        assert report_failure_ids(report, strip_prefix=PREFIX) == ["a.py::t"]
        assert report_failure_ids(report) == [PREFIX + "a.py::t"]

    def test_deduplicated_preserving_order(self, tmp_path):
        report = _write_report(tmp_path, [
            (PREFIX + "a.py::t1", "failed"),
            (PREFIX + "b.py::t2", "failed"),
            (PREFIX + "a.py::t1", "failed"),
        ])
        assert report_failure_ids(report, strip_prefix=PREFIX) == \
            ["a.py::t1", "b.py::t2"]

    def test_empty_report_is_empty(self, tmp_path):
        report = _write_report(tmp_path, [])
        assert report_failure_ids(report, strip_prefix=PREFIX) == []
