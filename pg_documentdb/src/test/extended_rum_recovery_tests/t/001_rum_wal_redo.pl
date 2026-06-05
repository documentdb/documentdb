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

done_testing();
