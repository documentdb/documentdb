"""Tests for check_allowlist_removals.py."""

import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).parent.parent / "tools"))
from check_allowlist_removals import check_allowlist_removals, find_removed_tests, main


def write_allowlist(path, tests):
    path.write_text(yaml.dump({"schema_version": 1, "tests": tests}))
    return path


def test_find_removed_tests_reports_only_base_entries_missing_from_head(tmp_path):
    base = write_allowlist(tmp_path / "base.yml", ["a::test_one", "b::test_two"])
    head = write_allowlist(tmp_path / "head.yml", ["b::test_two", "c::test_three"])

    assert find_removed_tests(base, head) == ["a::test_one"]


def test_check_allowlist_removals_allows_additions(tmp_path, capsys):
    base = write_allowlist(tmp_path / "base.yml", ["a::test_one"])
    head = write_allowlist(tmp_path / "head.yml", ["a::test_one", "b::test_two"])

    assert check_allowlist_removals(base, head) == 0
    assert "No allow-list removals detected." in capsys.readouterr().out


def test_check_allowlist_removals_fails_with_removed_ids(tmp_path, capsys):
    base = write_allowlist(tmp_path / "base.yml", ["a::test_one", "b::test_two"])
    head = write_allowlist(tmp_path / "head.yml", ["b::test_two"])

    assert check_allowlist_removals(base, head) == 1
    out = capsys.readouterr().out
    assert "1 test(s) removed" in out
    assert "a::test_one" in out
    assert "explicit justification" in out


def test_main_returns_error_for_invalid_allowlist(tmp_path, capsys):
    base = tmp_path / "base.yml"
    head = write_allowlist(tmp_path / "head.yml", [])
    base.write_text("not-a-mapping\n")

    assert main(["--base", str(base), "--head", str(head)]) == 2
    assert "Allow-list removal check failed" in capsys.readouterr().err
