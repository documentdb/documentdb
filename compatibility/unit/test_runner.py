# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Runner failure envelopes and resource/credential boundaries."""

import io
import json
import shutil
import subprocess
import sys
import time

import pytest

from compatibility import runner
from compatibility.contracts import ROOT, compatibility_state, suite_files

pytestmark = pytest.mark.unit


def test_client_context_has_only_declared_execution_inputs(prepared_context):
    expected = {path.relative_to(ROOT) for path in suite_files("pymongo")}
    actual = {
        path.relative_to(prepared_context)
        for path in (prepared_context / "compatibility").rglob("*")
        if path.is_file()
    }
    assert actual == expected
    assert not (prepared_context / "documentdb_tests").exists()


def test_shell_metacharacters_rejected_before_execution(tmp_path, registry, monkeypatch):
    def unexpected(*args, **kwargs):
        pytest.fail("Invalid version must not reach package installation")

    monkeypatch.setattr(runner, "prepare_client", unexpected)
    with pytest.raises(ValueError, match="policy"):
        runner.execute(
            registry, "pymongo", "4.18.0;echo unsafe", "0.117.0", tmp_path / "result.json"
        )


@pytest.mark.parametrize("trigger", ["manual", "push"])
def test_setup_failure_produces_not_tested_and_cleans_up(tmp_path, registry, monkeypatch, trigger):
    cleaned = []

    def unavailable(*args, **kwargs):
        raise RuntimeError("Package download unavailable")

    monkeypatch.setattr(runner, "prepare_client", unavailable)
    monkeypatch.setattr(runner, "cleanup", lambda *args: cleaned.append(args) or [])
    result = runner.execute(
        registry, "pymongo", "4.18.0", "0.117.0", tmp_path / "result.json", trigger=trigger
    )
    assert (
        compatibility_state(result) == "Not tested"
        and cleaned
        and (tmp_path / "result.json").is_file()
    )
    assert result["trigger"] == trigger


@pytest.mark.parametrize("trigger", ["manual", "push"])
def test_cli_forwards_the_execution_trigger(tmp_path, record, monkeypatch, trigger):
    captured = {}

    def execute(*args, **kwargs):
        captured.update(kwargs)
        return record

    monkeypatch.setattr(runner, "execute", execute)
    monkeypatch.setattr(
        sys,
        "argv",
        ["runner", "--output", str(tmp_path / "result.json"), "--trigger", trigger],
    )
    assert runner.main() == 0
    assert captured["trigger"] == trigger


def test_cleanup_uses_only_the_invocation_label(monkeypatch):
    calls = []

    def fake(arguments, **kwargs):
        calls.append(arguments)
        return subprocess.CompletedProcess(arguments, 0, "", "")

    monkeypatch.setattr(runner, "command", fake)
    runner.cleanup("a" * 32, "")
    assert all(f"label={runner.LABEL}=" + "a" * 32 in call for call in calls)


def test_plain_and_encoded_credentials_are_redacted():
    secret = "synthetic-fixture!"
    value = f"{secret} synthetic-fixture%21 protocol://user:another-fixture@host"
    assert runner.redact(value, secret) == "[REDACTED] [REDACTED] protocol://[REDACTED]@host"


def test_command_timeout_is_an_explicit_failure():
    with pytest.raises(RuntimeError, match="limit"):
        runner.command([sys.executable, "-c", "import time; time.sleep(5)"], timeout=1)


def test_command_output_limit_is_an_explicit_failure(monkeypatch):
    monkeypatch.setattr(runner, "MAX_COMMAND_OUTPUT", 10)
    with pytest.raises(RuntimeError, match="limit"):
        runner.command([sys.executable, "-c", "print('a' * 100)"])


def test_command_timeout_stops_descendants(tmp_path):
    marker = tmp_path / "descendant-output"
    child = "import sys,time; from pathlib import Path; time.sleep(2); Path(sys.argv[1]).touch()"
    parent = (
        "import subprocess,sys,time; "
        "subprocess.Popen([sys.executable, '-c', sys.argv[1], sys.argv[2]]); time.sleep(5)"
    )
    with pytest.raises(RuntimeError, match="limit"):
        runner.command([sys.executable, "-c", parent, child, str(marker)], timeout=1)
    time.sleep(1.5)
    assert not marker.exists()


def test_failure_record_does_not_include_fixture_credentials(tmp_path, registry, monkeypatch):
    monkeypatch.setattr(runner.secrets, "token_urlsafe", lambda size: "synthetic-fixture")
    monkeypatch.setattr(runner, "cleanup", lambda *args: [])

    def unavailable(*args, **kwargs):
        raise RuntimeError("synthetic-fixtureAa1! connection failed")

    monkeypatch.setattr(runner, "prepare_client", unavailable)
    output = tmp_path / "result.json"
    runner.execute(registry, "pymongo", "4.18.0", "0.117.0", output)
    assert (
        "synthetic-fixtureAa1!" not in output.read_text()
        and json.loads(output.read_text())["execution_error"]
    )
    assert "synthetic-fixtureAa1!" not in output.with_suffix(".log").read_text()


@pytest.mark.parametrize("suffix", [".json", ".log", ".xml"])
def test_existing_result_and_diagnostics_are_preserved(tmp_path, registry, suffix):
    output = tmp_path / "result.json"
    existing = output.with_suffix(suffix)
    existing.write_text("Earlier evidence")
    with pytest.raises(ValueError, match="overwrite"):
        runner.execute(registry, "pymongo", "4.18.0", "0.117.0", output)
    assert existing.read_text() == "Earlier evidence"


def test_result_path_cannot_collide_with_its_diagnostics(tmp_path, registry):
    with pytest.raises(ValueError, match=".json extension"):
        runner.execute(registry, "pymongo", "4.18.0", "0.117.0", tmp_path / "result.log")


def test_long_setup_error_keeps_its_root_cause_and_full_diagnostic(tmp_path, registry, monkeypatch):
    def unavailable(*args, **kwargs):
        raise RuntimeError("Download failed\n" + "traceback frame\n" * 400 + "TLS handshake failed")

    monkeypatch.setattr(runner, "prepare_client", unavailable)
    monkeypatch.setattr(runner, "cleanup", lambda *args: [])
    output = tmp_path / "result.json"
    record = runner.execute(registry, "pymongo", "4.18.0", "0.117.0", output)
    assert len(record["execution_error"]) == 2000
    assert record["execution_error"].startswith("RuntimeError: Download failed")
    assert record["execution_error"].endswith("TLS handshake failed")
    assert output.with_suffix(".log").read_text().count("traceback frame") == 400
    assert compatibility_state(record) == "Not tested"


def test_cleanup_errors_are_retained_in_the_controller_log(tmp_path, registry, monkeypatch):
    def unavailable(*args, **kwargs):
        raise RuntimeError("Setup unavailable")

    monkeypatch.setattr(runner, "prepare_client", unavailable)
    monkeypatch.setattr(runner, "cleanup", lambda *args: ["Cleanup network: daemon unavailable"])
    output = tmp_path / "result.json"
    record = runner.execute(registry, "pymongo", "4.18.0", "0.117.0", output)
    assert "Cleanup network: daemon unavailable" in record["execution_error"]
    assert "Cleanup network: daemon unavailable" in output.with_suffix(".log").read_text()


def test_download_uses_the_adapter_requirements_and_target_runtime(
    prepared_context, tmp_path, registry, monkeypatch
):
    calls = []
    selected = next((prepared_context / "wheels").glob("pymongo-*.whl"))

    def download(arguments, **kwargs):
        calls.append(arguments)
        destination = arguments[arguments.index("--dest") + 1]
        shutil.copyfile(selected, f"{destination}/{selected.name}")

    monkeypatch.setattr(runner, "command", download)
    context = tmp_path / "download-context"
    context.mkdir()
    runner.prepare_client(context, registry["integrations"]["pymongo"], "4.18.0", None)
    arguments = calls[0]
    assert arguments[:4] == [sys.executable, "-m", "pip", "download"]
    assert arguments[arguments.index("--python-version") + 1] == "312"
    assert arguments[arguments.index("-r") + 1] == str(
        ROOT / "compatibility/integrations/pymongo/requirements.txt"
    )
    assert "--only-binary=:all:" in arguments
    assert "pymongo==4.18.0" in arguments


@pytest.mark.parametrize("reason", ["yanked", "hash", "filename"])
def test_unverified_or_withdrawn_wheel_is_rejected(
    prepared_context, tmp_path, registry, monkeypatch, reason
):
    selected = next((prepared_context / "wheels").glob("pymongo-*.whl"))
    asset = {
        "filename": selected.name,
        "yanked": False,
        "digests": {"sha256": runner.hashlib.sha256(selected.read_bytes()).hexdigest()},
    }
    if reason == "yanked":
        asset["yanked"] = True
    elif reason == "hash":
        asset["digests"]["sha256"] = "0" * 64
    else:
        asset["filename"] = "different.whl"
    monkeypatch.setattr(
        runner.urllib.request,
        "urlopen",
        lambda *args, **kwargs: io.BytesIO(json.dumps({"urls": [asset]}).encode()),
    )
    context = tmp_path / "rejected-context"
    context.mkdir()
    with pytest.raises(ValueError, match="eligible published artifact"):
        runner.prepare_client(
            context, registry["integrations"]["pymongo"], "4.18.0", prepared_context / "wheels"
        )
