#include "rbac/extension_schema_setup--0.110-0.sql"

#include "udfs/commands_crud/delete--0.110-0.sql"
#include "udfs/commands_crud/find_and_modify--0.110-0.sql"
#include "udfs/commands_crud/insert--0.110-0.sql"
#include "udfs/commands_crud/update--0.110-0.sql"

#include "udfs/index_mgmt/create_indexes_non_concurrently--0.110-0.sql"
#include "udfs/index_mgmt/record_id_index--0.110-0.sql"
#include "udfs/index_mgmt/create_builtin_id_index--0.110-0.sql"
#include "udfs/index_mgmt/drop_indexes--0.110-0.sql"
#include "udfs/index_mgmt/create_index_background--0.110-0.sql"

#include "udfs/metadata/collection--0.110-0.sql"
#include "udfs/metadata/empty_data_table--0.110-0.sql"
#include "udfs/metadata/replica_set_fields--0.110-0.sql"

#include "udfs/schema_mgmt/create_collection--0.110-0.sql"
#include "udfs/schema_mgmt/create_collection_view--0.110-0.sql"
#include "udfs/schema_mgmt/rename_collection--0.110-0.sql"
#include "udfs/schema_mgmt/drop_database--0.110-0.sql"
#include "udfs/schema_mgmt/drop_collection--0.110-0.sql"

#include "udfs/commands_crud/query_cursors_aggregate--0.110-0.sql"
#include "udfs/commands_crud/query_cursors_single_page--0.110-0.sql"
#include "udfs/commands_diagnostic/coll_stats--0.110-0.sql"
#include "udfs/commands_diagnostic/current_op--0.110-0.sql"
#include "udfs/commands_diagnostic/db_stats--0.110-0.sql"
#include "udfs/metadata/list_databases--0.110-0.sql"
#include "udfs/commands_diagnostic/validate--0.110-0.sql"
#include "udfs/commands_crud/insert_one_helper--0.110-0.sql"
#include "udfs/commands_crud/cursor_functions--0.110-0.sql"
#include "udfs/commands_crud/cursor_functions--0.110-0.sql"

-- Revoke public execute on all functions in documentdb_api_v2 schema
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA documentdb_api_v2 FROM PUBLIC;

-- Adding new built-in roles
#include "rbac/extension_readwrite_setup--0.110-0.sql"
#include "types/bsonindexterm--0.110-0.sql"
#include "udfs/index_mgmt/bson_index_term_functions--0.110-0.sql"
#include "operators/bsonindexterm_btree_operators--0.110-0.sql"
#include "operators/bsonindexterm_btree_operator_family--0.110-0.sql"
#include "udfs/commands_crud/insert--0.110-0.sql"
#include "udfs/commands_crud/update--0.110-0.sql"
#include "udfs/query/bson_orderby--0.110-0.sql"

#include "udfs/rum/composite_path_operator_functions--0.110-0.sql"