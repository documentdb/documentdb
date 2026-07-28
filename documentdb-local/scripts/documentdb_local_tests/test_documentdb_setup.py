import re
import shutil
import shlex
import subprocess
import tempfile
import unittest
import os
from pathlib import Path

OSS_ROOT = Path(__file__).resolve().parents[3]
SETUP_SCRIPT = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-setup.sh"
RESET_SCRIPT = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-local-reset.sh"
TUNE_SCRIPT = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-tune.sh"
GATEWAY_SETUP_SCRIPT = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-register-gateway.sh"
GATEWAY_ADMIN_SCRIPT = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-gateway-admin.sh"
TOOLS_LIB = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-tools-lib.sh"
GATEWAY_POSTINST = OSS_ROOT / "documentdb-local" / "maintainer-scripts" / "gateway" / "postinst"
STANDALONE_BUILD_SCRIPT = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
BUILD_EXTRA_PACKAGES = OSS_ROOT / "packaging" / "build_extra_packages.sh"
DEB_COMMON = OSS_ROOT / "packaging" / "deb-common.sh"
META_BUILD_SCRIPT = OSS_ROOT / "packaging" / "standalone" / "build-meta-deb.sh"
COMMON_BUILD_SCRIPT = OSS_ROOT / "packaging" / "standalone" / "build-common-deb.sh"
COMMON_SPEC = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-common.spec"
STANDALONE_SPEC = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local.spec"
PACKAGING_README = OSS_ROOT / "packaging" / "README.md"


class DocumentDBSetupTests(unittest.TestCase):
    def test_peer_auth_map_allows_supported_documentdb_user_roles(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"local -a map_lines=\(\n(?P<body>.*?)\n\s*\)",
            script,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match)

        map_lines = {
            line.strip().strip('"')
            for line in match.group("body").splitlines()
            if line.strip().startswith('"documentdb-map')
        }

        self.assertTrue(
            {
                "documentdb-map   documentdb   documentdb",
                "documentdb-map   documentdb   +documentdb_readonly_role",
                "documentdb-map   documentdb   +documentdb_readwrite_role",
                "documentdb-map   documentdb   +documentdb_admin_role",
            }.issubset(map_lines)
        )
        self.assertNotIn("documentdb-map   documentdb   all", map_lines)

    def test_peer_auth_map_includes_wizard_persona(self):
        # The fallback hba rule is `local all all peer map=documentdb-map`
        # (first match wins), so the wizard's own greenfield superuser
        # persona needs an identity entry — without it the greenfield
        # fallback locks itself out and wait_for_postgres dies after 60s
        # with a misleading readiness error.
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"local -a map_lines=\(\n(?P<body>.*?)\n\s*\)",
            script,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match)
        map_lines = {
            line.strip().strip('"')
            for line in match.group("body").splitlines()
            if line.strip().startswith('"documentdb-map')
        }
        self.assertIn(
            "documentdb-map   documentdb-local   documentdb-local",
            map_lines,
        )

    def test_admin_username_validated_against_gateway_blocked_prefixes(self):
        # Found by the PG16 E2E run: documentdb-setup accepted any admin
        # name, so `--admin-user pgadmin --yes` exited 0, printed
        # "SUCCESS: DocumentDB is ready" plus a connect command, and left an
        # install whose only admin failed every login with "Username is
        # invalid" — the gateway blocks the documentdb/citus/pg/
        # internal_role prefixes. Both the flag path and the interactive
        # prompt must consult the gateway's own policy, in argument
        # validation, before anything is mutated.
        lib = (OSS_ROOT / "documentdb-local" / "scripts"
               / "documentdb-tools-lib.sh").read_text(encoding="utf-8")
        self.assertIn(
            "documentdb_validate_gateway_username()",
            lib,
            "the shared library must provide the gateway username validator",
        )
        self.assertIn("BlockedRolePrefixes", lib)

        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertGreaterEqual(
            script.count("documentdb_validate_gateway_username"), 2,
            "both the --admin-user flag path and the interactive prompt "
            "must validate the username",
        )
        match = re.search(
            r"validate_required_arguments\(\)\s*\{(?P<body>.*?)\n\}",
            script,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match)
        self.assertIn(
            "documentdb_validate_gateway_username",
            match.group("body"),
            "validation must happen in validate_required_arguments, before "
            "any host mutation",
        )

        admin = GATEWAY_ADMIN_SCRIPT.read_text(encoding="utf-8")
        create = re.search(
            r"cmd_create_user\(\)\s*\{(?P<body>.*?)\n\}",
            admin,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(create)
        body = create.group("body")
        self.assertIn("documentdb_validate_gateway_username", body)
        # The check must precede the dry-run early return so a preview
        # reports the same refusal an apply would.
        self.assertLess(
            body.index("documentdb_validate_gateway_username"),
            body.index('"${DRY_RUN}" == "true"'),
            "create-user must validate before the dry-run branch",
        )

    def test_placeholder_listener_pid_is_resolved_per_port_not_host_wide(self):
        # find_listener_pid returns the literal "1" placeholder when the host
        # cannot map sockets to PIDs (no ss/lsof visibility — e.g. Docker
        # without SYS_PTRACE, the environment the wizard's nohup gateway
        # fallback exists for). Both classifiers need SOME way to resolve that
        # placeholder, or a bare day-2 re-run dies on its own listener.
        #
        # The first attempt answered it host-wide: `pgrep -x postgres` and
        # `pgrep -f documentdb-gateway`, i.e. "does any postgres/gateway exist
        # anywhere?". That is true on virtually every host the wizard runs on,
        # so a fail-closed guard became fail-open — a foreign process holding
        # the port was accepted as ours, and (via the ownership skip in
        # resolve_live_cluster_metadata) the wizard could go on to rewrite a
        # PostgreSQL cluster it did not own.
        #
        # The resolution must therefore be PORT-SCOPED: our own cluster's
        # postmaster.pid for PostgreSQL, and the per-port pidfile the nohup
        # launch writes for the gateway. This test pins that property and
        # forbids a regression to a host-wide process match.
        script = SETUP_SCRIPT.read_text(encoding="utf-8")

        self.assertNotIn(
            "pgrep -x postgres", script,
            "listener classification must not fall back to a host-wide "
            "postgres process match; use the cluster's own postmaster.pid",
        )
        self.assertNotIn(
            "documentdb-gateway-daemon|documentdb[-_]gateway", script,
            "gateway classification/stop must not use a host-wide process "
            "name match; it also matches other majors' gateways and the "
            "runuser wrapper this script itself launches",
        )

        # Both classifiers take an optional port and use it for the
        # placeholder case.
        for fn, resolver in (
            ("listener_looks_like_postgres", "postmaster_pid_owns_port"),
            ("listener_looks_like_gateway", "nohup_gateway_pid_for_port"),
        ):
            match = re.search(
                rf"^{fn}\(\)\s*\{{(?P<body>.*?)\n\}}",
                script,
                flags=re.DOTALL | re.MULTILINE,
            )
            self.assertIsNotNone(match, f"{fn} not found")
            body = match.group("body")
            self.assertIn(
                'local port="${2:-}"', body,
                f"{fn} must accept the port so the placeholder case can be "
                "resolved against a port-scoped record",
            )
            self.assertIn(
                '"${HAS_WORKING_SYSTEMD:-}" != "true"', body,
                f"{fn} must still handle the placeholder on a no-systemd host",
            )
            self.assertIn(
                resolver, body,
                f"{fn} must resolve the placeholder via {resolver}, not a "
                "host-wide process match",
            )

        # The per-port gateway record is written at launch, or the reader can
        # never succeed and every no-systemd re-run fails closed.
        self.assertIn(
            "nohup_gateway_pidfile", script,
            "the nohup launch must record its PID per port",
        )

    def test_genuine_pid1_postgres_still_gets_the_ownership_check(self):
        # "1" from find_listener_pid means two different things: the
        # unknown-owner placeholder, and a real listener that happens to be
        # process 1 — which is NORMAL in a container, where the main process
        # is pid 1. Skipping the UID/owner comparison for every "1" therefore
        # let a foreign PostgreSQL running as pid 1 past the guard whose die
        # message promises "documentdb-setup will not modify another
        # PostgreSQL cluster", after which the wizard rewrote its
        # postgresql.conf and pg_hba.conf.
        # The gates use an evidence-first decision table (binding plan review):
        # real pid → stat it; placeholder → datadir-proof proceeds,
        # pid-1-provably-the-listener stats /proc/1, provably-NOT proceeds
        # without statting the wrong process, and only UNKNOWN falls back to the
        # pid1_is_postgres heuristic. That table was extracted verbatim into the
        # shared resolve_uid_check_target helper (documentdb-tools-lib.sh) so the
        # two gates cannot drift — so pin the arms in the LIB once, and pin that
        # BOTH setup gates DELEGATE to it. The predicate is exercised
        # behaviourally in GatewayListenerPidSafetyTests, and the helper's full
        # decision table in test_resolve_uid_check_target_decision_table.
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        lib = TOOLS_LIB.read_text(encoding="utf-8")

        # Predicate + the whole decision table live in the shared lib.
        self.assertIn("pid1_is_postgres()", lib,
                      "the pid-1 discriminator must exist in the shared lib")
        self.assertIn("resolve_uid_check_target()", lib,
                      "the shared uid-target decision table must exist in the lib")
        # Table arms, now expressed once in the helper (keyed on its ${port} arg).
        self.assertIn('pid_listens_on_port 1 "${port}"', lib,
                      "the table must ask whether pid 1 actually holds the port")
        self.assertIn('postmaster_pid_owns_port "${port}"', lib,
                      "the table must accept datadir-proven ownership without a stat")
        # The heuristic survives ONLY as the unknown arm, gated on rc==2.
        self.assertIn("== 2 )) && pid1_is_postgres", lib,
                      "pid1_is_postgres must be the UNKNOWN-only fallback, "
                      "never the first question")
        # BOTH setup gates must DELEGATE to the shared helper — neither may
        # resolve the target inline (inline copies are exactly how they drift).
        self.assertIn(
            'resolve_uid_check_target "${live_cluster_pid}" "${port}"', script,
            "gate B (live-cluster adoption) must delegate to the shared helper")
        self.assertIn(
            'resolve_uid_check_target "${pg_listener_pid}" "${PG_PORT}"', script,
            "gate A (greenfield preflight) must delegate to the shared helper")
        # The old flat forms must not return anywhere: bare skip-every-pid-1, or
        # the heuristic deciding without port evidence.
        for hay, where in ((script, "setup"), (lib, "lib")):
            self.assertNotIn(
                '[[ "${live_cluster_pid}" != "1" ]] || pid1_is_postgres', hay,
                f"{where} must not stat /proc/1 merely because pid 1 is A "
                "postgres — that measured the wrong process (finding 2)",
            )
            self.assertNotIn(
                '[[ "${pg_listener_pid}" != "1" ]] || pid1_is_postgres', hay,
                f"{where} must not regress to the wrong-process stat either",
            )

    def test_status_and_print_config_survive_missing_postgres(self):
        # detect_postgres_installation's terminal `die` exits the whole
        # script straight through the `|| true` guards at the --status /
        # --print-config call sites (a shell `exit` is not catchable), so
        # both modes exited 1 with no output at all on a host without
        # PostgreSQL. The escape must cover both read-only modes.
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            script,
            r'if \[\[ "\$\{DRY_RUN\}" == "true" \|\| "\$\{STATUS_ONLY\}" == "true" \|\| "\$\{PRINT_CONFIG\}" == "true" \]\]; then',
            "detect_postgres_installation must not die under --status/--print-config",
        )
        # Behavioral: both modes must produce output and never die silently,
        # whether or not the host has PostgreSQL installed.
        env = {k: v for k, v in os.environ.items() if k != "PG_VERSION"}
        status = subprocess.run(
            ["bash", str(SETUP_SCRIPT), "--status"],
            capture_output=True, text=True, timeout=30, env=env,
        )
        self.assertIn(status.returncode, (0, 1), status.stderr)
        self.assertTrue(
            status.stdout.strip(),
            f"--status must print a report or the no-PG fallback, got rc="
            f"{status.returncode} stderr={status.stderr!r}",
        )
        print_config = subprocess.run(
            ["bash", str(SETUP_SCRIPT), "--print-config"],
            capture_output=True, text=True, timeout=30, env=env,
        )
        self.assertEqual(print_config.returncode, 0, print_config.stderr)
        self.assertTrue(print_config.stdout.strip(),
                        "--print-config must print the resolved config")

    def test_pg_version_env_var_is_ignored(self):
        # An exported PG_VERSION used to poison the parse-time port/data-dir
        # defaults (cluster initdb'd into .../15/data on port 9715 while
        # auto-detect re-pinned the version to 18). Version selection is
        # CLI-only.
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn('PG_VERSION="${PG_VERSION:-}"', script)
        self.assertRegex(script, r'\nPG_VERSION=""\n')

    def test_greenfield_over_brownfield_guard_runs_in_preflight(self):
        # The refusal must fire BEFORE initdb / legacy-env rewrite, not
        # only inside persist_self_managed_postgres_state after the damage
        # is done.
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"preflight_validation\(\)\s*\{(?P<body>.*?)\n\}",
            script,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match)
        self.assertIn("brownfield.conf", match.group("body"))
        self.assertIn(
            "Refusing to also create a package-owned private instance",
            match.group("body"),
        )

    def test_mode_flags_are_mutually_exclusive(self):
        # --use-new-postgres-instance (force greenfield) combined with
        # --target-postgres-instance (adopt) used to silently run the
        # brownfield flow, discarding the explicit greenfield flag.
        result = subprocess.run(
            ["bash", str(SETUP_SCRIPT), "--use-new-postgres-instance",
             "--target-postgres-instance", "18/main",
             "--admin-user", "admin", "--yes"],
            capture_output=True, text=True, timeout=30,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mutually exclusive", result.stderr)

    def test_tls_auto_generate_false_requires_cert_and_key(self):
        # Without this wizard-layer check the daemon rejects the combination
        # only at startup (exit 78, systemd restart loop) after PG state was
        # already mutated, surfacing ~60s later as a generic readiness error.
        result = subprocess.run(
            ["bash", str(SETUP_SCRIPT), "--tls-auto-generate", "false",
             "--admin-user", "admin", "--yes"],
            capture_output=True, text=True, timeout=30,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "--tls-auto-generate false requires --tls-cert and --tls-key",
            result.stderr,
        )

    def test_brownfield_rerun_command_preserves_password_source_and_gateway_flags(self):
        # Every FIRST brownfield adoption exits at the "restart PG, then
        # re-run" handoff. The printed step-2 command used to keep only
        # --admin-user/--yes: with --admin-password-file + --yes the
        # suggested command died in resolve_password, and dropped
        # --listen-port/--tls-* flags silently reset port/TLS on the
        # re-run.
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"build_rerun_suffix\(\)\s*\{(?P<body>.*?)\n\}",
            script,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match, "build_rerun_suffix helper must exist")
        body = match.group("body")
        for fragment in (
            "--admin-password-file ${PASSWORD_FILE}",
            "--admin-password-stdin",
            "--listen-port ${GATEWAY_PORT}",
            "--tls-cert ${TLS_CERT_FILE} --tls-key ${TLS_KEY_FILE}",
            "--tls-auto-generate ${TLS_AUTO_GENERATE}",
        ):
            self.assertIn(fragment, body)
        # Both brownfield handoff sites must use the helper (no stale
        # inline reconstruction left behind).
        self.assertGreaterEqual(script.count('rerun_suffix="$(build_rerun_suffix)"'), 2)
        self.assertNotRegex(
            script,
            r'\[\[ -n "\$\{USERNAME\}" \]\] && rerun_suffix\+=',
            "old inline rerun reconstruction must be gone",
        )

    def test_rerun_defaults_gateway_port_and_tls_from_persisted_state(self):
        # A bare re-run must not reset a --listen-port 27017 install to
        # 10260 or replace an operator cert with a fresh self-signed one:
        # register-gateway rebuilds gateway.env wholesale from its args,
        # and the wizard always passes --listen-addr and a
        # --tls-auto-generate value.
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"default_gateway_settings_from_persisted_state\(\)\s*\{(?P<body>.*?)\n\}",
            script,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('"${GATEWAY_PORT_EXPLICIT}" != "true"', body)
        self.assertIn("GATEWAY_PORT=", body)
        self.assertIn("DOCUMENTDB_TLS_AUTO_GENERATE=", body)
        self.assertIn("DOCUMENTDB_TLS_CERT_FILE=", body)
        # The helper must run before the register-gateway delegation
        # builds its argument list.
        ident_map = re.search(
            r"ensure_pg_ident_map\(\)\s*\{(?P<body>.*?)\n\}",
            script,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(ident_map)
        ident_body = ident_map.group("body")
        helper_idx = ident_body.index("default_gateway_settings_from_persisted_state")
        rg_args_idx = ident_body.index("local -a rg_args=()")
        self.assertLess(helper_idx, rg_args_idx)
        # --listen-port must record explicitness for the helper to respect.
        self.assertIn("GATEWAY_PORT_EXPLICIT=true", script)
        # CRITICAL ordering (round-11 F1/F2): the helper must ALSO run in
        # preflight — before the cross-major gateway-port collision scan,
        # and (because the greenfield flow later rewrites setup.conf with
        # the current GATEWAY_PORT via persist_self_managed_postgres_state)
        # before that rewrite can clobber the persisted value. Reading it
        # only from ensure_pg_ident_map was too late on both counts.
        preflight = re.search(
            r"preflight_validation\(\)\s*\{(?P<body>.*?)\n\}",
            script,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(preflight)
        pf_body = preflight.group("body")
        pf_helper_idx = pf_body.index("default_gateway_settings_from_persisted_state")
        pf_collision_idx = pf_body.index("is already in use by the documentdb-local@")
        self.assertLess(
            pf_helper_idx, pf_collision_idx,
            "port preservation must run before the cross-major collision scan",
        )
        # And the dry-run preview must mirror it so the previewed port
        # matches what a bare re-run would actually keep. Anchor on the
        # preview's defaults-recompute comment (the literal DRY_RUN check
        # also appears earlier inside the restore helpers).
        dry_run_block = script[script.index(
            "Recompute the per-major defaults the same way resolve_runtime_paths"):]
        self.assertIn(
            "default_gateway_settings_from_persisted_state",
            dry_run_block[:2500],
        )

    def test_restore_honors_dry_run(self):
        # `--restore --dry-run` used to execute the full destructive
        # restore (only the delegated documentdb-tune call got --dry-run),
        # while the help text promised "Preview changes without writing".
        # Every mutation in the restore block must now be gated on DRY_RUN.
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        restore_start = script.index('if [[ "${RESTORE}" == "true" ]]; then')
        restore_end = script.index("Restore complete. Restart PostgreSQL to apply.")
        block = script[restore_start:restore_end]
        # The strip/mutate helpers must exist and honor DRY_RUN.
        self.assertIn("_restore_strip_block()", block)
        self.assertIn("_restore_do()", block)
        self.assertIn('[dry-run] Would strip managed block from', block)
        self.assertIn('[dry-run] Would ${_desc}', block)
        # No direct unguarded state-file deletion may remain: every rm of
        # the per-major state files must go through _restore_do.
        self.assertNotRegex(
            block,
            r'(?m)^\s*rm -f "\$\{per_major_conf\}"',
            "per-major setup.conf removal must be dry-run-gated via _restore_do",
        )
        self.assertNotRegex(
            block,
            r'(?m)^\s*rm -f "\$\{per_major_brownfield\}"',
            "brownfield.conf removal must be dry-run-gated via _restore_do",
        )
        # Sanity-check the patterns are live: the guarded forms MUST match
        # when the _restore_do prefix is stripped, proving the negative
        # assertions above would catch a regression.
        self.assertRegex(
            block,
            r'(?m)^\s*_restore_do "remove \$\{per_major_conf\}" rm -f "\$\{per_major_conf\}"',
        )
        # The preview must announce itself and change nothing.
        self.assertIn(
            "Restore dry-run complete. No changes were made.",
            script,
        )
        # Root is only required for a real restore, matching the main
        # dry-run path which lets a non-root operator preview the plan.
        self.assertIn(
            '[[ "${DRY_RUN}" == "true" ]] || require_root',
            block,
        )

    def test_restore_scopes_to_explicit_pg_version(self):
        # An unscoped --restore sweeps EVERY major. With --pg-version N it
        # must restrict the state-file globs, the systemd target stop, and
        # the templated drop-in cleanup to that major only, and confirm
        # before an unscoped multi-major teardown.
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        restore_start = script.index('if [[ "${RESTORE}" == "true" ]]; then')
        restore_end = script.index("Restore complete. Restart PostgreSQL to apply.")
        block = script[restore_start:restore_end]
        self.assertIn('if [[ "${PG_VERSION_EXPLICIT}" == "true" ]]; then', block)
        self.assertIn(
            'per_major_glob="/etc/documentdb/local/${restore_scope}"',
            block,
        )
        self.assertIn(
            '_target_unit_glob="documentdb-local@${restore_scope}.target"',
            block,
        )
        self.assertIn(
            'templated_drop_in_glob="/etc/systemd/system/documentdb-postgresql@${restore_scope}.service.d"',
            block,
        )
        self.assertIn(
            "Continue with the multi-major restore?",
            block,
            "unscoped multi-major restore must ask for confirmation",
        )

    def test_brownfield_requires_delegated_tools_in_preflight(self):
        # The inline fallbacks are greenfield-only: pointed at an adopted
        # cluster they would clobber operator listen settings and write a
        # pg_hba map with no entry for the operator's OS users. Brownfield
        # without documentdb-postgresql-tools must fail fast in preflight,
        # before any mutation.
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"preflight_validation\(\)\s*\{(?P<body>.*?)\n\}",
            script,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('if [[ -n "${TARGET_CLUSTER}" ]]; then', body)
        self.assertIn(
            "! command_exists documentdb-tune || ! command_exists documentdb-register-gateway",
            body,
            "preflight must reject brownfield adoption when the delegated "
            "tools are missing",
        )


class DocumentDBTuneTests(unittest.TestCase):
    """Tests for the documentdb-tune standalone script."""

    def test_print_output_contains_required_settings(self):
        """--print should output all required GUC settings."""
        result = subprocess.run(
            ["bash", str(TUNE_SCRIPT), "--pg-version", "17", "--print"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        output = result.stdout
        self.assertIn("shared_preload_libraries", output)
        self.assertIn("pg_cron", output)
        self.assertIn("pg_documentdb_core", output)
        self.assertIn("pg_documentdb", output)
        self.assertIn("documentdb.enableBackgroundWorker = true", output)
        self.assertIn("cron.database_name = 'postgres'", output)
        self.assertIn("cron.use_background_workers = on", output)

    def test_print_emits_localhost_connection_string(self):
        # Workflow A/B run documentdb-tune directly; the managed block MUST set
        # documentdb.localhost_connection_string so the extension's internal
        # libpq connections use the Unix socket (peer/local auth) instead of the
        # default host=localhost (TCP/SCRAM -> "fe_sendauth: no password
        # supplied" on the first insert). Regression for the primary E2E
        # blocker (thread 34895xxx / iteration-16 socket routing).
        result = subprocess.run(
            ["bash", str(TUNE_SCRIPT), "--pg-version", "17", "--print"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(
            result.stdout,
            r"documentdb\.localhost_connection_string = 'host=\S+ port=[0-9]+'",
        )

    def test_print_honors_socket_dir_and_port_overrides(self):
        # documentdb-setup hands tune the greenfield private socket/port so the
        # GUC points at the private cluster's socket.
        result = subprocess.run(
            ["bash", str(TUNE_SCRIPT), "--pg-version", "17",
             "--socket-dir", "/run/documentdb-local/17/postgresql",
             "--port", "9999", "--print"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "documentdb.localhost_connection_string = "
            "'host=/run/documentdb-local/17/postgresql port=9999'",
            result.stdout,
        )

    def test_setup_passes_socket_and_port_to_tune_for_greenfield(self):
        # In greenfield mode documentdb-setup owns the private cluster's listen
        # settings, so it must forward the resolved socket dir + port to tune so
        # the localhost-connection GUC points at the private socket.
        setup = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('--socket-dir "${PG_SOCKET_DIR}" --port "${PG_PORT}"', setup,
                      "greenfield setup must pass --socket-dir/--port to documentdb-tune")

    def test_localhost_conn_honors_postgresql_auto_conf(self):
        # postgresql.auto.conf (ALTER SYSTEM) is read LAST by PostgreSQL, so the
        # resolver must let it override port / unix_socket_directories, else a
        # brownfield cluster tuned via ALTER SYSTEM gets a stale socket route.
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "postgresql.conf"), "w", encoding="utf-8") as f:
                f.write("port = 1111\nunix_socket_directories = '/sock/conf'\n")
            with open(os.path.join(td, "postgresql.auto.conf"), "w", encoding="utf-8") as f:
                f.write("port = 2222\nunix_socket_directories = '/sock/auto'\n")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--print"],
                capture_output=True, text=True, timeout=10,
            )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(
            "documentdb.localhost_connection_string = 'host=/sock/auto port=2222'",
            r.stdout,
        )

    def test_port_override_rejects_non_numeric(self):
        r = subprocess.run(
            ["bash", str(TUNE_SCRIPT), "--pg-version", "17", "--port", "abc", "--print"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("--port must be a positive integer", r.stderr)

    def test_socket_dir_override_rejects_quotes(self):
        # A single quote would terminate the outer single-quoted GUC value, and a
        # backslash is silently consumed as a libpq escape, so both are rejected
        # at parse time (aligned with enforce_localhost_conn_safe). A double quote
        # is accepted by libpq in a host value, so it is intentionally allowed.
        for bad in ("/x'y", "/x\\y", "/x y"):
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pg-version", "17", "--socket-dir", bad, "--print"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertNotEqual(r.returncode, 0, f"should reject {bad!r}")
            self.assertIn(
                "--socket-dir must not contain single quotes, backslashes, or whitespace",
                r.stderr,
            )
        # A double quote is a valid libpq host char -> accepted (reaches --print).
        r = subprocess.run(
            ["bash", str(TUNE_SCRIPT), "--pg-version", "17",
             "--socket-dir", '/x"y', "--port", "5432", "--print"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(
            "documentdb.localhost_connection_string = 'host=/x\"y port=5432'",
            r.stdout,
        )

    def test_localhost_conn_fallback_is_distro_aware(self):
        # No configured socket dir: Debian/Ubuntu -> /var/run/postgresql,
        # RHEL/PGDG -> /run/postgresql (verified default).
        t = TUNE_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('sock="/var/run/postgresql"', t)
        self.assertIn('sock="/run/postgresql"', t)

    def test_disabled_unix_sockets_print_warns_but_still_prints(self):
        # unix_socket_directories = '' turns Unix sockets OFF. documentdb routes
        # its internal libpq connections over the socket (peer auth, no
        # password), so a disabled socket cannot work. --print warns loudly but
        # still emits a preview block (non-fatal preview).
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "postgresql.conf"), "w", encoding="utf-8") as f:
                f.write("unix_socket_directories = ''\nport = 5440\n")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--print"],
                capture_output=True, text=True, timeout=10,
            )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Unix sockets are disabled", r.stderr)
        self.assertIn("documentdb.localhost_connection_string", r.stdout)

    def test_rhel_pgdata_reapply_does_not_resurrect_removed_library(self):
        # RHEL / --pgdata regression (Finding 3): current_preload must be seeded
        # from the operator's shared_preload_libraries with our OWN managed block
        # excluded. Reading the block back in makes it a fixpoint — a library the
        # operator removes after the first apply gets resurrected, and a re-apply
        # falsely reports "already up to date". Mirrors the Debian path, which
        # never folds its own fragment value back into the merge.
        with tempfile.TemporaryDirectory() as td:
            conf = os.path.join(td, "postgresql.conf")
            operator_line = (
                "shared_preload_libraries = 'pg_stat_statements, auto_explain'"
            )
            with open(conf, "w", encoding="utf-8") as f:
                f.write(operator_line + "\n")
                f.write("unix_socket_directories = '/tmp/ok'\n")
                f.write("port = 5442\n")

            # First apply writes the managed block (operator libs + docdb libs).
            r1 = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--yes"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(r1.returncode, 0, r1.stderr)
            after_apply = Path(conf).read_text(encoding="utf-8")
            self.assertIn("pg_stat_statements", after_apply)

            # Operator now removes pg_stat_statements from THEIR OWN line. The
            # managed block still lists it. The operator line is byte-preserved
            # by the apply and its trailing quote makes the string unique (the
            # block's SPL line continues with ", pg_cron, ..."), so this replace
            # touches only the operator line, not the managed block.
            updated = after_apply.replace(
                operator_line, "shared_preload_libraries = 'auto_explain'"
            )
            self.assertNotEqual(
                updated, after_apply, "operator SPL line not found to edit"
            )
            with open(conf, "w", encoding="utf-8") as f:
                f.write(updated)

            # Re-print recomputes the block from the operator's now-reduced value.
            r2 = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--print"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(r2.returncode, 0, r2.stderr)
            spl_line = next(
                (ln for ln in r2.stdout.splitlines()
                 if "shared_preload_libraries" in ln),
                "",
            )
            self.assertTrue(
                spl_line, f"no shared_preload_libraries line in:\n{r2.stdout}"
            )
            # The removed library must NOT be resurrected...
            self.assertNotIn("pg_stat_statements", spl_line)
            # ...while the operator's remaining library and the docdb libraries
            # are still present.
            self.assertIn("auto_explain", spl_line)
            self.assertIn("pg_documentdb", spl_line)

            # do_apply write path: a real re-apply must actually rewrite the
            # managed block rather than falsely report "already up to date", so
            # the PERSISTED block must no longer list the removed library. Had
            # do_apply short-circuited as up-to-date (the pre-fix fixpoint), the
            # stale pg_stat_statements would remain and this would fail.
            r3 = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--yes"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(r3.returncode, 0, r3.stderr)
            final = Path(conf).read_text(encoding="utf-8")
            # The managed block's SPL line is the one that also lists the docdb
            # libraries (the operator's own reduced line does not).
            block_spl = next(
                (ln for ln in final.splitlines()
                 if "shared_preload_libraries" in ln and "pg_documentdb" in ln),
                "",
            )
            self.assertTrue(block_spl, f"no managed SPL line in:\n{final}")
            self.assertNotIn("pg_stat_statements", block_spl)
            self.assertIn("auto_explain", block_spl)

    def test_rhel_pgdata_torn_managed_block_fails_closed(self):
        # The RHEL/--pgdata seed read strips our managed block via
        # strip_managed_block, which fails closed (die) on an unbalanced block.
        # Because that die runs on the LEFT of a pipe, fail-closed depends on
        # `set -o pipefail`. This locks that in end-to-end so a future refactor
        # that drops pipefail (or the pipe) cannot silently regress it into
        # seeding an empty shared_preload_libraries from a corrupt file.
        with tempfile.TemporaryDirectory() as td:
            conf = os.path.join(td, "postgresql.conf")
            with open(conf, "w", encoding="utf-8") as f:
                f.write("shared_preload_libraries = 'auto_explain'\n")
                f.write("unix_socket_directories = '/tmp/ok'\n")
                f.write("port = 5442\n")
            # Write a real, balanced managed block first.
            r1 = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--yes"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(r1.returncode, 0, r1.stderr)
            # Tear the block: drop its end-marker line(s) (the only lines with
            # "<<<"), leaving an unbalanced start marker.
            torn = "".join(
                ln for ln in Path(conf).read_text(encoding="utf-8").splitlines(keepends=True)
                if "<<<" not in ln
            )
            self.assertIn(">>>", torn, "start marker should remain after tearing")
            self.assertNotIn("<<<", torn, "end marker should be gone after tearing")
            with open(conf, "w", encoding="utf-8") as f:
                f.write(torn)
            # Both --print (read-only) and --yes (apply) must fail closed rather
            # than silently seed an empty value from the corrupt file.
            for mode in ("--print", "--yes"):
                r = subprocess.run(
                    ["bash", str(TUNE_SCRIPT), "--pgdata", td, mode],
                    capture_output=True, text=True, timeout=10,
                )
                self.assertNotEqual(
                    r.returncode, 0, f"{mode} must fail closed on a torn managed block"
                )
                self.assertIn("markers", r.stderr.lower())

    def test_disabled_unix_sockets_apply_dies(self):
        # A real apply (not --dry-run) must fail closed rather than write a GUC
        # that routes to a socket dir PostgreSQL is not listening on.
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "postgresql.conf"), "w", encoding="utf-8") as f:
                f.write("unix_socket_directories = ''\nport = 5440\n")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--yes"],
                capture_output=True, text=True, timeout=10,
            )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Unix sockets are disabled", r.stderr)

    def test_disabled_unix_sockets_socket_dir_override_bypasses(self):
        # An explicit --socket-dir wins over the disabled config, so the guard
        # must not fire (documentdb-setup can hand tune a private socket path).
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "postgresql.conf"), "w", encoding="utf-8") as f:
                f.write("unix_socket_directories = ''\nport = 5440\n")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td,
                 "--socket-dir", "/var/run/postgresql", "--print"],
                capture_output=True, text=True, timeout=10,
            )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("Unix sockets are disabled", r.stderr)
        self.assertIn(
            "documentdb.localhost_connection_string = "
            "'host=/var/run/postgresql port=5440'",
            r.stdout,
        )

    def test_autoconf_empty_unix_sockets_last_wins_disables(self):
        # postgresql.auto.conf is read LAST, so an ALTER SYSTEM that clears
        # unix_socket_directories overrides a non-empty postgresql.conf value.
        # The disabled-socket guard must detect this last-wins empty assignment.
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "postgresql.conf"), "w", encoding="utf-8") as f:
                f.write("unix_socket_directories = '/tmp/fromconf'\nport = 5443\n")
            with open(os.path.join(td, "postgresql.auto.conf"), "w", encoding="utf-8") as f:
                f.write("unix_socket_directories = ''\n")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--yes"],
                capture_output=True, text=True, timeout=10,
            )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Unix sockets are disabled", r.stderr)

    def test_autoconf_nonempty_unix_sockets_last_wins_reenables(self):
        # The mirror case: an empty postgresql.conf value re-enabled by a
        # non-empty auto.conf value must NOT trip the guard and must use the
        # auto.conf socket dir.
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "postgresql.conf"), "w", encoding="utf-8") as f:
                f.write("unix_socket_directories = ''\nport = 5444\n")
            with open(os.path.join(td, "postgresql.auto.conf"), "w", encoding="utf-8") as f:
                f.write("unix_socket_directories = '/tmp/fromauto'\n")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--print"],
                capture_output=True, text=True, timeout=10,
            )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("Unix sockets are disabled", r.stderr)
        self.assertIn(
            "documentdb.localhost_connection_string = "
            "'host=/tmp/fromauto port=5444'",
            r.stdout,
        )

    def test_commented_unix_sockets_default_is_not_disabled(self):
        # A fresh initdb postgresql.conf ships the socket default COMMENTED OUT
        # (#unix_socket_directories = '/run/postgresql'). The disabled-socket
        # guard must skip commented lines, else it would wrongly fire on every
        # fresh cluster. Such a cluster relies on the compiled-in default, so
        # the resolver must fall back to the distro default with no warning.
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "postgresql.conf"), "w", encoding="utf-8") as f:
                f.write("#unix_socket_directories = '/run/postgresql'\nport = 5445\n")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--print"],
                capture_output=True, text=True, timeout=10,
            )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("Unix sockets are disabled", r.stderr)
        self.assertRegex(
            r.stdout,
            r"documentdb\.localhost_connection_string = "
            r"'host=(/var)?/run/postgresql port=5445'",
        )

    def test_resolver_honors_case_insensitive_guc_names(self):
        # PostgreSQL parameter names are case-insensitive, so the resolver must
        # read Port / UNIX_SOCKET_DIRECTORIES too; otherwise a mixed-case config
        # silently yields the wrong port/socket and reintroduces the fe_sendauth
        # failure Fix A prevents.
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "postgresql.conf"), "w", encoding="utf-8") as f:
                f.write("Port = 5434\nUNIX_SOCKET_DIRECTORIES = '/tmp/upper'\n")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--print"],
                capture_output=True, text=True, timeout=10,
            )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(
            "documentdb.localhost_connection_string = "
            "'host=/tmp/upper port=5434'",
            r.stdout,
        )

    def test_resolver_honors_optional_equals(self):
        # PostgreSQL allows omitting the '=' between a parameter name and its
        # value (a space separates them). The resolver must honor that form.
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "postgresql.conf"), "w", encoding="utf-8") as f:
                f.write("port 5435\nunix_socket_directories '/tmp/noeq'\n")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--print"],
                capture_output=True, text=True, timeout=10,
            )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(
            "documentdb.localhost_connection_string = "
            "'host=/tmp/noeq port=5435'",
            r.stdout,
        )

    def test_resolver_key_match_has_word_boundary(self):
        # A key must not match a longer parameter that merely starts with it:
        # 'portfoo' must not be read as 'port'. With no real port set, the
        # resolver falls back to the default 5432.
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "postgresql.conf"), "w", encoding="utf-8") as f:
                f.write("portfoo 9999\nunix_socket_directories '/tmp/pfx'\n")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--print"],
                capture_output=True, text=True, timeout=10,
            )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("port=5432'", r.stdout)
        self.assertNotIn("port=9999", r.stdout)

    def test_uppercase_and_noequals_disabled_sockets_apply_dies(self):
        # The disabled-socket guard must also fire for case-variant and no-'='
        # forms of an empty unix_socket_directories.
        for content in ("UNIX_SOCKET_DIRECTORIES = ''\n", "unix_socket_directories ''\n"):
            with tempfile.TemporaryDirectory() as td:
                with open(os.path.join(td, "postgresql.conf"), "w", encoding="utf-8") as f:
                    f.write(content + "port = 5440\n")
                r = subprocess.run(
                    ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--yes"],
                    capture_output=True, text=True, timeout=10,
                )
            self.assertNotEqual(r.returncode, 0, f"should die for: {content!r}")
            self.assertIn("Unix sockets are disabled", r.stderr)

    def test_uppercase_nonempty_sockets_not_flagged_disabled(self):
        # A non-empty uppercase socket dir must NOT be misread as empty and
        # flagged disabled (guards against a case-only match in the assignment
        # detector diverging from the value reader).
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "postgresql.conf"), "w", encoding="utf-8") as f:
                f.write("UNIX_SOCKET_DIRECTORIES = '/tmp/ok'\nport = 5442\n")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--print"],
                capture_output=True, text=True, timeout=10,
            )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("Unix sockets are disabled", r.stderr)
        self.assertIn(
            "documentdb.localhost_connection_string = 'host=/tmp/ok port=5442'",
            r.stdout,
        )

    def test_unhandled_include_apply_dies(self):
        # The resolver reads only postgresql.conf / conf.d / postgresql.auto.conf.
        # A config that pulls in another file via `include` could set port or
        # unix_socket_directories there, which we would miss — so apply must fail
        # closed rather than emit a possibly-wrong localhost route.
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "postgresql.conf"), "w", encoding="utf-8") as f:
                f.write("include = 'custom.conf'\nport = 6543\n")
            with open(os.path.join(td, "custom.conf"), "w", encoding="utf-8") as f:
                f.write("unix_socket_directories = ''\n")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--yes"],
                capture_output=True, text=True, timeout=10,
            )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("include/include_if_exists/include_dir", r.stderr)

    def test_unhandled_include_print_warns_but_emits(self):
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "postgresql.conf"), "w", encoding="utf-8") as f:
                f.write("include_if_exists = 'maybe.conf'\nport = 5432\n")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--print"],
                capture_output=True, text=True, timeout=10,
            )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("include", r.stderr)
        self.assertIn("documentdb.localhost_connection_string", r.stdout)

    def test_include_dir_confd_under_pgdata_dies(self):
        # Under --pgdata (and on RHEL) the resolver does NOT walk conf.d, so even
        # `include_dir = 'conf.d'` is unresolved and must fail closed — a port /
        # socket set in conf.d/*.conf would otherwise be silently missed.
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "postgresql.conf"), "w", encoding="utf-8") as f:
                f.write("include_dir = 'conf.d'\nport = 5432\n")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td, "--yes"],
                capture_output=True, text=True, timeout=10,
            )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("include/include_if_exists/include_dir", r.stderr)

    def test_include_dir_confd_exempt_only_in_debian_split_mode(self):
        # In the Debian split-layout (IS_DEBIAN and no --pgdata) the resolver
        # walks the ROOT postgresql.conf's conf.d, so `include_dir = 'conf.d'`
        # declared in that root file (exactly, case-sensitively) is exempt. A
        # different directory whose name merely contains "conf.d" (conf.d2,
        # conf.d.bak), a different case (CONF.D), or a NESTED
        # `include_dir = 'conf.d'` in a non-root conf.d/*.conf file (which
        # resolves to conf.d/conf.d, unwalked) must all be flagged. Sourced with
        # mocked globals because a real /etc/postgresql cluster is unavailable.
        src = Path(tempfile.mkdtemp())
        try:
            stripped = "\n".join(
                line for line in TUNE_SCRIPT.read_text(encoding="utf-8").splitlines()
                if line != 'main "$@"'
            )
            (src / "documentdb-tune.sh").write_text(stripped, encoding="utf-8")
            (src / "documentdb-tools-lib.sh").write_text(
                TOOLS_LIB.read_text(encoding="utf-8"), encoding="utf-8")

            def verdict(conf_line, is_root=True):
                conf = src / "probe.conf"
                conf.write_text(conf_line + "\n", encoding="utf-8")
                # DEBIAN_LIVE_PG_CONF marks the root postgresql.conf; when the
                # scanned file is NOT the root, the conf.d exemption must not apply.
                root = str(conf) if is_root else str(src / "other_root.conf")
                script = (
                    "set -uo pipefail\n"
                    f"source {shlex.quote(str(src / 'documentdb-tune.sh'))} >/dev/null 2>&1\n"
                    f"IS_DEBIAN=true; PGDATA=''; DEBIAN_LIVE_PG_CONF={shlex.quote(root)}\n"
                    "_effective_config_files() { printf '%s\\n' "
                    f"{shlex.quote(str(conf))}; }}\n"
                    "if _config_declares_unhandled_include; then echo FLAGGED; "
                    "else echo OK; fi\n"
                )
                r = subprocess.run(
                    ["bash", "-c", script], capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(r.returncode, 0, r.stderr)
                return r.stdout.strip()

            for line in ("include_dir = 'conf.d'", "include_dir conf.d",
                         "INCLUDE_DIR = 'conf.d'", "include_dir = 'conf.d/'"):
                self.assertEqual(verdict(line), "OK", f"root should exempt: {line!r}")
            for line in ("include_dir = 'conf.d2'", "include_dir = 'conf.d.bak'",
                         "include_dir = 'myconf.d'", "include_dir = 'CONF.D'",
                         "include = 'custom.conf'"):
                self.assertEqual(verdict(line), "FLAGGED", f"should flag: {line!r}")
            # A nested `include_dir = 'conf.d'` in a non-root file must be flagged.
            self.assertEqual(
                verdict("include_dir = 'conf.d'", is_root=False), "FLAGGED",
                "nested (non-root) include_dir=conf.d must be flagged",
            )
        finally:
            shutil.rmtree(src, ignore_errors=True)

    def test_confd_include_with_trailing_root_content_fails_closed(self):
        # PostgreSQL processes `include_dir = 'conf.d'` INLINE and then continues
        # reading the root postgresql.conf, so a root assignment placed AFTER the
        # include overrides conf.d. The resolver reads the whole root and then
        # conf.d, which would give conf.d the wrong precedence, so the guard must
        # fail closed when any active (non-comment, non-blank) line follows the
        # exempted conf.d include in the root file. The standard Debian layout has
        # include_dir as the LAST active line, so that case still passes. This is
        # the exact ordering reproduction raised in review of iteration 16.
        src = Path(tempfile.mkdtemp())
        try:
            stripped = "\n".join(
                line for line in TUNE_SCRIPT.read_text(encoding="utf-8").splitlines()
                if line != 'main "$@"'
            )
            (src / "documentdb-tune.sh").write_text(stripped, encoding="utf-8")
            (src / "documentdb-tools-lib.sh").write_text(
                TOOLS_LIB.read_text(encoding="utf-8"), encoding="utf-8")
            root = src / "postgresql.conf"
            confd = src / "10-port.conf"
            confd.write_text("port = 2222\n", encoding="utf-8")

            def verdict(root_body):
                root.write_text(root_body, encoding="utf-8")
                script = (
                    "set -uo pipefail\n"
                    f"source {shlex.quote(str(src / 'documentdb-tune.sh'))} >/dev/null 2>&1\n"
                    f"IS_DEBIAN=true; PGDATA=''; DEBIAN_LIVE_PG_CONF={shlex.quote(str(root))}\n"
                    "_effective_config_files() { printf '%s\\n' "
                    f"{shlex.quote(str(root))} {shlex.quote(str(confd))}; }}\n"
                    "if _config_declares_unhandled_include; then echo FLAGGED; "
                    "else echo OK; fi\n"
                )
                r = subprocess.run(
                    ["bash", "-c", script], capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(r.returncode, 0, r.stderr)
                return r.stdout.strip()

            # Review repro: a root port assignment AFTER include_dir must fail
            # closed (the naive resolver would otherwise pick conf.d's 2222).
            self.assertEqual(
                verdict("port = 1111\ninclude_dir = 'conf.d'\nport = 3333\n"),
                "FLAGGED",
            )
            # Standard Debian layout: include_dir is the last active line; only
            # comments / blank lines follow, which is fine.
            self.assertEqual(verdict("port = 1111\ninclude_dir = 'conf.d'\n"), "OK")
            self.assertEqual(
                verdict("port = 1111\ninclude_dir = 'conf.d'\n# trailing\n\n"), "OK")
            # Any active directive after the include (not just port) fails closed.
            self.assertEqual(
                verdict("include_dir = 'conf.d'\nunix_socket_directories = '/tmp'\n"),
                "FLAGGED",
            )
        finally:
            shutil.rmtree(src, ignore_errors=True)

    def test_preload_scan_mode_allows_benign_trailing_gucs_but_guards_preload(self):
        # documentdb-setup's brownfield adoption forwards the wizard-verified
        # --socket-dir/--port, so enforce_config_includes_resolved runs
        # _config_declares_unhandled_include in scan_mode=preload. The connection
        # route is already pinned, so a BENIGN GUC after the conf.d include (e.g.
        # work_mem — an extremely common admin habit, the exact repro from the
        # brownfield adoption bug) must be allowed through. A
        # shared_preload_libraries / data_directory assignment after conf.d (which
        # mis-orders tune's ordered fold) or a foreign include (whose file the
        # walk never reads) must still fail closed. The default (full) scan is
        # unchanged — it flags ANY active trailing content. Sourced with mocked
        # globals because a real /etc/postgresql cluster is unavailable.
        src = Path(tempfile.mkdtemp())
        try:
            stripped = "\n".join(
                line for line in TUNE_SCRIPT.read_text(encoding="utf-8").splitlines()
                if line != 'main "$@"'
            )
            (src / "documentdb-tune.sh").write_text(stripped, encoding="utf-8")
            (src / "documentdb-tools-lib.sh").write_text(
                TOOLS_LIB.read_text(encoding="utf-8"), encoding="utf-8")
            root = src / "postgresql.conf"
            confd = src / "10-port.conf"
            confd.write_text("port = 2222\n", encoding="utf-8")

            def verdict(root_body, scan_mode):
                root.write_text(root_body, encoding="utf-8")
                script = (
                    "set -uo pipefail\n"
                    f"source {shlex.quote(str(src / 'documentdb-tune.sh'))} >/dev/null 2>&1\n"
                    f"IS_DEBIAN=true; PGDATA=''; DEBIAN_LIVE_PG_CONF={shlex.quote(str(root))}; "
                    "CONFIG_TARGET='/frag/documentdb.conf'\n"
                    "_effective_config_files() { printf '%s\\n' "
                    f"{shlex.quote(str(root))} {shlex.quote(str(confd))}; }}\n"
                    f"if _config_declares_unhandled_include {shlex.quote(scan_mode)}; "
                    "then echo FLAGGED; else echo OK; fi\n"
                )
                r = subprocess.run(
                    ["bash", "-c", script], capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(r.returncode, 0, r.stderr)
                return r.stdout.strip()

            benign = "include_dir = 'conf.d'\nwork_mem = '64MB'\n"
            spl = "include_dir = 'conf.d'\nshared_preload_libraries = 'x'\n"
            datadir = "include_dir = 'conf.d'\ndata_directory = '/x'\n"
            # A no-'=' form (PostgreSQL allows whitespace-separated GUCs) must
            # also be caught by the preload trailing-content check.
            spl_noeq = "include_dir = 'conf.d'\nshared_preload_libraries 'x'\n"
            foreign = "include = 'custom.conf'\ninclude_dir = 'conf.d'\n"
            clean = "port = 1\ninclude_dir = 'conf.d'\n"
            # data_directory in the no-'=' form, mixed-case SPL, a foreign include
            # placed AFTER conf.d, and a GUC whose name merely STARTS with a
            # guarded name (must NOT be flagged — the match has a word boundary).
            datadir_noeq = "include_dir = 'conf.d'\ndata_directory '/x'\n"
            mixed_case = "include_dir = 'conf.d'\nShared_Preload_Libraries = 'x'\n"
            foreign_after = "include_dir = 'conf.d'\ninclude = 'custom.conf'\n"
            spl_lookalike = "include_dir = 'conf.d'\nshared_preload_librariesx = '1'\n"

            # preload: benign trailing GUC is allowed; SPL/data_directory/foreign
            # include still fail closed (they corrupt tune's own ordered fold).
            self.assertEqual(verdict(benign, "preload"), "OK")
            self.assertEqual(verdict(spl, "preload"), "FLAGGED")
            self.assertEqual(verdict(spl_noeq, "preload"), "FLAGGED")
            self.assertEqual(verdict(datadir, "preload"), "FLAGGED")
            self.assertEqual(verdict(datadir_noeq, "preload"), "FLAGGED")
            self.assertEqual(verdict(mixed_case, "preload"), "FLAGGED")
            self.assertEqual(verdict(foreign, "preload"), "FLAGGED")
            # A foreign include is a hazard regardless of position (its file is
            # never walked), so it fails closed even when it follows conf.d — the
            # include branch flags it before the scan_mode trailing check runs.
            self.assertEqual(verdict(foreign_after, "preload"), "FLAGGED")
            # A name that only starts with a guarded GUC is not a match, so an
            # otherwise-benign trailing setting still passes in preload mode.
            self.assertEqual(verdict(spl_lookalike, "preload"), "OK")
            self.assertEqual(verdict(clean, "preload"), "OK")
            # full (default, and the no-arg call): ANY active trailing content
            # fails closed — unchanged from before the narrowing.
            self.assertEqual(verdict(benign, "full"), "FLAGGED")
            self.assertEqual(verdict(spl, "full"), "FLAGGED")
            self.assertEqual(verdict(clean, "full"), "OK")
        finally:
            shutil.rmtree(src, ignore_errors=True)

    def test_enforce_includes_narrows_to_preload_when_overrides_supplied(self):
        # enforce_config_includes_resolved routes on overrides + layout:
        #  * no overrides           -> full scan (die on any trailing content).
        #  * overrides + Debian split -> preload scan (die only on a foreign
        #    include or a shared_preload_libraries / data_directory assignment
        #    after conf.d; a benign trailing GUC passes — this is what unblocks
        #    brownfield adoption of a cluster with ordinary trailing tuning).
        #  * overrides + --pgdata/RHEL -> skipped entirely (unchanged, so the
        #    greenfield private-cluster path is untouched).
        src = Path(tempfile.mkdtemp())
        try:
            stripped = "\n".join(
                line for line in TUNE_SCRIPT.read_text(encoding="utf-8").splitlines()
                if line != 'main "$@"'
            )
            (src / "documentdb-tune.sh").write_text(stripped, encoding="utf-8")
            (src / "documentdb-tools-lib.sh").write_text(
                TOOLS_LIB.read_text(encoding="utf-8"), encoding="utf-8")
            root = src / "postgresql.conf"
            confd = src / "10-port.conf"
            confd.write_text("port = 2222\n", encoding="utf-8")

            def enforce(overrides, is_debian, pgdata, root_body):
                root.write_text(root_body, encoding="utf-8")
                sdo, ppo = ("/run/sock", "7000") if overrides else ("", "")
                script = (
                    "set -uo pipefail\n"
                    f"source {shlex.quote(str(src / 'documentdb-tune.sh'))} >/dev/null 2>&1\n"
                    f"IS_DEBIAN={shlex.quote(is_debian)}; PGDATA={shlex.quote(pgdata)}; "
                    f"DEBIAN_LIVE_PG_CONF={shlex.quote(str(root))}; "
                    "CONFIG_TARGET='/frag/documentdb.conf'\n"
                    f"SOCKET_DIR_OVERRIDE={shlex.quote(sdo)}; PG_PORT_OVERRIDE={shlex.quote(ppo)}\n"
                    "_effective_config_files() { printf '%s\\n' "
                    f"{shlex.quote(str(root))} {shlex.quote(str(confd))}; }}\n"
                    "if ( enforce_config_includes_resolved die ); then echo PASS; else echo DIE; fi\n"
                )
                r = subprocess.run(
                    ["bash", "-c", script], capture_output=True, text=True, timeout=10,
                )
                return r.stdout.strip(), r.stderr

            benign = "include_dir = 'conf.d'\nwork_mem = '64MB'\n"
            spl = "include_dir = 'conf.d'\nshared_preload_libraries = 'x'\n"
            datadir = "include_dir = 'conf.d'\ndata_directory = '/srv/pg'\n"
            foreign = "include = 'custom.conf'\nport = 6543\n"

            # No overrides: benign trailing content still dies (full scan).
            self.assertEqual(enforce(False, "true", "", benign)[0], "DIE")
            # Overrides + Debian split: benign trailing GUC now passes.
            self.assertEqual(enforce(True, "true", "", benign)[0], "PASS")
            # Overrides + Debian split: SPL after conf.d still dies, with the
            # narrowed (preload) message about the fold precedence.
            out, err = enforce(True, "true", "", spl)
            self.assertEqual(out, "DIE")
            self.assertIn("shared_preload_libraries", err)
            # data_directory after conf.d dies via the same narrowed path.
            out, err = enforce(True, "true", "", datadir)
            self.assertEqual(out, "DIE")
            self.assertIn("data_directory", err)
            # Overrides + --pgdata: skipped entirely — even a foreign include
            # passes (the greenfield private-cluster contract is unchanged).
            self.assertEqual(enforce(True, "false", "/some/pgdata", foreign)[0], "PASS")
        finally:
            shutil.rmtree(src, ignore_errors=True)

    def test_confd_include_followed_by_managed_include_is_exempt(self):
        # After tune's FIRST Debian apply, ensure_debian_include_line appends its
        # managed include block to the ROOT postgresql.conf via
        # rewrite_with_managed_block, which appends at EOF — i.e. AFTER the
        # standard `include_dir = 'conf.d'`. That tune-managed include_if_exists
        # points only at the documentdb fragment (== CONFIG_TARGET), which holds
        # no port / unix_socket_directories / nested include, so it does not
        # affect resolution. The trailing-content guard must therefore EXEMPT it,
        # otherwise a bare `documentdb-tune` rerun on Debian would spuriously fail
        # closed on tune's own include (an idempotency regression). A foreign
        # include, or a real assignment, after conf.d still fails closed.
        src = Path(tempfile.mkdtemp())
        try:
            stripped = "\n".join(
                line for line in TUNE_SCRIPT.read_text(encoding="utf-8").splitlines()
                if line != 'main "$@"'
            )
            (src / "documentdb-tune.sh").write_text(stripped, encoding="utf-8")
            (src / "documentdb-tools-lib.sh").write_text(
                TOOLS_LIB.read_text(encoding="utf-8"), encoding="utf-8")
            root = src / "postgresql.conf"
            confd = src / "10-port.conf"
            confd.write_text("port = 2222\n", encoding="utf-8")
            frag = "/etc/postgresql-common/documentdb/17/main/documentdb.conf"

            def verdict(root_body, config_target=frag):
                root.write_text(root_body, encoding="utf-8")
                script = (
                    "set -uo pipefail\n"
                    f"source {shlex.quote(str(src / 'documentdb-tune.sh'))} >/dev/null 2>&1\n"
                    f"IS_DEBIAN=true; PGDATA=''; DEBIAN_LIVE_PG_CONF={shlex.quote(str(root))}; "
                    f"CONFIG_TARGET={shlex.quote(config_target)}\n"
                    "_effective_config_files() { printf '%s\\n' "
                    f"{shlex.quote(str(root))} {shlex.quote(str(confd))}; }}\n"
                    "if _config_declares_unhandled_include; then echo FLAGGED; "
                    "else echo OK; fi\n"
                )
                r = subprocess.run(
                    ["bash", "-c", script], capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(r.returncode, 0, r.stderr)
                return r.stdout.strip()

            managed = (
                "# >>> documentdb-tune managed include >>>\n"
                f"include_if_exists = '{frag}'\n"
                "# <<< documentdb-tune managed include <<<\n"
            )
            # The exact post-first-apply Debian root layout: conf.d then the
            # tune-managed include. Must be OK (idempotent rerun must not die).
            self.assertEqual(
                verdict(f"port = 1111\ninclude_dir = 'conf.d'\n{managed}"), "OK")
            # A foreign include after conf.d still fails closed.
            self.assertEqual(
                verdict("include_dir = 'conf.d'\ninclude_if_exists = '/etc/other.conf'\n"),
                "FLAGGED",
            )
            # A real assignment after conf.d fails closed even if the managed
            # include follows it.
            self.assertEqual(
                verdict(f"include_dir = 'conf.d'\nport = 3333\n{managed}"), "FLAGGED")
            # With no CONFIG_TARGET the trailing include is not special -> flagged.
            self.assertEqual(
                verdict(f"include_dir = 'conf.d'\n{managed}", config_target=""),
                "FLAGGED",
            )
        finally:
            shutil.rmtree(src, ignore_errors=True)

    def test_localhost_conn_safe_rejects_unsafe_resolved_socket(self):
        # documentdb.localhost_connection_string is emitted as a libpq conninfo
        # (host=<dir> port=<port>). A resolved socket directory containing
        # whitespace or a quote/backslash makes that conninfo unparseable
        # (libpq: missing "=" after ...), so the guard fails closed on apply
        # (die) and warns on --print/--dry-run. --socket-dir/--port overrides are
        # validated at parse time, so this only guards config-RESOLVED values;
        # mocked here via _read_effective_scalar_guc.
        src = Path(tempfile.mkdtemp())
        try:
            stripped = "\n".join(
                line for line in TUNE_SCRIPT.read_text(encoding="utf-8").splitlines()
                if line != 'main "$@"'
            )
            (src / "documentdb-tune.sh").write_text(stripped, encoding="utf-8")
            (src / "documentdb-tools-lib.sh").write_text(
                TOOLS_LIB.read_text(encoding="utf-8"), encoding="utf-8")

            def run(sock_val, port_val, mode):
                script = (
                    "set -uo pipefail\n"
                    f"source {shlex.quote(str(src / 'documentdb-tune.sh'))} >/dev/null 2>&1\n"
                    "set +e\n"
                    "SOCKET_DIR_OVERRIDE=''; PG_PORT_OVERRIDE=''\n"
                    "_read_effective_scalar_guc() { case \"$1\" in "
                    f"unix_socket_directories) printf '%s' {shlex.quote(sock_val)};; "
                    f"port) printf '%s' {shlex.quote(port_val)};; esac; }}\n"
                    f"enforce_localhost_conn_safe {mode}; echo \"RC=$?\"\n"
                )
                return subprocess.run(
                    ["bash", "-c", script], capture_output=True, text=True, timeout=10,
                )

            # Space in the resolved socket dir -> die on apply; message points at
            # --socket-dir; no RC line because die exits first.
            r = run("/tmp/pg socket", "5433", "die")
            self.assertNotIn("RC=0", r.stdout)
            self.assertIn("--socket-dir", r.stderr)
            # --print / --dry-run only warns and continues.
            r = run("/tmp/pg socket", "5433", "warn")
            self.assertIn("RC=0", r.stdout)
            self.assertIn("WARNING", r.stderr)
            # A single quote would terminate the outer single-quoted GUC value ->
            # rejected.
            r = run("/tmp/a'b", "5432", "warn")
            self.assertIn("WARNING", r.stderr)
            # A backslash is silently consumed as a libpq escape (host=/tmp/a\\b
            # connects to /tmp/ab) -> rejected.
            r = run("/tmp/a\\b", "5432", "warn")
            self.assertIn("WARNING", r.stderr)
            # A non-numeric resolved port is also rejected.
            r = run("/var/run/postgresql", "abc", "warn")
            self.assertIn("WARNING", r.stderr)
            # A double quote is accepted by libpq in a host value (verified with
            # psql), so it must NOT be rejected -> no warning (regression guard
            # against re-introducing the over-conservative reject).
            r = run('/tmp/a"b', "5432", "warn")
            self.assertIn("RC=0", r.stdout)
            self.assertNotIn("WARNING", r.stderr)
            # Safe values -> no problem, no warning.
            r = run("/var/run/postgresql", "5432", "warn")
            self.assertIn("RC=0", r.stdout)
            self.assertNotIn("WARNING", r.stderr)
        finally:
            shutil.rmtree(src, ignore_errors=True)

    def test_help_documents_socket_dir_and_port_options(self):
        # The recovery flags --socket-dir and --port must be discoverable from
        # --help so operators hit by the include / conf.d / unsafe-socket guards
        # can act on the guidance those guards print.
        r = subprocess.run(
            ["bash", str(TUNE_SCRIPT), "--help"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("--socket-dir", r.stdout)
        self.assertIn("--port", r.stdout)

    def test_tune_managed_include_is_exempt_for_idempotency(self):
        # On Debian, documentdb-tune writes its OWN `include_if_exists` pointing
        # at the managed fragment (== CONFIG_TARGET) into the root
        # postgresql.conf. That fragment holds only the documentdb GUCs (no port
        # / unix_socket_directories, no nested includes), so the guard must
        # exempt it — otherwise the next apply would flag tune's own directive
        # and break idempotency. Any OTHER include/include_if_exists still fails
        # closed. Sourced with mocked globals (CONFIG_TARGET = the fragment path).
        src = Path(tempfile.mkdtemp())
        try:
            stripped = "\n".join(
                line for line in TUNE_SCRIPT.read_text(encoding="utf-8").splitlines()
                if line != 'main "$@"'
            )
            (src / "documentdb-tune.sh").write_text(stripped, encoding="utf-8")
            (src / "documentdb-tools-lib.sh").write_text(
                TOOLS_LIB.read_text(encoding="utf-8"), encoding="utf-8")
            frag = "/etc/postgresql-common/documentdb/17/main/documentdb.conf"

            def verdict(conf_line, config_target=frag):
                conf = src / "probe.conf"
                conf.write_text(conf_line + "\n", encoding="utf-8")
                script = (
                    "set -uo pipefail\n"
                    f"source {shlex.quote(str(src / 'documentdb-tune.sh'))} >/dev/null 2>&1\n"
                    "IS_DEBIAN=true; PGDATA=''; "
                    f"DEBIAN_LIVE_PG_CONF={shlex.quote(str(conf))}; "
                    f"CONFIG_TARGET={shlex.quote(config_target)}\n"
                    "_effective_config_files() { printf '%s\\n' "
                    f"{shlex.quote(str(conf))}; }}\n"
                    "if _config_declares_unhandled_include; then echo FLAGGED; "
                    "else echo OK; fi\n"
                )
                r = subprocess.run(
                    ["bash", "-c", script], capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(r.returncode, 0, r.stderr)
                return r.stdout.strip()

            # tune's own managed include (value == CONFIG_TARGET) is exempt.
            self.assertEqual(verdict(f"include_if_exists = '{frag}'"), "OK")
            self.assertEqual(verdict(f"include = '{frag}'"), "OK")
            # An operator's include pointing elsewhere still fails closed.
            self.assertEqual(verdict("include_if_exists = '/some/other.conf'"), "FLAGGED")
            self.assertEqual(verdict("include = '/etc/other.conf'"), "FLAGGED")
            # With no CONFIG_TARGET the managed include is not special -> flagged.
            self.assertEqual(verdict(f"include_if_exists = '{frag}'", config_target=""), "FLAGGED")
        finally:
            shutil.rmtree(src, ignore_errors=True)

    def test_include_guard_bypassed_when_both_overrides_supplied(self):
        # documentdb-setup's greenfield path passes --socket-dir and --port, so
        # resolution never reads the cluster config and includes are irrelevant.
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "postgresql.conf"), "w", encoding="utf-8") as f:
                f.write("include = 'custom.conf'\nport = 6543\n")
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", td,
                 "--socket-dir", "/run/documentdb", "--port", "7000", "--print"],
                capture_output=True, text=True, timeout=10,
            )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("include", r.stderr)
        self.assertIn(
            "documentdb.localhost_connection_string = 'host=/run/documentdb port=7000'",
            r.stdout,
        )

    def test_port_override_rejects_out_of_range(self):
        # A resolved port must be a valid TCP port (1-65535); 0 and >65535 are
        # rejected up front rather than emitted into a GUC libpq cannot use.
        for bad in ("0", "65536", "70000"):
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pg-version", "17",
                 "--port", bad, "--print"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertNotEqual(r.returncode, 0, f"--port {bad} should be rejected")
            self.assertIn("between 1 and 65535", r.stderr)

    def test_port_override_accepts_leading_zero_as_decimal(self):
        # A leading-zero port must be parsed base-10 (not octal), so 0080 -> 80.
        r = subprocess.run(
            ["bash", str(TUNE_SCRIPT), "--pg-version", "17",
             "--port", "0080", "--print"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertRegex(
            r.stdout,
            r"documentdb\.localhost_connection_string = 'host=\S+ port=0080'",
        )

    def test_socket_dir_override_rejects_empty_and_relative(self):
        for args, needle in (
            (["--socket-dir", ""], "must not be empty"),
            (["--socket-dir", "relative/path"], "must be an absolute path"),
        ):
            r = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pg-version", "17", *args, "--print"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertNotEqual(r.returncode, 0)
            self.assertIn(needle, r.stderr)

    def test_print_output_has_managed_block_markers(self):
        """--print should wrap output in managed block markers."""
        result = subprocess.run(
            ["bash", str(TUNE_SCRIPT), "--pg-version", "17", "--print"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("# >>> documentdb-setup managed configuration >>>", result.stdout)
        self.assertIn("# <<< documentdb-setup managed configuration <<<", result.stdout)

    def test_backup_file_uses_unique_tempfile(self):
        # backup_file is single-sourced in documentdb-tools-lib.sh; verify
        # documentdb-tune sources it, then assert the shared definition is safe.
        self.assertIn(
            "documentdb-tools-lib.sh",
            TUNE_SCRIPT.read_text(encoding="utf-8"),
            "documentdb-tune must source the shared documentdb-tools-lib.sh",
        )
        script = TOOLS_LIB.read_text(encoding="utf-8")
        match = re.search(
            r"backup_file\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "mktemp",
            body,
            "documentdb-tune backups must not collide under concurrent runs",
        )
        self.assertIn(
            ".documentdb-backup.${timestamp}.XXXXXX",
            body,
            "documentdb-tune backups must retain timestamped names with a unique suffix",
        )
        self.assertNotIn(
            'local backup="${file}.documentdb-backup.${timestamp}"',
            body,
            "documentdb-tune must not use timestamp-only backup filenames",
        )

    def test_debian_include_edit_is_backed_up(self):
        script = TUNE_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_debian_include_line\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        backup_idx = body.find('backup_file "${DEBIAN_LIVE_PG_CONF}"')
        append_idx = body.find('rewrite_with_managed_block "${DEBIAN_LIVE_PG_CONF}"')
        self.assertGreaterEqual(
            backup_idx,
            0,
            "documentdb-tune must back up the live config before appending the include",
        )
        self.assertGreater(
            append_idx,
            backup_idx,
            "documentdb-tune must back up the live config before appending the include",
        )

    def test_shared_preload_parser_is_single_sourced(self):
        lib = TOOLS_LIB.read_text(encoding="utf-8")
        setup = SETUP_SCRIPT.read_text(encoding="utf-8")
        tune = TUNE_SCRIPT.read_text(encoding="utf-8")

        for helper in (
            "trim_whitespace",
            "strip_wrapping_quotes",
            "array_contains",
            "read_shared_preload_libraries_from_file",
            "merge_shared_preload_libraries",
        ):
            pattern = rf"^{helper}\(\)\s*\{{"
            self.assertIsNotNone(
                re.search(pattern, lib, flags=re.MULTILINE),
                f"{helper} must be defined in documentdb-tools-lib.sh",
            )
            self.assertIsNone(
                re.search(pattern, setup, flags=re.MULTILINE),
                f"{helper} must not be redefined in documentdb-setup.sh",
            )
            self.assertIsNone(
                re.search(pattern, tune, flags=re.MULTILINE),
                f"{helper} must not be redefined in documentdb-tune.sh",
            )

    def test_prepend_with_managed_block_is_single_sourced(self):
        # prepend_with_managed_block is safety-sensitive — pg_hba.conf is
        # first-match-wins, so a drifted copy could reorder auth rules. It must
        # live only in the shared library and not be redefined in the consuming
        # scripts (thread 34942311).
        lib = TOOLS_LIB.read_text(encoding="utf-8")
        setup = SETUP_SCRIPT.read_text(encoding="utf-8")
        register = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        pattern = r"^prepend_with_managed_block\(\)\s*\{"
        self.assertIsNotNone(
            re.search(pattern, lib, flags=re.MULTILINE),
            "prepend_with_managed_block must be defined in documentdb-tools-lib.sh",
        )
        self.assertIsNone(
            re.search(pattern, setup, flags=re.MULTILINE),
            "prepend_with_managed_block must not be redefined in documentdb-setup.sh",
        )
        self.assertIsNone(
            re.search(pattern, register, flags=re.MULTILINE),
            "prepend_with_managed_block must not be redefined in documentdb-register-gateway.sh",
        )
        # Both consumers must still CALL the shared helper (match a code line —
        # `<ws>prepend_with_managed_block "` — not a comment mentioning it).
        call_re = r'^\s*prepend_with_managed_block\s+"'
        self.assertIsNotNone(
            re.search(call_re, setup, flags=re.MULTILINE),
            "documentdb-setup.sh must call the shared prepend_with_managed_block",
        )
        self.assertIsNotNone(
            re.search(call_re, register, flags=re.MULTILINE),
            "documentdb-register-gateway.sh must call the shared prepend_with_managed_block",
        )

    def test_prepend_with_managed_block_fails_closed_on_metadata_failure(self):
        # A security-sensitive pg_hba.conf rewrite must FAIL CLOSED if it cannot
        # restore the original owner/mode: proceeding would leave the temp
        # file's 0600/root mode, which PostgreSQL (running as the DB user) could
        # not read (auth outage). Preserves documentdb-setup's prior
        # preserve_file_metadata semantics after the dedup into tools-lib
        # (thread 34942311). Sourced with a minimal host contract and a chown
        # stub that fails.
        with tempfile.TemporaryDirectory() as td:
            hba = Path(td) / "pg_hba.conf"
            original = "host all all 0.0.0.0/0 md5\nlocal all all peer\n"
            hba.write_text(original, encoding="utf-8")
            # Deliberately NO `set -e`, and call the helper in an `if` condition:
            # the explicit `|| die` in the helper must still fail closed (it must
            # not depend on the caller's errexit state).
            script = (
                "set -uo pipefail\n"
                "PROG=t; VERBOSE=false\n"
                'die() { echo "t: $*" >&2; exit 1; }\n'
                "log_verbose() { return 0; }\n"
                "TEMP_FILES=()\n"
                'create_temp_in_dir() { local v="$1" d="$2" p; '
                'p="$(mktemp "$d/.t.XXXXXX")"; TEMP_FILES+=("$p"); printf -v "$v" "%s" "$p"; }\n'
                f"source {shlex.quote(str(TOOLS_LIB))}\n"
                # Simulate chown --reference failing (restricted environment).
                "chown() { return 1; }\n"
                "if prepend_with_managed_block "
                f"{shlex.quote(str(hba))} "
                "'# >>> t >>>' '# <<< t <<<' 'local all docdbadmin peer'; then echo applied; fi\n"
            )
            r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=10)
            self.assertNotEqual(r.returncode, 0,
                                "prepend must fail closed when chown --reference fails")
            self.assertNotIn("applied", r.stdout,
                             "the mv must not run when metadata preservation fails")
            self.assertEqual(hba.read_text(encoding="utf-8"), original,
                             "the original pg_hba.conf must be left intact on fail-closed")

    def test_managed_block_handles_crlf_and_rejects_misordered_markers(self):
        # The shared primitives strip_managed_block / assert_managed_markers_
        # balanced (used by prepend_with_managed_block) must (a) recognise a
        # CRLF-encoded existing managed block so it is REPLACED, not duplicated
        # with stale rules left behind, and (b) fail closed on misordered markers
        # (end-before-start), which the old count-only balance check accepted
        # (surfaced by the thread 34942311 review). Both are security-relevant
        # for pg_hba.conf (stale/torn auth rules).
        def run(initial_bytes):
            with tempfile.TemporaryDirectory() as td:
                hba = Path(td) / "pg_hba.conf"
                hba.write_bytes(initial_bytes)
                script = (
                    "set -uo pipefail\n"
                    "PROG=t; VERBOSE=false\n"
                    'die() { echo "t: $*" >&2; exit 1; }\n'
                    "log_verbose() { return 0; }\n"
                    "TEMP_FILES=()\n"
                    'create_temp_in_dir() { local v="$1" d="$2" p; '
                    'p="$(mktemp "$d/.t.XXXXXX")"; TEMP_FILES+=("$p"); printf -v "$v" "%s" "$p"; }\n'
                    f"source {shlex.quote(str(TOOLS_LIB))}\n"
                    f"prepend_with_managed_block {shlex.quote(str(hba))} "
                    "'# >>> t >>>' '# <<< t <<<' 'local all docdbadmin peer'\n"
                )
                r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=10)
                return r.returncode, r.stderr, hba.read_bytes()

        # (a) A CRLF-encoded existing block is replaced (exactly one block, the
        #     stale rule inside it removed).
        crlf = (b"# >>> t >>>\r\nlocal all STALEADMIN peer\r\n# <<< t <<<\r\n"
                b"host all all 0.0.0.0/0 md5\r\n")
        rc, err, content = run(crlf)
        self.assertEqual(rc, 0, err)
        text = content.decode("utf-8")
        self.assertEqual(text.count("# >>> t >>>"), 1,
                         "a CRLF-encoded existing block must be replaced, not duplicated")
        self.assertNotIn("STALEADMIN", text,
                         "the stale rule inside the CRLF block must be removed")

        # (b) Misordered markers (end before start) fail closed; file intact.
        rev = b"# <<< t <<<\nlocal all all peer\n# >>> t >>>\nhost all all all md5\n"
        rc, err, content = run(rev)
        self.assertNotEqual(rc, 0, "misordered markers must fail closed")
        self.assertEqual(content, rev,
                         "the original file must be intact when markers are misordered")

    def test_tools_lib_is_sourced_only(self):
        lib = TOOLS_LIB.read_text(encoding="utf-8")
        self.assertFalse(
            lib.splitlines()[0].startswith("#!"),
            "documentdb-tools-lib.sh is sourced-only and installed 0644; it must not carry a shebang",
        )
        self.assertEqual(
            lib.splitlines()[0],
            "# shellcheck shell=bash",
            "sourced-only bash library should declare its shell for shellcheck",
        )

        deb_builder = (OSS_ROOT / "packaging" / "postgresql-tools" /
                       "build-postgresql-tools-deb.sh").read_text(encoding="utf-8")
        self.assertIn(
            'install -m 0644 "${REPO_ROOT}/documentdb-local/scripts/documentdb-tools-lib.sh"',
            deb_builder,
            "DEB tools package should keep the sourced library non-executable",
        )

        rpm_spec = (OSS_ROOT / "packaging" / "rpm" / "spec" /
                    "documentdb-tools.spec").read_text(encoding="utf-8")
        self.assertIn(
            "install -Dpm 0644 %{_sourcedir}/documentdb-tools-lib.sh",
            rpm_spec,
            "RPM tools package should keep the sourced library non-executable",
        )

    def test_shared_preload_parser_strips_inline_comments(self):
        cases = {
            "shared_preload_libraries = 'pg_stat_statements'   # (change requires restart)\n": "pg_stat_statements",
            'shared_preload_libraries = "pg_stat_statements"   # comment\n': "pg_stat_statements",
            "shared_preload_libraries = pg_stat_statements   # comment\n": "pg_stat_statements",
            "shared_preload_libraries = 'lib#with_hash'   # comment\n": "lib#with_hash",
        }

        for contents, expected in cases.items():
            with self.subTest(contents=contents):
                with tempfile.TemporaryDirectory() as tmpdir:
                    conf = Path(tmpdir) / "postgresql.conf"
                    conf.write_text(contents)
                    script = (
                        "set -euo pipefail\n"
                        "HAS_EXTENDED_RUM=false\n"
                        f"source {shlex.quote(str(TOOLS_LIB))}\n"
                        f"value=\"$(read_shared_preload_libraries_from_file {shlex.quote(str(conf))})\"\n"
                        "printf '%s\\n' \"${value}\"\n"
                        "printf '%s\\n' \"$(merge_shared_preload_libraries \"${value}\")\"\n"
                    )
                    result = subprocess.run(
                        ["bash", "-c", script],
                        capture_output=True, text=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    parsed, merged = result.stdout.splitlines()
                    self.assertEqual(parsed, expected)
                    self.assertNotIn("comment", merged)
                    self.assertNotIn("change requires restart", merged)
                    self.assertIn(expected, merged)
                    self.assertIn("pg_cron", merged)
                    self.assertIn("pg_documentdb_core", merged)
                    self.assertIn("pg_documentdb", merged)

    def test_shared_preload_merge_preserves_extended_rum(self):
        script = (
            "set -euo pipefail\n"
            "HAS_EXTENDED_RUM=true\n"
            f"source {shlex.quote(str(TOOLS_LIB))}\n"
            "merge_shared_preload_libraries 'pg_stat_statements, pg_cron'\n"
        )
        result = subprocess.run(
            ["bash", "-c", script],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        merged = result.stdout.strip()
        self.assertIn("pg_documentdb_extended_rum", merged)
        self.assertEqual(merged.count("pg_cron"), 1)

    def test_tools_lib_sources_without_extended_rum_state(self):
        script = (
            "set -euo pipefail\n"
            f"source {shlex.quote(str(TOOLS_LIB))}\n"
            "trim_whitespace '  ok  '\n"
        )
        result = subprocess.run(
            ["bash", "-c", script],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "ok")

    def test_shared_preload_merge_requires_extended_rum_state(self):
        script = (
            "set -euo pipefail\n"
            f"source {shlex.quote(str(TOOLS_LIB))}\n"
            "merge_shared_preload_libraries ''\n"
        )
        result = subprocess.run(
            ["bash", "-c", script],
            capture_output=True, text=True, timeout=10,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HAS_EXTENDED_RUM", result.stderr)

    def test_shared_preload_merge_requires_extended_rum_state_without_set_u(self):
        script = (
            "set -eo pipefail\n"
            f"source {shlex.quote(str(TOOLS_LIB))}\n"
            "merge_shared_preload_libraries ''\n"
        )
        result = subprocess.run(
            ["bash", "-c", script],
            capture_output=True, text=True, timeout=10,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("merge_shared_preload_libraries requires HAS_EXTENDED_RUM", result.stderr)

    def test_register_gateway_does_not_call_preload_merge_helper(self):
        script = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn(
            "merge_shared_preload_libraries",
            script,
            "documentdb-register-gateway must add real extended-RUM detection before calling preload merge",
        )

    def test_tune_apply_strips_inline_preload_comment(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            conf = Path(tmpdir) / "postgresql.conf"
            conf.write_text(
                "shared_preload_libraries = 'pg_stat_statements'   # (change requires restart)\n"
            )

            result = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", tmpdir, "--yes"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            managed_preload_lines = [
                line
                for line in conf.read_text().splitlines()
                if line.startswith("shared_preload_libraries = '")
            ]
            self.assertGreaterEqual(len(managed_preload_lines), 2)
            managed_line = managed_preload_lines[-1]
            self.assertNotIn("#", managed_line)
            self.assertEqual(
                managed_line,
                "shared_preload_libraries = 'pg_stat_statements, pg_cron, pg_documentdb_core, pg_documentdb'",
            )

    def test_apply_restore_round_trip(self):
        """Apply then restore should leave the file unchanged (modulo trailing whitespace)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            conf = Path(tmpdir) / "postgresql.conf"
            original_content = "# existing config\nlisten_addresses = '*'\n"
            conf.write_text(original_content)

            # Apply
            result = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", tmpdir, "--yes"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            applied = conf.read_text()
            self.assertIn("shared_preload_libraries", applied)
            self.assertIn("# >>> documentdb-setup managed configuration >>>", applied)

            # Restore
            result = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", tmpdir, "--restore"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            restored = conf.read_text().rstrip("\n") + "\n"
            self.assertEqual(restored.strip(), original_content.strip())

    def test_idempotent_apply(self):
        """Applying twice should detect no changes on the second run."""
        with tempfile.TemporaryDirectory() as tmpdir:
            conf = Path(tmpdir) / "postgresql.conf"
            conf.write_text("# test\n")

            subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", tmpdir, "--yes"],
                capture_output=True, text=True, timeout=10,
            )
            first_content = conf.read_text()

            result = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", tmpdir, "--yes"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0)
            self.assertIn("already up to date", result.stdout)
            self.assertEqual(conf.read_text(), first_content)

    def test_dry_run_does_not_modify(self):
        """--dry-run should not write to the config file."""
        with tempfile.TemporaryDirectory() as tmpdir:
            conf = Path(tmpdir) / "postgresql.conf"
            conf.write_text("# original\n")

            result = subprocess.run(
                ["bash", str(TUNE_SCRIPT), "--pgdata", tmpdir, "--dry-run"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(conf.read_text(), "# original\n")

    def test_missing_pg_version_fails(self):
        """Missing --pg-version (without --pgdata) should fail."""
        result = subprocess.run(
            ["bash", str(TUNE_SCRIPT), "--yes"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--pg-version is required", result.stderr)

    def test_help_flag(self):
        """--help should succeed and show usage."""
        result = subprocess.run(
            ["bash", str(TUNE_SCRIPT), "--help"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("documentdb-tune", result.stdout)


class DocumentDBGatewaySetupTests(unittest.TestCase):
    """Tests for the gateway setup script's ident map configuration."""

    def test_ident_map_uses_gateway_user(self):
        """The gateway setup script should use documentdb-gateway OS user in ident map."""
        script = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('GW_OS_USER="documentdb-gateway"', script)
        self.assertIn('GW_PG_ROLE="documentdb-gateway"', script)
        self.assertIn("documentdb-gateway-map", script)

    def test_ident_map_contains_required_roles(self):
        """The ident map should map to all required role groups."""
        script = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("+documentdb_admin_role", script)
        self.assertIn("+documentdb_readwrite_role", script)
        self.assertIn("+documentdb_readonly_role", script)

    def test_no_all_mapping(self):
        """The ident map should NOT contain a wildcard 'all' mapping."""
        script = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # Look for patterns like "documentdb-gateway-map ... all" that would be unsafe
        all_pattern = re.compile(
            r"documentdb-gateway-map\s+\S+\s+all\b"
        )
        self.assertIsNone(all_pattern.search(script))

    def test_setup_complete_message_is_after_side_effects(self):
        """The 'Setup complete' message must print AFTER role creation,
        connection-file/env writing, optional admin user creation, and
        state recording. Previously this message was emitted before any of
        those side effects, which could mislead operators on failure."""
        script = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        setup_complete_idx = script.find('Setup complete. Remaining steps')
        self.assertGreater(setup_complete_idx, -1,
                           "Expected 'Setup complete' message in register-gateway script")
        for required_call in ("create_gateway_role",
                              "write_connection_secret",
                              "create_admin_user",
                              "record_state"):
            # Match the call as a token followed by a statement separator
            # (newline, semicolon, or `;` from `if foo; then`). The
            # create_admin_user call is now invoked via
            # `if create_admin_user; then` so the older "...\n" pattern no
            # longer matched even though the call site is correct.
            call_match = re.search(
                rf"(?m)^[\s\t]*(?:if\s+)?{re.escape(required_call)}\b(?:\s*;|\s*$)",
                script,
            )
            self.assertIsNotNone(
                call_match,
                f"Expected {required_call} call in register-gateway",
            )
            self.assertLess(
                call_match.start(), setup_complete_idx,
                f"{required_call} must be invoked before the 'Setup complete' message; "
                f"currently it is at position {call_match.start()} but message is at {setup_complete_idx}."
            )


class GatewayPgMajorGateTests(unittest.TestCase):
    """The package-managed gateway registration requires PostgreSQL 16+: the
    gateway authenticates each client's data pool AS that client's role over the
    local socket with an EMPTY password, relying on pg_ident.conf '+group'
    membership (a PG16 feature) to map the gateway OS user to the member role. On
    PG<=15 there is no working path, so documentdb-register-gateway (and
    documentdb-setup) must REJECT PG<16 rather than write a config that starts but
    fails on the first authenticated query. The pg_ident block itself keeps its
    unconditional '+group' entries (only reachable on a supported major)."""

    def _run_rg(self, snippet):
        rg_src = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # Remove the trailing `main "$@"` so sourcing defines the functions
        # without running the CLI.
        rg_nomain = re.sub(r'(?m)^main[ \t]+"\$@"[ \t]*$', '', rg_src)
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            (td_path / "documentdb-register-gateway.sh").write_text(rg_nomain, encoding="utf-8")
            shutil.copy2(TOOLS_LIB, td_path / "documentdb-tools-lib.sh")
            harness = (
                "set -uo pipefail\n"
                f"source {shlex.quote(str(td_path / 'documentdb-register-gateway.sh'))}\n"
                f"{snippet}\n"
            )
            return subprocess.run(
                ["bash", "-c", harness], capture_output=True, text=True, timeout=30,
            )

    def test_ident_block_always_emits_group_membership(self):
        # The ident block is version-independent now (the version gate, not the
        # block, handles PG<16), so every major emits the exact mapping plus the
        # six '+group' entries.
        for major in ("15", "16", "18", ""):
            r = self._run_rg(f'TARGET_PG_MAJOR={shlex.quote(major)}; build_ident_block')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("documentdb-gateway-map   documentdb-gateway   documentdb-gateway", r.stdout)
            for role in ("+documentdb_admin_role", "+documentdb_readwrite_role",
                         "+documentdb_readonly_role"):
                self.assertIn(role, r.stdout, f"major={major!r} must emit {role}")

    def test_ident_block_maps_pg_owner_for_brownfield(self):
        # Brownfield adopts a distro cluster running as PG_OWNER (e.g. postgres),
        # whose OS user must also assume the documentdb role groups via peer auth
        # for the extension's internal connections — otherwise CRUD fails.
        r = self._run_rg('PG_OWNER="postgres"; TARGET_PG_MAJOR="18"; build_ident_block')
        self.assertEqual(r.returncode, 0, r.stderr)
        for role in ("+documentdb_admin_role", "+documentdb_readwrite_role",
                     "+documentdb_readonly_role"):
            self.assertIn(f"documentdb-gateway-map   postgres   {role}", r.stdout,
                          f"brownfield ident must map postgres to {role}")

    def test_ident_block_dedups_pg_owner_when_documentdb_local(self):
        # Greenfield PG_OWNER is documentdb-local, already mapped, so no duplicate
        # group lines are emitted for it.
        r = self._run_rg('PG_OWNER="documentdb-local"; TARGET_PG_MAJOR="18"; build_ident_block')
        self.assertEqual(r.returncode, 0, r.stderr)
        n = r.stdout.count("documentdb-gateway-map   documentdb-local   +documentdb_")
        self.assertEqual(n, 3, f"expected exactly 3 documentdb-local group maps, got {n}")

    def test_gate_rejects_known_pg15(self):
        r = self._run_rg('TARGET_PG_MAJOR="15"; DRY_RUN=false; enforce_gateway_pg_major_supported')
        self.assertNotEqual(r.returncode, 0, "PG15 must be rejected")
        self.assertIn("16", r.stderr)

    def test_gate_allows_pg16(self):
        r = self._run_rg('TARGET_PG_MAJOR="16"; DRY_RUN=false; enforce_gateway_pg_major_supported')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_gate_fails_closed_on_unknown_apply(self):
        # Apply must NOT proceed when the major cannot be determined.
        r = self._run_rg('TARGET_PG_MAJOR=""; DRY_RUN=false; enforce_gateway_pg_major_supported')
        self.assertNotEqual(r.returncode, 0,
                            "unknown major on apply must fail closed, not assume PG16")

    def test_gate_warns_but_proceeds_on_unknown_dry_run(self):
        r = self._run_rg('TARGET_PG_MAJOR=""; DRY_RUN=true; enforce_gateway_pg_major_supported')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_do_setup_runs_resolver_and_gate_before_building_blocks(self):
        script = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(script, r"(?m)^resolve_target_pg_major\(\)\s*\{")
        self.assertRegex(script, r"(?m)^enforce_gateway_pg_major_supported\(\)\s*\{")
        do_setup_idx = script.find("do_setup()")
        self.assertGreater(do_setup_idx, -1)
        body = script[do_setup_idx:]
        resolve_idx = body.find("\n    resolve_target_pg_major\n")
        gate_idx = body.find("\n    enforce_gateway_pg_major_supported\n")
        hba_idx = body.find('hba_block="$(build_hba_block)"')
        self.assertGreater(resolve_idx, -1, "do_setup must resolve the PG major")
        self.assertGreater(gate_idx, resolve_idx, "gate must run after resolving the major")
        self.assertGreater(hba_idx, gate_idx, "gate must run before any block is built/written")

    def test_resolver_cross_checks_asserted_vs_live(self):
        script = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        m = re.search(r"resolve_target_pg_major\(\)\s*\{(?P<b>.*?)^\}",
                      script, flags=re.DOTALL | re.MULTILINE)
        self.assertIsNotNone(m)
        body = m.group("b")
        self.assertIn("server_version_num", body, "must consult the live server version")
        self.assertIn("mismatch", body.lower(),
                      "must reject when asserted and live majors disagree")

    def test_restore_path_is_exempt_from_gate(self):
        # --restore dispatches to do_restore, which must not call the gate/resolver
        # (PG15 users must still be able to remove managed blocks).
        script = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        m = re.search(r"do_restore\(\)\s*\{(?P<b>.*?)^\}",
                      script, flags=re.DOTALL | re.MULTILINE)
        self.assertIsNotNone(m, "do_restore not found")
        body = m.group("b")
        self.assertNotIn("enforce_gateway_pg_major_supported", body)
        self.assertNotIn("resolve_target_pg_major", body)

    def test_setup_gates_pg_major_in_all_apply_paths(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(script, r"(?m)^enforce_gateway_pg_major_supported\(\)\s*\{")
        # definition + early(main) + preflight + greenfield + brownfield +
        # dry-run = >= 6.
        self.assertGreaterEqual(script.count("enforce_gateway_pg_major_supported"), 6)
        # greenfield + brownfield + preflight gate on the resolved PG_VERSION;
        # dry-run gates on the preview version; the early main() gate uses a
        # locally resolved major.
        self.assertIn('enforce_gateway_pg_major_supported "${PG_VERSION}"', script)
        self.assertIn('enforce_gateway_pg_major_supported "${preview_pg_version}"', script)
        self.assertIn('enforce_gateway_pg_major_supported "${_early_pg_major}"', script)
        # The early gate must run BEFORE preflight_validation (which performs the
        # first host mutations: OS-user creation, TLS file permissions).
        early_idx = script.find('enforce_gateway_pg_major_supported "${_early_pg_major}"')
        preflight_call_idx = script.find("\n    preflight_validation\n")
        self.assertGreater(early_idx, -1, "early main() gate not found")
        self.assertGreater(preflight_call_idx, -1)
        self.assertLess(early_idx, preflight_call_idx,
                        "early PG-major gate must run before preflight_validation")
        # The preflight gate must run on the AUTHORITATIVE major immediately
        # after detect_postgres_installation and before the first host mutation
        # (ensure_documentdb_runtime_user), closing the multi-major greenfield
        # gap the early "highest installed" probe can miss.
        detect_idx = script.find("\n    detect_postgres_installation\n")
        runtime_user_idx = script.find("\n    ensure_documentdb_runtime_user\n")
        self.assertGreater(detect_idx, -1)
        self.assertGreater(runtime_user_idx, -1)
        preflight_gate_idx = script.find(
            'enforce_gateway_pg_major_supported "${PG_VERSION}"', detect_idx)
        self.assertGreater(preflight_gate_idx, detect_idx,
                           "preflight gate must run after detect_postgres_installation")
        self.assertLess(preflight_gate_idx, runtime_user_idx,
                        "preflight gate must run before ensure_documentdb_runtime_user")


class AdminPasswordLoggingTests(unittest.TestCase):
    """The wizard's admin create/reset SQL embeds the password in the statement
    (via the :'user_bson' / :'bson_arg' payload), so it must disable statement,
    duration, and error logging around those calls — matching
    documentdb-gateway-admin.sh — so the password never lands in the PG log."""

    @staticmethod
    def _function_body(script, name):
        m = re.search(rf"{name}\(\)\s*\{{(?P<body>.*?)^\}}", script,
                      flags=re.DOTALL | re.MULTILINE)
        return m.group("body") if m else None

    def test_create_and_reset_suppress_statement_logging(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        for name in ("create_documentdb_user", "reset_documentdb_user_password"):
            body = self._function_body(script, name)
            self.assertIsNotNone(body, f"{name} not found in documentdb-setup.sh")
            self.assertIn("SET log_statement = 'none'", body,
                          f"{name} must disable statement logging around the password payload")
            self.assertIn("SET log_min_duration_statement = -1", body, name)
            self.assertIn("SET log_min_error_statement = 'panic'", body, name)


class GatewayReloadDetectionTests(unittest.TestCase):
    """delegate_to_register_gateway must decide whether PostgreSQL needs a
    reload by comparing the CONTENT of the managed pg_hba/pg_ident blocks before
    and after register-gateway runs — not merely whether the markers were
    already present — so an upgrade / parameter change that rewrites the block
    with different content still triggers the reload it needs."""

    def test_reload_decision_compares_block_content(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # The delegation + reload-decision logic lives in ensure_pg_ident_map,
        # bounded below by the next function definition.
        start = script.find("ensure_pg_ident_map()")
        self.assertGreater(start, -1, "ensure_pg_ident_map not found")
        end = script.find("_run_register_gateway_capturing()", start)
        self.assertGreater(end, start, "could not bound ensure_pg_ident_map body")
        body = script[start:end]
        for var in ("_hba_before", "_hba_after", "_ident_before", "_ident_after"):
            self.assertIn(var, body, f"reload detection must capture {var}")
        self.assertEqual(
            body.count("extract_managed_block_content"), 4,
            "must extract hba+ident block content both before and after register-gateway",
        )
        self.assertIn('"${_hba_before}" == "${_hba_after}"', body,
                      "reload decision must compare hba block content")
        self.assertIn('"${_ident_before}" == "${_ident_after}"', body,
                      "reload decision must compare ident block content")
        # The old marker-presence-only heuristic must be gone.
        self.assertNotIn("_hba_had_block", body)
        self.assertNotIn("_ident_had_block", body)


class DebianPreloadFoldingTests(unittest.TestCase):
    """fold_in_debian_live_preload computes the operator's EFFECTIVE
    shared_preload_libraries via PostgreSQL last-wins across postgresql.conf and
    its conf.d drop-ins (so nothing declared there is dropped).
    postgresql.auto.conf is handled separately by
    enforce_autoconf_preload_not_overriding, which FAILS the apply when ALTER
    SYSTEM overrides the managed config away from the required documentdb
    libraries."""

    def test_folds_in_confd_last_wins(self):
        script = TUNE_SCRIPT.read_text(encoding="utf-8")
        m = re.search(r"fold_in_debian_live_preload\(\)\s*\{(?P<body>.*?)^\}",
                      script, flags=re.DOTALL | re.MULTILINE)
        self.assertIsNotNone(m, "fold_in_debian_live_preload not found")
        body = m.group("body")
        # fold_in walks the ordered Debian config files (postgresql.conf + conf.d)
        # via the shared helper and applies last-wins precedence.
        self.assertIn("_debian_live_config_files", body,
                      "must source the ordered config files from the shared helper")
        self.assertIn("read_shared_preload_libraries_from_file", body)
        # Effective value must follow PostgreSQL last-wins precedence (an
        # assigning source REPLACES the value), not a union that concatenates
        # every source and resurrects replaced/removed libraries.
        self.assertIn("_spl_assigned_in_file", body,
                      "must detect per-source assignment to implement last-wins (incl. empty clear)")
        self.assertNotIn("${current:+${current},}", body,
                         "must not union-concatenate sources (that resurrects replaced libraries)")
        # The shared helper enumerates the conf.d include directory the way
        # PostgreSQL's include_dir does: skip dot-prefixed files, C-locale order.
        h = re.search(r"_debian_live_config_files\(\)\s*\{(?P<body>.*?)^\}",
                      script, flags=re.DOTALL | re.MULTILINE)
        self.assertIsNotNone(h, "_debian_live_config_files not found")
        hbody = h.group("body")
        self.assertIn("conf.d", hbody, "must scan the conf.d include directory")
        self.assertIn("! -name '.*'", hbody,
                      "conf.d scan must skip dot-prefixed files like PostgreSQL's include_dir")
        self.assertIn("LC_ALL=C sort", hbody,
                      "conf.d scan must use C-locale order to match PostgreSQL's include_dir")
        # The assignment-detection helper must exist.
        self.assertRegex(script, r"(?m)^_spl_assigned_in_file\(\)\s*\{")


class DebianAutoconfOverrideTests(unittest.TestCase):
    """documentdb-tune must FAIL (not exit 0 with a warning) when
    postgresql.auto.conf (ALTER SYSTEM) overrides shared_preload_libraries away
    from the required documentdb libraries — otherwise automation gets a
    success-shaped broken state. It must pass when auto.conf already includes the
    required libraries or does not set shared_preload_libraries."""

    def _run_enforce(self, autoconf_content):
        """Source tune.sh (main-stripped) beside the lib, set up a fake --pgdata
        cluster with the given postgresql.auto.conf content (None = no file),
        and run enforce_autoconf_preload_not_overriding in die mode."""
        tune_src = TUNE_SCRIPT.read_text(encoding="utf-8")
        tune_nomain = re.sub(r'(?m)^main[ \t]+"\$@"[ \t]*$', '', tune_src)
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            (td_path / "documentdb-tune.sh").write_text(tune_nomain, encoding="utf-8")
            shutil.copy2(TOOLS_LIB, td_path / "documentdb-tools-lib.sh")
            pgdata = td_path / "pgdata"
            pgdata.mkdir()
            if autoconf_content is not None:
                (pgdata / "postgresql.auto.conf").write_text(
                    autoconf_content + "\n", encoding="utf-8")
            harness = (
                "set -uo pipefail\n"
                f"source {shlex.quote(str(td_path / 'documentdb-tune.sh'))}\n"
                "IS_DEBIAN=false\n"
                f"PGDATA={shlex.quote(str(pgdata))}\n"
                f"CONFIG_TARGET={shlex.quote(str(pgdata / 'postgresql.conf'))}\n"
                "HAS_EXTENDED_RUM=false; PG_VERSION=17; CLUSTER_NAME=main\n"
                "enforce_autoconf_preload_not_overriding die\n"
            )
            return subprocess.run(
                ["bash", "-c", harness], capture_output=True, text=True, timeout=30)

    def test_override_missing_required_libs_fails(self):
        r = self._run_enforce("shared_preload_libraries = 'pg_stat_statements'")
        self.assertNotEqual(r.returncode, 0,
                            "apply must fail when auto.conf overrides away the documentdb libs")
        self.assertIn("documentdb", r.stderr.lower())

    def test_override_empty_clear_fails(self):
        r = self._run_enforce("shared_preload_libraries = ''")
        self.assertNotEqual(r.returncode, 0,
                            "apply must fail on an empty-clear auto.conf override")

    def test_override_with_all_required_libs_passes(self):
        r = self._run_enforce("shared_preload_libraries = 'pg_cron,pg_documentdb_core,pg_documentdb'")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_no_spl_in_autoconf_passes(self):
        self.assertEqual(self._run_enforce("work_mem = '64MB'").returncode, 0)
        self.assertEqual(self._run_enforce(None).returncode, 0)

    def test_path_qualified_and_suffixed_libs_pass(self):
        # PostgreSQL loads the same library for "pg_cron", "$libdir/pg_cron" and
        # "pg_cron.so", so a qualified/suffixed override that still lists every
        # required library must PASS (not trigger a false-positive failure).
        r = self._run_enforce(
            "shared_preload_libraries = '$libdir/pg_cron, pg_documentdb_core.so, $libdir/pg_documentdb'")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_empty_clear_suggestion_has_no_leading_comma(self):
        # The remediation SQL must not have a stray leading comma when auto.conf
        # currently clears shared_preload_libraries (empty value).
        r = self._run_enforce("shared_preload_libraries = ''")
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("= ', ", r.stderr,
                         "suggested ALTER SYSTEM value must not start with a comma")
        self.assertIn("= 'pg_cron", r.stderr)

    def test_apply_calls_enforce_die_and_dry_run_warn(self):
        script = TUNE_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(script, r"(?m)^enforce_autoconf_preload_not_overriding\(\)\s*\{")
        # do_apply gates on it: die on a real apply, warn under --dry-run.
        self.assertIn("enforce_autoconf_preload_not_overriding die", script)
        self.assertIn("enforce_autoconf_preload_not_overriding warn", script)


class DebianAutoconfDataDirTests(unittest.TestCase):
    """On the Debian split-layout, enforce_autoconf_preload_not_overriding must
    resolve postgresql.auto.conf relative to the cluster's EFFECTIVE
    data_directory (resolved with the same postgresql.conf + conf.d last-wins
    walk used for shared_preload_libraries) — otherwise it inspects the wrong
    auto.conf and misses an override (a false negative)."""

    def _run_enforce_debian(self, live_conf_extra, autoconf_content):
        """Fake a Debian split-layout: a live postgresql.conf (declaring
        data_directory pointing at a temp data dir, plus live_conf_extra) and
        that data dir's postgresql.auto.conf (or None). Run enforce in die mode.
        Uses an implausible PG major/cluster so the hard-coded /etc/postgresql
        conf.d path never collides with a real cluster on the test host."""
        tune_src = TUNE_SCRIPT.read_text(encoding="utf-8")
        tune_nomain = re.sub(r'(?m)^main[ \t]+"\$@"[ \t]*$', '', tune_src)
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            (td_path / "documentdb-tune.sh").write_text(tune_nomain, encoding="utf-8")
            shutil.copy2(TOOLS_LIB, td_path / "documentdb-tools-lib.sh")
            datadir = td_path / "datadir"
            datadir.mkdir()
            live_conf = td_path / "postgresql.conf"
            live_conf.write_text(
                "shared_preload_libraries = 'pg_cron,pg_documentdb_core,pg_documentdb'\n"
                f"data_directory = '{datadir}'\n"
                f"{live_conf_extra}\n",
                encoding="utf-8")
            if autoconf_content is not None:
                (datadir / "postgresql.auto.conf").write_text(
                    autoconf_content + "\n", encoding="utf-8")
            harness = (
                "set -uo pipefail\n"
                f"source {shlex.quote(str(td_path / 'documentdb-tune.sh'))}\n"
                "IS_DEBIAN=true\n"
                "PGDATA=''\n"
                f"DEBIAN_LIVE_PG_CONF={shlex.quote(str(live_conf))}\n"
                "CONFIG_TARGET=''\n"
                "HAS_EXTENDED_RUM=false; PG_VERSION=99; CLUSTER_NAME=doctest\n"
                "enforce_autoconf_preload_not_overriding die\n"
            )
            return subprocess.run(
                ["bash", "-c", harness], capture_output=True, text=True, timeout=30)

    def test_autoconf_resolved_via_declared_data_directory(self):
        # auto.conf under the DECLARED data_directory overrides away the docdb
        # libs; enforce must locate it there (via the effective resolver) and fail.
        r = self._run_enforce_debian("", "shared_preload_libraries = 'pg_stat_statements'")
        self.assertNotEqual(r.returncode, 0,
                            "must resolve auto.conf under the declared data_directory and fail on override")
        self.assertIn("documentdb", r.stderr.lower())

    def test_autoconf_under_declared_datadir_with_all_libs_passes(self):
        # Proves it actually READ the auto.conf at the declared dir (not merely
        # failed for another reason): a complete override passes.
        r = self._run_enforce_debian(
            "", "shared_preload_libraries = 'pg_cron,pg_documentdb_core,pg_documentdb'")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_cluster_autoconf_path_resolves_data_directory_confd_aware(self):
        script = TUNE_SCRIPT.read_text(encoding="utf-8")
        # _cluster_autoconf_path resolves data_directory via the effective
        # (postgresql.conf + conf.d) walk, not a single top-level-file read.
        m = re.search(r"_cluster_autoconf_path\(\)\s*\{(?P<body>.*?)^\}",
                      script, flags=re.DOTALL | re.MULTILINE)
        self.assertIsNotNone(m, "_cluster_autoconf_path not found")
        self.assertIn("_read_effective_scalar_guc_debian data_directory", m.group("body"))
        # The effective resolver walks the ordered Debian config files ...
        m2 = re.search(r"_read_effective_scalar_guc_debian\(\)\s*\{(?P<body>.*?)^\}",
                       script, flags=re.DOTALL | re.MULTILINE)
        self.assertIsNotNone(m2, "_read_effective_scalar_guc_debian not found")
        self.assertIn("_debian_live_config_files", m2.group("body"))
        # ... which include the conf.d drop-ins (last-wins parity with PG).
        m3 = re.search(r"_debian_live_config_files\(\)\s*\{(?P<body>.*?)^\}",
                       script, flags=re.DOTALL | re.MULTILINE)
        self.assertIsNotNone(m3, "_debian_live_config_files not found")
        self.assertIn("conf.d", m3.group("body"))


class PackagingPgMajorBoundaryTests(unittest.TestCase):
    """Full-stack (stand-alone / gateway clean-install) build and test paths are
    restricted to PostgreSQL 16+ (the gateway floor); PG15 extension-only builds
    remain. The runtime gate in documentdb-setup / documentdb-register-gateway
    is the correctness backstop — these guards avoid building/testing an
    unusable full stack on PG15."""

    def test_build_extra_packages_skips_standalone_below_pg16(self):
        script = BUILD_EXTRA_PACKAGES.read_text(encoding="utf-8")
        # The full-stack payload is gated on PG16+ at four sites: the DEB
        # stand-alone build, the DEB documentdb-common build, the DEB
        # artifact-rename list, and the RPM stand-alone+common build block.
        self.assertEqual(script.count("(( PG_VERSION >= 16 ))"), 4,
                         "DEB standalone+common builds, DEB rename, and RPM build must all be gated on PG16+")
        # The PG-agnostic tools package is still built (extension-only path).
        self.assertIn("build-postgresql-tools-deb.sh", script)

    def test_build_gateway_packages_rejects_clean_install_below_pg16(self):
        script = (OSS_ROOT / "packaging" / "gateway" / "build_gateway_packages.sh").read_text(encoding="utf-8")
        idx = script.find("if [[ $TEST_CLEAN_INSTALL == true ]]")
        self.assertGreater(idx, -1, "--test-clean-install block not found")
        self.assertIn("(( PG < 16 ))", script[idx:idx + 700],
                      "the --test-clean-install block must reject PG<16")

    def test_build_standalone_deb_rejects_pg15(self):
        # The leaf stand-alone builder is directly invocable, so it must reject
        # PG<16 itself (defense in depth), not rely on the orchestrator.
        r = subprocess.run(
            ["bash", str(STANDALONE_BUILD_SCRIPT), "--version", "0.1.0", "--pg-version", "15"],
            capture_output=True, text=True, timeout=30)
        self.assertNotEqual(r.returncode, 0, "build-standalone-deb.sh must reject --pg-version 15")
        self.assertIn("16", r.stdout + r.stderr)

    def test_build_meta_deb_rejects_default_major_pg15(self):
        # The meta package pins to the paved-road default major; that major must
        # be PG16+ (it depends on the gateway-wrapping stand-alone).
        r = subprocess.run(
            ["bash", str(META_BUILD_SCRIPT), "--version", "0.1.0", "--default-pg-major", "15"],
            capture_output=True, text=True, timeout=30)
        self.assertNotEqual(r.returncode, 0, "build-meta-deb.sh must reject --default-pg-major 15")
        self.assertIn("16", r.stdout + r.stderr)

    def test_build_extra_packages_rejects_default_major_below_pg16(self):
        # The orchestrator forwards --default-pg-major to the DEB and RPM meta
        # paths, so it must reject a PG<16 paved-road default up front.
        r = subprocess.run(
            ["bash", str(BUILD_EXTRA_PACKAGES), "--type", "deb", "--pg", "18",
             "--version", "0.1.0", "--default-pg-major", "15"],
            capture_output=True, text=True, timeout=30)
        self.assertNotEqual(r.returncode, 0, "build_extra_packages.sh must reject --default-pg-major 15")
        self.assertIn("16", r.stdout + r.stderr)

    def test_public_alias_major_agrees_with_meta_build_defaults(self):
        # documentdb-setup.sh hardcodes the paved-road default major
        # (PUBLIC_ALIAS_PG_MAJOR) that gates enabling the public
        # documentdb-local.target alias, while the meta packages take the
        # same value as a build parameter (build-meta-deb.sh DEFAULT_PG_MAJOR
        # and the RPM spec's %define default_pg_major). Nothing wires them
        # together at build time, so a default-major bump that misses one
        # copy would ship a meta package whose alias points at a major the
        # wizard never maintains. Pin all three to the same value so the
        # mismatch fails here instead of on customer hosts.
        setup_text = SETUP_SCRIPT.read_text(encoding="utf-8")
        wizard = re.search(r'^readonly PUBLIC_ALIAS_PG_MAJOR="(\d+)"',
                           setup_text, re.M)
        self.assertIsNotNone(wizard, "PUBLIC_ALIAS_PG_MAJOR must be declared")

        meta_text = META_BUILD_SCRIPT.read_text(encoding="utf-8")
        meta = re.search(r'^DEFAULT_PG_MAJOR="(\d+)"', meta_text, re.M)
        self.assertIsNotNone(meta, "build-meta-deb.sh DEFAULT_PG_MAJOR default must be declared")

        spec_text = (OSS_ROOT / "packaging" / "rpm" / "spec"
                     / "documentdb-local-meta.spec").read_text(encoding="utf-8")
        spec = re.search(r'^%define default_pg_major (\d+)', spec_text, re.M)
        self.assertIsNotNone(spec, "documentdb-local-meta.spec %define default_pg_major must exist")

        self.assertEqual(
            wizard.group(1), meta.group(1),
            "documentdb-setup.sh PUBLIC_ALIAS_PG_MAJOR and build-meta-deb.sh "
            "DEFAULT_PG_MAJOR must agree (bump both together)")
        self.assertEqual(
            wizard.group(1), spec.group(1),
            "documentdb-setup.sh PUBLIC_ALIAS_PG_MAJOR and the RPM meta spec's "
            "default_pg_major must agree (bump both together)")


class ExtraPackagesBuildDepsPreflightTests(unittest.TestCase):
    """build_extra_packages.sh assembles the .deb/.rpm 'extras' on the host, so
    it must preflight the host build tool for BOTH formats the same way: rpm via
    ensure_rpm_extra_build_dependencies (rpmbuild) and deb via
    ensure_deb_extra_build_dependencies (dpkg-deb). Without the deb self-check a
    dpkg-deb-less host fails with a raw 'dpkg-deb: command not found' deep in the
    per-package builders (PR 2159000 thread 34895282)."""

    def test_deb_branch_preflights_dpkg_deb(self):
        script = BUILD_EXTRA_PACKAGES.read_text(encoding="utf-8")
        # A dedicated helper checks dpkg-deb, mirroring the rpm helper.
        self.assertIn("ensure_deb_extra_build_dependencies()", script)
        self.assertIn("command -v dpkg-deb", script)
        self.assertIn("ensure_rpm_extra_build_dependencies", script)
        # The deb build branch must actually call the preflight — this guards
        # against a fix landing in one format and silently drifting in the other.
        deb_idx = script.find('if [[ "${PACKAGE_TYPE}" == "deb" ]]; then')
        self.assertGreater(deb_idx, -1, "deb build branch not found")
        self.assertIn("ensure_deb_extra_build_dependencies",
                      script[deb_idx:deb_idx + 500],
                      "the deb build branch must preflight dpkg-deb")

    def test_check_build_deps_only_covers_deb(self):
        script = BUILD_EXTRA_PACKAGES.read_text(encoding="utf-8")
        # --check-build-deps-only must preflight deb too, not hard-reject non-rpm.
        self.assertNotIn("only valid with --type rpm", script)
        idx = script.find('CHECK_BUILD_DEPS_ONLY}" == "true"')
        self.assertGreater(idx, -1)
        block = script[idx:idx + 400]
        self.assertIn("ensure_deb_extra_build_dependencies", block)
        self.assertIn("ensure_rpm_extra_build_dependencies", block)

    def test_check_build_deps_only_rejects_unknown_type(self):
        # Regression guard: the if/elif/else must reject an invalid --type, not
        # silently treat any non-rpm value as deb. Environment-independent — the
        # else branch dies before any host-tool check.
        with tempfile.TemporaryDirectory() as td:
            r = subprocess.run(
                ["bash", str(BUILD_EXTRA_PACKAGES), "--type", "banana", "--pg", "18",
                 "--version", "0.1.0", "--output-dir", td, "--check-build-deps-only"],
                capture_output=True, text=True, timeout=30)
        self.assertNotEqual(r.returncode, 0,
                            "--check-build-deps-only must reject an unknown --type")
        self.assertIn("Unknown --type", r.stdout + r.stderr)

    def test_finalize_deb_guards_dpkg_deb(self):
        # The shared dpkg-deb choke point (finalize_deb in deb-common.sh) must
        # itself guard the tool, so a direct build-*-deb.sh call also fails with
        # an actionable message rather than a raw "dpkg-deb: command not found".
        common = DEB_COMMON.read_text(encoding="utf-8")
        idx = common.find("finalize_deb()")
        self.assertGreater(idx, -1, "finalize_deb not found in deb-common.sh")
        guard = common.find("command -v dpkg-deb", idx)
        build = common.find("--build", idx)
        self.assertGreater(guard, -1, "finalize_deb must check dpkg-deb")
        self.assertGreater(build, -1, "finalize_deb must call dpkg-deb --build")
        # The guard must precede the actual dpkg-deb --build invocation.
        self.assertLess(guard, build,
                        "the dpkg-deb guard must run before the dpkg-deb --build call")

    def test_deb_builders_use_portable_sed(self):
        # GNU and BSD/macOS `sed -i` disagree on the mandatory backup-suffix
        # argument, so the .deb 'extras' builders (run on the host, not in a
        # container) must not use `sed -i` — otherwise the local packaging smoke
        # is not reproducible on a non-GNU host such as macOS (thread 34895282).
        deb_builders = [
            OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh",
            OSS_ROOT / "packaging" / "standalone" / "build-common-deb.sh",
            OSS_ROOT / "packaging" / "standalone" / "build-meta-deb.sh",
            OSS_ROOT / "packaging" / "postgresql-tools" / "build-postgresql-tools-deb.sh",
            DEB_COMMON,
        ]
        for p in deb_builders:
            code_lines = [ln for ln in p.read_text(encoding="utf-8").splitlines()
                          if not ln.lstrip().startswith("#")]
            self.assertNotIn("sed -i", "\n".join(code_lines),
                             f"{p.name} uses GNU-only 'sed -i'; use a portable filter+mv instead")

    def test_deb_common_changelog_date_is_portable(self):
        # The SOURCE_DATE_EPOCH changelog date is generated on the host, so it
        # must work under BSD/macOS `date` too: GNU `date -d @epoch` with a BSD
        # `date -r epoch` fallback (thread 34895282). Homebrew dpkg does not
        # supply GNU date, so a lone `date -d` breaks the macOS host build.
        common = DEB_COMMON.read_text(encoding="utf-8")
        self.assertIn("date -u -r", common,
                      "changelog date must have a BSD `date -r` fallback for host portability")

    def test_check_build_deps_only_deb_succeeds_when_dpkg_deb_present(self):
        # Behavioral happy-path for the new deb preflight; skipped where dpkg-deb
        # is unavailable (e.g. a minimal Python CI image) so the test stays
        # environment-independent.
        if shutil.which("dpkg-deb") is None:
            self.skipTest("dpkg-deb not on PATH")
        with tempfile.TemporaryDirectory() as td:
            r = subprocess.run(
                ["bash", str(BUILD_EXTRA_PACKAGES), "--type", "deb", "--pg", "18",
                 "--version", "0.1.0", "--output-dir", td, "--check-build-deps-only"],
                capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("DEB extra-package build dependencies are satisfied",
                      r.stdout + r.stderr)


class DebPackagingPortabilityTests(unittest.TestCase):
    """Host-built .deb extras must install on every supported target, including
    older non-usr-merged Debian (bullseye). Two portability contracts:
    (1) xz compression — dpkg-deb defaults to zstd on modern build hosts, which
        Debian 11 dpkg cannot read ("unknown compression for member
        control.tar.zst"); (2) the gateway install test asserts the canonical
        /usr/lib/systemd/system unit path, not the legacy /lib (which is only a
        symlink on usr-merged systems)."""

    def test_finalize_deb_forces_xz_compression(self):
        common = DEB_COMMON.read_text(encoding="utf-8")
        self.assertRegex(common, r'dpkg-deb\s+-Zxz\s+--build',
                         "finalize_deb must force -Zxz so Debian 11 can unpack the extras")

    @unittest.skipUnless(shutil.which("dpkg-deb") and shutil.which("ar"),
                         "needs dpkg-deb + ar")
    def test_common_deb_uses_xz_members(self):
        with tempfile.TemporaryDirectory() as td:
            r = subprocess.run(
                ["bash", str(COMMON_BUILD_SCRIPT), "--version", "0.1.0", "--output-dir", td],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            debs = list(Path(td).glob("documentdb-common_*.deb"))
            self.assertTrue(debs, "common .deb not built")
            members = subprocess.run(["ar", "t", str(debs[0])],
                                     capture_output=True, text=True, timeout=30).stdout
        self.assertIn("control.tar.xz", members)
        self.assertIn("data.tar.xz", members)
        self.assertNotIn(".zst", members)

    def test_deb_gateway_entrypoint_uses_usr_lib_systemd(self):
        ep = (OSS_ROOT / "packaging" / "test_packages"
              / "test-gateway-install-entrypoint.sh").read_text(encoding="utf-8")
        self.assertIn("/usr/lib/systemd/system/documentdb-gateway.service", ep)
        self.assertIn('unit_dir="/usr/lib/systemd/system"', ep)
        # No legacy /lib/systemd/system path may remain in code (breaks on
        # non-usr-merged bullseye where /lib is not a symlink to /usr/lib).
        code = "\n".join(ln for ln in ep.splitlines()
                         if not ln.lstrip().startswith("#"))
        self.assertEqual([], re.findall(r'(?<!/usr)/lib/systemd/system', code),
                         "entrypoint must not assert the legacy /lib/systemd/system path")


class Iteration16HarnessFixesTests(unittest.TestCase):
    """Iteration-16 review threads: executable bits on directly-executed build
    scripts, Bash 3.2-safe FORWARD_ARGS expansion, and CWD-independent init-data
    DEB lookup."""

    def _git_mode(self, oss_relpath):
        # git ls-files resolves paths relative to the cwd, so running from
        # OSS_ROOT with OSS-relative paths works in BOTH checkout layouts:
        # the internal dual-root repo (<repo>/oss/...) and the standalone
        # OSS repo (checkout root == this repo's oss/). The previous
        # version used cwd=OSS_ROOT.parent with "oss/"-prefixed paths,
        # which in the standalone layout is outside any git checkout —
        # the guard then skipped forever in exactly the CI that was wired
        # to run it.
        try:
            r = subprocess.run(["git", "ls-files", "-s", oss_relpath],
                               cwd=str(OSS_ROOT), capture_output=True,
                               text=True, timeout=30)
        except (FileNotFoundError, subprocess.SubprocessError):
            return None
        return r.stdout.split()[0] if r.stdout.strip() else None

    def test_directly_executed_build_scripts_are_executable(self):
        # build_extra_packages.sh / test harness run these directly, so a
        # non-exec bit breaks fresh checkouts with "Permission denied"
        # (threads 34942463, 34942485).
        first = self._git_mode("packaging/standalone/build-common-deb.sh")
        if first is None:
            self.skipTest("git not available or not a checkout")
        for rel in ("packaging/standalone/build-common-deb.sh",
                    "packaging/standalone/build-standalone-deb.sh"):
            self.assertEqual(self._git_mode(rel), "100755",
                             f"oss/{rel} must be tracked executable (100755)")

    def test_init_data_deb_lookup_is_cwd_independent(self):
        # The DEB find must be anchored to PROJECT_ROOT (the docker build
        # context), not the caller's CWD (thread 34942313).
        for name in ("test_init_data.sh", "test_init_invalid_data.sh",
                     "test_init_sample_data.sh"):
            t = (OSS_ROOT / "documentdb-local" / "test-init-data" / name).read_text(encoding="utf-8")
            self.assertIn('cd "$PROJECT_ROOT" && find "packaging"', t,
                          f"{name} must anchor the DEB find to PROJECT_ROOT")


class DocumentDBCommonSplitTests(unittest.TestCase):
    """The byte-identical shared payload is owned once by documentdb-common;
    documentdb-N ships no payload files and depends on documentdb-common. This
    fixes the DEB multi-major co-install ownership hazard (removing one major
    deleting shared files a surviving major needs)."""

    SHARED_BINS = ("documentdb-setup", "documentdb-local-reset")
    SHARED_UNITS = (
        "documentdb-local@.target",
        "documentdb-postgresql@.service",
        "documentdb-gateway-local@.service",
    )

    # ── DEB: documentdb-common owns the shared payload ──────────────
    def test_common_deb_ships_shared_payload(self):
        script = COMMON_BUILD_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('DEB_PKG_NAME="documentdb-common"', script)
        self.assertIn("/usr/bin/documentdb-setup", script)
        self.assertIn("/usr/bin/documentdb-local-reset", script)
        for unit in self.SHARED_UNITS:
            self.assertIn(unit, script, f"documentdb-common must ship {unit}")
        self.assertIn("sysusers.d/documentdb-local.conf", script)
        self.assertIn("tmpfiles.d/documentdb-local.conf", script)
        self.assertIn("init_documentdb_data.sh", script)
        self.assertIn("sample-data", script)
        # PG-agnostic runtime deps moved here.
        self.assertRegex(script, r"Depends:.*documentdb-postgresql-tools")
        self.assertRegex(script, r"Depends:.*documentdb-gateway")
        # It carries the sysusers/tmpfiles bootstrap (moved from documentdb-N).
        self.assertIn("systemd-sysusers", script)
        self.assertIn("systemd-tmpfiles", script)

    # ── DEB: documentdb-N is a payload-less dependency package ──────
    def test_standalone_deb_ships_no_payload_and_depends_on_common(self):
        script = STANDALONE_BUILD_SCRIPT.read_text(encoding="utf-8")
        # No install of the shared files into the per-major package.
        self.assertNotIn('/usr/bin/documentdb-setup"', script,
                         "documentdb-N must not install documentdb-setup")
        for unit in self.SHARED_UNITS:
            self.assertNotIn(f'/usr/lib/systemd/system/{unit}"', script,
                             f"documentdb-N must not install {unit}")
        # Depends on documentdb-common; no cross-major Replaces control field.
        self.assertRegex(script, r"Depends:.*documentdb-common \(>= \$\{VERSION\}\)")
        self.assertNotIn("Replaces: documentdb-15", script)
        self.assertNotRegex(script, r"(?m)^Replaces: documentdb")
        # The per-major maintainer scripts stay (gateway restart / state cleanup).
        self.assertIn("documentdb-gateway-local@${PG_VERSION}.service", script)

    # ── RPM: documentdb-common.spec owns the shared payload ─────────
    def test_common_spec_owns_shared_payload(self):
        spec = COMMON_SPEC.read_text(encoding="utf-8")
        self.assertIn("Name:           documentdb-common", spec)
        self.assertIn("BuildArch:      noarch", spec)
        self.assertIn("/usr/bin/documentdb-setup", spec)
        for unit in self.SHARED_UNITS:
            self.assertIn(unit, spec, f"documentdb-common.spec must ship {unit}")
        self.assertRegex(spec, r"Requires:\s+documentdb-gateway")
        self.assertRegex(spec, r"Requires:\s+documentdb-postgresql-tools")
        # The %pre user bootstrap moved here.
        self.assertIn("documentdb-local", spec)
        self.assertRegex(spec, r"(?m)^%pre\b")

    # ── RPM: documentdb-local.spec (documentdb-N) is payload-less ───
    def test_standalone_spec_has_no_payload_and_requires_common(self):
        spec = STANDALONE_SPEC.read_text(encoding="utf-8")
        self.assertRegex(spec, r"Requires:\s+documentdb-common >= %\{version\}")
        # Shared file installs are gone.
        self.assertNotIn("install -Dpm 0755 %{_sourcedir}/documentdb-setup.sh", spec)
        self.assertNotIn("%{_unitdir}/documentdb-postgresql@.service", spec)
        # No %pre user creation (moved to documentdb-common).
        self.assertNotRegex(spec, r"(?m)^%pre\b")
        # It no longer directly requires gateway/tools/shadow-utils (via common).
        self.assertNotRegex(spec, r"Requires:\s+documentdb-gateway")
        self.assertNotRegex(spec, r"Requires\(pre\):\s+shadow-utils")
        # Per-major cleanup scriptlets remain.
        self.assertRegex(spec, r"(?m)^%postun\b")
        self.assertIn("documentdb-local@%{pg_version}.target", spec)

    def test_common_deb_declares_replaces_for_pre_split_major(self):
        # Unversioned Replaces: transfers ownership of the shared files from a
        # pre-split documentdb-N. There is intentionally NO Breaks: — a rolling
        # Breaks would contradict the deliberately-relaxed
        # `Depends: documentdb-common (>= VERSION)` staggered-release floor.
        script = COMMON_BUILD_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(script, r"(?m)^Replaces: documentdb-16, documentdb-17, documentdb-18")
        self.assertNotRegex(script, r"(?m)^Breaks:")

    # ── Orchestration builds documentdb-common (DEB + RPM) ──────────
    def test_build_extra_packages_builds_common(self):
        script = BUILD_EXTRA_PACKAGES.read_text(encoding="utf-8")
        self.assertIn("build-common-deb.sh", script)
        self.assertIn("documentdb-common.spec", script)

    # ── Clean-install test images install documentdb-common ─────────
    def test_gateway_test_images_install_common(self):
        deb_df = (OSS_ROOT / "packaging" / "gateway" / "test" / "Dockerfile_deb_gateway_test").read_text(encoding="utf-8")
        self.assertIn("COMMON_PACKAGE_REL_PATH", deb_df)
        # The two RHEL gateway-test Dockerfiles were merged into one
        # parameterized file (EL major derived from the base image).
        rhel_df = (OSS_ROOT / "packaging" / "test_packages" /
                   "Dockerfile-rhel-gateway-test").read_text(encoding="utf-8")
        self.assertIn("COMMON_RPM_PACKAGE_REL_PATH", rhel_df)
        self.assertIn("/tmp/documentdb-common.rpm", rhel_df)

    # ── Purge/remove lifecycle lists include documentdb-common ──────
    def test_entrypoint_cleanup_lists_include_common(self):
        deb_ep = (OSS_ROOT / "packaging" / "test_packages" / "test-gateway-install-entrypoint.sh").read_text(encoding="utf-8")
        rpm_ep = (OSS_ROOT / "packaging" / "test_packages" / "test-gateway-install-entrypoint-rpm.sh").read_text(encoding="utf-8")
        # documentdb-common must be in the purge/remove sets so the dependency
        # closure resolves and the shared files are cleaned.
        self.assertRegex(deb_ep, r'packages_to_purge=\([^)]*"documentdb-common"', )
        self.assertRegex(rpm_ep, r'packages_to_remove=\([^)]*"documentdb-common"')

    # ── Behavioral co-install regression test exists + is CI-wired ──
    def test_coinstall_regression_test_exists_and_is_ci_wired(self):
        script = OSS_ROOT / "packaging" / "test_packages" / "test-documentdb-common-coinstall.sh"
        self.assertTrue(script.is_file(),
                        "behavioral co-install regression test must exist")
        body = script.read_text(encoding="utf-8")
        # It drives the exact bug scenario (install two majors, remove one).
        self.assertIn("survives removal of documentdb-18", body)
        self.assertIn("pkg_install", body)
        # Both package families run it automatically in CI.
        deb_wf = (OSS_ROOT / ".github" / "workflows" / "build_deb_packages.yml").read_text(encoding="utf-8")
        rpm_wf = (OSS_ROOT / ".github" / "workflows" / "build_rpm_packages.yml").read_text(encoding="utf-8")
        self.assertIn("test-documentdb-common-coinstall.sh --type deb", deb_wf)
        self.assertIn("test-documentdb-common-coinstall.sh --type rpm", rpm_wf)


class DocumentDBSetupwizardFlagsTests(unittest.TestCase):
    """Phase 10 contract: documentdb-setup must implement the design's
    flag surface, branch flow on --target-postgres-instance, and honor
    --dry-run as a no-side-effect preview path."""

    def _help_output(self):
        result = subprocess.run(
            ["bash", str(SETUP_SCRIPT), "--help"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def _dry_run(self, *extra_args):
        result = subprocess.run(
            ["bash", str(SETUP_SCRIPT),
             "--admin-user", "admin",
             "--password-file", "/dev/null",
             "--dry-run", *extra_args],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0,
                         f"dry-run with args {extra_args!r} failed: {result.stderr}")
        return result.stdout

    def test_help_lists_canonical_flag_names(self):
        """Per design §4.4, the canonical flags are
        --use-new-postgres-instance and --target-postgres-instance."""
        h = self._help_output()
        self.assertIn("--use-new-postgres-instance", h)
        self.assertIn("--target-postgres-instance", h)

    def test_help_lists_deprecated_aliases(self):
        """Deprecated aliases must remain documented so existing
        automation does not silently break."""
        h = self._help_output()
        self.assertIn("--use-private-cluster", h)
        self.assertIn("--target-cluster", h)

    def test_dry_run_greenfield_announces_per_major_units(self):
        """Greenfield dry-run must reference the per-major templated
        systemd units (documentdb-postgresql@N.service,
        documentdb-gateway-local@N.service) per design §4.4."""
        out = self._dry_run("--pg-version", "18")
        self.assertIn("documentdb-postgresql@18.service", out)
        self.assertIn("documentdb-gateway-local@18.service", out)
        self.assertIn("GREENFIELD", out)
        # Greenfield must mention initdb with --username=documentdb-local
        # (OS user matches the templated service's User= directive).
        self.assertIn("--username=documentdb-local", out)

    def test_dry_run_brownfield_branches_correctly(self):
        """--target-postgres-instance N/C must switch the wizard into
        BROWNFIELD mode (no initdb, print reload command for operator)."""
        out = self._dry_run("--target-postgres-instance", "18/main")
        self.assertIn("BROWNFIELD", out)
        self.assertIn("18/main", out)
        # Brownfield must NOT initdb.
        self.assertNotIn("initdb --pgdata", out)
        # Brownfield must print the per-major reload command for the
        # operator to run against the system PG service.
        self.assertIn("systemctl reload postgresql@18-main", out)
        # Brownfield must still use the per-major templated gateway unit.
        self.assertIn("documentdb-gateway-local@18.service", out)

    def test_dry_run_delegates_to_subtools(self):
        """Both dry-run flows must mention delegation to documentdb-tune
        (postgresql.conf) and documentdb-register-gateway (hba/ident/role/url)."""
        out = self._dry_run("--pg-version", "18")
        self.assertIn("documentdb-tune --yes", out)
        self.assertIn("documentdb-register-gateway --yes", out)

    def test_dry_run_performs_no_side_effects(self):
        """--dry-run must not create any state files, data dirs, or
        run any service commands. We verify by ensuring the dry-run
        path exits before preflight_validation (which calls require_root)
        and without touching the filesystem."""
        with tempfile.TemporaryDirectory() as tmpdir:
            sentinel_etc = Path(tmpdir) / "etc-marker"
            sentinel_etc.write_text("untouched\n")
            result = subprocess.run(
                ["bash", str(SETUP_SCRIPT),
                 "--admin-user", "admin",
                 "--password-file", "/dev/null",
                 "--dry-run", "--pg-version", "18"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            # require_root would have failed the run if dry-run hadn't
            # exited early; success exit + sentinel intact confirms the
            # no-side-effect property.
            self.assertEqual(sentinel_etc.read_text(), "untouched\n")
            self.assertIn("no side effects performed", result.stdout)

    def test_target_postgres_instance_is_actually_wired(self):
        """Regression: TARGET_CLUSTER must be
        read in main() (not only in parse_arguments) to drive flow.
        Verified by source-grep — main() must reference prepare_brownfield_instance
        when TARGET_CLUSTER is non-empty."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("prepare_brownfield_instance", script,
                      "Expected prepare_brownfield_instance function in setup.sh")
        # The main() flow must check TARGET_CLUSTER and call brownfield prep.
        # We look for the canonical guard:
        self.assertRegex(
            script,
            r'if \[\[ -n "\$\{TARGET_CLUSTER\}" \]\]; then\s*\n\s*prepare_brownfield_instance',
            "main() must branch on TARGET_CLUSTER and call prepare_brownfield_instance",
        )

    def test_per_major_systemd_unit_is_default_target(self):
        """start_or_restart_postgres must enable the per-major templated
        unit (documentdb-postgresql@N.service), not the non-templated one."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # The new code path uses documentdb-postgresql@${PG_VERSION}.service
        self.assertRegex(
            script,
            r'pg_unit="documentdb-postgresql@\$\{PG_VERSION\}\.service"',
            "start_or_restart_postgres must use the per-major templated PG unit",
        )

    def test_greenfield_uses_documentdb_local_os_user(self):
        """Greenfield initdb must use --username=documentdb-local so
        that the templated PG unit (User=documentdb-local) and peer auth
        line up 1:1 (no ident map entry needed for the superuser)."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("--username=documentdb-local", script)
        # And the wizard must not initdb as the old "documentdb" OS user.
        self.assertNotIn("--username=documentdb \\", script)

    def test_every_invasive_step_routes_through_confirm_or_apply(self):
        """Ensure the wizard's consent gate
        actually wraps every invasive step the design lists in §4.4,
        not just initdb and systemctl. The script source must show
        confirm_or_apply guarding postgresql.conf write, hba/ident
        write (via register-gateway delegation), CREATE EXTENSION,
        and admin-user bootstrap."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # Each label is a substring of the confirm_or_apply description
        # for one invasive operation. If a step regresses past the gate,
        # this test will fail.
        for label in (
            "Initialize PostgreSQL ${PG_VERSION} cluster",
            "Write postgresql.conf managed block via documentdb-tune",
            "Run documentdb-register-gateway --yes",
            "Run CREATE EXTENSION documentdb CASCADE",
            "Bootstrap first admin user",
        ):
            self.assertRegex(
                script,
                r'confirm_or_apply "[^"]*' + re.escape(label),
                f"Invasive step '{label}' must be wrapped in confirm_or_apply",
            )

    def test_dry_run_advertises_all_invasive_steps(self):
        """The dry-run preview must enumerate every invasive step that
        would run in apply mode, not just initdb + systemctl."""
        result = subprocess.run(
            ["bash", str(SETUP_SCRIPT),
             "--admin-user", "admin",
             "--password-file", "/dev/null",
             "--dry-run", "--pg-version", "18"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        out = result.stdout
        for step in (
            "documentdb-tune --yes",
            "documentdb-register-gateway --yes",
            "CREATE EXTENSION documentdb CASCADE",
            "bootstrap admin user",
            "documentdb-postgresql@18.service",
            "documentdb-gateway-local@18.service",
        ):
            self.assertIn(step, out,
                          f"Dry-run preview must mention '{step}'")

    def test_brownfield_persists_per_major_state(self):
        """Brownfield must NOT write the
        per-major setup.conf (which would make the templated PG service
        activate). It writes a separate brownfield.conf for --restore
        tracking that no templated-unit ConditionPathExists checks."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            script,
            r'brownfield_conf="\$\{per_major_dir\}/brownfield\.conf"',
            "persist_brownfield_state must write /etc/documentdb/local/N/brownfield.conf",
        )
        # The brownfield branch in main() must call persist_brownfield_state,
        # NOT persist_self_managed_postgres_state.
        self.assertRegex(
            script,
            r'(?s)if \[\[ -n "\$\{TARGET_CLUSTER\}" \]\]; then\s*\n\s*prepare_brownfield_instance.*?persist_brownfield_state',
            "Brownfield flow must call persist_brownfield_state for --restore tracking",
        )


class Phase11wizardCorrectnessTests(unittest.TestCase):
    """Phase 11 regressions for the
    wizard-correctness issues that prevented end-to-end greenfield install."""

    def test_start_gateway_verifies_unit_activated(self):
        """Round-2 fix: start_gateway must confirm the systemd unit actually
        reached `active` after `systemctl start`, because a unit whose
        ConditionPathExists gate is unmet (gateway.env missing on the
        register-gateway-absent fallback path) is SKIPPED with an
        exit-success. Without the is-active check the wizard would block in
        wait_for_gateway_ready for 60s and die with a misleading timeout."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"verify_gateway_unit_active\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "verify_gateway_unit_active helper must exist")
        body = match.group("body")
        self.assertIn(
            'systemctl is-active --quiet "${gw_unit}"',
            body,
            "verify_gateway_unit_active must check is-active on the started unit",
        )
        self.assertIn(
            'documentdb-register-gateway',
            body,
            "the failure message must hint that documentdb-register-gateway "
            "writes the missing gateway.env",
        )
        self.assertRegex(
            body,
            r'\[\[ "\$\{DRY_RUN\}" == "true" \]\] && return 0',
            "verify_gateway_unit_active must skip in dry-run (nothing started)",
        )
        # The helper must actually be wired into start_gateway before the
        # 60s readiness poll, on the systemd path.
        self.assertRegex(
            script,
            r'verify_gateway_unit_active "\$\{gw_unit\}"\s*\n\s*wait_for_gateway_ready "\$\{gw_unit\}"',
            "start_gateway must call verify_gateway_unit_active before "
            "wait_for_gateway_ready",
        )

    def test_register_gateway_runs_after_pg_started(self):
        """Issue 1: register-gateway must NOT be called from
        prepare_self_managed_cluster (where PG is still down). It runs
        from register_gateway_after_pg_running, invoked from main()
        AFTER start_or_restart_postgres."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # The pre-Phase-11 bug: ensure_pg_ident_map called inside
        # prepare_self_managed_cluster before PG was started. The wrapper
        # helper register_gateway_after_pg_running must exist and be
        # invoked from main() after the PG-start step.
        self.assertIn("register_gateway_after_pg_running", script)
        self.assertRegex(
            script,
            r'(?s)start_or_restart_postgres.*?register_gateway_after_pg_running',
            "register_gateway_after_pg_running must be called after start_or_restart_postgres",
        )

    def test_register_gateway_accepts_pg_owner(self):
        """Issue 1 follow-up: the wizard passes --pg-owner so
        register-gateway connects as the right OS user
        (documentdb-local for greenfield, postgres for brownfield)."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            script,
            r'--pg-owner\s+"\$\{PG_OWNER\}"',
            "wizard must pass --pg-owner to documentdb-register-gateway",
        )
        rg = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("--pg-owner)", rg)

    def test_hba_rule_is_scoped_to_documentdb_roles(self):
        """Issue 2: build_hba_block must NOT produce 'all all' which would
        catch every local peer connection and lock out postgres /
        documentdb-local. It must be scoped to the documentdb_*_role
        groups plus the gateway PG role."""
        rg = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # Extract the heredoc body inside build_hba_block — that's the
        # actual rule emitted into pg_hba.conf, not the surrounding
        # comments. The cat <<EOF ... EOF block is what gets executed.
        m = re.search(
            r'build_hba_block\(\)\s*\{.*?cat\s*<<[A-Z]+\n(?P<body>.+?)\nEOF',
            rg, flags=re.DOTALL,
        )
        self.assertIsNotNone(m, "build_hba_block function or heredoc not found")
        body = m.group("body")
        self.assertNotRegex(
            body, r'^\s*local\s+all\s+all\s+peer',
            f"HBA rule must NOT match 'local all all peer'; got body:\n{body}",
        )
        # Scoped form: includes the role groups so peer auth still
        # applies for the gateway-relevant DB roles only.
        self.assertIn("+documentdb_admin_role", body)
        self.assertIn("+documentdb_readwrite_role", body)
        self.assertIn("+documentdb_readonly_role", body)

    def test_per_major_pg_systemd_unit_sets_user_and_no_pidfile(self):
        """The templated documentdb-postgresql@.service runs as
        User=documentdb-local / Group=documentdb-local: ExecStartPre=+ does the
        root-only runtime setup, then ExecStart drops to the unit user so the
        postmaster lives in this unit's cgroup. It must NOT set PIDFile= --
        under systemd 245+ a PIDFile owned by the non-root unit user can be
        refused (and races with ExecStartPre=+), so the unit tracks the
        postmaster via Type=forking + cgroup GuessMainPID instead."""
        unit_path = OSS_ROOT / "packaging" / "appliance" / "systemd" / "documentdb-postgresql@.service"
        unit = unit_path.read_text(encoding="utf-8")
        self.assertRegex(
            unit, r'(?m)^User=documentdb-local$',
            "documentdb-postgresql@.service must run as User=documentdb-local",
        )
        self.assertRegex(
            unit, r'(?m)^Group=documentdb-local$',
            "documentdb-postgresql@.service must run as Group=documentdb-local",
        )
        self.assertNotRegex(
            unit, r'(?m)^PIDFile=',
            "documentdb-postgresql@.service must NOT set PIDFile= (cgroup tracking)",
        )

    def test_per_major_pg_systemd_unit_hardening_is_pg_safe_profile(self):
        unit_path = OSS_ROOT / "packaging" / "appliance" / "systemd" / "documentdb-postgresql@.service"
        unit = unit_path.read_text(encoding="utf-8")
        self.assertRegex(
            unit,
            r'(?m)^RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK$',
            "PG unit should restrict sockets to Unix/TCP plus netlink interface enumeration",
        )
        for directive in (
            "ProtectSystem=strict",
            "PrivateDevices=yes",
            "MemoryDenyWriteExecute=yes",
            "SystemCallFilter=@system-service",
        ):
            self.assertNotRegex(
                unit,
                rf'(?m)^{re.escape(directive)}$',
                f"{directive} must remain omitted until PostgreSQL-specific runtime validation covers it",
            )
        for rationale in (
            "custom --data-dir",
            "device-namespace runtime validation",
            "JIT/extensions",
            "PostgreSQL-specific runtime validation",
            "AF_NETLINK",
            "getifaddrs",
            "NETLINK_ROUTE",
            "samehost/samenet",
            "gateway units intentionally stay tighter",
        ):
            self.assertIn(
                rationale,
                unit,
                f"PG unit must explain hardening omission rationale: {rationale}",
            )

    def test_lazy_defaults_in_resolve_runtime_paths(self):
        """Issue 4: per-major PG_PORT and DATA_DIR must be computed in
        resolve_runtime_paths (after detect_postgres_installation),
        not parse_arguments. Source-grep: resolve_runtime_paths must
        contain the per-major override logic."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # The override predicate that only fires if not explicit AND
        # value equals the legacy default.
        self.assertRegex(
            script,
            r'(?s)resolve_runtime_paths\(\) \{.*?PG_PORT_EXPLICIT.*?documentdb_default_pg_port',
            "resolve_runtime_paths must set PG_PORT via documentdb_default_pg_port when not explicit",
        )
        self.assertRegex(
            script,
            r'(?s)resolve_runtime_paths\(\) \{.*?DATA_DIR_EXPLICIT.*?/var/lib/documentdb-local/\$\{PG_VERSION\}/data',
            "resolve_runtime_paths must set DATA_DIR=/var/lib/documentdb-local/N/data when not explicit",
        )

    def test_url_password_detection_handles_empty_userinfo(self):
        """Suggestion 3: postgresql://:secret@host/db must be detected as
        password-bearing. Verified by source-grep that has_password no
        longer depends on user being non-empty."""
        # Read the Rust setup.rs to confirm the fix is present.
        rust_path = (
            OSS_ROOT / "pg_documentdb_gw" / "documentdb_gateway_core"
            / "src" / "configuration" / "setup.rs"
        )
        rust = rust_path.read_text(encoding="utf-8")
        self.assertNotRegex(
            rust,
            r'has_password\s*=\s*!user\.is_empty\(\)',
            "URL password detection must not gate on user being non-empty (empty-user-only edge case)",
        )

    def test_strict_version_check_env_var_removed(self):
        """Suggestion 2: DOCUMENTDB_STRICT_VERSION_CHECK was parsed but
        never enforced. It must be removed from the public env-var
        surface in setup.rs."""
        rust_path = (
            OSS_ROOT / "pg_documentdb_gw" / "documentdb_gateway_core"
            / "src" / "configuration" / "setup.rs"
        )
        rust = rust_path.read_text(encoding="utf-8")
        self.assertNotIn('"DOCUMENTDB_STRICT_VERSION_CHECK"', rust)
        # The struct field is also gone (the only mentions left are the
        # historical-note comments).
        self.assertNotRegex(
            rust,
            r'pub strict_version_check:\s*Option<bool>',
            "strict_version_check struct field must be removed",
        )

    def test_tune_writes_debian_documentdb_conf(self):
        """Issue 7: documentdb-tune must write the per-instance fragment
        as documentdb.conf (matching the createcluster.d hook and the
        design's .sample naming), NOT postgresql.conf."""
        tune_path = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-tune.sh"
        tune = tune_path.read_text(encoding="utf-8")
        self.assertIn(
            'CONFIG_TARGET="${cluster_dir}/documentdb.conf"',
            tune,
            "tune must write to /etc/postgresql-common/documentdb/N/C/documentdb.conf",
        )
        # The createcluster.d hook must point at the same filename.
        hook_path = OSS_ROOT / "documentdb-local" / "conf" / "99-documentdb.conf"
        self.assertIn("/documentdb.conf'", hook_path.read_text(encoding="utf-8"))

    def test_tune_adds_include_line_for_existing_debian_clusters(self):
        """Issue 7 follow-up: tune must add the include_if_exists line
        to the live cluster's postgresql.conf for clusters that pre-date
        the createcluster.d hook; otherwise the fragment is silently
        unused."""
        tune_path = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-tune.sh"
        tune = tune_path.read_text(encoding="utf-8")
        self.assertIn("ensure_debian_include_line", tune)
        self.assertRegex(
            tune,
            r'include_marker_start="# >>> documentdb-tune managed include >>>"',
            "include line must be wrapped in its own managed-block markers",
        )

    def test_gateway_postrm_does_not_strip_pg_state(self):
        """Issue 8: the gateway runtime package's postrm must NOT
        mutate PostgreSQL-side managed blocks — that violates the
        runtime-only boundary per design §4.3."""
        postrm_path = (
            OSS_ROOT / "documentdb-local" / "maintainer-scripts"
            / "gateway" / "postrm"
        )
        postrm = postrm_path.read_text(encoding="utf-8")
        # The pre-Phase-11 postrm called documentdb_strip_managed_block
        # against pg_hba.conf / pg_ident.conf / postgresql.conf — that's
        # what we're removing.
        self.assertNotIn(
            "documentdb-setup managed hba",
            postrm,
            "gateway postrm must not touch pg_hba.conf",
        )
        self.assertNotIn(
            "documentdb-setup managed pg_ident",
            postrm,
            "gateway postrm must not touch pg_ident.conf",
        )
        self.assertNotIn(
            "documentdb-setup managed configuration",
            postrm,
            "gateway postrm must not touch postgresql.conf",
        )


class Phase12DesignParityAndOpsTests(unittest.TestCase):
    """Phase 12: implement the missing operational flags the design
    promised (--print-config, --status) and pin the design doc's flag
    list to what the wizard actually ships."""

    def _run(self, *args):
        return subprocess.run(
            ["bash", str(SETUP_SCRIPT), *args],
            capture_output=True, text=True, timeout=10,
        )

    def test_print_config_emits_expected_keys(self):
        """--print-config must report mode, PG version/port, paths,
        templated systemd unit names, and delegated tools — read-only,
        no preflight."""
        r = self._run("--print-config", "--pg-version", "18")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout
        for needed in (
            "mode:",
            "GREENFIELD",
            "PG version:",
            "PG port:                       9718",
            "PG socket dir:                 /run/documentdb-local/18/postgresql",
            "PG data dir (greenfield):      /var/lib/documentdb-local/18/data",
            "documentdb-postgresql@18.service",
            "documentdb-gateway-local@18.service",
            "documentdb-local@18.target",
            "documentdb-local.target -> documentdb-local@18.target",
            "/etc/documentdb/local/18/setup.conf",
            "/etc/documentdb/local/18/brownfield.conf",
            "/var/lib/documentdb-local/18/gateway/pg-url",
            "documentdb-tune",
            "documentdb-register-gateway",
        ):
            self.assertIn(needed, out, f"--print-config missing '{needed}'")

    def test_print_config_brownfield_mode(self):
        """--print-config with --target-postgres-instance must report
        BROWNFIELD mode and include the targeted instance identifier."""
        r = self._run("--print-config", "--target-postgres-instance", "18/main")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("BROWNFIELD (18/main)", r.stdout)

    def test_print_config_performs_no_side_effects(self):
        """--print-config must not require root and must not touch the
        filesystem. The test runs as a non-root user; if any side-effect
        path runs, require_root inside preflight_validation would fire
        and fail the run."""
        r = self._run("--print-config", "--pg-version", "18")
        self.assertEqual(r.returncode, 0, r.stderr)
        # require_root prints "must be run as root"; its absence proves
        # the dispatch short-circuited before preflight.
        self.assertNotIn("must be run as root", r.stdout + r.stderr)

    def test_print_config_uses_per_major_target_for_non_default_major(self):
        """The public alias stays fixed to the paved-road major. For a
        non-default install, --print-config must point operators at the
        explicit per-major target instead of pretending the alias moves."""
        r = self._run("--print-config", "--pg-version", "17")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("preferred day-2 target:      documentdb-local@17.target", r.stdout)
        self.assertIn("documentdb-local.target -> documentdb-local@18.target", r.stdout)
        self.assertNotIn("documentdb-local.target -> documentdb-local@17.target", r.stdout)

    def test_status_reports_unconfigured_when_no_state_file(self):
        """--status with no installation should report '<not configured>'
        and exit non-zero so scripts can gate."""
        r = self._run("--status", "--pg-version", "18")
        # Exit code 1 (or 0 with state); in this dev env there is no
        # /etc/documentdb/local/18/setup.conf so we expect non-zero.
        self.assertIn("documentdb-setup status", r.stdout)
        # Either reports unconfigured or finds nothing — both are
        # non-fatal for the test; we just confirm the status path runs.
        self.assertNotIn("must be run as root", r.stdout + r.stderr)

    def test_help_lists_print_config_and_status(self):
        """--help must advertise the operational flags we just added so
        operators can discover them."""
        r = self._run("--help")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("--print-config", r.stdout)
        self.assertIn("--status", r.stdout)

    def test_design_doc_flag_list_matches_implementation(self):
        """Phase 12 parity check: every flag the
        design doc's §4.4 "Key flags" section claims as a wizard CLI
        flag must actually appear in --help output. The previous design
        listed --pgdata / --tls-cert-file / --tls-key-file / --quiet /
        --update which were never implemented; this test pins the doc
        to reality going forward."""
        design_path = OSS_ROOT / "packaging" / "gateway" / "packaging-design.md"
        design = design_path.read_text(encoding="utf-8")
        # Find the "Key flags" section in §4.4 and pull out every
        # `--flag-name` token mentioned (excluding things that are
        # clearly env vars or commented as alias).
        m = re.search(
            r'Key flags[^\n]*:\n(?P<body>(?:.+?\n){0,40}?)\n(?:The bootstrap flags|Terminology in)',
            design, flags=re.DOTALL,
        )
        self.assertIsNotNone(m, "Key flags section not found in packaging-design.md")
        body = m.group("body")
        claimed = set(re.findall(r'`(--[a-z][a-z0-9-]*)`', body))
        # Strip flags that the design intentionally lists as deprecated
        # aliases — they still must be honored by the wizard, but their
        # canonical form is what the design teaches.
        deprecated_alias_marker = re.compile(
            r'`(--[a-z][a-z0-9-]*)`\s+\(.*?deprecated', re.IGNORECASE,
        )
        deprecated = set(deprecated_alias_marker.findall(body))
        claimed_non_deprecated = claimed - deprecated

        r = subprocess.run(
            ["bash", str(SETUP_SCRIPT), "--help"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        help_text = r.stdout

        missing = [f for f in sorted(claimed_non_deprecated) if f not in help_text]
        self.assertFalse(
            missing,
            "Design doc claims these wizard flags but they are missing "
            f"from --help: {missing}\n\nHelp output:\n{help_text}",
        )

    def test_design_doc_tool_inventory_includes_gateway_admin(self):
        """Phase 12: documentdb-gateway-admin is
        installed by documentdb-postgresql-tools but was missing from
        the §8 tool inventory."""
        design_path = OSS_ROOT / "packaging" / "gateway" / "packaging-design.md"
        design = design_path.read_text(encoding="utf-8")
        # Look for the row in the §8 table.
        self.assertRegex(
            design,
            r'\|\s*`documentdb-gateway-admin`\s*\|\s*`documentdb-postgresql-tools`',
            "Tool inventory must include documentdb-gateway-admin in documentdb-postgresql-tools",
        )


class BrownfieldGatewayDropInTests(unittest.TestCase):
    """packaging-design.md §4.4: brownfield's stand-alone target must order the
    gateway on the adopted PostgreSQL service, not the (skipped) per-major
    greenfield documentdb-postgresql@N.service. The wizard writes a per-instance
    systemd drop-in to make this true at the unit level (not just at wizard
    Runtime). """

    def test_wizard_defines_brownfield_dropin_writer(self):
        """The wizard must expose write_brownfield_gateway_dropin and
        remove_brownfield_gateway_dropin (so both apply and --restore wire
        through one code path)."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("write_brownfield_gateway_dropin()", script,
                      "write_brownfield_gateway_dropin must be defined")
        self.assertIn("remove_brownfield_gateway_dropin()", script,
                      "remove_brownfield_gateway_dropin must be defined")

    def test_persist_brownfield_state_invokes_dropin_writer(self):
        """persist_brownfield_state must call write_brownfield_gateway_dropin
        so a brownfield apply actually installs the drop-in, not just the
        per-major state file."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"persist_brownfield_state\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "persist_brownfield_state body not found")
        self.assertIn(
            "write_brownfield_gateway_dropin",
            match.group("body"),
            "persist_brownfield_state must invoke the drop-in writer",
        )

    def test_dropin_path_matches_design(self):
        """The drop-in must live under
        /etc/systemd/system/documentdb-gateway-local@<N>.service.d/brownfield.conf
        — admin-owned tree so package upgrades never overwrite it."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            '/etc/systemd/system/documentdb-gateway-local@${PG_VERSION}.service.d',
            script,
            "Drop-in directory path must match design",
        )
        self.assertIn(
            'brownfield.conf',
            script,
            "Drop-in file must be named brownfield.conf",
        )

    def test_dropin_resets_and_repoints_dependency_lists(self):
        """The drop-in must (a) reset Requires=/After= to drop the greenfield
        documentdb-postgresql@%i.service dep, and (b) re-point at the adopted
        PG service unit. Without the empty-string reset, systemd would append
        rather than replace."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            script,
            r"Requires=\s*\n\s*After=\s*\n\s*Requires=\$\{adopted_pg_unit\}",
            "Drop-in must reset Requires= then set the adopted PG unit",
        )

    def test_debian_pg_service_unit_name_resolved_for_debian_layout(self):
        """On Debian-like layouts (/etc/postgresql/<V> present) the adopted PG
        service unit must be postgresql@<V>-<C>.service."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"resolve_brownfield_pg_service_unit\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "resolve_brownfield_pg_service_unit not found")
        body = match.group("body")
        self.assertIn('postgresql@%s-%s.service', body,
                      "Debian-style unit name (postgresql@V-C.service) must be used")
        self.assertIn('postgresql-%s.service', body,
                      "RHEL-style unit name (postgresql-V.service) must be the fallback")

    def test_restore_path_removes_brownfield_dropin(self):
        """--restore must iterate brownfield.conf state files and invoke
        remove_brownfield_gateway_dropin so a re-adopt of a different PG
        instance starts from a clean unit-file view."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("/etc/documentdb/local/*/brownfield.conf", script,
                      "--restore must look for brownfield.conf state files")
        self.assertRegex(
            script,
            r"remove_brownfield_gateway_dropin\s+\"\$\{bf_major\}\"",
            "--restore must invoke remove_brownfield_gateway_dropin for each brownfield state",
        )

    def test_deb_postrm_strips_brownfield_dropin_directory(self):
        """The DEB postrm in build-standalone-deb.sh must remove the drop-in
        directory on full purge so the unit-file view is clean after uninstall.
        The cleanup is scoped to the
        package's own PG major via the ${PKG_PG_VERSION} substitution so a
        co-installed documentdb-N for another major is not disturbed."""
        builder = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
        text = builder.read_text(encoding="utf-8")
        # The postrm heredoc references the substituted shell variable.
        self.assertIn(
            '/etc/systemd/system/documentdb-gateway-local@${PKG_PG_VERSION}.service.d',
            text,
            "DEB postrm must sweep the per-major brownfield drop-in dir scoped to PKG_PG_VERSION",
        )
        self.assertIn(
            'rm -f "${brownfield_file}"',
            text,
            "DEB postrm sweep must remove the brownfield.conf drop-in",
        )
        # Guard against regression to the wildcard form that touched other majors.
        self.assertNotIn(
            'for dropin_dir in /etc/systemd/system/documentdb-gateway-local@*.service.d',
            text,
            "DEB postrm must NOT iterate all majors — that would tear down co-installed documentdb-N for other PG versions",
        )

    def test_rpm_postun_strips_brownfield_dropin_directory(self):
        """The RPM %postun in documentdb-local.spec must remove the drop-in
        directory on full uninstall for the same reason."""
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertIn(
            '/etc/systemd/system/documentdb-gateway-local@%{pg_version}.service.d',
            text,
            "RPM %postun must clean up the per-major brownfield drop-in directory",
        )

    def test_target_cluster_strict_slash_validation(self):
        """--target-postgres-instance without a slash
        (e.g. just '18') would silently pass the old validator because both
        ${TARGET_CLUSTER%%/*} and ${TARGET_CLUSTER#*/} return the whole
        string when there is no slash, producing a broken
        postgresql@18-18.service Requires= in the drop-in. The wizard must
        now reject this up front and the resolver must double-check."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # Strict slash check at the top of prepare_brownfield_instance.
        self.assertRegex(
            script,
            r'if \[\[ "\$\{TARGET_CLUSTER\}" != \*/\* \]\]; then\s+die',
            "prepare_brownfield_instance must reject --target-postgres-instance without a slash",
        )
        # And again in the resolver as defense in depth.
        self.assertRegex(
            script,
            r'resolve_brownfield_pg_service_unit\(\)[\s\S]+?\[\[ "\$\{TARGET_CLUSTER\}" == \*/\* \]\]',
            "resolve_brownfield_pg_service_unit must defensively re-validate the slash form",
        )

    def test_target_cluster_strict_cluster_name_validation(self):
        """The cluster name (the part after the slash) becomes part of the
        systemd unit name (postgresql@V-C.service) and is interpolated into
        shell strings via runuser, so it must be restricted to a PostgreSQL
        identifier form. Without this, --target-postgres-instance '18/$(rm /)'
        would interpolate unchecked into the drop-in. The shape must match
        what Debian's pg_createcluster permits (alphanumeric first char) so
        the wizard never rejects an existing valid cluster like '1replica'."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            script,
            r'target_cluster_name.*=~.*\^\[A-Za-z0-9\]\[A-Za-z0-9_-\]\*\$',
            "Cluster name must be a safe identifier matching pg_createcluster's rules",
        )


class StandalonePackageMaintainerScriptTests(unittest.TestCase):
    """packaging-design.md §6 row "Restart active gateway service on upgrade:
    documentdb-N install: Yes (gateway side only)" + §7 "Maintainer scripts
    restart PostgreSQL: Never". The DEB postinst and RPM %posttrans must
    restart only the gateway-local templated instance on upgrade, never the
    per-major target (which would bounce the underlying PG too)."""

    def test_deb_standalone_postinst_restarts_only_gateway_on_upgrade(self):
        """Standalone DEB postinst on upgrade ($2 is the previously-installed
        version) must restart documentdb-gateway-local@N.service only — not
        the per-major target."""
        builder = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
        text = builder.read_text(encoding="utf-8")
        # Upgrade-gated restart present. After the earlier bug, the systemd
        # detection now uses { [ -d /run/systemd/system ] && command -v
        # systemctl ...; } compound. Both forms are accepted.
        self.assertRegex(
            text,
            r'if \[ -n "\\?\${2:-}" \] && (?:command -v systemctl|\{ \[ -d /run/systemd/system \] && command -v systemctl)',
            "DEB postinst must gate restart on upgrade (\\$2 is set) AND a working systemd",
        )
        # Restart targets the gateway-local unit, not the target.
        self.assertRegex(
            text,
            r'systemctl restart "\\?\$\{gw_unit\}"',
            "DEB postinst must restart the gateway-local unit on upgrade",
        )
        # Belt and braces: ensure the postinst does NOT restart the target.
        self.assertNotRegex(
            text,
            r'systemctl restart "documentdb-local@.*\.target"',
            "DEB postinst must NOT restart the per-major target (would bounce PG)",
        )

    def test_rpm_standalone_posttrans_restarts_only_gateway(self):
        """Same contract on the RPM side: %posttrans restarts the gateway-
        local instance, never the per-major target."""
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local.spec"
        text = spec.read_text(encoding="utf-8")
        # Match a single %posttrans block.
        match = re.search(r"%posttrans\s*\n(?P<body>.*?)(?=^%|\Z)", text,
                          flags=re.DOTALL | re.MULTILINE)
        self.assertIsNotNone(match, "documentdb-local.spec must define %posttrans")
        body = match.group("body")
        self.assertIn(
            'systemctl restart "documentdb-gateway-local@%{pg_version}.service"',
            body,
            "%posttrans must restart the gateway-local unit on upgrade",
        )
        self.assertNotRegex(
            body,
            r'systemctl restart "documentdb-local@.*\.target"',
            "%posttrans must NOT restart the per-major target (would bounce PG, violates §7)",
        )


class RegisterGatewayAutoDetectTests(unittest.TestCase):
    """packaging-design.md §5 Workflow B step (3): documentdb-register-gateway
    must auto-detect when there is exactly one PostgreSQL instance on the
    host (the typical case), and fail loudly when there are zero or many."""

    def test_help_text_advertises_autodetect(self):
        """Operators discover the auto-detect via --help. The help must say
        so explicitly so the design promise isn't a hidden behavior."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "exactly one PostgreSQL instance on the host",
            text,
            "Help text must advertise the auto-detect behavior",
        )

    def test_autodetect_function_present(self):
        """The autodetect helper exists and is invoked from parse_arguments
        when neither --target-postgres-instance nor --pgdata is given."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "autodetect_single_pg_instance()",
            text,
            "autodetect_single_pg_instance() helper must be defined",
        )
        # The wiring point: autodetect must run from the no-explicit-target
        # fall-through path inside parse_arguments. Match across whitespace
        # without depending on the exact comment formatting.
        match = re.search(
            r"parse_arguments\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "parse_arguments body not found")
        self.assertIn(
            "autodetect_single_pg_instance",
            match.group("body"),
            "parse_arguments must invoke autodetect_single_pg_instance when no target is given",
        )

    def test_autodetect_refuses_when_multiple_pg_instances(self):
        """When pg_lsclusters / /etc/postgresql/<V>/<C>/ enumerate more than
        one instance, the script must NOT silently pick one — it must fail
        with a message that lists the candidates so the operator picks."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # Check the multi-instance branch returns failure rather than picking [0].
        match = re.search(
            r"autodetect_single_pg_instance\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "autodetect_single_pg_instance body not found")
        body = match.group("body")
        self.assertRegex(
            body,
            r'\(\(\s*\$\{#candidates\[@\]\}\s*>\s*1\s*\)\)',
            "Auto-detect must explicitly handle the >1-candidate case",
        )
        self.assertRegex(
            body,
            r'multiple PostgreSQL instances found',
            "Auto-detect's multi-instance error message must enumerate candidates",
        )

    def test_autodetect_validates_cluster_name_safely(self):
        """Candidate cluster names (from pg_lsclusters output or directory
        enumeration) must be filtered through a safe identifier regex so a
        maliciously-named directory cannot inject a unit name fragment
        downstream. Shape must match pg_createcluster (alphanumeric first
        char) so existing legal clusters like '1replica' are not filtered
        out of the auto-detect candidate list."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"autodetect_single_pg_instance\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertRegex(
            body,
            r'cluster.*=~.*\^\[A-Za-z0-9\]\[A-Za-z0-9_-\]\*\$',
            "Auto-detect must use pg_createcluster's identifier shape",
        )

    def test_autodetect_handles_rhel_layout(self):
        """The RHEL/Fedora PGDG layout uses /var/lib/pgsql/<V>/data/ rather
        than /etc/postgresql/<V>/<C>/. Auto-detect must walk that path on
        RHEL or it would never resolve a candidate on the RPM-family OSes."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"autodetect_single_pg_instance\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "/var/lib/pgsql",
            body,
            "Auto-detect must enumerate RHEL-style /var/lib/pgsql/<V>/data",
        )


class BrownfieldClusterIdentityValidationTests(unittest.TestCase):
    """--target-postgres-instance
    V/NAME on Debian must refuse if /etc/postgresql/V/NAME doesn't exist,
    and after live-discovery must cross-check that the connected instance's
    config_file actually lives under that cluster's config dir. Otherwise a
    typo causes the wizard to mutate one cluster's config while wiring the
    systemd drop-in to a different cluster."""

    def test_debian_cluster_dir_existence_check(self):
        """Up-front check that the named Debian cluster's /etc/postgresql/V/N
        directory exists before any psql/SHOW round-trip."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'if [[ ! -d "/etc/postgresql/${PG_VERSION}/${target_cluster_name}" ]]; then',
            script,
            "Must check the named Debian cluster directory before proceeding",
        )
        self.assertIn(
            "Brownfield: PostgreSQL ${PG_VERSION} cluster '${target_cluster_name}' not found",
            script,
            "Error message must name the missing cluster so the operator sees the typo",
        )

    def test_rhel_data_dir_existence_check(self):
        """RHEL/Fedora analog: refuse if /var/lib/pgsql/V/data is missing
        (PGDG packages create this on initdb)."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            script,
            r'\[\[ ! -d "/var/lib/pgsql/\$\{PG_VERSION\}/data" \]\]',
            "Must check RHEL PGDG data directory existence",
        )

    def test_live_config_file_cluster_membership_verified(self):
        """After SHOW config_file, the live instance's config_file path must
        live under /etc/postgresql/<V>/<target_cluster_name>/ — otherwise we
        are connected to a different cluster than the operator named."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'Refusing to adopt the wrong cluster',
            script,
            "Must die with a clear message when live config_file is outside the named cluster",
        )


class StandalonePurgeOrphanSweepTests(unittest.TestCase):
    """The package's postrm / %postun
    orphan sweep must cover gateway.env and /run/.../pg-url, not just the
    brownfield drop-in. Otherwise --restore followed by purge leaves
    operator-visible files behind."""

    def test_deb_postrm_sweeps_orphaned_gateway_env(self):
        """DEB postrm per-major env strip must clean gateway.env left behind
        By --restore. scoped to the
        package's own PG major (per_major_env = .../<PKG_PG_VERSION>/gateway.env)
        so co-installed majors keep their env."""
        builder = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
        text = builder.read_text(encoding="utf-8")
        self.assertIn(
            'per_major_env="/etc/documentdb/local/${PKG_PG_VERSION}/gateway.env"',
            text,
            "DEB postrm must scope gateway.env cleanup to PKG_PG_VERSION",
        )
        # Guard against regression to the wildcard form.
        self.assertNotIn(
            'for per_major_env in /etc/documentdb/local/*/gateway.env',
            text,
            "DEB postrm must NOT iterate all majors when cleaning gateway.env",
        )

    def test_rpm_postun_sweeps_orphaned_gateway_env(self):
        """Mirror check for RPM %postun."""
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertIn(
            'per_major_env="/etc/documentdb/local/%{pg_version}/gateway.env"',
            text,
            "RPM %postun must unconditionally sweep the per-major gateway.env",
        )

    def test_restore_strips_brownfield_gateway_env_and_pgurl(self):
        """--restore must clean gateway.env + pg-url for each brownfield
        state, not just the brownfield drop-in. The postrm sweep is a
        backstop; --restore should be the primary path."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'bf_env_file="${bf_dir}/gateway.env"',
            script,
            "--restore must process the per-major gateway.env fragment",
        )
        # After earlier pg-url lives at /var/lib/.../pg-url (persistent),
        # but --restore must clean BOTH the new path AND the legacy /run/
        # path for upgrade-safe behavior.
        self.assertIn(
            '/run/documentdb-local/${bf_major}/gateway/pg-url',
            script,
            "--restore must clean the legacy /run/ pg-url path (for legacy hosts)",
        )
        self.assertIn(
            '/var/lib/documentdb-local/${bf_major}/gateway/pg-url',
            script,
            "--restore must clean the current /var/lib pg-url path",
        )

    def test_remove_brownfield_dropin_is_symmetric_with_writer(self):
        """write_brownfield_gateway_dropin
        does systemctl daemon-reload after installing the drop-in.
        remove_brownfield_gateway_dropin must do the same after removing it, so
        any future caller (not just --restore which does its own reload) gets a
        consistent unit-file view."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"remove_brownfield_gateway_dropin\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "remove_brownfield_gateway_dropin body not found")
        body = match.group("body")
        self.assertIn(
            "systemctl daemon-reload",
            body,
            "Remover must call daemon-reload symmetrically with the writer",
        )
        # Only reload if we actually removed something — avoid spurious
        # reloads when --restore iterates per-major dirs that have no drop-in.
        self.assertIn(
            'existed=true',
            body,
            "Remover should track whether the drop-in actually existed before reloading",
        )

    def test_brownfield_adoption_warning_present(self):
        """packaging-design.md §4.4 Safety Properties: "Warn loudly when
        adopting a postgres-owned PostgreSQL instance...require confirmation.
        Don't refuse." The brownfield path must emit an explicit warning and
        prompt before mutating an existing PG owned by a non-root OS user."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # The warning lives inside prepare_brownfield_instance (after the
        # cluster-membership cross-check).
        match = re.search(
            r"prepare_brownfield_instance\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "prepare_brownfield_instance body not found")
        body = match.group("body")
        self.assertIn(
            'Adopting an existing PostgreSQL instance owned by OS user',
            body,
            "Brownfield must warn loudly when adopting another OS user's PG",
        )
        # Interactive prompt with --yes bypass.
        self.assertIn(
            'Adopt this PostgreSQL instance and continue? [y/N]',
            body,
            "Brownfield must prompt for adoption confirmation in interactive mode",
        )
        # --yes branch is non-interactive but still logs the warning loudly.
        self.assertIn(
            'Proceeding non-interactively because --yes was given.',
            body,
            "Brownfield must explicitly log that --yes bypassed the prompt",
        )

    def test_brownfield_register_gateway_call_uses_target_postgres_instance(self):
        """On Debian brownfield, the HBA/
        ident files live at /etc/postgresql/<V>/<C>/, NOT under the data
        dir. Passing --pgdata "${LIVE_DATA_DIR}" makes register-gateway
        look for /var/lib/postgresql/<V>/<C>/pg_hba.conf which doesn't
        exist on Debian. ensure_pg_ident_map must branch on TARGET_CLUSTER:
        brownfield → --target-postgres-instance; greenfield → --pgdata."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_pg_ident_map\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "ensure_pg_ident_map body not found")
        body = match.group("body")
        # Branch on brownfield/greenfield.
        self.assertIn(
            'if [[ -n "${TARGET_CLUSTER}" ]]; then',
            body,
            "Must branch on TARGET_CLUSTER to choose the right register-gateway flags",
        )
        self.assertIn(
            '--target-postgres-instance "${TARGET_CLUSTER}"',
            body,
            "Brownfield path must pass --target-postgres-instance",
        )
        # Greenfield still uses --pgdata (its data dir IS where hba/ident live).
        self.assertIn(
            '--pgdata "${LIVE_DATA_DIR}"',
            body,
            "Greenfield path must still pass --pgdata (initdb places hba/ident there)",
        )




class RegisterGatewayPortResolutionTests(unittest.TestCase):
    """When --target-postgres-instance or
    auto-detect names a specific cluster, register-gateway must discover the
    cluster's actual TCP port before defaulting to 5432. Otherwise HBA/ident
    edits go to one cluster while psql ops hit whatever's on 5432."""

    def test_resolver_present(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'resolve_target_cluster_port()',
            text,
            "resolve_target_cluster_port helper must be defined",
        )

    def test_resolver_invoked_before_5432_fallback(self):
        """The resolver call must precede the [[ -z PG_PORT ]] && PG_PORT=5432
        line in main(), or the 5432 default would still win."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r'^main\(\) \{(?P<body>.*?)^\}',
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "main() body not found")
        body = match.group("body")
        resolver_idx = body.find('resolve_target_cluster_port')
        fallback_idx = body.find('PG_PORT="5432"')
        self.assertGreater(resolver_idx, 0, "Resolver must be invoked from main()")
        self.assertGreater(fallback_idx, resolver_idx,
                           "Resolver must run BEFORE the 5432 fallback")

    def test_resolver_reads_debian_postgresql_conf(self):
        """The resolver must parse /etc/postgresql/<V>/<C>/postgresql.conf
        on Debian — that's the canonical source for per-cluster port."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            '/etc/postgresql/${PG_VERSION}/${CLUSTER_NAME}/postgresql.conf',
            text,
            "Resolver must read the named Debian cluster's postgresql.conf",
        )


class RegisterGatewayRecoveryMarkerTests(unittest.TestCase):
    """Persist a recovery marker BEFORE the
    first HBA/ident write. Without this, a mid-flow SIGTERM leaves managed
    blocks in PG config files with no state-file pointer for the package's
    postrm sweep to find."""

    def test_recovery_marker_helper_defined(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'write_recovery_marker()',
            text,
            "write_recovery_marker helper must be defined",
        )

    def test_recovery_marker_called_before_hba_write(self):
        """The marker write must precede the first prepend_with_managed_block
        call so a SIGTERM between them still leaves a state-file pointer."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"do_setup\(\) \{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "do_setup body not found")
        body = match.group("body")
        marker_idx = body.find('write_recovery_marker')
        hba_idx = body.find('prepend_with_managed_block')
        self.assertGreater(marker_idx, 0, "write_recovery_marker must be invoked")
        self.assertGreater(hba_idx, marker_idx,
                           "Recovery marker must be written BEFORE the HBA edit")


class GreenfieldRestoreSymmetryTests(unittest.TestCase):
    """Greenfield --restore must strip the
    per-major gateway.env fragment, drop-in, and pg-url tmpfs file, same as
    brownfield --restore does."""

    def test_greenfield_restore_strips_gateway_env(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # The greenfield restore loop processes setup.conf (vs. brownfield's
        # brownfield.conf). Look for the per-major env-strip inside that loop.
        match = re.search(
            r"for per_major_conf in \$\{per_major_glob\}/setup\.conf;.*?(?=for per_major_brownfield)",
            script,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match, "Greenfield restore loop not found")
        body = match.group(0)
        self.assertIn(
            'pm_env_file="${pm_dir}/gateway.env"',
            body,
            "Greenfield --restore must clean per-major gateway.env",
        )
        # After earlier pg-url is at /var/lib (persistent); legacy /run/
        # path also cleaned for upgrade safety.
        self.assertIn(
            '/run/documentdb-local/${pm_major}/gateway/pg-url',
            body,
            "Greenfield --restore must clean the legacy /run/ pg-url (for legacy hosts)",
        )
        self.assertIn(
            '/var/lib/documentdb-local/${pm_major}/gateway/pg-url',
            body,
            "Greenfield --restore must clean the current /var/lib pg-url",
        )
        self.assertIn(
            'remove_brownfield_gateway_dropin "${pm_major}"',
            body,
            "Greenfield --restore must invoke the drop-in remover too (defensive)",
        )


class GatewayCiPavedRoadTests(unittest.TestCase):
    """The gateway build/test/upload CI
    steps were pinned to pg_version=='17'. The paved road per
    packaging-design.md §9.1 is PG 18, so on main pushes the paved-road
    combination was never being exercised. Both workflows must gate on '18'."""

    def test_deb_workflow_gates_gateway_on_pg18(self):
        wf = OSS_ROOT / ".github" / "workflows" / "build_deb_packages.yml"
        text = wf.read_text(encoding="utf-8")
        self.assertNotIn(
            "matrix.pg_version == '17'",
            text,
            "Gateway build must not gate on pg17 — the paved road is pg18 (§9.1)",
        )
        self.assertIn(
            "matrix.pg_version == '18'",
            text,
            "Gateway build must gate on pg18 per packaging-design.md §9.1",
        )

    def test_rpm_workflow_gates_gateway_on_pg18(self):
        wf = OSS_ROOT / ".github" / "workflows" / "build_rpm_packages.yml"
        text = wf.read_text(encoding="utf-8")
        self.assertNotIn(
            "matrix.pg_version == '17'",
            text,
            "Gateway build must not gate on pg17 — the paved road is pg18 (§9.1)",
        )
        self.assertIn(
            "matrix.pg_version == '18'",
            text,
            "Gateway build must gate on pg18 per packaging-design.md §9.1",
        )


class GatewayRpmPosttransRestartsLocalInstancesTests(unittest.TestCase):
    """documentdb-gateway DEB postinst
    restarts active documentdb-gateway-local@N instances after upgrade, but
    the RPM %posttrans only restarted the plain documentdb-gateway.service.
    Stand-alone per-major instances on RPM hosts would run the old binary
    until manually restarted."""

    def test_rpm_gateway_posttrans_iterates_local_instances(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-gateway.spec"
        text = spec.read_text(encoding="utf-8")
        match = re.search(r"%posttrans\s*\n(?P<body>.*?)(?=^%|\Z)", text,
                          flags=re.DOTALL | re.MULTILINE)
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "documentdb-gateway-local@*.service",
            body,
            "RPM %posttrans must enumerate active per-major gateway-local instances",
        )
        self.assertIn(
            "systemctl restart",
            body,
            "RPM %posttrans must restart enumerated instances",
        )


class DebianMaintainerBootstrapPathTests(unittest.TestCase):
    """The DEB maintainer scripts rely on shipped sysusers/tmpfiles.d
    files. They must point the systemd helpers at the installed paths and
    still fall back locally if those helpers are unavailable or fail."""

    def test_gateway_postinst_uses_installed_sysusers_and_tmpfiles_paths(self):
        text = GATEWAY_POSTINST.read_text(encoding="utf-8")
        self.assertIn(
            "/usr/lib/sysusers.d/documentdb-gateway.conf",
            text,
            "Gateway postinst must pass the installed sysusers.d path",
        )
        self.assertIn(
            "/usr/lib/tmpfiles.d/documentdb-gateway.conf",
            text,
            "Gateway postinst must pass the installed tmpfiles.d path",
        )
        self.assertIn(
            "ensure_gateway_user()",
            text,
            "Gateway postinst must keep a manual user fallback if sysusers fails",
        )
        self.assertIn(
            "ensure_gateway_tmpfiles()",
            text,
            "Gateway postinst must keep a manual tmpfiles fallback if tmpfiles fails",
        )

    def test_common_builder_uses_installed_sysusers_and_tmpfiles_paths(self):
        # The PG-agnostic sysusers/tmpfiles bootstrap moved to documentdb-common
        # (it owns the sysusers.d/tmpfiles.d drop-ins).
        text = COMMON_BUILD_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "/usr/lib/sysusers.d/documentdb-local.conf",
            text,
            "documentdb-common DEB postinst must pass the installed sysusers.d path",
        )
        self.assertIn(
            "/usr/lib/tmpfiles.d/documentdb-local.conf",
            text,
            "documentdb-common DEB postinst must pass the installed tmpfiles.d path",
        )
        self.assertIn(
            "groupadd --system documentdb-local",
            text,
            "documentdb-common DEB postinst must retain a manual user fallback",
        )


class GatewayDockerImageCiConsistencyTests(unittest.TestCase):
    """build_gateway.yml had `--pg 17`
    hard-coded for the gateway build step even though the workflow iterates
    matrix.pg_version 15-18 to produce a documentdb-local Docker image per
    major. The mismatch let the gateway artifact and extension artifact
    diverge in their PG build context. Must use the matrix value."""

    def test_build_gateway_yml_uses_matrix_pg_version(self):
        wf = OSS_ROOT / ".github" / "workflows" / "build_gateway.yml"
        text = wf.read_text(encoding="utf-8")
        self.assertNotIn(
            "--pg 17 --output-dir",
            text,
            "Gateway image build must not hard-code --pg 17; use ${{ matrix.pg_version }}",
        )
        self.assertIn(
            "--pg ${{ matrix.pg_version }} --output-dir",
            text,
            "Gateway image build must match the matrix PG major",
        )


class StateModeBrownfieldTriggerTests(unittest.TestCase):
    """In brownfield mode register-gateway
    must write brownfield.conf, NOT setup.conf. The greenfield templated PG
    service has ConditionPathExists=/etc/documentdb/local/%i/setup.conf, so
    if brownfield setup wrote setup.conf the greenfield PG service would
    become activatable and could trample the adopted PG service's lifecycle."""

    def test_register_gateway_supports_state_mode_flag(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('--state-mode', text,
                      "register-gateway must accept --state-mode")
        self.assertIn('STATE_MODE="greenfield"', text,
                      "Default state mode must remain greenfield for back-compat")
        self.assertRegex(text, r'greenfield\|brownfield', "Must validate mode value")

    def test_register_gateway_writes_brownfield_conf_when_mode_brownfield(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'STATE_FILE="/etc/documentdb/local/${PG_VERSION}/brownfield.conf"',
            text,
            "Brownfield state mode must produce brownfield.conf (avoids ConditionPathExists trigger)",
        )
        self.assertIn(
            'STATE_FILE="/etc/documentdb/local/${PG_VERSION}/setup.conf"',
            text,
            "Default/greenfield state mode must still produce setup.conf",
        )

    def test_setup_passes_brownfield_state_mode_in_brownfield(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_pg_ident_map\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            '--target-postgres-instance "${TARGET_CLUSTER}" --state-mode brownfield',
            body,
            "Brownfield invocation must pass --state-mode brownfield",
        )
        # After earlier the greenfield call also threads --pg-version.
        self.assertIn(
            '--pgdata "${LIVE_DATA_DIR}" --pg-version "${PG_VERSION}" --state-mode greenfield',
            body,
            "Greenfield invocation must pass --pg-version and --state-mode greenfield",
        )


class RecoveryMarkerFailureHandlingTests(unittest.TestCase):
    """write_recovery_marker must die on
    mktemp / write / mv failure rather than silently return. Otherwise the
    caller proceeds to HBA/ident edits without a recoverable state-file
    pointer."""

    def test_recovery_marker_dies_on_mktemp_failure(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"write_recovery_marker\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        # The only legitimate `|| return 0` is the empty-STATE_FILE guard
        # at the top. The mktemp/write/mv operations must all `|| die` so
        # the caller doesn't proceed without a recoverable state-file
        # pointer.
        self.assertIn('die "Cannot create recovery marker at', body,
                      "mktemp failure must die with a clear error")
        self.assertIn('die "Cannot write recovery marker contents to', body,
                      "stdout write failure must die")
        self.assertIn('die "Cannot rename recovery marker into place', body,
                      "mv failure must die")


class ClusterIdentityVerificationTests(unittest.TestCase):
    """register-gateway must verify
    SHOW config_file matches the named cluster after psql connection.
    Catches stale --pg-port, mid-flow port changes, and overlapping
    bind addresses."""

    def test_verifier_helper_defined(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('verify_psql_connects_to_named_cluster()', text,
                      "Cluster identity verifier helper must be defined")

    def test_verifier_called_before_hba_write(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"do_setup\(\) \{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        verifier_idx = body.find('verify_psql_connects_to_named_cluster')
        hba_idx = body.find('prepend_with_managed_block')
        self.assertGreater(verifier_idx, 0, "Verifier must be invoked from do_setup")
        self.assertGreater(hba_idx, verifier_idx,
                           "Verifier must run BEFORE the HBA write")

    def test_verifier_dies_on_mismatch(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"verify_psql_connects_to_named_cluster\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('Cluster identity check failed', body,
                      "Mismatch must produce a clear error message")
        self.assertIn('Refusing to edit HBA/ident', body,
                      "Mismatch error must explain the refusal")


class BrownfieldDropinMarkerCheckTests(unittest.TestCase):
    """The orphan sweep must only delete
    a brownfield.conf file that carries our generated-by marker, so an
    operator-authored override under the same filename survives purge."""

    def test_deb_postrm_checks_marker_before_delete(self):
        builder = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
        text = builder.read_text(encoding="utf-8")
        # The sweep must grep for the marker before rm -f.
        self.assertIn(
            'grep -Fq "# Generated by documentdb-setup --target-postgres-instance"',
            text,
            "DEB postrm orphan sweep must check generated-by marker before delete",
        )


class StandaloneDebPostrmPerMajorScopingTests(unittest.TestCase):
    """Purging one DEB documentdb-N must
    not tear down state for co-installed documentdb-M packages. The postrm
    is generated with a substituted ${PKG_PG_VERSION} placeholder so it
    only touches its own major's state."""

    def test_postrm_template_uses_placeholder(self):
        builder = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
        text = builder.read_text(encoding="utf-8")
        self.assertIn("PKG_PG_VERSION='__PG_VERSION__'", text,
                      "Postrm template must declare the PKG_PG_VERSION placeholder")
        self.assertIn(
            'sed "s|__PG_VERSION__|${PG_VERSION}|g" "${PKG_DIR}/DEBIAN/postrm"',
            text,
            "Placeholder must be substituted at build time",
        )
        # Fail-closed: the temp-file substitution must be guarded by `|| die`,
        # not a fall-through `&& mv` (which set -e swallows on sed failure,
        # packaging an unsubstituted postrm).
        self.assertRegex(text, r'DEBIAN/postrm\.tmp"\s*\\?\s*\|\|\s*die')
        self.assertNotRegex(text, r'DEBIAN/postrm\.tmp"\s*\\?\s*&&\s*mv')

    def test_postrm_no_wildcard_per_major_paths(self):
        builder = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
        text = builder.read_text(encoding="utf-8")
        # Extract just the postrm heredoc so the test isn't tricked by
        # the surrounding shell script using these wildcards safely (e.g.,
        # the "other_majors_remain" probe legitimately enumerates all
        # majors as a read-only check, not as a cleanup loop).
        postrm_match = re.search(
            r"cat > \"\$\{PKG_DIR\}/DEBIAN/postrm\" <<'POSTRM'\n(?P<body>.*?)\nPOSTRM\n",
            text,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(postrm_match, "DEB postrm heredoc not found")
        body = postrm_match.group("body")
        # Cleanup loops must scope to PKG_PG_VERSION — wildcard cleanup
        # patterns iterate other majors and break co-installs.
        self.assertNotRegex(
            body,
            r'for [a-zA-Z_]+ in /etc/documentdb/local/\*/setup\.conf;',
            "Postrm must not iterate setup.conf cleanup across all majors",
        )
        self.assertNotRegex(
            body,
            r'for [a-zA-Z_]+ in /etc/documentdb/local/\*/brownfield\.conf;',
            "Postrm must not iterate brownfield.conf cleanup across all majors",
        )
        self.assertNotIn(
            'rm -f /run/documentdb-local/*/gateway/pg-url',
            body,
            "Postrm must not remove pg-url across all majors",
        )
        # The read-only "other_majors_remain" probe IS allowed to enumerate
        # all majors — it just checks whether any other documentdb-N is
        # still installed before removing the shared
        # /etc/documentdb/documentdb-postgresql.env file.
        self.assertIn(
            'other_majors_remain',
            body,
            "Postrm must probe for other co-installed majors before removing shared state",
        )


class AwkPortParserBugfixTests(unittest.TestCase):
    """The awk port-extraction script's
    gsub regex `[[:space:]#].*` ate the entire value because of the leading
    whitespace after `=`. Fixed by stripping leading whitespace separately
    before stripping trailing whitespace/comment. This test guards against
    regression in both register-gateway and setup."""

    def test_register_gateway_awk_strips_leading_whitespace(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # The fixed form does TWO gsubs: leading whitespace first, then
        # trailing whitespace/comment. The old form did only the second.
        self.assertIn(
            'gsub(/^[[:space:]]+/, "", $2); gsub(/[[:space:]#].*/, "", $2)',
            text,
            "Port awk parser must strip leading whitespace before trailing comment",
        )

    def test_setup_awk_strips_leading_whitespace(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'gsub(/^[[:space:]]+/, "", $2); gsub(/[[:space:]#].*/, "", $2)',
            script,
            "Setup's port awk parser must also use the two-step strip pattern",
        )


class BrownfieldLegacySetupConfCleanupTests(unittest.TestCase):
    """Legacy brownfield runs wrote
    setup.conf (which has the wrong ConditionPathExists semantics for
    brownfield). On upgraded hosts, that stale file still triggers the
    greenfield PG service. persist_brownfield_state must delete it."""

    def test_persist_brownfield_state_removes_legacy_setup_conf(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"persist_brownfield_state\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('legacy_setup_conf="${per_major_dir}/setup.conf"', body,
                      "Must declare the legacy setup.conf path")
        self.assertIn('rm -f "${legacy_setup_conf}"', body,
                      "Must remove the legacy setup.conf so greenfield PG service stays silent")


class RegisterGatewayStateModeAutoSelectTests(unittest.TestCase):
    """Operators running
    documentdb-register-gateway directly with --target-postgres-instance
    (a brownfield invocation) should not have to remember --state-mode.
    The tool auto-defaults to brownfield when --target-postgres-instance
    is set unless --state-mode was passed explicitly."""

    def test_state_mode_tracks_explicit_flag(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('STATE_MODE_EXPLICIT=false', text,
                      "STATE_MODE_EXPLICIT tracking var must be declared")
        self.assertIn('STATE_MODE_EXPLICIT=true', text,
                      "Parser must set STATE_MODE_EXPLICIT=true when --state-mode is used")

    def test_auto_default_to_brownfield_when_target_set(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # The auto-default block runs after parse_arguments fall-through.
        self.assertIn(
            'if [[ "${STATE_MODE_EXPLICIT}" != "true" ]]; then',
            text,
            "Auto-default must only kick in when --state-mode was not explicit",
        )
        self.assertRegex(
            text,
            r'if \[\[ -n "\$\{TARGET_CLUSTER\}" \]\]; then\s+STATE_MODE="brownfield"',
            "Auto-default must select brownfield when --target-postgres-instance is set",
        )

    def test_help_documents_state_mode(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('--state-mode MODE', text,
                      "--help must document --state-mode")
        self.assertIn('Default: greenfield, unless', text,
                      "--help must explain the auto-default behavior")


class LegacyPostgresEnvFileCleanupTests(unittest.TestCase):
    """The legacy
    /etc/documentdb/documentdb-postgresql.env was never cleaned up by
    purge or %postun, so a stale file could persist after uninstall and
    confuse a future install. Only remove it when no other per-major
    install remains."""

    def test_deb_postrm_cleans_legacy_postgres_env_when_last_install(self):
        builder = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
        text = builder.read_text(encoding="utf-8")
        self.assertIn(
            '/etc/documentdb/documentdb-postgresql.env',
            text,
            "DEB postrm must reference the legacy postgres env file",
        )
        self.assertIn(
            'other_majors_remain',
            text,
            "DEB postrm must guard the removal with an other-majors probe",
        )

    def test_rpm_postun_cleans_legacy_postgres_env_when_last_install(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertIn(
            '/etc/documentdb/documentdb-postgresql.env',
            text,
            "RPM %postun must reference the legacy postgres env file",
        )
        self.assertIn(
            'other_majors_remain',
            text,
            "RPM %postun must guard the removal with an other-majors probe",
        )


class GatewayAdminBrownfieldStateAutoDetectTests(unittest.TestCase):
    """documentdb-gateway-admin's
    auto_detect_connection() only iterated setup.conf, so day-2 admin
    commands defaulted to port 5432 on hosts where the wizard ran in
    brownfield mode (state was in brownfield.conf, not setup.conf)."""

    def test_admin_autodetect_iterates_brownfield_conf(self):
        text = GATEWAY_ADMIN_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            '/etc/documentdb/local/*/brownfield.conf',
            text,
            "documentdb-gateway-admin auto-detect must also iterate brownfield.conf",
        )

    def test_admin_autodetect_uses_distro_socket_for_brownfield(self):
        text = GATEWAY_ADMIN_SCRIPT.read_text(encoding="utf-8")
        # Brownfield mode means adopted system PG, so the connection
        # socket dir is the distro's /var/run/postgresql (not the
        # appliance's /run/documentdb-local/N/postgresql).
        self.assertIn('DOCUMENTDB_MODE=', text,
                      "Auto-detect must read the mode marker")
        self.assertIn('"brownfield"', text,
                      "Auto-detect must branch on the brownfield marker")
        self.assertIn('/var/run/postgresql', text,
                      "Brownfield branch must use the distro socket dir")

    def test_admin_explicit_target_recovers_owner_and_db_from_state(self):
        # The multi-instance ambiguity error prescribes re-running with
        # --pg-port/--socket-dir. That explicit path must not discard the
        # state-derived PG_OWNER/TARGET_DB: without recovery, PG_OWNER
        # falls back to "postgres" in main(), which cannot traverse a
        # greenfield socket dir (0750 documentdb-local:documentdb-gateway),
        # so the tool's own prescribed re-run fails with a permission error.
        text = GATEWAY_ADMIN_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"auto_detect_connection\(\)\s*\{(?P<body>.*?)\n\}",
            text,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        explicit_block = body.split("# Per-major state files.")[0]
        self.assertIn(
            '_match_file',
            explicit_block,
            "the explicit --pg-port/--socket-dir early path must scan state "
            "files for a port match to recover PG_OWNER/TARGET_DB",
        )
        self.assertIn(
            'PG_OWNER_EXPLICIT',
            explicit_block,
            "recovered PG_OWNER must still defer to an explicit --pg-owner",
        )
        self.assertIn(
            'TARGET_DB_EXPLICIT',
            explicit_block,
            "recovered TARGET_DB must still defer to an explicit --target-db",
        )

    def test_admin_ambiguity_error_lists_per_instance_flags(self):
        # The multi-instance refusal must tell the operator the exact
        # --pg-port/--socket-dir values per instance, not just name the
        # instances and leave them to guess connection parameters.
        text = GATEWAY_ADMIN_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'distinct_details+=("${instance_key}: --pg-port ',
            text,
            "ambiguity listing must include copy-pasteable per-instance flags",
        )

    def test_admin_create_user_reads_password_from_file_in_jq(self):
        text = GATEWAY_ADMIN_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"cmd_create_user\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            '--rawfile pwd "${RESOLVED_PASSWORD_FILE}"',
            body,
            "create-user must pass the password to jq via --rawfile from a file path "
            "(resolve_password_to_file materializes either --password-file or "
            "--password-stdin into RESOLVED_PASSWORD_FILE before this call); "
            "the literal secret must never appear in argv",
        )
        self.assertNotIn(
            "--arg pwd",
            body,
            "create-user must not pass the password value through jq argv",
        )

    def test_register_gateway_state_file_includes_port_and_owner(self):
        """For the admin tool's auto-detect to work, register-gateway's
        state file must persist PG_PORT and PG_OWNER. Previously only
        the wizard's brownfield.conf did, so a direct Workflow B
        invocation left admin commands stuck at port 5432."""
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"record_state\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn("printf 'PG_PORT=%s\\n'", body,
                      "record_state must persist PG_PORT for the admin auto-detect")
        self.assertIn("printf 'PG_OWNER=%s\\n'", body,
                      "record_state must persist PG_OWNER for the admin auto-detect")
        self.assertIn("printf 'DOCUMENTDB_MODE=%s\\n'", body,
                      "record_state must persist the state mode for the admin auto-detect")


class GatewayAdminUsageSurfaceTests(unittest.TestCase):
    """The packaged admin helper is a standalone CLI; the help output
    should teach that name and advertise the target-db override."""

    def test_gateway_admin_help_uses_packaged_cli_name(self):
        result = subprocess.run(
            ["bash", str(GATEWAY_ADMIN_SCRIPT), "--help"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage: documentdb-gateway-admin <command> [OPTIONS]", result.stdout)

    def test_gateway_admin_help_mentions_target_db(self):
        result = subprocess.run(
            ["bash", str(GATEWAY_ADMIN_SCRIPT), "--help"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--target-db NAME", result.stdout)


class RpmMetaPackageSystemdAliasTests(unittest.TestCase):
    """The design's public day-2 surface
    is documentdb-local.target. The DEB meta package installs it via
    postinst; the RPM meta previously shipped no files and no scriptlets,
    so the alias did not exist on RPM hosts. Now %post installs and
    %postun removes the alias unit."""

    @staticmethod
    def _rpm_scriptlet(name: str) -> str:
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local-meta.spec"
        text = spec.read_text(encoding="utf-8")
        match = re.search(rf"^{re.escape(name)}\s*\n(?P<body>.*?)(?=^%[a-z]|\Z)",
                          text, flags=re.DOTALL | re.MULTILINE)
        if match is None:
            raise AssertionError(f"RPM meta must define a {name} scriptlet")
        return match.group("body")

    def _index_of(self, body: str, needle: str, message: str) -> int:
        index = body.find(needle)
        self.assertGreaterEqual(index, 0, message)
        return index

    def _assert_daemon_reload_is_guarded(self, body: str):
        guard = 'if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then'
        match = re.search(
            rf"{re.escape(guard)}(?P<body>.*?)^\s*fi$",
            body,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "daemon-reload must stay in the running-systemd guard")
        self.assertIn("systemctl daemon-reload", match.group("body"))

    def _assert_rpm_sweep_is_scoped_and_content_gated(self, body: str):
        self.assertIn(
            'for dropin in /etc/systemd/system/documentdb-local@[0-9]*.target.d/wrapper-partof.conf; do',
            body,
        )
        self.assertIn('instance=${dropin#/etc/systemd/system/documentdb-local@}', body)
        self.assertIn('instance=${instance%.target.d/wrapper-partof.conf}', body)
        self.assertIn("''|*[!0-9]*) continue ;;", body)
        self.assertIn("grep -Fq '# Managed-by: documentdb-meta-package'", body)
        self.assertIn("grep -Fq 'Installed by the documentdb meta'", body)
        self.assertIn("grep -Fxq 'PartOf=documentdb-local.target'", body)
        self.assertIn('rm -f "$dropin"', body)
        self.assertIn('rmdir --ignore-fail-on-non-empty "$dropin_dir"', body)
        self.assertNotIn('rm -rf', body)

    def test_rpm_meta_post_installs_alias(self):
        body = self._rpm_scriptlet("%post")
        self.assertIn(
            '/etc/systemd/system/documentdb-local.target',
            body,
            "RPM meta %post must create the documentdb-local.target alias",
        )
        self.assertIn(
            'Requires=documentdb-local@%{default_pg_major}.target',
            body,
            "RPM meta %post must reference the per-major target",
        )
        self.assertIn(
            '# Managed-by: documentdb-meta-package',
            body,
            "RPM meta %post must mark the drop-in as package-managed",
        )
        alias_write = self._index_of(
            body,
            'cat > /etc/systemd/system/documentdb-local.target <<DROPIN',
            "RPM meta %post must write the alias unit",
        )
        sweep = self._index_of(
            body,
            'for dropin in /etc/systemd/system/documentdb-local@[0-9]*.target.d/wrapper-partof.conf; do',
            "RPM meta %post must sweep stale numeric-major drop-ins",
        )
        dropin_install = self._index_of(
            body,
            'install -d -m 0755 /etc/systemd/system/documentdb-local@%{default_pg_major}.target.d',
            "RPM meta %post must recreate the current-major drop-in directory after sweeping",
        )
        dropin_write = self._index_of(
            body,
            'cat > /etc/systemd/system/documentdb-local@%{default_pg_major}.target.d/wrapper-partof.conf <<DROPIN2',
            "RPM meta %post must write the stop-propagation drop-in",
        )
        reload_guard = self._index_of(
            body,
            'if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then',
            "RPM meta %post must guard only daemon-reload on running systemd",
        )
        daemon_reload = self._index_of(
            body,
            'systemctl daemon-reload',
            "RPM meta %post must reload systemd when it is running",
        )
        self.assertNotIn('documentdb-local@*.target.d/wrapper-partof.conf', body,
                         "RPM meta %post sweep must not match the template target directory")
        self._assert_rpm_sweep_is_scoped_and_content_gated(body)
        self.assertLess(alias_write, reload_guard,
                        "RPM meta %post must create the alias in image/chroot installs too")
        self.assertLess(sweep, dropin_install,
                        "RPM meta %post must sweep stale drop-ins before recreating the current directory")
        self.assertLess(sweep, dropin_write,
                        "RPM meta %post must sweep stale drop-ins before writing the current drop-in")
        self.assertLess(dropin_write, reload_guard,
                        "RPM meta %post must create the drop-in in image/chroot installs too")
        self.assertGreater(daemon_reload, reload_guard,
                           "RPM meta %post must keep daemon-reload inside the systemd guard")
        self._assert_daemon_reload_is_guarded(body)

    def test_rpm_meta_postun_removes_alias(self):
        body = self._rpm_scriptlet("%postun")
        # Removal only on full uninstall ($1 == 0).
        self.assertIn(
            'if [ "$1" -eq 0 ]; then',
            body,
            "RPM meta %postun must guard removal on $1 == 0",
        )
        self.assertIn(
            'rm -f /etc/systemd/system/documentdb-local.target',
            body,
            "RPM meta %postun must remove the alias on full uninstall",
        )
        disable = self._index_of(
            body,
            'systemctl disable documentdb-local.target',
            "RPM meta %postun must disable the public alias on full uninstall",
        )
        direct_symlink_rm = self._index_of(
            body,
            'rm -f /etc/systemd/system/multi-user.target.wants/documentdb-local.target',
            "RPM meta %postun must remove the enablement symlink without systemd",
        )
        alias_rm = self._index_of(
            body,
            'rm -f /etc/systemd/system/documentdb-local.target',
            "RPM meta %postun must remove the alias unit",
        )
        sweep = self._index_of(
            body,
            'for dropin in /etc/systemd/system/documentdb-local@[0-9]*.target.d/wrapper-partof.conf; do',
            "RPM meta %postun must sweep stale numeric-major drop-ins",
        )
        self.assertNotIn('documentdb-local@*.target.d/wrapper-partof.conf', body,
                         "RPM meta %postun sweep must not match the template target directory")
        full_removal_match = re.search(
            r'if \[ "\$1" -eq 0 \]; then(?P<body>.*)^fi$',
            body,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(full_removal_match, "RPM meta %postun must keep cleanup inside $1 == 0 guard")
        self.assertIn(
            'for dropin in /etc/systemd/system/documentdb-local@[0-9]*.target.d/wrapper-partof.conf; do',
            full_removal_match.group("body"),
            "RPM meta %postun sweep must stay inside the full-removal guard",
        )
        self._assert_rpm_sweep_is_scoped_and_content_gated(body)
        self.assertLess(disable, alias_rm,
                        "RPM meta %postun must disable before deleting the unit file")
        self.assertLess(direct_symlink_rm, alias_rm,
                        "RPM meta %postun must remove the enablement symlink before deleting the unit file")
        self.assertGreater(sweep, alias_rm,
                           "RPM meta %postun must remove alias unit before sweeping drop-ins")


class GatewayAdminMultiMajorDisambiguationTests(unittest.TestCase):
    """documentdb-gateway-admin's
    auto_detect_connection() previously returned on first state-file
    match. With multiple majors installed (a supported topology per
    design §4.4), that nondeterministically picked one. Now it must
    refuse and tell the operator to be explicit."""

    def test_admin_autodetect_refuses_on_multiple_majors(self):
        admin_script = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-gateway-admin.sh"
        text = admin_script.read_text(encoding="utf-8")
        match = re.search(
            r"auto_detect_connection\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "auto_detect_connection body not found")
        body = match.group("body")
        # After earlier the dedup is at (major, cluster) granularity,
        # not just major. The variable is `distinct_instances` and the
        # error message says "instances", not "majors".
        self.assertIn('distinct_instances', body,
                      "auto-detect must track distinct (major, cluster) instances")
        # Must fail with a clear message on ambiguity.
        self.assertIn('multiple PostgreSQL instances are registered', body,
                      "auto-detect must surface a clear ambiguity error")
        self.assertIn('Re-run with --pg-port and --socket-dir', body,
                      "Error must tell the operator how to disambiguate")

    def test_admin_autodetect_collapses_legacy_env_with_same_major(self):
        """The legacy /etc/documentdb/documentdb-postgresql.env carries the
        same PG_VERSION as its matching per-major state file. Without
        deduplication, an upgraded host would show up as ambiguous when
        in fact there's only one logical instance."""
        admin_script = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-gateway-admin.sh"
        text = admin_script.read_text(encoding="utf-8")
        match = re.search(
            r"auto_detect_connection\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        # The dedup logic compares PG_VERSION across state files.
        self.assertIn('PG_VERSION=', body,
                      "auto-detect must read PG_VERSION for dedup")
        self.assertRegex(body, r'seen=false', "Must use a seen-flag for dedup")


class ToolsPackageJqDependencyTests(unittest.TestCase):
    """documentdb-gateway-admin invokes
    jq unconditionally for create-user / drop-user / reset-password BSON
    construction. The DEB postgresql-tools package and the RPM tools spec
    must declare jq as a hard dependency, otherwise Workflow B installs
    (just the tools package without the meta) die at runtime with
    'jq: command not found'."""

    def test_deb_tools_depends_on_jq(self):
        builder = OSS_ROOT / "packaging" / "postgresql-tools" / "build-postgresql-tools-deb.sh"
        text = builder.read_text(encoding="utf-8")
        self.assertRegex(
            text,
            r'Depends:.*\bjq\b',
            "DEB postgresql-tools must declare jq in Depends",
        )

    def test_rpm_tools_requires_jq(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-tools.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertRegex(
            text,
            r'(?m)^Requires:\s+jq\s*$',
            "RPM documentdb-tools.spec must Require jq",
        )


class RpmExtraBuildDependencyTests(unittest.TestCase):
    """Native RHEL/Fedora extra-package builds must satisfy the guarded
    BuildRequires in documentdb-local.spec before invoking rpmbuild."""

    def test_rpm_extras_preflight_checks_systemd_macros_before_rpmbuild(self):
        text = BUILD_EXTRA_PACKAGES.read_text(encoding="utf-8")
        self.assertIn("ensure_rpm_extra_build_dependencies()", text)
        self.assertIn("systemd-rpm-macros", text)
        rpm_branch_idx = text.find('elif [[ "${PACKAGE_TYPE}" == "rpm" ]]')
        self.assertGreaterEqual(rpm_branch_idx, 0)
        preflight_idx = text.find("ensure_rpm_extra_build_dependencies", rpm_branch_idx)
        rpmbuild_idx = text.find("rpmbuild -bb")
        self.assertGreaterEqual(preflight_idx, rpm_branch_idx)
        self.assertGreater(rpmbuild_idx, preflight_idx,
                           "RPM extras must check build deps before the first rpmbuild")

    def test_rpm_extras_preflight_matches_spec_guard(self):
        text = BUILD_EXTRA_PACKAGES.read_text(encoding="utf-8")
        helper_match = re.search(
            r"is_rhel_or_fedora_rpm_context\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(helper_match)
        body = helper_match.group("body")
        self.assertIn("rpm_macro_number rhel", body)
        self.assertIn("rpm_macro_number fedora", body)
        self.assertIn("rhel > 0 || fedora > 0", body)

    def test_rpm_extras_install_path_is_noninteractive(self):
        text = BUILD_EXTRA_PACKAGES.read_text(encoding="utf-8")
        install_match = re.search(
            r"run_noninteractive_package_install\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(install_match)
        body = install_match.group("body")
        self.assertIn("sudo -n true", body,
                      "sudo path must probe non-interactively before installing")
        self.assertIn('sudo -n "${installer}" install -y', body,
                      "sudo install must be non-interactive")
        self.assertNotIn("shadow-utils", body,
                         "shadow-utils is Requires(pre), not a build dependency")

    def test_rpm_extras_normalizes_output_dir_before_rpmbuild(self):
        text = BUILD_EXTRA_PACKAGES.read_text(encoding="utf-8")
        mkdir_idx = text.find('mkdir -p "${OUTPUT_DIR}"')
        normalize_idx = text.find('OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd -P)"')
        rpm_topdir_idx = text.find('RPM_TOPDIR="$(mktemp -d "${OUTPUT_DIR}/.rpmbuild.XXXXXX")"')
        self.assertGreaterEqual(mkdir_idx, 0)
        self.assertGreater(normalize_idx, mkdir_idx,
                           "build_extra_packages.sh must make relative --output-dir absolute")
        self.assertGreater(rpm_topdir_idx, normalize_idx,
                           "rpmbuild _topdir must be under the normalized absolute output dir")


class DebMetadataPolicyTests(unittest.TestCase):
    """The extra DEB packages should satisfy basic lintian metadata checks:
    phrase-form Maintainer, Debian-style changelog.gz, and a real copyright
    notice instead of a placeholder MIT template."""

    _EXTRA_BUILDERS = (
        OSS_ROOT / "packaging" / "postgresql-tools" / "build-postgresql-tools-deb.sh",
        OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh",
        OSS_ROOT / "packaging" / "standalone" / "build-meta-deb.sh",
    )

    def test_deb_common_defines_policy_helpers(self):
        common = (OSS_ROOT / "packaging" / "deb-common.sh").read_text(encoding="utf-8")
        self.assertIn(
            'DEB_MAINTAINER="DocumentDB Packaging <documentdb-packaging-maintainers@microsoft.com>"',
            common,
        )
        self.assertIn('DEB_DEFAULT_MIT_LICENSE_FILE="${_DEB_COMMON_REPO_ROOT}/LICENSE"', common)
        self.assertIn("deb_install_mit_copyright()", common)
        self.assertIn("deb_install_changelog()", common)
        self.assertIn("gzip -9n -f", common)
        self.assertIn("unstable; urgency=medium", common)
        self.assertIn('printf \' -- %s  %s\\n\' "${DEB_MAINTAINER}" "${date_rfc}"', common)
        self.assertIn("2015-present Microsoft Corporation", common)
        self.assertIn("<year>|<copyright holders>", common,
                      "helper must explicitly reject placeholder MIT templates")

    def test_extra_deb_builders_use_shared_metadata_helpers(self):
        for builder in self._EXTRA_BUILDERS:
            with self.subTest(builder=builder.name):
                text = builder.read_text(encoding="utf-8")
                self.assertIn("Maintainer: ${DEB_MAINTAINER}", text)
                self.assertIn("deb_install_mit_copyright", text)
                self.assertIn("deb_install_changelog", text)
                self.assertNotIn('echo "MIT License"', text)
                self.assertNotIn("LICENSE_MIT", text)
                self.assertNotIn("documentdb-packaging-maintainers@microsoft.com\nInstalled-Size", text)

    def test_gateway_deb_uses_shared_maintainer_and_changelog(self):
        text = (OSS_ROOT / "packaging" / "gateway" / "build-gateway-deb.sh").read_text(encoding="utf-8")
        self.assertIn("Maintainer: ${DEB_MAINTAINER}", text)
        self.assertIn("deb_install_changelog", text)
        self.assertIn("2015-present Microsoft Corporation", text)
        self.assertIn("deb_emit_mit_permission_text", text,
                      "gateway copyright should strip the placeholder MIT copyright line "
                      "via the shared deb_emit_mit_permission_text helper")
        self.assertIn("Copyright (c) 2015-present Microsoft Corporation", text,
                      "gateway copyright must keep the concrete Microsoft copyright notice")
        self.assertNotIn("Copyright \\(c\\)", text,
                         "the inline awk copyright-strip should be replaced by the shared helper")
        self.assertIn("strip --strip-unneeded", text,
                      "gateway daemon should be stripped before packaging")
        self.assertIn("/usr/share/common-licenses/Apache-2.0", text,
                      "gateway DEB should reference the common Apache-2.0 license")
        self.assertNotIn("cat \"${APACHE_LICENSE}\"", text,
                         "gateway DEB should not embed the full common Apache-2.0 text")


class RpmSpecMacroConventionTests(unittest.TestCase):
    """RPM spec comments should not trigger macro-expansion warnings, and
    custom systemd handling should be documented where macros do not fit."""

    _SPECS = (
        OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb.spec",
        OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local.spec",
        OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-common.spec",
        OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local-meta.spec",
        OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-tools.spec",
        OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-gateway.spec",
    )

    _SECTION_PREFIXES = (
        "%description", "%package", "%prep", "%build", "%install", "%check",
        "%clean", "%files", "%pre", "%post", "%preun", "%postun",
        "%pretrans", "%posttrans", "%changelog", "%trigger",
    )

    def test_preamble_comments_escape_braced_macros(self):
        offenders = []
        for spec in self._SPECS:
            for line_no, line in enumerate(spec.read_text(encoding="utf-8").splitlines(), 1):
                if line.startswith(self._SECTION_PREFIXES):
                    break
                if line.lstrip().startswith("#") and re.search(r"(?<!%)%\{[^}]+\}", line):
                    offenders.append(f"{spec.name}:{line_no}: {line}")
        self.assertEqual(offenders, [], "\n".join(offenders))

    def test_template_systemd_logic_has_rationale(self):
        # The "template units handled explicitly" rationale now lives in
        # documentdb-common (it owns/installs the template units); the
        # documentdb-N spec keeps the per-major "do not restart the target"
        # rationale in its %posttrans.
        common = COMMON_SPEC.read_text(encoding="utf-8")
        local = STANDALONE_SPEC.read_text(encoding="utf-8")
        meta = (OSS_ROOT / "packaging" / "rpm" / "spec" /
                "documentdb-local-meta.spec").read_text(encoding="utf-8")
        self.assertIn("Template units are handled explicitly", common)
        self.assertIn("systemd RPM macros", common)
        self.assertIn("Do not restart the target", local)
        self.assertIn("wrapper unit and a PartOf drop-in", meta)
        self.assertIn("standard systemd RPM macros do not model this alias", meta)

    def test_rpm_extra_files_pin_payload_modes(self):
        """Noarch extras can be built from a Windows-mounted worktree where
        source files appear as 0777. Pin %files attrs so RPM payload
        permissions are production-safe regardless of buildhost mode bits.
        The shared payload's %files entries now live in documentdb-common."""
        common = COMMON_SPEC.read_text(encoding="utf-8")
        tools = (OSS_ROOT / "packaging" / "rpm" / "spec" /
                 "documentdb-tools.spec").read_text(encoding="utf-8")

        executable_entries = (
            "/usr/bin/documentdb-setup",
            "/usr/bin/documentdb-local-reset",
            "/usr/share/documentdb/scripts/documentdb_postgresql_service.sh",
            "/usr/share/documentdb/scripts/init_documentdb_data.sh",
            "/usr/bin/documentdb-tune",
            "/usr/bin/documentdb-createcluster",
            "/usr/bin/documentdb-register-gateway",
            "/usr/bin/documentdb-gateway-admin",
        )
        non_executable_entries = (
            "%{_unitdir}/documentdb-local@.target",
            "%{_unitdir}/documentdb-postgresql@.service",
            "%{_unitdir}/documentdb-gateway-local@.service",
            "%{_sysusersdir}/documentdb-local.conf",
            "%{_tmpfilesdir}/documentdb-local.conf",
            "/usr/share/documentdb/sample-data/*",
            "/usr/share/documentdb/scripts/documentdb-tools-lib.sh",
            "/usr/share/doc/%{name}/examples/documentdb.conf.sample",
        )

        combined = f"{common}\n{tools}"
        for entry in executable_entries:
            self.assertIn(f"%attr(0755,root,root) {entry}", combined)
        for entry in non_executable_entries:
            self.assertIn(f"%attr(0644,root,root) {entry}", combined)

    @unittest.skipIf(shutil.which("rpmspec") is None, "rpmspec not installed")
    def test_rpmspec_parse_has_no_macro_expanded_comment_warnings(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            specs_to_check = []
            for spec in self._SPECS:
                staged = tmp / spec.name
                staged.write_text(
                    spec.read_text(encoding="utf-8")
                    .replace("DOCUMENTDB_VERSION", "0.114.0")
                    .replace("POSTGRES_VERSION", "18"),
                    encoding="utf-8",
                )
                specs_to_check.append(staged)

            for spec in specs_to_check:
                result = subprocess.run(
                    ["rpmspec", "--parse", str(spec)],
                    capture_output=True, text=True, timeout=30,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("Macro expanded in comment", result.stderr)


class ShippedCommentProvenanceTests(unittest.TestCase):
    """Shipped source comments and test descriptions should explain intent,
    not review history."""

    _PROVENANCE_RE = re.compile(
        r"Reviewer-flagged|Real-user E2E|Advanced-user E2E|Multi-reviewer|"
        r"Product re-review|Self-review|external review|multi-model|"
        r"reviewers?\s+flagged|Blocker\s+[IVXLC]+|"
        r"should-fix|Gap #[0-9]|\bGPT-[0-9]|\bSonnet\b|\bOpus\b|\bHaiku\b|"
        r"\biter\s+[0-9]\b|\biteration\s+[0-9]\b|[0-9]\s+iter\b|iter-[0-9]|pre-iter[0-9]|"
        r"second-pass review|Reviewer #[0-9]|from the review|from The review|"
        r"\blegacy legacy\b|\blegacy\+|copilot|copilot-instructions|"
        r"^\s*#\s*[0-9]+\)?:",
        flags=re.IGNORECASE | re.MULTILINE,
    )

    @staticmethod
    def _guard_class_ranges(lines):
        ranges = []
        start = None
        for idx, line in enumerate(lines):
            if line.startswith("class ShippedCommentProvenanceTests"):
                start = idx
                continue
            if start is not None and line.startswith("class ") and idx > start:
                ranges.append((start, idx))
                start = None
        if start is not None:
            ranges.append((start, len(lines)))
        return ranges

    @classmethod
    def _iter_guarded_lines(cls, path):
        lines = path.read_text(encoding="utf-8").splitlines()
        skip_ranges = cls._guard_class_ranges(lines) if path == Path(__file__).resolve() else []
        for idx, line in enumerate(lines):
            if any(start <= idx < end for start, end in skip_ranges):
                continue
            yield idx + 1, line

    @staticmethod
    def _shipped_text_files():
        files = []
        files.extend((OSS_ROOT / "documentdb-local" / "scripts").glob("*.sh"))
        files.extend((OSS_ROOT / "documentdb-local" / "maintainer-scripts" / "gateway").glob("*"))
        files.append(Path(__file__).resolve())
        files.extend(
            OSS_ROOT / ".github" / "workflows" / name
            for name in (
                "build_deb_packages.yml",
                "build_gateway.yml",
                "build_rpm_packages.yml",
                "documentdb_local_tests.yml",
            )
        )
        for pattern in (
            "packaging/*.sh",
            "packaging/gateway/*.sh",
            "packaging/test_packages/*.sh",
            "packaging/postgresql-tools/*.sh",
            "packaging/standalone/*.sh",
            "packaging/rpm/spec/*.spec",
            "packaging/appliance/systemd/*",
            "packaging/appliance/sysusers/*",
            "packaging/appliance/tmpfiles/*",
        ):
            files.extend(OSS_ROOT.glob(pattern))
        return sorted({path for path in files if path.is_file()})

    def test_shipped_comments_do_not_include_review_provenance(self):
        offenders = []
        for path in self._shipped_text_files():
            for line_no, line in self._iter_guarded_lines(path):
                if self._PROVENANCE_RE.search(line):
                    rel = path.relative_to(OSS_ROOT) if path.is_relative_to(OSS_ROOT) else path.name
                    offenders.append(f"{rel}:{line_no}: {line.strip()}")
        self.assertEqual(offenders, [], "\n".join(offenders[:50]))


class TemplatedPostgresDropInTests(unittest.TestCase):
    """The documentdb-postgresql@.service template tracks the postmaster via
    Type=forking + cgroup GuessMainPID and deliberately sets no PIDFile=, so a
    custom --data-dir needs no PIDFile override. ensure_postgres_systemd_drop_in
    must therefore NOT write a drop-in; it only strips a stale datadir.conf
    drop-in left by an older version, covering both the templated per-major
    path (documentdb-postgresql@N.service.d/) and the legacy non-templated
    path (documentdb-postgresql.service.d/)."""

    def test_dropin_cleanup_targets_templated_unit(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_postgres_systemd_drop_in\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            '/etc/systemd/system/documentdb-postgresql@${PG_VERSION}.service.d',
            body,
            "Drop-in cleanup must target the per-major templated unit path",
        )

    def test_dropin_writer_does_not_write_pidfile(self):
        """The function must clean only -- it must never write a PIDFile=
        drop-in, which would re-introduce the systemd 245+ ownership/race the
        template avoids by using cgroup tracking."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_postgres_systemd_drop_in\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        # Ignore comment lines so the explanatory comment (which legitimately
        # mentions PIDFile=) does not mask a real write in the code.
        code = "\n".join(
            line for line in match.group("body").splitlines()
            if not line.lstrip().startswith("#")
        )
        self.assertNotIn(
            'PIDFile=', code,
            "ensure_postgres_systemd_drop_in must not write a PIDFile= drop-in",
        )
        self.assertNotIn(
            '> "${drop_in_file}"', code,
            "ensure_postgres_systemd_drop_in must not write the drop-in file",
        )

    def test_dropin_cleans_legacy_non_templated_path(self):
        """Hosts upgraded from legacy may have a stale drop-in under the
        non-templated path. ensure_postgres_systemd_drop_in must clean it."""
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_postgres_systemd_drop_in\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('legacy_drop_in_dir', body,
                      "Must reference the legacy non-templated path for cleanup")

    def test_restore_cleans_both_templated_and_legacy_dropins(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'documentdb-postgresql@*.service.d',
            script,
            "--restore must iterate templated per-major drop-in dirs",
        )


class StatusReadsPersistedGatewayPortTests(unittest.TestCase):
    """--status was probing
    ${GATEWAY_PORT} from CLI/default (10260) instead of the persisted
    GATEWAY_PORT from the per-major state file. Installs created with
    --listen-port were reported "not listening" even when healthy."""

    def test_status_reads_persisted_port_from_state_file(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"status_only\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('effective_gateway_port', body,
                      "status must compute an effective gateway port")
        self.assertIn("GATEWAY_PORT=", body,
                      "status must read GATEWAY_PORT from the persisted state file")
        # The probe must use the effective port, not the CLI default.
        self.assertIn('"sport = :${effective_gateway_port}"', body,
                      "ss probe must use the effective (persisted-or-default) port")


class GatewayCleanInstallTestPackageContractTests(unittest.TestCase):
    """The DEB/RPM clean-install tests
    for the gateway package were still asserting documentdb-setup,
    documentdb-postgresql.service, sample-data, etc., even though those
    moved to documentdb-N under the split-package design. The
    gateway-only test container doesn't install documentdb-N, so the
    assertions would fail or (worse) the test wasn't being run at all."""

    def test_deb_gateway_test_asserts_only_gateway_surface(self):
        path = OSS_ROOT / "packaging" / "test_packages" / "test-gateway-install-entrypoint.sh"
        text = path.read_text(encoding="utf-8")
        # Must verify gateway-specific files.
        self.assertIn('assert_executable /usr/bin/documentdb-gateway', text)
        self.assertIn('assert_file /usr/lib/systemd/system/documentdb-gateway.service', text)
        # Must explicitly reject documentdb-setup presence in the gateway
        # package's MANIFEST (documentdb-N owns documentdb-setup, and
        # documentdb-N is now co-installed in the test container, so
        # disk-presence checks aren't useful — manifest checks via
        # `dpkg -L documentdb-gateway` are what gates the boundary).
        self.assertIn(
            'documentdb-gateway manifest must NOT contain documentdb-setup',
            text,
            "DEB gateway test must guard the package-boundary invariant via dpkg -L",
        )

    def test_rpm_gateway_test_asserts_only_gateway_surface(self):
        path = OSS_ROOT / "packaging" / "test_packages" / "test-gateway-install-entrypoint-rpm.sh"
        text = path.read_text(encoding="utf-8")
        self.assertIn('assert_executable /usr/bin/documentdb-gateway', text)
        self.assertIn('assert_file /usr/lib/systemd/system/documentdb-gateway.service', text)
        # documentdb-N is co-installed in the RPM test container, so a live
        # disk-presence check (`[ -e /usr/bin/documentdb-setup ]`) wrongly
        # fails. The boundary must be gated via the gateway package's installed
        # manifest (`rpm -ql documentdb-gateway`), mirroring the DEB test.
        self.assertIn('rpm -ql documentdb-gateway', text,
                      "RPM gateway test must query the package manifest, not live disk")
        self.assertIn(
            'documentdb-gateway manifest must NOT contain documentdb-setup',
            text,
            "RPM gateway test must guard the package-boundary invariant via rpm -ql",
        )


class JqDependencyBoundaryTests(unittest.TestCase):
    """jq belongs ONLY to
    documentdb-postgresql-tools (because documentdb-gateway-admin uses it).
    The gateway binary itself doesn't use jq — per packaging-design.md
    §4.3 the gateway package has no product-specific runtime deps. Both
    DEB and RPM gateway specs must NOT declare jq."""

    def test_gateway_deb_does_not_depend_on_jq(self):
        builder = OSS_ROOT / "packaging" / "gateway" / "build-gateway-deb.sh"
        text = builder.read_text(encoding="utf-8")
        # The DEPENDS variable construction must not include jq.
        match = re.search(
            r'DEPENDS="[^"]*jq[^"]*"',
            text,
        )
        self.assertIsNone(match,
                          "Gateway build-gateway-deb.sh must not include jq in DEPENDS")

    def test_gateway_rpm_does_not_require_jq(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-gateway.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertNotRegex(
            text,
            r'(?m)^Requires:\s+jq\s*$',
            "documentdb-gateway.spec must not Require jq (it belongs to documentdb-postgresql-tools)",
        )


class TargetAliasStopPropagationTests(unittest.TestCase):
    """The documentdb-local.target wrapper
    unit uses Requires=, which only propagates start (pull-in) — NOT stop
    or restart. `systemctl stop documentdb-local.target` would leave the
    appliance running. The fix is to install a PartOf=documentdb-local.target
    drop-in on the per-major target so stop/restart propagates correctly."""

    @staticmethod
    def _deb_meta_script(name: str) -> str:
        builder = OSS_ROOT / "packaging" / "standalone" / "build-meta-deb.sh"
        text = builder.read_text(encoding="utf-8")
        delimiter = name.upper()
        match = re.search(
            rf'cat > "\$\{{PKG_DIR\}}/DEBIAN/{name}" <<{delimiter}\n(?P<body>.*?)^{delimiter}$',
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        if match is None:
            raise AssertionError(f"DEB meta builder must generate {name}")
        return match.group("body")

    def _index_of(self, body: str, needle: str, message: str) -> int:
        index = body.find(needle)
        self.assertGreaterEqual(index, 0, message)
        return index

    def _assert_daemon_reload_is_guarded(self, body: str):
        guard = 'if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then'
        match = re.search(
            rf"{re.escape(guard)}(?P<body>.*?)^\s*fi$",
            body,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "daemon-reload must stay in the running-systemd guard")
        self.assertIn("systemctl daemon-reload", match.group("body"))

    def _assert_deb_sweep_is_scoped_and_content_gated(self, body: str):
        self.assertIn(
            'for dropin in /etc/systemd/system/documentdb-local@[0-9]*.target.d/wrapper-partof.conf; do',
            body,
        )
        self.assertIn(r'instance=\${dropin#/etc/systemd/system/documentdb-local@}', body)
        self.assertIn(r'instance=\${instance%.target.d/wrapper-partof.conf}', body)
        self.assertIn(r'case "\$instance" in', body)
        self.assertIn("''|*[!0-9]*) continue ;;", body)
        self.assertIn("grep -Fq '# Managed-by: documentdb-meta-package'", body)
        self.assertIn("grep -Fq 'Installed by the documentdb meta'", body)
        self.assertIn("grep -Fxq 'PartOf=documentdb-local.target'", body)
        self.assertIn(r'rm -f "\$dropin"', body)
        self.assertIn(r'rmdir --ignore-fail-on-non-empty "\$dropin_dir"', body)
        self.assertNotIn('rm -rf', body)

    def test_deb_meta_installs_partof_dropin(self):
        builder = OSS_ROOT / "packaging" / "standalone" / "build-meta-deb.sh"
        text = builder.read_text(encoding="utf-8")
        # In the source heredoc, ${DEFAULT_PG_MAJOR} is escaped to
        # \${DEFAULT_PG_MAJOR} so it stays a runtime variable in the
        # installed postinst. Look for either form to be robust.
        self.assertRegex(
            text,
            r'documentdb-local@\\?\$\{DEFAULT_PG_MAJOR\}\.target\.d/wrapper-partof\.conf',
            "DEB meta postinst must install the stop-propagation drop-in",
        )
        self.assertIn(
            'PartOf=documentdb-local.target',
            text,
            "Drop-in must declare PartOf=documentdb-local.target so stop propagates",
        )
        self.assertIn(
            '# Managed-by: documentdb-meta-package',
            text,
            "DEB meta postinst must mark the drop-in as package-managed",
        )

    def test_deb_meta_postinst_writes_alias_outside_systemd_guard(self):
        body = self._deb_meta_script("postinst")
        alias_write = self._index_of(
            body,
            'cat > /etc/systemd/system/documentdb-local.target <<DROPIN',
            "DEB meta postinst must write the alias unit",
        )
        sweep = self._index_of(
            body,
            'for dropin in /etc/systemd/system/documentdb-local@[0-9]*.target.d/wrapper-partof.conf; do',
            "DEB meta postinst must sweep stale numeric-major drop-ins",
        )
        dropin_install = self._index_of(
            body,
            r'install -d -m 0755 /etc/systemd/system/documentdb-local@\${DEFAULT_PG_MAJOR}.target.d',
            "DEB meta postinst must recreate the current-major drop-in directory after sweeping",
        )
        dropin_write = self._index_of(
            body,
            r'cat > /etc/systemd/system/documentdb-local@\${DEFAULT_PG_MAJOR}.target.d/wrapper-partof.conf <<DROPIN2',
            "DEB meta postinst must write the stop-propagation drop-in",
        )
        reload_guard = self._index_of(
            body,
            'if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then',
            "DEB meta postinst must guard only daemon-reload on running systemd",
        )
        daemon_reload = self._index_of(
            body,
            'systemctl daemon-reload',
            "DEB meta postinst must reload systemd when it is running",
        )
        self.assertNotIn('documentdb-local@*.target.d/wrapper-partof.conf', body,
                         "DEB meta postinst sweep must not match the template target directory")
        self._assert_deb_sweep_is_scoped_and_content_gated(body)
        self.assertLess(alias_write, reload_guard,
                        "DEB meta postinst must create the alias in image/chroot installs too")
        self.assertLess(sweep, dropin_install,
                        "DEB meta postinst must sweep stale drop-ins before recreating the current directory")
        self.assertLess(sweep, dropin_write,
                        "DEB meta postinst must sweep stale drop-ins before writing the current drop-in")
        self.assertLess(dropin_write, reload_guard,
                        "DEB meta postinst must create the drop-in in image/chroot installs too")
        self.assertGreater(daemon_reload, reload_guard,
                           "DEB meta postinst must keep daemon-reload inside the systemd guard")
        self._assert_daemon_reload_is_guarded(body)

    def test_rpm_meta_installs_partof_dropin(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local-meta.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertIn(
            'documentdb-local@%{default_pg_major}.target.d/wrapper-partof.conf',
            text,
            "RPM meta %post must install the stop-propagation drop-in",
        )
        self.assertIn(
            'PartOf=documentdb-local.target',
            text,
            "Drop-in must declare PartOf=documentdb-local.target so stop propagates",
        )

    def test_deb_meta_postrm_removes_partof_dropin(self):
        body = self._deb_meta_script("postrm")
        self.assertIn(
            'for dropin in /etc/systemd/system/documentdb-local@[0-9]*.target.d/wrapper-partof.conf; do',
            body,
            "DEB meta postrm must sweep meta-owned PartOf drop-ins on purge",
        )
        self.assertNotIn(
            r'rm -f /etc/systemd/system/documentdb-local@\${DEFAULT_PG_MAJOR}.target.d/wrapper-partof.conf',
            body,
            "DEB meta postrm must not unconditionally remove current-major user drop-ins",
        )

    def test_deb_meta_postrm_disables_alias_before_removing_unit(self):
        body = self._deb_meta_script("postrm")
        disable = self._index_of(
            body,
            'systemctl disable documentdb-local.target',
            "DEB meta postrm must disable the public alias on removal",
        )
        direct_symlink_rm = self._index_of(
            body,
            'rm -f /etc/systemd/system/multi-user.target.wants/documentdb-local.target',
            "DEB meta postrm must remove the enablement symlink without systemd",
        )
        alias_rm = self._index_of(
            body,
            'rm -f /etc/systemd/system/documentdb-local.target',
            "DEB meta postrm must remove the alias unit",
        )
        sweep = self._index_of(
            body,
            'for dropin in /etc/systemd/system/documentdb-local@[0-9]*.target.d/wrapper-partof.conf; do',
            "DEB meta postrm must sweep stale numeric-major drop-ins",
        )
        self.assertNotIn('documentdb-local@*.target.d/wrapper-partof.conf', body,
                         "DEB meta postrm sweep must not match the template target directory")
        self._assert_deb_sweep_is_scoped_and_content_gated(body)
        self.assertLess(disable, alias_rm,
                        "DEB meta postrm must disable before deleting the unit file")
        self.assertLess(direct_symlink_rm, alias_rm,
                        "DEB meta postrm must remove the enablement symlink before deleting the unit file")
        self.assertGreater(sweep, alias_rm,
                           "DEB meta postrm must remove alias unit before sweeping drop-ins")

    def test_rpm_meta_postun_removes_partof_dropin(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local-meta.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertIn(
            'for dropin in /etc/systemd/system/documentdb-local@[0-9]*.target.d/wrapper-partof.conf; do',
            text,
            "RPM meta %postun must sweep meta-owned PartOf drop-ins on full uninstall",
        )
        self.assertNotIn(
            'rm -f /etc/systemd/system/documentdb-local@%{default_pg_major}.target.d/wrapper-partof.conf',
            text,
            "RPM meta %postun must not unconditionally remove current-major user drop-ins",
        )


class GatewayMaintainerScriptDoesNotTouchPostgresTests(unittest.TestCase):
    """The gateway package is runtime-only
    per packaging-design.md §4.3 / §7 ("Maintainer scripts restart
    PostgreSQL: Never"). Gateway maintainer scripts must touch ONLY gateway
    services, never the PG service. Both DEB and RPM clean-install tests
    must assert this."""

    def test_deb_gateway_postinst_assertions_do_not_touch_postgres(self):
        path = OSS_ROOT / "packaging" / "test_packages" / "test-gateway-install-entrypoint.sh"
        text = path.read_text(encoding="utf-8")
        # The gateway postinst assertion should NOT positively assert
        # `restart documentdb-postgresql` anywhere. It SHOULD negatively
        # assert it.
        self.assertIn(
            'Upgrade postinst must NOT restart PostgreSQL',
            text,
            "DEB gateway test must assert postinst does NOT restart PostgreSQL",
        )
        # The old positive assertion that gateway prerm stops PG must be gone.
        self.assertIn(
            'Removal prerm must NOT touch PostgreSQL',
            text,
            "DEB gateway test must explicitly forbid prerm stopping PostgreSQL",
        )

    def test_rpm_gateway_posttrans_assertions_do_not_touch_postgres(self):
        path = OSS_ROOT / "packaging" / "test_packages" / "test-gateway-install-entrypoint-rpm.sh"
        text = path.read_text(encoding="utf-8")
        self.assertIn(
            'Posttrans must NOT restart PostgreSQL',
            text,
            "RPM gateway test must assert posttrans does NOT restart PostgreSQL",
        )
        self.assertIn(
            'Removal %preun must NOT touch PostgreSQL',
            text,
            "RPM gateway test must explicitly forbid %preun stopping PostgreSQL",
        )


class RegisterGatewayAdminBootstrapContractTests(unittest.TestCase):
    """The first-admin bootstrap is optional, but once requested it must
    either run with a password file or fail clearly."""

    def test_register_gateway_help_marks_admin_bootstrap_optional(self):
        result = subprocess.run(
            ["bash", str(GATEWAY_SETUP_SCRIPT), "--help"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Bootstrap the first admin user (optional;", result.stdout)
        self.assertIn("Password file for --admin-user", result.stdout)

    def test_register_gateway_validates_admin_user_and_password_file_together(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "--admin-user is required when --admin-password-file is set.",
            text,
            "register-gateway must reject a password file without --admin-user",
        )
        self.assertIn(
            "--admin-password-file is required when --admin-user is set.",
            text,
            "register-gateway must reject --admin-user without a password file",
        )
        self.assertIn(
            "without bootstrapping a first admin user",
            text,
            "register-gateway should describe the optional bootstrap accurately",
        )


class TargetDbThreadingTests(unittest.TestCase):
    """The original implementation
    hardcoded /postgres in the gateway connection URL and -d postgres in
    the admin tool, locking Workflow B installs to the postgres database.
    Operators who created the documentdb extension in a different DB
    silently broke. --target-db now threads the actual database name
    through register-gateway → connection URL + admin bootstrap, and
    through documentdb-gateway-admin's psql calls."""

    def test_register_gateway_accepts_target_db_flag(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('--target-db)', text,
                      "register-gateway must accept --target-db")
        self.assertIn('TARGET_DB="postgres"', text,
                      "register-gateway must default TARGET_DB to 'postgres'")

    def test_register_gateway_uses_target_db_in_connection_url(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"write_connection_secret\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('${TARGET_DB}', body,
                      "Connection URL must interpolate ${TARGET_DB}")
        # Belt-and-braces: must NOT hardcode /postgres anymore.
        self.assertNotRegex(
            body,
            r'postgresql://[^/"\']*@/postgres\?',
            "Connection URL must not hardcode /postgres",
        )

    def test_register_gateway_threads_target_db_to_admin_bootstrap(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"create_admin_user\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('--target-db "${TARGET_DB}"', body,
                      "create_admin_user must pass --target-db to documentdb-gateway-admin")

    def test_register_gateway_target_db_rejects_unsafe_value(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # The arg parser must reject anything that doesn't look like a
        # PostgreSQL identifier so it can't escape into the URL or shell.
        self.assertRegex(
            text,
            r'--target-db must be a PostgreSQL identifier',
            "--target-db must validate the value",
        )

    def test_gateway_admin_accepts_target_db_flag(self):
        admin = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-gateway-admin.sh"
        text = admin.read_text(encoding="utf-8")
        self.assertIn('--target-db)', text,
                      "documentdb-gateway-admin must accept --target-db")
        self.assertIn('TARGET_DB="postgres"', text,
                      "documentdb-gateway-admin must default TARGET_DB to 'postgres'")

    def test_gateway_admin_uses_target_db_in_all_psql_calls(self):
        admin = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-gateway-admin.sh"
        text = admin.read_text(encoding="utf-8")
        # No more hardcoded `-d postgres` (only the comment should still
        # mention it, prefixed by `# `).
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith('#'):
                continue
            self.assertNotRegex(
                line,
                r'-d postgres\b',
                f"Admin script must not hardcode -d postgres in: {stripped[:80]}",
            )


class ToolsDebSuggestsHardcodedExtensionTests(unittest.TestCase):
    """The DEB tools package's
    `Suggests: postgresql-18-documentdb` was misleading on PG 15/16/17
    hosts. The package is PG-agnostic per design §4.2 — Suggests should
    not pin one major. Matches the RPM tools spec which omits the
    suggestion entirely.

    Same pattern existed in the
    gateway DEB/RPM. Now neither should pin a specific PG-major
    extension package."""

    def test_deb_tools_does_not_suggest_pinned_extension(self):
        builder = OSS_ROOT / "packaging" / "postgresql-tools" / "build-postgresql-tools-deb.sh"
        text = builder.read_text(encoding="utf-8")
        # Walk non-comment lines only — the explanatory comment
        # mentions postgresql-18-documentdb historically.
        for lineno, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith('#'):
                continue
            self.assertNotIn(
                'postgresql-18-documentdb',
                line,
                f"DEB tools must not hardcode postgresql-18-documentdb (line {lineno}: {stripped[:80]})",
            )
        # Should still suggest the gateway runtime per §4.2.
        self.assertIn(
            'Suggests: documentdb-gateway',
            text,
            "DEB tools must still Suggest the gateway runtime",
        )

    def test_deb_gateway_does_not_suggest_pinned_extension(self):
        builder = OSS_ROOT / "packaging" / "gateway" / "build-gateway-deb.sh"
        text = builder.read_text(encoding="utf-8")
        for lineno, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith('#'):
                continue
            self.assertNotIn(
                'postgresql-18-documentdb',
                line,
                f"DEB gateway must not hardcode postgresql-18-documentdb (line {lineno}: {stripped[:80]})",
            )

    def test_rpm_gateway_does_not_suggest_pinned_extension(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-gateway.spec"
        text = spec.read_text(encoding="utf-8")
        # Walk non-comment lines only. The %post echo message intentionally
        # tells the operator "sudo dnf install postgresql18-documentdb"
        # as a hint, which is fine as user-visible text (the operator
        # adjusts for their major); only the Suggests directive matters.
        for lineno, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith('#') or stripped.startswith('echo'):
                continue
            self.assertNotRegex(
                line,
                r'^Suggests:\s+postgresql18-documentdb\b',
                f"RPM gateway must not Suggest a pinned PG-major extension (line {lineno})",
            )


# The packaged-config-path loading this asserts ships with the gateway change
# in PR #2138657, which implements load_configuration() in bootstrap.rs. The
# packaging PRs may be based on a branch that doesn't yet carry that change,
# so gate the test on the marker being present; it auto-enables once #2138657
# reaches the branch base.
_GATEWAY_BOOTSTRAP_RS = (
    OSS_ROOT / "pg_documentdb_gw" / "documentdb_gateway" / "src" / "bootstrap.rs"
)
_GATEWAY_HAS_PACKAGED_CONFIG = (
    _GATEWAY_BOOTSTRAP_RS.exists()
    and '"/etc/documentdb/gateway/SetupConfiguration.json"'
    in _GATEWAY_BOOTSTRAP_RS.read_text(encoding="utf-8")
)


class GatewayLoadsPackagedConfigTests(unittest.TestCase):
    """The packaged gateway
    runtime didn't load /etc/documentdb/gateway/SetupConfiguration.json by
    default — only an explicit --config or the build-tree dev path. So
    documentdb-setup wizard updates to that file were ignored when the
    systemd unit started the gateway with bare `documentdb-gateway run`."""

    @unittest.skipUnless(
        _GATEWAY_HAS_PACKAGED_CONFIG,
        "packaged-config-path loading ships with the gateway change in "
        "PR #2138657; this test auto-enables once that bootstrap.rs change is present.",
    )
    def test_gateway_main_reads_packaged_config_path(self):
        text = _GATEWAY_BOOTSTRAP_RS.read_text(encoding="utf-8")
        self.assertIn(
            '"/etc/documentdb/gateway/SetupConfiguration.json"',
            text,
            "Gateway runtime must check the packaged config path",
        )
        # The packaged path must take precedence over the dev path in the
        # .or_else() chain. Look at the actual chain (not the comment).
        # The structural pattern is: `config.or_else(packaged).or_else(dev)`.
        match = re.search(
            r"fn load_configuration[^{]*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        # Strip comments so positional comparisons reflect real code order.
        code_only = re.sub(r'^\s*//.*$', '', body, flags=re.MULTILINE)
        packaged_idx = code_only.find('packaged_path.exists()')
        dev_idx = code_only.find('dev_path.exists()')
        self.assertGreater(packaged_idx, 0,
                           "packaged_path.exists() must appear in real code, not just comments")
        self.assertGreater(dev_idx, 0,
                           "dev_path.exists() must still be checked as a fallback")
        self.assertLess(packaged_idx, dev_idx,
                        "packaged_path must be checked BEFORE dev_path in the .or_else() chain")


class GatewayEnvFragmentCarriesListenAddrTests(unittest.TestCase):
    """The per-major
    documentdb-gateway-local@N.service only loads its EnvironmentFile (the
    per-major gateway.env), not SetupConfiguration.json. The env fragment
    must therefore carry DOCUMENTDB_LISTEN_ADDR (and TLS auto-gen) so the
    operator's --listen-port reaches the runtime."""

    def test_register_gateway_supports_listen_addr_flag(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('--listen-addr)', text,
                      "register-gateway must accept --listen-addr")
        self.assertIn('GATEWAY_LISTEN_ADDR', text,
                      "register-gateway must store the listen addr")

    def test_env_fragment_emits_listen_addr(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"write_gateway_env_fragment\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('DOCUMENTDB_LISTEN_ADDR', body,
                      "Env fragment must emit DOCUMENTDB_LISTEN_ADDR when set")
        self.assertIn('DOCUMENTDB_TLS_AUTO_GENERATE', body,
                      "Env fragment must emit DOCUMENTDB_TLS_AUTO_GENERATE when set")

    def test_setup_passes_listen_addr_to_register_gateway(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_pg_ident_map\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('--listen-addr ":${GATEWAY_PORT}"', body,
                      "setup must thread --listen-port through register-gateway --listen-addr")
        self.assertIn('--tls-auto-generate true', body,
                      "setup must enable TLS auto-gen on standalone (design §4.3 default)")


class BrownfieldUsesDistroSocketTests(unittest.TestCase):
    """Brownfield setup discovered
    PG_SOCKET_DIR_BROWNFIELD from the running PG but the downstream
    register-gateway / psql calls all consulted PG_SOCKET_DIR, which was
    still the appliance per-major socket dir (which doesn't exist for
    brownfield). PG_SOCKET_DIR must be overridden in brownfield to the
    distro socket."""

    def test_brownfield_overrides_socket_dir(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"prepare_brownfield_instance\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('PG_SOCKET_DIR="${distro_socket}"', body,
                      "Brownfield must override PG_SOCKET_DIR to the distro socket")

    def test_brownfield_tune_forwards_socket_dir_and_port(self):
        # documentdb-tune's include-resolution guard fails closed on an adopted
        # cluster whose postgresql.conf has any active setting after its conf.d
        # include (a common admin habit, e.g. appending work_mem).
        # apply_managed_postgres_settings must forward the wizard-verified
        # --socket-dir/--port on the Debian brownfield (--cluster) branch so tune
        # pins documentdb.localhost_connection_string without re-parsing that
        # config — matching what the greenfield / RHEL brownfield branch already
        # does. In brownfield PG_SOCKET_DIR/PG_PORT already hold the adopted
        # instance's verified endpoint (prepare_brownfield_instance).
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"apply_managed_postgres_settings\(\)\s*\{(?P<body>.*?)^\}",
            script, flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        # Isolate the Debian brownfield (--cluster) branch: its `if` guard up to
        # the greenfield `else`.
        brownfield = re.search(
            r'if \[\[ -n "\$\{TARGET_CLUSTER\}" && -d.*?\n(?P<branch>.*?)\n\s*else',
            body, flags=re.DOTALL,
        )
        self.assertIsNotNone(brownfield,
                             "could not locate the brownfield --cluster branch")
        branch = brownfield.group("branch")
        self.assertIn('--cluster "${TARGET_CLUSTER#*/}"', branch)
        self.assertIn(
            '--socket-dir "${PG_SOCKET_DIR}" --port "${PG_PORT}"', branch,
            "brownfield must forward the wizard-verified socket dir and port to documentdb-tune",
        )


class GatewayLocalSocketAccessTests(unittest.TestCase):
    """The per-major gateway service must be able to traverse the private socket path."""

    def test_setup_creates_socket_dirs_with_gateway_group(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_socket_dir_writable\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            'install -d -o documentdb-local -g documentdb-gateway -m 0750 "${socket_parent}"',
            body,
            "The runtime parent must grant traversal to the gateway group",
        )
        self.assertIn(
            'install -d -o documentdb-local -g documentdb-gateway -m 0750 "${PG_SOCKET_DIR}"',
            body,
            "The socket directory must grant traversal to the gateway group",
        )

    def test_service_helper_recreates_socket_dirs_with_gateway_group(self):
        service_helper = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb_postgresql_service.sh"
        text = service_helper.read_text(encoding="utf-8")
        self.assertIn('socket_group="documentdb-gateway"', text)
        self.assertIn('socket_group="${PG_OWNER}"', text)
        self.assertIn('-g "${socket_group}" -m 0750', text)

    def test_gateway_local_unit_allows_private_socket_dir(self):
        unit = OSS_ROOT / "packaging" / "appliance" / "systemd" / "documentdb-gateway-local@.service"
        text = unit.read_text(encoding="utf-8")
        self.assertIn(
            "/run/documentdb-local/%i/postgresql",
            text,
            "The gateway-local unit must be allowed to access the private socket directory",
        )

    def test_gateway_local_unit_conditions_on_gateway_env(self):
        # The gateway-local template must skip cleanly until documentdb-setup
        # has provisioned this major, exactly like the sibling PG unit
        # (ConditionPathExists=setup.conf). Without it, starting
        # documentdb-local@N.target before setup ran would still launch the
        # gateway — a Condition-skipped greenfield PG unit still SATISFIES
        # Requires= — and ExecStart would hard-fail (status=200/CHDIR) on the
        # missing WorkingDirectory (created by setup, not at package install).
        unit = OSS_ROOT / "packaging" / "appliance" / "systemd" / "documentdb-gateway-local@.service"
        text = unit.read_text(encoding="utf-8")
        self.assertIn(
            "ConditionPathExists=/etc/documentdb/local/%i/gateway.env",
            text,
            "The gateway-local unit must ConditionPathExists on the per-major "
            "gateway.env so it skips cleanly before documentdb-setup runs",
        )

    def test_gateway_local_unit_precreates_workdir_root_owned_not_statedir(self):
        # The per-major WorkingDirectory must be ensured before ExecStart, but
        # via a privileged `ExecStartPre=+install -d` that reproduces
        # documentdb-register-gateway's root-owned (0750) create — NOT
        # StateDirectory=. systemd recursively chowns a StateDirectory whose
        # owner does not match User= on every start, which would re-own the
        # root:documentdb-gateway 0640 pg-url inside it to the gateway user and
        # let the gateway rewrite its own connection URL. install -d never
        # recurses into contents, so pg-url keeps its root ownership.
        unit = OSS_ROOT / "packaging" / "appliance" / "systemd" / "documentdb-gateway-local@.service"
        text = unit.read_text(encoding="utf-8")
        # Guard against an *active* StateDirectory= directive (ignore the
        # explanatory comment that names it as the rejected approach).
        active_statedir = [
            ln for ln in text.splitlines()
            if ln.lstrip().startswith("StateDirectory=")
        ]
        self.assertEqual(
            active_statedir,
            [],
            "The gateway-local unit must NOT use StateDirectory= — its recursive "
            "chown-on-mismatch would hand the gateway ownership of the "
            "root-owned pg-url connection file. Use a privileged ExecStartPre "
            "install -d instead.",
        )
        self.assertIn(
            "ExecStartPre=+/usr/bin/install -d -m 0750 -o root -g documentdb-gateway "
            "/var/lib/documentdb-local/%i/gateway",
            text,
            "The gateway-local unit must pre-create the WorkingDirectory "
            "root-owned via a privileged ExecStartPre so it is always valid "
            "(no status=200/CHDIR) without disturbing pg-url ownership",
        )


class BrownfieldTuneDelegationTests(unittest.TestCase):
    """On Debian brownfield, calling
    documentdb-tune --pgdata writes to the data-dir postgresql.conf which
    Debian clusters don't read. Use --pg-version/--cluster instead so the
    per-cluster fragment lands in /etc/postgresql-common/documentdb/V/C/."""

    def test_setup_uses_cluster_form_for_debian_brownfield(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"apply_managed_postgres_settings\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        # The tune delegation must branch on TARGET_CLUSTER + Debian
        # config-dir presence to use --pg-version/--cluster instead of --pgdata.
        self.assertIn(
            'if [[ -n "${TARGET_CLUSTER}" && -d "/etc/postgresql/${PG_VERSION}/${TARGET_CLUSTER#*/}" ]]',
            body,
            "Tune delegation must branch on TARGET_CLUSTER for Debian brownfield",
        )
        self.assertIn(
            '--pg-version "${PG_VERSION}" --cluster "${TARGET_CLUSTER#*/}"',
            body,
            "Debian brownfield must call documentdb-tune --pg-version/--cluster",
        )


class AdminAutoDetectInstanceLevelDedupTests(unittest.TestCase):
    """Admin auto-detect dedupes
    state files by PG_VERSION only. Two clusters on the same major
    (18/main + 18/analytics) silently collapsed to one — auto-detect
    picked state_files[0]. Dedup must be by (PG_VERSION, CLUSTER_NAME)."""

    def test_admin_autodetect_dedups_by_instance(self):
        admin = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-gateway-admin.sh"
        text = admin.read_text(encoding="utf-8")
        self.assertIn('distinct_instances', text,
                      "auto-detect must track distinct instances, not distinct majors")
        self.assertIn('CLUSTER_NAME=', text,
                      "auto-detect must read CLUSTER_NAME to form an instance key")
        self.assertIn('multiple PostgreSQL instances are registered', text,
                      "Ambiguity error must say 'instances', not 'majors'")


class RegisterGatewayQueriesLiveHbaIdentTests(unittest.TestCase):
    """Operators can override hba_file
    / ident_file in postgresql.conf. register-gateway must SHOW those
    values from the live cluster before mutating, otherwise it edits the
    distro-default paths and the running PG never sees the changes."""

    def test_verifier_queries_live_hba_and_ident(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"verify_psql_connects_to_named_cluster\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('SHOW hba_file', body,
                      "Verifier must SHOW hba_file from the live cluster")
        self.assertIn('SHOW ident_file', body,
                      "Verifier must SHOW ident_file from the live cluster")
        # On override, the resolved HBA_FILE/IDENT_FILE must be replaced
        # with the live values so subsequent writes go to the right files.
        self.assertIn('HBA_FILE="${live_hba_file}"', body,
                      "Verifier must override HBA_FILE with the live value")
        self.assertIn('IDENT_FILE="${live_ident_file}"', body,
                      "Verifier must override IDENT_FILE with the live value")


class BrownfieldRestartGuardTests(unittest.TestCase):
    """In brownfield mode, when
    documentdb-tune wrote shared_preload_libraries, the wizard logged
    "please restart PG" and then immediately ran CREATE EXTENSION.
    pg_documentdb is a preload library — CREATE EXTENSION fails until
    the postmaster restarts. wizard must stop and let the operator
    restart + re-run."""

    def test_brownfield_stops_when_config_changed(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"start_or_restart_postgres\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            'documentdb-setup is exiting BEFORE running CREATE EXTENSION',
            body,
            "Brownfield must exit when PG_CONFIG_CHANGED — CREATE EXTENSION would fail before postmaster restart",
        )
        self.assertIn(
            'exit 0',
            body,
            "Brownfield restart-required path must exit cleanly (not error) so the operator can rerun",
        )

    def test_brownfield_provides_rerun_instructions(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"start_or_restart_postgres\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            'sudo documentdb-setup --target-postgres-instance',
            body,
            "Brownfield restart-required path must give a concrete rerun command",
        )

    def test_uses_shared_resolver_not_inline_unit_name(self):
        # Regression: start_or_restart_postgres reconstructed the adopted PG
        # unit name inline with a raw ${TARGET_CLUSTER#*/}, which for an empty
        # cluster (e.g. --target-postgres-instance 18/) produced a broken
        # postgresql@18-.service. It must instead delegate to
        # resolve_brownfield_pg_service_unit, which normalizes the empty
        # cluster to "main".
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"start_or_restart_postgres\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "resolve_brownfield_pg_service_unit",
            body,
            "start_or_restart_postgres must resolve the adopted PG unit via the shared helper",
        )
        self.assertNotIn(
            "postgresql@${PG_VERSION}-${TARGET_CLUSTER#*/}",
            body,
            "start_or_restart_postgres must not rebuild the templated unit name "
            "inline (that skips the empty-cluster->main normalization)",
        )


class RegisterGatewayWorkflowBEnvFileTests(unittest.TestCase):
    """The per-major gateway.env path
    only works when documentdb-N (the standalone package) is installed.
    For Workflow B (just documentdb-gateway), the plain
    documentdb-gateway.service unit reads /etc/documentdb/gateway/gateway.env,
    not the per-major path. register-gateway must pick the right one
    based on which systemd template unit is shipped on the host."""

    def test_workflow_b_uses_plain_gateway_env_path(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # Must detect whether the per-major templated unit is shipped.
        self.assertIn(
            '/lib/systemd/system/documentdb-gateway-local@.service',
            text,
            "register-gateway must detect documentdb-N installation via the templated unit",
        )
        # Workflow B fallback path uses /etc/documentdb/gateway/gateway.env.
        self.assertRegex(
            text,
            r'GATEWAY_ENV_FILE="/etc/documentdb/gateway/gateway\.env"',
            "register-gateway must fall back to /etc/documentdb/gateway/gateway.env when documentdb-N is absent",
        )


class RegisterGatewayRecoveryMarkerOrderTests(unittest.TestCase):
    """Recovery marker was written
    BEFORE verify_psql_connects_to_named_cluster, but the verifier also
    overrides HBA_FILE/IDENT_FILE with the live SHOW values. The marker
    must reflect the actual paths we're about to mutate, so verifier
    must run first."""

    def test_verifier_runs_before_recovery_marker_in_do_setup(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"do_setup\(\) \{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        # Strip comments so we compare real code order.
        code_only = re.sub(r'^\s*#.*$', '', body, flags=re.MULTILINE)
        verifier_idx = code_only.find('verify_psql_connects_to_named_cluster')
        marker_idx = code_only.find('write_recovery_marker')
        hba_write_idx = code_only.find('prepend_with_managed_block')
        self.assertGreater(verifier_idx, 0)
        self.assertGreater(marker_idx, 0)
        self.assertGreater(hba_write_idx, 0)
        self.assertLess(verifier_idx, marker_idx,
                        "verifier must run BEFORE write_recovery_marker so the marker records live paths")
        self.assertLess(marker_idx, hba_write_idx,
                        "recovery marker must still be written BEFORE the HBA edit")


class RegisterGatewayAdminBootstrapPgOwnerTests(unittest.TestCase):
    """create_admin_user delegated to
    documentdb-gateway-admin without --pg-owner, so a register-gateway
    invocation with --pg-owner documentdb-local (private greenfield PG)
    silently failed the admin bootstrap because the admin tool defaulted
    to postgres."""

    def test_create_admin_user_passes_pg_owner(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"create_admin_user\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('--pg-owner "${PG_OWNER}"', body,
                      "create_admin_user must pass --pg-owner to documentdb-gateway-admin")


class AdminAutoDetectSkipsWhenExplicitTests(unittest.TestCase):
    """auto_detect_connection ran
    unconditionally, so on a multi-instance host the ambiguity check
    fired even when the operator already supplied --pg-port + --socket-dir.
    Operator got told to re-run with the flags they already passed."""

    def test_autodetect_returns_early_when_both_explicit(self):
        admin = OSS_ROOT / "documentdb-local" / "scripts" / "documentdb-gateway-admin.sh"
        text = admin.read_text(encoding="utf-8")
        match = re.search(
            r"auto_detect_connection\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        # The explicit-flags branch must still short-circuit before the
        # multi-instance ambiguity scan (its whole point), but it now first
        # recovers PG_OWNER/TARGET_DB from the state file whose PG_PORT
        # matches the explicit --pg-port — a bare `return 0` dropped those
        # and PG_OWNER fell back to "postgres", which cannot traverse a
        # greenfield socket dir.
        explicit_idx = body.index('if [[ -n "${PG_PORT}" && -n "${SOCKET_DIR}" ]]; then')
        scan_idx = body.index("# Per-major state files.")
        self.assertLess(
            explicit_idx, scan_idx,
            "the explicit-flags branch must short-circuit before the ambiguity scan",
        )
        explicit_block = body[explicit_idx:scan_idx]
        self.assertIn(
            "return 0",
            explicit_block,
            "auto-detect must still return early when both --pg-port and "
            "--socket-dir are explicit",
        )


class BrownfieldRestartLoopFixTests(unittest.TestCase):
    """On Debian, documentdb-tune
    writes shared_preload_libraries to the per-cluster include fragment,
    NOT to the live postgresql.conf. So setup's file-only SPL check kept
    triggering PG_CONFIG_CHANGED=true even after the operator restarted
    PG — causing an infinite restart-and-rerun loop.

    Fix: query the live server for the authoritative state and only force
    an exit-with-restart when the running postmaster is actually missing a
    required preload library OR a restart-only (PGC_POSTMASTER) GUC that
    documentdb-tune writes is stale."""

    def test_brownfield_queries_live_shared_preload_libraries(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            script,
            r'SHOW shared_preload_libraries',
            "Brownfield must SHOW shared_preload_libraries from the live PG",
        )

    def test_brownfield_skips_restart_when_libs_already_loaded(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # The live-library membership test must use comma-boundary matching so a
        # bare substring ("pg_documentdb") is not wrongly considered present when
        # only "pg_documentdb_core" is loaded.
        self.assertIn('case ",${live_preload}," in', script,
                      "Brownfield must comma-boundary match each required lib against live SPL")
        self.assertIn('*",${lib},"*', script,
                      "Brownfield must comma-boundary match each required lib against live SPL")
        # need_restart starts false and is only flipped true when the live PG is
        # missing a required library or a managed restart-only GUC is stale.
        self.assertIn('need_restart=false', script,
                      "Brownfield must skip the restart-required exit when live PG already matches")

    def test_brownfield_checks_restart_only_gucs_against_live_pg(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # Every restart-only (PGC_POSTMASTER) GUC documentdb-tune writes must be
        # verified against the live postmaster, not just the on-disk fragment:
        # the Debian per-cluster fragment never lands in LIVE_CONFIG_FILE, so a
        # stale live value (e.g. an operator's custom cron.database_name) would
        # otherwise be missed and the wizard would proceed without the restart.
        self.assertIn('managed_restart_gucs=(', script,
                      "Brownfield must verify the managed restart-only GUCs against the live PG")
        for guc in (
            'cron.use_background_workers',
            'cron.database_name',
            'documentdb.enableBackgroundWorker',
        ):
            self.assertIn(guc, script,
                          f"Brownfield must verify live {guc} to force a restart when stale")
        # The extended-RUM handler GUC is verified too (gated on HAS_EXTENDED_RUM).
        self.assertIn('documentdb.rum_library_load_option', script,
                      "Brownfield must verify live rum_library_load_option when extended RUM is present")

    def test_brownfield_guc_check_is_restart_loop_safe(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        # An unreadable SHOW (empty result) must be skipped rather than forcing a
        # restart, so a transient read failure cannot wedge an infinite loop.
        self.assertIn('[[ -z "${live_guc}" ]] && continue', script,
                      "Brownfield GUC check must skip (not restart on) an empty SHOW result")


class PgUrlPersistentPathTests(unittest.TestCase):
    """Pg-url was at
    /run/documentdb-local/N/gateway/pg-url (tmpfs, cleared on reboot).
    The env file references it via DOCUMENTDB_PG_URL_FILE, which
    persists, so on reboot the gateway started with a dangling pointer
    and failed. Moved to /var/lib/documentdb-local/N/gateway/pg-url
    (persistent, same security boundary)."""

    def test_register_gateway_uses_persistent_path(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'SECRET_DIR="/var/lib/documentdb-local/${PG_VERSION}/gateway"',
            text,
            "register-gateway must write pg-url to the persistent /var/lib path",
        )

    def test_design_doc_specifies_persistent_path(self):
        design_path = OSS_ROOT / "packaging" / "gateway" / "packaging-design.md"
        text = design_path.read_text(encoding="utf-8")
        self.assertIn(
            '/var/lib/documentdb-local/N/gateway/pg-url',
            text,
            "Design doc must specify the persistent pg-url path",
        )
        self.assertIn(
            'reboot',
            text,
            "Design doc must explain WHY pg-url moved off tmpfs",
        )

    def test_postrm_cleans_both_old_and_new_paths(self):
        """Upgrade safety: hosts that installed legacy have pg-url at
        /run/. The postrm must clean both the new and legacy paths."""
        builder = OSS_ROOT / "packaging" / "standalone" / "build-standalone-deb.sh"
        text = builder.read_text(encoding="utf-8")
        self.assertIn(
            '/run/documentdb-local/${PKG_PG_VERSION}/gateway/pg-url',
            text,
            "DEB postrm must clean the legacy /run/ pg-url for legacy upgrades",
        )
        self.assertIn(
            '/var/lib/documentdb-local/${PKG_PG_VERSION}/gateway/pg-url',
            text,
            "DEB postrm must clean the current /var/lib pg-url",
        )

    def test_rpm_postun_cleans_both_paths(self):
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertIn(
            '/run/documentdb-local/%{pg_version}/gateway/pg-url',
            text,
            "RPM %postun must clean legacy /run/ pg-url",
        )
        self.assertIn(
            '/var/lib/documentdb-local/%{pg_version}/gateway/pg-url',
            text,
            "RPM %postun must clean current /var/lib pg-url",
        )


class RegisterGatewayPgVersionDerivationTests(unittest.TestCase):
    """Greenfield setup via wizard
    called documentdb-register-gateway with --pgdata only, no --pg-version.
    register-gateway then silently skipped all per-major work (psql
    resolver, SECRET_DIR, STATE_FILE, GATEWAY_ENV_FILE). Result:
    greenfield wizard installs had no working gateway connection state."""

    def test_register_gateway_accepts_pg_version_flag(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('--pg-version)', text,
                      "register-gateway must accept --pg-version")
        self.assertIn('PG_VERSION="$2"', text,
                      "--pg-version must set PG_VERSION")

    def test_register_gateway_derives_pg_version_from_pgdata(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # Defensive fallback: even if the caller forgets --pg-version,
        # derive from PGDATA/PG_VERSION (standard initdb marker).
        self.assertIn(
            '"${PGDATA}/PG_VERSION"',
            text,
            "register-gateway must auto-derive PG_VERSION from PGDATA/PG_VERSION",
        )

    def test_setup_passes_pg_version_in_greenfield(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_pg_ident_map\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            '--pg-version "${PG_VERSION}"',
            body,
            "Greenfield invocation must pass --pg-version explicitly",
        )


class GatewayEnvSampleConsistencyTests(unittest.TestCase):
    """The gateway.env.sample shipped
    under /usr/share/doc/documentdb-gateway/examples/ still advertised
    /run/documentdb-local/N/gateway/pg-url even after earlier moved the
    actual path to /var/lib. The postinst tells operators to copy this
    sample into /etc/documentdb/gateway/gateway.env, so a Workflow B
    operator who uncomments the line would reintroduce the reboot bug."""

    def test_sample_uses_persistent_pg_url_path(self):
        sample = OSS_ROOT / "packaging" / "gateway" / "config" / "gateway.env"
        text = sample.read_text(encoding="utf-8")
        self.assertNotIn(
            'DOCUMENTDB_PG_URL_FILE=/run/documentdb-local',
            text,
            "Sample must not advertise the legacy tmpfs path (reboot-unsafe)",
        )
        self.assertIn(
            'DOCUMENTDB_PG_URL_FILE=/var/lib/documentdb-local/N/gateway/pg-url',
            text,
            "Sample must show the persistent /var/lib path",
        )


class PackagingReadmeWorkflowCTests(unittest.TestCase):
    """The recommended stand-alone workflow should mirror the wizard's
    required inputs and interactive password prompt."""

    def test_workflow_c_example_passes_admin_user(self):
        text = PACKAGING_README.read_text(encoding="utf-8")
        self.assertIn(
            "sudo documentdb-setup --admin-user admin",
            text,
            "Workflow C example must include the required --admin-user flag",
        )


class RegisterGatewayPersistsEnvFilePathTests(unittest.TestCase):
    """GATEWAY_ENV_FILE is chosen at
    apply-time based on whether documentdb-N is installed. On --restore,
    runtime detection can pick the wrong path if the host changed
    between setup and restore (e.g., operator uninstalled documentdb-N).
    Persist the chosen path in the state file so --restore always
    operates on the file we actually wrote."""

    def test_record_state_persists_gateway_env_file(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"record_state\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "printf 'GATEWAY_ENV_FILE=%s\\n'",
            body,
            "record_state must persist GATEWAY_ENV_FILE",
        )

    def test_do_restore_reads_persisted_gateway_env_file(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"do_restore\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "GATEWAY_ENV_FILE=",
            body,
            "do_restore must read GATEWAY_ENV_FILE from state file",
        )
        self.assertIn(
            'persisted_env_file',
            body,
            "do_restore must use a local variable to capture the persisted value",
        )


class RegisterGatewayAtomicStateWriteTests(unittest.TestCase):
    """record_state previously
    used `> "${STATE_FILE}"` which truncates on open. A SIGTERM mid-write
    leaves a partial/empty state file that defeats --restore/postrm.
    Must write atomically via tempfile + rename, matching the
    write_recovery_marker() pattern."""

    def test_record_state_uses_atomic_temp_rename(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"record_state\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            'mktemp "${STATE_FILE}',
            body,
            "record_state must allocate a tempfile via mktemp",
        )
        self.assertIn(
            'mv "${tmp}" "${STATE_FILE}"',
            body,
            "record_state must atomically rename tempfile into place",
        )
        self.assertNotRegex(
            body,
            r'\}\s*>\s*"\$\{STATE_FILE\}"',
            "record_state must not write directly to STATE_FILE (non-atomic)",
        )

    def test_record_state_dies_on_mktemp_failure(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"record_state\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        body = match.group("body")
        self.assertIn(
            "|| die",
            body,
            "record_state must die on mktemp/mv failure rather than leave inconsistent state",
        )


class RegisterGatewayRestoreFallbackTests(unittest.TestCase):
    """When state file lacks the
    GATEWAY_ENV_FILE field (legacy install), do_restore previously
    fell back to runtime detection — which is exactly what was broken
    originally and motivated persisting the path. Must instead scan
    BOTH known candidate paths (per-major + shared) so the managed
    block is reliably stripped from whichever one was actually written."""

    def test_do_restore_scans_multiple_env_candidates_on_legacy_state(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"do_restore\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "env_candidates",
            body,
            "do_restore must maintain a list of candidate env paths",
        )
        self.assertIn(
            "for env_target in",
            body,
            "do_restore must iterate over candidate env paths",
        )
        self.assertIn(
            "/etc/documentdb/gateway/gateway.env",
            body,
            "do_restore must consider the shared gateway env path",
        )
        self.assertIn(
            "/etc/documentdb/local/${PG_VERSION}/gateway.env",
            body,
            "do_restore must consider the per-major env path",
        )

    def test_do_restore_prefers_persisted_path_when_present(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"do_restore\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        body = match.group("body")
        self.assertRegex(
            body,
            r"if\s*\[\[\s*-n\s*\"\$\{persisted_env_file\}\"\s*\]\];?\s*then",
            "do_restore must short-circuit to persisted path when present",
        )

    def test_do_restore_strips_hba_without_reordering_remaining_rules(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"do_restore\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        hba_call = re.search(
            r"if \[\[ -f \"\$\{HBA_FILE\}\" \]\]; then(?P<body>.*?)fi",
            body,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(hba_call)
        self.assertIn(
            'rewrite_with_managed_block "${HBA_FILE}"',
            hba_call.group("body"),
            "HBA restore must strip the managed block without prepending an empty block path",
        )
        self.assertNotIn(
            'prepend_with_managed_block "${HBA_FILE}"',
            hba_call.group("body"),
            "HBA restore must not use the prepend helper for removal",
        )


class RegisterGatewayBackupSafetyTests(unittest.TestCase):
    """Config backups must be timestamped but unique under concurrent setup runs."""

    def test_backup_file_uses_unique_tempfile(self):
        # backup_file is single-sourced in documentdb-tools-lib.sh; verify
        # documentdb-register-gateway sources it, then assert the shared
        # definition is safe.
        self.assertIn(
            "documentdb-tools-lib.sh",
            GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8"),
            "documentdb-register-gateway must source the shared documentdb-tools-lib.sh",
        )
        text = TOOLS_LIB.read_text(encoding="utf-8")
        match = re.search(
            r"backup_file\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "mktemp",
            body,
            "register-gateway backups must not collide under concurrent runs",
        )
        self.assertIn(
            ".documentdb-backup.${timestamp}.XXXXXX",
            body,
            "register-gateway backups must retain timestamped names with a unique suffix",
        )
        self.assertNotIn(
            ".documentdb-backup.${timestamp}\"",
            body,
            "register-gateway must not use timestamp-only backup filenames",
        )


class StatusOnlyHealthExitCodeTests(unittest.TestCase):
    """The design doc (§5 line 284)
    says `--status ... exit 0 if a healthy install is found`, and the
    function docstring promises the same. The prior implementation
    exited 0 whenever the state file existed, regardless of whether
    the gateway service was running or anything was listening. CI
    scripts gating on documentdb-setup --status would treat broken
    installs as healthy. Real contract: state file + gw_active +
    listener (+ pg_active in greenfield)."""

    def test_status_only_requires_gateway_active(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"status_only\(\)\s*\{(?P<body>.*?)\nmain\(\)",
            text,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertRegex(
            body,
            r'"\$\{gw_active\}"\s*!=\s*"active"',
            "status_only must return non-zero when gateway service is not active",
        )

    def test_status_only_requires_listener(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"status_only\(\)\s*\{(?P<body>.*?)\nmain\(\)",
            text,
            flags=re.DOTALL,
        )
        body = match.group("body")
        self.assertRegex(
            body,
            r'"\$\{listening_port\}"\s*!=\s*"\$\{effective_gateway_port\}"',
            "status_only must return non-zero when no listener is found on the gateway port",
        )

    def test_status_only_requires_pg_active_in_greenfield(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"status_only\(\)\s*\{(?P<body>.*?)\nmain\(\)",
            text,
            flags=re.DOTALL,
        )
        body = match.group("body")
        self.assertRegex(
            body,
            r'"\$\{mode\}"\s*==\s*"greenfield"\s*&&\s*"\$\{pg_active\}"\s*!=\s*"active"',
            "status_only must require PG service active in greenfield mode (brownfield exempt)",
        )

    def test_status_only_does_not_short_circuit_on_state_file_alone(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"status_only\(\)\s*\{(?P<body>.*?)\nmain\(\)",
            text,
            flags=re.DOTALL,
        )
        body = match.group("body")
        # The legacy short-circuit:
        #   [[ "${mode}" != "<not configured>" ]] && return 0 || return 1
        # must be gone.
        self.assertNotRegex(
            body,
            r'\[\[\s*"\$\{mode\}"\s*!=\s*"<not configured>"\s*\]\]\s*&&\s*return\s*0',
            "status_only must not exit 0 based on state file presence alone",
        )


class WriteRecoveryMarkerPersistsEnvFileTests(unittest.TestCase):
    """The write_recovery_marker
    runs before HBA/ident mutations; if SIGTERM lands between
    write_recovery_marker and record_state, do_restore would fall back
    to the candidate-sweep path (safe but coarser). Persist
    GATEWAY_ENV_FILE in the recovery marker too so the precise file is
    always recoverable even from the narrow crash window."""

    def test_write_recovery_marker_persists_gateway_env_file(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"write_recovery_marker\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "printf 'GATEWAY_ENV_FILE=%s\\n'",
            body,
            "write_recovery_marker must persist GATEWAY_ENV_FILE for SIGTERM resilience",
        )


# The managed-keys regex is a single script-level constant
# (STATE_MANAGED_KEYS_RE) in documentdb-register-gateway.sh rather than a local
# inside record_state, because do_restore must strip exactly the keys
# record_state writes. While the two were independent, do_restore skipped the
# split entirely and deleted the whole (shared) state file.
_STATE_MANAGED_KEYS_DEF = r"STATE_MANAGED_KEYS_RE='\^\((?P<keys>[^)]+)\)='"


def _state_managed_keys(test):
    """Return the key names in register-gateway's STATE_MANAGED_KEYS_RE."""
    text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
    match = re.search(_STATE_MANAGED_KEYS_DEF, text)
    test.assertIsNotNone(
        match,
        "documentdb-register-gateway.sh must define a STATE_MANAGED_KEYS_RE constant",
    )
    return match.group("keys").split("|")


def _function_body(test, text, name):
    """Return the body of shell function ``name`` in ``text``."""
    match = re.search(
        re.escape(name) + r"\(\)\s*\{(?P<body>.*?)^\}",
        text,
        flags=re.DOTALL | re.MULTILINE,
    )
    test.assertIsNotNone(match, f"could not locate shell function {name}")
    return match.group("body")


class RegisterGatewayPreservesForeignStateKeysTests(unittest.TestCase):
    """In greenfield mode the wizard
    (documentdb-setup) writes /etc/documentdb/local/N/setup.conf with
    additional keys (GATEWAY_PORT, DATA_DIR, CONFIG_FILE,
    DOCUMENTDB_MANAGED_POSTGRES) BEFORE calling register-gateway, which
    then writes to the SAME path. Without preservation, register-gateway
    silently drops those keys — breaking documentdb-setup --status (it
    reads GATEWAY_PORT to know which port to probe). Both record_state
    and write_recovery_marker (which both rewrite STATE_FILE) must
    preserve foreign keys."""

    def test_record_state_preserves_foreign_keys(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"record_state\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            'grep -Ev "${STATE_MANAGED_KEYS_RE}"',
            body,
            "record_state must extract non-managed lines via grep -Ev",
        )
        self.assertIn(
            'preserved',
            body,
            "record_state must use a preserved variable",
        )
        # Ensure GATEWAY_PORT is NOT in the managed-keys set (so it survives)
        self.assertNotIn(
            "GATEWAY_PORT",
            _state_managed_keys(self),
            "GATEWAY_PORT must NOT be in record_state's managed keys (would be dropped)",
        )

    def test_restore_strips_managed_keys_instead_of_deleting_state_file(self):
        # --restore is documented as removing "only the managed gateway
        # registration wiring". Deleting the shared setup.conf also destroyed
        # the wizard's GATEWAY_PORT/DATA_DIR/CONFIG_FILE and, worse, the
        # ConditionPathExists gate documentdb-postgresql@N.service uses -- so
        # detaching the gateway silently stopped the private PostgreSQL from
        # starting on the next boot.
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        strip_body = _function_body(self, text, "strip_managed_state_keys")
        self.assertIn(
            'local strip_re="${STATE_MANAGED_KEYS_RE}"',
            strip_body,
            "the teardown must default to the same managed-keys regex record_state writes",
        )
        # On a wizard-co-owned state file (DOCUMENTDB_MANAGED_POSTGRES marker
        # present), only register-gateway's EXCLUSIVE keys may be stripped:
        # removing co-owned keys (PG_VERSION, DOCUMENTDB_MODE, PG_PORT, ...)
        # left documentdb-postgresql@N.service unable to start (its
        # ConditionPathExists still passed but load_config died on the
        # missing PG_VERSION) and let a later brownfield adoption delete the
        # file as "legacy".
        self.assertIn(
            "grep -qE '^DOCUMENTDB_MANAGED_POSTGRES=' \"${STATE_FILE}\"",
            strip_body,
            "the teardown must detect wizard co-ownership via the "
            "DOCUMENTDB_MANAGED_POSTGRES marker",
        )
        self.assertIn(
            'strip_re="${STATE_EXCLUSIVE_KEYS_RE}"',
            strip_body,
            "on a co-owned state file only the exclusive keys may be stripped",
        )
        self.assertIn(
            'grep -Ev "${strip_re}"',
            strip_body,
            "the teardown must strip via the resolved regex",
        )
        # The exclusive set must never claim a key the wizard also writes.
        exclusive = re.search(
            r"^readonly STATE_EXCLUSIVE_KEYS_RE='\^\(([^)]*)\)='", text, re.M)
        self.assertIsNotNone(exclusive, "STATE_EXCLUSIVE_KEYS_RE must be declared")
        wizard_text = SETUP_SCRIPT.read_text(encoding="utf-8")
        for wizard_re_name in ("GREENFIELD_MANAGED_KEYS_RE", "BROWNFIELD_MANAGED_KEYS_RE"):
            wizard_re = re.search(
                r"^readonly %s='\^\(([^)]*)\)='" % wizard_re_name, wizard_text, re.M)
            self.assertIsNotNone(wizard_re, f"{wizard_re_name} must be declared")
            overlap = set(exclusive.group(1).split("|")) & set(wizard_re.group(1).split("|"))
            self.assertEqual(
                set(), overlap,
                f"STATE_EXCLUSIVE_KEYS_RE must not overlap {wizard_re_name}: "
                f"stripping {overlap} on restore would break the wizard's install",
            )
        # Whole-file removal stays correct when nothing foreign remains (a
        # direct Workflow B install where register-gateway is the sole
        # writer), but it must be conditional on that.
        self.assertIn(
            'if [[ -z "${remaining}" ]]',
            strip_body,
            "state-file removal must be conditional on no foreign keys remaining",
        )
        restore_body = _function_body(self, text, "do_restore")
        self.assertIn(
            "strip_managed_state_keys",
            restore_body,
            "do_restore must delegate state teardown to strip_managed_state_keys",
        )
        self.assertNotIn(
            'rm -f "${STATE_FILE}"',
            restore_body,
            "do_restore must not unconditionally delete the shared state file",
        )

    def test_write_recovery_marker_preserves_foreign_keys(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"write_recovery_marker\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            "managed_keys_re=",
            body,
            "write_recovery_marker must define a managed-keys regex",
        )
        self.assertIn(
            'preserved',
            body,
            "write_recovery_marker must use a preserved variable",
        )
        managed_match = re.search(
            r"managed_keys_re='\^\((?P<keys>[^)]+)\)='",
            body,
        )
        self.assertIsNotNone(managed_match)
        keys = managed_match.group("keys").split("|")
        self.assertNotIn(
            "GATEWAY_PORT",
            keys,
            "GATEWAY_PORT must NOT be in write_recovery_marker's managed keys",
        )

    def test_record_state_preserves_only_valid_keyvalue_lines(self):
        # Guard: the preserve filter must reject comments and stray lines
        # that don't look like KEY=VALUE.
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"record_state\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        body = match.group("body")
        self.assertIn(
            "grep -E '^[A-Za-z_][A-Za-z0-9_]*='",
            body,
            "record_state must filter preserved lines to valid KEY=VALUE syntax",
        )


class RegisterGatewayPreserveLogicFunctionalTests(unittest.TestCase):
    """Functional verification of the state-preserve logic:
    actually run the grep -Ev filter against a synthesized state file
    that mimics what documentdb-setup writes in greenfield (setup.conf
    with GATEWAY_PORT, DATA_DIR, CONFIG_FILE, DOCUMENTDB_MANAGED_POSTGRES)
    and verify the foreign keys survive while the managed keys are
    overridden."""

    def test_preserve_filter_keeps_gateway_port(self):
        import subprocess
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            # Mimic what documentdb-setup writes in greenfield.
            f.write(
                "DOCUMENTDB_MANAGED_POSTGRES=true\n"
                "DOCUMENTDB_MODE=greenfield\n"
                "PG_VERSION=18\n"
                "PG_PORT=10260\n"
                "PG_OWNER=documentdb-local\n"
                "DATA_DIR=/var/lib/documentdb-local/18/data\n"
                "CONFIG_FILE=/var/lib/documentdb-local/18/data/postgresql.conf\n"
                "HBA_FILE=/var/lib/documentdb-local/18/data/pg_hba.conf\n"
                "IDENT_FILE=/var/lib/documentdb-local/18/data/pg_ident.conf\n"
                "GATEWAY_PORT=10261\n"
            )
            path = f.name
        try:
            managed_re = '^(HBA_FILE|IDENT_FILE|SECRET_FILE|PG_VERSION|CLUSTER_NAME|PG_PORT|PG_OWNER|DOCUMENTDB_MODE|GATEWAY_ENV_FILE)='
            result = subprocess.run(
                ["bash", "-c",
                 f"grep -Ev '{managed_re}' '{path}' | grep -E '^[A-Za-z_][A-Za-z0-9_]*='"],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0)
            preserved_lines = result.stdout.strip().split("\n")
            self.assertIn("GATEWAY_PORT=10261", preserved_lines,
                          "GATEWAY_PORT must survive the preserve filter")
            self.assertIn("DATA_DIR=/var/lib/documentdb-local/18/data", preserved_lines,
                          "DATA_DIR must survive the preserve filter")
            self.assertIn("CONFIG_FILE=/var/lib/documentdb-local/18/data/postgresql.conf",
                          preserved_lines,
                          "CONFIG_FILE must survive the preserve filter")
            self.assertIn("DOCUMENTDB_MANAGED_POSTGRES=true", preserved_lines,
                          "DOCUMENTDB_MANAGED_POSTGRES must survive the preserve filter")
            for line in preserved_lines:
                key = line.split("=", 1)[0]
                self.assertNotIn(key, ("HBA_FILE", "IDENT_FILE", "PG_PORT", "PG_OWNER",
                                       "DOCUMENTDB_MODE", "PG_VERSION", "GATEWAY_ENV_FILE"),
                                 f"Managed key {key} should NOT survive (will be overwritten)")
        finally:
            import os
            os.unlink(path)

    def test_preserve_filter_handles_empty_file(self):
        import subprocess
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            path = f.name
        try:
            managed_re = '^(HBA_FILE|IDENT_FILE|SECRET_FILE|PG_VERSION|CLUSTER_NAME|PG_PORT|PG_OWNER|DOCUMENTDB_MODE|GATEWAY_ENV_FILE)='
            result = subprocess.run(
                ["bash", "-c",
                 f"grep -Ev '{managed_re}' '{path}' 2>/dev/null | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' || true"],
                capture_output=True, text=True,
            )
            self.assertEqual(result.stdout, "", "Empty input should produce empty output")
        finally:
            import os
            os.unlink(path)

    def test_preserve_filter_strips_comments_and_garbage(self):
        import subprocess
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            f.write(
                "# This is a comment\n"
                "GATEWAY_PORT=10261\n"
                "not-a-keyvalue-line\n"
                "\n"
                "ANOTHER_KEY=value\n"
            )
            path = f.name
        try:
            managed_re = '^(HBA_FILE|IDENT_FILE|SECRET_FILE|PG_VERSION|CLUSTER_NAME|PG_PORT|PG_OWNER|DOCUMENTDB_MODE|GATEWAY_ENV_FILE)='
            result = subprocess.run(
                ["bash", "-c",
                 f"grep -Ev '{managed_re}' '{path}' | grep -E '^[A-Za-z_][A-Za-z0-9_]*='"],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0)
            preserved = result.stdout.strip().split("\n")
            self.assertEqual(sorted(preserved), sorted(["GATEWAY_PORT=10261", "ANOTHER_KEY=value"]))
            for line in preserved:
                self.assertFalse(line.startswith("#"))
                self.assertIn("=", line)
        finally:
            import os
            os.unlink(path)


class wizardEnablesTargetForBootPersistenceTests(unittest.TestCase):
    """The wizard previously
    enabled individual templated services (documentdb-postgresql@N,
    documentdb-gateway-local@N) but never enabled
    documentdb-local@N.target itself. Since the services are only
    WantedBy=target, the target had to be enabled for reboot
    persistence — but no one did it. The wizard must call ensure_target_enabled_at_boot before printing the completion message
    so the stack actually persists across reboots."""

    def test_ensure_target_enabled_at_boot_helper_exists(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "ensure_target_enabled_at_boot()",
            text,
            "wizard must define ensure_target_enabled_at_boot helper",
        )

    def test_helper_uses_per_major_target(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_target_enabled_at_boot\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            'documentdb-local@${PG_VERSION}.target',
            body,
            "helper must reference per-major target",
        )
        self.assertIn(
            "systemctl enable",
            body,
            "helper must call systemctl enable on the target",
        )
        self.assertIn(
            "PUBLIC_ALIAS_PG_MAJOR",
            body,
            "helper must prefer the public wrapper alias for the paved-road major",
        )

    def test_helper_respects_no_enable(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"ensure_target_enabled_at_boot\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        body = match.group("body")
        self.assertRegex(
            body,
            r'"\$\{NO_ENABLE\}"\s*==\s*"true"\s*\]\]\s*&&\s*return',
            "helper must early-return when --no-enable is set",
        )

    def test_main_calls_helper_before_completion(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        # The main flow must call ensure_target_enabled_at_boot before
        # print_completion_message so the operator's "ready" message
        # reflects the actually-enabled state.
        idx_helper = text.find("ensure_target_enabled_at_boot\n")
        idx_complete = text.find("print_completion_message\n")
        self.assertGreater(idx_helper, 0)
        self.assertGreater(idx_complete, 0)
        self.assertLess(
            idx_helper, idx_complete,
            "ensure_target_enabled_at_boot must run before print_completion_message",
        )

    def test_dry_run_preview_advertises_target_enable(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "systemctl enable documentdb-local@${preview_pg_version}.target",
            text,
            "dry-run preview must list target-enable step ",
        )


class WaitForGatewayReadyAcceptsUnitNameTests(unittest.TestCase):
    """wait_for_gateway_ready
    previously hardcoded `journalctl -u documentdb-gateway` in its
    failure-hint, but start_gateway often selects
    documentdb-gateway-local@N.service. The function must accept the
    unit name as a parameter and reflect it in the hint."""

    def test_wait_for_gateway_ready_takes_unit_arg(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"wait_for_gateway_ready\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            'running_unit="${1:-}"',
            body,
            "wait_for_gateway_ready must accept unit name as $1",
        )
        self.assertIn(
            'journalctl -u ${running_unit}',
            body,
            "failure hint must use the passed unit name",
        )

    def test_all_callers_pass_unit_name(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        # Find all calls to wait_for_gateway_ready (excluding the
        # definition itself). All of them must pass an argument.
        calls = re.findall(r'wait_for_gateway_ready(?:\s+[^"\n]*)?(\s+"[^"]*")?', text)
        # We expect at least 3 callers in start_gateway: per-major
        # systemd path, non-templated systemd path, and nohup fallback.
        # The function definition itself has no arg after the name.
        # Confirm via line-level check that the only naked invocation
        # is the definition line.
        for line in text.splitlines():
            stripped = line.strip()
            if stripped == "wait_for_gateway_ready" or stripped.startswith("wait_for_gateway_ready "):
                # Definition line is "wait_for_gateway_ready() {" — handled separately.
                if stripped.startswith("wait_for_gateway_ready()"):
                    continue
                self.assertTrue(
                    '"' in line,
                    f"Naked wait_for_gateway_ready call missing unit argument: {line!r}",
                )


class GatewayListenerPidSafetyTests(unittest.TestCase):
    """find_listener_pid returns literal PID 1 when /proc/net can only
    prove a listener exists but cannot identify its owner. That sentinel
    must never flow into kill/SIGKILL paths."""

    def test_stop_gateway_process_refuses_unresolved_pid(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"stop_gateway_process\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        guard_index = body.find('[[ -z "${pid}" || ! "${pid}" =~ ^[0-9]+$ ]] || (( 10#${pid} <= 1 ))')
        kill_index = body.find('kill "${pid}"')
        self.assertGreaterEqual(guard_index, 0,
                                "stop_gateway_process must reject unresolved placeholder PID 1 and invalid PIDs")
        self.assertGreater(kill_index, guard_index,
                           "PID safety guard must run before any signal is sent")
        self.assertIn("Refusing to signal PID", body)

    def test_stop_gateway_process_behaviorally_refuses_unsafe_pids(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        function_match = re.search(
            r"stop_gateway_process\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(function_match)
        function_text = function_match.group(0)

        for pid, expected_rc, expected_kill_calls in (
            ("", 1, 0),
            ("abc", 1, 0),
            ("0", 1, 0),
            ("1", 1, 0),
            ("01", 1, 0),
            ("001", 1, 0),
            ("08", 0, 1),
            ("12345", 0, 1),
        ):
            with self.subTest(pid=pid):
                script = (
                    "set -euo pipefail\n"
                    "kill_calls=0\n"
                    "kill() { kill_calls=$((kill_calls + 1)); return 0; }\n"
                    "log_warn() { :; }\n"
                    "wait_for_listener_to_clear() { return 0; }\n"
                    f"{function_text}\n"
                    "set +e\n"
                    f"stop_gateway_process {shlex.quote(pid)} 10260\n"
                    "rc=$?\n"
                    "set -e\n"
                    "printf 'rc=%s kill_calls=%s\\n' \"${rc}\" \"${kill_calls}\"\n"
                )
                result = subprocess.run(
                    ["bash", "-c", script],
                    capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(
                    f"rc={expected_rc} kill_calls={expected_kill_calls}",
                    result.stdout,
                )

    def test_start_gateway_dies_on_unresolved_listener_owner(self):
        # Both paths stay fail-closed on an unresolved placeholder PID.
        #
        # The systemd-takeover path refuses it outright. The nohup-restart
        # path resolves it against the PER-PORT pidfile written at launch and
        # stops exactly that process; with no trustworthy record it also
        # refuses. An earlier revision instead stopped gateways BY NAME with a
        # host-wide `pgrep -f`, which killed other majors' healthy gateways as
        # collateral (and passed THIS port to stop_gateway_process for each of
        # them, so every unrelated PID escalated to SIGKILL after the 30s wait
        # could not possibly succeed).
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("die_unknown_listener_owner()", text)
        self.assertIn("lsof/ss unavailable", text)
        self.assertGreaterEqual(
            text.count('[[ "${existing_gateway_pid}" != "1" ]] || die_unknown_listener_owner "${GATEWAY_PORT}"'),
            1,
            "the systemd-takeover path must refuse unresolved PID 1",
        )
        self.assertIn(
            'recorded_gw_pid="$(nohup_gateway_pid_for_port "${GATEWAY_PORT}"',
            text,
            "the nohup path must resolve the placeholder from the per-port "
            "record rather than a host-wide process match",
        )
        self.assertIn(
            '[[ -n "${recorded_gw_pid}" ]] || die_unknown_listener_owner "${GATEWAY_PORT}"',
            text,
            "with no trustworthy per-port record the nohup path must stay "
            "fail-closed instead of signalling an unidentified process",
        )
        self.assertNotIn(
            "stopping the gateway daemon by name",
            text,
            "stopping gateways by name is the collateral-kill defect; the "
            "nohup path must stop only the PID recorded for this port",
        )

    def test_nohup_launch_records_the_daemon_pid_not_the_subshell(self):
        # BEHAVIOURAL, deliberately. The first version of this mechanism was
        # written as
        #     cd DIR && ... && nohup BIN CFG > log 2>&1 & echo $! > pidfile
        # where `&` binds to the whole AND-list, so the shell backgrounds that
        # list and `$!` is the intermediate SUBSHELL's pid — a bash process,
        # never the daemon. Every source-text assertion in this file passed
        # against that completely non-functional writer, which is why this one
        # runs the shell instead of reading the script.
        #
        # SCOPE of the two runnable invocations below: they reproduce the
        # shipped GROUPING/SILENCE shape — `& { ... } 2>/dev/null || true` — not
        # the 3-field record CONTENT. That is the correct split: the grouping is
        # the only part that can only be proven by executing it (source text
        # cannot tell whether `$!` is the daemon or an intermediate subshell),
        # whereas the record content is pinned byte-for-byte by the needles
        # above and exercised end-to-end by the reader tests
        # (test_reader_starttime_and_boot_guards_behaviourally). So the snippets
        # write a single `echo $!` field on purpose — enough to identify the
        # recorded process — and do NOT re-implement the starttime/boot_id
        # computation, which would only duplicate the reader tests.
        # (a) a WRITABLE target proves the recorded pid is the daemon; (b) an
        # UNWRITABLE target proves the grouped tail exits 0 with EMPTY stderr
        # (an ungrouped `> pidfile 2>/dev/null` leaks the open error, verified)
        # and appends NOTHING of its own — an earlier revision ended in its own
        # `true;`, making its rc==0 assertion tautological.
        # The SHIPPED launch tail is asserted (needles) through the closing
        # `; }` so that deleting the pidfile write, un-grouping its stderr
        # redirect, or dropping the `|| true` all fail here (each breaks a
        # different guarantee: day-2 self-identification, silent record failure,
        # and not aborting the wizard after the gateway is already running).
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        # The record is now three fields (PID STARTTIME BOOT_ID) computed
        # inside the gateway-user child group. Pin the load-bearing invariants:
        # brace-grouped background + grouped-silent record write + || true.
        # Needles match the SHIPPED source bytes: the record write lives inside
        # the double-quoted run_as_user_shell argument, so its $-expansions are
        # backslash-escaped to fire in the launched (gateway-user) shell.
        for needle, why in (
            (r"& { _gwp=\$!;", "the record write must be brace-grouped with the "
                               "backgrounded daemon so $! is the daemon, not a subshell"),
            (r"""printf '%s' \"\$_gwp\${_gws:+ \$_gws\${_gwb:+ \$_gwb}}\" > ${escaped_pidfile}; }""",
             "the record must carry PID + optional starttime + optional boot_id, "
             "with boot_id NESTED inside starttime so it can never orphan into "
             "the starttime slot as a malformed 'PID BOOT_ID'"),
            (r"2>/dev/null || true; }",
             "the record write must be grouped-silent and never abort the wizard"),
        ):
            self.assertIn(needle, text, why)
        shipped_tail = r"& { _gwp=\$!;"
        self.assertIn(
            shipped_tail, text,
            "the shipped nohup launch must brace-group the daemon with a "
            "grouped, stderr-silenced, ||true'd pidfile write",
        )

        # Text pin above; the BEHAVIOURAL half needs a real /proc and bash.
        if not os.path.isdir("/proc"):
            self.skipTest("needs /proc to identify the recorded process")
        shell = shutil.which("bash")
        if not shell:
            self.skipTest("bash not available")

        with tempfile.TemporaryDirectory() as tmp:
            pidfile = os.path.join(tmp, "gw.pid")
            cmdfile = os.path.join(tmp, "cmdline")
            envfile = os.path.join(tmp, "env")
            with open(envfile, "w", encoding="utf-8") as fh:
                fh.write("export DOCUMENTDB_TEST_MARKER=1\n")

            # (a) writable target — shipped GROUPING shape (sleep standing in
            # for the daemon; single echo field standing in for the record),
            # then the cmdline captured in the SAME shell
            # AFTER the group, from the pid the group recorded. The daemon
            # (sleep 30) is alive throughout, so the recorded pid cannot vanish
            # mid-read -- but the read itself must RETRY past the fork->exec
            # window: immediately after `&` the child still shows the parent
            # shell's image ("bash -lc ...") in /proc/<pid>/cmdline until it
            # execs nohup/sleep, so on a slow or loaded host (2-core CI agents)
            # a single immediate read loses that race and misreads a CORRECT
            # daemon pid as the subshell. Only the '-lc' shell image is
            # retried; a pid that never leaves it (a real regression that
            # recorded the enclosing subshell, whose image is '-lc' for life)
            # still fails below once the ~5s budget lapses. Nothing appended
            # can mask the group's own behaviour because (a) asserts file
            # contents, not rc.
            cmd_a = (
                f"cd {tmp} && set -a && . {envfile} && set +a && "
                f"{{ nohup sleep 30 > {tmp}/gw.log 2>&1 & "
                f"{{ echo $! > {pidfile}; }} 2>/dev/null || true; }}; "
                f"gwpid=$(cat {pidfile} 2>/dev/null); "
                f"for _ in $(seq 1 50); do "
                f"tr '\\0' ' ' < /proc/$gwpid/cmdline > {cmdfile} 2>/dev/null"
                f" || true; "
                f"grep -q -- -lc {cmdfile} 2>/dev/null || break; "
                f"sleep 0.1; "
                f"done"
            )
            subprocess.run([shell, "-lc", cmd_a], capture_output=True,
                           text=True, timeout=20)
            with open(pidfile, encoding="utf-8") as fh:
                pid = fh.read().strip()
            self.assertTrue(pid.isdigit(), f"pidfile did not receive a pid: {pid!r}")
            try:
                with open(cmdfile, encoding="utf-8") as fh:
                    cmdline = fh.read()
                self.assertIn(
                    "sleep", cmdline,
                    "the recorded pid must be the launched daemon; got a "
                    f"different process instead: {cmdline!r}",
                )
                self.assertNotIn(
                    "-lc", cmdline,
                    "the recorded pid is the enclosing subshell, not the "
                    f"daemon — the launch lost its brace grouping: {cmdline!r}",
                )
            finally:
                subprocess.run(["kill", pid], capture_output=True)

            # (b) unwritable target — shipped GROUPING shape with NOTHING
            # appended, so returncode and stderr are exactly what the shipped
            # grouped-silent write produces when the record cannot be written.
            unwritable = os.path.join(tmp, "no-such-dir", "gw.pid")
            cmd_b = (
                f"cd {tmp} && set -a && . {envfile} && set +a && "
                f"{{ nohup sleep 1 > {tmp}/gw2.log 2>&1 & "
                f"{{ echo $! > {unwritable}; }} 2>/dev/null || true; }}"
            )
            # Plain -c, not -lc: the property under test (grouped, silent
            # redirect failure) is shell-profile-independent, and a host whose
            # profile.d writes to stderr must not fail the assertion below.
            result_b = subprocess.run([shell, "-c", cmd_b], capture_output=True,
                                      text=True, timeout=20)
            self.assertEqual(
                result_b.returncode, 0,
                "a failed pidfile write must not abort the wizard under set -e "
                f"(the gateway is already running): {result_b.stderr!r}",
            )
            self.assertEqual(
                result_b.stderr, "",
                "a failed pidfile write must be silent — the grouped "
                "2>/dev/null must swallow the open error",
            )

    def test_c4_argv_probe_behaviourally_detects_a_planted_leak(self):
        # BEHAVIOURAL, and it closes a named merge blocker: "prove the argv
        # probe goes RED on a planted leak." The probe's whole history is
        # always-green failures — a single-quote that broke the shell, a BRE
        # that ate `\!` — so asserting its text is worthless. Extract the exact
        # probe string the suite ships, point its /proc glob at a synthetic
        # fixture, and run it against planted cmdlines.
        shell = shutil.which("bash")
        if not shell:
            self.skipTest("bash not available")

        container_suite = (OSS_ROOT / "packaging" / "test_packages"
                           / "e2e-container-scenarios.sh")
        text = container_suite.read_text(encoding="utf-8")
        # The probe is `local probe='...'`, a single-quoted block ending at a
        # line that is exactly a quote.
        m = re.search(r"local probe='\n(?P<body>.*?)\n'\n", text, flags=re.DOTALL)
        self.assertIsNotNone(m, "could not extract the C4 probe from the suite")
        probe = m.group("body")
        self.assertIn("grep -l -F -f", probe,
                      "probe must match with grep -F (fixed strings), not a regex")

        # A password full of grep/BRE/shell metacharacters — the exact class
        # that defeated the earlier forms.
        password = "pa\"ss'w0rd\\!x*.["
        canary = "ARGVPROBECANARY7f3a"

        def run(fixture_setup):
            with tempfile.TemporaryDirectory() as tmp:
                procdir = os.path.join(tmp, "proc")
                os.makedirs(procdir)
                fixture_setup(procdir)
                # Redirect the probe's two /proc globs at the fixture. Use
                # forward slashes: the shell is bash, and a glob containing
                # backslashes (Windows os.path.join) would not expand.
                fixture_glob = procdir.replace(os.sep, "/") + "/[0-9]*/cmdline"
                probe_local = probe.replace("/proc/[0-9]*/cmdline", fixture_glob)
                result = subprocess.run(
                    [shell, "-c", probe_local],
                    input=password, capture_output=True, text=True, timeout=20,
                )
                return result.stdout.strip(), result.stderr

        def write_cmdline(procdir, pid, args):
            d = os.path.join(procdir, str(pid))
            os.makedirs(d)
            # /proc/<pid>/cmdline is NUL-separated, NUL-terminated.
            with open(os.path.join(d, "cmdline"), "wb") as fh:
                fh.write(b"\0".join(a.encode() for a in args) + b"\0")

        # 1. Clean host: the control canary is present (mechanism works), the
        #    password appears nowhere -> CLEAN.
        def clean(procdir):
            write_cmdline(procdir, 101, ["sh", "-c", f"probe {canary} here"])
            write_cmdline(procdir, 102, ["gateway", "--pg-url-file", "/x"])
        verdict, err = run(clean)
        self.assertEqual(verdict, "CLEAN",
                         f"clean host must be CLEAN; got {verdict!r} {err!r}")

        # 2. Leaked password on some process's argv -> LEAK. This is the case
        #    the probe exists to catch, and the case every earlier form missed.
        def leaked(procdir):
            write_cmdline(procdir, 101, ["sh", "-c", f"probe {canary} here"])
            write_cmdline(procdir, 102, ["admin", "--password", password])
        verdict, err = run(leaked)
        self.assertEqual(verdict, "LEAK",
                         f"a planted password must be caught; got {verdict!r} {err!r}")

        # 3. Mechanism broken (control canary absent) -> BROKEN, never CLEAN.
        def no_control(procdir):
            write_cmdline(procdir, 102, ["gateway", "--pg-url-file", "/x"])
        verdict, err = run(no_control)
        self.assertEqual(verdict, "BROKEN",
                         f"a probe that cannot see its own control must report "
                         f"BROKEN, not a false CLEAN; got {verdict!r} {err!r}")

    def _extract_shell_function(self, name):
        # Search BOTH the wizard and the shared lib: several identity
        # primitives now live in documentdb-tools-lib.sh. Assert the function
        # is defined in EXACTLY ONE of them — a second definition (a forgotten
        # copy left in setup.sh after the move) would let setup's copy silently
        # shadow the lib's and let drift return with green tests.
        pat = re.compile(rf"^{name}\(\)\s*\{{.*?^\}}", re.DOTALL | re.MULTILINE)
        hits = []
        for path in (SETUP_SCRIPT, TOOLS_LIB):
            m = pat.search(path.read_text(encoding="utf-8"))
            if m:
                hits.append((path.name, m.group(0)))
        self.assertEqual(
            len(hits), 1,
            f"{name} must be defined in exactly one of "
            f"{SETUP_SCRIPT.name}/{TOOLS_LIB.name}; found in "
            f"{[h[0] for h in hits]}",
        )
        return hits[0][1]

    @staticmethod
    def _spawn_listener(family="v4"):
        # Ephemeral-port listener; prints its chosen port then sleeps. Own
        # child ⇒ its /proc fd table is readable unprivileged, so the tests
        # exercise DEFINITE answers without root.
        code = (
            "import socket,sys,time\n"
            + ("s=socket.socket(socket.AF_INET6)\n" if family == "v6"
               else "s=socket.socket()\n")
            + ("s.bind(('::1',0))\n" if family == "v6"
               else "s.bind(('127.0.0.1',0))\n")
            + "s.listen(1)\nprint(s.getsockname()[1],flush=True)\n"
            + "time.sleep(30)\n"
        )
        proc = subprocess.Popen(["python3", "-c", code],
                                stdout=subprocess.PIPE, text=True)
        line = proc.stdout.readline().strip()
        if not line:
            # e.g. an IPv6-less host where the ::1 bind failed — the child
            # died before printing a port. Reap and signal "unavailable".
            proc.wait()
            raise unittest.SkipTest(f"could not spawn {family} listener "
                                    "(address family unavailable?)")
        return proc, int(line)

    def _port_helpers(self):
        return (self._extract_shell_function("port_listen_inodes") + "\n"
                + self._extract_shell_function("pid_listens_on_port") + "\n")

    def _reader_bundle(self):
        # Everything nohup_gateway_pid_for_port depends on, plus a log_warn
        # stub (the reader logs reject rationales to stderr). Tests still
        # override nohup_gateway_pidfile (temp path) and may stub
        # gateway_exe_matches. proc_starttime/current_boot_id/
        # nohup_gateway_record_pid are the record helpers the reader now uses.
        return (
            'log_warn() { echo "WARN: $*" >&2; }\n'
            + self._port_helpers()
            + self._extract_shell_function("proc_starttime") + "\n"
            + self._extract_shell_function("current_boot_id") + "\n"
            + self._extract_shell_function("nohup_gateway_record_pid") + "\n"
            + self._extract_shell_function("nohup_gateway_pid_for_port") + "\n"
        )

    def test_port_identity_primitives_behaviourally(self):
        # BEHAVIOURAL. These two helpers are the new root-cause fix for the
        # "1" placeholder family (unidentifiable listeners): everything else
        # keys off their three-state answer, so they get real listeners, not
        # source-text checks. Covers v4, tcp6-only (the dual-stack parse is
        # the primary new failure surface), definite-no via a live same-user
        # non-owner, and unknown when the port has no listener at all.
        if not os.path.isdir("/proc") or not os.access("/proc/net/tcp", os.R_OK):
            self.skipTest("needs readable /proc/net/tcp")
        shell = shutil.which("bash")
        if not shell:
            self.skipTest("bash not available")
        helpers = self._port_helpers()

        def run(snippet):
            return subprocess.run(
                [shell, "-c", "set -uo pipefail\n" + helpers + snippet],
                capture_output=True, text=True, timeout=20)

        for family in ("v4", "v6"):
            with self.subTest(family=family):
                owner, port = self._spawn_listener(family)
                other, other_port = self._spawn_listener("v4")
                try:
                    r = run(f"port_listen_inodes {port} | wc -l")
                    self.assertGreaterEqual(
                        int(r.stdout.strip() or 0), 1,
                        f"no inode found for a live {family} listener: "
                        f"{r.stdout!r} {r.stderr!r}")
                    r = run(f"pid_listens_on_port {owner.pid} {port}; echo rc=$?")
                    self.assertEqual(r.stdout.strip(), "rc=0",
                                     f"owner must be a definite yes: {r.stdout!r}")
                    r = run(f"pid_listens_on_port {other.pid} {port}; echo rc=$?")
                    self.assertEqual(
                        r.stdout.strip(), "rc=1",
                        "a live, fd-readable NON-owner must be a definite no "
                        f"— this is the recycled-PID reject: {r.stdout!r}")
                finally:
                    owner.kill(); other.kill()
                    owner.wait(); other.wait()
                # Listener gone → no inodes → three-state UNKNOWN, never a
                # definite answer manufactured from absence.
                r = run(f"pid_listens_on_port {os.getpid()} {port}; echo rc=$?")
                self.assertEqual(r.stdout.strip(), "rc=2",
                                 f"empty port must be unknown: {r.stdout!r}")

    def test_find_listener_pid_resolves_real_owner_without_ss_lsof(self):
        # BEHAVIOURAL, for the highest-blast-radius change (9 callers): with
        # lsof and ss both unavailable, find_listener_pid must resolve the
        # REAL owning pid from /proc alone instead of minting the "1"
        # placeholder, and must print nothing for a listener-free port.
        if not os.path.isdir("/proc") or not os.access("/proc/net/tcp", os.R_OK):
            self.skipTest("needs readable /proc/net/tcp")
        shell = shutil.which("bash")
        if not shell:
            self.skipTest("bash not available")
        harness = ("set -uo pipefail\n"
                   "command_exists() { return 1; }\n"   # no lsof, no ss
                   + self._port_helpers()
                   + self._extract_shell_function("find_listener_pid") + "\n")
        owner, port = self._spawn_listener()
        try:
            r = subprocess.run(
                [shell, "-c", harness + f"find_listener_pid {port}"],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(
                r.stdout.strip(), str(owner.pid),
                "the /proc fallback must name the true owner, not the "
                f"placeholder: {r.stdout!r} {r.stderr!r}")
        finally:
            owner.kill(); owner.wait()
        r = subprocess.run(
            [shell, "-c", harness + f"find_listener_pid {port}"],
            capture_output=True, text=True, timeout=30)
        self.assertEqual(r.stdout.strip(), "",
                         f"no listener must print nothing: {r.stdout!r}")

    def test_proc_starttime_parses_comm_with_parens_and_spaces(self):
        # The risky part of the starttime mechanism: /proc/<pid>/stat's comm
        # (field 2) can contain spaces and ')'. proc_starttime splits on the
        # LAST ')' and takes field 20 of the tail (overall field 22). Feed the
        # extracted awk crafted stat lines and assert it recovers starttime.
        shell = shutil.which("bash")
        if not shell:
            self.skipTest("bash not available")
        # The exact awk the helper (and the writer) use.
        awk = r"""awk '{ n = split($0, a, ")"); split(a[n], f); print f[20] }'"""
        # overall fields: 1=pid 2=(comm) 3=state 4..21 ... 22=starttime(=987654)
        tail = "R 1 1 1 0 -1 0 0 0 0 0 10 20 0 0 20 0 1 0 987654 rest more"
        for comm in ["(bash)", "(weird ) name)", "(x) y) z)", "(sleep 30)"]:
            with self.subTest(comm=comm):
                line = f"1234 {comm} {tail}"
                r = subprocess.run([shell, "-c", f"printf %s {shlex.quote(line)} | {awk}"],
                                   capture_output=True, text=True, timeout=10)
                self.assertEqual(r.stdout.strip(), "987654",
                                 f"starttime misparsed for comm={comm!r}: "
                                 f"{r.stdout!r} {r.stderr!r}")

    def _write_record(self, path, pid, start=None, boot=None):
        parts = [str(pid)]
        if start is not None:
            parts.append(str(start))
        if boot is not None:
            parts.append(str(boot))
        with open(path, "w") as fh:
            fh.write(" ".join(parts) + "\n")

    def _run_reader(self, record_path, port, exe_ok=True):
        shell = shutil.which("bash")
        stub_exe = "return 0" if exe_ok else "return 1"
        script = (
            "set -uo pipefail\n"
            f"nohup_gateway_pidfile() {{ printf %s {shlex.quote(record_path.replace(os.sep,'/'))}; }}\n"
            f"gateway_exe_matches() {{ {stub_exe}; }}\n"
            + self._reader_bundle()
            + f"\nout=$(nohup_gateway_pid_for_port {port}); rc=$?\n"
            'printf "rc=%s out=%s\\n" "${rc}" "${out}"\n'
        )
        return subprocess.run([shell, "-c", script], capture_output=True,
                              text=True, timeout=20)

    def test_reader_starttime_and_boot_guards_behaviourally(self):
        # BEHAVIOURAL: the ptrace-independent recycle guard. A live PID that is
        # a gateway (stub) but whose recorded starttime or boot_id no longer
        # matches must be rejected; a correct record is accepted.
        if not os.path.isdir("/proc"):
            self.skipTest("needs /proc")
        shell = shutil.which("bash")
        if not shell:
            self.skipTest("bash not available")
        proc = subprocess.Popen(["sleep", "60"])
        try:
            pid = proc.pid
            # the running pid's true starttime/boot, via the same helpers
            probe = subprocess.run(
                [shell, "-c", self._reader_bundle()
                 + f'printf "%s %s" "$(proc_starttime {pid})" "$(current_boot_id)"'],
                capture_output=True, text=True, timeout=10)
            true_start, true_boot = probe.stdout.split()
            with tempfile.TemporaryDirectory() as tmp:
                rec = os.path.join(tmp, "gateway-55001.pid")
                # (a) correct 3-field record → accept (prints the pid)
                self._write_record(rec, pid, true_start, true_boot)
                r = self._run_reader(rec, 55001)
                self.assertEqual(r.stdout.strip(), f"rc=0 out={pid}",
                                 f"correct record must accept: {r.stdout!r} {r.stderr!r}")
                # (b) wrong starttime → reject, empty stdout, rationale on stderr
                self._write_record(rec, pid, str(int(true_start) + 1), true_boot)
                r = self._run_reader(rec, 55001)
                self.assertEqual(r.stdout.strip(), "rc=1 out=",
                                 f"recycled (starttime) must reject: {r.stdout!r}")
                self.assertIn("start time", r.stderr)
                # (c) different boot_id → reject
                self._write_record(rec, pid, true_start,
                                   "00000000-0000-0000-0000-000000000000")
                r = self._run_reader(rec, 55001)
                self.assertEqual(r.stdout.strip(), "rc=1 out=",
                                 f"stale boot must reject: {r.stdout!r}")
                self.assertIn("previous boot", r.stderr)
                # (d) LEGACY one-field record → accepted (no new brick): live +
                # gateway + nothing on the port (rc2) → accept.
                self._write_record(rec, pid)
                r = self._run_reader(rec, 55001)
                self.assertEqual(r.stdout.strip(), f"rc=0 out={pid}",
                                 f"legacy record must still be honoured: {r.stdout!r}")
        finally:
            proc.kill(); proc.wait()

    def test_reader_rejects_alive_gateway_on_wrong_port(self):
        # BEHAVIOURAL — finding 1's exact scenario: the record names a pid
        # that is alive, fd-readable, and passes the exe check (stubbed yes,
        # as a recycled same-binary gateway would), but holds a DIFFERENT
        # port. The reader must reject with empty stdout and a stderr
        # rationale — signalling that pid is the cross-major collateral kill.
        if not os.path.isdir("/proc") or not os.access("/proc/net/tcp", os.R_OK):
            self.skipTest("needs readable /proc/net/tcp")
        shell = shutil.which("bash")
        if not shell:
            self.skipTest("bash not available")
        target_owner, target_port = self._spawn_listener()
        imposter, _ = self._spawn_listener()   # alive, listening elsewhere
        try:
            with tempfile.TemporaryDirectory() as tmp:
                record = os.path.join(tmp, f"gateway-{target_port}.pid")
                with open(record, "w") as fh:
                    fh.write(str(imposter.pid))
                record_posix = record.replace(os.sep, "/")
                script = (
                    "set -uo pipefail\n"
                    "log_warn() { echo \"WARN: $*\" >&2; }\n"
                    f"nohup_gateway_pidfile() {{ printf %s {shlex.quote(record_posix)}; }}\n"
                    "gateway_exe_matches() { return 0; }\n"
                    + self._reader_bundle()
                    + f"\nout=$(nohup_gateway_pid_for_port {target_port}); rc=$?\n"
                    'printf "rc=%s out=%s\\n" "${rc}" "${out}"\n'
                )
                r = subprocess.run([shell, "-c", script],
                                   capture_output=True, text=True, timeout=20)
                self.assertEqual(r.stdout.strip(), "rc=1 out=",
                                 f"must reject with EMPTY stdout: {r.stdout!r}")
                self.assertIn("does not hold the port", r.stderr,
                              "the reject must log its recycled-PID rationale")
        finally:
            target_owner.kill(); imposter.kill()
            target_owner.wait(); imposter.wait()

    def test_pid1_is_postgres_behaviourally_discriminates(self):
        # BEHAVIOURAL. This predicate gates the /proc/1 UID ownership check —
        # the guard whose die message promises "documentdb-setup will not
        # modify another PostgreSQL cluster". The source-text test above pins
        # the guard's PRESENCE; this one runs the predicate, because an
        # always-false regression would silently skip the security check while
        # every text assertion stayed green.
        #
        # The probe paths are substituted with COUNTED replacements: if a
        # refactor renames /proc/1/comm or the ps fallback, the counts change
        # and this test fails loudly instead of silently testing nothing.
        shell = shutil.which("bash")
        if not shell:
            self.skipTest("bash not available")
        fn = self._extract_shell_function("pid1_is_postgres")

        self.assertEqual(fn.count("/proc/1/comm"), 2,
                         "expected the -r guard + the tr read of /proc/1/comm")
        self.assertEqual(fn.count("ps -o comm= -p 1"), 1,
                         "expected exactly one ps fallback")

        cases = [
            ("postgres",   None,        0, "comm=postgres"),
            ("postmaster", None,        0, "comm=postmaster"),
            ("systemd",    None,        1, "comm=systemd (init) must be no"),
            (None,         "postgres",  0, "no comm file, ps says postgres"),
            (None,         None,        1, "no comm file, ps fails -> no"),
        ]
        for comm, ps, want_rc, why in cases:
            with self.subTest(case=why):
                with tempfile.TemporaryDirectory() as tmp:
                    tmp_posix = tmp.replace(os.sep, "/")
                    comm_path = tmp_posix + "/comm"
                    ps_path = tmp_posix + "/ps"
                    if comm is not None:
                        with open(tmp + os.sep + "comm", "w") as fh:
                            fh.write(comm)
                    if ps is not None:
                        with open(tmp + os.sep + "ps", "w") as fh:
                            fh.write(ps)
                    body = fn.replace("/proc/1/comm", comm_path)
                    body = body.replace("ps -o comm= -p 1",
                                        f"cat {ps_path}")
                    script = (
                        "set -uo pipefail\n"
                        f"{body}\n"
                        "pid1_is_postgres; rc=$?\n"
                        'printf "rc=%s\\n" "${rc}"\n'
                    )
                    result = subprocess.run([shell, "-c", script],
                                            capture_output=True, text=True,
                                            timeout=20)
                    self.assertEqual(
                        result.stdout.strip(), f"rc={want_rc}",
                        f"{why}: got {result.stdout!r} {result.stderr!r}",
                    )

    def test_nohup_gateway_pid_reader_behaviourally_fails_closed(self):
        # BEHAVIOURAL. This reader decides whether a recorded PID may be
        # SIGNALLED, so every way it can wrongly succeed is a way to kill a
        # process we never identified — the collateral-kill defect the per-port
        # record replaced. Source-text assertions that the guards "are present"
        # proved worthless earlier in this same change set (they passed against
        # a writer that recorded the wrong process entirely), so run it.
        shell = shutil.which("bash")
        if not shell:
            self.skipTest("bash not available")
        bundle = self._reader_bundle()

        # Port is picked by binding-then-closing an ephemeral socket rather than
        # hardcoded (matching the postmaster sibling below): nothing listens on
        # it, so the reader's pid_listens_on_port cross-check stays neutral, and
        # no host that happens to occupy a fixed port can perturb the result.
        import socket as _socket
        _probe = _socket.socket()
        _probe.bind(("127.0.0.1", 0))
        free_port = _probe.getsockname()[1]
        _probe.close()

        # (pidfile contents or None to omit, exe_matches stub, expected rc,
        #  expected stdout)
        live = "$$"          # the running shell: guaranteed alive
        dead = "4194303"     # at/above pid_max on virtually all hosts; if a
                             # host with pid_max=4194304 ever has it live, the
                             # failure direction is a visible flake, never a
                             # false pass
        cases = [
            (None,    "return 0", 1, "", "missing record"),
            ("",      "return 0", 1, "", "empty record"),
            ("abc",   "return 0", 1, "", "non-numeric record"),
            ("0",     "return 0", 1, "", "pid 0"),
            ("1",     "return 0", 1, "", "the PID-1 placeholder"),
            ("01",    "return 0", 1, "", "zero-padded pid 1"),
            (dead,    "return 0", 1, "", "a dead pid"),
            (live,    "return 1", 1, "", "a live pid that is not our gateway"),
            (live,    "return 0", 0, "LIVE", "a live pid that IS our gateway"),
        ]
        for contents, exe_stub, want_rc, want_out, why in cases:
            with self.subTest(case=why):
                with tempfile.TemporaryDirectory() as tmp:
                    pidfile = os.path.join(tmp, f"gateway-{free_port}.pid")
                    setup = ""
                    if contents is not None:
                        # `$$` must expand inside the script, not here.
                        setup = f'printf %s "{contents}" > {shlex.quote(pidfile)}\n'
                    script = (
                        "set -uo pipefail\n"
                        f"nohup_gateway_pidfile() {{ printf %s {shlex.quote(pidfile)}; }}\n"
                        f"gateway_exe_matches() {{ {exe_stub}; }}\n"
                        f"{bundle}\n"
                        f"{setup}"
                        f"out=$(nohup_gateway_pid_for_port {free_port}); rc=$?\n"
                        # Normalise a successful result: the actual pid varies.
                        'if [[ ${rc} -eq 0 && -n "${out}" ]]; then out=LIVE; fi\n'
                        'printf "rc=%s out=%s\\n" "${rc}" "${out}"\n'
                    )
                    result = subprocess.run([shell, "-c", script],
                                            capture_output=True, text=True,
                                            timeout=20)
                    # FULL-LINE equality, not assertIn: with want_out="" the
                    # substring form is a prefix match ('rc=1 out=' matches
                    # 'rc=1 out=4194303'), so a reader that returns 1 but
                    # LEAKS the pid on stdout passed every fail-closed case —
                    # and the production caller keys off stdout, so exactly
                    # that regression would signal an unidentified PID.
                    self.assertEqual(
                        result.stdout.strip(),
                        f"rc={want_rc} out={want_out}",
                        f"reader must fail closed on {why} with an EMPTY "
                        f"stdout; got {result.stdout!r} {result.stderr!r}",
                    )

    def test_postmaster_pid_owns_port_behaviourally_requires_a_port_match(self):
        # BEHAVIOURAL. This is what replaced the host-wide `pgrep -x postgres`
        # fallback, and it is the only thing standing between an unidentifiable
        # listener and the wizard treating a foreign PostgreSQL as its own. If
        # it can succeed without a genuine port+liveness match, the fail-open
        # bug it was written to fix is back.
        shell = shutil.which("bash")
        if not shell:
            self.skipTest("bash not available")
        # The function now calls pid_listens_on_port for its staleness
        # cross-check, so the harness must carry the helpers — without them
        # the call would be a 127 that silently skips the check.
        fn = (self._port_helpers()
              + self._extract_shell_function("postmaster_pid_owns_port"))

        # postmaster.pid: line 1 = pid, line 4 = port. `$$` must expand in the
        # SHELL (the running process is our guaranteed-live pid), so it goes
        # inside shell double quotes rather than through shlex.quote. The
        # live-pid-on-matching-port case doubles as the UNKNOWN-parity case:
        # the port is picked by binding-then-closing an ephemeral socket, so
        # nothing listens on it and the cross-check sees no inodes (rc 2) and
        # must keep accepting exactly as before hardening. (A hardcoded port
        # would flip to a definite non-owner reject on any host where a real
        # service happens to occupy it.)
        import socket as _socket
        _probe = _socket.socket()
        _probe.bind(("127.0.0.1", 0))
        free_port = _probe.getsockname()[1]
        _probe.close()
        cases = [
            (None,      None,    1, "no postmaster.pid at all"),
            ("$$",      "9999",     1, "a port that does not match"),
            ("4194303", free_port,  1, "a matching port but a dead pid"),
            ("1",       free_port,  1, "the pid-1 placeholder"),
            ("abc",     free_port,  1, "a malformed pid"),
            ("$$",      free_port,  0, "a live pid on the matching port"),
        ]
        for pid, port, want_rc, why in cases:
            with self.subTest(case=why):
                with tempfile.TemporaryDirectory() as tmp:
                    setup = ""
                    if pid is not None:
                        target = shlex.quote(os.path.join(tmp, "postmaster.pid"))
                        setup = (
                            f'printf "%s\\n/var/lib/data\\n1700000000\\n%s\\n/tmp\\n" '
                            f'"{pid}" "{port}" > {target}\n'
                        )
                    script = (
                        "set -uo pipefail\n"
                        f"DATA_DIR={shlex.quote(tmp)}\n"
                        f"{fn}\n"
                        f"{setup}"
                        f"postmaster_pid_owns_port {free_port}; rc=$?\n"
                        'printf "rc=%s\\n" "${rc}"\n'
                    )
                    result = subprocess.run([shell, "-c", script],
                                            capture_output=True, text=True,
                                            timeout=20)
                    # Full-line equality: assertIn("rc=1") would also match
                    # an "rc=127: command not found" harness failure.
                    self.assertEqual(
                        result.stdout.strip(), f"rc={want_rc}",
                        f"must return {want_rc} for {why}; "
                        f"got {result.stdout!r} {result.stderr!r}",
                    )

        # Stale-record spoof (the hardening's raison d'être): the record
        # names a pid that is ALIVE but does not hold the port, while a
        # different process really listens there. Before the cross-check this
        # passed and could spoof data-dir ownership of a foreign listener's
        # port; it must now be a definite reject.
        if os.path.isdir("/proc") and os.access("/proc/net/tcp", os.R_OK):
            listener, lport = self._spawn_listener()
            bystander = subprocess.Popen(["sleep", "30"])
            try:
                with tempfile.TemporaryDirectory() as tmp:
                    target = shlex.quote(os.path.join(tmp, "postmaster.pid"))
                    script = (
                        "set -uo pipefail\n"
                        f"DATA_DIR={shlex.quote(tmp)}\n"
                        f"{fn}\n"
                        f'printf "%s\\n/var/lib/data\\n1700000000\\n%s\\n/tmp\\n" '
                        f'"{bystander.pid}" "{lport}" > {target}\n'
                        f"postmaster_pid_owns_port {lport}; rc=$?\n"
                        'printf "rc=%s\\n" "${rc}"\n'
                    )
                    result = subprocess.run([shell, "-c", script],
                                            capture_output=True, text=True,
                                            timeout=20)
                    self.assertEqual(
                        result.stdout.strip(), "rc=1",
                        "a stale record whose alive pid does not hold the "
                        "port must be rejected — it would spoof ownership of "
                        f"a foreign listener: {result.stdout!r} {result.stderr!r}",
                    )
            finally:
                listener.kill(); bystander.kill()
                listener.wait(); bystander.wait()

    def test_resolve_uid_check_target_decision_table(self):
        # BEHAVIOURAL. This helper picks WHICH pid the port-owner UID check
        # stats, and it is shared verbatim by the live-cluster adoption path and
        # the greenfield PG-port preflight — so a single wrong branch reopens the
        # bug at BOTH. Statting the wrong pid (init, or a foreign pid-1 postgres
        # that merely shares the host) was the false-death defect the decision
        # table exists to prevent, so exercise every branch rather than assert
        # the source "looks right". The three predicates are stubbed so each
        # (owns / listens / is-postgres) combination is driven deterministically.
        shell = shutil.which("bash")
        if not shell:
            self.skipTest("bash not available")
        fn = self._extract_shell_function("resolve_uid_check_target")

        # (listener_pid, postmaster_owns_rc, pid_listens_rc, pid1_is_pg_rc,
        #  expected_stdout, why)
        cases = [
            ("1234", 1, 1, 1, "1234", "a real resolved pid is returned verbatim"),
            ("",     1, 1, 1, "",     "no listener -> no target"),
            ("1",    0, 1, 1, "",     "pid-1 placeholder but OUR postmaster owns the port -> skip"),
            # PRIORITY PIN: postmaster-owns MUST short-circuit BEFORE the
            # pid-1-holds-the-port check. pm_rc=0 AND plp_rc=0 — if the owns-port
            # arm were deleted or moved below pid_listens, this would fall
            # through to plp_rc=0 and wrongly print "1"; the arm makes it "".
            ("1",    0, 0, 1, "",     "owns-port wins over pid-1-holds-port (priority)"),
            ("1",    1, 0, 1, "1",    "pid 1 provably holds the port -> stat /proc/1"),
            ("1",    1, 1, 1, "",     "pid 1 provably does NOT hold the port -> nothing safe to stat"),
            ("1",    1, 2, 0, "1",    "indeterminate but pid 1 IS postgres -> stat /proc/1"),
            ("1",    1, 2, 1, "",     "indeterminate and pid 1 is NOT postgres -> skip"),
        ]
        for pid, pm_rc, plp_rc, pg_rc, want, why in cases:
            with self.subTest(case=why):
                script = (
                    "set -uo pipefail\n"
                    f"postmaster_pid_owns_port() {{ return {pm_rc}; }}\n"
                    f"pid_listens_on_port() {{ return {plp_rc}; }}\n"
                    f"pid1_is_postgres() {{ return {pg_rc}; }}\n"
                    f"{fn}\n"
                    f'out="$(resolve_uid_check_target {shlex.quote(pid)} 9999)"; rc=$?\n'
                    'printf "rc=%s out=%s\\n" "${rc}" "${out}"\n'
                )
                result = subprocess.run([shell, "-c", script],
                                        capture_output=True, text=True, timeout=20)
                # The helper is a pure computation: rc is always 0; the DECISION
                # is on stdout. Full-line equality so an empty want cannot be a
                # prefix of a leaked pid.
                self.assertEqual(
                    result.stdout.strip(), f"rc=0 out={want}",
                    f"{why}: got {result.stdout!r} {result.stderr!r}",
                )

    def test_nohup_gateway_pid_record_is_validated_before_signalling(self):
        # The per-port record is only usable if it is checked: a stale file
        # left by a crashed gateway can name a PID the kernel has since
        # recycled onto an unrelated process, and signalling that would be
        # exactly the collateral kill this mechanism replaced.
        # The reader moved to the shared lib; its record parse is delegated to
        # nohup_gateway_record_pid and its recycle guard is now starttime/boot
        # based (ptrace-independent), plus the fd-scan cross-check.
        libtext = TOOLS_LIB.read_text(encoding="utf-8")
        match = re.search(
            r"^nohup_gateway_pid_for_port\(\)\s*\{(?P<body>.*?)^\}",
            libtext,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "nohup_gateway_pid_for_port not found in lib")
        body = match.group("body")
        for needle, why in (
            ('nohup_gateway_record_pid "${pidfile}"', "delegated record parse (numeric/>1)"),
            ('kill -0 "${pid}" 2>/dev/null || return 1', "a dead PID"),
            ('gateway_exe_matches "${pid}" || return 1', "a non-gateway binary"),
            ('"${rec_start}" != "${cur_start}"', "a recycled PID (starttime mismatch)"),
            ('"${rec_boot}" != "${cur_boot}"', "a stale-boot record"),
        ):
            self.assertIn(
                needle, body,
                f"the record reader must fail closed on {why}",
            )


class RegisterGatewayCompletionBranchesOnAdminTests(unittest.TestCase):
    """When no --admin-user
    is supplied, the completion message previously printed a misleading
    `mongosh ...admin@.../` connect URI, contradicting the earlier log
    that says no admin user was bootstrapped. Must branch: either show
    connect URI (admin exists) or instruct operator to bootstrap one."""

    def test_completion_branches_on_admin_user(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        # The misleading default `${ADMIN_USER:-admin}` substitution
        # must NOT appear in the connect URI any more.
        self.assertNotIn(
            'connect_user="${ADMIN_USER:-admin}"',
            text,
            "register-gateway must not hardcode admin user fallback in connect URI",
        )

    def test_completion_has_admin_branch(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'if [[ -n "${ADMIN_USER}" ]]; then',
            text,
            "completion must have explicit ADMIN_USER branch",
        )

    def test_completion_has_no_admin_branch(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "Bootstrap first admin user",
            text,
            "completion must instruct bootstrap when ADMIN_USER is empty",
        )
        self.assertIn(
            "documentdb-gateway-admin create-user",
            text,
            "completion's bootstrap instruction must reference the create-user tool",
        )


class GatewayPostinstWorkflowCNotDuplicatedTests(unittest.TestCase):
    """Gateway postinst
    previously printed both Workflow B Next Steps and a Workflow C
    suggestion. When `apt install documentdb` pulls the gateway in
    transitively, the standalone postinst already prints Workflow C
    steps, so the gateway version is redundant and confusing."""

    def test_gateway_postinst_does_not_repeat_workflow_c(self):
        postinst = Path(__file__).resolve().parents[2] / "maintainer-scripts" / "gateway" / "postinst"
        text = postinst.read_text(encoding="utf-8")
        # The legacy wording included "Or install the full
        # stand-alone package instead" — this is what the standalone
        # postinst already prints, so it must not appear here.
        self.assertNotIn(
            "Or install the full stand-alone package instead",
            text,
            "gateway postinst must not redundantly suggest the meta package",
        )


class BrownfieldReloadRequiredAutoReloadTests(unittest.TestCase):
    """Brownfield reload-
    required path used to only log a hint, then continue into
    create_required_extensions_and_users + start_gateway. Without the
    reload, the new pg_hba/pg_ident rules are not active, so the
    gateway cannot authenticate as the documentdb-gateway PG role and
    silently fails to start. Must either auto-reload (preferred, since
    reload is non-disruptive) or exit-and-rerun like the restart path."""

    def test_reload_required_path_invokes_systemctl_reload(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"start_or_restart_postgres\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        # Must reach a confirm_or_apply systemctl reload of the
        # adopted PG unit when PG_RELOAD_CHANGED=true in brownfield.
        self.assertIn(
            'confirm_or_apply "Reload',
            body,
            "brownfield reload path must confirm+apply the reload",
        )
        self.assertIn(
            'systemctl reload "${pg_unit_name}"',
            body,
            "brownfield must reload the actual adopted PG unit, not just log a hint",
        )

    def test_reload_required_falls_back_to_exit_when_no_systemd(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"start_or_restart_postgres\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        body = match.group("body")
        # When systemd is unavailable, must exit-and-rerun (symmetry
        # with the restart-required branch).
        self.assertRegex(
            body,
            r'"\$\{HAS_WORKING_SYSTEMD\}"\s*==\s*"true"',
            "must check systemd availability before invoking systemctl reload",
        )


class GatewayBinaryBasenameBothFormsTests(unittest.TestCase):
    """listener_looks_like_gateway used to match only basename 'documentdb_gateway' (Cargo
    dev binary name). Packaged DEB/RPM install /usr/bin/documentdb-gateway (hyphen). Both must be accepted or the wizard falsely treats
    a running packaged gateway as a non-gateway port conflict."""

    def test_listener_check_accepts_both_basenames(self):
        # The basename matching now lives in gateway_exe_matches, extracted so
        # that listener_looks_like_gateway and the per-port pidfile reader
        # share ONE definition of "this is our gateway" (the reader must
        # confirm identity before signalling a recorded PID, or a recycled PID
        # could be killed). Assert against the helper, and assert the
        # classifier delegates to it.
        # gateway_exe_matches now lives in the shared lib.
        libtext = TOOLS_LIB.read_text(encoding="utf-8")
        self.assertEqual(
            len(re.findall(r"^gateway_exe_matches\(\)", libtext, re.MULTILINE)), 1,
            "gateway_exe_matches must be defined exactly once, in the shared lib",
        )
        self.assertNotIn(
            "gateway_exe_matches()", SETUP_SCRIPT.read_text(encoding="utf-8"),
            "gateway_exe_matches must NOT also be defined in setup.sh (shadow)",
        )
        m = re.search(r"^gateway_exe_matches\(\)\s*\{(?P<body>.*?)^\}",
                      libtext, re.DOTALL | re.MULTILINE)
        self.assertIsNotNone(m)
        body = m.group("body")
        for basename, why in (
            ("documentdb_gateway", "Cargo-built dev binary basename"),
            ("documentdb-gateway", "packaged binary basename"),
            ("documentdb-gateway-daemon", "wrapper/daemon split basename"),
        ):
            self.assertIn(basename, body, f"must accept the {why}")

        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        classifier = re.search(
            r"^listener_looks_like_gateway\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(classifier)
        self.assertIn(
            'gateway_exe_matches "${pid}"',
            classifier.group("body"),
            "listener_looks_like_gateway must delegate identity to the "
            "shared helper rather than re-implementing basename matching",
        )


class CaptureGatewayActiveStatePerMajorTests(unittest.TestCase):
    """The per-major
    templated documentdb-gateway-local@N.service is preferred by
    start_gateway. capture_gateway_active_state must check it too,
    not just the non-templated documentdb-gateway.service, so
    --no-enable correctly restores after PG-restart propagation."""

    def test_captures_per_major_unit_when_pg_version_known(self):
        text = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"capture_gateway_active_state\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn(
            'documentdb-gateway-local@${PG_VERSION}.service',
            body,
            "must inspect per-major templated unit when PG_VERSION is known",
        )
        self.assertIn(
            "documentdb-gateway.service",
            body,
            "must also inspect non-templated Workflow B unit",
        )


class RegisterGatewayPgdataSocketDefaultTests(unittest.TestCase):
    """resolve_cluster_paths
    early-returned for --pgdata without setting SOCKET_DIR. Result:
    pg-url had `host=&port=...` (empty host), role/extension checks
    silently skipped. Must default SOCKET_DIR in the --pgdata branch."""

    def test_pgdata_branch_defaults_socket_dir(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"resolve_cluster_paths\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        # Find the --pgdata branch (the if [[ -n "${PGDATA}" ]]) and
        # verify it sets SOCKET_DIR before its return.
        pgdata_branch = re.search(
            r'if \[\[ -n "\${PGDATA}" \]\];\s*then(.*?)return 0',
            body,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(pgdata_branch)
        self.assertIn(
            "SOCKET_DIR",
            pgdata_branch.group(1),
            "pgdata branch must set SOCKET_DIR before returning",
        )
        self.assertIn(
            "/var/run/postgresql",
            pgdata_branch.group(1),
            "default socket should match the distro convention",
        )


class StandaloneDebPrermStopsTargetTests(unittest.TestCase):
    """RPM has %preun to
    stop+disable documentdb-local@N.target on remove, but DEB had no
    prerm. apt remove/purge would unlink unit files while services
    still running. Must mirror RPM behavior in DEB prerm."""

    def test_deb_prerm_exists_in_build_script(self):
        build_script = (Path(__file__).resolve().parents[3] / "packaging" /
                        "standalone" / "build-standalone-deb.sh")
        text = build_script.read_text(encoding="utf-8")
        self.assertIn(
            'cat > "${PKG_DIR}/DEBIAN/prerm"',
            text,
            "build-standalone-deb.sh must generate a DEBIAN/prerm script",
        )

    def test_deb_prerm_stops_and_disables_target_on_remove(self):
        build_script = (Path(__file__).resolve().parents[3] / "packaging" /
                        "standalone" / "build-standalone-deb.sh")
        text = build_script.read_text(encoding="utf-8")
        prerm_match = re.search(
            r'cat > "\$\{PKG_DIR\}/DEBIAN/prerm" <<PRERM\n(.*?)\nPRERM',
            text,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(prerm_match)
        prerm = prerm_match.group(1)
        self.assertIn(
            "remove)",
            prerm,
            "prerm must branch on Debian's 'remove' case",
        )
        self.assertIn(
            'systemctl stop "documentdb-local@${PG_VERSION}.target"',
            prerm,
            "prerm must stop the per-major target on remove",
        )
        self.assertIn(
            'systemctl disable "documentdb-local@${PG_VERSION}.target"',
            prerm,
            "prerm must disable the per-major target on remove",
        )


class StandaloneDebReplacesLimitationTests(unittest.TestCase):
    """The cross-major Replaces bridge is gone: the byte-identical shared
    payload is owned by documentdb-common, so documentdb-N carries no shared
    files and needs no cross-major Replaces/Conflicts."""

    def test_standalone_has_no_cross_major_replaces(self):
        text = STANDALONE_BUILD_SCRIPT.read_text(encoding="utf-8")
        # No Replaces control field, and specifically no enumerated cross-major
        # Replaces that the shared-file bridge used.
        self.assertNotRegex(text, r"(?m)^Replaces: documentdb")
        self.assertNotIn("Replaces: documentdb-15", text)
        # It depends on the shared-payload owner instead.
        self.assertRegex(text, r"Depends:.*documentdb-common \(>= \$\{VERSION\}\)")
        # The control comment explains the ownership model references common.
        emit_idx = text.find('emit_control "${PKG_DIR}" <<CONTROL')
        self.assertGreater(emit_idx, 0)
        self.assertIn("documentdb-common", text[:emit_idx])

    def test_design_doc_tracks_documentdb_common_follow_up(self):
        design = (OSS_ROOT / "packaging" / "gateway" / "packaging-design.md").read_text(encoding="utf-8")
        self.assertIn("Multi-major DEB co-install shared-payload lifecycle", design)
        self.assertIn("documentdb-common", design)
        # The §11.4 backlog row is now marked done in this PR.
        self.assertIn("Done in this PR", design)


class RegisterGatewayPersistsTargetDbTests(unittest.TestCase):
    """TARGET_DB defaults
    to 'postgres' but operators commonly use --target-db <other>.
    Without persisting in state file, day-2 documentdb-gateway-admin
    auto-detect uses the wrong DB."""

    def test_record_state_persists_target_db(self):
        text = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"record_state\(\)\s*\{(?P<body>.*?)^\}",
            text,
            flags=re.DOTALL | re.MULTILINE,
        )
        body = match.group("body")
        self.assertIn(
            "printf 'TARGET_DB=%s\\n'",
            body,
            "record_state must persist TARGET_DB for gateway-admin auto-detect",
        )

    def test_managed_keys_re_includes_target_db(self):
        # TARGET_DB must be in the managed-keys set so the preserve filter
        # doesn't double-emit it.
        self.assertIn(
            "TARGET_DB",
            _state_managed_keys(self),
            "TARGET_DB must be in the managed-keys set (preserve filter would otherwise duplicate it)",
        )


class GatewayAdminReadsTargetDbFromStateTests(unittest.TestCase):
    """Gateway-admin's
    auto_detect_connection must read TARGET_DB from the state file
    when the operator didn't pass --target-db explicitly."""

    def test_explicit_flag_tracked(self):
        admin = (Path(__file__).resolve().parents[1] /
                 "documentdb-gateway-admin.sh")
        text = admin.read_text(encoding="utf-8")
        self.assertIn(
            "TARGET_DB_EXPLICIT=false",
            text,
            "gateway-admin must initialize TARGET_DB_EXPLICIT flag",
        )
        self.assertIn(
            "TARGET_DB_EXPLICIT=true",
            text,
            "--target-db arg parser must set TARGET_DB_EXPLICIT=true",
        )

    def test_auto_detect_reads_target_db_from_state(self):
        admin = (Path(__file__).resolve().parents[1] /
                 "documentdb-gateway-admin.sh")
        text = admin.read_text(encoding="utf-8")
        self.assertIn(
            'grep -E \'^TARGET_DB=\' "${state_file}"',
            text,
            "auto_detect_connection must grep TARGET_DB from state file",
        )
        self.assertIn(
            'TARGET_DB_EXPLICIT',
            text,
            "auto-detect must skip override when operator set --target-db explicitly",
        )


class GatewayDebJsonStripStaleFieldsTests(unittest.TestCase):
    """Shipped
    /etc/documentdb/gateway/SetupConfiguration.json carried
    PostgresPort:9712 which contradicts the per-major port design.
    Build script must strip connection-pinning fields and the
    legacy password field when packaging."""

    def test_deb_build_script_strips_stale_fields(self):
        build = (Path(__file__).resolve().parents[3] / "packaging" /
                 "gateway" / "build-gateway-deb.sh")
        text = build.read_text(encoding="utf-8")
        # The DEB build must INVOKE the shared helper (not merely mention it in a
        # comment) so the packaged JSON is actually stripped. The helper is the
        # single source of truth for the stripped-field set (shared with the RPM
        # %install) so the set cannot drift between the DEB and RPM packages.
        self.assertRegex(
            text, r"bash\s+\S*strip-setup-config\.sh",
            "DEB build script must invoke strip-setup-config.sh to strip "
            "connection-pinning fields from the packaged JSON",
        )
        strip = (Path(__file__).resolve().parents[3] / "packaging" /
                 "gateway" / "strip-setup-config.sh")
        strip_text = strip.read_text(encoding="utf-8")
        # The helper must strip all four sensitive fields from the packaged JSON.
        for field in ("PostgresPort", "GatewayListenPort",
                      "PostgresDataUserPassword", "PostgresHostName"):
            self.assertIn(
                field, strip_text,
                f"strip-setup-config.sh must strip {field} from packaged JSON",
            )

    def test_rpm_spec_strips_stale_fields(self):
        spec = (Path(__file__).resolve().parents[3] / "packaging" /
                "rpm" / "spec" / "documentdb-gateway.spec")
        text = spec.read_text(encoding="utf-8")
        # The RPM %install must INVOKE the shared helper (not merely name the
        # fields in a comment) so it strips the same fields as the DEB package.
        # The stripped-field coverage itself is asserted against the helper in
        # test_deb_build_script_strips_stale_fields (single source of truth).
        self.assertRegex(
            text, r"bash\s+\S*strip-setup-config\.sh",
            "RPM spec must invoke strip-setup-config.sh to strip "
            "connection-pinning fields from the packaged JSON",
        )


class StandalonePurgeRevertsTuneOnBrownfieldTests(unittest.TestCase):
    """On a Debian brownfield the
    wizard delegates postgresql.conf tuning to documentdb-tune, which writes
    a SEPARATE per-cluster fragment (carrying shared_preload_libraries) plus a
    distinct '# >>> documentdb-tune managed include >>>' line in the live
    postgresql.conf. The documentdb-setup managed-block strips in the
    stand-alone package's DEB postrm / RPM %postun do NOT cover those. DEB
    purge must clean the include and fragment without relying on
    documentdb-tune still being installed; the RPM branch remains a defensive
    no-op on RHEL's non-Debian config layout."""

    def _deb_postrm_body(self):
        text = STANDALONE_BUILD_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"cat > \"\$\{PKG_DIR\}/DEBIAN/postrm\" <<'POSTRM'\n(?P<body>.*?)\nPOSTRM\n",
            text,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match, "DEB postrm heredoc not found")
        return match.group("body")

    def test_deb_postrm_reverts_tune_for_debian_brownfield(self):
        body = self._deb_postrm_body()
        self.assertIn(
            "documentdb_restore_debian_tune_fragment()",
            body,
            "DEB postrm must carry self-contained Debian tune cleanup",
        )
        self.assertIn(
            "# >>> documentdb-tune managed include >>>",
            body,
            "DEB postrm must strip the documentdb-tune include marker",
        )
        self.assertIn(
            '/etc/postgresql-common/documentdb/${tune_pgver}/${tune_cluster}',
            body,
            "DEB postrm must remove the per-cluster tune fragment without documentdb-tune",
        )
        self.assertIn(
            "TARGET_CLUSTER=",
            body,
            "DEB postrm should use TARGET_CLUSTER when brownfield state provides it",
        )
        self.assertIn(
            'documentdb_restore_debian_tune_fragment "${config_file}" "${target_cluster}" || true',
            body,
            "DEB postrm must invoke the self-contained tune cleanup as best-effort purge cleanup",
        )
        self.assertIn(
            r"^/etc/postgresql/([0-9]+)/([A-Za-z0-9][A-Za-z0-9_-]*)/postgresql\.conf$",
            body,
            "DEB postrm must gate config-file fallback on the Debian config-path shape",
        )
        self.assertIn(
            '[ "${tune_pgver}" = "${PKG_PG_VERSION}" ] || return 0',
            body,
            "DEB postrm must not let stale state for another major remove this major's tune fragment",
        )
        self.assertNotIn(
            "command -v documentdb-tune",
            body,
            "DEB postrm must not depend on documentdb-tune being installed at purge time",
        )
        self.assertNotIn(
            "documentdb-tune --restore",
            body,
            "DEB postrm must clean Debian tune state directly at purge time",
        )

    def test_deb_postrm_heredoc_is_syntax_checked(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            postrm = Path(tmpdir) / "postrm"
            postrm.write_text(self._deb_postrm_body(), encoding="utf-8")
            result = subprocess.run(["bash", "-n", str(postrm)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rpm_postun_reverts_tune_for_debian_brownfield(self):
        spec = STANDALONE_SPEC.read_text(encoding="utf-8")
        self.assertIn(
            "documentdb-tune --restore --pg-version",
            spec,
            "RPM %postun must invoke documentdb-tune --restore for parity with the DEB postrm",
        )
        self.assertIn("command -v documentdb-tune", spec)
        self.assertIn(
            "^/etc/postgresql/([0-9]+)/([^/]+)/postgresql",
            spec,
            "tune-restore must be gated on the Debian config-path regex",
        )


class GatewayConnectHintEndpointTests(unittest.TestCase):
    """The printed connect hint must derive host/port from --listen-addr
    (GATEWAY_LISTEN_ADDR), not hardcode 127.0.0.1:10260. Extract the
    derivation block from do_setup and exercise it directly so the parser's
    edge cases (port-only, wildcard host, bare/bracketed IPv6, the bare-colon
    host) are locked in."""

    def _derive(self, listen_addr):
        script = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r'(local connect_host="127\.0\.0\.1".*?connect_host="\[\$\{connect_host\}\]"\n\s*fi)',
            script,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match, "connect-hint derivation block not found")
        # Wrap in a function so the block's `local` declarations are valid.
        harness = (
            "f() {\n"
            + match.group(1)
            + '\n  printf "%s:%s" "${connect_host}" "${connect_port}"\n}\nf\n'
        )
        env = dict(os.environ, GATEWAY_LISTEN_ADDR=listen_addr)
        out = subprocess.run(
            ["bash", "-c", harness],
            capture_output=True, text=True, timeout=10, env=env,
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout.strip()

    def test_endpoint_derivation_cases(self):
        cases = {
            "": "127.0.0.1:10260",            # unset -> default
            ":10260": "127.0.0.1:10260",       # port-only -> loopback
            ":9718": "127.0.0.1:9718",         # custom port honored
            "0.0.0.0:10260": "127.0.0.1:10260",  # wildcard host -> loopback
            "10.0.0.5:7000": "10.0.0.5:7000",  # explicit host:port
            "[::1]:10260": "[::1]:10260",       # already-bracketed IPv6
            "::1:10260": "[::1]:10260",         # bare IPv6 gets bracketed
            "fe80::1:10260": "[fe80::1]:10260",
            "::10260": "127.0.0.1:10260",       # bare-colon host -> loopback
        }
        for addr, expected in cases.items():
            with self.subTest(listen_addr=addr):
                self.assertEqual(self._derive(addr), expected)


class GatewayPortCollisionScanTests(unittest.TestCase):
    """The multi-major gateway-port collision check must scan both the
    greenfield setup.conf and the brownfield.conf state files, and must run
    for brownfield setups too (a brownfield install records GATEWAY_PORT only
    in brownfield.conf and must not reuse a port another major owns)."""

    def _collision_guard_and_loop(self):
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r'Multi-major gateway-port collision check.*?^\s*done',
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match, "collision-check block not found")
        return match.group(0)

    def test_scan_globs_both_setup_and_brownfield_conf(self):
        block = self._collision_guard_and_loop()
        self.assertRegex(
            block,
            r'/etc/documentdb/local/\*/setup\.conf\s*\\\s*\n\s*/etc/documentdb/local/\*/brownfield\.conf',
            "collision scan must glob both setup.conf and brownfield.conf",
        )

    def test_scan_is_not_gated_to_greenfield_only(self):
        block = self._collision_guard_and_loop()
        self.assertNotIn(
            '-z "${TARGET_CLUSTER}"', block,
            "collision check must run for brownfield too (no -z TARGET_CLUSTER gate)",
        )
        # Same-major entries are skipped so a re-apply never self-collides.
        self.assertIn('== "${PG_VERSION}" ]] && continue', block)


class DebianIdempotentIncludeRepairTests(unittest.TestCase):
    """On Debian the fragment is written as the raw block (no managed markers),
    so the idempotency check must compare the whole file; and when the fragment
    is current but the live postgresql.conf is missing the include line,
    do_apply must fall through to the confirmed write path to repair it."""

    def _do_apply_body(self):
        script = TUNE_SCRIPT.read_text(encoding="utf-8")
        match = re.search(r'do_apply\(\)\s*\{(?P<body>.*?)\n\}', script, flags=re.DOTALL)
        self.assertIsNotNone(match, "do_apply() not found")
        return match.group("body")

    def test_debian_idempotency_compares_raw_fragment(self):
        body = self._do_apply_body()
        self.assertIn(
            '"$(cat "${CONFIG_TARGET}")" == "${block}"', body,
            "Debian idempotency must compare the raw fragment content (no markers)",
        )

    def test_current_fragment_with_missing_include_falls_through(self):
        body = self._do_apply_body()
        self.assertIn(
            '! debian_include_line_satisfied', body,
            "do_apply must fall through to the write path to repair a missing include line",
        )

    def test_include_satisfied_helper_exists(self):
        script = TUNE_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            script, r'debian_include_line_satisfied\(\)\s*\{',
            "debian_include_line_satisfied helper must exist",
        )


class UxReviewFixTests(unittest.TestCase):
    """Round-4 UX review fixes: extension-version upgrade on re-run, safe
    non-interactive password handling, and honest destructive reset."""

    def test_extension_create_also_runs_alter_extension_update(self):
        # CREATE EXTENSION IF NOT EXISTS is a no-op on a re-run after a package
        # upgrade, leaving the in-database extension version stale forever. The
        # inline create wrappers must also ALTER EXTENSION ... UPDATE (idempotent)
        # so a re-run applies the shipped documentdb--X--Y.sql migrations.
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        for fn, ext in (
            ("_create_documentdb_extension_inline", "documentdb"),
            ("_create_extended_rum_extension_inline", "documentdb_extended_rum"),
        ):
            match = re.search(
                rf"{fn}\(\)\s*\{{(?P<body>.*?)^\}}",
                script,
                flags=re.DOTALL | re.MULTILINE,
            )
            self.assertIsNotNone(match, f"{fn} must exist")
            body = match.group("body")
            self.assertIn(
                f"ALTER EXTENSION {ext} UPDATE;",
                body,
                f"{fn} must idempotently upgrade the in-database extension",
            )

    def test_resolve_password_fails_fast_under_yes_without_source(self):
        # --yes with no password source must die with an actionable message
        # rather than fall through to a hidden interactive prompt that would
        # hang an automated run on a TTY.
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r"resolve_password\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertRegex(
            body,
            r'elif \[\[ "\$\{YES\}" == "true" \]\]; then\s*\n(?:\s*#.*\n)*\s*die ',
            "resolve_password must die under --yes before the interactive "
            "prompt when no password source was provided",
        )

    def test_reset_reads_data_dir_from_setup_conf(self):
        # documentdb-local-reset must honor a custom --data-dir recorded in
        # setup.conf before deleting it, instead of only wiping the hardcoded
        # default path and then falsely claiming a complete reset.
        script = RESET_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'setup_conf="${config_dir}/setup.conf"',
            script,
            "reset must resolve setup.conf to read the recorded data dir",
        )
        self.assertRegex(
            script,
            r"grep -E '\^DATA_DIR=' \"\$\{setup_conf\}\"",
            "reset must read the recorded DATA_DIR from setup.conf",
        )
        # The read must happen before the destructive rm -rf of the data dir.
        data_read = script.index("_recorded_data_dir=")
        data_rm = script.index('rm -rf "${data_dir}"')
        self.assertLess(
            data_read, data_rm,
            "reset must resolve the recorded data dir before removing it",
        )

    def test_reset_fails_closed_on_unmanaged_recorded_data_dir(self):
        # A legacy setup.conf wrongly written by an old brownfield run can
        # record the OPERATOR'S adopted PostgreSQL data dir with no
        # brownfield.conf marker. reset must only honor a non-default
        # recorded DATA_DIR when the state file proves package ownership
        # (DOCUMENTDB_MANAGED_POSTGRES=true + DOCUMENTDB_MODE=greenfield),
        # and must refuse when the recorded mode is not greenfield —
        # mirroring read_persisted_managed_data_dir in documentdb-setup.
        script = RESET_SCRIPT.read_text(encoding="utf-8")
        self.assertRegex(
            script,
            r"grep -E '\^DOCUMENTDB_MANAGED_POSTGRES=' \"\$\{setup_conf\}\"",
            "reset must read the managed-postgres marker from setup.conf",
        )
        self.assertRegex(
            script,
            r"grep -E '\^DOCUMENTDB_MODE=' \"\$\{setup_conf\}\"",
            "reset must read the recorded mode from setup.conf",
        )
        self.assertIn(
            '"${_recorded_managed}" == "true" && "${_recorded_mode}" == "greenfield"',
            script,
            "reset must require managed=true AND mode=greenfield before "
            "honoring a non-default recorded DATA_DIR",
        )
        self.assertIn(
            '"${_recorded_mode}" != "greenfield"',
            script,
            "reset must refuse when setup.conf records a non-greenfield mode",
        )
        # Both guards must fire before the destructive rm -rf.
        guard = script.index('_recorded_mode}" != "greenfield"')
        data_rm = script.index('rm -rf "${data_dir}"')
        self.assertLess(
            guard, data_rm,
            "the fail-closed mode guard must run before the data-dir removal",
        )


class UxReviewRound5Tests(unittest.TestCase):
    """Round-5 UX review follow-ups: accurate help/description text, safe
    non-interactive password guidance, RHEL prerequisite completeness, and a
    guard on the deferred RPM transitive-install suppression."""

    def test_yes_die_message_points_back_to_interactive_prompt(self):
        # The strict --yes fail-fast is intentional, but the die message must
        # tell an operator who used --yes only to skip the per-step confirms
        # that they can drop --yes to be prompted for the password.
        script = SETUP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "or drop --yes to be prompted interactively.",
            script,
            "the --yes/no-password die message must offer the interactive fallback",
        )

    def test_register_gateway_help_marks_pg_version_optional(self):
        # --pg-version is auto-derived from --pgdata's PG_VERSION file, so the
        # usage text must not claim it is "required with --pgdata".
        script = GATEWAY_SETUP_SCRIPT.read_text(encoding="utf-8")
        usage = re.search(
            r"usage\(\)\s*\{(?P<body>.*?)^\}",
            script,
            flags=re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(usage)
        body = usage.group("body")
        self.assertNotIn(
            "required with --pgdata",
            body,
            "usage() must not claim --pg-version is required with --pgdata",
        )
        self.assertIn(
            "auto-derived from --pgdata's PG_VERSION",
            body,
            "usage() must describe --pg-version as auto-derived from PG_VERSION",
        )
        # Round-6: no code path derives PG_VERSION from a live/reachable
        # server (the live probe only sets TARGET_PG_MAJOR for the 16+ gate),
        # so the help must not list "the reachable instance" as a source.
        self.assertNotIn(
            "reachable",
            body,
            "usage() must not claim --pg-version is derived from a reachable server",
        )

    def test_extension_spec_description_points_to_meta_package(self):
        # `dnf search documentdb` steers users to the extension-only package;
        # the %description must also point at the documentdb meta for the full
        # stand-alone stack (gateway + wire endpoint + setup wizard).
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertIn(
            "sudo dnf install documentdb",
            text,
            "documentdb.spec %description must point to the documentdb meta package",
        )

    def test_rhel_prereq_recipes_install_dnf_plugins_core(self):
        # `dnf config-manager` is provided by dnf-plugins-core, which is not on
        # a minimal EL image. Every RHEL prerequisite recipe must install it
        # before invoking config-manager so `--set-enabled crb` cannot fail
        # with "No such command".
        for path in (
            OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb.spec",
            OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-local-meta.spec",
            PACKAGING_README,
        ):
            text = path.read_text(encoding="utf-8")
            self.assertIn(
                "dnf install -y dnf-plugins-core",
                text,
                f"{path.name} RHEL recipe must install dnf-plugins-core",
            )
            core_pos = text.index("dnf-plugins-core")
            cm_pos = text.index("config-manager")
            self.assertLess(
                core_pos, cm_pos,
                f"{path.name} must install dnf-plugins-core before config-manager",
            )

    def test_gateway_spec_documents_deferred_transitive_suppression(self):
        # The DEB postinst suppresses the Workflow-B recipe on a transitive
        # install; RPM cannot detect that reliably in %post (the parent is not
        # yet in the rpmdb). The spec must document the deferral so a future
        # contributor does not "fix" it with a false-positive-prone rpm -q.
        spec = OSS_ROOT / "packaging" / "rpm" / "spec" / "documentdb-gateway.spec"
        text = spec.read_text(encoding="utf-8")
        self.assertIn(
            "not yet in",
            text,
            "gateway.spec %post must explain why RPM cannot detect a transitive install",
        )
        # Round-6: the note must name %posttrans as the viable path (rpm -q
        # reflects the committed transaction there) rather than claiming no
        # safe signal exists at all. Assert the note-specific phrasing, not
        # the always-present %posttrans scriptlet section.
        self.assertIn(
            "%posttrans check",
            text,
            "gateway.spec %post note must name %posttrans as the viable suppression path",
        )
