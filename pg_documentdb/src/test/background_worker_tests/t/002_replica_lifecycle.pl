# Copyright (c) Microsoft Corporation.  All rights reserved.
# SPDX-License-Identifier: MIT

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils qw(slurp_file);
use Test::More;
use Time::HiRes qw(usleep);

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
	my ($node, $timeout_sec) = @_;
	$timeout_sec //= 30;

	my $deadline = time() + $timeout_sec;
	while (time() < $deadline)
	{
		my $pid = leader_pid($node);
		return $pid if $pid > 0;
		usleep(100_000);
	}

	diag "leader startup timed out\n" . slurp_file($node->logfile);
	return 0;
}

sub wait_for_log
{
	my ($node, $pattern, $description, $timeout_sec) = @_;
	$timeout_sec //= 30;

	my $deadline = time() + $timeout_sec;
	while (time() < $deadline)
	{
		return 1 if slurp_file($node->logfile) =~ $pattern;
		usleep(100_000);
	}

	diag "$description timed out\n" . slurp_file($node->logfile);
	return 0;
}

sub wait_for_job_success
{
	my ($node, $job_id, $timeout_sec) = @_;
	$timeout_sec //= 30;
	my $pattern = qr/BGW_JOB_ATTEMPT_SUCCEEDED [^\n]*job_id=\Q$job_id\E\b/;

	my $deadline = time() + $timeout_sec;
	while (time() < $deadline)
	{
		return 1 if slurp_file($node->logfile) =~ $pattern;
		usleep(100_000);
	}

	diag "job $job_id timed out\n" . slurp_file($node->logfile);
	return 0;
}

sub wait_for_job_stats_success
{
	my ($node, $job_id, $timeout_sec) = @_;
	$timeout_sec //= 30;

	my $deadline = time() + $timeout_sec;
	while (time() < $deadline)
	{
		my $success_count = eval {
			$node->safe_psql(
				'postgres',
				qq{
SELECT documentdb_core.bson_get_value_text(
		   statistics, 'successfulExecutions')::bigint
FROM documentdb_api_internal.documentdb_stat_bgworker_job_stats
WHERE job_id = $job_id;
});
		};
		return 1 if defined $success_count && $success_count > 0;
		usleep(100_000);
	}

	diag "job $job_id statistics timed out\n" . slurp_file($node->logfile);
	return 0;
}

sub append_replica_config
{
	my ($node, $enable_startup) = @_;
	$node->append_conf(
		'postgresql.conf',
		qq{
documentdb.enableBackgroundWorker = on
documentdb.enableBackgroundWorkerJobs = on
documentdb.enableBackgroundWorkerInitJobs = on
documentdb.start_background_worker_in_recovery = $enable_startup
documentdb.enable_background_worker_jobs_in_recovery = off
documentdb.bg_worker_enable_diagnostics_log = on
documentdb.bg_worker_database_name = 'postgres'
documentdb.bg_worker_latch_timeout = 1
documentdb.indexBuildScheduleInSec = 1
});
}

my $primary = PostgreSQL::Test::Cluster->new('bgworker_replica_primary');
$primary->init(allows_streaming => 1);
$primary->append_conf(
	'postgresql.conf',
	qq{
shared_preload_libraries = 'pg_cron,pg_documentdb_core,pg_documentdb,pg_documentdb_extended_rum'
cron.database_name = 'postgres'
documentdb.rum_library_load_option = 'require_documentdb_extended_rum'
documentdb.enableBackgroundWorker = off
documentdb.enableBackgroundWorkerJobs = off
documentdb.enableBackgroundWorkerInitJobs = off
listen_addresses = 'localhost'
ssl = off
});
$primary->start;

is(
	$primary->safe_psql(
		'postgres',
		q{SHOW documentdb.start_background_worker_in_recovery;}),
	'off',
	'recovery startup defaults off');
is(
	$primary->safe_psql(
		'postgres',
		q{SHOW documentdb.enable_background_worker_jobs_in_recovery;}),
	'off',
	'recovery dispatch defaults off');
is(
	$primary->safe_psql(
		'postgres',
		q{SHOW documentdb.enable_bgworker_promotion_barrier;}),
	'off',
	'promotion barrier defaults off');

$primary->safe_psql(
	'postgres',
	q{
CREATE EXTENSION IF NOT EXISTS documentdb_core CASCADE;
CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;

CREATE OR REPLACE FUNCTION documentdb_api_internal.cursor_directory_cleanup(
	expiry_time_seconds bigint DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
	IF pg_catalog.pg_is_in_recovery() THEN
		RAISE LOG 'Recovery cursor cleanup entered blocking test body';
		PERFORM pg_catalog.pg_sleep(10);
	END IF;
END;
$function$;
});

my $backup_name = 'bgworker_replica_lifecycle_backup';
$primary->backup($backup_name);

subtest 'recovery startup defaults off' => sub
{
	my $standby = PostgreSQL::Test::Cluster->new('bgworker_replica_startup_off');
	$standby->init_from_backup($primary, $backup_name, has_streaming => 1);
	append_replica_config($standby, 'off');
	$standby->start;

	is(
		$standby->safe_psql('postgres', q{SELECT pg_is_in_recovery();}),
		't',
		'server remains in recovery');
	is(
		leader_pid($standby),
		0,
		'leader does not start while the recovery-startup gate is off');

	$standby->stop;
};

subtest 'promotion barrier defaults off' => sub
{
	my $standby = PostgreSQL::Test::Cluster->new('bgworker_replica_promotion_off');
	$standby->init_from_backup($primary, $backup_name, has_streaming => 1);
	append_replica_config($standby, 'on');
	$standby->start;

	my $recovery_leader_pid = wait_for_leader($standby);
	cmp_ok($recovery_leader_pid, '>', 0, 'leader starts in recovery');

	$standby->promote;

	is(
		leader_pid($standby),
		$recovery_leader_pid,
		'leader process survives promotion');
	ok(
		wait_for_log(
			$standby,
			qr/BGW_ROLE_TRANSITION leader_pid=\Q$recovery_leader_pid\E [^\n]*promotion_observed=1 [^\n]*previous_in_recovery=1 current_in_recovery=0 promotion_barrier_enabled=0 promotion_barrier_applied=0/,
			'default-off role transition'),
		'default-off promotion records the selected bypass path');
	ok(
		wait_for_log(
			$standby,
			qr/BGW_PRIMARY_SCHEDULING_RESUMED leader_pid=\Q$recovery_leader_pid\E promotion_observed=1 promotion_barrier_applied=0 transition_pass_count=0/,
			'default-off primary scheduling resume'),
		'default-off promotion records primary scheduling admission');
	ok(
		wait_for_job_success($standby, 90),
		'first production job runs after promotion');
	ok(
		wait_for_job_success($standby, 91),
		'second production job runs after promotion');
	unlike(
		slurp_file($standby->logfile),
		qr/BGW_PROMOTION_BARRIER_ENTERED/,
		'default-off promotion bypasses the barrier');
	$standby->stop;
};

subtest 'promotion barrier diagnostics default off' => sub
{
	my $standby = PostgreSQL::Test::Cluster->new('bgworker_replica_diagnostics_off');
	$standby->init_from_backup($primary, $backup_name, has_streaming => 1);
	append_replica_config($standby, 'on');
	$standby->append_conf(
		'postgresql.conf',
		qq{
documentdb.enable_bgworker_promotion_barrier = on
documentdb.bg_worker_enable_diagnostics_log = off
});
	$standby->start;

	my $recovery_leader_pid = wait_for_leader($standby);
	cmp_ok($recovery_leader_pid, '>', 0, 'leader starts in recovery');

	$standby->promote;

	ok(
		wait_for_job_stats_success($standby, 90),
		'primary-only job runs after promotion');
	unlike(
		slurp_file($standby->logfile),
		qr/BGW_PROMOTION_BARRIER_(?:ENTERED|PASS|COMPLETED)/,
		'promotion barrier diagnostics remain disabled');
	$standby->stop;
};

subtest 'promotion barrier drains recovery work' => sub
{
	my $standby = PostgreSQL::Test::Cluster->new('bgworker_replica_promotion_drain');
	$standby->init_from_backup($primary, $backup_name, has_streaming => 1);
	append_replica_config($standby, 'on');
	$standby->append_conf(
		'postgresql.conf',
		qq{
documentdb.enable_background_worker_jobs_in_recovery = on
documentdb.enable_bgworker_promotion_barrier = on
documentdb.enable_cursor_cleanup_in_recovery = on
});
	$standby->start;

	my $recovery_leader_pid = wait_for_leader($standby);
	cmp_ok($recovery_leader_pid, '>', 0, 'leader starts in recovery');
	ok(
		wait_for_log(
			$standby,
			qr/BGW_JOB_ATTEMPT_DISPATCHED [^\n]*job_id=92 [^\n]*execution_in_recovery=1\b/,
			'recovery-only job dispatch',
			75),
		'recovery-only job starts before promotion');
	ok(
		wait_for_log(
			$standby,
			qr/Recovery cursor cleanup entered blocking test body/,
			'recovery-only job blocking body'),
		'recovery-only job is running before promotion');

	$standby->promote;

	ok(
		wait_for_log(
			$standby,
			qr/BGW_PROMOTION_BARRIER_PASS promotion_observed=1 transition_pass_count=1 running_recovery_jobs_before=1 running_recovery_jobs_after=1/,
			'promotion barrier recovery-job drain'),
		'barrier remains active while recovery work is running');

	my $barrier_log = slurp_file($standby->logfile);
	unlike(
		$barrier_log,
		qr/BGW_PROMOTION_BARRIER_COMPLETED/,
		'barrier does not complete while recovery work is running');
	unlike(
		$barrier_log,
		qr/BGW_PRIMARY_SCHEDULING_RESUMED/,
		'primary scheduling does not resume while recovery work is running');
	unlike(
		$barrier_log,
		qr/BGW_JOB_ATTEMPT_SUCCEEDED [^\n]*job_id=(?:90|91)\b/,
		'primary-only jobs do not complete while recovery work is running');
	is(
		$standby->safe_psql(
			'postgres',
			q{
SELECT bool_and(
		   documentdb_core.bson_get_value_text(
			   statistics, 'executionAttempts')::bigint = 0)
FROM documentdb_api_internal.documentdb_stat_bgworker_job_stats
WHERE job_id IN (90, 91);
}),
		't',
		'cumulative statistics contain no primary-job completion while the barrier drains');

	ok(
		wait_for_job_success($standby, 92, 25),
		'recovery-only job completes after promotion');
	ok(
		wait_for_job_stats_success($standby, 92),
		'recovery-only job publishes a successful terminal attempt');
	ok(
		wait_for_log(
			$standby,
			qr/BGW_PROMOTION_BARRIER_PASS promotion_observed=1 transition_pass_count=\d+ running_recovery_jobs_before=1 running_recovery_jobs_after=0/,
			'promotion barrier recovery-job completion'),
		'barrier observes recovery work reaching a terminal state');
	ok(
		wait_for_log(
			$standby,
			qr/BGW_PROMOTION_BARRIER_COMPLETED leader_pid=\Q$recovery_leader_pid\E promotion_observed=1 transition_pass_count=\d+/,
			'promotion barrier completion'),
		'barrier completes after recovery work drains');
	ok(
		wait_for_log(
			$standby,
			qr/BGW_PRIMARY_SCHEDULING_RESUMED leader_pid=\Q$recovery_leader_pid\E promotion_observed=1 promotion_barrier_applied=1 transition_pass_count=\d+/,
			'primary scheduling resume'),
		'primary scheduling resumes on a later pass');
	ok(
		wait_for_job_success($standby, 90),
		'first production job runs after recovery work drains');
	ok(
		wait_for_job_success($standby, 91),
		'second production job runs after recovery work drains');
	ok(
		wait_for_job_stats_success($standby, 90),
		'first primary-only job publishes a successful terminal attempt');
	ok(
		wait_for_job_stats_success($standby, 91),
		'second primary-only job publishes a successful terminal attempt');
	is(
		leader_pid($standby),
		$recovery_leader_pid,
		'leader process survives promotion and recovery-job draining');
	is(
		$standby->safe_psql(
			'postgres',
			q{
WITH job_stats AS
(
	SELECT jobs.job_id,
		   documentdb_core.bson_get_value_text(
			   jobs.job_options, 'roleExecutionProfile') AS role_execution_profile,
		   documentdb_core.bson_get_value(
			   stats.statistics, 'firstAttemptTs') AS first_attempt_ts,
		   documentdb_core.bson_get_value(
			   stats.statistics, 'lastObservedResolutionTs')
			   AS last_observed_resolution_ts,
		   documentdb_core.bson_get_value(
			   stats.statistics, 'statsResetTs') AS stats_reset_ts
	FROM documentdb_api_internal.documentdb_stat_bgworker_jobs jobs
	JOIN documentdb_api_internal.documentdb_stat_bgworker_job_stats stats
		USING (job_id)
	WHERE jobs.job_id IN (90, 91, 92)
),
recovery_job AS
(
	SELECT last_observed_resolution_ts
	FROM job_stats
	WHERE job_id = 92
	  AND role_execution_profile = 'recoveryOnly'
)
SELECT count(*) = 2
	   AND (SELECT count(DISTINCT stats_reset_ts) = 1 FROM job_stats)
	   AND bool_and(role_execution_profile = 'primaryOnly')
	   AND bool_and(first_attempt_ts OPERATOR(documentdb_core.>=)
					(SELECT last_observed_resolution_ts FROM recovery_job))
FROM job_stats
WHERE job_id IN (90, 91);
}),
		't',
		'cumulative statistics prove recovery resolution preceded primary attempts');

	my $completed_log = slurp_file($standby->logfile);
	like(
		$completed_log,
		qr/BGW_PROMOTION_BARRIER_COMPLETED [^\n]*transition_pass_count=(?:[2-9]|\d{2,})\b/,
		'barrier waits across multiple scheduling passes');
	like(
		$completed_log,
		qr/BGW_JOB_ATTEMPT_DISPATCHED [^\n]*job_id=92 attempt_id=(\d+) execution_in_recovery=1 [^\n]*promotion_observed=0.*BGW_JOB_ATTEMPT_SUCCEEDED [^\n]*job_id=92 attempt_id=\1 execution_in_recovery=1 [^\n]*promotion_observed=0/s,
		'recovery attempt identity and role remain stable through terminal resolution');
	unlike(
		$completed_log,
		qr/BGW_JOB_ATTEMPT_(?:STARTED|DISPATCHED|SUCCEEDED|FAILED|TIMED_OUT|UNOBSERVED)[^\n]*execution_in_recovery=0x/,
		'role diagnostics never render pointer values');

	$standby->stop;
};

subtest 'promotion barrier enabled' => sub
{
	my $standby = PostgreSQL::Test::Cluster->new('bgworker_replica_promotion');
	$standby->init_from_backup($primary, $backup_name, has_streaming => 1);
	append_replica_config($standby, 'on');
	$standby->append_conf(
		'postgresql.conf',
		qq{
documentdb.enable_bgworker_promotion_barrier = on
});
	$standby->start;

	my $recovery_leader_pid = wait_for_leader($standby);
	cmp_ok($recovery_leader_pid, '>', 0, 'leader starts in recovery');

	$primary->stop;
	$standby->promote;

	ok(
		wait_for_log(
			$standby,
			qr/BGW_ROLE_TRANSITION leader_pid=\Q$recovery_leader_pid\E [^\n]*promotion_observed=1 [^\n]*previous_in_recovery=1 current_in_recovery=0 promotion_barrier_enabled=1 promotion_barrier_applied=1/,
			'promotion role transition'),
		'leader records the selected barrier path');
	ok(
		wait_for_log(
			$standby,
			qr/BGW_PROMOTION_BARRIER_ENTERED leader_pid=\Q$recovery_leader_pid\E promotion_observed=1/,
			'promotion barrier entry'),
		'leader observes promotion');
	ok(
		wait_for_log(
			$standby,
			qr/BGW_PROMOTION_BARRIER_PASS promotion_observed=1 transition_pass_count=1 running_recovery_jobs_before=0 running_recovery_jobs_after=0/,
			'promotion barrier lifecycle processing'),
		'barrier processes completion and timeout state without dispatch');
	ok(
		wait_for_log(
			$standby,
			qr/BGW_JOB_EXECUTIONS_REGENERATED previous_execution_count=\d+ regenerated_execution_count=\d+/,
			'promotion execution-state regeneration'),
		'job execution state is regenerated');
	ok(
		wait_for_log(
			$standby,
			qr/BGW_PROMOTION_BARRIER_COMPLETED leader_pid=\Q$recovery_leader_pid\E promotion_observed=1 transition_pass_count=1/,
			'promotion barrier completion'),
		'barrier completes before primary scheduling resumes');
	ok(
		wait_for_log(
			$standby,
			qr/BGW_PRIMARY_SCHEDULING_RESUMED leader_pid=\Q$recovery_leader_pid\E promotion_observed=1 promotion_barrier_applied=1 transition_pass_count=1/,
			'primary scheduling resume'),
		'primary scheduling resumes on a later pass');
	is(
		leader_pid($standby),
		$recovery_leader_pid,
		'leader process survives promotion');
	ok(
		wait_for_job_success($standby, 90),
		'first production job runs after promotion');
	ok(
		wait_for_job_success($standby, 91),
		'second production job runs after promotion');
	$standby->stop;
};

done_testing();
