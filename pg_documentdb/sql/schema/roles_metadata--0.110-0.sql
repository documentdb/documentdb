/*
 * Table to store custom role definitions for custom role RBAC.
 * 
 * This table serves as the source of truth for rolesInfo queries,
 * storing the original createRole/updateRole BSON document.
 */

CREATE TABLE __API_CATALOG_SCHEMA__.roles (
    role_oid oid NOT NULL,
    role_bson __CORE_SCHEMA__.bson NOT NULL,
    PRIMARY KEY (role_oid)
);

-- Grant access to the roles table
GRANT SELECT ON TABLE __API_CATALOG_SCHEMA__.roles TO __API_ADMIN_ROLE_V2__;