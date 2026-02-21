#!/bin/bash

# exit immediately if a command exits with a non-zero status
set -e
# fail if trying to reference a variable that is not set.
set -u

postgresqlInstallDir=""
debug="false"
cassert="false"
help="false";
withasan="false"
pgVersion=""
withvalgrind="false"
while getopts "d:hxcv:ags:" opt; do
  case $opt in
    d) postgresqlInstallDir="$OPTARG"
    ;;
    x) debug="true"
    ;;
    c) cassert="true"
    ;;
    h) help="true"
    ;;
    v) pgVersion="$OPTARG"
    ;;
    a) withasan="true"
    ;;
    g) withvalgrind="true"
    ;;
  esac

  # Assume empty string if it's unset since we cannot reference to
  # an unset variabled due to "set -u".
  case ${OPTARG:-""} in
    -*) echo "Option $opt needs a valid argument"
    exit 1
    ;;
  esac
done

if [ "$help" == "true" ]; then
    echo "downloads PostgreSQL sources for the specified version, build and install it."
    echo "[-d] the directory to install postgresql to. Default: /usr/lib/postgresql/14"
    echo "[-v] the version of postgresql to build. E.g. 14, 15 etc."
    echo "[-x] build with debug symbols."
    exit 1;
fi

if [ -z $postgresqlInstallDir ]; then
    echo "Postgres Install Directory must be specified."
    exit 1;
fi

if [ -z $pgVersion ]; then
  echo "PG Version must be specified";
  exit 1;
fi

source="${BASH_SOURCE[0]}"
while [[ -h $source ]]; do
   scriptroot="$( cd -P "$( dirname "$source" )" && pwd )"
   source="$(readlink "$source")"

   # if $source was a relative symlink, we need to resolve it relative to the path where the
   # symlink file was located
   [[ $source != /* ]] && source="$scriptroot/$source"
done
scriptDir="$( cd -P "$( dirname "$source" )" && pwd )"


if [ "${POSTGRESQL_REF-}" == "" ]; then
    . $scriptDir/setup_versions.sh
    POSTGRESQL_REF=$(GetPostgresSourceRef $pgVersion)
fi

postgresSourceRepo="https://github.com/postgres/postgres"
if [ "${OVERRIDE_POSTGRES_SOURCE_REPO-}" != "" ]; then
    postgresSourceRepo="$OVERRIDE_POSTGRES_SOURCE_REPO"
fi

pushd $INSTALL_DEPENDENCIES_ROOT

rm -rf postgres-repo/$pgVersion
mkdir -p postgres-repo/$pgVersion
cd postgres-repo/$pgVersion

git init
git remote add origin "$postgresSourceRepo"

# checkout to the commit specified in the cgmanifest.json
git fetch --depth 1 --no-tags --prune --prune-tags origin "$POSTGRESQL_REF"
git checkout FETCH_HEAD

echo "building and installing postgresql ref $POSTGRESQL_REF and installing to $postgresqlInstallDir..."

EXTRA_CFLAGS=" "
EXTRA_CPP_FLAGS=" "
EXTRA_COMMAND_LINE_ARGS=" "
EXTRA_LD_FLAGS=" "

if [ "$withvalgrind" == "true" ]; then
  EXTRA_CPP_FLAGS="${EXTRA_CPP_FLAGS} -DUSE_VALGRIND -Og"
  EXTRA_CFLAGS="${EXTRA_CFLAGS} -DUSE_VALGRIND -Og"
fi

if [ "$withasan" == "true" ]; then
  EXTRA_CPP_FLAGS="-ggdb -Og -g3 -fsanitize=address -fsanitize=undefined -fno-sanitize-recover=all -fno-sanitize=nonnull-attribute -fstack-protector ${EXTRA_CPP_FLAGS}"
  EXTRA_LD_FLAGS="-fsanitize=address -fsanitize=undefined -lstdc++ -static-libasan ${EXTRA_LD_FLAGS}"
  EXTRA_COMMAND_LINE_ARGS="${EXTRA_COMMAND_LINE_ARGS} --enable-cassert"
elif [ "$debug" == "true" ]; then
  EXTRA_COMMAND_LINE_ARGS="${EXTRA_COMMAND_LINE_ARGS} --enable-cassert"
  EXTRA_CFLAGS="${EXTRA_CFLAGS} -ggdb -Og -g3 -fno-omit-frame-pointer"
elif [ "$cassert" == "true" ]; then
  EXTRA_COMMAND_LINE_ARGS="${EXTRA_COMMAND_LINE_ARGS} --enable-cassert"
fi


if [ "${OVERRIDE_CFLAGS:-}" != "" ]; then
  EXTRA_CFLAGS="${OVERRIDE_CFLAGS} $EXTRA_CFLAGS"
fi

if [ "${OVERRIDE_CPPFLAGS:-}" != "" ]; then
  EXTRA_CPP_FLAGS="${OVERRIDE_CPPFLAGS} $EXTRA_CPP_FLAGS"
fi

if [ "${OVERRIDE_LDFLAGS:-}" != "" ]; then
  EXTRA_LD_FLAGS="${OVERRIDE_LDFLAGS} $EXTRA_LD_FLAGS"
fi

if [ "${OVERRIDE_COMMAND_LINE_ARGS:-}" != "" ]; then
  EXTRA_COMMAND_LINE_ARGS="${EXTRA_COMMAND_LINE_ARGS} ${OVERRIDE_COMMAND_LINE_ARGS}"
fi

if [ "$EXTRA_CPP_FLAGS" != " " ]; then
  export CPPFLAGS="$EXTRA_CPP_FLAGS"
fi

if [ "$EXTRA_CFLAGS" != " " ]; then
  export CFLAGS="$EXTRA_CFLAGS"
fi
if [ "$EXTRA_LD_FLAGS" != " " ]; then
  export LDFLAGS="$EXTRA_LD_FLAGS"
fi

echo "Extra command line args: $EXTRA_COMMAND_LINE_ARGS"
./configure -enable-debug --enable-tap-tests --with-openssl --with-zlib --with-zstd --with-libxml --with-icu --with-lz4 --prefix="$postgresqlInstallDir" $EXTRA_COMMAND_LINE_ARGS
make -sj$(cat /proc/cpuinfo | grep -c "processor") install

popd

if [ "${CLEANUP_SETUP:-"0"}" == "1" ]; then
    rm -rf $INSTALL_DEPENDENCIES_ROOT/postgres-repo
fi
