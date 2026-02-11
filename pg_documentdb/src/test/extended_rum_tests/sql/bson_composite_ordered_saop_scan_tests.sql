SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 1200;
SET documentdb.next_collection_index_id TO 1200;

set documentdb.defaultUseCompositeOpClass to on;

CREATE SCHEMA ordered_saop_scan_test;
CREATE FUNCTION ordered_saop_scan_test.insert_documents(collection_name text) RETURNS void
 LANGUAGE plpgsql
 AS $$
    BEGIN
    -- a goes from 2 to 2000 and 'b' will be half of a
    PERFORM documentdb_api.insert_one('ordered_saop_scan_test', collection_name,
        bson_build_document('_id', i, 'a', i * 2, 'b', i)) FROM generate_series(1, 1000) i;

    -- a goes from 1 to 1999 odd, and 'b' will be three times i
    PERFORM documentdb_api.insert_one('ordered_saop_scan_test', collection_name,
        bson_build_document('_id', i + 1000, 'a', (i * 2) - 1, 'b', i * 3)) FROM generate_series(1, 1000) i;
    -- 'a' goes from 2001 to 3000 and b walks that in reverse
    PERFORM documentdb_api.insert_one('ordered_saop_scan_test', collection_name,
        bson_build_document('_id', i, 'a', i, 'b', 3001 - i)) FROM generate_series(2001, 3000) i;

    -- now 'a' goes from 4000 to 3001 and 'b' walks that in ascending order
    PERFORM documentdb_api.insert_one('ordered_saop_scan_test', collection_name,
        bson_build_document('_id', i, 'a', 7001 - i, 'b', i)) FROM generate_series(3001, 4000) i;

    -- insert specific interesting values.
    PERFORM documentdb_api.insert_one('ordered_saop_scan_test', collection_name,
        bson_build_document('_id', 4001, 'a', 1000, 'b', 2000));
    END;
 $$;

SELECT ordered_saop_scan_test.insert_documents('ordered_saop_scan_coll');
SELECT ordered_saop_scan_test.insert_documents('ordered_saop_index_coll');
SELECT ordered_saop_scan_test.insert_documents('ordered_saop_index_reverse_coll');
SELECT ordered_saop_scan_test.insert_documents('ordered_saop_index_mixed_coll');

SELECT COUNT(*) FROM documentdb_api.collection('ordered_saop_scan_test', 'ordered_saop_scan_coll');
SELECT COUNT(*) FROM documentdb_api.collection('ordered_saop_scan_test', 'ordered_saop_index_coll');
SELECT COUNT(*) FROM documentdb_api.collection('ordered_saop_scan_test', 'ordered_saop_index_reverse_coll');
SELECT COUNT(*) FROM documentdb_api.collection('ordered_saop_scan_test', 'ordered_saop_index_mixed_coll');

-- create a multikey index on 'a' and 'b' for the index collection
SELECT documentdb_api_internal.create_indexes_non_concurrently('ordered_saop_scan_test',
    '{ "createIndexes": "ordered_saop_index_coll", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_1_b_1" } ] }'::bson, TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently('ordered_saop_scan_test',
    '{ "createIndexes": "ordered_saop_index_reverse_coll", "indexes": [ { "key": { "a": -1, "b": -1 }, "name": "a_-1_b_-1" } ] }'::bson, TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently('ordered_saop_scan_test',
    '{ "createIndexes": "ordered_saop_index_mixed_coll", "indexes": [ { "key": { "a": -1, "b": 1 }, "name": "a_-1_b_1" } ] }'::bson, TRUE);


\d documentdb_data.documents_1202
\d documentdb_data.documents_1203
\d documentdb_data.documents_1204

CREATE FUNCTION ordered_saop_scan_test.validate_index_runtime_equivalence(querySpec bson) RETURNS setof bson
 LANGUAGE plpgsql
 AS $$
    DECLARE
        index_query_spec bson;
        index_reverse_query_spec bson;
        index_mixed_query_spec bson;
        runtime_query_spec bson;
    BEGIN
        SELECT bson_dollar_add_fields(querySpec, '{ "find": "ordered_saop_scan_coll" }') INTO runtime_query_spec;
        SELECT bson_dollar_add_fields(querySpec, '{ "find": "ordered_saop_index_coll" }') INTO index_query_spec;
        SELECT bson_dollar_add_fields(querySpec, '{ "find": "ordered_saop_index_reverse_coll" }') INTO index_reverse_query_spec;
        SELECT bson_dollar_add_fields(querySpec, '{ "find": "ordered_saop_index_mixed_coll" }') INTO index_mixed_query_spec;

        set client_min_messages to warning;
        DROP TABLE IF EXISTS runtime_results;
        DROP TABLE IF EXISTS index_results;
        DROP TABLE IF EXISTS index_reverse_results;
        DROP TABLE IF EXISTS index_mixed_results;
        reset client_min_messages;

        -- run the runtime query.
        CREATE TEMP TABLE runtime_results AS SELECT document FROM bson_aggregation_find('ordered_saop_scan_test', runtime_query_spec);

        -- run the index query
        CREATE TEMP TABLE index_results AS SELECT document FROM bson_aggregation_find('ordered_saop_scan_test', index_query_spec);

        -- run the reverse query
        CREATE TEMP TABLE index_reverse_results AS SELECT document FROM bson_aggregation_find('ordered_saop_scan_test', index_reverse_query_spec);

        -- run the mixed query
        CREATE TEMP TABLE index_mixed_results AS SELECT document FROM bson_aggregation_find('ordered_saop_scan_test', index_mixed_query_spec);

        IF (SELECT COUNT(*) FROM (SELECT * FROM runtime_results EXCEPT SELECT * FROM index_results) AS subquery) > 0 THEN
            RAISE EXCEPTION 'Runtime has results that are not in index results, runtime query %, index query %', runtime_query_spec, index_query_spec;
        END IF;
        IF (SELECT COUNT(*) FROM (SELECT * FROM index_results EXCEPT SELECT * FROM runtime_results) AS subquery) > 0 THEN
            RAISE EXCEPTION 'Index has results that are not in runtime results, runtime query %, index query %', runtime_query_spec, index_query_spec;
        END IF;

        IF (SELECT COUNT(*) FROM (SELECT * FROM runtime_results EXCEPT SELECT * FROM index_reverse_results) AS subquery) > 0 THEN
            RAISE EXCEPTION 'Runtime has results that are not in index reverse results, runtime query %, index reverse query %', runtime_query_spec, index_reverse_query_spec;
        END IF;
        IF (SELECT COUNT(*) FROM (SELECT * FROM index_reverse_results EXCEPT SELECT * FROM runtime_results) AS subquery) > 0 THEN
            RAISE EXCEPTION 'Index reverse has results that are not in runtime results, runtime query %, index reverse query %', runtime_query_spec, index_reverse_query_spec;
        END IF;

        IF (SELECT COUNT(*) FROM (SELECT * FROM runtime_results EXCEPT SELECT * FROM index_mixed_results) AS subquery) > 0 THEN
            RAISE EXCEPTION 'Runtime has results that are not in index mixed results, runtime query %, index mixed query %', runtime_query_spec, index_mixed_query_spec;
        END IF;
        IF (SELECT COUNT(*) FROM (SELECT * FROM index_mixed_results EXCEPT SELECT * FROM runtime_results) AS subquery) > 0 THEN
            RAISE EXCEPTION 'Index mixed has results that are not in runtime results, runtime query %, index mixed query %', runtime_query_spec, index_mixed_query_spec;
        END IF;

        RETURN QUERY SELECT document FROM index_results;
    END;
    $$;

-- make it so that > 1 variable terms force ordered scans.
set documentdb.max_non_ordered_term_scan_threshold to 1;

-- validate from explain we are using ordered scans
-- TODO: This should not take 2999 loops
set documentdb.enableExtendedExplainPlans to on;
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, SUMMARY OFF, TIMING OFF)
    SELECT document FROM bson_aggregation_find('ordered_saop_scan_test',
        '{ "find": "ordered_saop_index_coll", "filter": { "a": { "$in": [ 5, 16, 2005, 3001 ] }, "b": { "$in": [ 8, 6, 2005, 2995, 2996, 4000 ] } } }'::bson);
$cmd$);

SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 5, 16, 2005, 3001 ] }, "b": { "$in": [ 8, 6, 2005, 2995, 2996, 4000 ] } } }'::bson
);

SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 5, 16, 2005, 3001 ], "$gt": 5 }, "b": { "$in": [ 8, 6, 2005, 2995, 2996, 4000 ] } } }'::bson
);

SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 5, 16, 2005, 3001 ], "$gt": 16 }, "b": { "$in": [ 8, 6, 2005, 2995, 2996, 4000 ] } } }'::bson
);

SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 5, 16, 2005, 3001 ], "$lt": 16 }, "b": { "$in": [ 8, 6, 2005, 2995, 2996, 4000 ] } } }'::bson
);

SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 5, 16, 2005, 3001 ], "$gt": 10, "$lt": 16 }, "b": { "$in": [ 8, 6, 2005, 2995, 2996, 4000 ] } } }'::bson
);

SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 5, 16, 2005, 3001 ], "$gt": 10, "$lt": 20 }, "b": { "$in": [ 8, 6, 2005, 2995, 2996, 4000 ] } } }'::bson
);

-- $in on 'a' combined with $gte/$lte (inclusive bounds) on 'b'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 100, 500, 2500 ] }, "b": { "$gte": 5, "$lte": 500 } } }'::bson
);

-- $in on 'a' combined with $gt/$lt range on 'b'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 100, 500, 2500 ] }, "b": { "$gt": 100, "$lt": 300 } } }'::bson
);

-- $in on 'b' combined with $gte/$lte range on 'a'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$gte": 100, "$lte": 500 }, "b": { "$in": [ 50, 100, 150, 200, 250 ] } } }'::bson
);

-- $in on both 'a' and 'b' with $gte on both
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 5, 2005, 16, 3001 ], "$gte": 16 }, "b": { "$in": [ 8, 6, 2005, 2995, 2996, 4000 ], "$gte": 2005 } } }'::bson
);

-- $in on both 'a' and 'b' with $lte on both
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 5, 2005, 16, 3001 ], "$lte": 2005 }, "b": { "$in": [ 8, 6, 2005, 2995, 2996, 4000 ], "$lte": 8 } } }'::bson
);

-- $in on 'a' with $ne on 'b' (not equal)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 20, 1000, 2500 ] }, "b": { "$ne": 500 } } }'::bson
);

-- $in on 'a' with exact equality on 'b'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 100, 1000, 2000 ] }, "b": 5 } }'::bson
);

-- exact equality on 'a' with $in on 'b'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": 1000, "b": { "$in": [ 500, 1001, 2000, 2001 ] } } }'::bson
);

-- $in on 'a' with $nin on 'b' (not in)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 30, 40, 20, 50 ] }, "b": { "$nin": [ 5, 10, 15 ] } } }'::bson
);

-- $in on 'a' with $exists true on 'b'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 2500, 500, 3500 ] }, "b": { "$exists": true } } }'::bson
);

-- $in on 'a' with $gte/$lt range on 'b' (half-open interval)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 1, 2, 3, 1999, 2000 ] }, "b": { "$gte": 1, "$lt": 1000 } } }'::bson
);

-- $in on 'a' with $gt/$lte range on 'b' (other half-open interval)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 1, 2, 3, 1999, 2000 ] }, "b": { "$gt": 500, "$lte": 1000 } } }'::bson
);

-- large $in list on 'a' with range on 'b'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 1, 50, 2000, 2500, 3000, 3500, 100, 200, 500, 1000, 1500, 4000 ] }, "b": { "$gt": 0, "$lt": 2000 } } }'::bson
);

-- $in on 'a' where no documents match (empty result expected)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 5000, 6000, 7000 ] }, "b": { "$in": [ 1, 2, 3 ] } } }'::bson
);

-- $in on 'a' with single value, combined with $in on 'b'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 1000 ] }, "b": { "$in": [ 500, 2000, 3000 ] } } }'::bson
);

-- $in with $gte and $lte forming a tight range on both paths
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 100, 200, 300 ], "$gte": 100, "$lte": 300 }, "b": { "$in": [ 50, 100, 150 ], "$gte": 50, "$lte": 150 } } }'::bson
);

-- $in with range that excludes all $in values on 'a' (contradictory - empty result)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 5, 16, 2005, 3001 ], "$gt": 5000 }, "b": { "$in": [ 8, 6 ] } } }'::bson
);

-- $in on 'a' with $mod on 'b'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 20, 100, 200 ] }, "b": { "$mod": [ 3, 0 ] } } }'::bson
);

-- boundary values: $in covering edge ranges of all data batches
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 1, 2, 2001, 3000, 3001, 1999, 2000, 4000 ] }, "b": { "$in": [ 1, 2000, 3000, 1000, 3001, 4000 ] } } }'::bson
);

-- $in on 'a' with overlapping values in data batches (a=1000 has two docs)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 998, 999, 1000, 1001, 1002 ] }, "b": { "$gte": 1, "$lte": 3000 } } }'::bson
);

-- $in on 'a' targeting only odd values with $in on 'b' targeting multiples of 3
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 1, 3, 5, 7, 9, 11 ] }, "b": { "$in": [ 3, 6, 9, 12, 15, 18 ] } } }'::bson
);

-- $in on 'a' targeting only even values with range on 'b'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 2, 4, 6, 8, 10, 12 ] }, "b": { "$gt": 0, "$lt": 10 } } }'::bson
);

-- sort ascending with $in on both paths
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 100, 1000, 2000 ] }, "b": { "$in": [ 5, 50, 500, 1000 ] } }, "sort": { "a": 1 } }'::bson
);

-- sort descending with $in on both paths
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 1000, 100, 2000 ] }, "b": { "$in": [ 500, 5, 50, 1000 ] } }, "sort": { "a": -1 } }'::bson
);

-- sort on 'b' ascending with $in on 'a'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 1000, 100, 2000 ] }, "b": { "$gt": 0, "$lt": 1000 } }, "sort": { "b": 1 } }'::bson
);

-- $in on both.
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 1000, 20, 2000, 100, 200, 500, 3000 ] }, "b": { "$in": [ 5, 100, 500, 10, 50, 1000 ] } } }'::bson
);

-- $in on both
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 20, 100, 200, 500, 1000 ] }, "b": { "$in": [ 5, 10, 50, 100, 500 ] } } }'::bson
);

-- projection with $in on both paths
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 100, 1000 ] }, "b": { "$in": [ 5, 50, 500 ] } }, "projection": { "a": 1, "b": 1 } }'::bson
);

-- ===== Additional operator tests =====

-- $in on 'a' with $type on 'b' (type 16 = int32, type 18 = int64)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    bson_build_document('filter', bson_build_document('a', bson_build_document('$in', '{ 10, 100, 500, 2000 }'::int4[]), 'b', bson_build_document('$type', 16)))
);

-- $in on 'a' with $type "number" on 'b'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 100, 500, 2000 ] }, "b": { "$type": "int" } } }'::bson
);

-- $in on 'a' with $not wrapping $gt on 'b' (equivalent to $lte)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 100, 500, 2000 ] }, "b": { "$not": { "$gt": 100 } } } }'::bson
);

-- $in on 'a' with $not wrapping $lt on 'b' (equivalent to $gte)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 100, 500, 2000 ] }, "b": { "$not": { "$lt": 50 } } } }'::bson
);

-- $in on 'a' with $not wrapping $in on 'b'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 20, 100, 200 ] }, "b": { "$not": { "$in": [ 5, 10, 50, 100 ] } } } }'::bson
);

SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 20, 100, 200 ] }, "b": { "$nin": [ 5, 10, 50, 100 ] } } }'::bson
);

SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 20, 100, 200 ] }, "b": { "$not": { "$in": [ 6, 12, 18, 24 ] } } } }'::bson
);

SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 20, 100, 200 ] }, "b": { "$nin": [ 6, 12, 18, 24 ] } } }'::bson
);

-- $and with $in on both paths
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "$and": [ { "a": { "$in": [ 10, 100, 1000 ] } }, { "b": { "$in": [ 5, 50, 500 ] } } ] } }'::bson
);

-- $and with $in and range operators combined
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "$and": [ { "a": { "$in": [ 10, 100, 500, 1000, 2000 ] } }, { "a": { "$gte": 100 } }, { "b": { "$lt": 600 } } ] } }'::bson
);

-- $or at top-level with $in on both branches
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "$or": [ { "a": { "$in": [ 10, 20 ] }, "b": { "$in": [ 5, 10 ] } }, { "a": { "$in": [ 2500, 3000 ] }, "b": { "$in": [ 500, 1 ] } } ] } }'::bson
);

-- $or with mixed operators on different branches
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "$or": [ { "a": { "$in": [ 10, 100 ] }, "b": { "$gt": 0, "$lt": 10 } }, { "a": { "$gte": 2500, "$lte": 2600 }, "b": { "$in": [ 450, 400, 500 ] } } ] } }'::bson
);

-- $in on 'a' with $mod on 'b' (remainder 1 when divided by 5)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 2, 4, 6, 8, 10 ] }, "b": { "$mod": [ 5, 1 ] } } }'::bson
);

-- $in on 'a' with $exists false on 'b' (all docs have 'b', should return nothing)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 100, 500 ] }, "b": { "$exists": false } } }'::bson
);

-- $in on both with $ne to exclude specific values
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 300, 10, 200, 20, 30, 100 ], "$ne": 20 }, "b": { "$in": [ 5, 10, 15, 50, 100, 150 ], "$ne": 10 } } }'::bson
);

-- $in on 'a' with compound $and/$or on 'b'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 1000, 100 ] }, "$or": [ { "b": { "$lt": 10 } }, { "b": { "$gt": 400 } } ] } }'::bson
);

-- ===== Unsatisfiable / contradictory query tests (should all return empty results) =====

-- $gt and $lt on 'a' with inverted range (gt > lt, impossible)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 100, 500 ], "$gt": 1000, "$lt": 5 }, "b": { "$in": [ 5, 50, 500 ] } } }'::bson
);

-- $gte and $lte on 'b' with inverted range (gte > lte, impossible)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 100, 500 ] }, "b": { "$in": [ 5, 50, 500 ], "$gte": 1000, "$lte": 1 } } }'::bson
);

-- $in on 'a' with values outside any data range, combined with range on 'b'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ -100, -50, 0 ] }, "b": { "$gt": 0, "$lt": 100 } } }'::bson
);

-- $in on 'b' with values that exist nowhere, combined with range on 'a'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$gte": 1, "$lte": 4000 }, "b": { "$in": [ -1, -2, -3 ] } } }'::bson
);

-- $gt on 'a' beyond max value (a max is 4000)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 100, 500 ], "$gt": 50000 }, "b": { "$in": [ 5, 50, 500 ] } } }'::bson
);

-- $lt on 'a' below min value (a min is 1)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 100, 500 ], "$lt": -100 }, "b": { "$in": [ 5, 50, 500 ] } } }'::bson
);

-- both 'a' and 'b' $in with completely non-overlapping values with range
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 100, 500 ], "$gt": 500 }, "b": { "$in": [ 5, 50, 500 ], "$lt": 5 } } }'::bson
);

-- $in with empty array on 'a' (no values to match at all)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [] }, "b": { "$in": [ 5, 50, 500 ] } } }'::bson
);

-- $in with empty array on 'b'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 100, 500 ] }, "b": { "$in": [] } } }'::bson
);

-- $in with empty arrays on both paths
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [] }, "b": { "$in": [] } } }'::bson
);

-- $in on 'a' with $gt that excludes every $in value, and tight $lte on 'b'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 5, 10, 15 ], "$gt": 15 }, "b": { "$lte": 100 } } }'::bson
);

-- $in on 'b' with $lt that excludes every $in value
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 100, 500 ] }, "b": { "$in": [ 50, 100, 500 ], "$lt": 50 } } }'::bson
);

-- $and with contradictory conditions on 'a'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "$and": [ { "a": { "$gt": 500 } }, { "a": { "$lt": 100 } } ], "b": { "$in": [ 5, 50, 500 ] } } }'::bson
);

-- $ne matching all $in values on 'a' (every value is excluded)
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10 ], "$ne": 10 }, "b": { "$in": [ 5, 50 ] } } }'::bson
);

-- $nin excluding all $in values on 'a'
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 10, 20 ], "$nin": [ 10, 20 ] }, "b": { "$in": [ 5, 10 ] } } }'::bson
);

-- very large non-existent values in $in on both paths
SELECT ordered_saop_scan_test.validate_index_runtime_equivalence(
    '{ "filter": { "a": { "$in": [ 999999, 888888, 777777 ] }, "b": { "$in": [ 999999, 888888, 777777 ] } } }'::bson
);

