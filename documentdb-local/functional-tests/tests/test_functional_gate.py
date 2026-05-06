"""
Tests for functional_gate.py gate tooling.

Tests config validation, gate summarization, daily delta, and area derivation
using fixture JSON reports.
"""
import json
import os
import sys
from pathlib import Path

import pytest
import yaml

# Add tools dir to path so we can import the module
sys.path.insert(0, str(Path(__file__).parent.parent / "tools"))
from functional_gate import (
    ConfigError,
    cmd_summarize_daily,
    validate_config,
    validate_allowlist_config,
    validate_image_config,
    summarize_gate,
    render_gate_markdown,
    summarize_daily,
    render_daily_markdown,
    derive_area,
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


@pytest.fixture
def valid_allowlist(tmp_path):
    path = tmp_path / "allowlist.yml"
    path.write_text(yaml.dump({
        "schema_version": 1,
        "tests": [
            "tests/test_a.py::test_one",
            "tests/test_a.py::test_two",
            "tests/test_b.py::test_three",
        ],
    }))
    return str(path)


def make_pytest_report(tmp_path, tests, summary=None, filename="report.json"):
    """Create a minimal pytest JSON report fixture."""
    report = {
        "tests": tests,
        "summary": summary or {
            "total": len(tests),
            "deselected": 0,
        },
    }
    path = tmp_path / filename
    path.write_text(json.dumps(report))
    return str(path)


# --- Config validation ---

class TestValidateConfig:
    def test_valid_config_passes(self, valid_image, valid_allowlist):
        errors = validate_config(valid_image, valid_allowlist)
        assert errors == []

    def test_missing_image_fields(self, tmp_path, valid_allowlist):
        path = tmp_path / "image.yml"
        path.write_text(yaml.dump({"image": "ghcr.io/x@sha256:abc"}))
        errors = validate_image_config(str(path))
        subtypes = [e.subtype for e in errors]
        assert "INVALID_SCHEMA" in subtypes

    def test_image_without_digest(self, tmp_path, valid_allowlist):
        path = tmp_path / "image.yml"
        path.write_text(yaml.dump({
            "image": "ghcr.io/test/image:latest",
            "source_ref": "main",
            "source_sha": "abc",
        }))
        errors = validate_image_config(str(path))
        assert any(e.subtype == "INVALID_SCHEMA" and "sha256" in e.message for e in errors)

    def test_duplicate_test_ids(self, tmp_path):
        path = tmp_path / "allowlist.yml"
        path.write_text(yaml.dump({
            "schema_version": 1,
            "tests": ["a::b", "a::b"],
        }))
        errors = validate_allowlist_config(str(path))
        assert any(e.subtype == "DUPLICATE_TEST_ID" for e in errors)

    def test_bad_schema_version(self, tmp_path):
        path = tmp_path / "allowlist.yml"
        path.write_text(yaml.dump({"schema_version": 99, "tests": []}))
        errors = validate_allowlist_config(str(path))
        assert any(e.subtype == "INVALID_SCHEMA" for e in errors)

    def test_missing_tests_field(self, tmp_path):
        path = tmp_path / "allowlist.yml"
        path.write_text(yaml.dump({"schema_version": 1}))
        errors = validate_allowlist_config(str(path))
        assert any(e.subtype == "INVALID_SCHEMA" and "tests" in e.message for e in errors)

    def test_tests_not_a_list(self, tmp_path):
        path = tmp_path / "allowlist.yml"
        path.write_text(yaml.dump({"schema_version": 1, "tests": "not a list"}))
        errors = validate_allowlist_config(str(path))
        assert any(e.subtype == "INVALID_SCHEMA" for e in errors)


# --- Gate summarization ---

class TestSummarizeGate:
    def test_all_pass(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_a.py::test_two", "outcome": "passed"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ], summary={"total": 3, "deselected": 100})
        result = summarize_gate(valid_allowlist, report, valid_image)
        assert result.outcome == "PASS"
        assert result.selected == 3
        assert result.passed == 3
        assert result.failed == 0
        assert result.missing == 0
        assert result.non_pass == 0

    def test_failed_test(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_a.py::test_two", "outcome": "failed"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ])
        result = summarize_gate(valid_allowlist, report, valid_image)
        assert result.outcome == "ALLOWED_TEST_FAILED"
        assert result.failed == 1

    def test_missing_test(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ])
        result = summarize_gate(valid_allowlist, report, valid_image)
        assert result.outcome == "ALLOWLIST_ERROR"
        assert result.missing == 1
        assert any(e["subtype"] == "UNKNOWN_TEST_ID" for e in result.errors)

    def test_skipped_is_non_pass(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_a.py::test_two", "outcome": "skipped"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ])
        result = summarize_gate(valid_allowlist, report, valid_image)
        assert result.outcome == "ALLOWLIST_ERROR"
        assert result.non_pass == 1

    def test_xfail_is_non_pass(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_a.py::test_two", "outcome": "xfail"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ])
        result = summarize_gate(valid_allowlist, report, valid_image)
        assert result.non_pass == 1

    def test_xpass_is_distinct(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_a.py::test_two", "outcome": "xpass"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ])
        result = summarize_gate(valid_allowlist, report, valid_image)
        assert result.non_pass == 1
        assert any(e["subtype"] == "ALLOWLISTED_XPASS" for e in result.errors)

    def test_error_is_non_pass(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_a.py::test_two", "outcome": "error"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ])
        result = summarize_gate(valid_allowlist, report, valid_image)
        assert result.non_pass == 1

    def test_coverage_boundary_fallback(self, tmp_path, valid_image, valid_allowlist):
        """Fallback path when summary.collected is absent."""
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_a.py::test_two", "outcome": "passed"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ], summary={"total": 3, "deselected": 500})
        result = summarize_gate(valid_allowlist, report, valid_image)
        assert result.total_discovered == 503
        assert result.outside_allowlist == 500

    def test_coverage_boundary_collected(self, tmp_path, valid_image, valid_allowlist):
        """Primary path using summary.collected from real pytest reports."""
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_a.py::test_two", "outcome": "passed"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ], summary={"total": 3, "collected": 9000})
        result = summarize_gate(valid_allowlist, report, valid_image)
        assert result.total_discovered == 9000
        assert result.outside_allowlist == 8997



class TestGateMarkdown:
    def test_pass_summary(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_a.py::test_two", "outcome": "passed"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ])
        result = summarize_gate(valid_allowlist, report, valid_image)
        md = render_gate_markdown(result)
        assert "PASS" in md
        assert "selected: 3" in md
        assert "passed: 3" in md

    def test_fail_summary_includes_repro(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "failed"},
            {"nodeid": "tests/test_a.py::test_two", "outcome": "passed"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ])
        result = summarize_gate(valid_allowlist, report, valid_image)
        md = render_gate_markdown(result)
        assert "FAIL" in md
        assert "scripts/run-functional-tests.sh single" in md
        assert "Every allowlisted test must be collected, executed, and pass." in md

    def test_missing_summary_includes_allowlist_repro(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ])
        result = summarize_gate(valid_allowlist, report, valid_image)
        md = render_gate_markdown(result)
        assert "FAIL" in md
        assert "scripts/run-functional-tests.sh allowlist" in md


# --- Daily delta ---

class TestSummarizeDaily:
    def test_delta_classification(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_a.py::test_two", "outcome": "failed"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
            {"nodeid": "tests/test_c.py::test_outside_pass", "outcome": "passed"},
            {"nodeid": "tests/test_d.py::test_outside_fail", "outcome": "failed"},
        ])
        delta = summarize_daily(valid_allowlist, report, valid_image)
        assert delta["allowlisted_passed"] == 2
        assert len(delta["allowlisted_failed"]) == 1
        assert delta["outside_passed"] == 1
        assert delta["outside_not_passing"] == 1

    def test_promotion_snippet(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_a.py::test_two", "outcome": "passed"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
            {"nodeid": "tests/test_new.py::test_candidate", "outcome": "passed"},
        ])
        delta = summarize_daily(valid_allowlist, report, valid_image)
        assert "test_new.py::test_candidate" in delta["promotion_snippet"]

    def test_daily_markdown_neutral_language(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_a.py::test_two", "outcome": "passed"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ])
        delta = summarize_daily(valid_allowlist, report, valid_image)
        md = render_daily_markdown(delta)
        assert "deny" not in md.lower()
        assert "invalid" not in md.lower()
        assert "rejected" not in md.lower()

    def test_daily_markdown_lists_missing_allowlisted_tests(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ])
        delta = summarize_daily(valid_allowlist, report, valid_image)
        md = render_daily_markdown(delta)
        assert "Allowlisted tests missing from the report" in md
        assert "tests/test_a.py::test_two" in md

    def test_summarize_daily_exits_nonzero_when_allowlisted_test_missing(
        self, tmp_path, valid_image, valid_allowlist
    ):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ])
        output_dir = tmp_path / "daily-output"
        args = type("Args", (), {
            "allowlist": valid_allowlist,
            "report": report,
            "image": valid_image,
            "output_dir": str(output_dir),
        })()
        assert cmd_summarize_daily(args) == 1


# --- Area derivation ---

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
        area = derive_area("totally/unknown/path.py::test_z")
        assert area == "unknown"
