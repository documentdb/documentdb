SET search_path TO documentdb_api_catalog, documentdb_core, public;
SET documentdb.next_collection_id TO 400;
SET documentdb.next_collection_index_id TO 400;

set documentdb_rum.enable_new_bulk_delete to off;
set documentdb_rum.prune_rum_empty_pages to off;

\i sql/rum_vacuum_cleanup_tests_core.sql