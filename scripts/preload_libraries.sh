#!/bin/bash

# Provides the base shared_preload_libraries list for DocumentDB.

# Returns the base preload libraries string for DocumentDB.
# Callers can prepend their own libraries to the output.
# Arguments:
#   --distributed: include citus and pg_documentdb_distributed
#   --rum: include pg_documentdb_extended_rum
function GetDocumentDBBasePreloadLibraries()
{
  local distributed=false
  local rum=false

  for arg in "$@"; do
    case "$arg" in
      --distributed) distributed=true ;;
      --rum) rum=true ;;
    esac
  done

  local clusterPreloadLibraries="pg_documentdb_core, pg_documentdb"

  if [ "$distributed" == "true" ]; then
    clusterPreloadLibraries="citus, $clusterPreloadLibraries, pg_documentdb_distributed"
  fi

  if [ "$rum" == "true" ]; then
    clusterPreloadLibraries="$clusterPreloadLibraries, pg_documentdb_extended_rum"
  fi

  echo "pg_cron, $clusterPreloadLibraries"
}
