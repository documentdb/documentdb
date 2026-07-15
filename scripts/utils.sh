#!/bin/bash

# fail if trying to reference a variable that is not set.
set -u
# exit immediately if a command exits with a non-zero status
set -e

# trap to print line number on error
error() {
  local parent_lineno="$1"
  local message="${2:-x}"
  local code="${3:-1}"
  if [[ -n "$message" ]] ; then
    echo "Error on or near line ${parent_lineno}: ${message}; exiting with status ${code}"
  else
    echo "Error on or near line ${parent_lineno}; exiting with status ${code}"
  fi
  exit "${code}"
}
trap 'error ${LINENO}' ERR

function GetPostgresPath()
{
  local pgVersion=$1
  local osVersion=$(cat /etc/os-release | grep "^ID=");

  if [[ "$osVersion" == "ID=ubuntu" || "$osVersion" == "ID=debian"|| "$osVersion" == "ID=mariner" || "$osVersion" == "ID=azurelinux" ]]; then
    echo "/usr/lib/postgresql/$pgVersion/bin"
  else
    echo "/usr/pgsql-$pgVersion/bin"
  fi
}

function GetPostgresSourceRef()
{
  local pgVersion=$1
  if [ "$pgVersion" == "16" ]; then
    # This maps to REL_16_2:b78fa8547d02fc72ace679fb4d5289dccdbfc781
    POSTGRESQL_REF="REL_16_2"
  elif [ "$pgVersion" == "15" ]; then
    # This maps to REL15_3:8382864eb5c9f9ebe962ac20b3392be5ae304d23
    POSTGRESQL_REF="REL_15_3"
  else
    echo "Invalid PG Version specified $pgVersion";
    exit 1;
  fi

  echo $POSTGRESQL_REF
}

function GetPGCTL()
{
  local pgVersion=${PG_VERSION:-16}
  echo ${pgctlPath:-$(GetPostgresPath $pgVersion)/pg_ctl}
}

function GetInitDB()
{
  local pgVersion=${PG_VERSION:-16}
  echo $(GetPostgresPath $pgVersion)/initdb
}

function GetPGConfig()
{
  local pgVersion=${PG_VERSION:-16}
  echo $(GetPostgresPath $pgVersion)/pg_config
}

function StopServer()
{
  local _directory=$1
  local _extraOptions=${2:-""}

  $(GetPGCTL) stop -D $_directory $_extraOptions || true;
  echo "Stopped all PG instances on $_directory";
}

function StartServer()
{
  local _directory=$1
  local _port=$2
  local _logPath=${3:-$_directory/pglog.log}
  local _additionalArgs=${4:-''}
  local _pgctlPath=$(GetPGCTL)

  echo "Starting postgres in $_directory"
  echo "Calling: $_pgctlPath start -D $_directory -o \"-p $_port\" -l $_logPath $_additionalArgs"
  $_pgctlPath start -D $_directory -o "-p $_port" -l $_logPath $_additionalArgs
}

function AddPostgresConfigToServer()
{
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: AddPostgresConfigToServer <postgres_dir> <config_line> [upsert]" >&2
    return 1
  fi

  local dir="$1"
  local line="$2"
  local upsert="${3:-false}"
  local configFile="$dir/postgresql.conf"

  if [ "$upsert" == "true" ]; then
    local settingName
    settingName=$(GetPostgresConfigSettingName "$line")

    if grep -Fxq "$line" "$configFile"; then
      return
    fi

    local escapedSettingName
    escapedSettingName=$(EscapeExtendedRegex "$settingName")

    if grep -Eq "^[[:space:]]*$escapedSettingName[[:space:]]*=" "$configFile"; then
      local escapedLine
      escapedLine=$(EscapeSedReplacement "$line")
      sed -i -E \
        "s|^[[:space:]]*$escapedSettingName[[:space:]]*=.*$|$escapedLine|" "$configFile"
      return
    fi
  fi

  echo "$line" >> "$configFile"
}

function GetPostgresConfigSettingName()
{
  if [[ "$1" != *=* ]]; then
    echo "GetPostgresConfigSettingName requires a setting assignment line." >&2
    return 1
  fi

  local settingName
  settingName=$(printf '%s\n' "${1%%=*}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

  if [ "$settingName" == "" ]; then
    echo "GetPostgresConfigSettingName requires a non-empty setting name." >&2
    return 1
  fi

  printf '%s\n' "$settingName"
}

function EscapeExtendedRegex()
{
  printf '%s\n' "$1" | sed -e 's/[][(){}.^$+*?|\\]/\\&/g'
}

function EscapeSedReplacement()
{
  printf '%s\n' "$1" | sed -e 's/[&|]/\\&/g'
}

function SetupPostgresServerExtensions()
{
  local user=$1
  local port=$2
  local extensionName=$3
  local extensionVersion=${4:-}
  
  local versionString="";
  if [ "$extensionVersion" != "" ]; then
    versionString="WITH VERSION '${extensionVersion}'";
  fi

  echo "create extension $extensionName on port $port with version '${extensionVersion:-latest}'."
  psql -p $port -U $user -d postgres -X -c "CREATE EXTENSION $extensionName $versionString CASCADE;"

  psql -p $port -U $user -d postgres -c "SELECT * FROM pg_extension WHERE extname = '$extensionName';"
}


function SetupCustomAdminUser()
{
  # This sets up a user
  local user=$1
  local pass=$2
  local port=$3
  local owner=$4

  echo "Setting up custom user $user with owner $owner.";
  if ! psql -p "$port" -U "$owner" -d postgres -c "SELECT 1 FROM pg_roles WHERE rolname = '$user';" | grep -q 1; then
    psql -p $port -U $owner -d postgres -c "SELECT documentdb_api.create_user('{\"createUser\":\"$user\", \"pwd\":\"$pass\", \"roles\":[{\"role\":\"readWriteAnyDatabase\",\"db\":\"admin\"}, {\"role\":\"clusterAdmin\",\"db\":\"admin\"}]}');";
  else
    echo "Role $user already exists."
  fi
}

function InitDatabaseExtended()
{
  local _directory=$1
  local _sharedPreloadLibraries=$2
  local _dataChecksums=$3

  echo "Initializing PostgreSQL database in $_directory with preload libraries: $_sharedPreloadLibraries"

  if [ -d "$_directory" ]; then
    echo "Removing contents of $_directory"
    rm -rf $_directory/*
    rm -rf $_directory/.[!.]*
  fi
  
  if [ ! -d "$_directory" ]; then
    echo "Creating directory $_directory"
    mkdir -p $_directory
  fi

  echo "Calling initdb for $_directory"
  if [ "$_dataChecksums" == "true" ]; then
    echo "Initializing database with data checksums"
    $(GetInitDB) -D $_directory --data-checksums
  else
    echo "Initializing database without data checksums"
    $(GetInitDB) -D $_directory
  fi
  SetupPostgresConfigurations $_directory "$_sharedPreloadLibraries"
}


function SetupPostgresConfigurations()
{
  local installdir=$1;
  local sharedPreloadLibraries=$2;
  echo shared_preload_libraries = \'$sharedPreloadLibraries\' | tee -a $installdir/postgresql.conf
  echo cron.database_name = \'postgres\' | tee -a $installdir/postgresql.conf
  echo documentdb.enableBackgroundWorker = 'true' | tee -a $installdir/postgresql.conf
  echo documentdb.enableBackgroundWorkerJobs = 'true' | tee -a $installdir/postgresql.conf
  echo documentdb.indexBuildsScheduledOnBgWorker = 'false' | tee -a $installdir/postgresql.conf
  echo ssl = off | tee -a $installdir/postgresql.conf
}


function AddNodeToCluster()
{
  local _coordinatorPort=$1
  local _nodePort=$2

  psql -d postgres -p $_coordinatorPort -c "SELECT citus_add_node('localhost', $_nodePort);"
  psql -d postgres -p $_coordinatorPort -c "SELECT citus_set_node_property('localhost', $_nodePort, 'shouldhaveshards', true);"
}
