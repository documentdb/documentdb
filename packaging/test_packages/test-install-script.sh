#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Deterministic behavior tests for packaging/install.sh.
#
# The installer exposes a dry-run-only test mode, so every supported cell,
# every refusal, and the streamed-execution barrier can be checked on a single
# machine without changing the host or requiring nested VMs.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INSTALLER="${REPO_ROOT}/packaging/install.sh"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/documentdb-installer-test.XXXXXX")"
MOCK_BIN="${WORK_DIR}/bin"
MUTATION_LOG="${WORK_DIR}/mutations.log"
PASS=0
FAIL=0
LAST_OUTPUT=""
INSTALLER_ENV=()

trap 'rm -rf "${WORK_DIR}"' EXIT

# Any command that could change a host is replaced by a logging stub, so the
# suite can assert that dry runs and truncated scripts execute nothing.
setup_mocks() {
    mkdir -p "${MOCK_BIN}"
    local command
    for command in sudo apt-get dnf rpm systemctl subscription-manager \
        documentdb-setup gpg curl; do
        cat > "${MOCK_BIN}/${command}" <<'MOCK'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "${DOCUMENTDB_TEST_MUTATION_LOG}"
exit 0
MOCK
        chmod 0755 "${MOCK_BIN}/${command}"
    done
    : > "${MUTATION_LOG}"
}

ok() {
    PASS=$((PASS + 1))
}

bad() {
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$1" >&2
    if [[ -n "${2:-}" ]]; then
        printf '%s\n' "$2" | sed 's/^/    /' >&2
    fi
}

new_root() {
    local id="$1" version="$2" root
    root="$(mktemp -d "${WORK_DIR}/root.XXXXXX")"
    mkdir -p "${root}/etc/apt/sources.list.d" "${root}/etc/yum.repos.d" \
        "${root}/run/systemd/system"
    printf 'ID=%s\nVERSION_ID="%s"\n' "${id}" "${version}" \
        > "${root}/etc/os-release"
    printf '%s\n' "${root}"
}

write_state_file() {
    local root="$1" pg="$2" name="$3"
    mkdir -p "${root}/etc/documentdb/local/${pg}"
    printf 'GATEWAY_PORT=10260\n' > "${root}/etc/documentdb/local/${pg}/${name}"
}

installer_env() {
    INSTALLER_ENV=("$@")
}

run_installer() {
    local root="$1"
    shift
    env PATH="${MOCK_BIN}:${PATH}" \
        DOCUMENTDB_TEST_MUTATION_LOG="${MUTATION_LOG}" \
        DOCUMENTDB_INSTALLER_TESTING=true \
        DOCUMENTDB_INSTALLER_TEST_ROOT="${root}" \
        ${INSTALLER_ENV[@]+"${INSTALLER_ENV[@]}"} \
        sh "${INSTALLER}" --dry-run "$@" 2>&1
}

expect_success() {
    local name="$1" status=0
    shift
    LAST_OUTPUT="$("$@" 2>&1)" || status=$?
    if ((status == 0)); then
        ok
        return 0
    fi
    bad "${name} (exit ${status})" "${LAST_OUTPUT}"
    return 1
}

expect_failure() {
    local name="$1" expected="$2" status=0
    shift 2
    LAST_OUTPUT="$("$@" 2>&1)" || status=$?
    if ((status == 0)); then
        bad "${name} (unexpected success)" "${LAST_OUTPUT}"
        return 1
    fi
    assert_has "${name}" "${expected}"
}

assert_has() {
    if [[ "${LAST_OUTPUT}" == *"$2"* ]]; then
        ok
        return 0
    fi
    bad "$1 (missing: $2)" "${LAST_OUTPUT}"
    return 1
}

assert_lacks() {
    if [[ "${LAST_OUTPUT}" != *"$2"* ]]; then
        ok
        return 0
    fi
    bad "$1 (unexpected: $2)" "${LAST_OUTPUT}"
    return 1
}

assert_no_mutation() {
    if [[ -s "${MUTATION_LOG}" ]]; then
        bad "$1 executed a real command" "$(cat "${MUTATION_LOG}")"
        : > "${MUTATION_LOG}"
        return 1
    fi
    ok
}

snapshot_tree() {
    find "$1" -mindepth 1 -printf '%P %m %s\n' 2>/dev/null | LC_ALL=C sort
}

section() {
    printf '\n== %s ==\n' "$1"
}

# --------------------------------------------------------------------------
# Supported cells: distribution, architecture, and PostgreSQL major routing.
# --------------------------------------------------------------------------
test_supported_matrix() {
    section "supported hosts"
    local id version arch native pg display expected_arch manager marker root
    while IFS='|' read -r id version arch native pg display expected_arch \
        manager marker; do
        [[ -n "${id}" ]] || continue
        root="$(new_root "${id}" "${version}")"
        installer_env DOCUMENTDB_INSTALLER_TEST_UNAME_M="${arch}" \
            DOCUMENTDB_INSTALLER_TEST_NATIVE_ARCH="${native}" \
            DOCUMENTDB_INSTALLER_TEST_RHEL_REPOLIST="codeready-builder-for-rhel-9-${native}-rhui-rpms CRB"
        expect_success "${id} ${version} ${arch} pg${pg}" \
            run_installer "${root}" --pg-major "${pg}" || continue
        assert_has "${id} plan reports ${display}" "Operating system: ${display}"
        assert_has "${id} plan reports ${expected_arch}" "Architecture:     ${expected_arch}"
        assert_has "${id} plan reports ${manager}" "Package manager:  ${manager}"
        assert_has "${id} installs documentdb-${pg}" "${marker}"
        assert_has "${id} hands off to setup" \
            "documentdb-setup --yes --pg-version ${pg} --use-new-postgres-instance --admin-user admin"
        assert_has "${id} reports the dry run" "Dry run complete"
    done <<'CELLS'
ubuntu|24.04|x86_64|amd64|18|Ubuntu 24.04 LTS|amd64|apt|apt-get -o DPkg::Lock::Timeout=120 install -y documentdb-18
ubuntu|24.04|aarch64|arm64|17|Ubuntu 24.04 LTS|arm64|apt|apt-get -o DPkg::Lock::Timeout=120 install -y documentdb-17
rocky|9.4|x86_64|x86_64|18|Rocky Linux 9|x86_64|dnf|dnf install -y documentdb-18
almalinux|9|aarch64|aarch64|17|AlmaLinux 9|aarch64|dnf|dnf install -y documentdb-17
centos|9.20240115|x86_64|x86_64|18|CentOS Stream 9|x86_64|dnf|dnf install -y epel-next-release
rhel|9.4|aarch64|aarch64|18|Red Hat Enterprise Linux 9|aarch64|dnf|dnf config-manager --set-enabled codeready-builder-for-rhel-9-aarch64-rhui-rpms
CELLS
    installer_env

    # Architecture-specific repository material must follow the host.
    root="$(new_root ubuntu 24.04)"
    installer_env DOCUMENTDB_INSTALLER_TEST_UNAME_M=aarch64 \
        DOCUMENTDB_INSTALLER_TEST_NATIVE_ARCH=arm64
    expect_success "arm64 apt source" run_installer "${root}"
    assert_has "arm64 apt source pins arch" "deb [arch=arm64 "
    root="$(new_root rocky 9.5)"
    installer_env DOCUMENTDB_INSTALLER_TEST_UNAME_M=aarch64 \
        DOCUMENTDB_INSTALLER_TEST_NATIVE_ARCH=aarch64
    expect_success "aarch64 pgdg rpm" run_installer "${root}"
    assert_has "aarch64 uses the aarch64 PGDG key" "PGDG-RPM-GPG-KEY-AARCH64-RHEL"
    assert_has "aarch64 uses the aarch64 repository rpm" "EL-9-aarch64"
    installer_env

    # Entitled RHEL hosts enable CodeReady Builder through subscription-manager.
    root="$(new_root rhel 9.4)"
    mkdir -p "${root}/etc/pki/consumer"
    printf 'certificate\n' > "${root}/etc/pki/consumer/cert.pem"
    expect_success "entitled RHEL" run_installer "${root}"
    assert_has "entitled RHEL uses subscription-manager" \
        "subscription-manager repos --enable codeready-builder-for-rhel-9-x86_64-rpms"

    # PGDG drops per-minor paths for older EL9 minors; Stream has no minor.
    root="$(new_root rocky 9.3)"
    expect_success "rocky 9.3" run_installer "${root}"
    assert_has "rocky 9.3 plans the PGDG major-path fallback" \
        "Would switch PGDG to its rhel-9 repository path if rhel-9.3 is not published."
    root="$(new_root centos 9)"
    expect_success "centos stream 9" run_installer "${root}"
    assert_has "stream always plans the PGDG major path" \
        "Would switch PGDG to its rhel-9 repository path for CentOS Stream."
}

# --------------------------------------------------------------------------
# Hosts outside the supported matrix are refused before anything is planned.
# --------------------------------------------------------------------------
test_unsupported_hosts() {
    section "unsupported hosts"
    local name id version expected root
    while IFS='|' read -r name id version expected; do
        [[ -n "${name}" ]] || continue
        root="$(new_root "${id}" "${version}")"
        expect_failure "${name}" "${expected}" run_installer "${root}"
    done <<'HOSTS'
Debian 12|debian|12|Unsupported Linux distribution
Ubuntu 22.04|ubuntu|22.04|Unsupported Ubuntu release
Ubuntu 26.04|ubuntu|26.04|Unsupported Ubuntu release
RHEL 8|rhel|8.9|Only the 9 series is supported
Rocky 10|rocky|10.0|Only the 9 series is supported
Fedora 41|fedora|41|Unsupported Linux distribution
HOSTS

    local probe expected
    while IFS='|' read -r name probe expected; do
        [[ -n "${name}" ]] || continue
        root="$(new_root ubuntu 24.04)"
        installer_env "${probe}"
        expect_failure "${name}" "${expected}" run_installer "${root}"
        installer_env
    done <<'PROBES'
non-Linux kernel|DOCUMENTDB_INSTALLER_TEST_UNAME_S=Darwin|supports Linux only
WSL kernel|DOCUMENTDB_INSTALLER_TEST_KERNEL_RELEASE=5.15.0-microsoft-standard-WSL2|Windows Subsystem for Linux is not supported
unsupported CPU|DOCUMENTDB_INSTALLER_TEST_UNAME_M=riscv64|Unsupported CPU architecture
chroot|DOCUMENTDB_INSTALLER_TEST_CHROOT_VIRT=chroot|Chroot environment 'chroot' is not supported
systemd offline|DOCUMENTDB_INSTALLER_TEST_SYSTEMD_STATE=offline|systemd is not ready
foreign package arch|DOCUMENTDB_INSTALLER_TEST_NATIVE_ARCH=arm64|does not match the native package architecture
missing package tool|DOCUMENTDB_INSTALLER_TEST_MISSING_COMMAND=dpkg-query|Required command 'dpkg-query' is not available
PROBES

    root="$(new_root ubuntu 24.04)"
    installer_env DOCUMENTDB_INSTALLER_TEST_CONTAINER_VIRT=docker \
        DOCUMENTDB_INSTALLER_TEST_KERNEL_RELEASE=5.15.0-microsoft-standard-WSL2
    expect_success "systemd-capable container on a WSL Docker host" \
        run_installer "${root}"
    installer_env

    root="$(new_root ubuntu 24.04)"
    rmdir "${root}/run/systemd/system"
    expect_failure "no running systemd" "A running systemd host is required" \
        run_installer "${root}"

    installer_env DOCUMENTDB_INSTALLER_TEST_MISSING_COMMAND=systemctl
    expect_success "--packages-only without systemd" \
        run_installer "${root}" --packages-only
    installer_env

    root="$(new_root rocky 9.4)"
    installer_env DOCUMENTDB_INSTALLER_TEST_MISSING_COMMAND=dnf
    expect_failure "missing dnf" "Required command 'dnf' is not available" \
        run_installer "${root}"
    installer_env

    root="$(new_root rhel 9.4)"
    expect_failure "unregistered RHEL" \
        "no RHUI CodeReady Builder repository was found" run_installer "${root}"
}

# --------------------------------------------------------------------------
# Argument parsing and canonical administrator/port validation.
# --------------------------------------------------------------------------
test_arguments() {
    section "argument parsing"
    local root name expected
    root="$(new_root ubuntu 24.04)"

    expect_success "--help" env sh "${INSTALLER}" --help
    assert_has "--help prints usage" "Usage: install.sh [OPTIONS]"
    assert_has "--help documents the supported flags" "--accept-external-listen"

    local args
    while IFS='|' read -r name expected args; do
        [[ -n "${name}" ]] || continue
        # shellcheck disable=SC2086 # the table intentionally supplies words.
        expect_failure "${name}" "${expected}" run_installer "${root}" ${args}
    done <<'ARGS'
unknown option|Unknown option: --bogus|--bogus
positional argument|Unexpected positional arguments|-- extra
missing pg-major value|--pg-major requires a value|--pg-major
missing release value|--version requires a value|--version
stable release tag|--version must be stable or an RC tag|--version v0.117-0
moving release name|--version must be stable or an RC tag|--version latest
RC suffix|--version must be stable or an RC tag|--version v1.0-RC1x
RC without minor|--version must be stable or an RC tag|--version v1-RC1
RC non-numeric version|--version must be stable or an RC tag|--version v1garbage-RC1
release path traversal|--version must be stable or an RC tag|--version ../latest
missing admin-user value|--admin-user requires a value|--admin-user
missing password-file value|--admin-password-file requires a value|--admin-password-file
missing listen-port value|--listen-port requires a value|--listen-port
unsupported pg-major|--pg-major must be 17 or 18|--pg-major 16
conflicting modes|--packages-only and --no-enable cannot be combined|--packages-only --no-enable
unattended without password|--yes requires --admin-password-file|--yes
unattended without listener acknowledgement|--yes requires --accept-external-listen|--yes --admin-password-file /dev/null
ARGS

    section "administrator and port validation"
    local value
    while IFS='|' read -r value expected; do
        [[ -n "${value}" ]] || continue
        expect_failure "--admin-user '${value}'" "${expected}" \
            run_installer "${root}" --admin-user "${value}"
    done <<ADMINS
1admin|must use letters, digits
admin user|must use letters, digits
admin;drop|must use letters, digits
-admin|must use letters, digits
$(printf 'a%.0s' {1..64})|must be at most 63 bytes
documentdb_admin|reserved prefix 'documentdb'
CitusAdmin|reserved prefix 'citus'
PGuser|reserved prefix 'pg'
internal_role_x|reserved prefix 'internal_role'
ADMINS
    expect_failure "empty --admin-user" "cannot be empty" \
        run_installer "${root}" --admin-user ""

    while IFS='|' read -r value expected; do
        [[ -n "${value}" ]] || continue
        expect_failure "--listen-port '${value}'" "${expected}" \
            run_installer "${root}" --listen-port "${value}"
    done <<'PORTS'
80|must be from 1024 through 65535
1023|must be from 1024 through 65535
65536|must be from 1024 through 65535
099999|canonical decimal notation
010260|canonical decimal notation
0|canonical decimal notation
abc|must be a number
12a4|must be a number
 10260|must be a number
PORTS

    # Canonical values on the boundaries stay accepted.
    for value in 1024 10260 65535; do
        expect_success "--listen-port ${value}" \
            run_installer "${root}" --listen-port "${value}"
        assert_has "--listen-port ${value} reaches the plan" \
            "Gateway port:     ${value}"
    done
    expect_success "63-byte --admin-user" run_installer "${root}" \
        --admin-user "$(printf 'a%.0s' {1..63})"
}

test_release_selection() {
    section "explicit release selection"
    local root id version arch native pg mode
    for id in ubuntu rocky centos; do
        case "${id}" in
            ubuntu) version=24.04 ;;
            rocky) version=9.4 ;;
            centos) version=9 ;;
        esac
        for arch in x86_64 aarch64; do
            native="${arch}"
            if [[ "${id}" == ubuntu ]]; then
                native=amd64
                [[ "${arch}" != aarch64 ]] || native=arm64
            fi
            for pg in 17 18; do
                root="$(new_root "${id}" "${version}")"
                installer_env DOCUMENTDB_INSTALLER_TEST_UNAME_M="${arch}" \
                    DOCUMENTDB_INSTALLER_TEST_NATIVE_ARCH="${native}"
                expect_success "${id} ${arch} pg${pg} RC selection" \
                    run_installer "${root}" --version v1.0-RC1 --pg-major "${pg}"
                assert_has "RC warning" "No RC maintenance or supported upgrades."
                assert_has "RC URL" "releases/download/v1.0-RC1/SHA256SUMS"
                assert_lacks "RC never subscribes to stable repository" "https://documentdb.io/"
                assert_lacks "RC does not request stable package" "install -y documentdb-${pg}"
                assert_has "RC runs setup" "documentdb-setup --yes --pg-version ${pg}"
                assert_no_mutation "RC dry run"
                if [[ "${id}" == centos ]]; then
                    assert_has "Stream RC uses the PGDG major path" \
                        "Would switch PGDG to its rhel-9 repository path for CentOS Stream."
                fi
            done
        done
    done
    installer_env
    root="$(new_root ubuntu 24.04)"
    expect_success "explicit stable" run_installer "${root}" --version stable
    assert_has "stable transaction unchanged" "install -y documentdb-18"
    assert_lacks "stable never downloads RC" "v1.0-RC1"
    for mode in --packages-only --no-enable; do
        expect_success "RC ${mode}" run_installer "${root}" --version v1.0-RC1 "${mode}"
        if [[ "${mode}" == --packages-only ]]; then
            assert_lacks "RC packages-only skips setup" "sudo documentdb-setup"
        else
            assert_has "RC no-enable reaches setup" "--listen-port 10260 --no-enable"
        fi
    done
    local package
    for package in documentdb-18 documentdb-common postgresql18-documentdb postgresql-18-documentdb; do
        installer_env DOCUMENTDB_INSTALLER_TEST_EXISTING_PACKAGES="${package}"
        expect_failure "RC refuses installed ${package}" "Release candidates require a clean host" \
            run_installer "${root}" --version v1.0-RC1 --packages-only
    done
    installer_env
    write_state_file "${root}" 17 setup.conf
    expect_failure "RC refuses other PG state" "Release candidates require a clean host" \
        run_installer "${root}" --version v1.0-RC1
    root="$(new_root ubuntu 24.04)"
    mkdir -p "${root}/var/lib/documentdb-local/17/data"
    expect_failure "RC refuses other PG data" "Release candidates require a clean host" \
        run_installer "${root}" --version v1.0-RC1
    root="$(new_root ubuntu 24.04)"
    mkdir -p "${root}/etc/documentdb/gateway"
    printf '{}\n' > "${root}/etc/documentdb/gateway/SetupConfiguration.json"
    expect_failure "RC refuses residual gateway configuration" "Release candidates require a clean host" \
        run_installer "${root}" --version v1.0-RC1
    root="$(new_root ubuntu 24.04)"
    mkdir -p "${root}/var/lib/documentdb-gateway/tls"
    expect_failure "RC refuses residual gateway data" "Release candidates require a clean host" \
        run_installer "${root}" --version v1.0-RC1
    root="$(new_root ubuntu 24.04)"
    mkdir -p "${root}/etc/documentdb"
    printf 'v1.0-RC1\n' > "${root}/etc/documentdb/installer-release-candidate"
    for version in stable v1.0-RC1; do
        expect_failure "${version} refuses recorded RC without packages or data" \
            "cannot upgrade or adopt an RC" run_installer "${root}" --version "${version}"
    done
    root="$(new_root ubuntu 24.04)"
    printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/documentdb-archive-keyring.gpg] https://documentdb.io/deb stable ubuntu24\n' \
        > "${root}/etc/apt/sources.list.d/documentdb.list"
    expect_failure "RC refuses preconfigured stable repository" "without a DocumentDB stable repository" \
        run_installer "${root}" --version v1.0-RC1
}

test_release_package_states() {
    section "RC package states"
    local library="${WORK_DIR}/state-library.sh" bin="${WORK_DIR}/dpkg-bin" state
    sed '/^# BEGIN EXECUTION BARRIER$/,$d' "${INSTALLER}" > "${library}"
    mkdir -p "${bin}"
    cat > "${bin}/dpkg-query" <<'MOCK'
#!/bin/sh
printf '%s  documentdb-postgresql-tools\n' "${PACKAGE_STATE}"
MOCK
    chmod 0755 "${bin}/dpkg-query"
    for state in rc iU iF; do
        # shellcheck disable=SC2016 # expanded by the inner shell.
        expect_success "${state} listing" env PATH="${bin}:${PATH}" PACKAGE_STATE="${state}" sh -c '
            . "$1"
            PACKAGE_FAMILY=apt
            printf "installed=[%s] any=[%s]\n" "$(list_documentdb_packages)" "$(list_documentdb_packages "^.[^n]")"
        ' _ "${library}"
        assert_has "stable ignores ${state}" "installed=[]"
        assert_has "RC sees ${state}" "any=[documentdb-postgresql-tools]"
    done
}

test_release_checksums() {
    section "release download verification"
    local library="${WORK_DIR}/release-library.sh" fixture="${WORK_DIR}/release-fixture"
    local runner="${WORK_DIR}/release-runner.sh" name mode
    sed '/^# BEGIN EXECUTION BARRIER$/,$d' "${INSTALLER}" > "${library}"
    mkdir -p "${fixture}"
    # Every RC1 asset, so selection must pick this host's five among them.
    for name in ubuntu24.04-documentdb{,-17,-18,-common,-postgresql-tools}_1.0.0_all.deb \
        ubuntu24.04-documentdb-gateway_1.0.0_{amd64,arm64}.deb \
        ubuntu24.04-postgresql-{17,18}-documentdb_1.0-0_{amd64,arm64}.deb \
        documentdb{,-17,-18,-common,-postgresql-tools}-1.0.0-1.noarch.rpm \
        documentdb-gateway-1.0.0-1.el9.{x86_64,aarch64}.rpm \
        rhel9-postgresql{17,18}-documentdb-1.0.0-1.el9.{x86_64,aarch64}.rpm; do
        printf 'fixture for %s\n' "${name}" > "${fixture}/${name}"
    done
    (cd "${fixture}" && sha256sum ./*.deb ./*.rpm | sed 's|  ./|  |' > SHA256SUMS)
    cat > "${runner}" <<'RUNNER'
#!/bin/sh
set -eu
. "$1"
fixture="$2"
mode="$3"
RELEASE_VERSION=v1.0-RC1
PACKAGE_FAMILY="${RELEASE_TEST_FAMILY:-apt}"
APT_ARCH=arm64
RPM_ARCH=x86_64
PG_MAJOR="${RELEASE_TEST_PG:-18}"
TMP_DIR="$(mktemp -d)"
strict_curl() {
    name="${1##*/}"
    [ "${mode}:${name}" != "missing:ubuntu24.04-documentdb-common_1.0.0_all.deb" ] || return 22
    [ "${mode}:${name}" != "missing-manifest:SHA256SUMS" ] || return 22
    cp "${fixture}/${name}" "$2"
    if [ "${mode}" = corrupt ] && [ "${name}" != SHA256SUMS ]; then
        printf 'corrupt\n' >> "$2"
    elif [ "${mode}:${name}" = manifest:SHA256SUMS ]; then
        printf '\n' >> "$2"
    fi
}
apt_get() {
    printf 'TRANSACTION'
    for argument in "$@"; do printf ' <%s>' "${argument##*/}"; done
    printf '\n'
}
run_root_no_stdin() {
    apt_get "$@"
}
write_root_file() {
    printf 'RC-MARKER %s %s %s\n' "$1" "$2" "$3"
}
install_release_packages
RUNNER
    expect_success "verified selected packages" sh "${runner}" "${library}" "${fixture}" good
    assert_has "verified packages reach one transaction" "TRANSACTION <install> <-y>"
    assert_has "RC origin recorded before package installation" \
        $'RC-MARKER /etc/documentdb/installer-release-candidate 0644 v1.0-RC1\nTRANSACTION'
    assert_has "apt arm64 pg18 selects exactly its packages" \
        "<install> <-y> <ubuntu24.04-documentdb-18_1.0.0_all.deb> <ubuntu24.04-documentdb-common_1.0.0_all.deb> <ubuntu24.04-documentdb-postgresql-tools_1.0.0_all.deb> <ubuntu24.04-documentdb-gateway_1.0.0_arm64.deb> <ubuntu24.04-postgresql-18-documentdb_1.0-0_arm64.deb>"
    expect_success "rpm x86_64 pg17 selection" env RELEASE_TEST_FAMILY=rpm RELEASE_TEST_PG=17 \
        sh "${runner}" "${library}" "${fixture}" good
    assert_has "rpm x86_64 pg17 selects exactly its packages" \
        "<install> <-y> <documentdb-17-1.0.0-1.noarch.rpm> <documentdb-common-1.0.0-1.noarch.rpm> <documentdb-postgresql-tools-1.0.0-1.noarch.rpm> <documentdb-gateway-1.0.0-1.el9.x86_64.rpm> <rhel9-postgresql17-documentdb-1.0.0-1.el9.x86_64.rpm>"
    expect_success "regenerated manifest formatting is accepted" \
        sh "${runner}" "${library}" "${fixture}" manifest
    assert_has "regenerated manifest still verifies packages" "TRANSACTION <install> <-y>"
    for mode in missing corrupt missing-manifest; do
        case "${mode}" in
            missing|missing-manifest) name="Cannot download" ;;
            corrupt) name="Checksum verification failed" ;;
        esac
        expect_failure "${mode} release download" "${name}" \
            sh "${runner}" "${library}" "${fixture}" "${mode}"
        assert_lacks "${mode} never installs packages or falls back" "TRANSACTION"
        assert_lacks "${mode} does not record an RC installation" "RC-MARKER"
    done
    printf 'rebuilt payload\n' >> "${fixture}/ubuntu24.04-documentdb-common_1.0.0_all.deb"
    expect_failure "rebuilt package with stale checksum" "Checksum verification failed" \
        sh "${runner}" "${library}" "${fixture}" good
    assert_lacks "stale checksum never installs" "TRANSACTION"
    (cd "${fixture}" && sha256sum ./*.deb ./*.rpm | sed 's|  ./|  |' > SHA256SUMS)
    expect_success "rebuilt package with updated release checksums" \
        sh "${runner}" "${library}" "${fixture}" good
    assert_has "rebuilt package reaches the transaction" "TRANSACTION <install> <-y>"
    grep documentdb-common_ "${fixture}/SHA256SUMS" >> "${fixture}/duplicate-sum"
    cat "${fixture}/duplicate-sum" >> "${fixture}/SHA256SUMS"
    expect_failure "duplicate selected-package checksum" "must publish exactly one package" \
        sh "${runner}" "${library}" "${fixture}" good
    assert_lacks "duplicate checksum never installs" "TRANSACTION"
    (cd "${fixture}" && sha256sum ./*.deb ./*.rpm | sed 's|  ./|  |' > SHA256SUMS)
    sed '/ubuntu24.04-documentdb-common_/d' "${fixture}/SHA256SUMS" > "${fixture}/missing-sums"
    cp "${fixture}/missing-sums" "${fixture}/SHA256SUMS"
    expect_failure "missing asset checksum" "must publish exactly one package" \
        sh "${runner}" "${library}" "${fixture}" good
    assert_lacks "missing checksum never installs" "TRANSACTION"
    # A later RC with another version spelling needs no installer change.
    for name in ubuntu24.04-documentdb-{18,common,postgresql-tools}_1.1.0~rc2_all.deb \
        ubuntu24.04-documentdb-gateway_1.1.0~rc2_arm64.deb \
        ubuntu24.04-postgresql-18-documentdb_1.1-0~rc2_arm64.deb; do
        printf 'fixture for %s\n' "${name}" > "${fixture}/${name}"
    done
    (cd "${fixture}" && sha256sum ./*1.1*.deb | sed 's|  ./|  |' > SHA256SUMS)
    expect_success "future RC version spelling" sh "${runner}" "${library}" "${fixture}" good
    assert_has "future RC extension selected" "<ubuntu24.04-postgresql-18-documentdb_1.1-0~rc2_arm64.deb>"
}

# --------------------------------------------------------------------------
# Derived state: what is installed and what documentdb-setup already owns.
# --------------------------------------------------------------------------
test_derived_state() {
    section "derived state"
    local root package_library package_names
    local setup_call="documentdb-setup --yes --pg-version 18 --use-new-postgres-instance"
    local status_call="documentdb-setup --status --pg-version 18"
    local package_call="apt-get -o DPkg::Lock::Timeout=120 install -y documentdb-18"

    root="$(new_root ubuntu 24.04)"
    expect_success "clean host" run_installer "${root}"
    assert_has "clean host installs the package" "${package_call}"
    assert_has "clean host runs setup" "${setup_call}"
    assert_has "clean host plan marks the package missing" \
        "documentdb-18 (to install)"

    root="$(new_root ubuntu 24.04)"
    installer_env DOCUMENTDB_INSTALLER_TEST_EXISTING_PACKAGES=$'documentdb-18\ndocumentdb-common'
    expect_success "package installed without setup state" run_installer "${root}"
    assert_lacks "installed package is not reinstalled" "${package_call}"
    assert_has "installed package still runs setup" "${setup_call}"
    assert_has "installed package is reported" \
        "Reusing the installed documentdb-18 package"

    write_state_file "${root}" 18 setup.conf
    expect_success "configured instance" run_installer "${root}"
    assert_lacks "configured instance never reruns setup" "${setup_call}"
    assert_has "configured instance reports status" "${status_call}"
    assert_has "configured instance keeps credentials" \
        "existing credentials unchanged"
    expect_success "configured instance ignores --admin-user" \
        run_installer "${root}" --admin-user other
    assert_has "configured instance warns about --admin-user" \
        "--admin-user is ignored"
    installer_env

    root="$(new_root ubuntu 24.04)"
    write_state_file "${root}" 18 setup.conf
    expect_failure "setup state without its package" \
        "describes a configured instance, but documentdb-18 is not installed" \
        run_installer "${root}"

    root="$(new_root ubuntu 24.04)"
    installer_env DOCUMENTDB_INSTALLER_TEST_EXISTING_PACKAGES=documentdb-17
    expect_failure "other stand-alone major installed" \
        "packages for PostgreSQL 17 are installed" run_installer "${root}"
    installer_env

    # RPM inventory must request package names rather than full NVRA strings.
    # Otherwise the documentdb meta package version is misread as PG major 0.
    package_library="${WORK_DIR}/installer-library.sh"
    sed '/^# BEGIN EXECUTION BARRIER$/,$d' "${INSTALLER}" > "${package_library}"
    package_names="$(
        bash -c '
            source "$1"
            TESTING=false
            PACKAGE_FAMILY=rpm
            rpm() {
                if [[ "$1" == "-qa" && "$2" == "--qf" &&
                      "$3" == "%{NAME}\\n" ]]; then
                    printf "%s\n" documentdb documentdb-18 documentdb-common
                else
                    printf "%s\n" \
                        documentdb-0.116.0-1.noarch \
                        documentdb-18-0.116.0-1.noarch \
                        documentdb-common-0.116.0-1.noarch
                fi
            }
            list_documentdb_packages
        ' bash "${package_library}"
    )"
    if [[ "${package_names}" == $'documentdb\ndocumentdb-18\ndocumentdb-common' ]]; then
        ok
    else
        bad "RPM package inventory did not normalize to package names" "${package_names}"
    fi

    root="$(new_root ubuntu 24.04)"
    write_state_file "${root}" 17 setup.conf
    expect_failure "other stand-alone major configured" \
        "Another DocumentDB instance is already configured" run_installer "${root}"

    root="$(new_root ubuntu 24.04)"
    mkdir -p "${root}/var/lib/documentdb-local/18/data"
    touch "${root}/var/lib/documentdb-local/18/data/PG_VERSION"
    expect_failure "residual data without configuration" \
        "Residual data exists under /var/lib/documentdb-local/18" \
        run_installer "${root}"
}

test_brownfield_refusal() {
    section "brownfield refusal"
    local root
    root="$(new_root ubuntu 24.04)"
    write_state_file "${root}" 18 brownfield.conf
    installer_env DOCUMENTDB_INSTALLER_TEST_EXISTING_PACKAGES=documentdb-18
    expect_failure "brownfield instance is refused" \
        "configured against an existing PostgreSQL server" run_installer "${root}"
    assert_has "brownfield refusal points at the existing tools" \
        "documentdb-setup and documentdb-gateway-admin"
    expect_failure "brownfield refusal also applies to --packages-only" \
        "configured against an existing PostgreSQL server" \
        run_installer "${root}" --packages-only
    installer_env
}

# --------------------------------------------------------------------------
# Mode flags: --packages-only and --no-enable.
# --------------------------------------------------------------------------
test_mode_flags() {
    section "mode flags"
    local root
    root="$(new_root ubuntu 24.04)"
    expect_success "--packages-only" run_installer "${root}" --packages-only
    assert_has "--packages-only installs packages" \
        "apt-get -o DPkg::Lock::Timeout=120 install -y documentdb-18"
    assert_lacks "--packages-only never runs setup" "sudo documentdb-setup"
    assert_has "--packages-only says setup will not run" \
        "packages only; documentdb-setup will not run"

    rmdir "${root}/run/systemd/system"
    installer_env DOCUMENTDB_INSTALLER_TEST_MISSING_COMMAND=systemctl
    expect_success "--packages-only skips service capability checks" \
        run_installer "${root}" --packages-only
    installer_env

    installer_env DOCUMENTDB_INSTALLER_TEST_EXISTING_PACKAGES=documentdb-18
    write_state_file "${root}" 18 setup.conf
    expect_success "--packages-only with a configured instance" \
        run_installer "${root}" --packages-only
    assert_lacks "--packages-only never health-checks setup" \
        "sudo documentdb-setup --status"
    installer_env

    root="$(new_root ubuntu 24.04)"
    expect_success "--no-enable" run_installer "${root}" --no-enable
    assert_has "--no-enable is forwarded to setup" \
        "--listen-port 10260 --no-enable"
    assert_lacks "--no-enable skips the status call" \
        "documentdb-setup --status"
    assert_has "--no-enable is described in the plan" "(configured, not enabled)"

    expect_success "default run enables the instance" run_installer "${root}"
    assert_lacks "default run does not pass --no-enable" "--no-enable"
    assert_has "default run checks status after setup" \
        "documentdb-setup --status --pg-version 18"

    expect_success "--admin-user and --listen-port reach setup" \
        run_installer "${root}" --admin-user dbadmin --listen-port 27019
    assert_has "setup receives the requested identity" \
        "--admin-user dbadmin --admin-password-file '<temporary-password-file>' --listen-port 27019"
}

# --------------------------------------------------------------------------
# Repository configuration is reused only when it is exactly ours.
# --------------------------------------------------------------------------
test_repositories() {
    section "repository conflicts"
    local root name id version relative content expected
    while IFS='|' read -r name id version relative content expected; do
        [[ -n "${name}" ]] || continue
        root="$(new_root "${id}" "${version}")"
        mkdir -p "$(dirname "${root}/${relative}")"
        printf '%b\n' "${content}" > "${root}/${relative}"
        expect_failure "${name}" "${expected}" run_installer "${root}"
    done <<'REPOS'
foreign PGDG apt source|ubuntu|24.04|etc/apt/sources.list|deb http://apt.postgresql.org/pub/repos/apt noble-pgdg main|Conflicting PGDG repository configuration
rewritten pgdg.list|ubuntu|24.04|etc/apt/sources.list.d/pgdg.list|deb https://apt.postgresql.org/pub/repos/apt jammy-pgdg main|Conflicting PGDG repository configuration
foreign DocumentDB apt source|ubuntu|24.04|etc/apt/sources.list.d/extra.sources|URIs: https://documentdb.io/deb|Conflicting DocumentDB repository configuration
unrelated documentdb.list|ubuntu|24.04|etc/apt/sources.list.d/documentdb.list|deb https://example.invalid/deb stable main|Refusing to overwrite unrelated repository file
PGDG rpm outside its package file|rocky|9.4|etc/yum.repos.d/custom.repo|[pgdg]\nbaseurl=https://download.postgresql.org/pub/repos/yum/18/redhat/rhel-9-x86_64|canonical pgdg-redhat-all.repo
rewritten documentdb.repo|rocky|9.4|etc/yum.repos.d/documentdb.repo|[documentdb]\nbaseurl=https://documentdb.io/rpm/rhel9\ngpgcheck=0|Conflicting DocumentDB repository configuration
unrelated documentdb.repo|rocky|9.4|etc/yum.repos.d/documentdb.repo|[other]\nbaseurl=https://example.invalid/rpm|Refusing to overwrite unrelated repository file
REPOS

    section "repository reuse"
    root="$(new_root ubuntu 24.04)"
    printf 'deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt noble-pgdg main\n' \
        > "${root}/etc/apt/sources.list.d/pgdg.list"
    printf '# managed by the installer\ndeb [arch=amd64 signed-by=/usr/share/keyrings/documentdb-archive-keyring.gpg] https://documentdb.io/deb stable ubuntu24\n' \
        > "${root}/etc/apt/sources.list.d/documentdb.list"
    expect_success "exact apt sources are reused" run_installer "${root}"
    assert_has "exact PGDG source is reused" \
        "Reusing the existing PGDG APT repository configuration"
    assert_has "exact DocumentDB source is reused" \
        "Reusing the existing DocumentDB APT repository configuration"
    assert_lacks "reused sources are not rewritten" "Would write ${root}/etc/apt"

    root="$(new_root rocky 9.4)"
    printf '[pgdg-common]\nbaseurl=https://download.postgresql.org/pub/repos/yum/common/redhat/rhel-9-x86_64\n' \
        > "${root}/etc/yum.repos.d/pgdg-redhat-all.repo"
    printf '[documentdb]\nname=DocumentDB Repository\nbaseurl=https://documentdb.io/rpm/rhel9\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=file://%s/etc/pki/rpm-gpg/RPM-GPG-KEY-documentdb\n' \
        "${root}" > "${root}/etc/yum.repos.d/documentdb.repo"
    expect_success "exact dnf repositories are reused" run_installer "${root}"
    assert_has "canonical PGDG repository file is reused" \
        "Reusing the existing PGDG DNF repository configuration"
    assert_has "exact DocumentDB repository file is reused" \
        "Reusing the existing DocumentDB DNF repository configuration"
    assert_has "reused PGDG repository is fixed before the first dnf call" \
        "rhel-9.4 is not published."$'\n'"  + sudo dnf install -y ca-certificates"

    root="$(new_root rocky 9.4)"
    printf '[pgdg-common]\nbaseurl=https://download.postgresql.org/pub/repos/yum/common/redhat/rhel-9-x86_64\n' \
        > "${root}/etc/yum.repos.d/pgdg-redhat-all.repo"
    printf '%s\n' \
        '[documentdb]' \
        'name=DocumentDB Repository' \
        'baseurl=https://documentdb.io/rpm/rhel9' \
        'enabled=1' \
        'gpgcheck=1' \
        'gpgkey=https://documentdb.io/documentdb-archive-keyring.gpg' \
        > "${root}/etc/yum.repos.d/documentdb.repo"
    expect_success "published DocumentDB dnf repository is reused" \
        run_installer "${root}"
    assert_has "published DocumentDB repository is reported as reused" \
        "Reusing the existing DocumentDB DNF repository configuration"

    installer_env DOCUMENTDB_INSTALLER_TEST_RPM_INSTALLED=epel-release
    expect_success "installed EPEL is reused" run_installer "${root}"
    assert_has "installed EPEL is reported" "Reusing the installed epel-release package"
    assert_lacks "installed EPEL is not downloaded again" "epel-release-latest-9.noarch.rpm"
    installer_env

    section "repository trust"
    root="$(new_root ubuntu 24.04)"
    expect_success "clean host trusts published keys" run_installer "${root}"
    assert_has "PGDG apt key is fingerprint checked" \
        "https://www.postgresql.org/media/keys/ACCC4CF8.asc and require fingerprint B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8"
    assert_has "DocumentDB apt key is fingerprint checked" \
        "require fingerprint 1F748DA911519E749521438252101F285C52B856"
    assert_has "DocumentDB source uses HTTPS" "https://documentdb.io/deb"
    assert_lacks "no plain HTTP repository is configured" "http://"

    root="$(new_root rocky 9.4)"
    expect_success "rpm host trusts published keys" run_installer "${root}"
    assert_has "EPEL key is fingerprint checked" \
        "require fingerprint FF8AD1344597106ECE813B918A3872BF3228467C"
    assert_has "x86_64 PGDG rpm key is fingerprint checked" \
        "require fingerprint D4BF08AE67A0B4C7A1DBCCD240BCA2B408B40D20"
    assert_has "repository packages are installed with gpg checking" \
        "dnf --setopt=localpkg_gpgcheck=1 install -y"
    assert_lacks "no plain HTTP repository is configured on rpm hosts" "http://"

    section "test repository overrides"
    root="$(new_root ubuntu 24.04)"
    installer_env \
        DOCUMENTDB_INSTALLER_TEST_REPOSITORY_MODE=true \
        DOCUMENTDB_INSTALLER_TEST_APT_REPOSITORY_URL=https://127.0.0.1:8443/deb \
        DOCUMENTDB_INSTALLER_TEST_RPM_REPOSITORY_URL=https://127.0.0.1:8443/rpm/rhel9 \
        DOCUMENTDB_INSTALLER_TEST_KEY_URL=https://127.0.0.1:8443/documentdb-archive-keyring.gpg \
        DOCUMENTDB_INSTALLER_TEST_KEY_FINGERPRINT=0123456789abcdef0123456789abcdef01234567
    expect_success "test apt repository" run_installer "${root}"
    assert_has "test apt source is selected" \
        "https://127.0.0.1:8443/deb stable ubuntu24"
    assert_has "test key URL is selected" \
        "https://127.0.0.1:8443/documentdb-archive-keyring.gpg"
    assert_has "test fingerprint is normalized" \
        "0123456789ABCDEF0123456789ABCDEF01234567"
    printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/documentdb-archive-keyring.gpg] https://127.0.0.1:8443/deb stable ubuntu24\n' \
        > "${root}/etc/apt/sources.list.d/documentdb.list"
    expect_success "test apt repository is reusable" run_installer "${root}"
    assert_has "test apt repository reuse is reported" \
        "Reusing the existing DocumentDB APT repository configuration"

    root="$(new_root rocky 9.4)"
    expect_success "test rpm repository" run_installer "${root}"
    assert_has "test rpm source is selected" \
        "baseurl=https://127.0.0.1:8443/rpm/rhel9"
    printf '[documentdb]\nname=DocumentDB Repository\nbaseurl=https://127.0.0.1:8443/rpm/rhel9\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=file://%s/etc/pki/rpm-gpg/RPM-GPG-KEY-documentdb\n' \
        "${root}" > "${root}/etc/yum.repos.d/documentdb.repo"
    expect_success "test rpm repository is reusable" run_installer "${root}"
    assert_has "test rpm repository reuse is reported" \
        "Reusing the existing DocumentDB DNF repository configuration"
    installer_env

    root="$(new_root ubuntu 24.04)"
    installer_env \
        DOCUMENTDB_INSTALLER_TEST_APT_REPOSITORY_URL=https://127.0.0.1:8443/deb
    expect_failure "repository override without test mode" \
        "require DOCUMENTDB_INSTALLER_TEST_REPOSITORY_MODE=true" \
        run_installer "${root}"
    installer_env
}

# --------------------------------------------------------------------------
# A dry run must plan everything and change nothing.
# --------------------------------------------------------------------------
test_dry_run_is_inert() {
    section "dry run"
    local root before after
    root="$(new_root ubuntu 24.04)"
    before="$(snapshot_tree "${root}")"
    : > "${MUTATION_LOG}"
    expect_success "dry run on a clean host" run_installer "${root}" \
        --admin-user dbadmin --listen-port 27019
    after="$(snapshot_tree "${root}")"
    if [[ "${before}" == "${after}" ]]; then
        ok
    else
        bad "dry run changed the target tree" "$(diff <(printf '%s\n' "${before}") <(printf '%s\n' "${after}"))"
    fi
    assert_no_mutation "dry run"
    assert_has "dry run only describes writes" "Would write"
    assert_has "dry run reports completion" "Dry run complete; no changes were made"
    assert_lacks "dry run does not claim success" "DocumentDB is installed."

    root="$(new_root rocky 9.4)"
    before="$(snapshot_tree "${root}")"
    expect_success "dry run on an rpm host" run_installer "${root}"
    after="$(snapshot_tree "${root}")"
    if [[ "${before}" == "${after}" ]]; then
        ok
    else
        bad "rpm dry run changed the target tree" ""
    fi
    assert_no_mutation "rpm dry run"
}

# --------------------------------------------------------------------------
# Password files are checked for owner-only metadata and never echoed.
# --------------------------------------------------------------------------
test_password_metadata() {
    section "password file handling"
    local root secrets="${WORK_DIR}/secrets"
    root="$(new_root ubuntu 24.04)"
    mkdir -p "${secrets}"
    printf 'sup3r-secret\n' > "${secrets}/good"
    chmod 0600 "${secrets}/good"
    printf 'sup3r-secret\n' > "${secrets}/group-readable"
    chmod 0644 "${secrets}/group-readable"
    : > "${secrets}/empty"
    chmod 0600 "${secrets}/empty"
    printf 'sup3r-secret\n' > "${secrets}/linked"
    chmod 0600 "${secrets}/linked"
    ln "${secrets}/linked" "${secrets}/linked-alias"
    ln -s "${secrets}/good" "${secrets}/symlink"

    validation_run() {
        env PATH="${MOCK_BIN}:${PATH}" TMPDIR="${WORK_DIR}" \
            DOCUMENTDB_TEST_MUTATION_LOG="${MUTATION_LOG}" \
            DOCUMENTDB_INSTALLER_TESTING=true \
            DOCUMENTDB_INSTALLER_TEST_VALIDATION_ONLY=true \
            DOCUMENTDB_INSTALLER_TEST_ROOT="${root}" \
            sh "${INSTALLER}" --yes --accept-external-listen \
            --admin-password-file "$1" 2>&1
    }

    expect_success "owner-only password file" validation_run "${secrets}/good"
    assert_lacks "password contents never reach the output" "sup3r-secret"
    assert_no_mutation "password validation"

    local name file expected
    while IFS='|' read -r name file expected; do
        [[ -n "${name}" ]] || continue
        expect_failure "${name}" "${expected}" validation_run "${secrets}/${file}"
    done <<'PASSWORDS'
group-readable password file|group-readable|must not be readable or writable by group or others
empty password file|empty|is empty
hard-linked password file|linked|must have exactly one hard link
symlinked password file|symlink|must not be a symbolic link
missing password file|absent|is not a regular file
PASSWORDS

    # The staged copy lives in the installer's private directory and is removed.
    if compgen -G "${WORK_DIR}/documentdb-install.*" > /dev/null; then
        bad "password staging left a temporary directory behind" ""
    else
        ok
    fi
}

# --------------------------------------------------------------------------
# Streamed execution barrier: no strict byte prefix may run main.
# --------------------------------------------------------------------------
run_prefix() {
    local file="$1" bytes="$2" root="$3"
    head -c "${bytes}" "${file}" |
        env PATH="${MOCK_BIN}:${PATH}" \
            DOCUMENTDB_TEST_MUTATION_LOG="${MUTATION_LOG}" \
            DOCUMENTDB_INSTALLER_TESTING=true \
            DOCUMENTDB_INSTALLER_TEST_ROOT="${root}" \
            sh -s -- --dry-run --yes --accept-external-listen \
            --admin-password-file /dev/null 2>&1
}

test_execution_barrier() {
    section "streamed execution barrier"
    local root total offset output observed=0
    root="$(new_root ubuntu 24.04)"
    total="$(wc -c < "${INSTALLER}")"

    if [[ "$(tail -c 1 "${INSTALLER}")" == "}" ]]; then
        ok
    else
        bad "installer does not end with the parser-closing brace" ""
    fi
    if [[ "$(tail -c 1 "${INSTALLER}" | od -An -c | tr -d ' ')" == "}" ]]; then
        ok
    else
        bad "installer ends with a trailing newline" ""
    fi
    if (($(grep -c 'main "\$@"' "${INSTALLER}") == 1)); then
        ok
    else
        bad "installer invokes main outside the barrier" ""
    fi

    : > "${MUTATION_LOG}"
    local offsets=()
    for ((offset = 1; offset < 16; offset++)); do
        offsets+=($((total * offset / 16)))
    done
    for ((offset = total - 60; offset < total; offset++)); do
        offsets+=("${offset}")
    done
    for offset in "${offsets[@]}"; do
        output="$(run_prefix "${INSTALLER}" "${offset}" "${root}")"
        if [[ "${output}" == *"[documentdb-install]"* ]]; then
            bad "byte prefix ${offset}/${total} executed the installer" "${output}"
            observed=1
        fi
    done
    ((observed == 0)) && ok
    assert_no_mutation "truncated installer"

    # Negative control: the same probe must catch a footer that calls main
    # directly, otherwise the barrier assertions above would prove nothing.
    local unsafe="${WORK_DIR}/unsafe-install.sh"
    awk '/^# BEGIN EXECUTION BARRIER$/ { exit } { print }' "${INSTALLER}" \
        > "${unsafe}"
    printf 'main "$@"\n' >> "${unsafe}"
    output="$(run_prefix "${unsafe}" "$(($(wc -c < "${unsafe}") - 1))" "${root}")"
    if [[ "${output}" == *"[documentdb-install]"* ]]; then
        ok
    else
        bad "barrier negative control did not run a truncated bare footer" "${output}"
    fi
}

setup_mocks
test_supported_matrix
test_unsupported_hosts
test_arguments
test_release_selection
test_release_package_states
test_release_checksums
test_derived_state
test_brownfield_refusal
test_mode_flags
test_repositories
test_dry_run_is_inert
test_password_metadata
test_execution_barrier

printf '\nResults: %d passed, %d failed\n' "${PASS}" "${FAIL}"
((FAIL == 0))
