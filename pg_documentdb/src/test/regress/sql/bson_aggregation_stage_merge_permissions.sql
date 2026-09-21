/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation. All rights reserved.
 * SPDX-License-Identifier: MIT
 *-------------------------------------------------------------------------
 */

SET search_path TO documentdb_core, documentdb_api, documentdb_api_catalog,
                   documentdb_api_internal, public;
SET documentdb.next_collection_id TO 8810000;
SET documentdb.next_collection_index_id TO 8810000;
\pset format unaligned

SELECT documentdb_api.create_collection('merge_acl_db', 'source');
SELECT documentdb_api.create_collection('merge_acl_db', 'target');
SELECT FORMAT('documentdb_data.documents_%s', collection_id) AS source_relation
FROM documentdb_api_catalog.collections
WHERE database_name = 'merge_acl_db' AND collection_name = 'source' \gset
SELECT FORMAT('documentdb_data.documents_%s', collection_id) AS target_relation
FROM documentdb_api_catalog.collections
WHERE database_name = 'merge_acl_db' AND collection_name = 'target' \gset

CREATE ROLE merge_acl_select;
CREATE ROLE merge_acl_insert;
CREATE ROLE merge_acl_update;
CREATE ROLE merge_acl_insert_update;
CREATE ROLE merge_acl_no_source;
GRANT USAGE ON SCHEMA documentdb_core, documentdb_api, documentdb_api_catalog,
                      documentdb_api_internal, documentdb_data
TO merge_acl_select, merge_acl_insert, merge_acl_update,
   merge_acl_insert_update, merge_acl_no_source;
GRANT SELECT ON ALL TABLES IN SCHEMA documentdb_api_catalog
TO merge_acl_select, merge_acl_insert, merge_acl_update,
   merge_acl_insert_update, merge_acl_no_source;

\set previous_echo :ECHO
\set ECHO none
SELECT FORMAT('GRANT SELECT ON %s TO merge_acl_select, merge_acl_insert, '
              'merge_acl_update, merge_acl_insert_update', :'source_relation') \gexec
SELECT FORMAT('GRANT SELECT ON %s TO merge_acl_select', :'target_relation') \gexec
SELECT FORMAT('GRANT INSERT ON %s TO merge_acl_insert', :'target_relation') \gexec
SELECT FORMAT('GRANT UPDATE ON %s TO merge_acl_update', :'target_relation') \gexec
SELECT FORMAT('GRANT INSERT, UPDATE ON %s TO merge_acl_insert_update, '
              'merge_acl_no_source', :'target_relation') \gexec
\set ECHO :previous_echo

SELECT NOT has_table_privilege('merge_acl_insert_update', :'target_relation', 'SELECT')
    AS target_find_not_granted;
SELECT NOT has_table_privilege('merge_acl_no_source', :'source_relation', 'SELECT')
    AS source_find_not_granted;

CREATE TEMP TABLE merge_acl_modes(
    matched text, unmatched text, required_mask integer);
INSERT INTO merge_acl_modes VALUES
    ('merge', 'insert', 5), ('merge', 'discard', 4), ('merge', 'fail', 4),
    ('replace', 'insert', 5), ('replace', 'discard', 4), ('replace', 'fail', 4),
    ('keepExisting', 'insert', 5), ('fail', 'insert', 1);
CREATE TEMP TABLE merge_acl_subjects(
    role_name text, granted_mask integer, source_find boolean);
INSERT INTO merge_acl_subjects VALUES
    ('merge_acl_select', 2, true),
    ('merge_acl_insert', 1, true),
    ('merge_acl_update', 4, true),
    ('merge_acl_insert_update', 5, true),
    ('merge_acl_no_source', 5, false);

CREATE TEMP TABLE merge_acl_cases AS
WITH combinations AS (
    SELECT m.*, s.*,
           layout,
           source_find AND (granted_mask & required_mask) = required_mask AS authorized,
           '{"_id":"source","value":"new","added":"source"}'::jsonb AS source_doc,
           jsonb_build_object('_id', CASE WHEN layout = 'unmatched' THEN 'target'
                                         ELSE 'source' END,
                              'value', 'old', 'retained', 'target') AS target_doc
    FROM merge_acl_modes m CROSS JOIN merge_acl_subjects s
    CROSS JOIN unnest(ARRAY['matched', 'unmatched', 'empty']) AS layout
)
SELECT matched || '/' || unmatched || '/' || layout || '/' || role_name AS case_id,
       role_name, layout,
       jsonb_build_object('$merge', jsonb_build_object(
           'into', 'target', 'whenMatched', matched, 'whenNotMatched', unmatched)) AS stage,
       authorized AND NOT (matched = 'fail' AND layout = 'matched')
                  AND NOT (unmatched = 'fail' AND layout = 'unmatched') AS expected_success,
       CASE
           WHEN NOT authorized OR layout = 'empty' THEN jsonb_build_array(target_doc)
           WHEN layout = 'matched' AND matched = 'merge'
               THEN jsonb_build_array(target_doc || source_doc)
           WHEN layout = 'matched' AND matched = 'replace'
               THEN jsonb_build_array(source_doc)
           WHEN layout = 'unmatched' AND unmatched = 'insert'
               THEN jsonb_build_array(source_doc, target_doc)
           ELSE jsonb_build_array(target_doc)
       END AS expected_documents,
       source_doc, target_doc
FROM combinations;

-- Both shorthand forms keep the default merge/insert requirements.
INSERT INTO merge_acl_cases
SELECT 'default/' || shorthand || '/' || layout,
       role_name, layout,
       CASE shorthand
           WHEN 'string' THEN '{"$merge":"target"}'::jsonb
           ELSE '{"$merge":{"into":"target"}}'::jsonb
       END,
       expected_success, expected_documents, source_doc, target_doc
FROM merge_acl_cases
CROSS JOIN unnest(ARRAY['string', 'object']) AS shorthand
WHERE case_id LIKE 'merge/insert/%/merge_acl_insert_update';

-- Unsupported pairs must not gain a zero-permission target as part of this change.
INSERT INTO merge_acl_cases
SELECT 'unsupported/' || modes.matched || '/' || modes.unmatched,
       template.role_name, template.layout,
       jsonb_build_object('$merge', jsonb_build_object(
           'into', 'target', 'whenMatched', modes.matched,
           'whenNotMatched', modes.unmatched)),
       false, template.expected_documents, template.source_doc, template.target_doc
FROM (VALUES ('keepExisting', 'discard'), ('keepExisting', 'fail'),
             ('fail', 'discard'), ('fail', 'fail')) AS modes(matched, unmatched)
CROSS JOIN merge_acl_cases template
WHERE template.case_id = 'merge/insert/empty/merge_acl_insert_update';

CREATE TEMP TABLE merge_acl_actual(
    case_id text PRIMARY KEY, succeeded boolean NOT NULL, documents jsonb);
GRANT INSERT ON merge_acl_actual
TO merge_acl_select, merge_acl_insert, merge_acl_update,
   merge_acl_insert_update, merge_acl_no_source;

-- Each generated cell is a separate autocommit statement, not a subtransaction.
\set ECHO none
SELECT FORMAT('SELECT %L AS permission_case', case_id),
       FORMAT('TRUNCATE TABLE %s, %s', :'source_relation', :'target_relation'),
       FORMAT($sql$
           DO $setup$ BEGIN
               PERFORM documentdb_api.insert_one('merge_acl_db', 'target', %L);
               IF %L <> 'empty' THEN
                   PERFORM documentdb_api.insert_one('merge_acl_db', 'source', %L);
               END IF;
           END $setup$
       $sql$, target_doc::text, layout, source_doc::text),
       FORMAT('SET ROLE %I', role_name),
       FORMAT(
           'INSERT INTO merge_acl_actual(case_id, succeeded) '
           'SELECT %L, true FROM documentdb_api.aggregate_cursor_first_page(%L, %L)',
           case_id, 'merge_acl_db',
           jsonb_build_object('aggregate', 'source', 'pipeline', jsonb_build_array(stage),
                              'cursor', '{}'::jsonb)::text),
       'RESET ROLE',
       FORMAT('INSERT INTO merge_acl_actual(case_id, succeeded) VALUES (%L, false) '
              'ON CONFLICT DO NOTHING', case_id),
       FORMAT(
           'UPDATE merge_acl_actual SET documents = '
           '(SELECT COALESCE(jsonb_agg(value ORDER BY value->>''_id''), ''[]''::jsonb) '
           'FROM (SELECT documentdb_core.bson_to_json_string(document)::text::jsonb AS value '
           'FROM documentdb_api.collection(%L, %L)) observed) WHERE case_id = %L',
           'merge_acl_db', 'target', case_id)
FROM merge_acl_cases
ORDER BY case_id \gexec
\set ECHO :previous_echo

SELECT COUNT(*) AS completed_cases,
       COUNT(*) FILTER (WHERE a.succeeded) AS successful_commands,
       COUNT(*) FILTER (WHERE c.expected_success) AS expected_successful_commands,
       BOOL_AND(a.succeeded = c.expected_success) AS all_outcomes_match,
       BOOL_AND(a.documents IS NOT DISTINCT FROM c.expected_documents) AS all_documents_match
FROM merge_acl_cases c JOIN merge_acl_actual a USING (case_id);

SELECT c.case_id, a.succeeded = c.expected_success AS outcome_matches,
       a.documents IS NOT DISTINCT FROM c.expected_documents AS documents_match
FROM merge_acl_cases c JOIN merge_acl_actual a USING (case_id)
WHERE a.succeeded <> c.expected_success OR a.documents IS DISTINCT FROM c.expected_documents
ORDER BY c.case_id;

-- A shared source/target relation still requires source read permission.
\set ECHO none
SELECT FORMAT('GRANT UPDATE ON %s TO merge_acl_update, merge_acl_no_source',
              :'source_relation') \gexec
\set ECHO :previous_echo
SELECT documentdb_api.insert_one(
    'merge_acl_db', 'source', '{"_id":"source","value":"new","added":"source"}');
SET ROLE merge_acl_update;
SELECT cursorPage IS NOT NULL AS same_collection_with_read_allowed
FROM documentdb_api.aggregate_cursor_first_page(
    'merge_acl_db',
    '{"aggregate":"source","pipeline":[{"$merge":{"into":"source","whenNotMatched":"discard"}}],"cursor":{}}');
RESET ROLE;
SET ROLE merge_acl_no_source;
SELECT cursorPage IS NOT NULL AS same_collection_requires_source_find
FROM documentdb_api.aggregate_cursor_first_page(
    'merge_acl_db',
    '{"aggregate":"source","pipeline":[{"$merge":{"into":"source","whenNotMatched":"discard"}}],"cursor":{}}');
RESET ROLE;
SELECT COUNT(*) = 1 AND BOOL_AND(
    documentdb_core.bson_to_json_string(document)::text::jsonb =
    '{"_id":"source","value":"new","added":"source"}'::jsonb)
    AS same_collection_data_preserved
FROM documentdb_api.collection('merge_acl_db', 'source');

-- Grant native TRUNCATE explicitly to test only the insert-phase permissions.
CREATE ROLE out_acl_no_update;
CREATE ROLE out_acl_no_insert;
CREATE ROLE out_acl_no_select;
GRANT USAGE ON SCHEMA documentdb_core, documentdb_api, documentdb_api_catalog,
                      documentdb_api_internal, documentdb_data
TO out_acl_no_update, out_acl_no_insert, out_acl_no_select;
GRANT SELECT ON ALL TABLES IN SCHEMA documentdb_api_catalog
TO out_acl_no_update, out_acl_no_insert, out_acl_no_select;
\set ECHO none
SELECT FORMAT('GRANT SELECT ON %s TO out_acl_no_update, out_acl_no_insert, '
              'out_acl_no_select', :'source_relation') \gexec
SELECT FORMAT('GRANT SELECT, INSERT, TRUNCATE ON %s TO out_acl_no_update',
              :'target_relation') \gexec
SELECT FORMAT('GRANT SELECT, UPDATE, TRUNCATE ON %s TO out_acl_no_insert',
              :'target_relation') \gexec
SELECT FORMAT('GRANT INSERT, UPDATE, TRUNCATE ON %s TO out_acl_no_select',
              :'target_relation') \gexec
\set ECHO :previous_echo
SELECT NOT has_table_privilege('out_acl_no_update', :'target_relation', 'UPDATE')
    AS out_has_no_update_privilege;

SET ROLE out_acl_no_update;
SELECT cursorPage IS NOT NULL AS out_without_update_allowed
FROM documentdb_api.aggregate_cursor_first_page(
    'merge_acl_db',
    '{"aggregate":"source","pipeline":[{"$out":"target"}],"cursor":{}}');
RESET ROLE;
SELECT COUNT(*) = 1 AND BOOL_AND(
    documentdb_core.bson_to_json_string(document)::text::jsonb =
    '{"_id":"source","value":"new","added":"source"}'::jsonb)
    AS out_copied_source
FROM documentdb_api.collection('merge_acl_db', 'target');

SET ROLE out_acl_no_insert;
SELECT cursorPage IS NOT NULL AS out_requires_insert
FROM documentdb_api.aggregate_cursor_first_page(
    'merge_acl_db',
    '{"aggregate":"source","pipeline":[{"$out":"target"}],"cursor":{}}');
RESET ROLE;
SET ROLE out_acl_no_select;
SELECT cursorPage IS NOT NULL AS out_requires_select
FROM documentdb_api.aggregate_cursor_first_page(
    'merge_acl_db',
    '{"aggregate":"source","pipeline":[{"$out":"target"}],"cursor":{}}');
RESET ROLE;
SELECT COUNT(*) = 1 AND BOOL_AND(
    documentdb_core.bson_to_json_string(document)::text::jsonb =
    '{"_id":"source","value":"new","added":"source"}'::jsonb)
    AS out_denials_preserved_target
FROM documentdb_api.collection('merge_acl_db', 'target');

DROP OWNED BY out_acl_no_update, out_acl_no_insert, out_acl_no_select;
DROP ROLE out_acl_no_update, out_acl_no_insert, out_acl_no_select;
DROP OWNED BY merge_acl_select, merge_acl_insert, merge_acl_update,
              merge_acl_insert_update, merge_acl_no_source;
DROP ROLE merge_acl_select, merge_acl_insert, merge_acl_update,
          merge_acl_insert_update, merge_acl_no_source;
SELECT documentdb_api.drop_collection('merge_acl_db', 'source');
SELECT documentdb_api.drop_collection('merge_acl_db', 'target');
DROP TABLE merge_acl_actual, merge_acl_cases, merge_acl_subjects, merge_acl_modes;
