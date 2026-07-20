"""
Backend-catalog contract for documentdb-local (issue #650, coverage hardening).

The log-scan gate (``backend_contract.py``) is *passive*: it only sees a
backend-contract error for a command the smoke workload actually exercises. A
backend routine the gateway advertises but that no smoke command triggers -- one
used only by ``compact``, ``collStats``, ``dbStats``, ``validate``, etc. -- would
go missing silently, which is precisely the #650 failure mode generalised.

This module makes the check *active*: enumerate every backend routine the
gateway's ``QueryCatalog`` calls, so an installed-image test can assert each one
exists in the shipped extension regardless of which commands the smoke runs.

Authoritative source
--------------------
The gateway builds its catalog in ``create_query_catalog()`` at
``pg_documentdb_gw/documentdb_gateway_core/src/postgres/query_catalog.rs``. The
image is built from the same commit, so parsing that source is a faithful proxy
for what the shipped gateway calls -- and it auto-updates as new commands are
added, so the contract cannot silently drift.

We extract calls into the ``documentdb_api``, ``documentdb_api_internal``,
``documentdb_api_catalog`` and ``documentdb_core`` schemas -- i.e. every
documentdb schema the gateway executes against, so a missing routine in any of
them is caught (the ``documentdb_core.bson_build_document`` /
``documentdb_core.row_get_bson`` / ``documentdb_api_catalog.bson_array_agg``
dependencies of ``explain`` / ``listDatabases`` are in scope, not just the
``documentdb_api`` command handlers).

Requiring a trailing ``(`` keeps the match to real function *calls* and excludes
the many name fragments and regex/diagnostic string fields (e.g.
``find_bson_text_meta_qual``, the ``bson_dollar_...`` regexes, the
``documentdb_api_catalog.`` name prefix), none of which are executable calls.
Rust ``//`` line comments are stripped first so a commented-out catalog entry is
not mistaken for a live call.

The one routine the static parser cannot resolve is the ``explain`` template
``documentdb_api_catalog.bson_aggregation_{query_base}(...)``: the function name
is built at runtime from ``{query_base}``, so the literal never contains a
complete callable name and is skipped by the trailing-``(`` rule. Because
``{query_base}`` is drawn from a small fixed set (``run_explain`` is called with
``pipeline``/``find``/``count``/``distinct`` in ``explain/mod.rs``), those
concrete names are enumerated in ``EXPLAIN_AGGREGATION_FUNCTIONS`` and folded
back in by ``required_backend_functions()`` -- so the active contract test still
covers them. Everything else the gateway calls is a static name the parser
captures directly.

OSS gap
-------
``documentdb_api_internal.authenticate_token`` is called by the gateway
(token-auth path) but has no ``CREATE FUNCTION`` under ``oss/`` -- it is an
internal-only routine that documentdb-local never invokes (the emulator uses
SCRAM). It is listed in ``KNOWN_MISSING_IN_OSS`` and subtracted from the
*required* set so the active image contract does not go permanently red against
the OSS extension. It is still captured by the parser (it is a real, statically
named call) so the parser assertion and the report stay honest.
"""

from __future__ import annotations

import pathlib
import re

# Path to the gateway QueryCatalog source, resolved for both repo layouts: the
# internal monorepo (this file at ``oss/documentdb-local/scripts/...``) and the
# standalone OSS checkout (``oss/`` is the repo root). ``parents[3]`` is the
# ``oss`` tree root in both cases. Exported so consumers (test_image.py) share a
# single source of truth for the path.
QUERY_CATALOG_RS = (
    pathlib.Path(__file__).resolve().parents[3]
    / "pg_documentdb_gw"
    / "documentdb_gateway_core"
    / "src"
    / "postgres"
    / "query_catalog.rs"
)

# Floor for the number of backend routines the parser must find. Guards against a
# parser or source-layout breakage that silently returns nothing or a tiny set
# (~50 static today; ~53 required with the explain family). Shared by both the
# unit test and the image test.
MIN_EXPECTED_BACKEND_FUNCTIONS = 40

# Routines the gateway QueryCatalog calls that are NOT defined in the OSS
# extension, so the active image contract must not require them. Kept explicit
# (not dropped from the parser) so the exclusion is auditable and a future OSS
# definition can be spotted.
#   * documentdb_api_internal.authenticate_token: the token-auth path, unused by
#     documentdb-local (SCRAM only); internal-only, no CREATE FUNCTION under oss/.
KNOWN_MISSING_IN_OSS: frozenset[str] = frozenset(
    {"documentdb_api_internal.authenticate_token"}
)

# A call to a documentdb backend routine: ``<schema>.<fn>(``. The schema
# alternation lists the longer names first so ``documentdb_api_internal`` /
# ``documentdb_api_catalog`` win over the ``documentdb_api`` prefix. Group 1 is
# the schema, group 2 the function name. The trailing ``\(`` requires an actual
# call, excluding name fragments, regex fields and the dynamically-named
# ``bson_aggregation_{query_base}`` explain template (whose ``{`` breaks the
# ``[a-z0-9_]+\s*\(`` tail).
_CALL_RE = re.compile(
    r"\b(documentdb_api_internal|documentdb_api_catalog|documentdb_api|documentdb_core)"
    r"\.([a-z0-9_]+)\s*\("
)

# Rust ``//`` line comment to end of line. Applied to strip commented-out catalog
# entries before extraction. Only ``//`` line comments are removed -- block
# comments (``/* */``) are left intact because a live SQL string legitimately
# contains one (the SQLCommenter ``/*traceparent=...*/`` block), and no
# documentdb call literal spans a block comment.
_LINE_COMMENT_RE = re.compile(r"//.*")

# Concrete routine names behind the dynamic explain template
# ``documentdb_api_catalog.bson_aggregation_{query_base}``. ``{query_base}`` is
# supplied by ``run_explain`` in
# ``pg_documentdb_gw/documentdb_gateway_core/src/explain/mod.rs`` as one of these
# four literals (RequestType::Aggregate -> "pipeline", Find -> "find",
# Count -> "count", Distinct -> "distinct"). Keep in sync with those call sites;
# ``test_catalog_contract.py`` asserts this set matches explain/mod.rs.
EXPLAIN_AGGREGATION_FUNCTIONS = frozenset(
    f"documentdb_api_catalog.bson_aggregation_{query_base}"
    for query_base in ("find", "pipeline", "count", "distinct")
)


def _strip_line_comments(rust_source: str) -> str:
    """Remove ``//`` line comments so a commented-out catalog entry is not parsed
    as a live call. Block comments are preserved (a live SQL string contains a
    ``/*traceparent=...*/`` SQLCommenter block)."""
    return "\n".join(
        _LINE_COMMENT_RE.sub("", line) for line in rust_source.splitlines()
    )


def extract_referenced_functions(rust_source: str) -> set[str]:
    """Return the set of ``schema.function`` names the gateway ``QueryCatalog``
    calls by a *static* name in the documentdb backend schemas (i.e. excluding
    the runtime-templated explain aggregation family). ``//`` line comments are
    stripped first so commented-out entries are not counted."""
    source = _strip_line_comments(rust_source)
    return {
        f"{match.group(1)}.{match.group(2)}"
        for match in _CALL_RE.finditer(source)
    }


def required_backend_functions(rust_source: str) -> set[str]:
    """Return every backend routine the gateway calls that must exist in the
    *shipped OSS extension*: the statically-parsed calls plus the enumerated
    explain aggregation family (which the static parser cannot resolve on its
    own), minus ``KNOWN_MISSING_IN_OSS`` (internal-only routines with no OSS
    definition that documentdb-local never invokes)."""
    parsed = extract_referenced_functions(rust_source)
    return (parsed | EXPLAIN_AGGREGATION_FUNCTIONS) - KNOWN_MISSING_IN_OSS
