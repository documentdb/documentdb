#!/bin/bash

targetFile=$1
pg_version=$2

sed -i -e "s/!MAJOR_VERSION!/${pg_version}/g" $targetFile

if (( $pg_version >= 16 )); then
    sed -i -e "s/!PG16_OR_HIGHER!/_pg16/g" $targetFile
else
    sed -i -e "s/!PG16_OR_HIGHER!//g" $targetFile
fi

if (( $pg_version >= 17 )); then
    sed -i -e "s/!PG17_OR_HIGHER!/_pg17/g" $targetFile
else
    sed -i -e "s/!PG17_OR_HIGHER!//g" $targetFile
fi

if (( $pg_version >= 18 )); then
    sed -i -e "s/!PG18_OR_HIGHER!/_pg18/g" $targetFile
else
    sed -i -e "s/!PG18_OR_HIGHER!//g" $targetFile
fi

mutateFile="./test_mutate_${pg_version}"
if [ -f $mutateFile ]; then
    cat $mutateFile | while read line 
    do
        sed -i -e "$line" $targetFile
    done
else
    echo "No version specific mutation. Skipping"
fi

# Mode-specific mutations. When the built-in rmgr core module is selected at
# runtime, tests that inspect the on-disk RUM page/metapage format are stripped
# from the schedule (the module intentionally uses a different, GIN-compatible
# layout and metapage version).
if [ "${RUM_USE_BUILTIN_RMGR:-}" == "yes" ]; then
    builtinMutateFile="./test_mutate_builtin_rmgr"
    if [ -f $builtinMutateFile ]; then
        while read -r line
        do
            sed -i -e "$line" $targetFile
        done < $builtinMutateFile
    else
        echo "No built-in rmgr mutation at $builtinMutateFile. Skipping"
    fi
fi
