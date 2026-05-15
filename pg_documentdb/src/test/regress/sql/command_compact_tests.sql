SET documentdb.next_collection_id TO 25709000;
SET documentdb.next_collection_index_id TO 25709000;
SET search_path TO documentdb_core,documentdb_api,documentdb_api_catalog,documentdb_api_internal;

-- Error cases: NULL and empty spec
SELECT documentdb_api.compact(NULL);
SELECT documentdb_api.compact('{}');
SELECT documentdb_api.compact('{"noIdea": "collection1"}');
SELECT documentdb_api.compact('{"compact": "non_existing_collection"}');
SELECT documentdb_api.compact('{"compact": 1 }');
SELECT documentdb_api.compact('{"compact": true }');
SELECT documentdb_api.compact('{"compact": ["coll"]}');

-- Create a test collection
SELECT documentdb_api.create_collection('compact_db','compact_coll');

-- Invalid args
SELECT documentdb_api.compact('{"compact": "compact_coll", "dryRun": "invalid"}');
SELECT documentdb_api.compact('{"compact": "compact_coll", "force": false}');

-- Default GUC is off: compact should be a no-op returning bytesFreed: 0
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db"}');

-- dryRun with GUC off should return estimatedBytesFreed: 0
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db", "dryRun": true}');

-- Enable the GUC and run compact (with vacuum full)
SET documentdb.enableCompactVacuumFull TO on;

-- Insert data to have something to compact
SELECT documentdb_api.insert_one('compact_db', 'compact_coll', '{ "_id": 1, "a": "hello" }');

-- With GUC on, compact should execute and return bytesFreed
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db"}');

-- dryRun with GUC on should return estimatedBytesFreed
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db", "dryRun": true}');

-- comment field should be accepted
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db", "comment": "test comment"}');

RESET documentdb.enableCompactVacuumFull;

-- After reset, compact should be no-op again
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db"}');

SELECT documentdb_api.drop_collection('compact_db','compact_coll');
