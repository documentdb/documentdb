/* Interim perms/setup for background worker role. */
-- Make policy creation idempotent
DO $$
BEGIN
    DROP POLICY IF EXISTS cron_job_bg_worker_policy ON cron.job;
    CREATE POLICY cron_job_bg_worker_policy ON cron.job
        FOR SELECT
        TO __API_BG_WORKER_ROLE__
        USING (true);
EXCEPTION
    WHEN duplicate_object THEN
        NULL;
END $$;

GRANT USAGE ON SCHEMA cron TO __API_BG_WORKER_ROLE__;
GRANT SELECT ON cron.job TO __API_BG_WORKER_ROLE__;