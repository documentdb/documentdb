-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.
-- SPDX-License-Identifier: MIT

SET search_path TO documentdb_api,documentdb_api_catalog;

SET documentdb.next_collection_id TO 782400;
SET documentdb.next_collection_index_id TO 782400;

SELECT documentdb_api.create_collection_view(
    'collation_schema_validation_db',
    '{"create":"validator_default","validator":{"state":"ready"},"validationAction":"error"}');
UPDATE documentdb_api_catalog.collections
SET options = '{"collation":{"locale":"en","strength":2}}'::documentdb_core.bson
WHERE database_name = 'collation_schema_validation_db' AND collection_name = 'validator_default';
SELECT documentdb_api_internal.invalidate_collection_cache();

SET documentdb_core.enableCollation TO on;
SET documentdb.skipFailOnCollation TO on;
SELECT documentdb_api.insert(
    'collation_schema_validation_db',
    '{"insert":"validator_default","documents":[{"_id":3,"state":"ready"}],"collation":{"locale":"simple"}}');
-- Ignoring the command collation still enforces the collection validator.
SELECT documentdb_api.insert(
    'collation_schema_validation_db',
    '{"insert":"validator_default","documents":[{"_id":4,"state":"waiting"}],"collation":{"locale":"simple"}}');
RESET documentdb.skipFailOnCollation;

SELECT documentdb_api.insert(
    'collation_schema_validation_db',
    '{"insert":"validator_default","documents":[{"_id":1,"state":"ready"},{"_id":2,"state":"ready"}]}');

-- Insert validators use the collection default when collation is enabled.
SELECT documentdb_api.create_collection_view(
    'collation_schema_validation_paths_db',
    '{"create":"validator_default","validator":{"state":"ready"},"validationAction":"error"}');
UPDATE documentdb_api_catalog.collections
SET options = '{"collation":{"locale":"en","strength":2}}'::documentdb_core.bson
WHERE database_name = 'collation_schema_validation_paths_db' AND collection_name = 'validator_default';
SELECT documentdb_api_internal.invalidate_collection_cache();

-- Only the canonical command field is rejected; other casing is ignored.
SET documentdb.skipFailOnCollation TO off;
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_default","documents":[{"_id":17,"state":"ready"}],"collation":{"locale":"en","strength":2}}');
RESET documentdb.skipFailOnCollation;
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_default","documents":[{"_id":18,"state":"ready"}],"Collation":{"locale":"simple"}}');
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_default","documents":[{"_id":1,"state":"READY"}]}');
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_default","documents":[{"_id":19,"state":"ready","collation":{"locale":"en"}}]}');
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_default","documents":[{"_id":2,"state":"waiting"}]}');
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_default","documents":[{"_id":3,"state":"ReAdY"},{"_id":4,"state":"waiting"},{"_id":5,"state":"ready"}]}');
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_default","ordered":false,"documents":[{"_id":6,"state":"READY"},{"_id":7,"state":"waiting"},{"_id":8,"state":"ready"}]}');
SET documentdb.enableBypassDocumentValidation TO on;
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_default","documents":[{"_id":9,"state":"waiting"}],"bypassDocumentValidation":true}');
RESET documentdb.enableBypassDocumentValidation;

BEGIN;
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_default","documents":[{"_id":11,"state":"READY"}]}');
COMMIT;

SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_default","documents":[{"_id":13,"state":"READY"}]}',
    NULL, 'insert-validator-retry-1');
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_default","documents":[{"_id":13,"state":"READY"}]}',
    NULL, 'insert-validator-retry-1');
CALL documentdb_api.insert_bulk(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_default","ordered":false,"documents":[{"_id":14,"state":"READY"},{"_id":15,"state":"waiting"},{"_id":16,"state":"ready"}]}');
CALL documentdb_api.insert_bulk(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_default","documents":[{"_id":20,"state":"ready"}],"collation":{"locale":"simple"}}');

SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_default","documents":[{"_id":22,"state":"ready"},{"_id":23,"state":"ready"}]}');

SELECT documentdb_api.create_collection_view(
    'collation_schema_validation_paths_db',
    '{"create":"validator_expr_default","validator":{"$expr":{"$eq":["$state","ready"]}}}');
UPDATE documentdb_api_catalog.collections
SET options = '{"collation":{"locale":"en","strength":2}}'::documentdb_core.bson
WHERE database_name = 'collation_schema_validation_paths_db' AND collection_name = 'validator_expr_default';
SELECT documentdb_api_internal.invalidate_collection_cache();
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_expr_default","documents":[{"_id":1,"state":"READY"}]}');
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_expr_default","documents":[{"_id":2,"state":"waiting"}]}');

SELECT documentdb_api.create_collection_view(
    'collation_schema_validation_db',
    '{"create":"validator_expr_default","validator":{"$expr":{"$eq":["$state","ready"]}}}');
UPDATE documentdb_api_catalog.collections
SET options = '{"collation":{"locale":"en","strength":2}}'::documentdb_core.bson
WHERE database_name = 'collation_schema_validation_db' AND collection_name = 'validator_expr_default';
SELECT documentdb_api_internal.invalidate_collection_cache();
SELECT documentdb_api.insert(
    'collation_schema_validation_db',
    '{"insert":"validator_expr_default","documents":[{"_id":5,"state":"ready"},{"_id":6,"state":"ready"}]}');

SELECT documentdb_api.create_collection_view(
    'collation_schema_validation_paths_db',
    '{"create":"validator_simple","validator":{"state":"ready"}}');
UPDATE documentdb_api_catalog.collections
SET options = '{"collation":{"locale":"simple"}}'::documentdb_core.bson
WHERE database_name = 'collation_schema_validation_paths_db' AND collection_name = 'validator_simple';
SELECT documentdb_api_internal.invalidate_collection_cache();
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_simple","documents":[{"_id":1,"state":"READY"}]}');
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_simple","documents":[{"_id":2,"state":"ready"}]}');

SELECT documentdb_api.create_collection_view(
    'collation_schema_validation_paths_db',
    '{"create":"validator_no_default","validator":{"state":"ready"}}');
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_no_default","documents":[{"_id":1,"state":"READY"}]}');
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_no_default","documents":[{"_id":2,"state":"ready"}]}');

SET documentdb_core.enableCollation TO off;

SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_expr_default","documents":[{"_id":3,"state":"READY"}]}');
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_expr_default","documents":[{"_id":4,"state":"ready"}]}');

SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_default","documents":[{"_id":21,"state":"ready"}],"collation":null}');
SELECT documentdb_api.insert(
    'collation_schema_validation_paths_db',
    '{"insert":"validator_default","documents":[{"_id":12,"state":"READY"}]}');

SET documentdb_core.enableCollation TO on;

SET documentdb.enable_collation_with_schema_validation TO off;
SELECT documentdb_api.update(
    'collation_schema_validation_db',
    '{"update":"validator_default","updates":[{"q":{"_id":{"$in":[1,2]}},"u":{"$set":{"state":"READY"}},"multi":true}]}');
SET documentdb.enable_collation_with_schema_validation TO on;
SELECT documentdb_api.update(
    'collation_schema_validation_db',
    '{"update":"validator_default","updates":[{"q":{"_id":{"$in":[1,2]}},"u":{"$set":{"state":"READY"}},"multi":true,"collation":{"locale":"simple"}}]}');
SELECT documentdb_api.update(
    'collation_schema_validation_db',
    '{"update":"validator_default","updates":[{"q":{"_id":{"$in":[1,2]}},"u":{"$set":{"state":"waiting"}},"multi":true}]}');
RESET documentdb.enable_collation_with_schema_validation;

-- A validator field named "collation" remains a field constraint.
SELECT documentdb_api_internal.schema_validation_against_update(
    '{"state":"ready","collation":"en"}'::documentdb_core.bson,
    '{"state":"ready","collation":"en"}'::documentdb_core.bson,
    '{}'::documentdb_core.bson, false);
SELECT documentdb_api_internal.schema_validation_against_update(
    '{"state":"ready","collation":"en"}'::documentdb_core.bson,
    '{"state":"ready","collation":"fr"}'::documentdb_core.bson,
    '{}'::documentdb_core.bson, false);

-- Malformed validator wrappers are rejected before evaluation.
SET documentdb.enable_collation_with_schema_validation TO on;
SELECT documentdb_api_internal.schema_validation_against_update(
    '{"$__schema_validator":{"state":"ready"}}'::documentdb_core.bson,
    '{"state":"ready"}'::documentdb_core.bson,
    '{}'::documentdb_core.bson, false);
SELECT documentdb_api_internal.schema_validation_against_update(
    '{"$__schema_validator":1,"collation":"en"}'::documentdb_core.bson,
    '{"state":"ready"}'::documentdb_core.bson,
    '{}'::documentdb_core.bson, false);
RESET documentdb.enable_collation_with_schema_validation;

-- Validator comparisons use the collection default, not the operation collation.
SELECT documentdb_api.update(
    'collation_schema_validation_paths_db',
    '{"update":"validator_default","updates":[{"q":{"_id":8},"u":{"$set":{"state":"READY"}},"multi":false,"collation":{"locale":"simple"}}]}');
SELECT documentdb_api.find_and_modify(
    'collation_schema_validation_paths_db',
    '{"findAndModify":"validator_default","query":{"_id":19},"update":{"$set":{"state":"READY"}},"new":true,"collation":{"locale":"simple"}}');
SELECT documentdb_api.update(
    'collation_schema_validation_paths_db',
    '{"update":"validator_default","updates":[{"q":{"_id":8},"u":{"$set":{"state":"waiting"}},"multi":false}]}');
SELECT documentdb_api.find_and_modify(
    'collation_schema_validation_paths_db',
    '{"findAndModify":"validator_default","query":{"_id":19},"update":{"$set":{"state":"waiting"}},"new":true}');

-- Multi-updates validate through a separate SQL function.
SET documentdb.enable_collation_with_schema_validation TO on;
SELECT documentdb_api.update(
    'collation_schema_validation_paths_db',
    '{"update":"validator_default","updates":[{"q":{"_id":{"$in":[22,23]}},"u":{"$set":{"state":"READY"}},"multi":true,"collation":{"locale":"simple"}}]}');
SELECT documentdb_api.update(
    'collation_schema_validation_paths_db',
    '{"update":"validator_default","updates":[{"q":{"_id":{"$in":[22,23]}},"u":{"$set":{"state":"waiting"}},"multi":true}]}');
RESET documentdb.enable_collation_with_schema_validation;

SELECT documentdb_api.find_and_modify(
    'collation_schema_validation_paths_db',
    '{"findAndModify":"validator_expr_default","query":{"_id":1},"update":{"$set":{"state":"ReAdY"}},"new":true}');

SET documentdb.enable_collation_with_schema_validation TO on;
SELECT documentdb_api.update(
    'collation_schema_validation_db',
    '{"update":"validator_expr_default","updates":[{"q":{"_id":{"$in":[5,6]}},"u":{"$set":{"state":"ReAdY"}},"multi":true}]}');
SELECT documentdb_api.update(
    'collation_schema_validation_db',
    '{"update":"validator_expr_default","updates":[{"q":{"_id":{"$in":[5,6]}},"u":{"$set":{"state":"waiting"}},"multi":true}]}');

SET documentdb_core.enableCollation TO off;
SELECT documentdb_api.update(
    'collation_schema_validation_db',
    '{"update":"validator_default","updates":[{"q":{"_id":{"$in":[1,2]}},"u":{"$set":{"state":"ReAdY"}},"multi":true}]}');
SELECT documentdb_api.update(
    'collation_schema_validation_db',
    '{"update":"validator_default","updates":[{"q":{"_id":{"$in":[1,2]}},"u":{"$set":{"state":"ready"}},"multi":true}]}');

SELECT documentdb_api.update(
    'collation_schema_validation_paths_db',
    '{"update":"validator_default","updates":[{"q":{"_id":8},"u":{"$set":{"state":"ReAdY"}},"multi":false}]}');
SELECT documentdb_api.find_and_modify(
    'collation_schema_validation_paths_db',
    '{"findAndModify":"validator_default","query":{"_id":19},"update":{"$set":{"state":"ReAdY"}},"new":true}');
SELECT documentdb_api.find_and_modify(
    'collation_schema_validation_paths_db',
    '{"findAndModify":"validator_expr_default","query":{"_id":4},"update":{"$set":{"state":"READY"}},"new":true}');
SELECT documentdb_api.update(
    'collation_schema_validation_paths_db',
    '{"update":"validator_default","updates":[{"q":{"_id":8},"u":{"$set":{"state":"ready"}},"multi":false}]}');
SELECT documentdb_api.find_and_modify(
    'collation_schema_validation_paths_db',
    '{"findAndModify":"validator_default","query":{"_id":19},"update":{"$set":{"state":"ready"}},"new":true}');

SELECT count(*) FROM documentdb_api.collection('collation_schema_validation_paths_db', 'validator_default');

RESET documentdb.enable_collation_with_schema_validation;
RESET documentdb_core.enableCollation;
RESET search_path;
