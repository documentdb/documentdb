"""
Unit tests for the shared backend-contract detector (``backend_contract``).

These tests are pure standard library -- they do not build or run any image --
so they execute anywhere, including the ``documentdb-local-tests`` PR job.

The critical coverage here is that the detector works on *ANSI-coloured* logs.
The gateway logs through ``tracing_subscriber``'s ``fmt`` layer with colour on
by default, so a real ``sub_status=42883`` field is emitted with SGR escapes
around the name and the ``=``. A naive ``grep`` misses it; the detector must
not.
"""

from __future__ import annotations

import contextlib
import io
import os
import pathlib
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
    + _field("sub_status_code", "42883")
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
        self.assertEqual(bc.find_undefined_function_errors(line), ["ERROR gw: sub_status=42883 failed."])

    def test_coloured_sub_status_code_is_detected(self):
        line = "ERROR gw: " + _field("sub_status_code", "42883")
        # Matches via the sub_status_code field (the `(?:_code)?` branch).
        self.assertEqual(len(bc.find_undefined_function_errors(line)), 1)

    def test_coloured_function_message_is_detected(self):
        line = "ERROR gw: " + _field(
            "error", "function documentdb_api.get_parameter(bson) does not exist"
        )
        self.assertEqual(len(bc.find_undefined_function_errors(line)), 1)

    def test_real_getparameter_line_is_detected_once(self):
        # A single offending line must be reported once, not per-alternative.
        self.assertEqual(
            len(bc.find_undefined_function_errors(_REAL_GETPARAMETER_LINE)), 1
        )

    def test_raw_coloured_sub_status_would_evade_plain_grep(self):
        # Guard the premise: the un-stripped line does NOT contain the literal
        # `sub_status=42883`, which is why a naive grep failed on real logs.
        raw = "ERROR gw: " + _field("sub_status", "42883")
        self.assertNotIn("sub_status=42883", raw)
        self.assertEqual(len(bc.find_undefined_function_errors(raw)), 1)


class DetectPlainTests(unittest.TestCase):
    """Uncoloured logs (colour disabled) must match too."""

    def test_plain_sub_status_is_detected(self):
        self.assertEqual(
            bc.find_undefined_function_errors("ts ERROR sub_status=42883 x"),
            ["ts ERROR sub_status=42883 x"],
        )

    def test_plain_sub_status_code_is_detected(self):
        # sub_status_code is the other real SQLSTATE-bearing field.
        self.assertEqual(
            len(bc.find_undefined_function_errors("gw ERROR sub_status_code=42883")),
            1,
        )

    def test_plain_function_message_is_detected(self):
        self.assertEqual(
            len(
                bc.find_undefined_function_errors(
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
                bc.find_undefined_function_errors(
                    "ERROR:  function documentdb_api.get_parameter(boolean, "
                    "boolean, text[]) does not exist"
                )
            ),
            1,
        )


class NoFalsePositiveTests(unittest.TestCase):
    def test_benign_database_does_not_exist_is_ignored(self):
        self.assertEqual(
            bc.find_undefined_function_errors(
                'ERROR: database "gateway_smoke" does not exist'
            ),
            [],
        )

    def test_benign_relation_does_not_exist_is_ignored(self):
        self.assertEqual(
            bc.find_undefined_function_errors(
                'ERROR: relation "documentdb_data.documents_5" does not exist'
            ),
            [],
        )

    def test_benign_drop_if_exists_function_notice_is_ignored(self):
        # `DROP FUNCTION IF EXISTS <absent>` logs this NOTICE (to psql stderr ->
        # docker logs) while CREATE EXTENSION runs the versioned upgrade chain.
        # It shares the "function ... does not exist" wording but is not a
        # backend-contract breach; the ", skipping" suffix must exclude it.
        self.assertEqual(
            bc.find_undefined_function_errors(
                "NOTICE:  function documentdb_api.foo(bson) does not exist, "
                "skipping"
            ),
            [],
        )

    def test_coloured_drop_if_exists_notice_is_ignored(self):
        line = "NOTICE " + _field(
            "msg", "function documentdb_api.foo(bson) does not exist, skipping"
        )
        self.assertEqual(bc.find_undefined_function_errors(line), [])

    def test_42883_digit_run_in_activity_id_is_ignored(self):
        # The `=42883` anchor must not fire on an unrelated digit run that
        # merely contains 42883 (e.g. inside an activity id or timestamp).
        self.assertEqual(
            bc.find_undefined_function_errors(
                _field("activity_id", "conn-1742883000") + " ready"
            ),
            [],
        )

    def test_error_code_field_is_not_matched(self):
        # The anchored SQLSTATE pattern must not fire on `error_code=42883`
        # (a MongoDB error code field, never a SQLSTATE); this is the collision
        # the old unanchored `code=42883` substring branch would have hit.
        self.assertEqual(
            bc.find_undefined_function_errors("gw ERROR error_code=42883 done"),
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
        self.assertEqual(bc.find_undefined_function_errors(logs), [])


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
        matches = bc.find_undefined_function_errors(logs)
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


if __name__ == "__main__":
    unittest.main()
