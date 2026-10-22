# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# SPDX-License-Identifier: MIT

# Write collation across collection-creation and row-lock races.
# Omitted collation must inherit the collection default, while explicit simple
# must preserve binary matching after either transaction handoff.

teardown
{
    SELECT documentdb_api.drop_collection('collation_race_db', 'upsert_creation');
    SELECT documentdb_api.drop_collection('collation_race_db', 'delete_recheck');
}

session "writer"
setup
{
    SET documentdb_core.enableCollation TO on;
}

# Neither the collection default nor its document is visible when the client
# parses the update batch. The upsert waits for creation, and the runner
# advances to commit-create only after observing that wait.
step "create-with-default"
{
    BEGIN;
    SELECT documentdb_api.create_collection('collation_race_db', 'upsert_creation');
    UPDATE documentdb_api_catalog.collections
    SET options = documentdb_core.bson_build_document(
        'collation', documentdb_core.bson_build_document(
            'locale', 'en'::text, 'strength', 1))
    WHERE database_name = 'collation_race_db'
      AND collection_name = 'upsert_creation';
    SELECT 1 FROM documentdb_api.insert_one('collation_race_db', 'upsert_creation',
        documentdb_core.bson_build_document('_id', 1, 'value', U&'caf\00e9'::text));
}

step "commit-create"
{
    COMMIT;
}

# Delete has no upsert-creation race: commit its fixture before taking row locks.
step "prepare-delete"
{
    SELECT documentdb_api.create_collection('collation_race_db', 'delete_recheck');
    UPDATE documentdb_api_catalog.collections
    SET options = documentdb_core.bson_build_document(
        'collation', documentdb_core.bson_build_document(
            'locale', 'en'::text, 'strength', 1))
    WHERE database_name = 'collation_race_db'
      AND collection_name = 'delete_recheck';
    SELECT 1 FROM documentdb_api.insert_one('collation_race_db', 'delete_recheck',
        documentdb_core.bson_build_document('_id', 1, 'value', U&'caf\00e9'::text));
    SELECT 1 FROM documentdb_api.insert_one('collation_race_db', 'delete_recheck',
        documentdb_core.bson_build_document('_id', 2, 'value', U&'caf\00e9'::text));
}

# Lock the tuples without replacing their versions, so this race isolates
# collation-sensitive matching rather than concurrent row replacement.
step "lock-delete-rows"
{
    BEGIN;
    DO $$
    DECLARE cid bigint;
    BEGIN
        SELECT collection_id INTO STRICT cid FROM documentdb_api_catalog.collections
            WHERE database_name = 'collation_race_db' AND collection_name = 'delete_recheck';
        EXECUTE format('SELECT 1 FROM documentdb_data.documents_%s FOR UPDATE', cid);
    END $$;
}

step "release-delete-locks"
{
    COMMIT;
}

session "client"
setup
{
    SET documentdb_core.enableCollation TO on;
}

# The plain update precedes the upsert to verify that discovering the default
# refreshes every inherited batch entry, not only the entry that creates a row.
step "upsert-inherited"
{
    SELECT documentdb_api.update('collation_race_db',
        documentdb_core.bson_build_document(
            'update', 'upsert_creation'::text,
            'updates', ARRAY[
                documentdb_core.bson_build_document(
                    'q', documentdb_core.bson_build_document('value', 'CAFE'::text),
                    'u', documentdb_core.bson_build_document(
                        '$set', documentdb_core.bson_build_document('regular_hit', true))),
                documentdb_core.bson_build_document(
                    'q', documentdb_core.bson_build_document('value', 'CAFE'::text),
                    'u', documentdb_core.bson_build_document(
                        '$set', documentdb_core.bson_build_document('hit', true),
                        '$setOnInsert', documentdb_core.bson_build_document('_id', 2)),
                    'upsert', true)
            ]));
}

step "upsert-simple"
{
    SELECT documentdb_api.update('collation_race_db',
        documentdb_core.bson_build_document(
            'update', 'upsert_creation'::text,
            'updates', ARRAY[
                documentdb_core.bson_build_document(
                    'q', documentdb_core.bson_build_document('value', 'CAFE'::text),
                    'u', documentdb_core.bson_build_document(
                        '$set', documentdb_core.bson_build_document('regular_hit', true)),
                    'collation', documentdb_core.bson_build_document(
                        'locale', 'simple'::text)),
                documentdb_core.bson_build_document(
                    'q', documentdb_core.bson_build_document('value', 'CAFE'::text),
                    'u', documentdb_core.bson_build_document(
                        '$set', documentdb_core.bson_build_document('hit', true),
                        '$setOnInsert', documentdb_core.bson_build_document('_id', 2)),
                    'upsert', true,
                    'collation', documentdb_core.bson_build_document(
                        'locale', 'simple'::text))
            ]));
}

step "check-upsert-rows"
{
    SELECT count(*) AS total_rows,
        count(*) FILTER (WHERE document OPERATOR(documentdb_api_catalog.@@)
            documentdb_core.bson_build_document('hit', true)) AS modified_rows,
        count(*) FILTER (WHERE document OPERATOR(documentdb_api_catalog.@@)
            documentdb_core.bson_build_document('regular_hit', true)) AS regular_modified_rows
    FROM documentdb_api.collection('collation_race_db', 'upsert_creation');
    SELECT document FROM documentdb_api.collection('collation_race_db', 'upsert_creation')
    ORDER BY object_id;
}

# Query the string field rather than _id so matching depends on collation.
step "delete-one-inherited"
{
    SELECT documentdb_api.delete('collation_race_db',
        documentdb_core.bson_build_document(
            'delete', 'delete_recheck'::text,
            'deletes', ARRAY[
                documentdb_core.bson_build_document(
                    'q', documentdb_core.bson_build_document('value', 'cafe'::text),
                    'limit', 1)
            ]));
}

step "delete-many-inherited"
{
    SELECT documentdb_api.delete('collation_race_db',
        documentdb_core.bson_build_document(
            'delete', 'delete_recheck'::text,
            'deletes', ARRAY[
                documentdb_core.bson_build_document(
                    'q', documentdb_core.bson_build_document('value', 'cafe'::text),
                    'limit', 0)
            ]));
}

step "delete-one-simple"
{
    SELECT documentdb_api.delete('collation_race_db',
        documentdb_core.bson_build_document(
            'delete', 'delete_recheck'::text,
            'deletes', ARRAY[
                documentdb_core.bson_build_document(
                    'q', documentdb_core.bson_build_document('value', 'cafe'::text),
                    'limit', 1,
                    'collation', documentdb_core.bson_build_document(
                        'locale', 'simple'::text))
            ]));
}

step "delete-many-simple"
{
    SELECT documentdb_api.delete('collation_race_db',
        documentdb_core.bson_build_document(
            'delete', 'delete_recheck'::text,
            'deletes', ARRAY[
                documentdb_core.bson_build_document(
                    'q', documentdb_core.bson_build_document('value', 'cafe'::text),
                    'limit', 0,
                    'collation', documentdb_core.bson_build_document(
                        'locale', 'simple'::text))
            ]));
}

step "check-delete-rows"
{
    SELECT count(*) AS remaining_rows,
        count(*) FILTER (WHERE document OPERATOR(documentdb_api_catalog.@@)
            documentdb_core.bson_build_document('value', U&'caf\00e9'::text)) AS accented_rows
    FROM documentdb_api.collection('collation_race_db', 'delete_recheck');
}

# Both inherited updates must modify the existing accented value: n=2,
# nModified=2, and only one row remains.
permutation "create-with-default" "upsert-inherited" "commit-create" "check-upsert-rows"

# Explicit simple must survive the same refresh: the plain update is a no-op
# and the upsert inserts the binary-distinct value, leaving two rows.
permutation "create-with-default" "upsert-simple" "commit-create" "check-upsert-rows"

# The inherited deletes match accented values and must wait before the runner
# releases the locks: deleteOne removes one row; deleteMany removes both.
permutation "prepare-delete" "lock-delete-rows" "delete-one-inherited" "release-delete-locks" "check-delete-rows"
permutation "prepare-delete" "lock-delete-rows" "delete-many-inherited" "release-delete-locks" "check-delete-rows"

# Explicit simple matches neither accented value, so it must finish without
# waiting for the held locks: n=0 and both rows remain.
permutation "prepare-delete" "lock-delete-rows" "delete-one-simple" "release-delete-locks" "check-delete-rows"
permutation "prepare-delete" "lock-delete-rows" "delete-many-simple" "release-delete-locks" "check-delete-rows"
