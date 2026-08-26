"""Tests for `reconcile --summary-json` — the machine-readable classification
the auto-reconcile bot uses to decide clean XPASS-drift (safe to PR) vs a red
that needs a human (new failures / errors / flaky overlap)."""

import json
import os
import subprocess
import sys

HERE = os.path.dirname(__file__)
TOOL = os.path.join(HERE, "..", "tools", "functional_gate.py")
PREFIX = "docdb_functional_tests/documentdb_tests/"


def _report(tmp_path, tests):
    p = tmp_path / "report.json"
    p.write_text(json.dumps({"tests": [
        {"nodeid": nid, "outcome": oc, "call": {"longrepr": detail}}
        for nid, oc, detail in tests]}))
    return str(p)


def _list(tmp_path, name, lines):
    p = tmp_path / name
    p.write_text("\n".join(lines) + "\n")
    return str(p)


def _run(report, failing, flaky, tmp_path):
    out = str(tmp_path / "summary.json")
    subprocess.run([sys.executable, TOOL, "reconcile", "--report", report,
                    "--failing", failing, "--flaky", flaky,
                    "--prune-uncollected", "--out", str(tmp_path / "new.txt"),
                    "--summary-json", out], check=True,
                   capture_output=True, text=True)
    return json.load(open(out))


class TestReconcileSummary:
    def test_xpass_only_is_clean_and_changed(self, tmp_path):
        # A listed expected-failure that now passes => 'failed' with XPASS repr.
        report = _report(tmp_path, [
            (PREFIX + "a.py::t_listed", "failed", "[XPASS(strict)] ..."),
        ])
        failing = _list(tmp_path, "failing.txt", [PREFIX + "a.py::t_listed"])
        flaky = _list(tmp_path, "flaky.txt", ["# none"])
        s = _run(report, failing, flaky, tmp_path)
        assert s["clean"] is True
        assert s["changed"] is True
        assert s["removed"] == ["a.py::t_listed"]
        assert s["added"] == []

    def test_new_failure_is_not_clean(self, tmp_path):
        report = _report(tmp_path, [
            (PREFIX + "b.py::t_new", "failed", "AssertionError"),
        ])
        failing = _list(tmp_path, "failing.txt", ["# none"])
        flaky = _list(tmp_path, "flaky.txt", ["# none"])
        s = _run(report, failing, flaky, tmp_path)
        assert s["clean"] is False          # a human must triage a new failure
        assert s["added"] == ["b.py::t_new"]

    def test_listed_but_errored_is_not_clean(self, tmp_path):
        # A listed test that ERRORs (setup error, not an XPASS) is kept + flagged.
        report = _report(tmp_path, [
            (PREFIX + "c.py::t_listed", "error", "ConnectionError in setup"),
        ])
        failing = _list(tmp_path, "failing.txt", [PREFIX + "c.py::t_listed"])
        flaky = _list(tmp_path, "flaky.txt", ["# none"])
        s = _run(report, failing, flaky, tmp_path)
        assert s["clean"] is False
        assert s["kept_errored"] == ["c.py::t_listed"]

    def test_all_green_is_clean_but_unchanged(self, tmp_path):
        report = _report(tmp_path, [(PREFIX + "d.py::t", "passed", "")])
        failing = _list(tmp_path, "failing.txt", ["# none"])
        flaky = _list(tmp_path, "flaky.txt", ["# none"])
        s = _run(report, failing, flaky, tmp_path)
        assert s["clean"] is True
        assert s["changed"] is False        # nothing to PR

    def test_uncollected_entry_is_not_clean(self, tmp_path):
        # A listed test the run did not collect (deleted/renamed upstream) is a
        # suite-composition change beyond XPASS drift — the bot must defer to a
        # human even though --prune-uncollected would remove it. The report has
        # an XPASS drop but also a listed test that is absent from the report.
        report = _report(tmp_path, [
            (PREFIX + "a.py::t_listed", "failed", "[XPASS(strict)]"),
        ])
        failing = _list(tmp_path, "failing.txt", [
            PREFIX + "a.py::t_listed",
            PREFIX + "gone.py::t_deleted",   # not in the report -> uncollected
        ])
        flaky = _list(tmp_path, "flaky.txt", ["# none"])
        s = _run(report, failing, flaky, tmp_path)
        assert "gone.py::t_deleted" in "\n".join(s["uncollected"])
        assert s["clean"] is False
