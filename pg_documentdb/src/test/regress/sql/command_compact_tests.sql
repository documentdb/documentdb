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
SELECT documentdb_api.compact('{"compact": "compact_coll", "mode": "invalid"}');
SELECT documentdb_api.compact('{"compact": "compact_coll", "mode": 1}');
SELECT documentdb_api.compact('{"compact": "compact_coll", "dryRun": true, "mode": "updateStats"}');
SELECT documentdb_api.compact('{"compact": "compact_coll", "mode": "updateStats", "mode": "full"}');
SELECT documentdb_api.compact('{"compact": "compact_coll", "mode": "full", "mode": "standard"}');

-- Default mode is "standard", which is NOT gated by the GUC and runs even with GUC off
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db"}');

-- mode "full" IS gated: with GUC off it should be a no-op returning bytesFreed: 0
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db", "mode": "full"}');

-- mode "standard" is NOT gated and still runs (returns ok)
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db", "mode": "standard"}');

-- dryRun with GUC off should return estimatedBytesFreed: 0
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db", "dryRun": true}');
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db", "dryRun": true, "mode": "standard"}');
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db", "mode": "full", "dryRun": true}');

-- mode updateStats runs ANALYZE instead of VACUUM and is not gated by the vacuum full GUC
SET client_min_messages TO DEBUG1;
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db", "mode": "updateStats"}');
RESET client_min_messages;

-- Enable the GUC and run compact (with vacuum full)
SET documentdb.enableCompactVacuumFull TO on;

-- Insert data to have something to compact
SELECT documentdb_api.insert_one('compact_db', 'compact_coll', '{ "_id": 1, "a": "hello" }');

-- With GUC on, compact should execute and return bytesFreed
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db"}');

-- mode: "full" must be requested explicitly and runs a blocking vacuum full
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db", "mode": "full"}');

-- mode: "standard" should run a regular (non-blocking) vacuum
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db", "mode": "standard"}');

-- dryRun with GUC on should return estimatedBytesFreed
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db", "dryRun": true}');

-- comment field should be accepted
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db", "comment": "test comment"}');

RESET documentdb.enableCompactVacuumFull;

-- After reset, mode "full" should be no-op again since it is gated by the GUC
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db", "mode": "full"}');

-- ... but the default (standard) mode still runs since it is not gated by the GUC
SELECT documentdb_api.compact('{"compact": "compact_coll", "$db": "compact_db"}');

SELECT documentdb_api.drop_collection('compact_db','compact_coll');

-- bytesFreed must be a measured delta of the on-disk size, not an estimate.
-- Build a collection with real bloat: insert a large number of documents and
-- then delete most of them, leaving the dead tuples behind for compact to reclaim.
SELECT documentdb_api.create_collection('compact_db','compact_delta_coll');

SELECT documentdb_api.insert_one('compact_db', 'compact_delta_coll',
    FORMAT('{ "_id": %s, "a": "%s" }', g, repeat('x', 400))::documentdb_core.bson) IS NOT NULL AS inserted
    FROM generate_series(1, 20000) g OFFSET 19999;

SELECT documentdb_api.delete('compact_db',
    '{"delete": "compact_delta_coll", "deletes": [{"q": {"_id": {"$lt": 18000}}, "limit": 0}]}');

SET documentdb.enableCompactVacuumFull TO on;

-- Capture the size before and after so the assertion does not depend on an
-- exact byte count, which varies with page layout and PostgreSQL version.
SELECT documentdb_api_internal.get_storage_stats_worker(collection_id, '{ "physicalSize": true }') AS size_before
    FROM documentdb_api_catalog.collections
    WHERE database_name = 'compact_db' AND collection_name = 'compact_delta_coll' \gset

-- VACUUM FULL rewrites the table, so the reported bytesFreed must be positive
-- and must match the actual reduction in the on-disk size.
SELECT documentdb_api.compact('{"compact": "compact_delta_coll", "$db": "compact_db", "mode": "full"}') AS compact_result \gset

SELECT documentdb_api_internal.get_storage_stats_worker(collection_id, '{ "physicalSize": true }') AS size_after
    FROM documentdb_api_catalog.collections
    WHERE database_name = 'compact_db' AND collection_name = 'compact_delta_coll' \gset

SELECT documentdb_core.bson_get_value_text((:'compact_result')::documentdb_core.bson, 'bytesFreed')::int8 > 0
    AS reported_positive_bytes_freed;

SELECT documentdb_core.bson_get_value_text((:'compact_result')::documentdb_core.bson, 'bytesFreed')::int8 =
       documentdb_core.bson_get_value_text((:'size_before')::documentdb_core.bson, 'total_rel_size')::int8 -
       documentdb_core.bson_get_value_text((:'size_after')::documentdb_core.bson, 'total_rel_size')::int8
    AS reported_delta_matches_measurement;

-- A second compact on an already compacted collection has nothing left to
-- reclaim, so the measured delta must be 0 rather than a stale estimate.
SELECT documentdb_api.compact('{"compact": "compact_delta_coll", "$db": "compact_db", "mode": "full"}');

-- freeSpaceTarget larger than the remaining bloat must suppress the vacuum.
SELECT documentdb_api.compact('{"compact": "compact_delta_coll", "$db": "compact_db", "mode": "full", "freeSpaceTargetMB": 1000000}');

-- The spec selects which metric groups the single storage stats worker
-- collects, so a spec that does not ask for the physical size must not report
-- it and one that does must.
SELECT documentdb_core.bson_get_value_text(
           documentdb_api_internal.get_storage_stats_worker(collection_id, '{ "bloatEstimate": true }'),
           'total_rel_size') IS NULL AS bloat_only_spec_omits_size,
       documentdb_core.bson_get_value_text(
           documentdb_api_internal.get_storage_stats_worker(collection_id, '{ "physicalSize": true }'),
           'total_rel_size') IS NOT NULL AS size_spec_reports_size,
       documentdb_core.bson_get_value_text(
           documentdb_api_internal.get_storage_stats_worker(collection_id, '{}'),
           'total_rel_size') IS NULL AS empty_spec_reports_nothing
    FROM documentdb_api_catalog.collections
    WHERE database_name = 'compact_db' AND collection_name = 'compact_delta_coll';

RESET documentdb.enableCompactVacuumFull;

SELECT documentdb_api.drop_collection('compact_db','compact_delta_coll');
