#!/bin/bash
# Smoke test the published Copr packages end-to-end inside a fresh container.
#
# Installs the extension package and `documentdb-gateway` side by side and
# drives an authenticated CRUD round-trip via PyMongo. This validates
# the design's lean-daemon promise: the gateway must work against a
# separately-managed PostgreSQL, and neither package may silently pull in
# any appliance subpackage.
#
# TODO: when the `documentdb-local-N` appliance subpackage lands (see
# packaging-design.md §4.4 and the matching TODO in the RPM spec), reintroduce
# an appliance install path here so both flows can be exercised.
#
# Steps performed in the container:
#   1. Launch a container for the requested Copr chroot (Fedora or EL9).
#   2. Enable any external repos required by the chroot (PGDG, EPEL, CRB).
#   3. Enable the Copr repo and install the extension + gateway packages.
#   4. Provision an isolated PostgreSQL cluster directly (no local overlay).
#   5. Run the packaged gateway as its service user and check TLS CRUD.
#   6. Retain package provenance, configuration, and runtime logs.
#
# Usage:
#   ./packaging/copr/test_copr_install.sh [options]
#
# Options:
#   --copr OWNER/PROJECT      Copr project to enable
#                             (default: xgerman/DocumentDB).
#   --chroot CHROOT           fedora-43-x86_64 (default), fedora-45-x86_64,
#                             fedora-42-x86_64, or epel-9-x86_64.
#   --image IMAGE             Override the container image (otherwise inferred
#                             from --chroot).
#   --package-version EVR     Select an exact version-release for both packages.
#   --username NAME           Application MongoDB user (default: cloudsa).
#   --password PASSWORD       Password for the user (default:
#                             DocDbCoprSmoke!23).
#   --keep-container          Do not auto-remove the container; print its id.
#   --output-dir DIR          Directory for logs (default: a fresh /tmp dir).
#   --systemd                 Boot systemd in a privileged, private-cgroup
#                             container and test the packaged service units.
#   -h, --help                Show this help.

set -euo pipefail

COPR_PROJECT="xgerman/DocumentDB"
CHROOT="fedora-43-x86_64"
IMAGE=""
PACKAGE_VERSION=""
USERNAME="cloudsa"
PASSWORD="DocDbCoprSmoke!23"
KEEP_CONTAINER=0
OUTPUT_DIR=""
USE_SYSTEMD=0

usage() {
    sed -n '2,/^set -euo pipefail/{ /^set -euo pipefail/d; p; }' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --copr) shift; COPR_PROJECT="$1" ;;
        --chroot) shift; CHROOT="$1" ;;
        --image) shift; IMAGE="$1" ;;
        --package-version) shift; PACKAGE_VERSION="$1" ;;
        --username) shift; USERNAME="$1" ;;
        --password) shift; PASSWORD="$1" ;;
        --keep-container) KEEP_CONTAINER=1 ;;
        --output-dir) shift; OUTPUT_DIR="$1" ;;
        --systemd) USE_SYSTEMD=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ ! "${COPR_PROJECT}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: --copr value '${COPR_PROJECT}' must be OWNER/PROJECT" >&2
    exit 2
fi

case "${CHROOT}" in
    fedora-43-x86_64) DEFAULT_IMAGE="fedora:43" ;;
    fedora-45-x86_64) DEFAULT_IMAGE="fedora:45" ;;
    fedora-42-x86_64) DEFAULT_IMAGE="fedora:42" ;;
    epel-9-x86_64)    DEFAULT_IMAGE="rockylinux/rockylinux:9" ;;
    *) echo "ERROR: unsupported --chroot '${CHROOT}'" >&2; exit 2 ;;
esac

IMAGE="${IMAGE:-${DEFAULT_IMAGE}}"

# Pin the PG major the spec targets.  The `postgresql<NN>-documentdb` PGDG
# extension name keys off this.
PGVERSION=18

# Compute the extension package name for this chroot, matching the
# `postgresql_default` conditional in the spec:
#   - Fedora 43+ uses native PG 18 -> unversioned `documentdb`.
#   - Older Fedora and EL9 use PGDG -> `postgresql<NN>-documentdb`.
case "${CHROOT}" in
    fedora-43-x86_64|fedora-45-x86_64) EXT_PKG="documentdb" ;;
    *)                EXT_PKG="postgresql${PGVERSION}-documentdb" ;;
esac

echo "=== Copr install + gateway smoke test ==="
echo "Copr project : ${COPR_PROJECT}"
echo "Chroot       : ${CHROOT}"
echo "Image        : ${IMAGE}"
echo "Extension pkg: ${EXT_PKG}"
echo "Username     : ${USERNAME}"

# The inner script runs entirely inside the container. It receives:
#   $1 = COPR_PROJECT, $2 = CHROOT, $3 = USERNAME, $4 = PASSWORD,
#   $5 = EXT_PKG (extension package name), $6 = PACKAGE_VERSION (optional).
INNER_SCRIPT='
set -euo pipefail

COPR_PROJECT="$1"
CHROOT="$2"
USERNAME="$3"
PASSWORD="$4"
EXT_PKG="$5"
PACKAGE_VERSION="$6"
GATEWAY_PORT=10260
ARTIFACTS=/var/tmp/copr-artifacts
mkdir -p "${ARTIFACTS}"

log() { echo "[copr-smoke] $*"; }
fail() { echo "[copr-smoke] ERROR: $*" >&2; exit 1; }

cleanup() {
    local result=$?
    trap - EXIT
    if [[ -d /run/systemd/system ]]; then
        journalctl -u documentdb-gateway.service --no-pager > "${ARTIFACTS}/gateway.log"
        systemctl stop documentdb-gateway.service || true
        if [[ -n "${PG_SERVICE:-}" ]]; then
            systemctl stop "${PG_SERVICE}" || true
            journalctl -u "${PG_SERVICE}" --no-pager > "${ARTIFACTS}/postgres-final.log"
        fi
    elif [[ -n "${GATEWAY_PID:-}" ]]; then
        kill "${GATEWAY_PID}" 2>/dev/null || true
        wait "${GATEWAY_PID}" 2>/dev/null || true
    fi
    if [[ -n "${PG_BIN:-}" && -s /var/lib/pgsql/copr-smoke/postmaster.pid ]]; then
        runuser -u postgres -- "${PG_BIN}/pg_ctl" -D /var/lib/pgsql/copr-smoke -m fast -w stop || true
    fi
    if (( result != 0 )); then
        for logfile in "${ARTIFACTS}"/*.log; do
            [[ -f "${logfile}" ]] || continue
            echo "----- ${logfile} -----"
            tail -n 100 "${logfile}"
        done
    fi
    printf "%s\n" "${result}" > "${ARTIFACTS}/exit-code"
    exit "${result}"
}
trap cleanup EXIT

if rpm -qa | grep -Eq "^(documentdb|postgresql[0-9]+-documentdb)"; then
    fail "base image already contains DocumentDB"
fi
cat /etc/os-release | tee "${ARTIFACTS}/os-release"
log "Container PID 1: $(cat /proc/1/comm); cgroup mount: $(stat -f -c %T /sys/fs/cgroup)"

log "Installing base tooling."
dnf install -y dnf-plugins-core procps-ng iproute findutils

case "${CHROOT}" in
    epel-9-x86_64)
        log "Enabling EPEL, CRB, and PGDG for EL9."
        dnf install -y epel-release
        dnf config-manager --set-enabled crb
        dnf -qy module disable postgresql >/dev/null 2>&1 || true
        dnf install -y --nogpgcheck \
            https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
        ;;
    fedora-42-x86_64)
        log "Enabling PGDG for Fedora 42."
        dnf install -y --nogpgcheck \
            https://download.postgresql.org/pub/repos/yum/reporpms/F-42-x86_64/pgdg-fedora-repo-latest.noarch.rpm
        ;;
    fedora-43-x86_64|fedora-45-x86_64)
        log "Using native Fedora PostgreSQL 18 (no external repos required)."
        ;;
esac

log "Enabling Copr project ${COPR_PROJECT}."
dnf copr enable -y "${COPR_PROJECT}"
dnf install -y python3-pymongo

log "Installing the extension (${EXT_PKG}) and documentdb-gateway."
COPR_REPO="copr:copr.fedorainfracloud.org:${COPR_PROJECT/\//:}"
dnf repoquery --repo="${COPR_REPO}" --location "${EXT_PKG}" documentdb-gateway \
    | tee "${ARTIFACTS}/copr-package-urls.txt"
PACKAGE_SUFFIX="${PACKAGE_VERSION:+-${PACKAGE_VERSION}}"
dnf install -y --setopt=install_weak_deps=False "${EXT_PKG}${PACKAGE_SUFFIX}" "documentdb-gateway${PACKAGE_SUFFIX}"
dnf info --installed "${EXT_PKG}" documentdb-gateway | tee "${ARTIFACTS}/package-origin.txt"
[[ $(grep -c "From repo.*${COPR_REPO}" "${ARTIFACTS}/package-origin.txt") -eq 2 ]] \
    || fail "both packages must originate from ${COPR_REPO}"
rpm -q --qf "%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n" "${EXT_PKG}" documentdb-gateway \
    | tee "${ARTIFACTS}/versions.txt"
rpm -qa | sort > "${ARTIFACTS}/installed-rpms.txt"
rpm -V "${EXT_PKG}" documentdb-gateway > "${ARTIFACTS}/rpm-verify.txt"
dnf check
if rpm -qa | grep -Eq "^documentdb-(local-|tools-)"; then
    fail "unexpected appliance/tools dependency"
fi

rpm -q documentdb-gateway >/dev/null || fail "documentdb-gateway was not installed"
command -v documentdb-gateway
getent passwd documentdb-gateway | tee "${ARTIFACTS}/service-user.txt"
stat -c "%a %U:%G %n" /var/lib/documentdb-gateway /run/documentdb-gateway \
    | tee "${ARTIFACTS}/layout.txt"
cp /usr/lib/systemd/system/documentdb-gateway.service "${ARTIFACTS}/"
cp /etc/documentdb/gateway/gateway.env "${ARTIFACTS}/gateway.env.packaged"
systemd-analyze verify /usr/lib/systemd/system/documentdb-gateway.service \
    > "${ARTIFACTS}/unit-verify.log" 2>&1
documentdb-gateway --version | tee "${ARTIFACTS}/gateway-version.txt"

case "${CHROOT}" in
    fedora-43-x86_64|fedora-45-x86_64)
        PG_BIN=/usr/bin
        PG_SERVICE=postgresql.service
        ;;
    *)
        PG_BIN=/usr/pgsql-18/bin
        PG_SERVICE=postgresql-18.service
        ;;
esac
"${PG_BIN}/postgres" --version | tee "${ARTIFACTS}/postgres-version.txt"
install -d -m 0700 -o postgres -g postgres /var/lib/pgsql/copr-smoke
install -d -m 0755 -o postgres -g postgres /run/postgresql
runuser -u postgres -- "${PG_BIN}/initdb" -D /var/lib/pgsql/copr-smoke \
    --auth-local=trust --auth-host=trust > "${ARTIFACTS}/initdb.log" 2>&1
cat >> /var/lib/pgsql/copr-smoke/postgresql.conf <<CONF
listen_addresses = '\''127.0.0.1'\''
port = 5432
unix_socket_directories = '\''/var/run/postgresql'\''
logging_collector = off
shared_preload_libraries = '\''pg_cron,pg_documentdb_core,pg_documentdb,pg_documentdb_extended_rum'\''
cron.database_name = '\''postgres'\''
CONF
if [[ -d /run/systemd/system ]]; then
    install -d "/etc/systemd/system/${PG_SERVICE}.d"
    printf "%s\n" "[Service]" "Environment=PGDATA=/var/lib/pgsql/copr-smoke" \
        > "/etc/systemd/system/${PG_SERVICE}.d/copr-smoke.conf"
    systemctl daemon-reload
    systemctl start "${PG_SERVICE}"
    systemctl is-active "${PG_SERVICE}"
    systemctl cat "${PG_SERVICE}" > "${ARTIFACTS}/postgresql-unit.txt"
else
    runuser -u postgres -- "${PG_BIN}/pg_ctl" -D /var/lib/pgsql/copr-smoke \
        -l /var/lib/pgsql/copr-smoke/postgres.log -w start
    ln -s /var/lib/pgsql/copr-smoke/postgres.log "${ARTIFACTS}/postgres.log"
fi
"${PG_BIN}/psql" -X -h /var/run/postgresql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    -v username="${USERNAME}" -v password="${PASSWORD}" <<\SQL | tee "${ARTIFACTS}/extension-setup.log"
CREATE EXTENSION documentdb CASCADE;
CREATE EXTENSION documentdb_extended_rum CASCADE;
CREATE ROLE "documentdb-gateway" WITH LOGIN SUPERUSER;
SELECT documentdb_api.create_user(json_build_object(
    '\''createUser'\'', :'\''username'\'', '\''pwd'\'', :'\''password'\'',
    '\''roles'\'', json_build_array(
        json_build_object('\''role'\'', '\''readWriteAnyDatabase'\'', '\''db'\'', '\''admin'\''),
        json_build_object('\''role'\'', '\''clusterAdmin'\'', '\''db'\'', '\''admin'\'')))::text::documentdb_core.bson);
SELECT extname, extversion FROM pg_extension ORDER BY extname;
SHOW shared_preload_libraries;
SQL
printf "%s\n" "postgresql://documentdb-gateway@localhost:5432/postgres?host=/var/run/postgresql" \
    > /var/lib/documentdb-gateway/pg-url
chown root:documentdb-gateway /var/lib/documentdb-gateway/pg-url
chmod 0640 /var/lib/documentdb-gateway/pg-url
printf "%s\n" "DOCUMENTDB_PG_URL_FILE=/var/lib/documentdb-gateway/pg-url" \
    "DOCUMENTDB_LISTEN_ADDR=127.0.0.1:${GATEWAY_PORT}" \
    >> /etc/documentdb/gateway/gateway.env
cp /etc/documentdb/gateway/gateway.env "${ARTIFACTS}/gateway.env.configured"
cd /var/lib/documentdb-gateway
documentdb-gateway --check 2>&1 | tee "${ARTIFACTS}/gateway-check.log"
if [[ -d /run/systemd/system ]]; then
    log "Starting the packaged gateway unit under systemd."
    systemctl start documentdb-gateway.service
    systemctl is-active documentdb-gateway.service
    systemctl show documentdb-gateway.service \
        -p ActiveState -p SubState -p User -p Group -p ExecStart -p WorkingDirectory \
        -p NoNewPrivileges -p ProtectSystem -p PrivateTmp -p MemoryDenyWriteExecute \
        > "${ARTIFACTS}/gateway-service.txt"
    GATEWAY_PID=$(systemctl show documentdb-gateway.service -p MainPID --value)
else
    log "Starting packaged ExecStart manually as the service user; not a systemd boot test."
    runuser -u documentdb-gateway -- /usr/bin/documentdb-gateway run \
        > "${ARTIFACTS}/gateway.log" 2>&1 &
    GATEWAY_PID=$!
fi
env DOCUMENTDB_USERNAME="${USERNAME}" DOCUMENTDB_PASSWORD="${PASSWORD}" \
    python3 - <<\PY | tee "${ARTIFACTS}/crud.log"
import os
from pymongo import MongoClient

client = MongoClient("127.0.0.1", 10260,
    username=os.environ["DOCUMENTDB_USERNAME"],
    password=os.environ["DOCUMENTDB_PASSWORD"],
    authSource="admin", authMechanism="SCRAM-SHA-256",
    tls=True, tlsAllowInvalidCertificates=True,
    serverSelectionTimeoutMS=60000, connectTimeoutMS=10000, socketTimeoutMS=30000,
    retryWrites=False)
assert client.admin.command("ping")["ok"] == 1
print("PING_OK")
collection = client.coprSmokeDb.smoke
collection.drop()
assert collection.insert_many([
    {"_id": 1, "name": "first", "value": 10},
    {"_id": 2, "name": "second", "value": 20},
]).acknowledged
assert collection.find_one({"_id": 1})["value"] == 10
assert collection.count_documents({}) == 2
print("CREATE_READ_OK")
assert collection.update_one({"_id": 1}, {"$set": {"value": 15}}).modified_count == 1
assert collection.find_one({"_id": 1})["value"] == 15
print("UPDATE_OK")
collection.create_index("value")
assert list(collection.aggregate([{"$group": {"_id": None, "total": {"$sum": "$value"}}}]))[0]["total"] == 35
print("INDEX_AGGREGATE_OK")
assert collection.delete_one({"_id": 2}).deleted_count == 1
assert collection.count_documents({}) == 1
assert collection.delete_many({}).deleted_count == 1
assert collection.count_documents({}) == 0
print("DELETE_OK")
client.drop_database("coprSmokeDb")
client.close()
print("SMOKE_OK")
PY
kill -0 "${GATEWAY_PID}"
if [[ -d /run/systemd/system ]]; then
    systemctl is-active "${PG_SERVICE}" documentdb-gateway.service
else
    cp -L /var/lib/pgsql/copr-smoke/postgres.log "${ARTIFACTS}/postgres-final.log"
fi
stat -c "%a %U:%G %n" /var/lib/documentdb-gateway/tls/* \
    | tee "${ARTIFACTS}/tls-files.txt"

log "Copr install + gateway smoke test PASSED."
'

OUTPUT_DIR="${OUTPUT_DIR:-$(mktemp -d /tmp/documentdb-copr-smoke.XXXXXX)}"
mkdir -p "${OUTPUT_DIR}"
CONTAINER_NAME="documentdb-copr-smoke-${CHROOT}-$$"
cleanup_container() {
    local result=$?
    trap - EXIT
    docker logs "${CONTAINER_NAME}" > "${OUTPUT_DIR}/container.log" 2>&1 || true
    if ! docker cp "${CONTAINER_NAME}:/var/tmp/copr-artifacts/." "${OUTPUT_DIR}/"; then
        echo "ERROR: failed to preserve container test artifacts" >&2
        result=1
    fi
    docker cp "${CONTAINER_NAME}:/var/lib/pgsql/copr-smoke/postgres.log" "${OUTPUT_DIR}/postgres.log" 2>/dev/null || true
    if (( KEEP_CONTAINER )); then
        echo "Container retained: ${CONTAINER_NAME}"
    else
        docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    fi
    echo "Artifacts: ${OUTPUT_DIR}"
    exit "${result}"
}
trap cleanup_container EXIT
if (( USE_SYSTEMD )); then
    docker run -d --name "${CONTAINER_NAME}" --privileged --cgroupns=private \
        --tmpfs /run --tmpfs /tmp -e container=docker -e LANG=C.UTF-8 \
        "${IMAGE}" bash -c \
        "dnf install -y --setopt=install_weak_deps=False systemd && exec /usr/lib/systemd/systemd"
    BOOT_STARTED=${SECONDS}
    until docker exec "${CONTAINER_NAME}" systemctl is-active multi-user.target >/dev/null 2>&1; do
        if (( SECONDS - BOOT_STARTED >= 180 )) || \
            [[ $(docker inspect --format "{{.State.Running}}" "${CONTAINER_NAME}") != true ]]; then
            docker logs "${CONTAINER_NAME}"
            echo "ERROR: container failed to boot systemd" >&2
            exit 1
        fi
    done
    docker exec "${CONTAINER_NAME}" bash -c "${INNER_SCRIPT}" _ \
        "${COPR_PROJECT}" "${CHROOT}" "${USERNAME}" "${PASSWORD}" "${EXT_PKG}" "${PACKAGE_VERSION}"
else
    docker run --name "${CONTAINER_NAME}" -e LANG=C.UTF-8 "${IMAGE}" \
        bash -c "${INNER_SCRIPT}" _ \
        "${COPR_PROJECT}" "${CHROOT}" "${USERNAME}" "${PASSWORD}" "${EXT_PKG}" "${PACKAGE_VERSION}"
fi

echo
echo "Smoke test passed."
