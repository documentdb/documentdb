"""Tests for the non-gate functional_gate.py helpers that survive the
known-failures model: derive_area + compare_engines (reference-comparison lane)
and merge_reports (re-run / shard-combine folding)."""

import json
import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).parent.parent / "tools"))
from functional_gate import (  # noqa: E402
    cmd_compare_engines,
    compare_engines,
    render_comparison_markdown,
    derive_area,
    merge_reports,
)


@pytest.fixture
def valid_image(tmp_path):
    path = tmp_path / "image.yml"
    path.write_text(yaml.dump({
        "schema_version": 1,
        "image": "ghcr.io/test/image@sha256:abc123",
        "source_ref": "test/repo@main",
        "source_sha": "deadbeef",
    }))
    return str(path)


def make_pytest_report(tmp_path, tests, summary=None, filename="report.json"):
    report = {"tests": tests, "summary": summary or {"total": len(tests), "deselected": 0}}
    path = tmp_path / filename
    path.write_text(json.dumps(report))
    return str(path)


class TestDeriveArea:
    def test_known_areas(self):
        assert derive_area("tests/commands/find/test_find.py::test_x") == "find"
        assert derive_area("tests/commands/insert/test_insert.py::test_x") == "insert"
        assert derive_area("tests/commands/update/test_update.py::test_x") == "update"
        assert derive_area("tests/commands/delete/test_delete.py::test_x") == "delete"
        assert derive_area("tests/aggregate/test_agg.py::test_x") == "aggregate"
        assert derive_area("tests/collections/test_coll.py::test_x") == "collection_mgmt"

    def test_unknown_area(self):
        assert derive_area("tests/something/weird/test_x.py::test_y") == "unknown"

    def test_unknown_does_not_block(self):
        assert derive_area("totally/unknown/path.py::test_z") == "unknown"


class TestCompareEngines:
    def test_classification_buckets(self, tmp_path, valid_image):
        report_a = make_pytest_report(tmp_path, [
            {"nodeid": "tests/commands/find/test_a.py::both_pass", "outcome": "passed"},
            {"nodeid": "tests/commands/find/test_a.py::both_fail", "outcome": "failed"},
            {"nodeid": "tests/commands/find/test_a.py::a_only_pass", "outcome": "passed"},
            {"nodeid": "tests/commands/find/test_a.py::b_only_pass", "outcome": "failed"},
            {"nodeid": "tests/commands/find/test_a.py::both_skip", "outcome": "skipped"},
            {"nodeid": "tests/commands/find/test_a.py::a_missing", "outcome": "passed"},
        ], filename="a.json")
        report_b = make_pytest_report(tmp_path, [
            {"nodeid": "tests/commands/find/test_a.py::both_pass", "outcome": "passed"},
            {"nodeid": "tests/commands/find/test_a.py::both_fail", "outcome": "failed"},
            {"nodeid": "tests/commands/find/test_a.py::a_only_pass", "outcome": "failed"},
            {"nodeid": "tests/commands/find/test_a.py::b_only_pass", "outcome": "passed"},
            {"nodeid": "tests/commands/find/test_a.py::both_skip", "outcome": "skipped"},
            {"nodeid": "tests/commands/find/test_a.py::b_only_test", "outcome": "passed"},
        ], filename="b.json")

        result = compare_engines(report_a, report_b, "engineA", "engineB", valid_image)
        assert len(result["both_pass"]) == 1
        assert len(result["both_fail"]) == 1
        assert len(result["a_only_pass"]) == 1
        assert len(result["b_only_pass"]) == 1
        assert len(result["both_skip"]) == 1
        assert len(result["other"]) == 2
        assert result["summary"]["engineA"]["missing"] == 1
        assert result["summary"]["engineB"]["missing"] == 1

    def test_render_comparison_markdown_highlights_gaps(self, tmp_path, valid_image):
        report_a = make_pytest_report(tmp_path, [
            {"nodeid": "tests/commands/find/test_x.py::gap_test", "outcome": "failed"},
        ], filename="a.json")
        report_b = make_pytest_report(tmp_path, [
            {"nodeid": "tests/commands/find/test_x.py::gap_test", "outcome": "passed"},
        ], filename="b.json")

        result = compare_engines(report_a, report_b, "pgmongo", "reference", valid_image)
        md = render_comparison_markdown(result)
        assert "pgmongo vs reference" in md
        assert "Compatibility Gaps" in md
        assert "gap_test" in md

    def test_cmd_compare_engines_writes_artifacts(self, tmp_path, valid_image):
        report_a = make_pytest_report(tmp_path, [
            {"nodeid": "tests/commands/find/test_x.py::t1", "outcome": "passed"},
        ], filename="a.json")
        report_b = make_pytest_report(tmp_path, [
            {"nodeid": "tests/commands/find/test_x.py::t1", "outcome": "passed"},
        ], filename="b.json")
        output_dir = tmp_path / "out"
        args = type("Args", (), {
            "report_a": report_a, "report_b": report_b,
            "engine_a": "pgmongo", "engine_b": "documentdb",
            "image": valid_image, "output_dir": str(output_dir),
        })()

        assert cmd_compare_engines(args) == 0
        assert (output_dir / "comparison-summary.md").exists()
        data = json.loads((output_dir / "comparison-summary.json").read_text())
        assert data["engine_a"] == "pgmongo"
        assert data["total_compared"] == 1


class TestMergeReports:
    """merge_reports folds re-run outcomes into the base report (overlay wins)."""

    def test_overlay_pass_overrides_base_failure(self, tmp_path):
        base = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::flaky", "outcome": "failed"},
            {"nodeid": "tests/test_a.py::solid", "outcome": "passed"},
        ], summary={"collected": 2, "total": 2, "passed": 1, "failed": 1}, filename="base.json")
        overlay = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::flaky", "outcome": "passed"},
        ], summary={"collected": 1, "total": 1, "passed": 1}, filename="rerun.json")

        merged = merge_reports(base, [overlay])
        outcomes = {t["nodeid"]: t["outcome"] for t in merged["tests"]}
        assert outcomes["tests/test_a.py::flaky"] == "passed"
        assert outcomes["tests/test_a.py::solid"] == "passed"
        assert merged["summary"]["collected"] == 2
        assert merged["summary"]["passed"] == 2
        assert merged["summary"].get("failed", 0) == 0

    def test_overlay_failure_keeps_test_failed(self, tmp_path):
        base = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::broken", "outcome": "failed"},
        ], summary={"collected": 1, "total": 1, "failed": 1}, filename="base.json")
        overlay = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::broken", "outcome": "failed"},
        ], summary={"collected": 1, "total": 1, "failed": 1}, filename="rerun.json")

        merged = merge_reports(base, [overlay])
        outcomes = {t["nodeid"]: t["outcome"] for t in merged["tests"]}
        assert outcomes["tests/test_a.py::broken"] == "failed"

    def test_overlay_can_add_new_test(self, tmp_path):
        base = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::one", "outcome": "passed"},
        ], summary={"collected": 1, "total": 1}, filename="base.json")
        overlay = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::new", "outcome": "passed"},
        ], summary={"collected": 1, "total": 1}, filename="rerun.json")

        merged = merge_reports(base, [overlay])
        ids = {t["nodeid"] for t in merged["tests"]}
        assert ids == {"tests/test_a.py::one", "tests/test_a.py::new"}
        assert merged["summary"]["collected"] == 1

    def test_sum_collected_combines_shard_discovery_counts(self, tmp_path):
        shard0 = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::s0", "outcome": "passed"},
        ], summary={"collected": 2620, "total": 2620}, filename="s0.json")
        shard1 = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_b.py::s1", "outcome": "passed"},
        ], summary={"collected": 2620, "total": 2620}, filename="s1.json")
        shard2 = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_c.py::s2", "outcome": "passed"},
        ], summary={"collected": 2621, "total": 2621}, filename="s2.json")

        default_merge = merge_reports(shard0, [shard1, shard2])
        assert default_merge["summary"]["collected"] == 2620

        summed = merge_reports(shard0, [shard1, shard2], sum_collected=True)
        assert summed["summary"]["collected"] == 2620 + 2620 + 2621
        ids = {t["nodeid"] for t in summed["tests"]}
        assert ids == {"tests/test_a.py::s0", "tests/test_b.py::s1", "tests/test_c.py::s2"}
