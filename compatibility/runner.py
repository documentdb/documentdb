# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Run a reviewed integration against a released image in disposable Docker resources."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from compatibility.contracts import (
    ROOT,
    compatibility_state,
    expected_tests,
    read_registry,
    suite_digest,
    suite_files,
    validate_client_report,
    validate_result,
)

LABEL = "org.documentdb.compatibility.run"
MAX_COMMAND_OUTPUT = 4 * 1024 * 1024


def command(arguments: list[str], timeout: int = 180, check: bool = True):
    """Bound both command duration and captured output; never execute a shell string."""
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        with subprocess.Popen(
            arguments, stdout=stdout, stderr=stderr, start_new_session=True
        ) as process:
            deadline = time.monotonic() + timeout
            while process.poll() is None:
                if (
                    time.monotonic() > deadline
                    or os.fstat(stdout.fileno()).st_size > MAX_COMMAND_OUTPUT
                    or os.fstat(stderr.fileno()).st_size > MAX_COMMAND_OUTPUT
                ):
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                    raise RuntimeError(f"{arguments[0]} exceeded its time or output limit")
                time.sleep(0.1)
            stdout.seek(0)
            stderr.seek(0)
            if (
                max(os.fstat(stdout.fileno()).st_size, os.fstat(stderr.fileno()).st_size)
                > MAX_COMMAND_OUTPUT
            ):
                raise RuntimeError(f"{arguments[0]} exceeded its output limit")
            result = subprocess.CompletedProcess(
                arguments,
                process.returncode,
                stdout.read(MAX_COMMAND_OUTPUT).decode("utf-8", errors="replace"),
                stderr.read(MAX_COMMAND_OUTPUT).decode("utf-8", errors="replace"),
            )
    if check and result.returncode != 0:
        raise RuntimeError(
            f"{arguments[0]} exited {result.returncode}: "
            f"{(result.stderr or result.stdout)[-4000:]}"
        )
    return result


def redact(text: str, password: str) -> str:
    """Strip fixture credentials before producing any retained output."""
    text = text.replace(password, "[REDACTED]")
    text = text.replace(urllib.parse.quote(password, safe=""), "[REDACTED]")
    return re.sub(r"(?i)([a-z][a-z0-9+.-]*://)[^/\s@]+@", r"\1[REDACTED]@", text)


def record_error(output: Path, message: str, password: str) -> str:
    """Retain controller diagnostics and keep the terminal cause in bounded summaries."""
    sanitized = redact(message, password)
    with output.with_suffix(".log").open("a") as log:
        log.write(f"\nController error:\n{sanitized}\n")
    if len(sanitized) <= 2000:
        return sanitized
    return sanitized[:200] + "\n...\n" + sanitized[-1795:]


def prepare_client(
    context: Path, spec: dict[str, Any], version: str, wheelhouse: Path | None
) -> str:
    """Download binary wheels only and verify the selected artifact against publisher metadata."""
    wheels = context / "wheels"
    wheels.mkdir()
    requirements = ROOT / Path(spec["test_file"]).parent / "requirements.txt"
    if wheelhouse is not None:
        for source in wheelhouse.glob("*.whl"):
            if source.is_symlink():
                raise ValueError("Wheel inputs must not be symbolic links")
            shutil.copyfile(source, wheels / source.name)
    else:
        command(
            [
                sys.executable,
                "-m",
                "pip",
                "download",
                "--disable-pip-version-check",
                "--only-binary=:all:",
                "--python-version",
                "312",
                "--implementation",
                "cp",
                "--abi",
                "cp312",
                "--platform",
                "manylinux_2_28_x86_64",
                "--platform",
                "manylinux_2_17_x86_64",
                "--platform",
                "manylinux2014_x86_64",
                "--platform",
                "manylinux1_x86_64",
                "--dest",
                str(wheels),
                "-r",
                str(requirements),
                f"{spec['package']}=={version}",
            ],
            timeout=600,
        )
    candidates = list(wheels.glob(f"{spec['package'].replace('-', '_')}-{version}-*.whl"))
    if len(candidates) != 1:
        raise ValueError("Expected exactly one wheel for the requested integration version")
    selected = candidates[0]
    digest = hashlib.sha256(selected.read_bytes()).hexdigest()
    metadata_url = f"https://pypi.org/pypi/{spec['package']}/{version}/json"
    with urllib.request.urlopen(metadata_url, timeout=30) as response:
        metadata = json.load(response)
    matching = [
        asset
        for asset in metadata["urls"]
        if asset["filename"] == selected.name
        and not asset["yanked"]
        and asset["digests"]["sha256"] == digest
    ]
    if len(matching) != 1:
        raise ValueError("Selected wheel does not match an eligible published artifact")
    (context / "integration-requirements.txt").write_text(
        f"-r /requirements.txt\n{spec['package']}=={version}\n"
    )
    for source in suite_files(Path(spec["test_file"]).parent.name):
        destination = context / source.relative_to(ROOT)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    return digest


def cleanup(run_id: str, image: str) -> list[str]:
    """Resolve only this invocation's labeled resources; cleanup errors remain visible."""
    errors = []
    for kind, listing, removal in (
        ("containers", ["docker", "ps", "-aq"], ["docker", "rm", "-fv"]),
        ("networks", ["docker", "network", "ls", "-q"], ["docker", "network", "rm"]),
    ):
        try:
            identifiers = command(listing + ["--filter", f"label={LABEL}={run_id}"]).stdout.split()
            if any(not re.fullmatch("[a-f0-9]{12,64}", identifier) for identifier in identifiers):
                raise RuntimeError("Unexpected Docker resource identifier")
            if identifiers:
                command(removal + identifiers)
        except (OSError, RuntimeError) as error:
            errors.append(f"Cleanup {kind}: {error}")
    if image:
        try:
            command(["docker", "image", "rm", image])
        except (OSError, RuntimeError) as error:
            errors.append(f"Cleanup image: {error}")
    return errors


def execute(
    registry: dict[str, Any],
    integration: str,
    version: str,
    documentdb_version: str,
    output: Path,
    *,
    wheelhouse: Path | None = None,
    demonstration: bool = False,
    run_url: str | None = None,
    trigger: str = "manual",
) -> dict[str, Any]:
    """Emit a validated result even when setup, execution, or teardown fails."""
    spec = registry["integrations"][integration]
    database = registry["documentdb"][documentdb_version]
    if (
        not spec["enabled"]
        or len(version) > 40
        or not re.fullmatch(spec["version_pattern"], version)
    ):
        raise ValueError("Integration is disabled or the requested version is outside its policy")
    if output.suffix != ".json":
        raise ValueError("Result output must use a .json extension")
    if any(
        path.exists() or path.is_symlink()
        for path in (output, output.with_suffix(".log"), output.with_suffix(".xml"))
    ):
        raise ValueError("Refusing to overwrite an existing result or diagnostic file")
    run_id = uuid.uuid4().hex
    started = datetime.now(timezone.utc).isoformat()
    result: dict[str, Any] = {
        "schema_version": 1,
        "id": run_id,
        "integration": integration,
        "repository": spec["repository"],
        "owner": spec["owner"],
        "profile": spec["profile"],
        "suite_digest": suite_digest(integration, spec),
        "documentdb": {
            "version": documentdb_version,
            "image": database["image"],
            "actual_extension_version": None,
            "actual_postgres_version": None,
        },
        "upstream": {
            "version": version,
            "actual_version": None,
            "wheel_sha256": None,
            "client_image": None,
            "python_version": None,
            "dependencies": [],
        },
        "expected_tests": expected_tests(spec, demonstration),
        "tests": [],
        "started_at": started,
        "finished_at": started,
        "trigger": trigger,
        "run_url": run_url,
        "demonstration": demonstration,
        "execution_error": None,
    }
    validate_result(result, spec)
    password = secrets.token_urlsafe(24) + "Aa1!"
    image = ""
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="docdb-compat-") as directory:
            context = Path(directory) / "context"
            context.mkdir()
            result["upstream"]["wheel_sha256"] = prepare_client(context, spec, version, wheelhouse)
            result["suite_digest"] = suite_digest(integration, spec, root=context)
            candidate_image = f"docdb-compat-{run_id}"
            command(
                [
                    "docker",
                    "build",
                    "--network",
                    "none",
                    "--platform",
                    "linux/amd64",
                    "-t",
                    candidate_image,
                    "-f",
                    str(context / "compatibility" / "integrations" / integration / "Dockerfile"),
                    str(context),
                ],
                timeout=600,
            )
            image = candidate_image
            result["upstream"]["client_image"] = command(
                ["docker", "image", "inspect", image, "--format", "{{.Id}}"]
            ).stdout.strip()
            network = command(
                ["docker", "network", "create", "--internal", "--label", f"{LABEL}={run_id}", image]
            ).stdout.strip()
            environment = Path(directory) / "fixture.env"
            with environment.open("x") as file:
                os.chmod(environment, 0o600)
                file.write(f"USERNAME=compat_user\nPASSWORD={password}\n")
            server = command(
                [
                    "docker",
                    "run",
                    "-d",
                    "--platform",
                    "linux/amd64",
                    "--label",
                    f"{LABEL}={run_id}",
                    "--network",
                    network,
                    "--network-alias",
                    "db",
                    "--env-file",
                    str(environment),
                    "--env",
                    "TLS_MODE=requireTLS",
                    "--env",
                    "ENABLE_TELEMETRY=false",
                    "--memory=2g",
                    "--cpus=2",
                    "--shm-size=256m",
                    database["image"],
                ]
            ).stdout.strip()
            deadline = time.monotonic() + 180
            while True:
                running = command(
                    ["docker", "inspect", server, "--format", "{{.State.Running}}"]
                ).stdout.strip()
                logs = command(["docker", "logs", server])
                if running != "true":
                    raise RuntimeError("Database exited before readiness: " + logs.stdout[-2000:])
                if "=== DocumentDB is ready ===" in logs.stdout + logs.stderr:
                    break
                if time.monotonic() > deadline:
                    raise RuntimeError("Database readiness timed out")
                time.sleep(2)
            query = (
                "SELECT json_build_object('postgres', current_setting('server_version'),"
                "'extension', (SELECT extversion FROM pg_extension WHERE extname='documentdb'));"
            )
            actual = json.loads(
                command(
                    [
                        "docker",
                        "exec",
                        server,
                        "psql",
                        "-X",
                        "-p",
                        "9712",
                        "-d",
                        "postgres",
                        "-Atc",
                        query,
                    ]
                ).stdout
            )
            if (
                actual["extension"] != database["extension_version"]
                or int(actual["postgres"].split(".")[0]) != database["postgres_major"]
            ):
                raise ValueError(
                    "Actual database versions do not match the selected release profile"
                )
            result["documentdb"]["actual_extension_version"] = actual["extension"]
            result["documentdb"]["actual_postgres_version"] = actual["postgres"]
            process = command(
                [
                    "docker",
                    "run",
                    "--label",
                    f"{LABEL}={run_id}",
                    "--network",
                    network,
                    "--env-file",
                    str(environment),
                    "--read-only",
                    "--tmpfs",
                    "/tmp:size=128m",
                    "--cap-drop=ALL",
                    "--security-opt=no-new-privileges",
                    "--memory=512m",
                    "--cpus=1",
                    "--env",
                    f"COMPATIBILITY_PACKAGE={spec['package']}",
                    "--env",
                    f"COMPATIBILITY_TEST_FILE={spec['test_file']}",
                    "--env",
                    f"COMPATIBILITY_DEMONSTRATION_FILE={spec['demonstration_file']}",
                    "--env",
                    f"COMPATIBILITY_DEMONSTRATION={int(demonstration)}",
                    image,
                ],
                timeout=spec["timeout_seconds"],
                check=False,
            )
            output.with_suffix(".log").write_text(redact(process.stderr, password))
            payload = json.loads(process.stdout)
            validate_client_report(payload)
            if (
                payload["version"] != version
                or payload["wheel_sha256"] != result["upstream"]["wheel_sha256"]
                or not payload["python"].startswith("3.12.")
                or not any(
                    entry["name"].lower().replace("-", "_") == spec["package"].replace("-", "_")
                    and entry["version"] == version
                    and entry["sha256"] == result["upstream"]["wheel_sha256"]
                    for entry in payload["dependencies"]
                )
            ):
                raise ValueError(
                    "Installed integration artifact or runtime does not match the request"
                )
            result["upstream"]["actual_version"] = payload["version"]
            result["upstream"]["python_version"] = payload["python"]
            result["upstream"]["dependencies"] = payload["dependencies"]
            result["tests"] = payload["tests"]
            for test in result["tests"]:
                test["message"] = redact(test["message"], password)[:2000]
            validate_result(result, spec)
            output.with_suffix(".xml").write_text(redact(payload["junit"], password))
            if process.returncode not in (0, 1) or payload["exit_code"] != process.returncode:
                raise RuntimeError("Test process did not complete normally")
            if process.returncode and all(t["outcome"] == "passed" for t in result["tests"]):
                raise RuntimeError("Test process failed without a corresponding test outcome")
    except (OSError, ValueError, RuntimeError, KeyError, StopIteration) as error:
        result["execution_error"] = record_error(
            output, f"{type(error).__name__}: {error}", password
        )
        try:
            validate_result(result, spec)
        except ValueError:
            result["tests"] = []
    finally:
        errors = cleanup(run_id, image)
        if errors:
            combined = "; ".join(filter(None, [result["execution_error"], *errors]))
            result["execution_error"] = record_error(output, combined, password)
    result["finished_at"] = datetime.now(timezone.utc).isoformat()
    validate_result(result, spec)
    with output.open("x") as file:
        json.dump(result, file, indent=2, allow_nan=False)
        file.write("\n")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--integration", default="pymongo")
    parser.add_argument("--version", help="Defaults to the selected integration's registry version")
    parser.add_argument("--documentdb-version", default="0.117.0")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--wheelhouse", type=Path)
    parser.add_argument("--run-url")
    parser.add_argument("--trigger", choices=("manual", "push"), default="manual")
    parser.add_argument("--demonstration", action="store_true")
    args = parser.parse_args()
    try:
        registry = read_registry()
        version = args.version or registry["integrations"][args.integration]["default_version"]
        result = execute(
            registry,
            args.integration,
            version,
            args.documentdb_version,
            args.output,
            wheelhouse=args.wheelhouse,
            demonstration=args.demonstration,
            run_url=args.run_url,
            trigger=args.trigger,
        )
    except KeyError:
        print("Unknown integration or DocumentDB release", file=sys.stderr)
        return 2
    except (OSError, ValueError) as error:
        print(f"Invalid compatibility request: {error}", file=sys.stderr)
        return 2
    state = compatibility_state(result)
    print(f"{state}: {args.output}")
    return 0 if state == "Working" and not result["execution_error"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
