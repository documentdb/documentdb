#!/bin/bash

# fail if trying to reference a variable that is not set.
set -u
# exit immediately if a command exits with a non-zero status
set -e
# ensure pipeline failures are caught
set -o pipefail

documentdbSourceFile=$1
extensionErrorMappingFile=$2
corePgErrorMappingsFile=$3
targetFile=$4

tempTargetFile=$(mktemp)
trap 'rm -f "$tempTargetFile"' EXIT

declare -A documentdbErrorKeys=()
declare -A documentdbErrorOrdinals=()
isFirst=""
maxOrdinal=0
for fileLine in $(cat $documentdbSourceFile); do
        # Skip the header.
    if [ "$isFirst" = "" ]; then
        isFirst="false"
        continue;
    fi

    # Format is error,pgcode,ordinal
    regex="([A-Za-z0-9]+),([A-Za-z0-9]+),([0-9]+)"
    if [[ $fileLine =~ $regex ]]; then
        _name="${BASH_REMATCH[1]}"
        _pgError="${BASH_REMATCH[2]}"
        _existOrdinal="${BASH_REMATCH[3]}"

        if [[ -n "${documentdbErrorKeys[$_name]+x}" ]]; then
            echo "Duplicate error name detected: $_name"
            exit 1
        fi

        if [[ -n "${documentdbErrorOrdinals[$_existOrdinal]+x}" ]]; then
            echo "Duplicate error ordinal detected: $_existOrdinal"
            exit 1
        fi

        documentdbErrorKeys["$_name"]=$_pgError
        documentdbErrorOrdinals["$_existOrdinal"]=$_name

        if (( $maxOrdinal < $_existOrdinal )); then
            maxOrdinal=$_existOrdinal
        fi
    else
        echo "ERROR: documentdb error file line has unknown format $fileLine"
        exit 1
    fi
done

declare -A externalErrorKeys=()
isFirst=""
_maxErrorCode=0
for fileLine in $(cat $extensionErrorMappingFile); do
        # Skip the header.
    if [ "$isFirst" = "" ]; then
        isFirst="false"
        continue;
    fi

    # Format is ExternalError,ErrorName
    regex="([0-9]+),([A-Za-z0-9]+)"
    if [[ $fileLine =~ $regex ]]; then
        _externalError="${BASH_REMATCH[1]}"
        _externalErrorName="${BASH_REMATCH[2]}"

        if [[ -n "${externalErrorKeys[$_externalErrorName]+x}" ]]; then
            echo "Duplicate error name detected: $_externalErrorName"
            exit 1
        fi

        externalErrorKeys["$_externalErrorName"]=$_externalError

        if (( $_maxErrorCode < $_externalError )); then
            _maxErrorCode=$_externalError
        else
            echo "externalErrors must be in ascending order: detected $_externalError with max $_maxErrorCode"
            exit 1
        fi
    else
        echo "ERROR: external file line has unknown format $fileLine"
        exit 1
    fi
done

echo "[Extension error mappings] Max error code is $_maxErrorCode, maxOrdinal is $maxOrdinal"
echo "[Extension error mappings] external error count ${#externalErrorKeys[@]}, documentdb error count ${#documentdbErrorKeys[@]}"

if [ "${#externalErrorKeys[@]}" != "${#documentdbErrorKeys[@]}" ]; then
    echo "[Extension error mappings] mismatch between documentdb errors and external errors detected";
    exit 1
fi

for fileIndex in $(seq 1 $maxOrdinal); do
    _errorName=${documentdbErrorOrdinals[$fileIndex]}
    _errorCode=${documentdbErrorKeys[$_errorName]}
    _externalError=${externalErrorKeys[$_errorName]}

    echo "$_errorName,$_errorCode,$_externalError" >> "$tempTargetFile"
done

# Now read mappings of core postgres errors to external error codes.
if [[ $(head -n 1 "$corePgErrorMappingsFile") != "ErrorName,ErrorCode,ExternalErrorCode" ]]; then
    echo "ERROR: file '$corePgErrorMappingsFile' has invalid header"
    exit 1
else
    while IFS=',' read -ra tokens; do
        _errorName="${tokens[0]}"
        _errorCode="${tokens[1]}"
        _externalErrorCode="${tokens[2]}"

        if [[ -n "${documentdbErrorKeys[$_errorName]+x}" ]]; then
            echo "Duplicate error name detected: $_errorName"
            exit 1
        fi

        documentdbErrorKeys["$_errorName"]=$_errorCode
        echo "$_errorName,$_errorCode,$_externalErrorCode" >> "$tempTargetFile"
    done < <(tail -n +2 "$corePgErrorMappingsFile")
fi

echo "ErrorName,ErrorCode,ExternalErrorCode" > "$targetFile"
sort -t',' -k3,3n "$tempTargetFile" >> "$targetFile"