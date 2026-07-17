SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;

SET citus.next_shard_id TO 2960000;
SET documentdb.next_collection_id TO 29600;
SET documentdb.next_collection_index_id TO 29600;

SET documentdb.enableIndexMetadataGlobalTracking TO on;
SET documentdb.enableCompositeReducedCorrelatedTermsOnCommonSubPath TO on;
SET documentdb.enableExplainScanIndexCosts TO off;
SET citus.propagate_set_commands TO 'local';

SELECT documentdb_api.create_collection('rct_dist_db', 'items');
SELECT documentdb_distributed_test_helpers.place_collection_on_node(
    'rct_dist_db', 'items', 1);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'rct_dist_db',
    '{ "createIndexes": "items", "indexes": [
        {
          "key": { "items.id": 1, "items.city": 1 },
          "name": "idx_items",
          "enableOrderedIndex": 1
        }
    ]}',
    true);
SELECT documentdb_distributed_test_helpers.drop_primary_key(
    'rct_dist_db', 'items');

SELECT documentdb_api.insert_one(
    'rct_dist_db', 'items',
    '{"_id":1,"items":[{"id":"A","city":"seattle"}]}');
SELECT documentdb_api.insert_one(
    'rct_dist_db', 'items',
    '{"_id":2,"items":[{"id":"A","city":"portland"},{"id":"B","city":"seattle"}]}');

BEGIN;
SET LOCAL citus.enable_local_execution TO off;
SET LOCAL documentdb.enable_composite_reduced_correlated_bounds_planning TO on;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_bitmapscan TO off;

-- One $elemMatch retains both same-element bounds and excludes the
-- cross-element document before the heap filter.
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_find(
    'rct_dist_db',
    '{"find":"items","filter":{"items":{"$elemMatch":{"id":"A","city":"seattle"}}}}');
SELECT document FROM bson_aggregation_find(
    'rct_dist_db',
    '{"find":"items","filter":{"items":{"$elemMatch":{"id":"A","city":"seattle"}}},"sort":{"_id":1}}');

-- Plain dotted-path filters retain only the leading index bound. The
-- cross-element document must remain visible to the runtime filter.
EXPLAIN (COSTS OFF)
SELECT document FROM bson_aggregation_find(
    'rct_dist_db',
    '{"find":"items","filter":{"items.id":"A","items.city":"seattle"}}');
SELECT document FROM bson_aggregation_find(
    'rct_dist_db',
    '{"find":"items","filter":{"items.id":"A","items.city":"seattle"},"sort":{"_id":1}}');

ROLLBACK;

RESET citus.propagate_set_commands;
SET documentdb.enableIndexMetadataGlobalTracking TO off;
SELECT documentdb_api.drop_collection('rct_dist_db', 'items');
