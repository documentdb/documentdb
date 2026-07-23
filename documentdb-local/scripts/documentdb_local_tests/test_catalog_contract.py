"""
Unit tests for the backend-catalog contract parser (``catalog_contract``).

Pure standard library -- no image, no docker -- so these run in the
``documentdb-local-tests`` PR job. They pin the extraction rules and, against
the real ``query_catalog.rs``, prove the reviewer's unexercised routines
(``compact``/``collStats``/``dbStats``/...) are covered.
"""

from __future__ import annotations

import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import catalog_contract as cc  # noqa: E402  (path set up above)

# The gateway QueryCatalog source and its sibling explain module, derived from
# the single exported path so there is one source of truth for the repo layout.
_QUERY_CATALOG_RS = cc.QUERY_CATALOG_RS
_EXPLAIN_MOD_RS = _QUERY_CATALOG_RS.parents[1] / "explain" / "mod.rs"

# A synthetic catalog fragment covering every extraction rule.
_SYNTHETIC = """
    QueryCatalog {
        a: "SELECT documentdb_api.drop_database($1)".to_owned(),
        b: "SELECT * FROM documentdb_api.insert($1, $2, $3, NULL)".to_owned(),
        c: "SELECT documentdb_api_internal.authenticate_token($1, $2)".to_owned(),
        d: "CALL documentdb_api.insert_txn_proc($1, $2, $3, NULL)".to_owned(),
        e: "SELECT documentdb_api.get_parameter ($1, $2, $3)".to_owned(),
        f: "COALESCE(documentdb_api_catalog.bson_array_agg(r.doc, ''))".to_owned(),
        g: "SELECT documentdb_core.bson_build_document('a', 1)".to_owned(),
        h: "documentdb_api_catalog.bson_text_meta_qual".to_owned(),
        i: "(documentdb_api_catalog.)?bson_dollar_project".to_owned(),
        j: "SELECT documentdb_api.drop_database($1)".to_owned(),
        k: "... documentdb_api_catalog.bson_aggregation_{query_base}($1, $2)".to_owned(),
    }
"""


class ExtractTests(unittest.TestCase):
    def test_extracts_calls_across_all_documentdb_schemas(self):
        self.assertEqual(
            cc.extract_referenced_functions(_SYNTHETIC),
            {
                "documentdb_api.drop_database",
                "documentdb_api.insert",
                "documentdb_api_internal.authenticate_token",
                "documentdb_api.insert_txn_proc",
                "documentdb_api.get_parameter",
                # Static executable calls in the catalog/core schemas are in
                # scope too (explain / listDatabases dependencies).
                "documentdb_api_catalog.bson_array_agg",
                "documentdb_core.bson_build_document",
            },
        )

    def test_excludes_fragments_regex_and_dynamic_template(self):
        got = cc.extract_referenced_functions(_SYNTHETIC)
        # h: a bare name fragment (no `(`); i: a regex field; k: the
        # runtime-templated bson_aggregation_{query_base} explain name.
        self.assertNotIn("documentdb_api_catalog.bson_text_meta_qual", got)
        self.assertFalse(any("bson_dollar" in f for f in got))
        self.assertFalse(any("bson_aggregation" in f for f in got))

    def test_strips_line_commented_out_calls(self):
        # A commented-out catalog entry must not be parsed as a live call.
        source = (
            '        // a: "SELECT documentdb_api.removed_call($1)".to_owned(),\n'
            '        b: "SELECT documentdb_api.live_call($1)".to_owned(), '
            "// trailing note documentdb_api.also_commented($1)\n"
        )
        self.assertEqual(
            cc.extract_referenced_functions(source),
            {"documentdb_api.live_call"},
        )

    def test_preserves_block_comment_sql_string(self):
        # A live SQL string carrying a `/*...*/` SQLCommenter block must not be
        # mangled by comment stripping (only `//` line comments are removed).
        source = (
            '        a: "/*traceparent*/ SELECT documentdb_api.real_call($1)"'
            ".to_owned(),\n"
        )
        self.assertEqual(
            cc.extract_referenced_functions(source),
            {"documentdb_api.real_call"},
        )

    def test_requires_call_parenthesis(self):
        # A bare name reference (no `(`) is a string fragment, not a call.
        self.assertEqual(
            cc.extract_referenced_functions('"documentdb_api.binary_version"'),
            set(),
        )
        self.assertEqual(
            cc.extract_referenced_functions('"documentdb_api.binary_version()"'),
            {"documentdb_api.binary_version"},
        )

    def test_schema_names_disambiguated(self):
        # Each schema is captured whole; documentdb_api_catalog must not be read
        # as documentdb_api + ".catalog", nor shadow documentdb_api.
        self.assertEqual(
            cc.extract_referenced_functions('"documentdb_api_catalog.foo(x)"'),
            {"documentdb_api_catalog.foo"},
        )
        self.assertEqual(
            cc.extract_referenced_functions('"documentdb_api_internal.bar(x)"'),
            {"documentdb_api_internal.bar"},
        )
        self.assertEqual(
            cc.extract_referenced_functions('"documentdb_api.baz(x)"'),
            {"documentdb_api.baz"},
        )


class RequiredSetTests(unittest.TestCase):
    def test_required_adds_explain_and_drops_oss_gap(self):
        # required_backend_functions() folds the enumerated explain aggregation
        # family in on top of the statically-parsed calls, then subtracts the
        # OSS-missing routines (authenticate_token) so the active image contract
        # does not require a routine the OSS extension does not define.
        extracted = cc.extract_referenced_functions(_SYNTHETIC)
        required = cc.required_backend_functions(_SYNTHETIC)
        self.assertEqual(
            required,
            (extracted | set(cc.EXPLAIN_AGGREGATION_FUNCTIONS))
            - cc.KNOWN_MISSING_IN_OSS,
        )

    def test_known_missing_is_parsed_but_not_required(self):
        # authenticate_token IS a real static call the parser must still see
        # (keep the report honest), but it must NOT be in the required set (no
        # CREATE FUNCTION under oss/, so requiring it would go permanently red).
        self.assertIn(
            "documentdb_api_internal.authenticate_token",
            cc.extract_referenced_functions(_SYNTHETIC),
        )
        self.assertNotIn(
            "documentdb_api_internal.authenticate_token",
            cc.required_backend_functions(_SYNTHETIC),
        )

    def test_known_missing_membership_is_pinned(self):
        # Pin the exact exclusion set so a future addition/removal is deliberate.
        self.assertEqual(
            cc.KNOWN_MISSING_IN_OSS,
            frozenset({"documentdb_api_internal.authenticate_token"}),
        )


class ExplainFamilySyncTests(unittest.TestCase):
    """The explain aggregation family is templated at runtime, so it cannot be
    parsed from query_catalog.rs. It is enumerated in EXPLAIN_AGGREGATION_FUNCTIONS
    and must stay in sync with the ``run_explain(..., "<query_base>", ...)`` call
    sites in explain/mod.rs -- assert that here so a new/renamed explain target
    fails loudly instead of silently escaping the active contract."""

    # A `run_explain(` call site: the anchored prefix `\brun_explain\s*\(` is the
    # SAME prefix the counter uses, so the parser and the counter agree by
    # construction. Two leading args (request_context, &target) precede the
    # query_base string literal; `[^,]+` spans the intervening newlines.
    _RUN_EXPLAIN_PREFIX = r"\brun_explain\s*\("
    _RUN_EXPLAIN_RE = re.compile(
        _RUN_EXPLAIN_PREFIX + r'\s*[^,]+,\s*[^,]+,\s*"([a-z]+)"'
    )

    @classmethod
    def setUpClass(cls) -> None:
        # Hard-fail (not skip) if explain/mod.rs moved: a silent skip would let
        # the explain family drift out of sync unnoticed -- the #650 failure mode.
        if not _EXPLAIN_MOD_RS.is_file():
            raise AssertionError(
                f"explain/mod.rs not found at {_EXPLAIN_MOD_RS}; the OSS source "
                "tree layout may have changed and EXPLAIN_AGGREGATION_FUNCTIONS "
                "can no longer be kept in sync with its call sites."
            )
        # Strip `//` line comments so a commented-out or doc-comment mention of
        # `run_explain(` is counted by neither the parser nor the counter.
        cls.source = cc._strip_line_comments(
            _EXPLAIN_MOD_RS.read_text(encoding="utf-8")
        )

    def test_explain_family_matches_call_sites(self):
        query_bases = set(self._RUN_EXPLAIN_RE.findall(self.source))
        self.assertEqual(
            query_bases,
            {"find", "pipeline", "count", "distinct"},
            "run_explain call-site query_base literals in explain/mod.rs have "
            "drifted from the four expected; update EXPLAIN_AGGREGATION_FUNCTIONS.",
        )
        self.assertEqual(
            cc.EXPLAIN_AGGREGATION_FUNCTIONS,
            frozenset(
                f"documentdb_api_catalog.bson_aggregation_{base}"
                for base in query_bases
            ),
        )

    def test_every_call_site_is_parsed(self):
        # Two-sided guard: the set-equality above only sees call sites the regex
        # can parse (comma-free leading args + a string-literal query_base). A
        # future call shape -- e.g. run_explain(ctx, &t.resolve(a, b), "search")
        # or a variable query_base -- would escape the regex while set-equality
        # stayed green. Assert every call site (all `run_explain(` occurrences,
        # excluding the `fn run_explain` definition) is parsed, so an unparseable
        # site fails loudly instead of silently dropping from the contract. Both
        # counts use the same comment-stripped source and the same anchored
        # prefix as the parser, so a mismatch can only mean an unparseable shape.
        total_calls = len(re.findall(self._RUN_EXPLAIN_PREFIX, self.source))
        definitions = len(re.findall(r"\bfn\s+run_explain\s*\(", self.source))
        call_sites = total_calls - definitions
        parsed = len(self._RUN_EXPLAIN_RE.findall(self.source))
        self.assertEqual(
            parsed, call_sites,
            f"parsed {parsed} of {call_sites} run_explain call site(s) in "
            "explain/mod.rs; a call site uses a shape _RUN_EXPLAIN_RE cannot read "
            "-- update the regex so the explain family cannot silently drift.",
        )


class RealCatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        # Hard-fail (not skip) if the source moved: query_catalog.rs is part of
        # the same repo tree, so a missing file means the path logic or source
        # layout broke and the active contract would otherwise silently no-op.
        if not _QUERY_CATALOG_RS.is_file():
            raise AssertionError(
                f"query_catalog.rs not found at {_QUERY_CATALOG_RS}; the OSS "
                "source tree layout may have changed and the backend-catalog "
                "contract can no longer be enforced."
            )
        cls.source = _QUERY_CATALOG_RS.read_text(encoding="utf-8")
        cls.functions = cc.extract_referenced_functions(cls.source)

    def test_includes_unexercised_command_routines(self):
        # The reviewer's examples -- routines the CRUD/handshake smoke never
        # triggers, so only an active contract test can guard them.
        for fn in (
            "documentdb_api.compact",
            "documentdb_api.coll_stats",
            "documentdb_api.db_stats",
            "documentdb_api.get_parameter",
            "documentdb_api.validate",
        ):
            self.assertIn(fn, self.functions)

    def test_includes_internal_schema_routines(self):
        self.assertIn(
            "documentdb_api_internal.authenticate_token", self.functions
        )

    def test_includes_core_and_catalog_static_calls(self):
        # Real executable calls in the non-command schemas (explain /
        # listDatabases dependencies) must be covered, not just documentdb_api.
        for fn in (
            "documentdb_core.bson_build_document",
            "documentdb_core.row_get_bson",
            "documentdb_api_catalog.bson_array_agg",
        ):
            self.assertIn(fn, self.functions)

    def test_excludes_dynamic_aggregation_template(self):
        # The explain template documentdb_api_catalog.bson_aggregation_{query_base}
        # has no statically-complete name, so it must not be extracted.
        self.assertFalse(
            any("bson_aggregation" in f for f in self.functions)
        )

    def test_no_unparseable_format_assembled_call(self):
        # The parser assumes every documentdb call is a complete literal name. A
        # `format!("...documentdb_...")`-assembled call would slip past it, so
        # assert none exists -- the single-file/literal assumption must fail
        # loudly (here) if a future change violates it, rather than silently
        # dropping a routine from the contract.
        self.assertIsNone(
            re.search(r'format!\("[^"]*documentdb_', self.source),
            "query_catalog.rs now assembles a documentdb call with format!(); "
            "the static parser cannot see it -- extend catalog_contract.py.",
        )

    def test_required_adds_explain_aggregation_family(self):
        # The dynamic explain routines are excluded from the static parse but
        # re-added by required_backend_functions() (minus the OSS gap), so the
        # active gate covers bson_aggregation_{find,pipeline,count,distinct}.
        required = cc.required_backend_functions(self.source)
        self.assertTrue(set(cc.EXPLAIN_AGGREGATION_FUNCTIONS) <= required)
        for base in ("find", "pipeline", "count", "distinct"):
            self.assertIn(
                f"documentdb_api_catalog.bson_aggregation_{base}", required
            )

    def test_required_excludes_oss_gap(self):
        self.assertNotIn(
            "documentdb_api_internal.authenticate_token",
            cc.required_backend_functions(self.source),
        )

    def test_parses_a_substantial_set(self):
        # ~50 backend routines across the four documentdb schemas today; a floor
        # (shared with the image test) guards against a parser or source-layout
        # breakage that silently returns nothing or a tiny set.
        self.assertGreaterEqual(
            len(self.functions), cc.MIN_EXPECTED_BACKEND_FUNCTIONS
        )


if __name__ == "__main__":
    unittest.main()
