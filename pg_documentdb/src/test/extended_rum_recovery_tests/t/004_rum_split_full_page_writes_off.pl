# Crash recovery of RUM page splits with full_page_writes = off.
#
# A non-root page split allocates a new right page with RumNewBuffer(). If that
# page is WAL-logged as a generic delta instead of a full image, crash recovery
# finds the page all-zero on disk (it was only ever extended), skips the delta,
# and leaves downlinks and sibling links pointing at zero pages. With
# full_page_writes = on the first change after a checkpoint carries a full-page
# image anyway, so this only shows up with full_page_writes = off.
#
# The test keeps the new index pages in shared buffers until a crash (no
# bgwriter writes, no checkpoints), recovers, and checks that:
#   1. no index block is left all-zero,
#   2. inserts and index scans work.
#
# It then zeroes the posting-tree leaf pages of one index on disk to check that
# a tree descent that reaches a zero page fails with an index-corruption error
# instead of looping forever.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $test_dir = $ENV{TESTDIR};
my $num_docs = 30000;
my $num_batches = 30;
my $search_path = 'SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;';

my $node = PostgreSQL::Test::Cluster->new('fpw_off');
$node->init;

# Keep dirty index pages in shared buffers until the crash: no bgwriter
# writes, no checkpoints, and no autovacuum touching the index.
$node->append_conf('postgresql.conf', qq{
include '$test_dir/postgresql.conf'
full_page_writes = off
shared_buffers = '256MB'
bgwriter_lru_maxpages = 0
checkpoint_timeout = '1h'
max_wal_size = '20GB'
autovacuum = off
});
$node->start;

$node->safe_psql('postgres', q{
CREATE EXTENSION IF NOT EXISTS documentdb_core CASCADE;
CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;
CREATE EXTENSION IF NOT EXISTS documentdb_extended_rum CASCADE;
CREATE EXTENSION IF NOT EXISTS pageinspect;

CREATE OR REPLACE FUNCTION public.documentdb_rum_page_get_stats(page bytea)
RETURNS jsonb LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum_core', 'documentdb_rum_page_get_stats';
});

is($node->safe_psql('postgres', 'SHOW full_page_writes'), 'off',
    'full_page_writes is off');

my $coll = 'split_test';
$node->safe_psql('postgres', qq{
$search_path
SELECT documentdb_api.create_collection('testdb', '$coll');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'testdb',
    '{"createIndexes": "$coll", "indexes": [{"key": {"tags": 1}, "name": "idx_tags"}, {"key": {"k": 1}, "name": "idx_k"}]}',
    true
);
});

# Returns the RUM indexes of the collection, as regclass text.
sub rum_indexes
{
    my $out = $node->safe_psql('postgres', qq{
SELECT i.indexrelid::regclass
FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
    JOIN pg_am a ON a.oid = c.relam
WHERE a.amname LIKE '%rum%'
    AND i.indrelid = FORMAT('documentdb_data.documents_%s',
        (SELECT collection_id FROM documentdb_api_catalog.collections
         WHERE database_name = 'testdb' AND collection_name = '$coll'))::regclass
ORDER BY 1;
});
    return split(/\n/, $out);
}

# All later index pages are created after this checkpoint, so none of them
# get a full-page write from full_page_writes.
$node->safe_psql('postgres', 'CHECKPOINT');

# Each document has 2 of 5 tag values, so idx_tags gets 5 large posting
# trees with many non-root splits; k is unique and padded, so idx_k gets an
# entry tree with many non-root splits.
my $batch_size = $num_docs / $num_batches;
$node->safe_psql('postgres', qq{
$search_path
DO \$\$
BEGIN
    FOR b IN 0..$num_batches - 1 LOOP
        PERFORM documentdb_api.insert('testdb', FORMAT('{"insert": "$coll", "documents": [%s]}',
            (SELECT string_agg(FORMAT('{"_id": %s, "tags": ["t%s", "t%s"], "k": "key_%s_%s"}',
                    n, n % 5, (n + 1) % 5, lpad(n::text, 8, '0'), repeat('x', 80)), ',')
             FROM generate_series(b * $batch_size, (b + 1) * $batch_size - 1) n))::documentdb_core.bson);
    END LOOP;
END;
\$\$;
});

# Make sure the workload split non-root pages. A root split leaves the new root
# with 2 downlinks; an internal page with 3 or more got one from the split of a
# page that was not the root. Checked before the crash, from shared buffers.
my @indexes = rum_indexes();
is(scalar(@indexes), 2, 'collection has two RUM indexes');
foreach my $idx (@indexes)
{
    my $downlinks = $node->safe_psql('postgres', qq{
SELECT max((s ->> 'nEntries')::int)
FROM generate_series(1, pg_relation_size('$idx') / current_setting('block_size')::int - 1) b,
    LATERAL public.documentdb_rum_page_get_stats(get_raw_page('$idx', b::int)) s
WHERE ((s ->> 'flags')::int & (2 | 8)) = 0;
});
    cmp_ok($downlinks, '>=', 3,
        "$idx has non-root splits ($downlinks downlinks on an internal page)");
}

# Crash, then crash recovery.
$node->stop('immediate');
$node->start;

my $expected_t0 = $num_docs * 2 / 5;

foreach my $idx (@indexes)
{
    my $zero_pages = $node->safe_psql('postgres', qq{
SELECT count(*)
FROM generate_series(0, pg_relation_size('$idx') / current_setting('block_size')::int - 1) b
WHERE (page_header(get_raw_page('$idx', b::int))).upper = 0;
});
    is($zero_pages, '0', "$idx has no all-zero pages after crash recovery");
}

# Before the fix, this insert never returned.
my ($stdout, $stderr, $timed_out);
$node->psql('postgres', qq{
$search_path
SELECT documentdb_core.bson_to_json_string(
    documentdb_api.insert_one('testdb', '$coll', '{"_id": -1, "tags": ["t0"], "k": "key_new"}'));
},
    stdout => \$stdout, stderr => \$stderr,
    timeout => 60, timed_out => \$timed_out);
ok(!$timed_out, "insert after crash recovery does not hang");
like($stdout, qr/"n" : \{ "\$numberInt" : "1" \}/, "insert after crash recovery succeeds");
unlike($stdout, qr/writeErrors/, "insert after crash recovery has no write errors");

foreach my $filter ('{"tags": "t0"}', '{"k": {"$gte": "key_00010000"}}')
{
    my $seq = $node->safe_psql('postgres', qq{
$search_path
SET enable_indexscan = off;
SET enable_bitmapscan = off;
SELECT COUNT(*) FROM documentdb_api.collection('testdb', '$coll') WHERE document @@ '$filter';
});
    my $idx = $node->safe_psql('postgres', qq{
$search_path
SET enable_seqscan = off;
SELECT COUNT(*) FROM documentdb_api.collection('testdb', '$coll') WHERE document @@ '$filter';
});
    is($idx, $seq, "index scan matches sequential scan for $filter");
}

is($node->safe_psql('postgres', qq{
$search_path
SET enable_seqscan = off;
SELECT COUNT(*) FROM documentdb_api.collection('testdb', '$coll') WHERE document @@ '{"tags": "t0"}';
}), $expected_t0 + 1, "index scan returns every t0 document");

# ============================================================================
# A descent that reaches a zero page must error out, not spin forever.
# Zero every posting-tree leaf page of one idx_tags on disk: the posting tree
# roots stay intact, so both the insert and the scan descend into a zero page.
# ============================================================================
my $tags_idx = '';
my $relpath = '';
my @data_leaves;
foreach my $idx (@indexes)
{
    my $is_tags = $node->safe_psql('postgres', qq{
SELECT count(*) > 0
FROM generate_series(1, pg_relation_size('$idx') / current_setting('block_size')::int - 1) b
WHERE ((public.documentdb_rum_page_get_stats(get_raw_page('$idx', b::int)) ->> 'flags')::int & 1) <> 0;
});
    next unless $is_tags eq 't';

    $tags_idx = $idx;
    $relpath = $node->safe_psql('postgres', "SELECT pg_relation_filepath('$idx')");
    @data_leaves = split(/\n/, $node->safe_psql('postgres', qq{
SELECT b
FROM generate_series(1, pg_relation_size('$idx') / current_setting('block_size')::int - 1) b
WHERE ((public.documentdb_rum_page_get_stats(get_raw_page('$idx', b::int)) ->> 'flags')::int & 3) = 3;
}));
}
ok($relpath ne '', "found the posting-tree index $tags_idx");
cmp_ok(scalar(@data_leaves), '>', 0, 'posting-tree index has leaf pages to zero');

my $block_size = $node->safe_psql('postgres', 'SHOW block_size');
$node->stop;

open(my $fh, '+<', $node->data_dir . "/$relpath")
  or die "could not open $relpath: $!";
binmode $fh;
foreach my $blkno (@data_leaves)
{
    sysseek($fh, $blkno * $block_size, 0) or die "seek failed: $!";
    syswrite($fh, "\0" x $block_size) == $block_size or die "write failed: $!";
}
close($fh);

$node->start;

foreach my $case (
    [ 'insert', qq{SELECT documentdb_core.bson_to_json_string(documentdb_api.insert_one('testdb', '$coll', '{"_id": -2, "tags": ["t0"]}'));} ],
    [ 'index scan', qq{SET enable_seqscan = off; SELECT COUNT(*) FROM documentdb_api.collection('testdb', '$coll') WHERE document @@ '{"tags": "t0"}';} ])
{
    my ($name, $sql) = @$case;
    my ($stdout, $stderr, $timed_out);
    $node->psql('postgres', "$search_path\n$sql",
        stdout => \$stdout, stderr => \$stderr,
        timeout => 60, timed_out => \$timed_out);
    ok(!$timed_out, "$name into a zero page does not hang");
    like("$stdout\n$stderr", qr/contains unexpected zero page at block/,
        "$name into a zero page reports index corruption");
}

$node->stop;
done_testing();
