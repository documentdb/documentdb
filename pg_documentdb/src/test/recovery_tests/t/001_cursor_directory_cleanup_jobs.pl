# Verify recovery-only cursor cleanup registration and UDF behavior.

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

my $test_dir = $ENV{TESTDIR};
my $node = PostgreSQL::Test::Cluster->new('cursor_cleanup');
$node->init;
$node->append_conf('postgresql.conf', "include '$test_dir/postgresql.conf'");
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
	qr/^92\|documentdb_cursor_cleanup_background_job\|t\|documentdb_api_internal\.cursor_directory_cleanup\|.*"roleExecutionProfile" : "recoveryOnly".*$/,
	'cursor cleanup job is enabled and registered as recovery-only');

my $recovery_cursor_file =
	CreateExpiredCursorFile($node, 'recovery_cleanup_tap_test');
ok(-e $recovery_cursor_file,
	'expired cursor file exists before scheduled recovery cleanup');
WaitForFileRemoval(
	$recovery_cursor_file,
	90,
	'recovery leader dispatches cursor cleanup automatically');

done_testing();
