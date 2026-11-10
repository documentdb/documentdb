-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, public;
SET documentdb.next_collection_id TO 7600;
SET documentdb.next_collection_index_id TO 7600;

CREATE SCHEMA rum_cleanup_test;

-- Every workload has a disabled control and all three enabled combinations.
CREATE TEMP TABLE rum_cleanup_modes(name text, reclaim boolean, deletion boolean);
INSERT INTO rum_cleanup_modes VALUES
    ('off', false, false), ('reclaim', true, false),
    ('deletion', false, true), ('both', true, true);
SELECT * FROM rum_cleanup_modes ORDER BY name;
SELECT name, setting, reset_val, boot_val, context FROM pg_settings
WHERE name IN ('documentdb_rum.enable_insert_time_deletion',
               'documentdb_rum.enable_insert_time_posting_list_reclaim')
ORDER BY name;
SET documentdb_rum.enable_insert_time_deletion TO off;
SET documentdb_rum.enable_insert_time_posting_list_reclaim TO off;

CREATE FUNCTION rum_cleanup_test.index_name(coll text)
RETURNS text LANGUAGE sql AS $$
    SELECT 'documentdb_data.documents_rum_index_' || index_id
    FROM documentdb_api_catalog.collection_indexes
    WHERE collection_id = (
        SELECT collection_id FROM documentdb_api_catalog.collections
        WHERE database_name = 'insert_cleanup' AND collection_name = coll)
    ORDER BY index_id DESC LIMIT 1;
$$;

CREATE FUNCTION rum_cleanup_test.entries(coll text)
RETURNS TABLE(blockno int, value jsonb) LANGUAGE sql AS $$
    SELECT b, e
    FROM (SELECT rum_cleanup_test.index_name(coll) AS idx) names,
         LATERAL generate_series(1,
             (pg_relation_size(idx::regclass) / current_setting('block_size')::int - 1)::int) b,
         LATERAL documentdb_api_internal.documentdb_rum_page_get_entries(
             public.get_raw_page(idx, b), idx::regclass) e
    WHERE documentdb_api_internal.documentdb_rum_page_get_stats(
        public.get_raw_page(idx, b))->>'flagsStr' = 'LEAF';
$$;

-- Use the physical extent: metapage page counts are not refreshed after inserts.
CREATE FUNCTION rum_cleanup_test.count_leaf_pages(coll text, want_data boolean)
RETURNS bigint LANGUAGE sql AS $$
    SELECT count(*)
    FROM (SELECT rum_cleanup_test.index_name(coll) AS idx) names,
         LATERAL generate_series(1,
             (pg_relation_size(idx::regclass) / current_setting('block_size')::int - 1)::int) b
    WHERE documentdb_api_internal.documentdb_rum_page_get_stats(
        public.get_raw_page(idx, b))->>'flagsStr' LIKE '%LEAF%'
      AND (documentdb_api_internal.documentdb_rum_page_get_stats(
        public.get_raw_page(idx, b))->>'flagsStr' LIKE '%DATA%') = want_data;
$$;

CREATE FUNCTION rum_cleanup_test.count_rows(
    coll text, predicate text DEFAULT '{ "a": { "$exists": true } }')
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    result bigint;
BEGIN
    EXECUTE format(
        'SELECT count(*) FROM (SELECT document FROM bson_aggregation_find(''insert_cleanup'', %L::bson)) q',
        format('{ "find": "%s", "filter": %s }', coll, predicate))
    INTO result;
    RETURN result;
END;
$$;

CREATE FUNCTION rum_cleanup_test.create_fixture(coll text, full_page boolean)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    cid bigint;
BEGIN
    PERFORM documentdb_api.create_collection('insert_cleanup', coll);
    SELECT collection_id INTO cid FROM documentdb_api_catalog.collections
    WHERE database_name = 'insert_cleanup' AND collection_name = coll;
    EXECUTE format('ALTER TABLE documentdb_data.documents_%s SET (autovacuum_enabled = off)', cid);
    IF full_page THEN
        PERFORM documentdb_api.insert_one('insert_cleanup', coll,
            format('{ "_id": %s, "a": [1, %s] }', i, 2 * i + 10)::bson)
        FROM generate_series(1, 900) i;
        PERFORM set_config('documentdb_rum.rum_default_page_fill_factor', '100', true);
    END IF;
    PERFORM documentdb_api_internal.create_indexes_non_concurrently('insert_cleanup',
        format('{ "createIndexes": "%s", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableCompositeTerm": true } ] }', coll)::bson, true);
END;
$$;

CREATE FUNCTION rum_cleanup_test.insert_with_flags(coll text, mode_name text, doc bson)
RETURNS bson LANGUAGE plpgsql AS $$
DECLARE
    flags record;
BEGIN
    SELECT reclaim, deletion INTO STRICT flags FROM rum_cleanup_modes WHERE name = mode_name;
    PERFORM set_config('documentdb_rum.enable_insert_time_posting_list_reclaim', flags.reclaim::text, true);
    PERFORM set_config('documentdb_rum.enable_insert_time_deletion', flags.deletion::text, true);
    RETURN documentdb_api.insert_one('insert_cleanup', coll, doc);
END;
$$;

CREATE TEMP TABLE rum_cleanup_cases AS
SELECT scenario, name AS mode, reclaim, deletion, scenario || '_' || name AS coll
FROM (VALUES ('list'), ('partial'), ('unhinted'), ('small'),
             ('page'), ('page_partial'), ('fresh'), ('fresh_unhinted')) s(scenario),
     rum_cleanup_modes;

-- Calibrate inline capacity rather than assuming a posting compression threshold.
SELECT rum_cleanup_test.create_fixture('capacity', false);
CREATE TEMP TABLE rum_cleanup_limits(capacity int, page_inserts int);
DO $$
BEGIN
    FOR i IN 1..3000 LOOP
        PERFORM documentdb_api.insert_one('insert_cleanup', 'capacity',
            format('{ "_id": %s, "a": [1, 2] }', i)::bson);
        IF rum_cleanup_test.count_leaf_pages('capacity', true) > 0 THEN
            INSERT INTO rum_cleanup_limits VALUES (i - 1, NULL);
            RETURN;
        END IF;
    END LOOP;
    RAISE EXCEPTION 'inline capacity was not reached';
END;
$$;
SELECT capacity > 900 AS calibrated_capacity FROM rum_cleanup_limits;

-- Multikey fixtures repeat heap TIDs across entries and the pending list.
-- Partial targets retain 50 live postings; their dead sibling supplies LP_DEAD.
SELECT rum_cleanup_test.create_fixture(coll, false)
FROM rum_cleanup_cases WHERE scenario IN ('list', 'partial', 'unhinted', 'small')
ORDER BY scenario, mode;
SELECT scenario, mode, count(documentdb_api.insert_one('insert_cleanup', coll,
    format('{ "_id": %s, "a": [1, %s] }', i,
        CASE WHEN scenario = 'partial' AND i > capacity - 50 THEN 3 ELSE 2 END)::bson))
    = CASE WHEN scenario = 'small' THEN 1 ELSE capacity END AS filled_inline_list
FROM rum_cleanup_cases, rum_cleanup_limits,
     LATERAL generate_series(1, CASE WHEN scenario = 'small' THEN 1 ELSE capacity END) i
WHERE scenario IN ('list', 'partial', 'unhinted', 'small')
GROUP BY scenario, mode, capacity ORDER BY scenario, mode;
SELECT scenario, mode, count(*) > 0
    AND bool_and(value->>'entryType' = 'postingList') AS starts_inline
FROM rum_cleanup_cases CROSS JOIN LATERAL rum_cleanup_test.entries(coll)
WHERE scenario IN ('list', 'partial', 'unhinted', 'small')
GROUP BY scenario, mode ORDER BY scenario, mode;
SELECT documentdb_api.delete('insert_cleanup',
    format('{ "delete": "%s", "deletes": [ { "q": %s, "limit": 0 } ] }', coll,
        CASE WHEN scenario = 'partial' THEN format('{ "_id": { "$lte": %s } }', capacity - 50)
             ELSE '{}' END)::bson) IS NOT NULL AS deleted_old_rows
FROM rum_cleanup_cases, rum_cleanup_limits
WHERE scenario IN ('list', 'partial', 'unhinted', 'small') ORDER BY scenario, mode;
CALL documentdb_test_helpers.wait_for_vacuum_horizon();
SELECT format('VACUUM (FREEZE ON, INDEX_CLEANUP OFF) documentdb_data.documents_%s', collection_id)
FROM documentdb_api_catalog.collections JOIN rum_cleanup_cases ON collection_name = coll
WHERE database_name = 'insert_cleanup' AND scenario IN ('list', 'partial', 'small')
ORDER BY scenario, mode \gexec

SET documentdb.forceDisableSeqScan TO on;
SET documentdb_rum.enable_support_dead_index_items TO on;
SELECT scenario, mode, rum_cleanup_test.count_rows(coll)
    = CASE WHEN scenario = 'partial' THEN 50 ELSE 0 END AS expected_survivors
FROM rum_cleanup_cases WHERE scenario IN ('list', 'partial', 'small') ORDER BY scenario, mode;
SELECT scenario, mode, rum_cleanup_test.count_rows(coll)
    = CASE WHEN scenario = 'partial' THEN 50 ELSE 0 END AS expected_survivors
FROM rum_cleanup_cases WHERE scenario IN ('list', 'partial', 'small') ORDER BY scenario, mode;
RESET documentdb_rum.enable_support_dead_index_items;
SELECT scenario, mode, count(*) > 0 AND
    CASE WHEN scenario = 'unhinted' THEN bool_and((value->>'entryFlags')::int = 1)
         WHEN scenario = 'partial' THEN bool_or((value->>'entryFlags')::int = 3)
                                   AND bool_or((value->>'entryFlags')::int = 1)
         ELSE bool_and((value->>'entryFlags')::int = 3) END AS expected_dead_hints
FROM rum_cleanup_cases CROSS JOIN LATERAL rum_cleanup_test.entries(coll)
WHERE scenario IN ('list', 'partial', 'unhinted', 'small')
GROUP BY scenario, mode ORDER BY scenario, mode;

SELECT scenario, mode, rum_cleanup_test.insert_with_flags(coll, mode,
    format('{ "_id": 10000, "a": [1, %s] }',
        CASE WHEN scenario = 'partial' THEN 3 ELSE 2 END)::bson) IS NOT NULL AS inserted
FROM rum_cleanup_cases WHERE scenario IN ('list', 'partial', 'unhinted', 'small')
ORDER BY scenario, mode;
CREATE TEMP TABLE rum_cleanup_promoted AS
SELECT scenario, value->>'firstEntry' AS key, value->>'attrNumber' AS attnum
FROM rum_cleanup_cases CROSS JOIN LATERAL rum_cleanup_test.entries(coll)
WHERE scenario IN ('list', 'partial') AND mode = 'off'
    AND value->>'entryType' = 'postingTree';
SELECT scenario, count(*) > 0 AS disabled_baseline_promotes
FROM rum_cleanup_promoted GROUP BY scenario ORDER BY scenario;
SELECT scenario, mode, (rum_cleanup_test.count_leaf_pages(coll, true) > 0)
    = (scenario = 'unhinted' OR (scenario IN ('list', 'partial') AND NOT reclaim))
    AS expected_promotion
FROM rum_cleanup_cases WHERE scenario IN ('list', 'partial', 'unhinted', 'small')
ORDER BY scenario, mode;
-- Each scenario needs its own control because fully dead sibling keys can disappear.
SELECT c.scenario, mode, count(*) = (
    SELECT count(*) FROM rum_cleanup_promoted t WHERE t.scenario = c.scenario)
    AND count(*) > 0 AND bool_and(value->>'entryType' = 'postingList'
    AND (value->>'numPostings')::int = CASE WHEN c.scenario = 'partial' THEN 51 ELSE 1 END
    AND (value->>'entryFlags')::int = 1) AS pending_postings_cleaned
FROM rum_cleanup_cases c CROSS JOIN LATERAL rum_cleanup_test.entries(coll) e
JOIN rum_cleanup_promoted t
    ON t.scenario = c.scenario
    AND e.value->>'firstEntry' = t.key AND e.value->>'attrNumber' = t.attnum
WHERE c.scenario IN ('list', 'partial') AND reclaim
GROUP BY c.scenario, mode ORDER BY c.scenario, mode;
-- LP_DEAD alone does not trigger cleanup when both tuple and page have room.
SELECT mode, count(*) > 0 AND bool_and((value->>'numPostings')::int = 2
    AND (value->>'entryFlags')::int = 1) AS no_pressure_revives_without_reclaim
FROM rum_cleanup_cases CROSS JOIN LATERAL rum_cleanup_test.entries(coll)
WHERE scenario = 'small' GROUP BY mode ORDER BY mode;
SELECT scenario, mode,
    rum_cleanup_test.count_rows(coll) = CASE WHEN scenario = 'partial' THEN 51 ELSE 1 END AS live_rows,
    rum_cleanup_test.count_rows(coll, '{ "a": 1, "_id": 10000 }') = 1 AS incoming_present,
    rum_cleanup_test.count_rows(coll, '{ "a": 1, "_id": 1 }') = 0 AS deleted_absent,
    rum_cleanup_test.count_rows(coll, format('{ "a": 1, "_id": %s }', capacity))
        = CASE WHEN scenario = 'partial' THEN 1 ELSE 0 END AS survivor_preserved
FROM rum_cleanup_cases, rum_cleanup_limits
WHERE scenario IN ('list', 'partial', 'unhinted', 'small') ORDER BY scenario, mode;
RESET documentdb.forceDisableSeqScan;

-- Calibrate page pressure with an inline replacement, then replay that prefix.
-- The same full leaves also exercise fresh keys and the no-LP_DEAD negative case.
SELECT rum_cleanup_test.create_fixture('page_capacity', true);
SELECT rum_cleanup_test.create_fixture(coll, true)
FROM rum_cleanup_cases WHERE scenario IN ('page', 'page_partial', 'fresh', 'fresh_unhinted') ORDER BY scenario, mode;
SELECT documentdb_api.delete('insert_cleanup',
    format('{ "delete": "%s", "deletes": [ { "q": { "_id": { "$gte": 2 } }, "limit": 0 } ] }', collection_name)::bson) IS NOT NULL
FROM documentdb_api_catalog.collections
WHERE database_name = 'insert_cleanup'
  AND (collection_name = 'page_capacity' OR collection_name IN (
      SELECT coll FROM rum_cleanup_cases WHERE scenario IN ('page', 'page_partial', 'fresh', 'fresh_unhinted')))
ORDER BY collection_name;
SELECT format('VACUUM (FREEZE ON, INDEX_CLEANUP OFF) documentdb_data.documents_%s', collection_id)
FROM documentdb_api_catalog.collections
WHERE database_name = 'insert_cleanup'
  AND (collection_name = 'page_capacity' OR collection_name IN (
      SELECT coll FROM rum_cleanup_cases WHERE scenario IN ('page', 'page_partial', 'fresh', 'fresh_unhinted')))
ORDER BY collection_name \gexec
DO $$
DECLARE
    initial_size bigint := pg_relation_size(rum_cleanup_test.index_name('page_capacity')::regclass);
BEGIN
    FOR i IN 1..300 LOOP
        PERFORM documentdb_api.insert_one('insert_cleanup', 'page_capacity',
            format('{ "_id": %s, "a": [1] }', 10000 + i)::bson);
        IF pg_relation_size(rum_cleanup_test.index_name('page_capacity')::regclass) > initial_size THEN
            UPDATE rum_cleanup_limits SET page_inserts = i;
            RETURN;
        END IF;
    END LOOP;
    RAISE EXCEPTION 'page-space pressure was not reached';
END;
$$;
SELECT page_inserts BETWEEN 1 AND 300 AS calibrated_page_pressure FROM rum_cleanup_limits;
SELECT scenario, mode, count(documentdb_api.insert_one('insert_cleanup', coll,
    format('{ "_id": %s, "a": [1] }', 10000 + i)::bson)) = page_inserts - 1 AS replayed_prefix
FROM rum_cleanup_cases, rum_cleanup_limits, LATERAL generate_series(1, page_inserts - 1) i
WHERE scenario IN ('page', 'page_partial', 'fresh', 'fresh_unhinted')
GROUP BY scenario, mode, page_inserts ORDER BY scenario, mode;
SELECT documentdb_api.delete('insert_cleanup',
    format('{ "delete": "%s", "deletes": [ { "q": %s, "limit": 0 } ] }', coll,
        CASE WHEN scenario = 'page_partial' THEN '{ "_id": { "$gte": 2 } }' ELSE '{}' END)::bson) IS NOT NULL
FROM rum_cleanup_cases WHERE scenario IN ('page', 'page_partial', 'fresh', 'fresh_unhinted') ORDER BY scenario, mode;
SELECT format('VACUUM (FREEZE ON, INDEX_CLEANUP OFF) documentdb_data.documents_%s', collection_id)
FROM documentdb_api_catalog.collections JOIN rum_cleanup_cases ON collection_name = coll
WHERE database_name = 'insert_cleanup' AND scenario IN ('page', 'page_partial', 'fresh', 'fresh_unhinted')
ORDER BY scenario, mode \gexec
SET documentdb.forceDisableSeqScan TO on;
SET documentdb_rum.enable_support_dead_index_items TO on;
SELECT scenario, mode, rum_cleanup_test.count_rows(coll)
    = CASE WHEN scenario = 'page_partial' THEN 1 ELSE 0 END AS expected_survivors
FROM rum_cleanup_cases WHERE scenario IN ('page', 'page_partial', 'fresh') ORDER BY scenario, mode;
SELECT scenario, mode, rum_cleanup_test.count_rows(coll)
    = CASE WHEN scenario = 'page_partial' THEN 1 ELSE 0 END AS expected_survivors
FROM rum_cleanup_cases WHERE scenario IN ('page', 'page_partial', 'fresh') ORDER BY scenario, mode;
RESET documentdb_rum.enable_support_dead_index_items;
SELECT scenario, mode, count(*) > 0 AND
    CASE WHEN scenario = 'fresh_unhinted' THEN bool_and((value->>'entryFlags')::int = 1)
         ELSE bool_or((value->>'entryFlags')::int = 3) END AS expected_dead_hints
FROM rum_cleanup_cases CROSS JOIN LATERAL rum_cleanup_test.entries(coll)
WHERE scenario IN ('page', 'page_partial', 'fresh', 'fresh_unhinted')
GROUP BY scenario, mode ORDER BY scenario, mode;
CREATE TEMP TABLE rum_cleanup_targets AS
SELECT coll, value->>'firstEntry' AS key, value->>'attrNumber' AS attnum,
       (value->>'numPostings')::int AS old_count
FROM rum_cleanup_cases CROSS JOIN LATERAL rum_cleanup_test.entries(coll)
WHERE scenario IN ('page', 'page_partial') AND (value->>'numPostings')::int > 1;
SELECT scenario, mode, count(*) > 0 AND bool_and((value->>'entryFlags')::int
    = CASE WHEN scenario = 'page_partial' THEN 1 ELSE 3 END) AS expected_target_hints
FROM rum_cleanup_cases CROSS JOIN LATERAL rum_cleanup_test.entries(coll)
WHERE scenario IN ('page', 'page_partial') AND (value->>'numPostings')::int > 1
GROUP BY scenario, mode ORDER BY scenario, mode;
CREATE TEMP TABLE rum_cleanup_sizes AS
SELECT coll, rum_cleanup_test.count_leaf_pages(coll, false) AS leaves,
       pg_relation_size(rum_cleanup_test.index_name(coll)::regclass) AS bytes,
       (SELECT count(*) FROM rum_cleanup_test.entries(coll)) AS entry_count
FROM rum_cleanup_cases WHERE scenario IN ('page', 'page_partial', 'fresh', 'fresh_unhinted');

SELECT scenario, mode, rum_cleanup_test.insert_with_flags(coll, mode,
    format('{ "_id": %s, "a": [%s] }', 10000 + page_inserts,
        CASE WHEN scenario IN ('page', 'page_partial') THEN 1 ELSE 2 END)::bson) IS NOT NULL AS inserted
FROM rum_cleanup_cases, rum_cleanup_limits
WHERE scenario IN ('page', 'page_partial', 'fresh', 'fresh_unhinted') ORDER BY scenario, mode;
SELECT scenario, mode,
    (rum_cleanup_test.count_leaf_pages(coll, false) > leaves)
        = (NOT deletion OR scenario = 'fresh_unhinted') AS expected_split,
    (pg_relation_size(rum_cleanup_test.index_name(coll)::regclass) > bytes)
        = (NOT deletion OR scenario = 'fresh_unhinted') AS expected_growth,
    rum_cleanup_test.count_leaf_pages(coll, true) = 0 AS stays_inline
FROM rum_cleanup_cases JOIN rum_cleanup_sizes USING (coll) ORDER BY scenario, mode;
-- Partially live targets retain dead postings outside the selected heap blocks.
SELECT scenario, mode, count(*) = (SELECT count(*) FROM rum_cleanup_targets t WHERE t.coll = c.coll)
    AND count(*) > 0 AND bool_and(value->>'entryType' = 'postingList'
    AND CASE WHEN NOT deletion THEN (value->>'numPostings')::int = old_count + 1
             WHEN scenario = 'page_partial' THEN (value->>'numPostings')::int > 2
                 AND (value->>'numPostings')::int < old_count + 1
             ELSE (value->>'numPostings')::int = 1 END
    AND (value->>'entryFlags')::int = 1) AS expected_pending_postings
FROM rum_cleanup_cases c JOIN rum_cleanup_targets t USING (coll)
CROSS JOIN LATERAL rum_cleanup_test.entries(coll) e
WHERE e.value->>'firstEntry' = t.key AND e.value->>'attrNumber' = t.attnum
GROUP BY scenario, mode, deletion, c.coll ORDER BY scenario, mode;
SELECT scenario, mode,
    ((SELECT count(*) FROM rum_cleanup_test.entries(coll)) < entry_count)
        = (deletion AND scenario <> 'fresh_unhinted') AS dead_neighbors_reclaimed
FROM rum_cleanup_cases JOIN rum_cleanup_sizes USING (coll)
ORDER BY scenario, mode;
SELECT scenario, mode, rum_cleanup_test.count_rows(coll)
        = CASE WHEN scenario = 'page_partial' THEN 2 ELSE 1 END AS live_rows,
    rum_cleanup_test.count_rows(coll,
        format('{ "a": %s, "_id": %s }', CASE WHEN scenario IN ('page', 'page_partial') THEN 1 ELSE 2 END,
            10000 + page_inserts)) = 1 AS incoming_present,
    rum_cleanup_test.count_rows(coll, '{ "a": 14 }') = 0 AS deleted_key_absent,
    rum_cleanup_test.count_rows(coll, '{ "a": 12 }')
        = CASE WHEN scenario = 'page_partial' THEN 1 ELSE 0 END AS survivor_preserved
FROM rum_cleanup_cases, rum_cleanup_limits
WHERE scenario IN ('page', 'page_partial', 'fresh', 'fresh_unhinted') ORDER BY scenario, mode;

-- Only the replacement target is dead. Cleanup must prune it without changing a neighbor.
INSERT INTO rum_cleanup_cases
SELECT 'pending_only', name, reclaim, deletion, 'pending_only_' || name
FROM rum_cleanup_modes;
SELECT rum_cleanup_test.create_fixture('pending_only_capacity', false);
SELECT documentdb_api.insert_one('insert_cleanup', 'pending_only_capacity', '{ "_id": 0, "a": 2 }') IS NOT NULL;
CREATE TEMP TABLE rum_pending_only_limits(capacity int);
DO $$
BEGIN
    FOR i IN 1..3000 LOOP
        PERFORM documentdb_api.insert_one('insert_cleanup', 'pending_only_capacity',
            format('{ "_id": %s, "a": 1 }', i)::bson);
        IF rum_cleanup_test.count_leaf_pages('pending_only_capacity', true) > 0 THEN
            INSERT INTO rum_pending_only_limits VALUES (i - 1);
            RETURN;
        END IF;
    END LOOP;
    RAISE EXCEPTION 'pending-only inline capacity was not reached';
END;
$$;
SELECT capacity > 900 AS calibrated_pending_only_capacity FROM rum_pending_only_limits;
SELECT rum_cleanup_test.create_fixture(coll, false)
FROM rum_cleanup_cases WHERE scenario = 'pending_only' ORDER BY mode;
SELECT documentdb_api.insert_one('insert_cleanup', coll, '{ "_id": 0, "a": 2 }') IS NOT NULL
FROM rum_cleanup_cases WHERE scenario = 'pending_only' ORDER BY mode;
SELECT mode, count(documentdb_api.insert_one('insert_cleanup', coll,
    format('{ "_id": %s, "a": 1 }', i)::bson)) = capacity AS filled_target
FROM rum_cleanup_cases, rum_pending_only_limits, LATERAL generate_series(1, capacity) i
WHERE scenario = 'pending_only' GROUP BY mode, capacity ORDER BY mode;
SELECT documentdb_api.delete('insert_cleanup',
    format('{ "delete": "%s", "deletes": [ { "q": { "a": 1 }, "limit": 0 } ] }', coll)::bson) IS NOT NULL
FROM rum_cleanup_cases WHERE scenario = 'pending_only' ORDER BY mode;
SELECT format('VACUUM (FREEZE ON, INDEX_CLEANUP OFF) documentdb_data.documents_%s', collection_id)
FROM documentdb_api_catalog.collections JOIN rum_cleanup_cases ON collection_name = coll
WHERE database_name = 'insert_cleanup' AND scenario = 'pending_only' ORDER BY mode \gexec
SET documentdb_rum.enable_support_dead_index_items TO on;
SELECT mode, rum_cleanup_test.count_rows(coll, '{ "a": 1 }') = 0 AS target_rows_dead
FROM rum_cleanup_cases WHERE scenario = 'pending_only' ORDER BY mode;
SELECT mode, rum_cleanup_test.count_rows(coll, '{ "a": 1 }') = 0 AS target_rows_dead
FROM rum_cleanup_cases WHERE scenario = 'pending_only' ORDER BY mode;
RESET documentdb_rum.enable_support_dead_index_items;
CREATE TEMP TABLE rum_pending_only_before AS
SELECT coll, value FROM rum_cleanup_cases CROSS JOIN LATERAL rum_cleanup_test.entries(coll)
WHERE scenario = 'pending_only';
SELECT mode, rum_cleanup_test.count_leaf_pages(coll, false) = 1 AND count(*) = 2
    AND bool_and(value->>'entryType' = 'postingList')
    AND count(*) FILTER (WHERE (value->>'entryFlags')::int = 3
        AND (value->>'numPostings')::int = capacity) = 1
    AND count(*) FILTER (WHERE (value->>'entryFlags')::int = 1
        AND (value->>'numPostings')::int = 1) = 1 AS only_target_dead_on_page
FROM rum_cleanup_cases JOIN rum_pending_only_before USING (coll), rum_pending_only_limits
GROUP BY mode, coll, capacity ORDER BY mode;

SELECT mode, rum_cleanup_test.insert_with_flags(coll, mode, '{ "_id": 10000, "a": 1 }') IS NOT NULL AS inserted
FROM rum_cleanup_cases WHERE scenario = 'pending_only' ORDER BY mode;
SELECT mode, count(*) = 1 AND bool_and((e.value->>'entryFlags')::int = 1
    AND e.value->>'entryType' = CASE WHEN reclaim THEN 'postingList' ELSE 'postingTree' END
    AND (e.value->>'numPostings')::int = CASE WHEN reclaim THEN 1 ELSE -1 END) AS expected_pending_result
FROM rum_cleanup_cases JOIN rum_pending_only_before b USING (coll)
CROSS JOIN LATERAL rum_cleanup_test.entries(coll) e
WHERE (b.value->>'entryFlags')::int = 3
  AND e.value->>'firstEntry' = b.value->>'firstEntry'
  AND e.value->>'attrNumber' = b.value->>'attrNumber'
GROUP BY mode ORDER BY mode;
SELECT mode, count(*) = 1 AND bool_and(e.value = b.value) AS neighbor_tuple_unchanged
FROM rum_cleanup_cases JOIN rum_pending_only_before b USING (coll)
CROSS JOIN LATERAL rum_cleanup_test.entries(coll) e
WHERE (b.value->>'entryFlags')::int = 1
  AND e.value->>'firstEntry' = b.value->>'firstEntry'
  AND e.value->>'attrNumber' = b.value->>'attrNumber'
GROUP BY mode ORDER BY mode;
SELECT mode, (SELECT count(*) FROM rum_cleanup_test.entries(coll)) = 2 AS no_entry_deleted,
    rum_cleanup_test.count_rows(coll) = 2 AS live_rows,
    rum_cleanup_test.count_rows(coll, '{ "a": 1, "_id": 10000 }') = 1 AS incoming_present,
    rum_cleanup_test.count_rows(coll, '{ "a": 1, "_id": 1 }') = 0 AS deleted_absent,
    rum_cleanup_test.count_rows(coll, '{ "a": 2, "_id": 0 }') = 1 AS neighbor_row_preserved
FROM rum_cleanup_cases WHERE scenario = 'pending_only' ORDER BY mode;

-- Exercise retained boundaries on non-rightmost leaves, not just a leaf root.
RESET documentdb.forceDisableSeqScan;
CREATE FUNCTION rum_cleanup_test.index_term_to_bson(bytea)
RETURNS bson LANGUAGE c
AS '$libdir/pg_documentdb', 'gin_bson_index_term_to_bson';

CREATE FUNCTION rum_cleanup_test.create_boundary_fixture(coll text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    cid bigint;
BEGIN
    PERFORM documentdb_api.create_collection('insert_cleanup', coll);
    SELECT collection_id INTO cid FROM documentdb_api_catalog.collections
    WHERE database_name = 'insert_cleanup' AND collection_name = coll;
    EXECUTE format('ALTER TABLE documentdb_data.documents_%s SET (autovacuum_enabled = off)', cid);
    PERFORM documentdb_api.insert_one('insert_cleanup', coll,
        bson_build_document('_id', 2 * i + j, 'a', lpad(i::text, 6, '0') ||
            (SELECT left(string_agg(md5(i::text || ':' || salt::text), ''), 600)
             FROM generate_series(1, 19) salt)))
    FROM generate_series(1, 150) i, generate_series(-1, 0) j ORDER BY i, j;
    PERFORM set_config('documentdb_rum.rum_default_page_fill_factor', '100', true);
    PERFORM documentdb_api_internal.create_indexes_non_concurrently('insert_cleanup',
        format('{ "createIndexes": "%s", "indexes": [ { "key": { "a": 1 }, "name": "a_1", "enableCompositeTerm": true } ] }', coll)::bson, true);
END;
$$;

CREATE TEMP TABLE rum_boundary_cases AS
SELECT mode, target_fence, partial, false AS calibration,
       format('boundary_%s_%s_%s', target_fence, partial, mode) AS coll,
       NULL::jsonb AS fence, NULL::jsonb AS target,
       NULL::text AS fence_key, NULL::text AS target_key,
       NULL::int AS page_inserts, NULL::bigint AS leaves
FROM (SELECT name AS mode FROM rum_cleanup_modes WHERE name IN ('off', 'deletion')) m,
     (VALUES (false), (true)) t(target_fence), (VALUES (false), (true)) p(partial);
INSERT INTO rum_boundary_cases(mode, target_fence, partial, calibration, coll)
VALUES ('off', false, false, true, 'boundary_capacity'),
       ('off', true, false, true, 'boundary_target_capacity');
SELECT count(rum_cleanup_test.create_boundary_fixture(coll)) = 10 AS boundary_fixtures_created
FROM rum_boundary_cases;
DO $$
DECLARE
    c record;
    boundary record;
    target_entry jsonb;
BEGIN
    FOR c IN SELECT * FROM rum_boundary_cases ORDER BY coll LOOP
        SELECT blockno, value INTO STRICT boundary
        FROM rum_cleanup_test.entries(c.coll)
        WHERE documentdb_api_internal.documentdb_rum_page_get_stats(
            public.get_raw_page(rum_cleanup_test.index_name(c.coll), blockno))->>'rightLink' IS NOT NULL
          AND (value->>'offset')::int > 2
        ORDER BY blockno, (value->>'offset')::int DESC LIMIT 1;
        SELECT value INTO STRICT target_entry FROM rum_cleanup_test.entries(c.coll)
        WHERE blockno = boundary.blockno
        ORDER BY (value->>'offset')::int DESC LIMIT 1 OFFSET CASE WHEN c.target_fence THEN 0 ELSE 1 END;
        UPDATE rum_boundary_cases SET fence = boundary.value, target = target_entry,
            fence_key = rum_cleanup_test.index_term_to_bson((boundary.value->>'firstEntry')::bytea)->>'$',
            target_key = rum_cleanup_test.index_term_to_bson((target_entry->>'firstEntry')::bytea)->>'$'
        WHERE coll = c.coll;
    END LOOP;
END;
$$;
SELECT bool_and(length(fence_key) = 606 AND length(target_key) = 606
    AND (target_fence = (fence_key = target_key))
    AND rum_cleanup_test.count_leaf_pages(coll, false) > 1) AS non_rightmost_boundaries_selected
FROM rum_boundary_cases;
DO $$
DECLARE
    c record;
    initial_size bigint;
BEGIN
    FOR c IN SELECT * FROM rum_boundary_cases WHERE calibration LOOP
        initial_size := pg_relation_size(rum_cleanup_test.index_name(c.coll)::regclass);
        FOR i IN 1..1000 LOOP
            PERFORM documentdb_api.insert_one('insert_cleanup', c.coll,
                bson_build_document('_id', 1000 + i, 'a', c.target_key));
            IF pg_relation_size(rum_cleanup_test.index_name(c.coll)::regclass) > initial_size THEN
                UPDATE rum_boundary_cases SET page_inserts = i WHERE target_fence = c.target_fence;
                EXIT;
            END IF;
        END LOOP;
    END LOOP;
END;
$$;
SELECT bool_and(page_inserts BETWEEN 1 AND 1000) AS boundary_pressure_calibrated
FROM rum_boundary_cases;
SELECT count(documentdb_api.insert_one('insert_cleanup', coll,
    bson_build_document('_id', 1000 + i, 'a', target_key))) > 0 AS boundary_prefix_replayed
FROM rum_boundary_cases, LATERAL generate_series(1, page_inserts - 1) i
WHERE NOT calibration;
SELECT count(documentdb_api.delete('insert_cleanup',
    format('{ "delete": "%s", "deletes": [ { "q": %s, "limit": 0 } ] }', coll,
        CASE WHEN partial THEN format('{ "_id": { "$ne": %s } }', 2 * left(fence_key, 6)::int)
             ELSE '{}' END)::bson)) = 8 AS boundary_rows_deleted
FROM rum_boundary_cases WHERE NOT calibration;
CALL documentdb_test_helpers.wait_for_vacuum_horizon();
SELECT format('VACUUM (FREEZE ON, INDEX_CLEANUP OFF) documentdb_data.documents_%s', collection_id)
FROM documentdb_api_catalog.collections JOIN rum_boundary_cases ON collection_name = coll
WHERE database_name = 'insert_cleanup' AND NOT calibration ORDER BY coll \gexec
SET documentdb.forceDisableSeqScan TO on;
SET documentdb_rum.enable_support_dead_index_items TO on;
SELECT bool_and(rum_cleanup_test.count_rows(coll) = partial::int) AS boundary_survivors
FROM rum_boundary_cases WHERE NOT calibration;
SELECT bool_and(rum_cleanup_test.count_rows(coll) = partial::int) AS boundary_survivors
FROM rum_boundary_cases WHERE NOT calibration;
RESET documentdb_rum.enable_support_dead_index_items;
UPDATE rum_boundary_cases c SET fence = e.value,
    leaves = rum_cleanup_test.count_leaf_pages(c.coll, false)
FROM rum_boundary_cases b CROSS JOIN LATERAL rum_cleanup_test.entries(b.coll) e
WHERE c.coll = b.coll AND NOT c.calibration
  AND e.value->>'firstEntry' = c.fence->>'firstEntry'
  AND e.value->>'attrNumber' = c.fence->>'attrNumber';
SELECT bool_and((fence->>'entryFlags')::int = CASE WHEN partial THEN 1 ELSE 3 END
    AND (fence->>'numPostings')::int > partial::int) AS boundary_has_dead_postings
FROM rum_boundary_cases WHERE NOT calibration;
SELECT count(rum_cleanup_test.insert_with_flags(coll, mode,
    bson_build_document('_id', 100000, 'a', target_key))) = 8 AS boundary_inserted
FROM rum_boundary_cases WHERE NOT calibration;
-- A partially live replacement boundary is not itself a source of probe blocks.
SELECT mode, target_fence, partial,
    count(*) = 1 AND bool_and(e.value->>'entryType' = 'postingList'
        AND CASE WHEN NOT m.deletion THEN (e.value->>'numPostings')::int =
                     (c.fence->>'numPostings')::int + target_fence::int
                 WHEN partial AND target_fence THEN (e.value->>'numPostings')::int > 2
                     AND (e.value->>'numPostings')::int < (c.fence->>'numPostings')::int + 1
                 ELSE (e.value->>'numPostings')::int = partial::int + target_fence::int END)
        AS boundary_postings_pruned,
    bool_and(NOT m.deletion OR (e.value->>'offset')::int = CASE WHEN target_fence THEN 1 ELSE 2 END)
        AS shifted_boundary_found,
    (rum_cleanup_test.count_leaf_pages(coll, false) > leaves) = NOT m.deletion AS expected_split
FROM rum_boundary_cases c JOIN rum_cleanup_modes m ON m.name = c.mode
CROSS JOIN LATERAL rum_cleanup_test.entries(coll) e
WHERE NOT calibration AND e.value->>'firstEntry' = c.fence->>'firstEntry'
  AND e.value->>'attrNumber' = c.fence->>'attrNumber'
GROUP BY mode, target_fence, partial, m.deletion, coll, leaves
ORDER BY mode, target_fence, partial;
SELECT bool_and(rum_cleanup_test.count_rows(coll) = 1 + partial::int
    AND rum_cleanup_test.count_rows(coll, '{ "_id": 100000, "a": { "$exists": true } }') = 1)
    AS boundary_live_rows_preserved
FROM rum_boundary_cases WHERE NOT calibration;
-- Revive an emptied boundary, then force more splits on both sides of the old separator.
SELECT count(rum_cleanup_test.insert_with_flags(coll, mode,
    bson_build_document('_id', 100001, 'a', fence_key))) = 8 AS boundary_reinserted
FROM rum_boundary_cases WHERE NOT calibration;
UPDATE rum_boundary_cases SET leaves = rum_cleanup_test.count_leaf_pages(coll, false)
WHERE NOT calibration;
SELECT count(rum_cleanup_test.insert_with_flags(coll, mode,
    bson_build_document('_id', 100001 + i, 'a',
        CASE WHEN i = 31 THEN fence_key || 'q'
             ELSE left(fence_key, 6) || '!' || lpad(i::text, 3, '0') || substr(fence_key, 7) END))) = 248
    AS boundary_neighbors_inserted
FROM rum_boundary_cases, generate_series(1, 31) i WHERE NOT calibration;
SELECT mode, target_fence, partial,
    rum_cleanup_test.count_leaf_pages(coll, false) > leaves AS split_again,
    rum_cleanup_test.count_rows(coll) = 33 + partial::int AS all_rows_found,
    rum_cleanup_test.count_rows(coll, format('{ "a": { "$gt": "%s" } }', fence_key)) = 1
        AS right_neighbor_found
FROM rum_boundary_cases WHERE NOT calibration ORDER BY mode, target_fence, partial;

RESET documentdb.forceDisableSeqScan;
RESET documentdb_rum.enable_insert_time_deletion;
RESET documentdb_rum.enable_insert_time_posting_list_reclaim;
SELECT documentdb_api.drop_collection('insert_cleanup', coll)
FROM rum_cleanup_cases ORDER BY scenario, mode;
SELECT documentdb_api.drop_collection('insert_cleanup', 'capacity');
SELECT documentdb_api.drop_collection('insert_cleanup', 'page_capacity');
SELECT documentdb_api.drop_collection('insert_cleanup', 'pending_only_capacity');
SELECT documentdb_api.drop_collection('insert_cleanup', coll) FROM rum_boundary_cases ORDER BY coll;
DROP TABLE rum_cleanup_modes, rum_cleanup_cases, rum_cleanup_limits,
    rum_cleanup_promoted, rum_cleanup_targets, rum_cleanup_sizes,
    rum_pending_only_limits, rum_pending_only_before, rum_boundary_cases;
DROP SCHEMA rum_cleanup_test CASCADE;
