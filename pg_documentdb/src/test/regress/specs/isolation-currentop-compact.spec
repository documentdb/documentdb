# Validates that a compact operation is observable via currentOp and that
# compact fails fast when a conflicting operation already holds a lock on the
# collection.
#
# The real compact command runs the VACUUM on a separate connection, so it
# cannot be made to block deterministically inside the isolation tester. To
# exercise the currentOp surface we temporarily replace the compact function
# with a stub that takes an AccessExclusiveLock on the collection table (the
# same lock level VACUUM FULL needs). While that stub is blocked on a lock held
# by another session, currentOp maps the waited-on collection table back to the
# namespace and reports the operation.
#
# Permutations:
#   1. A conflicting lock is held while the real compact runs -- compact
#      validates the lock level up front and errors out; once the lock is
#      released compact succeeds.
#   2. The stub compact blocks on a held lock and shows up in currentOp with the
#      expected namespace while it waits.

setup
{
    SELECT documentdb_api.create_collection('isolation', 'compact-currentop-test');
}

teardown
{
    SELECT documentdb_api.drop_collection('isolation', 'compact-currentop-test');
}

session "s1"

step "s1-take-lock"
{
    BEGIN;
    DO $$
    DECLARE cid bigint;
    BEGIN
        SELECT collection_id INTO cid FROM documentdb_api_catalog.collections
            WHERE database_name = 'isolation' AND collection_name = 'compact-currentop-test';
        EXECUTE format('LOCK TABLE documentdb_data.documents_%s IN ACCESS EXCLUSIVE MODE', cid);
    END $$;
}

step "s1-release-lock"
{
    COMMIT;
}

session "s2"

step "s2-real-compact"
{
    SET documentdb_api.enableCompactVacuumFull TO on;
    SELECT documentdb_api.compact(documentdb_core.bson_build_document('compact', 'compact-currentop-test'::text, '$db', 'isolation'::text));
    RESET documentdb_api.enableCompactVacuumFull;
}

step "s2-begin-stub-compact"
{
    BEGIN;

    CREATE OR REPLACE FUNCTION documentdb_api.compact(p_spec documentdb_core.bson)
    RETURNS documentdb_core.bson
    SET search_path TO documentdb_api_catalog, pg_catalog
    AS $fn$
    DECLARE cid bigint;
    BEGIN
        -- Take an AccessExclusiveLock to simulate VACUUM FULL.
        SELECT collection_id INTO cid FROM documentdb_api_catalog.collections
            WHERE database_name = 'isolation' AND collection_name = 'compact-currentop-test';
        EXECUTE format('LOCK TABLE documentdb_data.documents_%s IN ACCESS EXCLUSIVE MODE', cid);
        RETURN documentdb_core.bson_build_document('ok', 1);
    END
    $fn$ LANGUAGE plpgsql;

    SELECT documentdb_api.compact(NULL);
}

step "s2-rollback-stub-compact"
{
    ROLLBACK;
}

session "s3"

step "s3-current-op-compact"
{
    -- Filter to the compact operation's namespace so the assertion is
    -- deterministic regardless of other background/session activity.
    SELECT documentdb_api_catalog.bson_dollar_project(
        document,
        documentdb_core.bson_build_document('opid', 0, 'secs_running', 0, 'locking_op_prefixes', 0, 'op_prefix', 0, 'currentOpTime', 0))
    FROM documentdb_api_internal.current_op_aggregation(
        documentdb_core.bson_build_document('allUsers', true, 'localOps', true, 'idleSessions', true, 'idleConnections', true))
    WHERE document OPERATOR(documentdb_api_catalog.@@) documentdb_core.bson_build_document('ns', 'isolation.compact-currentop-test'::text);
}

permutation "s1-take-lock" "s2-real-compact" "s1-release-lock" "s2-real-compact"
permutation "s1-take-lock" "s2-begin-stub-compact" "s3-current-op-compact" "s1-release-lock" "s2-rollback-stub-compact"
