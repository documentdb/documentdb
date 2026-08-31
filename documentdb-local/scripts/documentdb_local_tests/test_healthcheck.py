"""Unit tests for documentdb-local/scripts/healthcheck.sh.

Same stub-PATH harness as test_emulator_entrypoint.py: the real script runs
under bash with `openssl` / `pg_isready` replaced by stubs that record their
argv, so the tests assert which probes ran, against which ports, and how
their exit codes map to the health verdict.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
HEALTHCHECK = REPO_ROOT / "documentdb-local" / "scripts" / "healthcheck.sh"
# Absolute, so PATH in the child env is purely the stub search path and a test
# may narrow it to the stub directory alone.
BASH = shutil.which("bash") or "bash"


class HealthcheckTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.state_file = self.root / "runtime-state.env"
        # Default stubs: both probes succeed. Individual tests re-stub.
        self.openssl_args = self._stub_probe("openssl", 0)
        self.pg_isready_args = self._stub_probe("pg_isready", 0)

    def tearDown(self):
        self.temp_dir.cleanup()

    def _stub_probe(self, name: str, exit_code: int) -> Path:
        capture = self.root / f"{name}.args"
        stub = self.bin_dir / name
        stub.write_text(
            f'#!/bin/sh\necho "$@" >> "{capture}"\nexit {exit_code}\n',
            encoding="utf-8",
        )
        stub.chmod(0o755)
        return capture

    def _write_state(self, **values):
        lines = "".join(f"{key}={value}\n" for key, value in values.items())
        self.state_file.write_text(lines, encoding="utf-8")

    def _run(self, *args, extra_env=None):
        env = os.environ.copy()
        # The exec environment must not leak these into the run; tests set
        # them explicitly when the env-fallback path is under test.
        for var in ("DOCUMENTDB_PORT", "POSTGRESQL_PORT"):
            env.pop(var, None)
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "DOCUMENTDB_RUNTIME_STATE_FILE": str(self.state_file),
            }
        )
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [BASH, str(HEALTHCHECK), *args],
            env=env,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def test_missing_state_file_reports_unhealthy_without_probing(self):
        result = self._run()

        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
        self.assertIn("startup has not completed", result.stdout)
        self.assertFalse(self.openssl_args.exists())
        self.assertFalse(self.pg_isready_args.exists())

    @unittest.skipIf(
        not hasattr(os, "geteuid") or os.geteuid() == 0,
        "requires a non-root POSIX user for chmod 000 to deny reads",
    )
    def test_unreadable_state_file_reports_unhealthy_without_probing(self):
        # `[ -f ]` alone would pass here and the probe would silently continue
        # on env/default ports — the state file must be OPENED, fail-closed.
        self._write_state(DOCUMENTDB_PORT=12345, POSTGRESQL_PORT=9712)
        self.state_file.chmod(0o000)

        result = self._run()

        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
        self.assertIn("startup has not completed", result.stdout)
        self.assertFalse(self.openssl_args.exists())
        self.assertFalse(self.pg_isready_args.exists())

    def test_crlf_state_file_is_parsed(self):
        # CRLF line endings must not leave an invisible \r inside the values
        # (which would fail is_port with a message that looks self-refuting).
        self.state_file.write_bytes(
            b"DOCUMENTDB_PORT=12345\r\nPOSTGRESQL_PORT=9876\r\n"
        )

        result = self._run()

        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("localhost:12345", self.openssl_args.read_text(encoding="utf-8"))
        self.assertIn("-p 9876", self.pg_isready_args.read_text(encoding="utf-8"))

    def test_missing_openssl_is_unhealthy(self):
        # Same contract as the pg_isready guard: a broken image must not be
        # misreported as a failed handshake.
        (self.bin_dir / "openssl").unlink()
        self._write_state(DOCUMENTDB_PORT=12345, POSTGRESQL_PORT=9712)

        result = self._run(extra_env={"PATH": str(self.bin_dir)})

        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
        self.assertIn("openssl not found", result.stdout)

    def test_healthy_when_all_probes_succeed(self):
        # START_POSTGRESQL / TLS_MODE are unlisted keys the parser must skip
        # (the probe reads only the two ports).
        self._write_state(
            DOCUMENTDB_PORT=12345,
            POSTGRESQL_PORT=9876,
            START_POSTGRESQL="true",
            TLS_MODE="allowTLS",
        )

        result = self._run()

        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertTrue(
            result.stdout.startswith("healthy:"),
            f"expected a healthy verdict, got: {result.stdout!r}",
        )
        # Exact argv, not substrings: an added flag like -quiet (which
        # implies -ign_eof) would hang every probe on the open connection,
        # and a substring check would never notice it.
        self.assertEqual(
            self.openssl_args.read_text(encoding="utf-8").strip(),
            "s_client -connect localhost:12345",
        )
        self.assertEqual(
            self.pg_isready_args.read_text(encoding="utf-8").strip(),
            "-q -h localhost -p 9876",
        )

    def test_state_file_port_beats_exec_environment(self):
        # HEALTHCHECK / docker exec sessions see only the image's ENV
        # defaults; the entrypoint's published state must win over them.
        self._write_state(DOCUMENTDB_PORT=12345, POSTGRESQL_PORT=9712)

        result = self._run(extra_env={"DOCUMENTDB_PORT": "59999"})

        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("localhost:12345", self.openssl_args.read_text(encoding="utf-8"))

    def test_port_argument_beats_state_file(self):
        self._write_state(DOCUMENTDB_PORT=12345, POSTGRESQL_PORT=9712)

        result = self._run("23456")

        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("localhost:23456", self.openssl_args.read_text(encoding="utf-8"))

    def test_gateway_probe_failure_is_unhealthy(self):
        self._write_state(DOCUMENTDB_PORT=12345, POSTGRESQL_PORT=9712)
        self._stub_probe("openssl", 1)

        result = self._run()

        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
        self.assertIn("TLS handshake", result.stdout)

    def test_postgres_probe_failure_is_unhealthy(self):
        # This also covers an externally started PostgreSQL
        # (START_POSTGRESQL=false): the gateway always dials localhost, so a
        # dead backend is unhealthy regardless of who was meant to start it —
        # a TLS handshake alone cannot see it.
        self._write_state(DOCUMENTDB_PORT=12345, POSTGRESQL_PORT=9712)
        self._stub_probe("pg_isready", 2)

        result = self._run()

        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
        self.assertIn("PostgreSQL is not accepting connections", result.stdout)
        self.assertFalse(self.openssl_args.exists())

    def test_non_numeric_port_fails_without_probing(self):
        self._write_state(DOCUMENTDB_PORT="banana", POSTGRESQL_PORT=9712)

        result = self._run()

        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
        self.assertIn("invalid DocumentDB port", result.stdout)
        self.assertFalse(self.openssl_args.exists())

    def test_out_of_range_port_fails_without_probing(self):
        self._write_state(DOCUMENTDB_PORT=70000, POSTGRESQL_PORT=9712)

        result = self._run()

        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
        self.assertIn("invalid DocumentDB port", result.stdout)
        self.assertFalse(self.openssl_args.exists())

    def test_port_wider_than_shell_integer_fails_cleanly(self):
        # A 20-digit value passes a bare digits check; without the width
        # guard, `[ -ge ]` on it writes "integer expression expected" into
        # the container's health log instead of a clean verdict.
        self._write_state(
            DOCUMENTDB_PORT="99999999999999999999", POSTGRESQL_PORT=9712
        )

        result = self._run()

        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
        self.assertIn("invalid DocumentDB port", result.stdout)
        self.assertNotIn("integer expression expected", result.stderr)
        self.assertFalse(self.openssl_args.exists())

    def test_state_file_values_are_not_executed(self):
        # The probe must read the file literally rather than sourcing it: a
        # corrupt or hand-edited file must never execute on every probe.
        self.state_file.write_text(
            "DOCUMENTDB_PORT=12345\n"
            "POSTGRESQL_PORT=9712\n"
            "EXTRA_SETTING=harmless; echo INJECTED\n",
            encoding="utf-8",
        )

        result = self._run()

        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertNotIn("INJECTED", result.stdout + result.stderr)

    def test_state_file_value_with_whitespace_is_not_truncated(self):
        # A truncating parser would read a valid 9712 here and quietly mask a
        # corrupt value; the probe must read it intact and reject it.
        self._write_state(DOCUMENTDB_PORT=12345, POSTGRESQL_PORT="9712 1")

        result = self._run()

        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
        self.assertIn("invalid PostgreSQL port", result.stdout)
        self.assertFalse(self.pg_isready_args.exists())
        self.assertFalse(self.openssl_args.exists())

    def test_missing_pg_isready_is_unhealthy(self):
        # Reporting healthy without the probe would mean reporting healthy
        # with a dead database whenever the gateway's TLS listener answers.
        (self.bin_dir / "pg_isready").unlink()
        self._write_state(DOCUMENTDB_PORT=12345, POSTGRESQL_PORT=9712)

        result = self._run(extra_env={"PATH": str(self.bin_dir)})

        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
        self.assertIn("pg_isready not found", result.stdout)
        self.assertFalse(self.openssl_args.exists())

    def test_environment_used_when_state_file_omits_keys(self):
        # An (empty) state file still gates readiness; missing keys fall back
        # to the exec environment, then to the built-in defaults.
        self.state_file.write_text("", encoding="utf-8")

        result = self._run(extra_env={"DOCUMENTDB_PORT": "31000"})

        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("localhost:31000", self.openssl_args.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
