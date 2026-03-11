-- documentdb--0.110-0--0.111-0.sql
-- Upgrade script from version 0.110-0 to 0.111-0
-- Adds RBAC (Role-Based Access Control) metadata infrastructure for RFC-006

#include "rbac/metadata_tables--0.111-0.sql"
#include "rbac/builtin_roles--0.111-0.sql"
#include "rbac/copy_role_grants--0.111-0.sql"
