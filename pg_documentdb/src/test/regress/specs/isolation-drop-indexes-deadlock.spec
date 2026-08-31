# Validates that two simultaneous non-concurrent dropIndexes on the same
# collection serialize instead of deadlocking.
#
# Pre-fix hazard: a non-concurrent dropIndexes resolved the collection under a
# weak AccessShareLock, then upgraded to AccessExclusiveLock to drop the index
# within the same transaction. Two such drops could each hold the weak lock at
# once and then each block upgrading, waiting on the lock the other held -- a
# classic lock-upgrade deadlock.
#
# To force both drops into that window at once, a third session holds an
# AccessExclusiveLock on the index metadata table, blocking each drop right
# after it has taken the collection table lock but before it touches metadata.
# With the old weak-then-upgrade behavior the two drops deadlock; resolving the
# collection at AccessExclusiveLock up front makes them serialize at
# acquisition, so both succeed.

setup
{
    SELECT documentdb_api.create_collection('isolation', 'dropIdxDeadlock');
    SELECT documentdb_api_internal.create_indexes_non_concurrently('isolation',
        documentdb_core.bson_build_document(
            'createIndexes', 'dropIdxDeadlock'::text,
            'indexes', ARRAY[
                documentdb_core.bson_build_document('key', documentdb_core.bson_build_document('title', 1), 'name', 'title_1'::text),
                documentdb_core.bson_build_document('key', documentdb_core.bson_build_document('owner', 1), 'name', 'owner_1'::text)
            ]),
        true);
}

teardown
{
    SELECT documentdb_api.drop_collection('isolation', 'dropIdxDeadlock');
}

session "s1"

step "s1-drop-title"
{
    CALL documentdb_api.drop_indexes('isolation',
        documentdb_core.bson_build_document('dropIndexes', 'dropIdxDeadlock'::text, 'index', ARRAY['title_1'::text]));
}

session "s2"

step "s2-drop-owner"
{
    CALL documentdb_api.drop_indexes('isolation',
        documentdb_core.bson_build_document('dropIndexes', 'dropIdxDeadlock'::text, 'index', ARRAY['owner_1'::text]));
}

session "s3"

step "s3-block-metadata"
{
    BEGIN;
    LOCK TABLE documentdb_api_catalog.collection_indexes IN ACCESS EXCLUSIVE MODE;
}

step "s3-release"
{
    COMMIT;
}

permutation "s3-block-metadata" "s1-drop-title" "s2-drop-owner" "s3-release"
