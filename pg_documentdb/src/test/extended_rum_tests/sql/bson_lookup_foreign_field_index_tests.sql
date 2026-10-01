SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 97100;
SET documentdb.next_collection_index_id TO 97100;

-- Regression coverage for the inner (foreign) side of a $lookup honoring
-- per-collection planner statistics when costing an index on the foreignField.
--
-- The join is a point lookup on a high cardinality path, so the foreignField
-- index should be selected. Previously the inner side was costed with a fixed
-- fallback selectivity of 1 percent instead of the collected statistics, which
-- made the index look more expensive than reading the whole collection and
-- pushed the planner onto a sequential scan.
--
-- The support function for the lookup join filter now rewrites the join into an
-- equality over the two extracted paths and asks the standard join selectivity
-- estimator for a number, so the inner side estimates a single row for a unique
-- foreignField and an index or bitmap scan wins.
--
-- The identical predicate issued as a plain equality filter is asserted first
-- as a control, so a regression in the shared index or statistics machinery is
-- distinguishable from a regression in the $lookup inner side specifically.

-- Planner statistics must be enabled before the collections and indexes are
-- created so the per-path extended statistics objects are built.
set documentdb.enablePerCollectionPlannerStatistics to on;
set documentdb.enablePlannerStatisticsNewCollections to on;
set documentdb.enableCompositeIndexPlanner to on;
set documentdb.defaultUseCompositeOpClass to on;

SELECT documentdb_api.create_collection('lookup_stats_db', 'dispatch_events');
SELECT documentdb_api.create_collection('lookup_stats_db', 'delivery_events');

CREATE SCHEMA lookup_index_tests;

-- Reports the scan node chosen for a given shard table. Absolute costs are not
-- portable across platforms, so the scan choice is asserted instead.
CREATE FUNCTION lookup_index_tests.scan_type_for_table(p_query text, p_table text) RETURNS text
 LANGUAGE plpgsql AS $$
DECLARE
    v_row text;
    v_pending text := NULL;
BEGIN
    FOR v_row IN EXECUTE p_query
    LOOP
        -- An index scan names the index on its own line and the table on the
        -- same line; a bitmap heap scan names the table one or more lines
        -- after the bitmap index scan. Track the most recent scan keyword and
        -- report it once the target table is seen.
        IF v_row LIKE '%Seq Scan on%' THEN
            v_pending := 'Seq Scan';
        ELSIF v_row LIKE '%Bitmap Heap Scan on%' THEN
            v_pending := 'Bitmap Heap Scan';
        ELSIF v_row LIKE '%Index Only Scan%' THEN
            v_pending := 'Index Only Scan';
        ELSIF v_row LIKE '%Index Scan%' THEN
            v_pending := 'Index Scan';
        END IF;

        IF v_pending IS NOT NULL AND v_row LIKE '%' || p_table || '%' THEN
            RETURN v_pending;
        END IF;
    END LOOP;
    RETURN 'no scan node found for ' || p_table;
END;
$$;

-- Reports the selectivity the planner assigned to a named index, bucketed so
-- the assertion does not depend on exact floating point formatting.
CREATE FUNCTION lookup_index_tests.classify_index_selectivity(p_query text, p_index text) RETURNS text
 LANGUAGE plpgsql AS $$
DECLARE
    v_row text;
    v_selectivity numeric;
BEGIN
    FOR v_row IN EXECUTE p_query
    LOOP
        -- Match the index name followed by its colon so that a prefix of a
        -- wider index name (traceRef_-1 vs traceRef_-1_channel_-1) cannot be
        -- picked up by accident.
        IF v_row LIKE '%' || p_index || ': (%' AND v_row LIKE '%selectivity=%' THEN
            v_selectivity := substring(v_row from 'selectivity=([0-9.eE+-]+)')::numeric;
            IF v_selectivity >= 0.01 THEN
                RETURN 'fallback selectivity (>= 0.01), statistics not applied';
            ELSE
                RETURN 'statistics derived selectivity (< 0.01)';
            END IF;
        END IF;
    END LOOP;
    RETURN 'no cost line found for index ' || p_index;
END;
$$;

-- Reports the planner row estimate for a scan on the given table as a fraction
-- of the collection size, so the assertion holds at any scale.
CREATE FUNCTION lookup_index_tests.classify_inner_row_estimate(p_query text, p_table text, p_total int) RETURNS text
 LANGUAGE plpgsql AS $$
DECLARE
    v_row text;
    v_rows numeric;
BEGIN
    FOR v_row IN EXECUTE p_query
    LOOP
        IF v_row LIKE '%Scan on%' AND v_row LIKE '%' || p_table || '%' THEN
            v_rows := substring(v_row from 'rows=([0-9]+)')::numeric;
            IF v_rows = 1 THEN
                RETURN 'one row estimated, matches the unique foreignField';
            ELSIF v_rows = round(p_total * 0.01) THEN
                RETURN 'one percent of the collection estimated, fixed fallback';
            ELSE
                RETURN 'estimated ' || round(v_rows / p_total * 100, 2) || ' percent of the collection';
            END IF;
        END IF;
    END LOOP;
    RETURN 'no scan node found for ' || p_table;
END;
$$;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'lookup_stats_db', '{ "createIndexes": "dispatch_events", "indexes": [ { "name": "emittedAt_1", "key": { "emittedAt": 1 } } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'lookup_stats_db', '{ "createIndexes": "delivery_events", "indexes": [ { "name": "traceRef_-1", "key": { "traceRef": -1 } } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'lookup_stats_db', '{ "createIndexes": "delivery_events", "indexes": [ { "name": "traceRef_-1_channel_-1", "key": { "traceRef": -1, "channel": -1 } } ] }', TRUE);

-- The outer side is a narrow time window, matching the shape of the reported
-- query: a selective $match followed by the join.
SELECT COUNT(documentdb_api.insert_one('lookup_stats_db', 'dispatch_events',
    bson_build_document(
        '_id'::text, i,
        'emittedAt'::text, '2024-03-05T00:00:00Z'::timestamptz + (i || ' seconds')::interval,
        'traceRef'::text, 'trace-' || i,
        'channel'::text, (i % 4))))
FROM generate_series(1, 400) i;

-- The inner side is large and its foreignField is unique, so a point lookup
-- matches exactly one row out of the whole collection.
SELECT COUNT(documentdb_api.insert_one('lookup_stats_db', 'delivery_events',
    bson_build_document(
        '_id'::text, i,
        'traceRef'::text, 'trace-' || i,
        'channel'::text, (i % 4))))
FROM generate_series(1, 60000) i;

ANALYZE documentdb_data.documents_97101;
ANALYZE documentdb_data.documents_97102;

set documentdb.enableExplainScanIndexCosts to on;
set documentdb.enableExtendedExplainPlans to on;

---------------------------------------------------------------------
-- Control: the same equality predicate as a plain filter.
--
-- The foreignField index is available, costed from statistics, and chosen.
---------------------------------------------------------------------

SELECT lookup_index_tests.scan_type_for_table(
    $q$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM documentdb_api_catalog.bson_aggregation_find('lookup_stats_db', '{ "find": "delivery_events", "filter": { "traceRef": "trace-137" } }') $q$,
    'documents_97102');

SELECT lookup_index_tests.classify_index_selectivity(
    $q$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM documentdb_api_catalog.bson_aggregation_find('lookup_stats_db', '{ "find": "delivery_events", "filter": { "traceRef": "trace-137" } }') $q$,
    'traceRef_-1');

---------------------------------------------------------------------
-- The $lookup inner side over the very same path and index.
--
-- The inner side now costs the join from the collected statistics, so it picks
-- an index or bitmap scan on traceRef_-1, matching the control above.
---------------------------------------------------------------------

SELECT lookup_index_tests.scan_type_for_table(
    $q$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('lookup_stats_db', '{ "aggregate": "dispatch_events", "pipeline": [ { "$match": { "$and": [ { "emittedAt": { "$gte": { "$date": "2024-03-05T00:00:30Z" } } }, { "emittedAt": { "$lte": { "$date": "2024-03-05T00:01:30Z" } } } ] } }, { "$lookup": { "from": "delivery_events", "localField": "traceRef", "foreignField": "traceRef", "as": "linkedDeliveries" } }, { "$addFields": { "linkedDeliveries": { "$filter": { "input": "$linkedDeliveries", "as": "delivery", "cond": { "$eq": [ "$$delivery.channel", "$channel" ] } } } } }, { "$match": { "linkedDeliveries": { "$size": 0 } } } ], "cursor": {} }') $q$,
    'documents_97102');

-- The per-index cost annotation emitted by the extended explain output still
-- reports the fallback selectivity. That annotation is produced by the index
-- cost path, which is separate from the join row estimate asserted next, so it
-- is captured here to keep the two paths distinguishable if either changes.
SELECT lookup_index_tests.classify_index_selectivity(
    $q$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('lookup_stats_db', '{ "aggregate": "dispatch_events", "pipeline": [ { "$match": { "$and": [ { "emittedAt": { "$gte": { "$date": "2024-03-05T00:00:30Z" } } }, { "emittedAt": { "$lte": { "$date": "2024-03-05T00:01:30Z" } } } ] } }, { "$lookup": { "from": "delivery_events", "localField": "traceRef", "foreignField": "traceRef", "as": "linkedDeliveries" } } ], "cursor": {} }') $q$,
    'traceRef_-1');

-- The decisive number: the inner side now estimates a single row, because
-- traceRef is unique and the join matches exactly one document. Previously this
-- was a fixed 1 percent of the collection, which is what made the index look
-- more expensive than reading the whole collection at production scale.
SELECT lookup_index_tests.classify_inner_row_estimate(
    $q$ EXPLAIN (COSTS ON, VERBOSE ON) SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('lookup_stats_db', '{ "aggregate": "dispatch_events", "pipeline": [ { "$match": { "$and": [ { "emittedAt": { "$gte": { "$date": "2024-03-05T00:00:30Z" } } }, { "emittedAt": { "$lte": { "$date": "2024-03-05T00:01:30Z" } } } ] } }, { "$lookup": { "from": "delivery_events", "localField": "traceRef", "foreignField": "traceRef", "as": "linkedDeliveries" } } ], "cursor": {} }') $q$,
    'documents_97102', 60000);

---------------------------------------------------------------------
-- With the feature flag off the behavior fully reverts: the inner side goes
-- back to the fixed fallback selectivity and the plan goes back to a
-- sequential scan. The boundary qual costing change is gated by the same flag,
-- so no part of this change stays active when the flag is off.
---------------------------------------------------------------------
set documentdb.enable_lookup_join_selectivity_from_stats to off;

SELECT lookup_index_tests.scan_type_for_table(
    $q$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('lookup_stats_db', '{ "aggregate": "dispatch_events", "pipeline": [ { "$match": { "$and": [ { "emittedAt": { "$gte": { "$date": "2024-03-05T00:00:30Z" } } }, { "emittedAt": { "$lte": { "$date": "2024-03-05T00:01:30Z" } } } ] } }, { "$lookup": { "from": "delivery_events", "localField": "traceRef", "foreignField": "traceRef", "as": "linkedDeliveries" } }, { "$addFields": { "linkedDeliveries": { "$filter": { "input": "$linkedDeliveries", "as": "delivery", "cond": { "$eq": [ "$$delivery.channel", "$channel" ] } } } } }, { "$match": { "linkedDeliveries": { "$size": 0 } } } ], "cursor": {} }') $q$,
    'documents_97102');

SELECT lookup_index_tests.classify_inner_row_estimate(
    $q$ EXPLAIN (COSTS ON, VERBOSE ON) SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('lookup_stats_db', '{ "aggregate": "dispatch_events", "pipeline": [ { "$match": { "$and": [ { "emittedAt": { "$gte": { "$date": "2024-03-05T00:00:30Z" } } }, { "emittedAt": { "$lte": { "$date": "2024-03-05T00:01:30Z" } } } ] } }, { "$lookup": { "from": "delivery_events", "localField": "traceRef", "foreignField": "traceRef", "as": "linkedDeliveries" } } ], "cursor": {} }') $q$,
    'documents_97102', 60000);

reset documentdb.enable_lookup_join_selectivity_from_stats;

-- Forcing the sequential path off confirms the index remains usable for the
-- join, so a future costing change cannot silently make the index unreachable.
set enable_seqscan to off;
SELECT lookup_index_tests.scan_type_for_table(
    $q$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('lookup_stats_db', '{ "aggregate": "dispatch_events", "pipeline": [ { "$match": { "$and": [ { "emittedAt": { "$gte": { "$date": "2024-03-05T00:00:30Z" } } }, { "emittedAt": { "$lte": { "$date": "2024-03-05T00:01:30Z" } } } ] } }, { "$lookup": { "from": "delivery_events", "localField": "traceRef", "foreignField": "traceRef", "as": "linkedDeliveries" } } ], "cursor": {} }') $q$,
    'documents_97102');
reset enable_seqscan;

DROP FUNCTION lookup_index_tests.scan_type_for_table(text, text);
DROP FUNCTION lookup_index_tests.classify_index_selectivity(text, text);
DROP FUNCTION lookup_index_tests.classify_inner_row_estimate(text, text, int);
DROP SCHEMA lookup_index_tests CASCADE;
SELECT documentdb_api.drop_collection('lookup_stats_db', 'dispatch_events');
SELECT documentdb_api.drop_collection('lookup_stats_db', 'delivery_events');
