#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSS_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

PACKAGE_TYPE=""
PG_MAJOR=""
ARCH=""
OS_PREFIX=""
PACKAGES_DIR="${OSS_ROOT}/packaging"

usage() {
    cat <<'EOF'
Usage: run-installer-e2e.sh --type <deb|rpm> --pg <17|18> \
    --arch <amd64|arm64> --os-prefix <PREFIX> [--packages-dir DIR]
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type) PACKAGE_TYPE="$2"; shift 2 ;;
        --pg) PG_MAJOR="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --os-prefix) OS_PREFIX="$2"; shift 2 ;;
        --packages-dir) PACKAGES_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "${PACKAGE_TYPE}" in deb|rpm) ;; *) echo "--type must be deb or rpm" >&2; exit 2 ;; esac
case "${PG_MAJOR}" in 17|18) ;; *) echo "--pg must be 17 or 18" >&2; exit 2 ;; esac
case "${ARCH}" in amd64|arm64) ;; *) echo "--arch must be amd64 or arm64" >&2; exit 2 ;; esac
[[ -n "${OS_PREFIX}" ]] || { echo "--os-prefix is required" >&2; exit 2; }
[[ -d "${PACKAGES_DIR}" ]] || { echo "Package directory not found: ${PACKAGES_DIR}" >&2; exit 1; }

case "$(uname -m):${ARCH}" in
    x86_64:amd64|amd64:amd64|aarch64:arm64|arm64:arm64) ;;
    *) echo "Native runner architecture $(uname -m) does not match requested ${ARCH}." >&2; exit 1 ;;
esac

for command in docker gpg openssl; do
    command -v "${command}" >/dev/null 2>&1 ||
        { echo "Required command not found: ${command}" >&2; exit 1; }
done
if [[ "${PACKAGE_TYPE}" == "deb" ]]; then
    for command in apt-ftparchive dpkg-scanpackages dpkg-deb; do
        command -v "${command}" >/dev/null 2>&1 ||
            { echo "Required command not found: ${command}" >&2; exit 1; }
    done
else
    for command in createrepo_c rpm rpmsign; do
        command -v "${command}" >/dev/null 2>&1 ||
            { echo "Required command not found: ${command}" >&2; exit 1; }
    done
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/documentdb-installer-e2e.XXXXXX")"
GNUPG_HOME="${WORK_DIR}/gnupg"
CONTEXT_DIR="${WORK_DIR}/context"
REPOSITORY_DIR="${CONTEXT_DIR}/repository"
IMAGE="documentdb-installer-e2e-${PACKAGE_TYPE}-${ARCH}-$$"
CONTAINER="documentdb-installer-e2e-${PACKAGE_TYPE}-${ARCH}-$$"

cleanup() {
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    docker image rm -f "${IMAGE}" >/dev/null 2>&1 || true
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

mkdir -m 0700 "${GNUPG_HOME}"
mkdir -p "${REPOSITORY_DIR}"

cat > "${WORK_DIR}/gpg-batch" <<'EOF'
Key-Type: RSA
Key-Length: 3072
Name-Real: DocumentDB installer E2E
Name-Email: installer-e2e@example.invalid
Expire-Date: 1d
%no-protection
%commit
EOF
GNUPGHOME="${GNUPG_HOME}" gpg --batch --generate-key "${WORK_DIR}/gpg-batch"
KEY_FINGERPRINT="$(
    GNUPGHOME="${GNUPG_HOME}" gpg --batch --with-colons --list-keys |
        awk -F: '$1 == "fpr" { print toupper($10); exit }'
)"
[[ "${#KEY_FINGERPRINT}" -eq 40 ]] ||
    { echo "Could not determine test repository key fingerprint." >&2; exit 1; }
GNUPGHOME="${GNUPG_HOME}" gpg --batch --armor --export "${KEY_FINGERPRINT}" \
    > "${REPOSITORY_DIR}/documentdb-archive-keyring.gpg"

stage_deb_package() {
    local expected="$1"
    local package package_arch
    local -a matches=()
    while IFS= read -r -d '' package; do
        [[ "$(dpkg-deb -f "${package}" Package)" == "${expected}" ]] || continue
        [[ "$(basename "${package}")" == "${OS_PREFIX}-"* ]] || continue
        package_arch="$(dpkg-deb -f "${package}" Architecture)"
        [[ "${package_arch}" == "${ARCH}" || "${package_arch}" == "all" ]] || continue
        matches+=("${package}")
    done < <(find "${PACKAGES_DIR}" -maxdepth 1 -type f -name '*.deb' -print0)
    ((${#matches[@]} == 1)) || {
        echo "Expected exactly one ${OS_PREFIX} DEB for ${expected}/${ARCH}; found ${#matches[@]}." >&2
        return 1
    }
    cp "${matches[0]}" "${POOL_DIR}/"
}

stage_rpm_package() {
    local expected="$1"
    local package package_arch package_release
    local expected_arch="x86_64"
    local expected_release=".el9"
    local -a matches=()
    [[ "${ARCH}" == "amd64" ]] || expected_arch="aarch64"
    [[ "${OS_PREFIX}" == "rhel9" ]] ||
        { echo "Unsupported RPM OS prefix: ${OS_PREFIX}" >&2; return 1; }
    while IFS= read -r -d '' package; do
        [[ "$(rpm -qp --qf '%{NAME}' "${package}")" == "${expected}" ]] || continue
        package_arch="$(rpm -qp --qf '%{ARCH}' "${package}")"
        [[ "${package_arch}" == "${expected_arch}" || "${package_arch}" == "noarch" ]] || continue
        if [[ "${expected}" == "postgresql${PG_MAJOR}-documentdb" ]]; then
            [[ "$(basename "${package}")" == "${OS_PREFIX}-"* ]] || continue
        elif [[ "${expected}" == "documentdb-gateway" ]]; then
            package_release="$(rpm -qp --qf '%{RELEASE}' "${package}")"
            [[ "${package_release}" == *"${expected_release}"* ]] || continue
        fi
        matches+=("${package}")
    done < <(find "${PACKAGES_DIR}" -maxdepth 1 -type f -name '*.rpm' -print0)
    ((${#matches[@]} == 1)) || {
        echo "Expected exactly one ${OS_PREFIX} RPM for ${expected}/${ARCH}; found ${#matches[@]}." >&2
        return 1
    }
    cp "${matches[0]}" "${RPM_DIR}/"
}

if [[ "${PACKAGE_TYPE}" == "deb" ]]; then
    DEB_ARCH="${ARCH}"
    POOL_DIR="${REPOSITORY_DIR}/deb/pool"
    INDEX_DIR="${REPOSITORY_DIR}/deb/dists/stable/ubuntu24/binary-${DEB_ARCH}"
    mkdir -p "${POOL_DIR}" "${INDEX_DIR}"

    for package in "postgresql-${PG_MAJOR}-documentdb" documentdb-gateway \
        documentdb-postgresql-tools documentdb-common "documentdb-${PG_MAJOR}"; do
        stage_deb_package "${package}" ||
            { echo "Required DEB package is missing: ${package}" >&2; exit 1; }
    done

    (
        cd "${REPOSITORY_DIR}/deb"
        dpkg-scanpackages pool /dev/null > "dists/stable/ubuntu24/binary-${DEB_ARCH}/Packages"
        gzip -9c "dists/stable/ubuntu24/binary-${DEB_ARCH}/Packages" \
            > "dists/stable/ubuntu24/binary-${DEB_ARCH}/Packages.gz"
        apt-ftparchive \
            -o APT::FTPArchive::Release::Origin=DocumentDB \
            -o APT::FTPArchive::Release::Label=DocumentDB \
            -o APT::FTPArchive::Release::Suite=stable \
            -o APT::FTPArchive::Release::Codename=stable \
            -o APT::FTPArchive::Release::Architectures="${DEB_ARCH} all" \
            -o APT::FTPArchive::Release::Components=ubuntu24 \
            release dists/stable > dists/stable/Release
        GNUPGHOME="${GNUPG_HOME}" gpg --batch --yes --local-user "${KEY_FINGERPRINT}" \
            --clearsign --output dists/stable/InRelease dists/stable/Release
        GNUPGHOME="${GNUPG_HOME}" gpg --batch --yes --local-user "${KEY_FINGERPRINT}" \
            --armor --detach-sign --output dists/stable/Release.gpg dists/stable/Release
    )
    BASE_IMAGE="ubuntu:24.04"
else
    RPM_DIR="${REPOSITORY_DIR}/rpm/rhel9"
    mkdir -p "${RPM_DIR}"

    for package in "postgresql${PG_MAJOR}-documentdb" documentdb-gateway \
        documentdb-postgresql-tools documentdb-common "documentdb-${PG_MAJOR}"; do
        stage_rpm_package "${package}" ||
            { echo "Required RPM package is missing: ${package}" >&2; exit 1; }
    done

    for package in "${RPM_DIR}"/*.rpm; do
        GNUPGHOME="${GNUPG_HOME}" rpmsign \
            --define "_gpg_name ${KEY_FINGERPRINT}" \
            --define "__gpg /usr/bin/gpg" \
            --addsign "${package}"
    done
    createrepo_c "${RPM_DIR}"
    GNUPGHOME="${GNUPG_HOME}" gpg --batch --yes --local-user "${KEY_FINGERPRINT}" \
        --armor --detach-sign \
        --output "${RPM_DIR}/repodata/repomd.xml.asc" \
        "${RPM_DIR}/repodata/repomd.xml"
    BASE_IMAGE="rockylinux:9"
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=127.0.0.1' \
    -addext 'subjectAltName=IP:127.0.0.1' \
    -keyout "${CONTEXT_DIR}/repository-server.key" \
    -out "${CONTEXT_DIR}/repository-server.crt" >/dev/null 2>&1

cp "${SCRIPT_DIR}/Dockerfile" "${CONTEXT_DIR}/Dockerfile"
cp "${SCRIPT_DIR}/installer-test-repository.service" "${CONTEXT_DIR}/installer-test-repository.service"
cp "${SCRIPT_DIR}/serve-test-repository.py" "${CONTEXT_DIR}/serve-test-repository.py"
cp "${SCRIPT_DIR}/run-inside-container.sh" "${CONTEXT_DIR}/run-inside-container.sh"
cp "${OSS_ROOT}/packaging/install.sh" "${CONTEXT_DIR}/install.sh"

docker build --pull \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    -t "${IMAGE}" "${CONTEXT_DIR}"

docker run -d --name "${CONTAINER}" \
    --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock \
    "${IMAGE}" >/dev/null

systemd_ready=false
for _ in $(seq 1 60); do
    state="$(docker exec "${CONTAINER}" systemctl is-system-running 2>/dev/null || true)"
    case "${state}" in
        running|degraded) systemd_ready=true; break ;;
    esac
    sleep 2
done
if [[ "${systemd_ready}" != "true" ]]; then
    docker logs "${CONTAINER}" >&2 || true
    docker exec "${CONTAINER}" journalctl -b --no-pager -n 200 >&2 || true
    echo "systemd did not become ready." >&2
    exit 1
fi

if ! docker exec \
        -e "PACKAGE_TYPE=${PACKAGE_TYPE}" \
        -e "PG_MAJOR=${PG_MAJOR}" \
        -e "REPOSITORY_KEY_FINGERPRINT=${KEY_FINGERPRINT}" \
        "${CONTAINER}" /usr/local/bin/run-installer-e2e.sh; then
    docker exec "${CONTAINER}" \
        sh -c 'tail -100 /var/tmp/documentdb-installer-*.log 2>/dev/null || true' >&2 || true
    docker exec "${CONTAINER}" journalctl -b --no-pager -n 300 >&2 || true
    exit 1
fi
