"""
DocumentDB allowlist pytest plugin.

Mounts into the upstream functional-tests container to filter collected tests
against an allowlist. Uses @pytest.hookimpl(tryfirst=True) so it sees the
full collection before upstream hooks (e.g. no_parallel deselection) mutate
the item list.

See RFC-0007 for design details.
"""

import pytest
import yaml


def pytest_addoption(parser):
    parser.addoption(
        "--allowlist",
        default=None,
        help="Path to allowlist.yml for DocumentDB PR gate filtering",
    )
    parser.addoption(
        "--allowlist-engine-name",
        default="documentdb",
        help="Engine name to check for engine_xfail markers (default: documentdb)",
    )


@pytest.hookimpl(tryfirst=True)
def pytest_collection_modifyitems(session, config, items):
    allowlist_path = config.getoption("--allowlist")
    if not allowlist_path:
        raise pytest.UsageError(
            "[MISSING_ALLOWLIST] conftest_allowlist was loaded without --allowlist. "
            "Pass --allowlist <path> or do not load the plugin."
        )

    # Load and validate allowlist
    with open(allowlist_path) as f:
        data = yaml.safe_load(f)

    if not isinstance(data, dict):
        raise pytest.UsageError(
            f"[INVALID_SCHEMA] allowlist.yml must be a YAML mapping, got {type(data).__name__}"
        )

    schema_version = data.get("schema_version")
    if schema_version != 1:
        raise pytest.UsageError(
            f"[INVALID_SCHEMA] Unsupported schema_version: {schema_version} (expected 1)"
        )

    tests = data.get("tests")
    if tests is None:
        raise pytest.UsageError("[INVALID_SCHEMA] allowlist.yml missing required 'tests' field")

    if not isinstance(tests, list):
        raise pytest.UsageError(
            f"[INVALID_SCHEMA] 'tests' must be a list, got {type(tests).__name__}"
        )

    # Check for duplicates
    seen = set()
    duplicates = []
    for entry in tests:
        if not isinstance(entry, str):
            raise pytest.UsageError(
                f"[INVALID_SCHEMA] Test ID must be a string, got {type(entry).__name__}: {entry}"
            )
        if entry in seen:
            duplicates.append(entry)
        seen.add(entry)

    if duplicates:
        dup_list = ", ".join(duplicates[:5])
        suffix = f" (and {len(duplicates) - 5} more)" if len(duplicates) > 5 else ""
        raise pytest.UsageError(
            f"[DUPLICATE_TEST_ID] allowlist.yml contains duplicate test IDs: {dup_list}{suffix}"
        )

    allowed_ids = seen
    engine_name = config.getoption("--allowlist-engine-name", default="documentdb")

    # Classify items
    selected = []
    deselected = []
    matched_ids = set()
    no_parallel_ids = []
    engine_xfail_ids = []

    for item in items:
        if item.nodeid in allowed_ids:
            matched_ids.add(item.nodeid)

            # Check no_parallel
            if item.get_closest_marker("no_parallel"):
                no_parallel_ids.append(item.nodeid)

            # Check engine_xfail for the configured engine
            for marker in item.iter_markers("engine_xfail"):
                if marker.kwargs.get("engine") == engine_name:
                    engine_xfail_ids.append(item.nodeid)
                    break

            selected.append(item)
        else:
            deselected.append(item)

    # Detect missing IDs (must check against full collection before any deselection)
    missing_ids = sorted(allowed_ids - matched_ids)
    if missing_ids:
        missing_list = "\n  ".join(missing_ids[:10])
        suffix = f"\n  ... and {len(missing_ids) - 10} more" if len(missing_ids) > 10 else ""
        raise pytest.UsageError(
            f"[UNKNOWN_TEST_ID] allowlist.yml contains {len(missing_ids)} test IDs "
            f"not found in the pinned image:\n  {missing_list}{suffix}"
        )

    # Reject no_parallel tests in Phase 1
    if no_parallel_ids:
        np_list = "\n  ".join(no_parallel_ids[:10])
        suffix = f"\n  ... and {len(no_parallel_ids) - 10} more" if len(no_parallel_ids) > 10 else ""
        raise pytest.UsageError(
            f"[ALLOWLISTED_NO_PARALLEL] allowlist.yml contains {len(no_parallel_ids)} tests "
            f"marked no_parallel, but the Phase 1 PR gate runs with parallel workers and has no "
            f"sequential phase:\n  {np_list}{suffix}"
        )

    # Reject engine_xfail tests for the target engine
    if engine_xfail_ids:
        xf_list = "\n  ".join(engine_xfail_ids[:10])
        suffix = f"\n  ... and {len(engine_xfail_ids) - 10} more" if len(engine_xfail_ids) > 10 else ""
        raise pytest.UsageError(
            f"[ALLOWLISTED_ENGINE_XFAIL] allowlist.yml contains {len(engine_xfail_ids)} tests "
            f"marked engine_xfail(engine=\"{engine_name}\"). These tests cannot satisfy "
            f"the allowlist contract:\n  {xf_list}{suffix}"
        )

    # Deselect non-allowlisted items
    if deselected:
        config.hook.pytest_deselected(items=deselected)
        items[:] = selected
