SET search_path TO documentdb_api,documentdb_core,documentdb_api_catalog;

SET documentdb.next_collection_id TO 1300;
SET documentdb.next_collection_index_id TO 1300;

-- set the rum fillfactor to 100
set documentdb_rum.rum_default_page_fill_factor to 100;

-- now create an empty index.
SELECT documentdb_api_internal.create_indexes_non_concurrently('filltest',
    '{ "createIndexes": "fillcoll1", "indexes": [ { "key": { "c": 1, "a": 1 }, "name": "a_1" }, { "key": { "c": 1, "b": 1 }, "name": "b_1" } ] }');

-- now insert 2000 docs into the collection. do it such that "a" is consistently monotonically increasing, and "b" is consistently decreasing.
SELECT COUNT(documentdb_api.insert_one('filltest', 'fillcoll1', bson_build_document('_id', i, 'a', i, 'b', 2000 - i, 'c', repeat('a', 1024)))) FROM generate_series(1, 2000) i;

\d documentdb_data.documents_1301

VACUUM (FREEZE ON, INDEX_CLEANUP ON) documentdb_data.documents_1301;

-- check the fillfactor of the index pages. "a_1" should be ~100, "b_1" should be ~50% since most of the inserts would be into internal pages.
WITH r1 AS (
    SELECT documentdb_api_internal.documentdb_rum_get_meta_page_info(public.get_raw_page('documentdb_data.documents_rum_index_1302', 0))->>'totalPages' AS total_pages),
r2 AS (SELECT documentdb_api_internal.documentdb_rum_page_get_stats(public.get_raw_page('documentdb_data.documents_rum_index_1302', i)) AS page_stats FROM generate_series(1, (SELECT total_pages::int4 FROM r1) - 1) i)
SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY (page_stats->>'nEntries')::int4) BETWEEN 115 and 125 FROM r2 WHERE page_stats->>'flagsStr' = 'LEAF';

WITH r1 AS (
    SELECT documentdb_api_internal.documentdb_rum_get_meta_page_info(public.get_raw_page('documentdb_data.documents_rum_index_1303', 0))->>'totalPages' AS total_pages),
r2 AS (SELECT documentdb_api_internal.documentdb_rum_page_get_stats(public.get_raw_page('documentdb_data.documents_rum_index_1303', i)) AS page_stats FROM generate_series(1, (SELECT total_pages::int4 FROM r1) - 1) i)
SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY (page_stats->>'nEntries')::int4) BETWEEN 55 AND 65 FROM r2 WHERE page_stats->>'flagsStr' = 'LEAF';

-- reindexing fixes it since serial build will do a sort and insert in order when fill factor is set.
set maintenance_work_mem to '1024';
REINDEX INDEX documentdb_data.documents_rum_index_1303;
WITH r1 AS (
    SELECT documentdb_api_internal.documentdb_rum_get_meta_page_info(public.get_raw_page('documentdb_data.documents_rum_index_1303', 0))->>'totalPages' AS total_pages),
r2 AS (SELECT documentdb_api_internal.documentdb_rum_page_get_stats(public.get_raw_page('documentdb_data.documents_rum_index_1303', i)) AS page_stats FROM generate_series(1, (SELECT total_pages::int4 FROM r1) - 1) i)
SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY (page_stats->>'nEntries')::int4) BETWEEN 115 and 125 FROM r2 WHERE page_stats->>'flagsStr' = 'LEAF';

-- however if the fill factor doesn't get set, reindex will lose it.
set documentdb_rum.enable_page_fill_factor to off;
REINDEX INDEX documentdb_data.documents_rum_index_1303;
WITH r1 AS (
    SELECT documentdb_api_internal.documentdb_rum_get_meta_page_info(public.get_raw_page('documentdb_data.documents_rum_index_1303', 0))->>'totalPages' AS total_pages),
r2 AS (SELECT documentdb_api_internal.documentdb_rum_page_get_stats(public.get_raw_page('documentdb_data.documents_rum_index_1303', i)) AS page_stats FROM generate_series(1, (SELECT total_pages::int4 FROM r1) - 1) i)
SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY (page_stats->>'nEntries')::int4) BETWEEN 55 AND 65 FROM r2 WHERE page_stats->>'flagsStr' = 'LEAF';

reset documentdb_rum.enable_page_fill_factor;

-- repeat with 50% fill factor
set documentdb_rum.rum_default_page_fill_factor to 50;
TRUNCATE documentdb_data.documents_1301;
SELECT COUNT(documentdb_api.insert_one('filltest', 'fillcoll1', bson_build_document('_id', i, 'a', i, 'b', 2000 - i, 'c', repeat('a', 1024)))) FROM generate_series(1, 2000) i;

VACUUM (FREEZE ON, INDEX_CLEANUP ON) documentdb_data.documents_1301;

-- check the fillfactor of the index pages. "a_1" should be ~50%, "b_1" should be ~50% since most of the inserts would be into non-tail pages.
WITH r1 AS (
    SELECT documentdb_api_internal.documentdb_rum_get_meta_page_info(public.get_raw_page('documentdb_data.documents_rum_index_1302', 0))->>'totalPages' AS total_pages),
r2 AS (SELECT documentdb_api_internal.documentdb_rum_page_get_stats(public.get_raw_page('documentdb_data.documents_rum_index_1302', i)) AS page_stats FROM generate_series(1, (SELECT total_pages::int4 FROM r1) - 1) i)
SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY (page_stats->>'nEntries')::int4) BETWEEN 55 AND 65 FROM r2 WHERE page_stats->>'flagsStr' = 'LEAF';

WITH r1 AS (
    SELECT documentdb_api_internal.documentdb_rum_get_meta_page_info(public.get_raw_page('documentdb_data.documents_rum_index_1303', 0))->>'totalPages' AS total_pages),
r2 AS (SELECT documentdb_api_internal.documentdb_rum_page_get_stats(public.get_raw_page('documentdb_data.documents_rum_index_1303', i)) AS page_stats FROM generate_series(1, (SELECT total_pages::int4 FROM r1) - 1) i)
SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY (page_stats->>'nEntries')::int4) BETWEEN 55 AND 65 FROM r2 WHERE page_stats->>'flagsStr' = 'LEAF';

-- reindexing recovers fill factor here since serial build will restore the sort.
set maintenance_work_mem to '1024';
REINDEX INDEX documentdb_data.documents_rum_index_1303;
WITH r1 AS (
    SELECT documentdb_api_internal.documentdb_rum_get_meta_page_info(public.get_raw_page('documentdb_data.documents_rum_index_1303', 0))->>'totalPages' AS total_pages),
r2 AS (SELECT documentdb_api_internal.documentdb_rum_page_get_stats(public.get_raw_page('documentdb_data.documents_rum_index_1303', i)) AS page_stats FROM generate_series(1, (SELECT total_pages::int4 FROM r1) - 1) i)
SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY (page_stats->>'nEntries')::int4) BETWEEN 55 AND 65 FROM r2 WHERE page_stats->>'flagsStr' = 'LEAF';

-- drop and create a fresh index (fresh indexes should also respect the fillfactor)
set documentdb_rum.rum_default_page_fill_factor to 100;
CALL documentdb_api.drop_indexes('filltest', '{ "dropIndexes": "fillcoll1", "index": "a_1" }');
CALL documentdb_api.drop_indexes('filltest', '{ "dropIndexes": "fillcoll1", "index": "b_1" }');

reset maintenance_work_mem;
SELECT documentdb_api_internal.create_indexes_non_concurrently('filltest',
    '{ "createIndexes": "fillcoll1", "indexes": [ { "key": { "c": 1, "a": 1 }, "name": "a_1" }, { "key": { "c": 1, "b": 1 }, "name": "b_1" } ] }', TRUE);

-- check the fill factor
WITH r1 AS (
    SELECT documentdb_api_internal.documentdb_rum_get_meta_page_info(public.get_raw_page('documentdb_data.documents_rum_index_1304', 0))->>'totalPages' AS total_pages),
r2 AS (SELECT documentdb_api_internal.documentdb_rum_page_get_stats(public.get_raw_page('documentdb_data.documents_rum_index_1304', i)) AS page_stats FROM generate_series(1, (SELECT total_pages::int4 FROM r1) - 1) i)
SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY (page_stats->>'nEntries')::int4) BETWEEN 115 and 125 FROM r2 WHERE page_stats->>'flagsStr' = 'LEAF';

WITH r1 AS (
    SELECT documentdb_api_internal.documentdb_rum_get_meta_page_info(public.get_raw_page('documentdb_data.documents_rum_index_1305', 0))->>'totalPages' AS total_pages),
r2 AS (SELECT documentdb_api_internal.documentdb_rum_page_get_stats(public.get_raw_page('documentdb_data.documents_rum_index_1305', i)) AS page_stats FROM generate_series(1, (SELECT total_pages::int4 FROM r1) - 1) i)
SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY (page_stats->>'nEntries')::int4) BETWEEN 115 and 125 FROM r2 WHERE page_stats->>'flagsStr' = 'LEAF';


-- test setting fillfactor via index options

-- set to invalid value (should fail)
ALTER INDEX documentdb_data.documents_rum_index_1304 SET (fill_factor = 5);
ALTER INDEX documentdb_data.documents_rum_index_1304 SET (fill_factor = 50);
REINDEX INDEX documentdb_data.documents_rum_index_1304;

-- check the fill factor
WITH r1 AS (
    SELECT documentdb_api_internal.documentdb_rum_get_meta_page_info(public.get_raw_page('documentdb_data.documents_rum_index_1304', 0))->>'totalPages' AS total_pages),
r2 AS (SELECT documentdb_api_internal.documentdb_rum_page_get_stats(public.get_raw_page('documentdb_data.documents_rum_index_1304', i)) AS page_stats FROM generate_series(1, (SELECT total_pages::int4 FROM r1) - 1) i)
SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY (page_stats->>'nEntries')::int4) BETWEEN 55 AND 65 FROM r2 WHERE page_stats->>'flagsStr' = 'LEAF';