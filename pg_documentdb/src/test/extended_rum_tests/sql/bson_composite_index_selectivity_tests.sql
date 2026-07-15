SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 200;
SET documentdb.next_collection_index_id TO 200;

set documentdb.defaultUseCompositeOpClass to on;

CREATE SCHEMA index_selectivity_tests;
CREATE FUNCTION index_selectivity_tests.validate_explain_has_minimal_bounds(query text) RETURNS void
 LANGUAGE plpgsql AS $$
DECLARE
    v_explain_row text;
    v_has_index_bounds boolean := false;
BEGIN
    FOR v_explain_row IN EXECUTE p_query
    LOOP
        IF v_explain_row LIKE '%indexBounds:%' THEN
            v_has_index_bounds := true;
            IF LOWER(v_explain_row) LIKE '%minkey%' OR LOWER(v_explain_row) LIKE '%maxkey%' THEN
                RAISE EXCEPTION 'Pushed to an index which has a path that is not fully constrained %', v_explain_row;
            END IF;
        END IF;
    END LOOP;
    IF NOT v_has_index_bounds THEN
        RAISE EXCEPTION 'Expected index bounds not found in EXPLAIN output for query: %', p_query;
    END IF;
END;
$$;

CREATE FUNCTION index_selectivity_tests.transform_explain_index_bounds(p_query text) RETURNS SETOF TEXT
 LANGUAGE plpgsql AS $$
DECLARE
    v_explain_row text;
BEGIN
    FOR v_explain_row IN EXECUTE p_query
    LOOP
        IF regexp_like(v_explain_row, '.+startup cost=[0-9\.]+, total cost=[0-9\.]+, selectivity=[0-9\.e-]+, correlation=[0-9\.]+, estimated index pages loaded=[0-9\.]+%, estimated total index entries=5000, boundary selectivity=[0-9\.e-]+, num boundaries=[0-9]+, estimated data pages loaded=[0-9\.]+%') THEN
            RETURN NEXT regexp_replace(v_explain_row, '=[0-9\.e-]+', '=xx.xx', 'g');
        ELSE
            RETURN NEXT v_explain_row;
        END IF;
    END LOOP;
END;
$$;

-- create 2 single path indexes
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_idb', '{ "createIndexes": "comp_index_selectivity", "indexes": [ { "name": "comp_index1", "key": { "path1": 1 } } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_idb', '{ "createIndexes": "comp_index_selectivity", "indexes": [ { "name": "comp_index2", "key": { "path2": 1 } } ] }', TRUE);

-- insert 5000 rows
SELECT COUNT(documentdb_api.insert_one('comp_idb', 'comp_index_selectivity', bson_build_document('_id'::text, i, 'path1'::text, i, 'path2'::text, i))) FROM generate_series(1, 5000) i;

ANALYZE documentdb_data.documents_201;

-- now do a query on both fields, where the selectivity of 1 is far less than the other
-- this should pick index for path1 (but doesn't)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('comp_idb', '{ "find": "comp_index_selectivity", "filter": { "path1": 5, "path2": { "$gt": 500 } }}');

-- enable the composite planner GUC and now things should work (since documents are smaller than 1 KB)
set documentdb.enableCompositeIndexPlanner to on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('comp_idb', '{ "find": "comp_index_selectivity", "filter": { "path1": 5, "path2": { "$gt": 500 } }}');

set documentdb.enableExplainScanIndexCosts to on;
set documentdb.enableExtendedExplainPlans to on;
SELECT index_selectivity_tests.transform_explain_index_bounds($cmd$ 
    EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('comp_idb', '{ "find": "comp_index_selectivity", "filter": { "path1": 5, "path2": { "$gt": 500 } }}');
$cmd$);
reset documentdb.enableExplainScanIndexCosts;
reset documentdb.enableExtendedExplainPlans;

-- repeat this setup but with documents > 1 KB
TRUNCATE documentdb_data.documents_201;

SELECT COUNT(documentdb_api.insert_one('comp_idb', 'comp_index_selectivity',
    bson_build_document('_id'::text, i, 'path1'::text, i, 'path2'::text, i, 'large_text_field'::text, repeat('aaaaaaa', 500) ))) FROM generate_series(1, 5000) i;

ANALYZE documentdb_data.documents_201;
set documentdb.enableCompositeIndexPlanner to off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('comp_idb', '{ "find": "comp_index_selectivity", "filter": { "path1": 5, "path2": { "$gt": 500 } }}');

set documentdb.enableCompositeIndexPlanner to on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('comp_idb', '{ "find": "comp_index_selectivity", "filter": { "path1": 5, "path2": { "$gt": 500 } }}');

set documentdb.enableExtendedExplainPlans to on;
set documentdb.enableCompositeIndexPlanner to off;

-- Create indexes on the two $or branch fields and a compound sort index
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_idb', '{ "createIndexes": "generic_selectiviity_coll", "indexes": [ { "name": "idx_refs_val", "key": { "refs.val": 1 } } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_idb', '{ "createIndexes": "generic_selectiviity_coll", "indexes": [ { "name": "idx_code_id", "key": { "code": 1, "_id": 1 } } ] }', TRUE);

-- Insert docs > 1KB with padding. Many docs match the $in filter to make BitmapOr + Sort expensive.
SELECT COUNT(documentdb_api.insert_one('comp_idb', 'generic_selectiviity_coll',
    bson_build_document(
        '_id'::text, i,
        'code'::text, CASE WHEN i % 5 = 0 THEN 'xK9mTargetValue' ELSE 'otherVal' || i END,
        'refs'::text, ('[ { "val": "' || CASE WHEN i % 7 = 0 THEN 'xK9mTargetValue' ELSE 'otherRef' || i END || '" } ]')::bson,
        'removed'::text, CASE WHEN i % 100 = 0 THEN true ELSE false END,
        'padding'::text, repeat('z', 2000)
    ))) FROM generate_series(1, 10000) i;

ANALYZE documentdb_data.documents_202;

-- Test: $or with $in on separate indexes should not bitmap OR with composite planner
-- This reproduces a scenario where a query with $or, $ne, sort and limit picks a
-- bitmap OR plan unless enableCompositeIndexPlanner is set, where the composite planner
-- adjusts cost estimates on large documents to prefer the ordered index scan.
-- Without composite planner: uses Bitmap OR (suboptimal for large docs with sort + limit)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('comp_idb',
    '{ "find": "generic_selectiviity_coll", "filter": { "$or": [ { "code": { "$in": [ "xK9mTargetValue" ] } }, { "refs.val": { "$in": [ "xK9mTargetValue" ] } } ], "removed": { "$ne": true } }, "sort": { "code": 1 }, "limit": 50 }');

-- With composite planner: should use Bitmap OR
set documentdb.enableCompositeIndexPlanner to on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('comp_idb',
    '{ "find": "generic_selectiviity_coll", "filter": { "$or": [ { "code": { "$in": [ "xK9mTargetValue" ] } }, { "refs.val": { "$in": [ "xK9mTargetValue" ] } } ], "removed": { "$ne": true } }, "sort": { "code": 1 }, "limit": 50 }');

-- Test: composite planner picks optimal compound index for multi-field filter with sort + limit
-- Without composite planner, the planner picks a suboptimal index whose leading key is more
-- selective but does not align with the sort. With composite planner, it picks the compound
-- index whose key order aligns with the sort, avoiding an expensive sort step on large docs.
set documentdb.enableCompositeIndexPlanner to off;

-- Drop indexes from previous test and truncate
CALL documentdb_api.drop_indexes('comp_idb', '{ "dropIndexes": "generic_selectiviity_coll", "index": ["idx_refs_val", "idx_code_id"] }');
TRUNCATE documentdb_data.documents_202;

-- Create three compound indexes
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_idb', '{ "createIndexes": "generic_selectiviity_coll", "indexes": [ { "name": "idx_flag_groupId_ownerId", "key": { "flag": 1, "groupId": 1, "_id.ownerId": 1 } } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_idb', '{ "createIndexes": "generic_selectiviity_coll", "indexes": [ { "name": "idx_flag_ownerGroupId_ownerId", "key": { "flag": 1, "_id.ownerGroupId": 1, "_id.ownerId": 1 } } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_idb', '{ "createIndexes": "generic_selectiviity_coll", "indexes": [ { "name": "idx_ownerId_groupId_state_flag_id", "key": { "_id.ownerId": 1, "groupId": 1, "state": 1, "flag": 1, "_id": 1 } } ] }', TRUE);

-- Insert 5000 docs > 1KB with compound _id
SELECT COUNT(documentdb_api.insert_one('comp_idb', 'generic_selectiviity_coll',
    ('{ "_id": { "ownerId": "owner-' || (i % 10)::text || '", "ownerGroupId": "ownerGroup-' || (i % 50)::text || '", "seq": ' || i::text ||
     ' }, "flag": ' || CASE WHEN i % 50 = 0 THEN 'true' ELSE 'false' END ||
     ', "groupId": "group-' || (i % 200)::text ||
     '", "state": "active", "padding": "' || repeat('z', 1100) || '" }')::bson
    )) FROM generate_series(1, 5000) i;

ANALYZE documentdb_data.documents_202;

-- Without composite planner: picks suboptimal idx_ownerId_groupId_state_flag_id
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('comp_idb',
    '{ "find": "generic_selectiviity_coll", "filter": { "flag": false, "_id.ownerId": { "$in": ["owner-3"] }, "groupId": { "$in": ["group-0", "group-1", "group-2", "group-3", "group-4", "group-5", "group-6", "group-7", "group-8", "group-9", "group-10" ] } }, "sort": { "groupId": 1, "_id": 1 }, "limit": 500 }');

-- With composite planner: picks optimal idx_flag_groupId_ownerId
set documentdb.enableCompositeIndexPlanner to on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('comp_idb',
    '{ "find": "generic_selectiviity_coll", "filter": { "flag": false, "_id.ownerId": { "$in": ["owner-3"] }, "groupId": { "$in": ["group-0", "group-1", "group-2", "group-3", "group-4", "group-5", "group-6", "group-7", "group-8", "group-9", "group-10" ] } }, "sort": { "groupId": 1, "_id": 1 }, "limit": 500 }');

-- Test: composite planner picks correct index with $elemMatch on nested arrays
-- Reproduces https://github.com/documentdb/documentdb/issues/405
-- Without composite planner, a shorter prefix-matching index is picked instead of the
-- longer compound index that covers the $elemMatch fields.
set documentdb.enableCompositeIndexPlanner to off;
set enable_seqscan to on;
set enable_bitmapscan to on;

-- Drop indexes from previous test and truncate
CALL documentdb_api.drop_indexes('comp_idb', '{ "dropIndexes": "generic_selectiviity_coll", "index": ["idx_flag_groupId_ownerId", "idx_flag_ownerGroupId_ownerId", "idx_ownerId_groupId_state_flag_id"] }');
TRUNCATE documentdb_data.documents_202;

-- Create three compound indexes with enableOrderedIndex
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_idb', '{ "createIndexes": "generic_selectiviity_coll", "indexes": [ { "key": { "tenantId": 1, "active": 1, "status": 1, "steps.assignees.userId": 1, "steps.assignees.status": 1, "steps.assignees.active": 1, "label": 1 }, "name": "idx_tenant_active_status_userId_assigneeStatus_assigneeActive_label", "enableOrderedIndex": true } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_idb', '{ "createIndexes": "generic_selectiviity_coll", "indexes": [ { "key": { "tenantId": 1, "steps.assignees.userId": 1, "steps.assignees.status": 1, "steps.assignees.active": 1, "steps.assignees.updatedAt": -1 }, "name": "idx_tenant_userId_assigneeStatus_assigneeActive_updatedAt", "enableOrderedIndex": true } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_idb', '{ "createIndexes": "generic_selectiviity_coll", "indexes": [ { "key": { "tenantId": 1, "active": 1, "status": 1, "createdAt": -1 }, "name": "idx_tenant_active_status_createdAt", "enableOrderedIndex": true } ] }', TRUE);

-- Insert 1000 docs with nested array structure
SELECT COUNT(documentdb_api.insert_one('comp_idb', 'generic_selectiviity_coll',
    FORMAT('{ "_id": %s, "tenantId": "tenant-abc-001", "active": 1, "status": 1, "steps": [ { "assignees": [ { "status": 4, "active": 1, "userId": "user-xyz-001", "updatedAt": "20260101120000" } ] } ], "label": "entry-name" }', i)::bson
    )) FROM generate_series(1, 1000) i;

ANALYZE documentdb_data.documents_202;

-- Without composite planner: picks idx_tenant_active_status_createdAt (suboptimal, only matches 3-field prefix)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('comp_idb',
    '{ "find": "generic_selectiviity_coll", "filter": { "tenantId": { "$in": ["tenant-abc-001", "tenant-abc-002"] }, "active": 1, "status": { "$in": [1, 2, 3] }, "steps.assignees": { "$elemMatch": { "userId": "user-xyz-001", "status": 4, "active": 1 } } } }');

-- With composite planner: picks a better index that covers more query fields
set documentdb.enableCompositeIndexPlanner to on;
set enable_seqscan to off;
set enable_bitmapscan to off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('comp_idb',
    '{ "find": "generic_selectiviity_coll", "filter": { "tenantId": { "$in": ["tenant-abc-001", "tenant-abc-002"] }, "active": 1, "status": { "$in": [1, 2, 3] }, "steps.assignees": { "$elemMatch": { "userId": "user-xyz-001", "status": 4, "active": 1 } } } }');

-- Reset before next section
set enable_seqscan to on;
set enable_bitmapscan to on;
set documentdb.enableCompositeIndexPlanner to off;

--------------------------------------------------------------------------------
-- Test: Per-collection planner statistics using btree selectivity functions
-- Validates that with per-collection stats enabled, the planner uses accurate
-- selectivity estimates (eqsel/scalargtsel/etc.) instead of the generic
-- restriction selectivity which clamps at 0.0001. This prevents false positive
-- BitmapAnd plans when a highly selective index exists.
--------------------------------------------------------------------------------

SET documentdb.enablePerCollectionPlannerStatistics TO on;
SET documentdb.enablePlannerStatisticsNewCollections TO on;
SELECT documentdb_api.create_collection('comp_idb', 'btree_selectivity');

-- Create indexes on a highly selective field (guid) and a low-selectivity field (category)
SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_idb', '{ "createIndexes": "btree_selectivity", "indexes": [ { "key": { "guid": 1 }, "name": "guid_1" }, { "key": { "category": 1 }, "name": "category_1" }, { "key": { "score": 1 }, "name": "score_1" } ] }', TRUE);

-- Insert 50000 rows: unique guids, ~10% category="rare", ~90% category="common"
-- Documents > 1KB to ensure index scans are preferred over seq scan
-- At 50K rows: true guid selectivity = 2/50002 ~ 0.00004
-- Without fix: clamped to 0.0001 (2.5x overestimate → BitmapAnd becomes "cheap")
-- With fix: uses eqsel giving accurate estimate → Index Scan preferred
SELECT COUNT(documentdb_api.insert_one('comp_idb', 'btree_selectivity',
    bson_build_document('_id'::text, i, 'guid'::text, ('guid-' || lpad(i::text, 8, '0')), 'category'::text, 'common'::text, 'score'::text, i, 'padding'::text, repeat('x', 1200))))
FROM generate_series(1, 45000) i;
SELECT COUNT(documentdb_api.insert_one('comp_idb', 'btree_selectivity',
    bson_build_document('_id'::text, i, 'guid'::text, ('guid-' || lpad(i::text, 8, '0')), 'category'::text, 'rare'::text, 'score'::text, i, 'padding'::text, repeat('x', 1200))))
FROM generate_series(45001, 50000) i;

-- Insert 2 target rows with known guid and category="rare"
SELECT documentdb_api.insert_one('comp_idb', 'btree_selectivity',
    '{ "_id": 50001, "guid": "target-guid-00000001", "category": "rare", "score": 5000, "padding": "target1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }');
SELECT documentdb_api.insert_one('comp_idb', 'btree_selectivity',
    '{ "_id": 50002, "guid": "target-guid-00000001", "category": "rare", "score": 5001, "padding": "target2xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }');

ANALYZE documentdb_data.documents_203;

SET enable_seqscan TO off;

-- Test: Without per-collection stats, both guid and category get generic selectivity
-- (LowSelectivity = 0.01). The planner incorrectly combines both indexes via BitmapAnd
-- because it overestimates the number of matching rows for each index.
SET documentdb.enablePerCollectionPlannerStatistics TO off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('comp_idb',
    '{ "find": "btree_selectivity", "filter": { "$and": [ {"guid": "target-guid-00000001"}, {"category": "rare"} ] } }');

-- Test: With per-collection stats enabled, eqsel returns accurate selectivity for guid
-- (2/50002 ~ 0.00004) which is lower than category (5000/50002 ~ 0.1).
-- The accurate selectivity avoids BitmapAnd and uses guid_1 directly.
-- Disable bitmap scan for deterministic plan output (IndexScan vs BitmapHeapScan
-- is marginal at this data size; the key point is BitmapAnd is avoided above).
SET enable_bitmapscan TO off;
SET documentdb.enablePerCollectionPlannerStatistics TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('comp_idb',
    '{ "find": "btree_selectivity", "filter": { "$and": [ {"guid": "target-guid-00000001"}, {"category": "rare"} ] } }');

-- Test: Range query on score with guid uses scalar selectivity functions
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('comp_idb',
    '{ "find": "btree_selectivity", "filter": { "$and": [ {"guid": "target-guid-00000001"}, {"score": {"$gte": 4000, "$lte": 6000}} ] } }');

-- Test: Verify query returns correct results
SELECT document FROM bson_aggregation_find('comp_idb',
    '{ "find": "btree_selectivity", "filter": { "$and": [ {"guid": "target-guid-00000001"}, {"category": "rare"} ] } }');

-- Cleanup: drop the collection to free resources
SELECT documentdb_api.drop_collection('comp_idb', 'btree_selectivity');

-- ============================================================================
-- Root cause: GetDollarExistsSelectivity scenario
-- ============================================================================

SET documentdb.enablePerCollectionPlannerStatistics = on;
SET documentdb.enablePlannerStatisticsNewCollections = on;

-- Create a collection with a sparse field (some docs have "b", some don't)
SELECT documentdb_api.insert_one('comp_idb', 'exists_sel', '{ "_id": 1, "a": 1 }');
SELECT documentdb_api.insert_one('comp_idb', 'exists_sel', '{ "_id": 2, "a": 2, "b": 1 }');
SELECT documentdb_api.insert_one('comp_idb', 'exists_sel', '{ "_id": 3, "a": 3 }');
SELECT documentdb_api.insert_one('comp_idb', 'exists_sel', '{ "_id": 4, "a": 4, "b": 2 }');
SELECT documentdb_api.insert_one('comp_idb', 'exists_sel', '{ "_id": 5, "a": 5 }');

-- Create compound index (generates extended statistics when GUCs are on)
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'comp_idb',
    '{ "createIndexes": "exists_sel", "indexes": [{ "key": { "a": 1, "b": 1 }, "name": "idx_exists_sel" }] }',
    true
);

\d documentdb_data.documents_204

-- Force stats collection
ANALYZE documentdb_data.documents_204;

-- $exists: true on field "a" with stats - exercises GetDollarExistsSelectivity
SELECT document from documentdb_api_catalog.bson_aggregation_find('comp_idb', '{ "find": "exists_sel", "filter": { "a": { "$exists": true } } }');

-- $exists: false on field "a" with stats
SELECT document from documentdb_api_catalog.bson_aggregation_find('comp_idb', '{ "find": "exists_sel", "filter": { "a": { "$exists": false } } }');

-- Cleanup
SELECT documentdb_api.drop_collection('comp_idb', 'exists_sel');

RESET enable_seqscan;
RESET enable_bitmapscan;
RESET documentdb.enablePerCollectionPlannerStatistics;
RESET documentdb.enablePlannerStatisticsNewCollections;
RESET documentdb.enableCompositeIndexPlanner;