SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 13000;
SET documentdb.next_collection_index_id TO 13000;

set documentdb.enableCompositeReducedCorrelatedTerms to on;

-- Enable per-path multi-key term tracking: each multi-key path is tracked with
-- its own metadata term instead of a single root multi-key term.
set documentdb.enableIndexMetadataGlobalTracking to on;

set documentdb.enableExtendedExplainPlans to on;
-- Suppress per-index cost details so explain output is stable across runs.
set documentdb.enableExplainScanIndexCosts to off;
-- Force index usage so the multi-key metadata surfaces in explain deterministically.
set enable_seqscan to off;
-- Disable temporary-file logging: the parallel index builds below run with
-- client_min_messages at DEBUG1, and a parallel merge may spill to a temp file
-- whose logged path and size are non-deterministic. Suppressing the log keeps the
-- output stable.
set log_temp_files to -1;

-- Create an ordered composite index with per-path multi-key tracking enabled.
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_db', '{ "createIndexes": "mkp_coll", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "a_b_c_1", "enableOrderedIndex": 1 } ] }');

-- The underlying index reflects the per-path multi-key option (mkp=true).
SELECT pg_get_indexdef(indexrelid) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = 'documents_rum_index_13002';

-- Insert a document whose only array is on the second path (a.c). Per-path tracking
-- records a.c as multi-key: explain reports "multiKeyPaths: a.c" and the a.c path is
-- unbounded (0, Infinity) while a.b can still be bounded.
SELECT documentdb_api.insert_one('mkp_db', 'mkp_coll', '{ "_id": 1, "a": { "b": 1, "c": [ 1, 2 ] } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_coll", "filter": { "a.b": 1, "a.c": { "$gt": 0 } }}') $cmd$);

-- Insert a second document whose only array is on the first path (a.b). Per-path tracking
-- is cumulative: the index now records both a.b and a.c, so explain reports
-- "multiKeyPaths: a.b, a.c".
SELECT documentdb_api.insert_one('mkp_db', 'mkp_coll', '{ "_id": 2, "a": { "b": [ 3, 4 ], "c": 9 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_coll", "filter": { "a.b": { "$gt": 0 }, "a.c": 9 }}') $cmd$);

-- A single document with an array on the shared parent path "a" makes both leaf paths
-- multi-key at once: explain reports "multiKeyPaths: a.b, a.c" and the trailing path
-- is unbounded (MinKey, MaxKey).
TRUNCATE documentdb_data.documents_13001;
SELECT documentdb_api.insert_one('mkp_db', 'mkp_coll', '{ "_id": 3, "a": [ { "b": 1, "c": 1 }, { "b": 2, "c": 2 } ] }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_coll", "filter": { "a.b": { "$gt": 0 }, "a.c": 2 }}') $cmd$);

-- Scalar-only data (no arrays) is not multi-key: isMultiKey is false and no
-- "multiKeyPaths" line is emitted. Both paths can be bounded ([7, 7], [8, 8]).
TRUNCATE documentdb_data.documents_13001;
SELECT documentdb_api.insert_one('mkp_db', 'mkp_coll', '{ "_id": 4, "a": { "b": 7, "c": 8 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_coll", "filter": { "a.b": 7, "a.c": 8 }}') $cmd$);

-- Per-path tracking is populated by both the insert path and the build path. A REINDEX
-- rebuilds the index via the build path, which now also records the per-path multi-key
-- breakdown, so "multiKeyPaths" is preserved across the rebuild while array data is present.
TRUNCATE documentdb_data.documents_13001;
SELECT documentdb_api.insert_one('mkp_db', 'mkp_coll', '{ "_id": 5, "a": { "b": 1, "c": [ 1, 2 ] } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_coll", "filter": { "a.b": 1, "a.c": { "$gt": 0 } }}') $cmd$);
REINDEX INDEX documentdb_data.documents_rum_index_13002;
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_coll", "filter": { "a.b": 1, "a.c": { "$gt": 0 } }}') $cmd$);

-- The build path unions the per-path multi-key bits across every row it processes: with
-- one row whose array is on a.c and another whose array is on a.b, a REINDEX reports both
-- paths ("multiKeyPaths: a.b, a.c"), not just the path of the last row built.
TRUNCATE documentdb_data.documents_13001;
SELECT documentdb_api.insert_one('mkp_db', 'mkp_coll', '{ "_id": 6, "a": { "b": 1, "c": [ 1, 2 ] } }');
SELECT documentdb_api.insert_one('mkp_db', 'mkp_coll', '{ "_id": 7, "a": { "b": [ 3, 4 ], "c": 9 } }');
REINDEX INDEX documentdb_data.documents_rum_index_13002;
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_coll", "filter": { "a.b": { "$gt": 0 }, "a.c": 9 }}') $cmd$);

-- Replace array data with scalars only and reindex: the index is fully reset to
-- non-multi-key. isMultiKey becomes false and both paths can be bounded ([1, 1], [2, 2]).
TRUNCATE documentdb_data.documents_13001;
SELECT documentdb_api.insert_one('mkp_db', 'mkp_coll', '{ "_id": 8, "a": { "b": 1, "c": 2 } }');
REINDEX INDEX documentdb_data.documents_rum_index_13002;
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_coll", "filter": { "a.b": 1, "a.c": 2 }}') $cmd$);

-- Build path via CREATE INDEX (not REINDEX): insert array data on different paths into a
-- collection first, then build the composite index over the existing data (the third
-- argument skips the empty-collection check). The build path unions the per-path bits, so
-- explain reports "multiKeyPaths: a.b, a.c".
SELECT documentdb_api.insert_one('mkp_db', 'mkp_build_coll', '{ "_id": 1, "a": { "b": 1, "c": [ 1, 2 ] } }');
SELECT documentdb_api.insert_one('mkp_db', 'mkp_build_coll', '{ "_id": 2, "a": { "b": [ 3, 4 ], "c": 9 } }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_db', '{ "createIndexes": "mkp_build_coll", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "a_b_c_1", "enableOrderedIndex": 1 } ] }', TRUE);
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_build_coll", "filter": { "a.b": { "$gt": 0 }, "a.c": 9 }}') $cmd$);

-- Parallel build path with leader participation disabled: per-path multi-key tracking
-- under a worker-only heap scan. Insert rows whose arrays alternate between the first path
-- (a.b) and the second path (a.c) so more than one multi-key path is present, then build the
-- composite index over the existing data with parallel workers (leader does not participate).
--
-- With metadata-based tracking the per-path multi-key bits are folded into the opclass
-- metadata blob as each tuple is processed and unioned through the parallel merge, so the
-- full breakdown survives even when the leader does not scan: explain reports
-- "multiKeyPaths: a.b, a.c".
SET maintenance_work_mem TO '256MB';
SET documentdb_rum.enable_parallel_index_build TO on;
SET documentdb_rum.parallel_index_workers_override TO 2;
-- Test-only GUC: force all heap scanning onto parallel workers (leader does not participate).
SET documentdb_rum.parallel_index_build_leader_participates TO off;

SELECT COUNT(documentdb_api.insert_one('mkp_db', 'mkp_parallel_coll',
    CASE WHEN i % 2 = 0
         THEN FORMAT('{ "_id": %s, "a": { "b": %s, "c": [ %s, %s ] } }', i, i, i, -i)::bson
         ELSE FORMAT('{ "_id": %s, "a": { "b": [ %s, %s ], "c": %s } }', i, i, -i, i)::bson
    END))
FROM generate_series(1, 2000) AS i;

set client_min_messages to DEBUG1;
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_db', '{ "createIndexes": "mkp_parallel_coll", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "a_b_c_1", "enableOrderedIndex": 1 } ] }', TRUE);
RESET client_min_messages;

SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_parallel_coll", "filter": { "a.b": { "$gt": 0 }, "a.c": 2 }}') $cmd$);

RESET maintenance_work_mem;
RESET documentdb_rum.enable_parallel_index_build;
RESET documentdb_rum.parallel_index_workers_override;
RESET documentdb_rum.parallel_index_build_leader_participates;

-- ---------------------------------------------------------------------------
-- Metadata-tracked indexes fold multi-key, reduced-correlated, and truncation
-- state into a single opclass-metadata blob. The following scenarios validate
-- that all three properties surface together in explain for both the insert
-- path and the build path (regular and parallel-without-leader).
--
-- A single document drives all three at once:
--   * the array on the shared parent "a" makes both leaf paths multi-key
--     ("multiKeyPaths: a.b, a.c"),
--   * the array of correlated sub-objects produces reduced correlated terms
--     ("hasCorrelatedTerms: true"), and
--   * the long string on a.b exceeds the per-path term size limit so the term
--     is truncated ("hasTruncation: true").
-- A small indexTermLimitOverride forces truncation deterministically: the
-- per-path limit is (limit / numPaths) - 4, so 50 / 2 - 4 = 21 bytes per path.
-- ---------------------------------------------------------------------------
SET documentdb.indexTermLimitOverride TO 50;

-- Insert path: create the metadata-tracked index first, then insert the
-- document. Extraction at insert time ORs the multi-key, correlated, and
-- truncation bits into the opclass-metadata blob, so all three surface.
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_db', '{ "createIndexes": "mkp_props_insert_coll", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "a_b_c_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mkp_db', 'mkp_props_insert_coll', '{ "_id": 1, "a": [ { "b": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "c": 1 }, { "b": "bb", "c": 2 } ] }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_props_insert_coll", "filter": { "a.b": { "$exists": true }, "a.c": { "$gt": 0 } }}') $cmd$);

-- Regular build path: insert the document into a fresh collection first, then
-- build the metadata-tracked index over the existing data (the third argument
-- skips the empty-collection check). Extraction during the single-threaded
-- build populates the same blob, so all three properties surface.
SELECT documentdb_api.insert_one('mkp_db', 'mkp_props_build_coll', '{ "_id": 1, "a": [ { "b": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "c": 1 }, { "b": "bb", "c": 2 } ] }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_db', '{ "createIndexes": "mkp_props_build_coll", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "a_b_c_1", "enableOrderedIndex": 1 } ] }', TRUE);
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_props_build_coll", "filter": { "a.b": { "$exists": true }, "a.c": { "$gt": 0 } }}') $cmd$);

-- Parallel build path with leader participation disabled: insert several
-- documents that are multi-key, correlated, and truncated, then build the
-- metadata-tracked index over the existing data with parallel workers and the
-- leader excluded from the heap scan. Each worker ORs its bits into the blob
-- and the blob is unioned through the parallel merge, so all three properties
-- survive even though the leader does not scan.
SET maintenance_work_mem TO '256MB';
SET documentdb_rum.enable_parallel_index_build TO on;
SET documentdb_rum.parallel_index_workers_override TO 2;
SET documentdb_rum.parallel_index_build_leader_participates TO off;

SELECT COUNT(documentdb_api.insert_one('mkp_db', 'mkp_props_parallel_coll',
    FORMAT('{ "_id": %s, "a": [ { "b": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa%s", "c": %s }, { "b": "bb", "c": %s } ] }', i, i, i, -i)::bson))
FROM generate_series(1, 2000) AS i;

set client_min_messages to DEBUG1;
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_db', '{ "createIndexes": "mkp_props_parallel_coll", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "a_b_c_1", "enableOrderedIndex": 1 } ] }', TRUE);
RESET client_min_messages;

SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_props_parallel_coll", "filter": { "a.b": { "$exists": true }, "a.c": { "$gt": 0 } }}') $cmd$);

RESET maintenance_work_mem;
RESET documentdb_rum.enable_parallel_index_build;
RESET documentdb_rum.parallel_index_workers_override;
RESET documentdb_rum.parallel_index_build_leader_participates;

-- Negative case + insert-time transition. An index over scalar, short-string
-- data is neither multi-key, correlated, nor truncated: explain emits only
-- "isMultiKey: false" and omits the "multiKeyPaths", "hasCorrelatedTerms", and
-- "hasTruncation" lines entirely (those lines are written only when the
-- corresponding bit is set in the opclass-metadata blob).
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_db', '{ "createIndexes": "mkp_props_transition_coll", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "a_b_c_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mkp_db', 'mkp_props_transition_coll', '{ "_id": 1, "a": { "b": 1, "c": 2 } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_props_transition_coll", "filter": { "a.b": { "$exists": true }, "a.c": { "$gt": 0 } }}') $cmd$);

-- Inserting a single document that is multi-key, correlated, and truncated flips
-- all three on in place: the insert path ORs the bits into the same blob, so the
-- "multiKeyPaths", "hasCorrelatedTerms", and "hasTruncation" lines now appear.
SELECT documentdb_api.insert_one('mkp_db', 'mkp_props_transition_coll', '{ "_id": 2, "a": [ { "b": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "c": 1 }, { "b": "bb", "c": 2 } ] }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_props_transition_coll", "filter": { "a.b": { "$exists": true }, "a.c": { "$gt": 0 } }}') $cmd$);

-- Per-path truncation tracking. Truncation is recorded per-path the same way the
-- multi-key bitmask is (one bit per path, only the first 6 paths tracked). A
-- scalar document with a long string only on the second path (a.c) truncates only
-- that path: explain reports "truncatedPaths: a.c" (and isMultiKey is false, since
-- there are no arrays).
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_db', '{ "createIndexes": "mkp_props_truncpaths_coll", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "a_b_c_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mkp_db', 'mkp_props_truncpaths_coll', '{ "_id": 1, "a": { "b": 1, "c": "cccccccccccccccccccccccccccccccccc" } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_props_truncpaths_coll", "filter": { "a.b": { "$exists": true }, "a.c": { "$exists": true } }}') $cmd$);

-- A document with long strings on both paths truncates both: the per-path bitmask
-- is cumulative across inserts just like the multi-key bitmask, so explain now
-- reports "truncatedPaths: a.b, a.c".
SELECT documentdb_api.insert_one('mkp_db', 'mkp_props_truncpaths_coll', '{ "_id": 2, "a": { "b": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "c": "cccccccccccccccccccccccccccccccccc" } }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_props_truncpaths_coll", "filter": { "a.b": { "$exists": true }, "a.c": { "$exists": true } }}') $cmd$);

-- Build path: the per-path truncation bitmask is also written when the index is
-- built over existing data. Insert documents that truncate both paths into a fresh
-- collection, then build the composite index over the existing data, and explain
-- reports "truncatedPaths: a.b, a.c".
SELECT documentdb_api.insert_one('mkp_db', 'mkp_props_truncbuild_coll', '{ "_id": 1, "a": { "b": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "c": "cccccccccccccccccccccccccccccccccc" } }');
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_db', '{ "createIndexes": "mkp_props_truncbuild_coll", "indexes": [ { "key": { "a.b": 1, "a.c": 1 }, "name": "a_b_c_1", "enableOrderedIndex": 1 } ] }', TRUE);
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_props_truncbuild_coll", "filter": { "a.b": { "$exists": true }, "a.c": { "$exists": true } }}') $cmd$);

RESET documentdb.indexTermLimitOverride;

-- ---------------------------------------------------------------------------
-- Wide composite indexes (5, 10, and 20 paths). Every path holds an array of a
-- long string, so every path is simultaneously multi-key (the value is an array)
-- and truncated (the per-path term exceeds the size limit). Per-path multi-key is
-- tracked for up to 32 paths, so "multiKeyPaths" lists every path; per-path
-- truncation is tracked only for the first 6 paths, so "truncatedPaths" is capped
-- at 6 even when more paths truncate (the remainder is lossy and is reflected only
-- by the global "hasTruncation" flag). The per-path term limit is
-- (limit / numPaths) - 4, so an override of 500 yields 96/46/21 bytes per path for
-- 5/10/20 paths and the 120-byte values truncate on every path.
-- ---------------------------------------------------------------------------
SET documentdb.indexTermLimitOverride TO 500;

-- 5-path composite index: "multiKeyPaths" lists all 5 paths; truncatedPaths lists all 5 paths (since 5 <= 6).
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_db', '{ "createIndexes": "mkp_wide5_coll", "indexes": [ { "key": { "p0": 1, "p1": 1, "p2": 1, "p3": 1, "p4": 1 }, "name": "wide_5", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mkp_db', 'mkp_wide5_coll', '{ "_id": 1, "p0": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p1": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p2": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p3": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p4": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ] }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_wide5_coll", "filter": { "p0": { "$exists": true }, "p1": { "$exists": true } }}') $cmd$);

-- 10-path composite index: "multiKeyPaths" lists all 10 paths; truncatedPaths is capped at the first 6 paths (of 10).
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_db', '{ "createIndexes": "mkp_wide10_coll", "indexes": [ { "key": { "p0": 1, "p1": 1, "p2": 1, "p3": 1, "p4": 1, "p5": 1, "p6": 1, "p7": 1, "p8": 1, "p9": 1 }, "name": "wide_10", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mkp_db', 'mkp_wide10_coll', '{ "_id": 1, "p0": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p1": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p2": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p3": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p4": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p5": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p6": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p7": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p8": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p9": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ] }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_wide10_coll", "filter": { "p0": { "$exists": true }, "p1": { "$exists": true } }}') $cmd$);

-- 20-path composite index: "multiKeyPaths" lists all 20 paths; truncatedPaths is capped at the first 6 paths (of 20).
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_db', '{ "createIndexes": "mkp_wide20_coll", "indexes": [ { "key": { "p0": 1, "p1": 1, "p2": 1, "p3": 1, "p4": 1, "p5": 1, "p6": 1, "p7": 1, "p8": 1, "p9": 1, "p10": 1, "p11": 1, "p12": 1, "p13": 1, "p14": 1, "p15": 1, "p16": 1, "p17": 1, "p18": 1, "p19": 1 }, "name": "wide_20", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mkp_db', 'mkp_wide20_coll', '{ "_id": 1, "p0": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p1": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p2": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p3": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p4": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p5": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p6": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p7": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p8": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p9": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p10": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p11": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p12": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p13": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p14": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p15": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p16": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p17": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p18": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ], "p19": [ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ] }');
SELECT documentdb_test_helpers.run_explain_and_trim( $cmd$
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('mkp_db', '{ "find": "mkp_wide20_coll", "filter": { "p0": { "$exists": true }, "p1": { "$exists": true } }}') $cmd$);

RESET documentdb.indexTermLimitOverride;

-- ---------------------------------------------------------------------------
-- Metadata-based tracking does not add any extra index term entries: the
-- multi-key and truncation state lives in the metapage opclass-metadata blob
-- (surfaced as "pendingHeapTuples"), not as additional sentinel term entries in
-- the index. The legacy (non-metadata) path instead appends a root multi-key term
-- and a root truncated term as real entries. The two collections below index the
-- same multi-key + truncated document; after a VACUUM (which must preserve the
-- metapage blob) the metapage proves the difference:
--   * metadata-tracked index: "entries" counts only the single data term (no
--     sentinel terms) and "pendingHeapTuples" carries the full per-path bitmask
--     (isMultiKey + per-path multi-key for a,b + truncated + per-path truncated
--     for a,b), and
--   * legacy index: "entries" is larger by the two appended sentinel terms (root
--     multi-key + root truncated) and "pendingHeapTuples" holds only the global
--     multi-key flag, without the per-path breakdown.
-- ---------------------------------------------------------------------------
SET documentdb.indexTermLimitOverride TO 50;

-- Metadata-tracked index (per-path tracking enabled): state is folded into the
-- metapage blob, so no extra term entries are generated.
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_db', '{ "createIndexes": "mkp_metapage_meta_coll", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mkp_db', 'mkp_metapage_meta_coll', '{ "_id": 1, "a": [ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ], "b": [ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ] }');
SELECT collection_id AS meta_col FROM documentdb_api_catalog.collections WHERE database_name = 'mkp_db' AND collection_name = 'mkp_metapage_meta_coll' \gset
SELECT index_id AS meta_idx FROM documentdb_api_catalog.collection_indexes WHERE collection_id = :meta_col AND (index_spec).index_name = 'a_b_1' \gset
SELECT FORMAT('VACUUM (FREEZE ON, INDEX_CLEANUP ON, DISABLE_PAGE_SKIPPING ON, PARALLEL 0) documentdb_data.documents_%s;', :meta_col) \gexec
SELECT documentdb_api_internal.documentdb_rum_get_meta_page_info(public.get_raw_page(('documentdb_data.documents_rum_index_' || :meta_idx), 0));

-- Legacy index (per-path tracking disabled): the same document produces two extra
-- sentinel term entries (root multi-key + root truncated) and stores only the
-- global multi-key flag in the metapage (no per-path breakdown).
set documentdb.enableIndexMetadataGlobalTracking to off;
SELECT documentdb_api_internal.create_indexes_non_concurrently('mkp_db', '{ "createIndexes": "mkp_metapage_legacy_coll", "indexes": [ { "key": { "a": 1, "b": 1 }, "name": "a_b_1", "enableOrderedIndex": 1 } ] }');
SELECT documentdb_api.insert_one('mkp_db', 'mkp_metapage_legacy_coll', '{ "_id": 1, "a": [ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ], "b": [ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ] }');
set documentdb.enableIndexMetadataGlobalTracking to on;
SELECT collection_id AS legacy_col FROM documentdb_api_catalog.collections WHERE database_name = 'mkp_db' AND collection_name = 'mkp_metapage_legacy_coll' \gset
SELECT index_id AS legacy_idx FROM documentdb_api_catalog.collection_indexes WHERE collection_id = :legacy_col AND (index_spec).index_name = 'a_b_1' \gset
SELECT FORMAT('VACUUM (FREEZE ON, INDEX_CLEANUP ON, DISABLE_PAGE_SKIPPING ON, PARALLEL 0) documentdb_data.documents_%s;', :legacy_col) \gexec
SELECT documentdb_api_internal.documentdb_rum_get_meta_page_info(public.get_raw_page(('documentdb_data.documents_rum_index_' || :legacy_idx), 0));

RESET documentdb.indexTermLimitOverride;
