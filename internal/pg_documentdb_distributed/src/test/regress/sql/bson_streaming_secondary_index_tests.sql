-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.

SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog,
    documentdb_api_internal, public;
SET documentdb.next_collection_id TO 30123000;
SET documentdb.next_collection_index_id TO 30123000;
SET citus.next_shard_id TO 301230000;
SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.alternate_index_handler_name TO 'extended_rum';
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;

SELECT create_collection('secondary_streaming_db', 'docs');
SELECT shard_collection('secondary_streaming_db', 'docs', '{"sh":"hashed"}', false);
SELECT COUNT(insert_one('secondary_streaming_db', 'docs',
    FORMAT('{"_id":%s,"sh":%s,"a":%s,"b":%s,"s":"%s","long_s":"%s"}',
        i, mod(i, 6), mod(i, 3), mod(i, 4),
        CASE mod(i, 3) WHEN 0 THEN 'Alpha' WHEN 1 THEN 'alpha' ELSE 'Beta' END,
        repeat('long-key-', 32)
    )::bson))
FROM generate_series(36, 1, -1) AS i;

SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'secondary_streaming_db', '{"createIndexes":"docs","indexes":[
        {"key":{"a":1},"name":"a_asc","enableOrderedIndex":true},
        {"key":{"a":-1},"name":"a_desc","enableOrderedIndex":true},
        {"key":{"a":1,"b":1},"name":"ab_aa","enableOrderedIndex":true},
        {"key":{"a":1,"b":-1},"name":"ab_ad","enableOrderedIndex":true},
        {"key":{"a":1,"_id":1},"name":"a_id","enableOrderedIndex":true},
        {"key":{"long_s":1},"name":"long_asc","enableOrderedIndex":true},
        {"key":{"s":1},"name":"s_ci","enableOrderedIndex":true,
         "collation":{"locale":"en","strength":2}}
    ]}', true);

SELECT create_collection('secondary_streaming_db', 'replan');
SELECT shard_collection('secondary_streaming_db', 'replan', '{"sh":"hashed"}', false);
SELECT COUNT(insert_one('secondary_streaming_db', 'replan',
    FORMAT('{"_id":%s,"sh":%s,"a":%s}', i, mod(i, 6), mod(i, 3))::bson))
FROM generate_series(36, 1, -1) AS i;
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'secondary_streaming_db', '{"createIndexes":"replan","indexes":[
        {"key":{"a":1},"name":"a_asc","enableOrderedIndex":true}
    ]}', true);

-- Raw terms require the index collation when comparing the saved boundary.
BEGIN;
SET LOCAL documentdb.enableComparableTerms TO off;
SELECT create_collection('secondary_streaming_db', 'collation_resume');
SELECT shard_collection('secondary_streaming_db', 'collation_resume', '{"sh":"hashed"}', false);
SELECT COUNT(insert_one('secondary_streaming_db', 'collation_resume',
    FORMAT('{"_id":%s,"sh":1,"a":"item%s"}', i, i)::bson))
FROM (VALUES (2), (10), (20)) AS docs(i);
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'secondary_streaming_db', '{"createIndexes":"collation_resume","indexes":[
        {"key":{"a":1},"name":"numeric_a","enableOrderedIndex":true,
         "collation":{"locale":"en","numericOrdering":true}}
    ]}', true);
COMMIT;

-- SET LOCAL propagates the feature and planner settings to worker connections.
-- Remote execution exercises serialized continuations even on a single node.
SET citus.enable_local_execution TO off;
BEGIN;
SET LOCAL citus.max_adaptive_executor_pool_size TO 1;
SET LOCAL documentdb.enableDynamicCursors TO off;
SET LOCAL documentdb.enablePrimaryKeyCursorScan TO off;
SET LOCAL documentdb.enable_index_scan_on_streaming_cursors TO on;
SET LOCAL documentdb.enableIndexOnlyScanForFindProject TO on;
SET LOCAL documentdb.defaultUseCompositeOpClass TO on;
SET LOCAL documentdb_core.enableCollation TO on;
SET LOCAL documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET LOCAL enable_seqscan TO off;

DO $$
DECLARE
    test_case record;
    command_spec jsonb;
    get_more_spec bson;
    cursor_page bson;
    cursor_continuation bson;
    holds_portal bool;
    batch jsonb;
    continuation_entries jsonb;
    ids int[];
    sorted_ids int[];
    distinct_ids bigint;
    batch_ids int[];
    shard_names text[];
    batch_shards text[];
    shard_count bigint;
    pages int;
BEGIN
    FOR test_case IN
        SELECT * FROM (VALUES
            ('equality', 'docs', '{"a":1}'::jsonb, 'a_asc', 2, false,
                ARRAY(SELECT i FROM generate_series(1,36) i WHERE mod(i,3)=1)),
            ('in_ascending', 'docs', '{"a":{"$in":[0,2]}}', 'a_asc', 2, false,
                ARRAY(SELECT i FROM generate_series(1,36) i WHERE mod(i,3)<>1)),
            ('in_descending', 'docs', '{"a":{"$in":[0,2]}}', 'a_desc', 1, false,
                ARRAY(SELECT i FROM generate_series(1,36) i WHERE mod(i,3)<>1)),
            ('compound_ascending', 'docs', '{"a":{"$in":[0,2]},"b":{"$in":[1,3]}}', 'ab_aa', 2, false,
                ARRAY(SELECT i FROM generate_series(1,36) i WHERE mod(i,3)<>1 AND mod(i,2)=1)),
            ('compound_descending', 'docs', '{"a":{"$in":[0,2]},"b":{"$in":[1,3]}}', 'ab_ad', 2, false,
                ARRAY(SELECT i FROM generate_series(1,36) i WHERE mod(i,3)<>1 AND mod(i,2)=1)),
            ('routed_shard', 'docs', '{"sh":1,"a":1}', 'a_asc', 1, false,
                ARRAY(SELECT i FROM generate_series(1,36) i WHERE mod(i,6)=1)),
            ('covered', 'docs', '{"a":1}', 'a_id', 2, false,
                ARRAY(SELECT i FROM generate_series(1,36) i WHERE mod(i,3)=1)),
            ('range', 'docs', '{"a":{"$gte":0}}', 'a_asc', 5, false,
                ARRAY(SELECT i FROM generate_series(1,36) i)),
            ('empty', 'docs', '{"a":99}', 'a_asc', 2, false, ARRAY[]::int[]),
            ('one_page', 'docs', '{"a":1}', 'a_asc', 100, false,
                ARRAY(SELECT i FROM generate_series(1,36) i WHERE mod(i,3)=1)),
            ('collation', 'docs', '{"s":"ALPHA"}', 's_ci', 2, true,
                ARRAY(SELECT i FROM generate_series(1,36) i WHERE mod(i,3)<>2)),
            ('long_key', 'docs', jsonb_build_object('long_s', repeat('long-key-',32)),
                'long_asc', 2, false, ARRAY(SELECT i FROM generate_series(1,36) i)),
            ('competing_index', 'replan', '{"a":{"$gte":0}}', NULL, 2, false,
                ARRAY(SELECT i FROM generate_series(1,36) i)),
            ('collation_deleted_key', 'collation_resume',
                '{"sh":1,"a":{"$in":["item2","item10","item20"]}}', 'numeric_a', 1, false,
                ARRAY[2,10,20])
        ) cases(label, collection_name, filter, hint, batch_size, collated, expected_ids)
    LOOP
        ids := '{}';
        shard_names := '{}';
        pages := 0;
        command_spec := jsonb_build_object(
            'find', test_case.collection_name,
            'filter', test_case.filter,
            'projection', jsonb_build_object('_id', 1),
            'batchSize', test_case.batch_size);
        IF test_case.hint IS NOT NULL THEN
            command_spec := command_spec || jsonb_build_object('hint', test_case.hint);
        END IF;
        IF test_case.collated THEN
            command_spec := command_spec || '{"collation":{"locale":"en","strength":2}}'::jsonb;
        END IF;
        IF test_case.label = 'collation_deleted_key' THEN
            EXECUTE 'SET LOCAL documentdb.enableComparableTerms TO off';
            command_spec := command_spec ||
                '{"collation":{"locale":"en","numericOrdering":true}}'::jsonb;
        END IF;
        IF test_case.label = 'competing_index' THEN
            PERFORM set_config('documentdb.enableIndexOnlyScanForFindProject', 'off', true);
        END IF;
        get_more_spec := FORMAT(
            '{"getMore":{"$numberLong":"725"},"collection":"%s","batchSize":%s}',
            test_case.collection_name, test_case.batch_size)::bson;

        SELECT fp.cursorPage, fp.continuation, fp.persistConnection
        INTO cursor_page, cursor_continuation, holds_portal
        FROM find_cursor_first_page('secondary_streaming_db', command_spec::text::bson, 725) fp;
        IF holds_portal THEN
            RAISE EXCEPTION '%: expected a streaming cursor', test_case.label;
        END IF;

        IF test_case.label = 'competing_index' THEN
            PERFORM documentdb_api_internal.create_indexes_non_concurrently(
                'secondary_streaming_db', '{"createIndexes":"replan","indexes":[
                    {"key":{"a":-1},"name":"a_desc","enableOrderedIndex":true}
                ]}', true);
        ELSIF test_case.label = 'collation_deleted_key' THEN
            PERFORM documentdb_api.delete('secondary_streaming_db',
                '{"delete":"collation_resume","deletes":[{"q":{"sh":1,"a":"item2"},"limit":0}],"collation":{"locale":"en","numericOrdering":true}}');
        END IF;

        LOOP
            pages := pages + 1;
            IF pages > 64 THEN
                RAISE EXCEPTION '%: cursor did not terminate', test_case.label;
            END IF;
            batch := COALESCE(
                cursor_page::text::jsonb #> '{cursor,firstBatch}',
                cursor_page::text::jsonb #> '{cursor,nextBatch}');
            IF jsonb_array_length(batch) > test_case.batch_size THEN
                RAISE EXCEPTION '%: oversized batch', test_case.label;
            END IF;
            SELECT array_agg((doc -> '_id' ->> '$numberInt')::int)
            INTO batch_ids FROM jsonb_array_elements(batch) doc;
            ids := ids || COALESCE(batch_ids, '{}');
            EXIT WHEN cursor_continuation IS NULL;

            continuation_entries := cursor_continuation::text::jsonb -> 'continuation';
            IF jsonb_array_length(continuation_entries) = 0 OR EXISTS (
                SELECT FROM jsonb_array_elements(continuation_entries) entry
                WHERE NOT entry ? 'six'
            ) THEN
                RAISE EXCEPTION '%: expected secondary index continuations, got %',
                    test_case.label, continuation_entries;
            END IF;
            SELECT array_agg(entry ->> 'table_name') INTO batch_shards
            FROM jsonb_array_elements(continuation_entries) entry;
            shard_names := shard_names || batch_shards;

            SELECT gm.cursorPage, gm.continuation INTO cursor_page, cursor_continuation
            FROM cursor_get_more('secondary_streaming_db', get_more_spec, cursor_continuation) gm;
        END LOOP;

        SELECT array_agg(id ORDER BY id), count(DISTINCT id)
        INTO sorted_ids, distinct_ids FROM unnest(ids) id;
        IF COALESCE(sorted_ids, '{}') IS DISTINCT FROM test_case.expected_ids OR
           cardinality(ids) <> distinct_ids THEN
            RAISE EXCEPTION '%: expected %, got % with % distinct ids',
                test_case.label, test_case.expected_ids, sorted_ids, distinct_ids;
        END IF;
        SELECT count(DISTINCT name) INTO shard_count FROM unnest(shard_names) name;
        IF cardinality(ids) > test_case.batch_size AND
           (pages < 2 OR shard_count = 0) THEN
            RAISE EXCEPTION '%: secondary cursor did not paginate', test_case.label;
        END IF;
        IF test_case.label IN ('range', 'in_ascending', 'long_key', 'competing_index') AND shard_count < 2 THEN
            RAISE EXCEPTION '%: expected continuations from multiple shards', test_case.label;
        END IF;
        RAISE NOTICE '%: % documents, no duplicates, exhausted',
            test_case.label, cardinality(ids);
    END LOOP;
END;
$$;
COMMIT;

-- Only shards without a prior continuation may adopt the newly created index.
BEGIN;
SET LOCAL citus.max_adaptive_executor_pool_size TO 1;
SET LOCAL documentdb.enableDynamicCursors TO off;
SET LOCAL documentdb.enable_index_scan_on_streaming_cursors TO on;
SET LOCAL documentdb.enableIndexOnlyScanForFindProject TO off;
SET LOCAL enable_seqscan TO off;
DO $$
DECLARE
    test_case record;
    collection_name text;
    command_spec bson;
    get_more_spec bson;
    cursor_page bson;
    cursor_continuation bson;
    holds_portal bool;
    entries jsonb;
    tid_shards text[];
    seen_shards text[];
    batch_shards text[];
    ids int[];
    batch_ids int[];
    sorted_ids int[];
    distinct_ids bigint;
    pages int;
BEGIN
    FOR test_case IN
        SELECT * FROM (VALUES
            ('heap_index', false, false),
            ('heap_bitmap', false, true),
            ('multikey_index', true, false),
            ('multikey_bitmap', true, true)
        ) cases(label, multikey, bitmap_only)
    LOOP
        collection_name := 'mode_' || test_case.label;
        EXECUTE FORMAT('SET LOCAL documentdb.enablePrimaryKeyCursorScan TO %L', test_case.multikey);
        EXECUTE FORMAT('SET LOCAL enable_bitmapscan TO %L', test_case.bitmap_only);
        EXECUTE FORMAT('SET LOCAL enable_indexscan TO %L', NOT test_case.bitmap_only);
        PERFORM create_collection('secondary_streaming_db', collection_name);
        PERFORM shard_collection('secondary_streaming_db', collection_name, '{"sh":"hashed"}', false);
        PERFORM insert_one('secondary_streaming_db', collection_name,
            FORMAT('{"_id":%s,"sh":%s,"a":%s,"b":%s}', i, mod(i,6),
                CASE WHEN test_case.multikey THEN '[1,2]' ELSE i::text END, i)::bson)
        FROM generate_series(36, 1, -1) i;
        IF test_case.multikey THEN
            PERFORM documentdb_api_internal.create_indexes_non_concurrently('secondary_streaming_db',
                jsonb_build_object('createIndexes', collection_name, 'indexes',
                    '[{"key":{"a":1},"name":"a","enableOrderedIndex":true}]'::jsonb)::text::bson, true);
        END IF;
        command_spec := jsonb_build_object('find', collection_name,
            'filter', CASE WHEN test_case.multikey THEN '{"a":1,"b":{"$gte":1}}'::jsonb
                ELSE '{"b":{"$gte":1}}'::jsonb END,
            'projection', '{"_id":1}'::jsonb, 'batchSize', 2)::text::bson;
        get_more_spec := FORMAT(
            '{"getMore":{"$numberLong":"725"},"collection":"%s","batchSize":2}',
            collection_name)::bson;
        SELECT fp.cursorPage, fp.continuation, fp.persistConnection
        INTO cursor_page, cursor_continuation, holds_portal
        FROM find_cursor_first_page('secondary_streaming_db', command_spec, 725) fp;
        entries := cursor_continuation::text::jsonb -> 'continuation';
        IF holds_portal OR cursor_continuation IS NULL OR EXISTS (
            SELECT FROM jsonb_array_elements(entries) entry WHERE entry ? 'six'
        ) THEN
            RAISE EXCEPTION '%: expected initial TID continuations', test_case.label;
        END IF;
        PERFORM documentdb_api_internal.create_indexes_non_concurrently('secondary_streaming_db',
            jsonb_build_object('createIndexes', collection_name, 'indexes',
                '[{"key":{"b":1},"name":"b","enableOrderedIndex":true}]'::jsonb)::text::bson, true);
        ids := '{}';
        tid_shards := '{}';
        seen_shards := '{}';
        pages := 0;
        LOOP
            pages := pages + 1;
            IF pages > 64 THEN
                RAISE EXCEPTION '%: cursor did not terminate', test_case.label;
            END IF;
            SELECT array_agg((doc -> '_id' ->> '$numberInt')::int)
            INTO batch_ids FROM jsonb_array_elements(COALESCE(
                cursor_page::text::jsonb #> '{cursor,firstBatch}',
                cursor_page::text::jsonb #> '{cursor,nextBatch}')) doc;
            ids := ids || COALESCE(batch_ids, '{}');
            EXIT WHEN cursor_continuation IS NULL;
            entries := cursor_continuation::text::jsonb -> 'continuation';
            SELECT array_agg(entry ->> 'table_name') INTO batch_shards
            FROM jsonb_array_elements(entries) entry;
            seen_shards := seen_shards || COALESCE(batch_shards, '{}');
            IF EXISTS (
                SELECT FROM jsonb_array_elements(entries) entry
                WHERE entry ? 'six' AND entry ->> 'table_name' = ANY(tid_shards)
            ) THEN
                RAISE EXCEPTION '%: existing shard continuation changed scan order', test_case.label;
            END IF;
            SELECT array_agg(entry ->> 'table_name') INTO batch_shards
            FROM jsonb_array_elements(entries) entry WHERE NOT entry ? 'six';
            tid_shards := tid_shards || COALESCE(batch_shards, '{}');
            SELECT gm.cursorPage, gm.continuation INTO cursor_page, cursor_continuation
            FROM cursor_get_more('secondary_streaming_db', get_more_spec, cursor_continuation) gm;
        END LOOP;
        SELECT array_agg(id ORDER BY id), count(DISTINCT id)
        INTO sorted_ids, distinct_ids FROM unnest(ids) id;
        IF sorted_ids IS DISTINCT FROM ARRAY(SELECT generate_series(1,36)) OR
           cardinality(ids) <> distinct_ids OR cardinality(tid_shards) = 0 OR
           (SELECT count(DISTINCT name) FROM unnest(seen_shards) name) < 2 THEN
            RAISE EXCEPTION '%: incomplete or duplicate sharded results: %', test_case.label, sorted_ids;
        END IF;
        SELECT fp.continuation INTO cursor_continuation
        FROM find_cursor_first_page('secondary_streaming_db', command_spec, 725) fp;
        entries := cursor_continuation::text::jsonb -> 'continuation';
        IF cursor_continuation IS NULL OR jsonb_array_length(entries) = 0 OR EXISTS (
            SELECT FROM jsonb_array_elements(entries) entry WHERE NOT entry ? 'six'
        ) THEN
            RAISE EXCEPTION '%: fresh cursor did not use the new secondary index', test_case.label;
        END IF;
        PERFORM drop_collection('secondary_streaming_db', collection_name);
        RAISE NOTICE '%: 36 unique documents, shard continuations preserved, fresh cursor uses new index', test_case.label;
    END LOOP;
END;
$$;
COMMIT;

SELECT drop_collection('secondary_streaming_db', 'docs');
SELECT drop_collection('secondary_streaming_db', 'replan');
SELECT drop_collection('secondary_streaming_db', 'collation_resume');
