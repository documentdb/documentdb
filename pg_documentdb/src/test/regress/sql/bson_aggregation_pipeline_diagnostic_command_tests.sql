SET search_path TO documentdb_api,documentdb_core;

SET documentdb.next_collection_id TO 6600;
SET documentdb.next_collection_index_id TO 6600;

SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('diagnostic_db', 'diag_coll1', FORMAT('{ "_id": %s, "a": %s }', i, i)::documentdb_core.bson) FROM generate_series(1, 1000) i) innerQuery;
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('diagnostic_db', 'diag_coll2', FORMAT('{ "_id": %s, "a": %s }', i, i)::documentdb_core.bson) FROM generate_series(1, 500) i) innerQuery;
SELECT COUNT(*) FROM (SELECT documentdb_api.insert_one('diagnostic_db', 'diag_coll3', FORMAT('{ "_id": %s, "a": %s }', i, i)::documentdb_core.bson) FROM generate_series(1, 100) i) innerQuery;

SELECT documentdb_api_internal.create_indexes_non_concurrently('diagnostic_db', '{ "createIndexes": "diag_coll2", "indexes": [ { "key": { "a": 1 }, "name": "a_1" }]}', TRUE);

-- analyze for determinism
ANALYZE documentdb_data.documents_6601;
ANALYZE documentdb_data.documents_6602;
ANALYZE documentdb_data.documents_6603;

-- coll_stats should work
SELECT documentdb_api.coll_stats('diagnostic_db', 'diag_coll1');
SELECT documentdb_api.coll_stats('diagnostic_db', 'diag_coll2');
SELECT documentdb_api.coll_stats('diagnostic_db', 'diag_coll3');

-- db_stats should work
SELECT documentdb_api.db_stats('diagnostic_db');

-- coll_stats via aggregation should work.
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('diagnostic_db', '{ "aggregate": "diag_coll1", "pipeline": [ { "$collStats": { "storageStats": {} }}]}');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('diagnostic_db', '{ "aggregate": "diag_coll2", "pipeline": [ { "$collStats": { "storageStats": {} }}]}');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('diagnostic_db', '{ "aggregate": "diag_coll3", "pipeline": [ { "$collStats": { "storageStats": {} }}]}');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('diagnostic_db', '{ "aggregate": "diag_coll1", "pipeline": [ { "$collStats": { "storageStats": { "scale": 0.5 } }}]}');

-- index_stats should work
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('diagnostic_db', '{ "aggregate": "diag_coll1", "pipeline": [ { "$indexStats": { }}, { "$project": { "accesses.since": 0 }}]}');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('diagnostic_db', '{ "aggregate": "diag_coll2", "pipeline": [ { "$indexStats": { }}, { "$project": { "accesses.since": 0 }}]}');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('diagnostic_db', '{ "aggregate": "diag_coll3", "pipeline": [ { "$indexStats": { }}, { "$project": { "accesses.since": 0 }}]}');

-- Explicitly disabling sampled sizes retains the legacy storage statistics.
SET documentdb.enable_avg_size_from_sample TO off;
SELECT documentdb_api_internal.coll_stats_aggregation('diagnostic_db', 'diag_coll3',
    '{"storageStats": {}}') OPERATOR(documentdb_api_catalog.@@)
    '{"storageStats.avg_doc_size_raw": {"$exists": false}, "storageStats.avgObjSizeStored": {"$exists": false}}'::documentdb_core.bson AS sampled_sizes_disabled;

-- Reset to the default-on behavior, including stored sizes for compressed documents.
RESET documentdb.enable_avg_size_from_sample;
SELECT documentdb_api.create_collection('diagnostic_db', 'diag_empty');
SELECT documentdb_api.insert_one('diagnostic_db', 'diag_sample',
    documentdb_core.bson_build_document('_id', 1, 'payload', repeat('x', 10000)));
SELECT documentdb_api.insert_one('diagnostic_db', 'diag_sample',
    documentdb_core.bson_build_document('_id', 2, 'payload', repeat('x', 10001)));

WITH expected AS (
    SELECT avg(length(document::bytea))::float8 AS raw_size,
        avg(pg_column_size(document))::float8 AS stored_size,
        count(*) AS doc_count
    FROM documentdb_data.documents_6605
)
SELECT documentdb_api_internal.coll_stats_aggregation('diagnostic_db', 'diag_sample',
    '{"storageStats": {}}') OPERATOR(documentdb_api_catalog.@@)
    documentdb_core.bson_build_document(
        'storageStats.avgObjSize', expected.raw_size,
        'storageStats.avg_doc_size_raw', '{"$exists": false}'::documentdb_core.bson,
        'storageStats.avgObjSizeStored', expected.stored_size,
        'storageStats.avg_doc_size_stored', '{"$exists": false}'::documentdb_core.bson,
        'storageStats.size', expected.raw_size * expected.doc_count) AS sampled_sizes_match,
    documentdb_api_internal.coll_stats_aggregation('diagnostic_db', 'diag_sample',
        '{"storageStats": {"scale": 1024}}') OPERATOR(documentdb_api_catalog.@@)
    documentdb_core.bson_build_document(
        'storageStats.avgObjSize', expected.raw_size,
        'storageStats.avgObjSizeStored', expected.stored_size,
        'storageStats.size', trunc(expected.raw_size * expected.doc_count / 1024)::bigint) AS scaled_sizes_match,
    documentdb_api.coll_stats('diagnostic_db', 'diag_sample') OPERATOR(documentdb_api_catalog.@@)
    documentdb_core.bson_build_document(
        'avgObjSize', expected.raw_size, 'avgObjSizeStored', expected.stored_size,
        'avg_doc_size_raw', '{"$exists": false}'::documentdb_core.bson,
        'size', expected.raw_size * expected.doc_count) AS command_sizes_match,
    expected.raw_size > expected.stored_size AS compressed_size_is_smaller
FROM expected;

SELECT documentdb_api_internal.coll_stats_aggregation('diagnostic_db', 'diag_empty',
    '{"storageStats": {}}') OPERATOR(documentdb_api_catalog.@@)
    '{"storageStats.avgObjSize": 0, "storageStats.avg_doc_size_raw": {"$exists": false}, "storageStats.avgObjSizeStored": 0}'::documentdb_core.bson AS empty_sample_sizes;

SELECT documentdb_api.insert_one('diagnostic_db', 'diag_coll1', '{"_id": 1001, "a": 1001}');
SELECT documentdb_api_internal.coll_stats_worker('diagnostic_db', 'diag_coll1', 2)
    OPERATOR(documentdb_api_catalog.@@) '{"doc_size_sample_count": 1000}'::documentdb_core.bson AS sample_is_bounded;
SELECT documentdb_api_internal.coll_stats_worker('diagnostic_db', 'diag_coll1', 1)
    OPERATOR(documentdb_api_catalog.@@) '{"avg_obj_size_sampled": {"$exists": false}, "avg_obj_size_stored": {"$exists": false}}'::documentdb_core.bson AS count_does_not_sample;
RESET documentdb.enable_avg_size_from_sample;

-- queryExecStats only accepts an empty document.
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('diagnostic_db',
    '{"aggregate": "diag_coll3", "pipeline": [{"$collStats": {"queryExecStats": true}}]}');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('diagnostic_db',
    '{"aggregate": "diag_coll3", "pipeline": [{"$collStats": {"queryExecStats": {"extra": 1}}}]}');

-- compactStats is independently requested with an empty document.
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('diagnostic_db',
    '{"aggregate": "diag_coll3", "pipeline": [{"$collStats": {"compactStats": true}}]}');
SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('diagnostic_db',
    '{"aggregate": "diag_coll3", "pipeline": [{"$collStats": {"compactStats": {"extra": 1}}}]}');

SET stats_fetch_consistency TO none;
VACUUM documentdb_data.documents_6603;
ANALYZE documentdb_data.documents_6603;
SELECT pg_stat_force_next_flush();

CREATE TEMP TABLE expected_query_exec_stats AS
SELECT seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
    last_vacuum, last_autovacuum, last_analyze, last_autoanalyze
FROM pg_catalog.pg_stat_user_tables
WHERE relid = 'documentdb_data.documents_6603'::regclass;

SELECT documentdb_api_internal.coll_stats_aggregation('diagnostic_db', 'diag_coll3',
    '{"queryExecStats": {}}') OPERATOR(documentdb_api_catalog.@@)
    documentdb_core.bson_build_document(
        'queryExecStats.collectionScans.count', stats.seq_scan,
        'queryExecStats.collectionScans.numDocs', stats.seq_tup_read,
        'queryExecStats.indexScans.count', coalesce(stats.idx_scan, 0),
        'queryExecStats.indexScans.numDocs', coalesce(stats.idx_tup_fetch, 0),
        'queryExecStats.collScan', '{"$exists": false}'::documentdb_core.bson,
        'queryExecStats.collScanNumDocs', '{"$exists": false}'::documentdb_core.bson,
        'queryExecStats.ixscan', '{"$exists": false}'::documentdb_core.bson,
        'queryExecStats.ixscanNumDocs', '{"$exists": false}'::documentdb_core.bson,
        'queryExecStats.lastCompact', '{"$exists": false}'::documentdb_core.bson,
        'queryExecStats.lastCompactStats', '{"$exists": false}'::documentdb_core.bson,
        'queryExecStats.lastAutoCompact', '{"$exists": false}'::documentdb_core.bson,
        'queryExecStats.lastAutoCompactStats', '{"$exists": false}'::documentdb_core.bson,
        'compactStats', '{"$exists": false}'::documentdb_core.bson) AS query_stats_match
FROM expected_query_exec_stats stats;

SELECT documentdb_api_internal.coll_stats_aggregation('diagnostic_db', 'diag_coll3',
    '{"compactStats": {}}') OPERATOR(documentdb_api_catalog.@@)
    documentdb_core.bson_build_document(
        'compactStats.lastCompact', ARRAY[greatest(stats.last_vacuum, stats.last_autovacuum)],
        'compactStats.lastCompactStats', ARRAY[greatest(stats.last_analyze, stats.last_autoanalyze)],
        'compactStats.lastAutoCompact', '{"$exists": false}'::documentdb_core.bson,
        'compactStats.lastAutoCompactStats', '{"$exists": false}'::documentdb_core.bson,
        'compactStats.collectionScans', '{"$exists": false}'::documentdb_core.bson,
        'compactStats.indexScans', '{"$exists": false}'::documentdb_core.bson,
        'queryExecStats', '{"$exists": false}'::documentdb_core.bson) AS compact_stats_match
FROM expected_query_exec_stats stats;

SELECT documentdb_api.create_collection('diagnostic_db', 'diag_query_stats_empty');
SELECT documentdb_api_internal.coll_stats_aggregation('diagnostic_db', 'diag_query_stats_empty',
    '{"queryExecStats": {}}') OPERATOR(documentdb_api_catalog.@@)
    '{"queryExecStats.collectionScans.count": 0, "queryExecStats.collectionScans.numDocs": 0, "queryExecStats.indexScans.count": 0, "queryExecStats.indexScans.numDocs": 0, "queryExecStats.lastCompact": {"$exists": false}, "queryExecStats.lastCompactStats": {"$exists": false}, "compactStats": {"$exists": false}}'::documentdb_core.bson AS empty_query_stats;
SELECT documentdb_api_internal.coll_stats_aggregation('diagnostic_db', 'diag_query_stats_empty',
    '{"compactStats": {}}') OPERATOR(documentdb_api_catalog.@@)
    '{"compactStats.lastCompact": [null], "compactStats.lastCompactStats": [null], "queryExecStats": {"$exists": false}}'::documentdb_core.bson AS empty_compact_stats;

WITH stats AS MATERIALIZED (
    SELECT document FROM documentdb_api_catalog.bson_aggregation_pipeline('diagnostic_db',
        '{"aggregate": "diag_empty", "pipeline": [{"$collStats": {"count": {}, "storageStats": {}, "queryExecStats": {}, "compactStats": {}}}]}')
)
SELECT document OPERATOR(documentdb_api_catalog.@@)
    '{"ns": "diagnostic_db.diag_empty", "count": 0, "storageStats.count": 0, "queryExecStats.collectionScans.count": {"$gte": 0}, "queryExecStats.indexScans.count": {"$gte": 0}, "queryExecStats.lastCompact": {"$exists": false}, "queryExecStats.lastCompactStats": {"$exists": false}, "compactStats.lastCompact": [null], "compactStats.lastCompactStats": [null]}'::documentdb_core.bson AS combined_stats
FROM stats;
DROP TABLE expected_query_exec_stats;
RESET stats_fetch_consistency;