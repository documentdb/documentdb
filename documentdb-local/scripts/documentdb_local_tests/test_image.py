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
import re
import secrets
import shutil
import string
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

# The shared backend-contract detector lives alongside this file. Make it
# importable regardless of how the suite is launched: `unittest discover -s
# <dir>` puts <dir> on sys.path, but a dotted
# `-m unittest documentdb_local_tests.test_image` run does not.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import backend_contract  # noqa: E402
import catalog_contract  # noqa: E402

# The gateway QueryCatalog source path and the parser floor are single-sourced
# from catalog_contract so this image test and the unit tests cannot disagree.
QUERY_CATALOG_RS = catalog_contract.QUERY_CATALOG_RS


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
        # Decode leniently: container logs can carry invalid UTF-8, and the
        # runner/dev-machine locale must not turn a benign byte into a decode
        # error that fails the backend-contract gate (or breaks on cp1252).
        encoding="utf-8",
        errors="replace",
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


def _combined_logs(proc: subprocess.CompletedProcess) -> str:
    """Join a `docker logs` process's stdout and stderr with a newline. The
    explicit separator prevents a dangling (newline-less) final stdout line from
    gluing onto the first stderr line (which could hide or fabricate a match)."""
    return proc.stdout + "\n" + proc.stderr


def _container_pg_socket_port(container: str) -> str:
    """Return the single in-container PostgreSQL port from its unix socket.

    The emulator runs exactly one PostgreSQL cluster on a non-default port
    (default 9712) whose socket lives at `/var/run/postgresql/.s.PGSQL.<port>`.
    We require exactly one socket: zero means PostgreSQL is not up, and more than
    one would make introspection ambiguous (the contract could be satisfied by
    the wrong cluster). Both are errors with a clear message."""
    res = _docker(
        "exec", container, "sh", "-c",
        "ls /var/run/postgresql/.s.PGSQL.* 2>/dev/null",
        check=False, timeout=15,
    )
    ports = sorted(set(re.findall(r"\.s\.PGSQL\.(\d+)", res.stdout)))
    if not ports:
        raise RuntimeError(
            "could not find a PostgreSQL unix socket "
            "(/var/run/postgresql/.s.PGSQL.*) in the container; "
            f"stdout={res.stdout!r} stderr={res.stderr!r}"
        )
    if len(ports) > 1:
        raise RuntimeError(
            "expected exactly one PostgreSQL cluster in the container but found "
            f"sockets for ports {ports}; backend introspection is ambiguous."
        )
    return ports[0]


def _existing_documentdb_functions(container: str) -> set[str]:
    """Return the `schema.function` names present in the documentdb backend
    schemas (documentdb_api, documentdb_api_internal, documentdb_api_catalog,
    documentdb_core) of the container's `postgres` database.

    Connects as the container's OS user (a superuser via peer auth) over the
    single local socket -- the same path the emulator's own setup uses. The SQL
    is passed as a single argv element (no shell), so its quoting is literal."""
    sql = (
        "SELECT n.nspname || '.' || p.proname "
        "FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
        "WHERE n.nspname IN ('documentdb_api', 'documentdb_api_internal', "
        "'documentdb_api_catalog', 'documentdb_core')"
    )
    port = _container_pg_socket_port(container)
    res = _docker(
        "exec", container, "psql", "-p", port, "-d", "postgres",
        "-tAqc", sql, check=False, timeout=30,
    )
    if res.returncode != 0:
        raise RuntimeError(
            f"psql introspection on port {port} failed: rc={res.returncode} "
            f"stderr={res.stderr.strip()!r}"
        )
    functions = {
        line.strip() for line in res.stdout.splitlines() if line.strip()
    }
    if not functions:
        raise RuntimeError(
            "no documentdb backend functions found on the PostgreSQL socket "
            f"(port {port}) -- the extension may not be installed in the "
            "'postgres' database."
        )
    return functions


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

        # This body runs only when DOCUMENTDB_LOCAL_IMAGE is set (the class-level
        # @_SKIP_UNLESS_IMAGE decorator skips otherwise), i.e. we are in the CI
        # gate that this suite exists to enforce. So an unavailable or unbootable
        # image is a hard ERROR, not a SkipTest -- a silent skip here would let a
        # broken image pass green, the exact silent-no-op #650 is about.
        result = _docker("image", "inspect", cls.image, check=False)
        if result.returncode != 0:
            raise RuntimeError(
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
        except Exception:
            _cleanup_container(cls.container)
            cls.container = None
            # Re-raise the original failure (do NOT downgrade to SkipTest): an
            # image that will not boot must fail the gate.
            raise

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
        combined = logs.stdout + "\n" + logs.stderr
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

    def test_no_undefined_backend_function_errors_in_logs(self):
        """Backend-contract guard for issue #650.

        A gateway command whose backend SQL references a function, column,
        schema or callable of the wrong kind that the shipped extension does not
        define surfaces as a PostgreSQL undefined_function (42883),
        undefined_column (42703), wrong_object_type (42809), invalid_schema_name
        (3F000), syntax_error (42601) or invalid_catalog_name (3D000) error in
        the container logs -- but clients silently tolerate failed discovery
        probes (e.g. mongosh's getParameter on connect), so a green ping/CRUD
        assertion cannot catch it. That is exactly how #650 shipped. Drive one
        connection to force the discovery handshake, then scan the logs with the
        shared, ANSI-aware detector.

        The scanned window is cumulative: `docker logs` returns the whole boot
        history plus every prior test's traffic in this class (they share one
        container). That is intentional -- benign failures (e.g. the
        wrong-password test) log an EMPTY sub_status, so they neither trip this
        deny-list scan nor the strict unexpected-SQLSTATE scan below."""
        ping = self._mongosh("db.runCommand({ping: 1}).ok")
        self.assertEqual(
            ping.returncode, 0,
            "mongosh ping failed while priming the backend-contract check\n"
            f"stdout:\n{ping.stdout}\nstderr:\n{ping.stderr}",
        )

        # Let any teardown-path server logging (e.g. endSessions) land before the
        # snapshot so a late error line is not raced past the capture.
        time.sleep(2)
        logs = _docker("logs", self.container)
        combined = _combined_logs(logs)
        offending = backend_contract.find_backend_contract_errors(combined)
        self.assertEqual(
            offending, [],
            "gateway logged PostgreSQL backend-contract error(s) (undefined_"
            "function/undefined_column/wrong_object_type/invalid_schema_name/"
            "syntax_error/invalid_catalog_name): the gateway's hard-coded SQL "
            "references a function, column, schema or callable kind the shipped "
            "extension does not define, or runs a malformed static statement "
            "(cf. issue #650). Offending lines:\n" + "\n".join(offending),
        )

    def test_no_unexpected_backend_sqlstates_in_logs(self):
        """Strict backend-contract net (issue #650, manager's hybrid mode).

        Beyond the narrow deny-list above, assert the logs carry NO non-empty
        `sub_status` SQLSTATE outside that class at all. Evidence: a green
        documentdb-local workload emits only EMPTY sub_status on its benign
        failure paths (a wrong-password SCRAM attempt is a Gateway-kind error
        whose `as_db_error()` is None, so the field renders empty; retried
        transients log a different field). So any non-empty unexpected SQLSTATE
        is a new backend-error class worth surfacing before it silently becomes
        the next #650.

        Kept as a SEPARATE method from the deny-list scan so, if a future
        workload legitimately introduces a benign non-empty code, this can be
        triaged (and the code added to the deny-list or an allow-list) without
        masking the hard gate. Shares the cumulative-log-window property noted
        above."""
        time.sleep(2)
        logs = _docker("logs", self.container)
        combined = _combined_logs(logs)
        unexpected = backend_contract.find_unexpected_sqlstates(combined)
        self.assertEqual(
            unexpected, [],
            "gateway logged non-empty sub_status SQLSTATE(s) outside the gated "
            "deny-list; a green documentdb-local workload emits none (benign "
            f"failures log an empty sub_status). Unexpected codes: {unexpected}",
        )

    def test_no_unparseable_sub_status_values_in_logs(self):
        """Value-format guard for the backend-contract gate (issue #650).

        The deny-list and strict scans both key off the 5-char SQLSTATE shape, so
        a `sub_status` value logged in a DIFFERENT shape (a bit-packed integer, a
        doubled-quote, a JSON reformat) leaves both scans silently blind -- a
        green-but-dead risk. Assert the cumulative logs carry no such value.

        Kept SEPARATE from the channel-alive canary below so its signal is not
        lost if the canary's count-delta assertion fails first, and separate from
        the strict scan so a value-shape regression is triaged independently from
        a new-SQLSTATE regression. Shares the cumulative-log-window property."""
        time.sleep(2)
        logs = _docker("logs", self.container)
        combined = _combined_logs(logs)
        unparseable = backend_contract.find_unparseable_sub_status_values(combined)
        self.assertEqual(
            unparseable, [],
            "gateway logged a `sub_status` value the gate cannot parse as a "
            "SQLSTATE (e.g. a bit-packed integer or reformatted field); the "
            "deny-list and strict scans are blind to such values, a green-but-"
            f"dead risk (cf. issue #650). Offending values: {unparseable}",
        )

    def test_all_backend_catalog_functions_exist_in_image(self):
        """Active backend-contract coverage for issue #650.

        The log scan above only catches backend-contract errors for commands
        the smoke actually exercises. Assert instead that EVERY backend routine
        the gateway's QueryCatalog calls exists in the shipped extension -- so a
        function used only by an unexercised command (compact, collStats,
        dbStats, ...) cannot go missing silently, the generalised #650 class.
        The required set is the statically-parsed calls plus the enumerated
        explain aggregation family (bson_aggregation_{find,pipeline,count,
        distinct}), minus routines with no OSS definition (authenticate_token),
        which the gateway builds by a runtime-templated name.

        This is a name-existence check (schema.proname), not a signature/arity
        or prokind match: a routine shipped with the wrong overload (e.g.
        get_parameter(bson) vs (bool,bool,text[])) or the wrong kind for a CALL
        proc surfaces as SQLSTATE 42883/42809 and is caught by the log scan
        above, not here."""
        # query_catalog.rs ships in the same repo tree as this test, so a missing
        # file is a hard error (path logic / source layout broke), not a skip --
        # a silent skip would disable the active gate, the #650 failure mode.
        if not QUERY_CATALOG_RS.is_file():
            self.fail(f"gateway QueryCatalog source not found: {QUERY_CATALOG_RS}")
        referenced = catalog_contract.required_backend_functions(
            QUERY_CATALOG_RS.read_text(encoding="utf-8")
        )
        self.assertGreaterEqual(
            len(referenced), catalog_contract.MIN_EXPECTED_BACKEND_FUNCTIONS,
            f"parsed only {len(referenced)} catalog routines; the parser or "
            "query_catalog.rs layout may have changed",
        )
        # _existing_documentdb_functions raises with a clear message if the
        # extension is absent or the cluster is unreachable, so an empty result
        # cannot reach here -- no separate emptiness assertion is needed.
        existing = _existing_documentdb_functions(self.container)
        missing = sorted(referenced - existing)
        self.assertEqual(
            missing, [],
            "backend routines the gateway QueryCatalog calls but which are "
            f"ABSENT from the shipped image (cf. issue #650): {missing}",
        )

    def test_zz_gateway_failure_log_channel_is_alive(self):
        """Positive control for the backend-contract log gate (issue #650).

        The gate scans for a `sub_status=` field. If a tracing field rename or a
        switch to JSON logging changed that shape, the deny-list and strict
        scans would silently pass forever (green-but-dead). Guard against it:
        deliberately drive one FAILED request (a wrong-password auth, a
        Gateway-kind error) and assert a NEW `sub_status=` line then appears.

        The count-delta (new line vs. before) matters because an alphabetically
        earlier test already deposited a `sub_status=` line in this shared
        container -- a plain "field present" check could pass even if failure
        logging died mid-run. Both snapshots are taken after a `sleep 2` so an
        in-flight line from an earlier test cannot land between them and satisfy
        the delta on its own. A wrong-password failure logs an EMPTY sub_status,
        so this canary cannot trip the deny-list/strict/unparseable scans
        regardless of order (hence the `zz` name that runs it last). The value
        SHAPE is checked separately by
        test_no_unparseable_sub_status_values_in_logs."""
        # Quiesce first so the `before` count does not absorb a still-arriving
        # line from a prior test (which would let the delta pass spuriously).
        time.sleep(2)
        before = backend_contract.count_sub_status_fields(
            _combined_logs(_docker("logs", self.container))
        )
        rejected = self._mongosh(
            "db.runCommand({ping: 1})", password=self.password + "-canary-wrong",
        )
        self.assertNotEqual(
            rejected.returncode, 0,
            "wrong-password attempt unexpectedly succeeded while priming the "
            "log-channel canary",
        )
        time.sleep(2)
        after = backend_contract.count_sub_status_fields(
            _combined_logs(_docker("logs", self.container))
        )
        self.assertGreater(
            after, before,
            "the canary's own failed request produced no NEW `sub_status=` line "
            "-- the failure-log channel the backend-contract gate relies on may "
            "have been renamed or switched to a different format (or the runner "
            "rotated the container log between snapshots), which would leave the "
            "gate green-but-dead (cf. issue #650).",
        )

    @classmethod
    def tearDownClass(cls) -> None:
        """Post-workload liveness re-check, then cleanup. Done here (rather than
        as a `test_*` method) so it runs unconditionally AFTER every test in the
        class regardless of unittest's alphabetical method order -- the entrypoint
        must not have exited after all the client connections. State is captured
        before cleanup so the container is always removed even if the assertion
        fails."""
        inspect = None
        if cls.container:
            inspect = _docker(
                "inspect", "-f", "{{.State.Running}}", cls.container, check=False,
            )
        _cleanup_container(cls.container)
        cls.container = None
        if inspect is None:
            return
        if inspect.returncode != 0:
            # A daemon/inspect failure must not be misreported as a crashed
            # entrypoint -- raise a distinct error so triage is not misdirected.
            raise RuntimeError(
                "docker inspect failed during post-workload liveness check: "
                f"rc={inspect.returncode} stderr={inspect.stderr.strip()!r}"
            )
        if inspect.stdout.strip() != "true":
            raise AssertionError(
                "container exited after workload; entrypoint likely returned "
                "early or a managed process crashed. "
                f"State.Running={inspect.stdout.strip()!r}"
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
        except Exception:
            # Ensure the init dir is always removed even if _cleanup_container
            # itself raises (e.g. the docker daemon vanished, so `docker rm` times
            # out) -- otherwise the mkdtemp dir leaks (tearDownClass does not run
            # when setUpClass errors) and the secondary error masks the original
            # boot failure.
            try:
                _cleanup_container(cls.container)
            finally:
                cls.container = None
                if cls.init_dir:
                    shutil.rmtree(cls.init_dir, ignore_errors=True)
                    cls.init_dir = None
            # Re-raise the original failure (do NOT downgrade to SkipTest): an
            # image that wedges only under --init-data-path must fail the gate,
            # not silently skip -- the silent-no-op mode issue #650 is about.
            raise

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


# ---------------------------------------------------------------------------
# 9. Sample-data restart idempotency (regression test for #612) - re-running
#    the container with --init-data true on a persistent volume must NOT
#    re-seed and crash with a duplicate-key error. The entrypoint writes a
#    one-shot marker under DATA_PATH and skips initialization on later boots.
# ---------------------------------------------------------------------------


@_SKIP_UNLESS_IMAGE
class SampleDataRestartIdempotencyTests(unittest.TestCase):
    """Regression guard for #612: a documentdb-local container with a
    persistent --data-path and --init-data true entered a restart loop on
    its second boot because the bundled sample-data seed re-ran and failed
    with a duplicate _id. The container must instead start cleanly and skip
    the already-loaded sample data."""

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
            extra_run_args=["-v", f"{self.volume}:/data"],
            entrypoint_flags=[
                "--username", DEFAULT_USERNAME,
                "--password", self.password,
                "--data-path", "/data",
                "--init-data", "true",
            ],
            name=name,
        )

    def _user_count(self, container: str) -> str:
        result = _mongosh_exec(
            container,
            "db.getSiblingDB('sampledb').users.countDocuments({})",
            username=DEFAULT_USERNAME,
            password=self.password,
        )
        self.assertEqual(
            result.returncode, 0,
            f"countDocuments failed\nstdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}",
        )
        return _last_nonempty_line(result.stdout)

    def test_second_boot_skips_seed_and_does_not_crash(self):
        self.volume = f"docdb-image-test-vol-{uuid.uuid4().hex[:8]}"
        first: str | None = None
        second: str | None = None
        try:
            # First boot: seeds sampledb and writes the one-shot marker.
            first = self._start(
                f"{CONTAINER_PREFIX}-restart-a-{uuid.uuid4().hex[:6]}"
            )
            _wait_for_ready(first)
            self.assertEqual(
                self._user_count(first), "5",
                "sampledb.users should have 5 docs after first-boot seeding",
            )
            _cleanup_container(first)
            first = None

            # Second boot on the SAME volume. Before the #612 fix this
            # re-ran the seed, hit a duplicate _id, exited non-zero, and
            # never emitted the readiness marker -> _wait_for_ready raises.
            second = self._start(
                f"{CONTAINER_PREFIX}-restart-b-{uuid.uuid4().hex[:6]}"
            )
            _wait_for_ready(second)

            logs = _docker("logs", second, check=False)
            combined = logs.stdout + logs.stderr
            self.assertIn(
                "already initialized", combined,
                "second boot should log that sample data was already "
                "initialized and skip re-seeding",
            )
            self.assertNotIn(
                "Sample data initialization failed", combined,
                "second boot must not fail re-running the seed",
            )
            self.assertEqual(
                self._user_count(second), "5",
                "sampledb.users must still have exactly 5 docs (no "
                "duplicate-key crash, no data loss) on second boot",
            )
        finally:
            _cleanup_container(first)
            _cleanup_container(second)


# ---------------------------------------------------------------------------
# 10. Custom init-data restart idempotency (regression test for #612, custom
#     path) - re-running the container on a persistent volume with a
#     NON-IDEMPOTENT custom script must NOT re-run that script and crash. The
#     init script writes a one-shot attempt marker under DATA_PATH immediately
#     before the first user script runs, so later boots skip custom init.
# ---------------------------------------------------------------------------

CUSTOM_RESTART_DB_NAME = "image_custom_restart_db"
CUSTOM_RESTART_COLLECTION = "restart_marker"


@_SKIP_UNLESS_IMAGE
class CustomInitDataRestartIdempotencyTests(unittest.TestCase):
    """Regression guard for #612 on the custom init-data path: a container
    with a persistent --data-path and a user-mounted --init-data-path whose
    script is NOT idempotent (a fixed-_id insertOne that fails on replay)
    must start cleanly on its second boot and skip the already-applied custom
    init, instead of re-running the script, hitting a duplicate _id, exiting
    non-zero, and looping under a restart policy. The single-boot
    CustomInitDataTests proves the script runs; this proves it is one-shot."""

    image: str
    volume: str | None
    init_dir: str | None
    password: str

    @classmethod
    def setUpClass(cls) -> None:
        cls.image = os.environ["DOCUMENTDB_LOCAL_IMAGE"]
        cls.password = _random_password()
        cls.volume = None
        cls.init_dir = None

        init_dir = tempfile.mkdtemp(prefix="docdb-image-custom-restart-")
        # Deliberately NON-idempotent: a fixed _id with no countDocuments
        # guard. Replaying this script against the already-seeded volume
        # raises a duplicate-key error -- the exact failure that drove the
        # #612 restart loop. The one-shot attempt marker must prevent replay.
        script_path = pathlib.Path(init_dir) / "00-restart-marker.js"
        script_path.write_text(
            f"""use('{CUSTOM_RESTART_DB_NAME}');
db.{CUSTOM_RESTART_COLLECTION}.insertOne({{
    _id: 'custom-restart-marker',
    placed_by: 'documentdb_local_tests',
    via: 'init-data-path'
}});
print('custom restart marker placed');
""",
            encoding="utf-8",
        )
        os.chmod(init_dir, 0o755)
        os.chmod(script_path, 0o644)
        cls.init_dir = init_dir

    @classmethod
    def tearDownClass(cls) -> None:
        if cls.volume:
            _docker("volume", "rm", "-f", cls.volume, check=False)
            cls.volume = None
        if cls.init_dir:
            shutil.rmtree(cls.init_dir, ignore_errors=True)
            cls.init_dir = None

    def _start(self, name: str) -> str:
        # --skip-init-data disables only the bundled sample data; the custom
        # --init-data-path still runs (it is gated solely on the presence of
        # *.js files), which keeps this test focused on the custom path.
        return _start_container(
            self.image,
            extra_run_args=[
                "-v", f"{self.volume}:/data",
                "-v", f"{self.init_dir}:/init_doc_db.d:ro",
            ],
            entrypoint_flags=[
                "--username", DEFAULT_USERNAME,
                "--password", self.password,
                "--data-path", "/data",
                "--init-data-path", "/init_doc_db.d",
                "--skip-init-data",
            ],
            name=name,
        )

    def _marker_count(self, container: str) -> str:
        result = _mongosh_exec(
            container,
            f"db.getSiblingDB('{CUSTOM_RESTART_DB_NAME}')"
            f".{CUSTOM_RESTART_COLLECTION}.countDocuments({{}})",
            username=DEFAULT_USERNAME,
            password=self.password,
        )
        self.assertEqual(
            result.returncode, 0,
            f"countDocuments failed\nstdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}",
        )
        return _last_nonempty_line(result.stdout)

    def test_second_boot_skips_custom_init_and_does_not_crash(self):
        self.volume = f"docdb-image-test-vol-{uuid.uuid4().hex[:8]}"
        first: str | None = None
        second: str | None = None
        try:
            # First boot: runs the custom script and writes the one-shot
            # attempt + success markers under /data.
            first = self._start(
                f"{CONTAINER_PREFIX}-custom-restart-a-{uuid.uuid4().hex[:6]}"
            )
            _wait_for_ready(first)
            self.assertEqual(
                self._marker_count(first), "1",
                "custom collection should have 1 doc after first-boot init",
            )
            _cleanup_container(first)
            first = None

            # Second boot on the SAME volume with the SAME non-idempotent
            # script still mounted. Before the #612 custom-path fix this
            # re-ran the script, hit a duplicate _id, exited non-zero, and
            # never emitted the readiness marker -> _wait_for_ready raises.
            second = self._start(
                f"{CONTAINER_PREFIX}-custom-restart-b-{uuid.uuid4().hex[:6]}"
            )
            _wait_for_ready(second)

            logs = _docker("logs", second, check=False)
            combined = logs.stdout + logs.stderr
            self.assertIn(
                "already initialized", combined,
                "second boot should log that custom data was already "
                "initialized and skip re-running the script",
            )
            self.assertNotIn(
                "Custom data initialization failed", combined,
                "second boot must not fail re-running the custom script",
            )
            self.assertEqual(
                self._marker_count(second), "1",
                "custom collection must still have exactly 1 doc (no "
                "duplicate-key crash, no data loss) on second boot",
            )
        finally:
            _cleanup_container(first)
            _cleanup_container(second)


if __name__ == "__main__":
    unittest.main()
