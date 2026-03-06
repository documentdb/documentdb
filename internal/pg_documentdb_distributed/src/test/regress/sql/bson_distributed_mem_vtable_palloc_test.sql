SET documentdb.next_collection_id TO 9800;
SET documentdb.next_collection_index_id TO 9800;
SET citus.next_shard_id TO 98000;

-- Test: verify that pg_documentdb_distributed.so's libbson memory vtable uses palloc
--
-- Create a temp memory context,
-- do a bson_malloc() inside it, check if the context recorded allocations.

CREATE OR REPLACE FUNCTION test_bson_distributed_mem_vtable_uses_palloc()
RETURNS bool
LANGUAGE C AS 'pg_documentdb_distributed', $$test_bson_distributed_mem_vtable_uses_palloc$$;

-- Must return true: libbson allocations in pg_documentdb_distributed.so go through palloc
SELECT test_bson_distributed_mem_vtable_uses_palloc();

DROP FUNCTION test_bson_distributed_mem_vtable_uses_palloc();
