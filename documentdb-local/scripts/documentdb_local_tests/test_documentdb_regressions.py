# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Regression tests for a batch of packaging fixes (documentdb-tune, the
# shared_preload_libraries parsers, documentdb-register-gateway restore-mode
# auto-detection, the emulator entrypoint, and admin-password handling):
#
#   1. documentdb-tune --pgdata must not fabricate a data dir / postgresql.conf
#      for a mistyped path (apply/restore refuse; --print unaffected).
#   2. The shared_preload_libraries parsers (documentdb-tools-lib.sh and
#      documentdb-tune's assignment detector) must accept PostgreSQL's
#      optional-"=" form and case-insensitive GUC names.
#   3. documentdb-tune --pgdata without --pg-version must derive the major from
#      ${PGDATA}/PG_VERSION so extended-RUM detection still runs (or warn).
#   4. debian_include_line_satisfied must not count a commented-out include
#      line as satisfied.
#   5. documentdb-register-gateway restore-mode auto-detection must handle the
#      brownfield-default + greenfield-only-state converse case.
#   6. State-mode auto-default texts must describe the real behavior
#      (single-instance auto-detect also selects brownfield).
#   7. do_restore must remove the auto-generated TLS key dir under the secret
#      dir and prune the (then-empty) secret dir.
#   8. --tls-auto-generate false without BOTH --tls-cert/--tls-key must be
#      rejected at the CLI (not by the daemon's exit-78 restart loop).
#   9. emulator_entrypoint.sh must stop PostgreSQL cleanly on the gateway
#      self-exit path, not only in the SIGTERM/SIGINT trap.
#  10. The admin password must not travel through psql argv nor be
#      interpolated unescaped into the create_user JSON/SQL.

import json
import os
import re
import secrets
import shutil
import shlex
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

OSS_ROOT = Path(__file__).resolve().parents[3]
SCRIPTS_DIR = OSS_ROOT / "documentdb-local" / "scripts"
TUNE_SCRIPT = SCRIPTS_DIR / "documentdb-tune.sh"
GATEWAY_SETUP_SCRIPT = SCRIPTS_DIR / "documentdb-register-gateway.sh"
ENTRYPOINT = SCRIPTS_DIR / "emulator_entrypoint.sh"
TOOLS_LIB = SCRIPTS_DIR / "documentdb-tools-lib.sh"
UTILS_SH = OSS_ROOT / "scripts" / "utils.sh"


class TunePgdataValidationTests(unittest.TestCase):
    """Finding 1: a mistyped --pgdata silently fabricated the directory plus a
    fresh postgresql.conf and reported success. Apply/restore must now require
    the path to already look like a PostgreSQL cluster (PG_VERSION from initdb,
    or an existing postgresql.conf for config-only dev layouts)."""

    def _run(self, *args):
        return subprocess.run(
            ["bash", str(TUNE_SCRIPT), *args],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10,
        )

    def test_apply_rejects_nonexistent_pgdata(self):
        with tempfile.TemporaryDirectory() as td:
            bogus = os.path.join(td, "no", "such", "pgdata")
            r = self._run("--pgdata", bogus, "--yes")
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("does not look like a PostgreSQL data directory", r.stderr)
            # The whole point: nothing may be fabricated.
            self.assertFalse(os.path.exists(bogus),
                             "apply must not create the mistyped data directory")

    def test_restore_on_missing_pgdata_is_a_clean_noop(self):
        # --restore fabricates nothing, and documentdb-setup --restore after
        # documentdb-local-reset legitimately points it at a deleted data
        # dir — that must stay the historical "Nothing to restore" success,
        # not a fabrication-guard failure (the guard is apply-only).
        with tempfile.TemporaryDirectory() as td:
            bogus = os.path.join(td, "typo-pgdata")
            r = self._run("--pgdata", bogus, "--restore", "--yes")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("Nothing to restore", r.stdout + r.stderr)
            self.assertFalse(os.path.exists(bogus),
                             "restore must not create the missing data directory")

    def test_print_is_unaffected_by_missing_pgdata(self):
        with tempfile.TemporaryDirectory() as td:
            bogus = os.path.join(td, "still-missing")
            r = self._run("--pgdata", bogus, "--print")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("shared_preload_libraries", r.stdout)
            self.assertFalse(os.path.exists(bogus))

    def test_apply_accepts_freshly_initdbed_dir(self):
        # The greenfield wizard passes --pgdata of a freshly-initdb'd dir;
        # initdb writes PG_VERSION, so that flow must keep working even
        # before/without a postgresql.conf.
        with tempfile.TemporaryDirectory() as td:
            (Path(td) / "PG_VERSION").write_text("17\n", encoding="utf-8")
            r = self._run("--pgdata", td, "--yes")
            self.assertEqual(r.returncode, 0, r.stderr)
            conf = (Path(td) / "postgresql.conf").read_text(encoding="utf-8")
            self.assertIn("# >>> documentdb-setup managed configuration >>>", conf)

    def test_apply_accepts_config_only_dir(self):
        # Config-only layouts (dev/test fixtures) carry a postgresql.conf but
        # no PG_VERSION; they must still be accepted.
        with tempfile.TemporaryDirectory() as td:
            (Path(td) / "postgresql.conf").write_text("port = 5433\n", encoding="utf-8")
            r = self._run("--pgdata", td, "--yes")
            self.assertEqual(r.returncode, 0, r.stderr)
            conf = (Path(td) / "postgresql.conf").read_text(encoding="utf-8")
            self.assertIn("shared_preload_libraries", conf)


class SharedPreloadParserFormsTests(unittest.TestCase):
    """Finding 2: PostgreSQL GUC names are case-insensitive and the '=' between
    name and value is optional. Both shared parsers (library reader and tune's
    assignment detector) must accept those forms."""

    def _read_via_lib(self, contents):
        with tempfile.TemporaryDirectory() as td:
            conf = Path(td) / "postgresql.conf"
            conf.write_text(contents, encoding="utf-8")
            script = (
                "set -euo pipefail\n"
                "HAS_EXTENDED_RUM=false\n"
                f"source {shlex.quote(str(TOOLS_LIB))}\n"
                f"read_shared_preload_libraries_from_file {shlex.quote(str(conf))}\n"
            )
            r = subprocess.run(["bash", "-c", script],
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
            self.assertEqual(r.returncode, 0, r.stderr)
            return r.stdout

    def test_lib_parser_accepts_optional_equals_and_any_case(self):
        cases = {
            "SHARED_PRELOAD_LIBRARIES 'pg_alpha'   # comment\n": "pg_alpha",
            "Shared_Preload_Libraries = 'pg_beta'\n": "pg_beta",
            "shared_preload_libraries 'pg_gamma'\n": "pg_gamma",
            "shared_preload_libraries = 'pg_delta'\n": "pg_delta",
        }
        for contents, expected in cases.items():
            with self.subTest(contents=contents):
                self.assertEqual(self._read_via_lib(contents), expected)

    def test_lib_parser_keeps_word_boundary(self):
        # A longer parameter that merely starts with the key must not match.
        self.assertEqual(
            self._read_via_lib("shared_preload_libraries_extra = 'nope'\n"), "")

    def test_tune_detector_sees_caseinsensitive_noequals_autoconf_override(self):
        # Behavioral proof that tune's _spl_assigned_in_file and the reader
        # agree on the new forms: an ALTER-SYSTEM-style override written in
        # optional-'=' mixed case must be DETECTED and fail the apply with the
        # missing-libraries diagnostic (previously it was silently invisible).
        with tempfile.TemporaryDirectory() as td:
            (Path(td) / "postgresql.conf").write_text("port = 5433\n", encoding="utf-8")
            (Path(td) / "postgresql.auto.conf").write_text(
                "Shared_Preload_Libraries 'something_else'\n", encoding="utf-8")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--yes"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10,
            )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("missing required documentdb libraries", r.stderr)

    def test_tune_spl_detector_regex_is_hardened(self):
        script = TUNE_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "grep -Eiq '^[[:space:]]*shared_preload_libraries"
            "([[:space:]]*=|[[:space:]])'",
            script,
            "_spl_assigned_in_file must match case-insensitively with optional '='",
        )
        # The old case-sensitive, equals-only detector must be gone.
        self.assertNotIn(
            "grep -Eq '^[[:space:]]*shared_preload_libraries[[:space:]]*='",
            script,
        )


class TuneExtendedRumDerivationTests(unittest.TestCase):
    """Finding 3: --pgdata without --pg-version silently skipped extended-RUM
    detection. The major must be derived from ${PGDATA}/PG_VERSION; when that
    is unreadable, a warning must say detection is skipped."""

    def test_major_is_derived_from_pg_version_file(self):
        with tempfile.TemporaryDirectory() as td:
            (Path(td) / "PG_VERSION").write_text("17\n", encoding="utf-8")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--print", "--verbose"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10,
            )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Derived PostgreSQL major 17", r.stderr)
        self.assertNotIn("extended-RUM detection is skipped", r.stderr)

    def test_warns_when_pg_version_marker_unreadable(self):
        with tempfile.TemporaryDirectory() as td:
            (Path(td) / "postgresql.conf").write_text("port = 5433\n", encoding="utf-8")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--print"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10,
            )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("extended-RUM detection is skipped", r.stderr)

    def test_explicit_pg_version_still_wins(self):
        # An explicit --pg-version must not be overridden by the marker file.
        with tempfile.TemporaryDirectory() as td:
            (Path(td) / "PG_VERSION").write_text("17\n", encoding="utf-8")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td,
                 "--pg-version", "18", "--print", "--verbose"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10,
            )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("Derived PostgreSQL major", r.stderr)


class TuneDebianIncludeLineAnchoringTests(unittest.TestCase):
    """Finding 4: debian_include_line_satisfied used an unanchored fixed-string
    grep, so a commented-out include line counted as satisfied and the managed
    fragment was silently never loaded."""

    FRAGMENT = "/etc/postgresql-common/documentdb/17/main/documentdb.conf"

    def _satisfied(self, live_content):
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            stripped = "\n".join(
                line for line in TUNE_SCRIPT.read_text(encoding="utf-8").splitlines()
                if line != 'main "$@"'
            )
            (td_path / "documentdb-tune.sh").write_text(stripped, encoding="utf-8")
            shutil.copy2(TOOLS_LIB, td_path / "documentdb-tools-lib.sh")
            live = td_path / "postgresql.conf"
            live.write_text(live_content, encoding="utf-8")
            script = (
                "set -euo pipefail\n"
                f"cd {shlex.quote(str(td_path))}\n"
                "source ./documentdb-tune.sh\n"
                f"DEBIAN_LIVE_PG_CONF={shlex.quote(str(live))}\n"
                f"CONFIG_TARGET={shlex.quote(self.FRAGMENT)}\n"
                "if debian_include_line_satisfied; then echo SATISFIED; "
                "else echo MISSING; fi\n"
            )
            r = subprocess.run(["bash", "-c", script],
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
            self.assertEqual(r.returncode, 0, r.stderr)
            return r.stdout.strip()

    def test_commented_out_include_line_is_not_satisfied(self):
        self.assertEqual(
            self._satisfied(f"# include_if_exists = '{self.FRAGMENT}'\n"),
            "MISSING")
        self.assertEqual(
            self._satisfied(f"   #include_if_exists = '{self.FRAGMENT}'\n"),
            "MISSING")

    def test_active_include_line_is_satisfied(self):
        self.assertEqual(
            self._satisfied(f"include_if_exists = '{self.FRAGMENT}'\n"),
            "SATISFIED")
        # Leading whitespace is valid postgresql.conf syntax.
        self.assertEqual(
            self._satisfied(f"   include_if_exists = '{self.FRAGMENT}'\n"),
            "SATISFIED")

    def test_absent_include_line_is_missing(self):
        self.assertEqual(self._satisfied("port = 5432\n"), "MISSING")


class RegisterGatewayRestoreModeSymmetryTests(unittest.TestCase):
    """Finding 5: restore-mode auto-detection handled greenfield-default +
    brownfield-only-state, but not the converse (brownfield auto-default with
    only setup.conf on disk), which failed open."""

    def test_greenfield_only_state_switches_mode(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            text,
            r'elif \[\[ -r "\$\{_gf_state\}" && ! -r "\$\{_bf_state\}" \]\]; then'
            r'[\s\S]*?STATE_MODE="greenfield"'
            r'\s*\n\s*STATE_FILE="\$\{_gf_state\}"',
            "restore must switch to greenfield when only setup.conf is readable",
        )
        self.assertIn(
            'log_verbose "Restore: found greenfield state at ${STATE_FILE}; '
            'switching --state-mode to greenfield."',
            text,
        )

    def test_existing_branches_are_preserved(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            text,
            r'if \[\[ -r "\$\{_bf_state\}" && ! -r "\$\{_gf_state\}" \]\]; then'
            r'[\s\S]*?STATE_MODE="brownfield"',
        )
        # Ambiguous both-present case still dies.
        self.assertRegex(
            text, r'elif \[\[ -r "\$\{_gf_state\}" && -r "\$\{_bf_state\}" \]\]; then')

    def test_comment_documents_fail_open_hazard(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        m = re.search(
            r'elif \[\[ -r "\$\{_gf_state\}" && ! -r "\$\{_bf_state\}" \]\]; then'
            r'(?P<body>[\s\S]*?)STATE_MODE="greenfield"',
            text,
        )
        self.assertIsNotNone(m)
        body = m.group("body")
        self.assertIn("fail-open", body.replace("\n", " ").replace("# ", ""),
                      "the new branch must explain the symmetric fail-open hazard")
        self.assertIn("ConditionPathExists", body)


class RegisterGatewayStateModeTextsTests(unittest.TestCase):
    """Finding 6: the single-instance auto-detect fills TARGET_CLUSTER, so the
    state mode auto-defaults to brownfield in that path too. The verbose log,
    the comment above the auto-default, and usage() must all say so."""

    def test_misleading_log_text_is_gone(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn(
            'Auto-selected --state-mode brownfield (--target-postgres-instance is set)',
            text,
            "log must not claim the operator passed --target-postgres-instance "
            "when the instance may have been auto-detected",
        )
        self.assertNotIn(
            'Auto-selected --state-mode greenfield (no --target-postgres-instance)',
            text,
        )

    def test_log_and_comment_mention_auto_detect(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "named via --target-postgres-instance or resolved by the "
            "single-instance auto-detect",
            text,
            "brownfield auto-select log must cover the auto-detect path",
        )
        self.assertIn(
            "autodetect_single_pg_instance fills TARGET_CLUSTER",
            text,
            "the comment above the auto-default must explain that auto-detect "
            "also lands in the brownfield branch",
        )

    def test_usage_documents_auto_detect_default(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # Kept for compatibility with the older suites…
        self.assertIn("Default: greenfield, unless", text)
        # …but the sentence must now describe the auto-detect path and why
        # brownfield is correct for it.
        m = re.search(r"Default: greenfield, unless(?P<rest>[\s\S]{0,600})", text)
        self.assertIsNotNone(m)
        rest = m.group("rest")
        self.assertIn("single-instance auto-detect", rest)
        self.assertIn("documentdb-postgresql@N.service", rest)

    def test_auto_default_behavior_is_unchanged(self):
        # Texts only — the behavior contract from the earlier rounds stays.
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            text,
            r'if \[\[ -n "\$\{TARGET_CLUSTER\}" \]\]; then\s+STATE_MODE="brownfield"',
        )


class RegisterGatewayRestoreTlsCleanupTests(unittest.TestCase):
    """Finding 7: do_restore removed only pg-url and orphaned the
    auto-generated TLS private key dir ${SECRET_DIR}/tls after teardown."""

    def _do_restore_body(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        m = re.search(r"do_restore\(\)\s*\{(?P<body>[\s\S]*?)\n\}", text)
        self.assertIsNotNone(m, "do_restore not found")
        return m.group("body")

    def test_restore_removes_tls_dir_and_prunes_secret_dir(self):
        body = self._do_restore_body()
        self.assertIn('rm -rf "${SECRET_DIR}/tls"', body,
                      "do_restore must delete the auto-generated TLS key dir")
        self.assertIn('rmdir --ignore-fail-on-non-empty "${SECRET_DIR}"', body,
                      "do_restore must prune the secret dir when empty")
        # The key material must be gone before the prune attempt.
        self.assertLess(body.index('rm -rf "${SECRET_DIR}/tls"'),
                        body.index('rmdir --ignore-fail-on-non-empty "${SECRET_DIR}"'))

    def test_restore_documents_uid_recycling_hazard(self):
        body = self._do_restore_body()
        self.assertIn("recycles that UID", body,
                      "the deleted-UID recycling hazard must be documented")
        self.assertIn("pkey.pem", body)

    def test_dry_run_previews_tls_dir_removal(self):
        body = self._do_restore_body()
        self.assertIn(
            'log "  - auto-generated TLS key material ${SECRET_DIR}/tls"', body,
            "the --dry-run preview must mention the TLS dir it would remove")


class RegisterGatewayTlsAutoGenerateValidationTests(unittest.TestCase):
    """Finding 8: --tls-auto-generate false with no certificate pair was only
    rejected by the gateway daemon at startup (exit 78 + systemd restart
    loop). The CLI must reject it up front."""

    ERROR_SNIPPET = "--tls-auto-generate false requires both --tls-cert and --tls-key"

    def test_false_without_pair_is_rejected_at_cli(self):
        with tempfile.TemporaryDirectory() as td:
            r = subprocess.run(
                ["bash", str(GATEWAY_SETUP_SCRIPT), "--pgdata", td,
                 "--tls-auto-generate", "false", "--dry-run", "--yes"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10,
            )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(self.ERROR_SNIPPET, r.stderr)
        # The message must explain the daemon-side failure it prevents.
        self.assertIn("exit 78", r.stderr)

    def test_false_with_pair_passes_the_check(self):
        with tempfile.TemporaryDirectory() as td:
            cert = Path(td) / "cert.pem"
            key = Path(td) / "key.pem"
            cert.write_text("dummy-cert\n", encoding="utf-8")
            key.write_text("dummy-key\n", encoding="utf-8")
            r = subprocess.run(
                ["bash", str(GATEWAY_SETUP_SCRIPT), "--pgdata", td,
                 "--tls-auto-generate", "false",
                 "--tls-cert", str(cert), "--tls-key", str(key),
                 "--dry-run", "--yes"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10,
            )
        # The run may stop later for unrelated environmental reasons; the
        # contract under test is only that this validation does not fire.
        self.assertNotIn(self.ERROR_SNIPPET, r.stderr)

    def test_restore_ignores_tls_auto_generate(self):
        r = subprocess.run(
            ["bash", str(GATEWAY_SETUP_SCRIPT), "--restore", "--dry-run",
             "--pg-version", "99", "--tls-auto-generate", "false"],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10,
        )
        self.assertNotIn(self.ERROR_SNIPPET, r.stderr)


class EntrypointGatewaySelfExitPgStopTests(unittest.TestCase):
    """Finding 9: the clean PostgreSQL stop was bound only to the
    SIGTERM/SIGINT trap; a gateway self-exit (crash/OOM) let the script exit
    as PID 1 and the postmaster got SIGKILLed, forcing WAL recovery."""

    def test_cleanup_keeps_guarded_pg_stop(self):
        text = ENTRYPOINT.read_text(encoding="utf-8")
        m = re.search(r"cleanup\(\)\s*\{(?P<body>[\s\S]*?)\n\}", text)
        self.assertIsNotNone(m)
        body = m.group("body")
        # The clean stop stays in cleanup (docker-stop path)...
        self.assertIn('stop -D "${DATA_PATH}" -m fast', body)
        # ...guarded against a double stop when a signal lands while the
        # self-exit path is already running cleanup.
        self.assertIn('if [ "${POSTGRES_STOPPED:-false}" != "true" ]', body)
        self.assertIn("POSTGRES_STOPPED=true", body)
        # cleanup propagates a caller-supplied exit code (0 for the trap).
        self.assertIn('exit "${1:-0}"', body)

    def test_gateway_self_exit_path_runs_cleanup(self):
        text = ENTRYPOINT.read_text(encoding="utf-8")
        m = re.search(r"\nwait \$gateway_pid(?P<after>[\s\S]*)$", text)
        self.assertIsNotNone(m)
        after = m.group("after")
        # The exit status is captured set-e-safely (sourcing utils.sh turns
        # on set -e, which would otherwise abort at `wait` on a crash).
        self.assertIn("|| gateway_rc=$?", after,
                      "wait must capture a nonzero gateway status without "
                      "tripping set -e before the clean stop runs")
        self.assertIn('cleanup "$gateway_rc"', after,
                      "the post-wait (gateway self-exit) path must run the "
                      "same cleanup as the signal trap, stopping PG cleanly")


class EntrypointAdminPasswordHardeningTests(unittest.TestCase):
    """Finding 10: the admin password traveled through psql argv (visible in
    /proc/<pid>/cmdline) and was interpolated unescaped into the create_user
    JSON. The entrypoint now shadows utils.sh's stock SetupCustomAdminUser
    with a hardened variant (jq --rawfile from a 0600 temp file; SQL over
    stdin). utils.sh itself is shared with start_oss_server.sh and
    build_and_start_gateway.sh and stays unchanged."""

    def test_entrypoint_defines_hardened_shadow(self):
        text = ENTRYPOINT.read_text(encoding="utf-8")
        # Shadow only the stock (insecure) implementation; stubs/overrides
        # sourced from utils.sh keep working.
        self.assertIn("declare -f SetupCustomAdminUser", text)
        self.assertIn("jq -cn --rawfile pwd", text)
        self.assertIn('chmod 600 "$pw_file"', text)
        # SQL goes to psql over stdin, never argv.
        self.assertRegex(
            text,
            r"printf '%s\\n' \"SELECT documentdb_api\.create_user\('\$\{doc_sql\}'\);\"\s*\\\n\s*\| psql",
        )
        # The single-quote doubling for the SQL literal.
        self.assertIn("doc_sql=${create_user_doc//\\'/\\'\\'}", text)

    def test_hardened_create_user_sets_on_error_stop(self):
        # Round-11 F1: for stdin-scripted input psql exits 0 on SQL errors
        # unless ON_ERROR_STOP is set (the stock -c form exited 1). Without
        # it, a failed documentdb_api.create_user would slip past the
        # caller's error guard and the container would report ready with no
        # usable admin login.
        text = ENTRYPOINT.read_text(encoding="utf-8")
        shadow = text[text.index("SetupCustomAdminUser() {"):]
        shadow = shadow[:shadow.index("\n        }")]
        create_stmt_idx = shadow.index("documentdb_api.create_user")
        self.assertIn(
            "-v ON_ERROR_STOP=1",
            shadow[create_stmt_idx:],
            "the stdin-fed create_user psql call must set ON_ERROR_STOP so "
            "SQL-level failures propagate as a nonzero exit",
        )

    def test_utils_sh_signature_unchanged_for_other_callers(self):
        text = UTILS_SH.read_text(encoding="utf-8")
        self.assertIn("function SetupCustomAdminUser()", text,
                      "shared utils.sh must keep its signature for "
                      "start_oss_server.sh / build_and_start_gateway.sh")

    # ── Behavioral: run the entrypoint with the real utils.sh and a psql
    #    stub that records argv and stdin. ────────────────────────────────

    def _build_fixture(self, root: Path):
        gateway_home = root / "gateway"
        gateway_scripts = gateway_home / "scripts"
        gateway_config_dir = gateway_home / "pg_documentdb_gw"
        gateway_release = gateway_config_dir / "target" / "release-with-symbols"
        bin_dir = root / "bin"
        logs_dir = root / "logs"
        data_dir = root / "data"
        for d in (gateway_scripts, gateway_release, bin_dir, logs_dir, data_dir,
                  gateway_home / "sample-data"):
            d.mkdir(parents=True, exist_ok=True)

        (gateway_config_dir / "SetupConfiguration.json").write_text(
            json.dumps({
                "NodeHostName": "localhost",
                "BlockedRolePrefixes": ["documentdb"],
                "PostgresPort": 9712,
                "GatewayListenPort": 10260,
                "CertificateOptions": {"CertType": "PemAutoGenerated"},
            }),
            encoding="utf-8",
        )

        def write_exec(path: Path, content: str):
            path.write_text(textwrap.dedent(content), encoding="utf-8")
            path.chmod(0o755)

        write_exec(bin_dir / "sudo", """\
            #!/bin/sh
            if [ "$1" = "chown" ]; then
              exit 0
            fi
            exec "$@"
            """)
        write_exec(bin_dir / "nc", "#!/bin/sh\nexit 0\n")
        write_exec(bin_dir / "tail", "#!/bin/sh\nexit 0\n")
        write_exec(bin_dir / "pg_isready", "#!/bin/sh\nexit 0\n")

        # The REAL shared utils.sh: its stock SetupCustomAdminUser must be
        # detected and shadowed by the entrypoint's hardened variant.
        shutil.copy2(UTILS_SH, gateway_scripts / "utils.sh")

        argv_capture = root / "psql-argv.txt"
        stdin_capture = root / "psql-stdin.sql"
        write_exec(bin_dir / "psql", f"""\
            #!/bin/sh
            printf 'ARGS:%s\\n' "$*" >> {shlex.quote(str(argv_capture))}
            cat >> {shlex.quote(str(stdin_capture))}
            exit 0
            """)

        gateway_stub = "#!/bin/sh\necho gateway-daemon-stub-started\nexit 0\n"
        write_exec(gateway_release / "documentdb_gateway", gateway_stub)
        write_exec(bin_dir / "documentdb_gateway", gateway_stub)

        return {
            "gateway_home": gateway_home,
            "bin_dir": bin_dir,
            "logs_dir": logs_dir,
            "data_dir": data_dir,
            "config_file": gateway_config_dir / "target" / "test_config.json",
            "argv_capture": argv_capture,
            "stdin_capture": stdin_capture,
        }

    def test_password_never_reaches_psql_argv_and_is_json_escaped(self):
        if shutil.which("jq") is None:
            self.skipTest("jq not available; behavioral hardening test needs real jq")
        password = "pa\"ss'wd"  # double quote broke the old JSON interpolation
        with tempfile.TemporaryDirectory() as td:
            fx = self._build_fixture(Path(td))
            env = os.environ.copy()
            env.update({
                "PATH": f"{fx['bin_dir']}:{env['PATH']}",
                "GATEWAY_HOME": str(fx["gateway_home"]),
                "DOCUMENTDB_LOG_DIR": str(fx["logs_dir"]),
                "SYSTEM_POSTGRES_LOG": str(Path(td) / "postgres-system.log"),
                "START_POSTGRESQL": "false",
                "SKIP_INIT_DATA": "true",
                "CREATE_USER": "true",
                "USERNAME": "default_user",
                "PASSWORD": password,
                "OWNER": "documentdb",
                "DATA_PATH": str(fx["data_dir"]),
                "DOCUMENTDB_CONFIG_FILE": str(fx["config_file"]),
            })
            r = subprocess.run(
                ["bash", str(ENTRYPOINT)],
                cwd=str(OSS_ROOT), env=env, text=True,
                stdin=subprocess.DEVNULL, capture_output=True, timeout=30,
            )
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            # The hardened shadow ran (not the stock utils.sh path).
            self.assertIn("Setting up custom user default_user", r.stdout)
            # Finding 9 behavioral: the self-exit path reports and propagates
            # the gateway's exit status.
            self.assertIn("Gateway process exited with status 0.", r.stdout)

            argv = fx["argv_capture"].read_text(encoding="utf-8")
            sql = fx["stdin_capture"].read_text(encoding="utf-8")
            # The raw password must never appear in any psql argv.
            self.assertNotIn(password, argv)
            self.assertNotIn("pa\\\"ss", argv)
            # The SQL arrives on stdin with the JSON-escaped double quote and
            # the SQL-doubled single quote intact.
            self.assertIn("documentdb_api.create_user", sql)
            self.assertIn('"createUser":"default_user"', sql)
            self.assertIn('pa\\"ss\'\'wd', sql)
            # Role-existence probe also travels via stdin + psql variable.
            self.assertIn("WHERE rolname = :'u';", sql)

    def test_stub_override_from_utils_is_still_honored(self):
        # The shadow must replace ONLY the stock implementation: a custom
        # SetupCustomAdminUser sourced from utils.sh (used as the test seam by
        # test_emulator_entrypoint.py) keeps working.
        if shutil.which("jq") is None:
            self.skipTest("jq not available; the entrypoint's config rewrite needs real jq")
        with tempfile.TemporaryDirectory() as td:
            fx = self._build_fixture(Path(td))
            stub = fx["gateway_home"] / "scripts" / "utils.sh"
            stub.write_text(
                '#!/bin/sh\nSetupCustomAdminUser() { echo "stub-user-created"; }\n',
                encoding="utf-8")
            env = os.environ.copy()
            env.update({
                "PATH": f"{fx['bin_dir']}:{env['PATH']}",
                "GATEWAY_HOME": str(fx["gateway_home"]),
                "DOCUMENTDB_LOG_DIR": str(fx["logs_dir"]),
                "SYSTEM_POSTGRES_LOG": str(Path(td) / "postgres-system.log"),
                "START_POSTGRESQL": "false",
                "SKIP_INIT_DATA": "true",
                "CREATE_USER": "true",
                "USERNAME": "default_user",
                "PASSWORD": secrets.token_hex(8) + "Aa1!",
                "OWNER": "documentdb",
                "DATA_PATH": str(fx["data_dir"]),
                "DOCUMENTDB_CONFIG_FILE": str(fx["config_file"]),
            })
            r = subprocess.run(
                ["bash", str(ENTRYPOINT)],
                cwd=str(OSS_ROOT), env=env, text=True,
                stdin=subprocess.DEVNULL, capture_output=True, timeout=30,
            )
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("stub-user-created", r.stdout)
            # The stub was honored, so no psql call was made at all.
            self.assertFalse(fx["argv_capture"].exists())


if __name__ == "__main__":
    unittest.main()
