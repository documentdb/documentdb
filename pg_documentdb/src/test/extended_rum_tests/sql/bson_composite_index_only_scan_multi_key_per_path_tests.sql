SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 43600;
SET documentdb.next_collection_index_id TO 43600;

-- Enable the composite index planner (equality prefixes, ranges, order-by pushdown).
set documentdb.enableCompositeIndexPlanner to on;

-- Enable opclass metadata tracking so the composite index records per-path multi-key
-- state (the mkp=true opclass option). Index-only-scan eligibility for the operators
-- exercised below is decided per referenced column from this metadata.
set documentdb.enableIndexMetadataGlobalTracking to on;

-- The per-path multi-key gate is what unlocks the relaxed operators ($ne,
-- $eq null, $eq [], $exists) and index-wide multi-key relaxation. Pin it on so the
-- plan shapes are deterministic regardless of the default.
set documentdb.enablePerPathMultiKeySortPushdown to on;

set documentdb.enableExtendedExplainPlans to on;
-- Suppress per-index cost details so explain output is stable across runs.
set documentdb.enableExplainScanIndexCosts to off;
-- Force index usage and the ordered index-scan path so the scan shape surfaces.
set enable_seqscan to off;
set enable_bitmapscan to off;

-- ============================================================================
-- Composite index (region, tags) where the leading path "region" is only ever a
-- scalar / null / missing (NOT multi-key) and the trailing path "tags" is an array
-- on some documents (multi-key). The per-path metadata records region as non-multi-
-- key and tags as multi-key.
--
-- Contract under test: index-only-scan eligibility is decided per referenced column.
--   * Filters/targets that reference ONLY the non-multi-key "region" -- including the
--     previously-blocked negation and null/empty-array/exists operators -- become
--     index-only eligible.
--   * Filters/targets that reference the multi-key "tags" fall back to a regular
--     Index Scan with a heap recheck.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosmk_db', '{ "createIndexes": "coll", "indexes": [ { "key": { "region": 1, "tags": 1 }, "name": "region_tags_1", "enableOrderedIndex": 1 } ] }', true);

SELECT documentdb_api.insert_one('iosmk_db', 'coll', '{ "_id": 1, "region": "west", "tags": [ "x", "y" ] }');
SELECT documentdb_api.insert_one('iosmk_db', 'coll', '{ "_id": 2, "region": "east", "tags": [ "x" ] }');
SELECT documentdb_api.insert_one('iosmk_db', 'coll', '{ "_id": 3, "region": "west", "tags": [ "z" ] }');
SELECT documentdb_api.insert_one('iosmk_db', 'coll', '{ "_id": 4, "region": "south" }');
SELECT documentdb_api.insert_one('iosmk_db', 'coll', '{ "_id": 5, "region": null, "tags": [ "x" ] }');
SELECT documentdb_api.insert_one('iosmk_db', 'coll', '{ "_id": 6, "region": "east", "tags": [] }');
SELECT documentdb_api.insert_one('iosmk_db', 'coll', '{ "_id": 7, "tags": [ "q" ] }');

SELECT collection_id AS coll_cid FROM documentdb_api_catalog.collections WHERE database_name = 'iosmk_db' AND collection_name = 'coll' \gset

-- Confirm the index carries the per-path metadata opclass option (mkp=true).
SELECT (pg_get_indexdef(idx.indexrelid) LIKE '%mkp=''true''%') AS has_per_path_tracking
    FROM pg_index idx
    JOIN pg_class cls ON cls.oid = idx.indexrelid
    WHERE idx.indrelid = ('documentdb_data.documents_' || :'coll_cid')::regclass
      AND cls.relname LIKE 'documents_rum_index%'
    ORDER BY cls.relname;

-- Freeze the heap so index-only scans report no heap fetches; disable autovacuum so
-- the visibility map stays stable for the test.
SELECT format('ALTER TABLE documentdb_data.documents_%s set (autovacuum_enabled = off)', :'coll_cid') \gexec
SELECT format('VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_%s', :'coll_cid') \gexec

-- ----------------------------------------------------------------------------
-- Non-multi-key path "region": the relaxed operators are index-only eligible.
-- ----------------------------------------------------------------------------

-- $ne on region -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$ne": "west" } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- $nin (multi-value) is never index-only: it emits one bound per element that are
-- OR-combined at scan time, so every bound forces a runtime recheck to enforce the
-- AND-of-not-equals semantics -> Index Scan with recheck (result still correct).
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$nin": [ "west", "east" ] } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- $nin is never index-only (it always forces a runtime recheck), regardless of
-- whether it carries a regex -> Index Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$nin": [ "west", { "$regularExpression": { "pattern": "^s", "options": "" } } ] } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- $eq null on region -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$eq": null } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- $eq [] on region (never an array) -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$eq": [] } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- $exists true on region -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$exists": true } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- $exists false on region -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$exists": false } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- $in with a null entry on region -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$in": [ "west", null ] } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- $in carrying a regex on region -> Index Only Scan. Unlike $nin, a $in regex is
-- NOT lossy: the composite index stores the full term value, so the regex is
-- matched exactly against the index term (no heap fetch, no runtime recheck).
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$in": [ "west", { "$regularExpression": { "pattern": "^s", "options": "" } } ] } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- ----------------------------------------------------------------------------
-- Multi-key path "tags": the same operators fall back to a regular Index Scan.
-- Each bounds the leading non-multi-key "region" so the composite index is used
-- and the fallback is caused by the multi-key gate on "tags" (not by the index
-- being unusable).
-- ----------------------------------------------------------------------------

-- Leading "region" bound + $ne on the multi-key "tags" -> Index Scan (heap recheck), NOT index-only.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$eq": "west" }, "tags": { "$ne": "x" } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- Leading "region" bound + $eq null on the multi-key "tags" -> Index Scan, NOT index-only.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$eq": "east" }, "tags": { "$eq": null } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- Leading "region" bound + $exists true on the multi-key "tags" -> Index Scan, NOT index-only.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$eq": "west" }, "tags": { "$exists": true } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- Leading "region" bound + a range on the multi-key "tags" -> Index Scan, NOT index-only.
-- (range/$eq operators are "supported" strategies; the multi-key column gate is what blocks them.)
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$eq": "west" }, "tags": { "$gt": "a" } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- Leading "region" bound + $eq on the multi-key "tags" -> Index Scan, NOT index-only.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$eq": "west" }, "tags": { "$eq": "x" } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- Leading "region" bound + $in with a null entry on the multi-key "tags" -> Index Scan, NOT index-only.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$eq": "west" }, "tags": { "$in": [ "x", null ] } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- A filter on the non-multi-key "region" but a $group whose accumulator reads the
-- multi-key "tags": referencing the multi-key column in a target blocks index-only
-- scan (the group key "$region" is non-multi-key).
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$eq": "west" } } }, { "$group" : { "_id" : "$region", "s" : { "$sum" : "$tags" } } }]}') $$, p_ignore_heap_fetches => true);

-- Range and $in-with-empty-array on the non-multi-key "region" are index-only eligible.
-- $gte range on "region" -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$gte": "north" } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- $in with an empty-array entry on the non-multi-key "region" -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$in": [ "west", [] ] } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- ============================================================================
-- Fully scalar composite index (grade, score): NONE of the columns are ever an
-- array, so the extended explain reports "isMultiKey: false" (no multiKeyPaths
-- line). Every supported operator is index-only eligible on such an index.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosmk_db', '{ "createIndexes": "scalar_coll", "indexes": [ { "key": { "grade": 1, "score": 1 }, "name": "grade_score_1", "enableOrderedIndex": 1 } ] }', true);

SELECT documentdb_api.insert_one('iosmk_db', 'scalar_coll', '{ "_id": 1, "grade": "A", "score": 90 }');
SELECT documentdb_api.insert_one('iosmk_db', 'scalar_coll', '{ "_id": 2, "grade": "B", "score": 80 }');
SELECT documentdb_api.insert_one('iosmk_db', 'scalar_coll', '{ "_id": 3, "grade": "A", "score": 70 }');
SELECT documentdb_api.insert_one('iosmk_db', 'scalar_coll', '{ "_id": 4, "grade": null, "score": 60 }');
SELECT documentdb_api.insert_one('iosmk_db', 'scalar_coll', '{ "_id": 5, "score": 50 }');

SELECT collection_id AS scalar_cid FROM documentdb_api_catalog.collections WHERE database_name = 'iosmk_db' AND collection_name = 'scalar_coll' \gset
SELECT format('ALTER TABLE documentdb_data.documents_%s set (autovacuum_enabled = off)', :'scalar_cid') \gexec
SELECT format('VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_%s', :'scalar_cid') \gexec

-- $ne on the leading scalar column -> Index Only Scan (extended explain: isMultiKey: false).
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "scalar_coll", "pipeline" : [{ "$match" : { "grade": { "$ne": "A" } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- Single-element $nin is rewritten to $ne, so on the leading scalar column it
-- becomes Index Only Scan (unlike multi-value $nin, which always rechecks).
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "scalar_coll", "pipeline" : [{ "$match" : { "grade": { "$nin": [ "A" ] } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- $eq null on the leading scalar column -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "scalar_coll", "pipeline" : [{ "$match" : { "grade": { "$eq": null } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- $eq [] on the leading scalar column (never an array) -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "scalar_coll", "pipeline" : [{ "$match" : { "grade": { "$eq": [] } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- $exists true on the trailing scalar column, with the leading column bound so the
-- composite index is used -> Index Only Scan (covers a non-leading scalar column).
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "scalar_coll", "pipeline" : [{ "$match" : { "grade": { "$eq": "A" }, "score": { "$exists": true } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- $group over a scalar column with a scalar filter -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "scalar_coll", "pipeline" : [{ "$match" : { "grade": { "$ne": "A" } } }, { "$group" : { "_id" : "$grade", "total" : { "$sum" : "$score" } } }]}') $$, p_ignore_heap_fetches => true);

-- ============================================================================
-- Composite index (city, zone, visits) where "visits" is an array on some docs
-- (multi-key) but "city" and "zone" are always scalar. A query that references
-- only the non-multi-key columns is index-only eligible even though the index is
-- multi-key on an UNreferenced column. Extended explain shows isMultiKey: true /
-- multiKeyPaths: visits together with an Index Only Scan.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosmk_db', '{ "createIndexes": "coverage_coll", "indexes": [ { "key": { "city": 1, "zone": 1, "visits": 1 }, "name": "city_zone_visits_1", "enableOrderedIndex": 1 } ] }', true);

SELECT documentdb_api.insert_one('iosmk_db', 'coverage_coll', '{ "_id": 1, "city": "Reno", "zone": "north", "visits": [ 3, 5 ] }');
SELECT documentdb_api.insert_one('iosmk_db', 'coverage_coll', '{ "_id": 2, "city": "Reno", "zone": "south", "visits": [ 1 ] }');
SELECT documentdb_api.insert_one('iosmk_db', 'coverage_coll', '{ "_id": 3, "city": "Tahoe", "zone": "north", "visits": [ 4 ] }');
SELECT documentdb_api.insert_one('iosmk_db', 'coverage_coll', '{ "_id": 4, "city": "Tahoe", "zone": null }');
SELECT documentdb_api.insert_one('iosmk_db', 'coverage_coll', '{ "_id": 5, "zone": "south", "visits": [ 2 ] }');

SELECT collection_id AS coverage_cid FROM documentdb_api_catalog.collections WHERE database_name = 'iosmk_db' AND collection_name = 'coverage_coll' \gset
SELECT format('ALTER TABLE documentdb_data.documents_%s set (autovacuum_enabled = off)', :'coverage_cid') \gexec
SELECT format('VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_%s', :'coverage_cid') \gexec

-- $ne on the non-multi-key "city" (multi-key "visits" not referenced) -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coverage_coll", "pipeline" : [{ "$match" : { "city": { "$ne": "Reno" } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- Leading "city" bound plus $eq null on the non-multi-key "zone" (multi-key "visits"
-- not referenced) -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coverage_coll", "pipeline" : [{ "$match" : { "city": { "$eq": "Tahoe" }, "zone": { "$eq": null } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- $group over the non-multi-key "zone" filtering the non-multi-key "city" -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coverage_coll", "pipeline" : [{ "$match" : { "city": { "$ne": "Tahoe" } } }, { "$group" : { "_id" : "$zone", "n" : { "$sum" : 1 } } }]}') $$, p_ignore_heap_fetches => true);

-- Contrast: leading "city" bound but the multi-key "visits" referenced in the filter
-- (so the composite index is used) -> NOT index-only.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coverage_coll", "pipeline" : [{ "$match" : { "city": { "$eq": "Reno" }, "visits": { "$ne": 1 } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- Contrast: grouping over the multi-key "visits" -> NOT index-only.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coverage_coll", "pipeline" : [{ "$match" : { "city": { "$eq": "Reno" } } }, { "$group" : { "_id" : "$visits", "n" : { "$sum" : 1 } } }]}') $$, p_ignore_heap_fetches => true);

-- ============================================================================
-- TARGET coverage path. The projection / group-key / accumulator coverage check
-- (AreAllTargetsCoveredByIndex -> CheckFieldCoverage -> IsFieldPathCoveredByIndex /
-- IsProjectionCoveredByIndex) is a separate code path from the filter check. A
-- target that references a MULTI-KEY column blocks index-only scan even when the
-- filter only touches non-multi-key columns. Uses coverage_coll (city, zone are
-- scalar/non-multi-key; visits is multi-key).
-- ============================================================================

-- --- Group key + accumulator targets (all filters on the non-multi-key "city") ---

-- $group over non-multi-key "zone" with $min over non-multi-key "zone" -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coverage_coll", "pipeline" : [{ "$match" : { "city": { "$ne": "Tahoe" } } }, { "$group" : { "_id" : "$zone", "lo" : { "$min" : "$zone" } } }]}') $$, p_ignore_heap_fetches => true);

-- $group over non-multi-key "zone" but $sum over the MULTI-KEY "visits" -> Index Scan.
-- (the accumulator target references a multi-key column)
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coverage_coll", "pipeline" : [{ "$match" : { "city": { "$ne": "Tahoe" } } }, { "$group" : { "_id" : "$zone", "total" : { "$sum" : "$visits" } } }]}') $$, p_ignore_heap_fetches => true);

-- $avg over the MULTI-KEY "visits" -> Index Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coverage_coll", "pipeline" : [{ "$match" : { "city": { "$ne": "Tahoe" } } }, { "$group" : { "_id" : "$zone", "av" : { "$avg" : "$visits" } } }]}') $$, p_ignore_heap_fetches => true);

-- $max over the MULTI-KEY "visits" -> Index Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coverage_coll", "pipeline" : [{ "$match" : { "city": { "$ne": "Tahoe" } } }, { "$group" : { "_id" : "$zone", "hi" : { "$max" : "$visits" } } }]}') $$, p_ignore_heap_fetches => true);

-- $group over the MULTI-KEY "visits" with a constant accumulator -> Index Scan.
-- (the group key references a multi-key column even though the accumulator does not)
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coverage_coll", "pipeline" : [{ "$match" : { "city": { "$ne": "Tahoe" } } }, { "$group" : { "_id" : "$visits", "n" : { "$sum" : 1 } } }]}') $$, p_ignore_heap_fetches => true);

-- $group over non-multi-key "zone" with a constant accumulator -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coverage_coll", "pipeline" : [{ "$match" : { "city": { "$ne": "Tahoe" } } }, { "$group" : { "_id" : "$zone", "n" : { "$sum" : 1 } } }]}') $$, p_ignore_heap_fetches => true);

-- --- Find projection targets (require enableIndexOnlyScanForFindProject) ---
set documentdb.enableIndexOnlyScanForFindProject to on;

-- Project only the non-multi-key leading "city" (+ _id excluded) -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_find('iosmk_db', '{ "find" : "coverage_coll", "filter" : { "city": { "$ne": "Reno" } }, "projection" : { "city": 1, "_id": 0 } }') $$, p_ignore_heap_fetches => true);

-- Project two non-multi-key covered fields (city, zone) -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_find('iosmk_db', '{ "find" : "coverage_coll", "filter" : { "city": { "$ne": "Reno" } }, "projection" : { "city": 1, "zone": 1, "_id": 0 } }') $$, p_ignore_heap_fetches => true);

-- Project the non-multi-key non-leading "zone" -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_find('iosmk_db', '{ "find" : "coverage_coll", "filter" : { "city": { "$ne": "Reno" } }, "projection" : { "zone": 1, "_id": 0 } }') $$, p_ignore_heap_fetches => true);

-- Project the MULTI-KEY "visits" (filter only on non-multi-key "city") -> Index Scan.
-- (the projection target covers a multi-key column, so it cannot be reconstructed)
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_find('iosmk_db', '{ "find" : "coverage_coll", "filter" : { "city": { "$ne": "Reno" } }, "projection" : { "visits": 1, "_id": 0 } }') $$, p_ignore_heap_fetches => true);

-- Project a non-multi-key field but with the default _id included (not covered) -> Index Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_find('iosmk_db', '{ "find" : "coverage_coll", "filter" : { "city": { "$ne": "Reno" } }, "projection" : { "city": 1 } }') $$, p_ignore_heap_fetches => true);

-- Correctness: the index-only projection returns the expected covered documents.
SELECT document FROM bson_aggregation_find('iosmk_db', '{ "find" : "coverage_coll", "filter" : { "city": { "$eq": "Tahoe" } }, "projection" : { "city": 1, "zone": 1, "_id": 0 } }');

reset documentdb.enableIndexOnlyScanForFindProject;

-- ============================================================================
-- Multi-key on the LEADING column. Index (items, label) where "items" is an array
-- on some docs. Any query that filters "items" references a multi-key column, so
-- index-only scan is blocked regardless of operator.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosmk_db', '{ "createIndexes": "leadmk_coll", "indexes": [ { "key": { "items": 1, "label": 1 }, "name": "items_label_1", "enableOrderedIndex": 1 } ] }', true);

SELECT documentdb_api.insert_one('iosmk_db', 'leadmk_coll', '{ "_id": 1, "items": [ 1, 2 ], "label": "a" }');
SELECT documentdb_api.insert_one('iosmk_db', 'leadmk_coll', '{ "_id": 2, "items": [ 3 ], "label": "b" }');
SELECT documentdb_api.insert_one('iosmk_db', 'leadmk_coll', '{ "_id": 3, "items": 5, "label": "a" }');

SELECT collection_id AS leadmk_cid FROM documentdb_api_catalog.collections WHERE database_name = 'iosmk_db' AND collection_name = 'leadmk_coll' \gset
SELECT format('ALTER TABLE documentdb_data.documents_%s set (autovacuum_enabled = off)', :'leadmk_cid') \gexec
SELECT format('VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_%s', :'leadmk_cid') \gexec

-- $eq on the multi-key leading "items" -> Index Scan (composite index used), NOT index-only.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "leadmk_coll", "pipeline" : [{ "$match" : { "items": { "$eq": 5 } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- $ne on the multi-key leading "items" -> Index Scan, NOT index-only.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "leadmk_coll", "pipeline" : [{ "$match" : { "items": { "$ne": 5 } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- ============================================================================
-- Runtime transition of the REFERENCED column from scalar to multi-key. A $ne on
-- the leading "val" is index-only while "val" is scalar; after an array value is
-- inserted into "val" the same query flips to a regular Index Scan.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosmk_db', '{ "createIndexes": "flip_coll", "indexes": [ { "key": { "val": 1, "note": 1 }, "name": "val_note_1", "enableOrderedIndex": 1 } ] }', true);

SELECT documentdb_api.insert_one('iosmk_db', 'flip_coll', '{ "_id": 1, "val": 10, "note": "a" }');
SELECT documentdb_api.insert_one('iosmk_db', 'flip_coll', '{ "_id": 2, "val": 20, "note": "b" }');
SELECT documentdb_api.insert_one('iosmk_db', 'flip_coll', '{ "_id": 3, "val": 30, "note": "c" }');

SELECT collection_id AS flip_cid FROM documentdb_api_catalog.collections WHERE database_name = 'iosmk_db' AND collection_name = 'flip_coll' \gset
SELECT format('ALTER TABLE documentdb_data.documents_%s set (autovacuum_enabled = off)', :'flip_cid') \gexec
SELECT format('VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_%s', :'flip_cid') \gexec

-- While "val" is scalar: $ne on "val" -> Index Only Scan (isMultiKey: false).
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "flip_coll", "pipeline" : [{ "$match" : { "val": { "$ne": 10 } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- Insert an array value into "val", making the leading column multi-key. The
-- per-path multi-key metadata is updated on the insert path (no VACUUM needed).
SELECT documentdb_api.insert_one('iosmk_db', 'flip_coll', '{ "_id": 4, "val": [ 40, 50 ], "note": "d" }');

-- Now "val" is multi-key: the same $ne on "val" -> Index Scan, NOT index-only.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "flip_coll", "pipeline" : [{ "$match" : { "val": { "$ne": 10 } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- ============================================================================
-- Index built WITHOUT per-path metadata tracking (enableIndexMetadataGlobalTracking
-- off at build time -> no mkp option). $ne / null / empty-array are NOT index-only
-- eligible on such an index (legacy behavior), while a plain $eq on a scalar column
-- still is (the whole index is non-multi-key).
-- ============================================================================
set documentdb.enableIndexMetadataGlobalTracking to off;
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosmk_db', '{ "createIndexes": "untracked_coll", "indexes": [ { "key": { "key1": 1, "key2": 1 }, "name": "key1_key2_1", "enableOrderedIndex": 1 } ] }', true);
set documentdb.enableIndexMetadataGlobalTracking to on;

SELECT documentdb_api.insert_one('iosmk_db', 'untracked_coll', '{ "_id": 1, "key1": "p", "key2": 1 }');
SELECT documentdb_api.insert_one('iosmk_db', 'untracked_coll', '{ "_id": 2, "key1": "q", "key2": 2 }');
SELECT documentdb_api.insert_one('iosmk_db', 'untracked_coll', '{ "_id": 3, "key1": "p", "key2": 3 }');

SELECT collection_id AS untracked_cid FROM documentdb_api_catalog.collections WHERE database_name = 'iosmk_db' AND collection_name = 'untracked_coll' \gset
SELECT format('ALTER TABLE documentdb_data.documents_%s set (autovacuum_enabled = off)', :'untracked_cid') \gexec
SELECT format('VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_%s', :'untracked_cid') \gexec

-- Confirm the index does NOT carry the per-path metadata opclass option.
SELECT (pg_get_indexdef(idx.indexrelid) LIKE '%mkp=''true''%') AS has_per_path_tracking
    FROM pg_index idx
    JOIN pg_class cls ON cls.oid = idx.indexrelid
    WHERE idx.indrelid = ('documentdb_data.documents_' || :'untracked_cid')::regclass
      AND cls.relname LIKE 'documents_rum_index%'
    ORDER BY cls.relname;

-- $eq on a scalar column of the untracked (non-multi-key) index -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "untracked_coll", "pipeline" : [{ "$match" : { "key1": { "$eq": "p" } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- $ne on the untracked index -> NOT index-only (negation requires per-path tracking).
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "untracked_coll", "pipeline" : [{ "$match" : { "key1": { "$ne": "p" } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- $eq null on the untracked index -> NOT index-only (null needs a runtime recheck here).
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "untracked_coll", "pipeline" : [{ "$match" : { "key1": { "$eq": null } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- ============================================================================
-- Dotted/nested index path. Index ("addr.city", level) where "addr.city" is
-- scalar -> the relaxed operators on the dotted path are index-only eligible.
-- ============================================================================
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosmk_db', '{ "createIndexes": "dotted_coll", "indexes": [ { "key": { "addr.city": 1, "level": 1 }, "name": "addrcity_level_1", "enableOrderedIndex": 1 } ] }', true);

SELECT documentdb_api.insert_one('iosmk_db', 'dotted_coll', '{ "_id": 1, "addr": { "city": "Reno" }, "level": 1 }');
SELECT documentdb_api.insert_one('iosmk_db', 'dotted_coll', '{ "_id": 2, "addr": { "city": "Tahoe" }, "level": 2 }');
SELECT documentdb_api.insert_one('iosmk_db', 'dotted_coll', '{ "_id": 3, "addr": { "city": "Reno" }, "level": 3 }');

SELECT collection_id AS dotted_cid FROM documentdb_api_catalog.collections WHERE database_name = 'iosmk_db' AND collection_name = 'dotted_coll' \gset
SELECT format('ALTER TABLE documentdb_data.documents_%s set (autovacuum_enabled = off)', :'dotted_cid') \gexec
SELECT format('VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_%s', :'dotted_cid') \gexec

-- $ne on the scalar dotted path "addr.city" -> Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "dotted_coll", "pipeline" : [{ "$match" : { "addr.city": { "$ne": "Reno" } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- Insert an array under "addr" making the dotted path "addr.city" multi-key. The
-- per-path multi-key metadata is updated on the insert path (no VACUUM needed).
SELECT documentdb_api.insert_one('iosmk_db', 'dotted_coll', '{ "_id": 4, "addr": [ { "city": "Elko" }, { "city": "Ely" } ], "level": 4 }');

-- Now "addr.city" is multi-key: the same $ne flips to a regular Index Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "dotted_coll", "pipeline" : [{ "$match" : { "addr.city": { "$ne": "Reno" } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- ----------------------------------------------------------------------------
-- Feature flag OFF: the relaxed operators are no longer index-only eligible even on
-- the non-multi-key "region" (legacy behavior).
-- ----------------------------------------------------------------------------
set documentdb.enablePerPathMultiKeySortPushdown to off;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$ne": "west" } } }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
set documentdb.enablePerPathMultiKeySortPushdown to on;

-- ----------------------------------------------------------------------------
-- Correctness: index-only results for the relaxed operators match the documents.
-- ----------------------------------------------------------------------------
SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$ne": "west" } } }, { "$sort" : { "_id": 1 } }, { "$project" : { "_id": 1 } }]}');
SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$eq": null } } }, { "$sort" : { "_id": 1 } }, { "$project" : { "_id": 1 } }]}');
SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$exists": false } } }, { "$sort" : { "_id": 1 } }, { "$project" : { "_id": 1 } }]}');
SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$in": [ "west", null ] } } }, { "$sort" : { "_id": 1 } }, { "$project" : { "_id": 1 } }]}');
-- $in [west, /^s/] matches west(1,3) OR anything starting with s (south=4) -> 1,3,4.
SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coll", "pipeline" : [{ "$match" : { "region": { "$in": [ "west", { "$regularExpression": { "pattern": "^s", "options": "" } } ] } } }, { "$sort" : { "_id": 1 } }, { "$project" : { "_id": 1 } }]}');

-- Fully scalar index: $ne and $eq null return the expected documents.
SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "scalar_coll", "pipeline" : [{ "$match" : { "grade": { "$ne": "A" } } }, { "$sort" : { "_id": 1 } }, { "$project" : { "_id": 1 } }]}');
SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "scalar_coll", "pipeline" : [{ "$match" : { "grade": { "$eq": null } } }, { "$sort" : { "_id": 1 } }, { "$project" : { "_id": 1 } }]}');

-- Multi-key-on-unreferenced-column index: filters on the non-multi-key columns
-- return the expected documents.
SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coverage_coll", "pipeline" : [{ "$match" : { "city": { "$ne": "Reno" } } }, { "$sort" : { "_id": 1 } }, { "$project" : { "_id": 1 } }]}');
SELECT document FROM bson_aggregation_pipeline('iosmk_db', '{ "aggregate" : "coverage_coll", "pipeline" : [{ "$match" : { "city": { "$eq": "Tahoe" }, "zone": { "$eq": null } } }, { "$sort" : { "_id": 1 } }, { "$project" : { "_id": 1 } }]}');
