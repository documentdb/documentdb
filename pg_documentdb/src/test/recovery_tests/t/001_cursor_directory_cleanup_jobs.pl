# Verify role-aware cursor cleanup ownership and scheduled execution.

use strict;
use warnings;
use Time::HiRes qw(sleep time);
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

sub CreateExpiredCursorFile
{
	my ($node, $file_name) = @_;
	my $cursor_file =
		$node->data_dir . "/pg_documentdb_cursor_files/$file_name";

	open(my $cursor_fh, '>', $cursor_file)
		or die "could not create cursor file '$cursor_file': $!";
	print {$cursor_fh} "expired cursor\n";
	close($cursor_fh)
		or die "could not close cursor file '$cursor_file': $!";

	my $expired_time = time() - 10;
	utime($expired_time, $expired_time, $cursor_file)
		or die "could not age cursor file '$cursor_file': $!";

	return $cursor_file;
}

sub WaitForFileRemoval
{
	my ($cursor_file, $timeout_seconds, $description) = @_;
	my $deadline = time() + $timeout_seconds;

	while (time() < $deadline)
	{
		if (!-e $cursor_file)
		{
			pass($description);
			return;
		}
		sleep(0.25);
	}

	fail($description);
}

sub CheckPrimaryOwnership
{
	my ($node, $settings, $background_owns, $description) = @_;
	my $sql = "$settings SET documentdb.defaultCursorExpiryTimeLimitSeconds = 1;";

	is(
		$node->safe_psql('postgres', "$sql
SELECT enabled::int
FROM documentdb_api_internal.documentdb_stat_bgworker_jobs
WHERE job_id = 92;"),
		$background_owns ? '1' : '0',
		"$description: registry reflects ownership");

	my $background_file = CreateExpiredCursorFile($node, 'background_entrypoint');
	$node->safe_psql('postgres', "$sql
SELECT documentdb_api_internal.cursor_directory_cleanup_background();");
	ok($background_owns ? !-e $background_file : -e $background_file,
		"$description: background entry point matches ownership");
	unlink($background_file) if -e $background_file;

	my $legacy_file = CreateExpiredCursorFile($node, 'legacy_entrypoint');
	$node->safe_psql('postgres', "$sql
SELECT documentdb_api_internal.cursor_directory_cleanup(NULL::bigint);");
	ok($background_owns ? -e $legacy_file : !-e $legacy_file,
		"$description: legacy entry point matches inverse ownership");
	unlink($legacy_file) if -e $legacy_file;
}

my $test_dir = $ENV{TESTDIR};
my $node = PostgreSQL::Test::Cluster->new('cursor_cleanup');
$node->init;
$node->append_conf('postgresql.conf', "include '$test_dir/postgresql.conf'");
$node->append_conf('postgresql.conf', q{
log_line_prefix = '%u %a '
documentdb.defaultCursorExpiryTimeLimitSeconds = 3600
documentdb.enable_cursor_cleanup_background = off
documentdb.enable_bgworker_promotion_barrier = off
});
$node->start;

$node->safe_psql('postgres', q{
CREATE EXTENSION IF NOT EXISTS documentdb_core CASCADE;
CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;
UPDATE cron.job
SET active = false
WHERE jobname = 'documentdb_cursor_cleanup_task';
});

is(
	$node->safe_psql('postgres', 'SELECT pg_is_in_recovery()'),
	'f',
	'server starts as primary');

$node->poll_query_until(
	'postgres',
	q{SELECT EXISTS (
		SELECT 1
		FROM pg_stat_activity
		WHERE application_name = 'documentdb_bg_worker_leader')},
	't') or BAIL_OUT('background worker leader did not start on primary');

is(
	$node->safe_psql(
		'postgres',
		q{SELECT active::int
		  FROM cron.job
		  WHERE jobname = 'documentdb_cursor_cleanup_task'}),
	'0',
	'primary cron cursor cleanup is disabled for scheduler isolation');

CheckPrimaryOwnership(
	$node,
	'SET documentdb.enable_bgworker_promotion_barrier = on;',
	0,
	'ownership flag off');
CheckPrimaryOwnership(
	$node,
	'SET documentdb.enable_cursor_cleanup_background = on;',
	0,
	'promotion barrier off');
CheckPrimaryOwnership(
	$node,
	'SET documentdb.enable_cursor_cleanup_background = on;
SET documentdb.enable_bgworker_promotion_barrier = on;
SET documentdb.enableBackgroundWorkerJobs = off;',
	0,
	'periodic dispatch off');
CheckPrimaryOwnership(
	$node,
	'SET documentdb.enable_cursor_cleanup_background = on;
SET documentdb.enable_bgworker_promotion_barrier = on;
SET documentdb.enable_cursor_cleanup_in_recovery = off;',
	1,
	'primary ownership does not depend on the recovery flag');

$node->append_conf('postgresql.conf', q{
documentdb.enable_cursor_cleanup_background = on
documentdb.enable_bgworker_promotion_barrier = on
});
$node->reload;
$node->poll_query_until('postgres', q{
SELECT enabled
FROM documentdb_api_internal.documentdb_stat_bgworker_jobs
WHERE job_id = 92;
}, 't') or BAIL_OUT('primary background ownership was not enabled');

my $suppressed_cron_file =
	CreateExpiredCursorFile($node, 'suppressed_cron_cleanup');
$node->safe_psql('postgres', q{
SELECT cron.alter_job(
	(SELECT jobid FROM cron.job
	 WHERE jobname = 'documentdb_cursor_cleanup_task'),
	schedule => '10 seconds',
	command => 'SET documentdb.defaultCursorExpiryTimeLimitSeconds = 1; SELECT documentdb_api_internal.cursor_directory_cleanup();',
	active => true);
});
$node->poll_query_until('postgres', q{
SELECT EXISTS (
	SELECT 1 FROM cron.job_run_details
	WHERE jobid = (SELECT jobid FROM cron.job
				   WHERE jobname = 'documentdb_cursor_cleanup_task')
	  AND status = 'succeeded');
}, 't') or BAIL_OUT('suppressed cron cleanup did not complete successfully');
ok(-e $suppressed_cron_file,
	'active cron job succeeds without cleaning files owned by the background worker');

$node->safe_psql('postgres', q{
UPDATE cron.job SET active = false
WHERE jobname = 'documentdb_cursor_cleanup_task';
});
$node->append_conf('postgresql.conf',
	"documentdb.defaultCursorExpiryTimeLimitSeconds = 1\n");
$node->reload;

my $primary_cursor_file =
	CreateExpiredCursorFile($node, 'primary_cleanup_tap_test');
WaitForFileRemoval(
	$primary_cursor_file,
	90,
	'primary leader dispatches cursor cleanup automatically');
like(
	slurp_file($node->logfile),
	qr/documentdb_bg_worker_role documentdb_cursor_cleanup_background_job .*Deleting expired cursor file .*primary_cleanup_tap_test/,
	'primary file removal is performed by the background-worker role');

$node->append_conf('postgresql.conf',
	"documentdb.enable_cursor_cleanup_background = off\n");
$node->reload;
$node->poll_query_until('postgres', q{
SELECT enabled
FROM documentdb_api_internal.documentdb_stat_bgworker_jobs
WHERE job_id = 92;
}, 'f') or BAIL_OUT('primary background ownership was not disabled');
my $rollback_cursor_file =
	CreateExpiredCursorFile($node, 'cron_rollback_cleanup');
$node->safe_psql('postgres', q{
UPDATE cron.job SET active = true
WHERE jobname = 'documentdb_cursor_cleanup_task';
});
WaitForFileRemoval(
	$rollback_cursor_file,
	30,
	'cron resumes cleanup after live ownership rollback');
like(
	slurp_file($node->logfile),
	qr/ pg_cron .*Deleting expired cursor file .*cron_rollback_cleanup/,
	'rollback file removal is performed by the cron job owner');
$node->safe_psql('postgres', q{
UPDATE cron.job SET active = false
WHERE jobname = 'documentdb_cursor_cleanup_task';
});

$node->stop;
$node->set_standby_mode;
$node->start;

my $result = $node->safe_psql('postgres', 'SELECT pg_is_in_recovery()');
is($result, 't', 'server is in recovery');

$node->poll_query_until(
	'postgres',
	q{SELECT EXISTS (
		SELECT 1
		FROM pg_stat_activity
		WHERE application_name = 'documentdb_bg_worker_leader')},
	't') or BAIL_OUT('background worker leader did not start in recovery');

$result = $node->safe_psql('postgres', q{
SELECT job_id, job_name, enabled, command,
       documentdb_core.bson_to_json_string(job_options)
FROM documentdb_api_internal.documentdb_stat_bgworker_jobs
WHERE job_id = 92;
});
like(
	$result,
	qr/^92\|documentdb_cursor_cleanup_background_job\|t\|documentdb_api_internal\.cursor_directory_cleanup_background\|.*"roleExecutionProfile" : "recoveryEligible".*$/,
	'cursor cleanup job is enabled and registered for both roles');

my $recovery_cursor_file =
	CreateExpiredCursorFile($node, 'recovery_cleanup_tap_test');
ok(-e $recovery_cursor_file,
	'expired cursor file exists before scheduled recovery cleanup');
WaitForFileRemoval(
	$recovery_cursor_file,
	90,
	'recovery leader dispatches cursor cleanup automatically');

$node->stop;
$node->append_conf('postgresql.conf',
	"documentdb.enable_cursor_cleanup_in_recovery = off\n"
		. "documentdb.enable_cursor_cleanup_background = on\n");
$node->start;

my $manual_cursor_file =
	CreateExpiredCursorFile($node, 'manual_cleanup_tap_test');
$node->safe_psql('postgres', q{
SELECT documentdb_api_internal.cursor_directory_cleanup_background();
});
ok(-e $manual_cursor_file,
	'background cleanup respects the disabled recovery cleanup flag');
$node->safe_psql('postgres', q{
SELECT documentdb_api_internal.cursor_directory_cleanup(NULL::bigint);
});
ok(!-e $manual_cursor_file,
	'legacy cleanup remains callable in recovery with background cleanup disabled');

$node->stop;

done_testing();
