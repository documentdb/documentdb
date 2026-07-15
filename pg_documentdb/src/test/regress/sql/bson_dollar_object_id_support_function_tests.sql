SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET documentdb.next_collection_id TO 1984500;
SET documentdb.next_collection_index_id TO 1984500;

-- Insert test data
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('objid_support_db', 'test_support_func', FORMAT('{ "_id": %s, "a": %s }', g, g)::bson) FROM generate_series(1, 100) g) i;

-- Test 1: Direct invocation of the 3-argument UDFs to validate runtime results.
-- These are the object_id overloads (bson, bson, bsonquery) used for btree index pushdown.

-- bson_dollar_eq: should return true when _id matches
SELECT bson_dollar_eq('{ "_id": 5, "a": 5 }', '{ "": 5 }', '{ "_id": 5 }');
-- bson_dollar_eq: should return false when _id does not match
SELECT bson_dollar_eq('{ "_id": 5, "a": 5 }', '{ "": 5 }', '{ "_id": 10 }');

-- bson_dollar_gt: should return true when _id > value
SELECT bson_dollar_gt('{ "_id": 10, "a": 10 }', '{ "": 10 }', '{ "_id": 5 }');
-- bson_dollar_gt: should return false when _id <= value
SELECT bson_dollar_gt('{ "_id": 5, "a": 5 }', '{ "": 5 }', '{ "_id": 10 }');

-- bson_dollar_gte: should return true when _id >= value
SELECT bson_dollar_gte('{ "_id": 10, "a": 10 }', '{ "": 10 }', '{ "_id": 10 }');
-- bson_dollar_gte: should return false when _id < value
SELECT bson_dollar_gte('{ "_id": 5, "a": 5 }', '{ "": 5 }', '{ "_id": 10 }');

-- bson_dollar_lt: should return true when _id < value
SELECT bson_dollar_lt('{ "_id": 5, "a": 5 }', '{ "": 5 }', '{ "_id": 10 }');
-- bson_dollar_lt: should return false when _id >= value
SELECT bson_dollar_lt('{ "_id": 10, "a": 10 }', '{ "": 10 }', '{ "_id": 5 }');

-- bson_dollar_lte: should return true when _id <= value
SELECT bson_dollar_lte('{ "_id": 10, "a": 10 }', '{ "": 10 }', '{ "_id": 10 }');
-- bson_dollar_lte: should return false when _id > value
SELECT bson_dollar_lte('{ "_id": 10, "a": 10 }', '{ "": 10 }', '{ "_id": 5 }');

-- bson_dollar_in: should return true when _id is in the array
SELECT bson_dollar_in('{ "_id": 5, "a": 5 }', '{ "": 5 }', '{ "_id": [1, 5, 10] }');
-- bson_dollar_in: should return false when _id is not in the array
SELECT bson_dollar_in('{ "_id": 7, "a": 7 }', '{ "": 7 }', '{ "_id": [1, 5, 10] }');

-- Test 2: Runtime sanity on the btree _id_ index.
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": 15 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_gt(document, object_id, '{ "_id": 97 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_gte(document, object_id, '{ "_id": 99 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_lt(document, object_id, '{ "_id": 3 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_lte(document, object_id, '{ "_id": 2 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_in(document, object_id, '{ "_id": [10, 20, 30] }');

-- Test 2b: Index Scan pushdown to the _id_ btree index.
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": 15 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_gt(document, object_id, '{ "_id": 97 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_gte(document, object_id, '{ "_id": 99 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_lt(document, object_id, '{ "_id": 3 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_lte(document, object_id, '{ "_id": 2 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_in(document, object_id, '{ "_id": [10, 20, 30] }');

-- Test 2c: Bitmap scan pushdown to the _id_ btree index.
BEGIN;
SET LOCAL enable_indexscan TO off;
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": 15 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_gt(document, object_id, '{ "_id": 97 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_gte(document, object_id, '{ "_id": 99 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_lt(document, object_id, '{ "_id": 3 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_lte(document, object_id, '{ "_id": 2 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_in(document, object_id, '{ "_id": [10, 20, 30] }');
COMMIT;

-- Test 3: Compound RUM ordered index on (a, _id).
SELECT documentdb_api_internal.create_indexes_non_concurrently('objid_support_db', '{ "createIndexes": "test_support_func", "indexes": [ { "key": { "a": 1, "_id": 1 }, "name": "idx_a_id", "storageEngine": { "enableOrderedIndex": true } } ]}', true);

-- Runtime sanity.
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": 15 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_gt(document, object_id, '{ "_id": 97 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_in(document, object_id, '{ "_id": [10, 20, 30] }');

-- Test 3b: _id-only predicate must skip the (a, _id) compound index (leading column unspecified) and fall back to _id_ btree.
BEGIN;
SET LOCAL enable_seqscan TO off;
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": 15 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_gt(document, object_id, '{ "_id": 97 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_in(document, object_id, '{ "_id": [10, 20, 30] }');
COMMIT;

-- Test 3c: a + _id predicates push down to idx_a_id Index Scan.
ANALYZE;
BEGIN;
SET LOCAL enable_seqscan TO off;
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, '{ "a": 15 }') AND bson_dollar_eq(document, object_id, '{ "_id": 15 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, '{ "a": 50 }') AND bson_dollar_gt(document, object_id, '{ "_id": 40 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, '{ "a": 20 }') AND bson_dollar_in(document, object_id, '{ "_id": [10, 20, 30] }');
COMMIT;

-- Runtime sanity.
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, '{ "a": 15 }') AND bson_dollar_eq(document, object_id, '{ "_id": 15 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, '{ "a": 50 }') AND bson_dollar_gt(document, object_id, '{ "_id": 40 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, '{ "a": 20 }') AND bson_dollar_in(document, object_id, '{ "_id": [10, 20, 30] }');

-- Test 3d: a + _id predicates push down to idx_a_id Bitmap Index Scan.
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_indexscan TO off;
SET LOCAL enable_indexonlyscan TO off;
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, '{ "a": 15 }') AND bson_dollar_eq(document, object_id, '{ "_id": 15 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, '{ "a": 50 }') AND bson_dollar_gt(document, object_id, '{ "_id": 40 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, '{ "a": 20 }') AND bson_dollar_in(document, object_id, '{ "_id": [10, 20, 30] }');
-- Runtime sanity.
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, '{ "a": 15 }') AND bson_dollar_eq(document, object_id, '{ "_id": 15 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, '{ "a": 50 }') AND bson_dollar_gt(document, object_id, '{ "_id": 40 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, '{ "a": 20 }') AND bson_dollar_in(document, object_id, '{ "_id": [10, 20, 30] }');
COMMIT;

-- Test 3e: _id-only predicate under bitmap path falls back to _id_ btree.
BEGIN;
SET LOCAL enable_seqscan TO off;
SET LOCAL enable_indexscan TO off;
SET LOCAL enable_indexonlyscan TO off;
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": 15 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_in(document, object_id, '{ "_id": [10, 20, 30] }');
COMMIT;

-- Test 3f: 'a' is pushed via idx_a_id but the _id predicate is wrapped in NOT
-- and therefore non-indexable; the original bson_dollar_eq runtime call
-- survives as a per-row Filter (executed against object_id, not document).
BEGIN;
SET LOCAL enable_seqscan TO off;
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, '{ "a": 15 }') AND NOT bson_dollar_eq(document, object_id, '{ "_id": 15 }');
EXPLAIN (COSTS OFF, VERBOSE) SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, '{ "a": 15 }') AND NOT bson_dollar_in(document, object_id, '{ "_id": [10, 20, 30] }');
-- Runtime sanity: a=15 row has _id=15, so the first NOT-clause filters it out;
-- the second leaves it (15 is not in {10,20,30}).
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, '{ "a": 15 }') AND NOT bson_dollar_eq(document, object_id, '{ "_id": 15 }');
SELECT document FROM documentdb_api.collection('objid_support_db', 'test_support_func')
  WHERE bson_dollar_eq(document, '{ "a": 15 }') AND NOT bson_dollar_in(document, object_id, '{ "_id": [10, 20, 30] }');
COMMIT;

-- Test 4: Runtime evaluation of 3-arg ObjectId UDFs without index pushdown.
-- Heterogeneous _id types, including one row just above the TOAST threshold.
SELECT documentdb_api.insert_one('objid_support_db', 'test_runtime_eval',
  '{ "_id": 1, "kind": "int" }');
SELECT documentdb_api.insert_one('objid_support_db', 'test_runtime_eval',
  '{ "_id": { "$numberLong": "9223372036854775000" }, "kind": "long" }');
SELECT documentdb_api.insert_one('objid_support_db', 'test_runtime_eval',
  '{ "_id": { "$numberDouble": "3.14" }, "kind": "double" }');
SELECT documentdb_api.insert_one('objid_support_db', 'test_runtime_eval',
  '{ "_id": "hello", "kind": "string" }');
SELECT documentdb_api.insert_one('objid_support_db', 'test_runtime_eval',
  '{ "_id": { "$oid": "507f1f77bcf86cd799439011" }, "kind": "oid" }');
SELECT documentdb_api.insert_one('objid_support_db', 'test_runtime_eval',
  '{ "_id": { "x": 1, "y": 2 }, "kind": "subdoc" }');
SELECT documentdb_api.insert_one('objid_support_db', 'test_runtime_eval',
  '{ "_id": true, "kind": "bool_true" }');
SELECT documentdb_api.insert_one('objid_support_db', 'test_runtime_eval',
  '{ "_id": false, "kind": "bool_false" }');
SELECT documentdb_api.insert_one('objid_support_db', 'test_runtime_eval',
  '{ "_id": null, "kind": "null" }');
-- Just over the TOAST threshold; runtime should not detoast `document`.
SELECT documentdb_api.insert_one('objid_support_db', 'test_runtime_eval',
  FORMAT('{ "_id": 9999, "kind": "big", "blob": "%s" }', repeat('x', 2100))::bson);

-- Test 4a: Seq scan over heterogeneous _id corpus.
BEGIN;
SET LOCAL enable_indexscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_indexonlyscan TO off;

-- Plan check: Seq Scan with bson_dollar_eq in the Filter.
EXPLAIN (COSTS OFF, VERBOSE) SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": 1 }');

-- $eq across every type.
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": 1 }') ORDER BY kind;
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": "hello" }') ORDER BY kind;
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": { "$oid": "507f1f77bcf86cd799439011" } }') ORDER BY kind;
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": { "x": 1, "y": 2 } }') ORDER BY kind;
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": true }') ORDER BY kind;
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": null }') ORDER BY kind;
-- Numeric cross-type equality.
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": { "$numberDouble": "3.14" } }') ORDER BY kind;
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": { "$numberLong": "9223372036854775000" } }') ORDER BY kind;
-- Big-blob row: predicate evaluated via object_id, document blob not detoasted.
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_eq(document, object_id, '{ "_id": 9999 }');

-- $gt / $gte / $lt / $lte across the heterogeneous corpus.
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_gt(document, object_id, '{ "_id": 1 }') ORDER BY kind;
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_gte(document, object_id, '{ "_id": 1 }') ORDER BY kind;
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_lt(document, object_id, '{ "_id": "hello" }') ORDER BY kind;
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_lte(document, object_id, '{ "_id": "hello" }') ORDER BY kind;

-- $in with heterogeneous array.
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_in(document, object_id, '{ "_id": [1, "hello", true, null, 9999] }') ORDER BY kind;
-- $in with empty array.
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_in(document, object_id, '{ "_id": [] }');
-- $in with single-element array.
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_in(document, object_id, '{ "_id": [1] }') ORDER BY kind;
-- $in with no matches.
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_in(document, object_id, '{ "_id": [42, "missing"] }');

COMMIT;

-- Test 4b: Adversarial direct invocation. Pass document and object_id whose
-- _id values disagree to prove the runtime uses object_id, not document.
SELECT bson_dollar_eq('{ "_id": 5, "a": 5 }', '{ "": 10 }', '{ "_id": 10 }') AS uses_object_id_not_document;
-- Same shape, query for _id == 5 must be false.
SELECT bson_dollar_eq('{ "_id": 5, "a": 5 }', '{ "": 10 }', '{ "_id": 5 }') AS ignores_document_id;

-- $gt with document._id=100 but object_id=1: must be false.
SELECT bson_dollar_gt('{ "_id": 100, "a": 100 }', '{ "": 1 }', '{ "_id": 50 }') AS gt_uses_object_id;

-- $in with mismatched document._id vs object_id.
SELECT bson_dollar_in('{ "_id": 99, "a": 99 }', '{ "": 5 }', '{ "_id": [1, 5, 10] }') AS in_uses_object_id;
SELECT bson_dollar_in('{ "_id": 5, "a": 5 }', '{ "": 99 }', '{ "_id": [1, 5, 10] }') AS in_ignores_document_id;

-- Cross-type direct calls.
SELECT bson_dollar_eq('{ "_id": "x" }', '{ "": "hello" }', '{ "_id": "hello" }') AS eq_string;
SELECT bson_dollar_eq('{ "_id": "x" }', '{ "": { "$oid": "507f1f77bcf86cd799439011" } }', '{ "_id": { "$oid": "507f1f77bcf86cd799439011" } }') AS eq_oid;
SELECT bson_dollar_lt('{ "_id": 1 }', '{ "": "abc" }', '{ "_id": "def" }') AS lt_string;
SELECT bson_dollar_gte('{ "_id": 1 }', '{ "": { "$numberDouble": "1.5" } }', '{ "_id": { "$numberInt": "1" } }') AS gte_mixed_numeric;

-- $regex on string _id via object_id overload (seq scan).
BEGIN;
SET LOCAL enable_indexscan TO off;
SET LOCAL enable_bitmapscan TO off;
SET LOCAL enable_indexonlyscan TO off;
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_regex(document, object_id, '{ "_id": { "$regex": "^hel", "$options": "" } }');
SELECT document->>'kind' AS kind FROM documentdb_api.collection('objid_support_db', 'test_runtime_eval')
  WHERE bson_dollar_regex(document, object_id, '{ "_id": { "$regex": "no_match", "$options": "" } }');
COMMIT;
