"""
Backend-contract detector for documentdb-local (issue #650).

A gateway command whose backend SQL calls a function the shipped extension
does not define surfaces as a PostgreSQL ``undefined_function`` error
(SQLSTATE ``42883``) in the container logs. Clients silently tolerate failed
discovery probes -- e.g. the ``getParameter`` probe mongosh issues on every
connection -- so a green CRUD smoke test cannot catch it. That is exactly how
issue #650 shipped despite passing CI.

This module scans container logs for that class of error so a single shared,
unit-tested detector can be reused by:

  * the pre-merge image test (``test_image.py``),
  * the release-build smoke test (``.github/workflows/build_gateway.yml``).

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
        python3 backend_contract.py -

    python3 backend_contract.py path/to/container.log

Exit status is ``1`` if any undefined backend-function error is found (the
offending lines are printed to stderr) and ``0`` otherwise.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Iterable

# CSI/SGR escape sequence, e.g. ESC[3m (italic), ESC[0m (reset), ESC[2m (dim).
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

# After ANSI is stripped, an undefined backend-function error is detected in two
# ways:
#
#   * the PostgreSQL undefined_function SQLSTATE (42883) surfaced on the
#     gateway's structured error fields -- ``sub_status=42883`` and
#     ``sub_status_code=42883``. This is language-independent and is the signal
#     we actually want. The pattern is anchored to those exact field names (with
#     a leading word boundary) so it does not collide with an unrelated ``42883``
#     digit run in a timestamp/activity id, nor with a different field that merely
#     ends in ``code`` such as the gateway's ``error_code`` (a MongoDB error code,
#     never a SQLSTATE). A benign psql NOTICE never carries these fields, so this
#     branch needs no extra guard.
#
#   * the English ``function ... does not exist`` message (defense in depth, and
#     the form PostgreSQL itself logs). Benign ``database/relation ... does not
#     exist`` lines carry a different noun, so they never match. But PostgreSQL
#     also logs ``NOTICE: function ... does not exist, skipping`` for a
#     ``DROP ... IF EXISTS`` on an absent function (e.g. while ``CREATE EXTENSION``
#     runs the versioned upgrade chain), and that NOTICE *does* reach
#     ``docker logs`` -- so we exclude the ``, skipping`` form, which is emitted
#     only by ``IF EXISTS`` and never by a genuine undefined_function ERROR.
_SQLSTATE_42883_RE = re.compile(r"\bsub_status(?:_code)?=42883")
_FUNCTION_MISSING_RE = re.compile(r"function .* does not exist")


def strip_ansi(text: str) -> str:
    """Remove ANSI SGR/CSI escape sequences from ``text``."""
    return _ANSI_RE.sub("", text)


def _is_benign_missing_object_notice(line: str) -> bool:
    """Return ``True`` for PostgreSQL's benign ``... does not exist, skipping``
    NOTICE, emitted by ``DROP ... IF EXISTS`` on an absent object. Such NOTICEs
    reach ``docker logs`` (psql stderr) during ``CREATE EXTENSION`` but are not
    backend-contract violations. The ``, skipping`` suffix is unique to the
    ``IF EXISTS`` path and never appears on a genuine undefined_function ERROR."""
    return "does not exist, skipping" in line


def find_undefined_function_errors(logs: str) -> list[str]:
    """Return the (ANSI-stripped) log lines that indicate an undefined
    backend-function error -- the issue #650 class.

    Matching is line-oriented so the ``function ... does not exist`` pattern
    cannot straddle unrelated lines and so the benign-NOTICE guard applies per
    line.
    """
    matches: list[str] = []
    for raw_line in logs.splitlines():
        line = strip_ansi(raw_line)
        if _SQLSTATE_42883_RE.search(line):
            matches.append(line)
            continue
        if _FUNCTION_MISSING_RE.search(line) and not _is_benign_missing_object_notice(
            line
        ):
            matches.append(line)
    return matches


def _read_sources(paths: Iterable[str]) -> str:
    chunks: list[str] = []
    for path in paths:
        if path == "-":
            chunks.append(sys.stdin.read())
        else:
            with open(path, encoding="utf-8", errors="replace") as handle:
                chunks.append(handle.read())
    return "\n".join(chunks)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Fail (exit 1) if container logs contain a PostgreSQL "
            "undefined_function error (SQLSTATE 42883) -- the issue #650 "
            "class where a gateway command calls a backend function the "
            "shipped extension does not define."
        )
    )
    parser.add_argument(
        "paths",
        nargs="*",
        default=["-"],
        help="Log file paths, or '-' for stdin (default: stdin).",
    )
    args = parser.parse_args(argv)
    paths = args.paths or ["-"]

    logs = _read_sources(paths)
    matches = find_undefined_function_errors(logs)
    if matches:
        print(
            "Backend-contract gate FAILED: found PostgreSQL undefined_function "
            "error(s) in the gateway logs -- a gateway command calls a backend "
            "function the shipped extension does not define (cf. issue #650):",
            file=sys.stderr,
        )
        for line in matches:
            print(f"  {line}", file=sys.stderr)
        return 1
    print("Backend-contract gate passed: no undefined-function errors in logs.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
