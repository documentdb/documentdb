
-- Roles table: migrate primary key from role_oid to role_name.
SELECT documentdb_api_internal.apply_extension_data_table_upgrade(0, 116, 0);

#include "udfs/commands_crud/delete--0.116-0.sql"
#include "udfs/aggregation/bson_unwind_functions--0.116-0.sql"
#include "udfs/query/bson_dollar_comparison--0.116-0.sql"
