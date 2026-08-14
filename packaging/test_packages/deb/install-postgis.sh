#!/bin/bash
# Install postgis into the DEB test image: the PGDG package when it exists,
# else build from source and register a dpkg stub in its place.
#
# PGDG does not ship postgis for every (distro, PG) pair -- bullseye tops out
# at postgis 3.5.2 (pg17 only; PostGIS 3.5 does not support PG 18), so
# deb11/pg18 has no postgresql-18-postgis-3 at all. The regression suite
# loads postgis, and the documentdb .deb honestly declares
# Depends: postgresql-N-postgis-3, so on gap legs we (a) compile postgis from
# source via the same script the build image uses, and (b) install a
# contentless stub package under that name so dpkg -i of the documentdb .deb
# still resolves -- without weakening the shipped package's dependency for
# customers.
set -euo pipefail

PGVERSION="${1:?usage: install-postgis.sh <pg-major>}"
INSTALL_DEPENDENCIES_ROOT="${INSTALL_DEPENDENCIES_ROOT:-/tmp/install_setup}"

apt-get update
if apt-get install -y --no-install-recommends "postgresql-${PGVERSION}-postgis-3"; then
    exit 0
fi

echo "postgresql-${PGVERSION}-postgis-3 unavailable from PGDG; building postgis from source"

# Toolchain only on the fallback path. install_setup_postgis.sh runs
# ./autogen.sh, hence the autotools -- the build image gets those transitively
# via debhelper, this lean test image must name them. Its configure disables
# protobuf/topology/raster, so geos/proj/xml/json headers suffice.
apt-get install -y --no-install-recommends \
    curl \
    build-essential \
    autoconf \
    automake \
    libtool \
    "postgresql-server-dev-${PGVERSION}" \
    libproj-dev \
    libxml2-dev \
    libjson-c-dev \
    libgeos-dev \
    libgeos++-dev

export INSTALL_DEPENDENCIES_ROOT
PGVERSION="$PGVERSION" "$INSTALL_DEPENDENCIES_ROOT/install_setup_postgis.sh"

STUB_DIR=$(mktemp -d)
mkdir -p "$STUB_DIR/pkg/DEBIAN"
cat > "$STUB_DIR/pkg/DEBIAN/control" <<EOF
Package: postgresql-${PGVERSION}-postgis-3
Version: 0~local-source
Architecture: all
Maintainer: documentdb-ci <none@localhost>
Description: stub marking the from-source postgis build in this test image
EOF
dpkg-deb --build "$STUB_DIR/pkg" "$STUB_DIR/stub.deb"
dpkg -i "$STUB_DIR/stub.deb"
rm -rf "$STUB_DIR"
