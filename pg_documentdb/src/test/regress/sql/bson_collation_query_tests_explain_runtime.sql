SET citus.next_shard_id TO 8900000;
SET documentdb.next_collection_id TO 8900;
SET documentdb.next_collection_index_id TO 8900;

SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableExtendedExplainPlans TO on;

SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_simple', '{ "_id": 1, "a": "cat" }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_simple', '{ "_id": 2, "a": "Cat" }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_simple', '{ "_id": 3, "a": "DOG" }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_simple', '{ "_id": 4, "a": "dog" }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_simple', '{ "_id": 5, "a": "rabbit" }');

-- find with collation on equality predicate
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_q_runtime_explain_db', '{ "find": "coll_simple", "filter": { "a": "CAT" }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }') $cmd$);

-- find with $expr equality on collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_q_runtime_explain_db', '{ "find": "coll_simple", "filter": { "$expr": {"$eq": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }') $cmd$);

-- find with $expr inequality on collation (different locale)
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_q_runtime_explain_db', '{ "find": "coll_simple", "filter": { "$expr": {"$gte": ["$a", "CAT"]} }, "sort": { "_id": 1 }, "collation": { "locale": "fr", "strength": 1 } }') $cmd$);

-- aggregation pipeline with $match and collation
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_q_runtime_explain_db', '{ "aggregate": "coll_simple", "pipeline": [ { "$match": { "a": "DOG" } }, { "$sort": { "_id": 1 } } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }') $cmd$);

-- covered $count under collation without an index -> sequential scan
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_pipeline('coll_q_runtime_explain_db', '{ "aggregate": "coll_simple", "pipeline": [ { "$match": { "a": "CAT" } }, { "$count": "n" } ], "cursor": {}, "collation": { "locale": "en", "strength": 1 } }') $cmd$);
END;

-- count command without a matching collated index -> runtime filter
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_count('coll_q_runtime_explain_db', '{ "count": "coll_simple", "query": { "a": "CAT" }, "collation": { "locale": "en", "strength": 1 } }') $cmd$);
END;

-- equality on a string _id under collation without an index -> sequential scan
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_id_simple', '{ "_id": "cat" }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_id_simple', '{ "_id": "Cat" }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_id_simple', '{ "_id": "dog" }');
BEGIN;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableExtendedExplainPlans TO on;
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$ EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('coll_q_runtime_explain_db', '{ "find": "coll_id_simple", "filter": { "_id": "cat" }, "sort": { "_id": 1 }, "collation": { "locale": "en", "strength": 1 } }') $cmd$);
END;

-- Distinct with collation performs semantic deduplication with complete
-- collated keys.
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_distinct', '{ "_id": 1, "a": "cafe", "n": { "a": "cafe" }, "arr": [ "cafe", "tea" ] }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_distinct', '{ "_id": 2, "a": "CAFE", "n": { "a": "CAFE" }, "arr": [ "CAFE" ] }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_distinct', '{ "_id": 3, "a": "tea", "n": { "a": "tea" }, "arr": [ "TEA" ] }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_distinct(
  'coll_q_runtime_explain_db',
  '{ "distinct": "coll_distinct", "key": "a", "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- Dotted paths use the same three-argument unwind expression.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_distinct(
  'coll_q_runtime_explain_db',
  '{ "distinct": "coll_distinct", "key": "n.a", "query": { "a": { "$in": [ "CAFE", "TEA" ] } }, "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- Arrays retain ProjectSet, Sort, and Unique when no ordered index is present.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_distinct(
  'coll_q_runtime_explain_db',
  '{ "distinct": "coll_distinct", "key": "arr", "collation": { "locale": "en", "strength": 1 } }')
$cmd$);

-- Without a collation, distinct uses hash aggregation with binary comparison.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_distinct(
  'coll_q_runtime_explain_db',
  '{ "distinct": "coll_distinct", "key": "a" }')
$cmd$);

SELECT documentdb_api.drop_collection('coll_q_runtime_explain_db', 'coll_distinct');

-- ======================================================================
-- update: per-operation collation without a matching collated index
-- ======================================================================
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_update_explain', '{ "_id": "cat", "a": "cat" }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_update_explain', '{ "_id": "CAT", "a": "CAT" }');
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_update_explain', '{ "_id": "dog", "a": "dog" }');

-- multi:true carries the normalized collation into the selection filter that
-- picks the matched documents. The update expression itself keeps binary
-- semantics, so update_bson_document receives no collation argument.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_runtime_explain_db',
  '{ "update": "coll_update_explain", "updates": [ { "q": { "a": "CaT" }, "u": { "$set": { "b": 1 } }, "multi": true, "collation": { "locale": "en", "strength": 1 } } ] }')
$cmd$);

-- The same update without a collation drops the collation from the selection
-- filter. The update_bson_document call is unchanged, confirming the collation
-- only ever affects document selection.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_runtime_explain_db',
  '{ "update": "coll_update_explain", "updates": [ { "q": { "a": "CaT" }, "u": { "$set": { "b": 1 } }, "multi": true } ] }')
$cmd$);

-- multi:false selects a single locked candidate; the collation reaches the
-- candidate filter.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_runtime_explain_db',
  '{ "update": "coll_update_explain", "updates": [ { "q": { "a": "CaT" }, "u": { "$set": { "b": 1 } }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }')
$cmd$);

-- The sort that picks the single candidate orders on the collated index term.
-- With no collated index present the accompanying full scan qual cannot be
-- served, so the ordering is materialized by a Sort at runtime.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_runtime_explain_db',
  '{ "update": "coll_update_explain", "updates": [ { "q": { "a": "CaT" }, "u": { "$set": { "b": 1 } }, "multi": false, "sort": { "a": 1 }, "collation": { "locale": "en", "strength": 1 } } ] }')
$cmd$);

-- A descending collated sort uses the reverse index term variant.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_runtime_explain_db',
  '{ "update": "coll_update_explain", "updates": [ { "q": { "a": "CaT" }, "u": { "$set": { "b": 1 } }, "multi": false, "sort": { "a": -1 }, "collation": { "locale": "en", "strength": 1 } } ] }')
$cmd$);

-- A $meta ordering has no index term, so it falls back to the collation aware
-- runtime ordering operator.
SELECT documentdb_api_internal.create_indexes_non_concurrently('coll_q_runtime_explain_db',
  '{ "createIndexes": "coll_update_explain_text", "indexes": [ { "key": { "a": "text" }, "name": "idx_update_text_a" } ] }', TRUE);
SELECT documentdb_api.insert_one('coll_q_runtime_explain_db', 'coll_update_explain_text', '{ "_id": 1, "a": "cat" }');

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_runtime_explain_db',
  '{ "update": "coll_update_explain_text", "updates": [ { "q": { "$text": { "$search": "cat" } }, "u": { "$set": { "b": 1 } }, "multi": false, "sort": { "s": { "$meta": "textScore" } }, "collation": { "locale": "en", "strength": 1 } } ] }')
$cmd$);

SELECT documentdb_api.drop_collection('coll_q_runtime_explain_db', 'coll_update_explain_text');

-- The same sort without a collation keeps the binary ordering operator.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_runtime_explain_db',
  '{ "update": "coll_update_explain", "updates": [ { "q": { "a": "CaT" }, "u": { "$set": { "b": 1 } }, "multi": false, "sort": { "a": 1 } } ] }')
$cmd$);

-- A collation sensitive _id value cannot use the binary object_id equality
-- bound, so selection falls back to a collated runtime filter.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_runtime_explain_db',
  '{ "update": "coll_update_explain", "updates": [ { "q": { "_id": "cat" }, "u": { "$set": { "b": 1 } }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }')
$cmd$);

-- A non string _id is not collation sensitive, so the object_id bound is kept
-- even under a collation.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_runtime_explain_db',
  '{ "update": "coll_update_explain", "updates": [ { "q": { "_id": 1 }, "u": { "$set": { "b": 1 } }, "multi": false, "collation": { "locale": "en", "strength": 1 } } ] }')
$cmd$);

-- Without a collation the same string _id equality still pushes down as
-- object_id.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_runtime_explain_db',
  '{ "update": "coll_update_explain", "updates": [ { "q": { "_id": "cat" }, "u": { "$set": { "b": 1 } }, "multi": false } ] }')
$cmd$);

-- let and collation are carried together into the $expr predicate.
SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF, VERBOSE ON)
SELECT document FROM bson_aggregation_update(
  'coll_q_runtime_explain_db',
  '{ "update": "coll_update_explain", "updates": [ { "q": { "$expr": { "$eq": [ "$a", "$$target" ] } }, "u": { "$set": { "b": 1 } }, "multi": true, "collation": { "locale": "en", "strength": 1 } } ], "let": { "target": "CAT" } }')
$cmd$);

SELECT documentdb_api.drop_collection('coll_q_runtime_explain_db', 'coll_update_explain');
