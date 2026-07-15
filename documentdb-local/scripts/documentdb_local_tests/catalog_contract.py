"""
Backend-catalog contract for documentdb-local (issue #650, coverage hardening).

The log-scan gate (``backend_contract.py``) is *passive*: it only sees an
undefined-function error for a command the smoke workload actually exercises. A
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
"""

from __future__ import annotations

import re

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

# Concrete routine names behind the dynamic explain template
# ``documentdb_api_catalog.bson_aggregation_{query_base}``. ``{query_base}`` is
# supplied by ``run_explain`` in
# ``pg_documentdb_gw/documentdb_gateway_core/src/explain/mod.rs`` as one of these
# four literals (RequestType::Aggregate -> "pipeline", Find -> "find",
# Count -> "count", Distinct -> "distinct"). Keep in sync with those call sites.
EXPLAIN_AGGREGATION_FUNCTIONS = frozenset(
    f"documentdb_api_catalog.bson_aggregation_{query_base}"
    for query_base in ("find", "pipeline", "count", "distinct")
)


def extract_referenced_functions(rust_source: str) -> set[str]:
    """Return the set of ``schema.function`` names the gateway ``QueryCatalog``
    calls by a *static* name in the documentdb backend schemas (i.e. excluding
    the runtime-templated explain aggregation family)."""
    return {
        f"{match.group(1)}.{match.group(2)}"
        for match in _CALL_RE.finditer(rust_source)
    }


def required_backend_functions(rust_source: str) -> set[str]:
    """Return every backend routine the gateway calls that must exist in the
    shipped extension: the statically-parsed calls plus the enumerated explain
    aggregation family (which the static parser cannot resolve on its own)."""
    return extract_referenced_functions(rust_source) | EXPLAIN_AGGREGATION_FUNCTIONS
