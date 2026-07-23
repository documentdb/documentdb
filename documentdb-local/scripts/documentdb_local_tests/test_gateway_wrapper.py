# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Unit tests for the packaged documentdb-gateway wrapper
# (oss/packaging/gateway/documentdb-gateway-wrapper.sh). The wrapper is
# installed verbatim at /usr/bin/documentdb-gateway by both the DEB build and
# the RPM spec. These tests live under documentdb_local_tests because that is
# the directory the CI workflow discovers (`python3 -m unittest discover -p
# 'test_*.py'`); the suite already exercises packaging scripts via OSS_ROOT.
#
# The behavioral tests run a *sandboxed copy* of the wrapper whose daemon path
# and env-file search roots are redirected into a temp dir, so they neither
# require the real daemon binary nor read /etc. The stubbed daemon prints a
# sentinel and exits 0, which lets the "allow" cases positively assert that the
# launch actually happened (return code 0 + sentinel) rather than only that the
# rejection did not fire. INVOCATION_ID is set so the wrapper takes the
# systemd-style direct-exec path and never tries `runuser`, keeping the tests
# deterministic regardless of whether CI runs as root.

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

OSS_ROOT = Path(__file__).resolve().parents[3]
WRAPPER_SCRIPT = OSS_ROOT / "packaging" / "gateway" / "documentdb-gateway-wrapper.sh"

# Substring the wrapper prints on stderr when it refuses an inline
# DOCUMENTDB_PG_URL. Kept in one place so the assertions stay in sync with the
# wrapper's message.
REJECT_MARKER = "DOCUMENTDB_PG_URL is not supported"

# Substring the wrapper prints on stderr when more than one per-major
# gateway.env matches and no DOCUMENTDB_PG_URL_FILE pins the instance.
AMBIGUITY_MARKER = "refusing to guess which one to use"

# Marker the stubbed daemon prints to stdout so a test can prove the wrapper
# actually reached the daemon launch (the "allow" path) rather than exiting
# earlier for an unrelated reason.
DAEMON_SENTINEL = "STUB_DAEMON_REACHED"

# Literal lines the sandbox rewrites; asserted so a future wrapper reformat
# can't silently turn the substitutions into no-ops (which would make the
# behavioral tests exec the real /usr/lib daemon or read the real /etc).
_REAL_DAEMON_LINE = 'DAEMON="/usr/lib/documentdb-gateway/documentdb-gateway-daemon"'
_REAL_ETC_ROOT = "/etc/documentdb"


def _prepare_wrapper(workdir):
    """Write a sandboxed copy of the wrapper into ``workdir``.

    The real daemon path is replaced with a stub that prints a sentinel and
    exits 0, and the hardcoded ``/etc/documentdb`` env-file search roots are
    redirected under ``workdir`` so a test can drop a ``gateway.env`` for
    ``_load_env`` to source. Returns ``(wrapper_path, etc_dir)``.
    """
    # Use a redirect root that does NOT itself contain "/etc/documentdb", so the
    # post-substitution assertion below can confirm the real root is fully gone.
    etc_dir = workdir / "cfgroot"
    fake_daemon = workdir / "fake-daemon"
    # The stub echoes the DOCUMENTDB_* environment it was handed, not just a
    # sentinel. Without this every "allow" assertion is env-blind: a
    # regression that parsed gateway.env but exported nothing, or that loaded
    # the WRONG major's env, still reached the daemon and still passed. (That
    # was verified by mutation -- breaking the exporter left the positive
    # tests green.) Echoing lets the tests assert what actually got through.
    fake_daemon.write_text(
        f"#!/bin/sh\n"
        f"echo {DAEMON_SENTINEL}\n"
        f'echo "PG_URL_FILE=${{DOCUMENTDB_PG_URL_FILE-}}"\n'
        f'echo "LISTEN_ADDR=${{DOCUMENTDB_LISTEN_ADDR-}}"\n'
        f'echo "TLS_CERT_FILE=${{DOCUMENTDB_TLS_CERT_FILE-}}"\n'
        f"exit 0\n"
    )
    fake_daemon.chmod(0o755)

    source = WRAPPER_SCRIPT.read_text()
    if _REAL_DAEMON_LINE not in source or _REAL_ETC_ROOT not in source:
        raise AssertionError(
            "wrapper text drifted; sandbox substitution tokens not found. "
            "Update _REAL_DAEMON_LINE / _REAL_ETC_ROOT to match the wrapper."
        )
    source = source.replace(_REAL_DAEMON_LINE, f'DAEMON="{fake_daemon}"')
    # Redirect both hardcoded env-file roots (and the comment naming them) at
    # once; every occurrence lives under /etc/documentdb.
    source = source.replace(_REAL_ETC_ROOT, str(etc_dir))
    # Belt and suspenders: confirm neither real target survives, so the
    # behavioral tests can never accidentally hit the real daemon or /etc.
    # Explicit raise (not assert) so the guard still runs under `python -O`.
    if _REAL_DAEMON_LINE in source or _REAL_ETC_ROOT in source:
        raise AssertionError("sandbox substitution failed; a real daemon/etc target survived")

    wrapper = workdir / "documentdb-gateway-wrapper.sh"
    wrapper.write_text(source)
    wrapper.chmod(0o755)
    return wrapper, etc_dir


def _run(wrapper, args, *, env_overrides=None):
    """Run the wrapper in a clean environment.

    Every DOCUMENTDB_* variable is stripped first (so a value inherited from
    the CI environment can neither mask nor trigger the guard), then the
    requested overrides are applied. INVOCATION_ID forces the systemd-style
    direct-exec path so the stubbed daemon is reached without `runuser`.
    """
    env = {k: v for k, v in os.environ.items() if not k.startswith("DOCUMENTDB_")}
    # Pretend we're under systemd so _maybe_runuser_down takes the direct-exec
    # path and never calls runuser; the outcome is then independent of the test
    # UID and of whether the documentdb-gateway OS user exists.
    env["INVOCATION_ID"] = "documentdb-wrapper-test"
    for key, value in (env_overrides or {}).items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = value
    return subprocess.run(
        ["bash", str(wrapper), *args],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )


def _write_gateway_env(etc_dir, contents, *, major="18"):
    env_file = etc_dir / "local" / major / "gateway.env"
    env_file.parent.mkdir(parents=True, exist_ok=True)
    env_file.write_text(contents)
    return env_file


class _WrapperTestCase(unittest.TestCase):
    def assertRejected(self, result):
        """The guard fired: non-zero exit, reject marker, daemon NOT reached."""
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn(REJECT_MARKER, result.stderr)
        self.assertNotIn(DAEMON_SENTINEL, result.stdout)

    def assertLaunched(self, result):
        """The guard passed: clean exit, no reject marker, daemon reached."""
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(REJECT_MARKER, result.stderr)
        self.assertIn(DAEMON_SENTINEL, result.stdout)


class WrapperInlinePgUrlRejectionTests(_WrapperTestCase):
    """The wrapper must fail closed on an inline DOCUMENTDB_PG_URL in the
    caller's environment.

    The daemon reads only DOCUMENTDB_PG_URL_FILE, so an inline DOCUMENTDB_PG_URL
    is both non-functional and a password-leak vector (/proc/<pid>/environ).
    """

    def _run_sandboxed(self, args, **env):
        with tempfile.TemporaryDirectory() as tmp:
            wrapper, _ = _prepare_wrapper(Path(tmp))
            return _run(wrapper, args, env_overrides=env)

    def test_inline_pg_url_with_password_is_rejected(self):
        result = self._run_sandboxed(["run"], DOCUMENTDB_PG_URL="postgres://u:secret@/db")
        self.assertRejected(result)

    def test_inline_pg_url_without_password_is_rejected(self):
        # Even a passwordless inline URL is rejected: the daemon never reads it,
        # so honoring it would only mask a misconfiguration.
        result = self._run_sandboxed(
            ["run"], DOCUMENTDB_PG_URL="postgres:///db?host=/var/run/postgresql"
        )
        self.assertRejected(result)

    def test_inline_pg_url_rejected_on_every_dispatch_path(self):
        # The guard runs before the subcommand case, so every entry point
        # (run / --check / --version / no-arg / pass-through) fails closed.
        for argv in ([], ["run"], ["--check"], ["--version"], ["/etc/conf.json"]):
            with self.subTest(argv=argv):
                result = self._run_sandboxed(argv, DOCUMENTDB_PG_URL="postgres://u:secret@/db")
                self.assertRejected(result)

    def test_password_value_is_not_echoed(self):
        # The rejection message must never echo the variable's value, or it
        # would leak the secret it is trying to protect into logs.
        sentinel = "S3nt1nelPwDoNotEcho"
        result = self._run_sandboxed(["run"], DOCUMENTDB_PG_URL=f"postgres://u:{sentinel}@/db")
        self.assertRejected(result)
        self.assertNotIn(sentinel, result.stderr)
        self.assertNotIn(sentinel, result.stdout)


class WrapperEnvFileRejectionTests(_WrapperTestCase):
    """An inline DOCUMENTDB_PG_URL must be rejected no matter the source.

    _source_env_if_present exports every DOCUMENTDB_* key, so a hand-edited
    gateway.env containing DOCUMENTDB_PG_URL would otherwise be loaded into the
    daemon's environment after a guard that only checked the caller's env.
    """

    def test_inline_pg_url_from_gateway_env_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            wrapper, etc = _prepare_wrapper(Path(tmp))
            _write_gateway_env(
                etc,
                "DOCUMENTDB_LISTEN_ADDR=0.0.0.0:10260\n"
                "DOCUMENTDB_PG_URL=postgres://u:secret@/db\n",
            )
            self.assertRejected(_run(wrapper, ["run"]))

    def test_inline_pg_url_password_from_gateway_env_not_echoed(self):
        sentinel = "EnvFileSecretDoNotEcho"
        with tempfile.TemporaryDirectory() as tmp:
            wrapper, etc = _prepare_wrapper(Path(tmp))
            _write_gateway_env(etc, f"DOCUMENTDB_PG_URL=postgres://u:{sentinel}@/db\n")
            result = _run(wrapper, ["run"])
            self.assertRejected(result)
            self.assertNotIn(sentinel, result.stderr)
            self.assertNotIn(sentinel, result.stdout)

    def test_pg_url_file_from_gateway_env_is_not_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            wrapper, etc = _prepare_wrapper(Path(tmp))
            _write_gateway_env(
                etc,
                "DOCUMENTDB_PG_URL_FILE=/var/lib/documentdb-local/18/gateway/pg-url\n",
            )
            self.assertLaunched(_run(wrapper, ["run"]))


class WrapperNotRejectedTests(_WrapperTestCase):
    """A DOCUMENTDB_PG_URL_FILE-only (or empty) environment must pass the guard
    and reach the (stubbed) daemon launch."""

    def _run_sandboxed(self, args, **env):
        with tempfile.TemporaryDirectory() as tmp:
            wrapper, _ = _prepare_wrapper(Path(tmp))
            return _run(wrapper, args, env_overrides=env)

    def test_pg_url_file_only_is_not_rejected(self):
        result = self._run_sandboxed(
            ["run"], DOCUMENTDB_PG_URL_FILE="/var/lib/documentdb-local/18/gateway/pg-url"
        )
        self.assertLaunched(result)

    def test_no_pg_url_env_is_not_rejected(self):
        self.assertLaunched(self._run_sandboxed(["run"]))

    def test_empty_inline_pg_url_is_not_rejected(self):
        # An explicitly empty value is treated as unset, so it must not trip
        # the guard (the guard checks for a non-empty value).
        self.assertLaunched(self._run_sandboxed(["run"], DOCUMENTDB_PG_URL=""))


class WrapperMultiMajorAmbiguityTests(_WrapperTestCase):
    """On a host with more than one registered major, the wrapper must refuse
    rather than silently pick the lexically-first ``gateway.env``.

    Co-installing majors is supported (packaging-design.md 4.4), so the glob in
    ``_load_env`` can legitimately match several files. Taking the first one
    made a manual root ``documentdb-gateway --check``/``run`` probe or bind the
    wrong instance with no diagnostic, because the ``_load_env`` call site
    discards its output. ``documentdb-gateway-admin`` already refuses in the
    same situation; this pins the wrapper to matching behavior.
    """

    def _run_with_majors(self, majors, args=("run",), **env):
        with tempfile.TemporaryDirectory() as tmp:
            wrapper, etc_dir = _prepare_wrapper(Path(tmp))
            for major in majors:
                _write_gateway_env(
                    etc_dir,
                    f"DOCUMENTDB_PG_URL_FILE=/var/lib/documentdb-local/{major}/gateway/pg-url\n",
                    major=major,
                )
            return _run(wrapper, list(args), env_overrides=env)

    def assertAmbiguityRefused(self, result):
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn(AMBIGUITY_MARKER, result.stderr)
        self.assertNotIn(DAEMON_SENTINEL, result.stdout)

    def test_single_major_launches(self):
        # Baseline: one registered major is unambiguous, so the daemon runs.
        self.assertLaunched(self._run_with_majors(["18"]))

    def test_multiple_majors_are_refused(self):
        self.assertAmbiguityRefused(self._run_with_majors(["17", "18"]))

    def test_refusal_names_every_candidate(self):
        # The operator has to be able to act on the message, so it must list
        # the files rather than just declaring the situation ambiguous.
        result = self._run_with_majors(["17", "18"])
        self.assertIn("local/17/gateway.env", result.stderr)
        self.assertIn("local/18/gateway.env", result.stderr)

    def test_explicit_pg_url_file_disambiguates(self):
        # The systemd path (EnvironmentFile= pinned to the unit instance) and
        # callers like documentdb-setup both arrive with DOCUMENTDB_PG_URL_FILE
        # already set. They are not ambiguous and must not be blocked.
        self.assertLaunched(
            self._run_with_majors(
                ["17", "18"],
                DOCUMENTDB_PG_URL_FILE="/var/lib/documentdb-local/18/gateway/pg-url",
            )
        )

    def test_refusal_precedes_daemon_launch(self):
        # Failing closed only matters if it happens before the daemon binds.
        result = self._run_with_majors(["16", "17", "18"])
        self.assertNotIn(DAEMON_SENTINEL, result.stdout)

    def test_version_is_exempt_from_the_ambiguity_check(self):
        # --version reports the build and never touches PostgreSQL, so there
        # is no instance to be ambiguous about. Refusing it broke `documentdb-
        # gateway --version` on every multi-major host -- including the RPM
        # suite's root-shell privilege-drop probe, whose whole job is to run
        # --version.
        self.assertLaunched(self._run_with_majors(["17", "18"], args=["--version"]))

    def test_all_daemon_metadata_flags_are_exempt(self):
        # The daemon's metadata surface is wider than --version: clap also
        # serves -V, --help and -h. Exempting only --version left `documentdb-
        # gateway --help` refusing with a multi-instance error on any
        # two-major host, which is exactly the kind of first-contact command
        # a confused operator runs.
        for flag in ("-V", "--help", "-h"):
            with self.subTest(flag=flag):
                self.assertLaunched(self._run_with_majors(["17", "18"], args=[flag]))

    def test_check_is_not_exempt(self):
        # --check DOES probe a specific instance, so it must still refuse.
        self.assertAmbiguityRefused(self._run_with_majors(["17", "18"], args=["--check"]))


class WrapperEnvIsActuallyExportedTests(_WrapperTestCase):
    """The daemon must RECEIVE the values parsed out of gateway.env.

    Every other "allow" assertion in this file only proves the wrapper reached
    the daemon, not that it configured it. A wrapper that parsed the env file
    and exported nothing -- or that sourced the wrong major's file on a
    multi-major host -- would satisfy those and ship broken. These assert on
    the environment the stub daemon actually observed.
    """

    def _launch_with_env(self, contents, major="18"):
        with tempfile.TemporaryDirectory() as tmp:
            wrapper, etc_dir = _prepare_wrapper(Path(tmp))
            _write_gateway_env(etc_dir, contents, major=major)
            return _run(wrapper, ["run"])

    def test_pg_url_file_reaches_the_daemon(self):
        result = self._launch_with_env(
            "DOCUMENTDB_PG_URL_FILE=/var/lib/documentdb-local/18/gateway/pg-url\n"
        )
        self.assertLaunched(result)
        self.assertIn(
            "PG_URL_FILE=/var/lib/documentdb-local/18/gateway/pg-url",
            result.stdout,
            "the daemon did not receive DOCUMENTDB_PG_URL_FILE from gateway.env",
        )

    def test_listen_addr_and_tls_cert_reach_the_daemon(self):
        result = self._launch_with_env(
            "DOCUMENTDB_PG_URL_FILE=/var/lib/documentdb-local/18/gateway/pg-url\n"
            "DOCUMENTDB_LISTEN_ADDR=0.0.0.0:10260\n"
            'DOCUMENTDB_TLS_CERT_FILE="/etc/ssl/certs/gw.pem"\n'
        )
        self.assertLaunched(result)
        self.assertIn("LISTEN_ADDR=0.0.0.0:10260", result.stdout)
        # Surrounding quotes are stripped by the parser, as systemd's
        # EnvironmentFile= does.
        self.assertIn("TLS_CERT_FILE=/etc/ssl/certs/gw.pem", result.stdout)

    def test_non_documentdb_keys_are_not_exported(self):
        # The env file is untrusted input parsed as root, before the runuser
        # drop. Only DOCUMENTDB_* may cross into the daemon's environment.
        with tempfile.TemporaryDirectory() as tmp:
            wrapper, etc_dir = _prepare_wrapper(Path(tmp))
            _write_gateway_env(
                etc_dir,
                "DOCUMENTDB_PG_URL_FILE=/var/lib/documentdb-local/18/gateway/pg-url\n"
                "LD_PRELOAD=/tmp/evil.so\n"
                "PATH=/tmp/evil\n",
                major="18",
            )
            result = _run(wrapper, ["run"])
        self.assertLaunched(result)
        self.assertNotIn("/tmp/evil", result.stdout + result.stderr)

    def test_the_only_registered_major_is_the_one_loaded(self):
        # Guards the ambiguity fix from the other direction: with exactly one
        # major registered the wrapper must load THAT major's file, not
        # silently fall through to the global one.
        result = self._launch_with_env(
            "DOCUMENTDB_PG_URL_FILE=/var/lib/documentdb-local/17/gateway/pg-url\n",
            major="17",
        )
        self.assertLaunched(result)
        self.assertIn("PG_URL_FILE=/var/lib/documentdb-local/17/gateway/pg-url", result.stdout)


class WrapperStructuralContractTests(unittest.TestCase):
    """Static guards so the env-loading contract cannot silently regress."""

    @classmethod
    def setUpClass(cls):
        cls.source = WRAPPER_SCRIPT.read_text()

    def test_load_env_short_circuit_only_checks_pg_url_file(self):
        # Regression guard: the _load_env short-circuit must key off
        # DOCUMENTDB_PG_URL_FILE only. If it also honored a bare
        # DOCUMENTDB_PG_URL, setting that unsupported variable would skip
        # loading gateway.env and start the daemon with no connection file.
        match = re.search(
            r"_load_env\(\)\s*\{\s*\n\s*if\s*\[\[(?P<cond>.*?)\]\];\s*then",
            self.source,
            re.DOTALL,
        )
        self.assertIsNotNone(match, "could not locate the _load_env short-circuit guard")
        condition = match.group("cond")
        self.assertIn("DOCUMENTDB_PG_URL_FILE", condition)
        self.assertNotRegex(
            condition,
            r"DOCUMENTDB_PG_URL(?!_FILE)",
            "the _load_env guard must not short-circuit on a bare DOCUMENTDB_PG_URL",
        )

    def test_reject_runs_after_env_load_and_before_launch(self):
        # Security ordering guard: the top-level rejection must run AFTER
        # _load_env (so it also catches an inline value sourced from
        # gateway.env) and BEFORE the daemon launch (so it covers every entry
        # point and fires before any daemon exec).
        order = re.search(r"\n_load_env\b[^\n]*\n_reject_inline_pg_url\n", self.source)
        self.assertIsNotNone(
            order,
            "the top-level _load_env call must be immediately followed by _reject_inline_pg_url",
        )
        launch_idx = self.source.index('\n_maybe_runuser_down "$@"')
        self.assertLess(
            order.start(),
            launch_idx,
            "_reject_inline_pg_url must run before the daemon launch",
        )


if __name__ == "__main__":
    unittest.main()
