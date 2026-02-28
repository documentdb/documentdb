# RBAC Metadata Infrastructure - Phase 1

Phase 1 implementation of RFC-006. See the RFC for complete design details.

## Files

### 001_metadata_tables.sql
Creates the core metadata infrastructure:

**Tables:**
- `user_roles` - Database-scoped role grants (username, role_name, database_name)
- `metadata_version` - Version tracking for cache invalidation
- `roles` - BSON role definitions with privileges

**Permissions:**
- Grants access to extension roles (documentdb_admin_role, documentdb_readonly_role, etc.)

**Functions:**
- `increment_metadata_version()` - Call after metadata changes
- `get_metadata_version()` - Query current version

### 002_builtin_roles.sql
Populates built-in role definitions:

| Role | MongoDB Name | Description |
|------|--------------|-------------|
| documentdb_readwrite_role | readWrite | Read and write access |
| documentdb_readonly_role | read | Read-only access |
| documentdb_admin_role | dbAdmin | Database administration |
| documentdb_user_admin_role | userAdmin | User/role management |
| documentdb_root_role | root | Superuser with all privileges |

### 003_copy_role_grants.sql
One-time migration script (runs during upgrades):
- Copies existing role grants from `pg_auth_members` to `user_roles`
- Maps PG role names to MongoDB names
- Idempotent and safe to run multiple times

## Installation

Automatically applied when upgrading to version 0.111-0:

```sql
ALTER EXTENSION documentdb_core UPDATE TO '0.111-0';
```

## Synchronization

After installation, RBAC metadata is automatically kept in sync with PostgreSQL roles:
- `createUser()` updates `user_roles` before granting PG roles
- `dropUser()` updates `user_roles` before dropping PG roles
- Both systems (metadata + PG roles) remain consistent

Implementation: `pg_documentdb/src/commands/users.c`

## References

- RFC-006: RBAC Support
