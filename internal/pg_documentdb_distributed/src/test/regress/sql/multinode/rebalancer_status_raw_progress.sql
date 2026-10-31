SET citus.next_shard_id TO 87500;
SET documentdb.next_collection_id TO 8750;
SET documentdb.next_collection_index_id TO 8750;
SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal,public;

-- the API is gated
SET documentdb_distributed.enable_shard_rebalancer_apis TO off;
SELECT documentdb_api_distributed.rebalancer_status('{}');

SET documentdb_distributed.enable_shard_rebalancer_apis TO on;
SHOW documentdb_distributed.enable_rebalancer_raw_progress;

-- no active rebalance: no raw progress chunks are reported
SELECT documentdb_api.create_collection('rb_raw', 'c1');
SELECT documentdb_api_distributed.rebalancer_status('{}');
SELECT * FROM pg_catalog.get_rebalance_progress();

-- feature flag off: same response shape
SET documentdb_distributed.enable_rebalancer_raw_progress TO off;
SELECT documentdb_api_distributed.rebalancer_status('{}');

RESET documentdb_distributed.enable_rebalancer_raw_progress;

-- replace the progress function with a table-backed mock inside a transaction
BEGIN;
SET LOCAL allow_system_table_mods TO on;
CREATE TABLE public.mock_rebalance_progress (sessionid integer, table_name regclass, shardid bigint, shard_size bigint,
    sourcename text, sourceport integer, targetname text, targetport integer, progress bigint, source_shard_size bigint,
    target_shard_size bigint, operation_type text, source_lsn pg_lsn, target_lsn pg_lsn, status text);

CREATE OR REPLACE FUNCTION pg_catalog.get_rebalance_progress()
RETURNS TABLE(sessionid integer, table_name regclass, shardid bigint, shard_size bigint, sourcename text, sourceport integer,
    targetname text, targetport integer, progress bigint, source_shard_size bigint, target_shard_size bigint,
    operation_type text, source_lsn pg_lsn, target_lsn pg_lsn, status text)
LANGUAGE sql AS $$ SELECT * FROM public.mock_rebalance_progress ORDER BY shardid $$;

-- empty table: no chunks reported
SELECT documentdb_api_distributed.rebalancer_status('{}');

INSERT INTO public.mock_rebalance_progress VALUES
  (3303084, 'pg_class', 102046, 16384, '10.12.0.254', 7000, '10.12.0.254', 7001, 1, 16384, 16384, 'move', '9A39/CA3AA000', NULL, 'Copying Data'),
  (3303084, 'pg_class', 102047, 24576, '10.12.0.254', 7000, '10.12.0.254', 7001, 1, 24576, 16384, 'move', '9A39/CA3AA000', NULL, 'Copying Data');

SELECT documentdb_api_distributed.rebalancer_status('{}');

-- flag off hides the chunks
SET LOCAL documentdb_distributed.enable_rebalancer_raw_progress TO off;
SELECT documentdb_api_distributed.rebalancer_status('{}');
ROLLBACK;

-- the real function is restored
SELECT count(*) FROM pg_catalog.get_rebalance_progress();
