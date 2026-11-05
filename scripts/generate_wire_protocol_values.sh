#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# fail if trying to reference a variable that is not set.
set -u
# exit immediately if a command exits with a non-zero status
set -e

documentdbSourceFile=$1
wireErrorsFile=$2
targetCFileDest=$3

targetCFile="/tmp/${RANDOM}.c"

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

declare -A wireErrorKeys=()
isFirst=""
_maxErrorCode=0
for fileLine in $(cat $wireErrorsFile); do
        # Skip the header.
    if [ "$isFirst" = "" ]; then
        isFirst="false"
        continue;
    fi

    # Format is WireError,ErrorName
    regex="([0-9]+),([A-Za-z0-9]+)"
    if [[ $fileLine =~ $regex ]]; then
        _wireError="${BASH_REMATCH[1]}"
        _wireErrorName="${BASH_REMATCH[2]}"

        wireErrorKeys["$_wireErrorName"]=$_wireError

        if (( $_maxErrorCode < $_wireError )); then
            _maxErrorCode=$_wireError
        else
            echo "Wire errors must be in ascending order: detected $_wireError with max $_maxErrorCode"
            exit 1
        fi
    else
        echo "ERROR: wire error file line has unknown format $fileLine"
        exit 1
    fi
done

echo "Max error code is $_maxErrorCode, maxOrdinal is $maxOrdinal"
echo "DocumentDB error count ${#documentdbErrorKeys[@]}, wire error count ${#wireErrorKeys[@]}"

if [ "${#wireErrorKeys[@]}" != "${#documentdbErrorKeys[@]}" ]; then
    echo "Mismatch between DocumentDB errors and wire errors detected";
    exit 1
fi


# Write the outputs

# Write the C file for converting backend errors to wire protocol errors
targetFileName=$(basename $targetCFileDest)
wireErrorFileName=$(basename $wireErrorsFile)
cat << EOF > $targetCFile

/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License
 *
 * src/utils/$targetFileName
 *
 * Utilities for converting backend errors to wire protocol errors.
 * This file is generated - please modify the source ($wireErrorFileName)
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>
#include <utils/documentdb_errors.h>
#include <utils/documentdb_conversion_codes.h>
#include <utils/elog.h>

int32
ConvertDocumentDBErrorToWireError(int32 sqlState)
{
	switch (sqlState)
	{
EOF

for fileIndex in $(seq 1 $maxOrdinal); do
    _errorName=${documentdbErrorOrdinals[$fileIndex]}
    _wireError=${wireErrorKeys[$_errorName]}

    _errorNameUpper=${_errorName^^}
    echo "		case ERRCODE_DOCUMENTDB_$_errorNameUpper:" >> $targetCFile
    echo "		{" >> $targetCFile
    echo "			return $_wireError;" >> $targetCFile
    echo "		}" >> $targetCFile
    echo >> $targetCFile
done

cat << EOF >> $targetCFile
		default:
		{
			ereport(ERROR, (errcode(ERRCODE_DOCUMENTDB_INTERNALERROR),
							errmsg("Unrecognized error code %d", sqlState)));
		}
	}
}
EOF

mv -f $targetCFile $targetCFileDest