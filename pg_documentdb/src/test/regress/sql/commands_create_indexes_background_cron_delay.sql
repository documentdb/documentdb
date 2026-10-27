-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT License.

SET documentdb.next_collection_id TO 58327000;
SET documentdb.next_collection_index_id TO 58327000;
SET search_path TO documentdb_core, documentdb_api, documentdb_api_catalog;
SET statement_timeout TO '180s';

SELECT current_setting('documentdb.indexBuildsScheduledOnBgWorker') AS previous_index_build_mode \gset
SELECT current_setting('documentdb.enable_background_index_build_notify') AS previous_index_build_notify \gset
SELECT current_setting('documentdb.indexBuildScheduleInSec') AS previous_index_build_schedule \gset
ALTER SYSTEM SET documentdb.indexBuildsScheduledOnBgWorker = off;
ALTER SYSTEM SET documentdb.enable_background_index_build_notify = off;
ALTER SYSTEM SET documentdb.indexBuildScheduleInSec = 60;
SELECT pg_reload_conf();

SET documentdb.force_index_builds_blocking = off;
-- Pin the enqueue setting; reloads may not reach this session before a CALL.
SET documentdb.enable_background_index_build_notify = off;
SET documentdb.maxNumActiveUsersIndexBuilds TO 1;
SET documentdb.indexBuildScheduleInSec TO 60;
SELECT FROM documentdb_api_internal.schedule_background_index_build_jobs(true);

SELECT count(*) = 1 AND bool_and(schedule = '* * * * *' AND active) AS cron_runs_once_per_minute
FROM cron.job
WHERE jobname LIKE 'documentdb_index_build_task_%';

SELECT documentdb_test_helpers.stop_index_jobs();

DELETE FROM documentdb_api_catalog.documentdb_index_queue;
SELECT documentdb_api.create_collection('cron_schedule_db', 'cron_schedule_delay');

CREATE PROCEDURE documentdb_test_helpers.assert_cron_index_build_delay(use_notify boolean)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    create_response record;
    build_status record;
    index_path text;
    started_at timestamptz;
BEGIN
    FOREACH index_path IN ARRAY ARRAY[
        CASE WHEN use_notify THEN 'warmup_notify' ELSE 'warmup' END,
        CASE WHEN use_notify THEN 'notify' ELSE 'a' END]
    LOOP
        started_at := clock_timestamp();
        SELECT * INTO create_response
        FROM documentdb_api.create_indexes_background(
            'cron_schedule_db',
            format('{"createIndexes":"cron_schedule_delay","indexes":[{"key":{"%s":1},"name":"%s_1"}]}',
                   index_path, index_path)::documentdb_core.bson);

        IF create_response.ok IS DISTINCT FROM true
           OR create_response.requests->>'indexRequest' IS NULL THEN
            RAISE EXCEPTION 'Expected a queued index build, got %', create_response;
        END IF;
        COMMIT;

        LOOP
            SELECT * INTO build_status
            FROM documentdb_api_internal.check_build_index_status(create_response.requests);
            IF build_status.ok IS DISTINCT FROM true THEN
                RAISE EXCEPTION 'Background index build failed: %', build_status;
            END IF;
            IF build_status.complete THEN
                IF use_notify THEN
                    -- Require only task 1 to remain as a sleeping listener so the next
                    -- request tests a wakeup rather than the same queue-draining pass.
                    EXIT WHEN (
                        SELECT count(*) = 1
                            AND bool_and(j.jobname = 'documentdb_index_build_task_1'
                                         AND a.wait_event_type = 'Extension')
                        FROM pg_stat_activity AS a
                        JOIN cron.job AS j ON j.command = a.query
                        WHERE j.jobname LIKE 'documentdb_index_build_task_%'
                          AND a.datname = current_database()
                          AND a.state = 'active');
                ELSE
                    -- Without notifications, the warm-up invocation must have exited.
                    EXIT WHEN NOT EXISTS (
                        SELECT 1
                        FROM pg_stat_activity AS a
                        JOIN cron.job AS j ON j.command = a.query
                        WHERE j.jobname LIKE 'documentdb_index_build_task_%'
                          AND a.datname = current_database()
                          AND a.state = 'active');
                END IF;
            END IF;
            IF clock_timestamp() - started_at >
               (CASE WHEN index_path = 'notify' THEN interval '30 seconds'
                     ELSE interval '120 seconds' END) THEN
                RAISE EXCEPTION 'Timed out waiting for the cron index build: %', build_status;
            END IF;

            -- Release snapshots so the concurrent index build can finish.
            COMMIT;
            PERFORM pg_sleep(0.1);
        END LOOP;
    END LOOP;

    IF use_notify THEN
        IF clock_timestamp() - started_at >= interval '30 seconds' THEN
            RAISE EXCEPTION 'Expected a notification wakeup before 30 seconds, took %',
                clock_timestamp() - started_at;
        END IF;
        RAISE NOTICE 'Cron index creation woke before 30 seconds';
    ELSE
        IF clock_timestamp() - started_at <= interval '30 seconds' THEN
            RAISE EXCEPTION 'Expected the cron index build to take more than 30 seconds, took %',
                clock_timestamp() - started_at;
        END IF;
        RAISE NOTICE 'Cron index creation waited more than 30 seconds';
    END IF;
END;
$procedure$;

CALL documentdb_test_helpers.assert_cron_index_build_delay(false);

-- Cancel a listener, then verify both error and normal cleanup permit
-- another invocation to become the listener and wait for its idle timeout.
SET documentdb.enable_background_index_build_notify = on;
SET documentdb.indexBuildScheduleInSec TO 1;
SET statement_timeout TO '500ms';
CALL documentdb_api_internal.build_index_concurrently(1);
SET statement_timeout TO '180s';
SELECT count(*) = 0 AS canceled_listener_detached
FROM pg_listening_channels() AS channel
WHERE channel = 'documentdb_index_queue';
SELECT clock_timestamp() AS idle_wait_started_at \gset
CALL documentdb_api_internal.build_index_concurrently(1);
SELECT clock_timestamp() - :'idle_wait_started_at'::timestamptz >= interval '0.5 seconds'
    AS listener_waited_for_idle_timeout;
SELECT clock_timestamp() AS idle_wait_started_at \gset
CALL documentdb_api_internal.build_index_concurrently(1);
SELECT clock_timestamp() - :'idle_wait_started_at'::timestamptz >= interval '0.5 seconds'
    AS listener_waited_for_idle_timeout;
SELECT count(*) = 0 AS listener_detached
FROM pg_listening_channels() AS channel
WHERE channel = 'documentdb_index_queue';

-- Other tasks still build queued indexes, but must not remain idle listeners.
SELECT ok FROM documentdb_api.create_indexes_background('cron_schedule_db',
    '{"createIndexes":"cron_schedule_delay","indexes":[{"key":{"secondary":1},"name":"secondary_1"}]}');
CALL documentdb_api_internal.build_index_concurrently(2);
SELECT i.index_is_valid AS non_listener_built_index
FROM documentdb_api_catalog.collection_indexes AS i
JOIN documentdb_api_catalog.collections AS c USING (collection_id)
WHERE c.database_name = 'cron_schedule_db'
  AND c.collection_name = 'cron_schedule_delay'
  AND (i.index_spec).index_name = 'secondary_1';
SET statement_timeout TO '500ms';
CALL documentdb_api_internal.build_index_concurrently(2);
CALL documentdb_api_internal.build_index_concurrently(NULL);
SET statement_timeout TO '180s';
SELECT count(*) = 0 AS non_listener_detached
FROM pg_listening_channels() AS channel
WHERE channel = 'documentdb_index_queue';

SET documentdb.enable_background_index_build_notify = on;
SET documentdb.indexBuildScheduleInSec TO 60;

ALTER SYSTEM SET documentdb.enable_background_index_build_notify = on;
SELECT pg_reload_conf();
SET documentdb.maxNumActiveUsersIndexBuilds TO 2;
SELECT FROM documentdb_api_internal.schedule_background_index_build_jobs(true);
CALL documentdb_test_helpers.assert_cron_index_build_delay(true);

SELECT (i.index_spec).index_name, i.index_is_valid
FROM documentdb_api_catalog.collection_indexes AS i
JOIN documentdb_api_catalog.collections AS c USING (collection_id)
WHERE c.database_name = 'cron_schedule_db'
  AND c.collection_name = 'cron_schedule_delay'
  AND (i.index_spec).index_name IN ('a_1', 'notify_1')
ORDER BY (i.index_spec).index_name;

DROP PROCEDURE documentdb_test_helpers.assert_cron_index_build_delay(boolean);
SELECT documentdb_api.drop_collection('cron_schedule_db', 'cron_schedule_delay');

RESET documentdb.indexBuildScheduleInSec;
RESET documentdb.enable_background_index_build_notify;
RESET documentdb.maxNumActiveUsersIndexBuilds;
RESET documentdb.force_index_builds_blocking;
SELECT FROM documentdb_api_internal.schedule_background_index_build_jobs(true);
UPDATE cron.job SET active = false
WHERE jobname LIKE 'documentdb_index_build_task_%';

ALTER SYSTEM SET documentdb.indexBuildsScheduledOnBgWorker TO :'previous_index_build_mode';
ALTER SYSTEM SET documentdb.enable_background_index_build_notify TO :'previous_index_build_notify';
ALTER SYSTEM SET documentdb.indexBuildScheduleInSec TO :'previous_index_build_schedule';
SELECT pg_reload_conf();
RESET statement_timeout;
RESET search_path;
