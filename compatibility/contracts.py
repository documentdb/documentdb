# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

"""Validated registry, immutable result, and coverage contracts."""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import yaml
from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parent.parent
DEMONSTRATION_TEST = "test_failure_demonstration"


def validate_schema(value: Any, name: str) -> None:
    """Reject unknown fields and malformed values without echoing input secrets."""
    schema = json.loads((ROOT / "compatibility" / "schemas" / f"{name}.json").read_text())
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    error = next(validator.iter_errors(value), None)
    if error is not None:
        location = ".".join(map(str, error.absolute_path)) or "<root>"
        raise ValueError(f"Invalid {name} field {location}: {error.validator}")


def read_registry(path: Path = ROOT / "compatibility" / "registry.yaml") -> dict[str, Any]:
    """Load the reviewed registry and validate adapter locations and defaults."""
    registry = yaml.safe_load(path.read_text())
    validate_schema(registry, "registry")
    for name, integration in registry["integrations"].items():
        if not re.fullmatch(integration["version_pattern"], integration["default_version"]):
            raise ValueError(f"Default version is outside the policy for {name}")
        for key in ("test_file", "demonstration_file"):
            test_file = (ROOT / integration[key]).resolve()
            allowed = (ROOT / "compatibility" / "integrations" / name).resolve()
            if (
                not allowed.is_relative_to(ROOT)
                or test_file.parent != allowed
                or not test_file.is_file()
            ):
                raise ValueError(f"Invalid adapter location for {name}")
    return dict(registry)


def timestamp(value: str) -> datetime:
    """Parse an explicitly zoned timestamp into UTC."""
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Timestamps require an explicit timezone")
    return parsed.astimezone(timezone.utc)


def expected_tests(spec: dict[str, Any], demonstration: bool) -> list[str]:
    """Return the exact scenario contract, including an explicitly labeled demonstration."""
    return list(spec["expected_tests"]) + ([DEMONSTRATION_TEST] if demonstration else [])


def validate_result(result: dict[str, Any], spec: dict[str, Any] | None = None) -> None:
    """Validate raw records before either persistence or rendering."""
    validate_schema(result, "result")
    if timestamp(result["finished_at"]) < timestamp(result["started_at"]):
        raise ValueError("Result finishes before it starts")
    if timestamp(result["finished_at"]) > datetime.now(timezone.utc) + timedelta(minutes=5):
        raise ValueError("Result timestamp is implausibly far in the future")
    identifiers = [test["id"] for test in result["tests"]]
    if len(set(identifiers)) != len(identifiers):
        raise ValueError("Duplicate test outcomes")
    if not set(identifiers).issubset(result["expected_tests"]):
        raise ValueError("Result contains an undeclared scenario")
    if spec is not None:
        if result["expected_tests"] != expected_tests(spec, result["demonstration"]):
            raise ValueError("Result coverage does not match the reviewed registry")
        for key in ("repository", "owner", "profile"):
            if result[key] != spec[key]:
                raise ValueError(f"Result {key} does not match the reviewed registry")


def validate_client_report(value: Any) -> None:
    """Validate the untrusted container's envelope before reading or retaining its fields."""
    result_schema = json.loads((ROOT / "compatibility" / "schemas" / "result.json").read_text())
    properties = {
        "version": {"type": "string", "pattern": r"^[0-9]+\.[0-9]+\.[0-9]+$"},
        "python": {"type": "string", "pattern": r"^3\.12\.[0-9]+$"},
        "wheel_sha256": {"type": "string", "pattern": "^[a-f0-9]{64}$"},
        "exit_code": {"type": "integer", "minimum": 0, "maximum": 5},
        "tests": result_schema["properties"]["tests"],
        "junit": {"type": "string", "maxLength": 1024 * 1024},
        "dependencies": result_schema["properties"]["upstream"]["properties"]["dependencies"],
    }
    validator = Draft202012Validator(
        {
            "type": "object",
            "additionalProperties": False,
            "required": list(properties),
            "properties": properties,
        }
    )
    if next(validator.iter_errors(value), None) is not None:
        raise ValueError("Invalid isolated-client report")


def compatibility_state(result: dict[str, Any]) -> str:
    """A conclusive assertion failure wins; incomplete execution never becomes Working."""
    if any(test["outcome"] == "failed" for test in result["tests"]):
        return "Failing"
    if (
        result["execution_error"]
        or not result["documentdb"]["actual_extension_version"]
        or not result["documentdb"]["actual_postgres_version"]
        or result["upstream"]["actual_version"] != result["upstream"]["version"]
        or not result["upstream"]["wheel_sha256"]
        or not result["upstream"]["client_image"]
        or not result["upstream"]["python_version"]
        or not result["upstream"]["dependencies"]
    ):
        return "Not tested"
    outcomes = {test["id"]: test["outcome"] for test in result["tests"]}
    if all(outcomes.get(name) == "passed" for name in result["expected_tests"]):
        return "Working"
    return "Not tested"


def suite_files(integration: str, root: Path = ROOT) -> list[Path]:
    """Use the same explicit source set for provenance and the isolated client build."""
    adapter = root / "compatibility" / "integrations" / integration
    files = [
        root / "compatibility" / "pyproject.toml",
        root / "compatibility" / "requirements.txt",
        root / "compatibility" / "__init__.py",
        root / "compatibility" / "client.py",
        root / "compatibility" / "contracts.py",
        root / "compatibility" / "runner.py",
        root / "compatibility" / "schemas" / "registry.json",
        root / "compatibility" / "schemas" / "result.json",
        adapter / "Dockerfile",
        adapter / "requirements.txt",
    ]
    files.extend(adapter.rglob("*.py"))
    for path in files:
        if path.is_symlink():
            raise ValueError("Suite files must not be symbolic links")
    return sorted(files)


def suite_digest(integration: str, spec: dict[str, Any], root: Path = ROOT) -> str:
    """Hash execution inputs, including the runtime recipe and uncommitted local edits."""
    digest = hashlib.sha256()
    execution = {
        key: spec[key]
        for key in (
            "package",
            "profile",
            "test_file",
            "demonstration_file",
            "timeout_seconds",
            "expected_tests",
        )
    }
    digest.update(json.dumps(execution, sort_keys=True, separators=(",", ":")).encode())
    for path in suite_files(integration, root):
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()
