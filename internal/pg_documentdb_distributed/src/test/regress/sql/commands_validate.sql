SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;
SET citus.next_shard_id TO 870000;
SET documentdb.next_collection_id TO 8700;
SET documentdb.next_collection_index_id TO 8700;

SELECT documentdb_api.drop_collection('db', 'validatecoll');

-- Empty collection name
SELECT documentdb_api.validate('db','{}');
SELECT documentdb_api.validate('db', '{"validate" : ""}');

-- Collection does not exist
SELECT documentdb_api.validate('db', '{"validate" : "missingcoll"}');

-- Create Collection
SELECT documentdb_api.create_collection('db', 'validatecoll');

-- Collection without docs and with only id index/no user defined indexes
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll"}');

-- repair is not supported on views
SELECT documentdb_api.create_collection_view(
	'db',
	'{"create":"validateview","viewOn":"validatecoll"}');
SELECT documentdb_api.validate(
	'db',
	'{"validate":"validateview","repair":true}');

-- Collection with id index and an additional index
SELECT documentdb_api_internal.create_indexes_non_concurrently('db', documentdb_distributed_test_helpers.generate_create_index_arg('validatecoll', 'index_1', '{"a": 1}'), true);
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll"}');

-- Insert few docs
SELECT documentdb_api.insert_one('db','validatecoll','{"_id":"1", "a": 100 }');
SELECT documentdb_api.insert_one('db','validatecoll','{"_id":"1", "a": 101, "b": 201 }');
SELECT documentdb_api.insert_one('db','validatecoll','{"_id":"1", "a": 102, "b": 202 }');

-- Collection with docs and user defined index
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll"}');

-- Valid input options --
-- only validate
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll"}');

-- validate with repair: true or repair: false remains same
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll", "full" : null, "repair" : false}');

-- validate with full: true or full: false remains same
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll", "full" : false}');
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll", "full" : true}');

-- validate with metadata: true or metadata: false remains same
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll", "full" : null, "repair" : null, "metadata" : false}');
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll", "full" : null, "repair" : null, "metadata" : true}');

-- validate reports missing readWriteAnyDatabase access when repair is omitted or false
SELECT collection_id AS validate_collection_id
FROM documentdb_api_catalog.collections
WHERE database_name = 'db' AND collection_name = 'validatecoll' \gset
SELECT format(
	'REVOKE SELECT ON TABLE documentdb_data.documents_%s FROM documentdb_rbac_baseline_read_role',
	:'validate_collection_id') \gexec
SELECT format(
	'REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLE documentdb_data.documents_%s FROM documentdb_rbac_baseline_write_role',
	:'validate_collection_id') \gexec
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll"}');
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll", "repair" : false}');

-- validate with repair: true
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll", "repair" : true}');

-- validate no longer reports missing access after repair
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll"}');

-- validate with repair and full
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll", "full" : true, "repair" : true}');

-- Invalid input options --
-- validate with repair and metadata
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll", "repair" : true, "metadata" : true}');

-- validate with full and metadata
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll", "full" : true,  "metadata" : true}');

-- validate with repair, full and metadata
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll", "full" : true, "metadata" : true, "repair" : true}');
-- validate with document conformance checks and repair
SELECT documentdb_api.validate('db', '{"validate" : "validatecoll", "checkBSONConformance" : true, "repair" : true}');
-- validate field is an object
SELECT documentdb_api.validate('db','{"validate":{}}');