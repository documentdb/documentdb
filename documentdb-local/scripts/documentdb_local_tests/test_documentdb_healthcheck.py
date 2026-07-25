"""Unit tests for documentdb_healthcheck.sh (issue #482).

The script is exercised directly with bash in a sandbox: the readiness
marker, the runtime-generated gateway configuration, and the `nc` probe are
all faked through environment variables, temp files, and a stub `nc` on
PATH that records how it was invoked. `jq` is the real one (it is a runtime
dependency of the image and of the script's port lookup).

Contract under test -- healthy (exit 0) if and only if:
  1. the readiness marker file exists (written by emulator_entrypoint.sh
     after startup, including one-shot data initialization, completes), AND
  2. a TCP connection to the gateway's effective listen port succeeds,
     where the effective port comes from the runtime-generated
     SetupConfiguration_temp.json when present (a `--documentdb-port` flag
     is invisible to the healthcheck's environment), falling back to
     DOCUMENTDB_PORT, then 10260.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
HEALTHCHECK = (
    REPO_ROOT / "documentdb-local" / "scripts" / "documentdb_healthcheck.sh"
)

_TOOLS = ("bash", "jq")
_SKIP_UNLESS_TOOLS = unittest.skipUnless(
    all(shutil.which(t) for t in _TOOLS),
    f"requires {', '.join(_TOOLS)} on PATH",
)


@_SKIP_UNLESS_TOOLS
class DocumentdbHealthcheckTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)

        self.gateway_home = self.root / "gateway"
        self.target_dir = self.gateway_home / "pg_documentdb_gw" / "target"
        self.target_dir.mkdir(parents=True)
        self.runtime_config = self.target_dir / "SetupConfiguration_temp.json"

        self.marker = self.root / "documentdb-local.ready"

        # Stub `nc` that records its argv and exits per NC_STUB_EXIT.
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.nc_calls = self.root / "nc_calls.txt"
        nc_stub = self.bin_dir / "nc"
        nc_stub.write_text(
            '#!/bin/sh\n'
            'printf \'%s\\n\' "$*" >> "$NC_CALLS_FILE"\n'
            'exit "${NC_STUB_EXIT:-0}"\n',
            encoding="utf-8",
        )
        nc_stub.chmod(0o755)

    def _run(self, *, env_overrides=None, nc_exit=0):
        env = {
            # Minimal, deterministic environment. PATH puts the stub `nc`
            # first but keeps the system dirs so bash finds jq.
            "PATH": f"{self.bin_dir}{os.pathsep}{os.environ['PATH']}",
            "READY_MARKER_FILE": str(self.marker),
            "GATEWAY_HOME": str(self.gateway_home),
            "NC_CALLS_FILE": str(self.nc_calls),
            "NC_STUB_EXIT": str(nc_exit),
        }
        if env_overrides:
            env.update(env_overrides)
        return subprocess.run(
            ["bash", str(HEALTHCHECK)],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def _nc_invocations(self):
        if not self.nc_calls.exists():
            return []
        return self.nc_calls.read_text(encoding="utf-8").splitlines()

    def test_unhealthy_before_marker_exists_and_no_probe_is_attempted(self):
        result = self._run()
        self.assertNotEqual(result.returncode, 0)
        # No TCP probe before the marker: during startup the gateway port
        # accepting connections must NOT make the container healthy (data
        # initialization may still be running).
        self.assertEqual(self._nc_invocations(), [])

    def test_healthy_with_marker_and_accepting_gateway(self):
        self.marker.touch()
        result = self._run(nc_exit=0)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unhealthy_with_marker_but_refusing_gateway(self):
        self.marker.touch()
        result = self._run(nc_exit=1)
        self.assertNotEqual(result.returncode, 0)

    def test_port_comes_from_runtime_config(self):
        # A --documentdb-port flag only surfaces in the runtime-generated
        # config; the probe must use it over the environment fallback.
        self.marker.touch()
        self.runtime_config.write_text(
            '{"GatewayListenPort": 23456, "PostgresPort": 9712}',
            encoding="utf-8",
        )
        result = self._run(env_overrides={"DOCUMENTDB_PORT": "11111"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._nc_invocations(), ["-z localhost 23456"])

    def test_port_falls_back_to_env_without_runtime_config(self):
        self.marker.touch()
        result = self._run(env_overrides={"DOCUMENTDB_PORT": "11111"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._nc_invocations(), ["-z localhost 11111"])

    def test_port_falls_back_to_default_without_config_or_env(self):
        self.marker.touch()
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._nc_invocations(), ["-z localhost 10260"])

    def test_port_falls_back_when_runtime_config_lacks_port(self):
        self.marker.touch()
        self.runtime_config.write_text(
            '{"PostgresPort": 9712}', encoding="utf-8"
        )
        result = self._run(env_overrides={"DOCUMENTDB_PORT": "11111"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._nc_invocations(), ["-z localhost 11111"])

    def test_port_falls_back_when_runtime_config_is_invalid_json(self):
        self.marker.touch()
        self.runtime_config.write_text("{not json", encoding="utf-8")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._nc_invocations(), ["-z localhost 10260"])

    def test_non_numeric_config_port_is_rejected(self):
        # A non-numeric value must not be spliced into the nc invocation.
        self.marker.touch()
        self.runtime_config.write_text(
            '{"GatewayListenPort": "not-a-port"}', encoding="utf-8"
        )
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._nc_invocations(), ["-z localhost 10260"])


if __name__ == "__main__":
    unittest.main()
