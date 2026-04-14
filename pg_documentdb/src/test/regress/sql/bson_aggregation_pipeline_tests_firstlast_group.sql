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

-- 29. Cleanup original test collection
SELECT documentdb_api.drop_collection('db', 'fl_grp_test');
