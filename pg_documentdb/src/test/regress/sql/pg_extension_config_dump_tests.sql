SET search_path TO documentdb_api, documentdb_api_catalog, documentdb_core, public;
SET documentdb.next_collection_id TO 73700;
SET documentdb.next_collection_index_id TO 73700;

SELECT n.nspname AS schema_name, c.relname, c.relkind
FROM pg_extension e
CROSS JOIN LATERAL unnest(e.extconfig) AS cfg(oid)
JOIN pg_class c ON c.oid = cfg.oid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE e.extname = 'documentdb'
ORDER BY n.nspname, c.relname;

ALTER EXTENSION documentdb UPDATE;

SELECT n.nspname AS schema_name, c.relname, c.relkind
FROM pg_extension e
CROSS JOIN LATERAL unnest(e.extconfig) AS cfg(oid)
JOIN pg_class c ON c.oid = cfg.oid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE e.extname = 'documentdb'
ORDER BY n.nspname, c.relname;
