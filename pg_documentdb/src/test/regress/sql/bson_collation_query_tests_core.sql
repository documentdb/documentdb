SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;
SET documentdb_core.enableCollation TO on;

-- ==============================================================================
-- SECTION 1: find — basic queries on coll_strings
-- ==============================================================================

-- Insert fixtures.
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 1, "a": "Cat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 2, "a": "dog" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 3, "a": "cat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 4, "a": "Dog" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 5, "a": "caT" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 6, "a": "doG" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 7, "a": "goat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 8, "a": "Goat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 9, "b": "Cat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 10, "b": "dog" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 11, "b": "cat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 12, "b": "Dog" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 13, "b": "caT", "a" : "raBbIt" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 14, "b": "doG" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 15, "b": "goat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 16, "b": "Goat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 17, "a": ["Cat", "CAT", "dog"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 18, "a": ["dog", "cat", "CAT"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 19, "a": ["cat", "rabbit", "bAt"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 20, "a": ["Cat"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 21, "a": ["dog"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 22, "a": ["cat"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 23, "a": ["CAT"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 24, "a": ["cAt"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 25, "a": { "b" : "cAt"} }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_strings', '{ "_id": 26, "a": [{ "b": "CAT"}] }');

SET documentdb_core.enableCollation TO off;

-- enableCollation = off, skipFailOnCollation = off (default): collation is rejected.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_strings", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": { "b": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');

-- enableCollation = off, skipFailOnCollation = on: collation is accepted but ignored (binary match).
SET documentdb.skipFailOnCollation TO on;
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_strings", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cat" } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": { "b": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');
RESET documentdb.skipFailOnCollation;

SET documentdb_core.enableCollation TO on;

-- $eq with strength-1 collation matches all case variants.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": { "b": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');

-- $or across paths with collation.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "a": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 10, "collation": { "locale": "en", "strength" : 1 } }');

-- $all and $in with collation.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": { "a": { "$all": ["cAt", "DOG"] } }, "skip": 0, "limit":
 5, "collation": { "locale": "en", "strength": 1} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": { "a" : {"$in" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 5} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": { "a" : {"$in" : ["cat", "DOG" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 100, "collation": { "locale": "en", "strength" : 1} }');

-- Range query ($gt + $lt) on path "a" without an index.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": { "a": { "$gt": "CAT" }, "a" : {"$lt" : "RABBIT"} }, "collation": { "locale": "en", "strength" : 1.93 } }');

-- ==============================================================================
-- SECTION 2: find — multi-collation results on coll_multi_collation
-- ==============================================================================

-- Insert fixtures.
SELECT documentdb_api.insert_one('coll_q_db', 'coll_multi_collation', '{ "_id": 1, "a": "Cat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_multi_collation', '{ "_id": 2, "a": "dog" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_multi_collation', '{ "_id": 3, "a": "cat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_multi_collation', '{ "_id": 4, "a": "CaT" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_multi_collation', '{ "_id": 5, "b": "Dog" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_multi_collation', '{ "_id": 6, "b": "DoG" }');

-- $eq and $or under varying collation options (strength, caseLevel, caseFirst, numericOrdering).
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "a": { "$eq": "cat" } }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 3, "caseLevel": true, "caseFirst": "off", "numericOrdering": true } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1.93 } }');

-- $regex ignores collation (regex matching is byte-level).
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "a": { "$regex": "^c", "$options": "" } }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1 } }');

-- Same $or filter under different ICU locales (en, fr, de, bn).
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 2, "caseLevel": false, "caseFirst": "lower", "numericOrdering": true } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1, "caseLevel": true, "caseFirst": "lower", "numericOrdering": true} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "fr", "strength" : 1, "caseLevel": false, "caseFirst": "lower", "numericOrdering": true} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "de", "strength" : 1, "caseLevel": false, "caseFirst": "lower", "numericOrdering": true} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "bn", "strength" : 1, "caseLevel": false, "caseFirst": "lower", "numericOrdering": true} }');

-- ==============================================================================
-- SECTION 3: find — sort / orderBy under collation
-- ==============================================================================

-- Sort by `b` (mixed-case strings) under varying strength + caseFirst.
SELECT documentdb_api.insert_one('coll_q_db', 'coll_order_tests0', '{"_id": "CaT", "a": "cat", "b": "CaT"}');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_order_tests0', '{"_id": "CAt", "a": "cat", "b": "CAt"}');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_order_tests0', '{"_id": "CAT", "a": "cat", "b": "CAT"}');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_order_tests0', '{"_id": "cAT", "a": "cat", "b": "cAT"}');

SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_order_tests0", "filter": { "a": {"$lte": "cat"} }, "sort": { "b": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 3 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_order_tests0", "filter": { "a": {"$lte": "cat"} }, "sort": { "b": -1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 3 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_order_tests0", "filter": { "a": {"$lte": "cat"} }, "sort": { "b": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1, "caseLevel": true, "caseFirst": "upper" } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_order_tests0", "filter": { "a": {"$lte": "cat"} }, "sort": { "b": -1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1, "caseLevel": true, "caseFirst": "upper" } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_order_tests0", "filter": { "a": {"$gte": "cat"} }, "sort": { "b": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1, "caseLevel": true, "caseFirst": "lower" } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_order_tests0", "filter": { "a": {"$gte": "cat"} }, "sort": { "b": -1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1, "caseLevel": true, "caseFirst": "lower" } }');

-- Sort by `_id` (collation-aware string _id values).
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_order_tests0", "filter": { "a": {"$lte": "cat"} }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 3 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_order_tests0", "filter": { "a": {"$lte": "cat"} }, "sort": { "_id": -1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 3 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_order_tests0", "filter": { "a": {"$lte": "cat"} }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1, "caseLevel": true, "caseFirst": "upper" } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_order_tests0", "filter": { "a": {"$lte": "cat"} }, "sort": { "_id": -1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1, "caseLevel": true, "caseFirst": "upper" } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_order_tests0", "filter": { "a": {"$gte": "cat"} }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1, "caseLevel": true, "caseFirst": "lower" } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_order_tests0", "filter": { "a": {"$gte": "cat"} }, "sort": { "_id": -1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1, "caseLevel": true, "caseFirst": "lower" } }');

-- numericOrdering: lexical ("10" < "2") vs numeric ("2" < "10") sort order.
SELECT documentdb_api.insert_one('coll_q_db', 'coll_order_tests1', '{"_id": 1, "a": "cat", "b": "10"}');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_order_tests1', '{"_id": 2, "a": "cat", "b": "2"}');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_order_tests1', '{"_id": 3, "a": "cat", "b": "3"}');

SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_order_tests1", "filter": { "a": "cat" }, "sort": { "b": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "numericOrdering" : false } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_order_tests1", "filter": { "a": "cat" }, "sort": { "b": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "numericOrdering" : true } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_order_tests1", "filter": { "a": "cat" }, "sort": { "b": -1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "numericOrdering" : false } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_order_tests1", "filter": { "a": "cat" }, "sort": { "b": -1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "numericOrdering" : true } }');

-- $setWindowFields uses the sortBy collation when ordering.
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('coll_q_db',
    '{ "aggregate": "coll_order_tests1", "pipeline":  [{"$setWindowFields": { "sortBy": {"b": -1}, "output": {"res": { "$push": "$b", "window": {"documents": ["unbounded", "unbounded"]}}}}}], "collation": { "locale": "en", "numericOrdering" : false } }');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('coll_q_db',
    '{ "aggregate": "coll_order_tests1", "pipeline":  [{"$setWindowFields": { "sortBy": {"b": -1}, "output": {"res": { "$push": "$b", "window": {"documents": ["unbounded", "unbounded"]}}}}}], "collation": { "locale": "en", "numericOrdering" : true } }');

-- ==============================================================================
-- SECTION 4: find — _id filters under collation
-- ==============================================================================

SELECT documentdb_api.insert_one('coll_q_db', 'coll_string_ids', '{ "_id": "Cat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_string_ids', '{ "_id": "dog" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_string_ids', '{ "_id": "cat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_string_ids', '{ "_id": "CaT" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_string_ids', '{ "_id": "Dog" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_string_ids', '{ "_id": "DoG" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_string_ids', '{ "_id": { "a" : "cat" } }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_string_ids',' { "_id": { "a": "CAT"} }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_string_ids', '{ "a": { "a": "Dog" } } ');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_string_ids', '{ "_id": [ "cat", "CAT "] }');

-- $or on _id (case-insensitive match across mixed-case ids).
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_string_ids", "filter": { "$or" : [{ "_id": { "$eq": "cat" } }, { "_id": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');
-- Dotted-path _id.a.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_string_ids", "filter": { "$or" : [{ "_id.a": { "$eq": "cat" } }, { "_id.a": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');

-- ==============================================================================
-- SECTION 5: aggregation — array fields under collation
-- ==============================================================================

SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_strings", "pipeline": [ { "$sort": { "_id": 1 } }, { "$addFields": { "e": {  "f": "$a" } } }, { "$replaceRoot": { "newRoot": "$e" } }, { "$match" : { "f": { "$elemMatch": {"$eq": "cAt"} } } }, {"$project": { "items" : { "$filter" : { "input" : "$f", "as" : "animal", "cond" : { "$eq" : ["$$animal", "CAT"] } }} }} ],
 "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');

-- ==============================================================================
-- SECTION 6: aggregation — $expr and ICU locale semantics
-- ==============================================================================

SELECT documentdb_api.insert_one('coll_q_db', 'coll_agg_proj', '{ "_id": 1, "a": "cat" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_agg_proj', '{ "_id": 2, "a": "dog" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_agg_proj', '{ "_id": 3, "a": "cAt" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_agg_proj', '{ "_id": 4, "a": "dOg" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_agg_proj', '{ "_id": "hen", "a": "hen" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_agg_proj', '{ "_id": "bat", "a": "bat" }');

-- $expr with $eq/$ne/$lte/$gte/$gt under various locales.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "hi", "strength" : 2 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$ne": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "fi", "strength" : 1 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$lte": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$gte": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "fr", "strength" : 3 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$gte": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "fr_CA", "strength" : 3 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$gte": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "es@collation=search", "strength" : 3 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$gt": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "fr", "strength" : 1 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": { "$or": [{"$gte": [ "$a", "DOG" ]}, {"$gte": [ "$a", "CAT" ]}] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "fr", "strength" : 1 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": { "$and": [{"$lte": [ "$a", "DOG" ]}, {"$lte": [ "$a", "CAT" ]}] } }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "fr", "strength" : 2 } }');

-- en_US_POSIX uses C-style byte comparison: case-sensitive even at strength 1 (per ICU semantics).
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": ["$a", "cat"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en_US_POSIX", "strength" : 1 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en_US_POSIX", "strength" : 1 } }');

-- locale "simple": pure binary comparison (no ICU collation).
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj",  "filter": { "$expr": {"$eq": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "simple"} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj",  "filter": { "$expr": {"$eq": ["$a", "cat"]} }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "simple"} }');

-- locale "simple": ignores all other collation options.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj",  "filter": { "$expr": {"$eq": ["$a", "cat"]} }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "simple", "strength": 1} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj",  "filter": { "$expr": {"$eq": ["$a", "cat"]} }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "simple", "strength": 3} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj",  "filter": { "$expr": {"$eq": ["$a", "cat"]} }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "simple", "caseFirst": "upper"} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj",  "filter": { "$expr": {"$eq": ["$a", "cat"]} }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "simple", "caseFirst": "lower"} }');

-- ==============================================================================
-- SECTION 7: aggregation — expression operators ($filter, $in, $indexOf*, $strcasecmp)
-- ==============================================================================

-- $filter — element-wise predicate honors collation.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": { "$eq": [["$a"], { "$filter": { "input": ["$a"], "as": "item", "cond": { "$eq": [ "$$item", "CAT" ] } } } ] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": { "$eq": [["$a"], { "$filter": { "input": ["$a"], "as": "item", "cond": { "$eq": [ "$$item", "CAT" ] } } } ] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": { "$eq": [["$a"], { "$filter": { "input": ["$a"], "as": "item", "cond": { "$ne": [ "$$item", "CAT" ] } } } ] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": { "$eq": [["$a"], { "$filter": { "input": ["$a"], "as": "item", "cond": { "$or": [{"$gte": [ "$$item", "DOG" ]}, {"$gte": [ "$$item", "CAT" ]}] } } } ] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": { "$eq": [["$a"], { "$filter": { "input": ["$a"], "as": "item", "cond": { "$and": [{"$gte": [ "$$item", "DOG" ]}, {"$gte": [ "$$item", "CAT" ]}] } } } ] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": { "$eq": [["$_id"], { "$filter": { "input": ["$_id"], "as": "item", "cond": { "$and": [{"$gte": [ "$$item", "HEN" ]}, {"$gte": [ "$$item", "BAT" ]}] } } } ] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- $in — set membership honors collation.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$in": ["$a", ["CAT", "DOG"]]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "fr", "strength" : 1 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$in": ["$a", ["CAT", "DOG"]]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 2 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$in": ["$a", ["CAT", "DOG"]]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 3 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$in": ["$_id", ["HEN", "BAT"]]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$in": ["$_id", ["HEN", "BAT"]]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 3 } }');

-- $indexOfArray — element comparison honors collation.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": [{ "$indexOfArray": [ ["CAT", "DOG"], "$a" ] }, 0]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": [{ "$indexOfArray": [ ["CAT", "DOG"], "$a" ] }, 0]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 3 } }');

-- $indexOfBytes — byte-level operator; ignores collation.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": [{ "$indexOfBytes": [ "cAtALoNa", "$a" ] }, 0]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": [{ "$indexOfBytes": [ "cAtALoNa", "$a" ] }, 0]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 3 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": [{ "$indexOfBytes": [ "$a", "aT" ] }, 1]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 2 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": [{ "$indexOfBytes": [ "$a", "AT" ] }, -1]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 2 } }');

-- $indexOfCP — code-point operator; ignores collation.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": [{ "$indexOfCP": [ "cAtALoNa", "$a" ] }, 0]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": [{ "$indexOfCP": [ "cAtALoNa", "$a" ] }, 0]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 3 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": [{ "$indexOfCP": [ "$a", "at" ] }, 1]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 2 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": [{ "$indexOfCP": [ "$a", "AT" ] }, 1]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 2 } }');

-- $strcasecmp — has its own case-folding; ignores collation.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": [{ "$strcasecmp": ["$a", "CAT"] }, 0]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 1 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": [{ "$strcasecmp": ["$a", "CAT"] }, 0]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 3 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": [{ "$strcasecmp": ["$a", "CAT"] }, 0]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 2 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "filter": { "$expr": {"$eq": [{ "$strcasecmp": ["$a", "CAT"] }, 0]} }, "sort": { "_id": 1 }, "skip": 0, "collation": { "locale": "en", "strength" : 3 } }');

-- ==============================================================================
-- SECTION 8: aggregation — projection stages and set operators
-- ==============================================================================

-- $addFields with $ne / $lte / $gte under fr-strength-1/3.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$addFields": { "newField": { "$ne": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$addFields": { "newField": { "$lte": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$addFields": { "newField": { "$gte": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 3} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$addFields": { "newField": { "$gte": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }');

-- $set (alias of $addFields).
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$set": { "newField": { "$ne": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$set": { "newField": { "$lte": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$set": { "newField": { "$gte": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 3} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$set": { "newField": { "$gte": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }');

-- $project (and the bson_dollar_project helper) with collation-aware predicates.
SELECT documentdb_api_internal.bson_dollar_project(document, '{ "newField": { "$eq": ["$a", "CAT"] } }', '{}', 'en-u-ks-level1') FROM documentdb_api.collection('coll_q_db', 'coll_agg_proj');
SELECT documentdb_api_internal.bson_dollar_project(document, '{ "newField": { "$eq": ["$a", "DOG"] } }', '{}', 'en-u-ks-level1') FROM documentdb_api.collection('coll_q_db', 'coll_agg_proj');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": { "$ne": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": { "$lte": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": { "$gte": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 3} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": { "$gte": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }');

-- $replaceRoot — comparison inside the new root document.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$replaceRoot": { "newRoot": { "a": "$a", "newField": { "$eq": ["$a", "CAT"] } } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$replaceRoot": { "newRoot": { "a": "$a", "newField": { "$ne": ["$a", "CAT"] } } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$replaceRoot": { "newRoot": { "a": "$a", "newField": { "$lte": ["$a", "DoG"] } } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$replaceRoot": { "newRoot": { "a": "$a", "newField": { "$gte": ["$a", "doG"] } } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }');

-- $replaceWith (alias of $replaceRoot).
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$replaceWith": { "a": "$a", "newField": { "$eq": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$replaceWith": { "a": "$a", "newField": { "$ne": ["$a", "CAT"] } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$replaceWith": { "a": "$a", "newField": { "$lte": ["$a", "DoG"] } } } ], "cursor": {}, "collation": { "locale": "fr", "strength" : 1} }');

-- $documents — collection-less pipeline source; predicate inside $cond honors collation.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": 1, "pipeline": [ { "$documents": { "$cond": { "if": { "$eq": [ "CaT", "cAt" ] }, "then": [{"result": "case insensitive"}] , "else": [{"res": "case sensitive"}] }} } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": 1, "pipeline": [ { "$documents": { "$cond": { "if": { "$eq": [ "CaT", "cAt" ] }, "then": [{"result": "case insensitive"}] , "else": [{"res": "case sensitive"}] }} } ], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }');

-- $sortArray — element ordering inside an array uses command collation (and numericOrdering).
SELECT documentdb_api.insert_one('coll_q_db', 'coll_sortArray', '{"_id":1,"a":"one", "b":["10","1"]}', NULL);
SELECT documentdb_api.insert_one('coll_q_db', 'coll_sortArray', '{"_id":2,"a":"two", "b":["2","020"]}', NULL);

SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_sortArray", "pipeline": [ { "$project": { "sortedArray": { "$sortArray": { "input": ["cat", "dog", "DOG"], "sortBy": 1 } } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_sortArray", "pipeline": [ { "$project": { "sortedArray": { "$sortArray": { "input": ["cat", "dog", "DOG"], "sortBy": 1 } } } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }');

SELECT document FROM bson_aggregation_find('coll_q_db', '{
  "find": "coll_sortArray",
  "filter": { "a": {"$lte": "two"} },
  "projection": {
    "sortedArray": { "$sortArray": { "input": "$b", "sortBy": 1 } }
  },
  "collation": { "locale": "en", "numericOrdering" : false },
  "limit": 5
}');

SELECT document FROM bson_aggregation_find('coll_q_db', '{
  "find": "coll_sortArray",
  "filter": { "a": {"$lte": "two"} },
  "projection": {
    "sortedArray": { "$sortArray": { "input": "$b", "sortBy": 1 } }
  },
  "collation": { "locale": "en", "numericOrdering" : true },
  "limit": 5
}');

-- find with computed projection ($eq/$ne/$gte) under different strengths.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "projection": { "a": 1, "newField": { "$eq": ["$a", "CAT"] } }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "projection": { "a": 1, "newField": { "$ne": ["$a", "CAT"] } }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 2} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "projection": { "a": 1, "newField": { "$ne": ["$a", "CAT"] } }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 3} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "projection": { "a": 1, "newField": { "$gte": ["$a", "CAT"] } }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_agg_proj", "projection": { "a": 1, "newField": { "$gte": ["$a", "CAT"] } }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 3} }');

-- $redact — $$KEEP / $$PRUNE / $$DESCEND decisions made under collation.
SELECT documentdb_api.insert_one('coll_q_db','coll_redact','{ "_id": 1, "level": "public", "content": "content 1", "details": { "level": "public", "value": "content 1.1", "moreDetails": { "level": "restricted", "info": "content 1.1.1" } } }', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_redact','{ "_id": 2, "level": "restricted", "content": "content 2", "details": { "level": "public", "value": "content 2.1", "moreDetails": { "level": "restricted", "info": "content 2.1.1" } } }', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_redact','{ "_id": 3, "level": "public", "content": "content 3", "details": { "level": "restricted", "value": "content 3.1", "moreDetails": { "level": "public", "info": "content 3.1.1" } } }', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_redact','{ "_id": 4, "content": "content 4", "details": { "level": "public", "value": "content 4.1" } }', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_redact','{ "_id": 5, "level": "public", "content": "content 5", "details": { "level": "public", "value": "content 5.1", "moreDetails": [{ "level": "restricted", "info": "content 5.1.1" }, { "level": "public", "info": "content 5.1.2" }] } }', NULL);

SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_redact", "pipeline": [ { "$redact": { "$cond": { "if": { "$eq": ["$level", "PUBLIC"] }, "then": "$$KEEP", "else": "$$PRUNE" } } }  ], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_redact", "pipeline": [ { "$redact": { "$cond": { "if": { "$eq": ["$level", "puBliC"] }, "then": "$$DESCEND", "else": "$$PRUNE" } } }  ], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_redact", "pipeline": [ { "$redact": { "$switch": { "branches": [ { "case": { "$eq": ["$level", "PUBLIC"] }, "then": "$$PRUNE" }, { "case": { "$eq": ["$classification", "RESTRICTED"] }, "then": { "$cond": { "if": { "$eq": ["$content", null] }, "then": "$$KEEP", "else": "$$PRUNE" } } }], "default": "$$KEEP" } }  }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_redact", "pipeline": [ { "$redact": { "$switch": { "branches": [ { "case": { "$eq": ["$level", "PUBLIC"] }, "then": "$$PRUNE" }, { "case": { "$eq": ["$classification", "RESTRICTED"] }, "then": { "$cond": { "if": { "$eq": ["$content", null] }, "then": "$$KEEP", "else": "$$PRUNE" } } }], "default": "$$KEEP" } }  }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');

-- $setEquals — set equality compares elements under collation.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setEquals": [["$a"], ["CAT"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setEquals": [["$a"], ["DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setEquals": [["$a"], ["DOG", "dOg"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setEquals": [["$a", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setEquals": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setEquals": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }');

-- $setIntersection.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIntersection": [["$a"], ["CAT"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIntersection": [["$a"], ["DOG"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIntersection": [["$a"], ["DOG", "dOg"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIntersection": [["$a", "dog"], ["CAT", "DOG"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIntersection": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIntersection": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }');

-- $setUnion.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setUnion": [["$a"], ["CAT"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setUnion": [["$a"], ["DOG"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setUnion": [["$a"], ["DOG", "dOg"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setUnion": [["$a", "dog"], ["CAT", "DOG"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setUnion": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setUnion": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }');

-- $setDifference.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setDifference": [["$a"], ["CAT"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setDifference": [["$a"], ["DOG"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setDifference": [["$a"], ["DOG", "dOg"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setDifference": [["$a", "dog"], ["CAT", "DOG"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setDifference": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setDifference": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }, { "$project": { "a": 1, "newField": {"$sortArray": {"input": "$newField", "sortBy": 1}} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }');

-- $setIsSubset.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIsSubset": [["$a"], ["CAT"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIsSubset": [["$a"], ["DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIsSubset": [["$a"], ["DOG", "dOg"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 2} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIsSubset": [["$a", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIsSubset": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": {"$setIsSubset": [["$a", "cAT", "dog"], ["CAT", "DOG"]]} } }], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }');

-- $let — variable bindings; the $cond inside `in` honors collation.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": { "$let": { "vars": { "var1": "$a" }, "in": { "$cond": { "if": { "$eq": ["$$var1", "CAT"] }, "then": 1, "else": 0 } } } } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": { "$let": { "vars": { "var1": "$a" }, "in": { "$cond": { "if": { "$eq": ["$$var1", "CAT"] }, "then": 1, "else": 0 } } } } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }');

-- $zip — collation reaches expressions inside the `inputs` clause.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": { "$zip": { "inputs": [ {"$cond": [{"$eq": ["CAT", "$a"]}, ["$a"], ["null"]]}, ["$a"]] } } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_agg_proj", "pipeline": [ { "$project": { "a": 1, "newField": { "$zip": { "inputs": [ {"$cond": [{"$eq": ["CAT", "$a"]}, ["$a"], ["null"]]}, ["$a"]] } } } }], "cursor": {}, "collation": { "locale": "en", "strength" : 3} }');

-- ==============================================================================
-- SECTION 9: aggregation — $lookup, $facet, $unionWith, $graphLookup
-- ==============================================================================

SELECT documentdb_api.insert_one('coll_q_db','coll_lookup_src', '{"_id": "DOG", "a" : { "b" : "DOG" }}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_lookup_src', '{"_id": "dog", "a" : { "b" : "dog" }}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_lookup_src', '{"_id": "Cat", "a" : { "b" : "Cat" }}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_lookup_src', '{"_id": "Dog", "a" : { "b" : "Dog" }}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_lookup_src', '{"_id": "cAT", "a" : { "b" : "cAT" }}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_lookup_src', '{"_id": "DoG", "a" : { "b" : "DoG" }}', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_lookup_src', '{"_id": "dOg", "a" : { "b" : "dOg" }}', NULL);

-- $lookup with _id join — nested $match honors collation; the _id equality itself stays exact.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', 
    '{ "aggregate": "coll_lookup_src", "pipeline": [ { "$lookup": { "from": "coll_lookup_src", "as": "matched_docs", "localField": "_id", "foreignField": "_id", "pipeline": [ { "$match": { "$or" : [ { "a.b": "cat" }, { "a.b": "dog" } ] } } ] } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');

-- $lookup with _id join (repeat) — verifies _id-join optimization keeps the same result.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', 
    '{ "aggregate": "coll_lookup_src", "pipeline": [ { "$lookup": { "from": "coll_lookup_src", "as": "matched_docs", "localField": "_id", "foreignField": "_id", "pipeline": [ { "$match": { "$or" : [ { "a.b": "cat" }, { "a.b": "dog" } ] } } ] } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');

-- $lookup on non-_id field — both the join key match and the nested $match honor collation.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', 
    '{ "aggregate": "coll_lookup_src", "pipeline": [ { "$lookup": { "from": "coll_lookup_src", "as": "matched_docs", "localField": "a.b", "foreignField": "a.b", "pipeline": [ { "$match": { "$or" : [ { "a.b": "cat" }, { "a.b": "dog" } ] } } ] } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');

-- $lookup joining a non-_id localField to the _id foreignField. Because the foreign key is
-- _id this exercises the right-side _id-join path; under a collation the match is collation-
-- aware (never byte-wise), so each a.b value matches every _id the collation deems equal.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', 
    '{ "aggregate": "coll_lookup_src", "pipeline": [ { "$lookup": { "from": "coll_lookup_src", "as": "matched_docs", "localField": "a.b", "foreignField": "_id" } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}  }');

-- $facet — sub-pipelines inherit command collation.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_lookup_src", "pipeline": [ { "$facet": { "a" : [ { "$match": { "a.b": "cat" } }, { "$count": "catCount" } ], "b" : [ { "$match": { "a.b": "dog" } }, { "$count": "dogCount" } ]  } } ], "cursor": {}, "collation": { "locale": "en", "strength" : 1}}');

-- $unionWith — sub-pipeline $match honors command collation.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_lookup_src", "pipeline": [ { "$unionWith": { "coll": "coll_lookup_src", "pipeline" : [ { "$match": { "a.b": "cat" }}] } }], "cursor": {}, "collation": { "locale": "en", "strength" : 1} }');

-- $graphLookup — traversal across `connectFromField`/`connectToField` uses command collation.
SELECT documentdb_api.insert_one('coll_q_db','coll_graph_src', '{"_id": "alice", "pet" : "dog" }', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_graph_src', '{"_id": "bob", "pet" : "cat" }', NULL);

SELECT documentdb_api.insert_one('coll_q_db','coll_graph_target', '{"_id": "DOG", "name" : "DOG" }', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_graph_target', '{"_id": "dog", "name" : "dog" }', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_graph_target', '{"_id": "CAT", "name" : "CAT" }', NULL);
SELECT documentdb_api.insert_one('coll_q_db','coll_graph_target', '{"_id": "cAT", "name" : "cAT" }', NULL);

-- en/strength=3 — case-sensitive: only exact-case matches connect.
SELECT document FROM bson_aggregation_pipeline('coll_q_db',
    '{ "aggregate": "coll_graph_src", "pipeline": [ { "$graphLookup": { "from": "coll_graph_target", "startWith": "$pet", "connectFromField": "name", "connectToField": "_id", "as": "destinations", "depthField": "depth" } } ],  "collation": { "locale": "en", "strength" : 3} }');

-- Self-join graphLookup on a.b at strength=1 — full case-insensitive component traversal.
SELECT document FROM bson_aggregation_pipeline('coll_q_db',
    '{ "aggregate": "coll_lookup_src", "pipeline": [ { "$graphLookup": { "from": "coll_lookup_src", "startWith": "$a.b", "connectFromField": "a.b", "connectToField": "a.b", "as": "destinations", "depthField": "depth" } } ],  "collation": { "locale": "en", "strength" : 1} }');

-- en/strength=1 / 2: case-insensitive across DOG/dog/Dog and CAT/cAT.
SELECT document FROM bson_aggregation_pipeline('coll_q_db',
    '{ "aggregate": "coll_graph_src", "pipeline": [ { "$graphLookup": { "from": "coll_graph_target", "startWith": "$pet", "connectFromField": "name", "connectToField": "_id", "as": "destinations", "depthField": "depth" } } ],  "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db',
    '{ "aggregate": "coll_graph_src", "pipeline": [ { "$graphLookup": { "from": "coll_graph_target", "startWith": "$pet", "connectFromField": "name", "connectToField": "_id", "as": "destinations", "depthField": "depth" } } ],  "collation": { "locale": "en", "strength" : 2} }');

-- Locale + alternate / caseFirst variants.
SELECT document FROM bson_aggregation_pipeline('coll_q_db',
    '{ "aggregate": "coll_graph_src", "pipeline": [ { "$graphLookup": { "from": "coll_graph_target", "startWith": "$pet", "connectFromField": "name", "connectToField": "_id", "as": "destinations", "depthField": "depth" } } ],  "collation": { "locale": "fr", "strength" : 1, "alternate": "shifted" } }');
SELECT document FROM bson_aggregation_pipeline('coll_q_db',
    '{ "aggregate": "coll_graph_src", "pipeline": [ { "$graphLookup": { "from": "coll_graph_target", "startWith": "$pet", "connectFromField": "name", "connectToField": "_id", "as": "destinations", "depthField": "depth" } } ],  "collation": { "locale": "hi", "strength" : 2, "caseFirst": "lower" } }');

-- $graphLookup at en/strength=3 — repeat for stability.
SELECT document FROM bson_aggregation_pipeline('coll_q_db',
    '{ "aggregate": "coll_graph_src", "pipeline": [ { "$graphLookup": { "from": "coll_graph_target", "startWith": "$pet", "connectFromField": "name", "connectToField": "_id", "as": "destinations", "depthField": "depth" } } ],  "collation": { "locale": "en", "strength" : 3} }');

-- ==============================================================================
-- SECTION 10: operators — bson_query_match
-- ==============================================================================

-- enableCollation = off: collation argument is ignored (no error, no match).
SET documentdb_core.enableCollation TO off;

SELECT documentdb_api_internal.bson_query_match('{"a": "cat"}', '{"a": "CAT"}', '{}', 'en-u-ks-level1');

-- enableCollation = on: collation argument is honored.
SET documentdb_core.enableCollation TO on;

-- _id field is collation-aware in bson_query_match.
SELECT documentdb_api_internal.bson_query_match('{"_id": "cat"}', '{"_id": "CAT"}', '{}', 'en-u-ks-level1');
SELECT documentdb_api_internal.bson_query_match('{"_id": "cat"}', '{"_id": "CAT"}', '{}', 'en-u-ks-level2');
SELECT documentdb_api_internal.bson_query_match('{"_id": "cat"}', '{"_id": "CAT"}', '{}', 'en-US-u-ks-level2');

-- $eq with various locales/strengths.
SELECT documentdb_api_internal.bson_query_match('{"a": "cat"}', '{"a": "CAT"}', '{}', 'en-u-ks-level1');
SELECT documentdb_api_internal.bson_query_match('{"a": "cat"}', '{ "a": {"$eq" : "CAT"} }', '{}', 'de-u-ks-level1');
SELECT documentdb_api_internal.bson_query_match('{"a": "cat"}', '{ "a": {"$eq" : "càt"} }', '{}', 'fr-u-ks-level3');
SELECT documentdb_api_internal.bson_query_match('{"a": "cat", "b": "dog"}', '{"a": "CAT", "b": "DOG"}', '{}', 'en-u-ks-level1');
SELECT documentdb_api_internal.bson_query_match('{"a": "cat", "b": "dog"}', '{"a": "CAT", "b": "DOG"}', '{}', 'sv-u-ks-level1');

-- $ne — negation under collation.
SELECT documentdb_api_internal.bson_query_match('{"a": "cat"}', '{ "a": {"$ne" : "CAT"} }', '{}', 'de-u-ks-level1');
SELECT documentdb_api_internal.bson_query_match('{"a": "cat"}', '{ "a": {"$ne" : "càt"} }', '{}', 'fr-u-ks-level3');
SELECT documentdb_api_internal.bson_query_match('{"a": "cat", "b": "dog"}', '{"a": "CAT", "b": "DOG"}', '{}', 'en-u-ks-level1');
SELECT documentdb_api_internal.bson_query_match('{"a": "cat", "b": "dog"}', '{"a": "CAT", "b": "DOG"}', '{}', 'sv-u-ks-level1');

-- $gt / $gte.
SELECT documentdb_api_internal.bson_query_match('{"a": "cat"}', '{ "a": {"$gt" : "CAT"} }', '{}', 'de-u-ks-level1');
SELECT documentdb_api_internal.bson_query_match('{"a": "cat"}', '{ "a": {"$gte" : "CAT"} }', '{}', 'en-u-ks-level1');

-- $lt / $lte.
SELECT documentdb_api_internal.bson_query_match('{"a": "cat"}', '{ "a": {"$lte" : "CAT"} }', '{}', 'de-u-ks-level1');
SELECT documentdb_api_internal.bson_query_match('{"a": "cat"}', '{ "a": {"$lte" : "càt"} }', '{}', 'fr-u-ks-level3');
SELECT documentdb_api_internal.bson_query_match('{"a": "cat"}', '{ "a": {"$lte" : "càt"} }', '{}', 'fr-CA-u-ks-level3');

-- $in.
SELECT documentdb_api_internal.bson_query_match('{"a": "cat"}', '{ "a": {"$in" : ["CAT", "DOG"]} }', '{}', 'de-u-ks-level1');
SELECT documentdb_api_internal.bson_query_match('{"a": "cat"}', '{ "a": {"$in" : ["càt", "dòg"]} }', '{}', 'fr-u-ks-level3');

-- $nin.
SELECT documentdb_api_internal.bson_query_match('{"a": "cat"}', '{ "a": {"$nin" : ["CAT", "DOG"]} }', '{}', 'en-u-ks-level1');
SELECT documentdb_api_internal.bson_query_match('{"a": "cat"}', '{ "a": {"$nin" : ["càt", "dòg"]} }', '{}', 'fr-u-ks-level3');

-- Nested arrays — array element comparison honors collation.
SELECT documentdb_api_internal.bson_query_match('{"a": ["cat"]}', '{ "a": {"$in" : [["CAT"], "DOG"]} }', '{}', 'de-u-ks-level1');
SELECT documentdb_api_internal.bson_query_match('{"a": ["cat"]}', '{ "a": {"$in" : [["CAT"], ["DOG"]] } }', '{}', 'de-u-ks-level3');

SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays', '{ "_id": 1, "a": ["dog"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays', '{ "_id": 2, "a": ["cat", "dog"] }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays', '{ "_id": 3, "a": [[["cat"]]] }');

SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_arrays", "filter": { "a" : {"$in" : [ ["dOG"] ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_arrays", "filter": { "a" : {"$in" : [ [["CAT"]] ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_arrays", "filter": { "a" : {"$in" : [["CAT"], ["DOG"]] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');

-- Nested documents — string values inside sub-documents honor collation.
SELECT documentdb_api_internal.bson_query_match('{"a": {"b": "cat"}}', '{ "a": {"b": "CAT"} }', '{}', 'en-u-ks-level1');
SELECT documentdb_api_internal.bson_query_match('{"a": {"b": {"c": "cat"}}}', '{ "a": {"b": {"c": "CAT"}} }', '{}', 'en-u-ks-level2');

SELECT documentdb_api.insert_one('coll_q_db', 'nested_docs', '{ "_id": 1, "a": { "b": "cat" } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_docs', '{ "_id": 2, "a": { "b": "dog" } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_docs', '{ "_id": 3, "a": { "b": { "c": "cat" } } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_docs', '{ "_id": 4, "a": { "b": { "c": "dog" } } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_docs', '{ "_id": 5, "a": { "b": { "c": { "d": "cat" } } } }');

SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_docs", "filter": { "a" : {"$in" : [ {"b": "dOG"} ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_docs", "filter": { "a" : {"$in" : [ {"b": { "c": "dOg" }} ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_docs", "filter": { "a" : {"$in" : [ {"b": { "c": { "d": "dOg" }}} ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');

-- Nested document keys are collation-agnostic ("B" ≠ "b" even at strength 1).
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_docs", "filter": { "a" : {"$in" : [ {"B": "dOG"} ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');

-- Mix of nested arrays and documents.
SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays_docs', '{ "_id": 1, "a": { "b": ["cat"] } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays_docs', '{ "_id": 2, "a": { "b": ["dog"] } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays_docs', '{ "_id": 3, "a": { "b": ["cat", "dog"] } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays_docs', '{ "_id": 4, "a": {"b": [["dog"]] } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays_docs', '{ "_id": 5, "a": { "b": [[["cat"]]] } }');
SELECT documentdb_api.insert_one('coll_q_db', 'nested_arrays_docs', '{ "_id": 6, "a": "cat" }');

SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_arrays_docs", "filter": { "a" : {"$in" : [ {"b": ["dOG"]}, "CAT" ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "nested_arrays_docs", "filter": { "a" : {"$in" : [ {"b": [["dOg"]] } ] }}, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1} }');

-- ==============================================================================
-- SECTION 11: operators — positional projection and bson_dollar_* family
-- ==============================================================================

-- find with positional projection (`b.$`) — collation drives both the top-level $eq and the $elemMatch.
SELECT documentdb_api.insert_one('coll_q_db', 'coll_find_positional', '{"_id":1, "a":"cat", "b":[{"a":"cat"},{"a":"caT"}], "c": ["cat"]}', NULL);
SELECT documentdb_api.insert_one('coll_q_db', 'coll_find_positional', '{"_id":2, "a":"dog", "b":[{"a":"dog"},{"a":"doG"}], "c": ["dog"]}', NULL);
SELECT documentdb_api.insert_one('coll_q_db', 'coll_find_positional', '{"_id":3, "a":"caT", "b":[{"a":"caT"},{"a":"cat"}], "c": ["caT"]}', NULL);

-- strength 3: case-sensitive — only exact-case "CAT" matches (none here).
SELECT document FROM bson_aggregation_find('coll_q_db', '{
  "find": "coll_find_positional",
  "filter": { "a": "CAT", "b": { "$elemMatch": { "a": "CAT" } } },
  "projection": { "_id": 1, "b.$": 1 },
  "sort": { "_id": 1 },
  "skip": 0,
  "limit": 5,
  "collation": { "locale": "en", "strength" : 3}
}');

-- strength 1: case-insensitive — matches both cat and caT docs.
SELECT document FROM bson_aggregation_find('coll_q_db', '{
  "find": "coll_find_positional",
  "filter": { "a": "CAT", "b": { "$elemMatch": { "a": "CAT" } } },
  "projection": { "_id": 1, "b.$": 1 },
  "sort": { "_id": 1 },
  "skip": 0,
  "limit": 5,
  "collation": { "locale": "en", "strength" : 1 }
}');

SELECT documentdb_api.drop_collection('coll_q_db', 'coll_find_positional');

-- ----------------------------------------------------------------
-- $in: [] short-circuit through bson_dollar_* helpers.
-- ----------------------------------------------------------------
SELECT documentdb_api.insert_one('coll_q_db', 'coll_in_empty', '{"_id": 1, "name": "cat", "sound": "meow"}');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_in_empty', '{"_id": 2, "name": "dog", "sound": "woof"}');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_in_empty', '{"_id": 3, "sound": "moo"}');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_in_empty', '{"_id": 4, "name": "sheep", "sound": "baa"}');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_in_empty', '{"_id": 5, "name": "duck"}');

-- $addFields downstream — baseline / +let / +collation / +let+collation.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "coll_in_empty", 
  "pipeline": [ {"$match": {"_id": { "$in": [] }}}, { "$addFields": { "newField": "animal" } } ], 
  "cursor": {} }');

SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "coll_in_empty", 
  "pipeline": [ {"$match": {"_id": { "$in": [] }}}, { "$addFields": { "newField": "animal" } } ], 
  "let": { "varRef": "lion"},
  "cursor": {} }');

SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "coll_in_empty", 
  "pipeline": [ {"$match": {"_id": { "$in": [] }}}, { "$addFields": { "newField": "animal" } } ], 
  "collation": { "locale": "en", "strength" : 1},
  "cursor": {} }');

SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "coll_in_empty", 
  "pipeline": [ {"$match": {"sound": "moo", "_id": { "$in": [] }}}, { "$addFields": { "newField": "$$varRef" } } ], 
  "let": { "varRef": "lion"},
  "collation": { "locale": "en", "strength" : 1},
  "cursor": {} }');

-- $redact downstream — baseline / +let / +collation / +let+collation.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "coll_in_empty", 
  "pipeline": [ {"$match": {"_id": { "$in": [] }}}, { "$redact": { "$cond": [ { "$eq": [ "$sound", "meow" ] }, "$$KEEP", "$$PRUNE" ] } } ], 
  "cursor": {} }');

SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "coll_in_empty", 
  "pipeline": [ {"$match": {"owner": { "$in": [] }}}, { "$redact": { "$cond": [ { "$eq": [ "$sound", "meow" ] }, "$$KEEP", "$$PRUNE" ] } } ], 
  "let": { "varRef": "lion"},
  "cursor": {} }');

SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "coll_in_empty", 
  "pipeline": [ {"$match": {"sound": { "$in": [] }}}, { "$redact": { "$cond": [ { "$eq": [ "$sound", "meow" ] }, "$$KEEP", "$$PRUNE" ] } } ], 
  "collation": { "locale": "en", "strength" : 1},
  "cursor": {} }');

SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "coll_in_empty", 
  "pipeline": [ {"$match": {"_id": { "$in": [] }}}, { "$redact": { "$cond": [ { "$eq": [ "$sound", "meow" ] }, "$$KEEP", "$$PRUNE" ] } } ], 
  "let": { "varRef": "lion"},
  "collation": { "locale": "en", "strength" : 1},
  "cursor": {} }');

-- $project downstream (bson_dollar_project) — baseline / +let / +collation / +let+collation.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "coll_in_empty", 
  "pipeline": [ {"$match": {"name": { "$in": [] }}}, { "$project": { "_id": 0, "sound": 1 } } ], 
  "cursor": {} }');

SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "coll_in_empty", 
  "pipeline": [ {"$match": {"_id": { "$in": [] } }}, { "$project": { "_id": 0, "name": 1, "varEcho": "$$varRef" } } ], 
  "let": { "varRef": "lion"},
  "cursor": {} }');

SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "coll_in_empty", 
  "pipeline": [ {"$match": {"_id": { "$in": [] } }}, { "$project": { "_id": 0, "name": 1 } } ], 
  "collation": { "locale": "en", "strength" : 1},
  "cursor": {} }');

SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "coll_in_empty", 
  "pipeline": [ {"$match": {"_id": { "$in": [] } }}, { "$project": { "_id": 0, "name": 1, "varEcho": "$$varRef" } } ], 
  "let": { "varRef": "lion"},
  "collation": { "locale": "en", "strength" : 1},
  "cursor": {} }');

-- $replaceRoot downstream (bson_dollar_replace_root) — baseline / +let / +collation / +let+collation.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "coll_in_empty", 
  "pipeline": [ {"$match": {"name": {"$in": [] } }}, { "$replaceRoot": { "newRoot": { "animal": "$name", "call": "$sound" } } } ], 
  "cursor": {} }');

SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "coll_in_empty", 
  "pipeline": [ {"$match": {"name": {"$in": [] } }}, { "$replaceRoot": { "newRoot": { "animal": "$$varRef", "call": "$sound" } } } ], 
  "let": { "varRef": "lion"},
  "cursor": {} }');

SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "coll_in_empty", 
  "pipeline": [ {"$match": {"name": {"$in": [] } }}, { "$replaceRoot": { "newRoot": { "animal": "$name", "call": "$sound" } } } ], 
  "collation": { "locale": "en", "strength" : 1},
  "cursor": {} }');

SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ 
  "aggregate": "coll_in_empty", 
  "pipeline": [ {"$match": {"name": {"$in": [] } }}, { "$replaceRoot": { "newRoot": { "animal": "$$varRef", "call": "$sound" } } } ], 
  "let": { "varRef": "lion"},
  "collation": { "locale": "en", "strength" : 1},
  "cursor": {} }');

-- find-projection (bson_dollar_project_find) with let + collation.
SELECT document FROM bson_aggregation_find('coll_q_db', '{
  "find": "coll_in_empty",
  "filter": {
    "_id": { "$in": [] }
  },
  "projection": { "name": true },
  "let": { "varRef": "lion" },
  "collation": { "locale": "en", "strength" : 1 }
}');

SELECT documentdb_api.drop_collection('coll_q_db', 'coll_in_empty');

-- ==============================================================================
-- SECTION 12: operators — bson_expression_get / bson_expression_partition_get
-- ==============================================================================

-- $eq.
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$eq": ["$a", "cat"] } }'::bson, false, '{}'::bson, '');
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$eq": ["$a", "cat"] } }'::bson, false, '{}'::bson, 'en-u-ks-level1');

-- $ne.
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$ne": ["$a", "cat"] } }'::bson, false, '{}'::bson, '');
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$ne": ["$a", "cat"] } }'::bson, false, '{}'::bson, 'en-u-ks-level1');

-- $cmp.
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$cmp": ["$a", "cat"] } }'::bson, false, '{}'::bson, '');
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$cmp": ["$a", "cat"] } }'::bson, false, '{}'::bson, 'en-u-ks-level1');

-- $gt.
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "cat" }'::bson, '{ "result": { "$gt": ["$a", "Cat"] } }'::bson, false, '{}'::bson, '');
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "cat" }'::bson, '{ "result": { "$gt": ["$a", "Cat"] } }'::bson, false, '{}'::bson, 'en-u-ks-level1');

-- $gte.
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$gte": ["$a", "cat"] } }'::bson, false, '{}'::bson, '');
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$gte": ["$a", "cat"] } }'::bson, false, '{}'::bson, 'en-u-ks-level1');

-- $lt.
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$lt": ["$a", "cat"] } }'::bson, false, '{}'::bson, '');
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$lt": ["$a", "cat"] } }'::bson, false, '{}'::bson, 'en-u-ks-level1');

-- $lte.
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "cat" }'::bson, '{ "result": { "$lte": ["$a", "Cat"] } }'::bson, false, '{}'::bson, '');
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "cat" }'::bson, '{ "result": { "$lte": ["$a", "Cat"] } }'::bson, false, '{}'::bson, 'en-u-ks-level1');

-- $cond — predicate inside the conditional honors collation.
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$cond": [{ "$eq": ["$a", "cat"] }, "matched", "no_match"] } }'::bson, false, '{}'::bson, '');
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$cond": [{ "$eq": ["$a", "cat"] }, "matched", "no_match"] } }'::bson, false, '{}'::bson, 'en-u-ks-level1');

-- $in (expression operator) — set membership honors collation.
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$in": ["$a", ["cat", "dog"]] } }'::bson, false, '{}'::bson, '');
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$in": ["$a", ["cat", "dog"]] } }'::bson, false, '{}'::bson, 'en-u-ks-level1');

-- $and — both branches evaluated under collation.
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "Cat", "b": "Dog" }'::bson, '{ "result": { "$and": [{ "$eq": ["$a", "cat"] }, { "$eq": ["$b", "dog"] }] } }'::bson, false, '{}'::bson, 'en-u-ks-level1');

-- Strength variation: 2 (case-insensitive) vs 3 (case-sensitive).
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$eq": ["$a", "cat"] } }'::bson, false, '{}'::bson, 'en-u-ks-level2');
SELECT documentdb_api_internal.bson_expression_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$eq": ["$a", "cat"] } }'::bson, false, '{}'::bson, 'en-u-ks-level3');

-- bson_expression_partition_get — the partitioning variant also honors collation.
SELECT documentdb_api_internal.bson_expression_partition_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$eq": ["$a", "cat"] } }'::bson, false, '{}'::bson, '');
SELECT documentdb_api_internal.bson_expression_partition_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$eq": ["$a", "cat"] } }'::bson, false, '{}'::bson, 'en-u-ks-level1');
SELECT documentdb_api_internal.bson_expression_partition_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$cmp": ["$a", "cat"] } }'::bson, false, '{}'::bson, '');
SELECT documentdb_api_internal.bson_expression_partition_get(
  '{ "a": "Cat" }'::bson, '{ "result": { "$cmp": ["$a", "cat"] } }'::bson, false, '{}'::bson, 'en-u-ks-level1');

-- ==============================================================================
-- SECTION 13: write — delete with collation
-- ==============================================================================

SELECT documentdb_api.insert_one('coll_q_db', 'coll_delete', '{"_id": "dog", "a":"dog"}');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_delete', '{"_id": "DOG", "a":"DOG"}');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_delete', '{"_id": "cat", "a":"cat"}');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_delete', '{"_id": "CAT", "a":"CAT"}');

-- enableCollation = off: collation argument silently ignored, delete uses byte-exact match.
SET documentdb_core.enableCollation TO off;

BEGIN;
SELECT documentdb_api.delete('coll_q_db', '{ "delete": "coll_delete", "deletes": [ {"q": {"_id": "DoG" }, "limit": 0, "collation": { "locale": "fr", "strength" : 2}} ]}');
ROLLBACK;

-- enableCollation = on for the rest of the section.
SET documentdb_core.enableCollation TO on;

-- _id equality pushes down, but a string _id still uses the supplied collation
-- for the comparison ("DoG"/"cAT" match "dog"/"cat" at strength=2/3).
BEGIN;
SET citus.log_remote_commands TO ON;

SELECT documentdb_api.delete('coll_q_db', '{ "delete": "coll_delete", "deletes": [ {"q": {"_id": 1 }, "limit": 0, "collation": { "locale": "fr", "strength" : 2}} ]}');
SELECT documentdb_api.delete('coll_q_db', '{ "delete": "coll_delete", "deletes": [ {"q": {"_id": "DoG" }, "limit": 0, "collation": { "locale": "fr", "strength" : 2}} ]}');
SELECT documentdb_api.delete('coll_q_db', '{ "delete": "coll_delete", "deletes": [ {"q": {"_id": "cAT" }, "limit": 0, "collation": { "locale": "fr", "strength" : 3}} ]}');
ROLLBACK;

-- deleteMany on a non-_id field — strength 1 vs strength 3 controls how many rows match.
BEGIN;
SELECT document from documentdb_api.collection('coll_q_db', 'coll_delete');
SELECT documentdb_api.delete('coll_q_db', '{ "delete": "coll_delete", "deletes": [ { "q": {"a": "CaT" }, "limit": 0, "collation": { "locale": "en", "strength" : 3}}]}');
SELECT documentdb_api.delete('coll_q_db', '{ "delete": "coll_delete", "deletes": [ { "q": {"a": "CaT" }, "limit": 0, "collation": { "locale": "en", "strength" : 1}}]}');
SELECT documentdb_api.delete('coll_q_db', '{ "delete": "coll_delete", "deletes": [ { "q": {"a": "DoG" }, "limit": 0, "collation": { "locale": "en", "strength" : 3}}]}');
SELECT documentdb_api.delete('coll_q_db', '{ "delete": "coll_delete", "deletes": [ { "q": {"a": "DoG" }, "limit": 0, "collation": { "locale": "en", "strength" : 1}}]}');
SELECT document from documentdb_api.collection('coll_q_db', 'coll_delete');
ROLLBACK;

-- deleteOne (limit: 1) — same matching, but at most one row removed per call.
BEGIN;
SELECT document from documentdb_api.collection('coll_q_db', 'coll_delete');
SELECT documentdb_api.delete('coll_q_db', '{ "delete": "coll_delete", "deletes": [ { "q": {"a": "CaT" }, "limit": 1, "collation": { "locale": "en", "strength" : 1}}]}');
SELECT documentdb_api.delete('coll_q_db', '{ "delete": "coll_delete", "deletes": [ { "q": {"a": "CaT" }, "limit": 1, "collation": { "locale": "en", "strength" : 3}}]}');
SELECT documentdb_api.delete('coll_q_db', '{ "delete": "coll_delete", "deletes": [ { "q": {"a": "DoG" }, "limit": 1, "collation": { "locale": "en", "strength" : 1}}]}');
SELECT documentdb_api.delete('coll_q_db', '{ "delete": "coll_delete", "deletes": [ { "q": {"a": "DoG" }, "limit": 1, "collation": { "locale": "en", "strength" : 3}}]}');
SELECT document from documentdb_api.collection('coll_q_db', 'coll_delete');
ROLLBACK;

-- Range / multi-operator query predicates ($lt, $gt, $exists) under collation.
BEGIN;
SELECT documentdb_api.delete('coll_q_db', '{ "delete": "coll_delete", "deletes": [ {"q": {"a": {"$lt": "DeG"} },"limit": 1, "collation": { "locale": "fr", "strength" : 1} }] }');
SELECT documentdb_api.delete('coll_q_db', '{ "delete": "coll_delete", "deletes": [ {"q": {"a": {"$lt": "DoG"}, "a": {"$lt": "Goat"} },"limit": 1, "collation": { "locale": "fr", "strength" : 2} }] }');
SELECT documentdb_api.delete('coll_q_db', '{ "delete": "coll_delete", "deletes": [ {"q": {"a": { "$exists": true }, "a": {"$gt": "DoG"}, "a": {"$lt": "goat"} },"limit": 1, "collation": { "locale": "fr", "strength" : 1 } }] }');

SELECT document from documentdb_api.collection('coll_q_db', 'coll_delete');
ROLLBACK;

-- delete with sort: sort ordering uses collation, so deleteOne picks the right row.
SELECT documentdb_api.insert_one('coll_q_db', 'coll_delete_sort', '{"_id": "dog", "a": "dog"}');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_delete_sort', '{"_id": "DOG", "a": "dog"}');

-- Sort ASC by `_id` — strength 3 picks the case-sensitively smaller _id.
BEGIN;
SELECT document from documentdb_api.collection('coll_q_db', 'coll_delete_sort');

SELECT collection_id AS coll_delete_sort FROM documentdb_api_catalog.collections WHERE database_name = 'coll_q_db' AND collection_name = 'coll_delete_sort' \gset
SELECT documentdb_api_internal.delete_worker(
    p_collection_id=>:coll_delete_sort,
    p_shard_key_value=>:coll_delete_sort,
    p_shard_oid => 0,
    p_update_internal_spec => '{ "deleteOne": { "query": { "a": "dog" }, "collation": "en-u-ks-level3",  "sort": { "_id": 1 }, "returnDocument": 1, "returnFields": { "a": 0} } }'::bson,
    p_update_internal_docs=>null::bsonsequence,
    p_transaction_id=>null::text
) FROM documentdb_api.collection('coll_q_db', 'coll_delete_sort');
    
SELECT document from documentdb_api.collection('coll_q_db', 'coll_delete_sort');
ROLLBACK;

-- Sort DESC by `_id` — strength 3 picks the case-sensitively larger _id.
BEGIN;
SELECT document from documentdb_api.collection('coll_q_db', 'coll_delete_sort');

SELECT collection_id AS coll_delete_sort FROM documentdb_api_catalog.collections WHERE database_name = 'coll_q_db' AND collection_name = 'coll_delete_sort' \gset
SELECT documentdb_api_internal.delete_worker(
    p_collection_id=>:coll_delete_sort,
    p_shard_key_value=>:coll_delete_sort,
    p_shard_oid => 0,
    p_update_internal_spec => '{ "deleteOne": { "query": { "a": "dog" }, "collation": "en-u-ks-level3",  "sort": { "_id": -1 }, "returnDocument": 1, "returnFields": { "a": 0} } }'::bson,
    p_update_internal_docs=>null::bsonsequence,
    p_transaction_id=>null::text
) FROM documentdb_api.collection('coll_q_db', 'coll_delete_sort');
    
SELECT document from documentdb_api.collection('coll_q_db', 'coll_delete_sort');
ROLLBACK;

-- $in: [] short-circuit on delete — matches nothing regardless of collation.
BEGIN;
SELECT document from documentdb_api.collection('coll_q_db', 'coll_delete');
SELECT documentdb_api.delete('coll_q_db', '{ "delete": "coll_delete", "deletes": [ { "q": {"_id": {"$in": []} }, "limit": 0, "collation": { "locale": "en", "strength" : 1}}]}');
SELECT documentdb_api.delete('coll_q_db', '{ "delete": "coll_delete", "deletes": [ { "q": {"_id": {"$in": []} }, "limit": 1, "collation": { "locale": "en", "strength" : 1}}]}');
ROLLBACK;

SELECT documentdb_api.drop_collection('coll_q_db', 'coll_delete');
SELECT documentdb_api.drop_collection('coll_q_db', 'coll_delete_sort');

-- ==============================================================================
-- SECTION 14: errors — invalid collation options
-- ==============================================================================

-- Each query exercises a different invalid combination (alternate, locale, caseFirst, strength).
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1, "caseLevel": true, "caseFirst": "upper", "numericOrdering": true, "alternate": "none"} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en_DB", "strength" : 1, "caseLevel": true, "caseFirst": "upper", "numericOrdering": true, "alternate": "shifted"} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1, "caseLevel": true, "caseFirst": "bad", "numericOrdering": true} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 0, "caseLevel": true, "caseFirst": "bad", "numericOrdering": true} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : -1, "caseLevel": true, "caseFirst": "bad", "numericOrdering": true} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 6, "caseLevel": true, "caseFirst": "bad", "numericOrdering": true} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "abcd", "strength" : 1, "caseLevel": true, "caseFirst": "upper", "numericOrdering": true} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "fr_FR", "strength" : 1, "caseLevel": true, "caseFirst": "lower", "numericOrdering": true} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1, "caseLevel": true, "caseFirst": "upper", "numericOrdering": true, "alternate": "shifted", "backwards" : "0"} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1, "caseLevel": true, "caseFirst": "lower", "numericOrdering": true, "alternate": "non-ignorable", "backwards" : true, "normalization" : 1} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 1, "caseLevel": true, "caseFirst": "lower", "numericOrdering": true, "alternate": "non-ignorable", "backwards" : true, "normalization" : true} }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_multi_collation", "filter": { "$or" : [{ "a": { "$eq": "cat" } }, { "b": { "$eq": "DOG" } }] }, "sort": { "_id": 1 }, "skip": 0, "limit": 5, "collation": { "locale": "en", "strength" : 0.9 } }');

-- ==============================================================================
-- SECTION 15: collation parsing
-- ==============================================================================

-- Missing locale: must be rejected.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": {}, "sort": { "_id": 1 }, "limit": 1, "collation": { "strength": 1 } }');

-- alternate / maxVariable / backwards: parse, validate, and apply.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": { "a": "cat" }, "sort": { "_id": 1 }, "limit": 1, "collation": { "locale": "en", "alternate": "shifted" } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": { "a": "cat" }, "sort": { "_id": 1 }, "limit": 1, "collation": { "locale": "en", "alternate": "shifted", "maxVariable": "space" } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": { "a": "cat" }, "sort": { "_id": 1 }, "limit": 1, "collation": { "locale": "fr", "strength": 2, "backwards": true } }');

-- maxVariable without alternate parses; -kv- is suppressed (only meaningful with shifted).
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": { "a": "cat" }, "sort": { "_id": 1 }, "limit": 1, "collation": { "locale": "en", "maxVariable": "space" } }');

-- Invalid enums and wrong types: rejected at parse time.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": {}, "collation": { "locale": "en", "alternate": "bogus" } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": {}, "collation": { "locale": "en", "alternate": "shifted", "maxVariable": "bogus" } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": {}, "collation": { "locale": "en", "backwards": "true" } }');

-- Locale lookup table entries.
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": { "a": "cat" }, "sort": { "_id": 1 }, "limit": 1, "collation": { "locale": "sr_Latn", "strength": 1 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": { "a": "cat" }, "sort": { "_id": 1 }, "limit": 1, "collation": { "locale": "ko@collation=unihan", "strength": 1 } }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_strings", "filter": { "a": "cat" }, "sort": { "_id": 1 }, "limit": 1, "collation": { "locale": "zh@collation=zhuyin", "strength": 1 } }');

-- @collation= suffix is stripped from the ICU language tag (see explain output).
SELECT documentdb_api.insert_one('coll_q_db', 'coll_phonebook', '{ "_id": 1, "name": "Mueller" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_phonebook', '{ "_id": 2, "name": "Müller" }');
SELECT documentdb_api.insert_one('coll_q_db', 'coll_phonebook', '{ "_id": 3, "name": "Schmidt" }');
SELECT document FROM bson_aggregation_find('coll_q_db', '{ "find": "coll_phonebook", "filter": { "name": "Mueller" }, "sort": { "_id": 1 }, "collation": { "locale": "de@collation=phonebook", "strength": 1 } }');

-- ==============================================================================
-- SECTION 19: unsupported — aggregation stages
-- ==============================================================================

-- $bucket
SELECT document FROM bson_aggregation_pipeline('coll_q_db', 
'{
    "aggregate": "coll_strings",
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
}');

-- $geoNear
SELECT document FROM bson_aggregation_pipeline('coll_q_db',
'{ "aggregate": "coll_strings",
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
}');

-- $fill
SELECT document FROM bson_aggregation_pipeline('coll_q_db', 
'{
    "aggregate": "coll_strings",
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
}');

-- $group
SELECT document FROM bson_aggregation_pipeline('coll_q_db',
'{ "aggregate": "coll_strings",
   "pipeline": [
     { "$group": {
         "_id": "$a",
         "set": { "$addToSet": "$a" }
     }}
   ],
   "collation": { "locale": "en", "strength": 1 }
}');

-- $setWindowFields
SELECT document FROM bson_aggregation_pipeline('coll_q_db',
'{ "aggregate": "coll_strings",
   "pipeline": [
     { "$setWindowFields": {
         "sortBy": { "_id": 1 },
         "output": {
             "total": { "$eq": ["$a", "cAt"] }
         }
     }}
   ],
   "collation": { "locale": "en", "strength": 1 }
}');

-- $sortByCount
SELECT document FROM bson_aggregation_pipeline('coll_q_db',
'{ "aggregate": "coll_strings",
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
}');

-- ==============================================================================
-- SECTION 20: unsupported — $merge and write commands with collation
-- ==============================================================================

-- $merge: collation propagation through writes is not supported.
SELECT document FROM bson_aggregation_pipeline('coll_q_db', '{ "aggregate": "coll_lookup_src", "pipeline": [{"$merge" : { "into": "coll_merge_target", "whenMatched" : "replace" }} ], "collation": { "locale": "en", "strength" : 1} }');

-- $bucketAuto
SELECT document FROM bson_aggregation_pipeline('coll_q_db',
'{ "aggregate": "coll_strings",
   "pipeline": [
     { "$bucketAuto": { "groupBy": "$a", "buckets": 2 } }
   ],
   "collation": { "locale": "en", "strength": 1 }
}');

-- findAndModify with collation.
SELECT documentdb_api.find_and_modify('fam', '{"findAndModify": "coll_multi_collation", "query": {"a": 1}, "update": {"_id": 1, "b": 1}, "collation" : {"locale" : "en", "strength": 1} }');

-- findAndModify $elemMatch projection with collation (documents current unimplemented state).
SELECT documentdb_api.find_and_modify('fam', '{"findAndModify": "coll_multi_collation", "query": {"a": "Cat"}, "update": {"$set": {"b": 99}}, "fields": {"a": 1}, "collation": {"locale": "en", "strength": 1}}');

-- update with collation + arrayFilters.
SELECT documentdb_api.update('update', '{"update":"coll_multi_collation", "updates":[{"q":{"_id": 134111, "b": [ 5, 2, 4 ] },"u":{"$set" : {"b.$[a]":3} },"upsert":true, "collation" : {"locale" : "en", "strength": 1}, "arrayFilters": [ { "a": 2 } ]}]}');

-- count with collation: unsupported
SELECT documentdb_api.count_query('coll_q_db', '{"count":"coll_strings", "query":{"a":"cat"}, "collation":{"locale":"en","strength":1}}');

-- distinct with collation: unsupported
SELECT documentdb_api.distinct_query('coll_q_db', '{"distinct":"coll_strings", "key":"a", "query":{}, "collation":{"locale":"en","strength":1}}');

-- ======================================================================
-- CLEANUP
-- ======================================================================
SELECT documentdb_api.drop_collection('coll_q_db', 'coll_agg_proj');
SELECT documentdb_api.drop_collection('coll_q_db', 'coll_delete');
SELECT documentdb_api.drop_collection('coll_q_db', 'coll_delete_sort');
SELECT documentdb_api.drop_collection('coll_q_db', 'coll_find_positional');
SELECT documentdb_api.drop_collection('coll_q_db', 'coll_graph_src');
SELECT documentdb_api.drop_collection('coll_q_db', 'coll_graph_target');
SELECT documentdb_api.drop_collection('coll_q_db', 'coll_in_empty');
SELECT documentdb_api.drop_collection('coll_q_db', 'coll_lookup_src');
SELECT documentdb_api.drop_collection('coll_q_db', 'coll_multi_collation');
SELECT documentdb_api.drop_collection('coll_q_db', 'coll_order_tests0');
SELECT documentdb_api.drop_collection('coll_q_db', 'coll_order_tests1');
SELECT documentdb_api.drop_collection('coll_q_db', 'coll_phonebook');
SELECT documentdb_api.drop_collection('coll_q_db', 'coll_redact');
SELECT documentdb_api.drop_collection('coll_q_db', 'coll_string_ids');
SELECT documentdb_api.drop_collection('coll_q_db', 'coll_strings');
SELECT documentdb_api.drop_collection('coll_q_db', 'nested_arrays');
SELECT documentdb_api.drop_collection('coll_q_db', 'nested_arrays_docs');
SELECT documentdb_api.drop_collection('coll_q_db', 'nested_docs');
SELECT documentdb_api.drop_collection('coll_q_db', 'coll_sortArray');

RESET documentdb_core.enableCollation;
