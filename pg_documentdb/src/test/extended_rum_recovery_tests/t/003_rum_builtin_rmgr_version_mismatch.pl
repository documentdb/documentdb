# Cross-mode version-mismatch test for the side-by-side built-in rmgr core
# module of documentdb_extended_rum.
#
# documentdb_extended_rum links two core modules that are selected at runtime
# via the PGC_POSTMASTER GUC documentdb_extended_rum.rum_use_builtin_rmgr_modules:
#   * off (default) -> standard core module, RUM metapage version 0xC0DE0002
#   * on            -> built-in rmgr core module, RUM metapage version 0xC0DE0003
#
# An index physically written under one module cannot be read or written by the
# other: the metapage version check raises
#   ERROR:  unexpected RUM index version. Reindex
# Both scans (rumbeginscan -> rumValidateIndexVersion) and inserts/updates
# (ruminsert -> rumValidateIndexVersion) read the metapage and surface the
# mismatch on the first index access; the index has no fastupdate pending list
# to defer the read. Scans propagate the error directly, while insert_one traps
# it and reports it as a writeError (the document is not persisted). This test
# asserts both the read and write failures and, crucially, that flipping the GUC
# back to the module that wrote the index restores full functionality (no data
# loss, no reindex required).
#
# Both the standard and built-in rmgr core modules are preloaded in every
# phase; only the runtime GUC changes between restarts, so the version mismatch
# is attributable solely to the module selection and not to a missing library.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $test_dir = $ENV{TESTDIR};

my $node = PostgreSQL::Test::Cluster->new('rmgr_mode');
$node->init;

# Base extension configuration plus the built-in rmgr core module in
# shared_preload_libraries so it is available in every phase (its selection is
# still gated by the runtime GUC below). Parallelism is disabled so index
# access happens in the local backend, keeping the version-mismatch surface
# deterministic.
$node->append_conf('postgresql.conf', qq{
include '$test_dir/postgresql.conf'
shared_preload_libraries = 'pg_cron,pg_documentdb_core,pg_documentdb,pg_documentdb_extended_rum,pg_documentdb_extended_rum_core_builtin_rmgr'
documentdb_extended_rum.rum_use_builtin_rmgr_modules = 'off'
max_parallel_workers_per_gather = 0
max_parallel_maintenance_workers = 0
});

$node->start;

$node->safe_psql('postgres', q{
CREATE EXTENSION IF NOT EXISTS documentdb_core CASCADE;
CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;
CREATE EXTENSION IF NOT EXISTS documentdb_extended_rum CASCADE;
});

my $version_mismatch = qr/unexpected RUM index version|Invalid RUM version/;

# Flip the PGC_POSTMASTER GUC that selects the core module and restart so the
# new value takes effect.
sub set_builtin_rmgr
{
	my ($want_builtin) = @_;
	my $value = $want_builtin ? 'on' : 'off';
	$node->safe_psql('postgres',
		"ALTER SYSTEM SET documentdb_extended_rum.rum_use_builtin_rmgr_modules = '$value'");
	$node->restart;
	my $active = $node->safe_psql('postgres',
		'SHOW documentdb_extended_rum.rum_use_builtin_rmgr_modules');
	is($active, $value,
		"rum_use_builtin_rmgr_modules is '$value' after restart");
}

# Create a collection + extended_rum index and seed a few documents.
sub create_indexed_collection
{
	my ($db, $coll, $base_id) = @_;
	$node->safe_psql('postgres', qq{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SET documentdb.next_collection_id TO $base_id;
SET documentdb.next_collection_index_id TO $base_id;
SELECT documentdb_api.create_collection('$db', '$coll');
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    '$db',
    '{"createIndexes": "$coll", "indexes": [{"key": {"val": 1}, "name": "idx_val", "enableCompositeTerm": true}]}',
    true);
});
	seed_documents($db, $coll, 1, 200);
}

sub seed_documents
{
	my ($db, $coll, $from, $to) = @_;
	$node->safe_psql('postgres', qq{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SELECT COUNT(documentdb_api.insert_one(
    '$db', '$coll',
    FORMAT('{"_id": %s, "val": %s}', i, i % 25)::documentdb_core.bson))
FROM generate_series($from, $to) i;
});
}

# Force an index scan for the given filter and return (rc, stdout, stderr).
sub run_index_query
{
	my ($db, $coll, $val) = @_;
	my ($stdout, $stderr);
	my $rc = $node->psql('postgres', qq{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SET enable_seqscan = off;
SELECT COUNT(*) FROM documentdb_api.collection('$db', '$coll')
    WHERE document @@ '{"val": $val}';
}, stdout => \$stdout, stderr => \$stderr);
	return ($rc, $stdout, $stderr);
}

# Insert one document via insert_one. Returns (rc, result_json, stderr) where
# result_json is the insert_one response rendered as text. insert_one reports
# index failures inside the response document (writeErrors) rather than raising,
# so the SQL statement itself succeeds (rc 0) even when the write is rejected.
sub run_insert
{
	my ($db, $coll, $id) = @_;
	my ($stdout, $stderr);
	my $rc = $node->psql('postgres', qq{
SET search_path TO documentdb_api, documentdb_core, documentdb_api_catalog, documentdb_api_internal;
SELECT documentdb_core.bson_to_json_string(documentdb_api.insert_one(
    '$db', '$coll',
    FORMAT('{"_id": %s, "val": 7}', $id)::documentdb_core.bson));
}, stdout => \$stdout, stderr => \$stderr);
	return ($rc, $stdout, $stderr);
}

# ============================================================================
# Direction 1: index written by the standard core module, read under built-in.
# ============================================================================
create_indexed_collection('rmgrdb', 'core_first', 19000);

my ($rc, $out, $err) = run_index_query('rmgrdb', 'core_first', 7);
is($rc, 0, 'D1: index query succeeds in the module that created the index');
like($out, qr/\b8\b/, 'D1: index query returns expected count (200/25 = 8)');

# Switch to the built-in rmgr module: the core-format index is now unreadable.
set_builtin_rmgr(1);

($rc, $out, $err) = run_index_query('rmgrdb', 'core_first', 7);
isnt($rc, 0, 'D1: index query fails after switching to built-in rmgr module');
like($err, $version_mismatch,
	'D1: index query fails with a RUM version mismatch');

# Writes surface the mismatch too: RUM has no fastupdate pending list, so
# ruminsert reads the index metapage and hits the version check on the first
# indexed insert. insert_one traps the index error and reports it as a
# writeError (n:0) instead of raising, so assert on the response document.
my ($ins_rc, $ins_json, $ins_err) = run_insert('rmgrdb', 'core_first', 100001);
is($ins_rc, 0, 'D1: insert_one statement returns (error is carried in the response)');
like($ins_json, qr/"writeErrors"/,
	'D1: insert is rejected with a writeError under the built-in rmgr module');
like($ins_json, $version_mismatch,
	'D1: insert writeError reports a RUM version mismatch');

# Switch back to the standard module: the index is fully usable again.
set_builtin_rmgr(0);

($rc, $out, $err) = run_index_query('rmgrdb', 'core_first', 7);
is($rc, 0, 'D1: index query succeeds again after switching back');
like($out, qr/\b8\b/, 'D1: index query returns the original count after switching back');

($rc, $out, $err) = run_insert('rmgrdb', 'core_first', 100001);
is($rc, 0, 'D1: insert statement succeeds again after switching back');
unlike($out, qr/"writeErrors"/,
	'D1: insert is accepted (no writeError) after switching back');

# ============================================================================
# Direction 2 (inverse): index written by the built-in rmgr module, read under
# the standard module.
# ============================================================================
set_builtin_rmgr(1);
create_indexed_collection('rmgrdb', 'builtin_first', 19100);

($rc, $out, $err) = run_index_query('rmgrdb', 'builtin_first', 7);
is($rc, 0, 'D2: index query succeeds in the built-in rmgr module that created it');
like($out, qr/\b8\b/, 'D2: index query returns expected count');

# Switch to the standard module: the built-in-format index is now unreadable.
set_builtin_rmgr(0);

($rc, $out, $err) = run_index_query('rmgrdb', 'builtin_first', 7);
isnt($rc, 0, 'D2: index query fails after switching to standard module');
like($err, $version_mismatch,
	'D2: index query fails with a RUM version mismatch');

# Writes also fail cross-mode: no fastupdate pending list, so ruminsert reads
# the metapage and hits the version check on the first indexed insert. The error
# is reported as a writeError in the insert_one response.
my ($ins2_rc, $ins2_json, $ins2_err) = run_insert('rmgrdb', 'builtin_first', 200001);
is($ins2_rc, 0, 'D2: insert_one statement returns (error is carried in the response)');
like($ins2_json, qr/"writeErrors"/,
	'D2: insert is rejected with a writeError under the standard module');
like($ins2_json, $version_mismatch,
	'D2: insert writeError reports a RUM version mismatch');

# Switch back to the built-in rmgr module: the index is fully usable again.
set_builtin_rmgr(1);

($rc, $out, $err) = run_index_query('rmgrdb', 'builtin_first', 7);
is($rc, 0, 'D2: index query succeeds again after switching back');
like($out, qr/\b8\b/, 'D2: index query returns the original count after switching back');

($rc, $out, $err) = run_insert('rmgrdb', 'builtin_first', 200001);
is($rc, 0, 'D2: insert statement succeeds again after switching back');
unlike($out, qr/"writeErrors"/,
	'D2: insert is accepted (no writeError) after switching back');

$node->stop;

done_testing();
