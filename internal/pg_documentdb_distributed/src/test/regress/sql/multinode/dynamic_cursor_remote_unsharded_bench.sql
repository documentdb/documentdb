-- ===========================================================================
-- First-page latency micro-benchmark for the remote-unsharded path, run inside
-- the multinode harness (where the secondary-index ordered sort actually
-- streams). Measures find first-page latency for:
--   * empty find         { find, filter:{} }
--   * indexed sort       { find, filter:{}, sort:{a:1}, hint:"idx_a" }
-- comparing dynamic cursors ON (streaming remote drain) vs OFF.
-- Only the first page is fetched (no getMore). Timing output is intentionally
-- non-deterministic; this test is for ad-hoc measurement, not regression.
-- ===========================================================================
SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog,documentdb_api_internal;

SET documentdb.next_collection_id TO 43000;
SET citus.next_shard_id TO 4300000;
SET documentdb.next_collection_index_id TO 43000;

SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableIndexOnlyScanForFindProject TO on;
SET enable_seqscan TO off;

\i sql/documentdb_distributed_test_helpers.sql

-- ---------------------------------------------------------------------------
-- Setup: unsharded collection, ordered index on {a:1}, placed on a worker.
-- "a" is spread (multiplicative hash) so the {a:1} sort genuinely needs the
-- index for ordering (not already in _id order).
-- ---------------------------------------------------------------------------
SELECT documentdb_api.drop_collection('bench_db', 'bench_coll');
SELECT documentdb_api.create_collection('bench_db', 'bench_coll');

DO $$
DECLARE s int; e int; n int := 100000;
BEGIN
  s := 1;
  WHILE s <= n LOOP
    e := LEAST(s + 4999, n);
    PERFORM documentdb_api.insert('bench_db',
      ('{"insert":"bench_coll","documents":[' ||
       (SELECT string_agg(format('{"_id":%s,"a":%s}', g, (g * 7919) % n), ',')
        FROM generate_series(s, e) g) || ']}')::bson);
    s := e + 1;
  END LOOP;
END $$;

SELECT documentdb_api_internal.create_indexes_non_concurrently('bench_db',
  '{"createIndexes": "bench_coll", "indexes": [{"key": {"a": 1}, "name": "idx_a", "enableOrderedIndex": true}]}', true);
ANALYZE;
SELECT documentdb_distributed_test_helpers.place_collection_on_node('bench_db', 'bench_coll', 1);

SET documentdb.useLocalExecutionShardQueries TO off;

-- ---------------------------------------------------------------------------
-- Sanity: report stream (wc.dc) vs file (qf) for each shape + mode.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.cursor_kind(p_spec bson, p_dynamic bool)
RETURNS text AS $$
DECLARE c text;
BEGIN
  EXECUTE format('SET documentdb.enableDynamicCursors TO %s', CASE WHEN p_dynamic THEN 'on' ELSE 'off' END);
  SELECT documentdb_core.bson_to_json_string(fp.continuation)::text INTO c
  FROM documentdb_api.find_cursor_first_page('bench_db', p_spec, 73001) fp;
  RETURN CASE WHEN c ~ '"qf"' THEN 'file'
              WHEN c ~ '"dc"' THEN 'stream'
              WHEN c IS NULL THEN 'fully-drained'
              ELSE 'other' END;
END; $$ LANGUAGE plpgsql;

SELECT 'empty  dynamic_on  : ' || pg_temp.cursor_kind('{"find":"bench_coll","filter":{},"batchSize":1000}'::bson, true);
SELECT 'sorted dynamic_on  : ' || pg_temp.cursor_kind('{"find":"bench_coll","filter":{},"sort":{"a":1},"projection":{"_id":1,"a":1},"batchSize":1000,"hint":"idx_a"}'::bson, true);

-- ---------------------------------------------------------------------------
-- Timing: first-page latency, 15 iterations per (shape, mode), warmup first.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE bench_fp (query text, mode text, iter int, ms float8);

DO $$
DECLARE
  v_iters int := 15;
  i int;
  v_t0 timestamptz;
  v_empty  bson := '{"find":"bench_coll","filter":{},"batchSize":1000}';
  v_sorted bson := '{"find":"bench_coll","filter":{},"sort":{"a":1},"projection":{"_id":1,"a":1},"batchSize":1000,"hint":"idx_a"}';
BEGIN
  -- warmup
  SET documentdb.enableDynamicCursors TO on;
  PERFORM fp.cursorpage FROM documentdb_api.find_cursor_first_page('bench_db', v_empty,  9001) fp;
  PERFORM fp.cursorpage FROM documentdb_api.find_cursor_first_page('bench_db', v_sorted, 9002) fp;
  SET documentdb.enableDynamicCursors TO off;
  PERFORM fp.cursorpage FROM documentdb_api.find_cursor_first_page('bench_db', v_empty,  9003) fp;
  PERFORM fp.cursorpage FROM documentdb_api.find_cursor_first_page('bench_db', v_sorted, 9004) fp;

  FOR i IN 1..v_iters LOOP
    SET documentdb.enableDynamicCursors TO on;
    v_t0 := clock_timestamp();
    PERFORM fp.cursorpage FROM documentdb_api.find_cursor_first_page('bench_db', v_empty, 9101) fp;
    INSERT INTO bench_fp VALUES (v_empty::text, 'dynamic_on', i, EXTRACT(EPOCH FROM (clock_timestamp()-v_t0))*1000);

    v_t0 := clock_timestamp();
    PERFORM fp.cursorpage FROM documentdb_api.find_cursor_first_page('bench_db', v_sorted, 9102) fp;
    INSERT INTO bench_fp VALUES (v_sorted::text, 'dynamic_on', i, EXTRACT(EPOCH FROM (clock_timestamp()-v_t0))*1000);

    SET documentdb.enableDynamicCursors TO off;
    v_t0 := clock_timestamp();
    PERFORM fp.cursorpage FROM documentdb_api.find_cursor_first_page('bench_db', v_empty, 9103) fp;
    INSERT INTO bench_fp VALUES (v_empty::text, 'dynamic_off', i, EXTRACT(EPOCH FROM (clock_timestamp()-v_t0))*1000);

    v_t0 := clock_timestamp();
    PERFORM fp.cursorpage FROM documentdb_api.find_cursor_first_page('bench_db', v_sorted, 9104) fp;
    INSERT INTO bench_fp VALUES (v_sorted::text, 'dynamic_off', i, EXTRACT(EPOCH FROM (clock_timestamp()-v_t0))*1000);
  END LOOP;
END $$;

SELECT query, mode,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY ms)::numeric, 2) AS med_ms,
       round(min(ms)::numeric, 2) AS min_ms,
       round(max(ms)::numeric, 2) AS max_ms,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY ms)::numeric, 2) AS p90_ms
FROM bench_fp
GROUP BY query, mode
ORDER BY query, mode;

SELECT documentdb_api.drop_collection('bench_db', 'bench_coll');
