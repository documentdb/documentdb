/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/roles.h
 *
 * Role CRUD functions.
 *
 *-------------------------------------------------------------------------
 */

#ifndef EXTENSION_ROLES_H
#define EXTENSION_ROLES_H

#include "postgres.h"
#include "utils/string_view.h"

/* Method to create a role */
Datum create_role(pgbson *createRoleBson);

/* Method to drop a role */
Datum drop_role(pgbson *dropRoleBson);

/* Method to get roles information */
Datum roles_info(pgbson *rolesInfoBson);

/* Method to update a role */
Datum update_role(pgbson *updateRoleBson);

/* Method to grant roles to an existing custom role */
Datum grant_roles_to_role(pgbson *grantRolesBson);

/* Method to grant a resource-scoped privilege to an existing custom role */
Datum grant_privileges_to_role(pgbson *grantPrivilegesBson);

/* Method to revoke roles from an existing custom role */
Datum revoke_roles_from_role(pgbson *revokeRolesBson);

/* Method to revoke a resource-scoped privilege from an existing custom role */
Datum revoke_privileges_from_role(pgbson *revokePrivilegesBson);

/*
 * Parses a "roles" array, accepting either plain role names or {role, db}
 * documents, and collects the role names into parentRoles.
 */
void ParseParentRolesArray(bson_iter_t *rolesIter, HTAB *parentRoles);

/*
 * Validates every role in parentRoles and revokes it from targetRoleName.
 */
void ValidateAndRevokeParentRoles(const char *targetRoleName, HTAB *parentRoles);

/*
 * Validates every role in parentRoles and grants it to targetRoleName. When
 * allowCustomRoles is false only built-in roles may be granted.
 */
void ValidateAndGrantParentRoles(const char *targetRoleName, HTAB *parentRoles,
								 bool allowCustomRoles);

#endif
