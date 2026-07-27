"""Unit tests for documentdb_healthcheck.sh (issue #482).

The script is exercised directly with bash in a sandbox. Its only inputs are
the readiness marker (pointed at a temp file via READY_MARKER_FILE) and the
kernel's own view of the machine, so the tests use real processes and real
listening sockets rather than stubs: a live PID is this test process, a dead
PID comes from a reaped subprocess, and a listening port is a socket this
test binds.

Contract under test -- healthy (exit 0) if and only if ALL of:
  1. the readiness marker exists (emulator_entrypoint.sh writes it after
     startup, including one-shot data initialization, completes),
  2. the PID on line 2 of the marker is still alive, and
  3. something is listening on the port from line 1 of the marker, which is
     how `--documentdb-port` reaches a probe that Docker runs with the
     container's static environment.

The marker must carry both lines: a bare `touch`ed marker is not a valid
readiness signal and must read as unhealthy.

/proc/net/tcp is Linux-only, so the whole module skips elsewhere.
"""

import os
import shutil
import socket
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
HEALTHCHECK = (
    REPO_ROOT / "documentdb-local" / "scripts" / "documentdb_healthcheck.sh"
)

_TOOLS = ("bash", "sed", "grep")
_SKIP_UNLESS_SUPPORTED = unittest.skipUnless(
    all(shutil.which(t) for t in _TOOLS) and Path("/proc/net/tcp").exists(),
    f"requires Linux /proc/net/tcp and {', '.join(_TOOLS)} on PATH",
)


@_SKIP_UNLESS_SUPPORTED
class DocumentdbHealthcheckTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.marker = self.root / "documentdb-local.ready"

    # -- helpers ----------------------------------------------------------

    def _listening_socket(self):
        """Bind and listen on an ephemeral port; return (socket, port)."""
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.addCleanup(srv.close)
        srv.bind(("127.0.0.1", 0))
        srv.listen(8)
        return srv, srv.getsockname()[1]

    def _free_port(self):
        """Return a port number nothing is listening on."""
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.bind(("127.0.0.1", 0))
            return probe.getsockname()[1]

    def _reaped_pid(self):
        """Return the PID of an exited, reaped process."""
        proc = subprocess.Popen(["/bin/true"])
        proc.wait()
        return proc.pid

    def _write_marker(self, content):
        self.marker.write_text(content, encoding="utf-8")

    def _run(self, env_overrides=None):
        env = {"PATH": os.environ["PATH"], "READY_MARKER_FILE": str(self.marker)}
        if env_overrides:
            env.update(env_overrides)
        return subprocess.run(
            ["bash", str(HEALTHCHECK)],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )

    # -- marker gating ----------------------------------------------------

    def test_unhealthy_before_marker_exists(self):
        # During startup the gateway port can already be accepting
        # connections while data initialization is still running, so the
        # marker -- not the port -- is what gates `healthy`.
        _srv, _port = self._listening_socket()
        self.assertNotEqual(self._run().returncode, 0)

    def test_unhealthy_for_a_bare_touched_marker(self):
        # An empty marker carries no port and no PID; it is not a readiness
        # signal this probe can act on.
        self._write_marker("")
        self.assertNotEqual(self._run().returncode, 0)

    # -- healthy path -----------------------------------------------------

    def test_healthy_with_live_pid_and_listening_port(self):
        _srv, port = self._listening_socket()
        self._write_marker(f"{port}\n{os.getpid()}\n")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_healthy_with_a_zero_padded_port(self):
        # printf reads a leading zero as octal unless the script forces base
        # 10, which would probe a different port entirely.
        _srv, port = self._listening_socket()
        self._write_marker(f"{port:06d}\n{os.getpid()}\n")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_healthy_with_trailing_whitespace_in_the_marker(self):
        _srv, port = self._listening_socket()
        self._write_marker(f"  {port}  \n  {os.getpid()}  \n")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)

    # -- liveness ---------------------------------------------------------

    def test_unhealthy_when_the_recorded_pid_is_dead(self):
        # The gateway going away must flip the container out of `healthy`
        # even though the marker is still on disk.
        _srv, port = self._listening_socket()
        self._write_marker(f"{port}\n{self._reaped_pid()}\n")
        self.assertNotEqual(self._run().returncode, 0)

    def test_unhealthy_when_the_pid_line_is_missing(self):
        _srv, port = self._listening_socket()
        self._write_marker(f"{port}\n")
        self.assertNotEqual(self._run().returncode, 0)

    def test_unhealthy_when_the_pid_line_is_not_numeric(self):
        _srv, port = self._listening_socket()
        self._write_marker(f"{port}\nnot-a-pid\n")
        self.assertNotEqual(self._run().returncode, 0)

    # -- listener ---------------------------------------------------------

    def test_unhealthy_when_nothing_listens_on_the_recorded_port(self):
        self._write_marker(f"{self._free_port()}\n{os.getpid()}\n")
        self.assertNotEqual(self._run().returncode, 0)

    def test_port_comes_from_the_marker_not_the_environment(self):
        # `--documentdb-port` never reaches this probe's environment, so a
        # probe that trusted DOCUMENTDB_PORT could never turn healthy.
        _srv, port = self._listening_socket()
        self._write_marker(f"{port}\n{os.getpid()}\n")
        result = self._run(
            {"DOCUMENTDB_PORT": str(self._free_port())}
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_environment_port_is_only_a_fallback_for_a_portless_marker(self):
        _srv, port = self._listening_socket()
        self._write_marker(f"not-a-port\n{os.getpid()}\n")
        result = self._run({"DOCUMENTDB_PORT": str(port)})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_healthy_when_the_port_is_unknowable_entirely(self):
        # Marker plus liveness already hold; refusing to report healthy over
        # an unparseable port would wedge the container in `unhealthy`.
        self._write_marker(f"not-a-port\n{os.getpid()}\n")
        result = self._run({"DOCUMENTDB_PORT": "also-not-a-port"})
        self.assertEqual(result.returncode, 0, result.stderr)

    # -- the reason this probe is passive ---------------------------------

    def test_probe_never_connects_to_the_gateway_port(self):
        # The gateway logs an ERROR for every accepted-then-closed
        # connection, so a `nc -z` style probe would add a log line once per
        # healthcheck interval for the life of the container. Assert the
        # listening socket saw no connection attempt at all.
        srv, port = self._listening_socket()
        self._write_marker(f"{port}\n{os.getpid()}\n")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)

        srv.setblocking(False)
        with self.assertRaises(BlockingIOError):
            srv.accept()


if __name__ == "__main__":
    unittest.main()
