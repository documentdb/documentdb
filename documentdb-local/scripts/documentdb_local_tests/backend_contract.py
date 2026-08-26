"""
Backend-contract detector for documentdb-local (issue #650).

A gateway command whose backend SQL references a function, column, schema or
callable of the wrong kind that the shipped extension does not define surfaces as
a PostgreSQL ``undefined_function`` (SQLSTATE ``42883``), ``undefined_column``
(``42703``), ``wrong_object_type`` (``42809``), ``invalid_schema_name``
(``3F000``), ``syntax_error`` (``42601``) or ``invalid_catalog_name`` (``3D000``)
error in the container logs. Clients silently tolerate failed discovery probes --
e.g. the ``getParameter`` probe mongosh issues on every connection -- so a green
CRUD smoke test cannot catch it. That is exactly how issue #650 shipped despite
passing CI.

This module scans container logs for that class of error so a single shared,
unit-tested detector can be reused by:

  * the pre-merge image test (``test_image.py``),
  * the release-build smoke test (``.github/workflows/build_gateway.yml``).

Two complementary modes
-----------------------
The gateway logs every failed request's SQLSTATE on its structured
``sub_status`` field, so the logs carry both benign and contract-breaking codes.

  * DENY-LIST (the hard gate): ``find_backend_contract_errors`` reports lines
    whose ``sub_status`` is in the narrow ``_BACKEND_CONTRACT_SQLSTATES`` class,
    each of which can only mean the gateway's hard-coded SQL referenced a static,
    extension-defined object the shipped extension does not provide. This is the
    signal that fails the release gate and the PR-time image test.

  * REPORT (defence in depth): ``find_unexpected_sqlstates`` returns every
    *distinct, non-empty* ``sub_status`` SQLSTATE that is NOT in the deny-list.
    A green documentdb-local workload emits none of these today (every benign
    failure path logs an EMPTY ``sub_status`` -- a wrong-password SCRAM attempt is
    a Gateway-kind error whose ``as_db_error()`` is ``None``, so
    ``log_request_fail.rs`` renders ``sub_status=`` empty, and retried transients
    log a ``db_error_code`` field, not ``sub_status``). The release smoke prints
    these for triage without failing (``--report-unexpected``); the PR-time image
    test asserts the set is empty (``--strict``). This catches a NEW contract
    SQLSTATE outside the deny-list before someone has to remember to add it.

ANSI awareness (why this is not a plain ``grep``)
-------------------------------------------------
The gateway logs through ``tracing_subscriber``'s ``fmt`` layer, which emits
ANSI SGR escape sequences around structured field *names* and the ``=`` by
default (it does not auto-detect a TTY and nothing disables colour). So a real
log line for the #650 error is not the literal ``sub_status=42883`` but rather::

    \\x1b[3msub_status\\x1b[0m\\x1b[2m=\\x1b[0m42883

which means a naive ``grep 'sub_status=42883'`` matches *nothing* -- only the
language-specific English ``function ... does not exist`` fallback would fire,
defeating the point of a language-independent SQLSTATE gate. We therefore strip
ANSI before matching. Stripping is a no-op when colour is absent, so the same
detector works on both coloured and uncoloured logs.

CLI
---
Used by ``build_gateway.yml``'s release smoke test::

    docker logs "$CONTAINER" 2>&1 | \\
        python3 backend_contract.py --report-unexpected -

    python3 backend_contract.py path/to/container.log

Exit status is ``1`` if any deny-list backend-contract error is found (the
offending lines are printed to stderr), or if ``--strict`` is passed and any
unexpected non-empty ``sub_status`` SQLSTATE is present; ``0`` otherwise.
``--report-unexpected`` prints the unexpected codes without changing the exit
status (report-only).
"""

from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Iterable

# CSI/SGR escape sequence, e.g. ESC[3m (italic), ESC[0m (reset), ESC[2m (dim).
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

# After ANSI is stripped, a backend-contract error is detected in two ways.
#
# (1) PRIMARY -- the raw PostgreSQL SQLSTATE surfaced on the gateway's structured
#     ``sub_status`` field. ``log_request_fail.rs`` logs
#     ``sub_status = %db_error.code().code()`` (Display) for *every* failed
#     request whose error carries a PostgreSQL DbError, and ``auth.rs`` does the
#     same at connect time (the #650 path), so a real error renders as
#     ``sub_status=42883``. This is language-independent and is the signal we
#     want. We match a deliberately *narrow class* of SQLSTATEs -- see
#     ``_BACKEND_CONTRACT_SQLSTATES`` -- each of which means the gateway's
#     hard-coded SQL referenced a *static, extension-defined* object (function,
#     column, schema or callable kind, or a malformed hard-coded statement) the
#     shipped extension does not provide.
#
#     We match ``sub_status`` ONLY, not the sibling ``sub_status_code`` field:
#     that one is ``postgres_sqlstate_to_i32(...)`` (error.rs), a bit-packed
#     integer (42883 -> 52461700), never the 5-char SQLSTATE, so matching it would
#     be meaningless. The ``\b`` + exact ``sub_status=`` anchor also keeps the
#     gateway's ``error_code`` (a MongoDB error code, never a SQLSTATE) and the
#     ``error_sub_status`` local from colliding. A benign psql NOTICE never carries
#     ``sub_status``, so this branch needs no extra guard. The optional quote
#     tolerates a future switch from Display (``sub_status=42883``) to Debug
#     (``sub_status="42883"``) so such a refactor cannot silently disable the gate
#     -- the very silent-failure mode #650 is about.
#
# (2) DEFENSE IN DEPTH -- the English ``<object> ... does not exist`` message, the
#     form PostgreSQL itself logs (no ``sub_status`` field), which is how the
#     original #650 error also appears in raw psql stderr and on the tailed server
#     log. This branch is scoped to the same contract-object kinds: a missing
#     *function*/*operator* (42883), *column* (42703) or *schema* (3F000). It is
#     deliberately NOT scoped to ``database/relation/role ... does not exist``:
#     those name a dynamically-created object (a lazily-created collection/database
#     or an auth role) and occur benignly, which is why the SQLSTATE class below
#     omits 42P01/42704 (and 3D000/42601 are gated only via ``sub_status``, where
#     they cannot be produced by a benign runtime path -- see their notes below).
#     PostgreSQL also logs ``NOTICE: ... does not exist, skipping`` for a
#     ``DROP ... IF EXISTS`` on an absent object (e.g. while ``CREATE EXTENSION``
#     runs the versioned upgrade chain), and that NOTICE *does* reach
#     ``docker logs`` -- so we exclude the ``, skipping`` form, which is emitted
#     only by ``IF EXISTS`` and never by a genuine ERROR.
#
# The class is intentionally minimal. The gateway logs every failed request's
# SQLSTATE unconditionally, so a documentdb-local run emits many *benign*
# SQLSTATEs -- e.g. 42P01 "table does not exist" and 42704 "role does not exist"
# while a collection/role is created lazily, and (if the detector is ever pointed
# at a broader workload such as the functional suite) 23505 duplicate key and
# 22xxx bad input from thousands of intentional error paths. Gating on those would
# be pure noise. ``documentdb_macros/postgres_errors.csv`` is NOT used as the
# allow-list here: it has the wrong semantics (it is a per-code advisory
# LogOnFailure flag, its generated ``should_log_on_postgres_error`` has no caller,
# it defaults unknown codes to benign, and it omits codes such as 42601), so this
# detector classifies the codes itself. Adding a code below is a one-line,
# reviewable change, so a genuinely new *contract* SQLSTATE within this narrow
# class is covered without touching the matching logic; the ``--strict`` report
# mode (``find_unexpected_sqlstates``) is the safety net that surfaces a novel
# SQLSTATE outside the set before it has to be added by hand.
_BACKEND_CONTRACT_SQLSTATES: dict[str, str] = {
    # SQLSTATE -> PostgreSQL condition name. Each names a static object or a
    # malformed static statement the gateway hard-codes, so there is no benign
    # runtime path that produces it in documentdb-local (the extension source
    # never ``ereport``s these itself -- verified for column/schema/object-type).
    "42883": "undefined_function",   # issue #650; also "operator does not exist"
    "42703": "undefined_column",     # a hard-coded column / function-return field dropped by version skew
    "42809": "wrong_object_type",    # a hard-coded CALL proc / SELECT fn whose shipped routine has the wrong prokind
    "3F000": "invalid_schema_name",  # documentdb_api* schema absent -> extension not installed
    # 42601 syntax_error: every gateway SQL text is static (catalog strings, a
    # numeric statement_timeout, a hex-only sqlcommenter block comment) and all
    # user data is parameter-bound, so a client can never cause a syntax error --
    # a sub_status=42601 can only be a typo'd hard-coded query, exactly the #650
    # class, and would otherwise be invisible.
    "42601": "syntax_error",
    # 3D000 invalid_catalog_name: the gateway connects to one fixed PostgreSQL
    # database (Config::dbname, pinned to ``postgres`` in start_oss_server.sh).
    # Wire-protocol databases are extension-catalog rows, not PostgreSQL
    # databases, so a 3D000 means a packaging/config regression removed the
    # target database, never a lazily-created user database.
    "3D000": "invalid_catalog_name",
}
# Deliberately EXCLUDED: 42704 is PostgreSQL's generic ``undefined_object`` -- not
# merely "role does not exist" as the gateway CSV labels it, but also a missing
# type/cast/collation/operator-class. We still exclude it because its role /
# user-management / ``dropIndexes`` "... does not exist" forms are benign and
# frequent (the gateway even remaps 42704 -> UserNotFound), and a genuinely
# missing type/opclass almost always co-surfaces as a 42883 on the function or
# operator that consumes it (which IS gated). 42P01 table and the 22xxx/23xxx
# data/constraint classes are excluded for the same benign-path reason.

# Named-object kinds whose English ``<kind> <name> ... does not exist`` message
# maps to a gated contract SQLSTATE (42883 function, 42703 column, 3F000 schema).
# ``operator`` uses a different message shape (``operator does not exist:
# <types>`` -- no name in between) and is handled as a separate alternative
# below. ``database``/``relation``/``role`` are intentionally absent -- see
# note (2).
_NAMED_MISSING_OBJECT_KINDS = ("function", "column", "schema")

# ``\b`` + exact ``sub_status=`` so ``error_code=`` / ``sub_status_code=`` cannot
# match; an optional quote tolerates a Display->Debug logging change; the trailing
# ``(?![0-9A-Za-z])`` stops a code matching a longer alphanumeric run (SQLSTATEs
# such as ``3F000`` contain letters, so a plain ``\d`` boundary will not do).
_SQLSTATE_CONTRACT_RE = re.compile(
    r'\bsub_status="?(?:'
    + "|".join(re.escape(code) for code in _BACKEND_CONTRACT_SQLSTATES)
    + r")(?![0-9A-Za-z])"
)

# The bare ``sub_status=`` field anchor, shared by the value/token regexes below
# and by ``count_sub_status_fields`` (the canary's liveness count) so there is a
# single definition of "a sub_status field occurrence" and the canary cannot
# drift from the scans. ``sub_status_code=`` does not match (the ``=`` must
# follow ``sub_status`` immediately).
_SUB_STATUS_FIELD_RE = re.compile(r"\bsub_status=")

# Any structured ``sub_status`` SQLSTATE value (5 chars: digits/letters), used by
# the report scan to find codes OUTSIDE the deny-list AND -- crucially -- as the
# SINGLE definition of "a value the scans can parse" (see
# ``find_unparseable_sub_status_values``). Group 1 is the code. An empty
# ``sub_status=`` (the benign Gateway-kind case) has no value char, so it does
# not match -- exactly what we want.
_SUB_STATUS_VALUE_RE = re.compile(r'\bsub_status="?([0-9A-Za-z]{5})(?![0-9A-Za-z])')

# The ``sub_status`` field value as a raw token (any run of non-space chars after
# ``sub_status=`` and an optional opening quote). Used to extract the value at a
# KNOWN ``sub_status=`` anchor (via ``.match(line, pos)``) -- NOT with ``finditer``
# to locate occurrences, because its ``\S+`` swallows a following ``sub_status=``
# glued to it and would skip that second occurrence. ``sub_status_code=...`` does
# not match.
_SUB_STATUS_TOKEN_RE = re.compile(r'\bsub_status="?(\S+)')

# English fallback: PostgreSQL's own ``... does not exist`` message (no
# ``sub_status`` field), the form the #650 error takes in raw psql stderr and on
# the tailed server log. Two anchored shapes:
#   * ``<kind> <name>(...) does not exist`` for function/column/schema -- a
#     whole-word object kind, a schema-qualified name, and (for a function) an
#     optional parenthesised argument-type list including the zero-arg ``()``
#     case; and
#   * ``operator does not exist`` -- PostgreSQL renders the missing-operator
#     42883 as ``operator does not exist: <types>`` with no name in between.
# Anchoring this tightly means the pattern cannot straddle unrelated clauses on
# one line (e.g. ``database "sampledb" does not exist, creating it`` or a stray
# ``malfunction``). The benign ``, skipping`` NOTICE (``DROP ... IF EXISTS``) is
# excluded by the caller's guard.
_MISSING_OBJECT_RE = re.compile(
    r"\b(?:"
    r"(?:" + "|".join(_NAMED_MISSING_OBJECT_KINDS) + r")\s+"
    r'[A-Za-z0-9_".]+(?:\([^)]*\))? does not exist'
    r"|operator does not exist"
    r")"
)


def strip_ansi(text: str) -> str:
    """Remove ANSI SGR/CSI escape sequences from ``text``."""
    return _ANSI_RE.sub("", text)


def _is_benign_missing_object_notice(line: str) -> bool:
    """Return ``True`` for PostgreSQL's benign ``... does not exist, skipping``
    NOTICE, emitted by ``DROP ... IF EXISTS`` on an absent object. Such NOTICEs
    reach ``docker logs`` (psql stderr) during ``CREATE EXTENSION`` but are not
    backend-contract violations. The ``, skipping`` suffix is unique to the
    ``IF EXISTS`` path and never appears on a genuine ERROR.

    NOTE: ``, skipping`` is the ONLY benign suffix exempted here. ``_MISSING_OBJECT_RE``
    matches mid-sentence, so a hypothetical advisory line such as
    ``schema documentdb_data does not exist, creating it`` WOULD be flagged (there
    is verifiably no producer of such a line in the boot+smoke window today, so
    the matcher is deliberately kept tight rather than loosened, which would risk
    false negatives). If a future benign producer logs a ``, creating`` /
    ``, ignoring`` advisory form, extend this guard here -- do not widen the
    matcher. ``test_backend_contract.py`` pins the current ``, creating it``
    behaviour so this decision stays explicit."""
    return "does not exist, skipping" in line


def find_backend_contract_errors(logs: str) -> list[str]:
    """Return the (ANSI-stripped) log lines that indicate a backend-contract
    error -- the gateway referenced a function, operator, column or schema the
    shipped extension does not define, or ran a malformed hard-coded statement
    (the issue #650 class, generalised to the narrow SQLSTATE set in
    ``_BACKEND_CONTRACT_SQLSTATES``).

    Matching is line-oriented so the English ``... does not exist`` pattern
    cannot straddle unrelated lines and so the benign-NOTICE guard applies per
    line.
    """
    matches: list[str] = []
    for raw_line in logs.splitlines():
        line = strip_ansi(raw_line)
        if _SQLSTATE_CONTRACT_RE.search(line):
            matches.append(line)
            continue
        if _MISSING_OBJECT_RE.search(line) and not _is_benign_missing_object_notice(
            line
        ):
            matches.append(line)
    return matches


def find_unexpected_sqlstates(logs: str) -> list[str]:
    """Return the sorted, distinct, non-empty ``sub_status`` SQLSTATEs present in
    the logs that are NOT in the deny-list (``_BACKEND_CONTRACT_SQLSTATES``).

    A green documentdb-local workload emits none of these -- benign failures log
    an EMPTY ``sub_status`` -- so a non-empty result is a novel backend error
    class worth surfacing (report-only) or failing on (``--strict``) before it
    silently becomes the next #650.
    """
    seen: set[str] = set()
    for raw_line in logs.splitlines():
        line = strip_ansi(raw_line)
        for match in _SUB_STATUS_VALUE_RE.finditer(line):
            code = match.group(1)
            if code not in _BACKEND_CONTRACT_SQLSTATES:
                seen.add(code)
    return sorted(seen)


def find_unparseable_sub_status_values(logs: str) -> list[str]:
    """Return the sorted, distinct ``sub_status`` field values in the logs that
    the gate's OWN value scan cannot parse.

    "Parseable" has exactly ONE definition here: the same ``_SUB_STATUS_VALUE_RE``
    the deny-list and report scans use. A ``sub_status`` occurrence is flagged iff
    it carries a non-empty value but ``_SUB_STATUS_VALUE_RE`` does NOT match at
    that occurrence -- i.e. the scans are provably blind to it. This is
    deliberately NOT a second, independent shape check: an independent check can
    disagree with the scans in either direction (it once did -- it missed a
    doubled-quote ``sub_status=""42883""`` the scans also miss, and falsely
    flagged ``sub_status=42883.`` the scans parse fine).

    We iterate over ``_SUB_STATUS_FIELD_RE`` ANCHORS (every ``sub_status=``), not
    over value tokens: a value token's ``\\S+`` swallows a following
    ``sub_status=`` glued to it with no whitespace, so a token-based ``finditer``
    would silently skip that second, glued occurrence -- hiding an unparseable
    value behind a parseable one, the exact drift this guard exists to catch. By
    visiting each anchor, every occurrence is classified exactly once (matching
    ``count_sub_status_fields``).

    It catches a value logged in a shape the scans cannot read -- a bit-packed
    integer ``sub_status=52461700``, a doubled-quote ``sub_status=""42883""``, a
    comma-glued ``sub_status=X,sub_status=Y``, a JSON switch -- which is the
    green-but-dead risk. An EMPTY value (``sub_status=`` / ``sub_status=""`` --
    the benign Gateway-kind form) carries no value and is never flagged. The raw
    token (as it appears in the log) is reported so the offending value is
    visible."""
    seen: set[str] = set()
    for raw_line in logs.splitlines():
        line = strip_ansi(raw_line)
        for anchor in _SUB_STATUS_FIELD_RE.finditer(line):
            pos = anchor.start()
            token_match = _SUB_STATUS_TOKEN_RE.match(line, pos)
            if token_match is None:
                continue  # empty value (``sub_status=`` at end / before a space)
            token = token_match.group(1)
            if not token.strip('"'):
                continue  # only quotes (``sub_status=""``) -> empty -> benign
            if _SUB_STATUS_VALUE_RE.match(line, pos):
                continue  # the scans can parse THIS occurrence
            seen.add(token)
    return sorted(seen)


def count_sub_status_fields(logs: str) -> int:
    """Return the number of ``sub_status=`` field occurrences across the
    ANSI-stripped logs. The canary uses this (rather than an inline regex) so its
    liveness count shares the exact field anchor the scans use and cannot drift
    from them."""
    return len(_SUB_STATUS_FIELD_RE.findall(strip_ansi(logs)))


def _read_sources(paths: Iterable[str]) -> str:
    chunks: list[str] = []
    for path in paths:
        if path == "-":
            if sys.stdin is None:
                raise SystemExit(
                    "backend_contract: stdin requested ('-') but not available"
                )
            # Decode leniently: a container log can contain invalid UTF-8 (binary
            # noise, truncated multi-byte runs), and a strict decode here would
            # raise -- indistinguishable, in the CI gate, from a real detection.
            # Read the raw byte buffer when available (the real stdin) so the
            # lenient decode actually applies; fall back to text for an
            # already-decoded stream (e.g. a test-supplied StringIO).
            buffer = getattr(sys.stdin, "buffer", None)
            if buffer is not None:
                chunks.append(buffer.read().decode("utf-8", errors="replace"))
            else:
                chunks.append(sys.stdin.read())
        else:
            with open(path, encoding="utf-8", errors="replace") as handle:
                chunks.append(handle.read())
    return "\n".join(chunks)


def main(argv: list[str] | None = None) -> int:
    contract_codes = ", ".join(
        f"{code} {name}" for code, name in _BACKEND_CONTRACT_SQLSTATES.items()
    )
    parser = argparse.ArgumentParser(
        description=(
            "Fail (exit 1) if container logs contain a PostgreSQL "
            "backend-contract error -- a SQLSTATE in the deny-list "
            f"({contract_codes}) on the gateway's structured sub_status field, or "
            "the matching English '<kind> ... does not exist' message, where the "
            "gateway's hard-coded SQL references a function, column, schema or "
            "callable kind the shipped extension does not define, or runs a "
            "malformed static statement (issue #650 class)."
        )
    )
    parser.add_argument(
        "paths",
        nargs="*",
        default=["-"],
        help="Log file paths, or '-' for stdin (default: stdin).",
    )
    parser.add_argument(
        "--report-unexpected",
        action="store_true",
        help=(
            "Print (report-only, exit unchanged) every distinct non-empty "
            "sub_status SQLSTATE outside the deny-list, and every sub_status "
            "value the scans cannot parse (e.g. a bit-packed integer). Does not "
            "change the exit status unless --strict is also given."
        ),
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help=(
            "Also exit 1 if any unexpected (outside-deny-list) non-empty "
            "sub_status SQLSTATE, or any sub_status value the scans cannot parse, "
            "is present. A green documentdb-local workload emits neither."
        ),
    )
    args = parser.parse_args(argv)

    logs = _read_sources(args.paths)
    matches = find_backend_contract_errors(logs)
    want_report = args.report_unexpected or args.strict
    unexpected = find_unexpected_sqlstates(logs) if want_report else []
    unparseable = find_unparseable_sub_status_values(logs) if want_report else []

    if args.report_unexpected and unexpected:
        print(
            "Backend-contract report: unexpected non-empty sub_status SQLSTATE(s) "
            "outside the gated deny-list (a green documentdb-local workload emits "
            f"none): {', '.join(unexpected)}",
            file=sys.stderr,
        )
    if args.report_unexpected and unparseable:
        print(
            "Backend-contract report: sub_status value(s) the scans cannot parse "
            "as a SQLSTATE -- the deny-list and report scans are blind to these, a "
            f"green-but-dead risk (cf. issue #650): {', '.join(unparseable)}",
            file=sys.stderr,
        )

    failed = False
    if matches:
        print(
            "Backend-contract gate FAILED: found PostgreSQL backend-contract "
            "error(s) in the gateway logs -- the gateway's hard-coded SQL "
            "references a function, column or schema the shipped extension does "
            "not define, or runs a malformed static statement "
            "(undefined_function/undefined_column/wrong_object_type/"
            "invalid_schema_name/syntax_error/invalid_catalog_name; cf. issue "
            "#650):",
            file=sys.stderr,
        )
        for line in matches:
            print(f"  {line}", file=sys.stderr)
        failed = True

    if args.strict and unexpected:
        print(
            "Backend-contract gate FAILED (--strict): unexpected non-empty "
            "sub_status SQLSTATE(s) outside the gated deny-list: "
            f"{', '.join(unexpected)}",
            file=sys.stderr,
        )
        failed = True

    if args.strict and unparseable:
        print(
            "Backend-contract gate FAILED (--strict): sub_status value(s) the "
            "scans cannot parse as a SQLSTATE (green-but-dead risk; cf. issue "
            f"#650): {', '.join(unparseable)}",
            file=sys.stderr,
        )
        failed = True

    if failed:
        return 1
    print("Backend-contract gate passed: no backend-contract errors in logs.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
