SET citus.next_shard_id TO 696000;
SET documentdb.next_collection_id TO 6960;
SET documentdb.next_collection_index_id TO 6960;
SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_api_internal,documentdb_core;

SET documentdb.enableExtendedExplainPlans TO on;
SET documentdb.enableIndexOnlyScan TO on;
SET documentdb.enableIndexOnlyScanForFindProject TO on;
SET documentdb.enableNewMinMaxAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;

-- if documentdb_extended_rum exists, set alternate index handler
SELECT pg_catalog.set_config('documentdb.alternate_index_handler_name', 'extended_rum', false), extname FROM pg_extension WHERE extname = 'documentdb_extended_rum';

SELECT documentdb_api.drop_collection('iosfp_db', 'iosfp_coll') IS NOT NULL;
SELECT documentdb_api.create_collection('iosfp_db', 'iosfp_coll');
ALTER TABLE documentdb_data.documents_6961 SET (autovacuum_enabled = off);

-- Single field index on country
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "country": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "country_1" }] }', true);

-- Compound index on (country, provider)
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "country": 1, "provider": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "country_provider_1" }] }', true);

-- Compound index on (country, _id)
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "country": 1, "_id": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "country_id_1" }] }', true);

SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 1, "country": "USA", "provider": "AWS", "region": "east"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 2, "country": "USA", "provider": "Azure", "region": "west"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 3, "country": "Mexico", "provider": "GCP", "region": "north"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 4, "country": "India", "provider": "AWS", "region": "south"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 5, "country": "Brazil", "provider": "Azure", "region": "east"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 6, "country": "Brazil", "provider": "GCP", "region": "west"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 7, "country": "Mexico", "provider": "AWS", "region": "north"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 8, "country": "USA", "provider": "Azure", "region": "south"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 9, "country": "India", "provider": "GCP", "region": "east"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 10, "country": "Mexico", "provider": "AWS", "region": "west"}');

VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_6961;

SET enable_seqscan TO off;
SET enable_bitmapscan TO off;
SET seq_page_cost TO 1000;

-- ===========================================================================
-- SECTION A: find with projection (single-field index `country_1`)
-- ===========================================================================

-- A1: find with inclusion projection only on covered field + _id excluded
-- Expected: IOS using country_1 (no need to project _id, country is covered)
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$gte": "Brazil" } }, "projection": { "country": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$gte": "Brazil" } }, "projection": { "country": 1, "_id": 0 } }');

-- A2: find with inclusion of covered field only, but default _id projection
-- Expected: no IOS using country_1 because _id is not in the index
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$gte": "Brazil" } }, "projection": { "country": 1 } }')$$, p_ignore_heap_fetches => true);

-- A3: find with inclusion of an UN-covered field (provider) + _id excluded
-- Expected: no IOS because provider is not in country_1
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$gte": "Brazil" } }, "projection": { "provider": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);

-- A4: find with inclusion of one covered + one UN-covered field
-- Expected: no IOS because provider is not covered by country_1
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$gte": "Brazil" } }, "projection": { "country": 1, "provider": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);

-- A5: find with pure exclusion projection
-- Expected: no IOS because we don't know what other fields exist (have to read full doc)
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$gte": "Brazil" } }, "projection": { "provider": 0 } }')$$, p_ignore_heap_fetches => true);

-- A6: find with pure exclusion that excludes _id only
-- Expected: no IOS (still pure exclusion)
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$gte": "Brazil" } }, "projection": { "_id": 0 } }')$$, p_ignore_heap_fetches => true);

-- A7: find with projection containing an expression (non-int value)
-- Expected: no IOS because expression projections cannot be reasoned about for coverage
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$gte": "Brazil" } }, "projection": { "country": 1, "_id": 0, "computed": { "$add": [ 1, 1 ] } } }')$$, p_ignore_heap_fetches => true);

-- A8: find with NO projection (basic find that previously required aggregates)
-- Expected: no IOS because the document var is not covered
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$gte": "Brazil" } } }')$$, p_ignore_heap_fetches => true);

-- ===========================================================================
-- SECTION B: find with projection - compound index `country_provider_1`
-- ===========================================================================

-- B1: project both index fields, _id excluded
-- Expected: IOS using country_provider_1
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$gte": "Brazil" }, "provider": { "$gte": "AWS" } }, "projection": { "country": 1, "provider": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);

-- B2: project subset of compound index fields, _id excluded
-- Expected: IOS using country_provider_1
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$gte": "Brazil" }, "provider": { "$gte": "AWS" } }, "projection": { "provider": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);

-- B3: project both index fields with default _id projection
-- Expected: no IOS since _id is not covered by country_provider_1
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$gte": "Brazil" }, "provider": { "$gte": "AWS" } }, "projection": { "country": 1, "provider": 1 } }')$$, p_ignore_heap_fetches => true);

-- ===========================================================================
-- SECTION C: find with projection - compound index `country_id_1` (covers _id)
-- Use hints to force the planner to consider country_id_1 specifically.
-- ===========================================================================

-- C1: project country with default _id projection (must cover _id) - hint country_id_1
-- Expected: IOS using country_id_1 (filter is on country, not _id, so RUM IOS works)
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "country_id_1", "filter": { "country": { "$eq": "USA" } }, "projection": { "country": 1 } }')$$, p_ignore_heap_fetches => true);

-- C2: project country with explicit _id: 1 - hint country_id_1
-- Expected: IOS using country_id_1 (filter is on country, not _id;
-- the RUM compound index covers _id so projection of _id is satisfied
-- by the index without a heap fetch).
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "country_id_1", "filter": { "country": { "$eq": "USA" } }, "projection": { "country": 1, "_id": 1 } }')$$, p_ignore_heap_fetches => true);

-- C3: project country + _id with default _id covered - hint country_1 (does NOT cover _id)
-- Expected: NOT IOS because _id is required by default but country_1 doesn't cover it
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "country_1", "filter": { "country": { "$eq": "USA" } }, "projection": { "country": 1 } }')$$, p_ignore_heap_fetches => true);

-- ===========================================================================
-- SECTION C-TODO: known suboptimal/unsupported cases to be addressed later
-- ===========================================================================

-- C-TODO-1: filter on _id with a RUM compound index covering _id.
-- TODO: IOS for filter-on-_id against a RUM compound index is not yet
-- supported. Today the planner generates _id-typed quals (object_id filters)
-- for _id predicates that the RUM index cannot satisfy index-only; enabling
-- this requires query generation and planner changes to emit RUM-friendly
-- _id quals on the indexed bson document column. Once supported, this
-- should produce an Index Only Scan on country_id_1.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "country_id_1", "filter": { "_id": { "$gt": 3 }, "country": { "$eq": "USA" } }, "projection": { "country": 1, "_id": 1 } }')$$, p_ignore_heap_fetches => true);

-- C-TODO-2: find with projection of only `_id`.
-- TODO: Index-only scan for a projection that only includes `_id` is not yet
-- supported end-to-end. Once supported, this should use IOS on _id_ (BTREE)
-- or the RUM compound index when applicable.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "_id": { "$gt": 3 } }, "projection": { "_id": 0 } }')$$, p_ignore_heap_fetches => true);

-- ===========================================================================
-- SECTION D: aggregation pipeline $project (uses bson_dollar_project)
-- ===========================================================================

-- D1: $match + $project covered by single field index
-- Expected: IOS using country_1
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('iosfp_db', '{ "aggregate": "iosfp_coll", "pipeline": [ { "$match": { "country": { "$gte": "Brazil" } } }, { "$project": { "country": 1, "_id": 0 } } ] }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('iosfp_db', '{ "aggregate": "iosfp_coll", "pipeline": [ { "$match": { "country": { "$gte": "Brazil" } } }, { "$project": { "country": 1, "_id": 0 } } ] }');

-- D2: $match + $project of UN-covered field
-- Expected: no IOS since provider not covered by country_1
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('iosfp_db', '{ "aggregate": "iosfp_coll", "pipeline": [ { "$match": { "country": { "$gte": "Brazil" } } }, { "$project": { "provider": 1, "_id": 0 } } ] }')$$, p_ignore_heap_fetches => true);

-- D3: $match + $project + $count using covered fields
-- Expected: IOS using country_1
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('iosfp_db', '{ "aggregate": "iosfp_coll", "pipeline": [ { "$match": { "country": { "$gte": "Brazil" } } }, { "$project": { "country": 1, "_id": 0 } }, { "$count": "n" } ] }')$$, p_ignore_heap_fetches => true);

-- D4: $project with expression value -> no IOS
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('iosfp_db', '{ "aggregate": "iosfp_coll", "pipeline": [ { "$match": { "country": { "$gte": "Brazil" } } }, { "$project": { "country": 1, "_id": 0, "doubled": { "$multiply": [ "$_id", 2 ] } } } ] }')$$, p_ignore_heap_fetches => true);

-- D5: $project with pure exclusion -> no IOS
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('iosfp_db', '{ "aggregate": "iosfp_coll", "pipeline": [ { "$match": { "country": { "$gte": "Brazil" } } }, { "$project": { "region": 0 } } ] }')$$, p_ignore_heap_fetches => true);

-- ===========================================================================
-- SECTION E: regression - aggregate-only paths still work as before
-- ===========================================================================

-- E1: $match + $group on covered field (existing aggregate path)
-- Expected: IOS using country_1 (regression: must not break)
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('iosfp_db', '{ "aggregate": "iosfp_coll", "pipeline": [ { "$match": { "country": { "$gte": "Brazil" } } }, { "$group": { "_id": "$country", "n": { "$sum": 1 } } } ] }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('iosfp_db', '{ "aggregate": "iosfp_coll", "pipeline": [ { "$match": { "country": { "$gte": "Brazil" } } }, { "$group": { "_id": "$country", "n": { "$sum": 1 } } } ] }');

-- E2: $match + $count on covered field
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('iosfp_db', '{ "aggregate": "iosfp_coll", "pipeline": [ { "$match": { "country": { "$gte": "Brazil" } } }, { "$count": "n" } ] }')$$, p_ignore_heap_fetches => true);

-- ===========================================================================
-- SECTION F: GUC interaction (enableIndexOnlyScanForCoveredAggregateTargets)
-- ===========================================================================

-- The GUC `enableIndexOnlyScanForCoveredAggregateTargets` only gates IOS for queries
-- that have aggregates. Find queries with projection should NOT be affected.

SET documentdb.enableIndexOnlyScanForCoveredAggregateTargets TO off;

-- F1: find with projection (no aggregates) -> IOS still allowed
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$gte": "Brazil" } }, "projection": { "country": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);

-- F2: aggregation with $project that references document var via $group -> IOS gated off
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($sql$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline('iosfp_db', '{ "aggregate": "iosfp_coll", "pipeline": [ { "$match": { "country": { "$gte": "Brazil" } } }, { "$group": { "_id": "$country", "first": { "$first": "$$ROOT" } } } ] }')$sql$, p_ignore_heap_fetches => true);

RESET documentdb.enableIndexOnlyScanForCoveredAggregateTargets;

-- ===========================================================================
-- SECTION G: hint preservation
-- ===========================================================================

-- G1: Hinted find with projection on covered fields -> IOS preserved
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "country_1", "filter": { "country": { "$gte": "Brazil" } }, "projection": { "country": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);

-- G2: Hinted find with projection of UN-covered field -> no IOS (coverage check honored even with hint)
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "country_1", "filter": { "country": { "$gte": "Brazil" } }, "projection": { "provider": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);

-- ===========================================================================
-- SECTION H: limit / sort interaction with find + projection
-- ===========================================================================

-- H1: find + filter + projection covered + limit
-- Expected: IOS with limit
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$gte": "Brazil" } }, "projection": { "country": 1, "_id": 0 }, "limit": 5 }')$$, p_ignore_heap_fetches => true);

-- H2: find + filter + projection covered + sort on covered field
-- Expected: IOS with sort
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$gte": "Brazil" } }, "projection": { "country": 1, "_id": 0 }, "sort": { "country": 1 } }')$$, p_ignore_heap_fetches => true);

-- H3: find + filter + projection covered + sort on UN-covered field
-- Expected: no IOS because sort path not covered
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$gte": "Brazil" } }, "projection": { "country": 1, "_id": 0 }, "sort": { "region": 1 } }')$$, p_ignore_heap_fetches => true);

-- ===========================================================================
-- SECTION I: Runtime correctness validation - verify projection still produces right results
-- ===========================================================================

-- I1: verify IOS with projection returns correct documents
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$eq": "USA" } }, "projection": { "country": 1, "_id": 0 }, "sort": { "country": 1 } }');

-- I2: verify pipeline IOS with $project returns correct documents
SELECT document FROM bson_aggregation_pipeline('iosfp_db', '{ "aggregate": "iosfp_coll", "pipeline": [ { "$match": { "country": { "$eq": "USA" } } }, { "$project": { "country": 1, "_id": 0 } } ] }');

-- I3: verify default _id projection IOS path returns documents with _id and country
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$eq": "USA" } }, "projection": { "country": 1 }, "sort": { "country": 1, "_id": 0 } }');

-- ===========================================================================
-- SECTION J: IOS-specific runtime behaviors
-- ===========================================================================

-- J1: IOS reconstructs documents in index-key order, not insertion order.
-- Insert a doc whose source order is { provider, country, ... } (provider first).
-- The compound index `country_provider_1` orders keys (country, provider), so an
-- IOS-projected document comes back as { country, provider } regardless of how
-- it was originally written.
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 100, "provider": "Oracle", "country": "Canada", "region": "central"}');
ANALYZE documentdb_data.documents_6961;

-- Confirm the plan is IOS via country_provider_1.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$eq": "Canada" }, "provider": { "$eq": "Oracle" } }, "projection": { "provider": 1, "country": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);

-- Returned document has fields in index order (country, provider) not insertion order.
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "filter": { "country": { "$eq": "Canada" }, "provider": { "$eq": "Oracle" } }, "projection": { "provider": 1, "country": 1, "_id": 0 } }');

-- ===========================================================================
-- SECTION K: dotted-path index coverage (nested documents only, no arrays)
-- ===========================================================================
-- IOS over an indexed dotted path should work when the path traverses nested
-- documents only. Indexes on paths that traverse arrays cannot be used for IOS
-- (the index entries are per-element, not per-document), so this section
-- intentionally uses object-only nesting.

SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 200, "country": "Germany", "provider": "Hetzner", "addr": {"city": "Berlin", "zip": "10115"}}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 201, "country": "France", "provider": "OVH", "addr": {"city": "Paris", "zip": "75001"}}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 202, "country": "Spain", "provider": "Acens", "addr": {"city": "Madrid", "zip": "28001"}}');

-- Build an index on the dotted path `addr.city`.
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "addr.city": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "addr_city_1" }] }', true);
ANALYZE documentdb_data.documents_6961;

-- K1: filter and project on the dotted path -> IOS using addr_city_1.
-- The IOS reconstruction expands the indexed dotted path into nested
-- sub-documents, so the projected output matches the regular Index Scan path.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "addr_city_1", "filter": { "addr.city": { "$gte": "Berlin" } }, "projection": { "addr.city": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);

-- Expected: { "addr": { "city": ... } } for each matching document.
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "addr_city_1", "filter": { "addr.city": { "$gte": "Berlin" } }, "projection": { "addr.city": 1, "_id": 0 } }');

-- ===========================================================================
-- SECTION L: dotted-path reconstruction (exhaustive shapes)
-- ===========================================================================
-- Exercise every branch of the IOS document reconstruction:
--   * non-dotted compound (no reconstruction work)
--   * single dotted key (WriteSingleDottedPath fast path)
--   * adjacent shared prefixes (one nested doc, multiple leaves)
--   * non-adjacent shared prefixes (entries with the same head separated
--     by an unrelated key in the index spec)
--   * flat keys interleaved with dotted ones
--   * deeply-nested paths (multiple levels of grouping)
-- All test docs nest plain objects only - dotted paths through arrays
-- can't be IOS-covered.

SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 300, "kind": "L", "g": {"x": 1, "y": 2, "z": 3}, "h": {"x": 10, "y": 20}, "top": "alpha", "bottom": "one"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 301, "kind": "L", "g": {"x": 4, "y": 5, "z": 6}, "h": {"x": 40, "y": 50}, "top": "beta",  "bottom": "two"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 302, "kind": "L", "g": {"x": 7, "y": 8, "z": 9}, "h": {"x": 70, "y": 80}, "top": "gamma", "bottom": "three"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 303, "kind": "L", "deep": {"a": {"b": {"c": 111, "d": 222}}, "e": 333}, "flat": "f1"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 304, "kind": "L", "deep": {"a": {"b": {"c": 444, "d": 555}}, "e": 666}, "flat": "f2"}');

-- Index variants. All ordered indexes so they can serve IOS via the
-- composite ordering transform.
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "g.x": 1, "g.y": 1, "g.z": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "L_g_xyz" }] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "g.x": 1, "h.y": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "L_g_h" }] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "kind": 1, "g.x": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "L_kind_gx" }] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "top": 1, "g.x": 1, "bottom": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "L_top_gx_bottom" }] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "g.x": 1, "h.x": 1, "g.y": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "L_gx_hx_gy" }] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "deep.a.b.c": 1, "deep.a.b.d": 1, "deep.e": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "L_deep" }] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "kind": 1, "flat": 1, "deep.e": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "L_kind_flat_deepe" }] }', true);
ANALYZE documentdb_data.documents_6961;

-- L1: single dotted key in a compound index, all keys projected.
-- Adjacent shared-prefix grouping: { g: { x, y, z } }. The g.x range
-- alone disambiguates against pre-existing rows (they don't have g.x).
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_g_xyz", "filter": { "g.x": { "$gte": 1 } }, "projection": { "g.x": 1, "g.y": 1, "g.z": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_g_xyz", "filter": { "g.x": { "$gte": 1 } }, "projection": { "g.x": 1, "g.y": 1, "g.z": 1, "_id": 0 } }');

-- L2: two dotted keys with disjoint heads. Output has two top-level
-- nested docs: { g: { x }, h: { y } }.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_g_h", "filter": { "g.x": { "$gte": 1 } }, "projection": { "g.x": 1, "h.y": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_g_h", "filter": { "g.x": { "$gte": 1 } }, "projection": { "g.x": 1, "h.y": 1, "_id": 0 } }');

-- L3: flat key followed by dotted key. The reconstruction's flat fast
-- path writes `kind` directly; the dotted tail writes `g.x` as a nested
-- doc. Output: { kind, g: { x } }.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_kind_gx", "filter": { "kind": "L" }, "projection": { "kind": 1, "g.x": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_kind_gx", "filter": { "kind": "L" }, "projection": { "kind": 1, "g.x": 1, "_id": 0 } }');

-- L4: flat-dotted-flat. The trailing `bottom` lands after the last
-- dotted index key, exercising the lastDottedIdx short-circuit in the
-- grouping pass. Output: { top, g: { x }, bottom }.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_top_gx_bottom", "filter": { "top": { "$gte": "alpha" } }, "projection": { "top": 1, "g.x": 1, "bottom": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_top_gx_bottom", "filter": { "top": { "$gte": "alpha" } }, "projection": { "top": 1, "g.x": 1, "bottom": 1, "_id": 0 } }');

-- L5: non-adjacent shared prefix. Index keys are (g.x, h.x, g.y) - the
-- two `g.*` entries are separated by `h.x`. The grouping pass must
-- still merge them into one `g` sub-document.
-- Expected: { g: { x, y }, h: { x } }.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_gx_hx_gy", "filter": { "g.x": { "$gte": 1 } }, "projection": { "g.x": 1, "h.x": 1, "g.y": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_gx_hx_gy", "filter": { "g.x": { "$gte": 1 } }, "projection": { "g.x": 1, "h.x": 1, "g.y": 1, "_id": 0 } }');

-- L6: deep nesting with multi-level grouping. Index keys deep.a.b.c,
-- deep.a.b.d, deep.e share `deep` at the top and `a.b` at the next
-- level. Expected: { deep: { a: { b: { c, d } }, e } }.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_deep", "filter": { "deep.a.b.c": { "$gte": 0 } }, "projection": { "deep.a.b.c": 1, "deep.a.b.d": 1, "deep.e": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_deep", "filter": { "deep.a.b.c": { "$gte": 0 } }, "projection": { "deep.a.b.c": 1, "deep.a.b.d": 1, "deep.e": 1, "_id": 0 } }');

-- L7: dotted key is last in the index spec, after two flat keys. This
-- hits the `firstDottedIdx == numPaths - 1` short-circuit -
-- WriteSingleDottedPath emits the trailing nested doc directly without
-- going through the grouping pass. Expected: { kind, flat, deep: { e } }.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_kind_flat_deepe", "filter": { "kind": "L", "deep.e": { "$gte": 0 } }, "projection": { "kind": 1, "flat": 1, "deep.e": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_kind_flat_deepe", "filter": { "kind": "L", "deep.e": { "$gte": 0 } }, "projection": { "kind": 1, "flat": 1, "deep.e": 1, "_id": 0 } }');

-- L8: index has a dotted key but projection asks for the parent path.
-- An index on `g.x` does not cover a projection of `g` (we'd need every
-- field of `g`, not just `x`), so this should NOT be IOS.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_g_xyz", "filter": { "g.x": { "$gte": 1 } }, "projection": { "g": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);

-- L9: subset projection - index L_g_xyz covers (g.x, g.y, g.z) but we
-- only project g.x. Reconstruction still has to handle the prefix; the
-- other two index terms are dropped on the projection side after the
-- IOS materializes them. IOS plan is still chosen.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_g_xyz", "filter": { "g.x": { "$gte": 1 } }, "projection": { "g.x": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_g_xyz", "filter": { "g.x": { "$gte": 1 } }, "projection": { "g.x": 1, "_id": 0 } }');

-- ===========================================================================
-- Section M: documents with PARTIAL paths.
-- ===========================================================================
--
-- Each indexed key that's missing from the source document materializes
-- as an "undefined" term in the index. The reconstruction code must
-- skip those entirely - missing fields must NOT show up as null/empty
-- in the projected output.
--
-- We use g.x values >= 100 to keep these docs disjoint from Section L's
-- range filters (1..7), so existing L tests aren't perturbed.

-- M docs with sparse single-level fields. _id 320 has g.x and g.y but
-- no g.z. _id 321 has g.x only. _id 322 has g.x and g.z but no g.y -
-- this exercises a "hole" in the middle of an adjacent shared-prefix
-- group, so the grouping pass must still emit { g: { x, z } } without
-- a stray empty slot for y.
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 320, "kind": "M", "g": {"x": 110, "y": 220}}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 321, "kind": "M", "g": {"x": 130}}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 322, "kind": "M", "g": {"x": 140, "z": 660}}');

-- M docs with sparse deep-nested fields. _id 323 misses deep.a.b.d so
-- the inner b sub-doc only has c. _id 324 misses deep.e so the e
-- sibling at the deep level is absent. _id 325 has only deep.a.b.c -
-- both deep.a.b.d and deep.e are missing, so reconstruction must emit
-- just { deep: { a: { b: { c } } } } with no empty d slot or empty e.
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 323, "kind": "M", "deep": {"a": {"b": {"c": 1110}}, "e": 3330}}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 324, "kind": "M", "deep": {"a": {"b": {"c": 4440, "d": 5550}}}}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 325, "kind": "M", "deep": {"a": {"b": {"c": 7770}}}}');

-- M doc with the leading filter column present but the OTHER top-level
-- path (h) entirely absent. This tests that a missing non-leading
-- top-level group is dropped, not emitted as { h: {} }.
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 326, "kind": "M", "g": {"x": 990}}');

-- M1: trailing field missing - _id 320 lacks g.z. Expected output for
-- _id 320 is { g: { x:110, y:220 } } with NO z. _id 321 lacks both y
-- and z, so it's { g: { x:130 } }. _id 322 has x and z but no y, so
-- the projection emits { g: { x:140, z:660 } }.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_g_xyz", "filter": { "g.x": { "$gte": 100, "$lt": 900 } }, "projection": { "g.x": 1, "g.y": 1, "g.z": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_g_xyz", "filter": { "g.x": { "$gte": 100, "$lt": 900 } }, "projection": { "g.x": 1, "g.y": 1, "g.z": 1, "_id": 0 } }');

-- M2: an entire non-leading top-level path is missing. _id 326 has
-- g.x:990 but no h at all. Index L_g_h covers (g.x, h.y); h.y is
-- undefined for 326. Expected: { g: { x:990 } } - the h sub-document
-- must NOT appear at all (no { h: {} }).
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_g_h", "filter": { "g.x": { "$gte": 900 } }, "projection": { "g.x": 1, "h.y": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_g_h", "filter": { "g.x": { "$gte": 900 } }, "projection": { "g.x": 1, "h.y": 1, "_id": 0 } }');

-- M3: deep nesting with a missing trailing leaf. _id 323 lacks
-- deep.a.b.d. Expected: { deep: { a: { b: { c:1110 } }, e:3330 } }.
-- The b sub-document has only c, no d.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_deep", "filter": { "deep.a.b.c": { "$gte": 1100, "$lt": 4000 } }, "projection": { "deep.a.b.c": 1, "deep.a.b.d": 1, "deep.e": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_deep", "filter": { "deep.a.b.c": { "$gte": 1100, "$lt": 4000 } }, "projection": { "deep.a.b.c": 1, "deep.a.b.d": 1, "deep.e": 1, "_id": 0 } }');

-- M4: deep nesting with a missing trailing sibling. _id 324 lacks
-- deep.e. Expected: { deep: { a: { b: { c:4440, d:5550 } } } } - the
-- deep sub-document must NOT have an empty e slot.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_deep", "filter": { "deep.a.b.c": { "$gte": 4000, "$lt": 5000 } }, "projection": { "deep.a.b.c": 1, "deep.a.b.d": 1, "deep.e": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_deep", "filter": { "deep.a.b.c": { "$gte": 4000, "$lt": 5000 } }, "projection": { "deep.a.b.c": 1, "deep.a.b.d": 1, "deep.e": 1, "_id": 0 } }');

-- M5: deep nesting with a missing tail AND missing inner leaf at once.
-- _id 325 has only deep.a.b.c - no d, no e. Expected:
-- { deep: { a: { b: { c:7770 } } } }. Both intermediate-level (b
-- missing d) and top-level (deep missing e) drops must work together.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_deep", "filter": { "deep.a.b.c": { "$gte": 7000 } }, "projection": { "deep.a.b.c": 1, "deep.a.b.d": 1, "deep.e": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_deep", "filter": { "deep.a.b.c": { "$gte": 7000 } }, "projection": { "deep.a.b.c": 1, "deep.a.b.d": 1, "deep.e": 1, "_id": 0 } }');

-- M6: non-adjacent shared prefix with a hole. Index (g.x, h.x, g.y).
-- _id 322 lacks g.y AND lacks h.x. Expected: { g: { x:140 } } - both
-- the h sub-document and the g.y entry must be omitted, even though
-- the merged g group has only one surviving member.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_gx_hx_gy", "filter": { "g.x": { "$gte": 140, "$lt": 150 } }, "projection": { "g.x": 1, "h.x": 1, "g.y": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "L_gx_hx_gy", "filter": { "g.x": { "$gte": 140, "$lt": 150 } }, "projection": { "g.x": 1, "h.x": 1, "g.y": 1, "_id": 0 } }');


-- ===========================================================================
-- SECTION N: prefix-overlap indexes (parent path + child paths covered)
-- ===========================================================================
-- An index that covers both a parent path (e.g. "p") and one or more child
-- paths under it ("p.q") is valid. The parent's index entry already
-- holds the whole sub-document, so the child entries are redundant. IOS
-- reconstruction must take the parent (leaf) value and discard the children
-- at every depth - otherwise the reconstructed document loses the parent's
-- non-indexed fields and produces wrong projections.
--
-- Projections that reference both a parent and one of its descendants
-- (e.g. { p: 1, "p.q": 1 }) are rejected by the projection layer with
-- a path collision error, so we don't test that shape here. We do project
-- the parent and the child individually against an index whose keys
-- overlap, so the leaf-wins branch of the reconstruction is exercised.
-- Tested shapes:
--   * 2-level: { p, p.q }
--   * deeper:  { p.q, p.q.r }
--   * mixed:   { p, p.q, p.q.r }       -- top wins; deeper redundant
--   * branch:  { p.q, p.q.r, p.q.s }   -- middle wins over both leaves

-- N-docs: parent values are always sub-documents and carry extra fields
-- that are NOT in the index, so we can verify the parent leaf is being
-- written rather than reconstructed from the children alone.
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 500, "kind": "N", "p": {"q": 1, "extra": "keep"}, "tag": "a"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 501, "kind": "N", "p": {"q": 2, "extra": "skip"}, "tag": "b"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 502, "kind": "N2", "p": {"q": {"r": 30, "s": 31, "stay": "keep2"}}, "tag": "c"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 503, "kind": "N2", "p": {"q": {"r": 40, "s": 41, "stay": "keep3"}}, "tag": "d"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 504, "kind": "N3", "p": {"q": {"r": 50, "s": 51, "extra": "deep"}}, "tag": "e"}');
SELECT documentdb_api.insert_one('iosfp_db', 'iosfp_coll', '{"_id": 505, "kind": "N3", "p": {"q": {"r": 60, "s": 61, "extra": "deep2"}}, "tag": "f"}');

SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "kind": 1, "p": 1, "p.q": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "N_p_pq" }] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "kind": 1, "p.q": 1, "p.q.r": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "N_pq_pqr" }] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "kind": 1, "p": 1, "p.q": 1, "p.q.r": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "N_p_pq_pqr" }] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "kind": 1, "p.q": 1, "p.q.r": 1, "p.q.s": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "N_pq_pqr_pqs" }] }', true);
ANALYZE documentdb_data.documents_6961;

-- N1: 2-level overlap {p, p.q}, project the parent.
-- Leaf at "p" wins; the redundant "p.q" entry is dropped.
-- Expected: full original "p" sub-document including the non-indexed "extra".
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_p_pq", "filter": { "kind": { "$eq": "N" } }, "projection": { "p": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_p_pq", "filter": { "kind": { "$eq": "N" } }, "projection": { "p": 1, "_id": 0 } }');

-- N1b: same overlap, project the child only. The reconstructed doc still
-- comes from the "p" leaf; the projection then walks into p.q to extract
-- the value. Expected: { p: { q: <int> } } per doc.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_p_pq", "filter": { "kind": { "$eq": "N" } }, "projection": { "p.q": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_p_pq", "filter": { "kind": { "$eq": "N" } }, "projection": { "p.q": 1, "_id": 0 } }');

-- N2: deeper overlap {p.q, p.q.r}, project the parent of the overlap.
-- The "p.q" leaf wins under the recursed "p" segment; "p.q.r" is dropped.
-- Expected: { p: { q: { r, s, stay } } } - the full sub-document the
-- "p.q" entry holds, including non-indexed "stay".
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pq_pqr", "filter": { "kind": { "$eq": "N2" } }, "projection": { "p.q": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pq_pqr", "filter": { "kind": { "$eq": "N2" } }, "projection": { "p.q": 1, "_id": 0 } }');

-- N2b: same index, project the child of the overlap. Expected: only the
-- r leaf surfaces under p.q.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pq_pqr", "filter": { "kind": { "$eq": "N2" } }, "projection": { "p.q.r": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pq_pqr", "filter": { "kind": { "$eq": "N2" } }, "projection": { "p.q.r": 1, "_id": 0 } }');

-- N3: 3-level chain {p, p.q, p.q.r}, project the top parent. Top "p"
-- leaf wins outright; both deeper entries are redundant.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_p_pq_pqr", "filter": { "kind": { "$eq": "N3" } }, "projection": { "p": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_p_pq_pqr", "filter": { "kind": { "$eq": "N3" } }, "projection": { "p": 1, "_id": 0 } }');

-- N3b: same chain, project the deepest field. Reconstructed doc still
-- comes entirely from the top-level "p" leaf; projection walks down.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_p_pq_pqr", "filter": { "kind": { "$eq": "N3" } }, "projection": { "p.q.r": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_p_pq_pqr", "filter": { "kind": { "$eq": "N3" } }, "projection": { "p.q.r": 1, "_id": 0 } }');

-- N4: branching overlap {p.q, p.q.r, p.q.s}. The middle "p.q" leaf wins
-- at its level; both deeper sibling leaves are dropped. Project the
-- parent of the overlap to confirm the full sub-document - including the
-- non-indexed "extra" field - is restored from the "p.q" leaf.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pq_pqr_pqs", "filter": { "kind": { "$eq": "N3" } }, "projection": { "p.q": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pq_pqr_pqs", "filter": { "kind": { "$eq": "N3" } }, "projection": { "p.q": 1, "_id": 0 } }');

-- The same overlap shapes, but with the deeper paths declared BEFORE
-- their parent in the index spec. The reconstruction has to walk the
-- index keys in order and still recognise that the trailing leaf
-- supersedes the earlier child entries. Indexes:
--   * { kind, p.q, p }              - 2-level reversed
--   * { kind, p.q.r, p.q }          - deeper reversed
--   * { kind, p.q.r, p.q, p }       - 3-level chain reversed
--   * { kind, p.q.s, p.q.r, p.q }   - branching, parent last
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "kind": 1, "p.q": 1, "p": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "N_pq_p" }] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "kind": 1, "p.q.r": 1, "p.q": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "N_pqr_pq" }] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "kind": 1, "p.q.r": 1, "p.q": 1, "p": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "N_pqr_pq_p" }] }', true);
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosfp_db', '{ "createIndexes": "iosfp_coll", "indexes": [ { "key": { "kind": 1, "p.q.s": 1, "p.q.r": 1, "p.q": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "N_pqs_pqr_pq" }] }', true);
ANALYZE documentdb_data.documents_6961;

-- N5: 2-level reversed {p.q, p}, project the parent. The "p.q" entry
-- appears first in the index spec but is redundant; the trailing "p"
-- leaf must still win the top-level segment.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pq_p", "filter": { "kind": { "$eq": "N" } }, "projection": { "p": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pq_p", "filter": { "kind": { "$eq": "N" } }, "projection": { "p": 1, "_id": 0 } }');

-- N5b: same reversed index, project the child. The leaf-wins decision
-- for "p" is what feeds the projection; result must include the
-- non-indexed "extra" untouched.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pq_p", "filter": { "kind": { "$eq": "N" } }, "projection": { "p.q": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pq_p", "filter": { "kind": { "$eq": "N" } }, "projection": { "p.q": 1, "_id": 0 } }');

-- N6: deeper reversed {p.q.r, p.q}. Parent of the overlap is "p.q";
-- projecting it must yield the full sub-document including non-indexed
-- "stay", proving the recursion preferred the trailing "p.q" leaf over
-- the earlier "p.q.r" entry.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pqr_pq", "filter": { "kind": { "$eq": "N2" } }, "projection": { "p.q": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pqr_pq", "filter": { "kind": { "$eq": "N2" } }, "projection": { "p.q": 1, "_id": 0 } }');

-- N7: 3-level chain reversed {p.q.r, p.q, p}, project the topmost
-- parent. All three levels are eligible leaves at their depths but
-- only the outermost "p" is what makes it into the reconstructed doc.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pqr_pq_p", "filter": { "kind": { "$eq": "N3" } }, "projection": { "p": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pqr_pq_p", "filter": { "kind": { "$eq": "N3" } }, "projection": { "p": 1, "_id": 0 } }');

-- N7b: same 3-level reversed chain, project the deepest field. Even
-- though the deepest entry is declared first, the projection still has
-- to walk down through the "p" leaf-restored sub-document.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pqr_pq_p", "filter": { "kind": { "$eq": "N3" } }, "projection": { "p.q.r": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pqr_pq_p", "filter": { "kind": { "$eq": "N3" } }, "projection": { "p.q.r": 1, "_id": 0 } }');

-- N8: branching with parent last {p.q.s, p.q.r, p.q}. The two deeper
-- sibling leaves come first, the merging "p.q" leaf comes last. The
-- merging leaf must still supersede both of its earlier siblings.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pqs_pqr_pq", "filter": { "kind": { "$eq": "N3" } }, "projection": { "p.q": 1, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_pqs_pqr_pq", "filter": { "kind": { "$eq": "N3" } }, "projection": { "p.q": 1, "_id": 0 } }');

-- N9: nested-document projection { "p": { "q": 1 } } is semantically
-- equivalent to { "p.q": 1 } and would be coverable by N_p_pq, but the
-- IOS coverage check currently rejects any projection value that is
-- not a 64-bit integer (see TODO in IsProjectionCoveredByIndex). Pin
-- the current behaviour: regular Index Scan, not IOS. When the TODO is
-- addressed this test should be updated to expect IOS.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_p_pq", "filter": { "kind": { "$eq": "N" } }, "projection": { "p": { "q": 1 }, "_id": 0 } }')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_find('iosfp_db', '{ "find": "iosfp_coll", "hint": "N_p_pq", "filter": { "kind": { "$eq": "N" } }, "projection": { "p": { "q": 1 }, "_id": 0 } }');


-- ===========================================================================
-- Cleanup
-- ===========================================================================

SELECT documentdb_api.drop_collection('iosfp_db', 'iosfp_coll') IS NOT NULL;
