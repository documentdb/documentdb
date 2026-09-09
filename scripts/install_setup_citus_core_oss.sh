#!/bin/bash

# fail if trying to reference a variable that is not set.
set -u
# exit immediately if a command exits with a non-zero status
set -e

citusVersion=$1

source="${BASH_SOURCE[0]}"
while [[ -h $source ]]; do
   scriptroot="$( cd -P "$( dirname "$source" )" && pwd )"
   source="$(readlink "$source")"

   # if $source was a relative symlink, we need to resolve it relative to the path where the
   # symlink file was located
   [[ $source != /* ]] && source="$scriptroot/$source"
done
scriptDir="$( cd -P "$( dirname "$source" )" && pwd )"

. $scriptDir/setup_versions.sh
CITUS_REF=$(GetCitusVersion $citusVersion)

. $scriptDir/utils.sh
if [ "${PGVERSION:-}" != "" ]; then
    pgPath=$(GetPostgresPath $PGVERSION)
    PATH=$pgPath:$PATH
fi

pushd $INSTALL_DEPENDENCIES_ROOT

rm -rf citus-repo
mkdir citus-repo
cd citus-repo

git init
git remote add origin https://github.com/citusdata/citus.git

git fetch --depth 1 origin "$CITUS_REF"
git checkout FETCH_HEAD

echo "building and installing citus extension ..."
./configure --without-lz4 --without-zstd --without-libcurl
make PATH=$PATH clean

if declare -F ProcessCitusMakefileGlobal > /dev/null; then
    echo "Function ProcessCitusMakefileGlobal is defined"
    ProcessCitusMakefileGlobal
else
    echo "Function ProcessCitusMakefileGlobal is not defined"
fi


# Build in parallel, then install serially.
#
# The CDC decoders (src/backend/distributed/cdc) extract debug symbols into a
# single shared symbols directory. Running the
# build and install phases together under `-j` lets two make jobs operate on the
# same citus_<decoder>.so at once: one `cp`s the file while another runs
# `objcopy --strip-unneeded` on it, producing a truncated file and the failure
# `objcopy: ...: file format not recognized`. Building everything first and then
# installing serially (no `-j`) guarantees the symbol extraction never races.
NPROC=$(cat /proc/cpuinfo | grep -c "processor")
if [ "${DESTINSTALLDIR:-}" == "" ]; then
make PATH=$PATH -j$NPROC all
make PATH=$PATH install
else
make PATH=$PATH DESTDIR=$DESTINSTALLDIR -j$NPROC all
make PATH=$PATH DESTDIR=$DESTINSTALLDIR install
fi
popd

if [ "${CLEANUP_SETUP:-"0"}" == "1" ]; then
    rm -rf $INSTALL_DEPENDENCIES_ROOT/citus-repo
fi
