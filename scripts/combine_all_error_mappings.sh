#!/bin/bash

# fail if trying to reference a variable that is not set.
set -u
# exit immediately if a command exits with a non-zero status
set -e

externalErrorMappingsFile=$1
corePgErrorMappingsFile=$2
targetFile=$3

declare -A errorNames=()

tempFile="/tmp/all_error_mappings_file_temp.csv"
rm -f "$tempFile"

writeIntoFile() {
    errorName=$1
    errorCode=$2
    externalErrorCode=$3
    OverriddenUserFacingMessage=$4

    if [[ -n "${errorNames[$errorName]+x}" ]]; then
        echo "Duplicate error name detected: $errorName"
        exit 1
    fi

    errorNames["$errorName"]=1

    echo "$errorName,$errorCode,$externalErrorCode,$OverriddenUserFacingMessage" >> $tempFile
}

# TODO: Add column OverriddenUserFacingMessage in external error mappings
if [[ $(head -n 1 "$externalErrorMappingsFile") != "ErrorName,ErrorCode,ExternalError,ErrorOrdinal" ]]; then
    echo "ERROR: file "$externalErrorMappingsFile" has invalid header"
    exit 1
else
    tail -n +2 "$externalErrorMappingsFile" | while IFS=',' read -ra tokens; do
        writeIntoFile ${tokens[0]} ${tokens[1]} ${tokens[2]} "null"
    done
fi

# TODO: Add column OverriddenUserFacingMessage in core pg error mappings
if [[ $(head -n 1 "$corePgErrorMappingsFile") != "ErrorName,ErrorCode,ExternalErrorCode" ]]; then
    echo "ERROR: file "$corePgErrorMappingsFile" has invalid header"
    exit 1
else
    tail -n +2 "$corePgErrorMappingsFile" | while IFS=',' read -ra tokens; do
        writeIntoFile ${tokens[0]} ${tokens[1]} ${tokens[2]} "null"
    done
fi

echo "ErrorName,ErrorCode,ExternalErrorCode,OverriddenUserFacingMessage" > $targetFile
sort -t',' -k3,3n $tempFile >> $targetFile
