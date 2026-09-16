#!/bin/sh
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Clean-host bootstrap for the current stable DocumentDB stand-alone packages.
#
# The script trusts the public package repositories, installs
# documentdb-<major>, and hands provisioning to documentdb-setup. It keeps no
# state of its own: what it does is derived from the installed packages and
# from the configuration documentdb-setup owns.
#
# Supported hosts:
#   Ubuntu 24.04 LTS                          amd64, arm64
#   RHEL, Rocky, AlmaLinux, CentOS Stream 9   x86_64, aarch64
#   PostgreSQL 17 or 18
#
# This is a new-install bootstrap. It never upgrades, adopts, or removes an
# existing instance and never removes packages or data.

set -eu

umask 077

PROGRAM="${0##*/}"
DEFAULT_PG_MAJOR="18"
DEFAULT_ADMIN_USER="admin"
DEFAULT_LISTEN_PORT="10260"
BLOCKED_ADMIN_PREFIXES="documentdb citus pg internal_role"
INSTALL_LOCK_DIR="/run/lock/documentdb-installer.lock"
STATE_ROOT="/etc/documentdb/local"
DATA_ROOT="/var/lib/documentdb-local"

PGDG_APT_KEY_URL="https://www.postgresql.org/media/keys/ACCC4CF8.asc"
PGDG_APT_KEY_FINGERPRINT="B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8"
PGDG_RPM_X86_64_KEY_URL="https://download.postgresql.org/pub/repos/yum/keys/PGDG-RPM-GPG-KEY-RHEL"
PGDG_RPM_X86_64_KEY_FINGERPRINT="D4BF08AE67A0B4C7A1DBCCD240BCA2B408B40D20"
PGDG_RPM_AARCH64_KEY_URL="https://download.postgresql.org/pub/repos/yum/keys/PGDG-RPM-GPG-KEY-AARCH64-RHEL"
PGDG_RPM_AARCH64_KEY_FINGERPRINT="B031F89FC983E98262906B6E177B343BB9738825"
EPEL_KEY_URL="https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-9"
EPEL_KEY_FINGERPRINT="FF8AD1344597106ECE813B918A3872BF3228467C"
EPEL_RELEASE_URL="https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
DOCUMENTDB_KEY_URL="https://documentdb.io/documentdb-archive-keyring.gpg"
DOCUMENTDB_KEY_FINGERPRINT="1F748DA911519E749521438252101F285C52B856"
DOCUMENTDB_APT_REPOSITORY_URL="https://documentdb.io/deb"
DOCUMENTDB_RPM_REPOSITORY_URL="https://documentdb.io/rpm/rhel9"

PG_MAJOR="${DEFAULT_PG_MAJOR}"
ADMIN_USER="${DEFAULT_ADMIN_USER}"
ADMIN_USER_EXPLICIT="false"
ADMIN_PASSWORD_FILE=""
LISTEN_PORT="${DEFAULT_LISTEN_PORT}"
ASSUME_YES="false"
DRY_RUN="false"
PACKAGES_ONLY="false"
NO_ENABLE="false"
ACCEPT_EXTERNAL_LISTEN="false"

# Test hooks. The installer refuses to mutate a host while they are active, so
# the deterministic suite can exercise every supported cell on one machine.
TESTING="${DOCUMENTDB_INSTALLER_TESTING:-false}"
TEST_VALIDATION_ONLY="${DOCUMENTDB_INSTALLER_TEST_VALIDATION_ONLY:-false}"
TEST_REPOSITORY_MODE="${DOCUMENTDB_INSTALLER_TEST_REPOSITORY_MODE:-false}"
TEST_REPOSITORY_MARKER="/etc/documentdb-installer-test-repository"
SYSTEM_ROOT=""

TMP_DIR=""
TTY_PATH="/dev/tty"
TTY_STATE=""
IS_ROOT="false"
SUDO="sudo"
LOCK_HELD="false"
LOCK_PATH=""

OS_ID=""
OS_VERSION_ID=""
OS_DISPLAY=""
DISTRO_KIND=""
PACKAGE_FAMILY=""
RAW_ARCH=""
APT_ARCH=""
RPM_ARCH=""

PGDG_REPO_PRESENT="false"
DOCUMENTDB_REPO_PRESENT="false"
DESIRED_PGDG_SOURCE=""
DESIRED_DOCUMENTDB_SOURCE=""
DESIRED_DOCUMENTDB_RPM_REPO=""
PUBLISHED_DOCUMENTDB_RPM_REPO=""
RHEL_CRB_METHOD=""
RHEL_CRB_REPO=""

SELECTED_PACKAGE_INSTALLED="false"
SETUP_CONFIGURED="false"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Install the current stable DocumentDB stand-alone packages and provision a new
private DocumentDB instance with documentdb-setup.

Supported hosts:
  Ubuntu 24.04 LTS                  amd64, arm64
  RHEL/Rocky/Alma/CentOS Stream 9   x86_64, aarch64

Options:
  --pg-major <17|18>          PostgreSQL major (default: 18)
  --admin-user <USER>         Initial DocumentDB administrator (default: admin)
  --admin-password-file <FILE>
                              Read the initial administrator password from
                              FILE. Required with --yes.
  --listen-port <PORT>        Gateway port, 1024-65535 (default: 10260)
  --packages-only             Configure repositories and install packages
                              without running documentdb-setup.
  --no-enable                 Provision the instance without starting or
                              enabling its systemd target.
  --accept-external-listen    Acknowledge that setup binds the gateway on all
                              interfaces. Required with --yes.
  --yes                       Run unattended. Requires --admin-password-file
                              and --accept-external-listen unless
                              --packages-only is used.
  --dry-run                   Detect the host and print the planned commands
                              without changing files, repositories, packages,
                              or services.
  -h, --help                  Show this help.

Interactive installation:
  sh install.sh

Unattended installation:
  sh install.sh --yes --accept-external-listen \
    --admin-password-file /secure/path/password

When documentdb-setup has already configured the selected PostgreSQL major,
this script reports that instance's status instead of configuring it again.
EOF
}

log() {
    printf '[documentdb-install] %s\n' "$*"
}

warn() {
    printf '[documentdb-install] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[documentdb-install] ERROR: %s\n' "$*" >&2
    exit 1
}

restore_tty() {
    if [ -n "${TTY_STATE}" ] && [ -r "${TTY_PATH}" ]; then
        stty "${TTY_STATE}" < "${TTY_PATH}" 2>/dev/null || true
        TTY_STATE=""
        printf '\n' > "${TTY_PATH}" 2>/dev/null || true
    fi
}

cleanup() {
    restore_tty
    if [ "${LOCK_HELD}" = "true" ]; then
        if [ "${IS_ROOT}" = "true" ]; then
            rmdir "${LOCK_PATH}" 2>/dev/null || true
        else
            sudo -n rmdir "${LOCK_PATH}" 2>/dev/null || true
        fi
        LOCK_HELD="false"
    fi
    if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
        rm -rf "${TMP_DIR}"
    fi
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

system_path() {
    printf '%s%s\n' "${SYSTEM_ROOT}" "$1"
}

lowercase() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

strip_outer_quotes() {
    quoted_value="$1"
    case "${quoted_value}" in
        \"*\") quoted_value="${quoted_value#\"}"; quoted_value="${quoted_value%\"}" ;;
        \'*\') quoted_value="${quoted_value#\'}"; quoted_value="${quoted_value%\'}" ;;
    esac
    printf '%s\n' "${quoted_value}"
}

# PostgreSQL role names: letters, digits, '_' and '-', starting with a letter
# or '_', at most NAMEDATALEN-1 bytes, and never inside a reserved prefix.
validate_admin_user() {
    admin_value="$1"
    admin_label="$2"

    [ -n "${admin_value}" ] || die "${admin_label} cannot be empty."
    case "${admin_value}" in
        [A-Za-z_]*[!A-Za-z0-9_-]*|[!A-Za-z_]*)
            die "${admin_label} must use letters, digits, '_' or '-' and start with a letter or '_'."
            ;;
    esac
    [ "${#admin_value}" -le 63 ] ||
        die "${admin_label} must be at most 63 bytes."

    admin_value_lower="$(lowercase "${admin_value}")"
    for blocked_prefix in ${BLOCKED_ADMIN_PREFIXES}; do
        case "${admin_value_lower}" in
            "${blocked_prefix}"*)
                die "${admin_label} '${admin_value}' begins with reserved prefix '${blocked_prefix}'. Reserved prefixes: ${BLOCKED_ADMIN_PREFIXES}."
                ;;
        esac
    done
}

# Canonical decimal only: shell arithmetic on a leading-zero value would be
# read as octal, and non-digits would be a syntax error.
validate_listen_port() {
    port_value="$1"
    port_label="$2"

    case "${port_value}" in
        ''|*[!0-9]*)
            die "${port_label} must be a number from 1024 through 65535."
            ;;
        0*)
            die "${port_label} must use canonical decimal notation without leading zeros."
            ;;
    esac
    [ "${#port_value}" -le 5 ] ||
        die "${port_label} must be from 1024 through 65535."
    if [ "${port_value}" -lt 1024 ] || [ "${port_value}" -gt 65535 ]; then
        die "${port_label} must be from 1024 through 65535."
    fi
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --pg-major)
                [ "$#" -ge 2 ] || die "--pg-major requires a value."
                PG_MAJOR="$2"
                shift 2
                ;;
            --admin-user)
                [ "$#" -ge 2 ] || die "--admin-user requires a value."
                ADMIN_USER="$2"
                ADMIN_USER_EXPLICIT="true"
                shift 2
                ;;
            --admin-password-file)
                [ "$#" -ge 2 ] || die "--admin-password-file requires a value."
                ADMIN_PASSWORD_FILE="$2"
                shift 2
                ;;
            --listen-port)
                [ "$#" -ge 2 ] || die "--listen-port requires a value."
                LISTEN_PORT="$2"
                shift 2
                ;;
            --packages-only) PACKAGES_ONLY="true"; shift ;;
            --no-enable) NO_ENABLE="true"; shift ;;
            --accept-external-listen) ACCEPT_EXTERNAL_LISTEN="true"; shift ;;
            --yes) ASSUME_YES="true"; shift ;;
            --dry-run) DRY_RUN="true"; shift ;;
            -h|--help) usage; exit 0 ;;
            --)
                shift
                [ "$#" -eq 0 ] || die "Unexpected positional arguments: $*"
                ;;
            *)
                die "Unknown option: $1. Run ${PROGRAM} --help for usage."
                ;;
        esac
    done
}

validate_arguments() {
    case "${PG_MAJOR}" in
        17|18) ;;
        *) die "--pg-major must be 17 or 18." ;;
    esac
    validate_admin_user "${ADMIN_USER}" "--admin-user"
    validate_listen_port "${LISTEN_PORT}" "--listen-port"

    if [ "${PACKAGES_ONLY}" = "true" ] && [ "${NO_ENABLE}" = "true" ]; then
        die "--packages-only and --no-enable cannot be combined."
    fi
    if [ "${DRY_RUN}" = "true" ] || [ -z "${ADMIN_PASSWORD_FILE}" ]; then
        return 0
    fi
    [ ! -L "${ADMIN_PASSWORD_FILE}" ] ||
        die "Password file '${ADMIN_PASSWORD_FILE}' must not be a symbolic link."
    [ -f "${ADMIN_PASSWORD_FILE}" ] ||
        die "Password file '${ADMIN_PASSWORD_FILE}' is not a regular file."
    [ -r "${ADMIN_PASSWORD_FILE}" ] ||
        die "Password file '${ADMIN_PASSWORD_FILE}' is not readable."
}

# The password never reaches argv, the environment, or the transcript: it is
# copied into an owner-only file inside the installer's 0700 temporary
# directory and only that path is passed to documentdb-setup.
stage_supplied_password_file() {
    [ "${DRY_RUN}" = "false" ] || return 0
    [ -n "${ADMIN_PASSWORD_FILE}" ] || return 0

    password_metadata="$(stat -c '%u %a %h' "${ADMIN_PASSWORD_FILE}" 2>/dev/null || true)"
    [ -n "${password_metadata}" ] ||
        die "Cannot read metadata for password file '${ADMIN_PASSWORD_FILE}'."
    password_owner="${password_metadata%% *}"
    password_rest="${password_metadata#* }"
    password_mode="${password_rest%% *}"
    password_links="${password_rest##* }"

    [ "${password_owner}" = "$(id -u)" ] ||
        die "Password file '${ADMIN_PASSWORD_FILE}' must be owned by the user running the installer."
    case "${password_mode}" in
        ''|*[!0-7]*) die "Cannot validate permissions on password file '${ADMIN_PASSWORD_FILE}'." ;;
    esac
    [ $((password_mode % 100)) -eq 0 ] ||
        die "Password file '${ADMIN_PASSWORD_FILE}' must not be readable or writable by group or others (use chmod 600)."
    [ "${password_links}" = "1" ] ||
        die "Password file '${ADMIN_PASSWORD_FILE}' must have exactly one hard link."

    staged_password_file="${TMP_DIR}/admin-password"
    cp "${ADMIN_PASSWORD_FILE}" "${staged_password_file}"
    chmod 0600 "${staged_password_file}"
    [ -s "${staged_password_file}" ] ||
        die "Password file '${ADMIN_PASSWORD_FILE}' is empty."
    ADMIN_PASSWORD_FILE="${staged_password_file}"
}

initialize_environment() {
    case "${TESTING}" in
        true|false) ;;
        *) die "DOCUMENTDB_INSTALLER_TESTING must be true or false." ;;
    esac
    case "${TEST_VALIDATION_ONLY}" in
        true|false) ;;
        *) die "DOCUMENTDB_INSTALLER_TEST_VALIDATION_ONLY must be true or false." ;;
    esac
    case "${TEST_REPOSITORY_MODE}" in
        true|false) ;;
        *) die "DOCUMENTDB_INSTALLER_TEST_REPOSITORY_MODE must be true or false." ;;
    esac

    if [ "${TESTING}" = "true" ]; then
        [ "${DRY_RUN}" = "true" ] || [ "${TEST_VALIDATION_ONLY}" = "true" ] ||
            die "Internal installer test mode is restricted to --dry-run or validation-only mode."
        SYSTEM_ROOT="${DOCUMENTDB_INSTALLER_TEST_ROOT:-}"
        case "${SYSTEM_ROOT}" in
            /*|'') ;;
            *) die "DOCUMENTDB_INSTALLER_TEST_ROOT must be an absolute path." ;;
        esac
    else
        PATH="/usr/sbin:/usr/bin:/sbin:/bin"
        export PATH
        unset CDPATH ENV BASH_ENV APT_CONFIG GNUPGHOME GPG_AGENT_INFO || true
        LC_ALL=C
        export LC_ALL
    fi

    configure_test_repository
}

validate_https_url() {
    case "$2" in
        https://*) ;;
        *) die "$1 must be an HTTPS URL." ;;
    esac
    case "$2" in
        *[[:space:]]*) die "$1 must be an HTTPS URL without whitespace." ;;
    esac
}

configure_test_repository() {
    test_apt_url="${DOCUMENTDB_INSTALLER_TEST_APT_REPOSITORY_URL:-}"
    test_rpm_url="${DOCUMENTDB_INSTALLER_TEST_RPM_REPOSITORY_URL:-}"
    test_key_url="${DOCUMENTDB_INSTALLER_TEST_KEY_URL:-}"
    test_key_fingerprint="${DOCUMENTDB_INSTALLER_TEST_KEY_FINGERPRINT:-}"

    if [ "${TEST_REPOSITORY_MODE}" = "false" ]; then
        [ -z "${test_apt_url}${test_rpm_url}${test_key_url}${test_key_fingerprint}" ] ||
            die "Installer test repository overrides require DOCUMENTDB_INSTALLER_TEST_REPOSITORY_MODE=true."
        return 0
    fi

    if [ "${TESTING}" = "false" ]; then
        marker_path="$(system_path "${TEST_REPOSITORY_MARKER}")"
        marker_metadata="$(stat -c '%u %a %h' "${marker_path}" 2>/dev/null || true)"
        [ "${marker_metadata}" = "0 600 1" ] ||
            die "Installer test repository mode requires root-owned mode 0600 marker ${TEST_REPOSITORY_MARKER}."
    fi

    validate_https_url "DOCUMENTDB_INSTALLER_TEST_APT_REPOSITORY_URL" "${test_apt_url}"
    validate_https_url "DOCUMENTDB_INSTALLER_TEST_RPM_REPOSITORY_URL" "${test_rpm_url}"
    validate_https_url "DOCUMENTDB_INSTALLER_TEST_KEY_URL" "${test_key_url}"
    case "${test_key_fingerprint}" in
        *[!0-9A-Fa-f]*|'')
            die "DOCUMENTDB_INSTALLER_TEST_KEY_FINGERPRINT must be a 40-character hexadecimal fingerprint."
            ;;
    esac
    [ "${#test_key_fingerprint}" -eq 40 ] ||
        die "DOCUMENTDB_INSTALLER_TEST_KEY_FINGERPRINT must be a 40-character hexadecimal fingerprint."

    DOCUMENTDB_APT_REPOSITORY_URL="${test_apt_url}"
    DOCUMENTDB_RPM_REPOSITORY_URL="${test_rpm_url}"
    DOCUMENTDB_KEY_URL="${test_key_url}"
    DOCUMENTDB_KEY_FINGERPRINT="$(printf '%s' "${test_key_fingerprint}" | tr '[:lower:]' '[:upper:]')"
}

command_exists() {
    if [ "${TESTING}" = "true" ]; then
        [ "$1" != "${DOCUMENTDB_INSTALLER_TEST_MISSING_COMMAND:-}" ]
        return
    fi
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    command_exists "$1" || die "Required command '$1' is not available."
}

probe() {
    probe_name="$1"
    probe_default="$2"
    shift 2
    if [ "${TESTING}" = "true" ]; then
        eval "printf '%s\\n' \"\${DOCUMENTDB_INSTALLER_TEST_${probe_name}:-${probe_default}}\""
        return 0
    fi
    "$@" 2>/dev/null || true
}

detect_platform() {
    os_name="$(probe UNAME_S Linux uname -s)"
    [ "${os_name}" = "Linux" ] ||
        die "Unsupported operating system '${os_name}'. This installer supports Linux only."

    kernel_release="$(lowercase "$(probe KERNEL_RELEASE generic-linux uname -r)")"
    case "${kernel_release}" in
        *microsoft*|*wsl*)
            container_virt="$(probe CONTAINER_VIRT none systemd-detect-virt --container)"
            if [ ! -f "$(system_path /.dockerenv)" ] &&
                [ ! -f "$(system_path /run/.containerenv)" ]; then
                case "${container_virt}" in
                    ''|none) die "Windows Subsystem for Linux is not supported by this installer." ;;
                esac
            fi
            ;;
    esac

    read_os_release
    case "${OS_ID}" in
        ubuntu)
            [ "${OS_VERSION_ID}" = "24.04" ] ||
                die "Unsupported Ubuntu release ${OS_VERSION_ID}. Only Ubuntu 24.04 LTS is supported."
            PACKAGE_FAMILY="apt"
            DISTRO_KIND="ubuntu"
            OS_DISPLAY="Ubuntu 24.04 LTS"
            ;;
        rhel|rocky|almalinux|centos)
            case "${OS_VERSION_ID}" in
                9|9.[0-9]*) ;;
                *) die "Unsupported ${OS_ID} release ${OS_VERSION_ID}. Only the 9 series is supported." ;;
            esac
            PACKAGE_FAMILY="rpm"
            case "${OS_ID}" in
                rhel) DISTRO_KIND="rhel"; OS_DISPLAY="Red Hat Enterprise Linux 9" ;;
                rocky) DISTRO_KIND="rocky"; OS_DISPLAY="Rocky Linux 9" ;;
                almalinux) DISTRO_KIND="almalinux"; OS_DISPLAY="AlmaLinux 9" ;;
                *) DISTRO_KIND="centos-stream"; OS_DISPLAY="CentOS Stream 9" ;;
            esac
            ;;
        *)
            die "Unsupported Linux distribution '${OS_ID}' ${OS_VERSION_ID}. Supported distributions are Ubuntu 24.04 and the RHEL-compatible 9 family."
            ;;
    esac

    RAW_ARCH="$(lowercase "$(probe UNAME_M x86_64 uname -m)")"
    case "${RAW_ARCH}" in
        x86_64|amd64) APT_ARCH="amd64"; RPM_ARCH="x86_64" ;;
        aarch64|arm64) APT_ARCH="arm64"; RPM_ARCH="aarch64" ;;
        *) die "Unsupported CPU architecture '${RAW_ARCH}'. Supported architectures are x86_64 and arm64." ;;
    esac
}

read_os_release() {
    os_release_file="$(system_path /etc/os-release)"
    [ -r "${os_release_file}" ] || die "Cannot read ${os_release_file}."

    while IFS='=' read -r os_release_key os_release_value; do
        case "${os_release_key}" in
            ID) OS_ID="$(strip_outer_quotes "${os_release_value}")" ;;
            VERSION_ID) OS_VERSION_ID="$(strip_outer_quotes "${os_release_value}")" ;;
        esac
    done < "${os_release_file}"

    OS_ID="$(lowercase "${OS_ID}")"
    case "${OS_ID}" in
        ''|*[!a-z0-9._-]*) die "Invalid ID in ${os_release_file}." ;;
    esac
    case "${OS_VERSION_ID}" in
        ''|*[!0-9.]*|.*|*.|*..*) die "Invalid VERSION_ID in ${os_release_file}." ;;
    esac
}

validate_native_environment() {
    for required in grep awk sed sort find mktemp install cp stat curl; do
        require_command "${required}"
    done

    if [ "${PACKAGE_FAMILY}" = "apt" ]; then
        require_command apt-get
        require_command dpkg-query
        native_arch="$(lowercase "$(probe NATIVE_ARCH "${APT_ARCH}" dpkg --print-architecture)")"
        expected_arch="${APT_ARCH}"
    else
        require_command dnf
        require_command rpm
        native_arch="$(lowercase "$(probe NATIVE_ARCH "${RPM_ARCH}" rpm --eval '%{_arch}')")"
        expected_arch="${RPM_ARCH}"
    fi
    [ "${native_arch}" = "${expected_arch}" ] ||
        die "Kernel architecture '${RAW_ARCH}' does not match the native package architecture '${native_arch}'."

    [ "${PACKAGES_ONLY}" = "false" ] || return 0
    require_command systemctl
    require_command systemd-detect-virt
    systemd_dir="$(system_path /run/systemd/system)"
    [ -d "${systemd_dir}" ] ||
        die "A running systemd host is required; ${systemd_dir} is not present."
    systemd_state="$(probe SYSTEMD_STATE running systemctl is-system-running)"
    case "${systemd_state}" in
        running|degraded) ;;
        *) die "systemd is not ready (state: ${systemd_state:-unknown})." ;;
    esac
    chroot_virt="$(probe CHROOT_VIRT none systemd-detect-virt --chroot)"
    case "${chroot_virt}" in
        ''|none) ;;
        *) die "Chroot environment '${chroot_virt}' is not supported by this installer." ;;
    esac
}

directory_has_entries() {
    [ -d "$1" ] || return 1
    [ -n "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)" ]
}

# Root-owned, single-link regular files are the only configuration this script
# is willing to interpret; anything else is reported instead of trusted.
validate_trust_file() {
    trust_path="$1"
    trust_label="$2"
    trust_mode="$3"
    [ ! -L "${trust_path}" ] ||
        die "${trust_label} ${trust_path} must not be a symbolic link."
    [ -f "${trust_path}" ] ||
        die "${trust_label} ${trust_path} must be a regular file."
    [ "${TESTING}" = "false" ] || return 0
    trust_metadata="$(stat -c '%u %a %h' "${trust_path}" 2>/dev/null || true)"
    [ "${trust_metadata}" = "0 ${trust_mode} 1" ] ||
        die "${trust_label} ${trust_path} must be root-owned mode 0${trust_mode} with one hard link (found: ${trust_metadata:-unknown})."
}

list_documentdb_packages() {
    if [ "${TESTING}" = "true" ]; then
        printf '%s\n' "${DOCUMENTDB_INSTALLER_TEST_EXISTING_PACKAGES:-}"
        return 0
    fi
    if [ "${PACKAGE_FAMILY}" = "apt" ]; then
        dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' \
            'documentdb*' 'postgresql-*-documentdb' 2>/dev/null |
            awk '$1 ~ /^.i$/ { print $2 }' | sort -u || true
    else
        rpm -qa --qf '%{NAME}\n' 'documentdb*' 2>/dev/null | sort -u || true
    fi
}

# Everything this script does follows from two facts: whether the selected
# package is installed, and whether documentdb-setup has already configured
# the selected major. Conflicting state is refused rather than reconciled.
detect_installation_state() {
    SELECTED_PACKAGE_INSTALLED="false"
    SETUP_CONFIGURED="false"

    installed_packages="$(list_documentdb_packages)"
    other_majors="$(
        printf '%s\n' "${installed_packages}" |
            sed -n -E 's/^documentdb-([0-9]+)([-.].*)?$/\1/p' |
            sort -u | grep -v "^${PG_MAJOR}$" || true
    )"
    if [ -n "${other_majors}" ]; then
        printf '%s\n' "${installed_packages}" | sed 's/^/  - /' >&2
        die "DocumentDB stand-alone packages for PostgreSQL $(printf '%s' "${other_majors}" | tr '\n' ' ') are installed. Rerun with a matching --pg-major, or remove those packages first."
    fi
    if printf '%s\n' "${installed_packages}" |
        grep -Eq "^documentdb-${PG_MAJOR}([-.]|$)"; then
        SELECTED_PACKAGE_INSTALLED="true"
    fi

    brownfield_state="$(system_path "${STATE_ROOT}/${PG_MAJOR}/brownfield.conf")"
    if [ -e "${brownfield_state}" ] || [ -L "${brownfield_state}" ]; then
        validate_trust_file "${brownfield_state}" "instance state" "600"
        die "PostgreSQL ${PG_MAJOR} already hosts a DocumentDB instance that was configured against an existing PostgreSQL server. Manage it with documentdb-setup and documentdb-gateway-admin; this bootstrap only creates new private instances."
    fi

    setup_state="$(system_path "${STATE_ROOT}/${PG_MAJOR}/setup.conf")"
    if [ -e "${setup_state}" ] || [ -L "${setup_state}" ]; then
        validate_trust_file "${setup_state}" "instance state" "644"
        [ "${SELECTED_PACKAGE_INSTALLED}" = "true" ] ||
            die "${setup_state} describes a configured instance, but documentdb-${PG_MAJOR} is not installed. Reinstall the package or remove that configuration with documentdb-setup before rerunning."
        SETUP_CONFIGURED="true"
        return 0
    fi

    for other_state in "$(system_path "${STATE_ROOT}")"/*/setup.conf \
        "$(system_path "${STATE_ROOT}")"/*/brownfield.conf; do
        [ -f "${other_state}" ] || continue
        die "Another DocumentDB instance is already configured (${other_state}). This bootstrap configures a single stand-alone major; manage the existing instance with documentdb-setup."
    done
    if directory_has_entries "$(system_path "${DATA_ROOT}/${PG_MAJOR}")"; then
        die "Residual data exists under ${DATA_ROOT}/${PG_MAJOR} without a configured instance. Reconcile or remove it with documentdb-setup before installing."
    fi
}

file_contains() {
    [ -r "$1" ] && grep -Eq "$2" "$1"
}

file_matches_content() {
    [ -r "$1" ] || return 1
    [ "$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' -e 's/[[:space:]]*$//' "$1")" = "$2" ]
}

# Repository definitions are reused only when they are byte-for-byte the
# definitions this script would write; anything else fails closed instead of
# silently installing from an unexpected source.
preflight_apt_repositories() {
    sources_dir="$(system_path /etc/apt/sources.list.d)"
    managed_pgdg="${sources_dir}/pgdg.list"
    managed_docdb="${sources_dir}/documentdb.list"
    DESIRED_PGDG_SOURCE="deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt noble-pgdg main"
    DESIRED_DOCUMENTDB_SOURCE="deb [arch=${APT_ARCH} signed-by=/usr/share/keyrings/documentdb-archive-keyring.gpg] ${DOCUMENTDB_APT_REPOSITORY_URL} stable ubuntu24"

    if [ -f "${managed_docdb}" ] &&
        file_matches_content "${managed_docdb}" "${DESIRED_DOCUMENTDB_SOURCE}"; then
        validate_trust_file "${managed_docdb}" "DocumentDB APT source" "644"
        DOCUMENTDB_REPO_PRESENT="true"
    fi

    for file in "$(system_path /etc/apt/sources.list)" \
        "${sources_dir}"/*.list "${sources_dir}"/*.sources; do
        [ -f "${file}" ] || continue
        if file_contains "${file}" 'apt\.postgresql\.org/pub/repos/apt'; then
            { [ "${file}" = "${managed_pgdg}" ] &&
                file_matches_content "${file}" "${DESIRED_PGDG_SOURCE}"; } ||
                die "Conflicting PGDG repository configuration found in ${file}. The installer only reuses its exact HTTPS noble-pgdg source definition."
            validate_trust_file "${file}" "PGDG APT source" "644"
            PGDG_REPO_PRESENT="true"
        fi
        if file_contains "${file}" 'documentdb\.io/deb'; then
            { [ "${file}" = "${managed_docdb}" ] &&
                file_matches_content "${file}" "${DESIRED_DOCUMENTDB_SOURCE}"; } ||
                die "Conflicting DocumentDB repository configuration found in ${file}. The installer only reuses its exact HTTPS source definition."
            validate_trust_file "${file}" "DocumentDB APT source" "644"
            DOCUMENTDB_REPO_PRESENT="true"
        fi
    done

    [ ! -e "${managed_pgdg}" ] || [ "${PGDG_REPO_PRESENT}" = "true" ] ||
        die "Refusing to overwrite unrelated repository file ${managed_pgdg}."
    [ ! -e "${managed_docdb}" ] || [ "${DOCUMENTDB_REPO_PRESENT}" = "true" ] ||
        die "Refusing to overwrite unrelated repository file ${managed_docdb}."
}

preflight_rpm_repositories() {
    repo_dir="$(system_path /etc/yum.repos.d)"
    managed_pgdg="${repo_dir}/pgdg-redhat-all.repo"
    managed_docdb="${repo_dir}/documentdb.repo"
    DESIRED_DOCUMENTDB_RPM_REPO="[documentdb]
name=DocumentDB Repository
baseurl=${DOCUMENTDB_RPM_REPOSITORY_URL}
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$(system_path /etc/pki/rpm-gpg/RPM-GPG-KEY-documentdb)"
    PUBLISHED_DOCUMENTDB_RPM_REPO="[documentdb]
name=DocumentDB Repository
baseurl=https://documentdb.io/rpm/rhel9
enabled=1
gpgcheck=1
gpgkey=https://documentdb.io/documentdb-archive-keyring.gpg"

    if [ -f "${managed_docdb}" ] &&
        file_matches_content "${managed_docdb}" "${DESIRED_DOCUMENTDB_RPM_REPO}"; then
        validate_trust_file "${managed_docdb}" "DocumentDB DNF source" "644"
        DOCUMENTDB_REPO_PRESENT="true"
    fi

    for file in "${repo_dir}"/*.repo; do
        [ -f "${file}" ] || continue
        if file_contains "${file}" 'download\.postgresql\.org/pub/repos/yum'; then
            [ "${file}" = "${managed_pgdg}" ] ||
                die "Conflicting PGDG repository configuration found in ${file}. The installer only reuses the PGDG repository package's canonical pgdg-redhat-all.repo file."
            if [ "${TESTING}" = "false" ] &&
                ! rpm -q pgdg-redhat-repo >/dev/null 2>&1; then
                die "${managed_pgdg} exists but is not owned by the pgdg-redhat-repo package."
            fi
            PGDG_REPO_PRESENT="true"
        fi
        if file_contains "${file}" 'documentdb\.io/rpm'; then
            { [ "${file}" = "${managed_docdb}" ] &&
                { file_matches_content "${file}" "${DESIRED_DOCUMENTDB_RPM_REPO}" ||
                  file_matches_content "${file}" "${PUBLISHED_DOCUMENTDB_RPM_REPO}"; }; } ||
                die "Conflicting DocumentDB repository configuration found in ${file}. The installer only reuses its exact HTTPS repository definition."
            validate_trust_file "${file}" "DocumentDB DNF source" "644"
            DOCUMENTDB_REPO_PRESENT="true"
        fi
    done

    [ ! -e "${managed_pgdg}" ] || [ "${PGDG_REPO_PRESENT}" = "true" ] ||
        die "Refusing to use existing PGDG repository file ${managed_pgdg} because it does not match the official repository package configuration."
    [ ! -e "${managed_docdb}" ] || [ "${DOCUMENTDB_REPO_PRESENT}" = "true" ] ||
        die "Refusing to overwrite unrelated repository file ${managed_docdb}."

    if [ "${TESTING}" = "false" ] && rpm -q postgresql-server >/dev/null 2>&1; then
        die "The distribution postgresql-server package is installed. Refusing to disable the PostgreSQL module on an existing PostgreSQL host."
    fi
    [ "${DISTRO_KIND}" != "rhel" ] || detect_rhel_crb_method
}

# CodeReady Builder carries build dependencies of the PGDG packages. Entitled
# hosts enable it through subscription-manager; cloud images expose a RHUI
# variant whose repository id differs per image.
detect_rhel_crb_method() {
    if command_exists subscription-manager &&
        [ -s "$(system_path /etc/pki/consumer/cert.pem)" ]; then
        RHEL_CRB_METHOD="subscription-manager"
        RHEL_CRB_REPO="codeready-builder-for-rhel-9-${RPM_ARCH}-rpms"
        return 0
    fi

    repolist="$(probe RHEL_REPOLIST '' dnf -q repolist --all)"
    RHEL_CRB_REPO="$(
        printf '%s\n' "${repolist}" |
            awk -v arch="${RPM_ARCH}" '
                {
                    id = tolower($1)
                    expected = "codeready-builder-for-rhel-9-" tolower(arch) "-rhui-rpms"
                    aws = "codeready-builder-for-rhel-9-rhui-rpms"
                    if (id == expected || id == "rhui-" expected) { print $1; found = 1; exit }
                    if ((id == aws || id == "rhui-" aws) && fallback == "") { fallback = $1 }
                }
                END { if (!found && fallback != "") print fallback }
            '
    )"
    [ -n "${RHEL_CRB_REPO}" ] ||
        die "RHEL 9 is not registered with subscription-manager and no RHUI CodeReady Builder repository was found."
    RHEL_CRB_METHOD="dnf"
}

preflight_repositories() {
    if [ "${PACKAGE_FAMILY}" = "apt" ]; then
        preflight_apt_repositories
    else
        preflight_rpm_repositories
    fi
}

print_argument() {
    case "$1" in
        ''|*[!A-Za-z0-9_./:=,@%+-]*)
            printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
            ;;
        *) printf '%s' "$1" ;;
    esac
}

run_command() {
    if [ "${DRY_RUN}" = "false" ]; then
        "$@"
        return
    fi
    printf '  +'
    for argument in "$@"; do
        printf ' '
        print_argument "${argument}"
    done
    printf '\n'
}

run_root() {
    if [ "${IS_ROOT}" = "true" ]; then
        run_command "$@"
    else
        run_command "${SUDO}" "$@"
    fi
}

# Package managers and setup must never consume this script's stdin, which may
# be the piped script itself. Proxy variables are forwarded by name only, so
# their values never appear in the transcript.
run_root_no_stdin() {
    if [ "${DRY_RUN}" = "true" ]; then
        if [ "${IS_ROOT}" = "false" ] && proxy_environment_is_set; then
            run_command "${SUDO}" --preserve-env="${PROXY_VARIABLES}" "$@"
        else
            run_root "$@"
        fi
    elif [ "${IS_ROOT}" = "true" ]; then
        "$@" < /dev/null
    elif proxy_environment_is_set; then
        "${SUDO}" --preserve-env="${PROXY_VARIABLES}" "$@" < /dev/null
    else
        "${SUDO}" "$@" < /dev/null
    fi
}

PROXY_VARIABLES="HTTP_PROXY,HTTPS_PROXY,NO_PROXY,http_proxy,https_proxy,no_proxy"

proxy_environment_is_set() {
    [ -n "${HTTP_PROXY:-}" ] || [ -n "${HTTPS_PROXY:-}" ] ||
        [ -n "${NO_PROXY:-}" ] || [ -n "${http_proxy:-}" ] ||
        [ -n "${https_proxy:-}" ] || [ -n "${no_proxy:-}" ]
}

apt_get() {
    run_root_no_stdin env DEBIAN_FRONTEND=noninteractive \
        apt-get -o DPkg::Lock::Timeout=120 "$@"
}

write_root_file() {
    write_destination="$1"
    write_mode="$2"
    write_content="$3"

    if [ "${DRY_RUN}" = "true" ]; then
        log "Would write ${write_destination} (mode ${write_mode}):"
        printf '%s\n' "${write_content}" | sed 's/^/    /'
        return 0
    fi
    write_staged="${TMP_DIR}/$(basename "${write_destination}").staged"
    printf '%s\n' "${write_content}" > "${write_staged}"
    run_root install -D -m "${write_mode}" "${write_staged}" "${write_destination}"
}

strict_curl() {
    curl --disable --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 300 \
        --retry 5 --retry-delay 2 --retry-connrefused \
        -fsSL "$1" -o "$2"
}

# A repository key is trusted only when the downloaded or installed file holds
# exactly one primary key with the published fingerprint.
verify_key_fingerprint() {
    key_listing="$(
        GNUPGHOME="${TMP_DIR}/gnupg" gpg --no-options --batch \
            --show-keys --with-colons "$1" 2>/dev/null
    )" || die "Cannot inspect the $3 signing key."

    key_count="$(printf '%s\n' "${key_listing}" |
        awk -F: '$1 == "pub" { count++ } END { print count + 0 }')"
    [ "${key_count}" -eq 1 ] ||
        die "$3 key file contains ${key_count} primary keys; expected exactly one."
    key_fingerprint="$(printf '%s\n' "${key_listing}" |
        awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print toupper($10); exit }')"
    [ "${key_fingerprint}" = "$2" ] ||
        die "$3 key fingerprint is ${key_fingerprint:-unknown}; expected $2."
}

download_key() {
    require_command gpg
    strict_curl "$1" "$2"
    verify_key_fingerprint "$2" "$3" "$4"
}

ensure_apt_keyring() {
    keyring_destination="$1"
    keyring_url="$2"
    keyring_fingerprint="$3"
    keyring_label="$4"

    if [ "${DRY_RUN}" = "true" ]; then
        log "Would install or verify ${keyring_destination} from ${keyring_url} and require fingerprint ${keyring_fingerprint}."
        return 0
    fi
    if [ -f "${keyring_destination}" ]; then
        validate_trust_file "${keyring_destination}" "${keyring_label} APT key" "644"
        require_command gpg
        verify_key_fingerprint "${keyring_destination}" \
            "${keyring_fingerprint}" "${keyring_label}"
        return 0
    fi

    keyring_armored="${TMP_DIR}/$(basename "${keyring_destination}").asc"
    keyring_binary="${TMP_DIR}/$(basename "${keyring_destination}").gpg"
    download_key "${keyring_url}" "${keyring_armored}" \
        "${keyring_fingerprint}" "${keyring_label}"
    GNUPGHOME="${TMP_DIR}/gnupg" gpg --no-options --batch --yes \
        --dearmor --output "${keyring_binary}" "${keyring_armored}"
    run_root install -D -m 0644 "${keyring_binary}" "${keyring_destination}"
}

ensure_rpm_key() {
    rpm_key_destination="$1"
    rpm_key_url="$2"
    rpm_key_fingerprint="$3"
    rpm_key_label="$4"

    if [ "${DRY_RUN}" = "true" ]; then
        log "Would install or verify ${rpm_key_destination} from ${rpm_key_url} and require fingerprint ${rpm_key_fingerprint}."
    elif [ -f "${rpm_key_destination}" ]; then
        validate_trust_file "${rpm_key_destination}" "${rpm_key_label} RPM key" "644"
        require_command gpg
        verify_key_fingerprint "${rpm_key_destination}" \
            "${rpm_key_fingerprint}" "${rpm_key_label}"
    else
        rpm_key_download="${TMP_DIR}/$(basename "${rpm_key_destination}")"
        download_key "${rpm_key_url}" "${rpm_key_download}" \
            "${rpm_key_fingerprint}" "${rpm_key_label}"
        run_root install -D -m 0644 "${rpm_key_download}" "${rpm_key_destination}"
    fi
    run_root_no_stdin rpm --import "${rpm_key_destination}"
}

install_verified_repository_rpm() {
    repo_rpm_url="$1"
    repo_rpm_name="$2"
    repo_key_destination="$3"
    repo_key_url="$4"
    repo_key_fingerprint="$5"
    repo_label="$6"

    ensure_rpm_key "${repo_key_destination}" "${repo_key_url}" \
        "${repo_key_fingerprint}" "${repo_label}"

    if [ "${DRY_RUN}" = "true" ]; then
        log "Would download the ${repo_label} repository package from ${repo_rpm_url}."
        repo_rpm_path="<temporary-directory>/${repo_rpm_name}"
    else
        repo_rpm_path="${TMP_DIR}/${repo_rpm_name}"
        strict_curl "${repo_rpm_url}" "${repo_rpm_path}"
    fi
    run_root_no_stdin dnf --setopt=localpkg_gpgcheck=1 install -y "${repo_rpm_path}"

    # The repository package owns the same key path, so re-check it: an
    # enabled repository must not silently replace the verified bootstrap key.
    [ "${DRY_RUN}" = "true" ] || verify_key_fingerprint \
        "${repo_key_destination}" "${repo_key_fingerprint}" "${repo_label}"
}

create_temp_dir() {
    [ "${DRY_RUN}" = "false" ] || return 0
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/documentdb-install.XXXXXX")"
    mkdir -m 0700 "${TMP_DIR}/gnupg"
}

determine_privilege_mode() {
    if [ "${TESTING}" = "true" ] || [ "$(id -u)" -ne 0 ]; then
        IS_ROOT="false"
        SUDO="sudo"
        [ "${DRY_RUN}" = "true" ] || [ "${TESTING}" = "true" ] || require_command sudo
        return 0
    fi
    IS_ROOT="true"
    SUDO=""
}

acquire_privileges() {
    [ "${IS_ROOT}" = "false" ] || return 0
    if [ "${ASSUME_YES}" = "true" ]; then
        sudo -n true >/dev/null 2>&1 ||
            die "--yes requires root or non-interactive sudo access."
    else
        sudo -v
    fi
}

# A directory create is the atomic primitive available to both root and sudo
# callers; concurrent installers stop instead of racing over the same setup.
acquire_install_lock() {
    LOCK_PATH="$(system_path "${INSTALL_LOCK_DIR}")"
    if [ "${IS_ROOT}" = "true" ]; then
        lock_error="$(mkdir "${LOCK_PATH}" 2>&1)" && LOCK_HELD="true"
    else
        lock_error="$("${SUDO}" -n mkdir "${LOCK_PATH}" 2>&1)" && LOCK_HELD="true"
    fi
    [ "${LOCK_HELD}" = "false" ] || return 0
    [ ! -d "${LOCK_PATH}" ] ||
        die "Another DocumentDB installer is already running (lock ${LOCK_PATH}). If no installer is running, remove that directory as root and retry."
    die "Cannot create the installer lock ${LOCK_PATH}: ${lock_error}"
}

tty_available() {
    [ -r "${TTY_PATH}" ] && [ -w "${TTY_PATH}" ] &&
        ( : < "${TTY_PATH}" ) 2>/dev/null && ( : > "${TTY_PATH}" ) 2>/dev/null
}

confirm_plan() {
    [ "${ASSUME_YES}" = "false" ] || return 0
    tty_available ||
        die "Interactive confirmation requires /dev/tty. Use --yes with --admin-password-file and --accept-external-listen for unattended installation."

    printf 'Continue with this installation? [y/N] ' > "${TTY_PATH}"
    answer=""
    IFS= read -r answer < "${TTY_PATH}" || true
    case "${answer}" in
        y|Y|yes|YES) ;;
        *) die "Installation cancelled." ;;
    esac
}

prompt_password_file() {
    [ -z "${ADMIN_PASSWORD_FILE}" ] || return 0
    tty_available ||
        die "The password prompt requires /dev/tty. Use --admin-password-file for unattended installation."
    require_command stty

    password_copy="${TMP_DIR}/admin-password"
    attempts=0
    while [ "${attempts}" -lt 3 ]; do
        TTY_STATE="$(stty -g < "${TTY_PATH}")"
        stty -echo < "${TTY_PATH}"
        printf 'DocumentDB admin password: ' > "${TTY_PATH}"
        password=""
        IFS= read -r password < "${TTY_PATH}" || true
        printf '\nConfirm admin password: ' > "${TTY_PATH}"
        confirmation=""
        IFS= read -r confirmation < "${TTY_PATH}" || true
        restore_tty

        if [ -n "${password}" ] && [ "${password}" = "${confirmation}" ]; then
            printf '%s' "${password}" > "${password_copy}"
            chmod 0600 "${password_copy}"
            password=""
            confirmation=""
            ADMIN_PASSWORD_FILE="${password_copy}"
            return 0
        fi
        password=""
        confirmation=""
        attempts=$((attempts + 1))
        [ "${attempts}" -ge 3 ] ||
            warn "Passwords were empty or did not match; try again."
    done
    die "Passwords did not match after three attempts."
}

validate_required_setup_inputs() {
    [ "${ASSUME_YES}" = "true" ] || return 0
    [ "${PACKAGES_ONLY}" = "false" ] || return 0
    [ "${SETUP_CONFIGURED}" = "false" ] || return 0
    [ -n "${ADMIN_PASSWORD_FILE}" ] ||
        die "--yes requires --admin-password-file unless --packages-only is used."
    [ "${ACCEPT_EXTERNAL_LISTEN}" = "true" ] ||
        die "--yes requires --accept-external-listen unless --packages-only is used."
}

print_plan() {
    log "Installation plan"
    printf '  Operating system: %s\n' "${OS_DISPLAY}"
    if [ "${PACKAGE_FAMILY}" = "apt" ]; then
        printf '  Architecture:     %s\n  Package manager:  apt\n' "${APT_ARCH}"
    else
        printf '  Architecture:     %s\n  Package manager:  dnf\n' "${RPM_ARCH}"
    fi
    printf '  PostgreSQL major: %s\n' "${PG_MAJOR}"
    printf '  Package:          documentdb-%s (%s)\n' "${PG_MAJOR}" \
        "$([ "${SELECTED_PACKAGE_INSTALLED}" = "true" ] && printf 'installed' || printf 'to install')"
    if [ "${SETUP_CONFIGURED}" = "true" ]; then
        printf '  Instance:         already configured; setup will not run again\n'
        printf '  Admin user:       existing credentials unchanged\n'
        [ "${ADMIN_USER_EXPLICIT}" = "false" ] ||
            warn "--admin-user is ignored: the configured instance keeps its existing credentials."
    elif [ "${PACKAGES_ONLY}" = "true" ]; then
        printf '  Instance:         packages only; documentdb-setup will not run\n'
    else
        printf '  Instance:         new private PostgreSQL instance managed by systemd\n'
        printf '  Admin user:       %s\n' "${ADMIN_USER}"
        printf '  Gateway port:     %s%s\n' "${LISTEN_PORT}" \
            "$([ "${NO_ENABLE}" = "true" ] && printf ' (configured, not enabled)' || printf '')"
    fi
    printf '\n'
    if [ "${SETUP_CONFIGURED}" = "false" ] && [ "${PACKAGES_ONLY}" = "false" ]; then
        warn "Setup binds the gateway on all interfaces with a self-signed TLS certificate. Restrict port ${LISTEN_PORT} with the host firewall before exposing this machine to an untrusted network."
    fi
}

install_ubuntu() {
    apt_get update
    apt_get install -y --no-install-recommends ca-certificates curl gnupg

    ensure_apt_keyring "$(system_path /usr/share/keyrings/postgresql.gpg)" \
        "${PGDG_APT_KEY_URL}" "${PGDG_APT_KEY_FINGERPRINT}" "PGDG"
    if [ "${PGDG_REPO_PRESENT}" = "true" ]; then
        log "Reusing the existing PGDG APT repository configuration."
    else
        write_root_file "$(system_path /etc/apt/sources.list.d/pgdg.list)" \
            0644 "${DESIRED_PGDG_SOURCE}"
    fi

    ensure_apt_keyring \
        "$(system_path /usr/share/keyrings/documentdb-archive-keyring.gpg)" \
        "${DOCUMENTDB_KEY_URL}" "${DOCUMENTDB_KEY_FINGERPRINT}" "DocumentDB"
    if [ "${DOCUMENTDB_REPO_PRESENT}" = "true" ]; then
        log "Reusing the existing DocumentDB APT repository configuration."
    else
        write_root_file "$(system_path /etc/apt/sources.list.d/documentdb.list)" \
            0644 "${DESIRED_DOCUMENTDB_SOURCE}"
    fi

    apt_get update
    apt_get install -y "documentdb-${PG_MAJOR}"
}

rpm_package_installed() {
    if [ "${TESTING}" = "true" ]; then
        case " ${DOCUMENTDB_INSTALLER_TEST_RPM_INSTALLED:-} " in
            *" $1 "*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    rpm -q "$1" >/dev/null 2>&1
}

install_rhel_family() {
    if [ "${RPM_ARCH}" = "aarch64" ]; then
        pgdg_key="$(system_path /etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY-AARCH64-RHEL)"
        pgdg_key_url="${PGDG_RPM_AARCH64_KEY_URL}"
        pgdg_key_fingerprint="${PGDG_RPM_AARCH64_KEY_FINGERPRINT}"
    else
        pgdg_key="$(system_path /etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY-RHEL)"
        pgdg_key_url="${PGDG_RPM_X86_64_KEY_URL}"
        pgdg_key_fingerprint="${PGDG_RPM_X86_64_KEY_FINGERPRINT}"
    fi

    run_root_no_stdin dnf install -y ca-certificates gnupg2 dnf-plugins-core

    if [ "${DISTRO_KIND}" = "rhel" ]; then
        if [ "${RHEL_CRB_METHOD}" = "subscription-manager" ]; then
            run_root_no_stdin subscription-manager repos --enable "${RHEL_CRB_REPO}"
        else
            run_root_no_stdin dnf config-manager --set-enabled "${RHEL_CRB_REPO}"
        fi
    else
        run_root_no_stdin dnf config-manager --set-enabled crb
    fi

    if rpm_package_installed epel-release; then
        log "Reusing the installed epel-release package."
    else
        install_verified_repository_rpm "${EPEL_RELEASE_URL}" \
            "epel-release-latest-9.noarch.rpm" \
            "$(system_path /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-9)" \
            "${EPEL_KEY_URL}" "${EPEL_KEY_FINGERPRINT}" "EPEL 9"
    fi
    if [ "${DISTRO_KIND}" = "centos-stream" ] &&
        ! rpm_package_installed epel-next-release; then
        run_root_no_stdin dnf install -y epel-next-release
    fi

    if [ "${PGDG_REPO_PRESENT}" = "true" ]; then
        log "Reusing the existing PGDG DNF repository configuration."
    else
        install_verified_repository_rpm \
            "https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-${RPM_ARCH}/pgdg-redhat-repo-latest.noarch.rpm" \
            "pgdg-redhat-repo-latest.noarch.rpm" "${pgdg_key}" \
            "${pgdg_key_url}" "${pgdg_key_fingerprint}" "PGDG RPM"
    fi

    run_root_no_stdin dnf -qy module disable postgresql

    ensure_rpm_key "$(system_path /etc/pki/rpm-gpg/RPM-GPG-KEY-documentdb)" \
        "${DOCUMENTDB_KEY_URL}" "${DOCUMENTDB_KEY_FINGERPRINT}" "DocumentDB"
    if [ "${DOCUMENTDB_REPO_PRESENT}" = "true" ]; then
        log "Reusing the existing DocumentDB DNF repository configuration."
    else
        write_root_file "$(system_path /etc/yum.repos.d/documentdb.repo)" \
            0644 "${DESIRED_DOCUMENTDB_RPM_REPO}"
    fi

    run_root_no_stdin dnf clean expire-cache
    run_root_no_stdin dnf -y makecache --refresh
    run_root_no_stdin dnf install -y "documentdb-${PG_MAJOR}"
}

run_setup() {
    [ "${DRY_RUN}" = "true" ] || command_exists documentdb-setup ||
        die "Package installation completed, but documentdb-setup is not on PATH."

    log "Provisioning the DocumentDB instance with documentdb-setup:"
    setup_password_file="${ADMIN_PASSWORD_FILE}"
    [ "${DRY_RUN}" = "false" ] || setup_password_file="<temporary-password-file>"

    if [ "${NO_ENABLE}" = "true" ]; then
        run_root_no_stdin documentdb-setup --yes \
            --pg-version "${PG_MAJOR}" --use-new-postgres-instance \
            --admin-user "${ADMIN_USER}" \
            --admin-password-file "${setup_password_file}" \
            --listen-port "${LISTEN_PORT}" --no-enable || setup_failed
        return 0
    fi
    run_root_no_stdin documentdb-setup --yes \
        --pg-version "${PG_MAJOR}" --use-new-postgres-instance \
        --admin-user "${ADMIN_USER}" \
        --admin-password-file "${setup_password_file}" \
        --listen-port "${LISTEN_PORT}" || setup_failed
    run_root_no_stdin documentdb-setup --status --pg-version "${PG_MAJOR}" ||
        die "Setup completed, but the instance is not reporting a healthy status. Diagnose it with documentdb-setup and systemctl."
}

setup_failed() {
    warn "The packages remain installed, but documentdb-setup did not complete."
    warn "After resolving the reported error, resume with:"
    warn "  sudo documentdb-setup --yes --pg-version ${PG_MAJOR} --use-new-postgres-instance --admin-user ${ADMIN_USER} --admin-password-file <file> --listen-port ${LISTEN_PORT}$([ "${NO_ENABLE}" = "true" ] && printf ' --no-enable' || printf '')"
    exit 1
}

print_success() {
    [ "${DRY_RUN}" = "false" ] || return 0
    log "DocumentDB is installed."
    if [ "${NO_ENABLE}" = "true" ]; then
        printf '  Start it: sudo systemctl enable --now documentdb-local@%s.target\n' "${PG_MAJOR}"
    else
        printf '  Gateway:  127.0.0.1:%s (TLS, self-signed certificate)\n' "${LISTEN_PORT}"
        printf '  User:     %s\n' "${ADMIN_USER}"
    fi
    printf '  Status:   sudo documentdb-setup --status --pg-version %s\n' "${PG_MAJOR}"
}

perform_installation() {
    if [ "${SETUP_CONFIGURED}" = "true" ]; then
        if [ "${PACKAGES_ONLY}" = "true" ]; then
            log "documentdb-${PG_MAJOR} is installed and the instance is already configured; nothing to do."
            return 0
        fi
        log "PostgreSQL ${PG_MAJOR} already has a configured DocumentDB instance; reporting its status instead of running setup again."
        run_root_no_stdin documentdb-setup --status --pg-version "${PG_MAJOR}" ||
            die "The configured instance is not healthy. Diagnose it with documentdb-setup and systemctl; this bootstrap never reruns setup or changes credentials."
        return 0
    fi

    if [ "${SELECTED_PACKAGE_INSTALLED}" = "true" ]; then
        log "Reusing the installed documentdb-${PG_MAJOR} package."
    elif [ "${PACKAGE_FAMILY}" = "apt" ]; then
        install_ubuntu
    else
        install_rhel_family
    fi

    if [ "${PACKAGES_ONLY}" = "true" ]; then
        if [ "${DRY_RUN}" = "false" ]; then
            log "DocumentDB packages are installed."
            printf '  Next: sudo documentdb-setup --pg-version %s --use-new-postgres-instance --admin-user %s\n' \
                "${PG_MAJOR}" "${ADMIN_USER}"
        fi
        return 0
    fi

    run_setup
    print_success
}

main() {
    parse_arguments "$@"
    initialize_environment
    validate_arguments
    detect_platform
    validate_native_environment
    determine_privilege_mode
    create_temp_dir
    stage_supplied_password_file
    detect_installation_state

    if [ "${TESTING}" = "true" ] && [ "${TEST_VALIDATION_ONLY}" = "true" ]; then
        validate_required_setup_inputs
        log "Validation-only test complete; nothing was changed."
        return 0
    fi

    if [ "${SETUP_CONFIGURED}" = "false" ] &&
        [ "${SELECTED_PACKAGE_INSTALLED}" = "false" ]; then
        preflight_repositories
    fi
    print_plan
    validate_required_setup_inputs

    if [ "${DRY_RUN}" = "true" ]; then
        perform_installation
        log "Dry run complete; no changes were made."
        return 0
    fi

    acquire_privileges
    acquire_install_lock
    # Another installer may have finished while this one waited for the lock,
    # so the derived state is recomputed before anything is changed.
    detect_installation_state
    if [ "${SETUP_CONFIGURED}" = "false" ]; then
        confirm_plan
        [ "${PACKAGES_ONLY}" = "true" ] || prompt_password_file
    fi
    perform_installation
}

# BEGIN EXECUTION BARRIER
# The final outer closing brace is the last byte of this file. Every strict
# byte prefix is therefore syntactically incomplete and cannot invoke main, so
# a truncated download cannot half-install this host.
{
    {
        main "$@"
    }
}