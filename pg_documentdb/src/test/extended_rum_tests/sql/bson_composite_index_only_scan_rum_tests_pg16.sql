SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 9100;
SET documentdb.next_collection_index_id TO 9100;

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

ALTER TABLE documentdb_data.documents_9101 set (autovacuum_enabled = off);

-- create ordered index on country
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosdb_rum', '{ "createIndexes": "iosc_comp", "indexes": [ { "key": { "country": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "country_1" }] }', true);

VACUUM (ANALYZE ON, FREEZE ON) documentdb_data.documents_9101;

set enable_seqscan to off;
set enable_bitmapscan to off;

-- basic composite index only scan with different operators
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$eq": "USA"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$gt": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$gte": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$lt": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$lte": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- composite index only scan with $group $sum: 1 (count-like accumulator)
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$gte": "Brazil"}} }, { "$group" : { "_id" : "1", "n" : { "$sum" : 1 } } }]}') $$, p_ignore_heap_fetches => true);

-- range query on composite index
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$gt": "Brazil", "$lt": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- count with match + limit uses index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{"$match": { "country": {"$gt": "Brazil", "$lt": "Mexico"} }}, { "$limit": 10 }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{"$match": { "country": {"$gt": "Brazil", "$lt": "Mexico"} }}, { "$limit": 10 }, { "$group": { "_id": 1, "c": { "$sum": 1 } } }]}') $$, p_ignore_heap_fetches => true);

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

-- turning off enableIndexOnlyScanForCoveredAggregateTargets should keep count IOS enabled,
-- but disable the new covered aggregate-target IOS path
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to off;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$lt": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$gte": "Mexico"}} }, { "$group" : { "_id" : "$country", "n" : { "$sum" : 1 } } }]}') $$, p_ignore_heap_fetches => true);
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to on;

-- index only scan with a truncated scan key should work fine
SELECT FORMAT('{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$lt": "%s"}} }, { "$count": "count" }]}', repeat('a', 5000))::bson large_scan_key \gset
PREPARE large_prepare_query AS
SELECT document FROM bson_aggregation_pipeline('iosdb_rum', :'large_scan_key'::bson);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) EXECUTE large_prepare_query $$, p_ignore_heap_fetches => true);

-- force index only scan via GUC
set documentdb.forceIndexOnlyScanIfAvailable to on;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$lt": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
-- forceIndexOnlyScan + uncovered accumulator (provider not in country_1): should NOT use IOS
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$lt": "Mexico"}} }, { "$group" : { "_id" : 1, "maxProvider" : { "$max" : "$provider" } } }]}') $$, p_ignore_heap_fetches => true);
reset documentdb.forceIndexOnlyScanIfAvailable;

-- disable index only scan on cost to go through the legacy path
set documentdb.enableIndexOnlyScanOnCost to off;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$lt": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
-- enableIndexOnlyScanOnCost=off + uncovered accumulator (provider not in country_1): should NOT use IOS
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$lt": "Mexico"}} }, { "$group" : { "_id" : 1, "maxProvider" : { "$max" : "$provider" } } }]}') $$, p_ignore_heap_fetches => true);
reset documentdb.enableIndexOnlyScanOnCost;

-- Multi-key value should prevent index only scan
SELECT documentdb_api.insert_one('iosdb_rum', 'iosc_comp', '{"_id": 17, "country": "Mexico", "provider": ["AWS", "GCP"]}');
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$eq": "Mexico"}, "provider": {"$eq": ["AWS", "GCP"]}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
-- Once the compound index becomes multi-key, even scalar predicates that used to be
-- IOS candidates should fall back to Index Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$eq": "USA"}, "provider": {"$eq": "Azure"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

CALL documentdb_api.drop_indexes('iosdb_rum', '{ "dropIndexes": "iosc_comp", "index": "country_provider_1" }');

-- Truncated data should prevent index only scan
SELECT documentdb_api.insert_one('iosdb_rum', 'iosc_comp', FORMAT('{ "_id": 18, "country": { "key": "%s", "provider": "%s" } }', repeat('a', 10000), repeat('a', 10000))::bson);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$eq": "Mexico"}} }, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- Test index only scan for numeric fields
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 1, "city": "NYC", "sqft": 300, "rent": 3000}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 2, "city": "NYC", "sqft": 400, "rent": 3200}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 3, "city": "NYC", "sqft": 500, "rent": 3500}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 4, "city": "NYC", "sqft": 600, "rent": 2800}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 5, "city": "NYC", "sqft": 700, "rent": 3300}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 6, "city": "NYC", "sqft": 800, "rent": 2000}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 7, "city": "NYC", "sqft": 900, "rent": 2200}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 8, "city": "NYC", "sqft": 1000, "rent": 2500}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 9, "city": "NYC", "sqft": 1100, "rent": 2700}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 10, "city": "Seattle", "sqft": 1200, "rent": 3500}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 11, "city": "Seattle", "sqft": 1300, "rent": 3700}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 12, "city": "Seattle", "sqft": 1400, "rent": 4000}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 13, "city": "Seattle", "sqft": 1500, "rent": 4200}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 14, "city": "Seattle", "sqft": 1600, "rent": 4500}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 15, "city": "Seattle", "sqft": 1700, "rent": 4800}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 16, "city": "Seattle", "sqft": 1800, "rent": 5000}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 17, "city": "Chicago", "sqft": 1900, "rent": 2000}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 18, "city": "Chicago", "sqft": 2000, "rent": 2200}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 19, "city": "Chicago", "sqft": 2100, "rent": 2500}');
SELECT documentdb_api.insert_one('iosdb_rum_numeric', 'rent_data', '{"_id": 20, "city": "Chicago", "sqft": 2200, "rent": 2700}');

-- create index on city and rent
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosdb_rum_numeric', '{ "createIndexes": "rent_data", "indexes": [ { "key": { "city": 1, "rent": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "city_rent_1" }] }', true);
VACUUM (ANALYZE ON, FREEZE ON);

-- NO GROUP BY
-- where city is Seattle and rent > 4000 with a count (no grouping) should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"city": {"$eq": "Seattle"}, "rent": {"$gt": 4000} }}, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- SORT + COUNT (no group by) — tests that sort field coverage is checked, not just aggregates
-- $match + $sort on (city, rent) + $count: both fields in index, should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"city": {"$gte": "A"}} }, { "$sort": {"city": 1, "rent": 1} }, { "$count": "total" }]}') $$, p_ignore_heap_fetches => true);

-- $match + $sort on (city, sqft) + $count: sqft NOT in index, should NOT use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"city": {"$gte": "A"}} }, { "$sort": {"city": 1, "sqft": 1} }, { "$count": "total" }]}') $$, p_ignore_heap_fetches => true);

-- CONSTANT GROUP (aggregate without a grouping key)
-- where city is Seattle and rent > 4000 with a constant-group count should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"city": {"$eq": "Seattle"}, "rent": {"$gt": 4000} }}, { "$group" : { "_id" : 1, "cnt" : { "$count" : {} } } }]}') $$, p_ignore_heap_fetches => true);

-- where city is Seattle and rent > 4000 with a constant-group sum should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"city": {"$eq": "Seattle"}, "rent": {"$gt": 4000} }}, { "$group" : { "_id" : 1, "totalRent" : { "$sum" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- where city is Seattle and rent > 4000 with a constant-group average should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"city": {"$eq": "Seattle"}, "rent": {"$gt": 4000} }}, { "$group" : { "_id" : 1, "avgRent" : { "$avg" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- where city is Seattle and rent > 4000 with a constant-group minimum should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"city": {"$eq": "Seattle"}, "rent": {"$gt": 4000} }}, { "$group" : { "_id" : 1, "minRent" : { "$min" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- where city is Seattle and rent > 4000 with a constant-group maximum should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"city": {"$eq": "Seattle"}, "rent": {"$gt": 4000} }}, { "$group" : { "_id" : 1, "maxRent" : { "$max" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- where city is Seattle with a constant-group average on sqft should NOT use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"city": {"$eq": "Seattle"} }}, { "$group" : { "_id" : 1, "avgSqft" : { "$avg" : "$sqft" } } }]}') $$, p_ignore_heap_fetches => true);

-- HINTED QUERIES (no match / constant group)
-- hint by name + $match + $count: should use IOS
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$match" : {"city": {"$eq": "Seattle"}, "rent": {"$gt": 4000} }}, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- hint by key document + $match + $count: same behavior as hint by name
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "hint" : { "city" : 1, "rent" : 1 }, "pipeline" : [{ "$match" : {"city": {"$eq": "Seattle"}, "rent": {"$gt": 4000} }}, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- hint + no match + $count: fullScan on index should use IOS
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$count": "count" }]}') $$, p_ignore_heap_fetches => true);

-- turning off enableIndexOnlyScanForRangeMatch should keep hinted count IOS enabled
-- when standard quals are used, but disable the new fullScan range-match IOS path
set documentdb.enableIndexOnlyScanForRangeMatch to off;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$match" : {"city": {"$eq": "Seattle"}, "rent": {"$gt": 4000} }}, { "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$count": "count" }]}') $$, p_ignore_heap_fetches => true);
set documentdb.enableIndexOnlyScanForRangeMatch to on;

-- hint + $match + covered sort + $count: should use IOS
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$match" : {"city": {"$gte": "A"}} }, { "$sort": {"city": 1, "rent": 1} }, { "$count": "total" }]}') $$, p_ignore_heap_fetches => true);

-- hint + $match + uncovered sort (sqft) + $count: should NOT use IOS
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$match" : {"city": {"$gte": "A"}} }, { "$sort": {"city": 1, "sqft": 1} }, { "$count": "total" }]}') $$, p_ignore_heap_fetches => true);

-- hint + $match + constant-group $count: should use IOS
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$match" : {"city": {"$eq": "Seattle"}, "rent": {"$gt": 4000} }}, { "$group" : { "_id" : 1, "cnt" : { "$count" : {} } } }]}') $$, p_ignore_heap_fetches => true);

-- hint + no match + constant-group $sum on covered field: fullScan should use IOS
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$group" : { "_id" : 1, "totalRent" : { "$sum" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- hint + no match + constant-group $avg on covered field: fullScan should use IOS
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$group" : { "_id" : 1, "avgRent" : { "$avg" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- hint + no match + constant-group $count: fullScan should use IOS
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$group" : { "_id" : 1, "cnt" : { "$count" : {} } } }]}') $$, p_ignore_heap_fetches => true);

-- hint + $match + uncovered accumulator (sqft): should NOT use IOS
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$match" : {"city": {"$eq": "Seattle"} }}, { "$group" : { "_id" : 1, "avgSqft" : { "$avg" : "$sqft" } } }]}') $$, p_ignore_heap_fetches => true);

-- SORT BEFORE GROUP
-- $sort on uncovered field (sqft) before $group should NOT use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$sort": {"city": 1, "sqft": 1} }, { "$group" : { "_id" : "$city", "firstRent" : { "$first" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- $sort on covered fields before $group with uncovered accumulator (sqft) should NOT use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$sort": {"city": 1, "rent": 1} }, { "$group" : { "_id" : "$city", "firstSqft" : { "$first" : "$sqft" } } }]}') $$, p_ignore_heap_fetches => true);

-- $sort on covered fields before $group with a covered sum should work, but doesn't yet
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$sort": {"city": 1, "rent": 1} }, { "$group" : { "_id" : "$city", "totalRent" : { "$sum" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- $sort on covered fields before $group with a covered count should work, but doesn't yet
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$sort": {"city": 1, "rent": 1} }, { "$group" : { "_id" : "$city", "cnt" : { "$count" : {} } } }]}') $$, p_ignore_heap_fetches => true);

-- $sort on uncovered fields before $group with a covered sum should NOT use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$sort": {"city": 1, "sqft": 1} }, { "$group" : { "_id" : "$city", "totalRent" : { "$sum" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- GROUP BY (AVERAGE)
-- average rent for each city should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "avgRent" : { "$avg" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- average rent for each city with a filter should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"rent": {"$gt": 2000} }}, { "$group" : { "_id" : "$city", "avgRent" : { "$avg" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- average rent for each city with a filter that doesn't match any documents should still use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"rent": {"$gt": 10000} }}, { "$group" : { "_id" : "$city", "avgRent" : { "$avg" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- average rent for each city with a filter on sqft should not use index only scan because sqft is not in the index
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"sqft": {"$gt": 1000} }}, { "$group" : { "_id" : "$city", "avgRent" : { "$avg" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- average rent for each sqft should not use index only scan because sqft is not in the index
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$sqft", "avgRent" : { "$avg" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);   

-- GROUP BY (MIN)
-- minimum rent for each city should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "minRent" : { "$min" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- minimum rent for each city with a filter should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"rent": {"$gt": 2000} }}, { "$group" : { "_id" : "$city", "minRent" : { "$min" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- minimum rent for each city with a filter that doesn't match any documents should still use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"rent": {"$gt": 10000} }}, { "$group" : { "_id" : "$city", "minRent" : { "$min" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- minimum rent for each city with a filter on sqft should not use index only scan because sqft is not in the index
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"sqft": {"$gt": 1000} }}, { "$group" : { "_id" : "$city", "minRent" : { "$min" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- minimum rent for each sqft should not use index only scan because sqft is not in the index
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$sqft", "minRent" : { "$min" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- GROUP BY (MAX)
-- maximum rent for each city should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "maxRent" : { "$max" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- maximum rent for each city with a filter should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"rent": {"$gt": 2000} }}, { "$group" : { "_id" : "$city", "maxRent" : { "$max" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- maximum rent for each sqft should not use index only scan because sqft is not in the index
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$sqft", "maxRent" : { "$max" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- GROUP BY (SUM)
-- total rent for each city should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "totalRent" : { "$sum" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- total rent for each city with a filter should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"rent": {"$gt": 2000} }}, { "$group" : { "_id" : "$city", "totalRent" : { "$sum" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- total sqft for each city should not use index only scan because sqft is not in the index
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "totalSqft" : { "$sum" : "$sqft" } } }]}') $$, p_ignore_heap_fetches => true);

-- GROUP BY (COUNT)
-- count for each city should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "cnt" : { "$count" : {} } } }]}') $$, p_ignore_heap_fetches => true);

-- count for each city with a filter should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"rent": {"$gt": 3000} }}, { "$group" : { "_id" : "$city", "cnt" : { "$count" : {} } } }]}') $$, p_ignore_heap_fetches => true);

-- count for each sqft should not use index only scan because sqft is not in the index
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$sqft", "cnt" : { "$count" : {} } } }]}') $$, p_ignore_heap_fetches => true);

-- GROUP BY (FIRST / LAST)
-- first rent for each city should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "firstRent" : { "$first" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- last rent for each city should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "lastRent" : { "$last" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- first sqft for each city should not use index only scan because sqft is not in the index
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "firstSqft" : { "$first" : "$sqft" } } }]}') $$, p_ignore_heap_fetches => true);

-- last sqft for each city should not use index only scan because sqft is not in the index
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "lastSqft" : { "$last" : "$sqft" } } }]}') $$, p_ignore_heap_fetches => true);

-- MIXED ACCUMULATORS
-- mixed covered accumulators (sum + count + min + max on rent) should use index only scan
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "totalRent" : { "$sum" : "$rent" }, "cnt" : { "$count" : {} }, "minRent" : { "$min" : "$rent" }, "maxRent" : { "$max" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- mixed: one uncovered accumulator should prevent index only scan for the whole query
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "totalRent" : { "$sum" : "$rent" }, "avgSqft" : { "$avg" : "$sqft" } } }]}') $$, p_ignore_heap_fetches => true);

-- representative explain pair for the covered-target IOS GUC
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to off;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "totalRent" : { "$sum" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to on;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "totalRent" : { "$sum" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- CORRECTNESS TESTS (verify actual values with the covered-target IOS GUC off and then on)

-- $count correctness
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to off;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "cnt" : { "$count" : {} } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to on;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "cnt" : { "$count" : {} } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');

-- $sum correctness
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to off;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "totalRent" : { "$sum" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to on;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "totalRent" : { "$sum" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');

-- $avg correctness
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to off;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "avgRent" : { "$avg" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to on;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "avgRent" : { "$avg" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');

-- $min correctness
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to off;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "minRent" : { "$min" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to on;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "minRent" : { "$min" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');

-- $max correctness
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to off;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "maxRent" : { "$max" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to on;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "maxRent" : { "$max" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');

-- $first correctness on the IOS path (no explicit sort; relies on ordered index traversal)
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to off;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "firstRent" : { "$first" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to on;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "firstRent" : { "$first" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');

-- $last correctness on the IOS path (no explicit sort; relies on ordered index traversal)
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to off;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "lastRent" : { "$last" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to on;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "lastRent" : { "$last" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');

-- sorted $first correctness (use explicit sort so the selected value is deterministic)
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to off;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$sort": {"city": 1, "rent": 1} }, { "$group" : { "_id" : "$city", "firstRent" : { "$first" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to on;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$sort": {"city": 1, "rent": 1} }, { "$group" : { "_id" : "$city", "firstRent" : { "$first" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');
set documentdb.enableSortGroupStage to off;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$sort": {"city": 1, "rent": 1} }, { "$group" : { "_id" : "$city", "firstRent" : { "$first" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');
set documentdb.enableSortGroupStage to on;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$sort": {"city": 1, "rent": 1} }, { "$group" : { "_id" : "$city", "firstRent" : { "$first" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');

-- sorted $last correctness (use explicit sort so the selected value is deterministic)
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to off;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$sort": {"city": 1, "rent": 1} }, { "$group" : { "_id" : "$city", "lastRent" : { "$last" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to on;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$sort": {"city": 1, "rent": 1} }, { "$group" : { "_id" : "$city", "lastRent" : { "$last" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');
set documentdb.enableSortGroupStage to off;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$sort": {"city": 1, "rent": 1} }, { "$group" : { "_id" : "$city", "lastRent" : { "$last" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');
set documentdb.enableSortGroupStage to on;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$sort": {"city": 1, "rent": 1} }, { "$group" : { "_id" : "$city", "lastRent" : { "$last" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');

-- mixed accumulators correctness
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to off;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "totalRent" : { "$sum" : "$rent" }, "cnt" : { "$count" : {} }, "minRent" : { "$min" : "$rent" }, "maxRent" : { "$max" : "$rent" }, "avgRent" : { "$avg" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to on;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : "$city", "totalRent" : { "$sum" : "$rent" }, "cnt" : { "$count" : {} }, "minRent" : { "$min" : "$rent" }, "maxRent" : { "$max" : "$rent" }, "avgRent" : { "$avg" : "$rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');

-- missing covered aggregate target should match heap semantics
SELECT documentdb_api.insert_one('iosdb_rum_missing', 'rent_data', '{"_id": 1, "city": "Seattle"}');
SELECT documentdb_api.insert_one('iosdb_rum_missing', 'rent_data', '{"_id": 2, "city": "Seattle", "rent": 1000}');
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosdb_rum_missing', '{ "createIndexes": "rent_data", "indexes": [ { "key": { "city": 1, "rent": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "city_rent_1" }] }', true);
VACUUM (ANALYZE ON, FREEZE ON);
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to off;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_missing', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$match" : {"city": "Seattle"} }, { "$group" : { "_id" : "$rent", "n" : { "$sum" : 1 } } }, { "$sort" : {"_id" : 1} }], "cursor" : {}}');
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to on;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_missing', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$match" : {"city": "Seattle"} }, { "$group" : { "_id" : "$rent", "n" : { "$sum" : 1 } } }, { "$sort" : {"_id" : 1} }], "cursor" : {}}') $$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_missing', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$match" : {"city": "Seattle"} }, { "$group" : { "_id" : "$rent", "n" : { "$sum" : 1 } } }, { "$sort" : {"_id" : 1} }], "cursor" : {}}');

-- GROUP BY (DOTTED PATHS)
-- Verify that $group with dotted-path index keys uses index only scan and
-- that the dotted-path reconstruction produces correct grouped results.
SELECT documentdb_api.insert_one('iosdb_rum_dotted', 'rent_data', '{"_id": 1, "addr": {"city": "Seattle", "rent": 4000}, "sqft": 1500}');
SELECT documentdb_api.insert_one('iosdb_rum_dotted', 'rent_data', '{"_id": 2, "addr": {"city": "Seattle", "rent": 4500}, "sqft": 1600}');
SELECT documentdb_api.insert_one('iosdb_rum_dotted', 'rent_data', '{"_id": 3, "addr": {"city": "Seattle", "rent": 5000}, "sqft": 1700}');
SELECT documentdb_api.insert_one('iosdb_rum_dotted', 'rent_data', '{"_id": 4, "addr": {"city": "NYC", "rent": 3000}, "sqft": 800}');
SELECT documentdb_api.insert_one('iosdb_rum_dotted', 'rent_data', '{"_id": 5, "addr": {"city": "NYC", "rent": 3500}, "sqft": 900}');
SELECT documentdb_api.insert_one('iosdb_rum_dotted', 'rent_data', '{"_id": 6, "addr": {"city": "Chicago", "rent": 2000}, "sqft": 1000}');
SELECT documentdb_api.insert_one('iosdb_rum_dotted', 'rent_data', '{"_id": 7, "addr": {"city": "Chicago", "rent": 2500}, "sqft": 1100}');
SELECT documentdb_api.insert_one('iosdb_rum_dotted', 'rent_data', '{"_id": 8, "addr": {"city": "Chicago", "rent": 2800}, "sqft": 1200}');
-- Doc with deeper nesting (addr.geo.zip) for the 3-level dotted index test.
SELECT documentdb_api.insert_one('iosdb_rum_dotted', 'rent_data', '{"_id": 9, "addr": {"city": "Seattle", "rent": 4200, "geo": {"zip": "98101"}}, "sqft": 1500}');
SELECT documentdb_api.insert_one('iosdb_rum_dotted', 'rent_data', '{"_id": 10, "addr": {"city": "NYC", "rent": 3200, "geo": {"zip": "10001"}}, "sqft": 950}');

SELECT documentdb_api_internal.create_indexes_non_concurrently('iosdb_rum_dotted', '{ "createIndexes": "rent_data", "indexes": [ { "key": { "addr.city": 1, "addr.rent": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "addr_city_rent_1" }] }', true);
VACUUM (ANALYZE ON, FREEZE ON);

-- D-G1: $group by dotted _id with $count, no $match. Index addr_city_rent_1
-- covers both keys, so this should use IOS and produce one row per city.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "hint" : "addr_city_rent_1", "pipeline" : [{ "$group" : { "_id" : "$addr.city", "cnt" : { "$count" : {} } } }, { "$sort": {"_id": 1} }]}') $$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "hint" : "addr_city_rent_1", "pipeline" : [{ "$group" : { "_id" : "$addr.city", "cnt" : { "$count" : {} } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');

-- D-G2: $group by dotted _id with covered $sum/$avg/$min/$max on dotted accumulator.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "hint" : "addr_city_rent_1", "pipeline" : [{ "$group" : { "_id" : "$addr.city", "totalRent" : { "$sum" : "$addr.rent" }, "avgRent" : { "$avg" : "$addr.rent" }, "minRent" : { "$min" : "$addr.rent" }, "maxRent" : { "$max" : "$addr.rent" } } }, { "$sort": {"_id": 1} }]}') $$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "hint" : "addr_city_rent_1", "pipeline" : [{ "$group" : { "_id" : "$addr.city", "totalRent" : { "$sum" : "$addr.rent" }, "avgRent" : { "$avg" : "$addr.rent" }, "minRent" : { "$min" : "$addr.rent" }, "maxRent" : { "$max" : "$addr.rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');

-- D-G3: $match on dotted leading key + $group with covered accumulator.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"addr.city": {"$eq": "Seattle"}} }, { "$group" : { "_id" : "$addr.city", "totalRent" : { "$sum" : "$addr.rent" } } }]}') $$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"addr.city": {"$eq": "Seattle"}} }, { "$group" : { "_id" : "$addr.city", "totalRent" : { "$sum" : "$addr.rent" } } }]}');

-- D-G4: $match on dotted non-leading key + $group with covered accumulator.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "hint" : "addr_city_rent_1", "pipeline" : [{ "$match" : {"addr.rent": {"$gt": 3000}} }, { "$group" : { "_id" : "$addr.city", "cnt" : { "$count" : {} } } }, { "$sort": {"_id": 1} }]}') $$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "hint" : "addr_city_rent_1", "pipeline" : [{ "$match" : {"addr.rent": {"$gt": 3000}} }, { "$group" : { "_id" : "$addr.city", "cnt" : { "$count" : {} } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');

-- D-G5: $group _id is the parent path of an index key. The index covers
-- `addr.city`, but a projection or grouping by `addr` (the parent) needs
-- the entire `addr` sub-document, which the index does not cover. Should
-- NOT use IOS.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "hint" : "addr_city_rent_1", "pipeline" : [{ "$group" : { "_id" : "$addr", "cnt" : { "$count" : {} } } }]}') $$, p_ignore_heap_fetches => true);

-- D-G6: $group with an uncovered accumulator (sqft is not in the index).
-- Should NOT use IOS.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "hint" : "addr_city_rent_1", "pipeline" : [{ "$group" : { "_id" : "$addr.city", "avgSqft" : { "$avg" : "$sqft" } } }]}') $$, p_ignore_heap_fetches => true);

-- D-G7: compound _id built as an object expression with two dotted fields
-- that are both individually covered by the index. Today the IOS aggregate
-- target push only recognises flat "$path" expressions, so the whole-object
-- `_id` shape falls back to a regular Index Scan even though every leaf
-- path it references is covered. Tracked as a known gap; correctness is
-- still verified.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "hint" : "addr_city_rent_1", "pipeline" : [{ "$group" : { "_id" : { "city": "$addr.city", "rent": "$addr.rent" }, "cnt" : { "$count" : {} } } }, { "$sort": {"_id.city": 1, "_id.rent": 1} }]}') $$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "hint" : "addr_city_rent_1", "pipeline" : [{ "$group" : { "_id" : { "city": "$addr.city", "rent": "$addr.rent" }, "cnt" : { "$count" : {} } } }, { "$sort": {"_id.city": 1, "_id.rent": 1} }], "cursor" : {}}');

-- D-G8: deep dotted index (3 levels). Same coverage rules - $group on
-- addr.geo.zip is covered if the index has that exact path.
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosdb_rum_dotted', '{ "createIndexes": "rent_data", "indexes": [ { "key": { "addr.city": 1, "addr.geo.zip": 1 }, "storageEngine": { "enableOrderedIndex": true }, "name": "addr_city_geo_zip_1" }] }', true);
VACUUM (ANALYZE ON, FREEZE ON);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "hint" : "addr_city_geo_zip_1", "pipeline" : [{ "$match" : {"addr.city": {"$eq": "Seattle"}} }, { "$group" : { "_id" : "$addr.geo.zip", "cnt" : { "$count" : {} } } }, { "$sort": {"_id": 1} }]}') $$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "hint" : "addr_city_geo_zip_1", "pipeline" : [{ "$match" : {"addr.city": {"$eq": "Seattle"}} }, { "$group" : { "_id" : "$addr.geo.zip", "cnt" : { "$count" : {} } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');

-- D-G9: correctness parity with the covered-target IOS GUC off vs on for
-- a dotted-path $group. Both runs must produce identical output.
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to off;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "hint" : "addr_city_rent_1", "pipeline" : [{ "$group" : { "_id" : "$addr.city", "totalRent" : { "$sum" : "$addr.rent" }, "cnt" : { "$count" : {} }, "minRent" : { "$min" : "$addr.rent" }, "maxRent" : { "$max" : "$addr.rent" }, "avgRent" : { "$avg" : "$addr.rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to on;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "hint" : "addr_city_rent_1", "pipeline" : [{ "$group" : { "_id" : "$addr.city", "totalRent" : { "$sum" : "$addr.rent" }, "cnt" : { "$count" : {} }, "minRent" : { "$min" : "$addr.rent" }, "maxRent" : { "$max" : "$addr.rent" }, "avgRent" : { "$avg" : "$addr.rent" } } }, { "$sort": {"_id": 1} }], "cursor" : {}}');

-- GROUP BY WITHOUT ACCUMULATORS
-- Distinct-style $group (no accumulator). When the grouping key is covered by
-- the secondary index and the $match produces an equality (single-key) qual,
-- the plan should use Index Only Scan. Range quals and hint-only fullScan
-- variants today fall back to a regular Index Scan even when the grouping key
-- is covered; these are tracked as known gaps.

-- NG1: leading-key _id covered by compound index city_rent_1 with equality
-- $match. Plan should use Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"city": {"$eq": "Seattle"}} }, { "$group" : { "_id" : "$city" } }]}') $$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"city": {"$eq": "Seattle"}} }, { "$group" : { "_id" : "$city" } }], "cursor" : {}}');

-- NG2: dotted _id covered by addr_city_rent_1; equality $match. IOS.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"addr.city": {"$eq": "Seattle"}} }, { "$group" : { "_id" : "$addr.city" } }]}') $$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_dotted', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"addr.city": {"$eq": "Seattle"}} }, { "$group" : { "_id" : "$addr.city" } }], "cursor" : {}}');

-- NG3: uncovered _id (sqft is not in city_rent_1) should NOT use IOS even with
-- an equality $match and hint, because the grouping key isn't covered.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$match" : {"city": {"$eq": "Seattle"}} }, { "$group" : { "_id" : "$sqft" } }]}') $$, p_ignore_heap_fetches => true);

-- NG4: correctness parity with enableIndexOnlyScanForCoveredAggregateTargets
-- off vs on for a no-accumulator $group. Both runs must produce identical output.
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to off;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"city": {"$eq": "Seattle"}} }, { "$group" : { "_id" : "$city" } }], "cursor" : {}}');
set documentdb.enableIndexOnlyScanForCoveredAggregateTargets to on;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$match" : {"city": {"$eq": "Seattle"}} }, { "$group" : { "_id" : "$city" } }], "cursor" : {}}');

-- NG5: range $match + no-accumulator $group on a covered key. The country_1
-- index on this collection has a truncated entry (doc _id:18 above is truncated)
-- so we can't do index only scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$gte": "Mexico"}} }, { "$group" : { "_id" : "$country" } }, { "$sort": {"_id": 1} }]}') $$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate" : "iosc_comp", "pipeline" : [{ "$match" : {"country": {"$gte": "Mexico"}} }, { "$group" : { "_id" : "$country" } }, { "$sort": {"_id": 1} }], "cursor" : {}}');

-- NG6: hint-only (no $match) + no-accumulator $group on a non-leading
-- covered key. Plan should use Index Only Scan.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$group" : { "_id" : "$rent" } }, { "$sort": {"_id": 1} }]}') $$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$group" : { "_id" : "$rent" } }, { "$sort": {"_id": 1} }], "cursor" : {}}');

-- NG7 (known gap): whole-object _id { city: "$city", rent: "$rent" } - both
-- leaf paths are individually covered by city_rent_1, but the IOS aggregate
-- target push only recognises flat "$path" expressions today. Falls back to
-- a regular Index Scan; correctness is still verified.
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$group" : { "_id" : { "city": "$city", "rent": "$rent" } } }, { "$sort": {"_id.city": 1, "_id.rent": 1} }]}') $$, p_ignore_heap_fetches => true);
SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "hint" : "city_rent_1", "pipeline" : [{ "$group" : { "_id" : { "city": "$city", "rent": "$rent" } } }, { "$sort": {"_id.city": 1, "_id.rent": 1} }], "cursor" : {}}');

-- KNOWN INDEX ONLY SCAN GAPS (should work, but doesn't yet)
-- Without a $match or hint, the planner has no reason to pick the secondary index.
-- In the future, accumulator-only pipelines should be able to use IOS via aggregate pushdown.
-- $count is omitted because it already gets an index-driven path without a hint.
-- no match + constant-group $sum on covered field: no IOS without a hint or filter
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : 1, "totalRent" : { "$sum" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- no match + constant-group $avg on covered field: no IOS without a hint or filter
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$group" : { "_id" : 1, "avgRent" : { "$avg" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- TODO: Explicit sorted $first/$last on covered fields should work, but don't yet,
-- because this path is lowered as bson_expression_get(bsonfirst/bsonlast(document,
-- sortArrayConst), ...) instead of the single-path accumulator shape
-- handled by the index only scan coverage walker today.
set documentdb.enableSortGroupStage to off;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$sort": {"city": 1, "rent": 1} }, { "$group" : { "_id" : "$city", "firstRent" : { "$first" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$sort": {"city": 1, "rent": 1} }, { "$group" : { "_id" : "$city", "lastRent" : { "$last" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);
set documentdb.enableSortGroupStage to on;
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$sort": {"city": 1, "rent": 1} }, { "$group" : { "_id" : "$city", "firstRent" : { "$first" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);
SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum_numeric', '{ "aggregate" : "rent_data", "pipeline" : [{ "$sort": {"city": 1, "rent": 1} }, { "$group" : { "_id" : "$city", "lastRent" : { "$last" : "$rent" } } }]}') $$, p_ignore_heap_fetches => true);

-- =============================================================================
-- Test: $sum with constant value uses index only scan with a hinted compound
-- index.
-- =============================================================================
SELECT documentdb_api.create_collection('iosdb_rum', 'sum_const_test');
SELECT documentdb_api_internal.create_indexes_non_concurrently('iosdb_rum', '{ "createIndexes": "sum_const_test", "indexes": [ { "key": { "region": 1, "dept": 1, "level": 1, "tag": 1 }, "name": "region_1_dept_1_level_1_tag_1", "enableOrderedIndex": true } ] }', true);

SELECT COUNT(documentdb_api.insert_one('iosdb_rum', 'sum_const_test', FORMAT('{ "_id": %s, "region": 100, "dept": 20, "level": 5, "tag": "tag-%s" }', i, i % 3)::documentdb_core.bson)) FROM generate_series(1, 100) i;

SET documentdb.enableIndexOnlyScanForCoveredAggregateTargets TO on;

-- Result correctness must hold both with the legacy $sum accumulator and the
-- new with-expr accumulator path; both runs should produce the same counts.
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate": "sum_const_test", "pipeline": [ { "$match": { "region": 100, "dept": 20, "level": 5 } }, { "$group": { "_id": "$tag", "count": { "$sum": 1 } } }, { "$sort": { "_id": 1 } } ], "cursor": {}, "hint": "region_1_dept_1_level_1_tag_1" }');
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate": "sum_const_test", "pipeline": [ { "$match": { "region": 100, "dept": 20, "level": 5 } }, { "$group": { "_id": "$tag", "count": { "$sum": 1 } } }, { "$sort": { "_id": 1 } } ], "cursor": {}, "hint": "region_1_dept_1_level_1_tag_1" }');

SELECT documentdb_test_helpers.run_explain_and_trim($$ EXPLAIN (ANALYZE ON, COSTS OFF, BUFFERS OFF, VERBOSE ON, TIMING OFF, SUMMARY OFF) SELECT document FROM bson_aggregation_pipeline('iosdb_rum', '{ "aggregate": "sum_const_test", "pipeline": [ { "$match": { "region": 100, "dept": 20, "level": 5 } }, { "$group": { "_id": "$tag", "count": { "$sum": 1 } } } ], "cursor": {}, "hint": "region_1_dept_1_level_1_tag_1" }') $$, p_ignore_heap_fetches => true);

RESET documentdb.enableIndexOnlyScanForCoveredAggregateTargets;
RESET documentdb.enableNewWithExprAccumulators;
SELECT documentdb_api.drop_collection('iosdb_rum', 'sum_const_test');
