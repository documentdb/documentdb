SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 29400;
SET documentdb.next_collection_index_id TO 29400;

SET documentdb.enableCompositeIndexPlanner TO on;
SET documentdb.enableIndexMetadataGlobalTracking TO on;
SET documentdb.enableExtendedExplainPlans TO on;
SET documentdb.enableExplainScanIndexCosts TO off;
SET enable_seqscan TO off;
SET enable_bitmapscan TO off;

-- ============================================================================
-- Index-only-scan lowering for a covered count over a NON-multi-key composite
-- index. All paths here are scalar (no arrays), so the index is not multi-key and
-- a count -- which never needs the document body -- can be answered from the
-- index alone (an index-only scan) with no heap access.
--
-- Data shape:
--   * zone / band are scalar strings, both covered by the composite index.
-- ============================================================================

-- Non-multi-key composite index over (zone, band).
SELECT documentdb_api_internal.create_indexes_non_concurrently('orcount_db',
    '{ "createIndexes": "records", "indexes": [ { "key": { "zone": 1, "band": 1 }, "name": "idx_zone_band", "enableOrderedIndex": 1 } ] }', TRUE);

-- Seed data (scalar only -> the index stays non-multi-key). Wrapped in COUNT() to
-- avoid per-row output spew.
SELECT COUNT(documentdb_api.insert_one('orcount_db', 'records',
    ('{ "_id": ' || i::text ||
     ', "zone": "z' || (i % 4)::text || '"' ||
     ', "band": "b' || (i % 3)::text || '" }')::bson))
FROM generate_series(1, 200) i;

-- VACUUM (ANALYZE) the collection heap we created (scoped, not a global bare
-- ANALYZE) so the visibility map is populated alongside fresh statistics,
-- keeping the index-only-scan vs. bitmap-heap-scan plan choice stable across
-- PostgreSQL versions.
VACUUM (ANALYZE) documentdb_data.documents_29401;

-- ============================================================================
-- 1. Baseline: a count whose filter is a SINGLE equality $and fully covered by
--    the composite index IS lowered to an Index Only Scan (no heap access needed
--    for the count). isMultiKey is false, so the index tuple is authoritative.
--    (Heap Fetches are masked because they are environment-dependent.)
-- ============================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('orcount_db',
        '{ "count": "records", "query": { "$and": [ { "zone": "z1" }, { "band": "b1" } ] }, "hint": "idx_zone_band" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('orcount_db',
    '{ "count": "records", "query": { "$and": [ { "zone": "z1" }, { "band": "b1" } ] }, "hint": "idx_zone_band" }');

-- ============================================================================
-- 2. A count whose filter is an $or of TWO equality $and branches over the SAME
--    non-multi-key composite index (an OR-of-ANDs). Every branch is fully covered
--    by (zone, band), so the count could be answered without touching the heap.
--    OBSERVED TODAY: the plan is a Bitmap Heap Scan (BitmapOr of two Bitmap Index
--    Scans) with a heap Recheck Cond -- it fetches heap pages even though nothing
--    but the count is needed.
--    TODO: this SHOULD be lowered to an index-only scan. The index is not
--    multi-key (isMultiKey: false) and every $or branch is fully covered by
--    (zone, band), so the union of the two equality ranges can be served straight
--    from the index with no heap access -- exactly as the single-branch count in
--    section 1 already is. The OR-of-ANDs-on-one-index shape should lower to an
--    index-only scan (a union / append of the two covered ranges) instead of a
--    Bitmap Heap Scan.
-- ============================================================================
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('orcount_db',
        '{ "count": "records", "query": { "$or": [ { "$and": [ { "zone": "z1" }, { "band": "b1" } ] }, { "$and": [ { "zone": "z2" }, { "band": "b2" } ] } ] }, "hint": "idx_zone_band" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('orcount_db',
    '{ "count": "records", "query": { "$or": [ { "$and": [ { "zone": "z1" }, { "band": "b1" } ] }, { "$and": [ { "zone": "z2" }, { "band": "b2" } ] } ] }, "hint": "idx_zone_band" }');

-- ============================================================================
-- FORCE ORDERED INDEX SCAN + CORRECTNESS VALIDATION
-- Re-run every scenario above with documentdb_rum.forceRumOrderedIndexScan = on.
-- This forces the extended-RUM access method onto its ordered (streaming) index
-- scan path even where the natural plan chose a regular or bitmap index scan, so
-- the ordered-scan code path is exercised directly. For each scenario the forced
-- EXPLAIN shows the resulting plan (note where scanType flips from regular to
-- ordered) and the query result is printed; each forced result MUST match the
-- corresponding non-forced scenario's result above, validating that the ordered
-- scan path returns identical rows.
-- ============================================================================
SET documentdb_rum.forceRumOrderedIndexScan TO on;

-- Scenario 1 (forced ordered): plan + result must match section 1 above.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('orcount_db',
        '{ "count": "records", "query": { "$and": [ { "zone": "z1" }, { "band": "b1" } ] }, "hint": "idx_zone_band" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('orcount_db',
    '{ "count": "records", "query": { "$and": [ { "zone": "z1" }, { "band": "b1" } ] }, "hint": "idx_zone_band" }');

-- Scenario 2 (forced ordered): plan + result must match section 2 above.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('orcount_db',
        '{ "count": "records", "query": { "$or": [ { "$and": [ { "zone": "z1" }, { "band": "b1" } ] }, { "$and": [ { "zone": "z2" }, { "band": "b2" } ] } ] }, "hint": "idx_zone_band" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('orcount_db',
    '{ "count": "records", "query": { "$or": [ { "$and": [ { "zone": "z1" }, { "band": "b1" } ] }, { "$and": [ { "zone": "z2" }, { "band": "b2" } ] } ] }, "hint": "idx_zone_band" }');

RESET documentdb_rum.forceRumOrderedIndexScan;

-- ============================================================================
-- An empty array must mark the index multi-key even when per-path metadata
-- tracking is off. [] is indexed as undefined, so an index-only scan would
-- recheck against undefined instead of [] and drop the row for filters such as
-- { "$lt": [2, 2] }. Count, group and covered find must all return the [] doc.
-- ============================================================================
SET documentdb.enableIndexMetadataGlobalTracking TO off;
SET documentdb.enableIndexOnlyScanForFindProject TO on;

SELECT documentdb_api_internal.create_indexes_non_concurrently('orcount_db',
    '{ "createIndexes": "emptyarr", "indexes": [ { "key": { "val": 1 }, "name": "val_1", "enableOrderedIndex": 1 } ] }', TRUE);
SELECT documentdb_api.insert_one('orcount_db', 'emptyarr', '{ "_id": 1, "val": [] }');
SELECT documentdb_api.insert_one('orcount_db', 'emptyarr', '{ "_id": 2, "val": 2 }');
SELECT documentdb_api.insert_one('orcount_db', 'emptyarr', '{ "_id": 3, "val": 3 }');
VACUUM (ANALYZE) documentdb_data.documents_29402;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('orcount_db',
        '{ "count": "emptyarr", "query": { "val": { "$lt": [2, 2] } }, "hint": "val_1" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('orcount_db',
    '{ "count": "emptyarr", "query": { "val": { "$lt": [2, 2] } }, "hint": "val_1" }');
SELECT document FROM bson_aggregation_pipeline('orcount_db',
    '{ "aggregate": "emptyarr", "pipeline": [ { "$match": { "val": { "$lt": [2, 2] } } }, { "$group": { "_id": "$val", "c": { "$sum": 1 } } } ], "hint": "val_1", "cursor": {} }');
SELECT document FROM bson_aggregation_find('orcount_db',
    '{ "find": "emptyarr", "filter": { "val": { "$lt": [2, 2] } }, "projection": { "_id": 0, "val": 1 }, "hint": "val_1" }');

RESET documentdb.enableIndexOnlyScanForFindProject;
RESET documentdb.enableIndexMetadataGlobalTracking;

-- ============================================================================
-- Kill switch, feature counter and repair for empty-array multi-key marking on
-- composite indexes without per-path multi-key tracking.
-- documentdb.enable_empty_array_multi_key_marking (default on) gates the marking.
-- The index_empty_array_marked_multi_key counter bumps when an empty array is the
-- only reason an entry is multi-key. documentdb_rum_repair_unset_multi_key_status
-- clears the index multi-key flag on the meta page.
-- ============================================================================
CREATE OR REPLACE FUNCTION documentdb_api_internal.orcount_index_oid(p_coll text, p_idx text)
RETURNS oid
LANGUAGE sql
AS $fn$
    SELECT ('documentdb_data.documents_rum_index_' || ci.index_id)::regclass::oid
    FROM documentdb_api_catalog.collection_indexes ci
    JOIN documentdb_api_catalog.collections c USING (collection_id)
    WHERE c.database_name = 'orcount_db' AND c.collection_name = p_coll
      AND (ci.index_spec).index_name = p_idx;
$fn$;

CREATE OR REPLACE FUNCTION documentdb_api_internal.orcount_multi_key_blob(p_coll text, p_idx text)
RETURNS jsonb
LANGUAGE sql
AS $fn$
    SELECT documentdb_api_internal.documentdb_rum_get_meta_page_info_index(
               documentdb_api_internal.orcount_index_oid(p_coll, p_idx)::regclass) -> 'pendingHeapTuples';
$fn$;

-- Counter checks report the increase since the last orcount_mark_empty_array_counter()
-- call instead of resetting the shared counters, which other tests may read.
CREATE OR REPLACE FUNCTION documentdb_api_internal.orcount_empty_array_counter_raw()
RETURNS bigint
LANGUAGE sql
AS $fn$
    SELECT COALESCE(SUM(usage_count), 0)::bigint
    FROM documentdb_api_internal.command_feature_counter_stats(false)
    WHERE feature_name = 'index_empty_array_marked_multi_key';
$fn$;

CREATE TEMP TABLE orcount_counter_base (v bigint);
INSERT INTO orcount_counter_base VALUES (0);

CREATE OR REPLACE FUNCTION documentdb_api_internal.orcount_mark_empty_array_counter()
RETURNS bigint
LANGUAGE sql
AS $fn$
    UPDATE orcount_counter_base
    SET v = documentdb_api_internal.orcount_empty_array_counter_raw();
    SELECT 0::bigint;
$fn$;

CREATE OR REPLACE FUNCTION documentdb_api_internal.orcount_empty_array_counter()
RETURNS bigint
LANGUAGE sql
AS $fn$
    SELECT documentdb_api_internal.orcount_empty_array_counter_raw() - v
    FROM orcount_counter_base;
$fn$;

SET documentdb.enableIndexMetadataGlobalTracking TO off;
SHOW documentdb.enable_empty_array_multi_key_marking;

-- Kill switch off: an empty array, on the leaf or a nested path, leaves the index
-- non-multi-key (blob 0) and the counter does not bump.
SET documentdb.enable_empty_array_multi_key_marking TO off;
SELECT documentdb_api_internal.orcount_mark_empty_array_counter() AS reset;
SELECT documentdb_api_internal.create_indexes_non_concurrently('orcount_db',
    '{ "createIndexes": "ea_off", "indexes": [ { "key": { "val": 1, "n.x": 1 }, "name": "val_nx_1", "enableOrderedIndex": 1 } ] }', TRUE);
SELECT documentdb_api.insert_one('orcount_db', 'ea_off', '{ "_id": 1, "val": [], "n": { "x": 1 } }');
SELECT documentdb_api.insert_one('orcount_db', 'ea_off', '{ "_id": 2, "val": 1, "n": { "x": [] } }');
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_off', 'val_nx_1');
SELECT documentdb_api_internal.orcount_empty_array_counter();

-- Real arrays still mark the index multi-key with the kill switch off, and the
-- counter does not bump.
SELECT documentdb_api.insert_one('orcount_db', 'ea_off', '{ "_id": 3, "val": [ 1 ] }');
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_off', 'val_nx_1');
SELECT documentdb_api_internal.orcount_empty_array_counter();

-- Kill switch on: the first scalar keeps the index non-multi-key, then an empty
-- array marks it multi-key (blob 1). The counter bumps once per document whose
-- only array value is empty, on both the leaf and a nested path.
RESET documentdb.enable_empty_array_multi_key_marking;
SELECT documentdb_api_internal.orcount_mark_empty_array_counter() AS reset;
SELECT documentdb_api_internal.create_indexes_non_concurrently('orcount_db',
    '{ "createIndexes": "ea_on", "indexes": [ { "key": { "val": 1, "n.x": 1 }, "name": "val_nx_1", "enableOrderedIndex": 1 } ] }', TRUE);
SELECT documentdb_api.insert_one('orcount_db', 'ea_on', '{ "_id": 1, "val": 1, "n": { "x": 1 } }');
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_on', 'val_nx_1');
SELECT documentdb_api.insert_one('orcount_db', 'ea_on', '{ "_id": 2, "val": [], "n": { "x": 1 } }');
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_on', 'val_nx_1');
SELECT documentdb_api_internal.orcount_empty_array_counter();
SELECT documentdb_api.insert_one('orcount_db', 'ea_on', '{ "_id": 3, "val": 1, "n": { "x": [] } }');
SELECT documentdb_api_internal.orcount_empty_array_counter();

-- A document that also has a real array is multi-key regardless, so the counter
-- does not bump.
SELECT documentdb_api.insert_one('orcount_db', 'ea_on', '{ "_id": 4, "val": [], "n": { "x": [ 1, 2 ] } }');
SELECT documentdb_api_internal.orcount_empty_array_counter();

-- A document with duplicate field names produces multiple terms for the path, which
-- is multi-key regardless, so the counter does not bump.
SELECT documentdb_api.insert_one('orcount_db', 'ea_on', '{ "_id": 5, "val": [], "val": 2, "n": { "x": 1 } }');
SELECT documentdb_api_internal.orcount_empty_array_counter();

-- Updates: setting a scalar to an empty array with the kill switch off leaves the
-- index non-multi-key; with it on the update marks it multi-key and bumps the
-- counter.
SELECT documentdb_api_internal.create_indexes_non_concurrently('orcount_db',
    '{ "createIndexes": "ea_upd", "indexes": [ { "key": { "val": 1 }, "name": "val_1", "enableOrderedIndex": 1 } ] }', TRUE);
SELECT documentdb_api.insert_one('orcount_db', 'ea_upd', '{ "_id": 1, "val": 1 }');
SELECT documentdb_api.insert_one('orcount_db', 'ea_upd', '{ "_id": 2, "val": 2 }');
SELECT documentdb_api_internal.orcount_mark_empty_array_counter() AS reset;
SET documentdb.enable_empty_array_multi_key_marking TO off;
SELECT documentdb_api.update('orcount_db', '{ "update": "ea_upd", "updates": [ { "q": { "_id": 1 }, "u": { "$set": { "val": [] } } } ] }');
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_upd', 'val_1');
SELECT documentdb_api_internal.orcount_empty_array_counter();
RESET documentdb.enable_empty_array_multi_key_marking;
SELECT documentdb_api.update('orcount_db', '{ "update": "ea_upd", "updates": [ { "q": { "_id": 2 }, "u": { "$set": { "val": [] } } } ] }');
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_upd', 'val_1');
SELECT documentdb_api_internal.orcount_empty_array_counter();

-- Index build: with the kill switch on an existing empty array marks the new index
-- multi-key and bumps the counter; with it off the new index stays non-multi-key.
SELECT documentdb_api.insert_one('orcount_db', 'ea_build', '{ "_id": 1, "val": [] }');
SELECT documentdb_api.insert_one('orcount_db', 'ea_build', '{ "_id": 2, "val": 2 }');
SELECT documentdb_api_internal.orcount_mark_empty_array_counter() AS reset;
SELECT documentdb_api_internal.create_indexes_non_concurrently('orcount_db',
    '{ "createIndexes": "ea_build", "indexes": [ { "key": { "val": 1 }, "name": "val_on", "enableOrderedIndex": 1 } ] }', TRUE);
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_build', 'val_on');
SELECT documentdb_api_internal.orcount_empty_array_counter();
SET documentdb.enable_empty_array_multi_key_marking TO off;
SELECT documentdb_api_internal.create_indexes_non_concurrently('orcount_db',
    '{ "createIndexes": "ea_build", "indexes": [ { "key": { "val": 1, "_id": 1 }, "name": "val_off", "enableOrderedIndex": 1 } ] }', TRUE);
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_build', 'val_off');
SELECT documentdb_api_internal.orcount_empty_array_counter();
RESET documentdb.enable_empty_array_multi_key_marking;

-- Generating terms through the diagnostic function is not an index write, so the
-- counter does not bump.
CREATE FUNCTION documentdb_api_internal.orcount_generated_terms(documentdb_core.bson, text, int4, bool,
    p_wildcardIndex int4 = -1)
    RETURNS SETOF documentdb_core.bson LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT AS '$libdir/pg_documentdb',
$$gin_bson_get_composite_path_generated_terms$$;
SELECT documentdb_api_internal.orcount_mark_empty_array_counter() AS reset;
SELECT COUNT(*) FROM documentdb_api_internal.orcount_generated_terms(
    '{ "val": [] }', '[ "val" ]', 2000, true);
SELECT documentdb_api_internal.orcount_empty_array_counter();

-- Repair: clears the multi-key flag and returns true. A second call is a no-op
-- and returns false, as is a call on an index that was never multi-key. The []
-- document is still present here, so this only checks the flag mechanics; real
-- recovery must remove all array values (empty or not) on the indexed paths first
-- (see the end of this file).
SELECT documentdb_api_internal.create_indexes_non_concurrently('orcount_db',
    '{ "createIndexes": "ea_repair", "indexes": [ { "key": { "val": 1 }, "name": "val_1", "enableOrderedIndex": 1 } ] }', TRUE);
SELECT documentdb_api.insert_one('orcount_db', 'ea_repair', '{ "_id": 1, "val": [] }');
SELECT documentdb_api.insert_one('orcount_db', 'ea_repair', '{ "_id": 2, "val": 2 }');
SELECT documentdb_api.insert_one('orcount_db', 'ea_repair', '{ "_id": 3, "val": 3 }');
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_repair', 'val_1');
SELECT documentdb_api_internal.documentdb_rum_repair_unset_multi_key_status(
    documentdb_api_internal.orcount_index_oid('ea_repair', 'val_1'));
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_repair', 'val_1');
SELECT documentdb_api_internal.documentdb_rum_repair_unset_multi_key_status(
    documentdb_api_internal.orcount_index_oid('ea_repair', 'val_1'));
SELECT documentdb_api_internal.documentdb_rum_repair_unset_multi_key_status(
    documentdb_api_internal.orcount_index_oid('ea_build', 'val_off'));

-- After repair, with the kill switch off a new empty array does not mark the
-- index multi-key again; with it on, it does.
SET documentdb.enable_empty_array_multi_key_marking TO off;
SELECT documentdb_api.insert_one('orcount_db', 'ea_repair', '{ "_id": 4, "val": [] }');
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_repair', 'val_1');
RESET documentdb.enable_empty_array_multi_key_marking;
SELECT documentdb_api.insert_one('orcount_db', 'ea_repair', '{ "_id": 5, "val": [] }');
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_repair', 'val_1');

-- Per-path multi-key tracking (mkp) and composite wildcard indexes always mark an
-- empty array as multi-key, regardless of the kill switch, and do not bump the
-- counter.
SET documentdb.enable_empty_array_multi_key_marking TO off;
SELECT documentdb_api_internal.orcount_mark_empty_array_counter() AS reset;
SET documentdb.enableIndexMetadataGlobalTracking TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('orcount_db',
    '{ "createIndexes": "ea_mkp", "indexes": [ { "key": { "val": 1 }, "name": "val_1", "enableOrderedIndex": 1 } ] }', TRUE);
SELECT documentdb_api.insert_one('orcount_db', 'ea_mkp', '{ "_id": 1, "val": [] }');
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_mkp', 'val_1');
SET documentdb.enableIndexMetadataGlobalTracking TO off;
SELECT documentdb_api_internal.create_indexes_non_concurrently('orcount_db',
    '{ "createIndexes": "ea_wc", "indexes": [ { "key": { "$**": 1 }, "name": "wc_1", "enableOrderedIndex": 1 } ] }', TRUE);
SELECT documentdb_api.insert_one('orcount_db', 'ea_wc', '{ "_id": 1, "val": [] }');
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_wc', 'wc_1');
SELECT documentdb_api_internal.orcount_empty_array_counter();
RESET documentdb.enable_empty_array_multi_key_marking;

-- With the kill switch on, empty arrays on these indexes still do not bump the
-- counter, since the marking does not depend on the kill switch there.
SELECT documentdb_api_internal.orcount_mark_empty_array_counter() AS reset;
SELECT documentdb_api.insert_one('orcount_db', 'ea_mkp', '{ "_id": 2, "val": [] }');
SELECT documentdb_api.insert_one('orcount_db', 'ea_wc', '{ "_id": 2, "val": [] }');
SELECT documentdb_api_internal.orcount_empty_array_counter();

-- Repair rejects an index that tracks multi-key status in the opclass metadata, a
-- composite wildcard index (which always needs the flag) and a non-composite index,
-- and leaves their state unchanged.
SELECT documentdb_api_internal.documentdb_rum_repair_unset_multi_key_status(
    documentdb_api_internal.orcount_index_oid('ea_mkp', 'val_1'));
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_mkp', 'val_1');
SELECT documentdb_api_internal.documentdb_rum_repair_unset_multi_key_status(
    documentdb_api_internal.orcount_index_oid('ea_wc', 'wc_1'));
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_wc', 'wc_1');
SELECT documentdb_api_internal.create_indexes_non_concurrently('orcount_db',
    '{ "createIndexes": "ea_wc", "indexes": [ { "key": { "nc": 1 }, "name": "nc_1", "enableOrderedIndex": false } ] }', TRUE);
SELECT documentdb_api_internal.documentdb_rum_repair_unset_multi_key_status(
    documentdb_api_internal.orcount_index_oid('ea_wc', 'nc_1'));

-- Repair rejects an index that is not valid.
UPDATE pg_index SET indisvalid = false
WHERE indexrelid = documentdb_api_internal.orcount_index_oid('ea_repair', 'val_1');
SELECT documentdb_api_internal.documentdb_rum_repair_unset_multi_key_status(
    documentdb_api_internal.orcount_index_oid('ea_repair', 'val_1'));
UPDATE pg_index SET indisvalid = true
WHERE indexrelid = documentdb_api_internal.orcount_index_oid('ea_repair', 'val_1');
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_repair', 'val_1');

-- Repair rejects an index that is not ready.
UPDATE pg_index SET indisready = false
WHERE indexrelid = documentdb_api_internal.orcount_index_oid('ea_repair', 'val_1');
SELECT documentdb_api_internal.documentdb_rum_repair_unset_multi_key_status(
    documentdb_api_internal.orcount_index_oid('ea_repair', 'val_1'));
UPDATE pg_index SET indisready = true
WHERE indexrelid = documentdb_api_internal.orcount_index_oid('ea_repair', 'val_1');
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_repair', 'val_1');

-- Repair rejects calls inside a transaction block, since the meta page change
-- would survive a rollback of the array removal.
BEGIN;
SELECT documentdb_api_internal.documentdb_rum_repair_unset_multi_key_status(
    documentdb_api_internal.orcount_index_oid('ea_repair', 'val_1'));
ROLLBACK;
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_repair', 'val_1');

-- It also rejects a single statement that has already written data, and calls in
-- a subtransaction.
DO $$
BEGIN
    PERFORM documentdb_api.update('orcount_db', '{ "update": "ea_repair", "updates": [ { "q": { "_id": 2 }, "u": { "$set": { "val": 20 } } } ] }');
    PERFORM documentdb_api_internal.documentdb_rum_repair_unset_multi_key_status(
        documentdb_api_internal.orcount_index_oid('ea_repair', 'val_1'));
END
$$;
DO $$
BEGIN
    PERFORM documentdb_api_internal.documentdb_rum_repair_unset_multi_key_status(
        documentdb_api_internal.orcount_index_oid('ea_repair', 'val_1'));
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '%', SQLERRM;
END
$$;
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_repair', 'val_1');
SELECT document FROM bson_aggregation_find('orcount_db',
    '{ "find": "ea_repair", "filter": { "_id": 2 } }');

-- Recovery flow: while the flag is set, the index-only scan is not used. Once all
-- array values (here [] and [5, 6]) are replaced, repair clears the flag, the
-- index-only scan comes back and results stay correct. The
-- non-empty array stays outside the queried range so its dead entries, which a
-- concurrent snapshot can keep VACUUM from removing, do not change the estimates.
SELECT documentdb_api_internal.create_indexes_non_concurrently('orcount_db',
    '{ "createIndexes": "ea_fix", "indexes": [ { "key": { "val": 1 }, "name": "val_1", "enableOrderedIndex": 1 } ] }', TRUE);
SELECT documentdb_api.insert_one('orcount_db', 'ea_fix', '{ "_id": 1, "val": [] }');
SELECT documentdb_api.insert_one('orcount_db', 'ea_fix', '{ "_id": 2, "val": 2 }');
SELECT documentdb_api.insert_one('orcount_db', 'ea_fix', '{ "_id": 3, "val": 3 }');
SELECT documentdb_api.insert_one('orcount_db', 'ea_fix', '{ "_id": 4, "val": [5, 6] }');
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_fix', 'val_1');
SELECT documentdb_api.update('orcount_db', '{ "update": "ea_fix", "updates": [ { "q": { "_id": 1 }, "u": { "$set": { "val": 1 } } } ] }');
SELECT documentdb_api.update('orcount_db', '{ "update": "ea_fix", "updates": [ { "q": { "_id": 4 }, "u": { "$set": { "val": 4 } } } ] }');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('orcount_db',
        '{ "count": "ea_fix", "query": { "val": { "$lt": 3 } }, "hint": "val_1" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT documentdb_api_internal.documentdb_rum_repair_unset_multi_key_status(
    documentdb_api_internal.orcount_index_oid('ea_fix', 'val_1'));
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_fix', 'val_1');
VACUUM (ANALYZE) documentdb_data.documents_29410;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('orcount_db',
        '{ "count": "ea_fix", "query": { "val": { "$lt": 3 } }, "hint": "val_1" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('orcount_db',
    '{ "count": "ea_fix", "query": { "val": { "$lt": 3 } }, "hint": "val_1" }');
SELECT document FROM bson_aggregation_find('orcount_db',
    '{ "find": "ea_fix", "filter": { "val": { "$lt": 3 } }, "projection": { "_id": 0, "val": 1 }, "sort": { "val": 1 }, "hint": "val_1" }');

-- Rollback flow: an index marked multi-key only by [] is repaired with the kill
-- switch off while the [] is still present. Repair clears the flag, the
-- index-only scan comes back and queries that don't match [] stay correct.
SELECT documentdb_api_internal.create_indexes_non_concurrently('orcount_db',
    '{ "createIndexes": "ea_ks", "indexes": [ { "key": { "val": 1 }, "name": "val_1", "enableOrderedIndex": 1 } ] }', TRUE);
SELECT documentdb_api.insert_one('orcount_db', 'ea_ks', '{ "_id": 1, "val": [] }');
SELECT documentdb_api.insert_one('orcount_db', 'ea_ks', '{ "_id": 2, "val": 2 }');
SELECT documentdb_api.insert_one('orcount_db', 'ea_ks', '{ "_id": 3, "val": 3 }');
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_ks', 'val_1');
SET documentdb.enable_empty_array_multi_key_marking TO off;
SELECT documentdb_api_internal.documentdb_rum_repair_unset_multi_key_status(
    documentdb_api_internal.orcount_index_oid('ea_ks', 'val_1'));
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_ks', 'val_1');
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
    SELECT document FROM bson_aggregation_count('orcount_db',
        '{ "count": "ea_ks", "query": { "val": { "$lt": 3 } }, "hint": "val_1" }')
$cmd$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('orcount_db',
    '{ "count": "ea_ks", "query": { "val": { "$lt": 3 } }, "hint": "val_1" }');
SELECT document FROM bson_aggregation_find('orcount_db',
    '{ "find": "ea_ks", "filter": { "val": { "$lt": 3 } }, "projection": { "_id": 0, "val": 1 }, "sort": { "val": 1 }, "hint": "val_1" }');
RESET documentdb.enable_empty_array_multi_key_marking;

-- A unique composite index containing [] is marked multi-key and still enforces
-- uniqueness.
SELECT documentdb_api_internal.create_indexes_non_concurrently('orcount_db',
    '{ "createIndexes": "ea_uniq", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "unique": true, "enableOrderedIndex": 1 } ] }', TRUE);
SELECT documentdb_api.insert_one('orcount_db', 'ea_uniq', '{ "_id": 1, "a": [], "b": 1 }');
SELECT documentdb_api_internal.orcount_multi_key_blob('ea_uniq', 'a_b_1');
SELECT documentdb_api.insert_one('orcount_db', 'ea_uniq', '{ "_id": 2, "a": [], "b": 1 }');
SELECT documentdb_api.insert_one('orcount_db', 'ea_uniq', '{ "_id": 3, "a": [], "b": 2 }');
SELECT document FROM bson_aggregation_count('orcount_db',
    '{ "count": "ea_uniq", "query": { "a": [] } }');

DROP FUNCTION documentdb_api_internal.orcount_multi_key_blob(text, text);
DROP FUNCTION documentdb_api_internal.orcount_index_oid(text, text);
DROP FUNCTION documentdb_api_internal.orcount_empty_array_counter();
DROP FUNCTION documentdb_api_internal.orcount_mark_empty_array_counter();
DROP FUNCTION documentdb_api_internal.orcount_empty_array_counter_raw();
DROP FUNCTION documentdb_api_internal.orcount_generated_terms(documentdb_core.bson, text, int4, bool, int4);

RESET documentdb.enableIndexMetadataGlobalTracking;
