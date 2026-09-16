#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

set -euo pipefail

: "${PACKAGE_TYPE:?PACKAGE_TYPE is required}"
: "${PG_MAJOR:?PG_MAJOR is required}"
: "${REPOSITORY_KEY_FINGERPRINT:?REPOSITORY_KEY_FINGERPRINT is required}"

REPOSITORY_ORIGIN="https://127.0.0.1:8443"
PASSWORD_FILE="/root/documentdb-installer-e2e-password"
INSTALL_LOG="/var/tmp/documentdb-installer-e2e.log"

for _ in $(seq 1 60); do
    if curl -fsS "${REPOSITORY_ORIGIN}/documentdb-archive-keyring.gpg" >/dev/null; then
        break
    fi
    sleep 1
done
curl -fsS "${REPOSITORY_ORIGIN}/documentdb-archive-keyring.gpg" >/dev/null

openssl rand -base64 24 > "${PASSWORD_FILE}"
chmod 0600 "${PASSWORD_FILE}"

if ! env \
    DOCUMENTDB_INSTALLER_TEST_REPOSITORY_MODE=true \
    DOCUMENTDB_INSTALLER_TEST_APT_REPOSITORY_URL="${REPOSITORY_ORIGIN}/deb" \
    DOCUMENTDB_INSTALLER_TEST_RPM_REPOSITORY_URL="${REPOSITORY_ORIGIN}/rpm/rhel9" \
    DOCUMENTDB_INSTALLER_TEST_KEY_URL="${REPOSITORY_ORIGIN}/documentdb-archive-keyring.gpg" \
    DOCUMENTDB_INSTALLER_TEST_KEY_FINGERPRINT="${REPOSITORY_KEY_FINGERPRINT}" \
    sh /opt/documentdb-installer/install.sh \
        --yes \
        --pg-major "${PG_MAJOR}" \
        --admin-user e2eadmin \
        --admin-password-file "${PASSWORD_FILE}" \
        --accept-external-listen > "${INSTALL_LOG}" 2>&1; then
    tail -100 "${INSTALL_LOG}" >&2
    exit 1
fi

grep -Fq "DocumentDB is installed." "${INSTALL_LOG}"
documentdb-setup --status --pg-version "${PG_MAJOR}"
systemctl is-active --quiet "documentdb-postgresql@${PG_MAJOR}.service"
systemctl is-active --quiet "documentdb-gateway-local@${PG_MAJOR}.service"

for _ in $(seq 1 30); do
    if ss -ltn "sport = :10260" 2>/dev/null | grep -q ':10260'; then
        break
    fi
    sleep 1
done
ss -ltn "sport = :10260" 2>/dev/null | grep -q ':10260'

if ! timeout 15 openssl s_client \
        -connect 127.0.0.1:10260 -showcerts < /dev/null \
        > /var/tmp/documentdb-installer-endpoint.log 2>&1; then
    cat /var/tmp/documentdb-installer-endpoint.log >&2
    exit 1
fi
grep -Fq -- "-----BEGIN CERTIFICATE-----" \
    /var/tmp/documentdb-installer-endpoint.log

env \
    DOCUMENTDB_INSTALLER_TEST_REPOSITORY_MODE=true \
    DOCUMENTDB_INSTALLER_TEST_APT_REPOSITORY_URL="${REPOSITORY_ORIGIN}/deb" \
    DOCUMENTDB_INSTALLER_TEST_RPM_REPOSITORY_URL="${REPOSITORY_ORIGIN}/rpm/rhel9" \
    DOCUMENTDB_INSTALLER_TEST_KEY_URL="${REPOSITORY_ORIGIN}/documentdb-archive-keyring.gpg" \
    DOCUMENTDB_INSTALLER_TEST_KEY_FINGERPRINT="${REPOSITORY_KEY_FINGERPRINT}" \
    sh /opt/documentdb-installer/install.sh \
        --yes \
        --pg-major "${PG_MAJOR}" \
        --admin-password-file "${PASSWORD_FILE}" \
        --accept-external-listen \
        > /var/tmp/documentdb-installer-second-run.log 2>&1
grep -Fq "reporting its status instead of running setup again" \
    /var/tmp/documentdb-installer-second-run.log

printf 'Installer E2E passed for %s on %s\n' "${PACKAGE_TYPE}" "$(uname -m)"
