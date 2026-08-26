SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET documentdb.next_collection_id TO 1993000;
SET documentdb.next_collection_index_id TO 1993000;

/*
 * enableUpdateDescription collection option tests
 *
 * TEST PLAN:
 * 1. collMod to enable enableUpdateDescription on a collection
 * 2. listCollections shows enableUpdateDescription option
 * 3. collMod to disable enableUpdateDescription
 * 4. listCollections after disable
 * 5. create collection with enableUpdateDescription enabled
 * 6. create collection with enableUpdateDescription disabled (no-op)
 * 7. collMod enableUpdateDescription on a view fails
 * 8. collMod enableUpdateDescription with non-boolean value fails
 */

-- ============================================================================
-- Setup: create a database and collection
-- ============================================================================
SELECT documentdb_api.create_collection('updesc_db', 'test_coll');

-- ============================================================================
-- Test 1: collMod to enable enableUpdateDescription
-- ============================================================================
SELECT documentdb_api.coll_mod('updesc_db', 'test_coll', '{ "collMod": "test_coll", "enableUpdateDescription": true }');

-- ============================================================================
-- Test 2: listCollections shows enableUpdateDescription option
-- ============================================================================
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch.name": 1, "cursor.firstBatch.options": 1 }')
FROM documentdb_api.list_collections_cursor_first_page('updesc_db', '{ "filter": { "name": "test_coll" } }');

-- ============================================================================
-- Test 3: collMod to disable enableUpdateDescription
-- ============================================================================
SELECT documentdb_api.coll_mod('updesc_db', 'test_coll', '{ "collMod": "test_coll", "enableUpdateDescription": false }');

-- ============================================================================
-- Test 4: listCollections after disable - option should be removed
-- ============================================================================
SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch.name": 1, "cursor.firstBatch.options": 1 }')
FROM documentdb_api.list_collections_cursor_first_page('updesc_db', '{ "filter": { "name": "test_coll" } }');

-- ============================================================================
-- Test 5: create collection with enableUpdateDescription enabled
-- ============================================================================
SELECT documentdb_api.create_collection_view('updesc_db',
    '{ "create": "test_coll_with_updesc", "enableUpdateDescription": true }');

SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch.name": 1, "cursor.firstBatch.options": 1 }')
FROM documentdb_api.list_collections_cursor_first_page('updesc_db', '{ "filter": { "name": "test_coll_with_updesc" } }');

-- ============================================================================
-- Test 6: create collection with enableUpdateDescription disabled (no-op)
-- ============================================================================
SELECT documentdb_api.create_collection_view('updesc_db',
    '{ "create": "test_coll_no_updesc", "enableUpdateDescription": false }');

SELECT bson_dollar_project(cursorpage, '{ "cursor.firstBatch.name": 1, "cursor.firstBatch.options": 1 }')
FROM documentdb_api.list_collections_cursor_first_page('updesc_db', '{ "filter": { "name": "test_coll_no_updesc" } }');

-- ============================================================================
-- Test 7: collMod enableUpdateDescription on a view fails
-- ============================================================================
SELECT documentdb_api.create_collection_view('updesc_db',
    '{ "create": "test_view", "viewOn": "test_coll", "pipeline": [] }');

SELECT documentdb_api.coll_mod('updesc_db', 'test_view', '{ "collMod": "test_view", "enableUpdateDescription": true }');

-- ============================================================================
-- Test 8: collMod enableUpdateDescription with non-boolean value fails
-- ============================================================================
SELECT documentdb_api.coll_mod('updesc_db', 'test_coll', '{ "collMod": "test_coll", "enableUpdateDescription": "yes" }');

-- ============================================================================
-- Cleanup
-- ============================================================================
SELECT documentdb_api.drop_collection('updesc_db', 'test_coll');
SELECT documentdb_api.drop_collection('updesc_db', 'test_coll_with_updesc');
SELECT documentdb_api.drop_collection('updesc_db', 'test_coll_no_updesc');
SELECT documentdb_api.drop_collection('updesc_db', 'test_view');
