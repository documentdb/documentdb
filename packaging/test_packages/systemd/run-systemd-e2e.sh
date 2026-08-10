#!/bin/bash
# Host-side driver for the systemd lifecycle E2E.
#
# Builds a systemd-as-PID-1 container from the freshly built .deb packages,
# then drives the staged suite inside it. The container is restarted partway
# through -- that `docker restart` IS the reboot test, which is the whole
# reason this harness exists: it is the one thing the regular E2E image cannot
# do, and it is the path every real user's host takes every time it boots.
#
# Usage:
#   ./run-systemd-e2e.sh [--pg 18] [--packages-dir DIR] [--keep] [--os ubuntu24.04]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SCRIPT_DIR is oss/packaging/test_packages/systemd — three levels below
# the oss root (a ../.. here once resolved to oss/packaging and made the
# default --packages-dir a nonexistent oss/packaging/packaging, which
# emptied every glob below and let the bare `ls -1` fall back to listing
# the current directory).
OSS_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

PG_MAJOR="18"
OS_PREFIX="ubuntu24.04"
PACKAGES_DIR="${OSS_ROOT}/packaging"
KEEP=false
IMAGE="documentdb-systemd-e2e:latest"
CONTAINER="documentdb-systemd-e2e"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pg)           PG_MAJOR="$2"; shift 2 ;;
        --os)           OS_PREFIX="$2"; shift 2 ;;
        --packages-dir) PACKAGES_DIR="$2"; shift 2 ;;
        --keep)         KEEP=true; shift ;;
        -h|--help)      sed -n '1,20p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

log()  { echo -e "\033[1;36m[systemd-e2e-driver]\033[0m $*"; }
die()  { echo -e "\033[1;31m[systemd-e2e-driver] ERROR:\033[0m $*" >&2; exit 1; }

cleanup() {
    if [[ "${KEEP}" != "true" ]]; then
        docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    else
        log "Leaving container '${CONTAINER}' running (--keep)."
    fi
}
trap cleanup EXIT

# ── Stage the packages the image will install ───────────────────────
STAGING="${SCRIPT_DIR}/pkgs"
rm -rf "${STAGING}"; mkdir -p "${STAGING}"

# The six packages a real `apt install documentdb` resolves: extension,
# gateway, tools, common, per-major stand-alone, and the meta package.
# Expand the globs into an array FIRST (nullglob drops empty patterns) —
# never hand them to `ls`, which with zero surviving arguments lists the
# current directory and staged this script's own files into the image.
shopt -s nullglob
found=(
    "${PACKAGES_DIR}/${OS_PREFIX}-postgresql-${PG_MAJOR}-documentdb_"*.deb
    "${PACKAGES_DIR}/${OS_PREFIX}-documentdb-gateway_"*.deb
    "${PACKAGES_DIR}/${OS_PREFIX}-documentdb-postgresql-tools_"*.deb
    "${PACKAGES_DIR}/${OS_PREFIX}-documentdb-common_"*.deb
    "${PACKAGES_DIR}/${OS_PREFIX}-documentdb-${PG_MAJOR}_"*.deb
    "${PACKAGES_DIR}/${OS_PREFIX}-documentdb_"*.deb
)
shopt -u nullglob

(( ${#found[@]} > 0 )) || die "No .deb packages found under ${PACKAGES_DIR} for ${OS_PREFIX}/pg${PG_MAJOR}. Build them first (see oss/packaging/README.md)."

for f in "${found[@]}"; do
    cp "${f}" "${STAGING}/"
    log "staged $(basename "${f}")"
done

# ── Build + boot ────────────────────────────────────────────────────
log "Building systemd test image..."
docker build -q \
    --build-arg "POSTGRES_VERSION=${PG_MAJOR}" \
    -f "${SCRIPT_DIR}/Dockerfile-systemd-deb-test" \
    -t "${IMAGE}" "${SCRIPT_DIR}" >/dev/null || die "image build failed"

docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
log "Booting systemd container..."
docker run -d --name "${CONTAINER}" \
    --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock \
    "${IMAGE}" >/dev/null || die "container failed to start"

wait_for_systemd() {
    local label="$1"
    for _ in $(seq 1 60); do
        local state
        state="$(docker exec "${CONTAINER}" systemctl is-system-running 2>&1 || true)"
        case "${state}" in
            running|degraded) log "${label}: systemd is up (${state})"; return 0 ;;
        esac
        sleep 2
    done
    docker logs --tail 40 "${CONTAINER}" >&2 || true
    die "${label}: systemd did not finish booting"
}
wait_for_systemd "boot"

run_stage() {
    local stage="$1"
    log "── stage: ${stage}"
    if ! docker exec -e "PG_MAJOR=${PG_MAJOR}" "${CONTAINER}" \
            /usr/local/bin/test-systemd-lifecycle.sh "${stage}"; then
        die "stage '${stage}' FAILED"
    fi
}

# ── Drive the lifecycle ─────────────────────────────────────────────
run_stage install
run_stage setup
run_stage verify
run_stage seed
run_stage restart
run_stage stopstart
# stopstart left the target stopped-then-started; make sure it is serving
# again before we pull the power.
run_stage verify
run_stage upgrade

log "══ REBOOT (docker restart) ══"
docker restart -t 30 "${CONTAINER}" >/dev/null || die "container restart failed"
wait_for_systemd "post-reboot"

# Nothing is run by hand here -- if the stack is not back, boot enablement is broken.
run_stage post-reboot
run_stage day2
run_stage bad-password
run_stage restore
# Destructive to the gateway package, so it runs last.
run_stage enablement

log "All systemd lifecycle stages PASSED."
