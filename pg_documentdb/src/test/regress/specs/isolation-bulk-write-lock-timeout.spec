# Validates the behavioral difference between the function (SELECT) and
# procedure (CALL _bulk) write paths with respect to read-committed
# visibility when a concurrent lock is held.
#
# Setup: s1 holds a row lock on _id=1 via an uncommitted transaction.
# s2 writes to _id=2 first, then _id=1 (blocking on s1's lock).
# While s2 is blocked, s3 reads both rows under READ COMMITTED.
#
# Function path (SELECT update/insert):
#   The entire multi-doc write is a single statement/transaction.
#   While s2 blocks on _id=1, nothing from s2 is committed yet,
#   so s3 sees no changes from s2 (0 new rows for insert, old
#   values for update).
#
# Bulk procedure path (CALL update_bulk/insert_bulk):
#   The procedure processes docs individually via subtransactions.
#   _id=2 succeeds and commits before _id=1 is attempted.
#   While s2 blocks on _id=1, s3 can already see _id=2's changes.
#   After s1 commits/rolls back, s2 completes and s3 sees all changes.
#
# Permutations:
#   1. update via function  — s3 sees original rows while s2 is blocked
#   2. update via bulk proc — s3 sees _id=2 updated while s2 is blocked
#   3. insert via function  — s3 sees 0 new rows while s2 is blocked
#   4. insert via bulk proc — s3 sees _id=2 inserted while s2 is blocked

setup
{
    SELECT documentdb_api.create_collection('isolation', 'bulkWriteTest');

    SELECT 1 FROM documentdb_api.insert_one('isolation','bulkWriteTest',
        documentdb_core.bson_build_document('_id', 1, 'a', 1));
    SELECT 1 FROM documentdb_api.insert_one('isolation','bulkWriteTest',
        documentdb_core.bson_build_document('_id', 2, 'a', 2));

    SELECT documentdb_api.create_collection('isolation', 'bulkInsertTest');
}

teardown
{
    SELECT documentdb_api.drop_collection('isolation','bulkWriteTest');
    SELECT documentdb_api.drop_collection('isolation','bulkInsertTest');
}

session "s1"

step "s1-begin"
{
    BEGIN;
}

step "s1-lock-row1-update"
{
    -- Hold a row lock on _id=1 by updating it without committing.
    SELECT documentdb_api.update('isolation',
        documentdb_core.bson_build_document(
            'update', 'bulkWriteTest'::text,
            'updates', ARRAY[
                documentdb_core.bson_build_document(
                    'q', documentdb_core.bson_build_document('_id', 1),
                    'u', documentdb_core.bson_build_document('$set',
                        documentdb_core.bson_build_document('locked', true)),
                    'multi', false
                )
            ]
        ));
}

step "s1-insert-hold-lock-row1"
{
    -- Insert _id=1 without committing; holds the unique-index lock.
    SELECT 1 FROM documentdb_api.insert_one('isolation','bulkInsertTest',
        documentdb_core.bson_build_document('_id', 1, 'a', 99));
}

step "s1-commit"
{
    COMMIT;
}

step "s1-rollback"
{
    ROLLBACK;
}

session "s2"

step "s2-disable-batch"
{
    -- Set lock_timeout to 1ms so the batch subtransaction fails almost
    -- immediately on _id=1, then the single-doc fallback commits _id=2
    -- before blocking on _id=1 with the default (infinite) lock_timeout.
    SET documentdb.batchUpdateLockTimeoutMs TO 1;
}

step "s2-func-update"
{
    -- Update _id=2 then _id=1 via the function path (single statement).
    -- Blocks on _id=1 since s1 holds the lock. Nothing is visible until
    -- the entire statement completes.
    SELECT documentdb_api.update('isolation',
        documentdb_core.bson_build_document(
            'update', 'bulkWriteTest'::text,
            'updates', ARRAY[
                documentdb_core.bson_build_document(
                    'q', documentdb_core.bson_build_document('_id', 2),
                    'u', documentdb_core.bson_build_document('$set',
                        documentdb_core.bson_build_document('b', 20)),
                    'multi', false
                ),
                documentdb_core.bson_build_document(
                    'q', documentdb_core.bson_build_document('_id', 1),
                    'u', documentdb_core.bson_build_document('$set',
                        documentdb_core.bson_build_document('b', 10)),
                    'multi', false
                )
            ],
            'ordered', false
        ));
}

step "s2-bulk-update"
{
    -- Update _id=2 then _id=1 via the bulk procedure path.
    -- _id=2 succeeds and is committed immediately. _id=1 blocks on s1.
    -- While blocked, s3 can see _id=2's update.
    CALL documentdb_api.update_bulk('isolation',
        documentdb_core.bson_build_document(
            'update', 'bulkWriteTest'::text,
            'updates', ARRAY[
                documentdb_core.bson_build_document(
                    'q', documentdb_core.bson_build_document('_id', 2),
                    'u', documentdb_core.bson_build_document('$set',
                        documentdb_core.bson_build_document('b', 20)),
                    'multi', false
                ),
                documentdb_core.bson_build_document(
                    'q', documentdb_core.bson_build_document('_id', 1),
                    'u', documentdb_core.bson_build_document('$set',
                        documentdb_core.bson_build_document('b', 10)),
                    'multi', false
                )
            ],
            'ordered', false
        ));
}

step "s2-func-insert"
{
    -- Insert _id=2 then _id=1 via the function path (single statement).
    -- Blocks on _id=1 since s1 holds the unique-index lock.
    SELECT documentdb_api.insert('isolation',
        documentdb_core.bson_build_document(
            'insert', 'bulkInsertTest'::text,
            'documents', ARRAY[
                documentdb_core.bson_build_document('_id', 2, 'a', 20),
                documentdb_core.bson_build_document('_id', 1, 'a', 10)
            ]
        ));
}

step "s2-bulk-insert"
{
    -- Insert _id=2 then _id=1 via the bulk procedure path.
    -- _id=2 succeeds and is committed independently. _id=1 blocks on s1.
    -- While blocked, s3 can see _id=2's insert.
    CALL documentdb_api.insert_bulk('isolation',
        documentdb_core.bson_build_document(
            'insert', 'bulkInsertTest'::text,
            'documents', ARRAY[
                documentdb_core.bson_build_document('_id', 2, 'a', 20),
                documentdb_core.bson_build_document('_id', 1, 'a', 10)
            ]
        ));
}

session "s3"

step "s3-read-update-rows"
{
    -- Read both rows from the update test collection.
    SELECT document FROM documentdb_api.collection('isolation', 'bulkWriteTest')
        ORDER BY document;
}

step "s3-read-insert-rows"
{
    -- Read all rows from the insert test collection.
    SELECT document FROM documentdb_api.collection('isolation', 'bulkInsertTest')
        ORDER BY document;
}

# Permutation 1: update via function path
# s2 blocks on _id=1; s3 reads while blocked (sees original rows); s1 commits;
# s2 completes; s3 reads again (sees both updated).
permutation "s1-begin" "s1-lock-row1-update" "s2-func-update" "s3-read-update-rows" "s1-commit" "s3-read-update-rows"

# Permutation 2: update via bulk procedure path
# s2 blocks on _id=1; s3 reads while blocked (sees _id=2 updated);
# s1 commits; s2 completes; s3 reads again (sees both updated).
permutation "s1-begin" "s1-lock-row1-update" "s2-disable-batch" "s2-bulk-update" "s3-read-update-rows" "s1-commit" "s3-read-update-rows"

# Permutation 3: insert via function path
# s2 blocks on _id=1; s3 reads while blocked (sees 0 rows);
# s1 rolls back; s2 completes; s3 reads again (sees both inserted).
permutation "s1-begin" "s1-insert-hold-lock-row1" "s2-func-insert" "s3-read-insert-rows" "s1-rollback" "s3-read-insert-rows"

# Permutation 4: insert via bulk procedure path
# s2 blocks on _id=1; s3 reads while blocked (sees _id=2);
# s1 rolls back; s2 completes; s3 reads again (sees both inserted).
permutation "s1-begin" "s1-insert-hold-lock-row1" "s2-disable-batch" "s2-bulk-insert" "s3-read-insert-rows" "s1-rollback" "s3-read-insert-rows"
