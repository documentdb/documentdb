SET citus.next_shard_id TO 690000;
SET documentdb.next_collection_id TO 69000;
SET documentdb.next_collection_index_id TO 69000;
SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_api_internal,documentdb_core;

SET documentdb.enableExtendedExplainPlans to on;
SET documentdb.enableIndexOnlyScan to on;

-- if documentdb_extended_rum exists, set alternate index handler
SELECT pg_catalog.set_config('documentdb.alternate_index_handler_name', 'extended_rum', false), extname FROM pg_extension WHERE extname = 'documentdb_extended_rum';

SELECT documentdb_api.drop_collection('idx_only_scan_db', 'idx_only_scan_coll') IS NOT NULL;
SELECT documentdb_api.create_collection('idx_only_scan_db', 'idx_only_scan_coll');

ALTER TABLE documentdb_data.documents_69001 set (autovacuum_enabled = off);

SELECT documentdb_api_internal.create_indexes_non_concurrently('idx_only_scan_db', '{ "createIndexes": "idx_only_scan_coll", "indexes": [ { "key": { "country": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "country_1" }] }', true);

select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', '{"_id": 1, "country": "USA", "provider": "AWS"}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', '{"_id": 2, "country": "USA", "provider": "Azure"}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', '{"_id": 3, "country": "Mexico", "provider": "GCP"}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', '{"_id": 4, "country": "India", "provider": "AWS"}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', '{"_id": 5, "country": "Brazil", "provider": "Azure"}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', '{"_id": 6, "country": "Brazil", "provider": "GCP"}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', '{"_id": 7, "country": "Mexico", "provider": "AWS"}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', '{"_id": 8, "country": "USA", "provider": "Azure"}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', '{"_id": 9, "country": "India", "provider": "GCP"}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', '{"_id": 10, "country": "Mexico", "provider": "AWS"}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', '{"_id": 11, "country": "USA", "provider": "Azure"}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', '{"_id": 12, "country": "Spain", "provider": "GCP"}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', '{"_id": 13, "country": "Italy", "provider": "AWS"}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', '{"_id": 14, "country": "France", "provider": "Azure"}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', '{"_id": 15, "country": "France", "provider": "GCP"}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', '{"_id": 16, "country": "Mexico", "provider": "AWS"}');

ANALYZE documentdb_data.documents_69001;

set enable_seqscan to off;
set enable_bitmapscan to off;

-- test index only scan
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$gte": "Brazil"}} }, { "$group" : { "_id" : "1", "n" : { "$sum" : 1 } } }]}')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$gte": "Brazil"}} }, { "$group" : { "_id" : "1", "n" : { "$sum" : 1 } } }]}');

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$lt": "Mexico"}} }, { "$group" : { "_id" : "1", "n" : { "$sum" : 1 } } }]}')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$lt": "Mexico"}} }, { "$group" : { "_id" : "1", "n" : { "$sum" : 1 } } }]}');

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_count('idx_only_scan_db', '{"count": "idx_only_scan_coll", "query": {"country": {"$eq": "USA"}}}')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('idx_only_scan_db', '{"count": "idx_only_scan_coll", "query": {"country": {"$eq": "USA"}}}');

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_count('idx_only_scan_db', '{"count": "idx_only_scan_coll", "query": {"country": {"$eq": "USA"}}}')$$, p_ignore_heap_fetches => true);

-- now update a document to change the country
SELECT documentdb_api.update('idx_only_scan_db', '{"update": "idx_only_scan_coll", "updates":[{"q": {"_id": 8},"u":{"$set":{"country": "Italy"}},"multi":false}]}');

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_count('idx_only_scan_db', '{"count": "idx_only_scan_coll", "query": {"country": {"$eq": "USA"}}}')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('idx_only_scan_db', '{"count": "idx_only_scan_coll", "query": {"country": {"$eq": "USA"}}}');

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_count('idx_only_scan_db', '{"count": "idx_only_scan_coll", "query": {"country": {"$in": ["USA", "Italy"]}}}')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_count('idx_only_scan_db', '{"count": "idx_only_scan_coll", "query": {"country": {"$in": ["USA", "Italy"]}}}');

-- $gt and $lte operators on single composite index
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$gt": "India"}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$gt": "India"}} }, { "$count": "count" }]}');

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$lte": "India"}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$lte": "India"}} }, { "$count": "count" }]}');

-- match with count
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$lt": "Mexico"}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$lt": "Mexico"}} }, { "$count": "count" }]}');

-- range queries should also use index only scan
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$gt": "Brazil"}, "country": {"$lt": "Mexico"}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$gt": "Brazil"}, "country": {"$lt": "Mexico"}} }, { "$count": "count" }]}');

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{"$match": { "country": {"$gt": "Brazil"}, "country": {"$lt": "Mexico"} }}, { "$limit": 10 }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{"$match": { "country": {"$gt": "Brazil"}, "country": {"$lt": "Mexico"} }}, { "$limit": 10 }, { "$group": { "_id": 1, "c": { "$sum": 1 } } }]}')$$, p_ignore_heap_fetches => true);

-- match + eq + limit + count on composite index
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{"$match": { "country": {"$eq": "USA"} }}, { "$limit": 5 }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{"$match": { "country": {"$eq": "USA"} }}, { "$limit": 5 }, { "$count": "count" }]}');

-- No filters and not sharded should use _id_ index
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{"$match": {}}, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{"$match": { "_id": { "$gt": 3, "$lt": 8 }}}, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);

-- count with match + limit uses index only scan 
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{"$match": { "_id": { "$gt": 3, "$lt": 8 }}}, { "$limit": 10 }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{"$match": { "_id": { "$gt": 3, "$lt": 8 }}}, { "$limit": 10 }, { "$group": { "_id": 1, "c": { "$sum": 1 } } }]}')$$, p_ignore_heap_fetches => true);

-- this will need index scan
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{"$match": { "_id": { "$gt": 3, "$lt": 8 }}}, { "$limit": 10 }, { "$group": { "_id": 1, "c": { "$max": "$_id" } } }]}')$$, p_ignore_heap_fetches => true);

SET documentdb.enableNewWithExprAccumulators TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{"$match": { "_id": { "$gt": 3, "$lt": 8 }}}, { "$limit": 10 }, { "$group": { "_id": 1, "c": { "$max": "$_id" } } }]}')$$, p_ignore_heap_fetches => true);
SET documentdb.enableNewWithExprAccumulators TO off;



-- now test with compound index
SELECT documentdb_api_internal.create_indexes_non_concurrently('idx_only_scan_db', '{ "createIndexes": "idx_only_scan_coll", "indexes": [ { "key": { "country": 1, "provider": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "country_provider_1" }] }', true);

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$eq": "Mexico"}, "provider": {"$eq": "AWS"}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$eq": "Mexico"}, "provider": {"$eq": "AWS"}} }, { "$count": "count" }]}');

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$eq": "Mexico"}, "provider": {"$eq": "GCP"}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$eq": "Mexico"}, "provider": {"$eq": "GCP"}} }, { "$count": "count" }]}');

-- if the filter doesn't match the first field in the index, shouldn't use the compound index and not index only scan
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"provider": {"$eq": "AWS"}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);

-- if we project something out it shouldn't do index only scan
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$gte": "Mexico"}} }, { "$group" : { "_id" : "$country", "n" : { "$sum" : 1 } } }]}')$$, p_ignore_heap_fetches => true);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$eq": "Mexico"}} }]}')$$, p_ignore_heap_fetches => true);

-- negation, elemMatch, type and size queries should not use index only scan
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$ne": "Mexico"}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$type": "string"}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$size": 2}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$elemMatch": {"$eq": "Mexico"}}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);

-- null/empty array and mixed $in predicates need runtime recheck and should not use index only scan
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$eq": null}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$eq": []}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$in": ["USA", null]}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$in": ["USA", []]}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);

-- if we turn the GUC off by it shouldn't use index only scan
set documentdb.enableIndexOnlyScan to off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$lt": "Mexico"}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);

set documentdb.enableIndexOnlyScan to on;

-- test with force and planner path
set documentdb.forceIndexOnlyScanIfAvailable to on;
set documentdb.enableIndexOnlyScanOnCost to off;

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$lt": "Mexico"}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);

reset documentdb.forceIndexOnlyScanIfAvailable;
reset documentdb.enableIndexOnlyScanOnCost;

-- if we insert a multi-key value, it shouldn't use index only scan
SELECT documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', '{"_id": 17, "country": "Mexico", "provider": ["AWS", "GCP"]}');
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$eq": "Mexico"}, "provider": {"$eq": ["AWS", "GCP"]}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
CALL documentdb_api.drop_indexes('idx_only_scan_db', '{ "dropIndexes": "idx_only_scan_coll", "index": "country_provider_1" }');

-- now insert a truncated term, should not use index only scan
SELECT documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_coll', FORMAT('{ "_id": 18, "country": { "key": "%s", "provider": "%s" } }', repeat('a', 10000), repeat('a', 10000))::bson);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$eq": "Mexico"}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);

-- if we delete it and vacuum it should use index only scan again
SELECT documentdb_api.delete('idx_only_scan_db', '{ "delete": "idx_only_scan_coll", "deletes": [ {"q": {"_id": {"$eq": 18} }, "limit": 0} ]}');

set client_min_messages to DEBUG1;
VACUUM (FREEZE ON) documentdb_data.documents_69001;
reset client_min_messages;

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$eq": "Mexico"}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);

-- test _id index only scans
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"_id": {"$gt": 5 }} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"_id": {"$gt": 5, "$lt": 8 }} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"_id": {"$gt": 5, "$lt": 8 }, "country": { "$lt": { "$maxKey": 1 }}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);

-- count with legacy count aggregates
set documentdb.enableNewCountAggregates to off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$eq": "Mexico"}} }, { "$count": "count" }]}')$$, p_ignore_heap_fetches => true);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$gte": "Brazil"}} }, { "$group" : { "_id" : "1", "n" : { "$sum" : 1 } } }]}')$$, p_ignore_heap_fetches => true);
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_coll", "pipeline" : [{ "$match" : {"country": {"$gte": "Brazil"}} }, { "$group" : { "_id" : null, "n" : { "$sum" : 1 } } }]}')$$, p_ignore_heap_fetches => true);

set documentdb.enableNewCountAggregates to on;

-- Sharded collections can't be supported with a shard key filter because in RUM indexes the shard_key_value becomes a runtime filter and for index only scans everything needs to be satisfied by the index. 
SELECT COUNT(documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_sharded', bson_build_document('_id'::text, i, 'shardKey'::text, i % 10, 'value'::text, i))) FROM generate_series(1, 1000) i;
SELECT documentdb_api.shard_collection('{ "shardCollection": "idx_only_scan_db.idx_only_scan_sharded", "key": { "shardKey": "hashed" } }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('idx_only_scan_db', '{ "createIndexes": "idx_only_scan_sharded", "indexes": [ { "key": { "shardKey": 1 }, "name": "idx1", "enableOrderedIndex": true }]}', TRUE);

VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_69002;

BEGIN;
set local enable_seqscan to off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF)
    SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_sharded", "pipeline" : [{ "$match" : {"shardKey": {"$eq": 5 } } }, { "$count": "c" } ]}')$$, p_ignore_heap_fetches => true);

set local documentdb.forceIndexOnlyScanIfAvailable to on;

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF)
    SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_sharded", "pipeline" : [{ "$match" : {"shardKey": {"$eq": 5 } } }, { "$count": "c" } ]}')$$, p_ignore_heap_fetches => true);
ROLLBACK;

-- test index only scan is not enabled for wildcard indexes
SELECT documentdb_api.insert_one('idx_only_scan_db', 'compwildcard2', '{ "a": { "b": 1, "c": 5 }}');
SELECT documentdb_api.insert_one('idx_only_scan_db', 'compwildcard2', '{ "a": { "b": 1, "c": 6 }}');
SELECT documentdb_api.insert_one('idx_only_scan_db', 'compwildcard2', '{ "a": { "b": 2, "c": 6 }}');
SELECT documentdb_api.insert_one('idx_only_scan_db', 'compwildcard2', '{ "a": { "b": 2, "c": 7 }}');
SELECT documentdb_api.insert_one('idx_only_scan_db', 'compwildcard2', '{ "a": { "b": 3, "c": 7 }}');
SELECT documentdb_api_internal.create_indexes_non_concurrently('idx_only_scan_db', '{ "createIndexes": "compwildcard2", "indexes": [ { "key": { "$**": 1 }, "name": "$**_1", "enableOrderedIndex": true }]}', TRUE);

set documentdb.forceIndexOnlyScanIfAvailable to on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF)
    SELECT document FROM bson_aggregation_count('idx_only_scan_db', '{ "count" : "compwildcard2", "query" : { "a.b": { "$gt": 2 } } }')$$, p_ignore_heap_fetches => true);
RESET documentdb.forceIndexOnlyScanIfAvailable;

-- test $sum/$avg on numeric field with ordered index (future index-only scan optimization candidate)
SELECT documentdb_api.create_collection('idx_only_scan_db', 'idx_only_scan_numeric');

select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_numeric', '{"_id": 1, "dept": "eng", "age": 30}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_numeric', '{"_id": 2, "dept": "eng", "age": 25}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_numeric', '{"_id": 3, "dept": "eng", "age": 35}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_numeric', '{"_id": 4, "dept": "sales", "age": 40}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_numeric', '{"_id": 5, "dept": "sales", "age": 28}');
select documentdb_api.insert_one('idx_only_scan_db', 'idx_only_scan_numeric', '{"_id": 6, "dept": "sales", "age": 45}');

SELECT documentdb_api_internal.create_indexes_non_concurrently('idx_only_scan_db', '{ "createIndexes": "idx_only_scan_numeric", "indexes": [ { "key": { "dept": 1, "age": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "dept_age_1" }] }', true);

ANALYZE documentdb_data.documents_69003;
VACUUM (FREEZE ON) documentdb_data.documents_69003;

-- $sum on indexed numeric field with old accumulators (needs index scan, not IOS — reads document for field value)
EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_numeric", "pipeline" : [{ "$match" : {"dept": {"$eq": "eng"}} }, { "$group": { "_id": "$dept", "totalAge": { "$sum": "$age" } } }]}');
SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_numeric", "pipeline" : [{ "$match" : {"dept": {"$eq": "eng"}} }, { "$group": { "_id": "$dept", "totalAge": { "$sum": "$age" } } }]}');

-- $avg on indexed numeric field with old accumulators
EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_numeric", "pipeline" : [{ "$match" : {"dept": {"$eq": "eng"}} }, { "$group": { "_id": "$dept", "avgAge": { "$avg": "$age" } } }]}');
SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_numeric", "pipeline" : [{ "$match" : {"dept": {"$eq": "eng"}} }, { "$group": { "_id": "$dept", "avgAge": { "$avg": "$age" } } }]}');

-- $sum and $avg across all groups
EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_numeric", "pipeline" : [{ "$group": { "_id": "$dept", "totalAge": { "$sum": "$age" }, "avgAge": { "$avg": "$age" } } }, { "$sort": { "_id": 1 } }]}');
SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_numeric", "pipeline" : [{ "$group": { "_id": "$dept", "totalAge": { "$sum": "$age" }, "avgAge": { "$avg": "$age" } } }, { "$sort": { "_id": 1 } }]}');

-- $sum on indexed numeric field with new accumulators
SET documentdb.enableNewWithExprAccumulators TO on;
EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_numeric", "pipeline" : [{ "$match" : {"dept": {"$eq": "eng"}} }, { "$group": { "_id": "$dept", "totalAge": { "$sum": "$age" } } }]}');
SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_numeric", "pipeline" : [{ "$match" : {"dept": {"$eq": "eng"}} }, { "$group": { "_id": "$dept", "totalAge": { "$sum": "$age" } } }]}');

-- $avg on indexed numeric field with new accumulators
EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_numeric", "pipeline" : [{ "$match" : {"dept": {"$eq": "eng"}} }, { "$group": { "_id": "$dept", "avgAge": { "$avg": "$age" } } }]}');
SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_numeric", "pipeline" : [{ "$match" : {"dept": {"$eq": "eng"}} }, { "$group": { "_id": "$dept", "avgAge": { "$avg": "$age" } } }]}');

-- $sum and $avg across all groups with new accumulators
EXPLAIN (ANALYZE ON, COSTS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_numeric", "pipeline" : [{ "$group": { "_id": "$dept", "totalAge": { "$sum": "$age" }, "avgAge": { "$avg": "$age" } } }, { "$sort": { "_id": 1 } }]}');
SELECT document FROM bson_aggregation_pipeline('idx_only_scan_db', '{ "aggregate" : "idx_only_scan_numeric", "pipeline" : [{ "$group": { "_id": "$dept", "totalAge": { "$sum": "$age" }, "avgAge": { "$avg": "$age" } } }, { "$sort": { "_id": 1 } }]}');
SET documentdb.enableNewWithExprAccumulators TO off;
