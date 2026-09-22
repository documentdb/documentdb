# Copyright (c) Microsoft Corporation.  All rights reserved.
# SPDX-License-Identifier: MIT

use strict;
use warnings;
use Time::HiRes qw(usleep);
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils qw(slurp_file);
use Test::More;

sub leader_pid
{
	my ($node) = @_;
	return 0 + $node->safe_psql(
		'postgres',
		q{
SELECT COALESCE(max(pid), 0)
FROM pg_catalog.pg_stat_activity
WHERE application_name = 'documentdb_bg_worker_leader';
});
}

sub wait_for_leader
{
	my ($node) = @_;
	my $deadline = time() + 30;

	while (time() < $deadline)
	{
		my $pid = leader_pid($node);
		return $pid if $pid > 0;
		usleep(100_000);
	}

	diag "Server log:\n" . slurp_file($node->logfile);
	return 0;
}

sub wait_for_job_stats_success
{
	my ($node, $job_name) = @_;
	my $deadline = time() + 30;

	while (time() < $deadline)
	{
		my $success_count = eval {
			$node->safe_psql(
				'postgres',
				qq{
SELECT count(*)
FROM documentdb_api_internal.documentdb_stat_bgworker_jobs jobs
JOIN documentdb_api_internal.documentdb_stat_bgworker_job_stats stats
USING (job_id)
WHERE jobs.job_name = '$job_name'
  AND documentdb_core.bson_get_value_text(
          stats.statistics, 'successfulExecutions')::bigint > 0;
});
		};
		return 1 if defined $success_count && $success_count eq '1';
		usleep(100_000);
	}

	diag "Server log:\n" . slurp_file($node->logfile);
	return 0;
}

sub wait_for_job_log_success
{
	my ($node, $job_id) = @_;
	my $deadline = time() + 30;
	my $pattern = qr/Background worker job with id \Q$job_id\E succeeded/;

	while (time() < $deadline)
	{
		return 1 if slurp_file($node->logfile) =~ $pattern;
		usleep(100_000);
	}

	diag "Server log:\n" . slurp_file($node->logfile);
	return 0;
}

my $primary = PostgreSQL::Test::Cluster->new('bgworker_primary');
$primary->init();
$primary->append_conf(
	'postgresql.conf',
	qq{
shared_preload_libraries = 'pg_cron,pg_documentdb_core,pg_documentdb,pg_documentdb_extended_rum'
cron.database_name = 'postgres'
documentdb.rum_library_load_option = 'require_documentdb_extended_rum'
documentdb.enableBackgroundWorker = on
documentdb.enableBackgroundWorkerJobs = on
documentdb.enableBackgroundWorkerInitJobs = on
documentdb.bg_worker_enable_diagnostics_log = on
documentdb.bg_worker_database_name = 'postgres'
documentdb.bg_worker_latch_timeout = 1
documentdb.indexBuildScheduleInSec = 1
listen_addresses = 'localhost'
ssl = off
});
$primary->start();

is(
	$primary->safe_psql('postgres', q{SELECT pg_catalog.pg_is_in_recovery();}),
	'f',
	'primary server is writable');

$primary->safe_psql(
	'postgres',
	q{
CREATE EXTENSION IF NOT EXISTS documentdb_core CASCADE;
CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;
});

cmp_ok(wait_for_leader($primary), '>', 0, 'primary leader is attached');
ok(
	wait_for_job_stats_success(
		$primary, 'documentdb_index_build_background_job_1'),
	'first production index-build job records a successful execution');
ok(
	wait_for_job_stats_success(
		$primary, 'documentdb_index_build_background_job_2'),
	'second production index-build job records a successful execution');

ok(
	wait_for_job_log_success($primary, 90),
	'first production index-build job logs a successful execution');
ok(
	wait_for_job_log_success($primary, 91),
	'second production index-build job logs a successful execution');

is(
	$primary->safe_psql(
		'postgres',
		q{SHOW documentdb.enable_legacy_jobs_timeout;}),
	'on',
	'legacy job timeout remains enabled by default');

$primary->stop();

done_testing();
