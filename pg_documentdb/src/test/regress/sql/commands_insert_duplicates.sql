SET search_path TO documentdb_core, documentdb_api, documentdb_api_catalog, documentdb_api_internal;
SET documentdb.next_collection_id TO 25830000;
SET documentdb.next_collection_index_id TO 25830000;

-- ============================================================
-- Tests for bulk insert behavior with duplicate _id values.
-- Validates correctness (n, writeErrors count) across:
--   - Different duplicate ratios (0%, 10%, 50%, 100%)
--   - GUC enableInsertDuplicateInlineHandling ON vs OFF
--   - ordered:true vs ordered:false
--   - Multiple batch sizes (1, 10, 100)
-- ============================================================

-- Wrapper: runs insert and returns n (count inserted), write_errors, and success flag
CREATE OR REPLACE FUNCTION pg_temp.do_insert(db text, cmd documentdb_core.bson)
RETURNS TABLE(n int, write_errors int, success bool) AS $$
    SELECT
        (regexp_match((p_result -> 'n')::text, '"(\d+)"'))[1]::int,
        CASE WHEN p_success THEN 0
             ELSE (length(p_result::text) - length(replace(p_result::text, '"index"', ''))) / length('"index"')
        END,
        p_success
    FROM documentdb_api.insert(db, cmd)
$$ LANGUAGE SQL;


-- ============================================================
-- Part 1: Baseline — ordered:false, GUC ON (default)
-- ============================================================
\echo '--- Part 1: GUC ON, ordered:false ---'

SET documentdb.enableInsertDuplicateInlineHandling = ON;

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
-- Part 2: GUC OFF, ordered:false — same scenarios
-- ============================================================
\echo '--- Part 2: GUC OFF, ordered:false ---'

SET documentdb.enableInsertDuplicateInlineHandling = OFF;

SELECT documentdb_api.create_collection('insertdupdb', 'dup_test');

-- 2a: Insert 10 unique documents
SELECT * FROM pg_temp.do_insert('insertdupdb',
    '{"insert": "dup_test", "ordered": false, "documents": [
        {"_id": 1}, {"_id": 2}, {"_id": 3}, {"_id": 4}, {"_id": 5},
        {"_id": 6}, {"_id": 7}, {"_id": 8}, {"_id": 9}, {"_id": 10}
    ]}');

-- 2b: 100% duplicates
SELECT * FROM pg_temp.do_insert('insertdupdb',
    '{"insert": "dup_test", "ordered": false, "documents": [
        {"_id": 1}, {"_id": 2}, {"_id": 3}, {"_id": 4}, {"_id": 5},
        {"_id": 6}, {"_id": 7}, {"_id": 8}, {"_id": 9}, {"_id": 10}
    ]}');

-- 2c: 50% duplicates
SELECT * FROM pg_temp.do_insert('insertdupdb',
    '{"insert": "dup_test", "ordered": false, "documents": [
        {"_id": 1}, {"_id": 2}, {"_id": 3}, {"_id": 4}, {"_id": 5},
        {"_id": 11}, {"_id": 12}, {"_id": 13}, {"_id": 14}, {"_id": 15}
    ]}');

-- 2d: 10% duplicate
SELECT * FROM pg_temp.do_insert('insertdupdb',
    '{"insert": "dup_test", "ordered": false, "documents": [
        {"_id": 1},
        {"_id": 16}, {"_id": 17}, {"_id": 18}, {"_id": 19}, {"_id": 20},
        {"_id": 21}, {"_id": 22}, {"_id": 23}, {"_id": 24}
    ]}');

-- Verify same total: 24
SELECT COUNT(*) AS total_docs FROM documentdb_api.collection('insertdupdb', 'dup_test');

SELECT documentdb_api.drop_collection('insertdupdb', 'dup_test');


-- ============================================================
-- Part 3: ordered:true — duplicates stop further inserts
-- ============================================================
\echo '--- Part 3: ordered:true, duplicate stops batch ---'

SET documentdb.enableInsertDuplicateInlineHandling = ON;

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

-- Same test with GUC OFF
SET documentdb.enableInsertDuplicateInlineHandling = OFF;

SELECT * FROM pg_temp.do_insert('insertdupdb',
    '{"insert": "dup_test", "ordered": true, "documents": [
        {"_id": 10}, {"_id": 11},
        {"_id": 1},
        {"_id": 12}, {"_id": 13}
    ]}');

-- Verify: 7 + 2 new (10,11) = 9
SELECT COUNT(*) AS total_docs FROM documentdb_api.collection('insertdupdb', 'dup_test');

SELECT documentdb_api.drop_collection('insertdupdb', 'dup_test');


-- ============================================================
-- Part 4: Larger batches — 100 docs with various dup ratios
-- ============================================================
\echo '--- Part 4: 100-doc batches ---'

SET documentdb.enableInsertDuplicateInlineHandling = ON;

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
-- Part 5: Same 100-doc batches with GUC OFF
-- ============================================================
\echo '--- Part 5: 100-doc batches, GUC OFF ---'

SET documentdb.enableInsertDuplicateInlineHandling = OFF;

SELECT documentdb_api.create_collection('insertdupdb', 'dup_test');

-- Populate 100
SELECT * FROM pg_temp.do_insert('insertdupdb',
    documentdb_core.bson_build_document(
        'insert', 'dup_test'::text,
        'ordered', false,
        'documents', (SELECT array_agg(documentdb_core.bson_build_document('_id', i))
                      FROM generate_series(1, 100) i)
    ));

-- 0% dups
SELECT * FROM pg_temp.do_insert('insertdupdb',
    documentdb_core.bson_build_document(
        'insert', 'dup_test'::text,
        'ordered', false,
        'documents', (SELECT array_agg(documentdb_core.bson_build_document('_id', i))
                      FROM generate_series(101, 200) i)
    ));

-- 10% dups
SELECT * FROM pg_temp.do_insert('insertdupdb',
    documentdb_core.bson_build_document(
        'insert', 'dup_test'::text,
        'ordered', false,
        'documents', (SELECT array_agg(documentdb_core.bson_build_document('_id', i))
                      FROM (SELECT i FROM generate_series(1, 10) i
                            UNION ALL
                            SELECT i FROM generate_series(201, 290) i) sub)
    ));

-- 50% dups
SELECT * FROM pg_temp.do_insert('insertdupdb',
    documentdb_core.bson_build_document(
        'insert', 'dup_test'::text,
        'ordered', false,
        'documents', (SELECT array_agg(documentdb_core.bson_build_document('_id', i))
                      FROM (SELECT i FROM generate_series(1, 50) i
                            UNION ALL
                            SELECT i FROM generate_series(291, 340) i) sub)
    ));

-- 100% dups
SELECT * FROM pg_temp.do_insert('insertdupdb',
    documentdb_core.bson_build_document(
        'insert', 'dup_test'::text,
        'ordered', false,
        'documents', (SELECT array_agg(documentdb_core.bson_build_document('_id', i))
                      FROM generate_series(1, 100) i)
    ));

-- Same total: 340
SELECT COUNT(*) AS total_docs FROM documentdb_api.collection('insertdupdb', 'dup_test');

SELECT documentdb_api.drop_collection('insertdupdb', 'dup_test');


-- ============================================================
-- Part 6: Single-doc batch with duplicate
-- ============================================================
\echo '--- Part 6: Single-doc batches ---'

SET documentdb.enableInsertDuplicateInlineHandling = ON;

SELECT documentdb_api.create_collection('insertdupdb', 'dup_test');

-- Insert a doc
SELECT * FROM pg_temp.do_insert('insertdupdb',
    '{"insert": "dup_test", "ordered": false, "documents": [{"_id": 1}]}');

-- Insert same _id again (single-doc batch, GUC ON)
SELECT * FROM pg_temp.do_insert('insertdupdb',
    '{"insert": "dup_test", "ordered": false, "documents": [{"_id": 1}]}');

-- Same with GUC OFF
SET documentdb.enableInsertDuplicateInlineHandling = OFF;

SELECT * FROM pg_temp.do_insert('insertdupdb',
    '{"insert": "dup_test", "ordered": false, "documents": [{"_id": 1}]}');

-- Still only 1 doc
SELECT COUNT(*) AS total_docs FROM documentdb_api.collection('insertdupdb', 'dup_test');

SELECT documentdb_api.drop_collection('insertdupdb', 'dup_test');


-- ============================================================
-- Cleanup
-- ============================================================
SELECT documentdb_api.drop_database('insertdupdb');

-- Reset GUC
RESET documentdb.enableInsertDuplicateInlineHandling;
