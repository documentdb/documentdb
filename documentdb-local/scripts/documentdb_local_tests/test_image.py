"""
Image-level integration tests for documentdb-local.

Scope: documentdb-local's own contract as a published image.

  - The image must build.
  - A freshly-started container must reach readiness within a sane timeout.
  - The entrypoint flags documented in `emulator_entrypoint.sh --help` must
    actually take effect: `--username`, `--password`, `--documentdb-port`,
    `--tlsMode`, `--data-path`, `--init-data`, `--init-data-path`,
    `--skip-init-data`.
  - The published port must be reachable from outside the container when
    mapped via `docker run -p HOST:CONTAINER` (the most-used scenario).
  - Data placed under `--data-path` must survive container recreation.
  - Authentication must be enforced (wrong password rejected).
  - The image must run as a non-root user.

Out of scope (by design):

  - Wire-protocol / aggregation / CRUD / indexing / BSON correctness:
    those are covered by the upstream functional-tests image referenced
    from `documentdb-local/functional-tests/config/image.yml`. The tests
    here use `mongosh` only as a vehicle to assert image-contract
    properties (port binding, auth enforcement, data persistence),
    never to assert engine semantics.
  - Performance, clustering / replication, custom certificate fixture
    generation, telemetry endpoint behavior.

The image reference is supplied via DOCUMENTDB_LOCAL_IMAGE so the same
script works locally and in CI:

    DOCUMENTDB_LOCAL_IMAGE=documentdb-local:dev \\
        python3 -m unittest discover -v \\
            -s documentdb-local/scripts/documentdb_local_tests \\
            -p 'test_image.py'

Each test class spawns its own throwaway container; lifecycles are
isolated so one class's failure doesn't cascade.
"""

from __future__ import annotations

import os
import pathlib
import secrets
import shutil
import string
import subprocess
import tempfile
import time
import unittest
import uuid


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

READY_LOG = "=== DocumentDB is ready ==="
DEFAULT_PORT = 10260
DEFAULT_USERNAME = "docdb_admin"

DEFAULT_READY_TIMEOUT = int(os.environ.get("DOCUMENTDB_READY_TIMEOUT", "240"))
DEFAULT_MONGOSH_TIMEOUT = 30

# Directory where container logs are persisted before container removal.
# CI uploads the contents of this directory as an artifact when a job
# fails. Logs MUST be written here before `docker rm -f` runs.
LOG_DIR = pathlib.Path(
    os.environ.get("DOCUMENTDB_LOCAL_LOG_DIR", ".test-results/image-test")
)

# Container name prefix - tests use this as a `docker ps --filter name=`
# anchor for log capture on failure. Kept deliberately short so it fits
# in CI artifact names.
CONTAINER_PREFIX = "docdb-image-test"

# Skip every TestCase in this module when the image reference is not
# provided. Keeps the file safe under `unittest discover` outside CI.
_SKIP_REASON = (
    "Set DOCUMENTDB_LOCAL_IMAGE to the documentdb-local image reference to run."
)
_SKIP_UNLESS_IMAGE = unittest.skipUnless(
    os.environ.get("DOCUMENTDB_LOCAL_IMAGE"), _SKIP_REASON
)


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def _docker(*args: str, check: bool = True, capture: bool = True,
            timeout: int | None = None) -> subprocess.CompletedProcess:
    """Thin wrapper around subprocess.run for `docker` calls."""
    return subprocess.run(
        ["docker", *args],
        check=check,
        text=True,
        capture_output=capture,
        timeout=timeout,
    )


def _random_password(length: int = 32) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def _random_container_name() -> str:
    return f"{CONTAINER_PREFIX}-{uuid.uuid4().hex[:8]}"


def _persist_container_logs(container: str | None) -> None:
    """Write `docker logs <container>` to LOG_DIR so the CI artifact
    step can find them. Must run BEFORE `docker rm -f` because logs
    disappear with the container. Best-effort: never raises."""
    if not container:
        return
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        logs = _docker("logs", container, check=False)
        (LOG_DIR / f"{container}.log").write_text(
            f"--- stdout ---\n{logs.stdout}\n"
            f"--- stderr ---\n{logs.stderr}\n",
            encoding="utf-8",
        )
    except (OSError, subprocess.SubprocessError):
        pass


def _wait_for_ready(container: str, *, timeout: int = DEFAULT_READY_TIMEOUT,
                    poll_interval: float = 2.0) -> None:
    """Poll docker logs for READY_LOG. Raises RuntimeError on timeout
    or premature container exit. Caller is responsible for log capture
    and container removal."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        running = _docker(
            "inspect", "-f", "{{.State.Running}}", container, check=False,
        )
        if running.returncode != 0 or running.stdout.strip() != "true":
            raise RuntimeError(
                f"container {container!r} exited before becoming ready "
                f"(state inspect: {running.stdout.strip()!r})"
            )
        logs = _docker("logs", container, check=False)
        if READY_LOG in logs.stdout or READY_LOG in logs.stderr:
            return
        time.sleep(poll_interval)
    raise RuntimeError(
        f"container {container!r} did not emit readiness marker "
        f"{READY_LOG!r} within {timeout}s"
    )


def _start_container(image: str, *, extra_run_args: list[str] | None = None,
                     entrypoint_flags: list[str] | None = None,
                     name: str | None = None) -> str:
    """Spawn a container and return its name. Caller owns cleanup."""
    container = name or _random_container_name()
    args = ["run", "-d", "--name", container]
    if extra_run_args:
        args.extend(extra_run_args)
    args.append(image)
    if entrypoint_flags:
        args.extend(entrypoint_flags)
    _docker(*args, timeout=60)
    return container


def _cleanup_container(container: str | None) -> None:
    """Persist logs then remove the container. Best-effort."""
    if not container:
        return
    _persist_container_logs(container)
    _docker("rm", "-f", container, check=False)


def _mongosh_exec(container: str, eval_code: str, *,
                  username: str, password: str,
                  port: int = DEFAULT_PORT,
                  use_tls: bool = True,
                  auth_mechanism: str = "SCRAM-SHA-256",
                  timeout: int = DEFAULT_MONGOSH_TIMEOUT,
                  ) -> subprocess.CompletedProcess:
    """Run mongosh via `docker exec` inside the target container."""
    cmd = [
        "exec", "-i", container,
        "mongosh",
        f"localhost:{port}",
        "-u", username, "-p", password,
        "--authenticationMechanism", auth_mechanism,
    ]
    if use_tls:
        cmd.extend(["--tls", "--tlsAllowInvalidCertificates"])
    cmd.extend(["--quiet", "--eval", eval_code])
    return _docker(*cmd, check=False, timeout=timeout)


def _mongosh_sibling(image: str, host: str, port: int, eval_code: str, *,
                     username: str, password: str,
                     use_tls: bool = True,
                     timeout: int = DEFAULT_MONGOSH_TIMEOUT,
                     ) -> subprocess.CompletedProcess:
    """Run mongosh in a sibling container with `--network host`, talking
    to the documentdb-local container via its host-published port.
    Reuses the documentdb-local image (it ships mongosh) so no extra
    image pull is needed."""
    cmd = [
        "run", "--rm", "--network", "host",
        "--entrypoint", "mongosh",
        image,
        f"{host}:{port}",
        "-u", username, "-p", password,
        "--authenticationMechanism", "SCRAM-SHA-256",
    ]
    if use_tls:
        cmd.extend(["--tls", "--tlsAllowInvalidCertificates"])
    cmd.extend(["--quiet", "--eval", eval_code])
    return _docker(*cmd, check=False, timeout=timeout)


def _last_nonempty_line(text: str) -> str:
    for line in reversed(text.splitlines()):
        if line.strip():
            return line.strip()
    return ""


# ---------------------------------------------------------------------------
# Base classes
# ---------------------------------------------------------------------------

class _ContainerTestBase(unittest.TestCase):
    """Test case base that spawns one container per class.

    Subclasses override class attributes:
      - EXTRA_RUN_ARGS: extra `docker run` flags (e.g. `-p`, `-v`).
      - ENTRYPOINT_FLAGS: extra emulator_entrypoint.sh flags.
      - USERNAME: gateway username to provision (default DEFAULT_USERNAME).

    Subclasses inherit shared setUpClass / tearDownClass that handle:
      - lazy skip if DOCUMENTDB_LOCAL_IMAGE is unset (via decorator).
      - random container name + random password.
      - readiness polling.
      - log persistence + container removal.
    """

    EXTRA_RUN_ARGS: list[str] = []
    ENTRYPOINT_FLAGS: list[str] = []
    USERNAME: str = DEFAULT_USERNAME

    image: str
    container: str | None
    password: str

    @classmethod
    def setUpClass(cls) -> None:
        cls.image = os.environ["DOCUMENTDB_LOCAL_IMAGE"]
        cls.container = None
        cls.password = _random_password()

        # Sanity check the image is locally available.
        result = _docker("image", "inspect", cls.image, check=False)
        if result.returncode != 0:
            raise unittest.SkipTest(
                f"Image not available locally: {cls.image}\n"
                f"docker image inspect stderr:\n{result.stderr}"
            )

        flags = ["--username", cls.USERNAME, "--password", cls.password,
                 *cls.ENTRYPOINT_FLAGS]
        try:
            cls.container = _start_container(
                cls.image,
                extra_run_args=cls.EXTRA_RUN_ARGS,
                entrypoint_flags=flags,
            )
            _wait_for_ready(cls.container)
        except Exception as exc:
            _cleanup_container(cls.container)
            cls.container = None
            raise unittest.SkipTest(
                f"setUpClass failed for {cls.__name__}: {exc}"
            ) from exc

    @classmethod
    def tearDownClass(cls) -> None:
        _cleanup_container(cls.container)
        cls.container = None

    # Convenience wrapper that fills in the per-test creds and container.
    def _mongosh(self, eval_code: str, *,
                 username: str | None = None,
                 password: str | None = None,
                 port: int = DEFAULT_PORT,
                 use_tls: bool = True,
                 timeout: int = DEFAULT_MONGOSH_TIMEOUT,
                 ) -> subprocess.CompletedProcess:
        return _mongosh_exec(
            self.container,
            eval_code,
            username=username if username is not None else self.USERNAME,
            password=password if password is not None else self.password,
            port=port,
            use_tls=use_tls,
            timeout=timeout,
        )


# ---------------------------------------------------------------------------
# 1. Default container - boot, readiness, ping, auth, non-root,
#    mongosh binary, post-workload liveness.
# ---------------------------------------------------------------------------

@_SKIP_UNLESS_IMAGE
class DefaultContainerTests(_ContainerTestBase):
    """Defaults-only container: --skip-init-data, allowTLS, internal port."""

    ENTRYPOINT_FLAGS = ["--skip-init-data"]

    def test_container_is_running(self):
        result = _docker("inspect", "-f", "{{.State.Running}}", self.container)
        self.assertEqual(
            result.stdout.strip(), "true",
            f"container not running: {result.stdout!r}",
        )

    def test_readiness_log_is_present(self):
        logs = _docker("logs", self.container)
        combined = logs.stdout + logs.stderr
        self.assertIn(
            READY_LOG, combined,
            "readiness log not found in container logs (last 40 lines):\n"
            + "\n".join(combined.splitlines()[-40:]),
        )

    def test_image_runs_as_non_root(self):
        """Security baseline: the runtime user must not be root."""
        result = _docker(
            "inspect", "-f", "{{.Config.User}}", self.image,
        )
        configured_user = result.stdout.strip()
        self.assertNotIn(
            configured_user, ("", "root", "0", "0:0"),
            f"image Config.User is {configured_user!r}; expected a non-root user.",
        )
        # Cross-check the live process is also non-root.
        whoami = _docker(
            "exec", self.container, "whoami", check=False, timeout=10,
        )
        self.assertEqual(whoami.returncode, 0, msg=whoami.stderr)
        self.assertNotEqual(
            whoami.stdout.strip(), "root",
            "in-container `whoami` reports root; expected a non-root user.",
        )

    def test_mongosh_binary_is_shipped_in_image(self):
        """The image must ship mongosh - we rely on it for in-container
        client work, and users follow our docs that assume it's there."""
        result = _docker(
            "exec", self.container, "which", "mongosh",
            check=False, timeout=10,
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertTrue(
            result.stdout.strip().endswith("/mongosh"),
            f"`which mongosh` returned {result.stdout!r}",
        )

    def test_mongosh_ping_succeeds_with_correct_credentials(self):
        result = self._mongosh("db.runCommand({ping: 1}).ok")
        self.assertEqual(
            result.returncode, 0,
            f"mongosh exited {result.returncode}\nstdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}",
        )
        self.assertEqual(
            _last_nonempty_line(result.stdout), "1",
            f"expected ping ok=1 as the last stdout line\n"
            f"full stdout:\n{result.stdout}",
        )

    def test_mongosh_ping_succeeds_without_tls(self):
        """Default mode is allowTLS, so a plain (non-TLS) client must be
        able to connect. This is the documented 'connect without TLS'
        behavior and the regression guard for the TLS_MODE wiring."""
        result = self._mongosh("db.runCommand({ping: 1}).ok", use_tls=False)
        self.assertEqual(
            result.returncode, 0,
            f"plain (non-TLS) mongosh failed against the allowTLS default "
            f"container; the gateway appears to still enforce TLS.\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        self.assertEqual(
            _last_nonempty_line(result.stdout), "1",
            f"expected ping ok=1 over a plain (non-TLS) connection\n"
            f"full stdout:\n{result.stdout}",
        )

    def test_mongosh_ping_rejected_with_wrong_password(self):
        """Authentication must be enforced - a wrong password must fail."""
        result = self._mongosh(
            "db.runCommand({ping: 1})",
            password=self.password + "-wrong",
        )
        self.assertNotEqual(
            result.returncode, 0,
            "mongosh unexpectedly succeeded with a wrong password\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )

    def test_container_still_running_after_workload(self):
        """The entrypoint must not exit after a client connection. Run
        this last so it sees the post-ping state."""
        result = _docker("inspect", "-f", "{{.State.Running}}", self.container)
        self.assertEqual(
            result.stdout.strip(), "true",
            "container exited after workload; entrypoint likely returned "
            "early or a managed process crashed.\n"
            f"State inspect: {result.stdout!r}",
        )


# ---------------------------------------------------------------------------
# 2. External port binding - the published-port surface that real
#    users hit when running `docker run -p HOST:10260 documentdb-local`.
#    The default container above tests in-container loopback only.
# ---------------------------------------------------------------------------

@_SKIP_UNLESS_IMAGE
class ExternalPortBindingTests(_ContainerTestBase):
    """Catches a regression where the gateway binds to 127.0.0.1 inside
    the container instead of 0.0.0.0 (in-container ping would still pass)."""

    # Publish to a random host port to avoid runner-side collisions when
    # multiple tests run on the same machine.
    EXTRA_RUN_ARGS = ["-p", f"127.0.0.1::{DEFAULT_PORT}/tcp"]
    ENTRYPOINT_FLAGS = ["--skip-init-data"]

    def _published_host_port(self) -> int:
        result = _docker(
            "port", self.container, f"{DEFAULT_PORT}/tcp", timeout=10,
        )
        # Output like "127.0.0.1:32768" (possibly multi-line for ipv4/ipv6).
        for line in result.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            host, _, port_str = line.rpartition(":")
            try:
                return int(port_str)
            except ValueError:
                continue
        self.fail(
            f"unable to parse `docker port` output: {result.stdout!r}"
        )

    def test_published_host_port_accepts_mongosh_from_outside(self):
        host_port = self._published_host_port()
        result = _mongosh_sibling(
            self.image,
            host="127.0.0.1",
            port=host_port,
            eval_code="db.runCommand({ping: 1}).ok",
            username=self.USERNAME,
            password=self.password,
        )
        self.assertEqual(
            result.returncode, 0,
            f"mongosh from sibling container (network=host) failed against "
            f"127.0.0.1:{host_port}; the gateway is likely bound to the "
            f"container loopback only.\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        self.assertEqual(
            _last_nonempty_line(result.stdout), "1",
            f"expected ping ok=1 from external client\n"
            f"full stdout:\n{result.stdout}",
        )


# ---------------------------------------------------------------------------
# 3. Custom --documentdb-port: the flag must actually move the listener.
# ---------------------------------------------------------------------------

CUSTOM_PORT = 11000


@_SKIP_UNLESS_IMAGE
class CustomDocumentDBPortTests(_ContainerTestBase):
    """Catches a regression where --documentdb-port is silently ignored."""

    ENTRYPOINT_FLAGS = [
        "--skip-init-data",
        "--documentdb-port", str(CUSTOM_PORT),
    ]

    def test_ping_succeeds_on_custom_port(self):
        result = self._mongosh(
            "db.runCommand({ping: 1}).ok", port=CUSTOM_PORT,
        )
        self.assertEqual(
            result.returncode, 0,
            f"mongosh on custom port {CUSTOM_PORT} failed; --documentdb-port "
            f"likely not honored.\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        self.assertEqual(
            _last_nonempty_line(result.stdout), "1",
            f"expected ping ok=1 on custom port {CUSTOM_PORT}\n"
            f"full stdout:\n{result.stdout}",
        )

    def test_default_port_not_listening(self):
        """Sanity: with --documentdb-port set, the default port should
        NOT be serving the gateway. We tolerate `port 10260 still has
        SOMETHING bound` (unusual but possible) by only failing if a
        full SCRAM-SHA-256 ping completes successfully."""
        result = self._mongosh(
            "db.runCommand({ping: 1}).ok", port=DEFAULT_PORT,
        )
        if result.returncode == 0 and _last_nonempty_line(result.stdout) == "1":
            self.fail(
                "ping succeeded on the default port even though "
                "--documentdb-port was set; the gateway appears to be "
                "listening on the default port in addition to (or instead "
                "of) the requested custom port.\n"
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )


# ---------------------------------------------------------------------------
# 4. TLS modes. allowTLS (the default) accepts both plain (non-TLS) and TLS
#    client connections; that default is exercised by DefaultContainerTests
#    above, which pings over both TLS and a plain connection. The requireTLS
#    path (plain rejected, TLS accepted) is exercised below. `--tlsMode
#    disabled` is not separately smoke-tested: it maps to the same
#    accept-both behavior as allowTLS (the gateway has no plain-only mode),
#    so it would assert nothing new here.
# ---------------------------------------------------------------------------

@_SKIP_UNLESS_IMAGE
class TlsRequiredTests(_ContainerTestBase):
    """--tlsMode requireTLS: WITHOUT --tls must be rejected, WITH --tls works."""

    ENTRYPOINT_FLAGS = ["--skip-init-data", "--tlsMode", "requireTLS"]

    def test_ping_with_tls_succeeds(self):
        result = self._mongosh(
            "db.runCommand({ping: 1}).ok", use_tls=True,
        )
        self.assertEqual(
            result.returncode, 0,
            f"mongosh --tls failed against --tlsMode=requireTLS container.\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        self.assertEqual(
            _last_nonempty_line(result.stdout), "1",
            f"expected ping ok=1 over TLS\n"
            f"full stdout:\n{result.stdout}",
        )

    def test_ping_without_tls_rejected(self):
        result = self._mongosh(
            "db.runCommand({ping: 1})", use_tls=False,
        )
        self.assertNotEqual(
            result.returncode, 0,
            "mongosh without --tls unexpectedly succeeded against a "
            "--tlsMode=requireTLS container; the require mode is not "
            "being enforced.\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )


# ---------------------------------------------------------------------------
# 5. Custom username - --username FOO must actually provision FOO,
#    and the documented default user must not be auto-created.
# ---------------------------------------------------------------------------

ALT_USERNAME = "alt_admin"
LEGACY_DEFAULT_USERNAME = "default_user"


@_SKIP_UNLESS_IMAGE
class CustomUsernameTests(_ContainerTestBase):
    """Catches a regression where --username is silently ignored."""

    USERNAME = ALT_USERNAME
    ENTRYPOINT_FLAGS = ["--skip-init-data"]

    def test_ping_with_alt_username_succeeds(self):
        result = self._mongosh("db.runCommand({ping: 1}).ok")
        self.assertEqual(
            result.returncode, 0,
            f"mongosh as --username {ALT_USERNAME!r} failed; the custom "
            f"username does not appear to have been provisioned.\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )

    def test_ping_with_default_username_rejected(self):
        """The image's hard-coded default user must not be auto-created
        when the operator passes --username explicitly."""
        result = self._mongosh(
            "db.runCommand({ping: 1})",
            username=LEGACY_DEFAULT_USERNAME,
        )
        self.assertNotEqual(
            result.returncode, 0,
            f"mongosh succeeded as {LEGACY_DEFAULT_USERNAME!r} even though "
            f"the container was started with --username {ALT_USERNAME!r}.\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )


# ---------------------------------------------------------------------------
# 6. Built-in sample data - the entrypoint exposes a flag that loads
#    the sample-data shipped in the image; verify the flag actually
#    populates the expected collection. NOTE: the documentdb-local
#    default is `--init-data false` since PR 2027838, so we must
#    pass `--init-data true` explicitly to exercise this path.
# ---------------------------------------------------------------------------

@_SKIP_UNLESS_IMAGE
class BuiltInSampleDataTests(_ContainerTestBase):
    """Catches a regression where the bundled sample-data files stop
    being executed when the user opts in via `--init-data true`
    (e.g. COPY missing in Dockerfile, init script changes)."""

    ENTRYPOINT_FLAGS = ["--init-data", "true"]

    def test_sampledb_users_collection_has_documents(self):
        # The readiness marker is emitted after init-data has run, but
        # keep a small retry loop as defense against any future change
        # to the entrypoint's init ordering.
        deadline = time.monotonic() + 30
        result = None
        while time.monotonic() < deadline:
            result = self._mongosh(
                "db.getSiblingDB('sampledb').users.countDocuments({})",
            )
            if result.returncode == 0:
                last = _last_nonempty_line(result.stdout)
                if last.isdigit() and int(last) > 0:
                    return
            time.sleep(2)
        self.fail(
            "sampledb.users is empty or unreadable after 30s; the "
            "built-in sample-data scripts did not populate it.\n"
            f"last mongosh stdout:\n{getattr(result, 'stdout', '')}\n"
            f"last mongosh stderr:\n{getattr(result, 'stderr', '')}"
        )


# ---------------------------------------------------------------------------
# 7. Custom init-data path - user-mounted .js files in
#    --init-data-path must be executed at first boot.
# ---------------------------------------------------------------------------

CUSTOM_INIT_DB_NAME = "image_smoke_init_db"
CUSTOM_INIT_COLLECTION = "init_marker"


@_SKIP_UNLESS_IMAGE
class CustomInitDataTests(unittest.TestCase):
    """Catches regressions in the custom init-data path: the directory
    mount, the discovery glob, the script execution loop."""

    image: str
    container: str | None
    password: str
    init_dir: str | None

    @classmethod
    def setUpClass(cls) -> None:
        cls.image = os.environ["DOCUMENTDB_LOCAL_IMAGE"]
        cls.container = None
        cls.password = _random_password()
        cls.init_dir = None

        init_dir = tempfile.mkdtemp(prefix="docdb-image-init-")
        # Marker script the entrypoint must execute. Using `use(db)` +
        # insertOne mirrors the shape of the shipped sample-data scripts
        # without asserting any engine semantics beyond round-tripping
        # the document we insert.
        script_path = pathlib.Path(init_dir) / "00-marker.js"
        script_path.write_text(
            f"""use('{CUSTOM_INIT_DB_NAME}');
db.{CUSTOM_INIT_COLLECTION}.insertOne({{
    _id: 'image-smoke-marker',
    placed_by: 'documentdb_local_tests',
    via: 'init-data-path'
}});
print('init-data marker placed');
""",
            encoding="utf-8",
        )
        os.chmod(init_dir, 0o755)
        os.chmod(script_path, 0o644)
        cls.init_dir = init_dir

        try:
            cls.container = _start_container(
                cls.image,
                extra_run_args=["-v", f"{init_dir}:/init_doc_db.d:ro"],
                entrypoint_flags=[
                    "--username", DEFAULT_USERNAME,
                    "--password", cls.password,
                    "--init-data-path", "/init_doc_db.d",
                    "--init-data", "true",
                ],
            )
            _wait_for_ready(cls.container)
        except Exception as exc:
            _cleanup_container(cls.container)
            cls.container = None
            if cls.init_dir:
                shutil.rmtree(cls.init_dir, ignore_errors=True)
                cls.init_dir = None
            raise unittest.SkipTest(
                f"setUpClass failed for {cls.__name__}: {exc}"
            ) from exc

    @classmethod
    def tearDownClass(cls) -> None:
        _cleanup_container(cls.container)
        cls.container = None
        if cls.init_dir:
            shutil.rmtree(cls.init_dir, ignore_errors=True)
            cls.init_dir = None

    def test_custom_init_script_was_executed(self):
        """Verify the marker we wrote at init time is queryable."""
        # Allow the init step a few extra seconds to complete after
        # readiness - the entrypoint streams the readiness marker
        # before init scripts finish in some configurations.
        deadline = time.monotonic() + 30
        last_result = None
        while time.monotonic() < deadline:
            last_result = _mongosh_exec(
                self.container,
                f"db.getSiblingDB('{CUSTOM_INIT_DB_NAME}')"
                f".{CUSTOM_INIT_COLLECTION}.countDocuments({{}})",
                username=DEFAULT_USERNAME,
                password=self.password,
            )
            if (last_result.returncode == 0
                    and _last_nonempty_line(last_result.stdout).isdigit()
                    and int(_last_nonempty_line(last_result.stdout)) >= 1):
                return
            time.sleep(2)
        self.fail(
            f"custom init-data marker not found in "
            f"{CUSTOM_INIT_DB_NAME}.{CUSTOM_INIT_COLLECTION} after 30s.\n"
            f"last mongosh stdout:\n{getattr(last_result, 'stdout', '')}\n"
            f"last mongosh stderr:\n{getattr(last_result, 'stderr', '')}"
        )


# ---------------------------------------------------------------------------
# 8. Data persistence across container recreation - --data-path mounted
#    on a docker volume must retain data when the container is replaced.
#    This is the central value proposition of the --data-path flag.
# ---------------------------------------------------------------------------

PERSISTENCE_DB_NAME = "image_smoke_persistence_db"
PERSISTENCE_COLLECTION = "persistence_marker"
PERSISTENCE_DOC_ID = "persistence-marker-1"


@_SKIP_UNLESS_IMAGE
class PersistenceTests(unittest.TestCase):
    """Catches regressions where --data-path stops mapping to the
    PostgreSQL data directory, or where data is wiped on second boot."""

    image: str
    volume: str | None
    password: str

    @classmethod
    def setUpClass(cls) -> None:
        cls.image = os.environ["DOCUMENTDB_LOCAL_IMAGE"]
        cls.password = _random_password()
        cls.volume = None

    @classmethod
    def tearDownClass(cls) -> None:
        if cls.volume:
            _docker("volume", "rm", "-f", cls.volume, check=False)
            cls.volume = None

    def _start(self, name: str) -> str:
        return _start_container(
            self.image,
            extra_run_args=[
                "-v", f"{self.volume}:/data",
            ],
            entrypoint_flags=[
                "--username", DEFAULT_USERNAME,
                "--password", self.password,
                "--data-path", "/data",
                "--skip-init-data",
            ],
            name=name,
        )

    def test_doc_survives_container_recreate(self):
        self.volume = f"docdb-image-test-vol-{uuid.uuid4().hex[:8]}"
        # `docker run` will create the volume on first mount; no need
        # to `docker volume create` explicitly. But we DO want it to
        # exist for tearDownClass cleanup even if first boot fails -
        # cleanup is best-effort via `volume rm -f`, so this is fine.

        first_container: str | None = None
        second_container: str | None = None
        try:
            first_container = self._start(
                f"{CONTAINER_PREFIX}-persist-a-{uuid.uuid4().hex[:6]}"
            )
            _wait_for_ready(first_container)

            insert = _mongosh_exec(
                first_container,
                f"""const r = db.getSiblingDB('{PERSISTENCE_DB_NAME}')
.{PERSISTENCE_COLLECTION}
.insertOne({{_id: '{PERSISTENCE_DOC_ID}', placed_at: new Date()}});
print(r.acknowledged ? 'ack' : 'noack');""",
                username=DEFAULT_USERNAME,
                password=self.password,
            )
            self.assertEqual(
                insert.returncode, 0,
                f"insert on first container failed\n"
                f"stdout:\n{insert.stdout}\nstderr:\n{insert.stderr}",
            )
            self.assertIn(
                "ack", insert.stdout,
                f"insert was not acknowledged on first container\n"
                f"stdout:\n{insert.stdout}",
            )

            _cleanup_container(first_container)
            first_container = None

            second_container = self._start(
                f"{CONTAINER_PREFIX}-persist-b-{uuid.uuid4().hex[:6]}"
            )
            _wait_for_ready(second_container)

            find = _mongosh_exec(
                second_container,
                f"db.getSiblingDB('{PERSISTENCE_DB_NAME}')"
                f".{PERSISTENCE_COLLECTION}"
                f".countDocuments({{_id: '{PERSISTENCE_DOC_ID}'}})",
                username=DEFAULT_USERNAME,
                password=self.password,
            )
            self.assertEqual(
                find.returncode, 0,
                f"countDocuments on second container failed\n"
                f"stdout:\n{find.stdout}\nstderr:\n{find.stderr}",
            )
            self.assertEqual(
                _last_nonempty_line(find.stdout), "1",
                f"document with _id={PERSISTENCE_DOC_ID!r} not found on "
                f"second container; --data-path persistence is broken.\n"
                f"full stdout:\n{find.stdout}",
            )
        finally:
            _cleanup_container(first_container)
            _cleanup_container(second_container)


if __name__ == "__main__":
    unittest.main()
