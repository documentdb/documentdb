#include "rbac/setup_root_role--1.1-0.sql"
#include "udfs/aggregation/bson_unwind_functions--1.1-0.sql"
#include "udfs/schema_mgmt/cursor_support--1.1-0.sql"
#include "udfs/roles/grant_roles_to_role--1.1-0.sql"
#include "udfs/roles/grant_privileges_to_role--1.1-0.sql"
#include "udfs/roles/grant_roles_to_user--1.1-0.sql"
#include "udfs/roles/is_reserved_user--1.1-0.sql"
#include "udfs/roles/revoke_roles_from_role--1.1-0.sql"
#include "udfs/roles/revoke_privileges_from_role--1.1-0.sql"
#include "udfs/roles/revoke_roles_from_user--1.1-0.sql"

-- Grant read to all data for the cluster wide read role.
GRANT pg_read_all_data TO documentdb_readonly_role;

#include "rbac/collection_rbac_roles--1.1-0.sql"
