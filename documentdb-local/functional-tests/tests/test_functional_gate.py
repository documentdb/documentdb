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
    cmd_compare_engines,
    compare_engines,
    render_comparison_markdown,
    load_allowlist_entries,
    load_allowlist_ids,
    parse_allowlist_entries,
    validate_config,
    validate_allowlist_config,
    validate_image_config,
    summarize_gate,
    render_gate_markdown,
    summarize_daily,
    render_daily_markdown,
    derive_area,
    gate_failure_ids,
    merge_reports,
    split_allowlist_ids,
    cmd_recover_and_gate,
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
            {"nodeid": "tests/test_a.py::test_two", "outcome": "xfailed"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ])
        result = summarize_gate(valid_allowlist, report, valid_image)
        assert result.non_pass == 1

    def test_xpass_is_distinct(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_a.py::test_two", "outcome": "xpassed"},
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
            "engine_name": "documentdb",
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


# --- Schema v2 (per-engine scoping) ---

def write_v2_allowlist(tmp_path, entries):
    """Write a schema_version=2 allowlist with the given entries."""
    path = tmp_path / "allowlist.yml"
    path.write_text(yaml.dump({"schema_version": 2, "tests": entries},
                              default_flow_style=False))
    return str(path)


class TestParseAllowlistEntries:
    """Direct coverage of the parse_allowlist_entries helper."""

    def test_v1_bare_strings_become_none_engines(self, tmp_path):
        data = {"schema_version": 1, "tests": ["a::b", "c::d"]}
        entries, errors = parse_allowlist_entries(data)
        assert errors == []
        assert entries == [("a::b", None), ("c::d", None)]

    def test_v1_rejects_dict_entry(self):
        data = {"schema_version": 1, "tests": [{"id": "a::b"}]}
        _, errors = parse_allowlist_entries(data)
        assert any(e.subtype == "INVALID_SCHEMA" and "schema_version >= 2" in e.message
                   for e in errors)

    def test_v2_bare_string(self):
        data = {"schema_version": 2, "tests": ["a::b"]}
        entries, errors = parse_allowlist_entries(data)
        assert errors == []
        assert entries == [("a::b", None)]

    def test_v2_dict_with_engines(self):
        data = {"schema_version": 2, "tests": [{"id": "a::b", "engines": ["pgmongo"]}]}
        entries, errors = parse_allowlist_entries(data)
        assert errors == []
        assert entries == [("a::b", frozenset({"pgmongo"}))]

    def test_v2_dict_without_engines_means_all(self):
        data = {"schema_version": 2, "tests": [{"id": "a::b"}]}
        entries, errors = parse_allowlist_entries(data)
        assert errors == []
        assert entries == [("a::b", None)]

    def test_v2_rejects_empty_engines(self):
        data = {"schema_version": 2, "tests": [{"id": "a::b", "engines": []}]}
        _, errors = parse_allowlist_entries(data)
        assert any(e.subtype == "INVALID_SCHEMA" and "non-empty list" in e.message
                   for e in errors)

    def test_v2_rejects_unknown_key(self):
        data = {"schema_version": 2, "tests": [{"id": "a::b", "engine": "pgmongo"}]}
        _, errors = parse_allowlist_entries(data)
        assert any(e.subtype == "INVALID_SCHEMA" and "Unknown keys" in e.message
                   for e in errors)

    def test_v2_rejects_non_string_engine(self):
        data = {"schema_version": 2, "tests": [{"id": "a::b", "engines": [123]}]}
        _, errors = parse_allowlist_entries(data)
        assert any(e.subtype == "INVALID_SCHEMA" for e in errors)

    def test_v2_rejects_non_string_id(self):
        data = {"schema_version": 2, "tests": [{"id": 123, "engines": ["pgmongo"]}]}
        _, errors = parse_allowlist_entries(data)
        assert any(e.subtype == "INVALID_SCHEMA" and "'id'" in e.message for e in errors)

    def test_v2_duplicate_id_rejected_regardless_of_engines(self):
        data = {"schema_version": 2, "tests": [
            {"id": "a::b", "engines": ["documentdb"]},
            {"id": "a::b", "engines": ["pgmongo"]},
        ]}
        _, errors = parse_allowlist_entries(data)
        assert any(e.subtype == "DUPLICATE_TEST_ID" for e in errors)

    def test_v2_mixed_bare_and_dict(self):
        data = {"schema_version": 2, "tests": [
            "bare::id",
            {"id": "scoped::id", "engines": ["documentdb"]},
        ]}
        entries, errors = parse_allowlist_entries(data)
        assert errors == []
        assert entries == [("bare::id", None), ("scoped::id", frozenset({"documentdb"}))]

    def test_invalid_schema_version_returns_early(self):
        data = {"schema_version": 99, "tests": ["a::b"]}
        entries, errors = parse_allowlist_entries(data)
        assert entries == []
        assert any(e.subtype == "INVALID_SCHEMA" for e in errors)


class TestLoadAllowlistIds:
    def test_v1_returns_all_entries(self, tmp_path):
        path = tmp_path / "allowlist.yml"
        path.write_text(yaml.dump({"schema_version": 1, "tests": ["a::b", "c::d"]}))
        assert load_allowlist_ids(str(path), "documentdb") == {"a::b", "c::d"}
        assert load_allowlist_ids(str(path), "pgmongo") == {"a::b", "c::d"}

    def test_v2_per_engine_filter(self, tmp_path):
        path = write_v2_allowlist(tmp_path, [
            "shared::test",
            {"id": "pgmongo_only::test", "engines": ["pgmongo"]},
            {"id": "docdb_only::test", "engines": ["documentdb"]},
            {"id": "no_engines::test"},
        ])
        assert load_allowlist_ids(path, "documentdb") == {
            "shared::test", "docdb_only::test", "no_engines::test"
        }
        assert load_allowlist_ids(path, "pgmongo") == {
            "shared::test", "pgmongo_only::test", "no_engines::test"
        }

    def test_v2_multiple_engines_per_entry(self, tmp_path):
        path = write_v2_allowlist(tmp_path, [
            {"id": "two_engines::test", "engines": ["documentdb", "pgmongo"]},
            {"id": "one_engine::test", "engines": ["other_engine"]},
        ])
        assert load_allowlist_ids(path, "documentdb") == {"two_engines::test"}
        assert load_allowlist_ids(path, "pgmongo") == {"two_engines::test"}
        # other_engine sees only the entry that explicitly lists it; two_engines::test
        # is scoped to {documentdb, pgmongo} and is correctly excluded here.
        assert load_allowlist_ids(path, "other_engine") == {"one_engine::test"}

    def test_load_allowlist_entries_raises_on_invalid(self, tmp_path):
        path = tmp_path / "allowlist.yml"
        path.write_text(yaml.dump({"schema_version": 2,
                                   "tests": [{"id": "a::b", "engines": []}]}))
        with pytest.raises(ValueError, match="INVALID_SCHEMA"):
            load_allowlist_entries(path)


class TestSummarizeGateEngineFilter:
    """v2: out-of-scope entries must not contribute to gate failures."""

    def test_pgmongo_only_entry_not_flagged_on_documentdb(self, tmp_path):
        allowlist = write_v2_allowlist(tmp_path, [
            "shared::test",
            {"id": "pgmongo_only::test", "engines": ["pgmongo"]},
        ])
        # documentdb pytest report contains only the shared test
        report = make_pytest_report(tmp_path, [
            {"nodeid": "shared::test", "outcome": "passed"},
        ], summary={"total": 1, "deselected": 100, "collected": 1})
        result = summarize_gate(allowlist, report, "", engine_name="documentdb")
        assert result.outcome == "PASS"
        assert result.selected == 1  # only the in-scope entry
        assert result.passed == 1
        assert result.missing == 0
        assert not any(e.get("subtype") == "UNKNOWN_TEST_ID" for e in result.errors)

    def test_pgmongo_only_entry_in_scope_on_pgmongo(self, tmp_path):
        allowlist = write_v2_allowlist(tmp_path, [
            "shared::test",
            {"id": "pgmongo_only::test", "engines": ["pgmongo"]},
        ])
        # On the pgmongo gate, both entries are in scope
        report = make_pytest_report(tmp_path, [
            {"nodeid": "shared::test", "outcome": "passed"},
            {"nodeid": "pgmongo_only::test", "outcome": "passed"},
        ], summary={"total": 2, "deselected": 100, "collected": 2})
        result = summarize_gate(allowlist, report, "", engine_name="pgmongo")
        assert result.outcome == "PASS"
        assert result.selected == 2
        assert result.passed == 2

    def test_documentdb_only_entry_missing_on_pgmongo_run_not_flagged(self, tmp_path):
        """A documentdb-only entry should not appear as UNKNOWN_TEST_ID on a pgmongo gate."""
        allowlist = write_v2_allowlist(tmp_path, [
            {"id": "docdb_only::test", "engines": ["documentdb"]},
            "shared::test",
        ])
        report = make_pytest_report(tmp_path, [
            {"nodeid": "shared::test", "outcome": "passed"},
        ], summary={"total": 1, "deselected": 0, "collected": 1})
        result = summarize_gate(allowlist, report, "", engine_name="pgmongo")
        assert result.outcome == "PASS"
        assert result.missing == 0


class TestSummarizeDailyEngineFilter:
    def test_pgmongo_only_passes_on_documentdb_run_is_scoped_not_outside(self, tmp_path):
        """A pgmongo-only entry that happens to pass on the documentdb daily
        suite must NOT count toward allowlisted_*, must NOT count toward
        outside_*, and must land in scoped_other_engine_passed so the
        promotion snippet doesn't recommend a duplicate."""
        allowlist = write_v2_allowlist(tmp_path, [
            "shared::test",
            {"id": "pgmongo_only::test", "engines": ["pgmongo"]},
        ])
        report = make_pytest_report(tmp_path, [
            {"nodeid": "shared::test", "outcome": "passed"},
            {"nodeid": "pgmongo_only::test", "outcome": "passed"},
            {"nodeid": "truly_outside::test", "outcome": "failed"},
        ], summary={"total": 3, "deselected": 0, "collected": 3})
        delta = summarize_daily(allowlist, report, "", engine_name="documentdb")
        assert delta["allowlisted_passed"] == 1  # only shared::test
        # pgmongo_only::test goes to the scoped bucket, NOT outside_passed
        assert delta["scoped_other_engine_passed"] == ["pgmongo_only::test"]
        assert delta["outside_passed"] == 0
        assert delta["outside_not_passing"] == 1  # truly_outside::test
        # pgmongo-only entry must not appear as "missing" either
        assert "pgmongo_only::test" not in delta["allowlisted_missing"]

    def test_promotion_snippet_excludes_already_allowlisted_other_engine(self, tmp_path):
        """The promotion snippet must never suggest adding an ID that is already
        in the allowlist under another engine scope — that would create a
        DUPLICATE_TEST_ID failure on the next validate-config."""
        allowlist = write_v2_allowlist(tmp_path, [
            {"id": "pgmongo_only::test", "engines": ["pgmongo"]},
        ])
        report = make_pytest_report(tmp_path, [
            {"nodeid": "pgmongo_only::test", "outcome": "passed"},
            {"nodeid": "fresh_candidate::test", "outcome": "passed"},
        ], summary={"total": 2, "deselected": 0, "collected": 2})
        delta = summarize_daily(allowlist, report, "", engine_name="documentdb")
        # pgmongo_only is in the file → not a promotion candidate; only the
        # fresh_candidate is a true outside-the-file pass.
        assert delta["scoped_other_engine_passed"] == ["pgmongo_only::test"]
        assert delta["outside_passed"] == 1
        snippet = delta["promotion_snippet"]
        assert "fresh_candidate::test" in snippet
        assert "pgmongo_only::test" not in snippet


class TestImageOverride:
    """When CI is parameterized with a one-off image, the summarizer must
    report that override in place of the pinned image, so the artifact reflects
    what actually ran."""

    def test_summarize_gate_with_image_override(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_a.py::test_two", "outcome": "passed"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ], summary={"total": 3, "deselected": 0, "collected": 3})
        override = "ghcr.io/example/functional-tests@sha256:" + "f" * 64
        result = summarize_gate(valid_allowlist, report, valid_image,
                                engine_name="documentdb",
                                image_override=override)
        assert result.outcome == "PASS"
        assert result.image == override  # NOT the pinned image from valid_image

    def test_summarize_gate_without_override_uses_pinned(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
            {"nodeid": "tests/test_a.py::test_two", "outcome": "passed"},
            {"nodeid": "tests/test_b.py::test_three", "outcome": "passed"},
        ], summary={"total": 3, "deselected": 0, "collected": 3})
        result = summarize_gate(valid_allowlist, report, valid_image,
                                engine_name="documentdb")
        assert result.image == "ghcr.io/test/image@sha256:abc123"  # from valid_image fixture

    def test_summarize_daily_with_image_override(self, tmp_path, valid_image, valid_allowlist):
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::test_one", "outcome": "passed"},
        ], summary={"total": 1, "deselected": 0, "collected": 1})
        override = "ghcr.io/example/functional-tests@sha256:" + "a" * 64
        delta = summarize_daily(valid_allowlist, report, valid_image,
                                engine_name="documentdb",
                                image_override=override)
        assert delta["image"] == override


class TestParseAllowlistEntriesNonMapping:
    """Helper must reject non-mapping input cleanly (matches plugin behavior)."""

    def test_none_input_returns_error(self):
        entries, errors = parse_allowlist_entries(None)
        assert entries == []
        assert any(e.subtype == "INVALID_SCHEMA" and "mapping" in e.message
                   for e in errors)

    def test_list_input_returns_error(self):
        entries, errors = parse_allowlist_entries(["just", "a", "list"])
        assert entries == []
        assert any(e.subtype == "INVALID_SCHEMA" and "mapping" in e.message
                   for e in errors)


class TestCrossParserGolden:
    """Golden table: the in-process helper and the subprocess plugin must agree
    on accept/reject for every fixture. Guards against drift between the two
    parsers that both live in this repo.
    """

    GOLDEN_VALID = [
        ("v1_bare", {"schema_version": 1, "tests": ["a::b"]}),
        ("v2_bare", {"schema_version": 2, "tests": ["a::b"]}),
        ("v2_dict_with_engines", {"schema_version": 2,
                                  "tests": [{"id": "a::b", "engines": ["documentdb"]}]}),
        ("v2_dict_no_engines", {"schema_version": 2,
                                "tests": [{"id": "a::b"}]}),
        ("v2_mixed", {"schema_version": 2,
                      "tests": ["bare::id",
                                {"id": "scoped::id", "engines": ["pgmongo"]}]}),
    ]

    GOLDEN_INVALID = [
        ("bad_schema_version", {"schema_version": 99, "tests": []}),
        ("v1_dict_entry", {"schema_version": 1, "tests": [{"id": "a::b"}]}),
        ("empty_engines", {"schema_version": 2,
                           "tests": [{"id": "a::b", "engines": []}]}),
        ("unknown_key", {"schema_version": 2,
                         "tests": [{"id": "a::b", "engine": "pgmongo"}]}),
        ("non_string_engine", {"schema_version": 2,
                               "tests": [{"id": "a::b", "engines": [123]}]}),
        ("non_string_id", {"schema_version": 2,
                           "tests": [{"id": 123, "engines": ["pgmongo"]}]}),
        ("duplicate_id", {"schema_version": 2,
                          "tests": ["a::b", {"id": "a::b", "engines": ["pgmongo"]}]}),
    ]

    @pytest.mark.parametrize("name,data",
                             [(n, d) for n, d in GOLDEN_VALID])
    def test_helper_accepts_valid(self, tmp_path, name, data):
        path = tmp_path / f"{name}.yml"
        path.write_text(yaml.dump(data))
        _, errors = parse_allowlist_entries(data)
        assert errors == [], f"{name} should be valid: {errors}"
        # And the loader doesn't raise
        load_allowlist_entries(str(path))

    @pytest.mark.parametrize("name,data",
                             [(n, d) for n, d in GOLDEN_INVALID])
    def test_helper_rejects_invalid(self, name, data):
        _, errors = parse_allowlist_entries(data)
        assert errors, f"{name} should be invalid but was accepted"

    @pytest.mark.parametrize("name,data",
                             [(n, d) for n, d in GOLDEN_INVALID])
    def test_plugin_rejects_invalid(self, tmp_path, name, data):
        """Run the plugin via subprocess and assert it rejects the same fixture."""
        plugin_path = Path(__file__).parent.parent / "tools" / "conftest_allowlist.py"
        plugin_dir = tmp_path / "plugins"
        plugin_dir.mkdir()
        import shutil
        shutil.copy(str(plugin_path), str(plugin_dir / "conftest_allowlist.py"))

        allowlist = tmp_path / "allowlist.yml"
        allowlist.write_text(yaml.dump(data))

        test_file = tmp_path / "test_dummy.py"
        test_file.write_text("def test_x():\n    pass\n")

        env = os.environ.copy()
        env["PYTHONPATH"] = str(plugin_dir) + os.pathsep + env.get("PYTHONPATH", "")
        import subprocess
        r = subprocess.run(
            [sys.executable, "-m", "pytest", str(test_file),
             "-p", "no:cacheprovider", "-p", "conftest_allowlist",
             f"--allowlist={allowlist}"],
            capture_output=True, text=True, cwd=str(tmp_path), env=env,
        )
        assert r.returncode != 0, f"{name} was accepted by plugin: {r.stdout}\n{r.stderr}"

    @pytest.mark.parametrize("name,data",
                             [(n, d) for n, d in GOLDEN_VALID])
    def test_plugin_accepts_valid(self, tmp_path, name, data):
        """Symmetric guard: the plugin must accept the same fixtures the helper
        accepts. Catches drift where the plugin becomes stricter than the
        helper (which would make ``validate-config`` green but the real gate
        red on the same file)."""
        plugin_path = Path(__file__).parent.parent / "tools" / "conftest_allowlist.py"
        plugin_dir = tmp_path / "plugins"
        plugin_dir.mkdir()
        import shutil
        shutil.copy(str(plugin_path), str(plugin_dir / "conftest_allowlist.py"))

        allowlist = tmp_path / "allowlist.yml"
        allowlist.write_text(yaml.dump(data))

        # Generate a test file containing every node ID the fixture references
        # so the plugin's UNKNOWN_TEST_ID guard doesn't fire on valid input.
        helper_entries, _ = parse_allowlist_entries(data)
        all_ids = [tid for tid, _ in helper_entries]
        # Synthesize a test file whose collected node IDs match the allowlist.
        test_file_lines = []
        for idx, _ in enumerate(all_ids):
            test_file_lines.append(f"def test_synth_{idx}():\n    pass\n")
        test_file = tmp_path / "test_dummy.py"
        test_file.write_text("".join(test_file_lines) or "def test_x():\n    pass\n")

        # Write a custom allowlist whose IDs match the synthesized collection.
        # We rewrite the fixture preserving structure (bare vs dict) but with
        # the synthesized node IDs in entry order.
        rewritten = []
        for synth_idx, entry in enumerate(data["tests"]):
            new_id = f"test_dummy.py::test_synth_{synth_idx}"
            if isinstance(entry, str):
                rewritten.append(new_id)
            else:
                new_entry = dict(entry)
                new_entry["id"] = new_id
                rewritten.append(new_entry)
        allowlist.write_text(yaml.dump({"schema_version": data["schema_version"],
                                        "tests": rewritten}))

        env = os.environ.copy()
        env["PYTHONPATH"] = str(plugin_dir) + os.pathsep + env.get("PYTHONPATH", "")
        import subprocess
        r = subprocess.run(
            [sys.executable, "-m", "pytest", str(test_file),
             "-p", "no:cacheprovider", "-p", "conftest_allowlist",
             f"--allowlist={allowlist}",
             "--allowlist-engine-name=documentdb"],
            capture_output=True, text=True, cwd=str(tmp_path), env=env,
        )
        # 0 = tests ran; 5 = no tests collected (all entries scoped out on
        # this engine). Either is a valid "accepted" outcome — no UsageError.
        assert r.returncode in (0, 5), (
            f"{name} was rejected by plugin (returncode={r.returncode}):\n"
            f"STDOUT:\n{r.stdout}\nSTDERR:\n{r.stderr}"
        )
        # And the plugin must not emit any of our schema-error codes.
        for code in ("INVALID_SCHEMA", "DUPLICATE_TEST_ID", "UNKNOWN_TEST_ID",
                     "ALLOWLISTED_NO_PARALLEL", "ALLOWLISTED_ENGINE_XFAIL"):
            assert code not in r.stderr, f"{name} produced {code}: {r.stderr}"

    def test_plugin_helper_in_scope_set_parity_mixed_fixture(self, tmp_path):
        """For a fixture with mixed engine scopes, the set of node IDs the
        plugin selects must equal ``load_allowlist_ids(path, engine)``. Guards
        against drift where both parsers accept the input but produce
        different in-scope sets."""
        plugin_path = Path(__file__).parent.parent / "tools" / "conftest_allowlist.py"
        plugin_dir = tmp_path / "plugins"
        plugin_dir.mkdir()
        import shutil
        shutil.copy(str(plugin_path), str(plugin_dir / "conftest_allowlist.py"))

        # 4 tests with a mix of scoping shapes; we generate the matching test
        # file and allowlist.
        entries = [
            ("test_dummy.py::test_synth_0", None),                     # bare
            ("test_dummy.py::test_synth_1", {"documentdb"}),           # docdb only
            ("test_dummy.py::test_synth_2", {"pgmongo"}),              # pgmongo only
            ("test_dummy.py::test_synth_3", None),                     # bare via dict-no-engines
        ]
        test_file = tmp_path / "test_dummy.py"
        test_file.write_text("".join(f"def test_synth_{i}():\n    pass\n"
                                     for i in range(len(entries))))
        allowlist = tmp_path / "allowlist.yml"
        yaml_entries = [
            entries[0][0],
            {"id": entries[1][0], "engines": list(entries[1][1])},
            {"id": entries[2][0], "engines": list(entries[2][1])},
            {"id": entries[3][0]},
        ]
        allowlist.write_text(yaml.dump({"schema_version": 2, "tests": yaml_entries}))

        for engine in ("documentdb", "pgmongo"):
            helper_in_scope = load_allowlist_ids(str(allowlist), engine)

            env = os.environ.copy()
            env["PYTHONPATH"] = str(plugin_dir) + os.pathsep + env.get("PYTHONPATH", "")
            import subprocess
            r = subprocess.run(
                [sys.executable, "-m", "pytest", str(test_file),
                 "-p", "no:cacheprovider", "-p", "conftest_allowlist",
                 f"--allowlist={allowlist}",
                 f"--allowlist-engine-name={engine}",
                 "--collect-only", "-q"],
                capture_output=True, text=True, cwd=str(tmp_path), env=env,
            )
            assert r.returncode in (0, 5), (
                f"engine={engine}: plugin failed with {r.returncode}:\n"
                f"STDOUT:\n{r.stdout}\nSTDERR:\n{r.stderr}"
            )
            # Extract collected (selected) test IDs from --collect-only -q output
            plugin_selected = set()
            for line in r.stdout.splitlines():
                line = line.strip()
                if "::" in line and not line.startswith(("=", "_", "[", "<")):
                    # Strip any pytest decorations
                    plugin_selected.add(line)
            assert plugin_selected == helper_in_scope, (
                f"engine={engine}: parser drift\n"
                f"helper in-scope: {sorted(helper_in_scope)}\n"
                f"plugin selected: {sorted(plugin_selected)}\n"
                f"STDOUT:\n{r.stdout}"
            )


# --- Compare engines ---

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
        # a_missing only in A, b_only_test only in B -> both go to "other"
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
            "report_a": report_a,
            "report_b": report_b,
            "engine_a": "pgmongo",
            "engine_b": "documentdb",
            "image": valid_image,
            "output_dir": str(output_dir),
        })()

        assert cmd_compare_engines(args) == 0
        assert (output_dir / "comparison-summary.md").exists()
        assert (output_dir / "comparison-summary.json").exists()
        data = json.loads((output_dir / "comparison-summary.json").read_text())
        assert data["engine_a"] == "pgmongo"
        assert data["engine_b"] == "documentdb"
        assert data["total_compared"] == 1


class TestGateFailureIds:
    """gate_failure_ids selects allowlisted tests that ran but did not pass."""

    def test_returns_failed_and_nonpass_excludes_missing_and_passed(self, tmp_path):
        allowlist = write_v2_allowlist(tmp_path, [
            "tests/test_a.py::passed",
            "tests/test_a.py::failed",
            "tests/test_a.py::skipped",
            "tests/test_a.py::xfailed",
            "tests/test_a.py::missing",  # not present in the report
        ])
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::passed", "outcome": "passed"},
            {"nodeid": "tests/test_a.py::failed", "outcome": "failed"},
            {"nodeid": "tests/test_a.py::skipped", "outcome": "skipped"},
            {"nodeid": "tests/test_a.py::xfailed", "outcome": "xfailed"},
            # non-allowlisted failure must be ignored
            {"nodeid": "tests/test_a.py::other", "outcome": "failed"},
        ], summary={"collected": 5, "total": 5})

        ids = gate_failure_ids(allowlist, report, "documentdb")

        assert "tests/test_a.py::failed" in ids
        assert "tests/test_a.py::skipped" in ids
        assert "tests/test_a.py::xfailed" in ids
        assert "tests/test_a.py::passed" not in ids
        assert "tests/test_a.py::missing" not in ids  # missing is never re-run
        assert "tests/test_a.py::other" not in ids  # non-allowlisted ignored

    def test_empty_when_all_pass(self, tmp_path):
        allowlist = write_v2_allowlist(tmp_path, ["tests/test_a.py::one"])
        report = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::one", "outcome": "passed"},
        ], summary={"collected": 1, "total": 1})
        assert gate_failure_ids(allowlist, report, "documentdb") == []


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
        # collected (discovery count) is preserved from the base
        assert merged["summary"]["collected"] == 2
        # tallies are refreshed
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

    def test_merge_then_summarize_gate_passes(self, tmp_path):
        """End-to-end: a re-run that passes the failures flips the gate to PASS."""
        allowlist = write_v2_allowlist(tmp_path, [
            "tests/test_a.py::one",
            "tests/test_a.py::two",
        ])
        base = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::one", "outcome": "passed"},
            {"nodeid": "tests/test_a.py::two", "outcome": "failed"},
        ], summary={"collected": 2, "total": 2}, filename="base.json")
        overlay = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::two", "outcome": "passed"},
        ], summary={"collected": 1, "total": 1}, filename="rerun.json")

        merged = merge_reports(base, [overlay])
        merged_path = tmp_path / "merged.json"
        merged_path.write_text(json.dumps(merged))

        result = summarize_gate(allowlist, str(merged_path), engine_name="documentdb")
        assert result.outcome == "PASS"
        assert result.passed == 2
        assert result.failed == 0

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
        # collected preserved from base (default re-run merge)
        assert merged["summary"]["collected"] == 1

    def test_sum_collected_combines_split_discovery_counts(self, tmp_path):
        """Split-combine merge sums collected across disjoint test-split reports."""
        split0 = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_a.py::s0", "outcome": "passed"},
        ], summary={"collected": 2620, "total": 2620}, filename="s0.json")
        split1 = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_b.py::s1", "outcome": "passed"},
        ], summary={"collected": 2620, "total": 2620}, filename="s1.json")
        split2 = make_pytest_report(tmp_path, [
            {"nodeid": "tests/test_c.py::s2", "outcome": "passed"},
        ], summary={"collected": 2621, "total": 2621}, filename="s2.json")

        # default: preserves base's collected (wrong for split combine)
        default_merge = merge_reports(split0, [split1, split2])
        assert default_merge["summary"]["collected"] == 2620

        # sum_collected: sums across all test-split reports
        summed = merge_reports(split0, [split1, split2], sum_collected=True)
        assert summed["summary"]["collected"] == 2620 + 2620 + 2621
        ids = {t["nodeid"] for t in summed["tests"]}
        assert ids == {"tests/test_a.py::s0", "tests/test_b.py::s1", "tests/test_c.py::s2"}


class TestSplitAllowlist:
    """split_allowlist_ids partitions the allowlist into disjoint, even test-splits."""

    def test_partition_is_complete_disjoint_and_even(self, tmp_path):
        entries = [f"tests/test_{i}.py::t" for i in range(103)]
        allowlist = write_v2_allowlist(tmp_path, entries)
        num_splits = 4
        splits = [
            set(split_allowlist_ids(allowlist, "documentdb", num_splits, k))
            for k in range(num_splits)
        ]
        union = set().union(*splits)
        # complete
        assert union == set(entries)
        # disjoint
        for i in range(num_splits):
            for j in range(i + 1, num_splits):
                assert not (splits[i] & splits[j])
        # even (max-min <= 1 for round-robin)
        sizes = sorted(len(s) for s in splits)
        assert sizes[-1] - sizes[0] <= 1

    def test_prefix_is_applied(self, tmp_path):
        allowlist = write_v2_allowlist(tmp_path, ["tests/test_a.py::t"])
        out = split_allowlist_ids(allowlist, "documentdb", 1, 0, prefix="documentdb_tests/")
        assert out == ["documentdb_tests/tests/test_a.py::t"]

    def test_single_split_returns_all_sorted(self, tmp_path):
        entries = ["tests/test_b.py::t", "tests/test_a.py::t"]
        allowlist = write_v2_allowlist(tmp_path, entries)
        out = split_allowlist_ids(allowlist, "documentdb", 1, 0)
        assert out == sorted(entries)

    def test_invalid_split_id_raises(self, tmp_path):
        allowlist = write_v2_allowlist(tmp_path, ["tests/test_a.py::t"])
        with pytest.raises(ValueError):
            split_allowlist_ids(allowlist, "documentdb", 4, 4)
        with pytest.raises(ValueError):
            split_allowlist_ids(allowlist, "documentdb", 0, 0)

    def test_engine_scoping_respected(self, tmp_path):
        path = tmp_path / "allowlist.yml"
        path.write_text(yaml.dump({
            "schema_version": 2,
            "tests": [
                "tests/test_a.py::all_engines",
                {"id": "tests/test_b.py::pgmongo_only", "engines": ["pgmongo"]},
            ],
        }))
        # documentdb sees only the unscoped entry
        out = split_allowlist_ids(str(path), "documentdb", 1, 0)
        assert out == ["tests/test_a.py::all_engines"]


class TestRecoverAndGate:
    """recover-and-gate: sequential re-run recovery of transient crash victims,
    then gate (exit 1 on any residual) on the merged report."""

    GATE_PY = str(Path(__file__).parent.parent / "tools" / "functional_gate.py")
    PFX = "docdb_functional_tests/documentdb_tests/"

    def _base(self, tmp_path, outcomes):
        rep = {"tests": [{"nodeid": self.PFX + nid, "outcome": oc}
                         for nid, oc in outcomes],
               "summary": {"collected": len(outcomes)}}
        p = tmp_path / "report.json"
        p.write_text(json.dumps(rep))
        return p

    def _fake_pytest(self, tmp_path, outcome):
        # Reads the @argfile node IDs + --json-report-file target and writes a
        # report where each re-run test gets `outcome`.
        src = (
            "import sys, json\n"
            "out=[a.split('=',1)[1] for a in sys.argv if a.startswith('--json-report-file=')][0]\n"
            "argf=[a[1:] for a in sys.argv if a.startswith('@')][0]\n"
            "ids=[l.strip() for l in open(argf) if l.strip()]\n"
            f"json.dump({{'tests':[{{'nodeid':i,'outcome':{outcome!r}}} for i in ids],"
            "'summary':{'collected':len(ids)}}, open(out,'w'))\n"
        )
        f = tmp_path / "fake_pytest.py"
        f.write_text(src)
        return f

    def _run(self, tmp_path, report, fake, extra=()):
        import subprocess
        cmd = [sys.executable, self.GATE_PY, "recover-and-gate",
               "--report", str(report), "--strip-prefix", self.PFX,
               "--prefix", self.PFX, "--settle-seconds", "0",
               "--workdir", str(tmp_path), *extra,
               "--", sys.executable, str(fake)]
        return subprocess.run(cmd, capture_output=True, text=True)

    def test_transient_victims_recovered_pass(self, tmp_path):
        report = self._base(tmp_path, [("a.py::test_a", "failed"),
                                       ("b.py::test_b", "failed"),
                                       ("c.py::test_c", "passed")])
        fake = self._fake_pytest(tmp_path, "passed")  # the re-run passes
        r = self._run(tmp_path, report, fake)
        assert r.returncode == 0, r.stdout + r.stderr
        assert "gate PASS" in r.stdout

    def test_persistent_failure_reds(self, tmp_path):
        report = self._base(tmp_path, [("a.py::test_a", "failed"),
                                       ("b.py::test_b", "failed")])
        fake = self._fake_pytest(tmp_path, "failed")  # the re-run still fails
        r = self._run(tmp_path, report, fake, extra=["--max-passes", "2"])
        assert r.returncode == 1, r.stdout + r.stderr
        assert "2 residual" in r.stdout
        assert "a.py::test_a" in r.stdout  # residual reported stripped (bare)

    def test_missing_report_fails_closed(self, tmp_path):
        fake = self._fake_pytest(tmp_path, "passed")
        r = self._run(tmp_path, tmp_path / "does_not_exist.json", fake)
        assert r.returncode == 1

    def test_clean_run_passes_without_rerun(self, tmp_path):
        report = self._base(tmp_path, [("a.py::test_a", "passed"),
                                       ("b.py::test_b", "xfailed")])
        fake = self._fake_pytest(tmp_path, "failed")  # must never be invoked
        r = self._run(tmp_path, report, fake)
        assert r.returncode == 0, r.stdout + r.stderr
        assert "re-run pass 1: 0 failing" in r.stdout

    def test_over_transient_limit_left_for_gate(self, tmp_path):
        report = self._base(tmp_path, [(f"a.py::t{i}", "failed") for i in range(5)])
        fake = self._fake_pytest(tmp_path, "passed")
        # limit below the failing count -> no re-run, residual reds the gate
        r = self._run(tmp_path, report, fake, extra=["--transient-limit", "3"])
        assert r.returncode == 1, r.stdout + r.stderr
        assert "too many failures" in r.stdout

    def _fake_pytest_batch_dies(self, tmp_path, hang_marker):
        # Mimics a pytest-timeout `thread` kill: the process dies without writing
        # a report. The BATCH invocation (@argfile) always dies; an isolated
        # invocation (bare node ID) dies only for the test carrying hang_marker
        # and otherwise reports a pass.
        src = (
            "import sys, json\n"
            "out=[a.split('=',1)[1] for a in sys.argv if a.startswith('--json-report-file=')][0]\n"
            "if [a for a in sys.argv if a.startswith('@')]:\n"
            "    sys.exit(1)\n"
            "ids=[a for a in sys.argv[1:] if '::' in a and not a.startswith('-')]\n"
            f"if any({hang_marker!r} in i for i in ids):\n"
            "    sys.exit(1)\n"
            "json.dump({'tests':[{'nodeid':i,'outcome':'passed'} for i in ids],"
            "'summary':{'collected':len(ids)}}, open(out,'w'))\n"
        )
        f = tmp_path / "fake_pytest_hang.py"
        f.write_text(src)
        return f

    def test_batch_abort_falls_back_to_isolated_rerun(self, tmp_path):
        # Regression (gate build 228232606): the batched re-run is a single pytest
        # process, so a --timeout kill on ONE hanging test takes the whole batch
        # down before json-report writes anything. Recovery used to stop there,
        # scoring every crash victim in the set as residual (21 of them, of which
        # only the hanger was real). It must now fall back to one process per
        # test: the hanger stays failed, everything else still recovers.
        report = self._base(tmp_path, [("a.py::test_a", "failed"),
                                       ("hang.py::test_hang", "failed"),
                                       ("b.py::test_b", "failed")])
        fake = self._fake_pytest_batch_dies(tmp_path, "test_hang")
        r = self._run(tmp_path, report, fake, extra=["--max-passes", "1"])
        assert r.returncode == 1, r.stdout + r.stderr
        assert "falling back to one process per test" in r.stdout
        assert "isolated re-run produced 2/3 report(s)." in r.stdout
        assert "1 residual" in r.stdout
        assert "hang.py::test_hang" in r.stdout      # the real failure survives
        assert "a.py::test_a" not in r.stdout        # victim recovered, not residual
        assert "b.py::test_b" not in r.stdout

    def test_isolated_rerun_recovers_every_victim(self, tmp_path):
        # Same batch abort, but nothing actually hangs on the isolated re-run:
        # every victim recovers and the gate goes green.
        report = self._base(tmp_path, [("a.py::test_a", "failed"),
                                       ("b.py::test_b", "failed")])
        fake = self._fake_pytest_batch_dies(tmp_path, "__never_matches__")
        r = self._run(tmp_path, report, fake, extra=["--max-passes", "1"])
        assert r.returncode == 0, r.stdout + r.stderr
        assert "isolated re-run produced 2/2 report(s)." in r.stdout

    def test_batch_and_isolated_both_dead_stops(self, tmp_path):
        # If neither the batch nor any isolated re-run produces a report, recovery
        # must stop and gate on what it has rather than loop or score green.
        report = self._base(tmp_path, [("a.py::test_a", "failed")])
        fake = self._fake_pytest_batch_dies(tmp_path, "test_a")
        r = self._run(tmp_path, report, fake, extra=["--max-passes", "3"])
        assert r.returncode == 1, r.stdout + r.stderr
        assert "re-run produced no report; stopping." in r.stdout
        assert "1 residual" in r.stdout

    def test_merge_staged_in_report_dir_survives_cross_device(self, tmp_path, monkeypatch):
        # Regression: the merged report must be staged in the REPORT's directory so
        # the final os.replace is intra-device. On ADO the --workdir
        # ($(Agent.TempDirectory), /__w/_temp) and the report (artifact-staging dir,
        # /__w/1/a) are different mounts; staging the merged file in workdir made
        # os.replace raise OSError(EXDEV) and abort recovery, reding the gate on
        # transient crash-cascade victims that the serial re-run had already cleared.
        import errno
        from argparse import Namespace
        import functional_gate as fg
        reportdir = tmp_path / "artifacts"; reportdir.mkdir()
        workdir = tmp_path / "agenttmp"; workdir.mkdir()
        report = reportdir / "report.json"
        report.write_text(json.dumps(
            {"tests": [{"nodeid": self.PFX + "a.py::test_a", "outcome": "failed"},
                       {"nodeid": self.PFX + "b.py::test_b", "outcome": "failed"}],
             "summary": {"collected": 2}}))
        fake = self._fake_pytest(tmp_path, "passed")  # re-run passes -> transient
        real_replace = os.replace
        def guarded_replace(src, dst, *a, **k):  # simulate a cross-mount boundary
            if os.path.dirname(os.path.abspath(src)) != os.path.dirname(os.path.abspath(dst)):
                raise OSError(errno.EXDEV, "Invalid cross-device link")
            return real_replace(src, dst, *a, **k)
        monkeypatch.setattr(fg.os, "replace", guarded_replace)
        rc = fg.cmd_recover_and_gate(Namespace(
            report=str(report), strip_prefix=self.PFX, prefix=self.PFX,
            workdir=str(workdir), output=str(workdir / "gate-failures.txt"),
            max_passes=3, transient_limit=400, settle_seconds=0,
            rerun_cmd=["--", sys.executable, str(fake)]))
        assert rc == 0  # merged staged in report_dir -> intra-device replace -> recovered

    # ---- --expected-ids: the xdist worker-death hole (assigned tests whose
    # ---- outcomes were never recorded; build 228667621 p1 lost 1,175 of
    # ---- 12,094 that way and scored green) --------------------------------

    def _expected(self, tmp_path, ids, noise=True):
        lines = [self.PFX + i for i in ids]
        if noise:
            lines += ["", "3 tests collected in 0.42s"]  # manifest-style noise
        f = tmp_path / "expected_ids.txt"
        f.write_text("\n".join(lines) + "\n")
        return f

    def test_unrecorded_assigned_tests_are_recovered(self, tmp_path):
        # 3 assigned, 1 recorded: the other 2 must be re-run, merged, and PASS.
        report = self._base(tmp_path, [("a.py::t1", "passed")])
        exp = self._expected(tmp_path, ["a.py::t1", "b.py::t2", "c.py::t3"])
        fake = self._fake_pytest(tmp_path, "passed")
        r = self._run(tmp_path, report, fake, extra=["--expected-ids", str(exp)])
        assert r.returncode == 0, r.stdout + r.stderr
        assert "0 failing, 2 unrecorded" in r.stdout
        merged = json.loads(report.read_text())
        assert len(merged["tests"]) == 3  # outcomes now recorded for all assigned

    def test_unrecorded_over_limit_reds_the_gate(self, tmp_path):
        report = self._base(tmp_path, [("a.py::t1", "passed")])
        exp = self._expected(tmp_path, ["a.py::t1", "b.py::t2", "c.py::t3"])
        fake = self._fake_pytest(tmp_path, "passed")  # never reached: over limit
        r = self._run(tmp_path, report, fake,
                      extra=["--expected-ids", str(exp), "--missing-limit", "1"])
        assert r.returncode == 1, r.stdout + r.stderr
        assert "too many unrecorded tests (2 > 1)" in r.stdout
        assert "b.py::t2" in r.stdout  # unrecorded tests reported as gate failures

    def test_unrecorded_test_failing_on_rerun_stays_red(self, tmp_path):
        report = self._base(tmp_path, [("a.py::t1", "passed")])
        exp = self._expected(tmp_path, ["a.py::t1", "b.py::t2"])
        fake = self._fake_pytest(tmp_path, "failed")  # the lost test genuinely fails
        r = self._run(tmp_path, report, fake, extra=["--expected-ids", str(exp)])
        assert r.returncode == 1, r.stdout + r.stderr
        assert "1 residual" in r.stdout
        assert "b.py::t2" in r.stdout

    def test_complete_report_with_expected_ids_passes_without_rerun(self, tmp_path):
        report = self._base(tmp_path, [("a.py::t1", "passed"),
                                       ("b.py::t2", "xfailed")])
        exp = self._expected(tmp_path, ["a.py::t1", "b.py::t2"])
        fake = self._fake_pytest(tmp_path, "failed")  # must never be invoked
        r = self._run(tmp_path, report, fake, extra=["--expected-ids", str(exp)])
        assert r.returncode == 0, r.stdout + r.stderr
        assert "0 failing, 0 unrecorded" in r.stdout

    def test_empty_expected_ids_file_fails_closed(self, tmp_path):
        # An empty assigned set means the caller's slice/manifest pipeline broke;
        # gating "nothing was expected" green would hide it.
        report = self._base(tmp_path, [("a.py::t1", "passed")])
        exp = tmp_path / "expected_ids.txt"
        exp.write_text("3 tests collected in 0.42s\n")  # noise only, no node IDs
        fake = self._fake_pytest(tmp_path, "passed")
        r = self._run(tmp_path, report, fake, extra=["--expected-ids", str(exp)])
        assert r.returncode == 1, r.stdout + r.stderr
        assert "holds no node IDs" in r.stdout


class TestVerifySplitUniverses:
    """Cross-leg guard for the stride slice used by split-collection.

    Each parallel leg collects the suite itself and then takes
    ids[split_id::num_splits]. That is a partition ONLY if every leg sliced the
    same sorted universe; a leg whose collection silently omits one node shifts
    every later position, so it runs the next leg's tests while its own share
    runs nowhere -- and every leg still passes. These tests pin that the skew
    fails instead of scoring green.
    """

    def _u(self, tmp_path, tag, mode, uhash, count):
        d = tmp_path / f"art-{tag}"
        d.mkdir(parents=True, exist_ok=True)
        p = d / "universe.txt"
        p.write_text(f"{tag} {mode} {uhash} {count}\n", encoding="utf-8")
        return str(p)

    def test_identical_universes_pass(self, tmp_path):
        import functional_gate as fg
        files = [self._u(tmp_path, f"p{i}", "parallel", "abc123", 48374)
                 for i in range(4)]
        files.append(self._u(tmp_path, "np", "noparallel", "deadbeef", 1913))
        assert fg.verify_split_universes(files, 4) == []

    def test_one_skewed_leg_is_rejected(self, tmp_path):
        # THE production failure: p2's collect dropped a node, so its hash and
        # count differ and its stride is shifted against the others'.
        import functional_gate as fg
        files = [self._u(tmp_path, "p0", "parallel", "abc123", 48374),
                 self._u(tmp_path, "p1", "parallel", "abc123", 48374),
                 self._u(tmp_path, "p2", "parallel", "9999ff", 48373),
                 self._u(tmp_path, "p3", "parallel", "abc123", 48374)]
        problems = fg.verify_split_universes(files, 4)
        assert problems, "skewed universes must not pass"
        assert any("DIFFERENT universes" in p for p in problems)
        assert any("p2=9999ff" in p for p in problems)

    def test_noparallel_hash_may_differ(self, tmp_path):
        # The serial leg collects a different marker set by design.
        import functional_gate as fg
        files = [self._u(tmp_path, f"p{i}", "parallel", "same", 10) for i in range(2)]
        files.append(self._u(tmp_path, "np", "noparallel", "totally-different", 3))
        assert fg.verify_split_universes(files, 2) == []

    def test_missing_leg_is_rejected(self, tmp_path):
        # A leg that never reported leaves its stride unrun; no per-leg gate sees it.
        import functional_gate as fg
        files = [self._u(tmp_path, f"p{i}", "parallel", "same", 10) for i in range(3)]
        problems = fg.verify_split_universes(files, 4)
        assert any("expected 4 parallel split(s)" in p for p in problems)

    def test_repeated_record_does_not_inflate_the_split_count(self, tmp_path):
        # A repeated record is one leg reporting twice (stage retry), so it must
        # NOT be counted as an extra split and let a missing leg slip through:
        # two real legs plus a repeat of p0 is still two splits, not three.
        import functional_gate as fg
        files = [self._u(tmp_path, "p0", "parallel", "same", 10),
                 self._u(tmp_path, "p1", "parallel", "same", 10)]
        d = tmp_path / "dup"; d.mkdir()
        p = d / "universe.txt"; p.write_text("p0 parallel same 10\n", encoding="utf-8")
        files.append(str(p))
        problems = fg.verify_split_universes(files, 3)
        assert any("expected 3 parallel split(s)" in p for p in problems)
        assert any("got 2" in p for p in problems)

    def test_stage_retry_republishing_every_leg_is_not_a_duplicate(self, tmp_path):
        # Artifact names carry System.PhaseAttempt, so a stage RETRY leaves the
        # attempt-1 records in place and adds attempt-2 ones. The verify job then
        # downloads one record per leg PER ATTEMPT. That must not be mistaken for
        # two legs claiming the same split id.
        import functional_gate as fg
        files = []
        for attempt in (1, 2):
            for i in range(4):
                d = tmp_path / f"art-p{i}-{attempt}"
                d.mkdir(parents=True)
                p = d / "universe.txt"
                p.write_text(f"p{i} parallel abc123 48374\n", encoding="utf-8")
                files.append(str(p))
        assert len(files) == 8
        assert fg.verify_split_universes(files, 4) == []

    def test_same_tag_reporting_two_universes_is_rejected(self, tmp_path):
        # Dedupe must not hide a leg that genuinely disagreed with itself.
        import functional_gate as fg
        d1 = tmp_path / "a1"; d1.mkdir()
        (d1 / "universe.txt").write_text("p0 parallel aaa 10\n", encoding="utf-8")
        d2 = tmp_path / "a2"; d2.mkdir()
        (d2 / "universe.txt").write_text("p0 parallel bbb 9\n", encoding="utf-8")
        problems = fg.verify_split_universes([str(d1 / "universe.txt"),
                                              str(d2 / "universe.txt")], 1)
        assert any("CONFLICTING universes" in p for p in problems)

    def test_malformed_record_is_rejected(self, tmp_path):
        import functional_gate as fg
        d = tmp_path / "bad"; d.mkdir()
        p = d / "universe.txt"; p.write_text("garbage\n", encoding="utf-8")
        problems = fg.verify_split_universes([str(p)], 1)
        assert any("unreadable universe record" in p for p in problems)

    def test_cmd_exits_nonzero_on_skew(self, tmp_path):
        from argparse import Namespace
        import functional_gate as fg
        self._u(tmp_path, "p0", "parallel", "aaa", 10)
        self._u(tmp_path, "p1", "parallel", "bbb", 10)
        rc = fg.cmd_verify_split_universes(Namespace(
            dir=[str(tmp_path)], universe=[], expected_splits=2))
        assert rc == 1

    def test_cmd_fails_closed_when_no_records_found(self, tmp_path):
        # An empty download must never be read as "nothing disagreed".
        from argparse import Namespace
        import functional_gate as fg
        rc = fg.cmd_verify_split_universes(Namespace(
            dir=[str(tmp_path)], universe=[], expected_splits=4))
        assert rc == 1

    def test_cmd_passes_on_agreement(self, tmp_path):
        from argparse import Namespace
        import functional_gate as fg
        for i in range(4):
            self._u(tmp_path, f"p{i}", "parallel", "same", 48374)
        self._u(tmp_path, "np", "noparallel", "other", 1913)
        rc = fg.cmd_verify_split_universes(Namespace(
            dir=[str(tmp_path)], universe=[], expected_splits=4))
        assert rc == 0


class TestVerifySplitUniversesArtifactLayout:
    """Pins the REAL downloaded layout, which the first cut of these tests missed.

    Build 228524875 failed with "no universe.txt found" even though all five
    legs wrote one. Cause: DownloadPipelineArtifact matches its patterns against
    each file's path INSIDE its artifact, not against '<artifactName>/<path>',
    so an artifact-name-qualified pattern filtered 0 files from all 107
    artifacts. The unit tests could not have caught it -- they built a flat
    directory of records rather than the <workspace>/<artifactName>/universe.txt
    tree the download actually produces. These tests use that tree.
    """
    PFX = "docdb-pytest-results-pg16-azl3-citus12"

    def _leg(self, ws, tag, uhash, count, mode="parallel", attempt=1, prefix=None):
        d = ws / f"{prefix or self.PFX}-{tag}-{attempt}"
        d.mkdir(parents=True, exist_ok=True)
        (d / "universe.txt").write_text(
            f"{tag} {mode} {uhash} {count}\n", encoding="utf-8")
        # the artifact also carries the rest of the leg's results
        (d / "results.xml").write_text("<testsuite/>", encoding="utf-8")
        return d

    def _ns(self, ws, expected, prefix=""):
        from argparse import Namespace
        return Namespace(dir=[str(ws)], universe=[], expected_splits=expected,
                         artifact_prefix=prefix)

    def test_real_download_layout_passes(self, tmp_path):
        import functional_gate as fg
        for i in range(4):
            self._leg(tmp_path, f"p{i}", "4a433410c839bd86", 48374)
        self._leg(tmp_path, "np", "4133a3a9c9142a79", 1913, mode="noparallel")
        assert fg.cmd_verify_split_universes(self._ns(tmp_path, 4, self.PFX)) == 0

    def test_real_download_layout_catches_skew(self, tmp_path):
        import functional_gate as fg
        for i in (0, 1, 3):
            self._leg(tmp_path, f"p{i}", "4a433410c839bd86", 48374)
        self._leg(tmp_path, "p2", "deadbeefdeadbeef", 48373)
        assert fg.cmd_verify_split_universes(self._ns(tmp_path, 4, self.PFX)) == 1

    def test_records_from_another_stage_are_ignored(self, tmp_path):
        # A second instance of this stage template (e.g. a rust-gateway variant)
        # publishes its own legs into the same run. Those must not be counted
        # here, or the split count and duplicate checks fire for no real reason.
        import functional_gate as fg
        for i in range(4):
            self._leg(tmp_path, f"p{i}", "4a433410c839bd86", 48374)
        for i in range(4):
            self._leg(tmp_path, f"p{i}", "ffff0000ffff0000", 12345,
                      prefix="docdb-pytest-results-pg16-mariner-citus12")
        assert fg.cmd_verify_split_universes(self._ns(tmp_path, 4, self.PFX)) == 0

    def test_stage_retry_layout_passes(self, tmp_path):
        # attempt 1 and attempt 2 artifacts both present after a stage retry
        import functional_gate as fg
        for attempt in (1, 2):
            for i in range(4):
                self._leg(tmp_path, f"p{i}", "4a433410c839bd86", 48374,
                          attempt=attempt)
        assert fg.cmd_verify_split_universes(self._ns(tmp_path, 4, self.PFX)) == 0

    def test_empty_workspace_fails_closed(self, tmp_path):
        import functional_gate as fg
        assert fg.cmd_verify_split_universes(self._ns(tmp_path, 4, self.PFX)) == 1

    def test_prefix_filtering_everything_out_fails_closed(self, tmp_path):
        # The 228524875 shape: records exist, but none are accepted. Must fail,
        # and must not be mistaken for "nothing disagreed".
        import functional_gate as fg
        for i in range(4):
            self._leg(tmp_path, f"p{i}", "4a433410c839bd86", 48374)
        rc = fg.cmd_verify_split_universes(
            self._ns(tmp_path, 4, "some-other-artifact-prefix"))
        assert rc == 1

    def test_no_prefix_accepts_everything(self, tmp_path):
        import functional_gate as fg
        for i in range(4):
            self._leg(tmp_path, f"p{i}", "4a433410c839bd86", 48374)
        assert fg.cmd_verify_split_universes(self._ns(tmp_path, 4, "")) == 0
