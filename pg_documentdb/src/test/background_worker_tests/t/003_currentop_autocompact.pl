# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Observe real automatic maintenance workers with and without application filtering.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('currentop_autocompact');
$node->init;
$node->append_conf('postgresql.conf', q{
shared_preload_libraries = 'pg_cron,pg_documentdb_core,pg_documentdb,pg_documentdb_extended_rum'
cron.database_name = 'postgres'
documentdb.rum_library_load_option = 'require_documentdb_extended_rum'
documentdb.enableBackgroundWorker = off
documentdb.enableBackgroundWorkerJobs = off
listen_addresses = 'localhost'
autovacuum = on
autovacuum_naptime = '1s'
autovacuum_max_workers = 1
});
$node->start;
$node->safe_psql('postgres', q{
CREATE EXTENSION documentdb_core CASCADE;
CREATE EXTENSION documentdb CASCADE;
SELECT documentdb_api.create_collection('testdb', 'auto_maintenance');
});
my $table = $node->safe_psql('postgres', q{
SELECT FORMAT('documentdb_data.documents_%s', collection_id)
FROM documentdb_api_catalog.collections
WHERE database_name = 'testdb' AND collection_name = 'auto_maintenance';
});
$node->safe_psql('postgres', qq{
ALTER TABLE $table SET (autovacuum_enabled = false);
SELECT documentdb_api.insert_one('testdb', 'auto_maintenance',
    json_build_object('_id', i, 'padding', repeat('x', 1000))::text::documentdb_core.bson)
FROM generate_series(1, 6000) i;
});

my $current_op = q{
SELECT documentdb_core.bson_to_json_string(document)
FROM documentdb_api_internal.current_op_aggregation(
    '{"allUsers":true,"localOps":true}')
WHERE document OPERATOR(documentdb_api_catalog.@@)
    '{"ns":"testdb.auto_maintenance","active":true,"op":"workerCommand"}';
};

for my $operation ('vacuum', 'analyze')
{
    # Cost delays keep each worker observable without relying on fixed sleeps.
    my $insert_threshold = $operation eq 'vacuum' ? 0 : -1;
    my $analyze_threshold = $operation eq 'analyze' ? 0 : 1000000000;
    $node->safe_psql('postgres', qq{
ALTER TABLE $table SET (
    autovacuum_enabled = true,
    autovacuum_vacuum_insert_threshold = $insert_threshold,
    autovacuum_vacuum_insert_scale_factor = 0,
    autovacuum_analyze_threshold = $analyze_threshold,
    autovacuum_analyze_scale_factor = 0,
    autovacuum_vacuum_cost_limit = 1,
    autovacuum_vacuum_cost_delay = 20);
});
    $node->poll_query_until('postgres', qq{
SELECT EXISTS (
    SELECT 1
    FROM pg_stat_progress_$operation progress
    JOIN pg_stat_activity activity USING (pid)
    WHERE progress.relid = '$table'::regclass
      AND activity.backend_type = 'autovacuum worker'
      AND progress.phase IN ('scanning heap', 'acquiring sample rows'));
}) or BAIL_OUT("automatic $operation did not start");

    my $document = $node->safe_psql('postgres', qq{
SET documentdb.current_op_application_name = '';
$current_op
});
    like($document, qr/"autocompact"\s*:\s*"auto_maintenance"/,
        "automatic $operation is classified as autocompact");
    my $message = $operation eq 'vacuum' ? 'Vacuum' : 'Analyze';
    like($document, qr/"msg"\s*:\s*"$message progress:/,
        "automatic $operation includes maintenance progress");
    if ($operation eq 'analyze')
    {
        like($document, qr/"mode"\s*:\s*"updateStats"/,
            'automatic analyze uses updateStats mode');
    }

    my $filtered_document = $node->safe_psql('postgres', qq{
SET documentdb.current_op_application_name = 'currentop_test_client';
$current_op
});
    like($filtered_document, qr/"autocompact"\s*:\s*"auto_maintenance"/,
        "automatic $operation remains visible with application filtering");

    $node->safe_psql('postgres', qq{
ALTER TABLE $table SET (autovacuum_enabled = false);
});
}

my $locker = $node->background_psql('postgres');
my $maintenance_session = $node->background_psql('postgres');
$maintenance_session->query_safe(
    "SET application_name = 'currentop_test_client';");
my $maintenance_pid = $maintenance_session->query_safe('SELECT pg_backend_pid()');
for my $operation ('VACUUM', 'ANALYZE')
{
    $locker->query_safe("BEGIN; LOCK TABLE $table IN ACCESS EXCLUSIVE MODE;");
    $maintenance_session->query_until(qr/maintenance_started/,
        "\\echo maintenance_started\n$operation $table;\n");
    $node->poll_query_until('postgres', qq{
SELECT wait_event_type = 'Lock'
FROM pg_stat_activity WHERE pid = $maintenance_pid;
}) or BAIL_OUT("manual $operation did not wait for the collection lock");

    my $document = $node->safe_psql('postgres', qq{
SET documentdb.current_op_application_name = 'currentop_test_client';
$current_op
});
    like($document, qr/"command"\s*:\s*\{\s*"compact"\s*:\s*"auto_maintenance"/,
        "manual $operation remains classified as compact");
    $locker->query_safe('COMMIT;');
    $maintenance_session->query_safe('SELECT 1;');
}
$maintenance_session->quit;
$locker->quit;

$node->stop;
done_testing();
