CREATE TABLE __API_CATALOG_SCHEMA_V2__.__EXTENSION_OBJECT_V2__(_background_jobs)
(
  jobid integer not null,
  schedule_sec integer not null,
  command text not null,
  timeout_sec integer not null,
  exec_on_coordinator_only boolean not null,
  registered_time timestamp with time zone DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS __EXTENSION_OBJECT_V2__(_background_jobs_jobid_idx) ON __API_CATALOG_SCHEMA_V2__.__EXTENSION_OBJECT_V2__(_background_jobs) (jobid);

GRANT SELECT ON TABLE __API_CATALOG_SCHEMA_V2__.__EXTENSION_OBJECT_V2__(_background_jobs) TO public;
GRANT ALL ON TABLE __API_CATALOG_SCHEMA_V2__.__EXTENSION_OBJECT_V2__(_background_jobs) TO __API_ADMIN_ROLE__;