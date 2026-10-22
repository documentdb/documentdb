#include "udfs/commands_crud/cursor_functions--1.2-0.sql"
#include "rbac/collection_rbac_collection_owner_role--1.2-0.sql"
#include "rbac/collection_rbac_collection_create_role--1.2-0.sql"
#include "rbac/collection_rbac_index_create_role--1.2-0.sql"
#include "udfs/schema_mgmt/create_collection_with_privs--1.2-0.sql"
#include "udfs/ttl/delete_expired_rows_background--1.2-0.sql"
#include "udfs/index_mgmt/create_indexes_with_privs--1.2-0.sql"

#include "udfs/rum/bson_rum_shard_exclusion_functions--1.2-0.sql"

SELECT __API_SCHEMA_INTERNAL__.setup_index_queue_table(1, 2, 0);