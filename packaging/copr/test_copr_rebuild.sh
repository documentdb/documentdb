#!/bin/bash
# Full local rebuild of a shared Fedora-produced SRPM in a target Copr chroot.
#
# This is the most faithful local reproduction of a Copr build: unlike
# `test_copr_srpm.sh` (which only builds the SRPM) and
# `test_copr_dynamic_br.sh` (which only resolves BuildRequires), this
# script mirrors Copr end to end:
#
#   1. Spin up a container matching the chroot with the same external repos
#      Copr uses (EPEL + CRB + PGDG for EL9; PGDG for F42; native PG18 for
#      F43, F45, and Rawhide).
#   2. Install the shared SRPM and regenerate it using `rpmbuild -bs`, as
#      mock does, so its static BuildRequires reflect the target distro.
#   3. `dnf builddep` the target-regenerated SRPM.
#   4. `rpmbuild --rebuild` — runs %prep, %build, %install, and %files,
#      which is the only way to catch install-stage errors such as:
#
#         error: File listed twice: /usr/pgsql-18/lib/pg_documentdb.so
#         error: Installed (but unpackaged) file(s) found
#
#      These are the failures reported by Copr build 10363880; the other
#      test scripts in this directory cannot see them because they stop
#      before %install.
#
# Usage
# -----
#   ./packaging/copr/test_copr_rebuild.sh [--chroot CHROOT] [--srpm PATH] [--keep]
#
# --chroot fedora-43-x86_64 (default) | fedora-42-x86_64 | fedora-45-x86_64 |
#          fedora-rawhide-x86_64 | epel-9-x86_64
# --srpm   Shared source RPM. If omitted, build one using test_copr_srpm.sh's
#          default Fedora source builder, independently of the target chroot.
# --keep   Keep the container on exit for post-mortem
#          (`docker exec -it docdb-rebuild-<chroot> bash`).
#
# The full build takes several minutes per chroot because it compiles the
# C extensions, vendored libbson / pcre2 / pg_cron, and the Rust gateway.
# Output is streamed live.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CHROOT="fedora-43-x86_64"
KEEP=0
SRPM=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chroot) shift; CHROOT="$1" ;;
        --srpm)   shift; SRPM="$1" ;;
        --keep)   KEEP=1 ;;
        -h|--help)
            grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$CHROOT" in
    fedora-43-x86_64) IMAGE="fedora:43" ;;
    fedora-42-x86_64) IMAGE="fedora:42" ;;
    fedora-45-x86_64) IMAGE="fedora:45" ;;
    fedora-rawhide-x86_64) IMAGE="fedora:rawhide" ;;
    epel-9-x86_64)    IMAGE="rockylinux:9" ;;
    *) echo "Unsupported chroot: $CHROOT" >&2; exit 2 ;;
esac

if [[ -z "$SRPM" ]]; then
    srpm_dir=$(mktemp -d /tmp/docdb-rebuild-srpm.XXXXXX)
    "$script_dir/test_copr_srpm.sh" --output-dir "$srpm_dir"
    SRPM=$(find "$srpm_dir" -name '*.src.rpm' -print -quit)
fi
if [[ ! -f "$SRPM" ]]; then
    echo "SRPM not found: $SRPM" >&2
    exit 2
fi
SRPM=$(realpath "$SRPM")
echo "[rebuild] chroot=$CHROOT image=$IMAGE srpm=$SRPM"
sha256sum "$SRPM"

CONTAINER_NAME="docdb-rebuild-${CHROOT}"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

in_container=$(cat <<'EOS'
set -euo pipefail
CHROOT="$1"

echo "--- [rebuild] installing base tooling ---"
dnf install -y --allowerasing dnf-plugins-core rpm-build rpmdevtools curl make >/dev/null

case "$CHROOT" in
    epel-9-x86_64)
        dnf install -y epel-release >/dev/null
        dnf config-manager --set-enabled crb >/dev/null
        dnf upgrade -y rocky-release >/dev/null
        dnf -qy module disable postgresql >/dev/null 2>&1 || true
        dnf install -y \
            https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm \
            >/dev/null
        ;;
    fedora-42-x86_64)
        dnf install -y \
            https://download.postgresql.org/pub/repos/yum/reporpms/F-42-x86_64/pgdg-fedora-repo-latest.noarch.rpm \
            >/dev/null
        ;;
esac

rpmdev-setuptree
rpm -i --nodeps /input.src.rpm
SPEC=$(find /root/rpmbuild/SPECS -name '*.spec' -print -quit)
for attempt in 1 2 3; do
    before=$(rpm -qa | sort)
    echo "--- [rebuild] regenerating shared SRPM for target (pass $attempt) ---"
    rpmbuild -bs "$SPEC"
    SRPM=$(find /root/rpmbuild/SRPMS -name '*.src.rpm' -print -quit)
    rpm -qp --requires "$SRPM" | sed 's/^/    /'
    dnf builddep -y --nogpgcheck "$SRPM" >/dev/null
    if [[ "$before" == "$(rpm -qa | sort)" ]]; then
        break
    fi
    if [[ $attempt -eq 3 ]]; then
        echo "Static BuildRequires did not stabilize" >&2
        exit 1
    fi
done

echo "--- [rebuild] running rpmbuild --rebuild (full build + %install + %files) ---"
set +e
rpmbuild --rebuild "$SRPM" 2>&1 | tee /tmp/rebuild.log
rc=${PIPESTATUS[0]}
set -e

echo ""
echo "--- [rebuild] exit code: $rc ---"
if [[ $rc -ne 0 ]]; then
    echo "--- [rebuild] last 80 lines of build log ---"
    tail -80 /tmp/rebuild.log
    echo ""
    echo "--- [rebuild] install/files errors (if any) ---"
    grep -E "error:|File listed twice|Installed \(but unpackaged\)|File not found|aborting|Found.*in installed files" \
        /tmp/rebuild.log | head -40 | sed 's/^/    /'
    echo "[rebuild] RESULT=FAIL ($CHROOT)"
else
    echo "--- [rebuild] produced RPMs: ---"
    ls -la /root/rpmbuild/RPMS/*/*.rpm 2>/dev/null | sed 's/^/    /' | tail -20
    echo "[rebuild] RESULT=PASS ($CHROOT)"
fi
exit "$rc"
EOS
)

docker_opts=(--name "$CONTAINER_NAME" -v "$SRPM:/input.src.rpm:ro")
if [[ "$KEEP" -eq 0 ]]; then
    docker_opts+=(--rm)
fi

docker run "${docker_opts[@]}" \
    "$IMAGE" \
    bash -c "$in_container" _ "$CHROOT"
