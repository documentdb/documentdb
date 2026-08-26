#!/bin/bash

set -e -u


source="${BASH_SOURCE[0]}"
while [[ -h $source ]]; do
   scriptroot="$( cd -P "$( dirname "$source" )" && pwd )"
   source="$(readlink "$source")"

   # if $source was a relative symlink, we need to resolve it relative to the path where the
   # symlink file was located
   [[ $source != /* ]] && source="$scriptroot/$source"
done

repoScriptDir="$( cd -P "$( dirname "$source" )" && pwd )"
repoRoot="$( cd -P "$repoScriptDir/../" && pwd )"

errorMappingsFile="$repoRoot/error_mappings.csv"
generatedMappingsFile="$repoRoot/pg_documentdb_gw/include/all_error_mappings_oss_generated.csv"

if [[ ! -f "$errorMappingsFile" ]]; then
    echo "ERROR: $errorMappingsFile not found"
    exit 1
fi

if [[ ! -f "$generatedMappingsFile" ]]; then
    echo "ERROR: $generatedMappingsFile not found"
    exit 1
fi

# error_mappings.csv format: ErrorMapping,ErrorName
# all_error_mappings_oss_generated.csv format: ErrorName,ErrorCode,ExternalErrorCode
missingErrors=$(grep -vxF -f <(awk -F',' 'NR>1 {print $1}' "$generatedMappingsFile") <(awk -F',' 'NR>1 {print $2}' "$errorMappingsFile") || true)

if [[ -n "$missingErrors" ]]; then
    echo "ERROR: The following errors from $errorMappingsFile are missing in $generatedMappingsFile:"
    echo "$missingErrors"
    echo "Run make -C pg_documentdb_gw generate_external_error_mapping_file to update the gateway mappings"
    exit 1
fi

echo "OK: All errors in error_mappings.csv are present in all_error_mappings_oss_generated.csv"