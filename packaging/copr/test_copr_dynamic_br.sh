#!/bin/bash
# Resolve a shared SRPM's static and dynamic BuildRequires as Copr/mock does.
#
# Background
# ----------
# Mock first regenerates the incoming SRPM with `rpmbuild -bs` in the target
# chroot, then installs that regenerated SRPM's static BuildRequires. Reading
# the original Fedora SRPM's header directly does not model this step. When
# the spec uses `%generate_buildrequires` + `%cargo_generate_buildrequires`
# (Fedora's cargo-rpm-macros), rpmbuild walks the vendored Cargo tree in
# %prep and emits one `BuildRequires: crate(<name>) >= <ver>` line per
# crate.  Those dynamic BRs are what the Copr builder actually tries to
# install; failures like
#
#     nothing provides requested (crate(bson/default) >= 2.7.0 ...)
#
# only surface there.  This script reproduces that step inside a container
# that mirrors each Copr chroot, so dependency-resolution failures can be
# caught before pushing to Copr.
#
# What it does
# ------------
# For the selected chroot:
#   1. Spin up a matching container (rockylinux:9, fedora:42, fedora:43)
#      with the same external repos Copr has configured for the project
#      (EPEL + CRB + PGDG for EL9; PGDG for Fedora 42; native for Fedora 43).
#   2. Install the shared SRPM, regenerate its target-specific static header,
#      and resolve those requirements before running any %prep code.
#   3. Run `rpmbuild -br --nodeps` on the extracted
#      spec.  That executes %generate_buildrequires exactly the way mock
#      does and produces `*.buildreqs.nosrc.rpm` next to the original SRPM.
#   4. Run `dnf builddep --nogpgcheck` against that nosrc.rpm, if produced. This is the
#      moment Copr fails on EL9; the script surfaces the same
#      `nothing provides requested (crate(...))` message locally.
#
# Usage
# -----
#   ./packaging/copr/test_copr_dynamic_br.sh [--chroot CHROOT] [--srpm PATH]
#
# --chroot fedora-43-x86_64 (default) | fedora-42-x86_64 | fedora-45-x86_64 |
#          fedora-rawhide-x86_64 | epel-9-x86_64
# --srpm   Path to an already-built SRPM; default is the most recent
#          DocumentDB SRPM in packaging/copr/. If none exists, the
#          script invokes `test_copr_srpm.sh` on its default Fedora source
#          builder, not the target chroot. Pass the same --srpm to each target.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
packaging_dir="$script_dir"

CHROOT="fedora-43-x86_64"
SRPM=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chroot)
            shift
            CHROOT="$1"
            ;;
        --srpm)
            shift
            SRPM="$1"
            ;;
        -h|--help)
            grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
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

# Locate or build an SRPM to feed into the container.
if [[ -z "$SRPM" ]]; then
    SRPM="$(ls -t "$packaging_dir"/documentdb-*.src.rpm "$packaging_dir"/postgresql18-documentdb-*.src.rpm 2>/dev/null | head -1 || true)"
fi
if [[ -z "$SRPM" ]]; then
    echo "[dyn-br] No SRPM found; building one via test_copr_srpm.sh ..."
    "$script_dir/test_copr_srpm.sh" >/dev/null
    SRPM="$(ls -t "$packaging_dir"/documentdb-*.src.rpm "$packaging_dir"/postgresql18-documentdb-*.src.rpm 2>/dev/null | head -1 || true)"
fi
if [[ ! -f "$SRPM" ]]; then
    echo "SRPM not found: $SRPM" >&2
    exit 2
fi

SRPM="$(realpath "$SRPM")"
echo "[dyn-br] chroot=$CHROOT image=$IMAGE srpm=$SRPM"
sha256sum "$SRPM"

# The in-container script: install the SRPM, invoke %generate_buildrequires,
# then try to resolve the resulting dynamic BR set with dnf.
in_container=$(cat <<'EOS'
set -euo pipefail
CHROOT="$1"

echo "--- [dyn-br] installing base build tooling ---"
dnf install -y --allowerasing dnf-plugins-core rpm-build rpmdevtools jq tar gzip >/dev/null

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

echo "--- [dyn-br] installing SRPM (drops sources + spec into rpmbuild tree) ---"
rpm -i --nodeps /input.src.rpm 2>&1 | tail -5

SPEC=$(ls /root/rpmbuild/SPECS/*.spec | head -1)
echo "--- [dyn-br] spec=$SPEC ---"
echo "--- [dyn-br] original source-builder BuildRequires ---"
rpm -qp --requires /input.src.rpm

for attempt in 1 2 3; do
    before=$(rpm -qa | sort)
    echo "--- [dyn-br] regenerating SRPM in target chroot (pass $attempt) ---"
    rpmbuild -bs "$SPEC"
    TARGET_SRPM=$(find /root/rpmbuild/SRPMS -name '*.src.rpm' -print -quit)
    rpm -qp --requires "$TARGET_SRPM" | tee /tmp/static-buildrequires
    dnf builddep -y --nogpgcheck "$TARGET_SRPM"
    if [[ "$before" == "$(rpm -qa | sort)" ]]; then
        break
    fi
    if [[ $attempt -eq 3 ]]; then
        echo "Static BuildRequires did not stabilize" >&2
        exit 1
    fi
done

case "$CHROOT" in
    epel-9-x86_64|fedora-42-x86_64)
        grep -qx 'postgresql18-devel' /tmp/static-buildrequires
        if grep -Eq '^postgresql-server-devel|^pcre2-static' /tmp/static-buildrequires; then
            echo "Source-builder dependencies leaked into the PGDG target" >&2
            exit 1
        fi
        ;;
    *)
        grep -qx 'postgresql-server-devel >= 18' /tmp/static-buildrequires
        grep -qx 'postgresql-server-devel < 19' /tmp/static-buildrequires
        grep -qx 'pcre2-static' /tmp/static-buildrequires
        ;;
esac

echo "--- [dyn-br] target runtime Requires from the reparsed spec ---"
rpmspec -q --requires "$SPEC"

echo "--- [dyn-br] validating prep (also when no dynamic generator exists) ---"
rpmbuild -bp "$SPEC"

# -br emits the dynamic BR stub if a generator exists; otherwise it only
# writes an SRPM. Prep was explicitly checked above in either case.
echo "--- [dyn-br] running rpmbuild -br to generate dynamic BuildRequires ---"
set +e
rpmbuild -br --noprep --nodeps "$SPEC" 2>&1 | tee /tmp/genbr.log
rc_genbr=${PIPESTATUS[0]}
set -e
# rpmbuild exits 11 when `-br` stops at the buildrequires stage after
# emitting the nosrc.rpm — that is the *success* path for this script.
# Any other non-zero rc means %prep or %generate_buildrequires itself blew up.
if [[ $rc_genbr -ne 0 && $rc_genbr -ne 11 ]]; then
    echo "--- [dyn-br] %generate_buildrequires itself failed (rc=$rc_genbr) ---"
    exit "$rc_genbr"
fi

NOSRC=$(ls /root/rpmbuild/SRPMS/*.buildreqs.nosrc.rpm 2>/dev/null | head -1 || true)
if [[ -z "$NOSRC" ]]; then
    echo "--- [dyn-br] no buildreqs.nosrc.rpm produced; spec may not use %generate_buildrequires ---"
    echo "[dyn-br] RESULT=PASS ($CHROOT; shared SRPM static dependencies + prep; no dynamic BuildRequires)"
    exit 0
fi
echo "--- [dyn-br] dynamic BR stub: $NOSRC ---"
echo "--- [dyn-br] dynamic BuildRequires list: ---"
rpm -qp --requires "$NOSRC" | sed 's/^/    /'

echo "--- [dyn-br] resolving dynamic BuildRequires via dnf builddep ---"
set +e
dnf builddep -y --nogpgcheck "$NOSRC" 2>&1 | tee /tmp/builddep.log
rc_bd=${PIPESTATUS[0]}
set -e

if [[ $rc_bd -eq 0 ]]; then
    echo "[dyn-br] RESULT=PASS ($CHROOT)"
else
    echo "[dyn-br] RESULT=FAIL ($CHROOT)  -- missing providers below:"
    grep -E "nothing provides|No match for argument" /tmp/builddep.log | sort -u | sed 's/^/    /'
fi
exit "$rc_bd"
EOS
)

docker run --rm \
    -v "$SRPM:/input.src.rpm:ro" \
    -e CHROOT="$CHROOT" \
    "$IMAGE" \
    bash -c "$in_container" _ "$CHROOT"
