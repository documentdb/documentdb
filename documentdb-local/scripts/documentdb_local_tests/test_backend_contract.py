"""
Unit tests for the shared backend-contract detector (``backend_contract``).

These tests are pure standard library -- they do not build or run any image --
so they execute anywhere, including the ``documentdb-local-tests`` PR job.

The critical coverage here is that the detector works on *ANSI-coloured* logs.
The gateway logs through ``tracing_subscriber``'s ``fmt`` layer with colour on
by default, so a real ``sub_status=42883`` field is emitted with SGR escapes
around the name and the ``=``. A naive ``grep`` misses it; the detector must
not.

The other critical coverage is that the gated SQLSTATE class stays *narrow*:
only static extension objects / malformed static statements gate, while benign,
dynamically-created objects (42P01 table, 42704 role) and data errors (23505
duplicate key) -- which the gateway logs unconditionally on every failed request
-- must NOT gate, or the check turns noisy.
"""

from __future__ import annotations

import contextlib
import io
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import backend_contract as bc  # noqa: E402  (path set up above)


# --- ANSI SGR codes tracing_subscriber's fmt layer uses for fields ----------
_ITALIC = "\x1b[3m"
_DIM = "\x1b[2m"
_RESET = "\x1b[0m"


def _field(name: str, value: str) -> str:
    """Render a structured tracing field the way the coloured ``fmt`` layer
    does: italic(name) + dim('=') + value."""
    return f"{_ITALIC}{name}{_RESET}{_DIM}={_RESET}{value}"


# A realistic (coloured) gateway error line for the #650 getParameter failure.
_REAL_GETPARAMETER_LINE = (
    "2026-07-15T10:21:17.351234Z \x1b[31mERROR\x1b[0m gateway: "
    + _field("activity_id", "abc-123")
    + " "
    + _field(
        "error",
        "db error: ERROR: function documentdb_api.get_parameter(bson) "
        "does not exist",
    )
    + " "
    + _field("error_code", "59")
    + " "
    + _field("sub_status", "42883")
    + " "
    # sub_status_code is postgres_sqlstate_to_i32(42883) -- a bit-packed integer,
    # never the raw SQLSTATE, so the detector must match via sub_status not this.
    + _field("sub_status_code", "52461700")
    + " DbError during request."
)


class StripAnsiTests(unittest.TestCase):
    def test_strips_field_escapes(self):
        self.assertEqual(
            bc.strip_ansi(_field("sub_status", "42883")), "sub_status=42883"
        )

    def test_noop_on_plain_text(self):
        self.assertEqual(bc.strip_ansi("sub_status=42883"), "sub_status=42883")

    def test_strips_standalone_level_colour(self):
        self.assertEqual(bc.strip_ansi("\x1b[31mERROR\x1b[0m done"), "ERROR done")


class DetectColouredTests(unittest.TestCase):
    """The regression that motivated this module: coloured logs must match."""

    def test_coloured_sub_status_is_detected(self):
        line = "ERROR gw: " + _field("sub_status", "42883") + " failed."
        self.assertEqual(bc.find_backend_contract_errors(line), ["ERROR gw: sub_status=42883 failed."])

    def test_coloured_wrong_object_type_is_detected(self):
        # 42809 wrong_object_type: a hard-coded `CALL proc(...)` / `SELECT fn(...)`
        # whose shipped routine has the wrong prokind. No benign runtime path.
        line = "ERROR gw: " + _field("sub_status", "42809") + " bad kind"
        self.assertEqual(
            bc.find_backend_contract_errors(line),
            ["ERROR gw: sub_status=42809 bad kind"],
        )

    def test_coloured_undefined_column_is_detected(self):
        # 42703 undefined_column: a hard-coded column / function-return field the
        # shipped extension dropped -- a contract breach, not user data.
        line = "ERROR gw: " + _field("sub_status", "42703") + " failed."
        self.assertEqual(
            bc.find_backend_contract_errors(line),
            ["ERROR gw: sub_status=42703 failed."],
        )

    def test_coloured_invalid_schema_is_detected(self):
        # 3F000 invalid_schema_name: the documentdb_api* schema is absent (the
        # extension is not installed). A SQLSTATE with a letter (the 'F') must
        # still match through the ANSI-stripped, boundary-anchored pattern.
        line = "ERROR gw: " + _field("sub_status", "3F000")
        self.assertEqual(len(bc.find_backend_contract_errors(line)), 1)

    def test_coloured_syntax_error_is_detected(self):
        # 42601 syntax_error: all gateway SQL is static and user data is
        # parameter-bound, so a syntax error can only be a typo'd hard-coded query
        # (the #650 class) -- gate it.
        line = "ERROR gw: " + _field("sub_status", "42601")
        self.assertEqual(len(bc.find_backend_contract_errors(line)), 1)

    def test_coloured_invalid_catalog_name_is_detected(self):
        # 3D000 invalid_catalog_name: the gateway connects to one fixed PostgreSQL
        # database; a missing target database is a packaging/config regression,
        # never a lazily-created user database (those are extension-catalog rows).
        # A SQLSTATE with a letter (the 'D') must still match.
        line = "ERROR gw: " + _field("sub_status", "3D000")
        self.assertEqual(len(bc.find_backend_contract_errors(line)), 1)

    def test_coloured_function_message_is_detected(self):
        line = "ERROR gw: " + _field(
            "error", "function documentdb_api.get_parameter(bson) does not exist"
        )
        self.assertEqual(len(bc.find_backend_contract_errors(line)), 1)

    def test_real_getparameter_line_is_detected_once(self):
        # A single offending line must be reported once, not per-alternative.
        self.assertEqual(
            len(bc.find_backend_contract_errors(_REAL_GETPARAMETER_LINE)), 1
        )

    def test_raw_coloured_sub_status_would_evade_plain_grep(self):
        # Guard the premise: the un-stripped line does NOT contain the literal
        # `sub_status=42883`, which is why a naive grep failed on real logs.
        raw = "ERROR gw: " + _field("sub_status", "42883")
        self.assertNotIn("sub_status=42883", raw)
        self.assertEqual(len(bc.find_backend_contract_errors(raw)), 1)


class DetectPlainTests(unittest.TestCase):
    """Uncoloured logs (colour disabled) must match too."""

    def test_plain_sub_status_is_detected(self):
        self.assertEqual(
            bc.find_backend_contract_errors("ts ERROR sub_status=42883 x"),
            ["ts ERROR sub_status=42883 x"],
        )

    def test_plain_wrong_object_type_is_detected(self):
        self.assertEqual(
            len(bc.find_backend_contract_errors("gw ERROR sub_status=42809 x")), 1
        )

    def test_quoted_sub_status_is_detected(self):
        # Tolerate a Display->Debug logging change that would render the value
        # quoted (`sub_status="42883"`), so such a refactor can't silently
        # disable the gate.
        self.assertEqual(
            len(bc.find_backend_contract_errors('gw ERROR sub_status="42883" x')), 1
        )

    def test_plain_undefined_column_is_detected(self):
        self.assertEqual(
            len(bc.find_backend_contract_errors("gw ERROR sub_status=42703 x")), 1
        )

    def test_plain_invalid_schema_is_detected(self):
        self.assertEqual(
            len(bc.find_backend_contract_errors("gw ERROR sub_status=3F000 x")), 1
        )

    def test_plain_syntax_error_is_detected(self):
        self.assertEqual(
            len(bc.find_backend_contract_errors("gw ERROR sub_status=42601 x")), 1
        )

    def test_plain_invalid_catalog_name_is_detected(self):
        self.assertEqual(
            len(bc.find_backend_contract_errors("gw ERROR sub_status=3D000 x")), 1
        )

    def test_plain_function_message_is_detected(self):
        self.assertEqual(
            len(
                bc.find_backend_contract_errors(
                    "function documentdb_api.get_parameter(bson) does not exist"
                )
            ),
            1,
        )

    def test_genuine_error_function_missing_without_skipping_is_detected(self):
        # A real undefined_function ERROR (no ", skipping") must still fire even
        # though the benign IF-EXISTS NOTICE is excluded.
        self.assertEqual(
            len(
                bc.find_backend_contract_errors(
                    "ERROR:  function documentdb_api.get_parameter(boolean, "
                    "boolean, text[]) does not exist"
                )
            ),
            1,
        )


class EnglishFallbackObjectKindTests(unittest.TestCase):
    """The English ``... does not exist`` fallback covers the whole gated
    object class -- function/column/schema/operator -- not just ``function``,
    for the raw server-log channel that carries no ``sub_status`` field."""

    def test_zero_arg_function_message_is_detected(self):
        self.assertEqual(
            len(
                bc.find_backend_contract_errors(
                    "ERROR:  function documentdb_api.binary_version() does not exist"
                )
            ),
            1,
        )

    def test_missing_column_message_is_detected(self):
        self.assertEqual(
            len(
                bc.find_backend_contract_errors(
                    'ERROR:  column "shard_key_value" does not exist'
                )
            ),
            1,
        )

    def test_missing_schema_message_is_detected(self):
        self.assertEqual(
            len(
                bc.find_backend_contract_errors(
                    'ERROR:  schema "documentdb_api" does not exist'
                )
            ),
            1,
        )

    def test_missing_operator_message_is_detected(self):
        # PostgreSQL renders a missing operator as ``operator does not exist:
        # <types>`` -- no name between ``operator`` and ``does not exist``.
        self.assertEqual(
            len(
                bc.find_backend_contract_errors(
                    "ERROR:  operator does not exist: documentdb_core.bson = text"
                )
            ),
            1,
        )

    def test_benign_column_drop_if_exists_notice_is_ignored(self):
        self.assertEqual(
            bc.find_backend_contract_errors(
                'NOTICE:  column "x" of relation "y" does not exist, skipping'
            ),
            [],
        )

    def test_benign_schema_drop_if_exists_notice_is_ignored(self):
        self.assertEqual(
            bc.find_backend_contract_errors(
                'NOTICE:  schema "x" does not exist, skipping'
            ),
            [],
        )


class UnanchoredFallbackFalsePositiveTests(unittest.TestCase):
    """The English fallback must be anchored to PostgreSQL's real message shape
    so it cannot fire on unrelated clauses that merely contain the words."""

    def test_benign_creating_database_clause_is_ignored(self):
        # A single line containing both an unrelated ``function`` word and a
        # ``database ... does not exist`` clause must NOT match: neither shape is
        # the gated ``<kind> <name> does not exist`` / ``operator does not exist``.
        self.assertEqual(
            bc.find_backend_contract_errors(
                'init function ran; database "sampledb" does not exist, creating it'
            ),
            [],
        )

    def test_malfunction_word_is_ignored(self):
        # No word boundary before ``function`` inside ``malfunction``.
        self.assertEqual(
            bc.find_backend_contract_errors(
                "a malfunction was reported but nothing does not exist here"
            ),
            [],
        )

    def test_schema_creating_advisory_currently_matches(self):
        # BREADCRUMB (fix 5): ``schema`` IS a gated object kind, so a mid-sentence
        # advisory like ``schema documentdb_data does not exist, creating it``
        # WOULD be flagged today (only ``, skipping`` is exempted). There is
        # verifiably no producer of such a line in the boot+smoke window, so the
        # matcher is kept tight rather than loosened (loosening risks false
        # negatives on the real #650 error). If a future benign producer logs a
        # ``, creating`` / ``, ignoring`` advisory, extend the ``, skipping``
        # guard in ``_is_benign_missing_object_notice`` -- do NOT widen the
        # matcher. This test pins the current behaviour so that decision stays
        # explicit and whoever hits the false positive finds this breadcrumb.
        self.assertEqual(
            len(
                bc.find_backend_contract_errors(
                    "INFO: schema documentdb_data does not exist, creating it"
                )
            ),
            1,
        )


class NoFalsePositiveTests(unittest.TestCase):
    def test_benign_database_does_not_exist_is_ignored(self):
        self.assertEqual(
            bc.find_backend_contract_errors(
                'ERROR: database "gateway_smoke" does not exist'
            ),
            [],
        )

    def test_benign_relation_does_not_exist_is_ignored(self):
        self.assertEqual(
            bc.find_backend_contract_errors(
                'ERROR: relation "documentdb_data.documents_5" does not exist'
            ),
            [],
        )

    def test_benign_role_does_not_exist_english_is_ignored(self):
        # ``role ... does not exist`` is a benign auth-time condition; ``role`` is
        # not a gated object kind for the English fallback.
        self.assertEqual(
            bc.find_backend_contract_errors(
                'ERROR:  role "app_user" does not exist'
            ),
            [],
        )

    def test_benign_drop_if_exists_function_notice_is_ignored(self):
        # `DROP FUNCTION IF EXISTS <absent>` logs this NOTICE (to psql stderr ->
        # docker logs) while CREATE EXTENSION runs the versioned upgrade chain.
        # It shares the "function ... does not exist" wording but is not a
        # backend-contract breach; the ", skipping" suffix must exclude it.
        self.assertEqual(
            bc.find_backend_contract_errors(
                "NOTICE:  function documentdb_api.foo(bson) does not exist, "
                "skipping"
            ),
            [],
        )

    def test_coloured_drop_if_exists_notice_is_ignored(self):
        line = "NOTICE " + _field(
            "msg", "function documentdb_api.foo(bson) does not exist, skipping"
        )
        self.assertEqual(bc.find_backend_contract_errors(line), [])

    def test_42883_digit_run_in_activity_id_is_ignored(self):
        # The `=42883` anchor must not fire on an unrelated digit run that
        # merely contains 42883 (e.g. inside an activity id or timestamp).
        self.assertEqual(
            bc.find_backend_contract_errors(
                _field("activity_id", "conn-1742883000") + " ready"
            ),
            [],
        )

    def test_error_code_field_is_not_matched(self):
        # The anchored SQLSTATE pattern must not fire on `error_code=42883`
        # (a MongoDB error code field, never a SQLSTATE); this is the collision
        # the old unanchored `code=42883` substring branch would have hit.
        self.assertEqual(
            bc.find_backend_contract_errors("gw ERROR error_code=42883 done"),
            [],
        )

    def test_benign_undefined_table_sub_status_is_ignored(self):
        # 42P01 "table does not exist" is benign in documentdb-local: a query on
        # a not-yet-created collection, so it must not gate even in structured form.
        self.assertEqual(
            bc.find_backend_contract_errors(
                "ERROR gw: " + _field("sub_status", "42P01") + " miss"
            ),
            [],
        )

    def test_benign_role_does_not_exist_sub_status_is_ignored(self):
        # 42704 is "role does not exist" in the gateway's mapping -- a benign
        # auth-time condition the gateway even remaps to UserNotFound.
        self.assertEqual(
            bc.find_backend_contract_errors(
                "ERROR gw: " + _field("sub_status", "42704")
            ),
            [],
        )

    def test_benign_duplicate_key_sub_status_is_ignored(self):
        # 23505 unique_violation: an ordinary duplicate-key error the functional
        # suite triggers thousands of times. Gating on it would be pure noise.
        self.assertEqual(
            bc.find_backend_contract_errors(
                "ERROR gw: " + _field("sub_status", "23505")
            ),
            [],
        )

    def test_class_code_prefix_run_is_ignored(self):
        # The trailing boundary must stop a class code (42703) matching a longer
        # alphanumeric run such as `sub_status=427030`.
        self.assertEqual(
            bc.find_backend_contract_errors(
                "ERROR gw: " + _field("sub_status", "427030")
            ),
            [],
        )

    def test_sub_status_code_integer_field_is_not_matched(self):
        # sub_status_code is postgres_sqlstate_to_i32(...), a bit-packed integer
        # (42883 -> 52461700), never the raw SQLSTATE -- so neither the real
        # encoded value nor a (production-impossible) raw code on that field may
        # fire. Only the sibling `sub_status` field carries the 5-char SQLSTATE.
        for value in ("52461700", "42883"):
            with self.subTest(value=value):
                self.assertEqual(
                    bc.find_backend_contract_errors(
                        "ERROR gw: " + _field("sub_status_code", value)
                    ),
                    [],
                )

    def test_clean_logs_yield_no_matches(self):
        logs = "\n".join(
            [
                "INFO gateway: === DocumentDB is ready ===",
                "INFO gateway: " + _field("request", "ping") + " ok",
                "INFO gateway: Custom data initialization completed.",
            ]
        )
        self.assertEqual(bc.find_backend_contract_errors(logs), [])


class ContractSqlstateClassTests(unittest.TestCase):
    """The gated class is data-driven (``_BACKEND_CONTRACT_SQLSTATES``); keep it
    honest and auditable so a future addition is automatically covered."""

    def test_expected_class_membership(self):
        # Pin the exact deny-list so a code cannot be silently added or dropped.
        self.assertEqual(
            set(bc._BACKEND_CONTRACT_SQLSTATES),
            {"42883", "42703", "42809", "3F000", "42601", "3D000"},
        )

    def test_every_class_code_matches_in_structured_form(self):
        for code in bc._BACKEND_CONTRACT_SQLSTATES:
            with self.subTest(code=code):
                line = "ERROR gw: " + _field("sub_status", code)
                self.assertEqual(len(bc.find_backend_contract_errors(line)), 1)

    def test_benign_codes_are_excluded_from_the_class(self):
        # Codes the gateway treats as benign (lazily-created objects, auth,
        # data/constraint errors) must stay out of the gated class, or the gate
        # turns noisy against ordinary and functional-suite traffic.
        for benign in ("42P01", "42704", "23505", "22P02"):
            with self.subTest(code=benign):
                self.assertNotIn(benign, bc._BACKEND_CONTRACT_SQLSTATES)
                line = "ERROR gw: " + _field("sub_status", benign)
                self.assertEqual(bc.find_backend_contract_errors(line), [])


class UnexpectedSqlstateTests(unittest.TestCase):
    """``find_unexpected_sqlstates`` is the report/strict safety net: every
    distinct non-empty ``sub_status`` OUTSIDE the deny-list. A green
    documentdb-local workload emits none (benign paths log an EMPTY sub_status)."""

    def test_reports_code_outside_denylist(self):
        self.assertEqual(
            bc.find_unexpected_sqlstates("gw ERROR sub_status=42P01 x"),
            ["42P01"],
        )

    def test_ignores_denylist_codes(self):
        # A deny-list code is handled by the hard gate, not reported as unexpected.
        self.assertEqual(
            bc.find_unexpected_sqlstates("gw ERROR sub_status=42883 x"),
            [],
        )

    def test_ignores_empty_sub_status(self):
        # The benign Gateway-kind path (e.g. wrong-password SCRAM) logs an EMPTY
        # sub_status -- there is no value char, so it must not be reported.
        self.assertEqual(
            bc.find_unexpected_sqlstates("gw ERROR sub_status= done"),
            [],
        )

    def test_deduplicates_and_sorts(self):
        logs = "\n".join(
            [
                "sub_status=42P01",
                "sub_status=23505",
                "sub_status=42P01",
                "sub_status=42883",  # deny-list: excluded from the report
            ]
        )
        self.assertEqual(
            bc.find_unexpected_sqlstates(logs), ["23505", "42P01"]
        )

    def test_matches_through_ansi_colour(self):
        line = "ERROR gw: " + _field("sub_status", "42P01")
        self.assertEqual(bc.find_unexpected_sqlstates(line), ["42P01"])

    def test_does_not_match_sub_status_code_integer(self):
        # sub_status_code is a bit-packed integer, not a SQLSTATE; the 5-char
        # boundary must not fire on the wider field name / value.
        self.assertEqual(
            bc.find_unexpected_sqlstates(
                "ERROR gw: " + _field("sub_status_code", "52461700")
            ),
            [],
        )


class UnparseableSubStatusTests(unittest.TestCase):
    """``find_unparseable_sub_status_values`` is the guard against a ``sub_status``
    VALUE-format change (e.g. logging the bit-packed integer or a JSON reformat)
    that would leave the deny-list and report scans silently blind -- the
    green-but-dead risk. "Parseable" is defined by the scans' OWN value regex, so
    the guard cannot disagree with the scans in either direction."""

    def test_flags_bit_packed_integer(self):
        # A refactor logging postgres_sqlstate_to_i32(...) instead of the 5-char
        # SQLSTATE is exactly the value the scans cannot parse.
        self.assertEqual(
            bc.find_unparseable_sub_status_values("x sub_status=52461700 y"),
            ["52461700"],
        )

    def test_flags_doubled_quote_value(self):
        # The confirmed blind spot: `sub_status=""42883""`. The deny-list/strict
        # value regex only tolerates ONE quote, so it does NOT match; the guard
        # must therefore flag this (an earlier shape-based guard peeled all quotes
        # to `42883` and wrongly passed it -> green-but-dead).
        self.assertEqual(
            bc.find_backend_contract_errors('sub_status=""42883""'), []
        )
        self.assertEqual(
            bc.find_unexpected_sqlstates('sub_status=""42883""'), []
        )
        self.assertNotEqual(
            bc.find_unparseable_sub_status_values('sub_status=""42883""'), []
        )

    def test_does_not_flag_trailing_punctuation(self):
        # `sub_status=42883.` -- the value regex's boundary passes on `.`, so the
        # scans parse it fine; the guard must NOT flag it (an earlier shape-based
        # guard falsely flagged `42883.` with a "scans are blind" message).
        self.assertTrue(bc._SUB_STATUS_VALUE_RE.search("sub_status=42883."))
        self.assertEqual(
            bc.find_unparseable_sub_status_values("sub_status=42883."), []
        )

    def test_ignores_valid_sqlstate_shape(self):
        # A well-formed 5-char SQLSTATE is parseable, whether deny-list or not.
        self.assertEqual(
            bc.find_unparseable_sub_status_values("x sub_status=42883 y"), []
        )
        self.assertEqual(
            bc.find_unparseable_sub_status_values("x sub_status=3D000 y"), []
        )

    def test_ignores_empty_value(self):
        # The benign Gateway-kind form logs an EMPTY sub_status -- no value token,
        # so nothing to flag. Covers trailing space, end-of-line and "".
        for text in ("x sub_status= y", "foo sub_status=", 'x sub_status="" y'):
            with self.subTest(text=text):
                self.assertEqual(
                    bc.find_unparseable_sub_status_values(text), []
                )

    def test_flags_quoted_bit_packed_integer(self):
        # A quoted non-SQLSTATE value is still flagged (the raw token, which may
        # carry the trailing quote, is reported for visibility).
        got = bc.find_unparseable_sub_status_values('x sub_status="52461700" y')
        self.assertEqual(len(got), 1)
        self.assertIn("52461700", got[0])
        self.assertEqual(
            bc.find_unparseable_sub_status_values('x sub_status="42883" y'), []
        )

    def test_flags_value_at_end_of_line(self):
        self.assertEqual(
            bc.find_unparseable_sub_status_values("foo bar sub_status=52461700"),
            ["52461700"],
        )

    def test_does_not_match_sub_status_code_field(self):
        # sub_status_code=<int> must NOT be flagged: the `=` must follow
        # `sub_status` immediately.
        self.assertEqual(
            bc.find_unparseable_sub_status_values("x sub_status_code=52461700 y"),
            [],
        )

    def test_matches_through_ansi_colour(self):
        line = "ERROR gw: " + _field("sub_status", "52461700")
        self.assertEqual(
            bc.find_unparseable_sub_status_values(line), ["52461700"]
        )

    def test_deduplicates_and_sorts(self):
        logs = "\n".join(
            [
                "sub_status=999",
                "sub_status=52461700",
                "sub_status=999",
                "sub_status=42883",  # valid shape: not flagged
            ]
        )
        self.assertEqual(
            bc.find_unparseable_sub_status_values(logs), ["52461700", "999"]
        )

    def test_consistency_with_value_scan(self):
        # The invariant that keeps the guard honest: for every sub_status
        # occurrence with a non-empty value, it is flagged IFF the scans' own
        # value regex does not match there.
        samples = [
            "sub_status=42883",
            "sub_status=52461700",
            'sub_status=""42883""',
            "sub_status=42883.",
            'sub_status="42883"',
            "sub_status=3D000",
            "sub_status=999",
        ]
        for text in samples:
            with self.subTest(text=text):
                token = bc._SUB_STATUS_TOKEN_RE.search(text)
                value_parses = bc._SUB_STATUS_VALUE_RE.search(text) is not None
                flagged = bc.find_unparseable_sub_status_values(text) != []
                # token always present & non-empty in these samples
                self.assertIsNotNone(token)
                self.assertEqual(flagged, not value_parses)

    def test_glued_occurrence_parseable_first_is_not_a_blind_spot(self):
        # The confirmed glued blind spot: two `sub_status=` fields with NO
        # whitespace between them, the parseable one first. A value token's `\S+`
        # swallows the second anchor, so anchor-based iteration is required to see
        # the unparseable second value. (Before the fix this returned [].)
        got = bc.find_unparseable_sub_status_values(
            "sub_status=00000,sub_status=52461700"
        )
        self.assertNotEqual(got, [])
        self.assertTrue(any("52461700" in v for v in got))

    def test_glued_occurrence_unparseable_first_is_flagged(self):
        got = bc.find_unparseable_sub_status_values(
            "sub_status=52461700,sub_status=00000"
        )
        self.assertTrue(any("52461700" in v for v in got))

    def test_every_field_occurrence_is_classified(self):
        # Occurrence-count consistency: each `sub_status=` field (as counted by
        # count_sub_status_fields, including glued ones) is evaluated exactly
        # once. Here: 42883 (parseable), 52461700 (unparseable, glued to) 00000
        # (parseable), abc (unparseable) -> 4 fields, two unparseable surfaced.
        line = (
            "sub_status=42883 x sub_status=52461700,sub_status=00000 y "
            "sub_status=abc"
        )
        self.assertEqual(bc.count_sub_status_fields(line), 4)
        flagged = bc.find_unparseable_sub_status_values(line)
        joined = " ".join(flagged)
        self.assertIn("52461700", joined)
        self.assertIn("abc", joined)
        # The two valid 5-char codes must not be reported as standalone flags.
        self.assertNotIn("42883", flagged)
        self.assertNotIn("00000", flagged)


class CountSubStatusFieldsTests(unittest.TestCase):
    """``count_sub_status_fields`` shares the field anchor with the scans so the
    canary's liveness count cannot drift from what the scans consider a field."""

    def test_counts_fields_including_empty(self):
        logs = "a sub_status=42883 b\nsub_status= c\nno field here"
        self.assertEqual(bc.count_sub_status_fields(logs), 2)

    def test_excludes_sub_status_code(self):
        self.assertEqual(
            bc.count_sub_status_fields("x sub_status_code=52461700 y"), 0
        )

    def test_counts_through_ansi_colour(self):
        line = "ERROR gw: " + _field("sub_status", "42883")
        self.assertEqual(bc.count_sub_status_fields(line), 1)


class MultiLineTests(unittest.TestCase):
    def test_returns_only_offending_lines(self):
        logs = "\n".join(
            [
                "INFO ok",
                "ERROR gw: " + _field("sub_status", "42883"),
                "INFO still ok",
                'ERROR: database "x" does not exist',
                "ERROR gw: function foo.bar() does not exist",
            ]
        )
        matches = bc.find_backend_contract_errors(logs)
        self.assertEqual(len(matches), 2)
        self.assertTrue(all("does not exist" in m or "42883" in m for m in matches))


class CliTests(unittest.TestCase):
    def _run_main(self, argv: list[str]) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = bc.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_file_with_match_exits_1(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = pathlib.Path(tmp) / "c.log"
            log.write_text(_REAL_GETPARAMETER_LINE, encoding="utf-8")
            code, _, err = self._run_main([str(log)])
        self.assertEqual(code, 1)
        self.assertIn("FAILED", err)

    def test_clean_file_exits_0(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = pathlib.Path(tmp) / "c.log"
            log.write_text("INFO ready\nINFO done\n", encoding="utf-8")
            code, out, _ = self._run_main([str(log)])
        self.assertEqual(code, 0)
        self.assertIn("passed", out)

    def test_stdin_with_match_exits_1(self):
        stdin = sys.stdin
        sys.stdin = io.StringIO("ERROR " + _field("sub_status", "42883"))
        try:
            code, _, _ = self._run_main(["-"])
        finally:
            sys.stdin = stdin
        self.assertEqual(code, 1)

    def test_default_reads_stdin(self):
        stdin = sys.stdin
        sys.stdin = io.StringIO("all good here")
        try:
            code, _, _ = self._run_main([])
        finally:
            sys.stdin = stdin
        self.assertEqual(code, 0)


class CliStdinBytesTests(unittest.TestCase):
    """The stdin path must decode leniently: a container log can carry invalid
    UTF-8, and a strict decode would raise -- in the CI gate, indistinguishable
    from a real detection. These run the CLI as a subprocess so the real
    ``sys.stdin.buffer`` byte path is exercised (the in-process CliTests patch
    ``sys.stdin`` with a StringIO, which bypasses decoding)."""

    _SCRIPT = pathlib.Path(__file__).resolve().parent / "backend_contract.py"

    def _run(self, argv: list[str], data: bytes) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(self._SCRIPT), *argv],
            input=data,
            capture_output=True,
        )

    def test_invalid_utf8_clean_log_exits_0(self):
        # Invalid bytes with no contract error must not crash -> clean exit 0.
        res = self._run(["-"], b"hello \xff\xfe world\n")
        self.assertEqual(res.returncode, 0, res.stderr.decode("utf-8", "replace"))
        self.assertIn("passed", res.stdout.decode("utf-8", "replace"))

    def test_invalid_utf8_with_match_exits_1(self):
        # A real detection surrounded by invalid bytes must still gate.
        res = self._run(["-"], b"\xff sub_status=42883 \xfe\n")
        self.assertEqual(res.returncode, 1)
        self.assertIn("FAILED", res.stderr.decode("utf-8", "replace"))

    def test_report_unexpected_prints_but_exits_0(self):
        res = self._run(["--report-unexpected", "-"], b"line sub_status=42P01 x\n")
        self.assertEqual(res.returncode, 0)
        self.assertIn("42P01", res.stderr.decode("utf-8", "replace"))

    def test_strict_fails_on_unexpected(self):
        res = self._run(["--strict", "-"], b"line sub_status=42P01 x\n")
        self.assertEqual(res.returncode, 1)
        self.assertIn("42P01", res.stderr.decode("utf-8", "replace"))

    def test_report_unexpected_reports_unparseable_but_exits_0(self):
        # The release-smoke path (--report-unexpected) must surface an
        # unparseable sub_status value (green-but-dead risk) without failing.
        res = self._run(["--report-unexpected", "-"], b"line sub_status=52461700 x\n")
        self.assertEqual(res.returncode, 0)
        err = res.stderr.decode("utf-8", "replace")
        self.assertIn("cannot parse", err)
        self.assertIn("52461700", err)

    def test_strict_fails_on_unparseable(self):
        res = self._run(["--strict", "-"], b"line sub_status=52461700 x\n")
        self.assertEqual(res.returncode, 1)
        self.assertIn("cannot parse", res.stderr.decode("utf-8", "replace"))

    def test_plain_invocation_ignores_unparseable(self):
        # Without --report-unexpected/--strict the unparseable/unexpected scans
        # are not run, so plain invocation semantics are unchanged.
        res = self._run(["-"], b"line sub_status=52461700 x\n")
        self.assertEqual(res.returncode, 0)


if __name__ == "__main__":
    unittest.main()
