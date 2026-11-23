# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Recycling nonpersistent RUM pages must not emit snapshot-conflict WAL.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use JSON::PP qw(decode_json);

my $primary = PostgreSQL::Test::Cluster->new('recycle_primary');
$primary->init(allows_streaming => 1);
my $test_dir = $ENV{TESTDIR};
$primary->append_conf('postgresql.conf', qq{
include '$test_dir/postgresql.conf'
documentdb_rum.enable_emit_reuse_page_on_recycle = on
documentdb_rum.prune_rum_empty_pages = on
documentdb_rum.skip_global_visibility_check_on_prune = on
autovacuum = off
});
$primary->start;
$primary->safe_psql('postgres', q{
CREATE EXTENSION documentdb_core CASCADE;
CREATE EXTENSION documentdb CASCADE;
CREATE EXTENSION documentdb_extended_rum CASCADE;
CREATE EXTENSION pageinspect;
CREATE FUNCTION public.rum_page_stats(bytea)
RETURNS jsonb LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum_core', 'documentdb_rum_page_get_stats';
CREATE TABLE logged_table(i int);
INSERT INTO logged_table VALUES (1);
});
$primary->backup('baseline');
my $standby = PostgreSQL::Test::Cluster->new('recycle_standby');
$standby->init_from_backup($primary, 'baseline', has_streaming => 1);
$standby->append_conf('postgresql.conf', q{
max_standby_streaming_delay = 0
hot_standby_feedback = off
});
$standby->start;

for my $persistence ('UNLOGGED', 'TEMPORARY')
{
    my $session = $standby->background_psql('postgres');
    $session->query_safe(q{
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT COUNT(*) FROM logged_table;
});
    my $pid = $session->query_safe('SELECT pg_backend_pid()');
    chomp $pid;
    my $output = $primary->safe_psql('postgres', qq{
CREATE $persistence TABLE recycle_test(id int, document documentdb_core.bson);
CREATE INDEX recycle_test_idx ON recycle_test USING documentdb_extended_rum(
    document documentdb_extended_rum_catalog.bson_extended_rum_single_path_ops(path='a'));
INSERT INTO recycle_test
SELECT i, FORMAT('{"a":"%s%s"}', lpad(i::text,5,'0'), repeat('p',600))::documentdb_core.bson
FROM generate_series(1,800) i;
DELETE FROM recycle_test WHERE id >= 50;
VACUUM (FREEZE ON, INDEX_CLEANUP ON) recycle_test;
SELECT COUNT(*)
FROM generate_series(1, pg_relation_size('recycle_test_idx') /
    current_setting('block_size')::int - 1) b
WHERE (public.rum_page_stats(get_raw_page('recycle_test_idx', b::int))->>'flags')::int & 4 <> 0;
EXPLAIN (ANALYZE, WAL, FORMAT JSON)
INSERT INTO recycle_test
SELECT 100000+i,
    FORMAT('{"a":"x%s%s"}', lpad(i::text,5,'0'), repeat('q',600))::documentdb_core.bson
FROM generate_series(1,800) i;
DROP TABLE recycle_test;
});
    my ($deleted_pages, $json) = split(/\n/, $output, 2);
    cmp_ok($deleted_pages, '>', 0, "$persistence index has recyclable pages");
    my $plan = decode_json($json);
    is($plan->[0]->{'Plan'}->{'WAL Records'}, 0,
        "$persistence page recycling does not emit WAL");
    $primary->wait_for_catchup($standby);
    is($standby->safe_psql('postgres', qq{
SELECT COUNT(*) FROM pg_stat_activity WHERE pid = $pid;
}), '1', "$persistence page recycling preserves unrelated standby reader");
    eval { $session->quit; };
}
done_testing();
