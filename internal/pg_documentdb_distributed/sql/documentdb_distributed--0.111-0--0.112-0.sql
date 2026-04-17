-- for index builds scheduled on background workers
GRANT SELECT on pg_authid TO __API_BG_WORKER_ROLE__;