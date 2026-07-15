# When documentdb_rum.enable_emit_reuse_page_on_recycle is ON, the
# RUM page allocator (RumNewBuffer) emits XLOG_BTREE_REUSE_PAGE before
# returning a vacuum-deleted page pulled back from the free-space map.
# The record itself does not modify any page; its sole purpose is to
# give standbys a snapshot-conflict horizon (so that snapshots that
# could still see entries that lived on the page get cancelled before
# the page contents are overwritten).
#
# This test validates:
#   1. The recycle path actually fires under a workload that empties
#      RUM entry-leaf pages via VACUUM and then re-grows the index, and
#      the primary emits at least one XLOG_BTREE_REUSE_PAGE record.y
#   2. A streaming standby holding a pre-recycle snapshot has its query
#      cancelled with "conflict with recovery" once the REUSE_PAGE
#      record is replayed (with max_standby_streaming_delay = 0 and
#      hot_standby_feedback = off).
#   3. After replay, primary and standby agree on row count, index scan
#      result, and index page count (basic WAL-redo sanity check).

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# ============================================================================
# PART 1: Initialize primary node
# ============================================================================
my $node_primary = PostgreSQL::Test::Cluster->new('primary');
$node_primary->init(allows_streaming => 1);

my $test_dir = $ENV{TESTDIR};
$node_primary->append_conf('postgresql.conf', qq{
include '$test_dir/postgresql.conf'
documentdb_rum.enable_support_dead_index_items = 'on'
documentdb_rum.enable_emit_reuse_page_on_recycle = 'on'
documentdb_rum.prune_rum_empty_pages = 'on'
documentdb_rum.skip_global_visibility_check_on_prune = 'on'
});

$node_primary->start;

my $result = $node_primary->safe_psql('postgres', "SELECT pg_is_in_recovery()");
is($result, 'f', 'primary is not in recovery');

# ============================================================================
# PART 2: Create extensions, collection, and index on primary
# ============================================================================
$node_primary->safe_psql('postgres', q{
CREATE EXTENSION IF NOT EXISTS documentdb_core CASCADE;
CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;
CREATE EXTENSION IF NOT EXISTS documentdb_extended_rum CASCADE;
});

$result = $node_primary->safe_psql('postgres',
    "SHOW documentdb_rum.enable_emit_reuse_page_on_recycle");
is($result, 'on', 'enable_emit_reuse_page_on_recycle is on');

$node_primary->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SET documentdb.next_collection_id TO 8900;
SET documentdb.next_collection_index_id TO 8900;
SELECT documentdb_api.create_collection('testdb', 'reclaim_test');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'testdb',
    '{"createIndexes": "reclaim_test", "indexes": [{"key": {"a": 1}, "name": "idx_a"}]}',
    true
);
});

my $coll_id = $node_primary->safe_psql('postgres', q{
SELECT collection_id FROM documentdb_api_catalog.collections
    WHERE database_name = 'testdb' AND collection_name = 'reclaim_test';
});
is($coll_id, '8901', 'collection created with expected ID');

# ============================================================================
# PART 3: Take backup, create streaming standby with delay = 0
#
# max_standby_streaming_delay = 0 makes the standby cancel conflicting
# backends immediately upon seeing a REUSE_PAGE record whose
# snapshotConflictHorizon is not visible to the held snapshot.
# hot_standby_feedback = off ensures the primary's xmin horizon is not
# pinned by the standby session, so the primary can actually emit a
# REUSE_PAGE record with a useful conflict horizon.
# ============================================================================
my $backup_name = 'reclaim_backup';
$node_primary->backup($backup_name);

my $node_standby = PostgreSQL::Test::Cluster->new('standby');
$node_standby->init_from_backup($node_primary, $backup_name,
    has_streaming => 1);
$node_standby->append_conf('postgresql.conf', qq{
hot_standby = on
hot_standby_feedback = off
max_standby_streaming_delay = 0
});
$node_standby->start;

$result = $node_standby->safe_psql('postgres', "SELECT pg_is_in_recovery()");
is($result, 't', 'standby is in recovery mode');

# ============================================================================
# PART 4: Prime the RUM index with vacuum-deleted entry-leaf pages
#
# To force RumNewBuffer into the recycle branch we need:
#   (a) RUM pages that VACUUM has marked deleted and stamped with a
#       deleteXid (RumPageSetDeleteXid), so they sit in the FSM waiting
#       to be reused, and
#   (b) a subsequent insert wave that requests new pages (via splits),
#       causing RumNewBuffer to pull one of those deleted pages back
#       from the FSM and emit XLOG_BTREE_REUSE_PAGE.
#
# rumvacuumcleanup walks every page in the index and, for any empty
# entry leaf, calls RumPageMarkAsDeleted (gated by
# documentdb_rum.prune_rum_empty_pages) and adds the block to the FSM.
# So all we need is a workload that fills several entry leaves, then
# empties them, then refills.
#
# The priming workload below:
#   1. Inserts 800 docs with unique 600-byte string values for "a".
#      Each term occupies its own entry-leaf line pointer (RUM cannot
#      compress distinct large strings), so the entry tree splits into
#      multiple leaf pages.
#   2. Deletes all rows with _id >= 50, leaving only a small anchor.
#   3. VACUUM (FREEZE ON, INDEX_CLEANUP ON) so the bulk-delete pass
#      empties the entry leaves and the cleanup pass marks them
#      deleted and records them in the FSM.
# ============================================================================
$node_primary->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
DO $$
BEGIN
    FOR i IN 1..800 LOOP
        PERFORM documentdb_api.insert_one(
            'testdb',
            'reclaim_test',
            FORMAT(
                '{"_id": %s, "a": "%s%s"}',
                i,
                lpad(i::text, 5, '0'),
                repeat('p', 600)
            )::documentdb_core.bson
        );
    END LOOP;
END;
$$;
});

# Find the shard table name so we can disable autovacuum and run VACUUM
# directly. On non-Citus deployments we use the parent table.
my $shard_table = $node_primary->safe_psql('postgres', qq{
SET citus.override_table_visibility TO false;
SELECT n.nspname || '.' || c.relname
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relname LIKE 'documents_${coll_id}_%' AND c.relkind = 'r' LIMIT 1;
});
$shard_table = "documentdb_data.documents_${coll_id}" if $shard_table eq '';

$node_primary->safe_psql('postgres', qq{
SET citus.override_table_visibility TO false;
ALTER TABLE $shard_table SET (autovacuum_enabled = false, toast.autovacuum_enabled = false);
});

$node_primary->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SELECT documentdb_api.delete(
    'testdb',
    '{"delete": "reclaim_test", "deletes": [{"q": {"_id": {"$gte": 50}}, "limit": 0}]}'::documentdb_core.bson
);
});

$node_primary->safe_psql('postgres', qq{
SET citus.override_table_visibility TO false;
VACUUM (FREEZE ON, INDEX_CLEANUP ON) $shard_table;
});

my $rum_index = $node_primary->safe_psql('postgres', qq{
SET citus.override_table_visibility TO false;
SELECT n.nspname || '.' || c.relname
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relname LIKE 'documents_rum_index_%' AND c.relkind = 'i' LIMIT 1;
});
my $rum_pages_after_vacuum = $node_primary->safe_psql('postgres',
    "SELECT pg_relation_size('$rum_index'::regclass) / current_setting('block_size')::int");
note "RUM index '$rum_index' has $rum_pages_after_vacuum pages after priming VACUUM";

# ============================================================================
# PART 5: Open a standby session that pins an old snapshot, then drive
# the recycle wave on the primary.
# ============================================================================
$node_primary->safe_psql('postgres', 'CHECKPOINT');
$node_primary->wait_for_catchup($node_standby);

# Snapshot the standby logfile size so wait_for_log only matches new
# entries written after this point.
my $log_start = -s $node_standby->logfile;

# Open a long-lived standby session pinning a snapshot. background_psql
# stays connected so we can verify the session was cancelled.
my $standby_session = $node_standby->background_psql('postgres');
$standby_session->query_safe(q{
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT 1;
});

my $standby_pid = $standby_session->query_safe('SELECT pg_backend_pid()');
chomp $standby_pid;
note "standby snapshot-holder pid: $standby_pid";

# Capture the WAL position right before the recycle wave so we can scan
# only the records emitted from this point on.
my $lsn_before = $node_primary->safe_psql('postgres',
    'SELECT pg_current_wal_lsn()');

# Insert wave with NEW unique 600-byte values to force entry-leaf
# splits. Each split calls RumNewBuffer; with the FSM populated by the
# prior VACUUM, RumNewBuffer pulls a vacuum-deleted page back and emits
# XLOG_BTREE_REUSE_PAGE before re-initializing it.
$node_primary->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
DO $$
BEGIN
    FOR i IN 1..800 LOOP
        PERFORM documentdb_api.insert_one(
            'testdb',
            'reclaim_test',
            FORMAT(
                '{"_id": %s, "a": "x%s%s"}',
                100000 + i,
                lpad(i::text, 5, '0'),
                repeat('q', 600)
            )::documentdb_core.bson
        );
    END LOOP;
END;
$$;
});

# Force a WAL flush so pg_waldump can read everything we just wrote.
$node_primary->safe_psql('postgres', 'SELECT pg_switch_wal()');

# ============================================================================
# PART 6: Verify the primary emitted at least one XLOG_BTREE_REUSE_PAGE
# ============================================================================
my $lsn_after = $node_primary->safe_psql('postgres',
    'SELECT pg_current_wal_lsn()');

my $pgdata = $node_primary->data_dir;
my $waldump_out = '';
my $waldump_err = '';
PostgreSQL::Test::Utils::run_log(
    [
        'pg_waldump',
        '-p', "$pgdata/pg_wal",
        '-s', $lsn_before,
        '-e', $lsn_after,
    ],
    '>', \$waldump_out,
    '2>', \$waldump_err);

my $reuse_page_count = () = $waldump_out =~ /Btree\b.*REUSE_PAGE/g;
cmp_ok($reuse_page_count, '>=', 1,
    "primary emitted at least one XLOG_BTREE_REUSE_PAGE record (got $reuse_page_count)");

# ============================================================================
# PART 7: Verify the standby cancelled the snapshot-holding session
# ============================================================================
$node_primary->wait_for_catchup($node_standby);

# Poll the standby's server log for the recovery-conflict cancellation
# message. With max_standby_streaming_delay = 0 this appears as soon as
# the startup process replays our REUSE_PAGE record and finds a backend
# whose snapshot's xmin precedes snapshotConflictHorizon. The standby
# may use either form depending on whether the backend was running a
# query (ERROR: canceling statement...) or sitting idle-in-transaction
# (FATAL: terminating connection...). Both prove the conflict point
# was emitted and acted on.
$node_standby->wait_for_log(
    qr/(canceling statement|terminating connection) due to conflict with recovery/,
    $log_start);
pass('standby logged a recovery-conflict cancellation against the snapshot holder');

# Read the full standby log to confirm the cancellation targeted our
# specific snapshot-holding pid.
my $standby_log = PostgreSQL::Test::Utils::slurp_file($node_standby->logfile);
like(
    $standby_log,
    qr/\[$standby_pid\][^\n]*(canceling statement|terminating connection) due to conflict with recovery/,
    "snapshot-holder pid $standby_pid was the target of the recovery conflict");

# Best-effort cleanup. If the session was killed with FATAL its psql
# pipe is already closed; quit() may raise — eval-protect.
eval { $standby_session->quit; };

# ============================================================================
# PART 8: Sanity-check primary/standby agree on the index after replay
# ============================================================================
my $primary_count = $node_primary->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SELECT COUNT(*) FROM documentdb_api.collection('testdb', 'reclaim_test');
});
my $standby_count = $node_standby->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SELECT COUNT(*) FROM documentdb_api.collection('testdb', 'reclaim_test');
});
is($standby_count, $primary_count,
    "standby row count matches primary after REUSE_PAGE replay ($primary_count)");

my $primary_index_count = $node_primary->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SET enable_seqscan = off;
SELECT COUNT(*) FROM documentdb_api.collection('testdb', 'reclaim_test')
    WHERE document @@ '{"a": {"$exists": true}}';
});
my $standby_index_count = $node_standby->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SET enable_seqscan = off;
SELECT COUNT(*) FROM documentdb_api.collection('testdb', 'reclaim_test')
    WHERE document @@ '{"a": {"$exists": true}}';
});
is($standby_index_count, $primary_index_count,
    "standby index scan count matches primary ($primary_index_count)");

my $primary_pages = $node_primary->safe_psql('postgres', qq{
SET citus.override_table_visibility TO false;
SELECT pg_relation_size((
    SELECT n.nspname || '.' || c.relname
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname LIKE 'documents_rum_index_%' AND c.relkind = 'i' LIMIT 1
)::regclass) / current_setting('block_size')::int;
});
my $standby_pages = $node_standby->safe_psql('postgres', qq{
SET citus.override_table_visibility TO false;
SELECT pg_relation_size((
    SELECT n.nspname || '.' || c.relname
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname LIKE 'documents_rum_index_%' AND c.relkind = 'i' LIMIT 1
)::regclass) / current_setting('block_size')::int;
});
is($standby_pages, $primary_pages,
    "standby index page count matches primary ($primary_pages)");

done_testing();
