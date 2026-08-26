#!/bin/bash
set -euo pipefail

readonly USERNAME="cloudsa"
readonly PASSWORD="$(head -c 16 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)Aa1"
# Per packaging-design.md §4.4: stand-alone defaults are derived from the
# PostgreSQL major (PG 18 → port 9718, socket /run/documentdb-local/18/postgresql,
# data /var/lib/documentdb-local/18/data). The Dockerfile passes
# POSTGRES_VERSION as ENV so we resolve once here and use these constants
# everywhere — keeping the test cell-agnostic across PG 15/16/17/18.
readonly PG_MAJOR="${POSTGRES_VERSION:?POSTGRES_VERSION env must be set by the test Dockerfile}"
readonly PG_PORT="$(( 9700 + PG_MAJOR ))"
readonly GATEWAY_PORT="10260"
readonly PG_SOCKET_DIR="/run/documentdb-local/${PG_MAJOR}/postgresql"
# Per-major standalone data directory (documentdb-setup's runtime default
# when --data-dir is omitted, per resolve_runtime_paths in
# documentdb-setup.sh). Used by the brownfield-adoption test below.
readonly STANDALONE_DATA_DIR="/var/lib/documentdb-local/${PG_MAJOR}/data"
readonly SETUP_LOG="/tmp/documentdb-setup.log"
readonly LSOF_PATH="$(command -v lsof || true)"
LSOF_BACKUP_PATH=""
TEMP_FILES=()

log() {
    echo "[gateway-package-e2e] $*"
}

cleanup() {
    if (( ${#TEMP_FILES[@]} > 0 )); then
        rm -rf "${TEMP_FILES[@]}" 2>/dev/null || true
        TEMP_FILES=()
    fi
    if [[ -n "${LSOF_BACKUP_PATH}" && -e "${LSOF_BACKUP_PATH}" ]]; then
        sudo mv "${LSOF_BACKUP_PATH}" "${LSOF_PATH}"
    fi
}
trap cleanup EXIT

fail() {
    echo "[gateway-package-e2e] ERROR: $*" >&2
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

assert_not_exists() {
    local path="$1"
    if [[ -e "${path}" ]]; then
        fail "Expected ${path} to be absent"
    fi
}

disable_lsof() {
    if [[ -z "${LSOF_PATH}" ]]; then
        return 0
    fi

    command -v ss >/dev/null 2>&1 || fail "ss is required to exercise the listener fallback path"
    LSOF_BACKUP_PATH="${LSOF_PATH}.documentdb-disabled"
    sudo mv "${LSOF_PATH}" "${LSOF_BACKUP_PATH}"
}

restore_lsof() {
    if [[ -n "${LSOF_BACKUP_PATH}" && -e "${LSOF_BACKUP_PATH}" ]]; then
        sudo mv "${LSOF_BACKUP_PATH}" "${LSOF_PATH}"
        LSOF_BACKUP_PATH=""
    fi
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

register_temp_file() {
    TEMP_FILES+=("$1")
}

create_temp_file() {
    local target_var="$1"
    local template="${2:-}"
    local created_file=""
    local -n target_ref="${target_var}"

    if [[ -n "${template}" ]]; then
        created_file="$(mktemp "${template}")"
    else
        created_file="$(mktemp)"
    fi

    chmod 600 "${created_file}"
    register_temp_file "${created_file}"
    target_ref="${created_file}"
}

create_temp_dir() {
    local target_var="$1"
    local template="${2:-/tmp/documentdb-tempdir.XXXXXX}"
    local created_dir=""
    local -n target_ref="${target_var}"

    created_dir="$(mktemp -d "${template}")"
    chmod 700 "${created_dir}"
    register_temp_file "${created_dir}"
    target_ref="${created_dir}"
}

run_maintainer_script_with_fake_systemctl() {
    local script_path="$1"
    local systemctl_log="$2"
    local active_services="$3"
    shift 3
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
# `list-units '<glob>' --state=active --plain --no-legend` is how the gateway
# prerm stop-loop and postinst restart-loop enumerate active per-major
# documentdb-gateway-local@N.service instances. Echo the FAKE_ACTIVE_SERVICES
# entries that match the requested glob in `--plain --no-legend` shape (the
# maintainer scripts read the first field via awk), so those loops are actually
# exercised instead of silently iterating over an empty list.
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

    # Docker Desktop runs containers in rootless mode (host kernel does
    # not grant the in-container `root` CAP_DAC_OVERRIDE), so a
    # documentdb-user-owned tempfile cannot be appended to by the
    # `sudo env ... bash ${prerm_script}` invocation below even when
    # the file is mode 0666 — the kernel-side write check fails before
    # the perm-bypass would normally apply.
    #
    # Re-create the systemctl_log via `sudo touch` so it ends up
    # owned by in-container-root, then chmod 666 so the test driver
    # (running as the documentdb user) can still read it back with
    # `$(< "${systemctl_log}")`. On real Docker (CI) this is a no-op
    # behaviorally because root genuinely owns the file either way.
    sudo bash -c "rm -f '${systemctl_log}' && touch '${systemctl_log}' && chmod 666 '${systemctl_log}'"

    # The maintainer scripts gate systemctl calls on `[ -d /run/systemd/system ]`.
    # The test container ships the systemctl binary (from the `systemd` package)
    # but not that directory — only systemd-as-PID-1 creates it at runtime — so
    # the gated stop/disable/daemon-reload paths would never execute and the
    # behavioral assertions would all trivially pass on an empty log. Create the
    # directory for the duration of this invocation only (removed afterwards if
    # we created it) so tests that intentionally exercise the no-systemd path
    # are unaffected, then let the fake systemctl on PATH record the calls.
    local _made_run_systemd=false
    if [[ ! -d /run/systemd/system ]]; then
        sudo install -d -m 0755 /run/systemd/system && _made_run_systemd=true
    fi

    local _rc=0
    sudo env \
        FAKE_ACTIVE_SERVICES="${active_services}" \
        FAKE_SYSTEMCTL_LOG="${systemctl_log}" \
        PATH="${fakebin_dir}:${PATH}" \
        bash "${script_path}" "$@" || _rc=$?

    if [[ "${_made_run_systemd}" == "true" ]]; then
        sudo rmdir /run/systemd/system 2>/dev/null || true
    fi
    return "${_rc}"
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

assert_executable() {
    local path="$1"
    if [[ ! -x "${path}" ]]; then
        fail "Expected executable ${path} to exist"
    fi
}

# Read one control field from an INSTALLED package.
#
# These queries used to end in `|| true`. dpkg-query already exits 0 with
# empty output when a field is merely absent, so the only thing `|| true`
# suppressed was "package not installed" -- which then fed an empty string
# into the negative assertions (no Recommends on the extension, no Conflicts
# between majors, no Depends on the tools package). Those pass trivially on an
# empty string, so a renamed or missing package silently disabled exactly the
# checks that protect multi-major co-installability. Fail loudly instead.
dpkg_field() {
    local pkg="$1"
    local field="$2"
    dpkg-query -W -f="\${${field}}\n" "${pkg}" 2>/dev/null \
        || fail "dpkg-query could not read ${field} from ${pkg} -- is the package installed under that name?"
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

    # Unreadable and no sudo: we cannot evaluate the assertion at all. Fail
    # rather than returning success -- a negative assertion that silently
    # passes because the file could not be opened is worse than no assertion,
    # since it reads as coverage.
    fail "${message}: cannot read ${path} (not readable by $(id -un) and sudo is unavailable), so this assertion could not be evaluated"
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

    # Per packaging-design.md §4.4 the greenfield private PG instance is
    # owned by the 'documentdb-local' OS user (created by
    # ensure_documentdb_runtime_user in documentdb-setup). Peer auth
    # via the wizard's managed ident map routes OS user
    # 'documentdb-local' → PG role 'documentdb-local'. Pre-redesign
    # this OS user was simply 'documentdb'.
    #
    # Prefer sudo over runuser: runuser requires CAP_SETUID and refuses
    # for non-root invokers (Docker Desktop / rootless containers run
    # the test entrypoint as the unprivileged 'documentdb' user). sudo
    # via the no-pass-ask sudoers rule works in both environments.
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

run_psql() {
    local sql="$1"
    # Per packaging-design.md §4.4 the greenfield PG instance is owned by
    # the 'documentdb-local' OS + PG superuser (initdb --username=
    # documentdb-local). Peer auth via the wizard's managed ident map
    # entry routes OS user 'documentdb-local' → PG role 'documentdb-local'.
    # Pre-redesign this was 'documentdb' on both sides.
    run_psql_as_documentdb_os documentdb-local "${sql}"
}

verify_package_contents() {
    log "Verifying packaged assets are installed."
    # All four Track 1 packages are installed in this container (per
    # the build_gateway_packages.sh orchestrator), so the gateway-side
    # files asserted here are present via the documentdb-gateway DEB,
    # while documentdb-setup / the templated PG service come from
    # documentdb-N. The package-boundary invariants are checked below
    # via dpkg -L (against the gateway package's manifest) rather than
    # file existence on disk.
    assert_executable /usr/bin/documentdb-gateway
    assert_file /etc/documentdb/gateway/SetupConfiguration.json
    assert_file /usr/lib/systemd/system/documentdb-gateway.service
    assert_file /usr/lib/sysusers.d/documentdb-gateway.conf
    assert_file /usr/lib/tmpfiles.d/documentdb-gateway.conf
    assert_file /usr/share/doc/documentdb-gateway/examples/gateway.env.sample

    # Package-boundary invariants (per packaging-design.md §4.3: the
    # gateway is runtime-only, must NOT ship documentdb-setup or any
    # PG service template). Check the gateway package's MANIFEST via
    # dpkg -L rather than file existence on disk — disk existence is
    # noise now that all four packages are co-installed, but the
    # gateway DEB's own file list is still the right place to check
    # the boundary.
    local gw_manifest=""
    gw_manifest="$(dpkg -L documentdb-gateway 2>/dev/null)"
    if printf '%s\n' "${gw_manifest}" | grep -qE '(^|/)documentdb-setup$'; then
        fail "documentdb-gateway manifest must NOT contain documentdb-setup (lives in documentdb-common)"
    fi
    if printf '%s\n' "${gw_manifest}" | grep -qE 'documentdb-postgresql(@\.service|\.service)$'; then
        fail "documentdb-gateway manifest must NOT contain a PostgreSQL service template (lives in documentdb-common)"
    fi
    if printf '%s\n' "${gw_manifest}" | grep -qE '(documentdb-tune|documentdb-register-gateway|documentdb-createcluster|documentdb-gateway-admin)$'; then
        fail "documentdb-gateway manifest must NOT contain PostgreSQL admin helpers (live in documentdb-postgresql-tools)"
    fi
}

verify_package_dependencies() {
    local gateway_conflicts=""
    local gateway_depends=""
    local gateway_provides=""
    local gateway_replaces=""
    local gateway_suggests=""
    local tools_suggests=""

    log "Verifying gateway package metadata leaves PostgreSQL-major selection to the user."
    gateway_depends="$(dpkg-query -W -f='${Depends}\n' documentdb-gateway)"
    # jq must NOT be a gateway runtime dependency (the gateway binary doesn't
    # use it — only documentdb-gateway-admin
    # in the tools package does). Per packaging-design.md §4.3 the gateway
    # is runtime-only with minimal deps. Guard against regression.
    if printf '%s\n' "${gateway_depends}" | grep -Eq '(^|,[[:space:]]*)jq([[:space:]]|,|$)'; then
        fail "Gateway DEB metadata must not declare jq as a Depends — jq belongs to documentdb-postgresql-tools: ${gateway_depends}"
    fi
    assert_contains "${gateway_depends}" "openssl" "Gateway package metadata is missing the openssl dependency"
    if printf '%s\n' "${gateway_depends}" | grep -Eq 'postgresql-[0-9]+-documentdb'; then
        fail "Gateway package metadata should not auto-select a DocumentDB extension package: ${gateway_depends}"
    fi

    local gateway_recommends=""
    gateway_recommends="$(dpkg_field documentdb-gateway Recommends)"
    if printf '%s\n' "${gateway_recommends}" | grep -Eq 'postgresql-[0-9]+-documentdb'; then
        fail "Gateway must use Suggests, not Recommends, for extension packages: ${gateway_recommends}"
    fi
    gateway_suggests="$(dpkg_field documentdb-gateway Suggests)"
    assert_contains "${gateway_suggests}" "documentdb-postgresql-tools" \
        "Gateway package should Suggests: documentdb-postgresql-tools"
    tools_suggests="$(dpkg_field documentdb-postgresql-tools Suggests)"
    assert_contains "${tools_suggests}" "documentdb-gateway" \
        "Tools package should Suggests: documentdb-gateway"

    local ext_suggests=""
    local ext_depends=""
    ext_suggests="$(dpkg_field "postgresql-${PG_MAJOR}-documentdb" Suggests)"
    ext_depends="$(dpkg_field "postgresql-${PG_MAJOR}-documentdb" Depends)"
    assert_contains "${ext_suggests}" "documentdb-postgresql-tools" \
        "Extension package should Suggests: documentdb-postgresql-tools"
    if printf '%s\n' "${ext_depends}" | grep -Eq 'documentdb-postgresql-tools'; then
        fail "Extension package must not Depends on documentdb-postgresql-tools: ${ext_depends}"
    fi

    local standalone_conflicts=""
    standalone_conflicts="$(dpkg_field "documentdb-${PG_MAJOR}" Conflicts)"
    if printf '%s\n' "${standalone_conflicts}" | grep -Eq 'documentdb-[0-9]+'; then
        fail "Stand-alone package must not Conflicts with other major-N variants: ${standalone_conflicts}"
    fi
}

verify_maintainer_script_behaviour() {
    local prerm_script="/var/lib/dpkg/info/documentdb-gateway.prerm"
    local postinst_script="/var/lib/dpkg/info/documentdb-gateway.postinst"
    local systemctl_log=""
    local systemctl_calls=""
    # An active per-major appliance gateway instance, used to exercise the
    # prerm stop-loop and postinst restart-loop over the templated
    # documentdb-gateway-local@N.service units (enumerated via `list-units`).
    local active_local_unit="documentdb-gateway-local@${PG_MAJOR}.service"

    log "Verifying DEB maintainer scripts preserve service state across upgrades."
    assert_file "${prerm_script}"
    assert_file "${postinst_script}"
    create_temp_file systemctl_log "/tmp/documentdb-deb-systemctl.XXXXXX.log"

    run_maintainer_script_with_fake_systemctl "${prerm_script}" "${systemctl_log}" \
        "documentdb-gateway.service documentdb-postgresql.service ${active_local_unit}" \
        upgrade 0.114.0
    systemctl_calls="$(< "${systemctl_log}")"
    assert_not_contains "${systemctl_calls}" "stop documentdb-postgresql" "Upgrade prerm should not stop PostgreSQL"
    assert_not_contains "${systemctl_calls}" "stop documentdb-gateway" "Upgrade prerm should not stop gateway"
    assert_not_contains "${systemctl_calls}" "disable documentdb-postgresql" "Upgrade prerm should not disable PostgreSQL"
    assert_not_contains "${systemctl_calls}" "disable documentdb-gateway" "Upgrade prerm should not disable gateway"

    run_maintainer_script_with_fake_systemctl "${prerm_script}" "${systemctl_log}" \
        "${active_local_unit}" remove
    systemctl_calls="$(< "${systemctl_log}")"
    # Exact-line match for the main unit: "stop documentdb-gateway" is a prefix
    # substring of "stop documentdb-gateway-local@N.service", so a plain
    # assert_contains would false-pass off the templated-unit stop emitted by the
    # list-units loop even if the main service were never stopped. grep -Fxq pins
    # the whole line so this genuinely verifies the main gateway teardown.
    printf '%s\n' "${systemctl_calls}" | grep -Fxq "stop documentdb-gateway" \
        || fail "Removal prerm did not stop gateway"
    # Removal must STOP but not DISABLE. Debian keeps enablement state across
    # remove -> reinstall and clears it only on purge (postrm, via
    # deb-systemd-helper). Disabling here also fired on dpkg's temporary
    # "deconfigure", and since postinst has no re-enable path a routine apt
    # dependency-resolution pass permanently dropped the multi-user.target
    # wants symlink -- the gateway just stopped starting at boot.
    if printf '%s\n' "${systemctl_calls}" | grep -Fxq "disable documentdb-gateway"; then
        fail "Removal prerm must NOT disable the gateway -- enablement is cleared at purge time by postrm, not on remove"
    fi
    assert_contains "${systemctl_calls}" "stop ${active_local_unit}" "Removal prerm did not stop the active per-major appliance gateway instance"

    # "deconfigure" is a temporary dpkg state, not a removal: the package
    # stays installed and gets reconfigured in the same transaction, so the
    # prerm must do nothing at all.
    run_maintainer_script_with_fake_systemctl "${prerm_script}" "${systemctl_log}" \
        "${active_local_unit}" deconfigure
    systemctl_calls="$(< "${systemctl_log}")"
    assert_not_contains "${systemctl_calls}" "stop documentdb-gateway" \
        "Deconfigure prerm must NOT stop the gateway (dpkg reconfigures it in the same run)"
    assert_not_contains "${systemctl_calls}" "disable documentdb-gateway" \
        "Deconfigure prerm must NOT disable the gateway (this silently dropped boot-time enablement)"
    # The gateway package is runtime-only per packaging-design.md §4.3 — it
    # MUST NOT touch the PostgreSQL
    # service. PG service lifecycle belongs to documentdb-N's maintainer
    # scripts. Guard against regression that re-couples them.
    assert_not_contains "${systemctl_calls}" "stop documentdb-postgresql" "Removal prerm must NOT touch PostgreSQL (gateway is runtime-only)"
    assert_not_contains "${systemctl_calls}" "disable documentdb-postgresql" "Removal prerm must NOT disable PostgreSQL (gateway is runtime-only)"

    run_maintainer_script_with_fake_systemctl "${postinst_script}" "${systemctl_log}" \
        "documentdb-gateway.service" \
        configure
    systemctl_calls="$(< "${systemctl_log}")"
    assert_contains "${systemctl_calls}" "daemon-reload" "Fresh configure postinst should reload systemd"
    assert_not_contains "${systemctl_calls}" "restart documentdb-postgresql" "Fresh configure postinst must NOT touch PostgreSQL"
    assert_not_contains "${systemctl_calls}" "restart documentdb-gateway.service" "Fresh configure postinst should not restart gateway"

    run_maintainer_script_with_fake_systemctl "${postinst_script}" "${systemctl_log}" \
        "documentdb-gateway.service ${active_local_unit}" \
        configure 0.113.0
    systemctl_calls="$(< "${systemctl_log}")"
    assert_contains "${systemctl_calls}" "daemon-reload" "Upgrade postinst should reload systemd"
    assert_contains "${systemctl_calls}" "restart documentdb-gateway.service" "Upgrade postinst did not restart active gateway"
    assert_contains "${systemctl_calls}" "restart ${active_local_unit}" "Upgrade postinst did not restart the active per-major appliance gateway instance"
    # Same as above — postinst must never restart PG.
    assert_not_contains "${systemctl_calls}" "restart documentdb-postgresql" "Upgrade postinst must NOT restart PostgreSQL (gateway is runtime-only)"

    run_maintainer_script_with_fake_systemctl "${postinst_script}" "${systemctl_log}" "" configure 0.113.0
    systemctl_calls="$(< "${systemctl_log}")"
    assert_not_contains "${systemctl_calls}" "restart documentdb-gateway.service" "Upgrade postinst should preserve stopped gateway"
    assert_not_contains "${systemctl_calls}" "restart documentdb-postgresql" "Upgrade postinst must NOT restart PostgreSQL even when nothing else is active"
}

LSOF_FALLBACK_TESTED=false

run_documentdb_setup() {
    local setup_pid=""
    local password_file=""
    local -a setup_args=("$@")

    create_temp_file password_file "/tmp/documentdb-password.XXXXXX"
    printf '%s' "${PASSWORD}" > "${password_file}"

    log "Running packaged documentdb-setup."
    # Only disable lsof on the first run to exercise the ss fallback path.
    # Subsequent runs keep lsof available so stop_gateway_process can find PIDs.
    if [[ "${LSOF_FALLBACK_TESTED}" == "false" ]]; then
        disable_lsof
        LSOF_FALLBACK_TESTED=true
    fi

    sudo documentdb-setup --username "${USERNAME}" --password-file "${password_file}" --yes --verbose "${setup_args[@]}" > "${SETUP_LOG}" 2>&1 &
    setup_pid=$!
    while kill -0 "${setup_pid}" 2>/dev/null; do
        if password_visible_in_process_args "${setup_pid}"; then
            cat "${SETUP_LOG}"
            fail "documentdb-setup exposed the password in process arguments"
        fi
        sleep 0.1
    done
    restore_lsof

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
    # Per packaging-design.md §4.3 + tls.rs::DEFAULT_TLS_STATE_DIR, the
    # auto-generated cert/key pair lives under DOCUMENTDB_TLS_STATE_DIR.
    # In this test the gateway is launched WITHOUT systemd (the Docker
    # container has no PID 1 systemd), so documentdb-setup falls through
    # to the `nohup`-as-documentdb-gateway path with cwd
    # /var/lib/documentdb-gateway/. With no env override, tls.rs uses
    # the default state dir /var/lib/documentdb-gateway/tls/.
    #
    # If a future iteration of the test brings up the per-major
    # systemd unit instead, the path becomes
    # /var/lib/documentdb-local/${PG_MAJOR}/gateway/tls/ (the unit sets
    # Environment=DOCUMENTDB_TLS_STATE_DIR there). Probe both so the
    # test keeps working across either invocation mode.
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

    # Per packaging-design.md §4.3 the gateway runtime runs as the
    # 'documentdb-gateway' OS user (created by the gateway DEB/RPM
    # via sysusers.d). Pre-redesign this was just 'documentdb' — the
    # rename was part of the Track 1 four-package split.
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
    assert_file_contains_regex "/etc/documentdb/local/${PG_MAJOR}/setup.conf" '^DOCUMENTDB_MANAGED_POSTGRES=true$' "Per-major managed PostgreSQL flag missing"
    assert_file_contains_regex "/etc/documentdb/local/${PG_MAJOR}/setup.conf" '^PG_VERSION=' "Per-major PostgreSQL version missing"
    assert_file_contains_regex "/etc/documentdb/local/${PG_MAJOR}/setup.conf" '^DATA_DIR=' "Per-major data dir missing"
    assert_file_contains_regex "/etc/documentdb/local/${PG_MAJOR}/setup.conf" '^CONFIG_FILE=' "Per-major config file path missing"
    assert_file_contains_regex "/etc/documentdb/local/${PG_MAJOR}/setup.conf" '^HBA_FILE=' "Per-major hba file path missing"
    assert_file_contains_regex "/etc/documentdb/local/${PG_MAJOR}/setup.conf" '^IDENT_FILE=' "Per-major ident file path missing"
    # The resolved CONFIG_FILE/HBA_FILE/IDENT_FILE paths are persisted so the
    # postrm purge cleanup can strip managed blocks from non-default config
    # paths under DATA_DIR (adopted clusters may have their config files
    # outside DATA_DIR/<default-name>).
    assert_file_contains_regex /etc/documentdb/documentdb-postgresql.env '^CONFIG_FILE=' "Managed PostgreSQL config file path missing"
    assert_file_contains_regex /etc/documentdb/documentdb-postgresql.env '^HBA_FILE=' "Managed PostgreSQL hba file path missing"
    assert_file_contains_regex /etc/documentdb/documentdb-postgresql.env '^IDENT_FILE=' "Managed PostgreSQL ident file path missing"

    # The packaged unit sets no PIDFile= (it tracks the postmaster via cgroup),
    # so ensure_postgres_systemd_drop_in never writes a drop-in. None should
    # exist here; a left-over drop-in would indicate the cleanup is not stripping
    # a stale datadir.conf from a previous custom-data-dir run.
    # Check BOTH the templated (post-Track-1) and legacy (pre-Track-1)
    # paths — the wizard explicitly cleans up the legacy path; a regression
    # in either is a bug.
    assert_not_exists "/etc/systemd/system/documentdb-postgresql@${PG_MAJOR}.service.d/datadir.conf"
    assert_not_exists /etc/systemd/system/documentdb-postgresql.service.d/datadir.conf
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

verify_postgres_state() {
    local preload_libraries
    local hba_file
    local extended_rum_control

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
    # Per packaging-design.md §7 the new ident map is 'documentdb-gateway-map'
    # (was 'documentdb-map' pre-Track-1). The HBA line is also more
    # restrictive: only the documentdb-gateway role and the
    # documentdb_*_role groups can authenticate via this map, not all
    # users. The full per-line assertion is in verify_hba_security;
    # here we just sanity-check the managed block exists.
    assert_file_contains_regex "${hba_file}" 'local[[:space:]]+all[[:space:]]+.*documentdb-gateway.*peer[[:space:]]+map=documentdb-gateway-map' "Missing local peer+map HBA entry"

    # The documentdb role is the bootstrap superuser created by
    # `initdb --username=documentdb`; it is no longer granted via an explicit
    # CREATE ROLE statement but must still be able to log in.
    assert_eq "$(run_psql "SELECT CASE WHEN rolcanlogin AND rolsuper THEN 'ok' ELSE 'bad' END FROM pg_roles WHERE rolname = 'documentdb-local';")" "ok" "documentdb-local bootstrap role missing LOGIN or SUPERUSER attribute"
    assert_eq "$(run_psql "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${USERNAME}') THEN 'ok' ELSE 'missing' END;")" "ok" "Application role was not created"
    assert_eq "$(run_psql "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'documentdb_core') THEN 'ok' ELSE 'missing' END;")" "ok" "documentdb_core extension missing"
    assert_eq "$(run_psql "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'documentdb') THEN 'ok' ELSE 'missing' END;")" "ok" "documentdb extension missing"

    extended_rum_control="$(pg_config --sharedir)/extension/documentdb_extended_rum.control"
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
        for diagnostic_log in \
                "/var/lib/documentdb-gateway/gateway.log" \
                "/var/lib/documentdb-local/${PG_MAJOR}/data/pglog.log"; do
            if sudo test -f "${diagnostic_log}"; then
                log "Last 200 lines from ${diagnostic_log}:"
                sudo tail -200 "${diagnostic_log}" || true
            fi
        done
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

verify_package_purge_cleanup() {
    local purge_log=""
    local data_dir=""
    local config_file=""
    local hba_file=""
    local ident_file=""
    local remaining_documentdb_state=""
    local admin_marker_ident="documentdb-setup-purge-test-admin-marker-ident   somemap   someuser"
    local admin_marker_hba="# documentdb-setup-purge-test-admin-marker-hba (must survive purge)"
    local admin_marker_conf="# documentdb-setup-purge-test-admin-marker-conf (must survive purge)"
    local -a packages_to_purge=(
        "documentdb-${PG_MAJOR}"
        "documentdb-common"
        "documentdb-gateway"
        "documentdb-postgresql-tools"
    )

    create_temp_file purge_log "/tmp/documentdb-packages-purge.XXXXXX.log"

    # Capture the cluster's resolved config-file paths from the env file --
    # the postrm cleanup uses the same source, so reading from there ensures
    # the test's view matches what the cleanup is actually going to operate
    # on. Falls back to default ${data_dir}/<name> for backward compat with
    # older env-file layouts that only persisted DATA_DIR.
    data_dir="$(sudo grep -E '^DATA_DIR=' /etc/documentdb/documentdb-postgresql.env | head -1 | cut -d= -f2-)"
    [[ -n "${data_dir}" ]] || fail "Could not read DATA_DIR from documentdb-postgresql.env before purge"
    config_file="$(sudo grep -E '^CONFIG_FILE=' /etc/documentdb/documentdb-postgresql.env | head -1 | cut -d= -f2-)"
    hba_file="$(sudo grep -E '^HBA_FILE=' /etc/documentdb/documentdb-postgresql.env | head -1 | cut -d= -f2-)"
    ident_file="$(sudo grep -E '^IDENT_FILE=' /etc/documentdb/documentdb-postgresql.env | head -1 | cut -d= -f2-)"
    [[ -n "${config_file}" ]] || config_file="${data_dir}/postgresql.conf"
    [[ -n "${hba_file}" ]] || hba_file="${data_dir}/pg_hba.conf"
    [[ -n "${ident_file}" ]] || ident_file="${data_dir}/pg_ident.conf"

    log "Verifying managed-block markers are present in PG config files before purge."
    assert_file_contains_regex "${config_file}" '^# >>> documentdb-setup managed configuration >>>$' \
        "postgresql.conf must contain the managed-configuration start marker before purge"
    assert_file_contains_regex "${config_file}" '^# >>> documentdb-setup managed listen >>>$' \
        "postgresql.conf must contain the managed-listen start marker before purge"
    assert_file_contains_regex "${hba_file}" '^# >>> documentdb-setup managed hba >>>$' \
        "pg_hba.conf must contain the managed-hba start marker before purge"
    assert_file_contains_regex "${ident_file}" '^# >>> documentdb-setup managed pg_ident >>>$' \
        "pg_ident.conf must contain the managed-pg_ident start marker before purge"

    # Append admin-owned marker lines OUTSIDE any managed block so we can
    # verify purge cleanup only strips the managed blocks and does not
    # accidentally clobber unrelated content. This guards against the worst
    # failure mode of the cleanup: stripping from start-marker-to-EOF on a
    # malformed file, or matching too greedily across blocks.
    log "Seeding admin-owned marker lines outside the managed blocks for purge-survival check."
    sudo bash -c "printf '%s\n' '${admin_marker_conf}' >> '${config_file}'"
    sudo bash -c "printf '%s\n' '${admin_marker_hba}' >> '${hba_file}'"
    sudo bash -c "printf '%s\n' '${admin_marker_ident}' >> '${ident_file}'"

    if dpkg-query -W documentdb >/dev/null 2>&1; then
        packages_to_purge=("documentdb" "${packages_to_purge[@]}")
    fi

    # Simulate the operator having enabled the Workflow B gateway unit
    # (postinst deliberately never auto-enables; the operator runs plain
    # `systemctl enable`, which creates this symlink without any
    # deb-systemd-helper state). The gateway postrm must remove the link at
    # purge once it dangles -- deb-systemd-helper purge alone cannot, since
    # it only removes links recorded in its own state file.
    local gateway_wants_link="/etc/systemd/system/multi-user.target.wants/documentdb-gateway.service"
    sudo install -d -m 0755 "$(dirname "${gateway_wants_link}")"
    sudo ln -sf /usr/lib/systemd/system/documentdb-gateway.service "${gateway_wants_link}"

    log "Verifying purge removes packaged configuration state from the stand-alone stack."
    if ! sudo dpkg --purge "${packages_to_purge[@]}" > "${purge_log}" 2>&1; then
        cat "${purge_log}"
        fail "Purging ${packages_to_purge[*]} failed"
    fi
    cat "${purge_log}"

    for package_name in "${packages_to_purge[@]}"; do
        if dpkg-query -W -f='${Status}\n' "${package_name}" 2>/dev/null \
            | grep -Fxq 'install ok installed'; then
            fail "${package_name} still appears installed after purge"
        fi
    done

    # The operator-created enablement link must be cleaned up by the postrm
    # purge arm now that its target unit file is gone (a dangling wants link
    # would make systemd log "Failed to load unit" noise on every boot).
    if sudo test -L "${gateway_wants_link}" || sudo test -e "${gateway_wants_link}"; then
        fail "Purge must remove the dangling ${gateway_wants_link} enablement symlink"
    fi

    assert_not_exists /etc/documentdb/gateway/SetupConfiguration.json
    assert_not_exists /etc/documentdb/documentdb-postgresql.env
    assert_not_exists "/etc/documentdb/local/${PG_MAJOR}/setup.conf"
    assert_not_exists "/etc/documentdb/local/${PG_MAJOR}/gateway.env"
    assert_not_exists "/var/lib/documentdb-local/${PG_MAJOR}/gateway/pg-url"
    if sudo test -d /etc/documentdb; then
        remaining_documentdb_state="$(sudo find /etc/documentdb -mindepth 1 -maxdepth 4 -print 2>/dev/null || true)"
        if [[ -n "${remaining_documentdb_state}" ]]; then
            printf '%s\n' "${remaining_documentdb_state}"
            fail "/etc/documentdb should not retain package-managed state after purge"
        fi
    fi

    # Any admin-owned PIDFile drop-in written by documentdb-setup for a
    # custom data dir must also be removed on purge so the override does
    # not survive package removal and silently affect a future install.
    # Cover both the templated (post-Track-1) and legacy (pre-Track-1)
    # paths in case an upgrade-from-old-install left the legacy form
    # behind.
    assert_not_exists "/etc/systemd/system/documentdb-postgresql@${PG_MAJOR}.service.d/datadir.conf"
    assert_not_exists "/etc/systemd/system/documentdb-postgresql@${PG_MAJOR}.service.d"
    assert_not_exists /etc/systemd/system/documentdb-postgresql.service.d/datadir.conf
    assert_not_exists /etc/systemd/system/documentdb-postgresql.service.d

    # The data directory itself is preserved on purge by design (operators
    # may want to reinstall and resume), but the documentdb-setup managed
    # blocks must be stripped from postgresql.conf, pg_hba.conf, and
    # pg_ident.conf so an adopted-or-foreign cluster's config is restored
    # to its pre-install shape. Without managed-block stripping, ident-map
    # entries would silently mutate the cluster long after the package is
    # gone -- the prior pg_ident.conf-without-markers regression that this
    # test guards against.
    sudo test -f "${data_dir}/PG_VERSION" \
        || fail "PG data directory ${data_dir}/PG_VERSION must still exist after purge"
    if sudo test -f "${config_file}"; then
        assert_file_not_contains_regex "${config_file}" '# >>> documentdb-setup managed configuration >>>' \
            "postgresql.conf managed configuration block must be stripped on purge"
        assert_file_not_contains_regex "${config_file}" '# <<< documentdb-setup managed configuration <<<' \
            "postgresql.conf managed configuration end marker must be stripped on purge"
        assert_file_not_contains_regex "${config_file}" '# >>> documentdb-setup managed listen >>>' \
            "postgresql.conf managed listen block must be stripped on purge"
        assert_file_not_contains_regex "${config_file}" '# <<< documentdb-setup managed listen <<<' \
            "postgresql.conf managed listen end marker must be stripped on purge"
        assert_file_contains_regex "${config_file}" "$(printf '%s' "${admin_marker_conf}" | sed 's/[][\.*^$()+?{|/]/\\&/g')" \
            "postgresql.conf admin marker outside managed block must survive purge"
    fi
    if sudo test -f "${hba_file}"; then
        assert_file_not_contains_regex "${hba_file}" '# >>> documentdb-setup managed hba >>>' \
            "pg_hba.conf managed hba block must be stripped on purge"
        assert_file_not_contains_regex "${hba_file}" '# <<< documentdb-setup managed hba <<<' \
            "pg_hba.conf managed hba end marker must be stripped on purge"
        if sudo grep -E 'map=documentdb(-gateway)?-map' "${hba_file}" >/dev/null 2>&1; then
            fail "pg_hba.conf still contains a package-managed peer rule after purge"
        fi
        assert_file_contains_regex "${hba_file}" "$(printf '%s' "${admin_marker_hba}" | sed 's/[][\.*^$()+?{|/]/\\&/g')" \
            "pg_hba.conf admin marker outside managed block must survive purge"
    fi
    if sudo test -f "${ident_file}"; then
        assert_file_not_contains_regex "${ident_file}" '# >>> documentdb-setup managed pg_ident >>>' \
            "pg_ident.conf managed pg_ident block must be stripped on purge"
        assert_file_not_contains_regex "${ident_file}" '# <<< documentdb-setup managed pg_ident <<<' \
            "pg_ident.conf managed pg_ident end marker must be stripped on purge"
        if sudo grep -E '^documentdb(-gateway)?-map[[:space:]]' "${ident_file}" >/dev/null 2>&1; then
            fail "pg_ident.conf still contains package-managed map entries after purge"
        fi
        assert_file_contains_regex "${ident_file}" '^documentdb-setup-purge-test-admin-marker-ident' \
            "pg_ident.conf admin marker outside managed block must survive purge"
    fi
}

# ---------------------------------------------------------------------------
# Error-path tests — validate that documentdb-setup rejects invalid inputs
# ---------------------------------------------------------------------------

verify_error_paths() {
    local err_log=""
    local tls_cert_file=""
    create_temp_file err_log "/tmp/documentdb-setup-errorpath.XXXXXX.log"
    create_temp_file tls_cert_file "/tmp/documentdb-setup-cert.XXXXXX.pem"
    printf '%s\n' 'not-a-real-cert' > "${tls_cert_file}"

    log "Verifying documentdb-setup rejects invalid inputs."

    # Missing --username
    if sudo documentdb-setup --password-file /dev/null > "${err_log}" 2>&1; then
        fail "documentdb-setup should fail when --username is missing"
    fi
    assert_file_contains_regex "${err_log}" 'username' "Missing --username error should mention username"

    # Missing password (no --password-file, no env var)
    if sudo documentdb-setup --username testuser > "${err_log}" 2>&1; then
        fail "documentdb-setup should fail when password is missing"
    fi
    assert_file_contains_regex "${err_log}" 'password' "Missing password error should mention password"

    # --password flag rejected (the tool only accepts --password-file; the value
    # below is never parsed, it just exercises the unknown-flag rejection path)
    if sudo documentdb-setup --username testuser --password placeholder-value > "${err_log}" 2>&1; then
        fail "documentdb-setup should reject --password flag"
    fi
    assert_file_contains_regex "${err_log}" 'Unknown' "Rejected --password error should mention Unknown"

    # Unreadable password file
    if sudo documentdb-setup --username testuser --password-file /nonexistent/path > "${err_log}" 2>&1; then
        fail "documentdb-setup should fail with unreadable password file"
    fi
    assert_file_contains_regex "${err_log}" 'not readable' "Unreadable password file error should mention not readable"

    # Non-root execution
    if documentdb-setup --username testuser --password-file /dev/null > "${err_log}" 2>&1; then
        fail "documentdb-setup should fail when run as non-root"
    fi
    assert_file_contains_regex "${err_log}" 'root' "Non-root error should mention root"

    # Wrong PG version
    local pw_file=""
    create_temp_file pw_file "/tmp/documentdb-pw-errtest.XXXXXX"
    # Runtime-generated so no credential literal lives in source (CredScan).
    local errpw; errpw="$(openssl rand -hex 8)Aa1!"
    printf '%s' "${errpw}" > "${pw_file}"
    if sudo documentdb-setup --username testuser --password-file "${pw_file}" --pg-version 99 > "${err_log}" 2>&1; then
        fail "documentdb-setup should fail with invalid --pg-version"
    fi
    assert_file_contains_regex "${err_log}" '99|not found|Unable' "Wrong PG version error should mention the version or not found"

    if printf '%s' "${errpw}" | sudo documentdb-setup --username testuser \
            --password-file "${pw_file}" --admin-password-stdin > "${err_log}" 2>&1; then
        fail "documentdb-setup should reject --admin-password-file + --admin-password-stdin together"
    fi
    assert_file_contains_regex "${err_log}" 'mutually exclusive' \
        "Mutual exclusion error should mention mutually exclusive"

    if sudo documentdb-setup --username testuser --password-file "${pw_file}" \
            --tls-cert "${tls_cert_file}" > "${err_log}" 2>&1; then
        fail "documentdb-setup should reject --tls-cert without --tls-key"
    fi
    assert_file_contains_regex "${err_log}" '((--tls-cert requires --tls-key)|--tls-key)' \
        "TLS cert/key pairing error should mention --tls-key"
}

# ---------------------------------------------------------------------------
# HBA security assertions — verify peer auth is scoped to DocumentDB roles
# ---------------------------------------------------------------------------

verify_hba_security() {
    log "Verifying HBA security: peer auth with ident map restricts socket access to documentdb-gateway OS user."

    local result=""
    local ident_file=""
    local hba_file=""
    local unauthorized_role="documentdb_ident_scope_test"

    # Per packaging-design.md §7: the new auth model has two OS users:
    #   - documentdb-local: the PG superuser owner (initdb default).
    #     Peer auth maps it 1:1 to PG role 'documentdb-local' via the
    #     default `local all all peer` line that initdb wrote (not via
    #     any custom map — the OS name == PG role name path is enough).
    #   - documentdb-gateway: the gateway runtime user. Peer auth maps
    #     it to documentdb-gateway / +documentdb_admin_role /
    #     +documentdb_readwrite_role / +documentdb_readonly_role via
    #     the `documentdb-gateway-map` ident map.
    # The pre-Track-1 single-user model (documentdb OS user → all
    # documentdb roles via documentdb-map) is gone.

    # documentdb-local connects as the bootstrap role via Unix socket
    # peer auth (default `local all all peer` line, OS name matches PG
    # role name 1:1).
    result="$(run_psql_as_documentdb_os documentdb-local 'SELECT current_user;' 2>&1)" \
        || fail "documentdb-local user should connect via Unix socket peer auth but got: ${result}"
    assert_eq "${result}" "documentdb-local" "documentdb-local Unix socket peer connection returned wrong user"

    # NOTE: Pre-Track-1 this test also asserted that the documentdb OS
    # user could SET ROLE to the bootstrapped app user (cloudsa) via
    # psql. The new model intentionally separates documentdb-local
    # (PG superuser only) from documentdb-gateway (the role that holds
    # documentdb_admin_role membership). App users like cloudsa are
    # reached via the GATEWAY (wire protocol), NOT via psql as
    # documentdb-local. So that assertion has been removed.

    # pg_ident.conf must contain the documentdb-gateway-map entries
    # written by documentdb-register-gateway.
    ident_file="$(run_psql 'SHOW ident_file;')"
    sudo grep -Eq '^documentdb-gateway-map[[:space:]]+documentdb-gateway[[:space:]]+documentdb-gateway([[:space:]]|$)' "${ident_file}" \
        || fail "pg_ident.conf should allow documentdb-gateway OS user as documentdb-gateway role"
    sudo grep -Eq '^documentdb-gateway-map[[:space:]]+documentdb-gateway[[:space:]]+\+documentdb_admin_role([[:space:]]|$)' "${ident_file}" \
        || fail "pg_ident.conf should allow documentdb-gateway OS user as documentdb_admin_role members"
    sudo grep -Eq '^documentdb-gateway-map[[:space:]]+documentdb-gateway[[:space:]]+\+documentdb_readwrite_role([[:space:]]|$)' "${ident_file}" \
        || fail "pg_ident.conf should allow documentdb-gateway OS user as documentdb_readwrite_role members"
    sudo grep -Eq '^documentdb-gateway-map[[:space:]]+documentdb-gateway[[:space:]]+\+documentdb_readonly_role([[:space:]]|$)' "${ident_file}" \
        || fail "pg_ident.conf should allow documentdb-gateway OS user as documentdb_readonly_role members"
    sudo grep -Eq '^documentdb-gateway-map[[:space:]]+documentdb-local[[:space:]]+\+documentdb_admin_role([[:space:]]|$)' "${ident_file}" \
        || fail "pg_ident.conf should allow documentdb-local OS user as documentdb_admin_role members for server-side maintenance connections"
    sudo grep -Eq '^documentdb-gateway-map[[:space:]]+documentdb-local[[:space:]]+\+documentdb_readwrite_role([[:space:]]|$)' "${ident_file}" \
        || fail "pg_ident.conf should allow documentdb-local OS user as documentdb_readwrite_role members for server-side maintenance connections"
    sudo grep -Eq '^documentdb-gateway-map[[:space:]]+documentdb-local[[:space:]]+\+documentdb_readonly_role([[:space:]]|$)' "${ident_file}" \
        || fail "pg_ident.conf should allow documentdb-local OS user as documentdb_readonly_role members for server-side maintenance connections"
    if sudo grep -Eq '^documentdb-gateway-map[[:space:]]+documentdb-gateway[[:space:]]+all([[:space:]]|$)' "${ident_file}"; then
        fail "pg_ident.conf must NOT allow documentdb-gateway OS user to impersonate every DB role"
    fi
    if sudo grep -Eq '^documentdb-gateway-map[[:space:]]+documentdb-local[[:space:]]+all([[:space:]]|$)' "${ident_file}"; then
        fail "pg_ident.conf must NOT allow documentdb-local OS user to impersonate every DB role via the gateway map"
    fi

    # Verify the managed HBA block uses peer auth with the gateway map.
    hba_file="$(run_psql 'SHOW hba_file;')"
    sudo grep -Eq 'local[[:space:]]+all[[:space:]]+.*documentdb-gateway.*peer[[:space:]]+map=documentdb-gateway-map' "${hba_file}" \
        || fail "HBA should contain a peer+map rule for local connections from documentdb-gateway"

    result="$(sudo -u documentdb-gateway psql \
        -h "${PG_SOCKET_DIR}" -p "${PG_PORT}" -U documentdb-gateway \
        -d postgres -X -Atqc 'SELECT current_user;' 2>&1)" \
        || fail "documentdb-gateway OS user should connect as documentdb-gateway but got: ${result}"
    assert_eq "${result}" "documentdb-gateway" \
        "documentdb-gateway Unix socket peer connection returned wrong user"

    run_psql "DROP ROLE IF EXISTS ${unauthorized_role}; CREATE ROLE ${unauthorized_role} LOGIN;"
    if result="$(sudo -u documentdb-gateway psql \
            -h "${PG_SOCKET_DIR}" -p "${PG_PORT}" -U "${unauthorized_role}" \
            -d postgres -X -Atqc 'SELECT current_user;' 2>&1)"; then
        run_psql "DROP ROLE IF EXISTS ${unauthorized_role};"
        fail "documentdb-gateway OS user should not be able to peer-auth as unauthorized role ${unauthorized_role}"
    fi
    run_psql "DROP ROLE IF EXISTS ${unauthorized_role};"

    # These two go through assert_file_not_contains_regex rather than a bare
    # `if grep`. The data directory is mode 700 owned by documentdb-local
    # (documentdb-setup.sh chmods it) while this suite runs as USER documentdb,
    # so an unprivileged grep on pg_hba.conf exits 2 (EACCES) -- with stderr
    # silenced that reads as "no match" and the assertion passes no matter what
    # the file says. The local-trust check below was written that way, which
    # meant a regression of --auth-local=peer back to trust (any local OS user
    # could then connect as the documentdb-local superuser unauthenticated)
    # would have kept this suite green. The helper retries under sudo and
    # fails loudly when it cannot read the file at all.
    assert_file_not_contains_regex "${hba_file}" \
        '^host[[:space:]]+all[[:space:]]+all[[:space:]]+(127\.0\.0\.1|::1).*trust' \
        "HBA should NOT have TCP localhost trust entries -- gateway uses Unix socket"

    assert_file_not_contains_regex "${hba_file}" \
        '^local[[:space:]]+all[[:space:]]+all[[:space:]]+trust' \
        "HBA should NOT have local trust entries -- peer auth should be used instead"
}

# ---------------------------------------------------------------------------
# --admin-password-stdin test
# ---------------------------------------------------------------------------

verify_admin_password_stdin() {
    local stdin_log=""
    create_temp_file stdin_log "/tmp/documentdb-setup-stdin.XXXXXX.log"

    log "Verifying setup works with --admin-password-stdin."
    if ! printf '%s' "${PASSWORD}" | sudo documentdb-setup \
            --username stdinuser --admin-password-stdin \
            --yes --no-enable --skip-init-data --verbose > "${stdin_log}" 2>&1; then
        cat "${stdin_log}"
        fail "documentdb-setup with --admin-password-stdin failed"
    fi

    assert_eq "$(run_psql "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stdinuser') THEN 'ok' ELSE 'missing' END;")" \
        "ok" "stdinuser role was not created via --admin-password-stdin"
}

# ---------------------------------------------------------------------------
# DOCUMENTDB_PASSWORD env var test
# ---------------------------------------------------------------------------

verify_env_var_password() {
    local env_log=""
    create_temp_file env_log "/tmp/documentdb-setup-envvar.XXXXXX.log"

    log "Verifying setup works with DOCUMENTDB_PASSWORD env var."
    # Use a different username to avoid collision with the primary user
    if ! sudo DOCUMENTDB_PASSWORD="${PASSWORD}" documentdb-setup \
            --username envvaruser --yes --no-enable --skip-init-data --verbose > "${env_log}" 2>&1; then
        cat "${env_log}"
        fail "documentdb-setup with DOCUMENTDB_PASSWORD env var failed"
    fi

    assert_eq "$(run_psql "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'envvaruser') THEN 'ok' ELSE 'missing' END;")" \
        "ok" "envvaruser role was not created via DOCUMENTDB_PASSWORD env var"

    assert_file_contains_regex "${env_log}" 'deprecated|DEPRECATED' \
        "DOCUMENTDB_PASSWORD env var should produce a deprecation warning"
}

# ---------------------------------------------------------------------------
# --no-enable test — setup without starting gateway
# ---------------------------------------------------------------------------

verify_no_enable() {
    local noenable_log=""
    local password_file=""
    create_temp_file noenable_log "/tmp/documentdb-setup-noenable.XXXXXX.log"
    create_temp_file password_file "/tmp/documentdb-pw-noenable.XXXXXX"
    printf '%s' "${PASSWORD}" > "${password_file}"

    log "Verifying --no-enable skips gateway startup."

    if ! sudo documentdb-setup --username "${USERNAME}" --password-file "${password_file}" \
            --yes --no-enable --skip-init-data --verbose > "${noenable_log}" 2>&1; then
        cat "${noenable_log}"
        fail "documentdb-setup with --no-enable failed"
    fi
    cat "${noenable_log}"

    grep -Fq "Skipping gateway startup" "${noenable_log}" \
        || fail "documentdb-setup --no-enable did not print skip message"

    # Verify no gateway is listening
    if sudo lsof -ti :"${GATEWAY_PORT}" >/dev/null 2>&1; then
        fail "Gateway should NOT be running after --no-enable"
    fi
}

# ---------------------------------------------------------------------------
# Custom ports test
# ---------------------------------------------------------------------------

verify_custom_ports() {
    local custom_pg_port="5433"
    local custom_gw_port="27017"
    local custom_log=""
    local password_file=""
    local custom_data_dir="/var/lib/documentdb/custom-port-test"
    create_temp_file custom_log "/tmp/documentdb-setup-customport.XXXXXX.log"
    create_temp_file password_file "/tmp/documentdb-pw-customport.XXXXXX"
    printf '%s' "${PASSWORD}" > "${password_file}"

    log "Verifying custom --pg-port and --gateway-port."
    if ! sudo documentdb-setup --username "${USERNAME}" --password-file "${password_file}" \
            --pg-port "${custom_pg_port}" --gateway-port "${custom_gw_port}" \
            --data-dir "${custom_data_dir}" --yes \
            --no-enable --skip-init-data --verbose > "${custom_log}" 2>&1; then
        cat "${custom_log}"
        fail "documentdb-setup with custom ports failed"
    fi

    # Verify the custom ports landed in the per-major authoritative config, not
    # the singleton SetupConfiguration.json. As in verify_gateway_configuration,
    # the per-major install records the connection config in the per-major
    # gateway.env + connection-secret and strips the singleton JSON.
    local custom_gateway_env="/etc/documentdb/local/${PG_MAJOR}/gateway.env"
    local custom_pg_url_file="/var/lib/documentdb-local/${PG_MAJOR}/gateway/pg-url"
    assert_eq "$(jq -r '.PostgresPort' /etc/documentdb/gateway/SetupConfiguration.json)" "null" \
        "SetupConfiguration.json must not carry per-major PostgresPort (it belongs in the per-major gateway.env)"
    assert_eq "$(jq -r '.GatewayListenPort' /etc/documentdb/gateway/SetupConfiguration.json)" "null" \
        "SetupConfiguration.json must not carry per-major GatewayListenPort (it belongs in the per-major gateway.env)"
    assert_file_contains_regex "${custom_gateway_env}" "^DOCUMENTDB_LISTEN_ADDR=:${custom_gw_port}$" \
        "Per-major gateway.env must record the custom gateway listen port ${custom_gw_port}"
    assert_file_contains_regex "${custom_pg_url_file}" "port=${custom_pg_port}([^0-9]|$)" \
        "Connection-secret must carry the custom PostgreSQL port ${custom_pg_port}"

    # Verify PG is actually accepting socket connections on the custom port.
    assert_eq "$(sudo -u documentdb-local psql -h "/run/documentdb-local/${PG_MAJOR}/postgresql" -p "${custom_pg_port}" -d postgres -X -Atqc 'SELECT 1;')" "1" "PG should be listening on port ${custom_pg_port}"

    # Verify data dir was used
    sudo test -f "${custom_data_dir}/PG_VERSION" \
        || fail "Expected file ${custom_data_dir}/PG_VERSION to exist"

    # Verify env file references custom data dir
    assert_file_contains_regex /etc/documentdb/documentdb-postgresql.env "DATA_DIR=${custom_data_dir}" "Env file should reference custom data dir"

    # Clean up: stop the custom PG
    sudo -u documentdb-local /usr/lib/postgresql/*/bin/pg_ctl -D "${custom_data_dir}" -w stop -m fast 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Custom DATA_DIR systemd drop-in test
# ---------------------------------------------------------------------------
#
# The documentdb-postgresql@.service template intentionally omits PIDFile= and
# tracks the postmaster via Type=forking + cgroup GuessMainPID, which is
# independent of the data directory. documentdb-setup must therefore NOT write
# a per-data-dir PIDFile drop-in for a custom --data-dir, and must clean up any
# stale datadir.conf drop-in left by an older version.
#
# Per packaging-design.md §4.4 the PG service is per-major-templated
# (documentdb-postgresql@N.service), so the per-major drop-in directory is
# documentdb-postgresql@N.service.d/; pre-redesign the unit was non-templated
# (documentdb-postgresql.service) with its drop-in at
# documentdb-postgresql.service.d/. ensure_postgres_systemd_drop_in in
# documentdb-setup.sh strips a stale datadir.conf from both paths.
verify_no_pidfile_drop_in_for_custom_data_dir() {
    local custom_pg_port="5434"
    # Keep the custom dir OUT of /var/lib/documentdb-local/${PG_MAJOR}/ so
    # documentdb-setup treats it as a non-default --data-dir. Using
    # /var/lib/documentdb/... is fine: the path doesn't have to live under any
    # specific owner-writable tree for this assertion; the wizard chowns it to
    # documentdb-local on the fly.
    local custom_data_dir="/var/lib/documentdb/data-dropin-test"
    local password_file=""
    local custom_log=""
    local drop_in_dir="/etc/systemd/system/documentdb-postgresql@${PG_MAJOR}.service.d"
    local drop_in_file="${drop_in_dir}/datadir.conf"
    local legacy_drop_in_file="/etc/systemd/system/documentdb-postgresql.service.d/datadir.conf"

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
            --data-dir "${custom_data_dir}" --yes \
            --no-enable --skip-init-data --verbose > "${custom_log}" 2>&1; then
        cat "${custom_log}"
        fail "documentdb-setup with custom --data-dir failed"
    fi

    if [[ -e "${drop_in_file}" ]]; then
        fail "No PIDFile drop-in must be written for a custom --data-dir (unit tracks via cgroup)"
    fi
    if [[ -e "${legacy_drop_in_file}" ]]; then
        fail "No legacy PIDFile drop-in must be written for a custom --data-dir"
    fi

    # Stop the custom PG cluster before the cleanup test.
    # Per Track 1 the PG cluster owner is 'documentdb-local' (the
    # wizard chowns the data dir + initdb --username=documentdb-local).
    sudo -u documentdb-local /usr/lib/postgresql/*/bin/pg_ctl -D "${custom_data_dir}" -w stop -m fast 2>/dev/null || true

    # Seed a stale drop-in (as an older version would have left) and confirm a
    # subsequent setup run strips it — the function is clean-up-only.
    log "Verifying a stale PIDFile drop-in is cleaned up on the next setup run."
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

    # Final cleanup of the custom data dir to avoid leaving state for later tests.
    sudo rm -rf "${custom_data_dir}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Help-text assertion for documentdb-setup --help
# ---------------------------------------------------------------------------

verify_help_text_after_scope_reduction() {
    local setup_help=""

    log "Verifying documentdb-setup --help no longer advertises removed flags."
    setup_help="$(documentdb-setup --help)"

    # The --skip-pg-init capability was removed; ensure the help text does not
    # advertise it, and that --pg-owner (only meaningful for skip-pg-init) is
    # also gone.
    if printf '%s\n' "${setup_help}" | grep -Fq -- '--skip-pg-init'; then
        fail "documentdb-setup help should no longer advertise --skip-pg-init"
    fi
    if printf '%s\n' "${setup_help}" | grep -Fq -- '--pg-owner'; then
        fail "documentdb-setup help should no longer advertise --pg-owner"
    fi

    # Sanity: the still-supported flags must remain in --help.
    printf '%s\n' "${setup_help}" | grep -Fq -- '--pg-version' \
        || fail "documentdb-setup help should still advertise --pg-version"
    printf '%s\n' "${setup_help}" | grep -Fq -- '--data-dir' \
        || fail "documentdb-setup help should still advertise --data-dir"
}

# ---------------------------------------------------------------------------
# Removed-flag rejection -- the script must reject --skip-pg-init / --pg-owner
# ---------------------------------------------------------------------------

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
# Gateway utility flags (--check, --version)
# ---------------------------------------------------------------------------

verify_gateway_utility_flags() {
    local version_output=""

    log "Verifying documentdb-gateway --version prints version info."
    version_output="$(documentdb-gateway --version 2>&1)" \
        || fail "documentdb-gateway --version exited non-zero"
    if ! printf '%s\n' "${version_output}" | grep -Eq '[0-9]+\.[0-9]+'; then
        fail "documentdb-gateway --version did not print a recognizable version: ${version_output}"
    fi
}

verify_gateway_check_connectivity() {
    local check_output=""
    local pg_url_file="/var/lib/documentdb-local/${PG_MAJOR}/gateway/pg-url"

    log "Verifying documentdb-gateway --check connectivity probe."
    if ! check_output="$(sudo -u documentdb-gateway env \
            DOCUMENTDB_PG_URL_FILE="${pg_url_file}" \
            documentdb-gateway --check 2>&1)"; then
        printf '%s\n' "${check_output}"
        fail "documentdb-gateway --check failed after setup"
    fi
    printf '%s\n' "${check_output}"
    if ! printf '%s\n' "${check_output}" | grep -Fq 'documentdb-gateway: check OK'; then
        fail "documentdb-gateway --check did not report success"
    fi
}

# ---------------------------------------------------------------------------
# Inline DOCUMENTDB_PG_URL rejection (packaged-wrapper regression guard)
# ---------------------------------------------------------------------------

verify_inline_pg_url_rejected() {
    # The packaged /usr/bin/documentdb-gateway wrapper must fail closed on the
    # unsupported inline DOCUMENTDB_PG_URL: the daemon reads only
    # DOCUMENTDB_PG_URL_FILE, so an inline value is non-functional AND would
    # leak via /proc/<pid>/environ. The wrapper rejects it (non-zero exit, a
    # fixed message, and without echoing the value) after assembling its
    # environment (so a value smuggled into gateway.env is caught too) but
    # before exec'ing the daemon. This package-level guard ensures a future
    # repackaging cannot silently drop the behavior covered by the wrapper
    # unit tests. It depends only on the wrapper being installed and the
    # documentdb-gateway user existing, so it runs in Phase 2 (before any
    # setup) and is unaffected by later setup-dependent assertions.
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
# Connection-file ownership
# ---------------------------------------------------------------------------

verify_connection_file_ownership() {
    local pg_url_file="/var/lib/documentdb-local/${PG_MAJOR}/gateway/pg-url"
    local url_owner=""
    local url_mode=""

    log "Verifying gateway connection file ownership and permissions."
    if ! sudo test -f "${pg_url_file}"; then
        fail "Expected file ${pg_url_file} to exist"
    fi

    url_owner="$(sudo stat -c '%U:%G' "${pg_url_file}")"
    url_mode="$(sudo stat -c '%a' "${pg_url_file}")"

    assert_eq "${url_owner}" "root:documentdb-gateway" \
        "Connection file must be owned by root:documentdb-gateway (got ${url_owner})"
    assert_eq "${url_mode}" "640" \
        "Connection file must be mode 0640 (got ${url_mode})"
}

# ---------------------------------------------------------------------------
# systemd unit-file static verification
# ---------------------------------------------------------------------------
#
# Per packaging-design.md §4.4 + §8 the design's public day-2 surface is
# the systemd target tree:
#   - documentdb-postgresql@N.service  (per-major templated PG service)
#   - documentdb-gateway-local@N.service (per-major templated gateway)
#   - documentdb-local@N.target  (per-major composite target)
#   - documentdb-gateway.service (Workflow B standalone gateway)
#
# Running the units requires a systemd PID 1, which isn't available in
# regular Docker containers (you'd need --privileged + cgroup mount +
# a systemd-enabled base image). What WE can do without PID 1 is:
#
#   1. `systemd-analyze verify <unit-file>` — full static parse +
#      semantic check (Requires=/After= ordering, sandbox options, etc).
#      Works without systemd as PID 1.
#   2. Confirm all unit files are present on disk after install.
#   3. Confirm the template's `%i` expansion is well-formed by
#      symlink-instantiating the per-major instance.
#
# This catches the kind of bug that would surface as
# "Failed to load configuration for ...: Invalid argument" on a real
# systemd host during `systemctl enable --now documentdb-local.target`.

verify_systemd_unit_files() {
    log "Verifying systemd unit files parse cleanly."
    if ! command -v systemd-analyze >/dev/null 2>&1; then
        record_skip "verify_systemd_unit_files" "systemd-analyze is not installed in this container"
        return 0
    fi

    # The packages install units under the canonical usr-merged location
    # /usr/lib/systemd/system (see build-gateway-deb.sh + documentdb-common),
    # not the legacy /lib/systemd/system. Assert that exact path so the check
    # holds on non-usr-merged targets (e.g. debian:bullseye-slim) too, where
    # /lib is not a symlink to /usr/lib.
    local unit_dir="/usr/lib/systemd/system"
    local -a required_units=(
        "documentdb-gateway.service"
        "documentdb-postgresql@.service"
        "documentdb-gateway-local@.service"
        "documentdb-local@.target"
    )
    local unit
    for unit in "${required_units[@]}"; do
        assert_file "${unit_dir}/${unit}"
    done

    # systemd-analyze verify against the on-disk unit files. Use the
    # full paths so the analyzer doesn't try to resolve from the
    # systemd unit dir lookup chain (which can need a running systemd
    # to be reliable inside containers). Capture stderr separately so
    # one bad unit doesn't hide the others.
    #
    # Some hardening settings (e.g. ProtectSystem=strict) emit
    # "Failed to query system call number ... offline" warnings
    # inside containers — those are NOT failures of the unit. Treat
    # only "Failed to load" / "Bad" / "Error in dependency" as fatal.
    local verify_log=""
    create_temp_file verify_log "/tmp/systemd-verify.XXXXXX.log"
    for unit in "${required_units[@]}"; do
        log "  systemd-analyze verify ${unit}"
        # systemd-analyze exits 0 even when there are warnings; check
        # stderr for the actual failure signatures we care about.
        if ! systemd-analyze verify "${unit_dir}/${unit}" >"${verify_log}" 2>&1; then
            cat "${verify_log}"
            fail "systemd-analyze verify exited non-zero for ${unit}"
        fi
        if grep -Eq '^(Failed to load|Bad |Error in dependency)' "${verify_log}"; then
            cat "${verify_log}"
            fail "systemd-analyze verify reported a fatal issue for ${unit}"
        fi
    done

    # Per packaging-design.md §4.4 the per-major target composes
    # documentdb-postgresql@N + documentdb-gateway-local@N via Wants=
    # plus After= ordering. systemd-analyze can verify the templated
    # instance composition by instantiating it with %i = PG_MAJOR.
    log "  systemd-analyze verify documentdb-local@${PG_MAJOR}.target"
    if ! systemd-analyze verify "documentdb-local@${PG_MAJOR}.target" >"${verify_log}" 2>&1; then
        # When verifying by instance name (not file path), the
        # analyzer needs to look up the unit. If we're in a stripped
        # container that can't see the systemd dir layout, just log
        # and continue — the per-file checks above already covered
        # the .target unit's syntax.
        if grep -Fq 'Cannot find unit' "${verify_log}" \
                || grep -Fq 'Failed to prepare' "${verify_log}"; then
            log "    (instance verify unreachable in this container — file-level verify above already covered the .target syntax)"
        else
            cat "${verify_log}"
            fail "systemd-analyze verify exited non-zero for the templated documentdb-local@${PG_MAJOR}.target"
        fi
    fi

    # The per-major target must Wants= both services (greenfield
    # composes them). Read the target file directly because
    # systemd-analyze dump requires PID 1.
    local target_content=""
    target_content="$(cat "${unit_dir}/documentdb-local@.target")"
    assert_contains "${target_content}" "documentdb-postgresql@%i.service" \
        "documentdb-local@.target must compose documentdb-postgresql@%i.service"
    assert_contains "${target_content}" "documentdb-gateway-local@%i.service" \
        "documentdb-local@.target must compose documentdb-gateway-local@%i.service"

    # The greenfield PG service must have PartOf=documentdb-local@%i.target
    # so stopping the target stops PG (design §4.4 day-2 lifecycle).
    local pg_unit_content=""
    pg_unit_content="$(cat "${unit_dir}/documentdb-postgresql@.service")"
    assert_contains "${pg_unit_content}" "PartOf=documentdb-local@%i.target" \
        "documentdb-postgresql@.service must be PartOf= the per-major target"
    assert_contains "${pg_unit_content}" "ConditionPathExists=/etc/documentdb/local/%i/setup.conf" \
        "documentdb-postgresql@.service must ConditionPathExists on /etc/documentdb/local/%i/setup.conf — the brownfield/greenfield discriminator from packaging-design.md §4.4"
    assert_contains "${pg_unit_content}" "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
        "documentdb-postgresql@.service must allow AF_NETLINK for PostgreSQL interface enumeration"

    # Gateway-local must Require + After PG (greenfield ordering).
    local gw_unit_content=""
    gw_unit_content="$(cat "${unit_dir}/documentdb-gateway-local@.service")"
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

    # §7 security: gateway must run hardened (User=, NoNewPrivileges,
    # ProtectSystem=strict, etc).
    assert_contains "${gw_unit_content}" "User=documentdb-gateway" \
        "documentdb-gateway-local@.service must run as documentdb-gateway"
    assert_contains "${gw_unit_content}" "NoNewPrivileges=yes" \
        "documentdb-gateway-local@.service must set NoNewPrivileges=yes"
    assert_contains "${gw_unit_content}" "ProtectSystem=strict" \
        "documentdb-gateway-local@.service must set ProtectSystem=strict"
    assert_contains "${gw_unit_content}" "MemoryDenyWriteExecute=yes" \
        "documentdb-gateway-local@.service must set MemoryDenyWriteExecute=yes (matches the Workflow B gateway hardening posture from packaging-design.md §7)"

    # Workflow B gateway unit must have the same hardening
    local gw_workflow_b=""
    gw_workflow_b="$(cat "${unit_dir}/documentdb-gateway.service")"
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

# ---------------------------------------------------------------------------
# --restore round-trip test
# ---------------------------------------------------------------------------

verify_restore_round_trip() {
    local restore_log=""
    local reapply_log=""
    local password_file=""
    local config_file=""
    local hba_file=""
    local ident_file=""
    local data_dir=""

    log "Verifying --restore round-trip: setup -> restore -> re-setup."
    create_temp_file restore_log "/tmp/documentdb-setup-restore.XXXXXX.log"
    create_temp_file reapply_log "/tmp/documentdb-setup-reapply.XXXXXX.log"
    create_temp_file password_file "/tmp/documentdb-pw-restore.XXXXXX"
    printf '%s' "${PASSWORD}" > "${password_file}"

    data_dir="$(sudo grep -E '^DATA_DIR=' /etc/documentdb/documentdb-postgresql.env | head -1 | cut -d= -f2-)"
    config_file="$(sudo grep -E '^CONFIG_FILE=' /etc/documentdb/documentdb-postgresql.env | head -1 | cut -d= -f2-)"
    hba_file="$(sudo grep -E '^HBA_FILE=' /etc/documentdb/documentdb-postgresql.env | head -1 | cut -d= -f2-)"
    ident_file="$(sudo grep -E '^IDENT_FILE=' /etc/documentdb/documentdb-postgresql.env | head -1 | cut -d= -f2-)"
    [[ -n "${data_dir}" ]] || fail "Could not read DATA_DIR before restore"
    [[ -n "${config_file}" ]] || config_file="${data_dir}/postgresql.conf"
    [[ -n "${hba_file}" ]] || hba_file="${data_dir}/pg_hba.conf"
    [[ -n "${ident_file}" ]] || ident_file="${data_dir}/pg_ident.conf"

    assert_file_contains_regex "${config_file}" '# >>> documentdb-setup managed configuration >>>' \
        "Pre-condition: postgresql.conf must have managed configuration block before restore"
    assert_file_contains_regex "${config_file}" '# >>> documentdb-setup managed listen >>>' \
        "Pre-condition: postgresql.conf must have managed listen block before restore"
    assert_file_contains_regex "${hba_file}" '# >>> documentdb-setup managed hba >>>' \
        "Pre-condition: pg_hba.conf must have managed block before restore"
    assert_file_contains_regex "${ident_file}" '# >>> documentdb-setup managed pg_ident >>>' \
        "Pre-condition: pg_ident.conf must have managed block before restore"
    assert_file_contains_regex "${hba_file}" 'documentdb-gateway-map' \
        "Pre-condition: pg_hba.conf must contain the gateway peer map before restore"
    assert_file_contains_regex "${ident_file}" '^documentdb-gateway-map[[:space:]]' \
        "Pre-condition: pg_ident.conf must contain gateway map entries before restore"

    if ! sudo documentdb-setup --restore --yes --verbose > "${restore_log}" 2>&1; then
        cat "${restore_log}"
        fail "documentdb-setup --restore failed"
    fi
    cat "${restore_log}"

    assert_file_not_contains_regex "${config_file}" '# >>> documentdb-setup managed configuration >>>' \
        "postgresql.conf managed configuration block must be stripped after --restore"
    assert_file_not_contains_regex "${config_file}" '# >>> documentdb-setup managed listen >>>' \
        "postgresql.conf managed listen block must be stripped after --restore"
    assert_file_not_contains_regex "${hba_file}" '# >>> documentdb-setup managed hba >>>' \
        "pg_hba.conf managed block must be stripped after --restore"
    assert_file_not_contains_regex "${ident_file}" '# >>> documentdb-setup managed pg_ident >>>' \
        "pg_ident.conf managed block must be stripped after --restore"
    assert_file_not_contains_regex "${hba_file}" 'documentdb-gateway-map' \
        "pg_hba.conf gateway peer map must be stripped after --restore"
    assert_file_not_contains_regex "${ident_file}" '^documentdb-gateway-map[[:space:]]' \
        "pg_ident.conf gateway map entries must be stripped after --restore"
    sudo test -f "${data_dir}/PG_VERSION" \
        || fail "PG data directory ${data_dir}/PG_VERSION must still exist after --restore"
    assert_not_exists "/etc/documentdb/local/${PG_MAJOR}/setup.conf"
    assert_not_exists /etc/documentdb/documentdb-postgresql.env

    if ! sudo documentdb-setup --username "${USERNAME}" --password-file "${password_file}" \
            --data-dir "${data_dir}" \
            --yes --no-enable --skip-init-data --verbose > "${reapply_log}" 2>&1; then
        cat "${reapply_log}"
        fail "documentdb-setup re-run after --restore failed"
    fi
    cat "${reapply_log}"

    assert_file_contains_regex "${config_file}" '# >>> documentdb-setup managed configuration >>>' \
        "postgresql.conf managed configuration block must be re-created after re-setup"
    assert_file_contains_regex "${config_file}" '# >>> documentdb-setup managed listen >>>' \
        "postgresql.conf managed listen block must be re-created after re-setup"
    assert_file_contains_regex "${hba_file}" '# >>> documentdb-setup managed hba >>>' \
        "pg_hba.conf managed block must be re-created after re-setup"
    assert_file_contains_regex "${ident_file}" '# >>> documentdb-setup managed pg_ident >>>' \
        "pg_ident.conf managed block must be re-created after re-setup"
    assert_eq "$(run_psql "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'documentdb') THEN 'ok' ELSE 'missing' END;")" \
        "ok" "documentdb extension must still be present after restore round-trip"
    assert_eq "$(run_psql "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${USERNAME}') THEN 'ok' ELSE 'missing' END;")" \
        "ok" "Application user must still exist after restore round-trip"
}

# ---------------------------------------------------------------------------
# Phase 9 — Workflow A and B direct-tool coverage
# ---------------------------------------------------------------------------
# Phases 1-8 exercise Workflow C end-to-end (the wizard delegates internally
# to documentdb-tune and documentdb-register-gateway). The direct
# administrator-facing surfaces — `documentdb-tune` (Workflow A extension-only)
# and `documentdb-register-gateway` (Workflow B BYO-gateway) — need coverage
# beyond --help smoke tests. Phase 9 closes that gap by invoking each tool
# directly against the cluster restored
# at the end of Phase 8 and asserting the design's behavioral contract.

verify_workflow_a_documentdb_tune_direct() {
    log "Phase 9a: Workflow A — documentdb-tune direct invocation."

    # --print (read-only) must emit the design's mandatory GUCs.
    local print_out=""
    print_out="$(documentdb-tune --pg-version "${PG_MAJOR}" --print 2>&1)" \
        || fail "documentdb-tune --print failed"
    for required in "shared_preload_libraries" "pg_documentdb_core" "pg_documentdb" \
                    "documentdb.enableBackgroundWorker = true" \
                    "cron.database_name = 'postgres'"; do
        if ! printf '%s\n' "${print_out}" | grep -Fq -- "${required}"; then
            fail "documentdb-tune --print output is missing required setting: ${required}"
        fi
    done

    # --dry-run against the live cluster must NOT modify the file.
    local pre_hash post_hash
    local data_dir="${STANDALONE_DATA_DIR}"
    local conf_file="${data_dir}/postgresql.conf"
    if ! sudo test -f "${conf_file}"; then
        fail "Workflow A: postgresql.conf missing at ${conf_file} (Phase 8 cluster gone?)"
    fi
    pre_hash="$(sudo sha256sum "${conf_file}" | awk '{print $1}')"
    sudo documentdb-tune --pg-version "${PG_MAJOR}" --pgdata "${data_dir}" --dry-run >/dev/null 2>&1 \
        || fail "documentdb-tune --dry-run against live cluster failed"
    post_hash="$(sudo sha256sum "${conf_file}" | awk '{print $1}')"
    [[ "${pre_hash}" == "${post_hash}" ]] \
        || fail "documentdb-tune --dry-run mutated ${conf_file} (pre=${pre_hash} post=${post_hash})"

    # --yes apply must write the managed block, then --restore must strip it
    # exactly back to the pre-apply state.
    sudo documentdb-tune --pg-version "${PG_MAJOR}" --pgdata "${data_dir}" --yes >/dev/null 2>&1 \
        || fail "documentdb-tune --yes apply failed"
    sudo grep -Fq '# >>> documentdb-setup managed configuration >>>' "${conf_file}" \
        || fail "documentdb-tune apply did not insert managed block into ${conf_file}"

    sudo documentdb-tune --pg-version "${PG_MAJOR}" --pgdata "${data_dir}" --restore --yes >/dev/null 2>&1 \
        || fail "documentdb-tune --restore failed"
    if sudo grep -Fq '# >>> documentdb-setup managed configuration >>>' "${conf_file}"; then
        fail "documentdb-tune --restore did not strip the managed block from ${conf_file}"
    fi

    log "Phase 9a: Workflow A passed."
}

verify_workflow_b_documentdb_register_gateway_direct() {
    log "Phase 9b: Workflow B — documentdb-register-gateway direct invocation."

    # Workflow B precondition: extension must be loaded (Phase 4 setup did
    # this); the gateway OS user must exist (postinst of documentdb-gateway
    # did this). Re-tune the cluster directly via documentdb-tune so PG has
    # the right shared_preload_libraries when we reload below.
    local data_dir="${STANDALONE_DATA_DIR}"
    sudo documentdb-tune --pg-version "${PG_MAJOR}" --pgdata "${data_dir}" --yes >/dev/null 2>&1 \
        || fail "Workflow B: documentdb-tune apply failed before register-gateway"

    # Direct register-gateway invocation against the live cluster.
    local reg_log=""
    create_temp_file reg_log "/tmp/documentdb-register-gateway.XXXXXX.log"
    if ! sudo documentdb-register-gateway \
            --pgdata "${data_dir}" \
            --socket-dir "${PG_SOCKET_DIR}" \
            --pg-port "${PG_PORT}" \
            --pg-owner documentdb-local \
            --state-mode greenfield \
            --yes --verbose > "${reg_log}" 2>&1; then
        cat "${reg_log}"
        fail "documentdb-register-gateway --yes failed"
    fi

    # The design (§4.3) promises mode 0640 root:documentdb-gateway on the
    # connection-URL file at the persistent per-major path.
    local secret_file="/var/lib/documentdb-local/${PG_MAJOR}/gateway/pg-url"
    sudo test -f "${secret_file}" \
        || fail "Workflow B: connection-URL file not written at ${secret_file}"
    local mode owner
    mode="$(sudo stat -c '%a' "${secret_file}")"
    owner="$(sudo stat -c '%U:%G' "${secret_file}")"
    [[ "${mode}" == "640" ]] \
        || fail "Workflow B: connection-URL file mode ${mode} != 640 at ${secret_file}"
    [[ "${owner}" == "root:documentdb-gateway" ]] \
        || fail "Workflow B: connection-URL file owner ${owner} != root:documentdb-gateway at ${secret_file}"

    # State file must persist HBA_FILE / IDENT_FILE / SECRET_FILE so
    # --restore can remove exactly the managed blocks this run wrote.
    local state_file="/etc/documentdb/local/${PG_MAJOR}/setup.conf"
    sudo test -f "${state_file}" || fail "Workflow B: state file not written at ${state_file}"
    for required_key in HBA_FILE IDENT_FILE SECRET_FILE; do
        sudo grep -Eq "^${required_key}=" "${state_file}" \
            || fail "Workflow B: state file missing required key ${required_key} (restore-state regression)"
    done

    # --restore must strip the managed blocks and remove the connection file.
    # Pass the SAME cluster-identifying flags the apply above used
    # (--pgdata + --state-mode greenfield). Without them, a no-flag
    # --restore runs autodetect_single_pg_instance, which on a host where
    # the extension package pulled in a distro postgresql-N cluster picks
    # that cluster (e.g. 18/main), flips STATE_MODE to brownfield, and
    # strips the managed block from /etc/postgresql/N/main/pg_hba.conf
    # instead of this stand-alone cluster's pg_hba.conf under --pgdata.
    # Naming --pgdata makes resolve_cluster_paths target the right file and
    # skips autodetect; --state-mode greenfield selects the setup.conf that
    # the apply wrote.
    local restore_log=""
    create_temp_file restore_log "/tmp/documentdb-register-gateway-restore.XXXXXX.log"
    if ! sudo documentdb-register-gateway --restore \
            --pgdata "${data_dir}" \
            --state-mode greenfield \
            --yes > "${restore_log}" 2>&1; then
        cat "${restore_log}"
        fail "documentdb-register-gateway --restore failed"
    fi
    if sudo test -f "${secret_file}"; then
        fail "Workflow B: --restore did not remove the connection-URL file at ${secret_file}"
    fi
    local hba_file="${data_dir}/pg_hba.conf"
    if sudo grep -Fq '# >>> documentdb-setup managed hba >>>' "${hba_file}"; then
        fail "Workflow B: --restore did not strip the managed HBA block from ${hba_file}"
    fi

    # --restore detaches only the gateway registration. It must NOT delete
    # the shared setup.conf: the wizard owns CONFIG_FILE / DATA_DIR /
    # GATEWAY_PORT in that same file, and documentdb-postgresql@N.service
    # gates on ConditionPathExists=/etc/documentdb/local/%i/setup.conf, so a
    # whole-file delete silently stops the private PostgreSQL from starting
    # on the next boot. Assert the split: our keys gone, the wizard's kept.
    sudo test -f "${state_file}" \
        || fail "Workflow B: --restore deleted the shared ${state_file} (must strip only register-gateway-managed keys)"
    for wizard_key in CONFIG_FILE DATA_DIR; do
        sudo grep -Eq "^${wizard_key}=" "${state_file}" \
            || fail "Workflow B: --restore dropped wizard-owned key ${wizard_key} from ${state_file}"
    done
    # Round-9 co-ownership contract (STATE_EXCLUSIVE_KEYS_RE in
    # documentdb-register-gateway.sh): when the wizard's
    # DOCUMENTDB_MANAGED_POSTGRES marker is present — as it is here,
    # because Phase 8 ended with a full wizard re-setup — --restore strips
    # only the keys EXCLUSIVELY owned by register-gateway. The co-owned
    # keys (HBA_FILE / IDENT_FILE, also written by the wizard) must
    # SURVIVE: the wizard's own --restore and the packaged postrm use them
    # to locate the files whose managed blocks they strip, and
    # documentdb-gateway-admin skips state files lacking PG_PORT. (The
    # previous round-7 expectation predated that contract; this suite had
    # not run since, so the stale assertion went unnoticed until the E2E
    # round-1 run.)
    for managed_key in SECRET_FILE GATEWAY_ENV_FILE CLUSTER_NAME TARGET_DB; do
        if sudo grep -Eq "^${managed_key}=" "${state_file}"; then
            fail "Workflow B: --restore left register-gateway-exclusive key ${managed_key} in ${state_file}"
        fi
    done
    for coowned_key in HBA_FILE IDENT_FILE PG_VERSION PG_PORT; do
        sudo grep -Eq "^${coowned_key}=" "${state_file}" \
            || fail "Workflow B: --restore stripped co-owned key ${coowned_key} from ${state_file} (the wizard still needs it — restore key co-ownership regression)"
    done

    # Phase 10 (verify_package_purge_cleanup) runs next and requires the
    # cluster restored to the COMPLETE documentdb-setup state: the legacy
    # env file and the per-major setup.conf must carry CONFIG_FILE /
    # DATA_DIR so the package postrm can locate and strip the managed
    # blocks from postgresql.conf on purge. The direct tools above cannot
    # produce that on their own — register-gateway's record_state only
    # preserves a pre-existing CONFIG_FILE and never writes one — so a bare
    # register-gateway re-apply cannot restore the gateway registration keys
    # --restore just stripped. (--restore now preserves the wizard's
    # CONFIG_FILE/DATA_DIR rather than deleting setup.conf outright, which
    # the assertions above pin down.) Restore the
    # cluster the same way Phase 8 does: a full wizard re-setup (which
    # writes CONFIG_FILE via persist_self_managed_postgres_state first,
    # then has register-gateway preserve it). --no-enable keeps the gateway
    # from (re)starting, which the purge test does not need.
    local resetup_log="" resetup_pw=""
    create_temp_file resetup_log "/tmp/documentdb-setup-phase9-resetup.XXXXXX.log"
    create_temp_file resetup_pw "/tmp/documentdb-pw-phase9-resetup.XXXXXX"
    printf '%s' "${PASSWORD}" > "${resetup_pw}"
    if ! sudo documentdb-setup --username "${USERNAME}" --password-file "${resetup_pw}" \
            --data-dir "${data_dir}" \
            --yes --no-enable --skip-init-data --verbose > "${resetup_log}" 2>&1; then
        cat "${resetup_log}"
        fail "Workflow B: post-test documentdb-setup re-setup failed"
    fi

    log "Phase 9b: Workflow B passed."
}

main() {
    # Precondition: documentdb-setup must be installed. As of the
    # build_gateway_packages.sh orchestrator update that lands with
    # this commit, the test Dockerfile installs all four Track 1
    # packages (extension + gateway + tools + per-major stand-alone),
    # so the command is always on PATH inside the test container. If
    # it ever goes missing, fail loudly with the same diagnostic the
    # earlier SKIP path printed — the failure mode would be a
    # regression in the Dockerfile, not a CI-environment issue.
    if ! command -v documentdb-setup >/dev/null 2>&1; then
        fail "documentdb-setup not found on PATH. Phases 4+ require it. Check that packaging/gateway/test/Dockerfile_deb_gateway_test installs the documentdb-postgresql-tools and documentdb-N DEBs (built via packaging/build_extra_packages.sh)."
    fi

    # Phase 1: Package validation
    verify_package_contents
    verify_package_dependencies
    verify_maintainer_script_behaviour
    verify_help_text_after_scope_reduction
    verify_gateway_utility_flags
    verify_systemd_unit_files

    # Phase 2: Error paths (before any setup)
    verify_error_paths
    verify_removed_flags_rejected
    # The inline-DOCUMENTDB_PG_URL rejection needs only the installed wrapper
    # and the documentdb-gateway user (both present after package install), so
    # run it here in Phase 2 -- a full run reaches it without depending on any
    # setup-stage assertion. Mirrors the RPM entrypoint ordering.
    verify_inline_pg_url_rejected

    # Phase 3: --no-enable (before gateway starts, so no zombie gateway)
    verify_no_enable
    # Phase 4: Primary happy path -- fresh self-managed cluster (starts gateway)
    run_documentdb_setup --skip-init-data
    verify_gateway_configuration
    verify_self_managed_postgres_persistence
    verify_live_cluster_readoption
    verify_postgres_state
    verify_tls_key_permissions
    verify_connection_file_ownership
    verify_gateway_check_connectivity

    # Phase 5: Security assertions (requires running PG from phase 4)
    verify_hba_security

    # Phase 6: Variant tests that only need PG (no gateway interaction)
    verify_admin_password_stdin
    verify_env_var_password
    # The custom-ports probe uses --no-enable against a separate data dir, and
    # the drop-in test below reruns setup back onto the default cluster state.
    verify_custom_ports

    # The drop-in test only needs the new cluster to *initdb and start*; it
    # never goes through the gateway, so the TLS issue that gates
    # verify_custom_ports does not apply. Use a unique port so the new
    # cluster cannot collide with the primary one.
    verify_no_pidfile_drop_in_for_custom_data_dir

    # Phase 7: Gateway CRUD (requires running gateway from phase 4)
    verify_gateway_crud
    verify_sample_data_absent

    # Phase 8: Restore and package lifecycle
    verify_restore_round_trip

    # Phase 9: Workflow A + B direct-tool coverage. Runs after Phase 8 has
    # restored the cluster to a clean state but before package purge, so the
    # cluster + extension +
    # gateway OS user are all still in place.
    verify_workflow_a_documentdb_tune_direct
    verify_workflow_b_documentdb_register_gateway_direct

    # Phase 9c: sample-data load coverage (parity with the RPM suite, which
    # runs `run_documentdb_setup --load-sample-data` + verify_sample_data as
    # the last step before its destructive package-remove test). Phase 7's
    # verify_sample_data_absent already pinned down that --skip-init-data
    # setups load nothing; now re-run the wizard with --load-sample-data --
    # this restarts the gateway (the flag requires one and cannot combine
    # with --no-enable, so it supersedes Phase 9b's --no-enable re-setup) and
    # loads the packaged sample data through mongosh, which the test image
    # installs unconditionally (same as the RPM test image; the wizard itself
    # fails fast if mongosh is missing). Then verify the data through the
    # gateway. Must stay after all absence checks and directly before the
    # destructive purge test.
    run_documentdb_setup --load-sample-data
    verify_sample_data

    verify_package_purge_cleanup
    report_skips
    log "Gateway package clean-install E2E passed."
}

main "$@"
