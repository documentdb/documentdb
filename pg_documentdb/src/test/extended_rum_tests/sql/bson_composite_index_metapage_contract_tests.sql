SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 14000;
SET documentdb.next_collection_index_id TO 14000;

-- Per-path metadata tracking folds the multi-key / truncation / reduced-correlated
-- state of a composite index into the metapage opclass-metadata blob (surfaced by
-- documentdb_rum_get_meta_page_info as "pendingHeapTuples" / "pendingHeapTuplesHex").
-- This suite validates that the hex blob matches the documented bit reservation:
--   bit0      - isMultiKey (any path multi-key)
--   bit1-33   - pathWiseMultiKey (one bit per path; path i -> bit (1 + i))
--   bit34     - reduced correlated
--   bit35     - truncated (any path truncated)
--   bit36-41  - perPathTruncated (one bit per path for the first 6 paths;
--               path i -> bit (36 + i); truncation on paths 6+ is lossy and is
--               reflected only in the global truncated bit 35)
--   bit42-63  - unused
set documentdb.enableIndexMetadataGlobalTracking to on;

-- Helper: return only the opclass-metadata blob (decimal + hex) for the metapage of
-- the named index. Reading just the blob keeps the validation focused on the contract
-- bits and independent of incidental page-layout counters.
CREATE OR REPLACE FUNCTION documentdb_api_internal.composite_metapage_blob(
    p_db text, p_coll text, p_idx text)
RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_col bigint;
    v_idx bigint;
    v_info jsonb;
BEGIN
    SELECT collection_id INTO v_col
    FROM documentdb_api_catalog.collections
    WHERE database_name = p_db AND collection_name = p_coll;

    SELECT index_id INTO v_idx
    FROM documentdb_api_catalog.collection_indexes
    WHERE collection_id = v_col AND (index_spec).index_name = p_idx;

    SELECT documentdb_api_internal.documentdb_rum_get_meta_page_info(
               public.get_raw_page('documentdb_data.documents_rum_index_' || v_idx, 0))
      INTO v_info;

    RETURN jsonb_build_object(
        'pendingHeapTuples', v_info -> 'pendingHeapTuples',
        'pendingHeapTuplesHex', v_info -> 'pendingHeapTuplesHex');
END
$fn$;

-- ---------------------------------------------------------------------------
-- No flags: a two-path index over short scalars sets no metadata bits, so the
-- blob is 0 (hex is null).
-- ---------------------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('mpc_db', '{ "createIndexes": "c_plain", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mpc_db', 'c_plain', '{ "_id": 1, "a": 1, "b": 2 }');
-- Expected: no bits set -> 0x(null)
SELECT documentdb_api_internal.composite_metapage_blob('mpc_db', 'c_plain', 'a_b_1');

-- ---------------------------------------------------------------------------
-- isMultiKey + pathWiseMultiKey: an array only on the first path (index 0) sets
-- bit0 (isMultiKey) and bit1 (path 0). Expected blob 0x3.
-- ---------------------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('mpc_db', '{ "createIndexes": "c_mk_a", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mpc_db', 'c_mk_a', '{ "_id": 1, "a": [ 1, 2, 3 ], "b": 5 }');
-- Expected: bit0 | bit1 -> 0x3
SELECT documentdb_api_internal.composite_metapage_blob('mpc_db', 'c_mk_a', 'a_b_1');

-- An array only on the second path (index 1) sets bit0 and bit2. Expected 0x5.
SELECT documentdb_api_internal.create_indexes_non_concurrently('mpc_db', '{ "createIndexes": "c_mk_b", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mpc_db', 'c_mk_b', '{ "_id": 1, "a": 5, "b": [ 1, 2, 3 ] }');
-- Expected: bit0 | bit2 -> 0x5
SELECT documentdb_api_internal.composite_metapage_blob('mpc_db', 'c_mk_b', 'a_b_1');

-- Arrays on both paths set bit0, bit1 and bit2. Expected 0x7.
SELECT documentdb_api_internal.create_indexes_non_concurrently('mpc_db', '{ "createIndexes": "c_mk_ab", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mpc_db', 'c_mk_ab', '{ "_id": 1, "a": [ 1, 2 ], "b": [ 3, 4 ] }');
-- Expected: bit0 | bit1 | bit2 -> 0x7
SELECT documentdb_api_internal.composite_metapage_blob('mpc_db', 'c_mk_ab', 'a_b_1');

-- pathWiseMultiKey is cumulative across inserts: starting multi-key only on path 0,
-- a later document that is multi-key only on path 1 unions bit2 into the blob.
SELECT documentdb_api_internal.create_indexes_non_concurrently('mpc_db', '{ "createIndexes": "c_mk_cumulative", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mpc_db', 'c_mk_cumulative', '{ "_id": 1, "a": [ 1, 2 ], "b": 5 }');
-- Expected after first insert: bit0 | bit1 -> 0x3
SELECT documentdb_api_internal.composite_metapage_blob('mpc_db', 'c_mk_cumulative', 'a_b_1');
SELECT documentdb_api.insert_one('mpc_db', 'c_mk_cumulative', '{ "_id": 2, "a": 9, "b": [ 6, 7 ] }');
-- Expected after second insert: bit0 | bit1 | bit2 -> 0x7
SELECT documentdb_api_internal.composite_metapage_blob('mpc_db', 'c_mk_cumulative', 'a_b_1');

-- ---------------------------------------------------------------------------
-- truncated + perPathTruncated: a long scalar that exceeds the per-path term size
-- limit sets the global truncated bit (35) and the per-path truncated bit for that
-- path (36 + path index).
-- ---------------------------------------------------------------------------
SET documentdb.indexTermLimitOverride TO 50;

-- Truncation only on path 0: bit35 | bit36. Expected 0x1800000000.
SELECT documentdb_api_internal.create_indexes_non_concurrently('mpc_db', '{ "createIndexes": "c_tr_a", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mpc_db', 'c_tr_a', '{ "_id": 1, "a": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "b": 5 }');
-- Expected: bit35 | bit36 -> 0x1800000000
SELECT documentdb_api_internal.composite_metapage_blob('mpc_db', 'c_tr_a', 'a_b_1');

-- Truncation only on path 1: bit35 | bit37. Expected 0x2800000000.
SELECT documentdb_api_internal.create_indexes_non_concurrently('mpc_db', '{ "createIndexes": "c_tr_b", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mpc_db', 'c_tr_b', '{ "_id": 1, "a": 5, "b": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }');
-- Expected: bit35 | bit37 -> 0x2800000000
SELECT documentdb_api_internal.composite_metapage_blob('mpc_db', 'c_tr_b', 'a_b_1');

-- ---------------------------------------------------------------------------
-- Combined multi-key + truncation: a multi-key array on path 0 and a truncated
-- scalar on path 1 set bit0 | bit1 (multi-key path 0) and bit35 | bit37 (truncated
-- path 1). Expected 0x2800000003.
-- ---------------------------------------------------------------------------
SELECT documentdb_api_internal.create_indexes_non_concurrently('mpc_db', '{ "createIndexes": "c_combined", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mpc_db', 'c_combined', '{ "_id": 1, "a": [ 1, 2, 3 ], "b": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }');
-- Expected: bit0 | bit1 | bit35 | bit37 -> 0x2800000003
SELECT documentdb_api_internal.composite_metapage_blob('mpc_db', 'c_combined', 'a_b_1');

RESET documentdb.indexTermLimitOverride;

-- ---------------------------------------------------------------------------
-- perPathTruncated is tracked only for the first 6 paths (bits 36-41). On a wide
-- 8-path index, truncation on the last tracked path (index 5) sets bit35 | bit41,
-- while truncation on paths 6 or 7 is lossy: only the global truncated bit (35) is
-- set, with no per-path bit.
-- ---------------------------------------------------------------------------
SET documentdb.indexTermLimitOverride TO 800;

-- Truncation on path 5 (last tracked): bit35 | bit41. Expected 0x20800000000.
SELECT documentdb_api_internal.create_indexes_non_concurrently('mpc_db', '{ "createIndexes": "c_w8_p5", "indexes": [ { "key": { "p0":1,"p1":1,"p2":1,"p3":1,"p4":1,"p5":1,"p6":1,"p7":1 }, "name": "w8", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mpc_db', 'c_w8_p5', '{ "_id":1,"p0":1,"p1":1,"p2":1,"p3":1,"p4":1,"p5":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","p6":1,"p7":1 }');
-- Expected: bit35 | bit41 -> 0x20800000000
SELECT documentdb_api_internal.composite_metapage_blob('mpc_db', 'c_w8_p5', 'w8');

-- Truncation on path 6 (beyond the tracked range, lossy): bit35 only. Expected 0x800000000.
SELECT documentdb_api_internal.create_indexes_non_concurrently('mpc_db', '{ "createIndexes": "c_w8_p6", "indexes": [ { "key": { "p0":1,"p1":1,"p2":1,"p3":1,"p4":1,"p5":1,"p6":1,"p7":1 }, "name": "w8", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mpc_db', 'c_w8_p6', '{ "_id":1,"p0":1,"p1":1,"p2":1,"p3":1,"p4":1,"p5":1,"p6":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","p7":1 }');
-- Expected: bit35 (lossy, no per-path bit) -> 0x800000000
SELECT documentdb_api_internal.composite_metapage_blob('mpc_db', 'c_w8_p6', 'w8');

-- Truncation on path 7 (beyond the tracked range, lossy): bit35 only. Expected 0x800000000.
SELECT documentdb_api_internal.create_indexes_non_concurrently('mpc_db', '{ "createIndexes": "c_w8_p7", "indexes": [ { "key": { "p0":1,"p1":1,"p2":1,"p3":1,"p4":1,"p5":1,"p6":1,"p7":1 }, "name": "w8", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mpc_db', 'c_w8_p7', '{ "_id":1,"p0":1,"p1":1,"p2":1,"p3":1,"p4":1,"p5":1,"p6":1,"p7":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }');
-- Expected: bit35 (lossy, no per-path bit) -> 0x800000000
SELECT documentdb_api_internal.composite_metapage_blob('mpc_db', 'c_w8_p7', 'w8');

RESET documentdb.indexTermLimitOverride;

-- ---------------------------------------------------------------------------
-- reduced correlated: when reduced-correlated term generation is enabled, an index
-- over arrays of objects sharing a common sub-path emits no extra correlated
-- sentinel term under metadata tracking; instead bit34 is set in the blob. The
-- multi-key bits for the two object sub-paths are also set, giving 0x400000007.
-- ---------------------------------------------------------------------------
SET documentdb.enableCompositeReducedCorrelatedTerms TO on;
SELECT documentdb_api_internal.create_indexes_non_concurrently('mpc_db', '{ "createIndexes": "c_reduced", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "ab_ac_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mpc_db', 'c_reduced', '{ "_id": 1, "a": [ { "b": 1, "c": 2 }, { "b": 3, "c": 4 } ] }');
-- Expected: bit34 | bit0 | bit1 | bit2 -> 0x400000007
SELECT documentdb_api_internal.composite_metapage_blob('mpc_db', 'c_reduced', 'ab_ac_1');
RESET documentdb.enableCompositeReducedCorrelatedTerms;

-- ---------------------------------------------------------------------------
-- The blob is persisted on the metapage and survives a VACUUM (it is not a
-- transient pending-list counter). Re-read the combined index after VACUUM and
-- confirm the same bits remain set.
-- ---------------------------------------------------------------------------
SELECT collection_id AS comb_col FROM documentdb_api_catalog.collections WHERE database_name = 'mpc_db' AND collection_name = 'c_combined' \gset
SELECT FORMAT('VACUUM (FREEZE ON, INDEX_CLEANUP ON, DISABLE_PAGE_SKIPPING ON, PARALLEL 0) documentdb_data.documents_%s;', :comb_col) \gexec
-- Expected (unchanged after VACUUM): bit0 | bit1 | bit35 | bit37 -> 0x2800000003
SELECT documentdb_api_internal.composite_metapage_blob('mpc_db', 'c_combined', 'a_b_1');

DROP FUNCTION documentdb_api_internal.composite_metapage_blob(text, text, text);
