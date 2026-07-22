"""
Tests for the clone-on-host default-pass helpers in functional_gate.py:
collection-manifest sharding (shard-collection) and failed/error extraction
(report-failures). Known-failure classification itself is handled in-process by
the conftest_known_failures xfail plugin, so these helpers only shard the suite
and read back genuine failures for the re-run + combine gate.
"""
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent / "tools"))
from functional_gate import (  # noqa: E402
    shard_collection_ids,
    report_failure_ids,
)


def write_report(tmp_path, tests, filename="report.json"):
    report = {"tests": tests, "summary": {"total": len(tests), "collected": len(tests)}}
    p = tmp_path / filename
    p.write_text(json.dumps(report))
    return str(p)


def write_lines(tmp_path, lines, filename="manifest.txt"):
    p = tmp_path / filename
    p.write_text("\n".join(lines) + "\n")
    return str(p)


def _t(nodeid, outcome):
    return {"nodeid": nodeid, "outcome": outcome}


class TestShardCollection:
    def _manifest(self, tmp_path, n, prefix=""):
        lines = [f"{prefix}compatibility/tests/test_{i}.py::test_it" for i in range(n)]
        lines += ["", "12 tests collected in 0.5s", "warning: something"]  # noise
        return write_lines(tmp_path, lines)

    def test_disjoint_and_complete(self, tmp_path):
        m = self._manifest(tmp_path, 12)
        shards = [shard_collection_ids(m, 4, k) for k in range(4)]
        flat = [x for s in shards for x in s]
        assert len(flat) == 12 and len(set(flat)) == 12
        assert set(flat) == {f"compatibility/tests/test_{i}.py::test_it" for i in range(12)}

    def test_even_distribution(self, tmp_path):
        m = self._manifest(tmp_path, 12)
        assert [len(shard_collection_ids(m, 4, k)) for k in range(4)] == [3, 3, 3, 3]

    def test_noise_and_dedup(self, tmp_path):
        m = write_lines(tmp_path, ["a.py::t", "a.py::t", "b.py::t", "12 collected", ""])
        assert sorted(shard_collection_ids(m, 1, 0)) == ["a.py::t", "b.py::t"]

    def test_prefix_idempotent_when_manifest_already_prefixed(self, tmp_path):
        pref = "docdb_functional_tests/documentdb_tests/"
        m = self._manifest(tmp_path, 4, prefix=pref)
        ids = shard_collection_ids(m, 1, 0, prefix=pref, strip_prefix=pref)
        assert all(i.startswith(pref) and i.count(pref) == 1 for i in ids)
        assert len(ids) == 4

    def test_prefix_added_when_manifest_relative(self, tmp_path):
        pref = "docdb_functional_tests/documentdb_tests/"
        m = self._manifest(tmp_path, 4)  # relative (no prefix)
        ids = shard_collection_ids(m, 1, 0, prefix=pref, strip_prefix=pref)
        assert all(i.startswith(pref) and i.count(pref) == 1 for i in ids)

    def test_bad_bounds(self, tmp_path):
        m = self._manifest(tmp_path, 4)
        with pytest.raises(ValueError):
            shard_collection_ids(m, 4, 4)
        with pytest.raises(ValueError):
            shard_collection_ids(m, 0, 0)


class TestReportFailures:
    def test_only_failed_and_error(self, tmp_path):
        rep = write_report(tmp_path, [
            _t("a.py::fail", "failed"),
            _t("a.py::err", "error"),
            _t("a.py::pass", "passed"),
            _t("a.py::xfail", "xfailed"),
            _t("a.py::xpass", "xpassed"),
            _t("a.py::skip", "skipped"),
        ])
        assert report_failure_ids(rep) == ["a.py::fail", "a.py::err"]

    def test_strip_prefix(self, tmp_path):
        pref = "docdb_functional_tests/documentdb_tests/"
        rep = write_report(tmp_path, [_t(pref + "a.py::fail", "failed")])
        assert report_failure_ids(rep, strip_prefix=pref) == ["a.py::fail"]

    def test_dedup_preserves_order(self, tmp_path):
        rep = write_report(tmp_path, [
            _t("a.py::b", "failed"),
            _t("a.py::a", "error"),
            _t("a.py::b", "failed"),
        ])
        assert report_failure_ids(rep) == ["a.py::b", "a.py::a"]

    def test_empty_when_all_pass(self, tmp_path):
        rep = write_report(tmp_path, [_t("a.py::p", "passed"), _t("a.py::x", "xfailed")])
        assert report_failure_ids(rep) == []
