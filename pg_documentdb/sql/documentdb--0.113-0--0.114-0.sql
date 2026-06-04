
#include "udfs/query/bson_dollar_object_id_comparison--0.114-0.sql"
#include "udfs/query/bson_query_match--0.114-0.sql"
#include "udfs/schema_validation/schema_validation--0.114-0.sql"

-- Roles table: migrate primary key from role_oid to role_name
#include "schema/roles_metadata--0.114-0.sql"
