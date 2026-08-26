SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 198470000;
SET documentdb.next_collection_id TO 1984700;
SET documentdb.next_collection_index_id TO 1984700;

-- Enable the worker path GUC for the entire test
SET documentdb.enable_update_many_worker_pushdown TO ON;

-- ================================================================
-- Tests for updateMany worker pushdown (enable_update_many_worker_pushdown)
-- Validates that sharded updateMany uses update_worker path
-- and returns correct matched/modified counts.
-- ================================================================

-- Setup: create collection, insert docs, shard it
SELECT 1 FROM documentdb_api.insert_one('umwdb', 'umwcoll', '{"_id":1, "a":1, "b":10, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('umwdb', 'umwcoll', '{"_id":2, "a":2, "b":20, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('umwdb', 'umwcoll', '{"_id":3, "a":3, "b":30, "tag":"y"}');
SELECT 1 FROM documentdb_api.insert_one('umwdb', 'umwcoll', '{"_id":4, "a":4, "b":40, "tag":"y"}');
SELECT 1 FROM documentdb_api.insert_one('umwdb', 'umwcoll', '{"_id":5, "a":5, "b":50, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('umwdb', 'umwcoll', '{"_id":6, "a":6, "b":60, "tag":"z"}');
SELECT 1 FROM documentdb_api.insert_one('umwdb', 'umwcoll', '{"_id":7, "a":7, "b":70, "tag":"z"}');
SELECT 1 FROM documentdb_api.insert_one('umwdb', 'umwcoll', '{"_id":8, "a":8, "b":80, "tag":"x"}');
SELECT 1 FROM documentdb_api.insert_one('umwdb', 'umwcoll', '{"_id":9, "a":9, "b":90, "tag":"y"}');
SELECT 1 FROM documentdb_api.insert_one('umwdb', 'umwcoll', '{"_id":10, "a":10, "b":100, "tag":"z"}');

SELECT documentdb_api.shard_collection('umwdb', 'umwcoll', '{"a":"hashed"}', false);

-- ================================================================
-- 1. Basic updateMany $set all docs (GUC ON by default)
--    Expect: matched=10, modified=10
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{},"u":{"$set":{"c":1}},"multi":true}]}');
-- Verify data
SELECT count(*) FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"c":1}';
ROLLBACK;

-- ================================================================
-- 2. updateMany $set on subset
--    Expect: matched=3, modified=3 (tag=y has 3 docs: _id 3,4,9)
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{"tag":"y"},"u":{"$set":{"c":2}},"multi":true}]}');
SELECT count(*) FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"c":2}';
ROLLBACK;

-- ================================================================
-- 3. updateMany $inc - all docs should change
--    Expect: matched=10, modified=10
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{},"u":{"$inc":{"b":1}},"multi":true}]}');
-- Verify a sample doc
SELECT document FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"_id":1}';
ROLLBACK;

-- ================================================================
-- 4. updateMany $set idempotent - set value that already exists
--    Expect: matched=4, modified=0 (tag=x already on 4 docs)
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{"tag":"x"},"u":{"$set":{"tag":"x"}},"multi":true}]}');
ROLLBACK;

-- ================================================================
-- 5. updateMany with shard key eq filter
--    Should route to single shard
-- ================================================================
BEGIN;
SET LOCAL citus.log_remote_commands TO ON;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{"a":{"$eq":5}},"u":{"$set":{"c":5}},"multi":true}]}');
RESET citus.log_remote_commands;
-- Verify
SELECT document FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"a":5}';
ROLLBACK;

-- ================================================================
-- 6. updateMany without shard key filter
--    Should fan out to all shards via update_worker
-- ================================================================
BEGIN;
SET LOCAL citus.log_remote_commands TO ON;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{"tag":"z"},"u":{"$set":{"c":6}},"multi":true}]}');
RESET citus.log_remote_commands;
-- Verify: 3 docs with tag=z (_id 6,7,10)
SELECT count(*) FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"c":6}';
ROLLBACK;

-- ================================================================
-- 7. updateMany with GUC OFF - should use CTE path (no update_worker for updateMany)
-- ================================================================
BEGIN;
SET LOCAL documentdb.enable_update_many_worker_pushdown TO OFF;
SET LOCAL citus.log_remote_commands TO ON;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{},"u":{"$set":{"c":7}},"multi":true}]}');
RESET citus.log_remote_commands;
-- Verify
SELECT count(*) FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"c":7}';
ROLLBACK;

-- ================================================================
-- 8. updateMany no matching docs
--    Expect: matched=0, modified=0
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{"a":999},"u":{"$set":{"c":8}},"multi":true}]}');
ROLLBACK;

-- ================================================================
-- 9. updateMany with range filter ($gte/$lte)
--    Expect: matched=5, modified=5 (a >= 3 AND a <= 7)
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{"a":{"$gte":3,"$lte":7}},"u":{"$set":{"range_hit":true}},"multi":true}]}');
SELECT count(*) FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"range_hit":true}';
ROLLBACK;

-- ================================================================
-- 10. updateMany with $unset via aggregation pipeline
--     Expect: matched=10, modified=10 (unset tag from all docs)
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{},"u":[{"$unset":["tag"]}],"multi":true}]}');
-- Verify: no docs should have tag field
SELECT count(*) FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"tag":"x"}';
ROLLBACK;

-- ================================================================
-- 11. updateMany with upsert (no match -> should upsert)
--     Expect: matched=0, modified=0, upserted=1
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{"_id":999,"a":999},"u":{"$set":{"c":11}},"multi":true,"upsert":true}]}');
-- Verify upserted doc exists
SELECT count(*) FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"c":11}';
ROLLBACK;

-- ================================================================
-- 12. Batch update: multiple update specs in one call
--     First spec: $set c=12 on tag=x (4 docs)
--     Second spec: $set c=13 on tag=y (3 docs)
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{"tag":"x"},"u":{"$set":{"c":12}},"multi":true},{"q":{"tag":"y"},"u":{"$set":{"c":13}},"multi":true}]}');
SELECT count(*) FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"c":12}';
SELECT count(*) FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"c":13}';
ROLLBACK;

-- ================================================================
-- 13. updateMany with $mul operator
--     Expect: matched=10, modified=10
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{},"u":{"$mul":{"b":2}},"multi":true}]}');
-- Verify a sample doc: _id=1 had b=10, now should be 20
SELECT document FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"_id":1}';
ROLLBACK;

-- ================================================================
-- 14. updateMany $set with arrayFilters
--     Insert docs with nested arrays, update specific elements
-- ================================================================
SELECT 1 FROM documentdb_api.insert_one('umwdb', 'umwaf', '{"_id":1, "a":1, "items":[{"name":"p1","qty":5},{"name":"p2","qty":15}]}');
SELECT 1 FROM documentdb_api.insert_one('umwdb', 'umwaf', '{"_id":2, "a":2, "items":[{"name":"p3","qty":25},{"name":"p4","qty":3}]}');
SELECT documentdb_api.shard_collection('umwdb', 'umwaf', '{"a":"hashed"}', false);

BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwaf", "updates":[{"q":{},"u":{"$set":{"items.$[elem].status":"low"}},"multi":true,"arrayFilters":[{"elem.qty":{"$lt":10}}]}]}');
-- Verify: items with qty<10 should have status=low
SELECT document FROM documentdb_api.collection('umwdb', 'umwaf') WHERE document @@ '{"_id":1}';
SELECT document FROM documentdb_api.collection('umwdb', 'umwaf') WHERE document @@ '{"_id":2}';
ROLLBACK;

SELECT documentdb_api.drop_collection('umwdb', 'umwaf');

-- ================================================================
-- 15. updateMany toggle GUC on/off and compare results
--     Both paths must return identical matched/modified counts
-- ================================================================
BEGIN;
-- With GUC ON (worker path)
SET LOCAL documentdb.enable_update_many_worker_pushdown TO ON;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{"tag":"x"},"u":{"$inc":{"b":100}},"multi":true}]}');
ROLLBACK;

BEGIN;
-- With GUC OFF (CTE path)
SET LOCAL documentdb.enable_update_many_worker_pushdown TO OFF;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{"tag":"x"},"u":{"$inc":{"b":100}},"multi":true}]}');
ROLLBACK;

-- ================================================================
-- 16. updateMany with ordered:false batch containing an error
--     First and third should succeed; second has bad operator
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{"a":1},"u":{"$set":{"c":16}},"multi":true},{"q":{"$badop":1},"u":{"$set":{"c":16}},"multi":true},{"q":{"a":3},"u":{"$set":{"c":16}},"multi":true}],"ordered":false}');
SELECT count(*) FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"c":16}';
ROLLBACK;

-- ================================================================
-- 17. Data integrity: permanent update and read-back
--     Apply $set, then verify all docs are correct
-- ================================================================
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{},"u":{"$set":{"verified":true}},"multi":true}]}');
SELECT count(*) FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"verified":true}';

-- ================================================================
-- 18. Upsert via worker path with _id-only filter (no match)
--     hasOnlyObjectIdFilter = true -> uses InsertOrReplace path
--     Expect: n=1, nModified=0, upserted=[{index:0, _id:888}]
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{"_id":888},"u":{"$set":{"c":18}},"multi":true,"upsert":true}]}');
SELECT document FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"_id":888}';
ROLLBACK;

-- ================================================================
-- 19. Upsert via worker path with non-_id filter (no match)
--     hasOnlyObjectIdFilter = false -> uses Insert path
--     Expect: n=1, nModified=0, upserted
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{"_id":666,"tag":"nonexistent"},"u":{"$set":{"c":19}},"multi":true,"upsert":true}]}');
SELECT document FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"_id":666}';
ROLLBACK;

-- ================================================================
-- 20. Upsert via worker path with _id + additional filters (no match)
--     hasOnlyObjectIdFilter = false (non-id filters present)
--     Expect: n=1, nModified=0, upserted
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{"_id":777,"tag":"nonexistent"},"u":{"$set":{"c":20}},"multi":true,"upsert":true}]}');
SELECT document FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"_id":777}';
ROLLBACK;

-- ================================================================
-- 21. Upsert via worker path when docs match (should NOT upsert)
--     Expect: matched=4, modified=4, no upserted array
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{"tag":"x"},"u":{"$set":{"c":21}},"multi":true,"upsert":true}]}');
SELECT count(*) FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"c":21}';
ROLLBACK;

-- ================================================================
-- 22. Upsert via worker path with _id-only filter on existing doc
--     hasOnlyObjectIdFilter = true, but doc exists so no upsert
--     Expect: matched=1, modified=1, no upserted array
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{"_id":1},"u":{"$set":{"c":22}},"multi":true,"upsert":true}]}');
SELECT document FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"_id":1}';
ROLLBACK;

-- ================================================================
-- 23. updateMany with let variables via worker path
--     Verifies that let variables are preserved through the worker
--     path serialization/deserialization (variableSpec on UpdateOneParams)
--     Expect: matched=3, modified=3 (tag=y has 3 docs: _id 3,4,9)
-- ================================================================
BEGIN;
SELECT documentdb_api.update('umwdb', '{"update":"umwcoll", "updates":[{"q":{"$expr":{"$eq":["$tag","$$targetTag"]}},"u":[{"$set":{"letHit":"$$targetTag"}}],"multi":true}], "let":{"targetTag":"y"}}');
SELECT count(*) FROM documentdb_api.collection('umwdb', 'umwcoll') WHERE document @@ '{"letHit":"y"}';
ROLLBACK;

-- Cleanup
SELECT documentdb_api.drop_collection('umwdb', 'umwcoll');

-- Reset the worker path GUC
RESET documentdb.enable_update_many_worker_pushdown;
