/*
 * Migrate roles table primary key from role_oid to role_name.
 * Role names are globally unique within the admin database and provide
 * a more stable identifier than OIDs (which can change across dump/restore).
 *
 * This table hasn’t been used as feature is still being developed.
 */

-- Drop old primary key, remove role_oid, add role_name as new PK
ALTER TABLE __API_CATALOG_SCHEMA__.roles DROP CONSTRAINT roles_pkey;
ALTER TABLE __API_CATALOG_SCHEMA__.roles DROP COLUMN role_oid;
ALTER TABLE __API_CATALOG_SCHEMA__.roles ADD COLUMN role_name text NOT NULL;
ALTER TABLE __API_CATALOG_SCHEMA__.roles ADD PRIMARY KEY (role_name);
