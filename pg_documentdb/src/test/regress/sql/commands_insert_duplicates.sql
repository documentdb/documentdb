SET search_path TO documentdb_core, documentdb_api, documentdb_api_catalog, documentdb_api_internal;
SET documentdb.next_collection_id TO 25830000;
SET documentdb.next_collection_index_id TO 25830000;
SET documentdb.enable_write_error_code_conversion TO on;

-- ============================================================
-- Tests for bulk insert behavior with duplicate _id values.
-- Validates correctness (n, writeErrors count) across:
--   - Different duplicate ratios (0%, 10%, 50%, 100%)
--   - ordered:true vs ordered:false
--   - Multiple batch sizes (1, 10, 100)
-- ============================================================

-- Wrapper: runs insert and returns n (count inserted), write_errors, and success flag
CREATE OR REPLACE FUNCTION pg_temp.do_insert(db text, cmd documentdb_core.bson)
RETURNS TABLE(n int, write_errors int, success bool) AS $$
    SELECT
        (regexp_match((p_result -> 'n')::text, '"(\d+)"'))[1]::int,
        (length(p_result::text) - length(replace(p_result::text, '"index"', ''))) /
            length('"index"'),
        p_success
    FROM documentdb_api.insert(db, cmd)
$$ LANGUAGE SQL;


-- ============================================================
-- Part 1: Baseline — ordered:false, GUC ON (default)
-- ============================================================
\echo '--- Part 1: GUC ON, ordered:false ---'

SELECT documentdb_api.create_collection('insertdupdb', 'dup_test');

-- 1a: Insert 10 unique documents
SELECT * FROM pg_temp.do_insert('insertdupdb',
    '{"insert": "dup_test", "ordered": false, "documents": [
        {"_id": 1}, {"_id": 2}, {"_id": 3}, {"_id": 4}, {"_id": 5},
        {"_id": 6}, {"_id": 7}, {"_id": 8}, {"_id": 9}, {"_id": 10}
    ]}');

-- 1b: Insert 10 docs — 100% duplicates (all collide with ids 1-10)
SELECT * FROM pg_temp.do_insert('insertdupdb',
    '{"insert": "dup_test", "ordered": false, "documents": [
        {"_id": 1}, {"_id": 2}, {"_id": 3}, {"_id": 4}, {"_id": 5},
        {"_id": 6}, {"_id": 7}, {"_id": 8}, {"_id": 9}, {"_id": 10}
    ]}');

-- 1c: Insert 10 docs — 50% duplicates (ids 1-5 collide, 11-15 are new)
SELECT * FROM pg_temp.do_insert('insertdupdb',
    '{"insert": "dup_test", "ordered": false, "documents": [
        {"_id": 1}, {"_id": 2}, {"_id": 3}, {"_id": 4}, {"_id": 5},
        {"_id": 11}, {"_id": 12}, {"_id": 13}, {"_id": 14}, {"_id": 15}
    ]}');

-- 1d: Insert 10 docs — 10% duplicate (id 1 collides, ids 16-24 are new)
SELECT * FROM pg_temp.do_insert('insertdupdb',
    '{"insert": "dup_test", "ordered": false, "documents": [
        {"_id": 1},
        {"_id": 16}, {"_id": 17}, {"_id": 18}, {"_id": 19}, {"_id": 20},
        {"_id": 21}, {"_id": 22}, {"_id": 23}, {"_id": 24}
    ]}');

-- Verify total document count: 10 + 0 + 5 + 9 = 24
SELECT COUNT(*) AS total_docs FROM documentdb_api.collection('insertdupdb', 'dup_test');

SELECT documentdb_api.drop_collection('insertdupdb', 'dup_test');

-- ============================================================
-- Part 2: ordered:true — duplicates stop further inserts
-- ============================================================
\echo '--- Part 3: ordered:true, duplicate stops batch ---'


SELECT documentdb_api.create_collection('insertdupdb', 'dup_test');

-- Populate ids 1-5
SELECT * FROM pg_temp.do_insert('insertdupdb',
    '{"insert": "dup_test", "ordered": true, "documents": [
        {"_id": 1}, {"_id": 2}, {"_id": 3}, {"_id": 4}, {"_id": 5}
    ]}');

-- 3a: ordered:true with dup at position 3 — should insert 2, fail on 3rd, skip rest
SELECT * FROM pg_temp.do_insert('insertdupdb',
    '{"insert": "dup_test", "ordered": true, "documents": [
        {"_id": 6}, {"_id": 7},
        {"_id": 1},
        {"_id": 8}, {"_id": 9}
    ]}');

-- Verify: 5 original + 2 new (6,7) = 7
SELECT COUNT(*) AS total_docs FROM documentdb_api.collection('insertdupdb', 'dup_test');

SELECT documentdb_api.drop_collection('insertdupdb', 'dup_test');

-- ============================================================
-- Part 3: Larger batches — 100 docs with various dup ratios
-- ============================================================
\echo '--- Part 3: 100-doc batches ---'
SELECT documentdb_api.create_collection('insertdupdb', 'dup_test');

-- Populate 100 unique docs (ids 1-100)
SELECT * FROM pg_temp.do_insert('insertdupdb',
    documentdb_core.bson_build_document(
        'insert', 'dup_test'::text,
        'ordered', false,
        'documents', (SELECT array_agg(documentdb_core.bson_build_document('_id', i))
                      FROM generate_series(1, 100) i)
    ));

-- 100 docs, 0% dups (ids 101-200)
SELECT * FROM pg_temp.do_insert('insertdupdb',
    documentdb_core.bson_build_document(
        'insert', 'dup_test'::text,
        'ordered', false,
        'documents', (SELECT array_agg(documentdb_core.bson_build_document('_id', i))
                      FROM generate_series(101, 200) i)
    ));

-- 100 docs, 10% dups (10 collide with ids 1-10, 90 new ids 201-290)
SELECT * FROM pg_temp.do_insert('insertdupdb',
    documentdb_core.bson_build_document(
        'insert', 'dup_test'::text,
        'ordered', false,
        'documents', (SELECT array_agg(documentdb_core.bson_build_document('_id', i))
                      FROM (SELECT i FROM generate_series(1, 10) i
                            UNION ALL
                            SELECT i FROM generate_series(201, 290) i) sub)
    ));

-- 100 docs, 50% dups (50 collide with ids 1-50, 50 new ids 291-340)
SELECT * FROM pg_temp.do_insert('insertdupdb',
    documentdb_core.bson_build_document(
        'insert', 'dup_test'::text,
        'ordered', false,
        'documents', (SELECT array_agg(documentdb_core.bson_build_document('_id', i))
                      FROM (SELECT i FROM generate_series(1, 50) i
                            UNION ALL
                            SELECT i FROM generate_series(291, 340) i) sub)
    ));

-- 100 docs, 100% dups (all collide with ids 1-100)
SELECT * FROM pg_temp.do_insert('insertdupdb',
    documentdb_core.bson_build_document(
        'insert', 'dup_test'::text,
        'ordered', false,
        'documents', (SELECT array_agg(documentdb_core.bson_build_document('_id', i))
                      FROM generate_series(1, 100) i)
    ));

-- Verify total: 100 + 100 + 90 + 50 + 0 = 340
SELECT COUNT(*) AS total_docs FROM documentdb_api.collection('insertdupdb', 'dup_test');

SELECT documentdb_api.drop_collection('insertdupdb', 'dup_test');



-- ============================================================
-- Part 5: Single-doc batch with duplicate
-- ============================================================
\echo '--- Part 5: Single-doc batches ---'
SELECT documentdb_api.create_collection('insertdupdb', 'dup_test');

-- Insert a doc
SELECT * FROM pg_temp.do_insert('insertdupdb',
    '{"insert": "dup_test", "ordered": false, "documents": [{"_id": 1}]}');

-- Insert same _id again (single-doc batch, GUC ON)
SELECT * FROM pg_temp.do_insert('insertdupdb',
    '{"insert": "dup_test", "ordered": false, "documents": [{"_id": 1}]}');




-- ============================================================
-- Part 6: Repeated duplicates on the same secondary index
-- ============================================================
\echo '--- Part 6: Secondary-index duplicate errors ---'

SELECT documentdb_api.create_collection('insertdupdb', 'secondary_dup_test');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'insertdupdb',
    '{"createIndexes": "secondary_dup_test", "indexes": [
        {"key": {"a": 1}, "name": "a_1", "unique": true},
        {"key": {"b": 1}, "name": "b_1", "unique": true}
    ]}',
    true);

SELECT * FROM pg_temp.do_insert('insertdupdb',
    '{"insert": "secondary_dup_test", "ordered": false, "documents": [
        {"_id": 1, "a": 1, "b": 1}
    ]}');

-- a_1 insert to cache get DEBUG log
-- a_1 reuse cache
-- b_1 insert to cache get DEBUG log
-- b_1 reuse cache
-- a_1 reuse cache
SET client_min_messages TO DEBUG1;
SELECT p_result -> 'writeErrors' AS write_errors
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "secondary_dup_test", "ordered": false, "documents": [
        {"_id": 2, "a": 1, "b": 2},
        {"_id": 3, "a": 1, "b": 3},
        {"_id": 4, "a": 4, "b": 1},
        {"_id": 5, "a": 5, "b": 1},
        {"_id": 6, "a": 1, "b": 6}
    ]}');
RESET client_min_messages;

-- With caching disabled, each duplicate performs the original direct lookup.
SET documentdb.enable_request_index_name_cache TO OFF;
SET client_min_messages TO DEBUG1;
SELECT p_result -> 'writeErrors' AS write_errors
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "secondary_dup_test", "ordered": false, "documents": [
        {"_id": 5, "a": 1, "b": 5},
        {"_id": 6, "a": 1, "b": 6},
        {"_id": 7, "a": 7, "b": 1}
    ]}');
RESET client_min_messages;
RESET documentdb.enable_request_index_name_cache;

SELECT p_result -> 'writeErrors.0.code' AS error_code, p_success
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "secondary_dup_test", "ordered": false, "documents": [
        {"_id": 8, "a": 1, "b": 8}
    ]}');

SET documentdb.enable_write_error_code_conversion TO off;
SELECT p_result -> 'writeErrors.0.code' AS error_code, p_success
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "secondary_dup_test", "ordered": false, "documents": [
        {"_id": 8, "a": 1, "b": 8}
    ]}');
SET documentdb.enable_write_error_code_conversion TO on;

-- A mixed response must keep every original code for downstream translation.
SELECT p_result -> 'writeErrors' AS write_errors, p_success
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "secondary_dup_test", "ordered": false, "documents": [
        {"_id": 9, "a": 1, "b": 9},
        {"_id": {"$regex": "^invalid"}}
    ]}');

SELECT documentdb_api.drop_collection('insertdupdb', 'secondary_dup_test');

CREATE FUNCTION documentdb_api_internal.test_try_get_wire_error_code(text)
RETURNS int LANGUAGE C STRICT AS 'pg_documentdb', $$test_try_get_wire_error_code$$;

SELECT sqlstate,
       documentdb_api_internal.test_try_get_wire_error_code(sqlstate) AS wire_error_code
FROM (VALUES
    ('M001C'),
    ('M00E8'),
    ('23505'),
    ('23P01'),
    ('M0001')
) AS error_codes(sqlstate);

DROP FUNCTION documentdb_api_internal.test_try_get_wire_error_code(text);


-- ============================================================
-- Part 8: Isolated ON CONFLICT sub-batch scenarios
-- ============================================================
\echo '--- Part 8: isolated ON CONFLICT scenarios ---'

SET documentdb.enable_insert_on_conflict_optimization = ON;
SET documentdb.batchWriteSubTransactionCount = 3;

-- 8.1: Only _id conflicts. Both sub-batches conflict at index 0.
SELECT documentdb_api.create_collection('insertdupdb', 'id_only');
SELECT documentdb_api.insert_one('insertdupdb', 'id_only', '{"_id": 0}');
SELECT documentdb_api_catalog.bson_dollar_project(
    p_result,
    '{"n": 1, "writeErrors.index": 1, "writeErrors.errmsg": 1}'::documentdb_core.bson)
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "id_only", "ordered": false, "documents": [
        {"_id": 0}, {"_id": 1}, {"_id": 2},
        {"_id": 0}, {"_id": 3}, {"_id": 4}
    ]}');
SELECT COUNT(*) AS total_docs
FROM documentdb_api.collection('insertdupdb', 'id_only');
SELECT documentdb_api.drop_collection('insertdupdb', 'id_only');

-- 8.2: Only one secondary unique index conflicts.
SELECT documentdb_api.create_collection('insertdupdb', 'unique_only');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'insertdupdb',
    '{"createIndexes": "unique_only", "indexes": [
        {"key": {"a": 1}, "name": "a_1", "unique": true}
    ]}',
    true);
SELECT documentdb_api.insert_one(
    'insertdupdb', 'unique_only', '{"_id": 0, "a": 0}');
SELECT documentdb_api_catalog.bson_dollar_project(
    p_result,
    '{"n": 1, "writeErrors.index": 1, "writeErrors.errmsg": 1}'::documentdb_core.bson)
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "unique_only", "ordered": false, "documents": [
        {"_id": 1, "a": 0}, {"_id": 2, "a": 2}, {"_id": 3, "a": 3},
        {"_id": 4, "a": 0}, {"_id": 5, "a": 5}, {"_id": 6, "a": 6}
    ]}');
SELECT COUNT(*) AS total_docs
FROM documentdb_api.collection('insertdupdb', 'unique_only');
SELECT documentdb_api.drop_collection('insertdupdb', 'unique_only');

-- 8.3: _id and secondary unique conflicts occur in the same command.
SELECT documentdb_api.create_collection('insertdupdb', 'id_and_unique');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'insertdupdb',
    '{"createIndexes": "id_and_unique", "indexes": [
        {"key": {"a": 1}, "name": "a_1", "unique": true}
    ]}',
    true);
SELECT documentdb_api.insert_one(
    'insertdupdb', 'id_and_unique', '{"_id": 0, "a": 0}');
SELECT documentdb_api_catalog.bson_dollar_project(
    p_result,
    '{"n": 1, "writeErrors.index": 1, "writeErrors.errmsg": 1}'::documentdb_core.bson)
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "id_and_unique", "ordered": false, "documents": [
        {"_id": 0, "a": 1}, {"_id": 1, "a": 1}, {"_id": 2, "a": 2},
        {"_id": 3, "a": 0}, {"_id": 0, "a": 4}, {"_id": 4, "a": 4}
    ]}');
SELECT COUNT(*) AS total_docs
FROM documentdb_api.collection('insertdupdb', 'id_and_unique');
SELECT documentdb_api.drop_collection('insertdupdb', 'id_and_unique');

-- 8.4: Two different secondary unique indexes conflict.
SELECT documentdb_api.create_collection('insertdupdb', 'two_unique');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'insertdupdb',
    '{"createIndexes": "two_unique", "indexes": [
        {"key": {"a": 1}, "name": "a_1", "unique": true},
        {"key": {"b": 1}, "name": "b_1", "unique": true}
    ]}',
    true);
SELECT documentdb_api.insert_one(
    'insertdupdb', 'two_unique', '{"_id": 0, "a": 0, "b": 0}');
SELECT documentdb_api_catalog.bson_dollar_project(
    p_result,
    '{"n": 1, "writeErrors.index": 1, "writeErrors.errmsg": 1}'::documentdb_core.bson)
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "two_unique", "ordered": false, "documents": [
        {"_id": 1, "a": 0, "b": 1}, {"_id": 2, "a": 2, "b": 2}, {"_id": 3, "a": 3, "b": 3},
        {"_id": 4, "a": 4, "b": 0}, {"_id": 5, "a": 0, "b": 5}, {"_id": 6, "a": 6, "b": 6}
    ]}');
SELECT COUNT(*) AS total_docs
FROM documentdb_api.collection('insertdupdb', 'two_unique');
SELECT documentdb_api.drop_collection('insertdupdb', 'two_unique');

-- 8.5: A trailing conflict is classified when each sub-batch is exhausted.
SELECT documentdb_api.create_collection('insertdupdb', 'trailing_conflict');
SELECT documentdb_api.insert_one(
    'insertdupdb', 'trailing_conflict', '{"_id": 0}');
SELECT documentdb_api_catalog.bson_dollar_project(
    p_result,
    '{"n": 1, "writeErrors.index": 1}'::documentdb_core.bson)
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "trailing_conflict", "ordered": false, "documents": [
        {"_id": 1}, {"_id": 2}, {"_id": 0},
        {"_id": 3}, {"_id": 4}, {"_id": 0}
    ]}');
SELECT COUNT(*) AS total_docs
FROM documentdb_api.collection('insertdupdb', 'trailing_conflict');
SELECT documentdb_api.drop_collection('insertdupdb', 'trailing_conflict');

-- 8.6: A leading conflict is classified before the next input.
SELECT documentdb_api.create_collection('insertdupdb', 'leading_conflict');
SELECT documentdb_api.insert_one(
    'insertdupdb', 'leading_conflict', '{"_id": 0}');
SELECT documentdb_api_catalog.bson_dollar_project(
    p_result,
    '{"n": 1, "writeErrors.index": 1}'::documentdb_core.bson)
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "leading_conflict", "ordered": false, "documents": [
        {"_id": 0}, {"_id": 1}, {"_id": 2},
        {"_id": 0}, {"_id": 3}, {"_id": 4}
    ]}');
SELECT COUNT(*) AS total_docs
FROM documentdb_api.collection('insertdupdb', 'leading_conflict');
SELECT documentdb_api.drop_collection('insertdupdb', 'leading_conflict');

-- 8.7: The first sub-batch conflicts and the optimized second one does not.
SELECT documentdb_api.create_collection('insertdupdb', 'first_conflict_only');
SELECT documentdb_api.insert_one(
    'insertdupdb', 'first_conflict_only', '{"_id": 0}');
SELECT documentdb_api_catalog.bson_dollar_project(
    p_result,
    '{"n": 1, "writeErrors.index": 1}'::documentdb_core.bson)
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "first_conflict_only", "ordered": false, "documents": [
        {"_id": 0}, {"_id": 1}, {"_id": 2},
        {"_id": 3}, {"_id": 4}, {"_id": 5}
    ]}');
SELECT COUNT(*) AS total_docs
FROM documentdb_api.collection('insertdupdb', 'first_conflict_only');
SELECT documentdb_api.drop_collection('insertdupdb', 'first_conflict_only');

-- 8.8: Both sub-batches contain multiple conflicts.
SELECT documentdb_api.create_collection('insertdupdb', 'both_conflict');
SELECT documentdb_api.insert_one(
    'insertdupdb', 'both_conflict', '{"_id": 0}');
SELECT documentdb_api_catalog.bson_dollar_project(
    p_result,
    '{"n": 1, "writeErrors.index": 1}'::documentdb_core.bson)
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "both_conflict", "ordered": false, "documents": [
        {"_id": 0}, {"_id": 1}, {"_id": 0},
        {"_id": 0}, {"_id": 2}, {"_id": 0}
    ]}');
SELECT COUNT(*) AS total_docs
FROM documentdb_api.collection('insertdupdb', 'both_conflict');
SELECT documentdb_api.drop_collection('insertdupdb', 'both_conflict');

-- 8.9: The optimized second sub-batch has a middle conflict.
SELECT documentdb_api.create_collection('insertdupdb', 'middle_conflict');
SELECT documentdb_api.insert_one(
    'insertdupdb', 'middle_conflict', '{"_id": 0}');
SELECT documentdb_api_catalog.bson_dollar_project(
    p_result,
    '{"n": 1, "writeErrors.index": 1}'::documentdb_core.bson)
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "middle_conflict", "ordered": false, "documents": [
        {"_id": 0}, {"_id": 1}, {"_id": 2},
        {"_id": 3}, {"_id": 0}, {"_id": 4}
    ]}');
SELECT COUNT(*) AS total_docs
FROM documentdb_api.collection('insertdupdb', 'middle_conflict');
SELECT documentdb_api.drop_collection('insertdupdb', 'middle_conflict');

-- 8.10: A successful optimized sub-batch can contain only conflicts.
SELECT documentdb_api.create_collection('insertdupdb', 'later_all_conflict');
SELECT documentdb_api.insert_one(
    'insertdupdb', 'later_all_conflict', '{"_id": 0}');
SELECT documentdb_api_catalog.bson_dollar_project(
    p_result,
    '{"n": 1, "writeErrors.index": 1}'::documentdb_core.bson)
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "later_all_conflict", "ordered": false, "documents": [
        {"_id": 0}, {"_id": 1}, {"_id": 2},
        {"_id": 0}, {"_id": 0}, {"_id": 0}
    ]}');
SELECT COUNT(*) AS total_docs
FROM documentdb_api.collection('insertdupdb', 'later_all_conflict');
SELECT documentdb_api.drop_collection('insertdupdb', 'later_all_conflict');

-- Ordered retries must stop on a suppressed duplicate, not treat it as success.
SELECT documentdb_api.create_collection('insertdupdb', 'ordered_conflict');
SELECT documentdb_api.insert_one(
    'insertdupdb', 'ordered_conflict', '{"_id": 0}');

-- A leading duplicate must prevent every later insert.
SELECT p_result, p_success
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "ordered_conflict", "ordered": true, "documents": [
        {"_id": 0}, {"_id": 1}, {"_id": 2}
    ]}');
SELECT object_id FROM documentdb_api.collection('insertdupdb', 'ordered_conflict')
ORDER BY object_id;

-- Keep the successful prefix, but skip the rest of this and later sub-batches.
SELECT p_result, p_success
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "ordered_conflict", "ordered": true, "documents": [
        {"_id": 1}, {"_id": 0}, {"_id": 2},
        {"_id": 3}, {"_id": 0}, {"_id": 4}
    ]}');
SELECT object_id FROM documentdb_api.collection('insertdupdb', 'ordered_conflict')
ORDER BY object_id;

-- A duplicate in a later sub-batch must preserve earlier successful work.
SELECT p_result, p_success
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "ordered_conflict", "ordered": true, "documents": [
        {"_id": 2}, {"_id": 3}, {"_id": 4},
        {"_id": 5}, {"_id": 0}, {"_id": 6}
    ]}');
SELECT object_id FROM documentdb_api.collection('insertdupdb', 'ordered_conflict')
ORDER BY object_id;
SELECT documentdb_api.drop_collection('insertdupdb', 'ordered_conflict');

-- Secondary duplicates must stop ordered retries too.
SELECT documentdb_api.create_collection('insertdupdb', 'ordered_unique_conflict');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'insertdupdb',
    '{"createIndexes": "ordered_unique_conflict", "indexes": [
        {"key": {"a": 1}, "name": "a_1", "unique": true}
    ]}',
    true);
SELECT documentdb_api.insert_one(
    'insertdupdb', 'ordered_unique_conflict', '{"_id": 0, "a": "Alpha"}');
SELECT p_result, p_success
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "ordered_unique_conflict", "ordered": true, "documents": [
        {"_id": 1, "a": "Beta"}, {"_id": 2, "a": "Alpha"}, {"_id": 3, "a": "Gamma"},
        {"_id": 4, "a": "Delta"}
    ]}');
SELECT document
FROM documentdb_api.collection('insertdupdb', 'ordered_unique_conflict')
ORDER BY object_id;
SELECT documentdb_api.drop_collection('insertdupdb', 'ordered_unique_conflict');

-- Retried prefix documents still use the collection's validator collation.
SET documentdb_core.enableCollation = ON;
SELECT documentdb_api.create_collection_view(
    'insertdupdb',
    '{"create": "ordered_validated_conflict", "validator": {"state": "ready"},
      "validationAction": "error"}');
UPDATE documentdb_api_catalog.collections
SET options = '{"collation": {"locale": "en", "strength": 2}}'::documentdb_core.bson
WHERE database_name = 'insertdupdb' AND collection_name = 'ordered_validated_conflict';
SELECT documentdb_api_internal.invalidate_collection_cache();
SELECT documentdb_api.insert_one(
    'insertdupdb', 'ordered_validated_conflict', '{"_id": 0, "state": "ready"}');
SELECT p_result, p_success
FROM documentdb_api.insert(
    'insertdupdb',
    '{"insert": "ordered_validated_conflict", "ordered": true, "documents": [
        {"_id": 1, "state": "READY"}, {"_id": 0, "state": "ready"},
        {"_id": 2, "state": "ready"}, {"_id": 3, "state": "ready"}
    ]}');
SELECT document
FROM documentdb_api.collection('insertdupdb', 'ordered_validated_conflict')
ORDER BY object_id;
SELECT documentdb_api.drop_collection('insertdupdb', 'ordered_validated_conflict');
RESET documentdb_core.enableCollation;

RESET documentdb.batchWriteSubTransactionCount;
RESET documentdb.enable_insert_on_conflict_optimization;



-- ============================================================
-- Cleanup
-- ============================================================
SELECT documentdb_api.drop_database('insertdupdb');
RESET documentdb.enable_write_error_code_conversion;
