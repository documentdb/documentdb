# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# GIN consistency masks do not normalize RUM entry hints. Exercise insertion
# and replacement with GIN consistency checking after primary-only hints.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $primary = PostgreSQL::Test::Cluster->new('builtin_primary');
$primary->init(allows_streaming => 1, extra => ['--data-checksums']);
my $test_dir = $ENV{TESTDIR};
$primary->append_conf('postgresql.conf', qq{
include '$test_dir/postgresql.conf'
shared_preload_libraries = 'pg_cron,pg_documentdb_core,pg_documentdb,pg_documentdb_extended_rum,pg_documentdb_extended_rum_core_builtin_rmgr'
documentdb_extended_rum.rum_use_builtin_rmgr_modules = on
documentdb_rum.enable_xlog_insert_entry = on
documentdb_rum.enable_custom_xlog_rmgr = off
full_page_writes = off
max_parallel_workers_per_gather = 0
});
$primary->start;
$primary->safe_psql('postgres', q{
CREATE EXTENSION documentdb_core CASCADE;
CREATE EXTENSION documentdb CASCADE;
CREATE EXTENSION documentdb_extended_rum CASCADE;
CREATE EXTENSION pageinspect;
CREATE FUNCTION public.rum_entries(bytea, oid)
RETURNS SETOF jsonb LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum_core_builtin_rmgr',
   'builtin_rmgr_documentdb_rum_page_get_entries';
CREATE FUNCTION public.rum_wal_descriptions(pg_lsn, pg_lsn)
RETURNS text[] LANGUAGE c STRICT
AS '$libdir/pg_documentdb_extended_rum_core_builtin_rmgr',
   'builtin_rmgr_documentdb_rum_get_wal_insert_descriptions';
SELECT documentdb_api.create_collection('testdb', 'builtin_hints');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'testdb',
    '{"createIndexes":"builtin_hints","indexes":[{"key":{"a":1},"name":"idx_a","enableCompositeTerm":true}]}',
    true);
SELECT documentdb_api.insert_one('testdb', 'builtin_hints',
    FORMAT('{"_id":%s,"a":%s}', i, i)::documentdb_core.bson)
FROM generate_series(1,5) i;
});

my $table = $primary->safe_psql('postgres', q{
SELECT FORMAT('documentdb_data.documents_%s', collection_id)
FROM documentdb_api_catalog.collections
WHERE database_name = 'testdb' AND collection_name = 'builtin_hints';
});
my $index = $primary->safe_psql('postgres', q{
SELECT FORMAT('documentdb_data.documents_rum_index_%s', ci.index_id)
FROM documentdb_api_catalog.collection_indexes ci
JOIN documentdb_api_catalog.collections c USING (collection_id)
WHERE database_name = 'testdb' AND collection_name = 'builtin_hints'
    AND (ci.index_spec).index_name = 'idx_a';
});
$primary->backup('baseline');
my $standby = PostgreSQL::Test::Cluster->new('builtin_standby');
$standby->init_from_backup($primary, 'baseline', has_streaming => 1);
$standby->start;

$primary->safe_psql('postgres', qq{
ALTER TABLE $table SET (autovacuum_enabled = off);
SELECT documentdb_api.delete('testdb',
    '{"delete":"builtin_hints","deletes":[{"q":{"a":2},"limit":0}]}');
VACUUM (FREEZE, INDEX_CLEANUP OFF) $table;
CHECKPOINT;
SELECT documentdb_api.insert_one('testdb', 'builtin_hints', '{"_id":6,"a":6}');
});
$primary->wait_for_catchup($standby);
$primary->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SET documentdb.forceDisableSeqScan = on;
SET documentdb_rum.enable_support_dead_index_items = on;
SELECT document FROM bson_aggregation_find('testdb',
    '{"find":"builtin_hints","filter":{"a":{"$exists":true}},"sort":{"a":1},"hint":"idx_a"}');
SELECT document FROM bson_aggregation_find('testdb',
    '{"find":"builtin_hints","filter":{"a":{"$exists":true}},"sort":{"a":1},"hint":"idx_a"}');
});
my $dead_query = qq{
SELECT COUNT(*) FROM public.rum_entries(
    get_raw_page('$index', 1), '$index'::regclass) entry
WHERE (entry->>'entryFlags')::int = 3;
};
cmp_ok($primary->safe_psql('postgres', $dead_query), '>', 0,
    'primary has dead-entry hints');
is($standby->safe_psql('postgres', $dead_query), '0',
    'standby has no dead-entry hints');

my $id = 7;
for my $value (7, 1)
{
    $primary->safe_psql('postgres', qq{
SET wal_consistency_checking = 'gin';
SELECT documentdb_api.insert_one('testdb', 'builtin_hints', '{"_id":$id,"a":$value}');
});
    $primary->wait_for_catchup($standby);
    my $count = $standby->safe_psql('postgres', qq{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SET documentdb.forceDisableSeqScan = on;
SELECT COUNT(*) FROM documentdb_api.collection('testdb', 'builtin_hints')
WHERE document @@ '{"a":$value}';
});
    is($count, $value == 1 ? '2' : '1',
        "standby index scan succeeds for a=$value with GIN consistency checking");
    $id++;
}

my $start = $primary->safe_psql('postgres',
    'SELECT pg_current_wal_insert_lsn()');
$primary->safe_psql('postgres', q{
SET wal_consistency_checking = '';
SELECT documentdb_api.insert_one('testdb', 'builtin_hints', '{"_id":9,"a":1}');
});
my $end = $primary->safe_psql('postgres',
    'SELECT pg_current_wal_flush_lsn()');
like($primary->safe_psql('postgres', qq{
SELECT unnest(public.rum_wal_descriptions('$start', '$end'));
}), qr/isdata: F isleaf: T isdelete: T/,
    'built-in entry replacement still uses GIN WAL without consistency checking');
$primary->wait_for_catchup($standby);
is($standby->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SET documentdb.forceDisableSeqScan = on;
SELECT COUNT(*) FROM documentdb_api.collection('testdb', 'builtin_hints')
WHERE document @@ '{"a":1}';
}), '3', 'standby replays GIN replacement after consistency checking is disabled');
done_testing();
