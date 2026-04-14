SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 9000;
SET documentdb.next_collection_index_id TO 9000;

-- Tests for composite on non-primary key

select documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 1, "country": "USA", "provider": "AWS"}');
select documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 2, "country": "USA", "provider": "Azure"}');
select documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 3, "country": "Mexico", "provider": "GCP"}');
select documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 4, "country": "India", "provider": "AWS"}');
select documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 5, "country": "Brazil", "provider": "Azure"}');
select documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 6, "country": "Brazil", "provider": "GCP"}');
select documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 7, "country": "Mexico", "provider": "AWS"}');
select documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 8, "country": "USA", "provider": "Azure"}');
select documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 9, "country": "India", "provider": "GCP"}');
select documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 10, "country": "Mexico", "provider": "AWS"}');
select documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 11, "country": "USA", "provider": "Azure"}');
select documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 12, "country": "Spain", "provider": "GCP"}');
select documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 13, "country": "Italy", "provider": "AWS"}');
select documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 14, "country": "France", "provider": "Azure"}');
select documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 15, "country": "France", "provider": "GCP"}');
select documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 16, "country": "Mexico", "provider": "AWS"}');

ALTER TABLE documentdb_data.documents_9001 set (autovacuum_enabled = off);

-- create composite ordered index on country
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosdb_rum', '{ "createIndexes": "iosc_comp", "indexes": [ { "key": { "country": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "country_1" }] }', true);

VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_9001;

set enable_seqscan to off;
set enable_bitmapscan to off;

-- basic composite index only scan with different operators
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$eq": "USA"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$gt": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$gte": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$lt": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$lte": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- composite index only scan with $group sum
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$gte": "Brazil"}} }, { "$group" : { "_id" : "1", "n" : { "$sum" : 1 } } }]}') $$, p_ignore_heap_fetches => true);

-- range query on composite index
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$gt": "Brazil"}, "country": {"$lt": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- count with match + limit uses index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{"$match": { "country": {"$gt": "Brazil"}, "country": {"$lt": "Mexico"} }}, { "$limit": 10 }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{"$match": { "country": {"$gt": "Brazil"}, "country": {"$lt": "Mexico"} }}, { "$limit": 10 }, { "$group": { "_id": 1, "c": { "$sum": 1 } } }]}') $$, p_ignore_heap_fetches => true);

-- index only scan respects the enable_indexonlyscan guc 
set enable_indexonlyscan to off;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{"$match": { "country": {"$gt": "Brazil"}, "country": {"$lt": "Mexico"} }}, { "$limit": 10 }, { "$group": { "_id": 1, "c": { "$sum": 1 } } }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{"$match": { "_id": {"$gt": 3} } }, { "$limit": 10 }, { "$group": { "_id": 1, "c": { "$sum": 1 } } }]}') $$, p_ignore_heap_fetches => true);
reset enable_indexonlyscan;

SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{"$match": { "_id": {"$gt": 3} } }, { "$limit": 10 }, { "$group": { "_id": 1, "c": { "$sum": 1 } } }]}') $$, p_ignore_heap_fetches => true);

-- compound index

SELECT documentdb_api_internal.create_indexes_non_concurrently('iosdb_rum', '{ "createIndexes": "iosc_comp", "indexes": [ { "key": { "country": 1, "provider": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "country_provider_1" }] }', true);

-- compound index with both fields matched should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$eq": "Mexico"}, "provider": {"$eq": "AWS"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$eq": "Mexico"}, "provider": {"$eq": "AWS"}} }, { "$count": "count" }]}');

SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$eq": "Mexico"}, "provider": {"$eq": "GCP"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$eq": "Mexico"}, "provider": {"$eq": "GCP"}} }, { "$count": "count" }]}');

-- query on non-leading field only should not use the compound index for index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"provider": {"$eq": "AWS"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- Unsupported operators because need runtime recheck

-- $ne, $type, $size, $elemMatch should not use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$ne": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$type": "string"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$size": 2}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$elemMatch": {"$eq": "Mexico"}}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- null/empty array and mixed $in predicates need runtime recheck and should not use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$eq": null}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$eq": []}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$in": ["USA", null]}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$in": ["USA", []]}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- turning off enableIndexOnlyScan should prevent index only scan
set documentdb.enableIndexOnlyScan to off;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$lt": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
set documentdb.enableIndexOnlyScan to on;

-- indexonly scan with a truncated scan key should work fine
SELECT FORMAT('{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$lt": "%s"}} }, { "$count": "count" }]}', repeat('a', 5000))::bson large_scan_key \gset
PREPARE large_prepare_query AS
SELECT document FROM bson_aggregation_pipeline('iosdb_rum', :'large_scan_key'::bson);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) EXECUTE large_prepare_query $$, p_ignore_heap_fetches => true);

-- force index only scan via GUC
set documentdb.forceIndexOnlyScanIfAvailable to on;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$lt": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
reset documentdb.forceIndexOnlyScanIfAvailable;

-- disable index only scan on cost to go through the legacy path
set documentdb.enableIndexOnlyScanOnCost to off;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$lt": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
reset documentdb.enableIndexOnlyScanOnCost;

-- Multi-key value should prevent index only scan
SELECT documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 17, "country": "Mexico", "provider": ["AWS", "GCP"]}');
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$eq": "Mexico"}, "provider": {"$eq": ["AWS", "GCP"]}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

CALL documentdb_api.drop_indexes('iosdb_rum', '{ "dropIndexes": "iosc_comp", "index": "country_provider_1" }');

-- Truncated data should prevent index only scan
SELECT documentdb_api.insert_one('iosdb_rum', 'iosc_comp', FORMAT('{ "_id": 18, "country": { "key": "%s", "provider": "%s" } }', repeat('a', 10000), repeat('a', 10000))::bson);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$eq": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
