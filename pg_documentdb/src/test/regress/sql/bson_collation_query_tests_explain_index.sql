SET citus.next_shard_id TO 8460000;
SET documentdb.next_collection_id TO 8800;
SET documentdb.next_collection_index_id TO 8800;

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.enableExtendedExplainPlans TO on;
SET enable_seqscan TO OFF;

-- ======================================================================
-- SECTION 1: Setup — coll_array_filter inserts
-- ======================================================================
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 1, "a": "Cat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 2, "a": "dog" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 3, "a": "cat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 4, "a": "Dog" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 5, "a": "caT" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 6, "a": "doG" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 7, "a": "goat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 8, "a": "Goat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 9, "b": "Cat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 10, "b": "dog" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 11, "b": "cat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 12, "b": "Dog" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 13, "b": "caT", "a" : "raBbIt" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 14, "b": "doG" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 15, "b": "goat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 16, "b": "Goat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 17, "a": ["Cat", "CAT", "dog"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 18, "a": ["dog", "cat", "CAT"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 19, "a": ["cat", "rabbit", "bAt"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 20, "a": ["Cat"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 21, "a": ["dog"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 22, "a": ["cat"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 23, "a": ["CAT"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 24, "a": ["cAt"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 25, "a": { "b" : "cAt"} }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_array_filter', '{ "_id": 26, "a": [{ "b": "CAT"}] }');

-- ======================================================================
-- SECTION 2: Aggregation on arrays with collation
-- ======================================================================
-- (6.B)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_array_filter", "pipeline": [ { "$sort": { "_id": 1 } }, { "$addFields": { "e": {  "f": "$a" } } }, { "$replaceRoot": { "newRoot": "$e" } }, { "$match" : { "f": { "$elemMatch": {"$eq": "cAt"} } } }, {"$project": { "items" : { "$filter" : { "input" : "$f", "as" : "animal", "cond" : { "$eq" : ["$$animal", "CAT"] } }} }} ],
 "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);

-- ======================================================================
-- SECTION 3: $expr and ICU locale semantics
-- ======================================================================
-- $expr
SELECT documentdb_api.insert_one('coll_q_db', 'coll_agg_proj', '{ "_id": 1, "a": "cat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_agg_proj', '{ "_id": 2, "a": "dog" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_agg_proj', '{ "_id": 3, "a": "cAt" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_agg_proj', '{ "_id": 4, "a": "dOg" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_agg_proj', '{ "_id": "hen", "a": "hen" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_agg_proj', '{ "_id": "bat", "a": "bat" }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "hi", "strength" : 2 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$ne": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "fi", "strength" : 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$lte": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$gte": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "fr", "strength" : 3 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$gte": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "fr_CA", "strength" : 3 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$gte": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "es@collation=search", "strength" : 3 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$gt": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "fr", "strength" : 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": { "$or": [{"$gte": [ "$a", "DOG" ]}, {"$gte": [ "$a", "CAT" ]}] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "fr", "strength" : 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": { "$and": [{"$lte": [ "$a", "DOG" ]}, {"$lte": [ "$a", "CAT" ]}] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "fr", "strength" : 2 } }')
$cmd$);

-- en_US_POSIX uses a c-style comparison. POSIX locale ignores case insensitivity. This is the ICU semantics.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": ["$a", "cat"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en_US_POSIX", "strength" : 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en_US_POSIX", "strength" : 1 } }')
$cmd$);

-- simple collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj",  "filter": { "$expr": {"$eq": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "simple"} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj",  "filter": { "$expr": {"$eq": ["$a", "cat"]} }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "simple"} }')
$cmd$);

-- simple locale ignores other options
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj",  "filter": { "$expr": {"$eq": ["$a", "cat"]} }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "simple", "strength": 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj",  "filter": { "$expr": {"$eq": ["$a", "cat"]} }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "simple", "strength": 3} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj",  "filter": { "$expr": {"$eq": ["$a", "cat"]} }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "simple", "caseFirst": "upper"} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj",  "filter": { "$expr": {"$eq": ["$a", "cat"]} }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "simple", "caseFirst": "lower"} }')
$cmd$);

-- ======================================================================
-- SECTION 4: Aggregation expression operators with collation
-- ======================================================================
-- support for $filter
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": { "$eq": [["$a"], { "$filter": { "input": ["$a"], "as": "item", "cond": { "$eq": [ "$$item", "CAT" ] } } } ] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": { "$eq": [["$a"], { "$filter": { "input": ["$a"], "as": "item", "cond": { "$eq": [ "$$item", "CAT" ] } } } ] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": { "$eq": [["$a"], { "$filter": { "input": ["$a"], "as": "item", "cond": { "$ne": [ "$$item", "CAT" ] } } } ] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": { "$eq": [["$a"], { "$filter": { "input": ["$a"], "as": "item", "cond": { "$or": [{"$gte": [ "$$item", "DOG" ]}, {"$gte": [ "$$item", "CAT" ]}] } } } ] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": { "$eq": [["$a"], { "$filter": { "input": ["$a"], "as": "item", "cond": { "$and": [{"$gte": [ "$$item", "DOG" ]}, {"$gte": [ "$$item", "CAT" ]}] } } } ] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": { "$eq": [["$_id"], { "$filter": { "input": ["$_id"], "as": "item", "cond": { "$and": [{"$gte": [ "$$item", "HEN" ]}, {"$gte": [ "$$item", "BAT" ]}] } } } ] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- support for $in
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$in": ["$a", ["CAT", "DOG"]]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "fr", "strength" : 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$in": ["$a", ["CAT", "DOG"]]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 2 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$in": ["$a", ["CAT", "DOG"]]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 3 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$in": ["$_id", ["HEN", "BAT"]]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$in": ["$_id", ["HEN", "BAT"]]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 3 } }')
$cmd$);

-- support for $indexOfArray
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": [{ "$indexOfArray": [ ["CAT", "DOG"], "$a" ] }, 0]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": [{ "$indexOfArray": [ ["CAT", "DOG"], "$a" ] }, 0]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 3 } }')
$cmd$);

-- ======================================================================
-- SECTION 5: Field/projection stages and set operators
-- ======================================================================
-- $addFields
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$addFields": { "newField": { "$ne": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$addFields": { "newField": { "$lte": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$addFields": { "newField": { "$gte": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 3} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$addFields": { "newField": { "$gte": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }')
$cmd$);

-- project
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT documentdb_api_internal.bson_dollar_project(document, '{ "newField": { "$eq": ["$a", "CAT"] } }', '{}', 'en-u-ks-level1') FROM documentdb_api.collection('coll_q_db', 'coll_agg_proj')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT documentdb_api_internal.bson_dollar_project(document, '{ "newField": { "$eq": ["$a", "DOG"] } }', '{}', 'en-u-ks-level1') FROM documentdb_api.collection('coll_q_db', 'coll_agg_proj')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": { "$ne": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": { "$lte": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": { "$gte": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 3} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": { "$gte": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }')
$cmd$);

-- $replaceRoot
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$replaceRoot": { "newRoot": { "a": "$a", "newField": { "$eq": ["$a", "CAT"] } } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$replaceRoot": { "newRoot": { "a": "$a", "newField": { "$ne": ["$a", "CAT"] } } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$replaceRoot": { "newRoot": { "a": "$a", "newField": { "$lte": ["$a", "DoG"] } } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$replaceRoot": { "newRoot": { "a": "$a", "newField": { "$gte": ["$a", "doG"] } } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }')
$cmd$);

-- $documents
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": 1, "pipeline": [ { "$documents": { "$cond": { "if": { "$eq": [ "CaT", "cAt" ] }, "then": [{"result": "case insensitive"}] , "else": [{"res": "case sensitive"}] }} } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": 1, "pipeline": [ { "$documents": { "$cond": { "if": { "$eq": [ "CaT", "cAt" ] }, "then": [{"result": "case insensitive"}] , "else": [{"res": "case sensitive"}] }} } ], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }')
$cmd$);

-- $sortArray
SELECT documentdb_api.insert_one('coll_q_db', 'coll_sortArray', '{"_id":1,"a":"one", "b":["10","1"]}', NULL);
SELECT documentdb_api.insert_one('coll_q_db', 'coll_sortArray', '{"_id":2,"a":"two", "b":["2","020"]}', NULL);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_sortArray", "pipeline": [ { "$project": { "sortedArray": { "$sortArray": { "input": ["cat", "dog", "DOG"], "sortBy": 1 } } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_sortArray", "pipeline": [ { "$project": { "sortedArray": { "$sortArray": { "input": ["cat", "dog", "DOG"], "sortBy": 1 } } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{
  "find": "coll_sortArray",
  "filter": { "a": {"$lte": "two"} },
  "projection": {
    "sortedArray": { "$sortArray": { "input": "$b", "sortBy": 1 } }
  },
  "collation": { "locale": "en", "numericOrdering" : false },
  "limit": 5
}')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{
  "find": "coll_sortArray",
  "filter": { "a": {"$lte": "two"} },
  "projection": {
    "sortedArray": { "$sortArray": { "input": "$b", "sortBy": 1 } }
  },
  "collation": { "locale": "en", "numericOrdering" : true },
  "limit": 5
}')
$cmd$);

SELECT documentdb_api.drop_collection('coll_q_db', 'coll_sortArray');

-- find
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "projection": { "a": 1, "newField": { "$eq": ["$a", "CAT"] } }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "projection": { "a": 1, "newField": { "$ne": ["$a", "CAT"] } }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 2} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "projection": { "a": 1, "newField": { "$ne": ["$a", "CAT"] } }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 3} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "projection": { "a": 1, "newField": { "$gte": ["$a", "CAT"] } }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "projection": { "a": 1, "newField": { "$gte": ["$a", "CAT"] } }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 3} }')
$cmd$);

-- $redact
SELECT documentdb_api.insert_one('coll_q_db','coll_redact','{ "_id": 1, "level": "public", "content": "content 1", "details": { "level": "public", "value": "content 1.1", "moreDetails": { "level": "restricted", "info": "content 1.1.1" } } }', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_redact','{ "_id": 2, "level": "restricted", "content": "content 2", "details": { "level": "public", "value": "content 2.1", "moreDetails": { "level": "restricted", "info": "content 2.1.1" } } }', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_redact','{ "_id": 3, "level": "public", "content": "content 3", "details": { "level": "restricted", "value": "content 3.1", "moreDetails": { "level": "public", "info": "content 3.1.1" } } }', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_redact','{ "_id": 4, "content": "content 4", "details": { "level": "public", "value": "content 4.1" } }', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_redact','{ "_id": 5, "level": "public", "content": "content 5", "details": { "level": "public", "value": "content 5.1", "moreDetails": [{ "level": "restricted", "info": "content 5.1.1" }, { "level": "public", "info": "content 5.1.2" }] } }', NULL);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_redact", "pipeline": [ { "$redact": { "$cond": { "if": { "$eq": ["$level", "PUBLIC"] }, "then": "$$KEEP", "else": "$$PRUNE" } } }  ], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_redact", "pipeline": [ { "$redact": { "$cond": { "if": { "$eq": ["$level", "puBliC"] }, "then": "$$DESCEND", "else": "$$PRUNE" } } }  ], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_redact", "pipeline": [ { "$redact": { "$switch": { "branches": [ { "case": { "$eq": ["$level", "PUBLIC"] }, "then": "$$PRUNE" }, { "case": { "$eq": ["$classification", "RESTRICTED"] }, "then": { "$cond": { "if": { "$eq": ["$content", null] }, "then": "$$KEEP", "else": "$$PRUNE" } } }], "default": "$$KEEP" } }  }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);

-- support for $setEquals
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setEquals": [["$a"], ["CAT"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setEquals": [["$a"], ["DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setEquals": [["$a"], ["DOG", "dOg"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setEquals": [["$a", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setEquals": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setEquals": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }')
$cmd$);

-- support for $setIntersection
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIntersection": [["$a"], ["CAT"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIntersection": [["$a"], ["DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIntersection": [["$a"], ["DOG", "dOg"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIntersection": [["$a", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIntersection": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIntersection": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }')
$cmd$);

-- support for $setUnion
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setUnion": [["$a"], ["CAT"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setUnion": [["$a"], ["DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setUnion": [["$a"], ["DOG", "dOg"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setUnion": [["$a", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setUnion": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setUnion": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }')
$cmd$);

-- support for $setDifference
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setDifference": [["$a"], ["CAT"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setDifference": [["$a"], ["DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setDifference": [["$a"], ["DOG", "dOg"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setDifference": [["$a", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setDifference": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setDifference": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }')
$cmd$);

-- support for $setIsSubset
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIsSubset": [["$a"], ["CAT"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIsSubset": [["$a"], ["DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIsSubset": [["$a"], ["DOG", "dOg"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIsSubset": [["$a", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIsSubset": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIsSubset": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }')
$cmd$);

-- support in $let
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": { "$let": { "vars": { "var1": "$a" }, "in": { "$cond": { "if": { "$eq": ["$$var1", "CAT"] }, "then": 1, "else": 0 } } } } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": { "$let": { "vars": { "var1": "$a" }, "in": { "$cond": { "if": { "$eq": ["$$var1", "CAT"] }, "then": 1, "else": 0 } } } } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }')
$cmd$);

-- support for $zip
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": { "$zip": { "inputs": [ {"$cond": [{"$eq": ["CAT", "$a"]}, ["$a"], ["null"]]}, ["$a"]] } } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": { "$zip": { "inputs": [ {"$cond": [{"$eq": ["CAT", "$a"]}, ["$a"], ["null"]]}, ["$a"]] } } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }')
$cmd$);

-- ======================================================================
-- SECTION 6: Positional projection and bson_dollar_* operators
-- ======================================================================
-- find with positional queries
SELECT documentdb_api.insert_one('coll_q_db', 'coll_find_positional', '{"_id":1, "a":"cat", "b":[{"a":"cat"},{"a":"caT"}], "c": ["cat"]}', NULL);
SELECT documentdb_api.insert_one('coll_q_db', 'coll_find_positional', '{"_id":2, "a":"dog", "b":[{"a":"dog"},{"a":"doG"}], "c": ["dog"]}', NULL);
SELECT documentdb_api.insert_one('coll_q_db', 'coll_find_positional', '{"_id":3, "a":"caT", "b":[{"a":"caT"},{"a":"cat"}], "c": ["caT"]}', NULL);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{
  "find": "coll_find_positional",
  "filter": { "a": "CAT", "b": { "$elemMatch": { "a": "CAT" } } },
  "projection": { "_id": 1, "b.$": 1 },
  "sort": { "_id": 1 },
  "skip": 0,
  "limit": 5,
  "collation": { "locale": "en", "strength" : 3}
}')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{
  "find": "coll_find_positional",
  "filter": { "a": "CAT", "b": { "$elemMatch": { "a": "CAT" } } },
  "projection": { "_id": 1, "b.$": 1 },
  "sort": { "_id": 1 },
  "skip": 0,
  "limit": 5,
  "collation": { "locale": "en", "strength" : 1 }
}')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_find('coll_q_db', '{
  "find": "coll_find_positional",
  "filter": { "a": "CAT", "b": { "$elemMatch": { "a": "CAT" } } },
  "projection": { "_id": 1, "b.$": 1 },
  "sort": { "_id": 1 },
  "skip": 0,
  "limit": 5,
  "collation": { "locale": "en", "strength" : 1 }
}')
$cmd$);

SELECT documentdb_api.drop_collection('coll_q_db', 'coll_find_positional');

-- $in: []
SELECT documentdb_api.insert_one('coll_q_db', 'collTest', '{"_id": 1, "name": "cat", "sound": "meow"}');
SELECT documentdb_api.insert_one('coll_q_db', 'collTest', '{"_id": 2, "name": "dog", "sound": "woof"}');
SELECT documentdb_api.insert_one('coll_q_db', 'collTest', '{"_id": 3, "sound": "moo"}');
SELECT documentdb_api.insert_one('coll_q_db', 'collTest', '{"_id": 4, "name": "sheep", "sound": "baa"}');
SELECT documentdb_api.insert_one('coll_q_db', 'collTest', '{"_id": 5, "name": "duck"}');

-- $in: [] with bson_dollar_add_fields
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "collTest", 
  "pipeline": [ {"$match": {"_id": { "$in": [] }}}, { "$addFields": { "newField": "animal" } } ], 
  "cursor": {} }')
$cmd$);

-- with variableSpec and collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "collTest", 
  "pipeline": [ {"$match": {"_id": { "$in": [] }}}, { "$addFields": { "newField": "animal" } } ], 
  "let": { "varRef": "lion"},
  "cursor": {} }')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "collTest", 
  "pipeline": [ {"$match": {"_id": { "$in": [] }}}, { "$addFields": { "newField": "animal" } } ], 
  "collation": { "locale": "en", "strength" : 1},
  "cursor": {} }')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "collTest", 
  "pipeline": [ {"$match": {"sound": "moo", "_id": { "$in": [] }}}, { "$addFields": { "newField": "$$varRef" } } ], 
  "let": { "varRef": "lion"},
  "collation": { "locale": "en", "strength" : 1},
  "cursor": {} }')
$cmd$);

-- $in: [] with bson_dollar_redact
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "collTest", 
  "pipeline": [ {"$match": {"_id": { "$in": [] }}}, { "$redact": { "$cond": [ { "$eq": [ "$sound", "meow" ] }, "$$KEEP", "$$PRUNE" ] } } ], 
  "cursor": {} }')
$cmd$);

-- $in: [] with bson_dollar_redact; with variableSpec and collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "collTest", 
  "pipeline": [ {"$match": {"owner": { "$in": [] }}}, { "$redact": { "$cond": [ { "$eq": [ "$sound", "meow" ] }, "$$KEEP", "$$PRUNE" ] } } ], 
  "let": { "varRef": "lion"},
  "cursor": {} }')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "collTest", 
  "pipeline": [ {"$match": {"sound": { "$in": [] }}}, { "$redact": { "$cond": [ { "$eq": [ "$sound", "meow" ] }, "$$KEEP", "$$PRUNE" ] } } ], 
  "collation": { "locale": "en", "strength" : 1},
  "cursor": {} }')
$cmd$);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "collTest", 
  "pipeline": [ {"$match": {"_id": { "$in": [] }}}, { "$redact": { "$cond": [ { "$eq": [ "$sound", "meow" ] }, "$$KEEP", "$$PRUNE" ] } } ], 
  "let": { "varRef": "lion"},
  "collation": { "locale": "en", "strength" : 1},
  "cursor": {} }')
$cmd$);

-- projection via bson_dollar_project (no let/collation)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "collTest", 
  "pipeline": [ {"$match": {"name": { "$in": [] }}}, { "$project": { "_id": 0, "sound": 1 } } ], 
  "cursor": {} }')
$cmd$);

-- projection via bson_dollar_project with let variables
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "collTest", 
  "pipeline": [ {"$match": {"_id": { "$in": [] } }}, { "$project": { "_id": 0, "name": 1, "varEcho": "$$varRef" } } ], 
  "let": { "varRef": "lion"},
  "cursor": {} }')
$cmd$);

-- projection via bson_dollar_project with collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "collTest", 
  "pipeline": [ {"$match": {"_id": { "$in": [] } }}, { "$project": { "_id": 0, "name": 1 } } ], 
  "collation": { "locale": "en", "strength" : 1},
  "cursor": {} }')
$cmd$);

-- projection via bson_dollar_project with let variables and collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "collTest", 
  "pipeline": [ {"$match": {"_id": { "$in": [] } }}, { "$project": { "_id": 0, "name": 1, "varEcho": "$$varRef" } } ], 
  "let": { "varRef": "lion"},
  "collation": { "locale": "en", "strength" : 1},
  "cursor": {} }')
$cmd$);

-- replaceRoot via bson_dollar_replace_root (no let/collation)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "collTest", 
  "pipeline": [ {"$match": {"name": {"$in": [] } }}, { "$replaceRoot": { "newRoot": { "animal": "$name", "call": "$sound" } } } ], 
  "cursor": {} }')
$cmd$);

-- replaceRoot via bson_dollar_replace_root with let variables
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "collTest", 
  "pipeline": [ {"$match": {"name": {"$in": [] } }}, { "$replaceRoot": { "newRoot": { "animal": "$$varRef", "call": "$sound" } } } ], 
  "let": { "varRef": "lion"},
  "cursor": {} }')
$cmd$);

-- replaceRoot via bson_dollar_replace_root with collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "collTest", 
  "pipeline": [ {"$match": {"name": {"$in": [] } }}, { "$replaceRoot": { "newRoot": { "animal": "$name", "call": "$sound" } } } ], 
  "collation": { "locale": "en", "strength" : 1},
  "cursor": {} }')
$cmd$);

-- replaceRoot via bson_dollar_replace_root with let variables and collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "collTest", 
  "pipeline": [ {"$match": {"name": {"$in": [] } }}, { "$replaceRoot": { "newRoot": { "animal": "$$varRef", "call": "$sound" } } } ], 
  "let": { "varRef": "lion"},
  "collation": { "locale": "en", "strength" : 1},
  "cursor": {} }')
$cmd$);

-- bson_dollar_project_find with let variables and collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{
  "find": "collTest",
  "filter": {
    "_id": { "$in": [] }
  },
  "projection": { "name": true },
  "let": { "varRef": "lion" },
  "collation": { "locale": "en", "strength" : 1 }
}')
$cmd$);

SELECT documentdb_api.drop_collection('coll_q_db', 'collTest');

-- ======================================================================
-- SECTION 7: Setup — single-field and compound indexes with collation
-- ======================================================================

SELECT documentdb_api.insert_one('coll_q_db','single_field', '{"_id": 1, "a": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','single_field', '{"_id": 2, "a": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','single_field', '{"_id": 3, "a": "BANANA"}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','single_field', '{"_id": 4, "a": "banana"}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','single_field', '{"_id": 5, "a": "cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','single_field', '{"_id": 6, "a": "Cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','single_field', '{"_id": 7, "a": "date"}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','single_field', '{"_id": 8, "a": "Date"}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','single_field', '{"_id": 9, "a": 42}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','single_field', '{"_id": 10, "a": null}', NULL);

SELECT documentdb_api.insert_one('coll_q_db','compound_field', '{"_id": 1, "a": "DOG", "b": 10}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','compound_field', '{"_id": 2, "a": "dog", "b": 20}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','compound_field', '{"_id": 3, "a": "Cat", "b": 30}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','compound_field', '{"_id": 4, "a": "cat", "b": 40}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','compound_field', '{"_id": 5, "a": "Bird", "b": 50}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','compound_field', '{"_id": 6, "a": "bird", "b": 60}', NULL);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_q_db',
  '{
    "createIndexes": "single_field",
    "indexes": [{
      "key": {"a": 1},
      "name": "idx_a_en_s1",
      "collation": {"locale": "en", "strength": 1}
    }]
  }',
  TRUE
);

SELECT documentdb_api_internal.create_indexes_non_concurrently(
  'coll_q_db',
  '{
    "createIndexes": "compound_field",
    "indexes": [{
      "key": {"a": 1, "b": 1},
      "name": "idx_ab_en_s1",
      "collation": {"locale": "en", "strength": 1}
    }]
  }',
  TRUE
);

-- ======================================================================
-- SECTION 8: Aggregation pipeline with collation
-- ======================================================================

-- 9.1: $match with $eq — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "apple" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim(format($cmd$ 
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline(%L, '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "apple" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
 $cmd$, 'coll_q_db'));

-- 9.2: $match with $eq — no collation — index should NOT be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "apple" } } } ], "cursor": {} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim(format($cmd$ 
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline(%L, '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "apple" } } } ], "cursor": {} }')
 $cmd$, 'coll_q_db'));

-- 9.3: $match with $gt — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "banana" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim(format($cmd$ 
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline(%L, '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "banana" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
 $cmd$, 'coll_q_db'));

-- 9.4: $match then $project — matching collation — index SHOULD be used for $eq
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cherry" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim(format($cmd$ 
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline(%L, '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cherry" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
 $cmd$, 'coll_q_db'));

-- 9.5: $match with $lt — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lt": "cherry" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim(format($cmd$ 
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline(%L, '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lt": "cherry" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
 $cmd$, 'coll_q_db'));

-- 9.6: $match with $lte — matching collation — index SHOULD be used
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lte": "banana" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim(format($cmd$ 
    EXPLAIN (COSTS OFF, ANALYZE ON, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT document FROM bson_aggregation_pipeline(%L, '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lte": "banana" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
 $cmd$, 'coll_q_db'));
-- ======================================================================
-- SECTION 9: $lookup, $facet, $unionWith, $graphLookup, $merge
-- ======================================================================

-- nested pipleline tests

SELECT documentdb_api.insert_one('coll_q_db','coll_lookup', '{"_id": "DOG", "a" : { "b" : "DOG" }}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_lookup', '{"_id": "dog", "a" : { "b" : "dog" }}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_lookup', '{"_id": "Cat", "a" : { "b" : "Cat" }}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_lookup', '{"_id": "Dog", "a" : { "b" : "Dog" }}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_lookup', '{"_id": "cAT", "a" : { "b" : "cAT" }}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_lookup', '{"_id": "DoG", "a" : { "b" : "DoG" }}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_lookup', '{"_id": "dOg", "a" : { "b" : "dOg" }}', NULL);

-- lookup with id join (collation aware)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', 
    '{ "aggregate": "coll_lookup", "pipeline": [ { "$lookup": { "from": "coll_lookup", "as": "matched_docs", "localField": "_id", "foreignField": "_id", "pipeline": [ { "$match": { "$or" : [ { "a.b": "cat" }, { "a.b": "dog" } ] } } ] } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }')
$cmd$);

-- lookup with id join optimized (explicitly asked to make _id join collation agnostic)
BEGIN;
SET LOCAL documentdb.enableLookupIdJoinOptimizationOnCollation to true;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', 
    '{ "aggregate": "coll_lookup", "pipeline": [ { "$lookup": { "from": "coll_lookup", "as": "matched_docs", "localField": "_id", "foreignField": "_id", "pipeline": [ { "$match": { "$or" : [ { "a.b": "cat" }, { "a.b": "dog" } ] } } ] } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }')
$cmd$);
ROLLBACK;

-- lookup with non-id join (collation aware)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', 
    '{ "aggregate": "coll_lookup", "pipeline": [ { "$lookup": { "from": "coll_lookup", "as": "matched_docs", "localField": "a.b", "foreignField": "a.b", "pipeline": [ { "$match": { "$or" : [ { "a.b": "cat" }, { "a.b": "dog" } ] } } ] } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }')
$cmd$);

-- lookup with non-id join (collation aware - explain)
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_q_db', 
    '{ "aggregate": "coll_lookup", "pipeline": [ { "$lookup": { "from": "coll_lookup", "as": "matched_docs", "localField": "a.b", "foreignField": "a.b", "pipeline": [ { "$match": { "$or" : [ { "a.b": "cat" }, { "a.b": "dog" } ] } } ] } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }')
$cmd$);
ROLLBACK;

-- $facet and $unionwith
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_lookup", "pipeline": [ { "$facet": { "a" : [ { "$match": { "a.b": "cat" } }, { "$count": "catCount" } ], "b" : [ { "$match": { "a.b": "dog" } }, { "$count": "dogCount" } ]  } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}}')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_lookup", "pipeline": [ { "$unionWith": { "coll": "coll_lookup", "pipeline" : [ { "$match": { "a.b": "cat" }}] } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);

-- $graphLookup 
SELECT documentdb_api.insert_one('coll_q_db','coll_graph_src', '{"_id": "alice", "pet" : "dog" }', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_graph_src', '{"_id": "bob", "pet" : "cat" }', NULL);

SELECT documentdb_api.insert_one('coll_q_db','coll_graph_dst', '{"_id": "DOG", "name" : "DOG" }', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_graph_dst', '{"_id": "dog", "name" : "dog" }', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_graph_dst', '{"_id": "CAT", "name" : "CAT" }', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_graph_dst', '{"_id": "cAT", "name" : "cAT" }', NULL);

BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_q_db',
    '{ "aggregate": "coll_graph_src", "pipeline": [ { "$graphLookup": { "from": "coll_graph_dst", "startWith": "$pet", "connectFromField": "name", "connectToField": "_id", "as": "destinations", "depthField": "depth" } } ],  "collation": { "locale": "en", "strength" : 3} }')
$cmd$);
ROLLBACK;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db',
    '{ "aggregate": "coll_lookup", "pipeline": [ { "$graphLookup": { "from": "coll_lookup", "startWith": "$a.b", "connectFromField": "a.b", "connectToField": "a.b", "as": "destinations", "depthField": "depth" } } ],  "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db',
    '{ "aggregate": "coll_graph_src", "pipeline": [ { "$graphLookup": { "from": "coll_graph_dst", "startWith": "$pet", "connectFromField": "name", "connectToField": "_id", "as": "destinations", "depthField": "depth" } } ],  "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db',
    '{ "aggregate": "coll_graph_src", "pipeline": [ { "$graphLookup": { "from": "coll_graph_dst", "startWith": "$pet", "connectFromField": "name", "connectToField": "_id", "as": "destinations", "depthField": "depth" } } ],  "collation": { "locale": "en", "strength" : 2} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db',
    '{ "aggregate": "coll_graph_src", "pipeline": [ { "$graphLookup": { "from": "coll_graph_dst", "startWith": "$pet", "connectFromField": "name", "connectToField": "_id", "as": "destinations", "depthField": "depth" } } ],  "collation": { "locale": "fr", "strength" : 1, "alternate": "shifted" } }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db',
    '{ "aggregate": "coll_graph_src", "pipeline": [ { "$graphLookup": { "from": "coll_graph_dst", "startWith": "$pet", "connectFromField": "name", "connectToField": "_id", "as": "destinations", "depthField": "depth" } } ],  "collation": { "locale": "hi", "strength" : 2, "caseFirst": "lower" } }')
$cmd$);

-- test $graphlookup
BEGIN;

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (VERBOSE ON, COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_q_db',
    '{ "aggregate": "coll_graph_src", "pipeline": [ { "$graphLookup": { "from": "coll_graph_dst", "startWith": "$pet", "connectFromField": "name", "connectToField": "_id", "as": "destinations", "depthField": "depth" } } ],  "collation": { "locale": "en", "strength" : 3} }')
$cmd$);
ROLLBACK;

-- unsupported $merge 
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_lookup", "pipeline": [{"$merge" : { "into": "coll_merge_target", "whenMatched" : "replace" }} ], "collation": { "locale": "en", "strength" : 1} }')
$cmd$);

-- ======================================================================
-- SECTION 10: $in with deeply nested arrays — collection-backed find plans
-- ======================================================================
-- Verifies plans for $in matches against deeply nested array fields under
-- collation, exercised through bson_aggregation_find.

SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays', '{ "_id": 1, "a": ["dog"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays', '{ "_id": 2, "a": ["cat", "dog"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays', '{ "_id": 3, "a": [[["cat"]]] }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_arrays", "filter": { "a" : {"$in" : [ ["dOG"] ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_arrays", "filter": { "a" : {"$in" : [ [["CAT"]] ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_arrays", "filter": { "a" : {"$in" : [["CAT"], ["DOG"]] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);

SELECT documentdb_api.insert_one('coll_q_db', 'nested_docs', '{ "_id": 1, "a": { "b": "cat" } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_docs', '{ "_id": 2, "a": { "b": "dog" } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_docs', '{ "_id": 3, "a": { "b": { "c": "cat" } } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_docs', '{ "_id": 4, "a": { "b": { "c": "dog" } } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_docs', '{ "_id": 5, "a": { "b": { "c": { "d": "cat" } } } }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_docs", "filter": { "a" : {"$in" : [ {"b": "dOG"} ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_docs", "filter": { "a" : {"$in" : [ {"b": { "c": "dOg" }} ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_docs", "filter": { "a" : {"$in" : [ {"b": { "c": { "d": "dOg" }}} ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);

-- nested documents: keys are collation-agnostic
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_docs", "filter": { "a" : {"$in" : [ {"B": "dOG"} ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);

SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays_docs', '{ "_id": 1, "a": { "b": ["cat"] } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays_docs', '{ "_id": 2, "a": { "b": ["dog"] } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays_docs', '{ "_id": 3, "a": { "b": ["cat", "dog"] } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays_docs', '{ "_id": 4, "a": {"b": [["dog"]] } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays_docs', '{ "_id": 5, "a": { "b": [[["cat"]]] } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays_docs', '{ "_id": 6, "a": "cat" }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_arrays_docs", "filter": { "a" : {"$in" : [ {"b": ["dOG"]}, "CAT" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_arrays_docs", "filter": { "a" : {"$in" : [ {"b": [["dOg"]] } ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }')
$cmd$);

-- ======================================================================
-- SECTION 15: Unsupported aggregation stages
-- ======================================================================

-- (6) currently unsupported scenarions:
-- unsupported: $bucket
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', 
'{
    "aggregate": "coll_array_filter",
    "pipeline": [
        {
            "$bucket": {
                "groupBy": "$price",
                "boundaries": [0, 10, 20, 30],
                "default": "Other",
                "output": {
                    "categoryMatch": {
                        "$sum": {
                            "$cond": [
                                { "$eq": ["$a", "PETS"] },
                                1,
                                0
                            ]
                        }
                    }
                }
            }
        }
    ],
    "collation": { "locale": "en", "strength": 1 }
}')
$cmd$);

-- unsupported: $geoNear
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db',
'{ "aggregate": "coll_array_filter",
   "pipeline": [
     {
       "$geoNear": {
         "near": { "type": "Point", "coordinates": [ 0 , 10 ] },
         "distanceField": "dist.calculated",
         "maxDistance": 2,
         "query": { "a": "cAT" }
       }
     }
   ],
   "collation": { "locale": "en", "strength": 1 }
}')
$cmd$);

-- unsupported: $fill
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', 
'{
    "aggregate": "coll_array_filter",
    "pipeline": [
        {
            "$fill": {
                "sortBy": { "timestamp": 1 },
                "partitionBy": "$status",
                "output": {
                     "$cond": {
                        "if": { "$eq": ["$a", "cAt"] },
                        "then": { "type": "feline" },
                        "else": { "type": "other" }
                      }
                }
            }
        }
    ],
    "collation": { "locale": "en", "strength": 1 }
}')
$cmd$);

-- unsupported: $group
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db',
'{ "aggregate": "coll_array_filter",
   "pipeline": [
     { "$group": {
         "_id": "$a",
         "set": { "$addToSet": "$a" }
     }}
   ],
   "collation": { "locale": "en", "strength": 1 }
}')
$cmd$);

-- unsupported: $setWindowFields
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db',
'{ "aggregate": "coll_array_filter",
   "pipeline": [
     { "$setWindowFields": {
         "sortBy": { "_id": 1 },
         "output": {
             "total": { "$eq": ["$a", "cAt"] }
         }
     }}
   ],
   "collation": { "locale": "en", "strength": 1 }
}')
$cmd$);

-- unsupported: $sortByCount
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db',
'{ "aggregate": "coll_array_filter",
   "pipeline": [
     { "$sortByCount": {
         "input": "$a",
         "as": "a",
         "by": { "$cond": { 
           "if": { "$eq": [ "$a", "caT" ] }, 
           "then": [{"x": 30}] , 
           "else": [{"x": 30}] }}
     }}
   ],
   "collation": { "locale": "en", "strength": 1 }
}')
$cmd$);

-- ======================================================================
-- TODO_COLLATION: $expr / $lookup must not use a collation-aware secondary index,
-- and a collated $expr / $lookup must not use any secondary index. single_field
-- carries a collation index on `a` (idx_a_en_s1), so each query falls back to _id_.
-- ======================================================================

-- Collated $expr on `a`: query-side gate -> _id_.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "single_field", "filter": { "$expr": {"$eq": ["$a", "APPLE"]} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- Non-collated $expr (numeric) on `a`: index-side gate -> _id_ (the collation index
-- could otherwise serve a numeric qual).
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "single_field", "filter": { "$expr": {"$eq": ["$a", 42]} }, "sort": { "_id": 1 } }')
$cmd$);

-- Collated $lookup self-join on `a`: query-side gate -> _id_.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "single_field", "pipeline": [ { "$lookup": { "from": "single_field", "as": "m", "localField": "a", "foreignField": "a" } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- Non-collated $lookup self-join on `a`: index-side gate -> _id_.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "single_field", "pipeline": [ { "$lookup": { "from": "single_field", "as": "m", "localField": "a", "foreignField": "a" } } ], "cursor": {} }')
$cmd$);

-- $merge (non-collated) onto a non-_id key carrying both the required unique index
-- and a collation-aware index: the merge join filter must use the unique key, never
-- the collated idx_merge_k_en. Rows are inserted so the planner picks the index path
-- (an empty target falls back to a join filter); collation+unique is disallowed so
-- the unique index always co-exists.
SELECT documentdb_api.insert_one('coll_q_db','coll_merge_src', '{"_id": 1, "k": "a"}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_merge_dst', '{"_id": 1, "k": "a"}', NULL);
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_db',
  '{ "createIndexes": "coll_merge_dst", "indexes": [ { "key": {"k": 1}, "name": "uq_merge_k", "unique": true }, { "key": {"k": 1}, "name": "idx_merge_k_en", "collation": {"locale":"en","strength":1} } ] }', TRUE);
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_merge_src", "pipeline": [{"$merge" : { "into": "coll_merge_dst", "on": "k", "whenMatched" : "replace", "whenNotMatched": "insert" }} ], "cursor": {} }')
$cmd$);
SELECT documentdb_api.drop_collection('coll_q_db','coll_merge_src');
SELECT documentdb_api.drop_collection('coll_q_db','coll_merge_dst');
