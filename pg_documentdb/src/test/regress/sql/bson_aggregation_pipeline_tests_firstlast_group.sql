SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_core;

SET documentdb.next_collection_id TO 25701000;
SET documentdb.next_collection_index_id TO 25701000;

-- 1. Setup test data
SELECT documentdb_api.insert_one('db', 'fl_grp_test', '{ "_id": 1, "g": "A", "v": 10, "name": "alpha" }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_grp_test', '{ "_id": 2, "g": "B", "v": 20, "name": "beta" }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_grp_test', '{ "_id": 3, "g": "A", "v": 30, "name": "gamma" }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_grp_test', '{ "_id": 4, "g": "B", "v": 40, "name": "delta" }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_grp_test', '{ "_id": 5, "g": "A", "v": 50, "name": "epsilon" }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_grp_test', '{ "_id": 6, "g": "C", "v": 60, "name": "zeta" }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_grp_test', '{ "_id": 7, "g": "A", "v": null, "name": "eta" }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_grp_test', '{ "_id": 8, "g": "B" }', NULL);

-- 2. $first/$last without $sort - GUC off then on
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$group": { "_id": "$g", "firstVal": { "$first": "$v" }, "lastName": { "$last": "$name" } } }], "cursor": {} }');

SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$group": { "_id": "$g", "firstVal": { "$first": "$v" }, "lastName": { "$last": "$name" } } }], "cursor": {} }');

-- 3. Computed expression in $first/$last - GUC on
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$group": { "_id": "$g", "firstDoubled": { "$first": { "$multiply": ["$v", 2] } }, "lastDoubled": { "$last": { "$multiply": ["$v", 2] } } } }], "cursor": {} }');

-- 4. Empty collection - $first
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT documentdb_api.create_collection('db', 'fl_empty');
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_empty", "pipeline": [{ "$group": { "_id": "$g", "f": { "$first": "$v" } } }], "cursor": {} }');
SELECT documentdb_api.drop_collection('db', 'fl_empty');

-- 5. Nested/embedded documents as accumulator input
SELECT documentdb_api.insert_one('db', 'fl_nested', '{ "_id": 1, "g": "X", "info": { "city": "SEA", "zip": 98101 } }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_nested', '{ "_id": 2, "g": "X", "info": { "city": "PDX", "zip": 97201 } }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_nested', '{ "_id": 3, "g": "Y", "info": { "city": "SFO", "zip": 94102 } }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_nested', '{ "_id": 4, "g": "X", "tags": ["a", "b", "c"] }', NULL);

SET documentdb.enableNewWithExprAccumulators TO on;
-- $first/$last on a sub-document field
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_nested", "pipeline": [{ "$group": { "_id": "$g", "firstInfo": { "$first": "$info" }, "lastInfo": { "$last": "$info" } } }], "cursor": {} }');
-- $first on an array field
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_nested", "pipeline": [{ "$group": { "_id": "$g", "firstTags": { "$first": "$tags" } } }], "cursor": {} }');

SELECT documentdb_api.drop_collection('db', 'fl_nested');

-- 6. Different BSON types: date, ObjectId, boolean, double
SELECT documentdb_api.insert_one('db', 'fl_types', '{ "_id": 1, "g": "T", "d": { "$date": "2024-01-15T00:00:00Z" }, "oid": { "$oid": "aaaaaaaaaaaaaaaaaaaaaaaa" }, "b": true, "f": 3.14 }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_types', '{ "_id": 2, "g": "T", "d": { "$date": "2025-06-20T12:30:00Z" }, "oid": { "$oid": "bbbbbbbbbbbbbbbbbbbbbbbb" }, "b": false, "f": 2.718 }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_types', '{ "_id": 3, "g": "U", "d": { "$date": "2023-03-01T08:00:00Z" }, "oid": { "$oid": "cccccccccccccccccccccccc" }, "b": true, "f": 1.0 }', NULL);

SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_types", "pipeline": [{ "$group": { "_id": "$g", "firstDate": { "$first": "$d" }, "lastDate": { "$last": "$d" } } }], "cursor": {} }');
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_types", "pipeline": [{ "$group": { "_id": "$g", "firstOid": { "$first": "$oid" }, "lastBool": { "$last": "$b" }, "firstDbl": { "$first": "$f" } } }], "cursor": {} }');

SELECT documentdb_api.drop_collection('db', 'fl_types');

-- 7. Type-agnostic first/last: mixed types within the same group
SELECT documentdb_api.insert_one('db', 'fl_mixed', '{ "_id": 1, "g": "M", "v": 42 }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_mixed', '{ "_id": 2, "g": "M", "v": "hello" }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_mixed', '{ "_id": 3, "g": "M", "v": true }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_mixed', '{ "_id": 4, "g": "M", "v": { "$date": "2024-01-01T00:00:00Z" } }', NULL);

SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_mixed", "pipeline": [{ "$group": { "_id": "$g", "firstV": { "$first": "$v" }, "lastV": { "$last": "$v" } } }], "cursor": {} }');

SELECT documentdb_api.drop_collection('db', 'fl_mixed');

-- 8. Top-level "let" passes varSpec to the with-expr transition function
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$group": { "_id": "$g", "firstAdj": { "$first": { "$add": ["$v", "$$bonus"] } }, "lastAdj": { "$last": { "$add": ["$v", "$$bonus"] } } } }], "cursor": {}, "let": { "bonus": 100 } }');
-- EXPLAIN shows non-empty varSpec with "let" variables
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$group": { "_id": "$g", "f": { "$first": { "$add": ["$v", "$$bonus"] } } } }], "cursor": {}, "let": { "bonus": 100 } }');

-- 9. $last where the final document in a group has a missing field
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$group": { "_id": "$g", "lastV": { "$last": "$v" }, "lastName": { "$last": "$name" } } }], "cursor": {} }');

-- =============================================================================
-- Collation tests for $first/$last with the new WithExpr accumulators
-- =============================================================================

-- 10. Setup collation test data
SELECT documentdb_api.insert_one('db', 'fl_collation_test', '{ "_id": 1, "g": "A", "name": "cherry" }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_collation_test', '{ "_id": 2, "g": "A", "name": "BANANA" }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_collation_test', '{ "_id": 3, "g": "A", "name": "Apple" }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_collation_test', '{ "_id": 4, "g": "a", "name": "date" }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_collation_test', '{ "_id": 5, "g": "a", "name": "FIG" }', NULL);

-- 11. Basic collation with simple field reference (sanity: collation doesn't change order-based result)
SET documentdb_core.enableCollation TO on;
SET documentdb.enableNewWithExprAccumulators TO on;
SET documentdb.enableNewWithExprAccumulators TO on;
SET documentdb.enableCollationWithNewGroupAccumulators TO on;

-- With collation (case-insensitive strength 1)
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_test", "pipeline": [{ "$group": { "_id": "$g", "firstName": { "$first": "$name" }, "lastName": { "$last": "$name" } } }, { "$sort": { "_id": 1 } }], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

-- Without collation baseline (binary comparison for grouping; first/last order unchanged)
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_test", "pipeline": [{ "$group": { "_id": "$g", "firstName": { "$first": "$name" }, "lastName": { "$last": "$name" } } }, { "$sort": { "_id": 1 } }], "cursor": {} }');

-- =============================================================================
-- 12. Collation-sensitive computed expression — KEY test proving collation
-- affects expression evaluation within $first/$last accumulators.
-- With strength 1 (case-insensitive): $eq: ["cherry", "CHERRY"] → true → "matched"
-- Without collation (binary):          $eq: ["cherry", "CHERRY"] → false → "no-match"
-- =============================================================================

-- $first with collation-sensitive $cond
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_test", "pipeline": [{ "$group": { "_id": "$g", "firstMatch": { "$first": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "matched", "else": "no-match" } } }, "lastMatch": { "$last": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "matched", "else": "no-match" } } } } }, { "$sort": { "_id": 1 } }], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

-- Same query without collation (binary: "cherry" != "CHERRY")
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_test", "pipeline": [{ "$group": { "_id": "$g", "firstMatch": { "$first": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "matched", "else": "no-match" } } }, "lastMatch": { "$last": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "matched", "else": "no-match" } } } } }, { "$sort": { "_id": 1 } }], "cursor": {} }');

-- =============================================================================
-- 13. EXPLAIN showing collation propagation in WithExpr aggregate functions
-- =============================================================================

-- With collation: collation text constant should appear in bsonfirstwithexpr/bsonlastwithexpr args
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_test", "pipeline": [{ "$group": { "_id": "$g", "f": { "$first": "$name" }, "l": { "$last": "$name" } } }], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

-- Without collation: NULL collation arg
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_test", "pipeline": [{ "$group": { "_id": "$g", "f": { "$first": "$name" }, "l": { "$last": "$name" } } }], "cursor": {} }');

-- =============================================================================
-- 14. Constant _id group with collation-sensitive expression
-- =============================================================================

SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_test", "pipeline": [{ "$group": { "_id": null, "firstMatch": { "$first": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "matched", "else": "no-match" } } }, "lastMatch": { "$last": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "matched", "else": "no-match" } } } } }], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

-- Without collation baseline
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_test", "pipeline": [{ "$group": { "_id": null, "firstMatch": { "$first": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "matched", "else": "no-match" } } }, "lastMatch": { "$last": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "matched", "else": "no-match" } } } } }], "cursor": {} }');

-- =============================================================================
-- 15. Collation with mixed types (string, number, null)
-- =============================================================================

SELECT documentdb_api.insert_one('db', 'fl_collation_mixed', '{ "_id": 1, "g": "G", "val": "banana" }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_collation_mixed', '{ "_id": 2, "g": "G", "val": "CHERRY" }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_collation_mixed', '{ "_id": 3, "g": "G", "val": 42 }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_collation_mixed', '{ "_id": 4, "g": "G", "val": null }', NULL);

-- $first/$last with collation-sensitive expression on mixed types
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_mixed", "pipeline": [{ "$group": { "_id": "$g", "firstMatch": { "$first": { "$cond": { "if": { "$eq": ["$val", "cherry"] }, "then": "matched", "else": "no-match" } } }, "lastMatch": { "$last": { "$cond": { "if": { "$eq": ["$val", "cherry"] }, "then": "matched", "else": "no-match" } } } } }], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

-- Without collation
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_mixed", "pipeline": [{ "$group": { "_id": "$g", "firstMatch": { "$first": { "$cond": { "if": { "$eq": ["$val", "cherry"] }, "then": "matched", "else": "no-match" } } }, "lastMatch": { "$last": { "$cond": { "if": { "$eq": ["$val", "cherry"] }, "then": "matched", "else": "no-match" } } } } }], "cursor": {} }');

SELECT documentdb_api.drop_collection('db', 'fl_collation_mixed');

-- =============================================================================
-- 16. numericOrdering in computed expression
-- With numericOrdering: "item10" > "item2" (numeric), without: "item10" < "item2" (lexical)
-- =============================================================================

SELECT documentdb_api.insert_one('db', 'fl_numeric_order', '{ "_id": 1, "g": "N", "val": "item10" }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_numeric_order', '{ "_id": 2, "g": "N", "val": "item2" }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_numeric_order', '{ "_id": 3, "g": "N", "val": "item20" }', NULL);

-- numericOrdering=true: $gt "item10" > "item2" → true → "above"
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_numeric_order", "pipeline": [{ "$group": { "_id": "$g", "firstCmp": { "$first": { "$cond": { "if": { "$gt": ["$val", "item2"] }, "then": "above", "else": "below" } } }, "lastCmp": { "$last": { "$cond": { "if": { "$gt": ["$val", "item2"] }, "then": "above", "else": "below" } } } } }], "cursor": {}, "collation": { "locale": "en", "numericOrdering": true } }');

-- numericOrdering=false (default): "item10" < "item2" (lexical) → false → "below"
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_numeric_order", "pipeline": [{ "$group": { "_id": "$g", "firstCmp": { "$first": { "$cond": { "if": { "$gt": ["$val", "item2"] }, "then": "above", "else": "below" } } }, "lastCmp": { "$last": { "$cond": { "if": { "$gt": ["$val", "item2"] }, "then": "above", "else": "below" } } } } }], "cursor": {}, "collation": { "locale": "en", "numericOrdering": false } }');

-- Without collation baseline
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_numeric_order", "pipeline": [{ "$group": { "_id": "$g", "firstCmp": { "$first": { "$cond": { "if": { "$gt": ["$val", "item2"] }, "then": "above", "else": "below" } } }, "lastCmp": { "$last": { "$cond": { "if": { "$gt": ["$val", "item2"] }, "then": "above", "else": "below" } } } } }], "cursor": {} }');

SELECT documentdb_api.drop_collection('db', 'fl_numeric_order');

-- =============================================================================
-- 17. GUC gating: enableCollationWithNewGroupAccumulators off → error
-- =============================================================================

SET documentdb.enableCollationWithNewGroupAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_test", "pipeline": [{ "$group": { "_id": "$g", "f": { "$first": "$name" } } }, { "$sort": { "_id": 1 } }], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');
SET documentdb.enableNewWithExprAccumulators TO on;
SET documentdb.enableCollationWithNewGroupAccumulators TO on;

-- =============================================================================
-- 18. GUC gating: enableCollation off → collation ignored, binary comparison
-- =============================================================================

SET documentdb_core.enableCollation TO off;
-- With enableCollation off, the collation string is not applicable so
-- it should not error out (collation is simply ignored) and binary comparison applies.
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_test", "pipeline": [{ "$group": { "_id": "$g", "firstMatch": { "$first": { "$cond": { "if": { "$eq": ["$name", "CHERRY"] }, "then": "matched", "else": "no-match" } } } } }, { "$sort": { "_id": 1 } }], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

-- Reset GUCs and cleanup
SET documentdb_core.enableCollation TO off;
SET documentdb.enableNewWithExprAccumulators TO off;
SET documentdb.enableNewWithExprAccumulators TO off;
SET documentdb.enableCollationWithNewGroupAccumulators TO off;

SELECT documentdb_api.drop_collection('db', 'fl_collation_test');

-- =============================================================================
-- 19. $first returns null when the first document in a group has a missing
--     nested field, even though a later document has the field defined.
-- =============================================================================
SELECT documentdb_api.insert_one('db', 'fl_first_missing', '{ "_id": 1, "category": "electronics" }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_first_missing', '{ "_id": 2, "category": "electronics", "profile": { "email": "alice@test.com" } }', NULL);

SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_first_missing", "pipeline": [{ "$group": { "_id": "$category", "result": { "$first": "$profile.email" } } }], "cursor": {} }');

SELECT documentdb_api.drop_collection('db', 'fl_first_missing');

-- =============================================================================
-- 20. $last returns null when the last document in a group has a missing
--     nested field, even though an earlier document has the field defined.
--     (Flipped version of test 19.)
-- =============================================================================
SELECT documentdb_api.insert_one('db', 'fl_last_missing', '{ "_id": 1, "category": "electronics", "profile": { "email": "bob@test.com" } }', NULL);
SELECT documentdb_api.insert_one('db', 'fl_last_missing', '{ "_id": 2, "category": "electronics" }', NULL);

SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_last_missing", "pipeline": [{ "$group": { "_id": "$category", "result": { "$last": "$profile.email" } } }], "cursor": {} }');

SELECT documentdb_api.drop_collection('db', 'fl_last_missing');

-- =============================================================================
-- 21. EXPLAIN matrix: $sort on/off × GUC on/off for $first/$last in $group
-- Verifies which aggregate function is chosen in each combination.
-- =============================================================================

-- 21a. GUC on, no $sort → bsonfirstwithexpr / bsonlastwithexpr
SET documentdb.enableNewWithExprAccumulators TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$group": { "_id": "$g", "f": { "$first": "$v" }, "l": { "$last": "$v" } } }], "cursor": {} }');

-- 21b. GUC off, no $sort → bsonfirstonsorted / bsonlastonsorted
SET documentdb.enableNewWithExprAccumulators TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$group": { "_id": "$g", "f": { "$first": "$v" }, "l": { "$last": "$v" } } }], "cursor": {} }');

-- 21c. GUC on, with $sort → bsonfirst / bsonlast (sorted path, not WithExpr)
SET documentdb.enableNewWithExprAccumulators TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$sort": { "v": 1 } }, { "$group": { "_id": "$g", "f": { "$first": "$v" }, "l": { "$last": "$v" } } }], "cursor": {} }');

-- 21d. GUC off, with $sort → bsonfirst / bsonlast (sorted path)
SET documentdb.enableNewWithExprAccumulators TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$sort": { "v": 1 } }, { "$group": { "_id": "$g", "f": { "$first": "$v" }, "l": { "$last": "$v" } } }], "cursor": {} }');

-- =============================================================================
-- $setWindowFields tests for $first/$last with the new WithExpr accumulators
-- =============================================================================

-- 22. $first/$last with sortBy in $setWindowFields - GUC on
-- With sortBy, the old sorted path should be used regardless of GUC
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$setWindowFields": { "partitionBy": "$g", "sortBy": { "v": 1 }, "output": { "firstVal": { "$first": "$v" }, "lastName": { "$last": "$name" } } } }, { "$sort": { "_id": 1 } }], "cursor": {} }');

-- 23. $first/$last without sortBy in $setWindowFields - GUC off (old OnSorted path)
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$setWindowFields": { "partitionBy": "$g", "output": { "firstVal": { "$first": "$v" }, "lastName": { "$last": "$name" } } } }, { "$sort": { "_id": 1 } }], "cursor": {} }');

-- 24. $first/$last without sortBy in $setWindowFields - GUC on (new WithExpr path)
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$setWindowFields": { "partitionBy": "$g", "output": { "firstVal": { "$first": "$v" }, "lastName": { "$last": "$name" } } } }, { "$sort": { "_id": 1 } }], "cursor": {} }');

-- 25. Computed expression with sortBy in $setWindowFields
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$setWindowFields": { "partitionBy": "$g", "sortBy": { "v": 1 }, "output": { "firstDoubled": { "$first": { "$multiply": ["$v", 2] } }, "lastDoubled": { "$last": { "$multiply": ["$v", 2] } } } } }, { "$sort": { "_id": 1 } }], "cursor": {} }');

-- 26. With let variables (varSpec), no sortBy in $setWindowFields - GUC on
SET documentdb.enableNewWithExprAccumulators TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$setWindowFields": { "partitionBy": "$g", "output": { "firstAdj": { "$first": { "$add": ["$v", "$$bonus"] } }, "lastAdj": { "$last": { "$add": ["$v", "$$bonus"] } } } } }, { "$sort": { "_id": 1 } }], "cursor": {}, "let": { "bonus": 100 } }');

-- =============================================================================
-- 27. EXPLAIN matrix: sortBy on/off × GUC on/off for $first/$last in $setWindowFields
-- =============================================================================

-- 27a. GUC on, with sortBy → bsonfirst / bsonlast (sorted path, NOT WithExpr)
SET documentdb.enableNewWithExprAccumulators TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$setWindowFields": { "partitionBy": "$g", "sortBy": { "v": 1 }, "output": { "f": { "$first": "$v" }, "l": { "$last": "$name" } } } }], "cursor": {} }');

-- 27b. GUC off, no sortBy → bsonfirstonsorted / bsonlastonsorted
SET documentdb.enableNewWithExprAccumulators TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$setWindowFields": { "partitionBy": "$g", "output": { "f": { "$first": "$v" }, "l": { "$last": "$name" } } } }], "cursor": {} }');

-- 27c. GUC on, no sortBy → bsonfirstwithexpr / bsonlastwithexpr
SET documentdb.enableNewWithExprAccumulators TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$setWindowFields": { "partitionBy": "$g", "output": { "f": { "$first": "$v" }, "l": { "$last": "$name" } } } }], "cursor": {} }');

-- 27d. GUC on, no sortBy, with let → varSpec should include user let variables
SET documentdb.enableNewWithExprAccumulators TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$setWindowFields": { "partitionBy": "$g", "output": { "f": { "$first": { "$add": ["$v", "$$bonus"] } } } } }], "cursor": {}, "let": { "bonus": 100 } }');

-- =============================================================================
-- 28. enableSortGroupStage must keep the user $sort for order-sensitive
--     $first/$last accumulators
-- =============================================================================
SET documentdb.enableSortGroupStage TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_grp_test", "pipeline": [{ "$sort": { "v": 1 } }, { "$group": { "_id": "$g", "f": { "$first": "$v" }, "l": { "$last": "$v" } } }, { "$sort": { "_id": 1 } }], "cursor": {} }');
RESET documentdb.enableSortGroupStage;

-- =============================================================================
-- 29. $sort + $group with only $first operator.
--     When enableSortGroupStage and enableSortPushToAccumulatorWithPrefix are
--     on AND the group keys form a non-dotted prefix of the sort keys, the
--     explicit Sort node is dropped and any suffix sort keys are pushed into
--     the accumulator's ORDER BY.  When the sort spec is not a prefix of the
--     group keys, the Sort node is preserved.
-- =============================================================================

-- Insert test data: 10 rows across 4 groups
SELECT documentdb_api.insert_one('db','fl_sortgroup_test','{ "_id": 1, "g": "X", "seq": 30, "val": "third" }', NULL);
SELECT documentdb_api.insert_one('db','fl_sortgroup_test','{ "_id": 2, "g": "X", "seq": 10, "val": "first" }', NULL);
SELECT documentdb_api.insert_one('db','fl_sortgroup_test','{ "_id": 3, "g": "X", "seq": 20, "val": "second" }', NULL);
SELECT documentdb_api.insert_one('db','fl_sortgroup_test','{ "_id": 4, "g": "Y", "seq": 50, "val": "later" }', NULL);
SELECT documentdb_api.insert_one('db','fl_sortgroup_test','{ "_id": 5, "g": "Y", "seq": 5, "val": "earliest" }', NULL);
SELECT documentdb_api.insert_one('db','fl_sortgroup_test','{ "_id": 6, "g": "Z", "seq": 40, "val": "high" }', NULL);
SELECT documentdb_api.insert_one('db','fl_sortgroup_test','{ "_id": 7, "g": "Z", "seq": 15, "val": "low" }', NULL);
SELECT documentdb_api.insert_one('db','fl_sortgroup_test','{ "_id": 8, "g": "Z", "seq": 25, "val": "mid" }', NULL);
SELECT documentdb_api.insert_one('db','fl_sortgroup_test','{ "_id": 9, "g": "W", "seq": 100, "val": "only-high" }', NULL);
SELECT documentdb_api.insert_one('db','fl_sortgroup_test','{ "_id": 10, "g": "W", "seq": 1, "val": "only-low" }', NULL);

-- With sortGroup OFF: Sort node should be present in the plan
SET documentdb.enableSortGroupStage TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "g": 1, "seq": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "g": 1, "seq": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');

-- With sortGroup ON: Sort node for {g,seq} should disappear, and orderby pushed to aggregate
SET documentdb.enableSortGroupStage TO on;
SET documentdb.enableSortPushToAccumulatorWithPrefix TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "g": 1, "seq": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "g": 1, "seq": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');

-- =============================================================================
-- 30. Negative tests: $sort + $group with only $first where sort should NOT
--     be pushed into the aggregate ORDER BY despite enableSortGroupStage=on.
--     IsSortSpecCompatibleForPushToAccumulatorOperator rejects $meta and $natural.
-- =============================================================================

-- 30a. $meta in sort spec → sort not pushed to accumulator (Sort node present)
SET documentdb.enableSortGroupStage TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "score": { "$meta": "textScore" } } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');

-- 30b. $natural in sort spec → sort not pushed to accumulator (Sort node present)
SET documentdb.enableSortGroupStage TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "$natural": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');

-- 30c. Mix of $first and $sum with non-prefix sort {seq} (group key is $g).
--      Sort spec is not a prefix of the group keys, so the Sort node is
--      preserved; $first cannot use the prefix-push path here.
SET documentdb.enableSortGroupStage TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" }, "total": { "$sum": "$seq" } } } ] }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" }, "total": { "$sum": "$seq" } } } ] }');

-- =============================================================================
-- 31. Descending sort.  31a uses sort {seq} (non-prefix, Sort node remains);
--     31b/31c use sort {g, seq} (prefix-eligible, suffix {seq} pushed into
--     accumulator's ORDER BY).
-- =============================================================================
SET documentdb.enableSortGroupStage TO on;
-- 31a. Single descending: non-prefix sort, Sort node remains; $first picks the row with the highest seq (100 for W, 50 for Y, etc.)
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": -1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": -1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');

-- 31b. Compound descending
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "g": -1, "seq": -1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');

-- 31c. Mixed ascending/descending: ascending on group key, descending on tiebreaker
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "g": 1, "seq": -1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "g": 1, "seq": -1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');

-- =============================================================================
-- 32. Multiple $first accumulators with non-prefix sort {seq}.
--     Sort spec is not a prefix of group key $g; Sort node remains.
-- =============================================================================
SET documentdb.enableSortGroupStage TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" }, "firstSeq": { "$first": "$seq" } } } ] }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" }, "firstSeq": { "$first": "$seq" } } } ] }');

-- =============================================================================
-- 33. $first with expression input under non-prefix sort {seq}.
--     Sort node remains; expression evaluation happens after the sort.
-- =============================================================================
SET documentdb.enableSortGroupStage TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "firstDoubled": { "$first": { "$multiply": ["$seq", 2] } } } } ] }');

-- =============================================================================
-- 34. Pipeline continuation: $sort + $group $first + subsequent $sort.
--     Non-prefix sort {seq} on the inner stage; Sort node remains there.
-- =============================================================================
SET documentdb.enableSortGroupStage TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } }, { "$sort": { "_id": 1 } } ], "cursor": {} }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } }, { "$sort": { "_id": 1 } } ], "cursor": {} }');

-- =============================================================================
-- 35. $first + all order-insensitive accumulators combined.
--     Non-prefix sort {seq}; Sort node remains.
-- =============================================================================
SET documentdb.enableSortGroupStage TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" }, "total": { "$sum": "$seq" }, "average": { "$avg": "$seq" }, "minSeq": { "$min": "$seq" }, "maxSeq": { "$max": "$seq" }, "cnt": { "$count": {} } } } ] }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" }, "total": { "$sum": "$seq" }, "average": { "$avg": "$seq" }, "minSeq": { "$min": "$seq" }, "maxSeq": { "$max": "$seq" }, "cnt": { "$count": {} } } } ] }');

-- =============================================================================
-- 36. Accumulators that block optimization (Sort node must remain)
-- =============================================================================
SET documentdb.enableSortGroupStage TO on;

-- 36a. $push only → sort NOT pushed
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "vals": { "$push": "$val" } } } ] }');

-- 36b. $addToSet only → sort NOT pushed
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "vals": { "$addToSet": "$val" } } } ] }');

-- 36c. $last only → sort NOT pushed
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "lastVal": { "$last": "$val" } } } ] }');

-- 36d. $mergeObjects only → sort NOT pushed (non-positional but still blocks)
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "merged": { "$mergeObjects": { "s": "$seq", "v": "$val" } } } } ] }');

-- =============================================================================
-- 37. Edge case: $group with only _id, no accumulators → sort dropped entirely
-- =============================================================================
SET documentdb.enableSortGroupStage TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g" } } ] }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g" } } ] }');

-- 37b. We do not require sort ordering in the group and it is just a distinct
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "g": 1 } }, { "$group": { "_id": "$g" } } ] }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "g": 1 } }, { "$group": { "_id": "$g" } } ] }');

-- =============================================================================
-- 38. enableNewWithExprAccumulators OFF with non-prefix sort.
--     Sort spec {seq} is not a prefix of group key $g, so Sort node remains;
--     this exercises the legacy BsonFirstOnSortedAggregate path.
-- =============================================================================
SET documentdb.enableSortGroupStage TO on;
SET documentdb.enableNewWithExprAccumulators TO off;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');
SET documentdb.enableNewWithExprAccumulators TO on;

-- =============================================================================
-- 39. enableOrderByIndexTerm with $sort + $group.
--     Only 39d uses a prefix-eligible sort {g, seq}; the others use non-prefix
--     sort {seq} so the Sort node remains and bson_orderby_index appears in
--     the explicit Sort instead of aggorder.
-- =============================================================================

-- 39a. enableOrderByIndexTerm ON, enableSortGroupStage OFF: bson_orderby_index in Sort node
SET documentdb.enableOrderByIndexTerm TO on;
SET documentdb.enableSortGroupStage TO off;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');

-- 39b. enableOrderByIndexTerm ON, enableSortGroupStage ON, non-prefix sort:
--      bson_orderby_index stays in the Sort node (no prefix-push)
SET documentdb.enableOrderByIndexTerm TO on;
SET documentdb.enableSortGroupStage TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');

-- 39c. enableOrderByIndexTerm ON, descending non-prefix sort: bson_orderby_index_reverse in Sort node
SET documentdb.enableOrderByIndexTerm TO on;
SET documentdb.enableSortGroupStage TO on;
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": -1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');

-- 39d. Execution: enableOrderByIndexTerm ON, enableSortGroupStage ON, prefix-eligible ascending
--      Sort {g, seq} matches the group prefix, so suffix {seq} is pushed into aggorder.
--      Output must match enableOrderByIndexTerm OFF (test 29 ON result)
SET documentdb.enableOrderByIndexTerm TO on;
SET documentdb.enableSortGroupStage TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "g": 1, "seq": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');

-- 39e. Execution: enableOrderByIndexTerm ON, enableSortGroupStage ON, non-prefix descending
SET documentdb.enableOrderByIndexTerm TO on;
SET documentdb.enableSortGroupStage TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_sortgroup_test", "pipeline": [ { "$sort": { "seq": -1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');

RESET documentdb.enableOrderByIndexTerm;

-- =============================================================================
-- 40. Nested field paths in sort spec.
--     Sort {info.priority} is dotted and group key is $g, so the prefix
--     decomposition bails out (dotted paths) and Sort node remains.
-- =============================================================================
SELECT documentdb_api.insert_one('db','fl_nested_sort','{ "_id": 1, "g": "A", "info": { "priority": 3 }, "val": "low-pri" }', NULL);
SELECT documentdb_api.insert_one('db','fl_nested_sort','{ "_id": 2, "g": "A", "info": { "priority": 1 }, "val": "high-pri" }', NULL);
SELECT documentdb_api.insert_one('db','fl_nested_sort','{ "_id": 3, "g": "B", "info": { "priority": 5 }, "val": "b-low" }', NULL);
SELECT documentdb_api.insert_one('db','fl_nested_sort','{ "_id": 4, "g": "B", "info": { "priority": 2 }, "val": "b-high" }', NULL);

SET documentdb.enableSortGroupStage TO on;
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_nested_sort", "pipeline": [ { "$sort": { "info.priority": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_nested_sort", "pipeline": [ { "$sort": { "info.priority": 1 } }, { "$group": { "_id": "$g", "firstVal": { "$first": "$val" } } } ] }');

SELECT documentdb_api.drop_collection('db', 'fl_nested_sort');

-- =============================================================================
-- 41. Collation with non-prefix sort {name} (group key $g): case-insensitive
--     sort affects $first result.  Sort node remains; collation applies inside
--     the explicit Sort.
--     Binary comparison sorts uppercase before lowercase (e.g. "Banana" < "apple"),
--     while case-insensitive collation (strength=1) sorts alphabetically ("apple" < "Banana").
-- =============================================================================
SELECT documentdb_api.insert_one('db','fl_collation_sortpush','{ "_id": 1, "g": "A", "name": "cherry", "seq": 2 }', NULL);
SELECT documentdb_api.insert_one('db','fl_collation_sortpush','{ "_id": 2, "g": "A", "name": "Banana", "seq": 1 }', NULL);
SELECT documentdb_api.insert_one('db','fl_collation_sortpush','{ "_id": 3, "g": "A", "name": "apple", "seq": 3 }', NULL);
SELECT documentdb_api.insert_one('db','fl_collation_sortpush','{ "_id": 4, "g": "B", "name": "date", "seq": 2 }', NULL);
SELECT documentdb_api.insert_one('db','fl_collation_sortpush','{ "_id": 5, "g": "B", "name": "Elderberry", "seq": 1 }', NULL);

SET documentdb.enableSortGroupStage TO on;
SET documentdb.enableNewWithExprAccumulators TO on;
SET documentdb.enableCollationWithNewGroupAccumulators TO on;
SET documentdb_core.enableCollation TO on;

-- 41a. With collation (case-insensitive): sort by name ascending, $first picks alphabetically first
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_sortpush", "pipeline": [ { "$sort": { "name": 1 } }, { "$group": { "_id": "$g", "firstName": { "$first": "$name" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

-- 41b. EXPLAIN: Sort node remains (non-prefix sort); collation-aware orderby applies in the Sort
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_sortpush", "pipeline": [ { "$sort": { "name": 1 } }, { "$group": { "_id": "$g", "firstName": { "$first": "$name" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

-- 41c. Without collation (binary comparison): $first result differs from collated sort
--      Binary: "Banana"(0x42) < "apple"(0x61) vs case-insensitive: "apple" < "Banana"
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_sortpush", "pipeline": [ { "$sort": { "name": 1 } }, { "$group": { "_id": "$g", "firstName": { "$first": "$name" } } } ], "cursor": {} }');

-- 41d. Collation with descending sort
SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_sortpush", "pipeline": [ { "$sort": { "name": -1 } }, { "$group": { "_id": "$g", "firstName": { "$first": "$name" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');
EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('db', '{ "aggregate": "fl_collation_sortpush", "pipeline": [ { "$sort": { "name": -1 } }, { "$group": { "_id": "$g", "firstName": { "$first": "$name" } } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }');

SET documentdb_core.enableCollation TO off;
SET documentdb.enableCollationWithNewGroupAccumulators TO off;

SELECT documentdb_api.drop_collection('db', 'fl_collation_sortpush');

RESET documentdb.enableSortPushToAccumulatorWithPrefix;
RESET documentdb.enableSortGroupStage;
SELECT documentdb_api.drop_collection('db', 'fl_sortgroup_test');

-- Cleanup original test collection
SELECT documentdb_api.drop_collection('db', 'fl_grp_test');
