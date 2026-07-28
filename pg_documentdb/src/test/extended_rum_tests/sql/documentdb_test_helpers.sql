\i ../regress/sql/documentdb_test_helpers.sql

CREATE OR REPLACE FUNCTION documentdb_api_internal.rum_prune_empty_entries_on_index(index_relid regclass)
RETURNS void
LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum', 'documentdb_extended_rum_prune_empty_entries_on_index';

CREATE OR REPLACE FUNCTION documentdb_api_internal.documentdb_rum_page_get_stats(page bytea)
RETURNS jsonb
LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum', 'documentdb_extended_rum_page_get_stats';

CREATE OR REPLACE FUNCTION documentdb_api_internal.documentdb_rum_get_meta_page_info(page bytea)
RETURNS jsonb
LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum', 'documentdb_extended_rum_get_meta_page_info';

CREATE OR REPLACE FUNCTION documentdb_api_internal.documentdb_rum_page_get_entries(page bytea, indexRelId Oid)
RETURNS SETOF jsonb
LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum', 'documentdb_extended_rum_page_get_entries';

CREATE OR REPLACE FUNCTION documentdb_api_internal.documentdb_rum_page_get_data_items(page bytea)
RETURNS SETOF jsonb
LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum', 'documentdb_extended_rum_page_get_data_items';

CREATE OR REPLACE FUNCTION documentdb_api_internal.documentdb_rum_repair_revive_all_pages_and_tuples(index_oid oid, dry_run bool)
RETURNS void
LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum', 'documentdb_extended_rum_repair_revive_all_pages_and_tuples';

CREATE OR REPLACE FUNCTION documentdb_api_internal.documentdb_rum_test_set_incomplete_split_on_page(index_relid regclass, block_number integer, set_incomplete_split boolean)
RETURNS void
LANGUAGE c
AS '$libdir/pg_documentdb_extended_rum', 'documentdb_extended_rum_test_set_incomplete_split_on_page';

-- Turn off cron jobs to avoid flakiness in tests.
UPDATE cron.job set active = false;