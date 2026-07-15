"""
DocumentDB allowlist pytest plugin.

Mounts into the upstream functional-tests container to filter collected tests
against an allowlist. Uses @pytest.hookimpl(tryfirst=True) so it sees the
full collection before upstream hooks (e.g. no_parallel deselection) mutate
the item list.

Supports allowlist schema versions 1 (flat list of node IDs) and 2 (list of
either bare strings or ``{id, engines: [...]}`` dicts). v2's ``engines:``
field scopes an entry to a subset of engines; missing/absent means "all
engines". Per-engine filtering happens BEFORE the no_parallel /
engine_xfail / missing-IDs guards so an out-of-scope entry on the current
engine is silently ignored, never falsely flagged.

The parsing rules in this file MUST stay in sync with
``functional_gate.parse_allowlist_entries``; the
``test_conftest_allowlist.TestEngineScoping`` golden tests guard against
drift.

See RFC-0007 for the underlying gate design.
"""

import pytest
import yaml


SUPPORTED_SCHEMA_VERSIONS = (1, 2)
_ALLOWED_ENTRY_KEYS = {"id", "engines"}


def pytest_addoption(parser):
    parser.addoption(
        "--allowlist",
        default=None,
        help="Path to allowlist.yml for DocumentDB PR gate filtering",
    )
    parser.addoption(
        "--allowlist-engine-name",
        default="documentdb",
        help="Engine name for filtering schema_version=2 'engines:' entries "
             "and for checking engine_xfail markers (default: documentdb)",
    )


def _parse_allowlist(data, engine_name):
    """Parse the loaded YAML mapping and return the set of in-scope test IDs.

    Raises ``pytest.UsageError`` on any schema problem. Entries with
    ``engines = None`` (bare string in v1/v2, or v2 dict with no ``engines``)
    apply to every engine; entries with an explicit ``engines`` list are in
    scope only when ``engine_name`` is in that list.
    """
    if not isinstance(data, dict):
        raise pytest.UsageError(
            f"[INVALID_SCHEMA] allowlist.yml must be a YAML mapping, got {type(data).__name__}"
        )

    schema_version = data.get("schema_version")
    if schema_version not in SUPPORTED_SCHEMA_VERSIONS:
        supported = ", ".join(str(v) for v in SUPPORTED_SCHEMA_VERSIONS)
        raise pytest.UsageError(
            f"[INVALID_SCHEMA] Unsupported schema_version: {schema_version} "
            f"(expected one of: {supported})"
        )

    tests = data.get("tests")
    if tests is None:
        raise pytest.UsageError("[INVALID_SCHEMA] allowlist.yml missing required 'tests' field")

    if not isinstance(tests, list):
        raise pytest.UsageError(
            f"[INVALID_SCHEMA] 'tests' must be a list, got {type(tests).__name__}"
        )

    seen_ids = set()
    duplicates = []
    in_scope = set()

    for entry in tests:
        if isinstance(entry, str):
            test_id = entry
            engines = None
        elif isinstance(entry, dict):
            if schema_version < 2:
                raise pytest.UsageError(
                    f"[INVALID_SCHEMA] Dict entries require schema_version >= 2, got: {entry}"
                )

            unknown_keys = set(entry.keys()) - _ALLOWED_ENTRY_KEYS
            if unknown_keys:
                raise pytest.UsageError(
                    f"[INVALID_SCHEMA] Unknown keys in entry {entry}: {sorted(unknown_keys)} "
                    f"(allowed: {sorted(_ALLOWED_ENTRY_KEYS)})"
                )

            test_id = entry.get("id")
            if not isinstance(test_id, str) or not test_id:
                raise pytest.UsageError(
                    f"[INVALID_SCHEMA] Entry 'id' must be a non-empty string, got: {entry}"
                )

            if "engines" in entry:
                engines_raw = entry["engines"]
                if not isinstance(engines_raw, list):
                    raise pytest.UsageError(
                        f"[INVALID_SCHEMA] Entry 'engines' must be a list, "
                        f"got {type(engines_raw).__name__} for {test_id}"
                    )
                if len(engines_raw) == 0:
                    raise pytest.UsageError(
                        f"[INVALID_SCHEMA] Entry 'engines' must be a non-empty list for {test_id} "
                        f"(omit the field to apply to all engines)"
                    )
                bad_engines = [e for e in engines_raw if not isinstance(e, str) or not e]
                if bad_engines:
                    raise pytest.UsageError(
                        f"[INVALID_SCHEMA] Entry 'engines' for {test_id} must contain "
                        f"non-empty strings, got: {bad_engines}"
                    )
                engines = frozenset(engines_raw)
            else:
                engines = None
        else:
            raise pytest.UsageError(
                f"[INVALID_SCHEMA] Test entry must be a string or mapping, "
                f"got {type(entry).__name__}: {entry}"
            )

        if test_id in seen_ids:
            duplicates.append(test_id)
        seen_ids.add(test_id)

        if engines is None or engine_name in engines:
            in_scope.add(test_id)

    if duplicates:
        dup_list = ", ".join(duplicates[:5])
        suffix = f" (and {len(duplicates) - 5} more)" if len(duplicates) > 5 else ""
        raise pytest.UsageError(
            f"[DUPLICATE_TEST_ID] allowlist.yml contains duplicate test IDs: {dup_list}{suffix}"
        )

    return in_scope


@pytest.hookimpl(tryfirst=True)
def pytest_collection_modifyitems(session, config, items):
    allowlist_path = config.getoption("--allowlist")
    if not allowlist_path:
        raise pytest.UsageError(
            "[MISSING_ALLOWLIST] conftest_allowlist was loaded without --allowlist. "
            "Pass --allowlist <path> or do not load the plugin."
        )

    with open(allowlist_path) as f:
        data = yaml.safe_load(f)

    engine_name = config.getoption("--allowlist-engine-name", default="documentdb")
    allowed_ids = _parse_allowlist(data, engine_name)

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
