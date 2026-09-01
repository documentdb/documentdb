CREATE OR REPLACE PROCEDURE __API_DISTRIBUTED_SCHEMA__.repair_collections_table_schema()
LANGUAGE C
AS 'MODULE_PATHNAME', $$command_repair_collections_table_schema$$;
COMMENT ON PROCEDURE __API_DISTRIBUTED_SCHEMA__.repair_collections_table_schema()
    IS 'Rebuilds the collections catalog table from the local reference table shard when the two have drifted apart.';

CREATE OR REPLACE FUNCTION __API_DISTRIBUTED_SCHEMA__.is_table_schema_consistent(table_name regclass)
RETURNS __CORE_SCHEMA_V2__.bson
LANGUAGE C
STABLE
AS 'MODULE_PATHNAME', $$command_is_table_schema_consistent$$;
COMMENT ON FUNCTION __API_DISTRIBUTED_SCHEMA__.is_table_schema_consistent(regclass)
    IS 'Reports whether a table matches the column layout of the reference table shard this node holds for it, listing each column with the position it occupies on either side, or NULL when this node holds no shard for it.';
