SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 1064000;
SET documentdb.next_collection_id TO 10640;
SET documentdb.next_collection_index_id TO 10640;

set enable_seqscan TO on;
set documentdb.forceUseIndexIfAvailable to on;
set documentdb.forceDisableSeqScan to off;

SELECT documentdb_api.drop_collection('comp_elmdb', 'cmp_elemmatch_ops') IS NOT NULL;
SELECT documentdb_api.create_collection('comp_elmdb', 'cmp_elemmatch_ops') IS NOT NULL;

SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_elmdb',
    '{ "createIndexes": "cmp_elemmatch_ops", "indexes": [ { "key": { "price": 1 }, "name": "price_1", "enableCompositeTerm": true }, { "key": { "brands": 1 }, "name": "brands_1", "enableCompositeTerm": true } ] }', TRUE);
SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_elmdb',
    '{ "createIndexes": "cmp_elemmatch_ops", "indexes": [ { "key": { "brands.name": 1 }, "name": "brands.name_1", "enableCompositeTerm": true }, { "key": { "brands.rating": 1 }, "name": "brands.rating_1", "enableCompositeTerm": true } ] }', TRUE);

SELECT documentdb_api.insert_one('comp_elmdb', 'cmp_elemmatch_ops', '{ "_id": 1, "price": [ 120, 150, 100 ] }');
SELECT documentdb_api.insert_one('comp_elmdb', 'cmp_elemmatch_ops', '{ "_id": 2, "price": [ 110, 140, 160 ] }');

-- pushes to the price index
set documentdb.enableExtendedExplainPlans to on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('comp_elmdb',
    '{ "find": "cmp_elemmatch_ops", "filter": { "price": { "$elemMatch": { "$gt": 120, "$lt": 150 } } } }') $cmd$);

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('comp_elmdb',
    '{ "find": "cmp_elemmatch_ops", "filter": { "price": { "$elemMatch": { "$in": [ 120, 140 ], "$gt": 121 } } } }') $cmd$);

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('comp_elmdb',
    '{ "find": "cmp_elemmatch_ops", "filter": { "price": { "$elemMatch": { "$type": "number" } } } }') $cmd$);

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('comp_elmdb',
    '{ "find": "cmp_elemmatch_ops", "filter": { "price": { "$elemMatch": { "$ne": 160 } } } }') $cmd$);

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('comp_elmdb',
    '{ "find": "cmp_elemmatch_ops", "filter": { "price": { "$elemMatch": { "$nin": [ 160, 110, 140] } } } }') $cmd$);

-- now test some with nested objects
SELECT documentdb_api.insert_one('comp_elmdb', 'cmp_elemmatch_ops', '{ "_id": 3, "brands": [ { "name" : "alpha", "rating" : 5 }, { "name" : "beta", "rating" : 3 } ] }');
SELECT documentdb_api.insert_one('comp_elmdb', 'cmp_elemmatch_ops', '{ "_id": 4, "brands": [ { "name" : "alpha", "rating" : 4 }, { "name" : "beta", "rating" : 2 } ] }');
SELECT documentdb_api.insert_one('comp_elmdb', 'cmp_elemmatch_ops', '{ "_id": 5, "brands": [ { "name" : "alpha", "rating" : 2 }, { "name" : "beta", "rating" : 4 } ] }');

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('comp_elmdb',
    '{ "find": "cmp_elemmatch_ops", "filter": { "brands": { "$elemMatch": { "name": "alpha", "rating": 2 } } } }') $cmd$);

SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('comp_elmdb',
    '{ "find": "cmp_elemmatch_ops", "filter": { "brands": { "$elemMatch": { "name": "alpha" } } } }') $cmd$);

-- test elemMatch behavior when confronted with multiple arrays
SELECT documentdb_api.insert_one('comp_elmdb', 'cmp_elemmatch_ops', '{ "_id": 6, "brands": [ { "name": [ "gurci", "dolte" ], "rating": 5 } ]}');

-- this technically matches the doc 6 above and the elemMatches don't get joined.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('comp_elmdb',
    '{ "find": "cmp_elemmatch_ops", "filter": { "brands": { "$elemMatch": { "name": { "$gt": "gabba", "$lt": "ergo" } } } } }') $cmd$);

-- this can now join the elemMatch filters
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('comp_elmdb',
    '{ "find": "cmp_elemmatch_ops", "filter": { "brands.name": { "$elemMatch": { "$gt": "gabba", "$lt": "ergo" } } } }') $cmd$);

-- disjoint filter handling for elemMatch and non elemMatch: this matches a document since these are matching different elements of the array.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF, ANALYZE ON, TIMING OFF, SUMMARY OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_find('comp_elmdb',
    '{ "find": "cmp_elemmatch_ops", "filter": { "price": { "$eq": 110, "$elemMatch": { "$gt": 155, "$lt": 165 } } } }') $cmd$);


-- test scenarios with prefix index and suffix object filters
SELECT COUNT(documentdb_api.insert_one('comp_elmdb', 'setup_1', 
    FORMAT('{ "_id": %s, "orgId": "8970674054893216127", "delFlag": 1, "state": 1, "workflowNodeList": [ { "nodePersonList": [ { "state": 4, "delFlag": 1, "personId": "5521063216615886977" } ] }] }', i)::bson)) FROM generate_series(1, 1000) i;

SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_elmdb',
    '{ "createIndexes": "setup_1", "indexes": [ { "key": { "orgId": 1, "delFlag": 1, "state": 1, "workFlowNodeList.nodePersonList.personId": 1, "workFlowNodeList.nodePersonList.state": 1, "workFlowNodeList.nodePersonList.delFlag": 1, "name": 1 }, "name": "idx2", "enableOrderedIndex": true } ] }', TRUE);

ANALYZE documentdb_data.documents_10642;
EXPLAIN (VERBOSE ON, COSTS OFF, VERBOSE ON) SELECT document from bson_aggregation_find('comp_elmdb',
    '{ "find": "setup_1", "filter": { "orgId": { "$in": [ "8970674054893216127", "7368253168030687073" ] }, "delFlag": 1, "state": { "$in": [ 1, 2, 3 ] }, "workFlowNodeList.nodePersonList": { "$elemMatch": { "personId": "5521063216615886977", "state": 4, "delFlag": 1 } } } }');

SELECT documentdb_api_internal.create_indexes_non_concurrently('comp_elmdb',
    '{ "createIndexes": "setup_1", "indexes": [ { "key": {"orgId": 1, "delFlag": 1, "state":1, "createTime": -1 }, "name": "idx1", "enableOrderedIndex": true } ] }', TRUE);

-- picks idx1 due to cost function being equivalent.
ANALYZE documentdb_data.documents_10642;
EXPLAIN (VERBOSE ON, COSTS OFF, VERBOSE ON) SELECT document from bson_aggregation_find('comp_elmdb',
    '{ "find": "setup_1", "filter": { "orgId": { "$in": [ "8970674054893216127", "7368253168030687073" ] }, "delFlag": 1, "state": { "$in": [ 1, 2, 3 ] }, "workFlowNodeList.nodePersonList": { "$elemMatch": { "personId": "5521063216615886977", "state": 4, "delFlag": 1 } } } }');

set enable_seqscan to off;
set enable_bitmapscan to off;
set documentdb.enablecompositeindexplanner to on;

-- TODO: We need to ensure the costing of rum indexes with composite works better here.
SELECT documentdb_distributed_test_helpers.drop_primary_key('comp_elmdb', 'setup_1');
EXPLAIN (VERBOSE ON, COSTS OFF, VERBOSE ON) SELECT document from bson_aggregation_find('comp_elmdb',
    '{ "find": "setup_1", "filter": { "orgId": { "$in": [ "8970674054893216127", "7368253168030687073" ] }, "delFlag": 1, "state": { "$in": [ 1, 2, 3 ] }, "workFlowNodeList.nodePersonList": { "$elemMatch": { "personId": "5521063216615886977", "state": 4, "delFlag": 1 } } } }');
