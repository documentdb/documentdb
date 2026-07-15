"""
Unit tests for the backend-catalog contract parser (``catalog_contract``).

Pure standard library -- no image, no docker -- so these run in the
``documentdb-local-tests`` PR job. They pin the extraction rules and, against
the real ``query_catalog.rs``, prove the reviewer's unexercised routines
(``compact``/``collStats``/``dbStats``/...) are covered.
"""

from __future__ import annotations

import os
import pathlib
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import catalog_contract as cc  # noqa: E402  (path set up above)

# Repo root: .../documentdb-local/scripts/documentdb_local_tests/<this file>.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_QUERY_CATALOG_RS = (
    _REPO_ROOT
    / "pg_documentdb_gw"
    / "documentdb_gateway_core"
    / "src"
    / "postgres"
    / "query_catalog.rs"
)

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

    def test_deduplicates_repeated_calls(self):
        got = cc.extract_referenced_functions(_SYNTHETIC)
        self.assertEqual(
            [f for f in got if f == "documentdb_api.drop_database"],
            ["documentdb_api.drop_database"],
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

    def test_required_is_extracted_plus_explain_family(self):
        # required_backend_functions() folds the enumerated explain aggregation
        # family back in on top of the statically-parsed calls.
        self.assertEqual(len(cc.EXPLAIN_AGGREGATION_FUNCTIONS), 4)
        extracted = cc.extract_referenced_functions(_SYNTHETIC)
        self.assertEqual(
            cc.required_backend_functions(_SYNTHETIC),
            extracted | set(cc.EXPLAIN_AGGREGATION_FUNCTIONS),
        )


@unittest.skipUnless(
    _QUERY_CATALOG_RS.is_file(), f"query_catalog.rs not found at {_QUERY_CATALOG_RS}"
)
class RealCatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.functions = cc.extract_referenced_functions(
            _QUERY_CATALOG_RS.read_text(encoding="utf-8")
        )

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

    def test_required_adds_explain_aggregation_family(self):
        # The dynamic explain routines are excluded from the static parse but
        # re-added by required_backend_functions(), so the active gate covers
        # bson_aggregation_{find,pipeline,count,distinct}.
        required = cc.required_backend_functions(
            _QUERY_CATALOG_RS.read_text(encoding="utf-8")
        )
        self.assertEqual(
            required - self.functions, set(cc.EXPLAIN_AGGREGATION_FUNCTIONS)
        )
        for base in ("find", "pipeline", "count", "distinct"):
            self.assertIn(
                f"documentdb_api_catalog.bson_aggregation_{base}", required
            )

    def test_parses_a_substantial_set(self):
        # ~49 backend routines across the four documentdb schemas today; a floor
        # guards against a parser or source-layout breakage that silently
        # returns nothing or a tiny set.
        self.assertGreaterEqual(len(self.functions), 40)


if __name__ == "__main__":
    unittest.main()
