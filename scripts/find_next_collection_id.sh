#!/bin/bash

test_dir=$1

collection_id_candidate=100

while true; do
    collection_id_string="SET \w+.next_collection_id TO $collection_id_candidate"
    grep -q -i -E "$collection_id_string" $test_dir/sql/*
    if [ "$?" == "0" ]; then
        collection_id_candidate=$(( collection_id_candidate + 100 ));
    else
        echo "Found candidate $collection_id_candidate";
        exit 0;
    fi
done