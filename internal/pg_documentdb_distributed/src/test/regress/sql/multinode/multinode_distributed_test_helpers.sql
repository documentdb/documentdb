\i sql/documentdb_distributed_test_helpers.sql

CREATE OR REPLACE FUNCTION documentdb_distributed_test_helpers.place_collection_on_node(
		p_database_name text,
		p_collection_name text,
		p_node_number integer)
RETURNS boolean
SET citus.enable_local_execution TO OFF
AS $$
DECLARE
	shard_key_exists boolean;
BEGIN
	SELECT shard_key IS NOT NULL FROM documentdb_api_catalog.collections where database_name = p_database_name AND collection_name = p_collection_name INTO shard_key_exists;
	IF shard_key_exists THEN
		-- Collection is sharded, can't place in one node
		RAISE EXCEPTION 'Collection %.% is already sharded; cannot place on single node', p_database_name, p_collection_name;
	END IF;

	-- Move the collection to the requested shard based on parameters
	BEGIN
		PERFORM documentdb_api_distributed.move_collection(
			documentdb_core.bson_build_document('moveCollection'::text, format('%s.%s', p_database_name, p_collection_name), 'toShard'::text, format('shard_%s', p_node_number::text))
		);
		RETURN TRUE;
	END;
	RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

