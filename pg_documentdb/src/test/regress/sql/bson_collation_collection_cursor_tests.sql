-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api, documentdb_api_catalog, documentdb_core, public;

SET documentdb.next_collection_id TO 25803000;
SET documentdb.next_collection_index_id TO 25803000;
SET documentdb_core.enableCollation TO on;
SET documentdb.enableCollationWithNonUniqueOrderedIndexes TO on;
SET documentdb.defaultUseCompositeOpClass TO on;
SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableExtendedExplainPlans TO on;
SET documentdb.enableIndexOnlyScanForFindProject TO on;

CREATE SCHEMA collation_find_cursor_test;

CREATE FUNCTION collation_find_cursor_test.drain_cursor_pages(
    p_collection text,
    p_query_spec bson,
    p_cursor_id bigint,
    p_get_more_batch_size int DEFAULT 1,
    p_fault_inject_missing_default bool DEFAULT false,
    p_is_aggregate bool DEFAULT false)
RETURNS TABLE(
    page_number int,
    cursor_kind text,
    batch bson,
    has_continuation bool)
LANGUAGE plpgsql
AS $$
DECLARE
    v_page bson;
    v_continuation bson;
    v_cursor_kind text;
    v_page_number int := 1;
    v_get_more_spec bson;
    v_original_options bson;
    v_default_removed bool := false;
BEGIN
    IF p_is_aggregate THEN
        SELECT cursorpage, continuation
        INTO v_page, v_continuation
        FROM aggregate_cursor_first_page(
            'collation_find_cursor_db', p_query_spec, p_cursor_id);
    ELSE
        SELECT cursorpage, continuation
        INTO v_page, v_continuation
        FROM find_cursor_first_page(
            'collation_find_cursor_db', p_query_spec, p_cursor_id);
    END IF;

    IF v_continuation IS NULL THEN
        v_cursor_kind := 'no cursor';
    ELSIF v_continuation::text::jsonb ? 'qd' THEN
        v_cursor_kind := 'dynamic streaming';
    ELSIF v_continuation::text::jsonb ? 'qc' THEN
        v_cursor_kind := 'streaming';
    ELSIF v_continuation::text::jsonb ? 'qf' THEN
        v_cursor_kind := 'file';
    ELSIF v_continuation::text::jsonb ? 'qn' THEN
        v_cursor_kind := 'persistent';
    ELSE
        v_cursor_kind := 'unknown';
    END IF;

    page_number := v_page_number;
    cursor_kind := v_cursor_kind;
    batch := bson_dollar_project(
        v_page,
        '{ "_id": 0,
           "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] },
           "cursorId": "$cursor.id" }');
    has_continuation := v_continuation IS NOT NULL;
    RETURN NEXT;

    IF v_continuation IS NOT NULL THEN
        IF p_fault_inject_missing_default THEN
            -- Supported commands cannot change a collection default. This
            -- catalog-only fault makes metadata re-resolution use binary
            -- semantics so getMore must apply the retained collation.
            SELECT options
            INTO STRICT v_original_options
            FROM documentdb_api_catalog.collections
            WHERE database_name = 'collation_find_cursor_db'
              AND collection_name = p_collection;

            UPDATE documentdb_api_catalog.collections
            SET options = '{}'::bson
            WHERE database_name = 'collation_find_cursor_db'
              AND collection_name = p_collection;
            v_default_removed := true;
        END IF;

        -- Eviction also verifies that retained state does not borrow memory
        -- from the collection metadata cache.
        PERFORM documentdb_api_internal.invalidate_collection_cache();
    END IF;

    v_get_more_spec := FORMAT(
        '{ "getMore": { "$numberLong": "%s" }, "collection": "%s", "batchSize": %s }',
        p_cursor_id, p_collection, p_get_more_batch_size)::bson;

    WHILE v_continuation IS NOT NULL AND v_page_number < 20 LOOP
        SELECT cursorpage, continuation
        INTO v_page, v_continuation
        FROM cursor_get_more(
            'collation_find_cursor_db', v_get_more_spec, v_continuation);

        v_page_number := v_page_number + 1;
        page_number := v_page_number;
        cursor_kind := v_cursor_kind;
        batch := bson_dollar_project(
            v_page,
            '{ "_id": 0,
               "ids": { "$ifNull": [ "$cursor.firstBatch._id", "$cursor.nextBatch._id" ] },
               "cursorId": "$cursor.id" }');
        has_continuation := v_continuation IS NOT NULL;
        RETURN NEXT;
    END LOOP;

    IF v_default_removed THEN
        UPDATE documentdb_api_catalog.collections
        SET options = v_original_options
        WHERE database_name = 'collation_find_cursor_db'
          AND collection_name = p_collection;
        PERFORM documentdb_api_internal.invalidate_collection_cache();
    END IF;

    IF v_continuation IS NOT NULL THEN
        RAISE EXCEPTION 'cursor did not drain within 20 pages';
    END IF;
END;
$$;

SELECT create_collection('collation_find_cursor_db', 'inherited_default');

-- Collection creation does not yet accept a default collation. Seed the catalog
-- once to model a collection created with this immutable default.
UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "fr", "strength": 1 } }'::bson
WHERE database_name = 'collation_find_cursor_db'
  AND collection_name = 'inherited_default';
SELECT documentdb_api_internal.invalidate_collection_cache();

SELECT insert_one(
    'collation_find_cursor_db', 'inherited_default',
    FORMAT('{ "_id": %s, "value": "%s" }', g.id, g.value)::bson)
FROM (VALUES
    (1, 'cafe'),
    (2, 'CAFE'),
    (3, 'CAFÉ'),
    (4, 'cafe'),
    (5, 'cafe'),
    (6, 'caff')
) AS g(id, value);

SELECT documentdb_test_helpers.run_explain_and_trim($cmd$
EXPLAIN (COSTS OFF)
SELECT document
FROM bson_aggregation_find(
    'collation_find_cursor_db',
    '{ "find": "inherited_default",
       "filter": { "value": "cafe" } }')
$cmd$);

-- A batch that drains the query does not create a cursor.
SELECT * FROM collation_find_cursor_test.drain_cursor_pages(
    'inherited_default',
    '{ "find": "inherited_default",
       "filter": { "value": "cafe" },
       "batchSize": 10 }',
    782301,
    1);

-- An aggregate batch that drains the query does not create a cursor.
SELECT * FROM collation_find_cursor_test.drain_cursor_pages(
    'inherited_default',
    '{ "aggregate": "inherited_default",
       "pipeline": [
           { "$match": { "value": "cafe" } },
           { "$project": { "_id": 1 } }
       ],
       "cursor": { "batchSize": 10 } }',
    782315,
    1,
    false,
    true);

-- A find without command collation resolves the collection default once.
-- Continuation pages reuse that retained effective collation.
SELECT * FROM collation_find_cursor_test.drain_cursor_pages(
    'inherited_default',
    '{ "find": "inherited_default",
       "filter": { "value": "cafe" },
       "batchSize": 1 }',
    782302,
    1,
    true);

-- The legacy streaming continuation preserves the same retained default.
SET documentdb.enableDynamicCursors TO off;
SELECT * FROM collation_find_cursor_test.drain_cursor_pages(
    'inherited_default',
    '{ "find": "inherited_default",
       "filter": { "value": "cafe" },
       "batchSize": 1 }',
    782308,
    1,
    true);

-- Aggregate streaming continuation also reuses the retained default.
SELECT * FROM collation_find_cursor_test.drain_cursor_pages(
    'inherited_default',
    '{ "aggregate": "inherited_default",
       "pipeline": [
           { "$match": { "value": "cafe" } },
           { "$project": { "_id": 1 } }
       ],
       "cursor": { "batchSize": 1 } }',
    782317,
    1,
    true,
    true);
SET documentdb.enableDynamicCursors TO on;

-- Explicit strength and simple collations override the collection default
-- across every continuation page.
SELECT * FROM collation_find_cursor_test.drain_cursor_pages(
    'inherited_default',
    '{ "find": "inherited_default",
       "filter": { "value": "cafe" },
       "collation": { "locale": "fr", "strength": 2 },
       "batchSize": 1 }',
    782303,
    1);

SELECT * FROM collation_find_cursor_test.drain_cursor_pages(
    'inherited_default',
    '{ "find": "inherited_default",
       "filter": { "value": "cafe" },
       "collation": { "locale": "simple" },
       "batchSize": 1 }',
    782304,
    1);

SELECT * FROM collation_find_cursor_test.drain_cursor_pages(
    'inherited_default',
    '{ "aggregate": "inherited_default",
       "pipeline": [
           { "$match": { "value": "cafe" } },
           { "$project": { "_id": 1 } }
       ],
       "collation": { "locale": "fr", "strength": 2 },
       "cursor": { "batchSize": 1 } }',
    782318,
    1,
    false,
    true);

SELECT * FROM collation_find_cursor_test.drain_cursor_pages(
    'inherited_default',
    '{ "aggregate": "inherited_default",
       "pipeline": [
           { "$match": { "value": "cafe" } },
           { "$project": { "_id": 1 } }
       ],
       "collation": { "locale": "simple" },
       "cursor": { "batchSize": 1 } }',
    782319,
    1,
    false,
    true);

-- A non-streamable find materializes its original collated results.
SET documentdb.enable_dynamic_cursor_with_skiplimit TO off;
SELECT * FROM collation_find_cursor_test.drain_cursor_pages(
    'inherited_default',
    '{ "find": "inherited_default",
       "filter": { "value": "cafe" },
       "sort": { "_id": 1 },
       "skip": 1,
       "batchSize": 1 }',
    782309,
    1,
    true);
RESET documentdb.enable_dynamic_cursor_with_skiplimit;

-- Empty command collation inherits the default on the non-index path.
SELECT * FROM collation_find_cursor_test.drain_cursor_pages(
    'inherited_default',
    '{ "find": "inherited_default",
       "filter": { "value": "cafe" },
       "collation": {},
       "batchSize": 1 }',
    782305,
    1,
    true);

-- Planner-rewritten streaming getMore restores the retained default before
-- regenerating the query.
SET documentdb.enableDynamicCursors TO off;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
SELECT cursorpage AS planner_page, continuation AS planner_continuation
FROM find_cursor_first_page(
    'collation_find_cursor_db',
    '{ "find": "inherited_default",
       "filter": { "value": "cafe" },
       "projection": { "_id": 1 },
       "batchSize": 1 }',
    782313) \gset

SELECT bson_dollar_project(
           :'planner_page'::bson,
           '{ "_id": 0, "ids": "$cursor.firstBatch._id" }') AS first_page,
       :'planner_continuation'::bson::text::jsonb ? 'cl' AS has_collation,
       :'planner_continuation'::bson::text::jsonb ? 'qc' AS streaming;

SELECT cursorpage AS aggregate_planner_page,
       continuation AS aggregate_planner_continuation
FROM aggregate_cursor_first_page(
    'collation_find_cursor_db',
    '{ "aggregate": "inherited_default",
       "pipeline": [
           { "$match": { "value": "cafe" } },
           { "$project": { "_id": 1 } }
       ],
       "cursor": { "batchSize": 1 } }',
    782321) \gset

SELECT bson_dollar_project(
           :'aggregate_planner_page'::bson,
           '{ "_id": 0, "ids": "$cursor.firstBatch._id" }')
           AS aggregate_first_page,
       :'aggregate_planner_continuation'::bson::text::jsonb ? 'cl'
           AS has_collation,
       :'aggregate_planner_continuation'::bson::text::jsonb ? 'qc'
           AS streaming;

-- Supported commands cannot remove the immutable default. This catalog-only
-- fault makes metadata re-resolution binary before the planner regenerates the
-- cursor queries.
UPDATE documentdb_api_catalog.collections
SET options = '{}'::bson
WHERE database_name = 'collation_find_cursor_db'
  AND collection_name = 'inherited_default';
SELECT documentdb_api_internal.invalidate_collection_cache();
SELECT document AS planner_document
FROM bson_aggregation_getmore(
    'collation_find_cursor_db',
    '{
        "getMore": { "$numberLong": "782313" },
        "collection": "inherited_default",
        "batchSize": 1
    }',
    :'planner_continuation'::bson);

SELECT document AS aggregate_planner_document
FROM bson_aggregation_getmore(
    'collation_find_cursor_db',
    '{
        "getMore": { "$numberLong": "782321" },
        "collection": "inherited_default",
        "batchSize": 1
    }',
    :'aggregate_planner_continuation'::bson);

SELECT bson_dollar_project(
           cursorpage,
           '{ "_id": 0,
              "ids": "$cursor.nextBatch._id",
              "cursorId": "$cursor.id" }') AS final_page,
       continuation IS NULL AS planner_cursor_exhausted
FROM cursor_get_more(
    'collation_find_cursor_db',
    '{
        "getMore": { "$numberLong": "782313" },
        "collection": "inherited_default",
        "batchSize": 10
    }',
    :'planner_continuation'::bson);

SELECT bson_dollar_project(
           cursorpage,
           '{ "_id": 0,
              "ids": "$cursor.nextBatch._id",
              "cursorId": "$cursor.id" }') AS aggregate_final_page,
       continuation IS NULL AS aggregate_planner_cursor_exhausted
FROM cursor_get_more(
    'collation_find_cursor_db',
    '{
        "getMore": { "$numberLong": "782321" },
        "collection": "inherited_default",
        "batchSize": 10
    }',
    :'aggregate_planner_continuation'::bson);

UPDATE documentdb_api_catalog.collections
SET options = '{ "collation": { "locale": "fr", "strength": 1 } }'::bson
WHERE database_name = 'collation_find_cursor_db'
  AND collection_name = 'inherited_default';
SELECT documentdb_api_internal.invalidate_collection_cache();
RESET documentdb.enableCursorsOnAggregationQueryRewrite;

-- A continuation without retained state remains compatible and resolves the
-- unchanged collection default when it resumes.
SELECT cursorpage AS legacy_page, continuation AS legacy_continuation
FROM find_cursor_first_page(
    'collation_find_cursor_db',
    '{ "find": "inherited_default",
       "filter": { "value": "cafe" },
       "projection": { "_id": 1 },
       "batchSize": 1 }',
    782314) \gset

SELECT :'legacy_continuation'::bson::text::jsonb ? 'cl' AS has_collation,
       :'legacy_continuation'::bson::text::jsonb ? 'qc' AS streaming;
SELECT bson_dollar_project(
           :'legacy_continuation'::bson,
           '{ "cl": 0 }') AS legacy_without_collation \gset

-- A legacy continuation re-resolves the same immutable default after eviction.
SELECT documentdb_api_internal.invalidate_collection_cache();
SELECT cursorpage AS legacy_page, continuation AS legacy_continuation
FROM cursor_get_more(
    'collation_find_cursor_db',
    '{
        "getMore": { "$numberLong": "782314" },
        "collection": "inherited_default",
        "batchSize": 1
    }',
    :'legacy_without_collation'::bson) \gset

SELECT bson_dollar_project(
           :'legacy_page'::bson,
           '{ "_id": 0,
              "ids": "$cursor.nextBatch._id",
              "cursorId": "$cursor.id" }') AS page,
       :'legacy_continuation'::bson::text::jsonb ? 'cl'
           AS restored_collation,
       :'legacy_continuation'::bson::text::jsonb ? 'qc'
           AS streaming;

SELECT bson_dollar_project(
           cursorpage,
           '{ "_id": 0,
              "ids": "$cursor.nextBatch._id",
              "cursorId": "$cursor.id" }') AS page,
       continuation IS NULL AS exhausted
FROM cursor_get_more(
    'collation_find_cursor_db',
    '{
        "getMore": { "$numberLong": "782314" },
        "collection": "inherited_default",
        "batchSize": 10
    }',
    :'legacy_continuation'::bson);

SET documentdb.enableDynamicCursors TO on;
SET documentdb.enableIndexOnlyScanForFindProject TO on;

-- A collection without a default uses binary comparison semantics. Batch size
-- zero returns an empty first batch and leaves all matching work for getMore.
SELECT create_collection('collation_find_cursor_db', 'no_default');
SELECT insert_one(
    'collation_find_cursor_db', 'no_default',
    '{ "_id": 11, "value": "cafe" }');
SELECT insert_one(
    'collation_find_cursor_db', 'no_default',
    '{ "_id": 12, "value": "CAFE" }');
SELECT insert_one(
    'collation_find_cursor_db', 'no_default',
    '{ "_id": 13, "value": "cafe" }');

SELECT * FROM collation_find_cursor_test.drain_cursor_pages(
    'no_default',
    '{ "find": "no_default",
       "filter": { "value": "cafe" },
       "batchSize": 0 }',
    782306,
    1);

SELECT * FROM collation_find_cursor_test.drain_cursor_pages(
    'no_default',
    '{ "aggregate": "no_default",
       "pipeline": [
           { "$match": { "value": "cafe" } },
           { "$project": { "_id": 1 } }
       ],
       "cursor": { "batchSize": 0 } }',
    782320,
    1,
    false,
    true);

-- Planner-rewritten getMore also restores the retained binary semantics before
-- regenerating the find query.
SET documentdb.enableDynamicCursors TO off;
SET documentdb.enableCursorsOnAggregationQueryRewrite TO on;
CREATE TEMP TABLE collation_find_cursor_planner_page AS
SELECT cursorpage, continuation
FROM find_cursor_first_page(
    'collation_find_cursor_db',
    '{ "find": "no_default",
       "filter": { "value": "cafe" },
       "projection": { "_id": 1 },
       "batchSize": 1 }',
    782310);

SELECT bson_dollar_project(
           cursorpage,
           '{ "_id": 0, "ids": "$cursor.firstBatch._id" }') AS first_page,
       continuation IS NOT NULL AS has_continuation,
       continuation::text::jsonb ? 'cl' AS has_collation,
       continuation::text::jsonb ? 'qc' AS streaming
FROM collation_find_cursor_planner_page;
SELECT continuation AS planner_continuation
FROM collation_find_cursor_planner_page \gset

-- Evict the source metadata before regenerating the binary find query.
SELECT documentdb_api_internal.invalidate_collection_cache();
SELECT document
FROM bson_aggregation_getmore(
    'collation_find_cursor_db',
    '{
        "getMore": { "$numberLong": "782310" },
        "collection": "no_default",
        "batchSize": 1
    }',
    :'planner_continuation'::bson);

DROP TABLE collation_find_cursor_planner_page;
RESET documentdb.enableCursorsOnAggregationQueryRewrite;
SET documentdb.enableDynamicCursors TO on;

-- Null remains invalid rather than being treated as missing or empty.
\set VERBOSITY sqlstate
SELECT cursorpage
FROM find_cursor_first_page(
    'collation_find_cursor_db',
    '{ "find": "inherited_default",
       "filter": { "value": "cafe" },
       "collation": null,
       "batchSize": 1 }',
    782307);
\set VERBOSITY default
SELECT drop_collection('collation_find_cursor_db', 'no_default');
SELECT drop_collection('collation_find_cursor_db', 'inherited_default');

DROP FUNCTION collation_find_cursor_test.drain_cursor_pages(
       text, bson, bigint, int, bool, bool);
DROP SCHEMA collation_find_cursor_test;

RESET documentdb.enableExtendedExplainPlans;
RESET documentdb.enableIndexOnlyScanForFindProject;
RESET documentdb.enableDynamicCursors;
RESET documentdb.defaultUseCompositeOpClass;
RESET documentdb.enableCollationWithNonUniqueOrderedIndexes;
RESET documentdb_core.enableCollation;
RESET search_path;
