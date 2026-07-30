"""Unit tests for documentdb-local/scripts/healthcheck.sh.

Same stub-PATH harness as test_emulator_entrypoint.py: the real script runs
under bash with `openssl` / `pg_isready` replaced by stubs that record their
argv, so the tests assert which probes ran, against which ports, and how
their exit codes map to the health verdict.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
HEALTHCHECK = REPO_ROOT / "documentdb-local" / "scripts" / "healthcheck.sh"


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
        for var in ("DOCUMENTDB_PORT", "POSTGRESQL_PORT", "START_POSTGRESQL"):
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
            ["bash", str(HEALTHCHECK), *args],
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

    def test_healthy_when_all_probes_succeed(self):
        self._write_state(
            DOCUMENTDB_PORT=12345,
            POSTGRESQL_PORT=9876,
            START_POSTGRESQL="true",
            TLS_MODE="allowTLS",
        )

        result = self._run()

        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("healthy", result.stdout)
        self.assertIn("localhost:12345", self.openssl_args.read_text(encoding="utf-8"))
        pg_args = self.pg_isready_args.read_text(encoding="utf-8")
        self.assertIn("-p 9876", pg_args)
        self.assertIn("-h localhost", pg_args)

    def test_state_file_port_beats_exec_environment(self):
        # HEALTHCHECK / docker exec sessions see only the image's ENV
        # defaults; the entrypoint's published state must win over them.
        self._write_state(
            DOCUMENTDB_PORT=12345, POSTGRESQL_PORT=9712, START_POSTGRESQL="false"
        )

        result = self._run(extra_env={"DOCUMENTDB_PORT": "59999"})

        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("localhost:12345", self.openssl_args.read_text(encoding="utf-8"))

    def test_port_argument_beats_state_file(self):
        self._write_state(
            DOCUMENTDB_PORT=12345, POSTGRESQL_PORT=9712, START_POSTGRESQL="false"
        )

        result = self._run("23456")

        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("localhost:23456", self.openssl_args.read_text(encoding="utf-8"))

    def test_gateway_probe_failure_is_unhealthy(self):
        self._write_state(
            DOCUMENTDB_PORT=12345, POSTGRESQL_PORT=9712, START_POSTGRESQL="false"
        )
        self._stub_probe("openssl", 1)

        result = self._run()

        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
        self.assertIn("TLS handshake", result.stdout)

    def test_postgres_probe_failure_is_unhealthy(self):
        self._write_state(
            DOCUMENTDB_PORT=12345, POSTGRESQL_PORT=9712, START_POSTGRESQL="true"
        )
        self._stub_probe("pg_isready", 2)

        result = self._run()

        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
        self.assertIn("PostgreSQL is not accepting connections", result.stdout)
        self.assertFalse(self.openssl_args.exists())

    def test_postgres_probe_skipped_for_external_postgres(self):
        self._write_state(
            DOCUMENTDB_PORT=12345, POSTGRESQL_PORT=9712, START_POSTGRESQL="false"
        )
        self._stub_probe("pg_isready", 2)

        result = self._run()

        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertFalse(self.pg_isready_args.exists())

    def test_non_numeric_port_fails_without_probing(self):
        self._write_state(
            DOCUMENTDB_PORT="banana", POSTGRESQL_PORT=9712, START_POSTGRESQL="false"
        )

        result = self._run()

        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
        self.assertIn("invalid DocumentDB port", result.stdout)
        self.assertFalse(self.openssl_args.exists())

    def test_out_of_range_port_fails_without_probing(self):
        self._write_state(
            DOCUMENTDB_PORT=70000, POSTGRESQL_PORT=9712, START_POSTGRESQL="false"
        )

        result = self._run()

        self.assertEqual(result.returncode, 1, msg=result.stdout + result.stderr)
        self.assertIn("invalid DocumentDB port", result.stdout)
        self.assertFalse(self.openssl_args.exists())

    def test_environment_used_when_state_file_omits_keys(self):
        # An (empty) state file still gates readiness; missing keys fall back
        # to the exec environment, then to the built-in defaults.
        self.state_file.write_text("", encoding="utf-8")

        result = self._run(
            extra_env={"DOCUMENTDB_PORT": "31000", "START_POSTGRESQL": "false"}
        )

        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("localhost:31000", self.openssl_args.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
