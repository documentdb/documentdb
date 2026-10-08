# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Registry-driven fan-out and combined reports with incomplete or conflicting evidence."""

import json
import sys
from copy import deepcopy
from datetime import timedelta

import pytest

from compatibility import workflow
from compatibility.contracts import RUNTIME_PREFIXES, expected_tests, suite_digest, timestamp

pytestmark = pytest.mark.unit
RUN_URL = "https://github.com/example/project/actions/runs/42/attempts/3"


@pytest.fixture
def runs(registry, selection):
    return workflow.select_runs(registry, "all", None, selection["documentdb_version"])


@pytest.fixture
def records(registry, record, runs):
    results = {}
    for index, run in enumerate(runs):
        integration = run["integration"]
        spec = registry["integrations"][integration]
        result = deepcopy(record)
        result.update(
            id=f"{index + 1:032x}",
            integration=integration,
            suite_digest=suite_digest(integration, spec),
            **{key: spec[key] for key in ("repository", "owner", "profile")},
        )
        result["expected_tests"] = expected_tests(spec, False)
        result["tests"] = [
            {"id": name, "outcome": "passed", "message": ""} for name in result["expected_tests"]
        ]
        runtime = spec["runtime"]
        parts = RUNTIME_PREFIXES[runtime].rstrip(".").split(".")
        result["upstream"].update(
            version=run["version"],
            actual_version=run["version"],
            runtime={"name": runtime, "version": ".".join(parts + ["0"] * (3 - len(parts)))},
            dependencies=[{"name": spec["package"], "version": run["version"], "sha256": "b" * 64}],
        )
        results[integration] = result
    return results


def write_records(path, records):
    for integration, result in records.items():
        directory = path / integration
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "result.json").write_text(json.dumps(result))
    return path


def read_report(output):
    report = json.loads((output / "summary.json").read_text())
    history = json.loads((output / "site/history.json").read_text())
    return report, {row["integration"]: row for row in report["integrations"]}, history


def test_all_uses_each_enabled_default_and_accepts_new_registry_entries(registry, selection):
    extra = deepcopy(registry["integrations"][selection["integration"]])
    extra.update(default_version="99.1.2", version_pattern=r"^99\.1\.2$")
    registry["integrations"]["additional"] = extra
    registry["integrations"][selection["integration"]]["enabled"] = False
    runs = workflow.select_runs(registry, "all", None, selection["documentdb_version"], True)
    assert {run["integration"]: run["version"] for run in runs} == {
        name: spec["default_version"]
        for name, spec in registry["integrations"].items()
        if spec["enabled"]
    }
    assert all(
        run["documentdb_version"] == selection["documentdb_version"] and run["demonstration"]
        for run in runs
    )


@pytest.mark.parametrize("override", [False, True])
def test_single_integration_default_and_override(registry, selection, other_version, override):
    version = other_version if override else None
    runs = workflow.select_runs(
        registry, selection["integration"], version, selection["documentdb_version"]
    )
    assert runs == [
        {**selection, "version": version or selection["version"], "demonstration": False}
    ]


@pytest.mark.parametrize(
    ("integration", "version", "database", "error"),
    [
        ("all", "1.2.3", None, "single integration"),
        ("unknown", None, None, "Unknown or disabled"),
        (None, "not-a-version; echo unsafe", None, "outside the policy"),
        ("all", None, "99.99.99", "Unknown DocumentDB"),
    ],
)
def test_invalid_selection_is_rejected(registry, selection, integration, version, database, error):
    with pytest.raises(ValueError, match=error):
        workflow.select_runs(
            registry,
            integration or selection["integration"],
            version,
            database or selection["documentdb_version"],
        )


def test_disabled_or_empty_selection_is_rejected(registry, selection):
    for spec in registry["integrations"].values():
        spec["enabled"] = False
    with pytest.raises(ValueError, match="disabled"):
        workflow.select_runs(
            registry, selection["integration"], None, selection["documentdb_version"]
        )
    with pytest.raises(ValueError, match="No enabled"):
        workflow.select_runs(registry, "all", None, selection["documentdb_version"])


def test_matrix_cli_serializes_the_selected_runs(monkeypatch, capsys, selection, runs):
    monkeypatch.setattr(
        sys, "argv", ["workflow", "matrix", "--documentdb-version", selection["documentdb_version"]]
    )
    assert workflow.main() == 0
    assert json.loads(capsys.readouterr().out) == {"include": runs}


def test_matrix_cli_does_not_emit_a_plan_for_invalid_input(monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["workflow", "matrix", "--version", "1.2.3"])
    assert workflow.main() == 2
    captured = capsys.readouterr()
    assert not captured.out and "single integration" in captured.err


@pytest.mark.parametrize("authorized", [False, True])
def test_upstream_matrix_uses_only_ledger_authorized_artifacts(
    monkeypatch, capsys, selection, authorized
):
    def authorize(registry, runs, identifier, nonce):
        assert runs == [{**selection, "demonstration": False}]
        assert identifier == "a" * 64 and nonce == "b" * 32
        if not authorized:
            raise ValueError("Fixture ledger rejected this request")
        return ["c" * 64]

    monkeypatch.setattr(workflow, "validate_dispatch", authorize)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "workflow",
            "matrix",
            "--integration",
            selection["integration"],
            "--version",
            selection["version"],
            "--documentdb-version",
            selection["documentdb_version"],
            "--detection-id",
            "a" * 64,
            "--dispatch-id",
            "b" * 32,
        ],
    )
    assert workflow.main() == (0 if authorized else 2)
    captured = capsys.readouterr()
    if authorized:
        assert json.loads(captured.out)["include"] == [
            {
                **selection,
                "demonstration": False,
                "trigger": "upstream_release",
                "detection_id": "a" * 64,
                "artifact_sha256s": ["c" * 64],
            }
        ]
    else:
        assert not captured.out and "ledger rejected" in captured.err


@pytest.mark.parametrize("matching", [False, True])
def test_upstream_report_preserves_only_matching_detection_provenance(
    tmp_path, registry, runs, records, matching
):
    for record in records.values():
        record.update(trigger="upstream_release", detection_id="a" * 64, run_url=RUN_URL)
    incoming = write_records(tmp_path / "incoming", records)
    output = tmp_path / "report"
    assert (
        workflow.collect_report(
            incoming,
            output,
            registry,
            runs,
            expected_run_url=RUN_URL,
            detection_id=("a" if matching else "b") * 64,
        )
        is matching
    )
    _, rows, history = read_report(output)
    if matching:
        assert {record["integration"]: record for record in history} == records
        assert all(row["detection_id"] == "a" * 64 for row in rows.values())
        assert all(row["trigger"] == "upstream_release" for row in rows.values())
        assert "upstream\\_release" in (output / "summary.md").read_text()
        assert "a" * 64 in (output / "site/index.html").read_text()
    else:
        assert history == [] and all(row["state"] == "Not tested" for row in rows.values())


def test_combined_passes_preserve_envelopes_and_share_dashboard_data(
    tmp_path, registry, runs, records
):
    for record in records.values():
        record["run_url"] = RUN_URL
    incoming = write_records(tmp_path / "incoming", records)
    output = tmp_path / "report"
    summary = tmp_path / "step-summary"
    summary.write_text("Earlier step\n")
    assert workflow.collect_report(
        incoming, output, registry, runs, expected_run_url=RUN_URL, summary=summary
    )
    report, rows, history = read_report(output)
    assert report["schema_version"] == 1 and report["success"] and report["errors"] == []
    assert set(rows) == set(records)
    assert {record["integration"]: record for record in history} == records
    assert {path.stem for path in (output / "results").glob("*.json")} == {
        record["id"] for record in records.values()
    }
    for integration, row in rows.items():
        assert row["state"] == "Working"
        assert row["passed"] == row["expected"] == len(records[integration]["expected_tests"])
        assert row["run_url"] == RUN_URL and row["issue_url"] is None
    assert (
        json.loads((output / "site/current.json").read_text())["integrations"]
        == report["integrations"]
    )
    assert summary.read_text() == "Earlier step\n" + (output / "summary.md").read_text()
    assert "All selected profiles passed." in summary.read_text()


@pytest.mark.parametrize("outcome", ["failed", "error", "skipped", "infrastructure", "incomplete"])
def test_one_nonpassing_profile_does_not_erase_other_results(
    tmp_path, registry, selection, runs, records, outcome
):
    integration = selection["integration"]
    record = records[integration]
    if outcome == "infrastructure":
        record["tests"] = []
        record["execution_error"] = "Fixture unavailable"
    elif outcome == "incomplete":
        record["tests"].pop()
    else:
        record["tests"][0].update(outcome=outcome, message="Scenario diagnostic")
    incoming = write_records(tmp_path / "incoming", records)
    output = tmp_path / "report"
    assert not workflow.collect_report(incoming, output, registry, runs)
    report, rows, history = read_report(output)
    assert not report["success"]
    assert rows[integration]["state"] == ("Failing" if outcome == "failed" else "Not tested")
    assert all(row["state"] == "Working" for name, row in rows.items() if name != integration)
    assert {record["integration"]: record for record in history} == records


@pytest.mark.parametrize(
    ("field", "value", "diagnostic"),
    [
        (("integration",), "other", "selected integration"),
        (("upstream", "version"), "99.1.2", "selected integration"),
        (("documentdb", "version"), "99.1.2", "selected integration"),
        (("profile",), "other-profile", "selected integration"),
        (("demonstration",), True, "selected integration"),
        (("trigger",), "scheduled", "selected integration"),
        (("repository",), "https://github.com/example/other", "repository"),
        (("owner",), "@example/other", "owner"),
        (("suite_digest",), "0" * 64, "suite revision"),
        (("documentdb", "actual_extension_version"), "99.1-2", "installed extension"),
        (
            ("documentdb", "image"),
            "ghcr.io/documentdb/documentdb/documentdb-local@sha256:" + "0" * 64,
            "reviewed database artifact",
        ),
        (("upstream", "runtime", "name"), "nodejs", "runtime"),
        (("expected_tests",), ["test_other"], "undeclared scenario"),
    ],
)
def test_unmatched_or_unreviewed_evidence_is_rejected_independently(
    tmp_path, registry, selection, runs, records, field, value, diagnostic
):
    integration = selection["integration"]
    target = records[integration]
    for part in field[:-1]:
        target = target[part]
    target[field[-1]] = value
    incoming = write_records(tmp_path / "incoming", records)
    output = tmp_path / "report"
    assert not workflow.collect_report(incoming, output, registry, runs)
    _, rows, history = read_report(output)
    assert rows[integration]["state"] == "Not tested"
    assert diagnostic in rows[integration]["error"]
    assert rows[integration]["passed"] == 0 and rows[integration]["last_attempt"] is None
    assert all(row["state"] == "Working" for name, row in rows.items() if name != integration)
    assert {record["integration"] for record in history} == set(records) - {integration}


@pytest.mark.parametrize(
    "origin",
    [
        None,
        "https://github.com/example/project/actions/runs/42",
        "https://github.com/example/project/actions/runs/42/attempts/2",
        "https://github.com/example/other/actions/runs/42/attempts/3",
        "https://github.com/example/project/actions/runs/43/attempts/3",
    ],
)
def test_other_runs_and_attempts_never_fill_current_evidence(
    tmp_path, registry, selection, runs, records, origin
):
    for record in records.values():
        record["run_url"] = RUN_URL
    records[selection["integration"]]["run_url"] = origin
    incoming = write_records(tmp_path / "incoming", records)
    output = tmp_path / "report"
    assert not workflow.collect_report(incoming, output, registry, runs, expected_run_url=RUN_URL)
    _, rows, history = read_report(output)
    assert rows[selection["integration"]]["state"] == "Not tested"
    assert "workflow run" in rows[selection["integration"]]["error"]
    assert {record["integration"] for record in history} == set(records) - {
        selection["integration"]
    }


@pytest.mark.parametrize(
    "kind",
    [
        "absent",
        "json",
        "schema",
        "encoding",
        "oversized",
        "directory",
        "file-link",
        "directory-link",
    ],
)
def test_missing_or_malformed_artifacts_still_produce_a_combined_report(
    tmp_path, registry, selection, runs, records, kind
):
    integration = selection["integration"]
    incoming = write_records(tmp_path / "incoming", records)
    path = incoming / integration / "result.json"
    path.unlink()
    if kind == "json":
        path.write_text("{")
    elif kind == "schema":
        path.write_text("{}")
    elif kind == "encoding":
        path.write_bytes(b"\xff")
    elif kind == "oversized":
        path.write_bytes(b" " * (1024 * 1024 + 1))
    elif kind == "directory":
        path.mkdir()
    elif kind == "file-link":
        path.symlink_to(tmp_path / "absent.json")
    elif kind == "directory-link":
        path.parent.rmdir()
        path.parent.symlink_to(tmp_path / "absent-directory", target_is_directory=True)
    output = tmp_path / "report"
    assert not workflow.collect_report(incoming, output, registry, runs)
    report, rows, history = read_report(output)
    assert not report["success"] and rows[integration]["state"] == "Not tested"
    assert rows[integration]["error"].startswith("Result unavailable:")
    assert all(row["state"] == "Working" for name, row in rows.items() if name != integration)
    assert {record["integration"] for record in history} == set(records) - {integration}
    assert "Result unavailable:" in (output / "summary.md").read_text()


@pytest.mark.parametrize("missing", [False, True])
def test_override_has_only_the_selected_integration_and_version(
    tmp_path, registry, selection, other_version, records, missing
):
    runs = workflow.select_runs(
        registry, selection["integration"], other_version, selection["documentdb_version"]
    )
    incoming = tmp_path / "incoming"
    record = records[selection["integration"]]
    record["upstream"].update(version=other_version, actual_version=other_version)
    record["upstream"]["dependencies"][0]["version"] = other_version
    if not missing:
        write_records(incoming, {selection["integration"]: record})
    output = tmp_path / "report"
    assert workflow.collect_report(incoming, output, registry, runs) is not missing
    _, rows, history = read_report(output)
    assert set(rows) == {selection["integration"]}
    assert history == ([] if missing else [record])
    row = rows[selection["integration"]]
    assert (row["upstream_version"], row["state"], row["passed"]) == (
        other_version,
        "Not tested" if missing else "Working",
        0 if missing else len(record["expected_tests"]),
    )
    if missing:
        assert not list((output / "results").glob("*.json"))


@pytest.mark.parametrize("missing", [False, True])
def test_demonstrations_have_separate_rows_and_complete_expected_coverage(
    tmp_path, registry, selection, records, missing
):
    runs = workflow.select_runs(registry, "all", None, selection["documentdb_version"], True)
    for integration, record in records.items():
        record["demonstration"] = True
        record["expected_tests"] = expected_tests(registry["integrations"][integration], True)
        record["tests"].append(
            {
                "id": record["expected_tests"][-1],
                "outcome": "failed",
                "message": "Deliberate mismatch",
            }
        )
    incoming = tmp_path / "incoming"
    if not missing:
        write_records(incoming, records)
    output = tmp_path / "report"
    assert not workflow.collect_report(incoming, output, registry, runs)
    _, rows, history = read_report(output)
    assert set(rows) == set(records)
    for integration, row in rows.items():
        assert row["demonstration"]
        assert row["scenarios"] == expected_tests(registry["integrations"][integration], True)
        assert row["expected"] == len(row["scenarios"])
        assert row["state"] == ("Not tested" if missing else "Failing")
    assert all(record["demonstration"] for record in history)
    assert "Demonstration" in (output / "summary.md").read_text()


def test_conflicting_ids_do_not_overwrite_other_integration_evidence(
    tmp_path, registry, selection, record, monkeypatch
):
    first = deepcopy(record)
    second = {**deepcopy(record), "integration": "additional"}
    registry["integrations"]["additional"] = deepcopy(
        registry["integrations"][first["integration"]]
    )
    # Exercise cross-integration collisions without requiring a second real adapter.
    monkeypatch.setattr("compatibility.publish.suite_digest", lambda *_: first["suite_digest"])
    runs = [
        {**selection, "demonstration": False},
        {**selection, "integration": "additional", "demonstration": False},
    ]
    records = {first["integration"]: first, second["integration"]: second}
    incoming = write_records(tmp_path / "incoming", records)
    output = tmp_path / "report"
    assert not workflow.collect_report(incoming, output, registry, runs)
    _, rows, history = read_report(output)
    assert rows[first["integration"]]["state"] == "Working"
    assert rows[second["integration"]]["state"] == "Not tested"
    assert "same run ID" in rows[second["integration"]]["error"]
    assert first in history and second not in history


def test_unexpected_artifacts_are_reported_without_erasing_valid_results(
    tmp_path, registry, runs, records
):
    incoming = write_records(tmp_path / "incoming", records)
    (incoming / "unexpected").mkdir()
    output = tmp_path / "report"
    assert not workflow.collect_report(incoming, output, registry, runs)
    report, rows, history = read_report(output)
    assert report["errors"] and not report["success"]
    assert all(row["state"] == "Working" for row in rows.values())
    assert {record["integration"]: record for record in history} == records
    assert "Reporting errors" in (output / "summary.md").read_text()


def test_nested_report_is_not_mistaken_for_an_incoming_artifact(tmp_path, registry, runs, records):
    incoming = write_records(tmp_path / "incoming", records)
    output = incoming / "report"
    assert workflow.collect_report(incoming, output, registry, runs)
    report, _, history = read_report(output)
    assert report["errors"] == []
    assert {record["integration"]: record for record in history} == records


def test_existing_report_and_symbolic_input_root_are_rejected(tmp_path, registry, runs, records):
    incoming = write_records(tmp_path / "incoming", records)
    output = tmp_path / "report"
    output.mkdir()
    sentinel = output / "preserved"
    sentinel.write_text("Original report")
    with pytest.raises(ValueError, match="overwrite"):
        workflow.collect_report(incoming, output, registry, runs)
    assert sentinel.read_text() == "Original report"
    link = tmp_path / "linked"
    link.symlink_to(incoming, target_is_directory=True)
    with pytest.raises(ValueError, match="symbolic link"):
        workflow.collect_report(link, tmp_path / "another-report", registry, runs)


def test_expired_success_is_not_reported_as_a_current_pass(
    tmp_path, registry, selection, runs, records
):
    record = records[selection["integration"]]
    age = timedelta(days=registry["integrations"][selection["integration"]]["freshness_days"] + 1)
    for key in ("started_at", "finished_at"):
        record[key] = (timestamp(record[key]) - age).isoformat()
    incoming = write_records(tmp_path / "incoming", records)
    output = tmp_path / "report"
    assert not workflow.collect_report(incoming, output, registry, runs)
    _, rows, _ = read_report(output)
    assert rows[selection["integration"]]["state"] == "Stale"


def test_summary_diagnostics_cannot_inject_markup_or_extra_rows(
    tmp_path, registry, selection, runs, records
):
    records[selection["integration"]]["tests"][0].update(
        outcome="failed", message="<script>bad</script>\n| Working | [click](https://example.com)\r"
    )
    incoming = write_records(tmp_path / "incoming", records)
    output = tmp_path / "report"
    assert not workflow.collect_report(incoming, output, registry, runs)
    summary = (output / "summary.md").read_text()
    assert "<script>" not in summary and "&lt;script&gt;" in summary
    assert "\\| Working \\|" in summary
    assert "\\[click\\]\\(https://example.com\\)" in summary
    assert len([line for line in summary.splitlines() if line.startswith("|")]) == len(runs) + 2


@pytest.mark.parametrize("outcome", ["pass", "fail", "missing"])
def test_report_cli_returns_failure_without_losing_the_summary(
    tmp_path, monkeypatch, registry, selection, records, outcome
):
    incoming = tmp_path / "incoming"
    if outcome == "fail":
        records[selection["integration"]]["tests"][0]["outcome"] = "failed"
    if outcome != "missing":
        write_records(incoming, records)
    output = tmp_path / "report"
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "workflow",
            "report",
            "--input",
            str(incoming),
            "--output",
            str(output),
            "--documentdb-version",
            selection["documentdb_version"],
        ],
    )
    assert workflow.main() == (0 if outcome == "pass" else 1)
    report, _, _ = read_report(output)
    assert report["success"] == (outcome == "pass")
