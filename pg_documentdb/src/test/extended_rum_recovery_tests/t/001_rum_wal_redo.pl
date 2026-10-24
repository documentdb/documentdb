# Test that RUM index WAL redo works correctly via streaming replication.
#
# When documentdb_rum.enable_xlog_insert_entry is ON, RUM emits GIN-format
# WAL records for index inserts. This test validates that a streaming standby
# can correctly replay those WAL records and produce a usable index.
#
# Architecture: primary node with documentdb + documentdb_extended_rum,
# streaming standby created from backup. All inserts happen after standby
# creation to ensure WAL redo is exercised.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use JSON::PP qw(decode_json);

# ============================================================================
# PART 1: Initialize primary node
# ============================================================================
my $node_primary = PostgreSQL::Test::Cluster->new('primary');
$node_primary->init(allows_streaming => 1, extra => ['--data-checksums']);

# Include shared configuration (TESTDIR is set by the Makefile)
my $test_dir = $ENV{TESTDIR};
$node_primary->append_conf('postgresql.conf', qq{
include '$test_dir/postgresql.conf'
documentdb_rum.allow_replace_on_insert_tuple = 'on'
documentdb_rum.enable_xlog_insert_entry = 'on'
documentdb_rum.enable_custom_xlog_rmgr = 'on'
});

$node_primary->start;

# Verify the primary is running and not in recovery
my $result = $node_primary->safe_psql('postgres', "SELECT pg_is_in_recovery()");
is($result, 'f', 'primary is not in recovery');

# ============================================================================
# PART 2: Create extensions and schema on primary
# ============================================================================
$node_primary->safe_psql('postgres', q{
CREATE EXTENSION IF NOT EXISTS documentdb_core CASCADE;
CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;
CREATE EXTENSION IF NOT EXISTS documentdb_extended_rum CASCADE;
CREATE EXTENSION IF NOT EXISTS pageinspect;
});

# Verify RUM optimization GUCs are active
$result = $node_primary->safe_psql('postgres',
    "SHOW documentdb_rum.enable_xlog_insert_entry");
is($result, 'on', 'enable_xlog_insert_entry is on');

$result = $node_primary->safe_psql('postgres',
    "SHOW documentdb_rum.allow_replace_on_insert_tuple");
is($result, 'on', 'allow_replace_on_insert_tuple is on');

my $checksum = $node_primary->safe_psql('postgres', 'SHOW data_checksums;');
is($checksum, 'on', 'checksums are enabled');

# Set deterministic collection IDs and create collection + index
$node_primary->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SET documentdb.next_collection_id TO 8800;
SET documentdb.next_collection_index_id TO 8800;
SELECT documentdb_api.create_collection('testdb', 'wal_redo_test');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'testdb',
    '{"createIndexes": "wal_redo_test", "indexes": [{"key": {"val": 1}, "name": "idx_val", "enableCompositeTerm": true}]}',
    true
);
});

# Create RUM page inspection helper functions on primary (standby inherits via catalog)
$node_primary->safe_psql('postgres', q{
CREATE OR REPLACE FUNCTION public.documentdb_rum_get_meta_page_info(page bytea)
RETURNS jsonb LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum_core', 'documentdb_rum_get_meta_page_info';

CREATE OR REPLACE FUNCTION public.documentdb_rum_page_get_stats(page bytea)
RETURNS jsonb LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum_core', 'documentdb_rum_page_get_stats';

CREATE OR REPLACE FUNCTION public.documentdb_rum_page_get_entries(page bytea, index_oid oid)
RETURNS SETOF jsonb LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum_core', 'documentdb_rum_page_get_entries';

CREATE FUNCTION public.documentdb_rum_get_wal_insert_descriptions(pg_lsn, pg_lsn)
RETURNS text[] LANGUAGE c STRICT
AS '$libdir/pg_documentdb_extended_rum_core', 'documentdb_rum_get_wal_insert_descriptions';
});

my ($inspect_status, $inspect_stdout, $inspect_stderr) = $node_primary->psql(
    'postgres',
    "SELECT public.documentdb_rum_get_wal_insert_descriptions('0/0', '0/1')");
isnt($inspect_status, 0, 'WAL inspection rejects invalid LSN ranges');
like($inspect_stderr, qr/invalid WAL LSN range/, 'invalid WAL range is reported');

$node_primary->safe_psql('postgres', q{
CREATE ROLE rum_wal_reader;
GRANT USAGE ON SCHEMA documentdb_core, documentdb_api, documentdb_api_internal,
    documentdb_api_catalog TO rum_wal_reader;
});
($inspect_status, $inspect_stdout, $inspect_stderr) = $node_primary->psql(
    'postgres', q{
SET ROLE rum_wal_reader;
SELECT public.documentdb_rum_get_wal_insert_descriptions('0/0', '0/1');
});
isnt($inspect_status, 0, 'WAL inspection rejects non-superusers');
like($inspect_stderr, qr/must be superuser to inspect RUM WAL/,
    'WAL inspection checks privileges before reading records');
$node_primary->safe_psql('postgres', q{
REVOKE USAGE ON SCHEMA documentdb_core, documentdb_api, documentdb_api_internal,
    documentdb_api_catalog FROM rum_wal_reader;
DROP ROLE rum_wal_reader;
});

# Verify collection was created
$result = $node_primary->safe_psql('postgres', q{
SELECT collection_id FROM documentdb_api_catalog.collections
WHERE database_name = 'testdb' AND collection_name = 'wal_redo_test';
});
is($result, '8801', 'collection created with expected ID');

# ============================================================================
# PART 3: Take backup and create streaming standby
# ============================================================================
my $backup_name = 'rum_backup';
$node_primary->backup($backup_name);

my $node_standby = PostgreSQL::Test::Cluster->new('standby');
$node_standby->init_from_backup($node_primary, $backup_name,
    has_streaming => 1, extra => ['--data-checksums']);
$node_standby->start;

# Verify standby is in recovery
$result = $node_standby->safe_psql('postgres', "SELECT pg_is_in_recovery()");
is($result, 't', 'standby is in recovery mode');

# ============================================================================
# PART 4: Insert data on primary (generates GIN-format WAL for standby redo)
# ============================================================================
$node_primary->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;

DO $$
BEGIN
    FOR i IN 1..1000 LOOP
        PERFORM documentdb_api.insert_one(
            'testdb',
            'wal_redo_test',
            FORMAT('{"_id": %s, "val": %s, "data": "doc_%s"}', i, i % 50, i)::documentdb_core.bson
        );
    END LOOP;

    FOR i IN 10001..15000 LOOP
        PERFORM documentdb_api.insert_one(
            'testdb',
            'wal_redo_test',
            FORMAT('{"_id": %s, "val": %s, "data": "doc_%s"}', i, 10000 + (i - 10000) / 50, i)::documentdb_core.bson
        );
    END LOOP;
    

    FOR i IN 15001..20000 LOOP
        PERFORM documentdb_api.insert_one(
            'testdb',
            'wal_redo_test',
            FORMAT('{"_id": %s, "val": %s, "data": "doc_%s"}', i, 20000, i)::documentdb_core.bson
        );
    END LOOP;
END;
$$;
});

$node_primary->safe_psql('postgres', q{ CHECKPOINT });

# Verify primary has all rows
$result = $node_primary->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SELECT COUNT(*) FROM documentdb_api.collection('testdb', 'wal_redo_test');
});
is($result, '11000', 'primary has 11000 rows');

# ============================================================================
# PART 5: Wait for standby to replay WAL and validate
# ============================================================================
$node_primary->wait_for_catchup($node_standby);

# Verify row count on standby
$result = $node_standby->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SELECT COUNT(*) FROM documentdb_api.collection('testdb', 'wal_redo_test');
});
is($result, '11000', 'standby has 11000 rows after WAL redo');

# Verify index scan works on standby (force index usage)
$result = $node_standby->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SET enable_seqscan = off;
SELECT COUNT(*) FROM documentdb_api.collection('testdb', 'wal_redo_test')
    WHERE document @@ '{"val": 1}';
});
is($result, '20', 'standby index scan returns correct count for val=1');

# Verify EXPLAIN shows index scan on standby
$result = $node_standby->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SET enable_seqscan = off;
EXPLAIN (COSTS OFF) SELECT document FROM documentdb_api.collection('testdb', 'wal_redo_test')
    WHERE document @@ '{"val": 1}';
});
like($result, qr/Bitmap Index Scan|Index Scan/, 'standby uses index scan');

# ============================================================================
# PART 6: Page-level validation on standby
# ============================================================================

# Get index ID
my $index_id = $node_standby->safe_psql('postgres', q{
SELECT index_id FROM documentdb_api_catalog.collection_indexes ci
    JOIN documentdb_api_catalog.collections c ON ci.collection_id = c.collection_id
    WHERE c.database_name = 'testdb' AND c.collection_name = 'wal_redo_test'
    AND (ci.index_spec).index_name = 'idx_val';
});

# Meta page validation on standby
$result = $node_standby->safe_psql('postgres', qq{
SELECT public.documentdb_rum_get_meta_page_info(
    get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', '$index_id'), 0)
) IS NOT NULL AS meta_page_valid;
});
is($result, 't', 'standby meta page is valid');

# Verify entry page has entries (index was populated via WAL redo)
$result = $node_standby->safe_psql('postgres', qq{
SELECT COUNT(*) > 0 AS has_entries
FROM public.documentdb_rum_page_get_entries(
    get_raw_page(FORMAT('documentdb_data.documents_rum_index_%s', '$index_id'), 1),
    FORMAT('documentdb_data.documents_rum_index_%s', '$index_id')::regclass::oid
);
});
is($result, 't', 'standby index entry page has entries after WAL redo');

# Compare index sizes between primary and standby
my $primary_pages = $node_primary->safe_psql('postgres', qq{
SELECT pg_relation_size(FORMAT('documentdb_data.documents_rum_index_%s', '$index_id')::regclass)
    / current_setting('block_size')::int;
});

my $standby_pages = $node_standby->safe_psql('postgres', qq{
SELECT pg_relation_size(FORMAT('documentdb_data.documents_rum_index_%s', '$index_id')::regclass)
    / current_setting('block_size')::int;
});

is($standby_pages, $primary_pages, 'standby index page count matches primary');

# ============================================================================
# PART 7: Additional inserts + VACUUM on primary, verify standby redo
# ============================================================================
$node_primary->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;

DO $$
BEGIN
    FOR i IN 1001..1500 LOOP
        PERFORM documentdb_api.insert_one(
            'testdb',
            'wal_redo_test',
            FORMAT('{"_id": %s, "val": %s, "data": "doc_%s"}', i, i % 50, i)::documentdb_core.bson
        );
    END LOOP;
END;
$$;
});

# VACUUM on primary to consolidate pending list and generate more WAL
$node_primary->safe_psql('postgres',
    "VACUUM (INDEX_CLEANUP ON) documentdb_data.documents_8801");

$node_primary->wait_for_catchup($node_standby);

# Verify updated row count on standby
$result = $node_standby->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SELECT COUNT(*) FROM documentdb_api.collection('testdb', 'wal_redo_test');
});
is($result, '11500', 'standby has 11500 rows after second batch WAL redo');

# Verify index scan still works correctly after VACUUM redo
$result = $node_standby->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SET enable_seqscan = off;
SELECT COUNT(*) FROM documentdb_api.collection('testdb', 'wal_redo_test')
    WHERE document @@ '{"val": 1}';
});
is($result, '30', 'standby index scan correct after VACUUM redo (val=1, 1500/50=30)');

# Final page-level comparison
$primary_pages = $node_primary->safe_psql('postgres', qq{
SELECT pg_relation_size(FORMAT('documentdb_data.documents_rum_index_%s', '$index_id')::regclass)
    / current_setting('block_size')::int;
});

$standby_pages = $node_standby->safe_psql('postgres', qq{
SELECT pg_relation_size(FORMAT('documentdb_data.documents_rum_index_%s', '$index_id')::regclass)
    / current_setting('block_size')::int;
});

is($standby_pages, $primary_pages, 'standby index page count matches primary after VACUUM');

for my $persistence ('', 'UNLOGGED', 'TEMPORARY')
{
    my $name = $persistence eq '' ? 'permanent' : lc($persistence);
    my $plan = decode_json($node_primary->safe_psql('postgres', qq{
CREATE $persistence TABLE rum_wal_$name (document documentdb_core.bson)
    WITH (autovacuum_enabled = off);
CREATE INDEX ON rum_wal_$name USING documentdb_extended_rum(
    document documentdb_extended_rum_catalog.bson_extended_rum_single_path_ops(path='a'));
EXPLAIN (ANALYZE, WAL, FORMAT JSON)
INSERT INTO rum_wal_$name VALUES ('{"a": 1}');
}));
    my $records = $plan->[0]->{'Plan'}->{'WAL Records'};
    if ($persistence eq '')
    {
        cmp_ok($records, '>', 0, 'permanent index insert generates WAL');
    }
    else
    {
        is($records, 0, "$name index insert does not generate WAL");
    }
}

$node_primary->safe_psql('postgres', q{
SELECT documentdb_api.create_collection('testdb', 'wal_hint_test');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    'testdb',
    '{"createIndexes": "wal_hint_test", "indexes": [{"key": {"a": 1}, "name": "idx_hint_a", "enableCompositeTerm": true}]}',
    true
);
SELECT documentdb_api.insert_one('testdb', 'wal_hint_test',
    FORMAT('{"_id": %s, "a": %s}', i, i)::documentdb_core.bson)
FROM generate_series(1, 5) AS i;
});

my $hint_table = $node_primary->safe_psql('postgres', q{
SELECT FORMAT('documentdb_data.documents_%s', collection_id)
FROM documentdb_api_catalog.collections
WHERE database_name = 'testdb' AND collection_name = 'wal_hint_test';
});
my $hint_index = $node_primary->safe_psql('postgres', q{
SELECT FORMAT('documentdb_data.documents_rum_index_%s', ci.index_id)
FROM documentdb_api_catalog.collection_indexes ci
JOIN documentdb_api_catalog.collections c USING (collection_id)
WHERE c.database_name = 'testdb' AND c.collection_name = 'wal_hint_test'
    AND (ci.index_spec).index_name = 'idx_hint_a';
});

$node_primary->safe_psql('postgres', qq{
ALTER TABLE $hint_table SET (autovacuum_enabled = off);
SELECT documentdb_api.delete('testdb',
    '{"delete": "wal_hint_test", "deletes": [{"q": {"a": 2}, "limit": 0}]}');
VACUUM (FREEZE, INDEX_CLEANUP OFF) $hint_table;
});

# Warm the index after the checkpoint so hinting does not emit another FPI.
$node_primary->safe_psql('postgres', 'CHECKPOINT');
my $fpi_start = $node_primary->safe_psql('postgres',
    'SELECT pg_current_wal_insert_lsn()');
$node_primary->safe_psql('postgres', q{
SET wal_consistency_checking = 'DOCDB_EXRUM';
SELECT documentdb_api.insert_one('testdb', 'wal_hint_test', '{"_id": 6, "a": 6}');
});
my $fpi_end = $node_primary->safe_psql('postgres',
    'SELECT pg_current_wal_flush_lsn()');
$result = $node_primary->safe_psql('postgres', qq{
SELECT unnest(public.documentdb_rum_get_wal_insert_descriptions('$fpi_start', '$fpi_end'));
});
like($result, qr/^isdata: F isleaf: T \(full page image\)$/m,
    'descriptor handles applied full-page images without block data');
$node_primary->wait_for_catchup($node_standby);

$node_primary->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SET documentdb.forceDisableSeqScan = on;
SET documentdb_rum.enable_support_dead_index_items = on;
SELECT document FROM bson_aggregation_find('testdb',
    '{"find": "wal_hint_test", "filter": {"a": {"$exists": true}}, "sort": {"a": 1}, "hint": "idx_hint_a"}');
SELECT document FROM bson_aggregation_find('testdb',
    '{"find": "wal_hint_test", "filter": {"a": {"$exists": true}}, "sort": {"a": 1}, "hint": "idx_hint_a"}');
});

my $dead_entries = $node_primary->safe_psql('postgres', qq{
SELECT COUNT(*)
FROM public.documentdb_rum_page_get_entries(
    get_raw_page('$hint_index', 1), '$hint_index'::regclass) entry
WHERE (entry->>'entryFlags')::int = 3;
});
cmp_ok($dead_entries, '>', 0, 'primary has entry hints not present on standby');

my $verification_start = $node_primary->safe_psql('postgres',
    'SELECT pg_current_wal_insert_lsn()');
$node_primary->safe_psql('postgres', q{
SET wal_consistency_checking = 'DOCDB_EXRUM';
SELECT documentdb_api.insert_one('testdb', 'wal_hint_test', '{"_id": 7, "a": 7}');
});
my $verification_end = $node_primary->safe_psql('postgres',
    'SELECT pg_current_wal_flush_lsn()');
$result = $node_primary->safe_psql('postgres', qq{
SELECT unnest(public.documentdb_rum_get_wal_insert_descriptions('$verification_start', '$verification_end'));
});
like($result, qr/^isdata: F isleaf: T \(full page image, for WAL verification\)$/m,
    'descriptor distinguishes verification-only full-page images');
$node_primary->wait_for_catchup($node_standby);

$result = $node_standby->safe_psql('postgres', q{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SET enable_seqscan = off;
SELECT COUNT(*) FROM documentdb_api.collection('testdb', 'wal_hint_test')
WHERE document @@ '{"a": 7}';
});
is($result, '1', 'standby replays entry inserts with unlogged primary hints');

my $delta_start = $node_primary->safe_psql('postgres',
    'SELECT pg_current_wal_insert_lsn()');
$node_primary->safe_psql('postgres', q{
SET wal_consistency_checking = '';
SELECT documentdb_api.insert_one('testdb', 'wal_hint_test', '{"_id": 8, "a": 8}');
});
my $delta_end = $node_primary->safe_psql('postgres',
    'SELECT pg_current_wal_flush_lsn()');
$result = $node_primary->safe_psql('postgres', qq{
SELECT unnest(public.documentdb_rum_get_wal_insert_descriptions('$delta_start', '$delta_end'));
});
like($result, qr/^isdata: F isleaf: T isdelete: [TF]$/m,
    'descriptor reads block data when no full-page image is present');

done_testing();
