# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Immutable history, honest freshness, safe rendering, and issue-form links."""

import json
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from datetime import timedelta
from urllib.parse import parse_qs, urlparse

import pytest

from compatibility.contracts import DEMONSTRATION_TEST, timestamp
from compatibility.publish import append_result, dashboard_rows, read_result, render

pytestmark = pytest.mark.unit


def row_for(rows, record):
    return next(row for row in rows if any(r["id"] == record["id"] for r in row["history"]))


def test_append_is_idempotent(tmp_path, record):
    path = append_result(tmp_path, record)
    append_result(tmp_path, record)
    assert read_result(path) == record


def test_existing_result_cannot_be_overwritten(tmp_path, record):
    append_result(tmp_path, record)
    changed = deepcopy(record)
    changed["tests"][0]["outcome"] = "failed"
    with pytest.raises(ValueError, match="overwrite"):
        append_result(tmp_path, changed)


def test_symlink_result_rejected(tmp_path, record):
    original = append_result(tmp_path / "original", record)
    link = tmp_path / "linked.json"
    link.symlink_to(original)
    with pytest.raises(ValueError, match="regular JSON"):
        read_result(link)


def test_result_history_remains_after_later_failure(tmp_path, record, registry):
    append_result(tmp_path / "data", record)
    failed = deepcopy(record)
    failed["id"] = "d" * 32
    failed["started_at"] = record["finished_at"]
    failed["tests"][0]["outcome"] = "failed"
    append_result(tmp_path / "data", failed)
    rows = render(tmp_path / "data", tmp_path / "site", registry)
    row = row_for(rows, record)
    assert (row["state"], len(row["history"])) == ("Failing", 2)


def test_arrival_order_does_not_overwrite_a_newer_failure(record, registry):
    failed = deepcopy(record)
    failed["id"] = "d" * 32
    failed["started_at"] = record["finished_at"]
    failed["tests"][0]["outcome"] = "failed"
    rows = dashboard_rows(
        [failed, record], registry, timestamp(record["finished_at"]), "documentdb/documentdb"
    )
    assert row_for(rows, record)["state"] == "Failing"


def test_infrastructure_failure_keeps_conclusive_result_and_attempt_error(record, registry):
    unavailable = deepcopy(record)
    unavailable["id"] = "d" * 32
    unavailable["started_at"] = record["finished_at"]
    unavailable["tests"] = []
    unavailable["execution_error"] = "Artifact download unavailable"
    rows = dashboard_rows(
        [record, unavailable],
        registry,
        timestamp(record["finished_at"]),
        "documentdb/documentdb",
    )
    row = row_for(rows, record)
    assert (row["state"], row["latest_attempt_state"], row["error"]) == (
        "Working",
        "Not tested",
        "Artifact download unavailable",
    )


def test_configured_freshness_boundary(record, registry):
    days = registry["integrations"][record["integration"]]["freshness_days"]
    boundary = timestamp(record["finished_at"]) + timedelta(days=days)
    fresh = dashboard_rows([record], registry, boundary, "documentdb/documentdb")
    stale = dashboard_rows(
        [record], registry, boundary + timedelta(milliseconds=1), "documentdb/documentdb"
    )
    assert (row_for(fresh, record)["state"], row_for(stale, record)["state"]) == (
        "Working",
        "Stale",
    )


def test_changed_suite_is_stale(record, registry):
    record["suite_digest"] = "0" * 64
    rows = dashboard_rows(
        [record], registry, timestamp(record["finished_at"]), "documentdb/documentdb"
    )
    assert row_for(rows, record)["state"] == "Stale"


def test_new_version_does_not_inherit_an_old_pass(record, registry, other_version):
    newer = deepcopy(record)
    newer["id"] = "d" * 32
    newer["upstream"]["version"] = other_version
    newer["upstream"]["actual_version"] = None
    newer["tests"] = []
    newer["execution_error"] = "Not installed"
    rows = dashboard_rows(
        [record, newer], registry, timestamp(record["finished_at"]), "documentdb/documentdb"
    )
    assert row_for(rows, record)["state"] == "Working"
    assert row_for(rows, newer)["state"] == "Not tested"


def test_synthetic_failure_does_not_poison_real_compatibility(record, registry):
    demonstration = deepcopy(record)
    demonstration["id"] = "d" * 32
    demonstration["demonstration"] = True
    demonstration["expected_tests"].append(DEMONSTRATION_TEST)
    demonstration["tests"].append(
        {"id": DEMONSTRATION_TEST, "outcome": "failed", "message": "Deliberate mismatch"}
    )
    rows = dashboard_rows(
        [record, demonstration],
        registry,
        timestamp(record["finished_at"]),
        "documentdb/documentdb",
    )
    assert row_for(rows, record)["state"] == "Working"
    assert row_for(rows, demonstration)["state"] == "Failing"


def test_html_escapes_failure_text_and_preserves_machine_readable_history(
    tmp_path, record, registry
):
    record["tests"][0].update(outcome="failed", message="<script>alert('test')</script>")
    append_result(tmp_path / "data", record)
    render(tmp_path / "data", tmp_path / "site", registry)
    html = (tmp_path / "site" / "index.html").read_text()
    history = json.loads((tmp_path / "site" / "history.json").read_text())
    assert "<script>alert" not in html and "&lt;script&gt;" in html and history == [record]


def test_issue_form_fields_are_prefilled(record, registry):
    rows = dashboard_rows(
        [record], registry, timestamp(record["finished_at"]), "documentdb/documentdb"
    )
    fields = parse_qs(urlparse(row_for(rows, record)["issue_url"]).query)
    assert (
        fields["integration"],
        fields["documentdb_version"],
        fields["upstream_version"],
        fields["template"],
    ) == (
        [record["integration"]],
        [record["documentdb"]["version"]],
        [record["upstream"]["version"]],
        ["compatibility-report.yml"],
    )


def test_empty_dashboard_does_not_claim_compatibility(tmp_path, registry):
    rows = render(tmp_path / "absent", tmp_path / "site", registry)
    expected_pairs = {
        (integration, version)
        for integration, spec in registry["integrations"].items()
        if spec["enabled"]
        for version in registry["documentdb"]
    }
    assert {(row["integration"], row["documentdb_version"]) for row in rows} == expected_pairs
    assert all((row["state"], row["last_attempt"]) == ("Not tested", None) for row in rows)
    assert all(
        urlparse(row["issue_url"]).path == "/documentdb/documentdb/issues/new" for row in rows
    )


def test_preview_is_labeled_and_does_not_offer_unprovisioned_issue_reporting(
    tmp_path, record, registry
):
    append_result(tmp_path / "data", record)
    rows = render(tmp_path / "data", tmp_path / "site", registry, preview=True)
    html = (tmp_path / "site" / "index.html").read_text()
    current = json.loads((tmp_path / "site" / "current.json").read_text())
    assert "Review prototype." in html and "not an official compatibility support matrix" in html
    assert "Report a compatibility problem" not in html
    assert all(row["issue_url"] is None for row in rows)
    assert all(row["issue_url"] is None for row in current["integrations"])
    assert row_for(rows, record)["state"] == "Working"


def test_concurrent_appends_preserve_both_results(tmp_path, record):
    other = deepcopy(record)
    other["id"] = "d" * 32
    with ThreadPoolExecutor(max_workers=2) as executor:
        list(executor.map(lambda result: append_result(tmp_path, result), [record, other]))
    assert {path.stem for path in tmp_path.glob("*.json")} == {record["id"], other["id"]}


def test_store_directory_symlinks_are_rejected(tmp_path, record):
    store = tmp_path / "store"
    store.mkdir()
    link = tmp_path / "linked"
    link.symlink_to(store, target_is_directory=True)
    with pytest.raises(ValueError, match="symbolic link"):
        append_result(link, record)


def test_old_failure_details_remain_visible_after_a_success(tmp_path, record, registry):
    failed = deepcopy(record)
    failed["id"] = "d" * 32
    failed["started_at"] = (timestamp(record["started_at"]) - timedelta(minutes=1)).isoformat()
    failed["finished_at"] = record["started_at"]
    failed["tests"][0].update(outcome="failed", message="Earlier assertion mismatch")
    append_result(tmp_path / "data", failed)
    append_result(tmp_path / "data", record)
    rows = render(tmp_path / "data", tmp_path / "site", registry)
    assert (
        row_for(rows, record)["state"] == "Working"
        and "Earlier assertion mismatch" in (tmp_path / "site" / "index.html").read_text()
    )
