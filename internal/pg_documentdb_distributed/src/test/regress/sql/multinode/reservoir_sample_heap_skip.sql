-- Distributed heap skip reservoir sampling ($sample) coverage.
--
-- Verifies that on an unsharded collection heap skip engages when the shard
-- query's $match is fully served by an index that supports heap skip. It covers
-- both the direct index scan path and the bitmap to index scan rewrite. On a
-- sharded collection $sample never heap skips, because it is pushed down to each
-- shard as a random order limit rather than the reservoir scan. Planner GUCs use
-- SET LOCAL with citus.propagate_set_commands='local' so they reach the worker.
SET citus.next_shard_id TO 72000;
SET documentdb.next_collection_id TO 7200;
SET documentdb.next_collection_index_id TO 7200;
SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal,public;
SET documentdb.enableDollarSampleReservoirScan TO on;
SET citus.propagate_set_commands TO 'local';

-- Drop the database first so the pinned next_collection_id is deterministic: the
-- first collection created in a fresh database also creates the internal
-- system.dbSentinel collection, which consumes the pinned id (7200). Dropping up
-- front guarantees the sentinel takes 7200 and the first user collection takes
-- 7201, independent of whether an earlier test already created the database.
SELECT documentdb_api.drop_database('rsampledb');

-- -----------------------------------------------------------------------------
-- Unsharded collection placed on a worker: btree (_id) path supports heap skip.
-- -----------------------------------------------------------------------------
SELECT documentdb_api.create_collection('rsampledb', 'heapskip_unsharded');
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('rsampledb', 'heapskip_unsharded', FORMAT('{ "_id": %s, "value": %s }', g, g)::documentdb_core.bson) FROM generate_series(1, 200) g) ig;
SELECT documentdb_distributed_test_helpers.place_collection_on_node('rsampledb', 'heapskip_unsharded', 1);

-- $match on _id folds shard_key_value + object_id into the _id_ Index Cond with
-- no residual Filter, so heap skip engages: "Sample Reservoir Method: Heap Skip".
-- Correctness runs in the SAME transaction so it exercises the heap skip plan
-- (index forced until ROLLBACK): a sample smaller than the population returns
-- exactly that many distinct documents, all satisfying the predicate, and
-- oversampling (size >= population) returns every matching document.
BEGIN;
SET LOCAL documentdb.enableDollarSampleHeapSkipReservoirScan TO on;
SET LOCAL documentdb.forceUseIndexIfAvailable TO on;
SET LOCAL enable_seqscan TO off;
-- run_explain_and_trim strips the PG18-only "Disabled: true" line that appears
-- when a scan node is produced while its enabling planner GUC is off.
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('rsampledb', '{ "aggregate": "heapskip_unsharded", "pipeline": [ { "$match": { "_id": { "$gt": 5 } } }, { "$sample": { "size": 5 } } ] }') $$);
SELECT COUNT(*) AS cnt, COUNT(DISTINCT document) AS distinct_cnt
FROM (SELECT document FROM bson_aggregation_pipeline('rsampledb', '{ "aggregate": "heapskip_unsharded", "pipeline": [ { "$match": { "_id": { "$gt": 5 } } }, { "$sample": { "size": 5 } } ] }')) t;
SELECT COUNT(*) FILTER (WHERE NOT (document @@ '{ "_id": { "$gt": 5 } }'::bson)) AS not_matching
FROM (SELECT document FROM bson_aggregation_pipeline('rsampledb', '{ "aggregate": "heapskip_unsharded", "pipeline": [ { "$match": { "_id": { "$gt": 5 } } }, { "$sample": { "size": 20 } } ] }')) t;
SELECT COUNT(*) AS cnt, COUNT(DISTINCT document) AS distinct_cnt
FROM (SELECT document FROM bson_aggregation_pipeline('rsampledb', '{ "aggregate": "heapskip_unsharded", "pipeline": [ { "$match": { "_id": { "$gt": 195 } } }, { "$sample": { "size": 100 } } ] }')) t;
ROLLBACK;

-- Flag off: the same plan falls back to "Sample Reservoir Method: Materialize".
BEGIN;
SET LOCAL documentdb.enableDollarSampleHeapSkipReservoirScan TO off;
SET LOCAL documentdb.forceUseIndexIfAvailable TO on;
SET LOCAL enable_seqscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('rsampledb', '{ "aggregate": "heapskip_unsharded", "pipeline": [ { "$match": { "_id": { "$gt": 5 } } }, { "$sample": { "size": 5 } } ] }') $$);
ROLLBACK;


-- -----------------------------------------------------------------------------
-- Bitmap to Index Scan rewrite on a shard placement: at plan time a bitmap heap
-- path built from a single index whose bitmap covers every restriction is
-- rewritten to an index scan path so heap skip can engage (the final plan is an
-- Index Scan, no Bitmap Heap Scan executes). The setup only makes a bitmap
-- reachable (drop_primary_key leaves value_1 as the sole index; shard_key_value
-- is pruned so value_1 fully covers the scan); the bitmap is forced by the GUCs
-- below.
-- -----------------------------------------------------------------------------
SELECT documentdb_api.create_collection('rsampledb', 'heapskip_bmp');
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('rsampledb', 'heapskip_bmp', FORMAT('{ "_id": %s, "value": %s }', g, g)::documentdb_core.bson) FROM generate_series(1, 200) g) ig;
SELECT documentdb_api_internal.create_indexes_non_concurrently('rsampledb', '{ "createIndexes": "heapskip_bmp", "indexes": [ { "key": { "value": 1 }, "name": "value_1" } ] }', TRUE);
SELECT documentdb_distributed_test_helpers.place_collection_on_node('rsampledb', 'heapskip_bmp', 1);
SELECT documentdb_distributed_test_helpers.drop_primary_key('rsampledb', 'heapskip_bmp');

-- Flag on: enable_indexscan=off + enable_seqscan=off force the value_1 path to a
-- Bitmap Heap Scan (bitmap scans obey enable_bitmapscan, left on); the flag then
-- rewrites it to an Index Scan that could not appear otherwise and heap skip
-- engages. Correctness runs in the SAME transaction so it exercises the
-- converted plan.
BEGIN;
SET LOCAL enable_indexscan TO off;
SET LOCAL enable_seqscan TO off;
SET LOCAL documentdb.enableDollarSampleHeapSkipReservoirScan TO on;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('rsampledb', '{ "aggregate": "heapskip_bmp", "pipeline": [ { "$match": { "value": { "$gte": 190 } } }, { "$sample": { "size": 5 } } ] }') $$);
SELECT COUNT(*) AS cnt, COUNT(DISTINCT document) AS distinct_cnt,
       COUNT(*) FILTER (WHERE NOT (document @@ '{ "value": { "$gte": 190 } }'::bson)) AS not_matching
FROM (SELECT document FROM bson_aggregation_pipeline('rsampledb', '{ "aggregate": "heapskip_bmp", "pipeline": [ { "$match": { "value": { "$gte": 190 } } }, { "$sample": { "size": 5 } } ] }')) t;
SELECT COUNT(*) AS cnt, COUNT(DISTINCT document) AS distinct_cnt
FROM (SELECT document FROM bson_aggregation_pipeline('rsampledb', '{ "aggregate": "heapskip_bmp", "pipeline": [ { "$match": { "value": { "$gte": 190 } } }, { "$sample": { "size": 100 } } ] }')) t;
ROLLBACK;

-- Flag off: same GUCs, so the base path is still a Bitmap Heap Scan on value_1.
-- With no rewrite the plan keeps it and stays "Materialize", proving the setup
-- really produces a bitmap for the flag on block to convert.
BEGIN;
SET LOCAL enable_indexscan TO off;
SET LOCAL enable_seqscan TO off;
SET LOCAL documentdb.enableDollarSampleHeapSkipReservoirScan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('rsampledb', '{ "aggregate": "heapskip_bmp", "pipeline": [ { "$match": { "value": { "$gte": 190 } } }, { "$sample": { "size": 5 } } ] }') $$);
ROLLBACK;

-- -----------------------------------------------------------------------------
-- Sharded collection: sampling must NOT use the heap skip reservoir path.
-- -----------------------------------------------------------------------------
SELECT documentdb_api.create_collection('rsampledb', 'heapskip_sharded');
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('rsampledb', 'heapskip_sharded', FORMAT('{ "_id": %s, "region": "%s", "value": %s }', g, (ARRAY['east','west','north','south'])[1 + (g % 4)], g)::documentdb_core.bson) FROM generate_series(1, 100) g) ig;
SELECT documentdb_api.shard_collection('rsampledb', 'heapskip_sharded', '{ "region": "hashed" }', false);

-- On a sharded collection $sample is pushed down to each shard as ORDER BY
-- random() LIMIT n (a Sort on random() feeding a Limit), so the reservoir custom
-- scan is never used and heap skip cannot engage. The $match on region is
-- enforced as a residual recheck Filter on the shard's _id_ index scan.
BEGIN;
SET LOCAL documentdb.enableDollarSampleHeapSkipReservoirScan TO on;
SET LOCAL documentdb.forceUseIndexIfAvailable TO on;
SET LOCAL enable_seqscan TO off;
SELECT documentdb_distributed_test_helpers.run_explain_and_trim($$ EXPLAIN (COSTS OFF, VERBOSE ON) SELECT document FROM bson_aggregation_pipeline('rsampledb', '{ "aggregate": "heapskip_sharded", "pipeline": [ { "$match": { "region": "east" } }, { "$sample": { "size": 5 } } ] }') $$);
ROLLBACK;

-- Correctness: shard key equality targets a single shard; oversampling returns
-- exactly that region's documents and never crosses shard boundaries.
SET documentdb.enableDollarSampleHeapSkipReservoirScan TO on;
SELECT COUNT(*) AS cnt, COUNT(DISTINCT document) AS distinct_cnt,
       COUNT(*) FILTER (WHERE NOT (document @@ '{ "region": "east" }'::bson)) AS not_matching
FROM (SELECT document FROM bson_aggregation_pipeline('rsampledb', '{ "aggregate": "heapskip_sharded", "pipeline": [ { "$match": { "region": "east" } }, { "$sample": { "size": 1000 } } ] }')) t;

-- A multi shard sample returns the requested number of distinct documents.
SELECT COUNT(*) AS cnt, COUNT(DISTINCT document) AS distinct_cnt
FROM (SELECT document FROM bson_aggregation_pipeline('rsampledb', '{ "aggregate": "heapskip_sharded", "pipeline": [ { "$sample": { "size": 10 } } ] }')) t;
RESET documentdb.enableDollarSampleHeapSkipReservoirScan;

RESET documentdb.enableDollarSampleReservoirScan;
SELECT documentdb_api.drop_collection('rsampledb', 'heapskip_unsharded');
SELECT documentdb_api.drop_collection('rsampledb', 'heapskip_bmp');
SELECT documentdb_api.drop_collection('rsampledb', 'heapskip_sharded');
