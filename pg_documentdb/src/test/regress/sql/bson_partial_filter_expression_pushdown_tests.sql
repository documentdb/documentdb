SET search_path TO documentdb_api,documentdb_api_catalog,documentdb_api_internal,documentdb_core;
SET documentdb.next_collection_id TO 87100;
SET documentdb.next_collection_index_id TO 87100;
SET documentdb.forceDisableSeqScan TO on;

-- =============================================
-- Setup: Insert test data with per-section fields to ensure deterministic index selection
-- =============================================
SELECT documentdb_api.insert_one('pfedb', 'pfecoll', '{"_id": 1, "s1_age": 25, "s2_score": 80, "s3_status": "active", "s3_val": 25, "s4_status": "active", "s4_val": 30, "s5_tags": ["a","b"], "s5_name": "alice", "s6_status": "active", "s6_age": 25, "s6_name": "alice", "s6_score": 80, "s6_sval": 80, "s6_sage": 25, "s7_name": "alice", "s10_nx": 1, "s13_status": "active", "s13_name": "alice", "s14_status": "active", "s14_score": 80}');
SELECT documentdb_api.insert_one('pfedb', 'pfecoll', '{"_id": 2, "s1_age": 30, "s2_score": 90, "s3_status": "active", "s3_val": 30, "s4_status": "active", "s4_val": 35, "s5_tags": ["b","c"], "s5_name": "bob", "s6_status": "active", "s6_age": 30, "s6_name": "bob", "s6_score": 90, "s6_sval": 90, "s6_sage": 30, "s7_name": "bob", "s10_nx": 2, "s13_status": "active", "s13_name": "bob", "s14_status": "active", "s14_score": 90}');
SELECT documentdb_api.insert_one('pfedb', 'pfecoll', '{"_id": 3, "s1_age": 35, "s2_score": 70, "s3_status": "inactive", "s3_val": 35, "s4_status": "inactive", "s4_val": 40, "s5_tags": ["a","c"], "s5_name": "charlie", "s6_status": "inactive", "s6_age": 35, "s6_name": "charlie", "s6_score": 70, "s6_sval": 70, "s6_sage": 35, "s7_name": "charlie", "s10_nx": 3, "s13_status": "inactive", "s13_name": "charlie", "s14_status": "inactive", "s14_score": 70}');
SELECT documentdb_api.insert_one('pfedb', 'pfecoll', '{"_id": 4, "s1_age": 40, "s2_score": 60, "s3_status": "active", "s3_val": 40, "s4_status": "active", "s4_val": 25, "s5_tags": ["d"], "s5_name": "dave", "s6_status": "active", "s6_age": 40, "s6_name": "dave", "s6_score": 60, "s6_sval": 60, "s6_sage": 40, "s7_name": "dave", "s10_nx": 4, "s13_status": "active", "s13_name": "dave", "s14_status": "active", "s14_score": 60}');
SELECT documentdb_api.insert_one('pfedb', 'pfecoll', '{"_id": 5, "s1_age": 22, "s2_score": 95, "s3_status": "pending", "s3_val": 22, "s4_status": "pending", "s4_val": 28, "s5_tags": ["a","b","c"], "s5_name": "eve", "s6_status": "pending", "s6_age": 22, "s6_name": "eve", "s6_score": 95, "s6_sval": 95, "s6_sage": 22, "s7_name": "eve", "s10_nx": 5, "s13_status": "pending", "s13_name": "eve", "s14_status": "pending", "s14_score": 95}');
SELECT documentdb_api.insert_one('pfedb', 'pfecoll', '{"_id": 6, "s1_age": 28, "s2_score": 85, "s3_status": "active", "s3_val": 28, "s4_status": "active", "s4_val": 33, "s5_name": "frank", "s6_status": "active", "s6_age": 28, "s6_name": "frank", "s6_score": 85, "s6_sval": 85, "s6_sage": 28, "s7_name": "frank", "s10_nx": 6, "s13_status": "active", "s13_name": "frank", "s14_status": "active", "s14_score": 85}');
SELECT documentdb_api.insert_one('pfedb', 'pfecoll', '{"_id": 7, "s1_age": 50, "s2_score": 55, "s3_val": 50, "s5_name": "grace", "s6_age": 50, "s6_name": "grace", "s6_score": 55, "s6_sval": 55, "s6_sage": 50, "s7_name": "grace", "s13_name": "grace", "s14_score": 55}');
SELECT documentdb_api.insert_one('pfedb', 'pfecoll', '{"_id": 8, "s1_age": 33, "s3_status": "active", "s3_val": 33, "s4_status": "active", "s4_val": 29, "s5_tags": ["b"], "s5_name": "heidi", "s6_status": "active", "s6_age": 33, "s6_name": "heidi", "s6_sval": 45, "s6_sage": 33, "s7_name": "heidi", "s13_status": "active", "s13_name": "heidi"}');
SELECT documentdb_api.insert_one('pfedb', 'pfecoll', '{"_id": 9, "s2_score": 45, "s3_status": "inactive", "s3_val": 45, "s4_status": "inactive", "s4_val": 38, "s5_tags": ["c","d"], "s5_name": "ivan", "s6_status": "inactive", "s6_name": "ivan", "s6_score": 45, "s6_sval": 45, "s7_name": "ivan", "s13_status": "inactive", "s13_name": "ivan", "s14_status": "inactive", "s14_score": 45}');
SELECT documentdb_api.insert_one('pfedb', 'pfecoll', '{"_id": 10, "s1_age": 29, "s2_score": 88, "s3_status": "active", "s3_val": 29, "s4_status": "active", "s4_val": 31, "s5_tags": ["a"], "s5_name": "judy", "s6_status": "active", "s6_age": 29, "s6_name": "judy", "s6_score": 88, "s6_sval": 88, "s6_sage": 29, "s7_name": "judy", "s10_nx": 10, "s13_status": "active", "s13_name": "judy", "s14_status": "active", "s14_score": 88}');

-- =============================================
-- Section 1: PFE with $exists
-- =============================================

-- Index with PFE requiring field exists
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "s1_age": 1 }, "name": "s1_age_exists_pfe", "partialFilterExpression": { "s1_age": { "$exists": true } } }] }', true);

-- Query with $exists: true on the PFE field - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$exists": true } } }');

-- Query with $gt on the indexed field (implicitly satisfies $exists PFE) - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$gt": 25 } } }');

-- Query with $lt on the indexed field - does NOT satisfy $exists PFE alone (range doesn't imply exists)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$lt": 40 } } }');

-- Query with $gte on the indexed field - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$gte": 30 } } }');

-- Query with $eq on the indexed field - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": 33 } }');

-- Query with $in on the indexed field - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$in": [25, 30, 35] } } }');

-- Query on a field with no index - should NOT use the partial index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s7_name": "alice" } }');

-- =============================================
-- Section 2: PFE with $gt / $gte / $lt / $lte
-- =============================================

-- Index with PFE requiring s2_score > 50
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "s2_score": 1 }, "name": "s2_score_gt50_pfe", "partialFilterExpression": { "s2_score": { "$gt": 50 } } }] }', true);

-- Query with matching PFE condition - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s2_score": { "$gt": 50 } } }');

-- Query with stricter condition (gt 80 implies gt 50) - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s2_score": { "$gt": 80 } } }');

-- Query with $gte 51 (implies gt 50) - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s2_score": { "$gte": 51 } } }');

-- Query with weaker condition (gt 30 does NOT imply gt 50) - may not use partial index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s2_score": { "$gt": 30 } } }');

-- Query with $lt (does NOT satisfy PFE gt 50) - should NOT use partial index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s2_score": { "$lt": 40 } } }');

-- Query with $eq on value satisfying PFE - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s2_score": 85 } }');

-- Query with $eq on value NOT satisfying PFE - may not use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s2_score": 30 } }');

-- Index with PFE requiring s2_score >= 70 (descending key)
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "s2_score": -1 }, "name": "s2_score_gte70_pfe", "partialFilterExpression": { "s2_score": { "$gte": 70 } } }] }', true);

-- Query matching the $gte PFE - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s2_score": { "$gte": 70 } } }');

-- Query with $gte 80 (stricter, implies gte 70) - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s2_score": { "$gte": 80 } } }');

-- Index with PFE requiring s2_lt_age < 40 on a cross-field key
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "s2_lt_name": 1 }, "name": "s2_lt_name_pfe", "partialFilterExpression": { "s1_age": { "$lt": 40 } } }] }', true);

-- Query matching PFE condition - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$lt": 40 }, "s2_lt_name": "alice" } }');

-- Query with stricter lt condition (lt 30 implies lt 40) - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$lt": 30 }, "s2_lt_name": "alice" } }');

-- Query without PFE condition - should NOT use the partial index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s2_lt_name": "alice" } }');

-- Index with PFE requiring s1_age <= 35 on a cross-field key
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "s2_lte_name": -1 }, "name": "s2_lte_name_pfe", "partialFilterExpression": { "s1_age": { "$lte": 35 } } }] }', true);

-- Query matching PFE condition - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$lte": 35 }, "s2_lte_name": "bob" } }');

-- =============================================
-- Section 3: PFE with $eq
-- =============================================

-- Index with PFE requiring s3_status == "active"
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "s3_val": 1 }, "name": "s3_val_status_active_pfe", "partialFilterExpression": { "s3_status": "active" } }] }', true);

-- Query with exact match on PFE field - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s3_status": "active", "s3_val": { "$gt": 25 } } }');

-- Query with $eq syntax on PFE field - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s3_status": { "$eq": "active" }, "s3_val": { "$gt": 25 } } }');

-- Query without PFE field - should NOT use this partial index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s3_val": { "$gt": 25 } } }');

-- Query with different value for PFE field - should NOT use this partial index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s3_status": "inactive", "s3_val": { "$gt": 25 } } }');

-- =============================================
-- Section 4: PFE with $in
-- =============================================

-- Index with PFE using $in
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "s4_val": 1 }, "name": "s4_val_status_in_pfe", "partialFilterExpression": { "s4_status": { "$in": ["active", "pending"] } } }] }', true);

-- Query with exact match on one of the $in values - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s4_status": "active", "s4_val": { "$gt": 20 } } }');

-- Query with the other $in value - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s4_status": "pending", "s4_val": { "$lt": 30 } } }');

-- Query with $in that is a subset of PFE's $in - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s4_status": { "$in": ["active"] }, "s4_val": { "$gt": 20 } } }');

-- Query with $in that matches PFE's $in exactly - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s4_status": { "$in": ["active", "pending"] }, "s4_val": { "$gt": 20 } } }');

-- Query with $in that is a superset of PFE's $in - should NOT use the partial index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s4_status": { "$in": ["active", "pending", "inactive"] }, "s4_val": { "$gt": 20 } } }');

-- Query with value not in PFE's $in - should NOT use the partial index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s4_status": "inactive", "s4_val": { "$gt": 20 } } }');

-- Query without PFE field - should NOT use the partial index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s4_val": { "$gt": 20 } } }');

-- =============================================
-- Section 5: PFE with $exists on a different field than the index key
-- =============================================

-- Index on "s5_name" with PFE requiring "s5_tags" exists
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "s5_name": 1 }, "name": "s5_name_tags_exists_pfe", "partialFilterExpression": { "s5_tags": { "$exists": true } } }] }', true);

-- Query with $exists: true on PFE field + filter on indexed field - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s5_tags": { "$exists": true }, "s5_name": "alice" } }');

-- Query with filter on indexed field but no $exists on PFE field - should NOT use partial index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s5_name": "alice" } }');

-- Query with $exists: true on PFE field only (no filter on indexed key) - behavior depends on planner
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s5_tags": { "$exists": true } } }');

-- =============================================
-- Section 6: PFE with combined conditions (AND)
-- =============================================

-- Index with PFE combining multiple conditions
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "s6_name": 1 }, "name": "s6_name_combined_pfe", "partialFilterExpression": { "s6_status": "active", "s6_age": { "$gte": 25 } } }] }', true);

-- Query satisfying all PFE conditions - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s6_status": "active", "s6_age": { "$gte": 25 }, "s6_name": "bob" } }');

-- Query satisfying all PFE conditions with stricter age - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s6_status": "active", "s6_age": { "$gte": 30 }, "s6_name": "bob" } }');

-- Query missing one PFE condition (no status) - should NOT use partial index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s6_age": { "$gte": 25 }, "s6_name": "bob" } }');

-- Query missing one PFE condition (no age) - should NOT use partial index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s6_status": "active", "s6_name": "bob" } }');

-- Query with wrong value for PFE condition - should NOT use partial index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s6_status": "inactive", "s6_age": { "$gte": 25 }, "s6_name": "bob" } }');

-- Combined PFE with $exists and comparison
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "s6_sval": 1 }, "name": "s6_sval_exists_and_gt_pfe", "partialFilterExpression": { "s6_sval": { "$exists": true }, "s6_sage": { "$gt": 20 } } }] }', true);

-- Query satisfying both PFE conditions - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s6_sval": { "$exists": true }, "s6_sage": { "$gt": 20 }, "s6_sval": { "$gte": 70 } } }');

-- Query missing $exists PFE condition - should NOT use partial index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s6_sage": { "$gt": 20 }, "s6_sval": { "$gte": 70 } } }');

-- =============================================
-- Section 7: PFE with $type
-- =============================================

-- Index with PFE requiring field to be a specific type
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "s7_name": 1 }, "name": "s7_name_type_string_pfe", "partialFilterExpression": { "s7_name": { "$type": "string" } } }] }', true);

-- Query with $type matching PFE - $type PFE is not currently supported for pushdown
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s7_name": { "$type": "string" } } }');

-- Query with $eq (string value implies type string) - $type PFE not supported
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s7_name": "alice" } }');

-- Query with $regex (implies string type) - $type PFE not supported
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s7_name": { "$regex": "^a" } } }');

-- =============================================
-- Section 8: Query operators on indexed field with various PFEs
-- Uses s1_age_exists_pfe (PFE: s1_age exists) from Section 1
-- =============================================

-- $eq
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$exists": true, "$eq": 30 } } }');

-- $ne (should still use the index with recheck)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$exists": true, "$ne": 30 } } }');

-- $gt
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$exists": true, "$gt": 30 } } }');

-- $gte
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$exists": true, "$gte": 30 } } }');

-- $lt
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$exists": true, "$lt": 30 } } }');

-- $lte
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$exists": true, "$lte": 30 } } }');

-- $in
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$exists": true, "$in": [25, 30, 40] } } }');

-- $nin (should still scan index with recheck)
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$exists": true, "$nin": [25, 30] } } }');

-- $regex on a different field with PFE satisfied
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$exists": true }, "s7_name": { "$regex": "^a" } } }');

-- =============================================
-- Section 9: $or queries with existing PFEs
-- Uses s3_val_status_active_pfe and s1_age_exists_pfe
-- =============================================

-- $or query where both branches satisfy PFE
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "$or": [ { "s3_status": "active", "s3_val": { "$gt": 30 } }, { "s3_status": "active", "s3_val": { "$lt": 25 } } ] } }');

-- $or query where one branch satisfies PFE and other does not
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "$or": [ { "s3_status": "active", "s3_val": { "$gt": 30 } }, { "s3_status": "inactive", "s3_val": { "$gt": 30 } } ] } }');

-- $or query on the indexed field with $exists PFE
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$exists": true }, "$or": [ { "s1_age": { "$gt": 35 } }, { "s1_age": { "$lt": 25 } } ] } }');

-- $or query without satisfying PFE
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "$or": [ { "s1_age": { "$gt": 35 } }, { "s7_name": "alice" } ] } }');

-- =============================================
-- Section 10: PFE with nested field paths
-- =============================================

-- Index with PFE on nested field
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "s10_nx": 1 }, "name": "s10_nx_gt0_pfe", "partialFilterExpression": { "s10_nx": { "$gt": 0 } } }] }', true);

-- Query matching nested PFE - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s10_nx": { "$gt": 0 } } }');

-- Query with stricter condition on nested field - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s10_nx": { "$gt": 3 } } }');

-- Query with $eq on nested field - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s10_nx": 5 } }');

-- Index with PFE requiring nested field exists
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "s10_nx": -1 }, "name": "s10_nx_exists_pfe", "partialFilterExpression": { "s10_nx": { "$exists": true } } }] }', true);

-- Query with $exists on nested PFE field - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s10_nx": { "$exists": true } } }');

-- Query with $eq on nested field (implies exists) - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s10_nx": 2 } }');

-- =============================================
-- Section 11: Result correctness verification
-- =============================================

-- Verify results are correct when using partial index with $exists PFE
SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s1_age": { "$exists": true, "$gt": 30 } }, "sort": { "_id": 1 } }');

-- Verify results with $in PFE
SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s4_status": { "$in": ["active", "pending"] }, "s4_val": { "$gt": 25 } }, "sort": { "_id": 1 } }');

-- Verify results with combined PFE
SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s6_status": "active", "s6_age": { "$gte": 25 }, "s6_name": { "$regex": "^b" } }, "sort": { "_id": 1 } }');

-- Verify results with nested field PFE
SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s10_nx": { "$gt": 3 } }, "sort": { "_id": 1 } }');

-- =============================================
-- Section 12: PFE with $exists: false (not supported - should error)
-- =============================================

-- Index with PFE requiring field does NOT exist - should error
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "s12_name": 1 }, "name": "s12_name_no_tags_pfe", "partialFilterExpression": { "s5_tags": { "$exists": false } } }] }', true);

-- =============================================
-- Section 13: PFE interaction with $regex queries
-- =============================================

-- Index with PFE on s13_status, query uses $regex on indexed field
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "s13_name": 1 }, "name": "s13_name_status_active_pfe", "partialFilterExpression": { "s13_status": "active" } }] }', true);

-- $regex query with PFE satisfied - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s13_status": "active", "s13_name": { "$regex": "^a" } } }');

-- $regex with case insensitive - PFE satisfied - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s13_status": "active", "s13_name": { "$regex": "^A", "$options": "i" } } }');

-- $regex query without PFE satisfied - should NOT use this partial index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s13_name": { "$regex": "^a" } } }');

-- Verify correctness
SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s13_status": "active", "s13_name": { "$regex": "^a" } }, "sort": { "_id": 1 } }');

-- =============================================
-- Section 14: $or in Partial Filter Expression
-- =============================================

-- Create an index with $or in the PFE
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "s14_score": 1 }, "name": "s14_score_or_pfe", "partialFilterExpression": { "$or": [{ "s14_status": "active" }, { "s14_priority": { "$gte": 5 } }] } }] }', true);

-- Query matching one branch of the $or PFE - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s14_status": "active", "s14_score": { "$gt": 50 } } }');

-- Query matching the other branch of the $or PFE - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s14_priority": { "$gte": 5 }, "s14_score": { "$gt": 50 } } }');

-- Query matching both branches of the $or PFE - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "$or": [{ "s14_status": "active" }, { "s14_priority": { "$gte": 5 } }], "s14_score": { "$gt": 50 } } }');

-- Query NOT matching any branch of the $or PFE - should NOT use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s14_status": "pending", "s14_score": { "$gt": 50 } } }');

-- Query with superset $gte on priority (weaker condition) - should NOT use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "s14_priority": { "$gte": 3 }, "s14_score": { "$gt": 50 } } }');

-- =============================================
-- Section 15: $regex should imply $exists: true for PFE pushdown
-- =============================================

-- Create an index with PFE on $exists: true on a distinct field
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "title": 1 }, "name": "title_exists_pfe", "partialFilterExpression": { "title": { "$exists": true } } }] }', true);

-- Query with $regex on the same field - $regex implies the field exists, so should satisfy the PFE
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "title": { "$regex": "^test" } } }');

-- Query with $regex and explicit $exists on the same field - should use the index
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "title": { "$regex": "^test" }, "title": { "$exists": true } } }');

-- =============================================
-- Section 16: $regex should NOT satisfy string-only PFE ($gt: "")
-- $regex needs to scan both string and regex typed values,
-- so a PFE that only covers strings should not be satisfied.
-- =============================================

-- Create an index with PFE restricting to string type only on a distinct field
SELECT documentdb_api_internal.create_indexes_non_concurrently('pfedb', '{ "createIndexes": "pfecoll", "indexes": [{ "key": { "label": 1 }, "name": "label_string_pfe", "partialFilterExpression": { "label": { "$gt": "" } } }] }', true);

-- $regex query should NOT use this index - PFE only covers strings, but $regex also matches regex-typed values
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "label": { "$regex": "^test" } } }');

-- $eq string query SHOULD use this index - string values satisfy $gt: "" PFE
EXPLAIN (COSTS OFF) SELECT document FROM bson_aggregation_find('pfedb', '{ "find": "pfecoll", "filter": { "label": "test" } }');

-- =============================================
-- Cleanup
-- =============================================
SELECT documentdb_api.drop_collection('pfedb', 'pfecoll');
