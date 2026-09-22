\i sql/documentdb_distributed_test_helpers.sql

CREATE OR REPLACE PROCEDURE documentdb_distributed_test_helpers.place_collection_on_node(
		p_database_name text,
		p_collection_name text,
		p_node_number integer)
AS $$
DECLARE
	shard_key_exists boolean;
	v_collection_id bigint;
	current_groupid integer;
	collection_relid oid;
BEGIN
	SELECT shard_key IS NOT NULL, collection_id
		FROM documentdb_api_catalog.collections
		WHERE database_name = p_database_name AND collection_name = p_collection_name
		INTO shard_key_exists, v_collection_id;

	IF shard_key_exists THEN
		-- Collection is sharded, can't place in one node
		RAISE EXCEPTION 'Collection %.% is already sharded; cannot place on single node', p_database_name, p_collection_name;
	END IF;

	-- Resolve the underlying distributed table OID from the collection_id.
	collection_relid := format('documentdb_data.documents_%s', v_collection_id)::regclass;

	-- Check current placement; skip move if already on the target node. This
	-- avoids the "cannot move shard to the same node" error.
	SELECT pdn.groupid INTO current_groupid
		FROM pg_dist_shard ps
		JOIN pg_dist_shard_placement pp ON ps.shardid = pp.shardid
		JOIN pg_dist_node pdn ON pp.nodename = pdn.nodename AND pp.nodeport = pdn.nodeport
		WHERE ps.logicalrelid = collection_relid
			AND pdn.noderole = 'primary'
		LIMIT 1;

	IF current_groupid IS NOT NULL AND current_groupid = p_node_number THEN
		-- Already on the target node, nothing to do
		RETURN;
	END IF;

	-- moveCollection is not permitted inside a transaction block, so commit any
	-- prior work and run it as the sole statement of a fresh transaction.
	COMMIT;

	PERFORM documentdb_api_distributed.move_collection(
		documentdb_core.bson_build_document('moveCollection'::text, format('%s.%s', p_database_name, p_collection_name), 'toShard'::text, format('shard_%s', p_node_number::text))
	);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE documentdb_distributed_test_helpers.wait_for_command_result_on_all_nodes(
		p_command text,
		p_expected_value text)
AS $$
DECLARE
	expected_result_observed boolean := false;
BEGIN
	FOR attempt IN 1..100 LOOP
		SELECT bool_and(CASE WHEN success THEN result = p_expected_value ELSE false END)
			INTO expected_result_observed
			FROM run_command_on_all_nodes(p_command);

		EXIT WHEN expected_result_observed;
		PERFORM pg_sleep(0.05);
	END LOOP;

	IF NOT COALESCE(expected_result_observed, false) THEN
		RAISE EXCEPTION 'Timed out waiting for command result % on all nodes',
			p_expected_value;
	END IF;
END;
$$ LANGUAGE plpgsql;
