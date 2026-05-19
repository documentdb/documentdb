SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;
SET documentdb_core.enableCollation TO on;

-- ======================================================================
-- SECTION 1: Setup — single-field and compound indexes with collation
-- ======================================================================

SELECT documentdb_api.insert_one('coll_op_db','single_field', '{"_id": 1, "a": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','single_field', '{"_id": 2, "a": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','single_field', '{"_id": 3, "a": "BANANA"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','single_field', '{"_id": 4, "a": "banana"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','single_field', '{"_id": 5, "a": "cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','single_field', '{"_id": 6, "a": "Cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','single_field', '{"_id": 7, "a": "date"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','single_field', '{"_id": 8, "a": "Date"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','single_field', '{"_id": 9, "a": 42}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','single_field', '{"_id": 10, "a": null}', NULL);

SELECT documentdb_api.insert_one('coll_op_db','compound_field', '{"_id": 1, "a": "DOG", "b": 10}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','compound_field', '{"_id": 2, "a": "dog", "b": 20}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','compound_field', '{"_id": 3, "a": "Cat", "b": 30}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','compound_field', '{"_id": 4, "a": "cat", "b": 40}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','compound_field', '{"_id": 5, "a": "Bird", "b": 50}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','compound_field', '{"_id": 6, "a": "bird", "b": 60}', NULL);

-- ======================================================================
-- SECTION 2: $eq — equality with index-aware collation
-- ======================================================================

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$eq": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1, "numericOrdering": true } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$eq": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 2.7: $eq case-insensitive match at strength=1 — "APPLE" matches "apple" and "Apple"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$eq": "APPLE" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 2.8: $eq with empty string and matching collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$eq": "" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- SECTION 3: $gt, $gte — range operators
-- ======================================================================

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$gt": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$gte": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$gt": "banana" } }, "sort": { "_id": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$gte": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');

-- 3.5: $gt "BANANA" case-insensitive at strength=1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$gt": "BANANA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 3.6: $gte "CHERRY" case-insensitive at strength=1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$gte": "CHERRY" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- SECTION 3b: $lt, $lte — range operators
-- ======================================================================

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$lt": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$lte": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$lt": "cherry" } }, "sort": { "_id": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$lte": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');

-- 3b.5: $lte case-insensitive at strength=1 — "banana" matches "banana" and "BANANA"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$lte": "banana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 3b.6: $lte "Cherry" case-insensitive at strength=1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$lte": "Cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$lt": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- SECTION 4: Combinations — $and and compound index
-- ======================================================================

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "apple" } }, { "a": { "$eq": "Apple" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "banana" } }, { "a": { "$gt": "apple" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "cherry" } }, { "a": { "$gte": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gt": "apple" } }, { "a": { "$lt": "date" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gte": "banana" } }, { "a": { "$lte": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$gt": "apple", "$lt": "date" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$gte": "banana", "$lte": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "banana" } }, { "a": { "$gt": "apple" } } ] }, "sort": { "_id": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" }, "b": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "cat" }, "b": { "$gte": 30 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" }, "b": { "$eq": 20 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$gt": "bird" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$gte": "cat" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "DOG" }, "b": { "$gt": 10 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "banana" } }, { "a": { "$lt": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "apple" } }, { "a": { "$lte": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$lt": "dog" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$lte": "cat" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "dog" }, "b": { "$lt": 20 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$eq": "cat" }, "b": { "$lte": 40 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 4.23: $lte "banana" AND $gt "CHERRY" — case-insensitive at strength=1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$lte": "banana" } }, { "a": { "$gt": "CHERRY" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 4.24: $eq "banana" AND $gt "CHERRY" — case-insensitive at strength=1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "banana" } }, { "a": { "$gt": "CHERRY" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 4.25: Compound: $lte on "a" + $lt on "b" — range on both keys
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$lte": "cat" }, "b": { "$lt": 50 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 4.26: $lt on "a" AND $lte on "a" — both string ranges at strength=1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$lt": "date" } }, { "a": { "$lte": "CHERRY" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 4.27: $gt "bAnAnA" AND $lte "chErRy" — mixed-case range at strength=1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gt": "bAnAnA" } }, { "a": { "$lte": "chErRy" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- SECTION 5: Multiple indexes with different collations
-- ======================================================================

SELECT documentdb_api.insert_one('coll_op_db','multi_coll', '{"_id": 1, "a": "Alpha"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','multi_coll', '{"_id": 2, "a": "alpha"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','multi_coll', '{"_id": 3, "a": "Beta"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','multi_coll', '{"_id": 4, "a": "beta"}', NULL);

-- 5.1: $eq with strength=1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 5.2: $eq with strength=3
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 } }');

-- 5.4: $eq with strength=2 — neither index matches
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }');

-- 5.5: strength=1 case-insensitive — "ALPHA" matches both Alpha and alpha
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "ALPHA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 5.6: strength=3 case-sensitive — "alpha" only matches "alpha"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$eq": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- ======================================================================
-- SECTION 6: Aggregation pipeline with collation
-- ======================================================================

SELECT document FROM bson_aggregation_pipeline('coll_op_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "apple" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_pipeline('coll_op_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "apple" } } } ], "cursor": {} }');

SELECT document FROM bson_aggregation_pipeline('coll_op_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$gt": "banana" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_pipeline('coll_op_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$eq": "cherry" } } }, { "$project": { "a": 1, "_id": 0 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_pipeline('coll_op_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lt": "cherry" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_pipeline('coll_op_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$lte": "banana" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- SECTION 7: Collation-insensitive operators on collated indexes
-- ======================================================================

-- Setup: collection with mixed types for collation-insensitive operator tests
SELECT documentdb_api.insert_one('coll_op_db','insensitive_ops', '{"_id": 1, "a": "hello"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','insensitive_ops', '{"_id": 2, "a": "HELLO"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','insensitive_ops', '{"_id": 3, "a": 42}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','insensitive_ops', '{"_id": 4, "a": 7}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','insensitive_ops', '{"_id": 5, "a": 255}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','insensitive_ops', '{"_id": 6, "a": null}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','insensitive_ops', '{"_id": 7, "a": true}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','insensitive_ops', '{"_id": 8, "a": [1, 2, 3]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','insensitive_ops', '{"_id": 9}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','insensitive_ops', '{"_id": 10, "a": {"x": 1, "y": 2}}', NULL);

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$exists": true } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 7.2: $exists: true — mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$exists": true } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$exists": false } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$type": "string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 7.5: $type "number" — mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$type": "number" } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }');

-- 7.6: $type "null" — no collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$type": "null" } }, "sort": { "_id": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$size": 3 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 7.8: $size — mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$size": 3 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$mod": [10, 2] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 7.10: $mod — mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$mod": [10, 2] } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAllSet": 7 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 7.12: $bitsAllSet — mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAllSet": 7 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAllClear": 8 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAnySet": 4 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$bitsAnyClear": 4 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "$and": [{ "a": { "$exists": true } }, { "a": { "$eq": "hello" } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "$and": [{ "a": { "$type": "number" } }, { "a": { "$gt": 10 } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- SECTION 8: $regex — byte-level matching with collated index
-- ======================================================================

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$regex": "ana" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app", "$options": "i" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 8.6: $regex combined with $eq via $and — collation applies to $eq only
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [{ "a": { "$eq": "apple" } }, { "a": { "$regex": "^app" } }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- SECTION 9: MinKey / MaxKey sentinel bounds
-- ======================================================================

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$gte": { "$minKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 9.2: $gte MinKey — mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$gte": { "$minKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 9.3: $gt MinKey — mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$gt": { "$minKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$lt": { "$maxKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 9.5: $lt MaxKey — mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$lt": { "$maxKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 9.6: $lte MaxKey — mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$lte": { "$maxKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }');

-- ======================================================================
-- SECTION 10: $ne — collation-aware inequality
-- ======================================================================

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.2: $ne case-insensitive — "APPLE" excludes both "apple" and "Apple" at strength=1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$ne": "APPLE" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$ne": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.6: $ne "bAnAnA" mixed-case at strength=1 — excludes both "banana" and "BANANA"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$ne": "bAnAnA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.7: $ne with empty string and matching collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$ne": "" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "cherry" } }, { "a": { "$gt": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "banana" } }, { "a": { "$lte": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_pipeline('coll_op_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "a": { "$ne": "date" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

-- 10.11: Compound: $ne on "a" + $eq on "b" — matching collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$ne": "dog" }, "b": { "$gte": 30 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.11b: Compound: $ne "DOG" (uppercase) — composite recheck uses collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$ne": "DOG" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }');

-- 10.13: $ne "DATE" case-insensitive — excludes both date and Date
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$ne": "DATE" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.14: $ne "zebra" — value not in collection, returns all docs
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$ne": "zebra" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.15: $ne "cherry" AND $gte "banana" AND $lte "date" — $ne within range
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "cherry" } }, { "a": { "$gte": "banana" } }, { "a": { "$lte": "date" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.16: Multiple $ne — $ne "apple" AND $ne "banana"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "apple" } }, { "a": { "$ne": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.17: Compound: $ne "DOG" AND $eq 20 — $ne excludes both dog variants, $eq 20 matches dog → empty
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$ne": "DOG" }, "b": { "$eq": 20 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.18: Compound: $ne "cat" AND $lt 50 — excludes Cat(30),cat(40), leaves Bird(50→no), bird(60→no), DOG(10),dog(20)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$ne": "cat" }, "b": { "$lt": 50 } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.19: $ne on multi_coll with strength=1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$ne": "ALPHA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.20: $ne on multi_coll with strength=3 — case-sensitive, "ALPHA" not stored so nothing excluded
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$ne": "ALPHA" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- 10.20b: $ne "alpha" at strength-3 — excludes only exact "alpha"(2), NOT "Alpha"(1); contrast with strength-1 (10.19)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$ne": "alpha" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- 10.21: $ne on insensitive_ops "HELLO" — case-insensitive excludes hello+HELLO
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": "HELLO" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.22: $ne boolean (true) on insensitive_ops
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": true } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.23: $ne + $eq on same field — $ne "banana" AND $eq "banana" — contradictory, empty result
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "banana" } }, { "a": { "$eq": "banana" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 10.24: $ne "APPLE" with strength=3 on multi_coll — "APPLE" not stored, nothing excluded
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$ne": "APPLE" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- 10.25: $ne $minKey with matching collation — boundary test
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$ne": { "$minKey": 1 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- SECTION 11: $not $gt — negated strict upper bound (a ≤ value)
-- ======================================================================

-- 11.1: $not $gt "BANANA" (uppercase) at strength-1 — includes both case variants (≤ banana)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gt": "BANANA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.2: $not $gt "DATE" at strength-1 — highest string in data, returns all docs
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gt": "DATE" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.4: Case-folding trio — BANANA, banana, bAnAnA all equivalent at strength-1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gt": "BANANA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gt": "banana" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gt": "bAnAnA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.5: Strength-3 contrast on multi_coll — $not $gt "Alpha" vs $not $gt "alpha"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$not": { "$gt": "Alpha" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$not": { "$gt": "alpha" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- 11.7: Compound — $not $gt on "a" only, no filter on "b"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$gt": "CAT" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.8: Compound — $not $gt on "a" with equality on "b"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$gt": "CAT" } } }, { "b": 50 } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.9: Compound — $not $gt on "a" + $lte on "b" (range on both fields)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$gt": "CAT" } } }, { "b": { "$lte": 30 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.11: $not $gt + $not $lt (bounded range via two negations) — ≤ cherry AND ≥ banana
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gt": "CHERRY" } } }, { "a": { "$not": { "$lt": "BANANA" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.12: $not $gt "CHERRY" combined with $ne "APPLE" — both case-insensitive
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gt": "CHERRY" } } }, { "a": { "$ne": "APPLE" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.13: Contradictory: $not $gt "Apple" AND $gt "Date" at strength-1 — empty result
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gt": "Apple" } } }, { "a": { "$gt": "Date" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.14: Empty string — $not $gt "" returns non-strings only (all strings > "")
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gt": "" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.15: Multiple $not $gt — $not $gt "CHERRY" AND $not $gt "BANANA", tighter bound wins: ≤ banana
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gt": "CHERRY" } } }, { "a": { "$not": { "$gt": "BANANA" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.16: insensitive_ops $not $gt "HELLO" at strength-1 — mixed-type collection
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gt": "HELLO" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.16b: insensitive_ops $not $gt "zzz" — all strings pass, non-strings (numbers, bool, array, null, missing) also returned
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gt": "zzz" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.16c: insensitive_ops $not $gt "a" — excludes strings >= "a" (case-insensitive), returns only non-string types
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gt": "a" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11.17: Compound — $not $gt + $eq on same field "a" with compound index
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$gt": "DOG" } } }, { "a": { "$eq": "CAT" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- SECTION 11b: $not $gte — negated inclusive upper bound (a < value)
-- ======================================================================

-- 11b.1: $not $gte "BANANA" (uppercase) at strength-1 — excludes both case variants (< banana)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gte": "BANANA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.2: $not $gte "CHERRY" at strength-1 — returns apple,Apple,BANANA,banana + non-strings
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gte": "CHERRY" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.4: Case-folding trio — BANANA, banana, bAnAnA all equivalent at strength-1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gte": "BANANA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gte": "banana" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gte": "bAnAnA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.5: Strength-3 contrast on multi_coll — $not $gte "Beta" vs $not $gte "beta"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$not": { "$gte": "Beta" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$not": { "$gte": "beta" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- 11b.7: Compound — $not $gte on "a" only, no filter on "b"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$gte": "DOG" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.8: Compound — $not $gte on "a" with equality on "b"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$gte": "DOG" } } }, { "b": 30 } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.9: Compound — $not $gte on "a" + $gte on "b" (range on both fields)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$gte": "DOG" } } }, { "b": { "$gte": 30 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.11: $not $gte + $not $lte (bounded range via two negations) — > apple AND < cherry
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gte": "CHERRY" } } }, { "a": { "$not": { "$lte": "APPLE" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.12: $not $gte "APPLE" + $ne "BANANA" at strength-1 — both case-insensitive
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gte": "APPLE" } } }, { "a": { "$ne": "BANANA" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.13: Contradictory: $not $gte "Apple" AND $gte "Date" at strength-1 — empty result
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gte": "Apple" } } }, { "a": { "$gte": "Date" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.14: Empty string — $not $gte "" returns only non-strings
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gte": "" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.15: Multiple $not $gte — $not $gte "CHERRY" AND $not $gte "BANANA", tighter bound wins: < banana
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gte": "CHERRY" } } }, { "a": { "$not": { "$gte": "BANANA" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.16: insensitive_ops $not $gte "HELLO" at strength-1 — mixed-type collection
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gte": "HELLO" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.16b: insensitive_ops $not $gte "zzz" — all strings pass, non-strings also returned
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gte": "zzz" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.16c: insensitive_ops $not $gte "a" — excludes strings >= "a", returns only non-string types
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gte": "a" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 11b.17: Compound — $not $gte + $eq on same field "a" with compound index
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$gte": "DOG" } } }, { "a": { "$eq": "BIRD" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- SECTION 12: $not $lt — negated strict lower bound (a ≥ value)
-- ======================================================================

-- 12.1: $not $lt "CHERRY" (uppercase) at strength-1 — returns docs ≥ cherry plus non-strings
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lt": "CHERRY" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.2: $not $lt "BANANA" at strength-1 — returns banana,BANANA,cherry,Cherry,date,Date + non-strings
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lt": "BANANA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.4: Case-folding trio — BANANA, banana, bAnAnA all equivalent at strength-1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lt": "BANANA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lt": "banana" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lt": "bAnAnA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.5: Strength-3 contrast on multi_coll — $not $lt "Alpha" vs $not $lt "alpha"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$not": { "$lt": "Alpha" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$not": { "$lt": "alpha" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- 12.7: Compound — $not $lt on "a" only, no filter on "b"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$lt": "CAT" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.8: Compound — $not $lt on "a" with equality on "b"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$lt": "BIRD" } } }, { "b": 50 } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.9: Compound — $not $lt on "a" + $gt on "b" (range on both fields)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$lt": "BIRD" } } }, { "b": { "$gt": 20 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.11: $not $lt + $not $gt (bounded range via two negations) — ≥ banana AND ≤ cherry
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$lt": "BANANA" } } }, { "a": { "$not": { "$gt": "CHERRY" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.12: $not $lt "CHERRY" combined with $ne "DATE" — both case-insensitive
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$lt": "CHERRY" } } }, { "a": { "$ne": "DATE" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.13: Contradictory: $not $lt "Cherry" AND $lt "Apple" at strength-1 — empty result
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$lt": "Cherry" } } }, { "a": { "$lt": "Apple" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.14: Empty string — $not $lt "" returns all docs (nothing is < "")
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lt": "" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.15: Multiple $not $lt — $not $lt "CHERRY" AND $not $lt "DATE", tighter bound wins: ≥ date
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$lt": "CHERRY" } } }, { "a": { "$not": { "$lt": "DATE" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.16: insensitive_ops $not $lt "HELLO" at strength-1 — mixed-type collection
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lt": "HELLO" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.16b: insensitive_ops $not $lt "a" — no strings excluded (none < "a"), returns everything
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lt": "a" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.16c: insensitive_ops $not $lt "zzz" — excludes strings < "zzz" (all strings), returns only non-string types
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lt": "zzz" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12.17: Compound — $not $lt + $eq on same field "a" with compound index
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$lt": "CAT" } } }, { "a": { "$eq": "DOG" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- SECTION 12b: $not $lte — negated inclusive lower bound (a > value)
-- ======================================================================

-- 12b.1: $not $lte "CHERRY" (uppercase) at strength-1 — returns docs > cherry plus non-strings
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lte": "CHERRY" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.2: $not $lte "BANANA" at strength-1 — returns cherry,Cherry,date,Date + non-strings
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lte": "BANANA" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.4: Case-folding trio — CHERRY, cherry, cHeRrY all equivalent at strength-1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lte": "CHERRY" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lte": "cherry" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lte": "cHeRrY" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.5: Strength-3 contrast on multi_coll — $not $lte "Alpha" vs $not $lte "alpha"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$not": { "$lte": "Alpha" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$not": { "$lte": "alpha" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- 12b.7: Compound — $not $lte on "a" only, no filter on "b"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$lte": "BIRD" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.8: Compound — $not $lte on "a" with equality on "b"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$lte": "BIRD" } } }, { "b": 30 } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.9: Compound — $not $lte on "a" + $lt on "b" (range on both fields)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$lte": "BIRD" } } }, { "b": { "$lt": 50 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.11: $not $lte + $not $gte (bounded range via two negations) — > banana AND < cherry
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$lte": "BANANA" } } }, { "a": { "$not": { "$gte": "CHERRY" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.12: $not $lte "BANANA" combined with $ne "DATE" — both case-insensitive
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$lte": "BANANA" } } }, { "a": { "$ne": "DATE" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.13: Contradictory: $not $lte "Cherry" AND $lte "Apple" — empty result
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$lte": "Cherry" } } }, { "a": { "$lte": "Apple" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.14: Empty string — $not $lte "" returns all strings plus non-strings
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lte": "" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.15: Multiple $not $lte — $not $lte "BANANA" AND $not $lte "CHERRY", tighter bound wins: > cherry
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$lte": "BANANA" } } }, { "a": { "$not": { "$lte": "CHERRY" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.16: insensitive_ops $not $lte "HELLO" at strength-1 — mixed-type collection
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lte": "HELLO" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.16b: insensitive_ops $not $lte "a" — no strings excluded (none <= "a" case-insensitive except exact match), returns most docs
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lte": "a" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.16c: insensitive_ops $not $lte "zzz" — excludes strings <= "zzz" (all strings), returns only non-string types
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lte": "zzz" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 12b.17: Compound — $not $lte + $eq on same field "a" with compound index
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "$and": [ { "a": { "$not": { "$lte": "BIRD" } } }, { "a": { "$eq": "DOG" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- SECTION 13: Non-string type bypass with MISMATCHED collation
-- ======================================================================

-- 13.1: $ne numeric with mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$ne": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 13.2: $eq numeric with mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$eq": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 13.3: $gt numeric with mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": 1 } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }');

-- 13.4: $eq bool with mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": true } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 13.5: $ne null with mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$ne": null } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 3 } }');

-- 13.6: $lt numeric with mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": 100 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 13.7: $gt bool with mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": false } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 13.8: $lte bool with mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": true } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 13.9: $eq regex value with mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$eq": { "$regularExpression": { "pattern": "^app", "options": "" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 13.10: $gte numeric with mismatched collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": 42 } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": ["apple", "banana"] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 13.12: $eq array with matching collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": ["apple", "banana"] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 13.19: $eq document with matching collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$ne": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gt": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$gte": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lt": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$lte": { "sub": "doc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 13.26: $eq nested document with matching collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$eq": { "outer": { "inner": "apple" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": [{ "key": "apple" }] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 13.28: $eq array of documents with matching collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": [{ "key": "apple" }] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": [["apple", "banana"]] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 13.30: $eq nested array with matching collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": [["apple", "banana"]] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 13.54: $not $gt null with matching collation — null is non-string, bypasses collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gt": null } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 13.55: $not $gt $minKey with matching collation — everything is > $minKey, so NOT returns nothing
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gt": { "$minKey": 1 } } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 13.56: $not $gt boolean (true) on insensitive_ops — non-string filter bypasses collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gt": true } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 13.57: $not $gte null with matching collation — null is non-string, bypasses collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gte": null } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 13.58: $not $gte $minKey with matching collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$gte": { "$minKey": 1 } } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 13.59: $not $gte boolean (true) on insensitive_ops — non-string filter bypasses collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$gte": true } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 13.68: $not $lt null with matching collation — null is non-string
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lt": null } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 13.69: $not $lt $minKey with matching collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lt": { "$minKey": 1 } } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 13.70: $not $lt boolean on insensitive_ops — non-string bypasses collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lt": true } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 13.71: $not $lte null with matching collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lte": null } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 13.72: $not $lte $minKey with matching collation — nothing is ≤ $minKey except $minKey itself
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$not": { "$lte": { "$minKey": 1 } } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 13.73: $not $lte boolean on insensitive_ops — non-string bypasses collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$not": { "$lte": true } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- SECTION 14: Mixed collation-aware and non-collation-aware type bounds
-- ======================================================================

-- 14.1: $gte numeric + $lt string with matching collation — both use index
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gte": 10 } }, { "a": { "$lt": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 14.2: $gt string + $lte numeric with matching collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gt": "banana" } }, { "a": { "$lte": 100 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 14.3: $gte numeric + $lt string with MISMATCHED collation — numeric uses index, string does NOT
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$gte": 10 } }, { "a": { "$lt": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 14.4: $ne string + $gte numeric with mismatched collation — numeric uses index, string $ne does NOT
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$ne": "apple" } }, { "a": { "$gte": 10 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 14.5: $not $gt string + $gte numeric with matching collation — both use index
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gt": "CHERRY" } } }, { "a": { "$gte": 10 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 14.6: $not $gt string + $lte numeric with MISMATCHED collation — numeric uses index, string does NOT
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gt": "banana" } } }, { "a": { "$lte": 100 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 14.7: $not $gte string + $gt numeric with matching collation — both use index
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gte": "BANANA" } } }, { "a": { "$gt": 1 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 14.8: $not $gte string + $lt numeric with MISMATCHED collation — numeric uses index, string does NOT
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$not": { "$gte": "cherry" } } }, { "a": { "$lt": 50 } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- ======================================================================
-- SECTION 15: Other operators — collation index behavior
-- ======================================================================

-- 15.1: $exists — collation-insensitive, always uses index
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$exists": true } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 15.2: $type — collation-insensitive, always uses index
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$type": "string" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 15.3: $all — decomposes to $eq, uses collation index
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$all": ["apple", "APPLE"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$in": ["apple", "BANANA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$regex": "^app" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT document FROM bson_aggregation_pipeline('coll_op_db', '{ "aggregate": "single_field", "pipeline": [ { "$sort": { "_id": 1 } }, { "$match": { "$or": [ { "a": { "$eq": "apple" } }, { "a": { "$eq": "banana" } } ] } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- SECTION 16: Data variety & negative cases
-- ======================================================================

-- Mixed-type fixture: 14 strings (with case-variant triples), 2 numerics, 1 bool, 1 null, 2 missing.
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 1,  "a": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 2,  "a": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 3,  "a": "APPLE"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 4,  "a": "banana"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 5,  "a": "Banana"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 6,  "a": "cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 7,  "a": "Cherry"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 8,  "a": "CHERRY"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 9,  "a": "date"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 10, "a": "elderberry"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 11, "a": "fig"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 12, "a": "grape"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 13, "a": "honeydew"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 14, "a": "kiwi"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 15, "a": 42}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 16, "a": 7}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 17, "a": true}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 18, "a": null}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 19}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','mixed_types', '{"_id": 20}', NULL);

-- 16.1: Mixed-type with $not $gt — strings ≤ "cherry" + all non-strings
--   cherry(6), Cherry(7), CHERRY(8) = 8
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$not": { "$gt": "cherry" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 16.2: $ne null — excludes null AND missing-field docs
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$ne": null } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 16.3: $not $lt on missing/null — strings ≥ "elderberry" + non-strings
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$not": { "$lt": "elderberry" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 16.4: Duplicate collation-equivalent count verification at strength-1
-- $ne "cherry" at strength-1 excludes cherry(6), Cherry(7), CHERRY(8) = 3 docs
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$ne": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 16.5: Same $ne "cherry" at strength-3 — only lowercase "cherry"(6) excluded
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$ne": "cherry" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- 16.6: $not $gt "apple" — strength-1 vs strength-3 count difference
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$not": { "$gt": "apple" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 16.7: Strength-3: a ≤ "apple" → only apple(1) since Apple > apple, APPLE > apple
-- at strength-3.  1 string + 6 non-strings = 7.
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$not": { "$gt": "apple" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- ======================================================================
-- SECTION 17: Sort direction
-- ======================================================================

-- 17.1: Descending sort {_id: -1} with $not $gt on single field
-- Same result set as 28.1 (14 docs) but in reverse _id order.
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$not": { "$gt": "cherry" } } }, "sort": { "_id": -1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 17.2: Descending sort with $not $lt
--   fig(11), grape(12), honeydew(13), kiwi(14) = 9
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$not": { "$lt": "cherry" } } }, "sort": { "_id": -1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 17.3: Compound sort {a: 1, b: 1} with negation on compound_field
-- ids: 3(Cat,30), 4(cat,40), 5(Bird,50), 6(bird,60) = 4 docs
-- Sorted by a then b ascending.
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$gt": "cat" } } }, "sort": { "a": 1, "b": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 17.4: Reverse compound sort {a: -1, _id: -1}
-- Same result set as 29.3 but in reverse order.
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$gt": "cat" } } }, "sort": { "a": -1, "_id": -1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 17.5: Compound $not on both keys with compound sort
-- a: $not $gt "dog", b: $not $lt 30
-- DOG(10) and dog(20) excluded by b < 30.
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$gt": "dog" } }, "b": { "$not": { "$lt": 30 } } }, "sort": { "a": 1, "b": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- SECTION 18: Collation-specific edge cases
-- ======================================================================

-- Collection with accented and non-accented variants
SELECT documentdb_api.insert_one('coll_op_db','accent_coll', '{"_id": 1, "a": "cafe"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','accent_coll', '{"_id": 2, "a": "café"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','accent_coll', '{"_id": 3, "a": "caff"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','accent_coll', '{"_id": 4, "a": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','accent_coll', '{"_id": 5, "a": "banana"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','accent_coll', '{"_id": 6, "a": "date"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','accent_coll', '{"_id": 7, "a": "elderberry"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','accent_coll', '{"_id": 8, "a": "Café"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','accent_coll', '{"_id": 9, "a": "CAFE"}', NULL);

-- 18.1: $ne "cafe" at strength-1
-- At primary level ICU treats "cafe", "café", "Café", "CAFE" as equal,
-- so all four (1, 2, 8, 9) are excluded.
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "accent_coll", "filter": { "a": { "$ne": "cafe" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 18.2: $ne "cafe" at strength-2
-- Accents matter at strength-2, so only cafe(1) and CAFE(9) are excluded.
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "accent_coll", "filter": { "a": { "$ne": "cafe" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }');

-- 18.3: $not $gt "cafe" at strength-1 — a ≤ "cafe"
-- All four café-variants are equal to "cafe" at primary level, so they are
-- all kept; "caff" is greater so it is excluded.
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "accent_coll", "filter": { "a": { "$not": { "$gt": "cafe" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 18.4: $not $gt "café" at strength-2 — a ≤ "café"
-- "cafe" < "café" at strength-2, so cafe IS included.
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "accent_coll", "filter": { "a": { "$not": { "$gt": "café" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 2 } }');

-- 18.5: Overlapping negations — narrow band with accented boundary
-- $not $gt "café" AND $not $lt "banana" at strength-1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "accent_coll", "filter": { "$and": [ { "a": { "$not": { "$gt": "café" } } }, { "a": { "$not": { "$lt": "banana" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 18.6: Overlapping negations on mixed_types — banana ≤ a ≤ cherry
-- $not $gt "cherry" AND $not $lt "banana" at strength-1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "$and": [ { "a": { "$not": { "$gt": "cherry" } } }, { "a": { "$not": { "$lt": "banana" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 18.7: Overlapping negations at strength-3 — banana ≤ a ≤ cherry
-- At strength-3 (uppercase > lowercase): Banana included; Cherry, CHERRY excluded.
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "$and": [ { "a": { "$not": { "$gt": "cherry" } } }, { "a": { "$not": { "$lt": "banana" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- ======================================================================
-- SECTION 19: Descending and mixed-direction indexes
-- ======================================================================

-- 19.1: $not $gt "cherry" on DESCENDING index
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$not": { "$gt": "cherry" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 19.2: Descending sort on DESCENDING index
--   grape(12), honeydew(13), kiwi(14) = 9.
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$not": { "$lt": "cherry" } } }, "sort": { "a": -1, "_id": -1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 19.3: $ne "apple" on DESCENDING index
-- Excludes apple/Apple/APPLE at S1: 20 - 3 = 17 docs.
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$ne": "apple" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 19.4: Mixed-direction index {a:1, b:-1} with $not on compound
-- a: $not $gt "cherry", b: $not $lt "green" at S1
-- Uses the compound_field collection.
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$gt": "cherry" } }, "b": { "$not": { "$lt": "green" } } }, "sort": { "a": 1, "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 19.5: Sort {a: 1, b: -1} matching the mixed-direction index
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$not": { "$gt": "cherry" } }, "b": { "$not": { "$lt": "green" } } }, "sort": { "a": 1, "b": -1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- SECTION 20: Three-key composite index
-- ======================================================================

SELECT documentdb_api.insert_one('coll_op_db','three_key', '{"_id": 1,  "a": "apple",  "b": "red",    "c": "x"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','three_key', '{"_id": 2,  "a": "apple",  "b": "red",    "c": "y"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','three_key', '{"_id": 3,  "a": "apple",  "b": "green",  "c": "z"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','three_key', '{"_id": 4,  "a": "banana", "b": "red",    "c": "x"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','three_key', '{"_id": 5,  "a": "banana", "b": "yellow", "c": "y"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','three_key', '{"_id": 6,  "a": "cherry", "b": "red",    "c": "x"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','three_key', '{"_id": 7,  "a": "cherry", "b": "green",  "c": "y"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','three_key', '{"_id": 8,  "a": "Cherry", "b": "Red",    "c": "Z"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','three_key', '{"_id": 9,  "a": "date",   "b": "red",    "c": "x"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','three_key', '{"_id": 10, "a": "date",   "b": "green",  "c": "y"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','three_key', '{"_id": 11, "a": null,     "b": "red",    "c": "x"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','three_key', '{"_id": 12, "a": "cherry", "b": null,     "c": "x"}', NULL);

-- 20.1: Equality prefix on a and b, negation on trailing key c
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "three_key", "filter": { "a": "cherry", "b": "red", "c": { "$not": { "$gt": "x" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 20.2: Negation on middle key b
-- a = "cherry", b: $not $gt "green", c = "y"
-- a="cherry" at s1: ids 6,7,8,12
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "three_key", "filter": { "a": "cherry", "b": { "$not": { "$gt": "green" } }, "c": "y" }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 20.3: All three keys with negation
-- a: $not $gt "cherry", b: $not $gt "red", c: $not $gt "x"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "three_key", "filter": { "a": { "$not": { "$gt": "cherry" } }, "b": { "$not": { "$gt": "red" } }, "c": { "$not": { "$gt": "x" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 20.4: $ne on first key + equality on rest (3 intervals on first key)
-- a: $ne "cherry", b = "red", c = "x"
-- Excluding a=cherry at s1: 6(cherry,red,x), 8(Cherry,Red,Z)
-- Remaining with b=red, c=x: 1(apple,red,x), 4(banana,red,x),
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "three_key", "filter": { "a": { "$ne": "cherry" }, "b": "red", "c": "x" }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- SECTION 21: Multi-key (array field) with collation
-- ======================================================================

SELECT documentdb_api.insert_one('coll_op_db','multikey_coll', '{"_id": 1, "tags": ["ABC", "def"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','multikey_coll', '{"_id": 2, "tags": ["abc", "DEF"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','multikey_coll', '{"_id": 3, "tags": ["ghi", "JKL"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','multikey_coll', '{"_id": 4, "tags": "abc"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','multikey_coll', '{"_id": 5, "tags": "ABC"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','multikey_coll', '{"_id": 6, "tags": ["abc", "ghi"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','multikey_coll', '{"_id": 7, "tags": null}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','multikey_coll', '{"_id": 8}', NULL);

-- 21.1: $eq "abc" at s1 — matches scalars and array elements case-insensitively
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multikey_coll", "filter": { "tags": "abc" }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 21.2: $ne "abc" at s1 — excludes docs where ANY element = "abc"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multikey_coll", "filter": { "tags": { "$ne": "abc" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 21.3: $not $eq "abc" at s1 — same semantics as $ne
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multikey_coll", "filter": { "tags": { "$not": { "$eq": "abc" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 21.4: $not $gt "def" at s1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multikey_coll", "filter": { "tags": { "$not": { "$gt": "def" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 21.5: $gt "def" at s1 on multi-key
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multikey_coll", "filter": { "tags": { "$gt": "def" } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 21.6: strength-3 — "abc" ≠ "ABC"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multikey_coll", "filter": { "tags": "abc" }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- ======================================================================
-- SECTION 22: Locale-specific collation tests — es (ñ) and de (ß)
-- ======================================================================

-- ===== 22A: Spanish (es) locale — ñ sorts after n =====

SELECT documentdb_api.insert_one('coll_op_db','es_locale', '{"_id": 1, "a": "napa"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','es_locale', '{"_id": 2, "a": "ñapa"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','es_locale', '{"_id": 3, "a": "nylon"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','es_locale', '{"_id": 4, "a": "Ñapa"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','es_locale', '{"_id": 5, "a": "opal"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','es_locale', '{"_id": 6, "a": "mango"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','es_locale', '{"_id": 7, "a": "nacho"}', NULL);

-- 22A.1: $eq "ñapa" at es/s1 — matches ñapa and Ñapa (case-insensitive)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "es_locale", "filter": { "a": { "$eq": "ñapa" } }, "sort": { "_id": 1 }, "collation": { "locale": "es", "strength": 1 } }');

-- 22A.2: $gt "n" at es/s1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "es_locale", "filter": { "a": { "$gt": "n" } }, "sort": { "_id": 1 }, "collation": { "locale": "es", "strength": 1 } }');

-- 22A.3: $gt "nylon" at es/s1 — ñ comes after all n-words
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "es_locale", "filter": { "a": { "$gt": "nylon" } }, "sort": { "_id": 1 }, "collation": { "locale": "es", "strength": 1 } }');

-- 22A.4: $not $gt "nylon" at es/s1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "es_locale", "filter": { "a": { "$not": { "$gt": "nylon" } } }, "sort": { "_id": 1 }, "collation": { "locale": "es", "strength": 1 } }');

-- 22A.5: $ne "ñapa" at es/s1 — excludes ñapa(2) and Ñapa(4)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "es_locale", "filter": { "a": { "$ne": "ñapa" } }, "sort": { "_id": 1 }, "collation": { "locale": "es", "strength": 1 } }');

-- ===== 22B: German (de) locale — ß equivalence with ss =====

SELECT documentdb_api.insert_one('coll_op_db','de_locale', '{"_id": 1, "a": "straße"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','de_locale', '{"_id": 2, "a": "strasse"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','de_locale', '{"_id": 3, "a": "Straße"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','de_locale', '{"_id": 4, "a": "STRASSE"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','de_locale', '{"_id": 5, "a": "string"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','de_locale', '{"_id": 6, "a": "strudel"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','de_locale', '{"_id": 7, "a": "apfel"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','de_locale', '{"_id": 8, "a": "zucker"}', NULL);

-- 22B.1: $eq "straße" at de/s1 — ß == ss at strength-1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "de_locale", "filter": { "a": { "$eq": "straße" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');

-- 22B.2: $eq "strasse" at de/s1 — same result (ss == ß)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "de_locale", "filter": { "a": { "$eq": "strasse" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');

-- 22B.3: $ne "straße" at de/s1 — excludes all straße/strasse variants
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "de_locale", "filter": { "a": { "$ne": "straße" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');

-- 22B.4: $gt "strasse" at de/s1 — straße is NOT > strasse since ß==ss
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "de_locale", "filter": { "a": { "$gt": "strasse" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');

-- 22B.5: $not $gt "strasse" at de/s1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "de_locale", "filter": { "a": { "$not": { "$gt": "strasse" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');

-- 22B.7: $eq "STRASSE" at de/s1 — case-insensitive + ß==ss
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "de_locale", "filter": { "a": { "$eq": "STRASSE" } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');

-- ======================================================================
-- Section 23: $elemMatch with collation — scalar arrays
-- ======================================================================

SELECT documentdb_api.insert_one('coll_op_db','elemmatch_coll', '{"_id": 1,  "items": ["Apple", "banana", "Cherry"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_coll', '{"_id": 2,  "items": ["apple", "BANANA", "cherry"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_coll', '{"_id": 3,  "items": ["APPLE", "Apple", "apple"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_coll', '{"_id": 4,  "items": ["Dog", "elephant", "FOX"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_coll', '{"_id": 5,  "items": [42, "apple", null]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_coll', '{"_id": 6,  "items": ["cherry", "CHERRY", "Cherry"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_coll', '{"_id": 7,  "items": []}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_coll', '{"_id": 8,  "items": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_coll', '{"_id": 9,  "other": "value"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_coll', '{"_id": 10, "items": [true, "Banana", false]}', NULL);

-- 23.1: $elemMatch $eq with case-folding at strength=1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "items": { "$elemMatch": { "$eq": "APPLE" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 23.2: same query at strength=3 — case-sensitive
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "items": { "$elemMatch": { "$eq": "APPLE" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- 23.3: no query collation — binary fallback
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "items": { "$elemMatch": { "$eq": "APPLE" } } }, "sort": { "_id": 1 } }');

-- 23.4: mismatched locale (de vs en index)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "items": { "$elemMatch": { "$eq": "APPLE" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');

-- 23.5: mixed-case needle "ApPlE" at en/s1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "items": { "$elemMatch": { "$eq": "ApPlE" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 23.6: numeric needle bypasses collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "items": { "$elemMatch": { "$eq": 42 } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 23.7: $ne with mixed-case needle
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "items": { "$elemMatch": { "$ne": "Cherry" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 23.8: inclusive range $gte "Banana" $lte "Dog"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "items": { "$elemMatch": { "$gte": "Banana", "$lte": "Dog" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 23.9: exclusive range $gt "Cherry" $lt "Fox"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "items": { "$elemMatch": { "$gt": "Cherry", "$lt": "Fox" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 23.10: $not $gt "Cherry"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "items": { "$elemMatch": { "$not": { "$gt": "Cherry" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 23.11: multi-bound merge $gte "Apple" + $gt "Banana" + $lt "Fox"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "items": { "$elemMatch": { "$gte": "Apple", "$gt": "Banana", "$lt": "Fox" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 23.12: $type bypasses collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "items": { "$elemMatch": { "$type": "string" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 23.13: $type combined with collation-aware bound
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "items": { "$elemMatch": { "$type": "string", "$gte": "Cherry" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 23.14: $exists: true bypasses collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "items": { "$elemMatch": { "$exists": true } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');


-- ======================================================================
-- Section 24: $elemMatch with collation — nested object arrays
-- ======================================================================

SELECT documentdb_api.insert_one('coll_op_db','elemmatch_obj', '{"_id": 1, "a": [{"name": "Apple", "qty": 5}, {"name": "banana", "qty": 10}]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_obj', '{"_id": 2, "a": [{"name": "APPLE", "qty": 3}]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_obj', '{"_id": 3, "a": [{"name": "apple", "qty": 1}, {"name": "Banana", "qty": 100}]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_obj', '{"_id": 4, "a": [{"name": "Dog", "qty": 8}]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_obj', '{"_id": 5, "a": [{"name": 42, "qty": "abc"}]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_obj', '{"_id": 6, "other": "value"}', NULL);

-- 24.1: case-folded equality on nested field
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_obj", "filter": { "a": { "$elemMatch": { "name": "APPLE" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 24.2: cross-element guard — predicates must apply to the same element
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_obj", "filter": { "a": { "$elemMatch": { "name": "apple", "qty": { "$gt": 4 } } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 24.3: range on a nested-object field
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_obj", "filter": { "a": { "$elemMatch": { "name": { "$gte": "Banana", "$lt": "Fox" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 24.4: mismatched query collation falls back to runtime evaluation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_obj", "filter": { "a": { "$elemMatch": { "name": "APPLE" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');


-- ======================================================================
-- Section 25: $elemMatch with collation — index variants
-- ======================================================================

SELECT documentdb_api.insert_one('coll_op_db','elemmatch_compound', '{"_id": 1, "tags": ["Apple", "banana"], "category": "Fruit"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_compound', '{"_id": 2, "tags": ["APPLE"],            "category": "fruit"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_compound', '{"_id": 3, "tags": ["Carrot"],           "category": "Veggie"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_compound', '{"_id": 4, "tags": ["dog"],              "category": "animal"}', NULL);

-- 25.1: compound pushdown — $elemMatch on multikey prefix + $eq on tail
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_compound", "filter": { "tags": { "$elemMatch": { "$eq": "APPLE" } }, "category": "Fruit" }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 25.2: mismatched collation — compound index NOT used
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_compound", "filter": { "tags": { "$elemMatch": { "$eq": "APPLE" } }, "category": "Fruit" }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');

SELECT documentdb_api.insert_one('coll_op_db','elemmatch_desc', '{"_id": 1, "v": ["Apple", "Cherry"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_desc', '{"_id": 2, "v": ["banana", "DATE"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_desc', '{"_id": 3, "v": ["FOX", "elephant"]}', NULL);

-- 25.3: equality on a descending collated index
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_desc", "filter": { "v": { "$elemMatch": { "$eq": "APPLE" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 25.4: range on a descending collated index
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_desc", "filter": { "v": { "$elemMatch": { "$gte": "Banana", "$lte": "Elephant" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');


-- ======================================================================
-- Section 26: $elemMatch with collation — locale-specific equivalence
-- ======================================================================

SELECT documentdb_api.insert_one('coll_op_db','elemmatch_es', '{"_id": 1, "a": ["niño", "Niño"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_es', '{"_id": 2, "a": ["nino"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_es', '{"_id": 3, "a": ["nylon"]}', NULL);

-- 26.1: $eq "ÑIÑO" at es/s1 — ñ ≠ n at primary level
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_es", "filter": { "a": { "$elemMatch": { "$eq": "ÑIÑO" } } }, "sort": { "_id": 1 }, "collation": { "locale": "es", "strength": 1 } }');

SELECT documentdb_api.insert_one('coll_op_db','elemmatch_de', '{"_id": 1, "a": ["straße", "STRASSE"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_de', '{"_id": 2, "a": ["Strasse"]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_de', '{"_id": 3, "a": ["string"]}', NULL);

-- 26.2: $eq "Strasse" at de/s1 — ß == ss with case-fold
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_de", "filter": { "a": { "$elemMatch": { "$eq": "Strasse" } } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');

-- 26.3: cross-locale mismatch — query es against de-indexed collection
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_de", "filter": { "a": { "$elemMatch": { "$eq": "Strasse" } } }, "sort": { "_id": 1 }, "collation": { "locale": "es", "strength": 1 } }');


-- ======================================================================
-- Section 27: $elemMatch with collation — combinators and nested
-- ======================================================================

-- 27.1: $or of two $elemMatch predicates
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "$or": [ { "items": { "$elemMatch": { "$eq": "APPLE" } } }, { "items": { "$elemMatch": { "$gt": "Elephant" } } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 27.2: $and of $elemMatch + $eq on different field
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_compound", "filter": { "$and": [ { "tags": { "$elemMatch": { "$eq": "APPLE" } } }, { "category": "FRUIT" } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

SELECT documentdb_api.insert_one('coll_op_db','elemmatch_nested', '{"_id": 1, "matrix": [{"vals": ["Apple", "Banana"]}, {"vals": ["Cherry"]}]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_nested', '{"_id": 2, "matrix": [{"vals": ["APPLE", "BANANA"]}]}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','elemmatch_nested', '{"_id": 3, "matrix": [{"vals": ["dog"]}, {"vals": ["FOX"]}]}', NULL);

-- 27.3: nested $elemMatch — outer on matrix, inner on vals
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_nested", "filter": { "matrix": { "$elemMatch": { "vals": { "$elemMatch": { "$eq": "APPLE" } } } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');


-- ======================================================================
-- Section 28: $elemMatch with collation — edge cases
-- ======================================================================

-- 28.1: empty range — bounds collapse to no elements
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "items": { "$elemMatch": { "$gt": "Cherry", "$lt": "Cherry" } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 28.2: $in inside $elemMatch — runtime filter, not pushed to collated index
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "items": { "$elemMatch": { "$in": ["APPLE", "FOX"] } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 28.3: $not:{$eq} ≡ $ne under collation
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "elemmatch_coll", "filter": { "items": { "$elemMatch": { "$not": { "$eq": "Cherry" } } } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- CLEANUP
-- ======================================================================
-- ======================================================================
-- Section 35: $in — collation index pushdown (comprehensive)
-- 35.6: $in with mixed case — "aPpLe" matches apple/Apple at strength=1
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$in": ["aPpLe"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 35.7: Case variants all equivalent — "cherry", "Cherry", "CHERRY" all match ids 5,6
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$in": ["cherry"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$in": ["Cherry"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$in": ["CHERRY"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 35.8: Redundant case variants in array — same as single element
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$in": ["apple", "APPLE", "Apple"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 35.13: $in value not in collection — empty result
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$in": ["zebra", "mango"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 35.24: $in "ALPHA" at s1 — matches Alpha(1) and alpha(2)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$in": ["ALPHA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 35.25: $in "ALPHA" at s3 — not stored, returns empty
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$in": ["ALPHA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- 35.29: $in combined with $lt — narrowing the range
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$in": ["apple", "banana", "cherry", "date"] } }, { "a": { "$lt": "cherry" } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 35.33: $in "ABC" on multikey — case-insensitive
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multikey_coll", "filter": { "tags": { "$in": ["ABC"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 35.44: $in on es_locale — ["ñapa", "opal"] matches ñapa(2), Ñapa(4), opal(5)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "es_locale", "filter": { "a": { "$in": ["ñapa", "opal"] } }, "sort": { "_id": 1 }, "collation": { "locale": "es", "strength": 1 } }');

-- 35.47: $in on de_locale — "strasse" same result (ss==ß)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "de_locale", "filter": { "a": { "$in": ["strasse"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');

-- 35.48: $in on de_locale — "STRASSE" case-insensitive + ß==ss
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "de_locale", "filter": { "a": { "$in": ["STRASSE"] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');

-- ======================================================================
-- Section 36: $nin — collation index pushdown (comprehensive)
-- 36.5: $nin "bAnAnA" mixed case — excludes BANANA(3), banana(4)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["bAnAnA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 36.7: $nin "zebra" — not in collection, nothing excluded
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["zebra"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 36.8: $nin redundant case variants — same as $nin: ["apple"]
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["apple", "APPLE", "Apple"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 36.10: $nin with empty string
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$nin": [""] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 36.11: $nin single element — equivalent to $ne
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$nin": ["cherry"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 36.18: $nin "DOG" UPPERCASE — excludes DOG(1) and dog(2)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "compound_field", "filter": { "a": { "$nin": ["DOG"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 36.21: $nin "ALPHA" at s3 — not stored, nothing excluded
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multi_coll", "filter": { "a": { "$nin": ["ALPHA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- 36.23: $nin combined with $eq — contradictory if value overlaps → empty
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$eq": "apple" } }, { "a": { "$nin": ["apple"] } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 36.28: $nin "ABC" on multikey — case-insensitive exclusion
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multikey_coll", "filter": { "tags": { "$nin": ["ABC"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 36.32: $nin boolean on insensitive_ops — excludes true(7)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "insensitive_ops", "filter": { "a": { "$nin": [true] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- Section 37: $in/$nin — feature flag disabled
-- ======================================================================
-- Section 38: $in/$nin — data distribution on mixed_types (20 docs)
-- 38.4: $nin "cherry" at s3 — only excludes cherry(6) = 19 docs returned
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$nin": ["cherry"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- 38.5: $in multiple groups — apple×3 + banana×2 = 5 docs
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$in": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 38.6: $nin multiple groups — excludes apple×3 + banana×2 = 15 docs returned
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$nin": ["apple", "banana"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 38.7: $in null — matches null(18) + missing(19,20) = 3 docs
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$in": [null] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 38.8: $nin null — excludes null + missing = 17 docs returned
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$nin": [null] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 38.9: $in mixed types — "apple" + 42 + true at s1 → apple×3 + 42(15) + true(17) = 5 docs
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$in": ["apple", 42, true] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 38.10: $nin everything — returns only null(18), 7(16), missing(19,20) = 4 docs
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "mixed_types", "filter": { "a": { "$nin": ["apple", "banana", "cherry", "date", "elderberry", "fig", "grape", "honeydew", "kiwi", 42, true] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');


-- ======================================================================
-- Section 39: $in/$nin — accent collection (café vs cafe)
-- 39.2: $in "café" at en/s1 — accent ignored at strength=1, matches all cafe-equivalents = 4 docs
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "accent_coll", "filter": { "a": { "$in": ["café"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 39.3: $in ["cafe", "café"] at en/s1 — both groups
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "accent_coll", "filter": { "a": { "$in": ["cafe", "café"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 39.5: $nin ["cafe", "café"] at en/s1 — excludes both groups
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "accent_coll", "filter": { "a": { "$nin": ["cafe", "café"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');


-- ======================================================================
-- Section 40: $in/$nin — three-key composite index
-- 40.3: $in on middle key
-- a = "cherry", b: $in ["red", "green"], c = "y"
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "three_key", "filter": { "a": "cherry", "b": { "$in": ["red", "green"] }, "c": "y" }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 40.4: $in case-insensitive on three-key — "CHERRY" at s1 matches all cherry variants
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "three_key", "filter": { "a": { "$in": ["CHERRY"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');


-- ======================================================================
-- Section 41: $in/$nin — write-path coverage (delete with collation)

SELECT documentdb_api.insert_one('coll_op_db','write_in_coll', '{"_id": 1, "a": "apple", "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','write_in_coll', '{"_id": 2, "a": "Apple", "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','write_in_coll', '{"_id": 3, "a": "BANANA", "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','write_in_coll', '{"_id": 4, "a": "banana", "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','write_in_coll', '{"_id": 5, "a": "cherry", "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','write_in_coll', '{"_id": 6, "a": "Cherry", "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','write_in_coll', '{"_id": 7, "a": "date",   "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','write_in_coll', '{"_id": 8, "a": "Date",   "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','write_in_coll', '{"_id": 9, "a": 42,       "v": 1}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','write_in_coll', '{"_id":10, "a": null,     "v": 1}', NULL);

-- 41.1: delete_one with $nin + matching collation (en s1) — removes one non-fruit doc (id 9 or 10)
SELECT documentdb_api.delete('coll_op_db', '{ "delete": "write_in_coll", "deletes": [ { "q": { "a": { "$nin": ["apple", "banana", "cherry", "date"] } }, "limit": 1, "collation": { "locale": "en", "strength": 1 } } ] }');
SELECT count(*) FROM documentdb_api.collection('coll_op_db', 'write_in_coll');

-- 41.2: delete_many with $in (matching collation) — removes BOTH date variants (ids 7,8)
SELECT documentdb_api.delete('coll_op_db', '{ "delete": "write_in_coll", "deletes": [ { "q": { "a": { "$in": ["DATE"] } }, "limit": 0, "collation": { "locale": "en", "strength": 1 } } ] }');
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "write_in_coll", "filter": { "a": { "$in": ["date", "Date"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 41.3: delete_many with $in + mismatched collation (de/s2 vs idx en/s1) — index NOT used; at de/s2 case is still ignored, so deletes BOTH cherry and Cherry
SELECT documentdb_api.delete('coll_op_db', '{ "delete": "write_in_coll", "deletes": [ { "q": { "a": { "$in": ["cherry"] } }, "limit": 0, "collation": { "locale": "de", "strength": 2 } } ] }');
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "write_in_coll", "filter": { "a": { "$in": ["cherry", "Cherry"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 41.4: delete with $in all-non-string + mismatched collation — index path still valid (non-string bypass)
SELECT documentdb_api.delete('coll_op_db', '{ "delete": "write_in_coll", "deletes": [ { "q": { "a": { "$in": [42] } }, "limit": 0, "collation": { "locale": "de", "strength": 2 } } ] }');

-- 41.5: Final state after all deletes
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "write_in_coll", "filter": {}, "sort": { "_id": 1 } }');


-- ======================================================================
-- Section 42: $in/$nin nested under $or / $and / $nor
-- 42.4: $and with $in + $nin — case-insensitive intersection then exclusion
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "a": { "$in": ["APPLE", "BANANA", "CHERRY"] } }, { "a": { "$nin": ["banana"] } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 42.6: Nested $or inside $and — ($in OR $eq) AND $exists
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "$or": [ { "a": { "$in": ["APPLE"] } }, { "a": "cherry" } ] }, { "a": { "$exists": true } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 42.7: $or with mismatched-collation $in leg + matching-collation $in leg
-- Behavior probe: query-level collation should apply uniformly. The
-- "mismatched" leg test uses an alternate locale only to ensure the planner
-- doesn't crash on mixed-shape predicates inside $or.
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$or": [ { "a": { "$in": ["APPLE"] } }, { "a": { "$in": ["DATE"] } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

-- 42.9: $and on multikey ($in inside conjunction with another $in)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "multikey_coll", "filter": { "$and": [ { "tags": { "$in": ["RED"] } }, { "tags": { "$in": ["GREEN"] } } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 42.10: Three-level nesting — $and [ $or, $nor ]
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "$and": [ { "$or": [ { "a": { "$in": ["APPLE", "BANANA"] } }, { "a": { "$in": ["DATE"] } } ] }, { "$nor": [ { "a": { "$eq": "Apple" } } ] } ] }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');


-- ======================================================================
-- Section 43: $in/$nin — large arrays (planner threshold behavior)
-- ======================================================================
-- Section 44: $in/$nin — degenerate arrays
-- 44.3: $in: [] without collation — must still match nothing
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$in": [] } }, "sort": { "_id": 1 } }');

-- 44.5: $in:[null, ""] — null OR empty string (both non-collation-aware in null-leg, collation-aware in empty-string leg)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$in": [null, ""] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 44.6: $nin:[null, ""] — exclude null + empty string from collated set
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "single_field", "filter": { "a": { "$nin": [null, ""] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');


-- ======================================================================
-- Section 45: $in/$nin — index hint
-- ======================================================================
-- Section 46: $in/$nin — nested field path with collation index

SELECT documentdb_api.insert_one('coll_op_db','nested_path_coll', '{"_id": 1, "a": {"b": "apple"}}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','nested_path_coll', '{"_id": 2, "a": {"b": "Apple"}}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','nested_path_coll', '{"_id": 3, "a": {"b": "BANANA"}}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','nested_path_coll', '{"_id": 4, "a": {"b": "banana"}}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','nested_path_coll', '{"_id": 5, "a": {"b": "cherry"}}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','nested_path_coll', '{"_id": 6, "a": {"b": "Cherry"}}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','nested_path_coll', '{"_id": 7, "a": {"b": null}}',    NULL);
SELECT documentdb_api.insert_one('coll_op_db','nested_path_coll', '{"_id": 8, "a": {}}',             NULL);
SELECT documentdb_api.insert_one('coll_op_db','nested_path_coll', '{"_id": 9}',                       NULL);

-- 46.2: $in on nested path — no collation — only exact "apple", "banana" → ids 1, 4
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "nested_path_coll", "filter": { "a.b": { "$in": ["apple", "banana"] } }, "sort": { "_id": 1 } }');

-- 46.4: $nin on nested path — matching collation — excludes apple+banana variants
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "nested_path_coll", "filter": { "a.b": { "$nin": ["APPLE", "BANANA"] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 46.5: $in:[null] on nested — matches doc with explicit null AND missing field/missing parent
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "nested_path_coll", "filter": { "a.b": { "$in": [null] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- ======================================================================
-- Section 47: $in/$nin — BSON type variety in array (non-string bypass)

SELECT documentdb_api.insert_one('coll_op_db','bson_types_coll', '{"_id": 1, "a": "apple"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','bson_types_coll', '{"_id": 2, "a": "Apple"}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','bson_types_coll', '{"_id": 3, "a": {"$date": "2024-01-15T00:00:00Z"}}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','bson_types_coll', '{"_id": 4, "a": {"$date": "2025-06-20T12:00:00Z"}}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','bson_types_coll', '{"_id": 5, "a": {"$oid": "507f1f77bcf86cd799439011"}}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','bson_types_coll', '{"_id": 6, "a": {"$oid": "507f1f77bcf86cd799439022"}}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','bson_types_coll', '{"_id": 7, "a": {"$numberDecimal": "3.14"}}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','bson_types_coll', '{"_id": 8, "a": {"$numberDecimal": "9.99"}}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','bson_types_coll', '{"_id": 9, "a": {"$binary": {"base64": "AAEC", "subType": "00"}}}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','bson_types_coll', '{"_id":10, "a": {"$binary": {"base64": "AwQF", "subType": "00"}}}', NULL);
SELECT documentdb_api.insert_one('coll_op_db','bson_types_coll', '{"_id":11, "a": null}', NULL);

-- 47.2: multi-element $in ObjectId mismatched collation — index NOT used
--       (array forces collation check, even though all elements are non-string)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "bson_types_coll", "filter": { "a": { "$in": [ {"$oid": "507f1f77bcf86cd799439011"}, {"$oid": "507f1f77bcf86cd799439022"} ] } }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 1 } }');

-- 47.3: single-element $in [Decimal128] mismatched collation — index IS used (decomposed to $eq)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "bson_types_coll", "filter": { "a": { "$in": [ {"$numberDecimal": "3.14"} ] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- 47.4: single-element $in [Binary] mismatched collation — index IS used (decomposed to $eq)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "bson_types_coll", "filter": { "a": { "$in": [ {"$binary": {"base64": "AAEC", "subType": "00"}} ] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 1 } }');

-- 47.6: $in [string, Date] matching collation (en/s1 = idx) — index used; at s1 case is ignored so APPLE matches apple+Apple = 3 rows
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "bson_types_coll", "filter": { "a": { "$in": [ "APPLE", {"$date": "2024-01-15T00:00:00Z"} ] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }');

-- 47.7: $in [string, Date] mismatched collation (en/s3 vs idx en/s1) — index NOT used; at s3 case is sensitive so "Apple" matches Apple only = 2 rows
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "bson_types_coll", "filter": { "a": { "$in": [ "Apple", {"$date": "2024-01-15T00:00:00Z"} ] } }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 3 } }');

-- 47.8: multi-element $nin ObjectId mismatched collation — index NOT used (array path)
SELECT document FROM bson_aggregation_find('coll_op_db', '{ "find": "bson_types_coll", "filter": { "a": { "$nin": [ {"$oid": "507f1f77bcf86cd799439011"}, {"$oid": "507f1f77bcf86cd799439022"} ] } }, "sort": { "_id": 1 }, "collation": { "locale": "de", "strength": 2 } }');

SELECT documentdb_api.drop_collection('coll_op_db', 'write_in_coll');
SELECT documentdb_api.drop_collection('coll_op_db', 'nested_path_coll');
SELECT documentdb_api.drop_collection('coll_op_db', 'bson_types_coll');
SELECT documentdb_api.drop_collection('coll_op_db', 'accent_coll');
SELECT documentdb_api.drop_collection('coll_op_db', 'compound_field');
SELECT documentdb_api.drop_collection('coll_op_db', 'de_locale');
SELECT documentdb_api.drop_collection('coll_op_db', 'elemmatch_coll');
SELECT documentdb_api.drop_collection('coll_op_db', 'elemmatch_compound');
SELECT documentdb_api.drop_collection('coll_op_db', 'elemmatch_de');
SELECT documentdb_api.drop_collection('coll_op_db', 'elemmatch_desc');
SELECT documentdb_api.drop_collection('coll_op_db', 'elemmatch_es');
SELECT documentdb_api.drop_collection('coll_op_db', 'elemmatch_nested');
SELECT documentdb_api.drop_collection('coll_op_db', 'elemmatch_obj');
SELECT documentdb_api.drop_collection('coll_op_db', 'es_locale');
SELECT documentdb_api.drop_collection('coll_op_db', 'insensitive_ops');
SELECT documentdb_api.drop_collection('coll_op_db', 'mixed_types');
SELECT documentdb_api.drop_collection('coll_op_db', 'multi_coll');
SELECT documentdb_api.drop_collection('coll_op_db', 'multikey_coll');
SELECT documentdb_api.drop_collection('coll_op_db', 'single_field');
SELECT documentdb_api.drop_collection('coll_op_db', 'three_key');

RESET documentdb_core.enableCollation;
