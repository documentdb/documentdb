#!/bin/bash
set -euo pipefail

readonly USERNAME="cloudsa"
readonly PASSWORD="$(head -c 16 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)Bb2"
# Per packaging-design.md §4.4 the standalone defaults are derived from
# the PG major. Resolve once so this test cell is OS/PG-agnostic.
readonly POSTGRES_VERSION="${POSTGRES_VERSION:-17}"
readonly PG_MAJOR="${POSTGRES_VERSION}"
readonly PG_PORT="$(( 9700 + PG_MAJOR ))"
readonly GATEWAY_PORT="10260"
readonly PG_SOCKET_DIR="/run/documentdb-local/${PG_MAJOR}/postgresql"
readonly STANDALONE_DATA_DIR="/var/lib/documentdb-local/${PG_MAJOR}/data"
# Resolved from the RPM header in verify_package_install (postgresql<N>-documentdb)
# and consumed by the uninstall check so the extension's %postun is exercised.
EXTENSION_PACKAGE_NAME=""
readonly SETUP_LOG="/tmp/documentdb-setup.log"
TEMP_FILES=()

log() {
    echo "[gateway-rpm-e2e] $*"
}

fail() {
    echo "[gateway-rpm-e2e] ERROR: $*" >&2
    exit 1
}

# --- Skipped-test tracking -------------------------------------------------
# A guard test that silently skips (e.g. because a runtime capability is
# missing) is how a real regression slipped through before: the suite reported
# PASS while never executing the assertion. Record every skip and surface it in
# a loud end-of-run summary so a green run cannot hide un-run guard tests.
SKIPPED_TESTS=()

record_skip() {
    local test_name="$1"
    local reason="$2"
    SKIPPED_TESTS+=("${test_name}: ${reason}")
    log "SKIP [${test_name}]: ${reason}"
}

# Skip a capability-gated guard test, UNLESS the orchestrator confirmed the
# required capability is in effect (GUARD_TESTS_REQUIRED=1, set by
# build_gateway_packages.sh once it has added --cap-add=SYS_PTRACE). When the
# capability is present the test must run, so an inability to run it is a real
# failure rather than an environment limitation -- failing here closes the
# silent-skip blind spot that previously masked a bug.
skip_or_fail_guard() {
    local test_name="$1"
    local reason="$2"
    if [[ "${GUARD_TESTS_REQUIRED:-}" == "1" ]]; then
        fail "${test_name} could not run even though the orchestrator granted the required capability (${reason}). A silent skip here would mask a regression; treating it as a failure."
    fi
    record_skip "${test_name}" "${reason}"
}

report_skips() {
    if (( ${#SKIPPED_TESTS[@]} == 0 )); then
        return 0
    fi
    log "================================================================"
    log "WARNING: ${#SKIPPED_TESTS[@]} test(s) were SKIPPED and NOT verified:"
    local entry
    for entry in "${SKIPPED_TESTS[@]}"; do
        log "  - ${entry}"
    done
    log "A PASS with skips does NOT mean these behaviors were verified. The"
    log "orchestrator (build_gateway_packages.sh) grants SYS_PTRACE when the"
    log "Docker daemon allows it so capability-gated guard tests can run."
    log "================================================================"
}

cleanup() {
    if (( ${#TEMP_FILES[@]} > 0 )); then
        rm -rf "${TEMP_FILES[@]}" 2>/dev/null || true
        TEMP_FILES=()
    fi
}
trap cleanup EXIT

assert_eq() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    if [[ "${actual}" != "${expected}" ]]; then
        fail "${message}: expected '${expected}', got '${actual}'"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    if [[ "${haystack}" != *"${needle}"* ]]; then
        fail "${message}: missing '${needle}' in '${haystack}'"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        fail "${message}: unexpectedly found '${needle}' in '${haystack}'"
    fi
}

assert_file() {
    local path="$1"
    if [[ ! -e "${path}" ]]; then
        fail "Expected file ${path} to exist"
    fi
}

assert_not_exists() {
    local path="$1"
    if [[ -e "${path}" ]]; then
        fail "Expected ${path} to be absent"
    fi
}

assert_executable() {
    local path="$1"
    if [[ ! -x "${path}" ]]; then
        fail "Expected executable ${path} to exist"
    fi
}

assert_file_contains_regex() {
    local path="$1"
    local regex="$2"
    local message="$3"
    if [[ -r "${path}" ]]; then
        grep -Eq "${regex}" "${path}" || fail "${message}: ${path} did not match ${regex}"
        return 0
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo grep -Eq "${regex}" "${path}" || fail "${message}: ${path} did not match ${regex}"
        return 0
    fi

    # Unreadable and no sudo: fail loudly rather than letting an unreadable
    # file read as a result. Mirrors the DEB entrypoint's helper — keep the
    # two in sync.
    fail "${message}: cannot read ${path} (not readable by $(id -un) and sudo is unavailable), so this assertion could not be evaluated"
}

assert_file_not_contains_regex() {
    local path="$1"
    local regex="$2"
    local message="$3"
    if [[ -r "${path}" ]]; then
        grep -Eq "${regex}" "${path}" && fail "${message}: ${path} unexpectedly matched ${regex}"
        return 0
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo grep -Eq "${regex}" "${path}" && fail "${message}: ${path} unexpectedly matched ${regex}"
        return 0
    fi

    # Unreadable and no sudo: a negative assertion that silently passes
    # because the file could not be opened is worse than no assertion, since
    # it reads as coverage. Mirrors the DEB entrypoint's helper — keep the
    # two in sync.
    fail "${message}: cannot read ${path} (not readable by $(id -un) and sudo is unavailable), so this assertion could not be evaluated"
}

register_temp_file() {
    TEMP_FILES+=("$1")
}

create_temp_dir() {
    local target_var="$1"
    local template="${2:-/tmp/documentdb-tempdir.XXXXXX}"
    local created_dir=""

    created_dir="$(mktemp -d "${template}")"
    chmod 700 "${created_dir}"
    register_temp_file "${created_dir}"
    printf -v "${target_var}" '%s' "${created_dir}"
}

create_temp_file() {
    local target_var="$1"
    local template="${2:-}"
    local created_file=""

    if [[ -n "${template}" ]]; then
        created_file="$(mktemp "${template}")"
    else
        created_file="$(mktemp)"
    fi

    chmod 600 "${created_file}"
    register_temp_file "${created_file}"
    printf -v "${target_var}" '%s' "${created_file}"
}

extract_rpm_scriptlet() {
    local target_var="$1"
    local scriptlet_name="$2"
    local package_path="$3"
    local scriptlet_file=""

    create_temp_file scriptlet_file "/tmp/documentdb-rpm-scriptlet.XXXXXX"
    rpm -qp --scripts "${package_path}" | awk -v section="${scriptlet_name}" '
        $0 == section " scriptlet (using /bin/sh):" { capture = 1; next }
        capture && /^[[:alpha:]][[:alpha:]-]* scriptlet \(using .*\):$/ { exit }
        capture { print }
    ' > "${scriptlet_file}"

    [[ -s "${scriptlet_file}" ]] || fail "Failed to extract ${scriptlet_name} from ${package_path}"
    printf -v "${target_var}" '%s' "${scriptlet_file}"
}

run_scriptlet_with_fake_systemctl() {
    local scriptlet_file="$1"
    local scriptlet_arg="$2"
    local systemctl_log="$3"
    local active_services="${4:-}"
    local fakebin_dir=""

    create_temp_dir fakebin_dir "/tmp/documentdb-fakebin.XXXXXX"
    cat > "${fakebin_dir}/systemctl" <<'EOF'
#!/bin/bash
if [[ "$1" == "is-active" && "${2:-}" == "--quiet" ]]; then
    service="${3:-}"
    if [[ " ${FAKE_ACTIVE_SERVICES:-} " == *" ${service} "* ]]; then
        exit 0
    fi
    exit 3
fi
# `list-units '<glob>' --state=active --plain --no-legend` is how the %preun
# stop-loop and %posttrans restart-loop enumerate active stand-alone
# gateway-local@N.service instances. Echo the FAKE_ACTIVE_SERVICES entries
# that match the requested glob in `--plain --no-legend` shape (the scriptlets
# read the first field via awk), so those loops are actually exercised instead
# of silently iterating over an empty list.
if [[ "$1" == "list-units" ]]; then
    printf '%s\n' "$*" >> "${FAKE_SYSTEMCTL_LOG}"
    pattern="${2:-}"
    for service in ${FAKE_ACTIVE_SERVICES:-}; do
        # shellcheck disable=SC2254  # glob match against the caller's pattern is intentional
        case "${service}" in
            ${pattern}) printf '%s loaded active running %s\n' "${service}" "${service}" ;;
        esac
    done
    exit 0
fi
printf '%s\n' "$*" >> "${FAKE_SYSTEMCTL_LOG}"
exit 0
EOF
    chmod 755 "${fakebin_dir}/systemctl"

    : > "${systemctl_log}"
    # See the DEB harness: the RPM scriptlets gate systemctl on
    # `[ -d /run/systemd/system ]`, which the container lacks. Create it for
    # this invocation only so the gated paths run against the fake systemctl.
    local _made_run_systemd=false
    if [[ ! -d /run/systemd/system ]]; then
        install -d -m 0755 /run/systemd/system 2>/dev/null && _made_run_systemd=true || true
    fi

    local _rc=0
    env FAKE_ACTIVE_SERVICES="${active_services}" FAKE_SYSTEMCTL_LOG="${systemctl_log}" PATH="${fakebin_dir}:${PATH}" \
        bash "${scriptlet_file}" "${scriptlet_arg}" || _rc=$?

    if [[ "${_made_run_systemd}" == "true" ]]; then
        rmdir /run/systemd/system 2>/dev/null || true
    fi
    return "${_rc}"
}

run_psql() {
    local sql="$1"
    # Per packaging-design.md §4.4: greenfield PG superuser is
    # 'documentdb-local' (initdb --username=documentdb-local). Pre-redesign
    # this was 'documentdb' on both sides.
    run_psql_as_documentdb_os documentdb-local "${sql}"
}

run_psql_as_documentdb_os() {
    local db_user="$1"
    local sql="$2"
    local -a psql_args=(
        -h "${PG_SOCKET_DIR}"
        -p "${PG_PORT}"
        -U "${db_user}"
        -d postgres
        -X
        -Atqc "${sql}"
    )

    # Prefer sudo over runuser, matching the DEB entrypoint: runuser needs
    # CAP_SETUID and refuses outright for non-root invokers (rootless
    # containers, Docker Desktop), while a no-password sudo rule works for
    # both root and unprivileged callers. This suite currently runs as root
    # (so either order works today), but keep the two entrypoints identical
    # so the ordering bug already diagnosed on the DEB side cannot come
    # back here if the RPM image ever drops root.
    if [[ "$(id -un)" == "documentdb-local" ]]; then
        psql "${psql_args[@]}"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -u documentdb-local psql "${psql_args[@]}"
    elif command -v runuser >/dev/null 2>&1; then
        runuser -u documentdb-local -- psql "${psql_args[@]}"
    else
        fail "Unable to run psql as the documentdb-local OS user."
    fi
}

resolve_pg_config() {
    local candidate="/usr/pgsql-${POSTGRES_VERSION}/bin/pg_config"

    if [[ -x "${candidate}" ]]; then
        printf '%s' "${candidate}"
        return 0
    fi

    if command -v pg_config >/dev/null 2>&1; then
        command -v pg_config
        return 0
    fi

    fail "pg_config was not found for PostgreSQL ${POSTGRES_VERSION}"
}

password_visible_in_process_args() {
    local root_pid="$1"
    local current_pid=""
    local child_pid=""
    local child_ppid=""
    local cmdline=""
    local seen_pids=" ${root_pid} "
    local -a scan_queue=("${root_pid}")

    while (( ${#scan_queue[@]} > 0 )); do
        current_pid="${scan_queue[0]}"
        scan_queue=("${scan_queue[@]:1}")

        if [[ -r "/proc/${current_pid}/cmdline" ]]; then
            cmdline="$(tr '\0' ' ' < "/proc/${current_pid}/cmdline" 2>/dev/null || true)"
        else
            cmdline="$(ps -p "${current_pid}" -o args= 2>/dev/null || true)"
        fi

        if [[ -n "${cmdline}" && "${cmdline}" == *"${PASSWORD}"* ]]; then
            return 0
        fi

        # Walk the full setup process tree so child-process argv leaks are caught too.
        while read -r child_pid child_ppid; do
            [[ -n "${child_pid}" ]] || continue
            if [[ "${child_ppid}" != "${current_pid}" ]]; then
                continue
            fi
            if [[ "${seen_pids}" == *" ${child_pid} "* ]]; then
                continue
            fi
            seen_pids+=" ${child_pid} "
            scan_queue+=("${child_pid}")
        done < <(ps -eo pid=,ppid=)
    done

    return 1
}

create_mongosh_wrapper_script() {
    local _target_var="$1"
    local _wrapper_path=""

    create_temp_file _wrapper_path "/tmp/documentdb-mongosh.XXXXXX.js"
    cat > "${_wrapper_path}" <<'EOF'
const host = process.env.DOCUMENTDB_HOST || 'localhost';
const port = process.env.DOCUMENTDB_PORT;
const username = process.env.DOCUMENTDB_USERNAME;
const password = process.env.DOCUMENTDB_PASSWORD;
const initFile = process.env.DOCUMENTDB_INIT_FILE || '';
const uri = `mongodb://${encodeURIComponent(username)}:${encodeURIComponent(password)}@${host}:${port}/admin?authSource=admin&authMechanism=SCRAM-SHA-256&tls=true&tlsAllowInvalidCertificates=true`;

db = connect(uri);

if (initFile) {
    load(initFile);
}
EOF

    printf -v "${_target_var}" '%s' "${_wrapper_path}"
}

run_mongosh_script() {
    local script_content="$1"
    local output_file="$2"
    local init_file=""
    local wrapper_file=""

    create_temp_file init_file "/tmp/documentdb-mongosh-init.XXXXXX.js"
    printf '%s\n' "${script_content}" > "${init_file}"
    create_mongosh_wrapper_script wrapper_file

    env \
        DOCUMENTDB_HOST="localhost" \
        DOCUMENTDB_PORT="${GATEWAY_PORT}" \
        DOCUMENTDB_USERNAME="${USERNAME}" \
        DOCUMENTDB_PASSWORD="${PASSWORD}" \
        DOCUMENTDB_INIT_FILE="${init_file}" \
        mongosh --quiet --nodb "${wrapper_file}" > "${output_file}" 2>&1
}

verify_package_install() {
    local gateway_requires=""
    local setup_help=""

    log "Installing extension and gateway RPM packages."
    # Global, not local: the uninstall check at the end of the suite needs the
    # real extension package name (postgresql<N>-documentdb) to remove it and
    # exercise its %postun.
    EXTENSION_PACKAGE_NAME="$(rpm -qp --queryformat "%{NAME}\n" /tmp/documentdb.rpm)"
    dnf install -y /tmp/documentdb.rpm /tmp/documentdb-gateway.rpm

    rpm -q "${EXTENSION_PACKAGE_NAME}" >/dev/null 2>&1 || fail "Extension RPM was not installed successfully"
    rpm -q documentdb-gateway >/dev/null 2>&1 || fail "Gateway RPM was not installed successfully"

    # The RHEL gateway-test container co-installs all four Track 1 RPMs (extension +
    # gateway + tools + per-major stand-alone) so phases 4+ can drive
    # documentdb-setup. After the four-package split (per packaging-design.md
    # §3, §4), documentdb-setup, the documentdb-postgresql service template,
    # sample-data, and init scripts live in documentdb-N (the stand-alone
    # RPM). This phase validates only the gateway runtime surface; the
    # standalone validation belongs in a dedicated documentdb-N test.
    assert_executable /usr/bin/documentdb-gateway
    assert_file /etc/documentdb/gateway/SetupConfiguration.json
    assert_file /usr/lib/systemd/system/documentdb-gateway.service
    assert_file /usr/lib/sysusers.d/documentdb-gateway.conf
    assert_file /usr/lib/tmpfiles.d/documentdb-gateway.conf
    assert_file /usr/share/doc/documentdb-gateway/examples/gateway.env.sample
    assert_file /usr/share/licenses/documentdb-gateway/LICENSE_Apache-2.0
    assert_file /usr/share/licenses/documentdb-gateway/LICENSE_MIT

    # The gateway PACKAGE must not SHIP the documentdb-N standalone surface
    # (documentdb-setup, the documentdb-postgresql service template) or the
    # documentdb-postgresql-tools admin helpers (per packaging-design.md §4.3:
    # the gateway is runtime-only). Because this container co-installs all four
    # RPMs, those files ARE present on disk -- a live-filesystem check would
    # wrongly fail. Inspect the gateway package's own installed manifest
    # instead (the RPM analog of the DEB test's `dpkg -L documentdb-gateway`),
    # so a regression that bundles these files INTO the gateway package is
    # caught regardless of what else the container installs.
    local gw_manifest=""
    gw_manifest="$(rpm -ql documentdb-gateway 2>/dev/null)" \
        || fail "Could not read documentdb-gateway RPM manifest"
    if printf '%s\n' "${gw_manifest}" | grep -qE '(^|/)documentdb-setup$'; then
        fail "documentdb-gateway manifest must NOT contain documentdb-setup (lives in documentdb-common)"
    fi
    if printf '%s\n' "${gw_manifest}" | grep -qE 'documentdb-postgresql(@\.service|\.service)$'; then
        fail "documentdb-gateway manifest must NOT contain a PostgreSQL service template (lives in documentdb-common)"
    fi
    if printf '%s\n' "${gw_manifest}" | grep -qE '(documentdb-tune|documentdb-register-gateway|documentdb-createcluster|documentdb-gateway-admin)$'; then
        fail "documentdb-gateway manifest must NOT contain PostgreSQL admin helpers (live in documentdb-postgresql-tools)"
    fi

    id documentdb-gateway >/dev/null 2>&1 || fail "documentdb-gateway runtime user was not created"

    # jq must NOT be a gateway runtime dependency (the gateway binary doesn't
    # use it — only documentdb-gateway-admin
    # in the tools package does). Per packaging-design.md §4.3 the gateway
    # is runtime-only with minimal deps. Guard against regression.
    gateway_requires="$(rpm -qpR /tmp/documentdb-gateway.rpm)"
    if printf "%s\n" "${gateway_requires}" | grep -Eq '^jq($| )'; then
        fail "Gateway RPM must not declare jq as a Requires — jq belongs to documentdb-postgresql-tools"
    fi
    assert_contains "${gateway_requires}" "openssl" "Gateway RPM metadata is missing the openssl dependency"
    if printf "%s\n" "${gateway_requires}" | grep -Eq "postgresql(15|16|17|18)-documentdb"; then
        fail "Gateway RPM metadata should not auto-select a DocumentDB extension package"
    fi
}

verify_preun_scriptlet_behaviour() {
    local preun_scriptlet=""
    local systemctl_log=""
    local systemctl_calls=""
    # An active stand-alone per-major gateway instance, used to exercise the
    # %preun stop-loop over documentdb-gateway-local@N.service units.
    local active_local_unit="documentdb-gateway-local@${PG_MAJOR}.service"

    log "Verifying RPM %preun preserves services on upgrade and tears them down only on removal."
    extract_rpm_scriptlet preun_scriptlet "preuninstall" /tmp/documentdb-gateway.rpm
    create_temp_file systemctl_log "/tmp/documentdb-rpm-preun.XXXXXX.log"

    # Upgrade ($1 >= 1): the %systemd_preun macro is a no-op and the custom
    # stop-loop is gated on $1 == 0, so nothing is stopped or disabled — the
    # running gateway is preserved across the upgrade.
    run_scriptlet_with_fake_systemctl "${preun_scriptlet}" 1 "${systemctl_log}" "${active_local_unit}"
    systemctl_calls="$(< "${systemctl_log}")"
    assert_not_contains "${systemctl_calls}" "disable --now" "Upgrade %preun must not stop/disable the gateway (services preserved across upgrade)"
    assert_not_contains "${systemctl_calls}" "stop documentdb-gateway" "Upgrade %preun must not stop the gateway"
    assert_not_contains "${systemctl_calls}" "documentdb-postgresql" "Upgrade %preun must not touch PostgreSQL (gateway is runtime-only)"

    # Removal ($1 == 0): the %systemd_preun macro tears down the main
    # documentdb-gateway.service. On EL9 it delegates to
    # systemd-update-helper, which runs `systemctl ... disable --now <unit>`
    # (--now stops the unit, disable clears its enablement); the custom loop
    # then stops any active stand-alone gateway-local@N.service instances.
    run_scriptlet_with_fake_systemctl "${preun_scriptlet}" 0 "${systemctl_log}" "${active_local_unit}"
    systemctl_calls="$(< "${systemctl_log}")"
    assert_contains "${systemctl_calls}" "disable --now" "Removal %preun did not stop+disable the gateway via %systemd_preun (disable --now)"
    assert_contains "${systemctl_calls}" "documentdb-gateway.service" "Removal %preun did not act on documentdb-gateway.service"
    assert_contains "${systemctl_calls}" "stop ${active_local_unit}" "Removal %preun did not stop the active stand-alone gateway-local instance"
    # The gateway package is runtime-only per packaging-design.md §4.3 — it
    # MUST NOT touch the PostgreSQL
    # service. PG service lifecycle belongs to documentdb-N's maintainer
    # scripts. Guard against regression.
    assert_not_contains "${systemctl_calls}" "documentdb-postgresql" "Removal %preun must NOT touch PostgreSQL (gateway is runtime-only)"
}

verify_posttrans_scriptlet_behaviour() {
    local posttrans_scriptlet=""
    local systemctl_log=""
    local systemctl_calls=""
    # An active stand-alone per-major gateway instance, used to exercise the
    # %posttrans restart-loop. The main documentdb-gateway.service is
    # restarted by %systemd_postun_with_restart in %postun (not here); this
    # scriptlet only refreshes the active gateway-local@N.service instances.
    local active_local_unit="documentdb-gateway-local@${PG_MAJOR}.service"

    log "Verifying RPM %posttrans reloads systemd and restarts only active stand-alone gateway instances."
    extract_rpm_scriptlet posttrans_scriptlet "posttrans" /tmp/documentdb-gateway.rpm
    create_temp_file systemctl_log "/tmp/documentdb-rpm-posttrans.XXXXXX.log"

    run_scriptlet_with_fake_systemctl "${posttrans_scriptlet}" 1 "${systemctl_log}" \
        "${active_local_unit}"
    systemctl_calls="$(< "${systemctl_log}")"
    assert_contains "${systemctl_calls}" "daemon-reload" "Posttrans did not reload systemd"
    assert_contains "${systemctl_calls}" "restart ${active_local_unit}" "Posttrans did not restart the active stand-alone gateway instance"
    # %posttrans must not restart PG — only the active
    # documentdb-gateway-local@N.service instances (the main
    # documentdb-gateway.service is handled by %postun, not here).
    assert_not_contains "${systemctl_calls}" "restart documentdb-postgresql" "Posttrans must NOT restart PostgreSQL (gateway is runtime-only)"

    run_scriptlet_with_fake_systemctl "${posttrans_scriptlet}" 1 "${systemctl_log}" ""
    systemctl_calls="$(< "${systemctl_log}")"
    assert_contains "${systemctl_calls}" "daemon-reload" "Posttrans did not reload systemd"
    assert_not_contains "${systemctl_calls}" "restart documentdb-gateway" "Posttrans should not restart any gateway instance when none is active"
    assert_not_contains "${systemctl_calls}" "restart documentdb-postgresql" "Posttrans must NOT restart PostgreSQL even when nothing else is active"
}

run_documentdb_setup() {
    local setup_pid=""
    local password_file=""
    local -a setup_args=("$@")

    create_temp_file password_file "/tmp/documentdb-password.XXXXXX"
    printf '%s' "${PASSWORD}" > "${password_file}"

    log "Running packaged documentdb-setup."

    documentdb-setup --username "${USERNAME}" --password-file "${password_file}" --yes --verbose "${setup_args[@]}" > "${SETUP_LOG}" 2>&1 &
    setup_pid=$!
    while kill -0 "${setup_pid}" 2>/dev/null; do
        if password_visible_in_process_args "${setup_pid}"; then
            cat "${SETUP_LOG}"
            fail "documentdb-setup exposed the password in process arguments"
        fi
        sleep 0.1
    done

    if ! wait "${setup_pid}"; then
        cat "${SETUP_LOG}"
        fail "documentdb-setup failed"
    fi
    cat "${SETUP_LOG}"

    grep -Fq "[documentdb-setup] SUCCESS: DocumentDB is ready." "${SETUP_LOG}" \
        || fail "documentdb-setup did not report readiness"

    local expected_connstr="mongosh 'mongodb://${USERNAME}:<your-password>@localhost:${GATEWAY_PORT}/mydb?tls=true&tlsAllowInvalidCertificates=true'"
    grep -Fq "${expected_connstr}" "${SETUP_LOG}" \
        || fail "documentdb-setup did not print the expected connection string"

    grep -Fq "Replace <your-password> with the password you provided." "${SETUP_LOG}" \
        || fail "documentdb-setup did not print the password redaction guidance"

    if grep -Fq "mongodb://${USERNAME}:${PASSWORD}@localhost:${GATEWAY_PORT}" "${SETUP_LOG}"; then
        fail "documentdb-setup leaked the plaintext password in its connection output"
    fi
}

verify_gateway_configuration() {
    log "Verifying packaged gateway configuration after the per-major (Workflow C) install."

    # After the Track-1 redesign the per-major documentdb-gateway-local@N.service
    # reads ONLY the per-major gateway.env (its systemd EnvironmentFile), never
    # the shared SetupConfiguration.json. documentdb-setup therefore records the
    # connection config in the per-major gateway.env + connection-secret file and
    # strips the now-stale per-major fields from the singleton JSON so a later
    # major's wizard run cannot clobber an earlier major's gateway (see
    # update_gateway_configuration() and packaging-design.md §4.3 / §4.4). The
    # OS-user identity formerly checked here (documentdb-local) is exercised by
    # the peer-auth / data-dir ownership tests instead.
    local config_json="/etc/documentdb/gateway/SetupConfiguration.json"
    local gateway_env="/etc/documentdb/local/${PG_MAJOR}/gateway.env"
    local pg_url_file="/var/lib/documentdb-local/${PG_MAJOR}/gateway/pg-url"

    # 1. The singleton JSON must have its per-major connection fields stripped.
    local stripped_field
    for stripped_field in PostgresPort GatewayListenPort PostgresHostName \
            PostgresSystemUser PostgresDataUser; do
        assert_eq "$(jq -r ".${stripped_field}" "${config_json}")" "null" \
            "SetupConfiguration.json must not carry per-major ${stripped_field} on a Workflow C install (the per-major gateway.env is authoritative)"
    done

    # 2. The per-major gateway.env carries the gateway listen port and points at
    #    the connection-secret file.
    assert_file "${gateway_env}"
    assert_file_contains_regex "${gateway_env}" "^DOCUMENTDB_LISTEN_ADDR=:${GATEWAY_PORT}$" \
        "Per-major gateway.env must record the gateway listen port ${GATEWAY_PORT}"
    assert_file_contains_regex "${gateway_env}" "^DOCUMENTDB_PG_URL_FILE=${pg_url_file}$" \
        "Per-major gateway.env must point at the connection-secret file"

    # 3. The connection-secret file carries the PostgreSQL socket dir + port. It
    #    is mode 0640 root:documentdb-gateway, so assert_file_contains_regex
    #    transparently falls back to sudo to read it.
    assert_file_contains_regex "${pg_url_file}" "host=${PG_SOCKET_DIR}&port=${PG_PORT}([^0-9]|$)" \
        "Connection-secret must carry the PostgreSQL socket dir and port (host=...&port=${PG_PORT})"
}

# The auto-generated TLS private key must NEVER be world- or group-readable.
# Regression test for the previously open-by-default key permissions: under
# systemd's default UMask=0022, openssl genpkey would otherwise leave the
# key file at mode 0644 inside a 0755 working directory, allowing any local
# user to read the gateway's TLS private key off disk and impersonate it.
# The defense is twofold:
#   1. docdb_openssl::generate_auth_keys explicitly chmods 0600 after generation
#   2. documentdb-gateway.service sets UMask=0077 so the initial creation is
#      already restricted before the chmod runs
# Both must hold; this test catches a regression of either.
verify_tls_key_permissions() {
    # Per packaging-design.md §4.3 + tls.rs::DEFAULT_TLS_STATE_DIR:
    # without systemd in the test container the gateway is launched via
    # the wizard's nohup-as-documentdb-gateway fallback and uses the
    # default state dir /var/lib/documentdb-gateway/tls/. With systemd,
    # the per-major unit pins it to
    # /var/lib/documentdb-local/${PG_MAJOR}/gateway/tls/. Probe both so
    # the test keeps working across either invocation mode.
    local pkey_path=""
    local cert_path=""
    for candidate_dir in \
            "/var/lib/documentdb-gateway/tls" \
            "/var/lib/documentdb-local/${PG_MAJOR}/gateway/tls"; do
        if sudo test -f "${candidate_dir}/pkey.pem"; then
            pkey_path="${candidate_dir}/pkey.pem"
            cert_path="${candidate_dir}/cert.pem"
            break
        fi
    done

    log "Verifying gateway TLS private key has restrictive permissions."
    if [[ -z "${pkey_path}" ]]; then
        fail "Gateway TLS private key not found under /var/lib/documentdb-gateway/tls/ or /var/lib/documentdb-local/${PG_MAJOR}/gateway/tls/; gateway may have failed to start"
    fi
    log "Found gateway TLS material under $(dirname "${pkey_path}")."

    local pkey_mode=""
    pkey_mode="$(sudo stat -c '%a' "${pkey_path}")"
    assert_eq "${pkey_mode}" "600" "Gateway TLS private key ${pkey_path} must be mode 0600 (got ${pkey_mode})"

    # Per packaging-design.md §4.3 the gateway OS user was renamed from
    # 'documentdb' to 'documentdb-gateway' as part of the Track 1 split.
    local pkey_owner=""
    pkey_owner="$(sudo stat -c '%U:%G' "${pkey_path}")"
    assert_eq "${pkey_owner}" "documentdb-gateway:documentdb-gateway" \
        "Gateway TLS private key ${pkey_path} must be owned by documentdb-gateway:documentdb-gateway (got ${pkey_owner})"

    # The cert is intentionally world-readable (it's the public key).
    if sudo test -f "${cert_path}"; then
        log "Gateway TLS certificate present at ${cert_path} (mode irrelevant)."
    fi
}

verify_self_managed_postgres_persistence() {
    log "Verifying self-managed PostgreSQL startup state was persisted for packaged installs."
    assert_file /etc/documentdb/documentdb-postgresql.env
    assert_file "/etc/documentdb/local/${PG_MAJOR}/setup.conf"
    assert_file_contains_regex /etc/documentdb/documentdb-postgresql.env '^DOCUMENTDB_MANAGED_POSTGRES=true$' "Managed PostgreSQL flag missing"
    assert_file_contains_regex /etc/documentdb/documentdb-postgresql.env '^PG_VERSION=' "Managed PostgreSQL version missing"
    assert_file_contains_regex /etc/documentdb/documentdb-postgresql.env '^DATA_DIR=' "Managed PostgreSQL data dir missing"
    # The per-major setup.conf is the brownfield/greenfield discriminator the
    # documentdb-postgresql@.service unit gates on (ConditionPathExists). Assert
    # the initial happy-path setup writes it with the full key set so a
    # regression that stops writing it is caught HERE, not silently re-created
    # by the re-adoption test that follows.
    assert_file_contains_regex "/etc/documentdb/local/${PG_MAJOR}/setup.conf" '^DOCUMENTDB_MANAGED_POSTGRES=true$' "Per-major managed PostgreSQL flag missing"
    assert_file_contains_regex "/etc/documentdb/local/${PG_MAJOR}/setup.conf" '^PG_VERSION=' "Per-major PostgreSQL version missing"
    assert_file_contains_regex "/etc/documentdb/local/${PG_MAJOR}/setup.conf" '^DATA_DIR=' "Per-major data dir missing"
    assert_file_contains_regex "/etc/documentdb/local/${PG_MAJOR}/setup.conf" '^CONFIG_FILE=' "Per-major config file path missing"
    assert_file_contains_regex "/etc/documentdb/local/${PG_MAJOR}/setup.conf" '^HBA_FILE=' "Per-major hba file path missing"
    assert_file_contains_regex "/etc/documentdb/local/${PG_MAJOR}/setup.conf" '^IDENT_FILE=' "Per-major ident file path missing"
    # The resolved CONFIG_FILE/HBA_FILE/IDENT_FILE paths are persisted so the
    # %postun cleanup can strip managed blocks from non-default config paths
    # under DATA_DIR (adopted clusters may have their config files outside
    # DATA_DIR/<default-name>).
    assert_file_contains_regex /etc/documentdb/documentdb-postgresql.env '^CONFIG_FILE=' "Managed PostgreSQL config file path missing"
    assert_file_contains_regex /etc/documentdb/documentdb-postgresql.env '^HBA_FILE=' "Managed PostgreSQL hba file path missing"
    assert_file_contains_regex /etc/documentdb/documentdb-postgresql.env '^IDENT_FILE=' "Managed PostgreSQL ident file path missing"

    # The packaged unit sets no PIDFile= (it tracks the postmaster via cgroup),
    # so ensure_postgres_systemd_drop_in never writes a drop-in. None should
    # exist here; a left-over drop-in would indicate the cleanup is not stripping
    # a stale datadir.conf from a previous custom-data-dir run.
    # Check both the templated (post-Track-1) and legacy (pre-Track-1) paths.
    if [[ -e "/etc/systemd/system/documentdb-postgresql@${PG_MAJOR}.service.d/datadir.conf" ]]; then
        fail "Unexpected per-major systemd PIDFile drop-in present after default-DATA_DIR setup"
    fi
    if [[ -e /etc/systemd/system/documentdb-postgresql.service.d/datadir.conf ]]; then
        fail "Unexpected (legacy non-templated) systemd PIDFile drop-in present after default-DATA_DIR setup"
    fi
}

verify_live_cluster_readoption() {
    local state_backup=""
    local per_major_state_backup=""
    local readopt_log=""
    local password_file=""
    local pg_url_file="/var/lib/documentdb-local/${PG_MAJOR}/gateway/pg-url"
    local pg_url_backup=""
    local gateway_env_file="/etc/documentdb/local/${PG_MAJOR}/gateway.env"
    local gateway_env_backup=""

    log "Verifying a live default-port cluster we own is silently re-adopted when its persisted setup state is missing."

    # Pre-flight: re-adoption happens inside validate_live_cluster_paths,
    # which documentdb-setup only reaches once find_listener_pid() (lsof/ss)
    # can attribute the running PG process to a PID. Some container runtimes
    # hide cross-UID socket ownership unless the test container has a
    # capability such as SYS_PTRACE. If lsof/ss report no PID, setup never
    # resolves the live data_directory and this code path is unreachable, so
    # skip rather than false-fail.
    if ! sudo lsof -tiTCP:"${PG_PORT}" -sTCP:LISTEN >/dev/null 2>&1 \
            && ! sudo ss -ltnp "( sport = :${PG_PORT} )" 2>/dev/null \
                 | grep -oE 'pid=[0-9]+' >/dev/null; then
        skip_or_fail_guard "verify_live_cluster_readoption" \
            "container cannot identify the PID of the running PG listener (needs SYS_PTRACE); the re-adoption path in validate_live_cluster_paths is unreachable"
        return 0
    fi

    create_temp_file state_backup "/tmp/documentdb-postgresql-state.XXXXXX"
    create_temp_file per_major_state_backup "/tmp/documentdb-postgresql-permajor-state.XXXXXX"
    create_temp_file pg_url_backup "/tmp/documentdb-postgresql-pg-url.XXXXXX"
    create_temp_file gateway_env_backup "/tmp/documentdb-postgresql-gateway-env.XXXXXX"
    create_temp_file readopt_log "/tmp/documentdb-setup-readopt.XXXXXX.log"
    create_temp_file password_file "/tmp/documentdb-pw-readopt.XXXXXX"
    printf '%s' "${PASSWORD}" > "${password_file}"

    sudo cp /etc/documentdb/documentdb-postgresql.env "${state_backup}"
    if sudo test -f "${pg_url_file}"; then
        sudo cp "${pg_url_file}" "${pg_url_backup}"
    fi
    if sudo test -f "${gateway_env_file}"; then
        sudo cp "${gateway_env_file}" "${gateway_env_backup}"
    fi
    sudo rm -f /etc/documentdb/documentdb-postgresql.env
    if sudo test -f "/etc/documentdb/local/${PG_MAJOR}/setup.conf"; then
        sudo cp "/etc/documentdb/local/${PG_MAJOR}/setup.conf" "${per_major_state_backup}"
        sudo rm -f "/etc/documentdb/local/${PG_MAJOR}/setup.conf"
    fi

    # Both state files are gone, but the cluster is still running from the
    # default per-major data directory and owned by documentdb-local. setup
    # must recognise it as ours and re-adopt it WITHOUT requiring --data-dir.
    if ! sudo documentdb-setup --username "${USERNAME}" --password-file "${password_file}" \
            --yes --no-enable --skip-init-data --verbose > "${readopt_log}" 2>&1; then
        cat "${readopt_log}"
        sudo cp "${state_backup}" /etc/documentdb/documentdb-postgresql.env
        [[ -s "${per_major_state_backup}" ]] && \
            sudo cp "${per_major_state_backup}" "/etc/documentdb/local/${PG_MAJOR}/setup.conf"
        if [[ -s "${pg_url_backup}" ]]; then
            sudo cp "${pg_url_backup}" "${pg_url_file}"
            sudo chown root:documentdb-gateway "${pg_url_file}"
            sudo chmod 0640 "${pg_url_file}"
        fi
        if [[ -s "${gateway_env_backup}" ]]; then
            sudo cp "${gateway_env_backup}" "${gateway_env_file}"
            sudo chown root:root "${gateway_env_file}"
            sudo chmod 0644 "${gateway_env_file}"
        fi
        fail "documentdb-setup should silently re-adopt a live default-port cluster it owns when persisted management state is missing"
    fi

    # Re-adoption must take the dedicated code path and re-record the
    # management state it just rebuilt: the legacy env file returns with
    # DOCUMENTDB_MANAGED_POSTGRES=true and the per-major setup.conf is
    # written again.
    assert_file_contains_regex "${readopt_log}" 'Re-adopting documentdb-local-owned PostgreSQL cluster' \
        "Re-adoption should be logged when no persisted management state is present"
    assert_file_contains_regex /etc/documentdb/documentdb-postgresql.env '^DOCUMENTDB_MANAGED_POSTGRES=true$' \
        "Re-adoption should re-record the legacy management-state env file"
    sudo test -f "/etc/documentdb/local/${PG_MAJOR}/setup.conf" \
        || fail "Re-adoption should re-create the per-major setup.conf"

    # Restore the exact pre-test on-disk state so later phases see the
    # cluster the primary happy-path run left behind.
    sudo cp "${state_backup}" /etc/documentdb/documentdb-postgresql.env
    [[ -s "${per_major_state_backup}" ]] && \
        sudo cp "${per_major_state_backup}" "/etc/documentdb/local/${PG_MAJOR}/setup.conf"
    if [[ -s "${pg_url_backup}" ]]; then
        sudo cp "${pg_url_backup}" "${pg_url_file}"
        sudo chown root:documentdb-gateway "${pg_url_file}"
        sudo chmod 0640 "${pg_url_file}"
    fi
    if [[ -s "${gateway_env_backup}" ]]; then
        sudo cp "${gateway_env_backup}" "${gateway_env_file}"
        sudo chown root:root "${gateway_env_file}"
        sudo chmod 0644 "${gateway_env_file}"
    fi
}

# The documentdb-postgresql@.service template intentionally omits PIDFile= and
# tracks the postmaster via Type=forking + cgroup GuessMainPID, which is
# independent of the data directory. documentdb-setup must therefore NOT write
# a per-data-dir PIDFile drop-in for a custom --data-dir, and must clean up any
# stale datadir.conf drop-in left by an older version.
verify_no_pidfile_drop_in_for_custom_data_dir() {
    local custom_pg_port="5434"
    local custom_data_dir="/var/lib/documentdb/data-dropin-test"
    local password_file=""
    local custom_log=""
    # Per packaging-design.md §4.4 the PG service is templated as
    # documentdb-postgresql@N.service, so the drop-in directory is
    # per-major (not the legacy non-templated form).
    local drop_in_dir="/etc/systemd/system/documentdb-postgresql@${PG_MAJOR}.service.d"
    local drop_in_file="${drop_in_dir}/datadir.conf"
    local legacy_drop_in_file="/etc/systemd/system/documentdb-postgresql.service.d/datadir.conf"
    local pg_ctl_bin="/usr/pgsql-${POSTGRES_VERSION}/bin/pg_ctl"

    create_temp_file custom_log "/tmp/documentdb-setup-dropin.XXXXXX.log"
    create_temp_file password_file "/tmp/documentdb-pw-dropin.XXXXXX"
    printf '%s' "${PASSWORD}" > "${password_file}"

    # Pre-clean so we cannot accidentally pass on a leftover from a prior run.
    sudo rm -rf "${custom_data_dir}" "${drop_in_file}" "${legacy_drop_in_file}" 2>/dev/null || true
    sudo rmdir "${drop_in_dir}" 2>/dev/null || true
    sudo rmdir "$(dirname "${legacy_drop_in_file}")" 2>/dev/null || true

    log "Verifying NO systemd PIDFile drop-in is written for custom --data-dir."
    if ! sudo documentdb-setup --username "${USERNAME}" --password-file "${password_file}" \
            --pg-port "${custom_pg_port}" \
            --data-dir "${custom_data_dir}" \
            --yes --no-enable --skip-init-data --verbose > "${custom_log}" 2>&1; then
        cat "${custom_log}"
        fail "documentdb-setup with custom --data-dir failed"
    fi

    if [[ -e "${drop_in_file}" ]]; then
        fail "No PIDFile drop-in must be written for a custom --data-dir (unit tracks via cgroup)"
    fi
    if [[ -e "${legacy_drop_in_file}" ]]; then
        fail "No legacy PIDFile drop-in must be written for a custom --data-dir"
    fi

    # Stop the custom PG cluster before returning state to the default.
    sudo -u documentdb-local "${pg_ctl_bin}" -D "${custom_data_dir}" -w stop -m fast 2>/dev/null || true

    # Seed a stale drop-in (as an older version would have left) and confirm the
    # next setup run strips it. Return DATA_DIR to the default in the same run so
    # the persisted per-major state is reset for subsequent tests. Pass the
    # default dir explicitly because capable containers can see the primary PG
    # is still running, so the live-cluster guard requires explicit adoption
    # after the custom-dir run temporarily pointed global state at the custom
    # cluster.
    log "Verifying a stale PIDFile drop-in is cleaned up when DATA_DIR returns to the default."
    sudo install -d -m 0755 "${drop_in_dir}" "$(dirname "${legacy_drop_in_file}")"
    printf '[Service]\nPIDFile=%s/postmaster.pid\n' "${custom_data_dir}" \
        | sudo tee "${drop_in_file}" >/dev/null
    # Seed the legacy non-templated path too, so cleanup of BOTH the templated
    # and legacy paths is exercised end-to-end, not just the templated one.
    printf '[Service]\nPIDFile=%s/postmaster.pid\n' "${custom_data_dir}" \
        | sudo tee "${legacy_drop_in_file}" >/dev/null
    if ! sudo documentdb-setup --username "${USERNAME}" --password-file "${password_file}" \
            --data-dir "${STANDALONE_DATA_DIR}" \
            --yes --no-enable --skip-init-data --verbose > "${custom_log}" 2>&1; then
        cat "${custom_log}"
        fail "documentdb-setup default-data-dir rerun (stale drop-in cleanup) failed"
    fi
    if [[ -e "${drop_in_file}" ]]; then
        fail "A stale templated PIDFile drop-in must be removed on a subsequent setup run"
    fi
    if [[ -e "${legacy_drop_in_file}" ]]; then
        fail "A stale legacy (non-templated) PIDFile drop-in must also be removed"
    fi

    sudo rm -rf "${custom_data_dir}" 2>/dev/null || true
}

verify_postgres_state() {
    local preload_libraries
    local hba_file
    local extended_rum_control
    local pg_config_bin
    local ident_file
    local result
    local unauthorized_role="documentdb_ident_scope_test"

    log "Verifying PostgreSQL settings, HBA, roles, and extensions."
    assert_eq "$(run_psql 'SHOW listen_addresses;')" "localhost" "Unexpected listen_addresses"
    assert_eq "$(run_psql 'SHOW unix_socket_directories;')" "${PG_SOCKET_DIR}" "Unexpected unix_socket_directories"
    assert_eq "$(run_psql 'SHOW ssl;')" "off" "Unexpected ssl setting"
    assert_eq "$(run_psql 'SHOW cron.database_name;')" "postgres" "Unexpected cron.database_name"
    # pg_cron must run jobs in background workers: the hardened pg_hba.conf blocks
    # pg_cron's default client connection (cron.host=localhost over TCP), so the
    # off mode fails every scheduled job ("connection failed") and the
    # build_index_concurrently job that completes createIndexes never runs,
    # hanging the gateway's index-build wait. Guard against regression.
    assert_eq "$(run_psql 'SHOW cron.use_background_workers;')" "on" "Unexpected cron.use_background_workers (must be on so scheduled index builds complete under the hardened HBA)"
    assert_eq "$(run_psql 'SHOW documentdb.localhost_connection_string;')" "host=${PG_SOCKET_DIR} port=${PG_PORT}" \
        "Unexpected documentdb.localhost_connection_string"
    assert_eq "$(run_psql 'SHOW documentdb.enableBackgroundWorker;')" "on" "Unexpected documentdb.enableBackgroundWorker"
    assert_eq "$(run_psql 'SHOW documentdb.enableBackgroundWorkerJobs;')" "on" "Unexpected documentdb.enableBackgroundWorkerJobs"
    assert_eq "$(run_psql 'SHOW documentdb.indexBuildsScheduledOnBgWorker;')" "off" "Unexpected documentdb.indexBuildsScheduledOnBgWorker"

    preload_libraries="$(run_psql 'SHOW shared_preload_libraries;')"
    assert_contains "${preload_libraries}" "pg_cron" "shared_preload_libraries missing pg_cron"
    assert_contains "${preload_libraries}" "pg_documentdb_core" "shared_preload_libraries missing pg_documentdb_core"
    assert_contains "${preload_libraries}" "pg_documentdb" "shared_preload_libraries missing pg_documentdb"

    hba_file="$(run_psql 'SHOW hba_file;')"
    assert_file_contains_regex "${hba_file}" 'local[[:space:]]+all[[:space:]]+.*documentdb-gateway.*peer[[:space:]]+map=documentdb-gateway-map' \
        "Missing scoped local peer+map HBA entry"

    # Verify no local trust entries remain (peer replaced trust)
    if grep -E '^local[[:space:]]+all[[:space:]]+all[[:space:]]+trust' "${hba_file}" >/dev/null 2>&1; then
        fail "HBA should NOT have local trust entries -- peer auth should be used instead"
    fi

    result="$(run_psql_as_documentdb_os documentdb-local 'SELECT current_user;' 2>&1)" \
        || fail "documentdb-local user should connect via Unix socket peer auth but got: ${result}"
    assert_eq "${result}" "documentdb-local" "documentdb-local Unix socket peer connection returned wrong user"

    result="$(run_psql_as_documentdb_os "${USERNAME}" 'SELECT current_user;' 2>&1)" \
        || fail "documentdb-local OS user should connect as app role ${USERNAME} through the scoped group map but got: ${result}"
    assert_eq "${result}" "${USERNAME}" "documentdb-local Unix socket app-role connection returned wrong user"

    ident_file="$(run_psql 'SHOW ident_file;')"
    assert_file_contains_regex "${ident_file}" '^documentdb-gateway-map[[:space:]]+documentdb-gateway[[:space:]]+documentdb-gateway([[:space:]]|$)' \
        "pg_ident.conf should allow documentdb-gateway OS user as documentdb-gateway role"
    assert_file_contains_regex "${ident_file}" '^documentdb-gateway-map[[:space:]]+documentdb-gateway[[:space:]]+\+documentdb_admin_role([[:space:]]|$)' \
        "pg_ident.conf should allow documentdb-gateway OS user as documentdb_admin_role members"
    assert_file_contains_regex "${ident_file}" '^documentdb-gateway-map[[:space:]]+documentdb-gateway[[:space:]]+\+documentdb_readwrite_role([[:space:]]|$)' \
        "pg_ident.conf should allow documentdb-gateway OS user as documentdb_readwrite_role members"
    assert_file_contains_regex "${ident_file}" '^documentdb-gateway-map[[:space:]]+documentdb-gateway[[:space:]]+\+documentdb_readonly_role([[:space:]]|$)' \
        "pg_ident.conf should allow documentdb-gateway OS user as documentdb_readonly_role members"
    assert_file_contains_regex "${ident_file}" '^documentdb-gateway-map[[:space:]]+documentdb-local[[:space:]]+\+documentdb_admin_role([[:space:]]|$)' \
        "pg_ident.conf should allow documentdb-local OS user as documentdb_admin_role members for server-side maintenance connections"
    assert_file_contains_regex "${ident_file}" '^documentdb-gateway-map[[:space:]]+documentdb-local[[:space:]]+\+documentdb_readwrite_role([[:space:]]|$)' \
        "pg_ident.conf should allow documentdb-local OS user as documentdb_readwrite_role members for server-side maintenance connections"
    assert_file_contains_regex "${ident_file}" '^documentdb-gateway-map[[:space:]]+documentdb-local[[:space:]]+\+documentdb_readonly_role([[:space:]]|$)' \
        "pg_ident.conf should allow documentdb-local OS user as documentdb_readonly_role members for server-side maintenance connections"
    assert_file_not_contains_regex "${ident_file}" '^documentdb-gateway-map[[:space:]]+documentdb-gateway[[:space:]]+all([[:space:]]|$)' \
        "pg_ident.conf should not allow documentdb-gateway OS user to impersonate every DB role"
    assert_file_not_contains_regex "${ident_file}" '^documentdb-gateway-map[[:space:]]+documentdb-local[[:space:]]+all([[:space:]]|$)' \
        "pg_ident.conf should not allow documentdb-local OS user to impersonate every DB role via the gateway map"

    run_psql "DROP ROLE IF EXISTS ${unauthorized_role}; CREATE ROLE ${unauthorized_role} LOGIN;"
    if result="$(run_psql_as_documentdb_os "${unauthorized_role}" 'SELECT current_user;' 2>&1)"; then
        run_psql "DROP ROLE ${unauthorized_role};"
        fail "documentdb OS user should not connect as non-DocumentDB role ${unauthorized_role}, got: ${result}"
    fi
    run_psql "DROP ROLE ${unauthorized_role};"

    # The documentdb role is the bootstrap superuser created by
    # `initdb --username=documentdb`; it is no longer granted via an explicit
    # CREATE ROLE statement but must still be able to log in.
    assert_eq "$(run_psql "SELECT CASE WHEN rolcanlogin AND rolsuper THEN 'ok' ELSE 'bad' END FROM pg_roles WHERE rolname = 'documentdb-local';")" "ok" "documentdb-local bootstrap role missing LOGIN or SUPERUSER attribute"
    assert_eq "$(run_psql "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${USERNAME}') THEN 'ok' ELSE 'missing' END;")" "ok" "Application role was not created"
    assert_eq "$(run_psql "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'documentdb_core') THEN 'ok' ELSE 'missing' END;")" "ok" "documentdb_core extension missing"
    assert_eq "$(run_psql "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'documentdb') THEN 'ok' ELSE 'missing' END;")" "ok" "documentdb extension missing"

    pg_config_bin="$(resolve_pg_config)"
    extended_rum_control="$("${pg_config_bin}" --sharedir)/extension/documentdb_extended_rum.control"
    if [[ -f "${extended_rum_control}" ]]; then
        assert_contains "${preload_libraries}" "pg_documentdb_extended_rum" "shared_preload_libraries missing pg_documentdb_extended_rum"
        assert_eq "$(run_psql 'SHOW documentdb.rum_library_load_option;')" "require_documentdb_extended_rum" "Unexpected documentdb.rum_library_load_option"
        assert_eq "$(run_psql 'SHOW documentdb.alternate_index_handler_name;')" "extended_rum" "Unexpected documentdb.alternate_index_handler_name"
        assert_eq "$(run_psql "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'documentdb_extended_rum') THEN 'ok' ELSE 'missing' END;")" "ok" "documentdb_extended_rum extension missing"
    fi
}

verify_gateway_crud() {
    local mongosh_log="/tmp/mongosh-smoke.log"
    local crud_script=""

    crud_script="$(cat <<'EOF'
const database = db.getSiblingDB("quickStartDatabase");
database.quickStartCollection.deleteMany({});
database.quickStartCollection.insertOne({name: "John Doe", email: "john@email.com"});
const doc = database.quickStartCollection.findOne({name: "John Doe"});
if (!doc || doc.email !== "john@email.com") {
    quit(1);
}
printjson(doc);
EOF
)"

    log "Running mongosh CRUD smoke test through the gateway."
    if ! run_mongosh_script "${crud_script}" "${mongosh_log}"; then
        cat "${mongosh_log}"
        fail "mongosh CRUD smoke test failed"
    fi
    cat "${mongosh_log}"

    grep -Fq 'John Doe' "${mongosh_log}" || fail "mongosh CRUD smoke test did not return the inserted document"
    grep -Fq 'john@email.com' "${mongosh_log}" || fail "mongosh CRUD smoke test did not persist the expected email"
}

verify_sample_data() {
    local sample_log="/tmp/mongosh-sampledata.log"
    local sample_script=""

    sample_script="$(cat <<'EOF'
const database = db.getSiblingDB("sampledb");
const counts = {
    users: database.users.countDocuments(),
    products: database.products.countDocuments(),
    orders: database.orders.countDocuments(),
    analytics: database.analytics.countDocuments(),
};
printjson(counts);
if (Object.values(counts).some((value) => value < 1)) {
    quit(1);
}
EOF
)"

    log "Verifying packaged sample data load through the gateway."
    if ! run_mongosh_script "${sample_script}" "${sample_log}"; then
        cat "${sample_log}"
        fail "Sample data verification failed"
    fi
    cat "${sample_log}"
}

verify_sample_data_absent() {
    local sample_log="/tmp/mongosh-sampledata-absent.log"
    local sample_script=""

    sample_script="$(cat <<'EOF'
const database = db.getSiblingDB("sampledb");
const counts = {
    users: database.users.countDocuments(),
    products: database.products.countDocuments(),
    orders: database.orders.countDocuments(),
    analytics: database.analytics.countDocuments(),
};
printjson(counts);
if (Object.values(counts).some((value) => value !== 0)) {
    quit(1);
}
EOF
)"

    log "Verifying packaged sample data is skipped when disabled."
    if ! run_mongosh_script "${sample_script}" "${sample_log}"; then
        cat "${sample_log}"
        fail "Sample data disable verification failed"
    fi
    cat "${sample_log}"
}

verify_removed_flags_rejected() {
    local err_log=""
    local pw_file=""

    log "Verifying documentdb-setup rejects removed flags --skip-pg-init and --pg-owner."
    create_temp_file err_log "/tmp/documentdb-setup-removed-flags.XXXXXX.log"
    create_temp_file pw_file "/tmp/documentdb-pw-removed-flags.XXXXXX"
    printf '%s' "${PASSWORD}" > "${pw_file}"

    if sudo documentdb-setup --username "${USERNAME}" --password-file "${pw_file}" \
            --skip-pg-init > "${err_log}" 2>&1; then
        fail "documentdb-setup should reject --skip-pg-init after scope reduction"
    fi
    assert_file_contains_regex "${err_log}" 'Unknown argument' \
        "Removed --skip-pg-init should produce an Unknown argument error"

    if sudo documentdb-setup --username "${USERNAME}" --password-file "${pw_file}" \
            --pg-owner documentdb > "${err_log}" 2>&1; then
        fail "documentdb-setup should reject --pg-owner after scope reduction"
    fi
    assert_file_contains_regex "${err_log}" 'Unknown argument' \
        "Removed --pg-owner should produce an Unknown argument error"
}

# ---------------------------------------------------------------------------
# Inline DOCUMENTDB_PG_URL rejection (packaged-wrapper regression guard)
# ---------------------------------------------------------------------------

verify_inline_pg_url_rejected() {
    # The packaged /usr/bin/documentdb-gateway wrapper must fail closed on the
    # unsupported inline DOCUMENTDB_PG_URL: the daemon reads only
    # DOCUMENTDB_PG_URL_FILE, so an inline value is non-functional AND would
    # leak via /proc/<pid>/environ. The wrapper rejects it (non-zero exit, a
    # fixed message, and without echoing the value) before sourcing env or
    # exec'ing the daemon. This package-level guard ensures a future
    # repackaging cannot silently drop the behavior covered by the wrapper
    # unit tests.
    local sentinel="InlineUrlSentinelDoNotLeak"
    local reject_output=""

    log "Verifying documentdb-gateway rejects an inline DOCUMENTDB_PG_URL."
    if reject_output="$(sudo -u documentdb-gateway env \
            DOCUMENTDB_PG_URL="postgres://u:${sentinel}@/db" \
            documentdb-gateway --version 2>&1)"; then
        printf '%s\n' "${reject_output}"
        fail "documentdb-gateway did NOT reject an inline DOCUMENTDB_PG_URL"
    fi
    if ! printf '%s\n' "${reject_output}" | grep -Fq 'DOCUMENTDB_PG_URL is not supported'; then
        printf '%s\n' "${reject_output}"
        fail "documentdb-gateway rejection did not print the expected message"
    fi
    if printf '%s\n' "${reject_output}" | grep -Fq "${sentinel}"; then
        fail "documentdb-gateway rejection leaked the inline DOCUMENTDB_PG_URL value"
    fi
}

# ---------------------------------------------------------------------------
# Root-shell privilege drop (EL8 runuser regression guard)
# ---------------------------------------------------------------------------

verify_wrapper_root_privilege_drop() {
    # This is the ONLY test in any suite that reaches the wrapper's
    # root -> runuser branch (_maybe_runuser_down). Everything else enters
    # already-unprivileged and skips it: the DEB gateway suite's container
    # runs as USER documentdb, the sudo -u invocations above drop before the
    # wrapper starts, and the Python unit tests set INVOCATION_ID to fake a
    # systemd run precisely so the drop is bypassed. That gap is how the
    # original bug shipped -- a runuser flag EL8's util-linux 2.32 does not
    # support (--whitelist-environment) -- so a root invocation is worth
    # keeping even though it duplicates a --version call: this RPM suite's
    # entrypoint already runs as root, and RHEL/Rocky 8 is exactly the
    # platform that regressed.
    local version_output=""

    log "Verifying documentdb-gateway --version works from a root shell (runuser privilege drop)."
    [[ "$(id -u)" -eq 0 ]] \
        || fail "Expected this suite to run as root; the runuser privilege-drop branch would be skipped"
    id -u documentdb-gateway >/dev/null 2>&1 \
        || fail "documentdb-gateway user missing; the runuser privilege-drop branch would be skipped"
    [[ -z "${INVOCATION_ID:-}" ]] \
        || fail "INVOCATION_ID is set; the wrapper would treat this as a systemd run and skip the privilege drop"

    if ! version_output="$(documentdb-gateway --version 2>&1)"; then
        printf '%s\n' "${version_output}"
        fail "documentdb-gateway --version failed from a root shell (runuser privilege drop regression)"
    fi
    # An unsupported runuser option fails with a usage/unrecognized-option
    # error rather than the daemon's own output -- assert we got the latter.
    if ! printf '%s\n' "${version_output}" | grep -Eqi '[0-9]+\.[0-9]+'; then
        printf '%s\n' "${version_output}"
        fail "documentdb-gateway --version from a root shell did not print a recognizable version"
    fi
    if printf '%s\n' "${version_output}" | grep -Eqi 'unrecognized option|invalid option|unknown option|Usage: runuser'; then
        printf '%s\n' "${version_output}"
        fail "runuser rejected an option (EL8 util-linux 2.32 compatibility regression)"
    fi
}

# ---------------------------------------------------------------------------
# systemd unit-file static verification
# ---------------------------------------------------------------------------
#
# Per packaging-design.md §4.4 + §8 the design's public day-2 surface is the
# systemd target tree:
#   - documentdb-postgresql@N.service
#   - documentdb-gateway-local@N.service
#   - documentdb-local@N.target
#   - documentdb-gateway.service
#
# Running those units needs a systemd PID 1, which a regular RHEL container
# doesn't have. What we CAN do is static-verify the unit files with
# `systemd-analyze verify`, which catches the kind of unit-file regression
# that surfaces as "Failed to load configuration for ...: Invalid argument"
# on a real systemd host during `systemctl enable --now`.
verify_systemd_unit_files() {
    log "Verifying systemd unit files parse cleanly."
    if ! command -v systemd-analyze >/dev/null 2>&1; then
        record_skip "verify_systemd_unit_files" "systemd-analyze is not installed in this container"
        return 0
    fi

    local unit_dir
    if [[ -d /usr/lib/systemd/system ]]; then
        unit_dir="/usr/lib/systemd/system"
    else
        unit_dir="/lib/systemd/system"
    fi

    local -a required_units=(
        "documentdb-gateway.service"
        "documentdb-postgresql@.service"
        "documentdb-gateway-local@.service"
        "documentdb-local@.target"
    )
    local unit
    for unit in "${required_units[@]}"; do
        if ! sudo test -f "${unit_dir}/${unit}"; then
            fail "Expected systemd unit ${unit_dir}/${unit} to exist after RPM install"
        fi
    done

    local verify_log=""
    create_temp_file verify_log "/tmp/systemd-verify.XXXXXX.log"
    for unit in "${required_units[@]}"; do
        log "  systemd-analyze verify ${unit}"
        if ! systemd-analyze verify "${unit_dir}/${unit}" >"${verify_log}" 2>&1; then
            cat "${verify_log}"
            fail "systemd-analyze verify exited non-zero for ${unit}"
        fi
        if grep -Eq '^(Failed to load|Bad |Error in dependency)' "${verify_log}"; then
            cat "${verify_log}"
            fail "systemd-analyze verify reported a fatal issue for ${unit}"
        fi
    done

    local target_content gw_unit_content gw_workflow_b pg_unit_content
    target_content="$(sudo cat "${unit_dir}/documentdb-local@.target")"
    assert_contains "${target_content}" "documentdb-postgresql@%i.service" \
        "documentdb-local@.target must compose documentdb-postgresql@%i.service"
    assert_contains "${target_content}" "documentdb-gateway-local@%i.service" \
        "documentdb-local@.target must compose documentdb-gateway-local@%i.service"

    pg_unit_content="$(sudo cat "${unit_dir}/documentdb-postgresql@.service")"
    assert_contains "${pg_unit_content}" "PartOf=documentdb-local@%i.target" \
        "documentdb-postgresql@.service must be PartOf= the per-major target"
    assert_contains "${pg_unit_content}" "ConditionPathExists=/etc/documentdb/local/%i/setup.conf" \
        "documentdb-postgresql@.service must ConditionPathExists on /etc/documentdb/local/%i/setup.conf — the brownfield/greenfield discriminator from packaging-design.md §4.4"
    assert_contains "${pg_unit_content}" "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
        "documentdb-postgresql@.service must allow AF_NETLINK for PostgreSQL interface enumeration"

    gw_unit_content="$(sudo cat "${unit_dir}/documentdb-gateway-local@.service")"
    assert_contains "${gw_unit_content}" "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6" \
        "documentdb-gateway-local@.service should keep the tighter gateway address-family set"
    assert_not_contains "${gw_unit_content}" "AF_NETLINK" \
        "documentdb-gateway-local@.service must not inherit PostgreSQL's AF_NETLINK exception"
    assert_contains "${gw_unit_content}" "After=documentdb-postgresql@%i.service" \
        "documentdb-gateway-local@.service must order After= documentdb-postgresql@%i.service"
    assert_contains "${gw_unit_content}" "Requires=documentdb-postgresql@%i.service" \
        "documentdb-gateway-local@.service must Requires= documentdb-postgresql@%i.service"
    assert_contains "${gw_unit_content}" "PartOf=documentdb-local@%i.target" \
        "documentdb-gateway-local@.service must be PartOf= the per-major target"
    assert_contains "${gw_unit_content}" "ConditionPathExists=/etc/documentdb/local/%i/gateway.env" \
        "documentdb-gateway-local@.service must ConditionPathExists on /etc/documentdb/local/%i/gateway.env so it skips cleanly (like the sibling PG unit) before documentdb-setup runs — see packaging-design.md §4.4"
    assert_contains "${gw_unit_content}" "User=documentdb-gateway" \
        "documentdb-gateway-local@.service must run as documentdb-gateway"
    assert_contains "${gw_unit_content}" "NoNewPrivileges=yes" \
        "documentdb-gateway-local@.service must set NoNewPrivileges=yes"
    assert_contains "${gw_unit_content}" "ProtectSystem=strict" \
        "documentdb-gateway-local@.service must set ProtectSystem=strict"
    assert_contains "${gw_unit_content}" "MemoryDenyWriteExecute=yes" \
        "documentdb-gateway-local@.service must set MemoryDenyWriteExecute=yes (matches the Workflow B gateway hardening posture from packaging-design.md §7)"

    gw_workflow_b="$(sudo cat "${unit_dir}/documentdb-gateway.service")"
    assert_contains "${gw_workflow_b}" "User=documentdb-gateway" \
        "documentdb-gateway.service must run as documentdb-gateway"
    assert_contains "${gw_workflow_b}" "NoNewPrivileges=yes" \
        "documentdb-gateway.service must set NoNewPrivileges=yes"
    assert_contains "${gw_workflow_b}" "ProtectSystem=strict" \
        "documentdb-gateway.service must set ProtectSystem=strict"
    assert_contains "${gw_workflow_b}" "MemoryDenyWriteExecute=yes" \
        "documentdb-gateway.service must set MemoryDenyWriteExecute=yes"
    assert_contains "${gw_workflow_b}" "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6" \
        "documentdb-gateway.service should keep the tighter gateway address-family set"
    assert_not_contains "${gw_workflow_b}" "AF_NETLINK" \
        "documentdb-gateway.service must not inherit PostgreSQL's AF_NETLINK exception"
}

# Verifies the rpm package's %postun ($1==0) scriptlet strips documentdb-setup
# managed configuration blocks from postgresql.conf, pg_hba.conf, and
# pg_ident.conf in the cluster's data directory. Without this cleanup, an
# adopted-or-foreign cluster's config would silently retain documentdb-setup's
# mutations after the package is gone -- the regression this test guards
# against (previously pg_ident.conf entries had no managed-block markers and
# were impossible to clean up at uninstall time).
#
# This test is destructive (it removes the package) so it must be the last
# one to run. It runs after sample-data verification so all gateway-stack
# functionality has already been exercised.
verify_package_remove_cleanup() {
    local remove_log=""
    local data_dir=""
    local config_file=""
    local hba_file=""
    local ident_file=""
    local -a packages_to_remove=(
        "documentdb-${PG_MAJOR}"
        "documentdb-common"
        "documentdb-gateway"
        "documentdb-postgresql-tools"
    )
    local admin_marker_ident="documentdb-setup-remove-test-admin-marker-ident   somemap   someuser"
    local admin_marker_hba="# documentdb-setup-remove-test-admin-marker-hba (must survive remove)"
    local admin_marker_conf="# documentdb-setup-remove-test-admin-marker-conf (must survive remove)"

    create_temp_file remove_log "/tmp/documentdb-packages-remove.XXXXXX.log"

    data_dir="$(grep -E '^DATA_DIR=' /etc/documentdb/documentdb-postgresql.env | head -1 | cut -d= -f2-)"
    [[ -n "${data_dir}" ]] || fail "Could not read DATA_DIR from documentdb-postgresql.env before remove"
    config_file="$(grep -E '^CONFIG_FILE=' /etc/documentdb/documentdb-postgresql.env | head -1 | cut -d= -f2-)"
    hba_file="$(grep -E '^HBA_FILE=' /etc/documentdb/documentdb-postgresql.env | head -1 | cut -d= -f2-)"
    ident_file="$(grep -E '^IDENT_FILE=' /etc/documentdb/documentdb-postgresql.env | head -1 | cut -d= -f2-)"
    [[ -n "${config_file}" ]] || config_file="${data_dir}/postgresql.conf"
    [[ -n "${hba_file}" ]] || hba_file="${data_dir}/pg_hba.conf"
    [[ -n "${ident_file}" ]] || ident_file="${data_dir}/pg_ident.conf"

    log "Verifying managed-block markers are present in PG config files before remove."
    assert_file_contains_regex "${config_file}" '^# >>> documentdb-setup managed configuration >>>$' \
        "postgresql.conf must contain the managed-configuration start marker before remove"
    assert_file_contains_regex "${hba_file}" '^# >>> documentdb-setup managed hba >>>$' \
        "pg_hba.conf must contain the managed-hba start marker before remove"
    assert_file_contains_regex "${ident_file}" '^# >>> documentdb-setup managed pg_ident >>>$' \
        "pg_ident.conf must contain the managed-pg_ident start marker before remove"

    # Append admin-owned marker lines OUTSIDE any managed block so we can
    # verify remove cleanup only strips the managed blocks and does not
    # accidentally clobber unrelated content.
    log "Seeding admin-owned marker lines outside the managed blocks for remove-survival check."
    sudo bash -c "printf '%s\n' '${admin_marker_conf}' >> '${config_file}'"
    sudo bash -c "printf '%s\n' '${admin_marker_hba}' >> '${hba_file}'"
    sudo bash -c "printf '%s\n' '${admin_marker_ident}' >> '${ident_file}'"

    # Include the extension RPM so its %postun actually runs.
    #
    # This used to probe `rpm -q documentdb` -- the META package's name
    # (documentdb-local-meta.spec), which this image never installs. The probe
    # was therefore always false, the silent else left the extension installed,
    # and the step logged "Verifying full uninstall..." while never exercising
    # the extension's own removal scriptlet. The real name is
    # postgresql<N>-documentdb, already resolved from the RPM header during
    # install; EXTENSION_PACKAGE_NAME carries it here.
    [[ -n "${EXTENSION_PACKAGE_NAME}" ]] \
        || fail "EXTENSION_PACKAGE_NAME was never resolved; verify_package_install must run before the uninstall check"
    packages_to_remove+=("${EXTENSION_PACKAGE_NAME}")
    if rpm -q documentdb >/dev/null 2>&1; then
        packages_to_remove=("documentdb" "${packages_to_remove[@]}")
    fi

    log "Verifying full uninstall strips packaged configuration state from the stand-alone stack."
    if ! sudo rpm -e "${packages_to_remove[@]}" > "${remove_log}" 2>&1; then
        cat "${remove_log}"
        fail "Removing ${packages_to_remove[*]} failed"
    fi
    cat "${remove_log}"

    for package_name in "${packages_to_remove[@]}"; do
        if rpm -q "${package_name}" >/dev/null 2>&1; then
            fail "${package_name} still appears installed after rpm -e"
        fi
    done

    assert_not_exists /etc/documentdb/documentdb-postgresql.env
    assert_not_exists "/etc/documentdb/local/${PG_MAJOR}/setup.conf"
    assert_not_exists "/etc/documentdb/local/${PG_MAJOR}/gateway.env"
    assert_not_exists "/var/lib/documentdb-local/${PG_MAJOR}/gateway/pg-url"
    # Cover both the templated (post-Track-1) and legacy (pre-Track-1)
    # drop-in paths so a regression in either form is caught.
    assert_not_exists "/etc/systemd/system/documentdb-postgresql@${PG_MAJOR}.service.d/datadir.conf"
    assert_not_exists "/etc/systemd/system/documentdb-postgresql@${PG_MAJOR}.service.d"
    assert_not_exists /etc/systemd/system/documentdb-postgresql.service.d/datadir.conf
    assert_not_exists /etc/systemd/system/documentdb-postgresql.service.d

    # Same managed-block stripping invariant as the deb path: data dir is
    # preserved on uninstall, but the documentdb-setup managed blocks must
    # be gone so the underlying cluster's config is restored to its
    # pre-install shape, AND admin-owned content outside the blocks must be
    # preserved.
    sudo test -f "${data_dir}/PG_VERSION" \
        || fail "PG data directory ${data_dir}/PG_VERSION must still exist after rpm -e"
    if sudo test -f "${config_file}"; then
        assert_file_not_contains_regex "${config_file}" '# >>> documentdb-setup managed configuration >>>' \
            "postgresql.conf managed configuration block must be stripped on rpm -e"
        assert_file_not_contains_regex "${config_file}" '# <<< documentdb-setup managed configuration <<<' \
            "postgresql.conf managed configuration end marker must be stripped on rpm -e"
        assert_file_not_contains_regex "${config_file}" '# >>> documentdb-setup managed listen >>>' \
            "postgresql.conf managed listen block must be stripped on rpm -e"
        assert_file_not_contains_regex "${config_file}" '# <<< documentdb-setup managed listen <<<' \
            "postgresql.conf managed listen end marker must be stripped on rpm -e"
        assert_file_contains_regex "${config_file}" "$(printf '%s' "${admin_marker_conf}" | sed 's/[][\.*^$()+?{|/]/\\&/g')" \
            "postgresql.conf admin marker outside managed block must survive rpm -e"
    fi
    if sudo test -f "${hba_file}"; then
        assert_file_not_contains_regex "${hba_file}" '# >>> documentdb-setup managed hba >>>' \
            "pg_hba.conf managed hba block must be stripped on rpm -e"
        assert_file_not_contains_regex "${hba_file}" '# <<< documentdb-setup managed hba <<<' \
            "pg_hba.conf managed hba end marker must be stripped on rpm -e"
        if sudo grep -E 'map=documentdb(-gateway)?-map' "${hba_file}" >/dev/null 2>&1; then
            fail "pg_hba.conf still contains a package-managed peer rule after rpm -e"
        fi
        assert_file_contains_regex "${hba_file}" "$(printf '%s' "${admin_marker_hba}" | sed 's/[][\.*^$()+?{|/]/\\&/g')" \
            "pg_hba.conf admin marker outside managed block must survive rpm -e"
    fi
    if sudo test -f "${ident_file}"; then
        assert_file_not_contains_regex "${ident_file}" '# >>> documentdb-setup managed pg_ident >>>' \
            "pg_ident.conf managed pg_ident block must be stripped on rpm -e"
        assert_file_not_contains_regex "${ident_file}" '# <<< documentdb-setup managed pg_ident <<<' \
            "pg_ident.conf managed pg_ident end marker must be stripped on rpm -e"
        if sudo grep -E '^documentdb(-gateway)?-map[[:space:]]' "${ident_file}" >/dev/null 2>&1; then
            fail "pg_ident.conf still contains package-managed map entries after rpm -e"
        fi
        assert_file_contains_regex "${ident_file}" '^documentdb-setup-remove-test-admin-marker-ident' \
            "pg_ident.conf admin marker outside managed block must survive rpm -e"
    fi
}

main() {
    # Precondition: documentdb-setup must be installed. The RHEL
    # gateway-test Dockerfiles install all four Track 1 packages
    # (extension + gateway + tools + per-major stand-alone), so the
    # command is always on PATH. If it is missing, that is a Dockerfile
    # regression, not a CI environment issue — fail loudly with a hint.
    if ! command -v documentdb-setup >/dev/null 2>&1; then
        fail "documentdb-setup not found on PATH. Phases 4+ require it. Check that packaging/test_packages/Dockerfile-rhel-gateway-test installs the documentdb-postgresql-tools and documentdb-N RPMs (built via packaging/build_extra_packages.sh --type rpm)."
    fi

    verify_preun_scriptlet_behaviour
    verify_posttrans_scriptlet_behaviour
    verify_package_install
    verify_systemd_unit_files
    verify_removed_flags_rejected
    verify_inline_pg_url_rejected
    verify_wrapper_root_privilege_drop
    run_documentdb_setup --skip-init-data
    verify_gateway_configuration
    verify_self_managed_postgres_persistence
    verify_live_cluster_readoption
    verify_postgres_state
    verify_tls_key_permissions
    verify_gateway_crud
    verify_sample_data_absent
    # Drop-in-for-custom-data-dir only initdb's and starts a PG cluster on a
    # unique port; it never goes through the gateway, so the TLS path that
    # gates other custom-port tests does not apply here.
    verify_no_pidfile_drop_in_for_custom_data_dir
    run_documentdb_setup --load-sample-data
    verify_sample_data
    # Destructive: must be the last test. Verifies %postun ($1==0) strips
    # documentdb-setup managed blocks from the underlying cluster's config
    # files and removes the env file.
    verify_package_remove_cleanup
    report_skips
    log "Gateway RPM clean-install E2E passed."
}

main "$@"
