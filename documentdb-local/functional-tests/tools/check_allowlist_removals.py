#!/usr/bin/env python3
"""Block accidental removals from the functional-test allowlist.

This script compares the base branch allowlist with the PR allowlist. Adding
tests is allowed; removing tests requires an explicit review decision, so the
CI check fails and prints the removed IDs.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml


def load_allowlist_tests(path: Path) -> set[str]:
    """Return the test IDs from an allowlist.yml file."""
    with path.open() as f:
        data = yaml.safe_load(f)

    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a YAML mapping")

    tests = data.get("tests")
    if not isinstance(tests, list):
        raise ValueError(f"{path} must contain a 'tests' list")

    non_strings = [test for test in tests if not isinstance(test, str)]
    if non_strings:
        raise ValueError(f"{path} contains non-string test IDs: {non_strings[:3]}")

    return set(tests)


def find_removed_tests(base_path: Path, head_path: Path) -> list[str]:
    """Return allowlisted tests that exist in base but not in head."""
    base_tests = load_allowlist_tests(base_path)
    head_tests = load_allowlist_tests(head_path)
    return sorted(base_tests - head_tests)


def check_allowlist_removals(base_path: Path, head_path: Path) -> int:
    """Print a readable result and return a process exit code."""
    removed = find_removed_tests(base_path, head_path)
    if not removed:
        print("No allow-list removals detected.")
        return 0

    print(f"WARNING: {len(removed)} test(s) removed from allowlist.yml:")
    for test_id in removed:
        print(f"  - {test_id}")
    print()
    print("Allow-list removals require explicit justification.")
    return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Fail if a PR removes entries from functional-tests/config/allowlist.yml."
    )
    parser.add_argument("--base", required=True, type=Path, help="Base branch allowlist.yml")
    parser.add_argument("--head", required=True, type=Path, help="PR/head allowlist.yml")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return check_allowlist_removals(args.base, args.head)
    except (OSError, ValueError, yaml.YAMLError) as exc:
        print(f"Allow-list removal check failed: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
