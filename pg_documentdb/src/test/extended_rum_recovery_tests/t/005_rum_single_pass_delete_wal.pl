# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Deferred single-pass leaf deletes must not inflate the index WAL.
#
# rumDeletePage() WAL-logs the deleted leaf together with its right sibling,
# because it rewrites the sibling's left link. The first change to a page
# after a checkpoint logs a full-page image of the page as it is at that
# moment. Targeted pruning removes the dead items from every leaf before it
# deletes any leaf, so that image is of an already vacuumed page. Single-pass
# vacuum deletes an emptied leaf before it vacuums the right sibling, so the
# sibling's image still holds all of its dead items, unless
# enable_single_pass_deferred_leaf_delete defers the delete until the
# sibling is vacuumed.
#
# The test applies the same delete to three identical collections, then
# vacuums them after one checkpoint: with deferred single-pass deletes, with
# immediate single-pass deletes, and with targeted pruning. It checks that
# all three delete the same number of posting-tree leaves, that deferred
# deletes log no more full-page image bytes for the index than targeted
# pruning, and that immediate deletes log more than deferred ones.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $test_dir = $ENV{TESTDIR};
my $num_docs = 20000;
my $num_batches = 20;
my $num_deleted = 14000;
my $search_path = 'SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;';

my $node = PostgreSQL::Test::Cluster->new('single_pass_wal');
$node->init;

# Nothing but the vacuums may write to the indexes, and no checkpoint may
# start between them.
$node->append_conf('postgresql.conf', qq{
include '$test_dir/postgresql.conf'
autovacuum = off
checkpoint_timeout = '1h'
max_wal_size = '20GB'
});
$node->start;

$node->safe_psql('postgres', q{
CREATE EXTENSION IF NOT EXISTS documentdb_core CASCADE;
CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;
CREATE EXTENSION IF NOT EXISTS documentdb_extended_rum CASCADE;
});

is($node->safe_psql('postgres', 'SHOW full_page_writes'), 'on',
    'full_page_writes is on');

# Every document has the same value of a, so idx_a holds a single posting
# tree whose leaves follow heap order. Deleting the lowest _id values empties
# the leftmost leaves of that tree.
my $batch_size = $num_docs / $num_batches;
my %index;
foreach my $coll ('deferred', 'immediate', 'targeted')
{
    $node->safe_psql('postgres', qq{
$search_path
SELECT documentdb_api.create_collection('testdb', '$coll');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'testdb',
    '{"createIndexes": "$coll", "indexes": [{"key": {"a": 1}, "name": "idx_a"}]}',
    true
);
DO \$\$
BEGIN
    FOR b IN 0..$num_batches - 1 LOOP
        PERFORM documentdb_api.insert('testdb', FORMAT('{"insert": "$coll", "documents": [%s]}',
            (SELECT string_agg(FORMAT('{"_id": %s, "a": 1}', n), ',')
             FROM generate_series(b * $batch_size, (b + 1) * $batch_size - 1) n))::documentdb_core.bson);
    END LOOP;
END;
\$\$;
SELECT documentdb_api.delete('testdb',
    '{"delete": "$coll", "deletes": [{"q": {"_id": {"\$lt": $num_deleted}}, "limit": 0}]}');
});

    my ($table, $oid, $relation) = split(/\|/, $node->safe_psql('postgres', qq{
SELECT i.indrelid::regclass, i.indexrelid,
    FORMAT('%s/%s/%s', COALESCE(NULLIF(c.reltablespace, 0), d.dattablespace), d.oid,
        pg_relation_filenode(c.oid))
FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
    JOIN pg_am a ON a.oid = c.relam
    JOIN pg_database d ON d.datname = current_database()
WHERE a.amname LIKE '%rum%'
    AND i.indrelid = FORMAT('documentdb_data.documents_%s',
        (SELECT collection_id FROM documentdb_api_catalog.collections
         WHERE database_name = 'testdb' AND collection_name = '$coll'))::regclass;
}));
    ok(defined($relation), "found the RUM index of $coll");
    $index{$coll} = { table => $table, oid => $oid, relation => $relation };
}

# All of the vacuums run after this checkpoint, so the first change each of
# them makes to an index page logs a full-page image.
$node->safe_psql('postgres', 'CHECKPOINT');
my $start_lsn = $node->safe_psql('postgres', 'SELECT pg_current_wal_insert_lsn()');

foreach my $case (['deferred', 'on', 'on'], ['immediate', 'on', 'off'],
    ['targeted', 'off', 'off'])
{
    my ($coll, $single_pass, $deferred) = @$case;
    my ($stdout, $stderr);

    # Inline data-page vacuum defers leaf deletion to vacuum cleanup, which
    # would bypass both strategies under test.
    my $ret = $node->psql('postgres', qq{
SET client_min_messages = log;
SET documentdb_rum.enable_new_bulk_delete_inline_data_pages = off;
SET documentdb_rum.enable_single_pass_posting_tree_vacuum = $single_pass;
SET documentdb_rum.enable_single_pass_deferred_leaf_delete = $deferred;
SET documentdb_rum.enable_targeted_posting_tree_pruning = on;
VACUUM (INDEX_CLEANUP ON, PARALLEL 0) $index{$coll}{table};
},
        stdout => \$stdout, stderr => \$stderr);
    is($ret, 0, "vacuum of $coll succeeds");

    # The bulk delete pass reports the posting-tree leaves it deleted and
    # which pruning strategy it used.
    my $oid = $index{$coll}{oid};
    my @stats = $stderr =~ /Vacuum\[index=$oid,vacuumCleanup=0\][^\n]*\bpostingPagesDeleted=(\d+)[^\n]*\btargetedPostingTreePrunes=(\d+), singlePassPostingTreePrunes=(\d+)/;
    is(scalar(@stats), 3, "vacuum of $coll logged its bulk delete statistics")
      or diag($stderr);
    @{ $index{$coll} }{qw(deleted targeted_prunes single_pass_prunes)} = @stats;
}

is($index{deferred}{single_pass_prunes}, 1, 'deferred used single-pass vacuum');
is($index{immediate}{single_pass_prunes}, 1, 'immediate used single-pass vacuum');
is($index{targeted}{targeted_prunes}, 1, 'targeted used targeted pruning');
cmp_ok($index{deferred}{deleted}, '>=', 5,
    "deferred single-pass deleted posting-tree leaves ($index{deferred}{deleted})");
is($index{deferred}{deleted}, $index{targeted}{deleted},
    'deferred single-pass and targeted pruning delete the same number of leaves');
is($index{immediate}{deleted}, $index{targeted}{deleted},
    'immediate single-pass and targeted pruning delete the same number of leaves');

# Make all of the vacuum WAL readable by pg_waldump.
my $end_lsn = $node->safe_psql('postgres', 'SELECT pg_current_wal_insert_lsn()');
$node->safe_psql('postgres', 'SELECT pg_switch_wal()');

my $pgdata = $node->data_dir;
foreach my $coll ('deferred', 'immediate', 'targeted')
{
    my ($stdout, $stderr) = ('', '');
    my $dump_ok = PostgreSQL::Test::Utils::run_log(
        [
            'pg_waldump', '--stats',
            '--relation', $index{$coll}{relation},
            '-p', "$pgdata/pg_wal",
            '-s', $start_lsn,
            '-e', $end_lsn,
        ],
        '>', \$stdout,
        '2>', \$stderr);

    # pg_waldump prints its statistics even when it stops early on a WAL
    # read error, so check that it read the whole range.
    ok($dump_ok, "pg_waldump read the WAL of the $coll index")
      or diag("stderr:\n$stderr");
    my @total = $stdout =~ /^Total\s+(\d+)\s+(\d+)\s+\[[^\]]*\]\s+(\d+)\s+\[[^\]]*\]\s+(\d+)/m;
    is(scalar(@total), 4, "pg_waldump reported the WAL of the $coll index")
      or diag("stdout:\n$stdout\nstderr:\n$stderr");
    $index{$coll}{fpi_bytes} = $total[2];
    $index{$coll}{wal_bytes} = $total[3];
    note("$coll index WAL: $total[3] bytes, of which $total[2] bytes are full-page images");
}

cmp_ok($index{targeted}{fpi_bytes}, '>', 0,
    'targeted pruning logged full-page images after the checkpoint');
cmp_ok($index{deferred}{fpi_bytes}, '<=', $index{targeted}{fpi_bytes},
    'deferred single-pass deletes log no more full-page image bytes than targeted pruning');
cmp_ok($index{immediate}{fpi_bytes}, '>', $index{deferred}{fpi_bytes},
    'immediate single-pass deletes log more full-page image bytes than deferred ones');

foreach my $coll ('deferred', 'immediate', 'targeted')
{
    is($node->safe_psql('postgres', qq{
$search_path
SET enable_seqscan = off;
SELECT COUNT(*) FROM documentdb_api.collection('testdb', '$coll') WHERE document @@ '{"a": 1}';
}), $num_docs - $num_deleted,
        "index scan after the $coll vacuum returns every remaining document");
}

$node->stop;
done_testing();
