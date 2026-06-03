SET search_path TO documentdb_api_catalog, documentdb_api, documentdb_core, documentdb_api_internal, public;
SET citus.next_shard_id TO 645000;
SET documentdb.next_collection_id TO 6450;
SET documentdb.next_collection_index_id TO 6450;

--------------------------------------------------------------------------------
-- Test: bson_operator_selectivity with btree stats
-- Validates that when enableBsonSelectivityFromBtreeStats is on, the planner
-- uses PG's native selectivity functions (eqsel/scalargtsel/etc.) on btree
-- expression indexes, giving accurate row estimates instead of the default 1%.
--------------------------------------------------------------------------------

-- Create a collection and insert data
SELECT documentdb_api.create_collection('sel_db', 'btree_sel');

-- Insert 50K rows: category has only 10 distinct values (each ~5000 rows),
-- guid is unique per row (each has exactly 1 row)
SELECT COUNT(documentdb_api.insert_one('sel_db', 'btree_sel',
    bson_build_document(
        '_id'::text, i,
        'guid'::text, format('guid-%08s', i),
        'category'::text, format('cat-%s', i % 10),
        'score'::text, (i % 1000)
    ))) FROM generate_series(1, 50000) i;

-- Insert 2 target rows with a known guid
SELECT documentdb_api.insert_one('sel_db', 'btree_sel',
    '{ "_id": 50001, "guid": "target-guid-00000001", "category": "cat-0", "score": 500 }');
SELECT documentdb_api.insert_one('sel_db', 'btree_sel',
    '{ "_id": 50002, "guid": "target-guid-00000001", "category": "cat-0", "score": 501 }');

-- Create btree expression indexes using bson_stats_project
CREATE INDEX btree_sel_guid ON documentdb_data.documents_6451
    USING btree(documentdb_api_internal.bson_stats_project(document, 'guid'::text));
CREATE INDEX btree_sel_category ON documentdb_data.documents_6451
    USING btree(documentdb_api_internal.bson_stats_project(document, 'category'::text));
CREATE INDEX btree_sel_score ON documentdb_data.documents_6451
    USING btree(documentdb_api_internal.bson_stats_project(document, 'score'::text));

ANALYZE documentdb_data.documents_6451;

SET enable_seqscan TO off;

-- Test 1: Without btree selectivity, default 1% selectivity for all operators.
-- Both guid and category get the same generic 1% selectivity.
SET documentdb_core.enableBsonSelectivityFromBtreeStats TO off;
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_data.documents_6451
    WHERE documentdb_api_internal.bson_stats_project(document, 'guid'::text) = '{"": "target-guid-00000001"}'
    AND documentdb_api_internal.bson_stats_project(document, 'category'::text) = '{"": "cat-0"}';

-- Test 2: With btree selectivity enabled, eqsel returns accurate selectivity.
-- guid "target-guid-00000001" has 2/50002 rows (~0.00004) vs category "cat-0"
-- with ~5002/50002 rows (~0.1). The planner uses the guid index (same index
-- choice but with accurate row estimates).
SET documentdb_core.enableBsonSelectivityFromBtreeStats TO on;
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_data.documents_6451
    WHERE documentdb_api_internal.bson_stats_project(document, 'guid'::text) = '{"": "target-guid-00000001"}'
    AND documentdb_api_internal.bson_stats_project(document, 'category'::text) = '{"": "cat-0"}';

-- Test 3: Range query with btree selectivity uses scalargtsel/scalarltsel
SET documentdb_core.enableBsonSelectivityFromBtreeStats TO on;
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_data.documents_6451
    WHERE documentdb_api_internal.bson_stats_project(document, 'guid'::text) = '{"": "target-guid-00000001"}'
    AND documentdb_api_internal.bson_stats_project(document, 'score'::text) >= '{"": 400}'
    AND documentdb_api_internal.bson_stats_project(document, 'score'::text) <= '{"": 600}';

-- Test 4: Verify query correctness
SELECT document FROM documentdb_data.documents_6451
    WHERE documentdb_api_internal.bson_stats_project(document, 'guid'::text) = '{"": "target-guid-00000001"}'
    AND documentdb_api_internal.bson_stats_project(document, 'category'::text) = '{"": "cat-0"}';

-- Test 5: PK _id index plan change with GUC on/off for range queries.
-- With accurate selectivity, PG knows _id > 500 matches ~99% of rows and
-- chooses Bitmap Heap Scan (efficient for large result sets). Without it,
-- the default 1% selectivity makes PG think few rows match → Index Scan.
SET documentdb_core.enableBsonSelectivityFromBtreeStats TO on;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('sel_db',
    '{ "find": "btree_sel", "filter": { "_id": { "$gt": 500 } } }');

SET documentdb_core.enableBsonSelectivityFromBtreeStats TO off;
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('sel_db',
    '{ "find": "btree_sel", "filter": { "_id": { "$gt": 500 } } }');

-- Cleanup: drop the collection to free resources
RESET enable_seqscan;
SELECT documentdb_api.drop_collection('sel_db', 'btree_sel');

RESET documentdb_core.enableBsonSelectivityFromBtreeStats;
